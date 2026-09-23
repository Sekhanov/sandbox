# How trades are processed (preprocess → process)

How a trade goes from `brokerdb.trade_data` (central DB) to the client's `bk_txn` (client DB), shown through the real SQL.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.
Related docs: `README.md` (index, glossary), `trade-alerts.md`, `exceptions.md`, `security-master.md`, `client-config.md`, `central-db-schema.md`, `client-db-schema.md`.

```
brokerdb.trade_data ──► PREPROCESS (full-preprocess-job) ──► PROCESS (trade-process-job) ──► client DB bk_txn
status = 'PENDING'      1A clean, set status   (SQL)         compliance rules per trade
processed = 'NO'        1B match security      (TS + SQL)    processed = 'YES'
                        1C exceptions          (SQL)
```

Two columns tell where a trade is:
- `status`: what the row is. `PENDING` → `TRADE` (matched), or `RNR | …`, `ACEX`, `INACTIVE_ACCOUNT`, `DUP`.
- `processed`: are we done. `'NO'` → `'YES'`. Only step 2 sets `'YES'`, except for duplicates.

---

## 1. Where trades come from (before this service)

```
broker ──SFTP──► Electra ──► S3 ──► loader task ──► brokerdb.fileuploadtracker (one row per file)
                                    tasks/loadTxnAndHoldings  └► brokerdb.trade_data (one row per trade)
```

- A **broker file** is a daily CSV of trades (`<yyyymmdd>_<brokerId>_..._TRN`) or holdings (`..._HLD`).
- The loader `compliance-rules-engine/tasks/loadTxnAndHoldings` is a separate app in the same git repo. It inserts rows with:
  - `status = 'PENDING'`, `processed = 'NO'`
  - `source = 'Direct Feed'`
  - `file_name` = the file name
- Its last change was in Sep 2024. Whether production still uses it is unknown.
- Other sources (`trade_data.source`): `Plaid`, `Manual Upload`.
- Rows with source `NULL` and `security_type = 'ACT_RECORD'` are account-status placeholders, not trades.

---

## 2. Jobs

| Job | Code | Runs |
|---|---|---|
| `full-preprocess-job` | `tasks/tradeProcess/fullPreprocessController.ts` | Everything in sections 3–5, for trades and holdings |
| `trade-preprocess-job` | `tasks/tradeProcess/tradePreprocessController.ts` | Only sections 3 and 4, for trades |
| `trade-process-job` | `tasks/tradeProcess/tradeProcessController.ts` | Section 6 |

Order inside `full-preprocess-job`:
1. `fn_process_trades()` (3) and `fn_process_holdings()`
2. Security matching for trades and holdings (4)
3. `fn_exception_mgmnt_auto_updates()`: fixes known broker quirks on failed rows
4. `fn_exception_mgmnt_refresh()`, only if `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE=true`
5. Security matching again, for the fixed rows
6. `ExceptionStatusSyncService`, only if `RUN_EXCEPTION_STATUS_SYNC=true`
7. `fn_exception_mgmnt_new_exceptions()` (5)

The schedule is not in this repo.

---

## 3. Preprocess 1A: `brokerdb.fn_process_trades()`

File: `plpgsql/post-migrations/brokerdb.fn_process_trades.sql`. About 150 `UPDATE`s over **all clients at once**. The key statements, in order:

