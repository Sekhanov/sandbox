# How holdings are processed (preprocess → load → status update)

**In one sentence:** this repo takes account position snapshots ("holdings") stored in the central DB table `brokerdb.holding_data`, cleans them, matches each one to a security, copies them into the client DB table `public.bk_holdings`, and then marks each copied holding `Active` or `Inactive`.

This is the holdings counterpart of `trade-process.md`. Unlike trades, holdings get **no compliance rules**.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `trade-process.md`, `exceptions.md`, `central-db-schema.md`, `client-db-schema.md`, `client-config.md`, `security-master.md`, `accounts-and-feedback.md`, `runtime-overview.md`.

---

## 1. Words used in this document

| Term | Meaning in this repo |
|---|---|
| **Holding** | One position (security + quantity) in one employee account on one date. **One row in `brokerdb.holding_data`**, id `holding_number`. |
| **Snapshot** | All holdings of one account with the same `as_of_date`. A new snapshot normally arrives once a month. |
| **`as_of_date`** | The date the snapshot describes. For Direct Feed it is forced to a month end (section 2). |
| **Automated source** | `Plaid`, `Direct Feed` or `eConversion` (`AUTOMATED_HOLDINGS_SOURCES` in `services/holdings/holdingsStatusUpdateService.ts`). Only these are loaded and compared. |
| **Load** | Copying a central row into the client DB `public.bk_holdings` (section 5). |
| **Post-process** | Setting `STATUS` = `Active` / `Inactive` in `bk_holdings_extra` by comparing snapshots (section 6). |
| Client, central DB, client DB, exception, RNR, ACEX | Same meaning as in `README.md`, glossary. |

---

## 2. Where holdings come from (before the jobs run)

When the jobs start, holdings are already rows in `brokerdb.holding_data`. `status` defaults to `'PENDING'` (migration `20_add_default_status_value.ts`); loaders also set `processed = 'NO'`.

| `source` | Where it comes from |
|---|---|
| `Direct Feed` | Broker holdings file. File names end in `HLD` (trades end in `TRN`). The sibling task `compliance-rules-engine/tasks/loadTxnAndHoldings` (outside `rules-engine-3.0`) reads such files from S3 and inserts them with `source = 'Direct Feed'`, `status = 'PENDING'`, `processed = 'NO'`. Whether it is the only production loader is unknown. Older rows may have `source = 'ELECTRA'`. Preprocess renames them. |
| `Plaid` | Plaid API, loaded outside this repo. Variants `PLAID` / `plaid` are renamed by preprocess. |
| `eConversion` | Loaded outside this repo (seen only in seed data). |
| `Manual Upload` | Exists in seed data. **This repo never loads these rows into the client DB** (not in the automated sources). |
| *(any)* | The holdings API (section 7, LOCAL/DEV/TST only). |

### Trigger: month-end dates for Direct Feed

`BEFORE INSERT` trigger `trg_set_as_of_created_date` (migration `14_trg_set_as_of_created_date.ts`) runs `brokerdb.set_as_of_and_created_date()` (`plpgsql/pre-migrations/brokerdb.set_as_of_and_created_date.sql`). It only fires for `source = 'Direct Feed'` and works from the row's `create_date` (the insert date):

```sql
IF NEW.source = 'Direct Feed' THEN
    IF insert_date >= tenth_of_month THEN      -- 10th..31st
        NEW.as_of_date := last_of_month;       --   → last day of this month
        NEW.create_date := last_of_month;
    ELSE                                       -- 1st..9th
        NEW.as_of_date := last_of_previous_month;   -- → last day of previous month
        NEW.create_date := last_of_previous_month;
    END IF;
END IF;
```
Example: a file loaded on 2026-10-05 → `as_of_date = 2026-09-30`. Loaded on 2026-10-13 → `2026-10-31`.
Any `as_of_date` sent by the loader is overwritten. Rows inserted as `source = 'ELECTRA'` don't fire the rule, because the rename to `Direct Feed` happens later in preprocess (inferred).

---

## 3. The big picture

```
 outside this repo              │  THIS REPO
                                │
 HLD file / Plaid / eConversion │   brokerdb.holding_data (central DB)                         client DB
 ─────────────► new row         │   ┌───────────────────────────────────────────────────┐
  trigger: month-end as_of_date │   │ STEP 1  PREPROCESS                                │
  status    = 'PENDING'         │   │  1A clean data, set status   fn_process_holdings  │
  processed = 'NO'              │   │  1B match to a security      (TS + SQL)           │
                                │   │  1C copy security from history (flag)             │
                                │   │  1D exception resolutions / sync                  │
                                │   └───────────────────────┬───────────────────────────┘
                                │                           │ status = 'TRADE'
                                │   ┌───────────────────────▼───────────────────────────┐   ┌─────────────┐
                                │   │ STEP 2  LOAD  (holdings-process-job)              │──►│ bk_holdings │
                                │   │  processed = 'YES', loaded = true                 │   └──────┬──────┘
                                │   └───────────────────────────────────────────────────┘          │
                                │   ┌───────────────────────────────────────────────────┐   ┌──────▼────────────┐
                                │   │ STEP 3  STATUS UPDATE  (if postProcess)           │──►│ bk_holdings_extra │
                                │   │  compare latest snapshot with older active ones   │   │ STATUS Active /   │
                                │   └───────────────────────────────────────────────────┘   │ Inactive          │
                                                                                            └───────────────────┘
```

