# k6 cheat sheet / beginner's guide

k6 is a load-testing tool. You write a test in JavaScript, k6 runs it many times
(concurrently if you want) and reports timings and pass/fail checks.

## Install & run
```zsh
brew install k6              # macOS
k6 version
k6 run script.js            # run a test
k6 inspect script.js        # parse-check a script without running it
```

## Minimal script
```js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = { vus: 5, duration: '30s' };   // 5 users for 30s

export default function () {
  const res = http.get('http://localhost:3010/health');
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);                                            // pause 1s per iteration
}
```
- **`export default function`** = one iteration. k6 repeats it per VU.
- **VU** (virtual user) = one concurrent worker running the default function in a loop.
- **iteration** = one run of the default function.

## Core concepts

| Term | Meaning |
|---|---|
| VU | concurrent virtual user |
| iteration | one execution of `export default` |
| check | non-failing assertion (records pass/fail, keeps going) |
| threshold | pass/fail rule for the whole run (sets exit code) |
| metric | a measured value (Trend/Counter/Rate/Gauge) |
| scenario | a named workload profile |

## How many times does it run? (`options`)
```js
export const options = { vus: 10, duration: '1m' };   // load for a duration
export const options = { vus: 1,  iterations: 20 };    // exactly 20 iterations total
export const options = {                               // ramp up/down
  stages: [
    { duration: '30s', target: 20 },   // ramp to 20 VUs
    { duration: '1m',  target: 20 },   // hold
    { duration: '10s', target: 0 },    // ramp down
  ],
};
```

## Scenarios (named workloads / arrival rate)
Run several workloads with different executors, functions, and start times.
```js
export const options = {
  scenarios: {
    // constant-arrival-rate: hold a fixed REQ/S, k6 adds VUs as needed (throughput test)
    api_v1: {
      executor: 'constant-arrival-rate',
      exec: 'v1',            // which exported function to run
      rate: 10, timeUnit: '1s', duration: '30s',
      preAllocatedVUs: 20, maxVUs: 100,
      startTime: '0s',
    },
    api_v2: { executor: 'constant-arrival-rate', exec: 'v2',
      rate: 10, timeUnit: '1s', duration: '30s',
      preAllocatedVUs: 20, maxVUs: 100, startTime: '30s' }, // starts after api_v1
  },
};
export function v1() { /* ... */ }
export function v2() { /* ... */ }
```
- `constant-arrival-rate` fixes **requests/sec** (not VUs) — the right way to compare throughput/latency.
  If k6 can't hit the rate with `maxVUs`, it warns "insufficient VUs" (a saturation signal).
- Same `startTime` = scenarios run **together**; stagger them to isolate each backend.
- Metrics can be filtered per scenario: threshold `'http_req_duration{scenario:api_v2}': ['p(95)<1000']`.

## HTTP requests
```js
import http from 'k6/http';

http.get(url, params);
http.post(url, body, params);
http.put(url, body, params);
http.del(url, body, params);
http.request('PATCH', url, body, params);

// params:
const params = {
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${t}` },
  tags: { name: 'my-endpoint' },   // groups metrics by this label
};

// JSON body:
http.post(url, JSON.stringify({ a: 1 }), params);
```
Response object: `res.status`, `res.body`, `res.json()`, `res.timings.duration` (ms),
`res.headers`.

## Checks (assertions that don't stop the test)
```js
check(res, {
  'status is 200': (r) => r.status === 200,
  'has data':      (r) => r.json().data !== undefined,
});
```
A failing check is recorded (shown as `checks` %) but the iteration continues.
To fail an iteration hard, `throw` or use `fail()` from `k6`.

## Thresholds (make the run pass/fail → CI exit code)
```js
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<500'],   // 95th percentile under 500ms
    http_req_failed:   ['rate<0.01'],   // <1% requests failed
    checks:            ['rate==1'],     // 100% of checks pass
  },
};
```
If a threshold fails, `k6 run` exits non-zero (good for CI).

## Custom metrics
```js
import { Trend, Counter, Rate, Gauge } from 'k6/metrics';

const myDuration = new Trend('my_duration', true); // true = time metric (ms)
const myErrors   = new Counter('my_errors');
const myRate     = new Rate('my_success');         // % true

