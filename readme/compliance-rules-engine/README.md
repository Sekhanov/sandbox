# compliance-rules-engine docs

Index of the docs for the `compliance-rules-engine` service (`lambdas/rules-engine-3.0`), plus the terms they all share.

Paths in every doc are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`, unless stated otherwise.
In these docs, **"this repo" / "this service"** means `lambdas/rules-engine-3.0`. Other apps in the same git repo, such as `tasks/loadTxnAndHoldings` and `lambdas/utilities`, are named explicitly.

---

## 1. What the service does

1. **Takes in** employee trades and holdings that are already loaded into the central DB (from broker files, Plaid and manual uploads).
2. **Cleans and matches** them to securities. Rows it can't match become **exceptions** for the ops team.
3. **Checks trades** against each client's compliance rules (preclearance, restrictions, …) and copies trades and holdings into the client's own DB.
4. **Decides preclearance requests** (Approved / Denied / In Review) through the rules engine API.
5. **Keeps accounts and broker feedback** in sync between the central DB and the client DBs.
6. **Reports** on all of this through Slack alerts.

---

## 2. The docs

| Doc | Read it for |
|---|---|
| `runtime-overview.md` | **Start here.** Every Lambda, job and route; build and deploy; AWS vs Azure; env vars; local dev and tests |
| **Pipelines** | |
| `trade-process.md` | How a trade goes from `brokerdb.trade_data` through preprocess and the compliance rules to the client `bk_txn`, explained through the SQL |
| `holdings-process.md` | The same for holdings: `holding_data` → client `bk_holdings`, with Active/Inactive status |
| `exceptions.md` | The life of an exception: creation, auto-fix, resolve API, status sync |
| `accounts-and-feedback.md` | Account load (client `account_view` → central `account_data`) and broker feedback |
| `preclear-rules-engine.md` | How a preclearance request gets a decision; every rule explained |
| **Monitoring** | |
| `trade-alerts.md` | The three daily Slack messages: broker file freshness, stuck trades, trades delivered |
| **Data and config** | |
| `central-db-schema.md` | The database shared by all clients: schemas, tables, functions |
| `client-db-schema.md` | Each client's own database, as this service uses it |
| `client-config.md` | `rulesenginedb.clients_v2`, versioned rule configs, onboarding, changing a config |
| **Integrations** | |
| `security-master.md` | How the service calls the security master (SMA) |
| `opensearch-sync.md` | The job that copies securities and entities into OpenSearch |

Suggested reading order for a new developer: `runtime-overview.md`, then `trade-process.md`, `central-db-schema.md`, `client-config.md`, and then the doc for your area.

---

## 3. Shared glossary

| Term | Meaning |
|---|---|
| **Client** | A company using the compliance product (e.g. `SAND`). It has one row in `rulesenginedb.clients_v2` and its own client DB. In SQL: `pdl_client_code`. |
| **Employee account** | A brokerage account of a client's employee. In SQL: `pdl_account_code` = `brokerdb.account_data.account_id` = client `account_view.account_id`. |
| **Broker** | The bank or brokerage holding the account (e.g. `GPB`). Listed in `public.bk_brokers_central*`. |
| **Broker file** | The file of trades (`…_TRN`) or holdings (`…_HLD`) a broker sends to Electra over SFTP. The loader task `compliance-rules-engine/tasks/loadTxnAndHoldings` copies it from S3 into the central DB. This service only sees the resulting rows and file name. |
| **Central DB** | The PostgreSQL database shared by all clients: `rulesenginedb` (configs), `brokerdb` (incoming trades and holdings), `public` (exceptions, feedback). |
| **Client DB** | A separate PostgreSQL database per client, owned by the client app: disclosures, accounts, and delivered trades (`bk_txn`) and holdings (`bk_holdings`). |
| **Trade / holding** | One row in `brokerdb.trade_data` / `brokerdb.holding_data`. |
| **`status`** | What a trade or holding is: `PENDING`, `TRADE` (matched), `RNR \| <reason>` (not a real trade), `ACEX` (unknown account), `INACTIVE_*`, `DUP`. |
| **`processed`** | Whether the service is done with the row: `'NO'` → `'YES'`. `loaded = true` means the row reached the client DB. |
| **Security / SMA** | The traded instrument. SMA is the security master service that matching calls. |
| **Exception** | A trade or holding that couldn't be matched automatically. Stored in central `public.bk_txn*` with id `'XJ69' \|\| trade_id`. |
| **Disclosure** | A record in the client DB: account, preclearance request, restriction, gift. Header in `disclosures`, values in `attribute_extra`. |
| **Preclearance** | An employee's request to trade, decided by the rules engine and later matched to the real trade. |
| **EAV ("extra" tables)** | Key/value storage: `*_types` names the attribute, `*_extra` holds the value, and `is_active = true` marks the current value. |
| **Job** | A background task run as a container (e.g. `trade-process-job`). See `runtime-overview.md`. |

---

## 4. Conventions in these docs

- **Writing style:** "central DB" and "client DB" in lowercase.
- **Settings:** client settings are written as DB paths, e.g. `tasks_config.tradeProcess.tradeStatus`. Env vars are written by their real name, e.g. `CHUNK_SIZE`.
- **"(inferred)"** marks a statement concluded from code behaviour but not confirmed. Each doc ends with **"Notes and unknowns"**.
- **Sources:** facts come from reading the code. Nothing was run. Production table definitions, schedules and deployed env values are not in the repo.
- **Bugs and risks** that docs mention are seen in code and not tested.