Note: a matched holding gets `status = 'TRADE'` (the same value as trades), not a holding-specific value.

### Example: the life of one holding
Direct Feed file loaded 2026-10-05 for account `ACC1` of client `SAND`. It holds 100 shares of `AAPL`. The September snapshot had `AAPL` and `MSFT`.

| Moment | `status` | `processed` | `security_id` | `process_outcome` | Client DB |
|---|---|---|---|---|---|
| Row inserted, trigger runs | `PENDING` | `NO` | – | – | – (`as_of_date = 2026-09-30`) |
| 1A: account known and active, flags set | `PENDING` | `NO` | – | – | – |
| 1B: security matched | **`TRADE`** | `NO` | `ABC123` | match status | – |
| 2: load | `TRADE` | **`YES`** | `ABC123` | match status | new `bk_holdings` row, `loaded = true`, no `STATUS` yet |
| 3: status update | unchanged | unchanged | | | new row `STATUS = Active`. The September `AAPL` row → `Inactive` ("kept", replaced). The September `MSFT` row → `Inactive` if a sell of `MSFT` was found, otherwise stays `Active`. |

If 1B **can't** find the security instead:
| Moment | `status` | `processed` | `process_outcome` |
|---|---|---|---|
| 1B: no match | `PENDING` | `NO` | `Fail: Could Not Find Matching Security ID` |
| 1C: same security found in recent history (if enabled) | **`TRADE`** (or `RNR \| …`) | `NO` | `Automated exception resolution based on historical data` |
| otherwise | `PENDING` | `NO` | unchanged. **No exception is created automatically** (section 4.4). |

---

## 4. Step 1: Preprocess

**Jobs** (registered in `tasks/index.ts`, schedule not in this repo):

| Job | Code | Holdings steps |
|---|---|---|
| `full-preprocess-job` | `tasks/tradeProcess/fullPreprocessController.ts` | 1A, 1B, exception resolution, 1B again, exception sync |
| `holdings-preprocess-job` | `tasks/holdingsPreprocess/holdingsPreprocessController.ts` | **only** 1B and 1C. It does **not** call `fn_process_holdings()`. |
| Holdings API (POST) | `services/holdings/HoldingsCreateService.ts` | 1A, 1B, 1C, then the load (section 7) |

**Order inside `full-preprocess-job`** (full list in `trade-process.md`, section 2):

| # | What | Holdings part |
|---|---|---|
| 2 | `SELECT brokerdb.fn_process_holdings()` | 1A |
| 4 | `HoldingsPreprocessService.runSecurityMatching()` | 1B |
| 5 | `fn_exception_mgmnt_auto_updates()` | none (only `trade_data`) |
| 6 | `fn_exception_mgmnt_refresh()` *(if `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE=true`)* | applies ops resolutions with `xtype = 'HOLDING'` (4.4) |
| 8 | `runSecurityMatching()` again | 1B |
| 9 | `ExceptionStatusSyncService` *(if `RUN_EXCEPTION_STATUS_SYNC=true`)* | closes / fails holding exceptions (4.4) |
| 10 | `fn_exception_mgmnt_new_exceptions()` | none: it only creates **trade** exceptions |

`full-preprocess-job` does **not** run 1C (historical resolution). Only `holdings-preprocess-job` and the API do.

### 4.1 (1A) `brokerdb.fn_process_holdings()`: clean data and set `status`

File: `plpgsql/post-migrations/brokerdb.fn_process_holdings.sql`. Like `fn_process_trades`, it is a list of `UPDATE brokerdb.holding_data …` statements over **all clients at once**. In order:

**a) Defaults and normalisation**
```sql
UPDATE holding_data SET source = 'Direct Feed' WHERE source = 'ELECTRA';
UPDATE holding_data SET source = 'Plaid' WHERE source IN ('PLAID','plaid');
UPDATE holding_data SET status = 'PENDING' WHERE status IS NULL OR trim(status) = '';
UPDATE holding_data SET processed = 'YES', status = 'RNR | DEMO'
 WHERE pdl_client_code = 'DEMO' AND status = 'PENDING';
UPDATE holding_data SET create_date = as_of_date WHERE create_date != as_of_date;   -- all rows
```