```sql
-- a) Defaults and duplicates
UPDATE brokerdb.trade_data SET status = 'PENDING' WHERE status IS NULL OR trim(status) = '';

-- Plaid duplicates. The ONLY place preprocess sets processed = 'YES'.
UPDATE brokerdb.trade_data SET status = 'DUP', processed = 'YES'
  FROM refdata.plaid_dupe
 WHERE trade_data.transaction_id = plaid_dupe.transactionid
   AND (status != 'DUP' OR processed != 'NO');

-- b) Cleanup: text 'NULL' -> real NULL, transaction_type from bank_tran_code,
--    hardcoded client code fixes ('NEA' -> 'NEWE', 'SNDS' -> 'SAND', ...)
UPDATE brokerdb.trade_data SET transaction_type = 'Buy'
 WHERE (transaction_type IS NULL OR transaction_type = '')
   AND bank_tran_code IN ('BUYO','BUYC','BUY','BUYTOCLOSE','BUYTOOPEN','SHORTSELL','BUYTOCOVER');

-- c) The account decides the client. Old value is saved to client_code_history first.
UPDATE brokerdb.trade_data SET pdl_client_code = client_code
  FROM brokerdb.account_data
 WHERE pdl_account_code = account_id AND pdl_client_code != client_code;

-- d) Is the account known and active?
-- ACEX row whose account now exists -> back to PENDING
UPDATE brokerdb.trade_data t SET status = 'PENDING'
 WHERE t.status = 'ACEX'
   AND t.pdl_account_code IS NOT NULL
   AND EXISTS (SELECT 1 FROM brokerdb.account_data a WHERE a.account_id = t.pdl_account_code);

-- Unknown account -> ACEX. Applies to ANY unprocessed row, whatever its status.
UPDATE brokerdb.trade_data t SET status = 'ACEX'
 WHERE NOT EXISTS (SELECT 1 FROM brokerdb.account_data a WHERE a.account_id = t.pdl_account_code)
   AND t.status != 'ACEX'
   AND t.processed = 'NO';

-- Inactive account or user -> INACTIVE_ACCOUNT. Never set back by this function.
UPDATE brokerdb.trade_data SET status = 'INACTIVE_ACCOUNT'
  FROM brokerdb.account_data
 WHERE trade_data.pdl_account_code = account_id
   AND processed = 'NO' AND status = 'PENDING'
   AND (account_status = 'Inactive' OR user_status = 'Inactive');

-- e) Security kind flags. They decide which matcher in section 4 takes the row.
UPDATE brokerdb.trade_data SET is_option = 'Yes'
 WHERE status = 'PENDING'
   AND (lower(security_type) IN ('option eligible','opt','option','options','opp','op')
        OR lower(security_name) LIKE 'put %' OR lower(security_name) LIKE 'call %' /* ... */)
   AND security_type != 'DEBT' AND (is_option IS NULL OR is_option = '');

UPDATE brokerdb.trade_data SET is_future = 'Yes', security_type = 'Futures'
 WHERE status = 'PENDING' AND security_type != 'DEBT' AND lower(security_type) IN ('futures','future');

UPDATE brokerdb.trade_data SET security_type = 'other'  WHERE status = 'PENDING' AND (security_type IS NULL OR security_type = '');
UPDATE brokerdb.trade_data SET security_type = 'CRYPTO' WHERE status = 'PENDING' AND lower(security_type) IN ('crypto','cryptocurrency');
UPDATE brokerdb.trade_data SET security_type = 'FX'     WHERE status = 'PENDING' AND lower(security_type) IN ('forex','fx','fxcfd');
-- ... plus many broker-specific symbol / security_name fixes

-- f) Not a real trade -> 'RNR | <reason>', security_id 'RNR_<reason>'.
-- By the reference table: one such statement per column
-- (security_type, bank_code, description, security_name, cusip, symbol, transaction_type, plaid_sub_type).
-- To add a new kind of non-trade, add a row to trade_process_reference. No code change.
UPDATE brokerdb.trade_data
   SET status      = trade_process_reference.status,                                       -- e.g. 'RNR | DIVINTCAP'
       security_id = concat('RNR_', split_part(trade_process_reference.status, ' | ', 2))  -- e.g. 'RNR_DIVINTCAP'
  FROM brokerdb.trade_process_reference
 WHERE security_type = value AND value_type = 'security_type'
   AND trade_data.status = 'PENDING';

-- And by hardcoded patterns (dividends, fees, transfers, DRIP, cusip 'XXXXXXXXX', ...)
UPDATE brokerdb.trade_data SET status = 'RNR | MISC', security_id = 'RNR_MISC'
 WHERE description LIKE 'Advisory Fee For %' AND trade_data.status = 'PENDING';

-- g) Unknown status guard (last statement). Only a note on the row:
--    the status isn't PENDING, so it never becomes an exception (section 5).
UPDATE brokerdb.trade_data
   SET process_outcome = 'FAIL: Unrecognized status'
 WHERE processed = 'NO'
   AND process_outcome IS DISTINCT FROM 'FAIL: Unrecognized status'
   AND upper(trim(status)) NOT IN ('PENDING','DUP','ACEX','INACTIVE_ACCOUNT','TRADE','INACTIVE_CLIENT')
   AND upper(trim(status)) NOT LIKE 'RNR | %';
```

