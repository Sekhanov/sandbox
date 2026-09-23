import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

// --------------------------------------------
// CSV output — run k6 from the script directory
// --------------------------------------------
const TEST_NAME  = __ENV.TEST_NAME || 'cor-10635-FUT+index';
const CSV_HEADER = 'name,timestamp,vus,iterations,duration_ms,req_avg_ms,req_p95_ms,req_p99_ms,failed_rate,rps\n';

let existingCsv;
try {
    existingCsv = open('./results.csv');
} catch (_) {
    existingCsv = CSV_HEADER;
}

// --------------------------------------------
// 1. Pre-defined pools of 100 IDs each
// --------------------------------------------
const SECURITY_IDS = Array.from({ length: 10000 }, (_, i) => `SEC-${String(i + 1).padStart(4, '0')}`);
const ENTITY_IDS   = Array.from({ length: 10000 }, (_, i) => `ENT-${String(i + 1).padStart(4, '0')}`);

// --------------------------------------------
// 2. Test options — shared-iterations measures
//    wall-clock time to complete all 1000 requests
// --------------------------------------------
export const options = {
    scenarios: {
        throughput: {
            executor: 'shared-iterations',
            vus: 50,
            iterations: 10000,
            maxDuration: '5m',
        },
    },
    thresholds: {
        http_req_duration:  ['p(95)<20000'],   // 95% of requests under 2 s
        http_req_failed:    ['rate<0.01'],     // error rate under 1%
        iteration_duration: ['p(99)<2000'],    // 99% of iterations under 2 s
    },
};

// --------------------------------------------
// 3. Fisher-Yates partial shuffle — O(n) random sample
// --------------------------------------------
function pickRandom(arr, n) {
    const copy = arr.slice();
    for (let i = copy.length - 1; i >= copy.length - n; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const tmp = copy[i]; copy[i] = copy[j]; copy[j] = tmp;
    }
    return copy.slice(copy.length - n);
}

// --------------------------------------------
// 4. Main function — no sleep, maximise throughput
// --------------------------------------------
export default function () {
    const payload = JSON.stringify({
        security_ids: pickRandom(SECURITY_IDS, 500),
        entity_ids:   pickRandom(ENTITY_IDS, 500),
        universe_type: 'FUT',
        // universe_type: 'FI',
    });

    const res = http.post(
        'http://localhost:3010/dev/security-master/factset/pre-fetch',
        payload,
        {
            headers: {
                'accept': 'application/json',
                'Content-Type': 'application/json',
            },
            tags: { name: 'prefetch' },
        }
    );

    // check(res, {
    //     'status is 200':         (r) => r.status === 200,
    //     'response time < 2s':  (r) => r.timings.duration < 2000,
    // });
}

// --------------------------------------------
// 5. Append one row to results.csv after each run
// --------------------------------------------
export function handleSummary(data) {
    const m   = data.metrics;
    const dur = data.state.testRunDurationMs;
    const iters = m.iterations ? m.iterations.values.count : 0;
    const vus   = m.vus_max   ? m.vus_max.values.max       : 0;

    const row = [
        TEST_NAME,
        new Date().toISOString(),
        vus,
        iters,
        Math.round(dur),
        Math.round(m.http_req_duration.values.avg),
        Math.round(m.http_req_duration.values['p(95)']),
        Math.round(m.http_req_duration.values['p(99)']),
        m.http_req_failed ? m.http_req_failed.values.rate.toFixed(4) : '0.0000',
        dur > 0 ? (iters / (dur / 1000)).toFixed(2) : '0.00',
    ].join(',') + '\n';

    const csvLine =
        '\n--- CSV row appended to results.csv ---\n' +
        CSV_HEADER +
        row;

    return {
        'results.csv': existingCsv + row,
        stdout: textSummary(data, { indent: '  ', enableColors: true }) + csvLine,
    };
}
