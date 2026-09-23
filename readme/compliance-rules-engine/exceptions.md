# Exceptions (trades and holdings without a security)

How an exception is created, fixed, resolved and closed, all in one place.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `trade-process.md`, `holdings-process.md`, `central-db-schema.md`, `client-db-schema.md`, `security-master.md`, `runtime-overview.md`, `trade-alerts.md`.

---

## 1. Overview

- An **exception** is a trade (`brokerdb.trade_data`) or holding (`brokerdb.holding_data`) that security matching could not match to a security.
- It stays `status = 'PENDING'`, `processed = 'NO'`, with `process_outcome` like `Fail: Could Not Find Matching Security ID`.
- Exceptions are stored in the **central DB** in `public.bk_txn` / `bk_txn_extra`, and shown to the ops team on the exceptions dashboard.
- The ops team resolves them by hand. The dashboard calls this repo's private API, which fixes the trade/holding row. The next preprocess run picks it up.

```
 brokerdb.trade_data / holding_data (central DB)            public.bk_txn + bk_txn_extra (central DB)
 ────────────────────────────────────────────              ────────────────────────────────────────
 PENDING, matching fails ──(fn_exception_mgmnt_new_exceptions)──► exception, STATUS = 'New'
         │                                                           │
         │ auto-fix (fn_exception_mgmnt_auto_updates) + re-match      │ ops team, exceptions dashboard
         │ historical resolution (holdings only)                      ▼
         │                                         POST v1/exceptions/resolve (this repo)
         │◄─── updates status / security_id ───────── returns STATUS + COMMENT to the caller
         ▼
 TRADE (or RNR | …) ──(ExceptionStatusSyncService)────────────► STATUS = 'Closed' / 'Failed'
                   ──(fn_exception_mgmnt_refresh, legacy, flag)─► STATUS = 'Resolved'
```

---

## 2. Storage

All tables are in the **central DB**, schema `public`. They have the same names as the client DB tables of delivered trades, but here they hold exceptions (see `central-db-schema.md` 4.5). Their production DDL is not in this repo; `seed/sql/bkTxn.sql` is a local approximation.

### 2.1 Tables

| Table / view | Holds | Notes |
|---|---|---|
| `bk_txn` | One row per exception | PK `transaction_id = 'XJ69' \|\| trade_id` (or `\|\| holding_number`). `trade_id` holds the trade id or the holding number. |
| `bk_txn_extra` | Exception attributes (EAV) | `transaction_id`, `extra_type_id`, `attribute_value`, `is_active`, `created_by`, `modified_by`. FK to `bk_txn`. |
| `bk_txn_extra_types` | Attribute names | `extra_type_id`, `attribute_type` |
| `exceptions_view` | Dashboard view | **Not in the repo** (no DDL, not in the seed). Columns used by code: `transaction_id`, `trade_id`, `xtype` (`TRADE`/`HOLDING`), `status`, `resolution`, `secid`, `security_name`, `security_type`, `symbol`, `currency_code`, `isin`, `cusip`. |

EAV rule: the current value of an attribute is the row with `is_active = true`. A change deactivates the old row and inserts a new one.

### 2.2 Attribute types

Names from the local seed `seed/central/configs/bkTxnExtraTypes.ts` (seed ids in brackets; **production ids are unknown**, see 15):