---

## 4. Preprocess 1B: match each trade to a security

Code: `tasks/tradeProcess/services/tradePreprocessService.ts`, `runSecurityMatching()`.
- Five matchers run in parallel. Each one selects its own `PENDING` rows.
- Rows that describe the same security are grouped.
- The groups are sent to the security master (`securityLookupMatch` in `@libs/sma`), in batches of `CHUNK_SIZE` (default 1000).

```sql
-- EQUITIES: everything that is not an option, future, crypto or FX
SELECT trade_id, isin, cusip, sedol, TRIM(symbol) AS symbol, security_name, currency_code
FROM brokerdb.trade_data
WHERE (is_option IS NULL OR LOWER(is_option) != 'yes')
  AND (is_future IS NULL OR LOWER(is_future) != 'yes')
  AND (LOWER(security_type) NOT IN ('crypto', 'fx'))
  AND LOWER(status) = 'pending'
ORDER BY pdl_client_code, trade_id;

-- The other matchers differ only in the WHERE (and the columns they send to SMA):
--   FUTURES  WHERE LOWER(is_future) = 'yes'       AND LOWER(status) = 'pending'
--   OPTIONS  WHERE LOWER(is_option) = 'yes'       AND LOWER(status) = 'pending'
--   FX       WHERE LOWER(security_type) = 'fx'     AND LOWER(status) = 'pending'
--   CRYPTO   WHERE LOWER(security_type) = 'crypto' AND LOWER(status) = 'pending'
```

The SMA answer is written back. Up to 100 of these blocks are wrapped in one `DO $$ BEGIN … END $$`:

```sql
-- Found: the trade is ready for step 2.
-- This is the only automatic PENDING -> TRADE step (the other is a manual exception resolution).
BEGIN
  UPDATE brokerdb.trade_data
  SET security_id = '<security_id>', process_outcome = '<SMA match status>', status = 'TRADE'
  WHERE LOWER(status) = 'pending' AND trade_id IN (<trade ids of this security>);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Update failed for trades: <ids>';   -- the error is swallowed; rows stay PENDING
END;

-- Not found: stays PENDING with a 'Fail:' outcome, so it becomes an exception (section 5)
BEGIN
  UPDATE brokerdb.trade_data
  SET security_id = '', process_outcome = 'Fail: Could Not Find Matching Security ID'
  WHERE LOWER(status) = 'pending' AND trade_id IN (<trade ids>);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Update failed for trades: <ids>';
END;

-- Crypto rows with no usable symbol never go to SMA:
UPDATE brokerdb.trade_data
SET security_id = '', process_outcome = 'Fail: Correct Symbol could not be extracted. Skipping this row'
WHERE LOWER(status) = 'pending' AND trade_id IN (<ids>);
```

If a whole matcher crashes, Slack gets `TRADE PROCESS V2 | <matcher>`, and its rows wait for the next run.

---

## 5. Preprocess 1C: exceptions