**b) What kind of security?** (`status = 'PENDING'`, plus some Plaid rules). Sets the flags that pick the matcher in 1B:
- `is_option = 'Yes'`: `security_type` in (`option eligible`, `opt`, `option`, `options`, `opp`, `op`), or a name like `put …` / `… call` / `call/…`; and for Plaid: description `BUYOPT …` / `SELLOPT …`, `security_type = 'derivative'`, or a long symbol with a name ending in ` Call` / ` Put`. Never for `security_type = 'DEBT'`.
- `is_future = 'Yes'`, `security_type = 'Futures'` (`futures`, `future`) or `'Futures Option'` (`fop`, `fsopt`, `fsop`, `fsfop`)
- `security_type = 'CRYPTO'` (`crypto`, `cryptocurrency`), `'FX'` (`forex`, `fx`, `fxcfd`), `'Other'` when NULL

**c) Account owner and client code from `brokerdb.account_data`**
```sql
UPDATE holding_data SET account_owner_id = owner_id
  FROM brokerdb.account_data WHERE pdl_account_code = account_id AND account_owner_id IS NULL;
UPDATE holding_data SET pdl_client_code = client_code
  FROM brokerdb.account_data WHERE pdl_account_code = account_id
   AND pdl_client_code != client_code AND status = 'PENDING';
```
Unlike trades, there is no `client_code_history` audit row.

**d) Hardcoded client rules**
```sql
UPDATE holding_data SET price = 0, quantity = 0, amount = 0 WHERE pdl_client_code IN ('MRCM','mrcm','WVR','wvr','crow');
UPDATE holding_data SET price = 0, amount = 0               WHERE pdl_client_code IN ('MOSS','moss');
UPDATE holding_data SET status = 'INACTIVE_CLIENT'
 WHERE pdl_client_code IN ('WACAP','PRSC','BRDWL') AND status != 'INACTIVE_CLIENT';   -- any status, any processed
```

**e) Inactive user or account → done, not loaded.** Unlike trades, these rows are closed (`processed = 'YES'`, `loaded` stays `false`):
```sql
UPDATE holding_data SET processed = 'YES', status = 'INACTIVE_USER',
       process_outcome = 'Inactive User - Processing Skipped'
  FROM brokerdb.account_data WHERE pdl_account_code = account_id AND processed = 'NO' AND user_status = 'Inactive';
UPDATE holding_data SET processed = 'YES', status = 'INACTIVE_ACCOUNT',
       process_outcome = 'Inactive Account - Processing Skipped'
  FROM brokerdb.account_data WHERE pdl_account_code = account_id AND processed = 'NO' AND account_status = 'Inactive';
```
These apply to every unprocessed row, whatever its status, including already matched `TRADE` rows.

**f) Unknown account → `ACEX`**
```sql
-- account has appeared since last run → back to PENDING
UPDATE holding_data t SET status = 'PENDING'
 WHERE t.status = 'ACEX' AND t.pdl_account_code IS NOT NULL
   AND EXISTS (SELECT 1 FROM brokerdb.account_data a WHERE a.account_id = t.pdl_account_code);
-- account unknown → ACEX (no processed filter: also hits processed rows)
UPDATE holding_data t SET status = 'ACEX'
 WHERE NOT EXISTS (SELECT 1 FROM brokerdb.account_data a WHERE a.account_id = t.pdl_account_code)
   AND t.status != 'ACEX';
UPDATE holding_data SET status = 'ACEX' WHERE pdl_account_code IS NULL AND status != 'ACEX';
```

**g) Plaid account code backfill.** A temp table `mmh` maps `plaid_account_id` → `pdl_account_code` from other Plaid rows. It fills rows that have no `pdl_account_code`. This runs **after** f), so those rows are `ACEX` for one run and go back to `PENDING` on the next run (inferred).

**h) Junk and not-a-holding (RNR)**
```sql
-- row with no security type, name, identifier, symbol or description → DELETED
DELETE FROM holding_data WHERE (security_type IS NULL OR security_type = '') AND ... AND status = 'PENDING' AND processed = 'NO';
-- Plaid row with no name, description, cusip or isin
UPDATE holding_data SET status = 'RNR | MISC', processed = 'YES'
 WHERE source = 'Plaid' AND security_name IS NULL AND description IS NULL AND cusip IS NULL AND isin IS NULL AND status = 'PENDING';
-- reference table, one statement per value_type
UPDATE holding_data SET status = r.status, security_id = concat('RNR_', split_part(r.status, ' | ', 2))
  FROM brokerdb.trade_process_reference r
 WHERE holding_data.security_type = r.value AND r.value_type = 'security_type' AND holding_data.status = 'PENDING';
```
The reference statements use the same table as trades, with these column pairs: `security_type`↔`security_type`, `description`↔`description`, `security_name`↔`security_name`, `identifier`↔`cusip`, `symbol`↔`symbol`, `security_type`↔`plaid_sub_type`. Holdings RNR rows keep `processed = 'NO'` and are never loaded (section 5.2). There are no hardcoded pattern rules (unlike trades), and no Plaid duplicate (`DUP`) handling.