| Attribute | Written by this repo? | Meaning |
|---|---|---|
| `STATUS` (1) | yes | Exception status (section 11) |
| `COMMENT` (2) | yes (status sync) | Free-text note, e.g. `Resolved Exception: Security matched successfully` |
| `EXCEPTION_TYPE` (3) | yes (creation) | `TRADE` or `HOLDING` |
| `TRADE_RESOLUTION_REASON` (4) | no | Ops choice: `Not a Trade`, `Matched to Factset Security`, `New Security` (inferred: shown as `exceptions_view.resolution`) |
| `PROCESS_OUTCOME` (5) | yes (creation) | Copy of the failed `process_outcome` |
| `SECURITY_ID` (6) | no | Security chosen by ops (inferred: `exceptions_view.secid`) |
| `TRADE_SECURITY_TYPE`, `SECURITY_DESCRIPTION`, `SECURITY_TYPE_CODE`, `SECURITY_CURRENCY_CODE`, `SECURITY_TICKER`, `SECURITY_CUSIP`, `SECURITY_ISIN`, `SECURITY_ISO_COUNTRY` | no | Same names as the API request fields (6.1). Inferred: the dashboard stores the request here. |

Code that writes `STATUS`, `COMMENT`, `PROCESS_OUTCOME`, `EXCEPTION_TYPE` looks up ids by name, **except** the legacy SQL functions, which hardcode ids (15).

### 2.3 Author

Rows written by this repo use the **support user**: `SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com'`.

---

## 3. Order inside `full-preprocess-job`

`tasks/tradeProcess/fullPreprocessController.ts`. Exception steps in bold. If any step throws, the job stops there (the logger rethrows by default) and `tasks/index.ts` sends an alert.

| # | Step | Code |
|---|---|---|
| 1–2 | Clean trades, then holdings | `fn_process_trades()`, `fn_process_holdings()` |
| 3–4 | Match trades, then holdings | `TradePreprocessService` / `HoldingsPreprocessService.runSecurityMatching()` |
| **5** | **Auto-fix known bad data (trades only)** | `fn_exception_mgmnt_auto_updates()` |
| **6** | **Legacy: apply resolutions, mark `Resolved`** *(only if `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE=true`)* | `fn_exception_mgmnt_refresh()` |
| 7–8 | Match again (trades, holdings) | same as 3–4 |
| **9** | **Sync statuses → `Closed` / `Failed`** *(only if `RUN_EXCEPTION_STATUS_SYNC=true`)*, then admin portal cache refresh | `ExceptionStatusSyncService` |
| **10** | **Create new trade exceptions** | `fn_exception_mgmnt_new_exceptions()` |

Notes:
- Step 10 runs after step 9, so an exception created in this run is synced at the earliest in the next run.
- Holding exceptions are **not** created by any step (4.2).
- Historical exception resolution (section 9) is **not** part of this job.
- Both flags are env vars parsed in `libs/globalConstants.ts` (`z.stringbool()`, default `false`). Their deployed values are not in the repo.

---

## 4. Creation

### 4.1 Trades: `brokerdb.fn_exception_mgmnt_new_exceptions()`

File: `plpgsql/post-migrations/brokerdb.fn_exception_mgmnt_new_exceptions.sql`. Called by step 10 (`ExceptionService.runNewExceptionsRefresh`).

Picks trades with:
```sql
status = 'PENDING' AND processed = 'NO'
AND process_outcome IS NOT NULL AND process_outcome ILIKE 'fail:%'
AND trade_id NOT IN (SELECT trade_id FROM bk_txn)      -- no exception yet
```
Fail reasons that qualify (set by matching): `Fail: Could Not Find Matching Security ID`, `Fail: Correct Symbol could not be extracted. Skipping this row` (crypto). `FAIL: Unrecognized status` does not, because its row is not `PENDING`.

Inserts:
- **`bk_txn`**: `transaction_id = concat('XJ69', trade_id)`, security fields, `pdl_client_code`, `bk_code = broker_code`, `source`. Masked: `account_number = 'xxxxxxx'`, `pdl_account_id` = a fixed hardcoded id, `price`/`quantity`/`amount` = `1` if > 0 else `0`.
- **`bk_txn_extra`**, three rows, all `is_active = true`: `PROCESS_OUTCOME = <process_outcome>`, `STATUS = 'New'`, `EXCEPTION_TYPE = 'TRADE'`.

Only one exception per trade, ever. If the trade fails again later, no new exception is created.