Full lifecycle: `exceptions.md`.
- Exceptions live in the **central** DB tables `public.bk_txn` / `bk_txn_extra`. Same names as the client DB tables, different database.
- They are created by `plpgsql/post-migrations/brokerdb.fn_exception_mgmnt_new_exceptions.sql`:

```sql
-- One exception header per failed trade that has none yet
INSERT INTO bk_txn (transaction_id, trade_id, account_number, price, quantity, amount, ... )
SELECT concat('XJ69', trade_id),             -- exception id
       trade_id,
       'xxxxxxx',                            -- account number masked
       CASE WHEN price    > 0 THEN 1 ELSE 0 END,   -- price, quantity, amount masked to 0/1
       CASE WHEN quantity > 0 THEN 1 ELSE 0 END,
       CASE WHEN amount   > 0 THEN 1 ELSE 0 END,
       ...
FROM brokerdb.trade_data
WHERE trade_data.status = 'PENDING'
  AND processed = 'NO'
  AND trade_id NOT IN (SELECT trade_id FROM bk_txn)   -- no exception yet
  AND process_outcome ILIKE 'fail:%';                 -- matching failed (section 4)

-- Plus 3 bk_txn_extra rows per exception (same WHERE):
--   PROCESS_OUTCOME = <fail reason>, STATUS = 'New', EXCEPTION_TYPE = 'TRADE'
```

When ops resolves an exception through the resolve API (`services/ExceptionResolvingService.ts`), the trade changes. The code does this in TypeScript; it is shown here as the equivalent SQL:

```sql
-- "Matched to existing security": the trade goes to step 2
UPDATE brokerdb.trade_data SET status = 'TRADE', security_id = '<chosen>',
       process_outcome = 'Resolved Exception: Matched to Existing Security' WHERE trade_id = <id>;

-- "Not a trade"
UPDATE brokerdb.trade_data SET status = '<RNR type>', security_id = 'RNR_…',
       process_outcome = 'Resolved Exception: Not a Trade' WHERE trade_id = <id>;
```

---

## 6. Process: compliance rules and load to the client DB

Job: `trade-process-job`. It handles one client at a time.
- Clients: this cloud and stage (and region, on Azure) with `tasks_config.tradeProcess.enabled = true`.

### 6.1 Fetch the client's trades

`FETCH_TRADE_RECORDS` in `tasks/tradeProcess/queries.ts`, filled in by `tasks/tradeProcess/services/tradeProcessService.ts`:

```sql
SELECT broker_code, account_number, price, quantity, amount, ...,
       CASE WHEN is_option = 'Yes' THEN 'Option'
            WHEN is_future = 'Yes' THEN 'Future'
            ELSE security_type END AS security_type,
       ..., pdl_client_code, trade_id AS txn_id, status, security_id,
       'Pending Match' AS match_status, is_option, is_future, transaction_id
FROM brokerdb.trade_data                    -- {{TRADE_DATA_TABLE}}
WHERE processed = 'NO'
  AND {{STATUS_REPLACE}}                    -- <-- tasks_config.tradeProcess.tradeStatus, pasted as SQL:
                                            --     most clients: status = 'TRADE'
                                            --     a few:        (status = 'TRADE' OR status like '%RNR%')
  AND lower(pdl_client_code) = lower($1)    -- this client
  AND DATE(transaction_date) >= $2          -- <-- tasks_config.tradeProcess.transactionDate
  {{SAND_SOURCE_FILTER}}                    -- <-- AND source = 'Manual Upload'  when manualUploadOnly = true
ORDER BY pdl_client_code, trade_id, transaction_date;

-- Never fetched, so they stay processed = 'NO' forever:
--   RNR rows, when tradeStatus is only status = 'TRADE'
--   rows dated before transactionDate, or with transaction_date NULL
```

