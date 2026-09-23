# COR-10967 — Test Manual

## Bug Summary

A trade/holding flagged as both `is_future = 'Yes'` and `is_option = 'Yes'` is picked up by the
futures and options matchers simultaneously (via `Promise.all`). If futures matches first and sets
`security_id = 'DAX'` + `status = 'TRADE'`, the options failure path overwrites `security_id = ''`
because the failure UPDATE lacked a `WHERE LOWER(status) = 'pending'` guard.

---

## Job naming clarification

| Job name | What it runs |
|---|---|
| `trade-preprocess-job` | `fn_process_trades` (sets flags) → security matching |
| `holdings-preprocess-job` | security matching only (no `fn_process_holdings`) |
| `holdings-process-job` | holdings transfer from client DBs — **unrelated to this bug** |

---

## Setup

```bash
cd lambdas/rules-engine-3.0
```

Ensure `.env` has Central DB credentials.

---

## Test 1 — `trade-preprocess-job`

`fn_process_trades` sets `ACEX` when `pdl_account_code` is `NULL` or unknown, so we bypass it
entirely using the test script which calls `runSecurityMatching()` directly.

### Step 1 — Insert test trade

```sql
INSERT INTO brokerdb.trade_data (
    status,
    security_type,
    security_name,    -- 'put %' → options matcher picks this up
    symbol,
    currency_code,
    description,
    file_name,
    pdl_client_code,
    source,
    transaction_date,
    processed,
    is_future,        -- pre-set: futures matcher picks this up
    is_option         -- pre-set: options matcher also picks this up → race condition
) VALUES (
    'PENDING',
    'Futures',
    'put DAX (EUR)',
    'DAX',
    'EUR',
    'DAX (EUR)',
    'TEST_TESTBROKER',
    'test',
    'Direct Feed',
    NOW(),
    'NO',
    'Yes',
    'Yes'
);
```

### Step 2 — Note the trade_id

```sql
SELECT trade_id FROM brokerdb.trade_data
WHERE pdl_client_code = 'test'
ORDER BY trade_id DESC
LIMIT 1;
```

### Step 3 — Run security matching only (bypasses fn_process_trades)

```bash
npx ts-node -r dotenv/config -r tsconfig-paths/register src/scripts/testSecurityMatching.ts trades
```

### Step 4 — Verify

```sql
SELECT trade_id, status, security_id, process_outcome, is_future, is_option
FROM brokerdb.trade_data
WHERE trade_id = <trade_id from Step 2>;
```

| Scenario    | `security_id` | `process_outcome` |
|-------------|---------------|-------------------|
| Before fix  | _(empty)_     | `Fail: Could Not Find Matching Security ID` |
| After fix   | `DAX`         | `Success: Found single futures security in FactSet by security_name, currency_code` |

### Cleanup

```sql
DELETE FROM brokerdb.trade_data WHERE pdl_client_code = 'test';
```

---

## Test 2 — `holdings-preprocess-job`

`holdings-preprocess-job` does **not** run `fn_process_holdings`, so there is no ACEX issue.
Insert with flags pre-set and run the job directly.

### Step 1 — Insert test holding

```sql
INSERT INTO brokerdb.holding_data (
    status,
    security_type,
    security_name,    -- 'put %' → options matcher picks this up
    symbol,
    currency_code,
    description,
    file_name,
    pdl_client_code,
    source,
    as_of_date,
    processed,
    is_future,        -- pre-set: futures matcher picks this up
    is_option         -- pre-set: options matcher also picks this up → race condition
) VALUES (
    'PENDING',
    'Futures',
    'put DAX (EUR)',
    'DAX',
    'EUR',
    'DAX (EUR)',
    'TEST_TESTBROKER',
    'test',
    'Direct Feed',
    NOW(),
    'NO',
    'Yes',
    'Yes'
);
```

### Step 2 — Note the holding_number

```sql
SELECT holding_number FROM brokerdb.holding_data
WHERE pdl_client_code = 'test'
ORDER BY holding_number DESC
LIMIT 1;
```

### Step 3 — Run the job

```bash
npm run dev:task holdings-preprocess-job
```

### Step 4 — Verify

```sql
SELECT holding_number, status, security_id, process_outcome, is_future, is_option
FROM brokerdb.holding_data
WHERE holding_number = <holding_number from Step 2>;
```

| Scenario    | `security_id` | `process_outcome` |
|-------------|---------------|-------------------|
| Before fix  | _(empty)_     | `Fail: Could Not Find Matching Security ID` |
| After fix   | `DAX`         | `Success: Found single futures security in FactSet by security_name, currency_code` |

### Cleanup

```sql
DELETE FROM brokerdb.holding_data WHERE pdl_client_code = 'test';
```

---

## Note

The race condition is timing-dependent — futures must win before options for the bug to manifest.
Re-insert and re-run a few times if the result is not conclusive on the first attempt.