### 4.2 Holdings: `brokerdb.fn_exception_mgmnt_new_exceptions_holdings()`

File: `plpgsql/post-migrations/brokerdb.fn_exception_mgmnt_new_exceptions_holdings.sql`. **Not called by any code in this repo.** Whether it is run by hand or by an external scheduler is unknown.

Differences from 4.1:
- Source `brokerdb.holding_data`; id `concat('XJ69', holding_number)`.
- Filter: `status = 'PENDING'`, `processed = 'NO'`, `is_option IS NULL`, `is_future IS NULL`, `process_outcome IS NOT NULL AND process_outcome != 'newsec'` (not limited to `fail:%`).
- `trade_date = as_of_date`, `transaction_type = 'holding'`, `bank_tran_code = 'n/a'`.
- `price`, `quantity`, `amount` are copied **unmasked**.
- `EXCEPTION_TYPE = 'HOLDING'`.

---

## 5. Auto-fix: `brokerdb.fn_exception_mgmnt_auto_updates()`

File: `plpgsql/post-migrations/brokerdb.fn_exception_mgmnt_auto_updates.sql` (first created by `migrations/11_add_exception_auto_updates_function.ts`). Step 5. Only `UPDATE`s on `brokerdb.trade_data`, `status = 'PENDING'` rows; holdings are not touched. It does not touch `bk_txn*`.

| Broker / case | Filter (plus `status = 'PENDING'`) | Fix |
|---|---|---|
| GPB options | `is_option = 'Yes'`, broker `GPB`, `process_outcome IS NOT NULL` | Build `symbol` from `security_name` |
| RMJ, VGD options | same, broker `RMJ` / `VGD` | Pad truncated `symbol` |
| LPL options | `is_option = 'Yes'`, broker `LPL`, `symbol LIKE '% %'` | `symbol` = part before the space |
| FX `USD/… OUTRIGHT` | `process_outcome IS NOT NULL` | `security_type = 'FX'`, `symbol` = the other currency |
| FX `EUR/… OUTRIGHT`, `EURO` | `process_outcome IS NOT NULL` | `security_type = 'FX'`, `symbol = 'EUR'`, `currency_code = 'USD'` |
| Plaid options (`CALL…`/`PUT…`) | `is_option = 'Yes'`, `source = 'Plaid'`, `symbol IS NOT NULL` | `cusip = symbol`, then rebuild `symbol` from `security_name` |

Broker = `split_part(file_name, '_', 2)`. Steps 7–8 then retry matching on these rows. If they still fail, step 10 makes them exceptions.

---

## 6. Manual resolution: private API

### 6.1 Endpoint and request

- Function `exceptionsResolvingV1`: `serverless/private/functions/exceptionResolvingV1/` (handler, `schema.ts`), logic in `services/ExceptionResolvingService.ts`.
- `POST v1/exceptions/resolve` on the AWS service `compliance-rules-engine-v3-private` (`serverless/private/serverless.ts`, API Gateway `endpointType: 'PRIVATE'`). No Azure route exists in `server/`.
- Caller: the exceptions dashboard (inferred; the caller is not in this repo).

Body (JSON, validated with zod as a discriminated union on `TRADE_RESOLUTION_REASON`):

| Field | Required for | Rule |
|---|---|---|
| `EXCEPTION_TYPE` | all | `TRADE` or `HOLDING` |
| `TRADE_ID` | all | integer ≥ 0. Trade id or holding number (**not** the `XJ69…` id) |
| `USER` | all | non-empty string |
| `TRADE_RESOLUTION_REASON` | all | `Not a Trade`, `Matched to Factset Security`, `New Security` |
| `TRADE_SECURITY_TYPE` | `Not a Trade` | non-empty, e.g. `RNR \| MISC` |
| `SECURITY_ID` | `Matched to Factset Security` | non-empty |
| `SECURITY_DESCRIPTION`, `SECURITY_TYPE_CODE` | `New Security` | non-empty |
| `SECURITY_CURRENCY_CODE` (3), `SECURITY_TICKER`, `SECURITY_CUSIP` (9), `SECURITY_ISIN` (12), `SECURITY_ISO_COUNTRY` (2) | `New Security`, optional | exact length in brackets |

