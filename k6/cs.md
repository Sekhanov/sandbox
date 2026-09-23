## k6 Basics

**What is k6?**  
An open-source, developer-friendly load testing tool built by Grafana. You write tests in JavaScript (ES6) and run them via CLI.

**Core Concepts:**
- **VUs (Virtual Users):** Concurrent users running your script.
- **Iterations:** How many times your script runs (each VU runs it repeatedly).
- **Stages:** Ramping up/down VU load over time.
- **Checks:** Assertions that verify responses (like `status === 200`).
- **Thresholds:** Pass/fail criteria for the whole test (e.g., "95% of requests must be < 200ms").
- **Options:** Configure VUs, duration, stages, thresholds in the script or via CLI.

---

## Cheat Sheet

### 1. Basic Script Template
```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 10,          // 10 virtual users
  duration: '30s',  // for 30 seconds
};

export default function () {
  const res = http.get('https://test-api.example.com');
  
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
  
  sleep(1); // Think time (1 second)
}
```

---

### 2. Common `options` (Stages & Thresholds)
```javascript
export const options = {
  stages: [
    { duration: '1m', target: 50 },  // Ramp up to 50 VUs
    { duration: '3m', target: 50 },  // Stay at 50
    { duration: '1m', target: 0 },   // Ramp down to 0
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],        // < 1% failure rate
    http_req_duration: ['p(95)<200'],      // 95% requests under 200ms
  },
};
```

---

### 3. HTTP Methods
```javascript
// GET
http.get('https://api.com/users');

// POST (with JSON)
const payload = JSON.stringify({ name: 'John' });
const params = { headers: { 'Content-Type': 'application/json' } };
http.post('https://api.com/users', payload, params);

// PUT / DELETE / PATCH
http.put(url, body, params);
http.del(url, params);
http.patch(url, body, params);
```

---

### 4. Useful Imports & Functions
| Import | Use |
|--------|-----|
| `http` | All HTTP requests |
| `check` | Assertions |
| `sleep(seconds)` | Pause VU execution |
| `group('name', fn)` | Group requests in results |
| `__VU` | Current VU ID (0 for init) |
| `__ITER` | Current iteration number |

---

### 5. `setup()` and `teardown()` (for auth/tokens)
```javascript
export function setup() {
  // Runs once before all VUs
  const res = http.post('https://api.com/login', { user: 'test' });
  return { token: res.json('token') };
}

export default function (data) {
  // data.token is available here
  http.get('https://api.com/dashboard', {
    headers: { Authorization: `Bearer ${data.token}` },
  });
}

export function teardown(data) {
  // Runs once after all VUs (cleanup)
}
```

---

### 6. Data Parameterization (CSV)
```javascript
import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
const csvData = papaparse.parse(open('users.csv'), { header: true }).data;

export default function () {
  const user = csvData[__ITER % csvData.length]; // Round-robin
  http.post('https://api.com/login', JSON.stringify(user));
}
```

---

### 7. CLI Commands (Most Used)
| Command | Description |
|---------|-------------|
| `k6 run script.js` | Run a test |
| `k6 run -u 10 -i 100 script.js` | 10 VUs, 100 total iterations |
| `k6 run --out csv=result.csv script.js` | Output results to CSV |
| `k6 run --out influxdb=http://localhost:8086 script.js` | Stream to InfluxDB (for Grafana) |
| `k6 run --vus 20 --duration 1m script.js` | Override options in CLI |
| `k6 inspect script.js` | Show options without running |

---

### 8. Useful Metrics (Built-in)
| Metric | What it measures |
|--------|------------------|
| `http_req_duration` | Total request time |
| `http_req_waiting` | Time to first byte (TTFB) |
| `http_req_connecting` | TCP connection time |
| `http_req_blocked` | Time blocked (waiting for socket) |
| `http_req_failed` | Rate of failed requests |
| `iterations` | Number of script iterations |
| `vus` | Current active VUs |
| `vus_max` | Max VUs allowed |

---

### 9. Tags & Custom Metrics (Advanced)
```javascript
import { Counter } from 'k6/metrics';
const myCounter = new Counter('my_custom_counter');

export default function () {
  myCounter.add(1, { tag: 'value' });
  
  // Tag individual requests
  http.get('https://api.com', { tags: { name: 'homepage' } });
}
```

---

### 10. Quick Debugging
- Use `console.log()` (outputs to terminal).
- Run with `--verbose` for more logs.
- Use `k6 run --http-debug script.js` to see raw HTTP requests/responses.

---

**Pro Tip:** Always run a smoke test first (`-u 1 -i 1`) to validate your script before heavy load.

Again, sorry for the Chinese mishap. Let me know if you want a deeper dive into any specific area (thresholds, custom metrics, distributed testing, or browser-based k6)!