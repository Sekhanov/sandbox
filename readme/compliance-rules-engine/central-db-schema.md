# Central DB schema

What the **central DB** holds and how `compliance-rules-engine` uses it.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

---

## 1. What this database is

- **One PostgreSQL database shared by all clients**, also called the common DB. `project.md` calls it `rulesenginedb`, the same name as one of its schemas. The real database name comes from the credentials.
- **What it is for:**
  - Holds the **client registry and rule configs**.
  - Is the **staging area** for every incoming trade and holding (from broker files, Plaid and manual uploads) before it is sent to a client DB.
  - Stores **exceptions** for the ops team.
- **Who owns the schema:**
  - **This repo owns `rulesenginedb`**: created and changed by `migrations/*.ts` (Umzug; log table `rulesenginedb.SequelizeMeta`).
  - **`brokerdb`, `public`, `refdata` and `userdb` already existed.** This repo only tracks a few of these tables with `CREATE TABLE IF NOT EXISTS` (migration `08_track_existing_db_objects.ts`) and adds columns or indexes. The rest is external: only the local seed creates it (`seed/sql/*.sql`), so production may differ.
  - **DB functions** (`plpgsql/{pre,post}-migrations/*.sql`) are deployed by `storage/applyDbFunctions.ts`. A function is skipped when its git hash, stored as the function comment, hasn't changed.
- **Connection:** `storage/centralDb.ts` → `connectToCentralDb()`. It is a singleton. Credentials come from AWS Secrets Manager (`CENTRAL_DB_SECRET`) on AWS, or from `DB_*` env vars on Azure and locally.

Related docs: `README.md` (index), `client-db-schema.md` (per-client databases), `client-config.md`, `trade-process.md`, `holdings-process.md`, `exceptions.md`, `accounts-and-feedback.md`, `trade-alerts.md`.

---

## 2. Schemas at a glance

| Schema | Holds | Created by | Service access |
|---|---|---|---|
| `rulesenginedb` | Clients, preclear rule configs, trade rule configs | **this repo (migrations)** | read; write via config scripts |
| `brokerdb` | Incoming trades and holdings, the account copy, reference rules, feedback staging | external (some tables tracked by migrations) | **read + write** (all pipelines) |
| `public` | Exceptions (`bk_txn*`), broker feedback disclosures, broker registry | external | read + write |
| `refdata` | Known Plaid duplicates | external | read |
| `userdb` | Users. Only used to find the support user | external | read |

---

## 3. How the tables connect

```
rulesenginedb.clients_v2 ──preclear_config_version──► preclear_configs_v2.version
        │                └─trade_config_version─────► trade_configs_v2.version
        │ id (client code)
        ▼  (case-insensitive)
brokerdb.trade_data.pdl_client_code          brokerdb.holding_data.pdl_client_code
brokerdb.trade_data.pdl_account_code ──┐     brokerdb.holding_data.pdl_account_code ──┐
                                       ▼                                              ▼
                          brokerdb.account_data.account_id  (copied from each client DB's account_view)

trade_data.trade_id / holding_data.holding_number
        └── 'XJ69' || id ──► public.bk_txn.transaction_id ──► public.bk_txn_extra ──► bk_txn_extra_types
                                         (exceptions)        (STATUS, EXCEPTION_TYPE, PROCESS_OUTCOME, …)

trade_data.<column> = trade_process_reference.value          (rules for "not a trade" → RNR)
trade_data.transaction_id = refdata.plaid_dupe.transactionid  (duplicates → DUP)
trade_data.file_name ≈ fileuploadtracker.filename; broker part = bk_brokers_central_extra[BK_ELECTRA_ID]
```

**Key pattern: EAV ("extra" tables).** Exceptions and feedback are stored as key/value rows:
- the `*_types` table names the attribute
- the `*_extra` table holds the value
- `is_active = true` marks the current value; older values are kept with `is_active = false`.

---

## 4. Tables

### 4.1 `rulesenginedb`: clients and rule configs (owned by this repo)