Example:
```json
{ "EXCEPTION_TYPE": "TRADE", "TRADE_ID": 1234567, "USER": "jdoe",
  "TRADE_RESOLUTION_REASON": "Matched to Factset Security", "SECURITY_ID": "ABC123-R" }
```

### 6.2 What it does

First, for all reasons: the row must exist in `trade_data` / `holding_data` and have `processed = 'NO'`. Otherwise → 400. It does **not** check that the row is `PENDING` or that an exception exists.

| Reason | Security master call | Update on `trade_data` / `holding_data` | Returned `STATUS` / `COMMENT` |
|---|---|---|---|
| `Not a Trade` | `GET /security-master/factset/get-security-types`; `TRADE_SECURITY_TYPE` must equal a `security_type_code` with `universe_type = 'RNR'` and have the form `RNR \| <CODE>` | `status = <TRADE_SECURITY_TYPE>`, `security_id = 'RNR_<CODE>'`, `process_outcome = 'Resolved Exception: Not a Trade'` | `Closed` / `Resolved Exception: Not a Trade` |
| `Matched to Factset Security` | `POST /security-master/factset/pre-fetch`; uses the returned `fsym_security_id` | `status = 'TRADE'`, `security_id = <fsym_security_id>`, `process_outcome = 'Resolved Exception: Matched to Existing Security'` | `Closed` / same text |
| `New Security` | `POST /security-master/central-custom/security` creates a custom security (`created_by = USER`) | **none** | `Awaiting Match` / `Awaiting Match: New security created` or `…: Security already exists` |

- After `Not a Trade` / `Matched`, the next trade process (or holdings process) run picks the row up as usual.
- After `New Security`, the row stays `PENDING`. It relies on the next preprocess matching run to find the new security (section 7).

### 6.3 What it does not do

- It **does not write `bk_txn` / `bk_txn_extra`**. It only returns `STATUS` and `COMMENT`. Inferred: the dashboard writes them, plus `TRADE_RESOLUTION_REASON` and the request fields (2.2).
- It **does not refresh the admin portal cache**. Only the status sync does (7.3).

### 6.4 Response and errors

Body: `{ status: <bool>, message, data: { STATUS, COMMENT }, error }`.

| Case | HTTP | `data.STATUS` | `data.COMMENT` |
|---|---|---|---|
| Success | 200 | `Closed` / `Awaiting Match` | see 6.2 |
| Zod validation error | 400 | `Failed` | `Failed to resolve exception: <field label> <message>` |
| `ValidationError` / `ApplicationError` (not found, already processed, invalid RNR type, security not found, SMA create failed) | 400 | `Failed` | `Failed to resolve exception: <message>` |
| Anything else | 500 | `Failed` | `Failed to resolve exception` |

Every error also sends an alert `Exception Resolving | TYPE: <type> | ID: <id>`. `error.stack` is included in the response outside PROD/SAND (`isProductionOrSandbox`).

---

## 7. Status sync: `ExceptionStatusSyncService`

Files: `tasks/tradeProcess/services/exceptionStatusSyncService.ts`, `storage/repositories/ExceptionsRepository.ts`. Step 9, flag `RUN_EXCEPTION_STATUS_SYNC`.

### 7.1 Rules

Trades and holdings run in parallel. "Record" = the `trade_data` / `holding_data` row joined on `transaction_id = CONCAT('XJ69', id)` and filtered by the active `EXCEPTION_TYPE`.

