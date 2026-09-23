// Load test for POST /security-match (COR-11163).
// Run: k6 run tmp/cor-11163/security-match-load-test.js
// Override target: k6 run -e BASE_URL=http://localhost:3010 -e API_ENV=dev
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';
import { Trend } from 'k6/metrics';

const responseSizeKB = new Trend('response_size_kb');

// test configx
const BATCH_SIZE = 1000;
const V_USER_COUNT = 10;
const ITERATIONS = 100


const BASE_URL = __ENV.BASE_URL || 'http://localhost:3010';
const API_ENV = __ENV.API_ENV || 'dev';

const RESULTS_FILE = './security-match-load-test-results.csv';
const CSV_HEADER = 'timestamp,api_env,batch_size,iterations,vus,checks_pass_rate_pct,http_req_duration_avg_ms,http_req_duration_p95_ms,http_req_duration_max_ms,response_size_kb_avg,response_size_kb_max\n';

// open() only works in init context, so the existing results (if any) are read once here
// and handleSummary() appends to them - each `k6 run` adds exactly one new row.
let existingResults = '';
try {
    existingResults = open(RESULTS_FILE);
} catch (e) {
    existingResults = '';
}

const securityIds = new SharedArray('securityIds', function () {
    return open('./security_ids.csv')
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => line.length > 0);
});

export const options = {
    vus: V_USER_COUNT,
    iterations: ITERATIONS,
};

function pickRandomBatch(pool, size) {
    const indices = new Set();
    while (indices.size < size) {
        indices.add(Math.floor(Math.random() * pool.length));
    }
    return Array.from(indices, (i) => pool[i]);
}

export default function () {
    const security_ids = pickRandomBatch(securityIds, BATCH_SIZE);

    const headers = { 'Content-Type': 'application/json' };

    const res = http.post(
        `${BASE_URL}/${API_ENV}/security-master/factset/security-match`,
        JSON.stringify({ security_ids }),
        { headers },
    );

    responseSizeKB.add(res.body ? res.body.length / 1024 : 0);

    check(res, {
        'status is 200': (r) => r.status === 200,
        'has data object': (r) => {
            const body = r.json();
            return !!(body && body.data && typeof body.data === 'object');
        },
    });
}

function metricValue(data, name, stat, fallback) {
    const metric = data.metrics[name];
    const value = metric && metric.values ? metric.values[stat] : undefined;
    return typeof value === 'number' ? value : fallback;
}

export function handleSummary(data) {
    const row = [
        new Date().toISOString(),
        API_ENV,
        BATCH_SIZE,
        options.iterations,
        options.vus,
        (metricValue(data, 'checks', 'rate', 0) * 100).toFixed(1),
        metricValue(data, 'http_req_duration', 'avg', 0).toFixed(2),
        metricValue(data, 'http_req_duration', 'p(95)', 0).toFixed(2),
        metricValue(data, 'http_req_duration', 'max', 0).toFixed(2),
        metricValue(data, 'response_size_kb', 'avg', 0).toFixed(2),
        metricValue(data, 'response_size_kb', 'max', 0).toFixed(2),
    ].join(',');

    const base = existingResults.trim().length > 0
        ? existingResults.replace(/\n+$/, '\n')
        : CSV_HEADER;

    return {
        stdout: `Appended results row to ${RESULTS_FILE}:\n${CSV_HEADER}${row}\n`,
        [RESULTS_FILE]: `${base}${row}\n`,
    };
}
