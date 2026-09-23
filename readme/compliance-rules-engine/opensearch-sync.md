# OpenSearch sync (`open-search-task`)

How the `open-search-task` job copies security and entity reference data from a Postgres database into AWS OpenSearch.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `security-master.md`, `runtime-overview.md`, `central-db-schema.md`.

---

## 1. Overview

- **What it does:** reads four reference tables from a separate Postgres database and writes them into two OpenSearch indices: `securities` and `entities`.
- **Load type:** always a **full reload** into a brand-new index, then an alias switch. There is no incremental mode.
- **Not the central DB, not a client DB.** The source DB has its own connection settings (`PG_*`). The code calls it "Factset RDS" in its log messages (`databases/postgres.ts`, `services/indexSyncRunner.ts`).
- **Nothing in this repo reads the indices.** The consumer is outside this repo (see section 8).

```
 Factset Postgres (PG_*)                         AWS OpenSearch (OPENSEARCH_*)
 ┌───────────────────────────┐                   ┌───────────────────────────────────────────┐
 │ public.tbl_securities     │──┐                │ securities_<yyyymmddHHMMss>  (new index)  │
 │ public.security_info      │──┼─ batches ────► │   alias "securities" switched at the end  │
 │   (EQ, FI, CRYPTO only)   │  │  of BATCH_SIZE │                                           │
 │ public.sym_futures_root   │──┘  (bulk index)  │                                           │
 │                           │                   │                                           │
 │ public.entity_base_info   │───── batches ───► │ entities_<yyyymmddHHMMss>    (new index)  │
 └───────────────────────────┘                   │   alias "entities" switched at the end    │
                                                 └───────────────────────────────────────────┘
```

Code:

| File | Role |
|---|---|
| `tasks/openSearchSync/openSearchSyncController.ts` | Entry point `initiateOpenSearchSync()`. Runs both index runners, handles rollback. |
| `tasks/openSearchSync/services/securitiesIndexRunner.ts` | Builds the `securities` index from three tables |
| `tasks/openSearchSync/services/entitiesIndexRunner.ts` | Builds the `entities` index from one table |
| `tasks/openSearchSync/services/indexSyncRunner.ts` | Shared base: keyset pagination, bulk writes, rollback |
| `tasks/openSearchSync/databases/postgres.ts` | Sequelize connection to the source DB |
| `tasks/openSearchSync/databases/opensearch.ts` | OpenSearch client: create index, bulk index, alias switch, delete |
| `tasks/openSearchSync/databases/mappings/*.ts` | Index mappings and analyzers |
| `libs/globalConstants.ts` → `openSearchSyncConfig` | All settings (section 6) |

---

## 2. What is synced

### 2.1 `securities` index (alias `OPENSEARCH_ALIAS`, default `securities`)

Three queries write into the **same** new index, in parallel (`Promise.all` in `SecuritiesIndexRunner.run()`):

| Runner method | Source table | Filter | Fields written | `table_name` | `collapse_id` |
|---|---|---|---|---|---|
| `runSecurities` | `public.tbl_securities` | none | `identity`, `security_id`, `security_description`, `security_type_code`, `universe_type`, `fref_security_type`, `fsym_regional_id`, `fsym_primary_listing_id`, `fsym_security_id`, `ticker`, `ticker_country`, `ticker_region`, `sedol`, `cusip`, `isin`, `entity_id`, `all_ticker_regions`, `all_tickers` | `tbl_securities` | `security_id` |
| `runCrypto` ("crypto and local securities") | `public.security_info` | `universe_type IN ('EQ', 'FI', 'CRYPTO')` | `identity`, `universe_type`, `security_id`, `ticker`, `security_description`, `entity_id` (= `cid`) | `security_info` | `security_id` |
| `runFutures` | `public.sym_futures_root` | none | `identity`, `ticker` (= `root`), `security_description` (= `root_name`), `universe_type` = `'FUT'`, `category`, `currency` | `sym_futures_root` | `root` |

Transforms done in SQL (there is no TS transform step):
- `all_tickers` = `all_ticker_regions` with the region suffix removed: `ARRAY(SELECT split_part(unnest(all_ticker_regions), '-', 1))`.
- Futures get a constant `universe_type = 'FUT'`.
- Each row gets `table_name` (its source table) and `collapse_id` (the value to group results by; inferred from the name: used with OpenSearch field collapsing by the consumer).