myDuration.add(res.timings.duration);
myErrors.add(1);
myRate.add(res.status === 200);
```

The four metric types — pick one for what you `.add()`:

| Type | You add | It computes | Use for |
|---|---|---|---|
| **Trend** | numbers (e.g. durations) | `avg`, `min`, `med`, `max`, `p(90)`, `p(95)` | timing/size distributions — "how fast?" |
| **Rate** | booleans (`true`/`false`) | the % that were `true` | success/match ratios — "how often true?" |
| **Counter** | numbers (usually `1`) | the running total (`count`, `rate`/sec) | "how many total?" |
| **Gauge** | numbers | the **last** value added | a current level (e.g. queue size) |

- **`Trend`** — a distribution of values. `new Trend('name', true)` marks it a *time* metric so k6 prints it in ms. In this folder's script `v1_duration` / `v2_duration` collect `res.timings.duration` each iteration, so the summary shows avg/p95/max latency per version → the speed comparison.
- **`Rate`** — a true/false ratio. Each `.add(boolean)`; the summary shows the fraction that were `true` (0–1). Here `results_match` / `objects_match` get `.add(true|false)` per iteration, so the summary shows the % of iterations that matched. A threshold like `['rate==1']` then means "must be true every time".

## Built-in metrics worth knowing
- `http_req_duration` — total request time (has `avg`, `p(90)`, `p(95)`, `max`, …).
- `http_req_failed` — request failure rate.
- `iterations`, `vus`, `checks`, `data_sent`, `data_received`.

## Reading data from files (`SharedArray`)
`open()` only works in *init* context (top level, not inside the default function).
`SharedArray` loads data once and shares it across all VUs (memory-efficient).
```js
import { SharedArray } from 'k6/data';

const rows = new SharedArray('rows', function () {
  return open('./data.csv').split('\n').filter((l) => l.length > 0);
});

export default function () {
  const row = rows[__ITER % rows.length];   // pick one per iteration
}
```

## Useful globals & modules
```js
__VU        // current VU number (1-based)
__ITER      // iteration number within this VU (0-based)
__ENV.NAME  // env var passed via -e NAME=value

import exec from 'k6/execution';
exec.scenario.iterationInTest;   // global iteration index across all VUs
```

## Passing values at runtime
```zsh
k6 run -e BASE_URL=http://localhost:3010 script.js
```
```js
const base = __ENV.BASE_URL || 'http://localhost:3010';
```

## Output & reports
```zsh
k6 run script.js                          # summary in the terminal
k6 run --summary-export=summary.json s.js  # machine-readable summary
k6 run --out json=raw.json s.js            # every metric point (large)
k6 run --out csv=raw.csv s.js
```
Custom end-of-run report / write your own file:
```js
export function handleSummary(data) {
  return {
    stdout: 'my summary text\n',
    './result.csv': 'col1,col2\n1,2\n',   // returned files are written to disk
  };
}
```

## Test lifecycle (run order)
```js
// 1. init — top-level code, imports, open() files (runs once per VU at startup)
export function setup() { /* 2. once before the test; return value passed to default */ }
export default function (data) { /* 3. the test, repeated */ }
export function teardown(data) { /* 4. once after the test */ }
export function handleSummary(data) { /* 5. build the final report */ }
```

## Gotchas
- `open()` and `SharedArray` are **init-only** — can't call them inside the default function.
- k6 is **not Node.js**: no `fs`, no `require`, no npm modules at runtime. Use k6's own
  modules (`k6/http`, `k6/metrics`, …) or bundle with a tool first.
- Each VU has its own JS context — module-level `let x` is **not** shared between VUs.
  Share read-only data with `SharedArray`; share numbers via custom metrics.
- Times from `res.timings.*` are in **milliseconds**.
- A test with `duration` ignores `iterations` and vice versa.

## This folder's example
`entity-search-parity.js` uses most of the above: `SharedArray` (reads `search-terms.json`),
custom `Trend`/`Rate`/`Counter` metrics, `check`, `thresholds`, `exec.scenario.iterationInTest`
for term rotation, and `handleSummary` to print a report and append a CSV row. Run it with:
```zsh
k6 run entity-search-parity.js
```

## Docs
Full reference: <https://grafana.com/docs/k6/latest/>