| Table | Purpose | Key columns |
|---|---|---|
| `clients_v2` | One row per client: environment, active configs, task settings | see below |
| `preclear_configs_v2` | Versioned preclear rule sets | `version` UUID PK; `client_id` → `clients_v2.id`; `name` (ticket); `is_published`; `rules` JSONB (array of `{id, key, parent_id, parameters, action_in, action_not_in}`; see `preclear-rules-engine.md`) |
| `trade_configs_v2` | Versioned trade-process rule parameters | same, with `parameters` JSONB instead of `rules` (`EXCLUDE_RULE`, `LOAD_MANAGED_ACCOUNTS`, `SET_VALUES_ZERO`, `ZERO_VALUES`, `HOLDING_PERIOD*`, `MATCHING_RESULTS`, …) |

**`clients_v2` columns**

| Column | Meaning |
|---|---|
| `id` (CITEXT PK) | Client code, e.g. `SAND`. Matches `trade_data.pdl_client_code` |
| `name` | Display name |
| `environment` | `AWS` / `AZURE` |
| `stage` | `LOCAL`, `DEV`, `TST`, `SAND`, `PROD` |
| `region` | `eastus`, `westeurope`, `uaenorth`, `canadacentral` (migration 06 sets `eastus` for existing Azure clients) |
| `preclear_config_version`, `trade_config_version` | Active config (FK to a **published** config of the same client) |
| `trade_status_config` | JSON labels for trade results: `MATCH_STATUS`, `PENDING_MATCH_STATUS`, `PRECLR_NOT_NEEDED`, `MANAGED_ACCOUNT` |
| `preclear_status_config` | JSON labels for preclear results: `APPROVE`, `DENY`, `REVIEW`, `OTHER` |
| `aws_environment` / `azure_environment` | How to reach the client DB (`{db:{roleArn,secretName,region}, backendUrl?}` / `{tenantId}`). See `client-config.md` |
| `tasks_config` | Which jobs run for this client (below) |
| `created_at`, `updated_at` | Timestamps |

**`tasks_config` JSON**

| Key | Fields | Used by |
|---|---|---|
| `tradeProcess` | `enabled`, `tradeStatus` (**raw SQL**, e.g. `status = 'TRADE'`), `transactionDate`, `manualUploadOnly` | trade process, trade alerts |
| `holdingsProcess` | `enabled`, `postProcess`, `manualUploadOnly`, `deactivationUser` | holdings process |
| `accountsLoad` | `enabled` | account load job |
| `feedbackProcess` | `enabled` | feedback job |

**Rules enforced in the DB (triggers):**
- A client can only point to a **published** config of its own (`check_client_configs_published`).
- A **published** config can't be updated (`forbid_update_if_published`). Changes need a new version.

**Access:**
- Read by every job through `services/ClientConfigService.ts` (`ClientRepository`, `PreclearConfigRepository`, `TradeConfigRepository`).
- Written by `scripts/migrateConfigs.ts`, the seeders, migrations, and `fn_migrate_config_to_azure()`, a manual tool that copies a client from AWS to Azure.

**Legacy (read only, not created by this repo):** `rulesenginedb.clients` and `rulesenginedb.preclear_rules`, read by the old `rulesEngineV3` functions.

### 4.2 `brokerdb.trade_data`: every incoming trade (staging)

One row per trade, from a broker file, Plaid or manual upload. The full lifecycle is in `trade-process.md`.

| Column | Meaning |
|---|---|
| `trade_id` (PK, identity) | Trade id. Exception id = `'XJ69' \|\| trade_id` |
| `pdl_client_code` | Client. Overwritten from `account_data.client_code` |
| `pdl_account_code` | Employee account → `account_data.account_id` |
| `broker_code`, `file_name` | Broker, and source file name (`<yyyymmdd>_<broker>_..._TRN`) |
| `source` | `Direct Feed`, `Plaid`, `Manual Upload` |
| `transaction_date`, `create_date` | Trade date; row insert time |
| `security_type`, `security_name`, `symbol`, `cusip`, `isin`, `sedol`, `exchange_code`, `currency_code`, `description`, `bank_tran_code`, `plaid_sub_type` | Raw security data used for matching |
| `is_option`, `is_future` | `'Yes'` / null (set by preprocess) |
| `transaction_type`, `price`, `quantity`, `amount`, `commission_*` | Trade data |
| `status` | `PENDING` (default), `TRADE`, `RNR \| <reason>`, `ACEX`, `INACTIVE_ACCOUNT`, `INACTIVE_CLIENT`, `DUP` |
| `security_id` | Matched security; `''` on failure; `RNR_<reason>` |
| `process_outcome` | Preprocess result. `Fail: …` → becomes an exception |
| `processed` | `'NO'` / `'YES'` (done by trade process) |
| `processed_date`, `rule_status`, `transaction_id`, `loaded` | Set by trade process (`loaded = true` → delivered to the client DB) |