**i) Unknown status guard** (last statement). Same as trades: `process_outcome = 'FAIL: Unrecognized status'` for unprocessed rows whose status is not `PENDING`, `DUP`, `ACEX`, `INACTIVE_ACCOUNT`, `TRADE`, `INACTIVE_CLIENT` or `RNR | …`.

### 4.2 (1B) Match each holding to a security

Code: `tasks/holdingsPreprocess/services/holdingsPreprocessService.ts` → `runSecurityMatching()`. The same design as trades (`trade-process.md` 1B). Five matchers run in parallel. Each reads rows with `LOWER(status) = 'pending' AND LOWER(processed) = 'no'`:

| Matcher | Extra filter | Sent to security master (`universe_type` + fields) |
|---|---|---|
| EQUITIES | not option, not future, `security_type` not `crypto`/`fx` | `EQ`: isin, cusip, sedol, ticker (symbol), currency, identifier, name |
| OPTIONS | `is_option = 'yes'` | `OPTIONS`: ticker, name, currency, identifier, `broker_code` = `split_part(file_name,'_',2)` (or `PLAID` for Plaid rows) |
| FUTURES | `is_future = 'yes'` | `FUTURES`: broker code from file name, description, ticker, name, currency |
| FX | `security_type = 'fx'` | `FX`: ticker = row currency (default `USD`), currency = `USD`, name |
| CRYPTO | `security_type = 'crypto'` | `CRYPTO`: ticker (symbol), name |

Steps:
1. Split rows into chunks of `SECURITIES_CHUNK_SIZE` (env var `CHUNK_SIZE`, default 1000).
2. Group rows with an identical payload, so each security is looked up once (`securityLookupMatch` in `@libs/sma`).
3. Write back, up to 100 statements per `DO $$ … $$` block. Each statement has its own `EXCEPTION WHEN OTHERS THEN RAISE NOTICE`, so a failed update is silently skipped.

```sql
-- found
UPDATE brokerdb.holding_data SET security_id = '<id>', process_outcome = '<match status>', status = 'TRADE'
 WHERE LOWER(status) = 'pending' AND holding_number IN (...);
-- not found
UPDATE brokerdb.holding_data SET security_id = '', process_outcome = 'Fail: Could Not Find Matching Security ID'
 WHERE LOWER(status) = 'pending' AND holding_number IN (...);
```
Crypto rows without a usable symbol (empty or `NULL`) get `process_outcome = 'Fail: Correct Symbol could not be extracted. Skipping this row'` and are not sent.
If a whole matcher throws, a Slack/SNS alert `HOLDINGS PREPROCESS | <matcher>` is sent. Its rows wait for the next run.

### 4.3 (1C) Historical exception resolution

Code: `HoldingsPreprocessService.resolveHistoricalExceptions()` + `tasks/holdingsPreprocess/services/historicalExceptionResolutionQuery.ts`. It runs **only if env var `RUN_HISTORICAL_EXCEPTION_RESOLUTION=true`** (default `false`).

The idea: a security that was matched in an earlier snapshot will look the same this month, so its `security_id` can be copied. For each `PENDING` holding ("current"), it takes the newest earlier holding ("history") that matches:

```sql
-- current row
current.status = 'PENDING'
AND current.as_of_date > date_trunc('month', CURRENT_DATE) - INTERVAL '1 month'   -- recent snapshot only
-- history row
AND history.as_of_date >= current.as_of_date - INTERVAL '6 months'
AND (history.processed = 'YES' OR history.status LIKE 'RNR |%')
AND history.status NOT IN ('INACTIVE_ACCOUNT','INACTIVE_USER')
AND nullif(trim(history.security_id), '') IS NOT NULL
-- same security
AND current.currency_code = history.currency_code
AND current.security_type = history.security_type
AND current.security_name = history.security_name            -- non-empty
AND (   (current.source = 'Direct Feed' AND (current.identifier is empty OR = history.identifier))
     OR (current.source = 'Plaid' AND current.description = history.description
                                  AND current.plaid_security_id = history.plaid_security_id))
```
The newest match wins (`DISTINCT ON … ORDER BY history.as_of_date DESC`). The row is updated:
```sql
UPDATE brokerdb.holding_data SET status = <history.status>,          -- 'TRADE' or 'RNR | …'
       security_id = <history.security_id>,
       process_outcome = 'Automated exception resolution based on historical data'
```
- There is **no client or account filter**: history from any client can be used. Security ids are global (inferred).
- `eConversion` rows never match.
- A NULL `currency_code` never matches.
- `processed` of the current row is not checked.

### 4.4 Holding exceptions