### 2.2 `entities` index (alias `OPENSEARCH_ENTITY_ALIAS`, default `entities`)

| Runner method | Source table | Fields written |
|---|---|---|
| `runEntities` | `public.entity_base_info` | `identity`, `entity_id`, `entity_name`, `country_code`, `entity_type`, `entity_type_desc`, `primary_sic_code` |

### 2.3 Document id
Every document is indexed with `_id = identity` (`opensearch.ts`, `bulkIndex`). Re-indexing the same `identity` overwrites the document.

---

## 3. Index mapping

Both mappings share the same analysis settings (`databases/mappings/*.ts`):

| Name | Type | Definition | Used for |
|---|---|---|---|
| `lowercase_normalizer` | normalizer | `lowercase` | All `keyword` fields except `identity` and `table_name`. Exact match is case-insensitive. |
| `edge_ngram_analyzer` | index analyzer | `standard` tokenizer → `lowercase` → English stop words → edge n-gram 1–15 | `security_description`, `entity_name` |
| `search_analyzer` | search analyzer | `standard` → `lowercase` → English stop words | same fields, at query time |

- Text fields (`security_description`, `entity_name`) also have a `.keyword` sub-field (lowercase, `ignore_above: 256`).
- This setup supports **prefix / type-ahead search** on names and **exact, case-insensitive** lookup on ids and tickers (inferred from the analyzers).
- Short `ignore_above` limits: `entity_id` 8, `country_code` 2, `entity_type` 3, `primary_sic_code` 8. Longer values are stored but not indexed.
- Fields not listed in the mapping (e.g. `ticker_region` in `securities`) are added by OpenSearch dynamic mapping (default behaviour; the mapping sets no `dynamic` option).

---

## 4. How a run works

`initiateOpenSearchSync()`:

1. If `JOB_TYPE` (default `initialLoad`) is not `initialLoad`: log an error and exit. Nothing else is supported.
2. Connect to the source Postgres (`authenticate()`).
3. Run the two runners **in parallel** (`Promise.allSettled`). Each runner:
   1. `ping()` OpenSearch.
   2. Create a new index `<alias>_<yyyymmddHHMMss>` (UTC, set when the connection object is created) with the mapping.
   3. Copy the table(s) in batches (section 5).
   4. Switch the alias to the new index (`updateAlias()`):

      | Alias state | Action |
      |---|---|
      | Alias does not exist (404) | Create alias → new index |
      | Alias points to index(es) | Atomic `updateAliases`: remove the **first** old index, add the new one. Then delete that old index. |
      | Alias exists with no index | Add the new index |

      If deleting the old index fails, it is only a warning plus an `alert()` ("Manual cleanup may be required"). The run still succeeds.
4. For each runner that failed: delete its new index, but only if the alias does not point to it yet (`rollBackIfNotPromoted()`). If the check itself fails, nothing is deleted.
5. One failure → rethrown. Several → `AggregateError('Multiple OpenSearch index syncs failed')`.
6. `process.exit()` on success.

Searches keep using the old index until the alias switch, so a reload has no downtime (inferred from the alias pattern).

---

## 5. Batching

`IndexSyncRunner.scrollTableAndSync()` uses **keyset pagination** on `identity`:

```sql
-- first page
<select> WHERE <extra filter> ORDER BY identity LIMIT $1
-- next pages
<select> WHERE identity > $1 AND <extra filter> ORDER BY identity LIMIT $2
```

- Batch size: `BATCH_SIZE` (default `50000`). Each batch is one OpenSearch `_bulk` request.
- The loop stops on an empty page, or when the last row has no `identity`.
- Progress is logged per batch against `SELECT COUNT(*) FROM <table>`. For `security_info` the count ignores the `universe_type` filter, so the percentage stays below 100%.
- **Local:** when `NODE_ENV = 'LOCAL'`, at most 100,000 rows per table are copied (`LOCAL_TASK_SYNC_LIMIT`), and TLS certificate checks are off.

---

## 6. Settings (env vars)