- **Index:** `(LOWER(pdl_client_code), pdl_account_code, LOWER(TRIM(transaction_type)), security_id, DATE(transaction_date))`, used by `TradeDataRepository.getLastSellDateBySecurityIdBeforeMaxDate` (last sell before a date).
- **Written by:**
  - the loader task `compliance-rules-engine/tasks/loadTxnAndHoldings` (insert Direct Feed rows), plus Plaid and manual loaders outside this repo
  - `fn_process_trades()`
  - security matching (`tradePreprocessService.ts`)
  - the exception functions and the exception-resolving API (`TradeDataRepository`)
  - trade process `updateElectraDb` (marks the row done)
  - the rules engine `INSERT_ACTIVITY_RECORD` (placeholder rows)
- **Read by:** preprocess, trade process (`FETCH_TRADE_RECORDS`), exceptions, trade alerts.

### 4.3 `brokerdb.holding_data`: every incoming holding (staging)

The same idea for holdings snapshots.

- **Columns:**
  - `holding_number` (PK). Exception id = `'XJ69' || holding_number`.
  - `pdl_client_code`, `pdl_account_code`, `account_owner_id`
  - `as_of_date`, `source` (`Direct Feed`, `Plaid`, `eConversion`)
  - security fields, `quantity`, `price`, `amount`
  - `status` (see section 5), `security_id`, `process_outcome`
  - `processed`, `processed_date`, `loaded`
- **Trigger:** `trg_set_as_of_created_date`. For `Direct Feed` rows it sets `as_of_date` / `create_date` to a month end.
- **Written by:** loaders, `fn_process_holdings()`, holdings matching, historical exception resolution (`holdings-preprocess-job`), the exception resolve API, the holdings process (marks rows done after copying them to the client `bk_holdings`).

### 4.4 `brokerdb`: other tables

| Table | Purpose | Key columns | Written by / Read by |
|---|---|---|---|
| `account_data` | Copy of every client's employee accounts | `account_id` PK, `client_code`, `owner_id`, `account_status`, `user_status`, `account_type`, `broker_name`, `feed_status`, `last_*` dates, … | **W:** account load job (`tasks/loadAccountData`): delete per client, then insert from the client `account_view`. **R:** `fn_process_trades` / `fn_process_holdings` (client code, ACEX, inactive) |
| `trade_process_reference` | Rules for "not a trade" | PK `(value, value_type)`, `status` (`RNR \| <code>`) | **W:** external. **R:** `fn_process_trades`, `fn_process_holdings` |
| `client_code_history` | Audit of overwritten client codes | `pdl_client_code`, `compliance_client_code`, `account_id`, `source_table` | **W:** `fn_process_trades`. **R:** none |
| `fileuploadtracker` | Log of loaded broker files | `filename` PK, `status` (`PENDING`/`SUCCESS`/`FAILURE`), `processingdate`, `numberrecordsprocessed`, `message` | **W:** loader task `compliance-rules-engine/tasks/loadTxnAndHoldings`. **R:** trade alerts (file freshness) |
| `broker_feedback_upload` | Staging for bulk broker-feedback upload | `client_code`, `account_id`, `feedback_type`, `additional_comment`, `disc_id`, `is_loaded` | **W/R:** `serverless/private/functions/bulkFeedback` |
| `electra_portal`, `trade_process_new_sec_type_map` | External; used only inside functions that the code never calls | – | – |

### 4.5 `public`: exceptions (`bk_txn*`)

These tables have the same names as the client DB tables of delivered trades, but **in central they hold exceptions**: trades and holdings the system couldn't match to a security.