- **Creation: no job creates holding exceptions.** `fn_exception_mgmnt_new_exceptions()` (step 10) reads only `trade_data`. `brokerdb.fn_exception_mgmnt_new_exceptions_holdings()` exists but nothing in the code calls it (it may be run by hand; unknown). If it runs, it creates `bk_txn` (`'XJ69' || holding_number`, `transaction_type = 'holding'`) and `bk_txn_extra` (`PROCESS_OUTCOME`, `STATUS = 'New'`, `EXCEPTION_TYPE = 'HOLDING'`) for rows where `status = 'PENDING'`, `processed = 'NO'`, `is_option IS NULL`, `is_future IS NULL`, and `process_outcome` is not null and not `'newsec'`. Options and futures are excluded.
- **Ops resolutions** (`fn_exception_mgmnt_refresh`, step 6), for rows still `PENDING` and `xtype = 'HOLDING'`:
  - `Matched to Factset Security` → `status = 'TRADE'`, `security_id = secid`, `process_outcome = '… via Exception Mgmnt'`
  - `Not a Trade` → `status = 'RNR | MISC'`, `security_id = 'RNR_MISC'`
  - The exception is marked `Resolved` once the holding is no longer `PENDING`.
  - A later statement (lines 170–175) references `trade_data.status` without `trade_data` in its `FROM`. In PostgreSQL this should fail at run time and abort the whole function (inferred, not tested).
- **Resolution API** (`serverless/private/functions/exceptionResolvingV1`, `services/ExceptionResolvingService.ts`): works for `exceptionType = 'HOLDING'` too. It rejects holdings with `processed != 'NO'`. `Matched to Factset Security` → `status = 'TRADE'` + global security id; `Not a Trade` → `status = 'RNR | <code>'`; `New Security` → creates the security in SMA, and the exception becomes `Awaiting Match`. Details: `exceptions.md`.
- **Sync** (`ExceptionStatusSyncService`, step 9): the same rules as trades. Exception `New`/`Reviewed`/`Awaiting Match` and the holding is `TRADE` → `Closed`. `Awaiting Match` and the holding is not `TRADE` → `Failed`.

### Where holdings stand after Step 1

| `status` | `processed` | What happens next |
|---|---|---|
| `TRADE` | `NO` | Step 2 loads it, if the source is automated and the client is enabled |
| `PENDING`, `process_outcome` starts with `Fail:` | `NO` | Waits: history (1C), manual exception, or the next matching run |
| `PENDING`, no outcome | `NO` | Tried again on the next run |
| `ACEX` | `NO` | Waits until the account appears in `account_data` |
| `RNR \| …` (reference table, history, ops) | `NO` | **Never loaded** |
| `RNR \| MISC` (Plaid, empty row), `RNR \| DEMO` | `YES` | Done |
| `INACTIVE_USER`, `INACTIVE_ACCOUNT` | `YES` | Done, `loaded = false` |
| `INACTIVE_CLIENT` | unchanged | Never loaded |
| *(deleted)* | – | Empty rows are removed |

---

## 5. Step 2: Load into the client DB

**Job:** `holdings-process-job` → `tasks/holdingsProcess/holdingsController.ts` (`initiateHoldingsTransfer`). Clients are handled one at a time.

### 5.1 Which clients
`clientConfigService.getClientsForHoldingsJob()` (`services/ClientConfigService.ts`): `environment = APP_ENV`, `stage = NODE_ENV`, `region = REGION`, and `tasks_config.holdingsProcess.enabled = true`.

For each client, `processClientHoldings()` (`services/holdings/holdingsService.ts`) uses `tasks_config.holdingsProcess`:

| Setting | Effect |
|---|---|
| `enabled` | Client is picked at all (5.1). Migrations `03` / `07` seeded `true` only on PROD and SAND. |
| `manualUploadOnly` | `true` → **nothing is loaded** (the fetch returns `[]`). Post-process still runs. `fn_migrate_config_to_azure` sets it to `true` on migrated clients. Note: for trades the same flag means "load only `Manual Upload` rows". |
| `postProcess` | `true` → run Step 3 after the load. Migration `07` set `true` for all clients. |
| `deactivationUser` | `modified_by` / `created_by` used when marking holdings `Inactive`. Default `'holding-process'` (`storage/models/ClientStorage.ts`). |

### 5.2 Which holdings (`tasks/holdingsProcess/queries.ts`, `getNonProcessedHoldingsQuery`)
```sql
SELECT * FROM brokerdb.holding_data
 WHERE processed = 'NO'
   AND status = 'TRADE'                                  -- fixed, no per-client status SQL
   AND lower(pdl_client_code) = lower(:pdl_client_code)
   AND source IN ('Plaid', 'Direct Feed', 'eConversion')
   [AND pdl_account_code IN (:accountIds)]               -- API only
 ORDER BY holding_number ASC;
```
Unlike trades, there is no date filter and no RNR option.

### 5.3 Mapping to `bk_holdings`
Rows without `pdl_account_code` or `account_owner_id` are **skipped**. They are counted as "Skipped (missing account or owner)" and stay `processed = 'NO'`. The others become one `bk_holdings` row each (model `storage/models/bkHoldings.ts`):