Hand-off:
- **AWS:** the SQS queue is purged, then one message is sent per trade. The Lambda `serverless/public/functions/tradeProcessV2/handler.ts` processes them, with no retry.
- **Azure:** trades are processed in-process, one by one.
- Both call `tradeProcess()` in `serverless/public/functions/tradeProcessV2/tradeProcess.ts`.

### 6.2 Compliance rules (TypeScript, per trade)

The rules run in this order. A rule can finish the trade early:
1. `cookData`: loads security details and checks the account exists in the client `account_view`. **Throws** if either is missing.
2. `managedAccount`: managed accounts can skip the rules.
3. `nonTradeCheck`: status is not `TRADE` (RNR) → preclearance not needed.
4. `usGovCheck`: US government security → preclearance not needed.
5. `holdingPeriodPreCheck`
6. `preclearNotNeeded`: by security type, region, universe or option close.
7. `restrictionCheck`: restricted list.
8. `sicCheck`: industry rules.
9. `preclearMatch`: did the employee get preclearance for this trade?

The results:
- `match_status`: what the client sees.
- `trade_process_outcome`: an audit trail such as `|COOK_DATA:true|…`.

### 6.3 Save (`loadToTarget`)

One transaction on the client DB and one on the central DB, committed together.

```sql
-- Client DB: deliver the trade
INSERT INTO public.bk_txn (...) VALUES (...);
INSERT INTO public.bk_txn_extra (...) VALUES (...);
-- Skipped when:
--   the account is managed and LOAD_MANAGED_ACCOUNTS is off
--   the same transaction_id is already in the client's bk_txn
--   EXCLUDE_RULE is on and the account is inactive or cannot hold covered securities

-- Central DB: always mark the trade done (updateElectraDb in tradeProcessV2/service.ts;
-- Sequelize TradeData.update, shown as SQL)
UPDATE brokerdb.trade_data
   SET processed      = 'YES',
       processed_date = now(),
       rule_status    = <trade_process_outcome>,
       transaction_id = <id>,
       loaded         = <true if inserted into the client DB, else false>
       -- + the ZERO_VALUES columns when SET_VALUES_ZERO is on
 WHERE trade_id = <txn_id>;
```

- `processed = 'YES'` with `loaded = true`: the trade was delivered.
- `processed = 'YES'` with `loaded = false`: the trade was finished on purpose without delivery.

---

## 7. Why a trade stays `processed = 'NO'` forever

| Reason | Stops at |
|---|---|
| `ACEX` (unknown account), `INACTIVE_ACCOUNT` | 3 |
| No security found, exception not resolved | 4, 5 |
| Unknown status (only flagged `FAIL: Unrecognized status`) | 3 |
| RNR, and `tradeStatus` is only `TRADE` | 6.1 |
| `transaction_date` before `transactionDate`, or `NULL` | 6.1 |
| A rule throws (e.g. account missing in the client DB). Slack: `TRADE PROCESS V2 \| <client> \| <trade>`. Fails again every run. | 6.2 |
| Client has `tradeProcess.enabled = false` | 6 |

The **Stuck** alert (COR-11552) should cover all of these. Today it uses the 6.1 filter plus an age limit, so it catches only the last two rows.

---

## 8. Settings

| Setting | Where | Used in |
|---|---|---|
| `tasks_config.tradeProcess.tradeStatus`, `.transactionDate`, `.manualUploadOnly`, `.enabled` | client config (`rulesenginedb.clients_v2`) | 6, 6.1 |
| `trade_configs_v2.parameters` (`EXCLUDE_RULE`, `LOAD_MANAGED_ACCOUNTS`, `SET_VALUES_ZERO`, …) | client's active trade config | 6.2, 6.3 |
| `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE`, `RUN_EXCEPTION_STATUS_SYNC` | env | 2 |
| `CHUNK_SIZE` (default 1000) | env | 4 |
| `TRADE_PROCESS_SQS_URL` | env (AWS) | 6.1 |