| Table | Purpose | Key columns |
|---|---|---|
| `bk_txn` | One row per exception | `transaction_id` = `'XJ69' \|\| trade_id/holding_number`; `trade_id`; security fields; `pdl_client_code`; `bk_code`; price/qty/amount masked to 0/1 |
| `bk_txn_extra` | Exception attributes (EAV) | `transaction_id`, `extra_type_id`, `attribute_value`, `is_active` |
| `bk_txn_extra_types` | Attribute names | `STATUS`, `COMMENT`, `EXCEPTION_TYPE`, `PROCESS_OUTCOME`, `TRADE_RESOLUTION_REASON`, `SECURITY_ID`, `SECURITY_*` |
| `exceptions_view` | Dashboard view of exceptions (not in repo) | `trade_id`, `xtype` (`TRADE`/`HOLDING`), `status`, `resolution`, `secid`, security fields |

- **Created by:** `fn_exception_mgmnt_new_exceptions()` for trades whose `status` is `PENDING`, `processed` is `NO`, and `process_outcome` starts with `fail:`. It writes `PROCESS_OUTCOME`, `STATUS='New'` and `EXCEPTION_TYPE='TRADE'`.
- **Updated by:**
  - `fn_exception_mgmnt_refresh()`: applies ops resolutions to `trade_data`, and marks exceptions `Resolved`.
  - `ExceptionStatusSyncService` / `ExceptionsRepository`: `Closed` / `Failed`, plus a comment.
- **Read by:** `ExceptionsRepository`, the exception functions.

### 4.6 `public`: broker feedback

Compliance feedback about an account, e.g. "account has no feed". It is stored as central disclosures of type `BROKER_FEEDBACK`.

| Table / view | Purpose | Key columns |
|---|---|---|
| `disclosure_types` | Kind; here `BROKER_FEEDBACK` | `disc_type_id`, `disc_type` |
| `disclosures` | One row per feedback | `disc_id` PK, `disc_type`, `created_date`, `is_active` |
| `attribute_extra_types` | Attribute names | `STATUS`, `BROKER_FEEDBACK_CLIENT_CODE`, `ACCOUNT_ID`, `BROKER_FEEDBACK_TYPE`, `COMMENT`, `COMPLIANCE_NOTE` |
| `attribute_extra` | Attribute values | `attribute_id` (= `disc_id`), `attribute_extra_type_id`, `attribute_value`, `is_active` |
| `broker_feedback` (view) | Flat view of feedback | `disc_id`, `client_code`, `account_id`, `feedback_type`, `add_comment`, `comp_note`, `status`, `created_date` |

Flow:
1. A bulk upload inserts feedback with `STATUS='Pending'` (`serverless/private/functions/bulkFeedback`). It then tries to apply each one right away.
2. Applying (`serverless/public/functions/rulesEngineV2/attributes/service.ts`) updates the account in the client DB and sets `STATUS='Processed'`.
3. The feedback job (`feedback-process-job`) picks up any rows still `Pending` in `broker_feedback` and applies them the same way.

Details: `accounts-and-feedback.md`.

### 4.7 `public`: broker registry

| Table | Purpose | Key columns |
|---|---|---|
| `bk_brokers_central` | All brokers | `bk_id` PK, `broker_name`, `is_active` |
| `bk_brokers_central_extra_types` | Attribute names | `BK_ELECTRA_ID` (broker id in file names), `STATUS` |
| `bk_brokers_central_extra` | Attribute values | `(bk_id, extra_type_id)` PK, `extra_value`, `is_active` |

Read only by trade alerts (which brokers are `Active`, and which files belong to them). Written externally.

### 4.8 `refdata` and `userdb`

| Table | Purpose | Used by |
|---|---|---|
| `refdata.plaid_dupe` | Known duplicate Plaid transactions (`transactionid` PK) | `fn_process_trades`: matching trades → `status='DUP'`, `processed='YES'` |
| `userdb.users` | Users | only to find the **support user** (`email_address = 'support@paragondatalabs.com'`). Its `user_key` is the author of exceptions and feedback rows |

---

## 5. Value dictionaries