| `bk_holdings` column | Value |
|---|---|
| `holding_id` (PK) | new random id `<CLIENT>_<32 hex>` (`generateHashedCode` in `libs/helper.ts`) |
| `holding_number` | central `holding_number` (the link back to central) |
| `pdl_account_code`, `pdl_client_code`, `account_number`, `file_name`, `source` | copied |
| `security_id`, `security_type`, `security_name`, `identifier`, `symbol`, `currency_code`, `description` | copied |
| `price`, `quantity`, `amount` | copied |
| `as_of_date` | copied |
| `created_date` | central `as_of_date` |
| `modified_date` | `CURRENT_DATE` |
| `created_by`, `modified_by` | central `account_owner_id` |
| `owner` | `account_owner_id`, **Azure only** |

Not copied, because they are not model attributes: `cusip`, `isin`, `sedol`, `status`, `process_outcome`, `is_option`, `is_future`, Plaid ids, `broker_code`. No `bk_holdings_extra` row is written here, so the new holding has **no `STATUS`** until Step 3.

### 5.4 Chunks and marking as done
Rows are written in chunks of **200**. Each chunk uses two transactions, one on the client DB and one on the central DB:
```sql
-- client DB
INSERT INTO bk_holdings (...) VALUES (...), ...;               -- Sequelize bulkCreate
-- central DB
UPDATE brokerdb.holding_data
   SET processed = 'YES', processed_date = CURRENT_DATE, loaded = true
 WHERE holding_number IN (<chunk>);
-- commit client, then commit central
```
On an error, both transactions of that chunk are rolled back and the error is re-thrown. Earlier chunks stay committed. The whole client stops: Step 3 is skipped, and an alert `Holdings Transfer | <STAGE>` is sent. The job continues with the next client.
On success, a summary notification `Holdings Transfer | <STAGE>` is sent with these counts: received, inserted, skipped, and (if post-process ran) the status-update counts from section 6.

---

## 6. Step 3: Status update (`postProcess`)

Code: `services/holdings/holdingsStatusUpdateService.ts` (`updateHoldingsStatusesForClient`) + `storage/repositories/BkHoldingsRepository.ts`. Everything here reads and writes the **client DB**, except two central lookups (sell trades and option/future flags).

### 6.1 Which accounts and which date
`getAccountsWithMaxDate()`: one entry per `pdl_account_code` in `bk_holdings`, with `maxDate = MAX(as_of_date)::date`. It covers **all accounts with any holdings** (or only the given accounts, for the API), not only those loaded in this run. Accounts are processed one by one. Each account has its own client DB transaction. A failure is logged, counted as "Accounts failed", and the next account runs.

### 6.2 Three sets per account (automated sources only)
| Set | Filter on `bk_holdings` |
|---|---|
| **New snapshot** | `as_of_date::date = maxDate`, plus a flag saying whether it is already `Active` |
| **Old active** | `as_of_date::date < maxDate` and has an active `STATUS = 'Active'` |
| **Late arriving** | `as_of_date::date < maxDate` and has **no `STATUS` row at all** |

"Active" means this row exists:
```sql
EXISTS (SELECT 1 FROM bk_holdings_extra bhe JOIN bk_holdings_extra_types bhet USING (extra_type_id)
         WHERE bhe.holding_id = h.holding_id AND bhet.attribute_type = 'STATUS'
           AND bhe.attribute_value = 'Active' AND bhe.is_active = true)
```

### 6.3 Comparison (key = `security_id`)
| Group | Rule | New `STATUS` |
|---|---|---|
| New, security also in old active ("kept new") | not yet Active | **Active** |
| New, security not in old active ("acquired") | not yet Active | **Active** |
| Old active, security also in new ("kept old") | replaced by the new row | **Inactive** |
| Old active, security not in new ("removed"), and **sold out** | a central `trade_data` row exists for the same account, client and `security_id`, with `transaction_type = 'sell'` and `transaction_date` between the oldest removed `as_of_date` and `maxDate`, and the last sell date > this holding's `as_of_date` (any trade status) | **Inactive** |
| Removed, no such sell, option or future | central `holding_data.is_option` / `is_future = 'yes'` (looked up by `holding_number`) | **Inactive** |
| Removed, no such sell, regular security (also: empty `security_id` or no `as_of_date`) | position may still exist | **stays Active** (carried forward) |
| Late arriving | older than the latest snapshot | **Inactive** |

Result: the `Active` holdings of an account are the latest snapshot, plus older regular positions that disappeared without a recorded sell.

### 6.4 How `STATUS` is written (`replaceHoldingsStatus`)
Rows are never updated in place. The old `STATUS` row is deactivated and a new one inserted:
```sql
UPDATE bk_holdings_extra SET is_active = false, modified_date = now() AT TIME ZONE 'EST',
       modified_by = COALESCE(:modifiedBy, modified_by)
 WHERE holding_id IN (:ids) AND is_active = true
   AND extra_type_id = (SELECT extra_type_id FROM bk_holdings_extra_types WHERE attribute_type = 'STATUS' LIMIT 1);

INSERT INTO bk_holdings_extra (holding_id, extra_type_id, attribute_value, created_by, modified_by, is_active, ...)
SELECT h.holding_id, <STATUS id>, :value /* 'Active' | 'Inactive' */, COALESCE(:modifiedBy, h.created_by), ..., true
  FROM bk_holdings h WHERE h.holding_id IN (:ids);
```
- `Inactive` is written by `deactivationUser`.
- `Active` is written by the `created_by` of the first holding being activated (the account owner), or by `deactivationUser` if there is none.
- The run is idempotent: already-active new holdings are not re-activated. A second run finds the same latest snapshot.