| Active exception `STATUS` | Record `status` | New `STATUS` | New `COMMENT` |
|---|---|---|---|
| `New`, `Reviewed`, `Awaiting Match` | `= 'TRADE'` | `Closed` | `Resolved Exception: Security matched successfully` |
| `Awaiting Match` | `!= 'TRADE'` (incl. `PENDING`, `RNR \| …`, `ACEX`) | `Failed` | `Resolving Failed: Could not find matching security` |

Not covered: `New` / `Reviewed` exceptions whose record became `RNR | …` (e.g. after `Not a Trade`) stay as they are unless the dashboard wrote `Closed`.

### 7.2 Writes

`bulkUpdateExceptionStatus`, chunks of 500, one `DO $$ … $$` block per chunk:
1. Deactivate the active `STATUS` and `COMMENT` rows (`is_active = false`, `modified_date = NOW()`).
2. Insert a new `STATUS` row and a new `COMMENT` row, author = support user, `is_active = true`.

### 7.3 Admin portal cache

After both syncs: `adminPortalClient.refreshCache('PERSONAL_TRADE')` (`libs/disclosureAppServer/AdminPortalClient.ts`) → `GET ${ADMIN_PORTAL_BASE_URL}/pdl/secured/config/cat/RELOAD_CACHE_EXTERNAL?cacheToUpdate=PERSONAL_TRADE`, API key read from the secret `ADMIN_PORTAL_API_KEY_SECRET_NAME`. A failure only sends an alert `ExceptionStatusSync | AdminPortal Cache Refresh`; the job continues.

---

## 8. Legacy refresh: `brokerdb.fn_exception_mgmnt_refresh()`

File: `plpgsql/post-migrations/brokerdb.fn_exception_mgmnt_refresh.sql`. Step 6, flag `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE`. Also called (twice) by `fn_exception_mgmnt_new_sec`. Reads `exceptions_view`, so it depends on the resolution being stored in `bk_txn_extra` by the dashboard.

**a) Apply resolutions** (only rows still `PENDING`, exception `status = 'Resolved'`):

| `resolution` | `trade_data` (`xtype = 'TRADE'`) | `holding_data` (`xtype = 'HOLDING'`) |
|---|---|---|
| `Matched to Factset Security` | `status = 'TRADE'`, `security_id = secid`, `process_outcome = 'Matched to Factset Security via Exception Mgmnt'` | same |
| `Not a Trade` | `status = 'RNR \| MISC'`, `security_id = 'RNR_MISC'` | same |

A second pair of `Not a Trade` statements then tries to set `TRADE` + `secid`. For trades it should match nothing, because the row is no longer `PENDING` (inferred). The holdings one is broken (15).

**b) Mark `Resolved`.** For every exception with `exceptions_view.status != 'Resolved'` whose record is no longer `PENDING`:
1. collect `bk_txn_extra.extra_id` where `extra_type_id = 2`
2. delete that exception's rows with `extra_type_id = 6`
3. insert a copy of each collected row with `attribute_value = 'Resolved'`
4. deactivate the collected rows

This also turns `Closed` and `Failed` exceptions into `Resolved` (inferred from the `!= 'Resolved'` filter).

---

## 9. Historical exception resolution (holdings only)

File: `tasks/holdingsPreprocess/services/historicalExceptionResolutionQuery.ts`, run by `HoldingsPreprocessService.resolveHistoricalExceptions()` when `RUN_HISTORICAL_EXCEPTION_RESOLUTION=true`.

Called from:
- `holdings-preprocess-job` (`tasks/holdingsPreprocess/holdingsPreprocessController.ts`), after holdings matching
- `services/holdings/HoldingsCreateService.ts` (only `LOCAL`/`DEV`/`TST`)

Not called by `full-preprocess-job`.

What it does: for each current `PENDING` holding (`as_of_date` after the start of last month), find the latest earlier holding (within 6 months) of the same security and copy its result:

| Match condition | |
|---|---|
| Always | same `currency_code`, `security_type`, non-empty `security_name`; different `holding_number` |
| `Direct Feed` | current `identifier` empty, or equal to the history one |
| `Plaid` | same `description` and `plaid_security_id` |
| History row | `processed = 'YES'` or `status LIKE 'RNR \|%'`; not `INACTIVE_ACCOUNT`/`INACTIVE_USER`; non-empty `security_id` |

Update: `status = <history status>`, `security_id = <history security_id>`, `process_outcome = 'Automated exception resolution based on historical data'`.

It works on `holding_data` only and does not touch `bk_txn*`. A holding exception (if one exists) is then closed by the status sync if the copied status is `TRADE`, or marked `Resolved` by the legacy refresh.

---

## 10. `brokerdb.fn_exception_mgmnt_new_sec()`

File: `plpgsql/post-migrations/brokerdb.fn_exception_mgmnt_new_sec.sql`. **Not called by code.** Intended (per its comments and SQL) for exceptions resolved as `New Security` without a `secid`:
1. call `fn_exception_mgmnt_exception_updates()` and `fn_exception_mgmnt_refresh()`
2. re-apply `trade_process_reference` RNR rules to `PENDING` trades
3. build a list of new securities from `exceptions_view` + `brokerdb.trade_process_new_sec_type_map`, with a random 12-char `security_id`
4. replace `bk_txn_extra` rows with `extra_type_id = 3` by the new id (author hardcoded)
5. `SELECT` the list (inferred: meant to be copied by hand into the security master), then refresh again

As written it cannot run (15). The API's `New Security` path (6.2) replaces it.

---

## 11. Status state machine

| `STATUS` | Set by | When |
|---|---|---|
| `New` | `fn_exception_mgmnt_new_exceptions` (and the holdings variant) | Exception created |
| `Reviewed` | **not this repo** (inferred: dashboard) | – |
| `Awaiting Match` | **not this repo**; the API returns it for `New Security` (inferred: dashboard writes it) | after `New Security` |
| `Closed` | `ExceptionStatusSyncService`; also returned by the API for `Not a Trade` / `Matched` | record is `TRADE`; or ops resolution |
| `Failed` | `ExceptionStatusSyncService`; also returned by the API on any error | `Awaiting Match` and record not `TRADE` |
| `Resolved` | `fn_exception_mgmnt_refresh` (flag); also read by it as the ops "done" mark | record no longer `PENDING` |

`Open` does not exist anywhere in the repo. `Resolved` is not in the TS `ExceptionStatus` enum (`services/ExceptionResolvingService.ts`).

```
                    fn_exception_mgmnt_new_exceptions
                                  │
                                  ▼
                              ┌───────┐   dashboard (not this repo)   ┌──────────┐
                              │  New  │ ─────────────────────────────►│ Reviewed │
                              └───┬───┘                               └────┬─────┘
       API "Not a Trade"/"Matched" │  API "New Security"                    │
       (dashboard writes Closed)   │  (dashboard writes Awaiting Match)     │
              ┌────────────────────┤◄───────────────────────────────────────┘
              │                    ▼
              │            ┌────────────────┐  sync: record != TRADE   ┌────────┐
              │            │ Awaiting Match │ ────────────────────────►│ Failed │
              │            └───────┬────────┘                          └────────┘
              │                    │ sync: record = TRADE
              ▼                    ▼            (sync also closes New/Reviewed when record = TRADE)
          ┌────────┐◄──────────────┘
          │ Closed │
          └────────┘
   Legacy, flag RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE:
   any status except Resolved ── record no longer PENDING ──► Resolved
```

What happens to a `Failed` exception next is not in this repo (inferred: ops can resolve it again).

---

## 12. Worked example

Trade `1234567` from a GPB file: a corporate bond the security master does not know.