| Where | Values |
|---|---|
| `trade_data.status` | `PENDING`, `TRADE`, `RNR \| <reason>` (`DIVINTCAP`, `MISC`, `DRIP`, `CASHEQ`, …), `ACEX`, `INACTIVE_ACCOUNT`, `INACTIVE_CLIENT`, `DUP` |
| `holding_data.status` | `PENDING`, `TRADE`, `RNR \| <reason>` (incl. `DEMO`), `ACEX`, `INACTIVE_CLIENT`, `INACTIVE_USER`, `INACTIVE_ACCOUNT` (no `DUP`). `INACTIVE_USER`, `INACTIVE_ACCOUNT` and `RNR \| DEMO` also set `processed = 'YES'`. See `holdings-process.md` |
| `process_outcome` | security-match status; `Fail: Could Not Find Matching Security ID`; `Fail: Correct Symbol could not be extracted…`; `FAIL: Unrecognized status`; `… via Exception Mgmnt`; `Resolved Exception: …` |
| `processed` | `NO`, `YES` |
| `source` | `Direct Feed`, `Plaid`, `Manual Upload`, `eConversion` (holdings) |
| Exception `STATUS` | `New`, `Awaiting Match`, `Reviewed`, `Closed`, `Failed`, `Resolved` |
| Exception `EXCEPTION_TYPE` | `TRADE`, `HOLDING` |
| Ops resolution (`exceptions_view.resolution`) | `Matched to Factset Security`, `Not a Trade`, `New Security` |
| Feedback `STATUS` | `Pending`, `Processed` |
| `clients_v2` enums | environment `AWS`/`AZURE`; stage `LOCAL`/`DEV`/`TST`/`SAND`/`PROD`; region `eastus`/`westeurope`/`uaenorth`/`canadacentral` |

---

## 6. DB functions

| Function | Called from | Does |
|---|---|---|
| `brokerdb.fn_process_trades()` | preprocess jobs | Cleans `trade_data`, sets `status` |
| `brokerdb.fn_process_holdings()` | `full-preprocess-job`, holdings API | Same for `holding_data` (`holdings-preprocess-job` does **not** call it) |
| `brokerdb.fn_exception_mgmnt_auto_updates()` | full preprocess, step 5 | Fixes known broker data quirks on failed rows |
| `brokerdb.fn_exception_mgmnt_refresh()` | full preprocess, step 6 (flag) | Applies ops resolutions; marks exceptions `Resolved` |
| `brokerdb.fn_exception_mgmnt_new_exceptions()` | full preprocess, step 10 | Creates trade exceptions |
| `brokerdb.set_as_of_and_created_date()` | trigger on `holding_data` | Month-end `as_of_date` for Direct Feed |
| `rulesenginedb.check_client_configs_published()`, `forbid_update_if_published()` | triggers on config tables | Config publishing rules |
| `rulesenginedb.fn_migrate_config_to_azure()` | manual | Copies a client from AWS to Azure (SAND/PROD) |
| `fn_exception_mgmnt_new_exceptions_holdings`, `fn_exception_mgmnt_new_sec`, `cleanup_electra_portal` | **not called by code** | Holding exceptions, new securities, portal cleanup |

---

## 7. Notes and unknowns

- **Same-named tables in client DBs.** `bk_txn*`, `disclosures`, `attribute_extra*` and `users` also exist in every client DB with different content: delivered trades instead of exceptions, account disclosures instead of feedback. Always check which connection a query uses.
- **Production DDL of external tables is not in this repo.** This covers `exceptions_view`, `fileuploadtracker`, `bk_brokers_central*`, `broker_feedback`, `bk_txn*` and others. The seed is only an approximation.
- **Exception type ids conflict.** `fn_exception_mgmnt_refresh` hardcodes `extra_type_id` 2 and 6. Its comments imply 2 = STATUS, but the local seed has STATUS = 1 and SECURITY_ID = 6. The production ids are unknown.
- **Possible bugs** (seen in code, not tested):
  - `fn_exception_mgmnt_refresh` updates `holding_data` with a `WHERE` on `trade_data.status`, a table that isn't in its `FROM`.
  - `fn_exception_mgmnt_new_sec` calls a function that doesn't exist in the repo.
- **Loaders.** Direct Feed trades and holdings (and `fileuploadtracker`) are written by the loader task `compliance-rules-engine/tasks/loadTxnAndHoldings`, a separate app in the same git repo, last changed Sep 2024. Unknown: whether it is the current production loader, who loads Plaid / manual rows, `plaid_dupe` and `trade_process_reference`, and whether the uncalled functions are run by hand.