---

## 7. Holdings API

| | AWS | Azure |
|---|---|---|
| Entry point | Lambda `serverless/public/functions/holdingProcessApi` (`POST` / `GET v1/holdings`) | Express `server/routes/holdingsRoute.ts` → `server/controllers/holdingsController.ts` (`/v1/holdings`) |

Both call the same services.

**Stages:** `HoldingsCreateService.createHoldings()` and `HoldingsQueryService.getHoldingsByAccount()` throw unless `NODE_ENV` is `LOCAL`, `DEV` or `TST`. Elsewhere the caller gets an unhandled error (500). The Swagger text (`server/swagger/holdingsSwagger.ts`) says "LOCAL and DEV" only.

**POST** body: a non-empty JSON array. Each item is validated alone (`createHoldingSchema` in `.../holdingProcessApi/schema.ts`):
- Required: `file_name`, `source`, `account_code`, `client_code`.
- Optional: `as_of_date`, `create_date`, security fields, `price` / `quantity` / `amount` (strings), `account_number`, Plaid ids, `permission_id`.
- `source` is any string. Only automated sources are loaded later.

What it does for the valid items:
1. Insert into `brokerdb.holding_data` with `status = 'PENDING'`, `processed = 'NO'`, `loaded = false`. The month-end trigger applies.
2. Run `fn_process_holdings()`, `runSecurityMatching()` and `resolveHistoricalExceptions()` (if its flag is on). These run **for all pending holdings of all clients**, not only the new ones.
3. For each client in the request, run `processClientHoldings()` (Steps 2 and 3) only for the accounts in the request, with the client's `tasks_config.holdingsProcess`. This applies even if `enabled = false`.
4. Return each item's central row after processing (`status`, `security_id`, `processed`, `loaded`, …). HTTP status: `201` all valid, `207` some valid, `400` none. A `debug` block holds the load and status-update counts.

No exception is created, and no `Holdings Transfer` notification is sent. Matcher failures in step 2 still send the `HOLDINGS PREPROCESS | …` alert.

**GET** `?account_code=…&as_of_date=…` returns the central `holding_data` rows for that account and date.

---

## 8. Statuses and value domains

| Field | Values |
|---|---|
| `holding_data.status` | `PENDING`, `TRADE` (matched), `ACEX`, `INACTIVE_USER`, `INACTIVE_ACCOUNT`, `INACTIVE_CLIENT`, `RNR \| <code>` (from the reference table, `RNR \| MISC`, `RNR \| DEMO`) |
| `holding_data.processed` | `NO`, `YES` |
| `holding_data.loaded` | `false` (default, migration `16`), `true` after the load |
| `holding_data.process_outcome` | security-master match status; `Fail: Could Not Find Matching Security ID`; `Fail: Correct Symbol could not be extracted. Skipping this row`; `FAIL: Unrecognized status`; `Inactive User - Processing Skipped`; `Inactive Account - Processing Skipped`; `Automated exception resolution based on historical data`; `… via Exception Mgmnt`; `Resolved Exception: …` |
| `holding_data.source` | `Direct Feed`, `Plaid`, `eConversion`, `Manual Upload` (`ELECTRA`, `PLAID`, `plaid` are normalised) |
| `is_option`, `is_future` | `Yes` or NULL |
| `bk_holdings_extra` `STATUS` | `Active`, `Inactive` (one row with `is_active = true` per holding; history kept as inactive rows) |
| Exception `EXCEPTION_TYPE` | `HOLDING` (only if created by hand, see 4.4) |

---

## 9. Why a holding can stay `processed = 'NO'` (or never reach the client)

| Reason | Where it stops |
|---|---|
| Unknown account (`ACEX`) | 1A |
| No security found, and no history match or ops resolution | 1B / 1C. **No exception is created automatically**, so nobody is told. |
| A per-row update inside a `DO` block failed (only a `NOTICE`) | 1B. Retried next run. |
| `RNR \| …` from the reference table, history or ops | 5.2: only `TRADE` is fetched |
| `INACTIVE_CLIENT` | 5.2 |
| Status not recognised (`FAIL: Unrecognized status`) | 1A |
| `source` is `Manual Upload` or any non-automated value | 5.2 |
| Client has `manualUploadOnly = true` | 5.1. Fetch returns nothing. |
| Client has `tasks_config.holdingsProcess.enabled = false` | 5.1 |
| `pdl_account_code` or `account_owner_id` is missing | 5.3. Skipped. The owner is back-filled by 1A once the account is in `account_data`. |
| A chunk insert failed | 5.4. That chunk and the later ones wait for the next run. |
| Only `holdings-preprocess-job` runs (no 1A) | New rows are matched without the 1A flags (all go to EQUITIES), and inactive or unknown accounts are not filtered (inferred). |