| Env var | Default | Meaning |
|---|---|---|
| `PG_HOST`, `PG_PORT`, `PG_DATABASE`, `PG_USERNAME`, `PG_PASSWORD` | `''`, `5432`, `''`, `''`, `''` | Source Postgres |
| `OPENSEARCH_PROTOCOL` | `https` | |
| `OPENSEARCH_HOST` | `''` | Host (and port) of the OpenSearch domain |
| `OPENSEARCH_USER`, `OPENSEARCH_PASSWORD` | `''` | Basic auth, put into the node URL (`<protocol>://<user>:<password>@<host>`) |
| `OPENSEARCH_ALIAS` | `securities` | Alias of the securities index; also the index name prefix |
| `OPENSEARCH_ENTITY_ALIAS` | `entities` | Alias of the entities index |
| `BATCH_SIZE` | `50000` | Rows per page / bulk request |
| `JOB_TYPE` | `initialLoad` | Only `initialLoad` is implemented |
| `NODE_ENV` | – | `LOCAL` → row limit and no TLS verification; also used in the alert subject |

- These are plain env vars. Unlike the central DB, the code does not read them from Secrets Manager or Key Vault.
- They are not in `serverless/common/createServerlessConfiguration.ts`: the job is a container task, not a Lambda.

---

## 7. How to run

- Registered in `tasks/index.ts` as job `open-search-task` (`Job.OpenSearchSync` in `tasks/Job.ts`).
- **Locally:** `npm run dev:task open-search-task` (reads `.env` via `dotenv`).
- **Deployed:** the job-executor image (`Dockerfile`, `ENTRYPOINT ["npm", "run"]`, built by `buildspec-tasks.yml`) runs `task open-search-task` → `node src/tasks/index.js open-search-task` (inferred from the `task` script and entrypoint).
- Schedule (cron) and the task definition are not in this repo.

---

## 8. Who uses the indices

- **No code in this repo queries OpenSearch.** `@opensearch-project/opensearch` is only imported by `tasks/openSearchSync/`.
- The SMA client (`libs/sma`, see `security-master.md`) calls HTTP endpoints only. Which of them, if any, are backed by these indices is not visible here.
- `project.md` describes OpenSearch as a "search index synced from PostgreSQL". It does not name a consumer.
- Likely use (inferred from the edge n-gram analyzers, `collapse_id` and the field set): security and company type-ahead search, e.g. when an employee picks a security in a disclosure or an ops user resolves an exception. Not verified.

---

## 9. Failure handling

| Failure | Effect |
|---|---|
| Source DB unreachable | `connect()` throws → job fails → `tasks/index.ts` sends `alert()` with the job name and exits `1` |
| One runner throws (OpenSearch down, query error, …) | Its new index is deleted if not promoted. The other runner still finishes and may switch its alias. Then the job fails and alerts as above. |
| Old index cannot be deleted after the switch | Warning + `alert()` "OpenSearch Sync \| <NODE_ENV>"; job still succeeds |
| `JOB_TYPE` not `initialLoad` | Error log only. No alert, exit code `0`. |
| Some documents rejected inside a `_bulk` request | **Not detected.** The bulk response is not checked for `errors`, so the alias is switched to an incomplete index. |

Alert delivery (Slack or SNS) is described in `trade-alerts.md`, section 2.

---

## 10. Notes and unknowns

- **Risks found in code:**
  - `databases/opensearch.ts:43`: `bulkIndex` returns the bulk response without checking `errors`. Rejected documents are lost silently.
  - `services/securitiesIndexRunner.ts:19-23`: three tables share one index with `_id = identity`. If `identity` values overlap across `tbl_securities`, `security_info` and `sym_futures_root`, documents overwrite each other. The type and uniqueness of `identity` are not visible here.
  - `services/securitiesIndexRunner.ts:19`: `Promise.all` rejects on the first error, but the other two queries keep writing. The rollback can then delete the index while they are still writing to it.
  - `databases/opensearch.ts:64`: only the first index under the alias is removed. If the alias points to more than one index, the others stay in the alias.
  - `openSearchSyncController.ts:51`: an invalid `JOB_TYPE` exits successfully.
- **Unknown:**
  - who owns and loads the source DB tables (`tbl_securities`, `security_info`, `sym_futures_root`, `entity_base_info`), and how fresh they are
  - who queries the indices
  - the schedule, and whether the job runs in every region / on Azure (the code has no `APP_ENV` check)
  - the type of `identity` in each table (the cursor compares it as `>`, so it must be sortable)