| # | Moment | `trade_data` | Active exception rows (`XJ691234567`) |
|---|---|---|---|
| 1 | Loaded | `PENDING`, `NO` | – |
| 2 | Run 1, step 3: no match | `PENDING`, `process_outcome = 'Fail: Could Not Find Matching Security ID'` | – |
| 3 | Run 1, step 5: no auto-fix rule applies; steps 7–8 fail again | same | – |
| 4 | Run 1, step 10 | same | `bk_txn` row; `STATUS = New`, `EXCEPTION_TYPE = TRADE`, `PROCESS_OUTCOME = Fail: …` |
| 5 | Ops: `New Security`, `SECURITY_DESCRIPTION = 'ACME 5% 2030'`, `SECURITY_TYPE_CODE = …` | unchanged | API returns `Awaiting Match: New security created`; dashboard writes `STATUS = Awaiting Match` (inferred) |
| 6a | Run 2, step 3 (or 7): matching now finds the new security | `TRADE`, `security_id = <id>` | – |
| 6b | Run 2, step 9 (sync on) | same | `STATUS = Closed`, `COMMENT = Resolved Exception: Security matched successfully` |
| 7 | `trade-process-job` | `processed = 'YES'`, copied to client DB `bk_txn` | unchanged |

If step 6a still fails: step 9 sets `STATUS = Failed`, `COMMENT = Resolving Failed: Could not find matching security`. The trade stays `PENDING`.

If ops had chosen `Matched to Factset Security` in step 5: the API sets the trade to `TRADE` right away, `process_outcome = 'Resolved Exception: Matched to Existing Security'`, and returns `Closed`.

---

## 13. What the ops team sees

- The **exceptions dashboard** (admin portal) reads `exceptions_view` (inferred from the code comments and the cache refresh; the dashboard is not in this repo).
- Per exception: client code, broker code, source, security fields (`security_name`, `security_type`, `isin`, `cusip`, `symbol`, `currency_code`, `exchange`), trade date, transaction type, description, the fail reason, the status and comment.
- Masked for trades: account number (`xxxxxxx`), `pdl_account_id` (fixed placeholder), price/quantity/amount (0/1). Holdings (4.2) are not masked.
- Trades that never become exceptions, so ops never see them: rows not `PENDING` (`ACEX`, `INACTIVE_ACCOUNT`, `FAIL: Unrecognized status`), and rows without a `fail:` outcome. See `trade-process.md` 6.
- Holding exceptions appear only if `fn_exception_mgmnt_new_exceptions_holdings` is run outside this repo.

---

## 14. Settings

| Setting | Where | Effect |
|---|---|---|
| `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE` | env var, default `false` | Step 6 (legacy refresh) |
| `RUN_EXCEPTION_STATUS_SYNC` | env var, default `false` | Step 9 (status sync + cache refresh) |
| `RUN_HISTORICAL_EXCEPTION_RESOLUTION` | env var, default `false` | Section 9 |
| `ADMIN_PORTAL_BASE_URL`, `ADMIN_PORTAL_API_KEY_SECRET_NAME`, `ADMIN_PORTAL_API_KEY_SECRET_REGION` (default `us-west-2`) | env vars | 7.3 |

No client setting (`tasks_config.*`) affects exceptions. All functions work on all clients at once.

---

## 15. Known issues and risks

Seen in code, not tested.