Holdings closed on purpose without being loaded: `INACTIVE_USER`, `INACTIVE_ACCOUNT`, `RNR | MISC` (Plaid), `RNR | DEMO` (`processed = 'YES'`, `loaded = false`).

---

## 10. Settings

| Setting | Where it lives | Used in |
|---|---|---|
| `tasks_config.holdingsProcess.enabled` | client config (`rulesenginedb.clients_v2`) | 5.1 |
| `tasks_config.holdingsProcess.postProcess` | client config | 5.1, Step 3 |
| `tasks_config.holdingsProcess.manualUploadOnly` | client config | 5.1 |
| `tasks_config.holdingsProcess.deactivationUser` | client config (default `holding-process`) | 6.4 |
| `RUN_HISTORICAL_EXCEPTION_RESOLUTION` | env var (default `false`) | 1C (holdings-preprocess-job, API) |
| `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE` | env var | full preprocess #6 |
| `RUN_EXCEPTION_STATUS_SYNC` | env var | full preprocess #9 |
| `CHUNK_SIZE` | env var (default 1000; constant `SECURITIES_CHUNK_SIZE`) | 1B batch size |
| `APP_ENV`, `NODE_ENV`, region | env | 5.1 client filter, `owner` column, API stage check |
| `brokerdb.trade_process_reference` | central DB table | 1A h) RNR rules (shared with trades) |
| Hardcoded client codes (`DEMO`, `MRCM`, `WVR`, `crow`, `MOSS`, `WACAP`, `PRSC`, `BRDWL`) | `fn_process_holdings.sql` | 1A a), d) |

---

## 11. AWS vs Azure

| | AWS | Azure |
|---|---|---|
| `bk_holdings.owner` | not written | `= account_owner_id` (`APP_ENV === 'AZURE'`) |
| Holdings API | Lambda `holdingProcessApi` | Express server `server/` (`/v1/holdings`) |
| Job alerts / summaries | SNS topic, unless Slack is enabled | Slack |
| Clients picked | `environment = 'AWS'` | `environment = 'AZURE'` |
| Load hand-off | Direct (no SQS), the same code on both | same |

---

## 12. Notes and unknowns

- **Unknown:** the schedule of `holdings-preprocess-job`, `full-preprocess-job` and `holdings-process-job`, and their order. Who loads `Plaid`, `eConversion` and `Manual Upload` holdings. Whether `fn_exception_mgmnt_new_exceptions_holdings` is run by hand. The production DDL of `holding_data` / `bk_holdings` (the repo has only `CREATE TABLE IF NOT EXISTS` and seed DDL).
- **Numbers may be rounded (inferred).** The seed and tracked DDL define `price`, `quantity` and `amount` as `numeric(18)` (scale 0) in both `holding_data` (migration `08`) and `bk_holdings` (`seed/sql/bkHoldings.sql`). Fractional quantities would be rounded if production matches.
- **Possible bugs and risks** (seen in code, not tested):
  - `fn_process_holdings.sql:127-132`: `ACEX` has no `processed = 'NO'` filter. When an account leaves `account_data`, even loaded holdings become `ACEX`. When it comes back, lines 118-126 set them to `PENDING`, while they stay `processed = 'YES'`.
  - `fn_process_holdings.sql:105`: `INACTIVE_CLIENT` overwrites every status, processed rows included.
  - `fn_process_holdings.sql:158`: `CREATE TEMP TABLE mmh` without `DROP` / `ON COMMIT DROP`. A second call on the same DB session would fail with "relation already exists". Possible on the Azure Express server, which reuses the central connection pool across API calls (inferred).
  - `holdingsService.ts:156-157`: the client commit happens before the central commit. If the central commit fails, the rows are in `bk_holdings` but still `processed = 'NO'`. They are inserted again next run with new `holding_id`s, because the insert has no check on `holding_number`.
  - `holdingsStatusUpdateService.ts:49-57` and `BkHoldingsRepository.ts:86-99`: `maxDate` is computed over **all** sources, but the snapshots use automated sources only. If an account's newest row is a non-automated one, the "new snapshot" is empty, and every old active holding is treated as removed (inferred).
  - `holdingsPreprocessService.ts:322`: `security_id` and the match status from the security master are put into the SQL string without escaping. A quote in them breaks the statement, which is then skipped silently.
  - `fn_exception_mgmnt_refresh.sql:170-175`: references `trade_data.status` without a `FROM` (see 4.4).
- **Status reads outside the transaction.** In 6.2 the three reads don't pass the account transaction. Only the writes are transactional.
