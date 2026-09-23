// COR-11399 — entity search STRESS test: v1 (RDS) vs v2 (OpenSearch) under rising concurrency.
// Run: k6 run entity-search-load.js   (local app, REQUIRE_AUTH=false, LEGACY_ENTITY_SEARCH=true so v1=RDS)
//
// Why a ramp (not a flat rate): RDS `LIKE '%term%'` can't use an index (leading wildcard), so it
// CPU-scans per query. At low concurrency that's cheap and beats OpenSearch; as the arrival rate
// climbs those scans contend and RDS latency/err-rate grow, while OpenSearch's inverted index stays
// flatter. We ramp each endpoint's arrival rate (sequentially) and compare latency + sustained
// capacity (watch `dropped_iterations` — the rate a backend could NOT keep up with).
//
// ⚠️ Hits SHARED dev backends. Keep PEAK modest; raise it only against a dedicated environment.
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';
import { Trend } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.3/index.js';

const V1 = 'http://localhost:3010/dev/security-master/factset/entity-search';
const V2 = 'http://localhost:3010/dev/v2/security-master/factset/entity-search';

// Arrival-rate ramp (req/s) applied to each endpoint. PEAK is the knob — raise only off shared dev.
const STAGES = [
    { target: 25, duration: '15s' },
    { target: 50, duration: '15s' },
    { target: 100, duration: '15s' }, // PEAK
    { target: 100, duration: '15s' },
];
const RAMP = '60s'; // = sum(STAGES); used to start v2 after v1's ramp

const v1Time = new Trend('v1_duration', true);
const v2Time = new Trend('v2_duration', true);

const cases = new SharedArray('cases', () => JSON.parse(open('./search-terms.json')));

// One row per run is appended here. k6 can't append, so read the old file at init and rewrite it.
// Run from this folder: open() resolves next to the script, handleSummary writes relative to cwd.
const CSV = 'entity-search-load.csv';
const CSV_HEADER = 'run_time,backend,peak_rps,avg_ms,med_ms,p90_ms,p95_ms,max_ms,http_req_failed_rate,dropped_iterations\n';
let previousCsv = CSV_HEADER;
try { previousCsv = open('./' + CSV); } catch (e) { /* first run: no file yet */ }

const scenario = (exec, startTime) => ({
    executor: 'ramping-arrival-rate',
    exec,
    startRate: 10,
    timeUnit: '1s',
    stages: STAGES,
    startTime,
    preAllocatedVUs: 30,
    maxVUs: 200,
});

export const options = {
    scenarios: {
        v1: scenario('v1', '0s'),
        v2: scenario('v2', RAMP), // v2 ramps after v1 finishes, so the backends don't compete
    },
    // Correctness only. Latency/capacity are reported (trends + table + dropped_iterations), not gated:
    // locally the absolute numbers are cache/network-dominated and swing run-to-run (see README).
    thresholds: {
        http_req_failed: ['rate==0'], // every request must return 200
        // Always-pass thresholds: they only make k6 report these metrics per scenario for the CSV.
        'http_req_failed{scenario:v1}': ['rate>=0'],
        'http_req_failed{scenario:v2}': ['rate>=0'],
        'dropped_iterations{scenario:v1}': ['count>=0'],
        'dropped_iterations{scenario:v2}': ['count>=0'],
    },
};

function query(c) {
    const p = ['input_string=' + encodeURIComponent(c.input_string)];
    (c.entity_type_order || []).forEach((t) => p.push('entity_type_order=' + encodeURIComponent(t)));
    (c.entity_type || []).forEach((t) => p.push('entity_type=' + encodeURIComponent(t)));
    return '?' + p.join('&');
}

function hit(url, trend) {
    const c = cases[Math.floor(Math.random() * cases.length)];
    const res = http.get(url + query(c));
    trend.add(res.timings.duration);
    check(res, { 'status 200': (r) => r.status === 200 });
}

export function v1() { hit(V1, v1Time); }
export function v2() { hit(V2, v2Time); }

// Append a v1-vs-v2 latency comparison table under the default k6 summary.
const ms = (v) => (v >= 1000 ? (v / 1000).toFixed(2) + 's' : v.toFixed(0) + 'ms');

function durationTable(data) {
    const cols = ['', 'avg', 'med', 'p90', 'p95', 'max'];
    const row = (label, m) => [label, ms(m.avg), ms(m.med), ms(m['p(90)']), ms(m['p(95)']), ms(m.max)]
        .map((c, i) => (i === 0 ? c.padEnd(10) : c.padStart(9))).join(' | ');
    const head = cols.map((c, i) => (i === 0 ? c.padEnd(10) : c.padStart(9))).join(' | ');
    return [
        '',
        'v1 (RDS) vs v2 (OpenSearch) — under ramp to ' + STAGES.reduce((m, s) => Math.max(m, s.target), 0) + ' req/s',
        head,
        '-'.repeat(head.length),
        row('v1 (RDS)', data.metrics.v1_duration.values),
        row('v2 (OS)', data.metrics.v2_duration.values),
        '',
    ].join('\n');
}

// One row per backend: RDS (v1) first, then OpenSearch (v2), both with the same run_time.
function csvRows(data) {
    const runTime = new Date().toISOString();
    const peak = STAGES.reduce((m, s) => Math.max(m, s.target), 0);
    const value = (name, field) => (data.metrics[name] ? data.metrics[name].values[field] : 0);
    const row = (backend, v) => {
        const d = data.metrics[`${v}_duration`].values;
        return [
            runTime,
            backend,
            peak,
            ...[d.avg, d.med, d['p(90)'], d['p(95)'], d.max].map((x) => x.toFixed(1)),
            value(`http_req_failed{scenario:${v}}`, 'rate').toFixed(4),
            value(`dropped_iterations{scenario:${v}}`, 'count'),
        ].join(',') + '\n';
    };
    return row('RDS', 'v1') + row('OpenSearch', 'v2');
}

export function handleSummary(data) {
    return {
        stdout: textSummary(data, { indent: ' ', enableColors: true }) + '\n' + durationTable(data),
        [CSV]: previousCsv + csvRows(data),
    };
}