| Where | Issue |
|---|---|
| `fn_exception_mgmnt_refresh.sql:170-175` | `UPDATE brokerdb.holding_data … WHERE trade_data.status = 'PENDING'`, but `trade_data` is not in `FROM`. PostgreSQL raises "missing FROM-clause entry" when it reaches this line. Inferred: with the flag on, the whole function fails and rolls back, and `full-preprocess-job` stops at step 6 (steps 7–10 skipped). |
| `fn_exception_mgmnt_refresh.sql:196,203` | Hardcoded `extra_type_id` 2 (treated as STATUS) and 6 (deleted). Seed ids: 1 = STATUS, 2 = COMMENT, 6 = SECURITY_ID. Commented-out code in the same file uses 2 = status, 3 = secid, 4 = comment, 7 = resolution. Production ids unknown. |
| `fn_exception_mgmnt_refresh.sql:196` | No `is_active` filter: old inactive STATUS rows are also copied as `Resolved`, giving several active `Resolved` rows. The insert (`:205`) has no `created_by`. |
| `fn_exception_mgmnt_refresh.sql:163-168` | `Not a Trade` → `TRADE` + `secid`. Dead for trades after `:141` (inferred), contradicts it otherwise. |
| `fn_exception_mgmnt_new_sec.sql:15` | Calls `fn_exception_mgmnt_exception_updates()`, which is not in the repo. Bare `SELECT` without `INTO` (`:15,16,80,87`) is an error in PL/pgSQL. |
| `fn_exception_mgmnt_new_sec.sql:75` | `jj` has no `transaction_id` column, so the subquery refers to `bk_txn_extra.transaction_id`: inferred to delete **all** `extra_type_id = 3` rows when `jj` is not empty. Also uses `md5(random())` for ids. |
| `fn_exception_mgmnt_new_exceptions_holdings.sql:40-45` | `CASE WHEN isin IS NULL THEN identifier END` yields `NULL` when `isin` is set, so the real ISIN/CUSIP is dropped. Price/qty/amount not masked (`:34-36`). |
| `fn_exception_mgmnt_new_exceptions.sql:100` | Ids share one namespace: trade `N` and holding `N` both map to `XJ69N`. If a holding exception `N` exists, trade `N` never gets one (and vice versa). |
| `fn_exception_mgmnt_auto_updates.sql:100-111` | Plaid fix is not idempotent: each run copies the already rebuilt `symbol` into `cusip`, so the original value is lost after the second run (inferred). |
| `exceptionStatusSyncService.ts:117` | `offset += 500` after updating a chunk, but updated rows drop out of the query. With more than 500 matches, rows are skipped until the next run. |
| `ExceptionsRepository.ts:80,109,130,141` | SQL built by string interpolation (statuses, ids, comment). Values are internal today, but it is not parameterized. |
| `ExceptionResolvingService.ts:249,260` | Only checks `processed = 'NO'`. A row with any status (e.g. `INACTIVE_ACCOUNT`) can be set to `TRADE`, and no exception needs to exist. |
| Sync + refresh both on | Refresh (step 6) marks non-`PENDING` records `Resolved` before the sync, and also overwrites `Closed`/`Failed`. Which final status ops see depends on the step order (inferred). |
| `New Security` timing | The first matching run after the API call decides. If the new security is not yet findable, the sync sets `Failed` at once (inferred). |

---

## 16. Notes and unknowns

- **Not in this repo:** the dashboard / admin portal, the `exceptions_view` definition, and production DDL and ids of `bk_txn_extra_types`.
- **Unknown:** who writes `Reviewed`, `Awaiting Match`, `Closed` (after the API), `TRADE_RESOLUTION_REASON`, `SECURITY_ID` and the other request attributes to `bk_txn_extra`. Inferred: the dashboard, from the API response and request.
- **Unknown:** the deployed values of the three `RUN_*` flags and the job schedules.
- **Unknown:** whether `fn_exception_mgmnt_new_exceptions_holdings` and `fn_exception_mgmnt_new_sec` are run by hand or by an external scheduler. If holding exceptions exist in production, they come from outside this repo's code.
- **Unknown:** whether the private API is deployed on Azure in another way; there is no Azure route in `server/`.
- The admin portal API key is read with `readSecret` from AWS Secrets Manager. How this works on Azure is unknown.
- `exceptions_view.resolution` / `secid` are assumed to come from `TRADE_RESOLUTION_REASON` / `SECURITY_ID` (inferred from names and the commented SQL).
