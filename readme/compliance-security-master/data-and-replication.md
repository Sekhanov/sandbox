# Data stores and replication

Which tables the service reads, where they come from, and how FactSet data is copied from Redshift into RDS.
SQL: `queries/` (deployed by hand to RDS / Redshift; not run by the Node app).

Related docs: `runtime-overview.md` §5, `api-reference.md`, `security-lookup.md`.

---

## 1. Overview

```
 Redshift (FactSet, full data)                         RDS PostgreSQL (SMA)
 factsetdb1.sym_v1 / ent_v1 / ref_v2 / fgp_v1          pg_cron jobs call plpgsql functions that
 factsetdb2.sym_v1 / ent_v1                            pull from Redshift over dblink('foreign_server', …)
 refdata.public (sec_map, entity_info, tbl_securities)
            │                                                    │
            └──────────── dblink (nightly) ─────────────────────►│ all_securities, historical_*, sym_merged_entity_id,
                                                                 │ entity_base_info, entity_info_with_attributes,
                                                                 │ ent_entity_identifiers, sym_futures_root,
                                                                 │ security_prices, ref_calendar_holidays, sec_map,
                                                                 │ entity_type_map, country_map, tbl_securities
                                                                 │
                                       SMA writes only ───────►  │ security_info (custom securities)
```

- Moving reads from Redshift to RDS was done step by step (commits for price, preclear expiration, SIC, pre-fetch, lookup). Some endpoints still read Redshift (`api-reference.md` §1).
- `dblink` server name: `foreign_server`. Its definition (host, user) is not in the repo.

---

## 2. RDS tables used by the service

| Table | Source (Redshift) | Refresh function | Used by |
|---|---|---|---|
| `all_securities` | `sym_coverage` + ticker-region, SEDOL, CUSIP, ISIN, BBG, sec-entity, entity, `sec_map` | `refresh_all_securities()` (procedure, §4) | lookup, pre-fetch, match, preclear match, price, by-entity, search-by-attr, entity-by-attributes |
| `historical_isins` / `_cusips` / `_sedols` | `sym_*_hist` minus identifiers still current | `refresh_historical_identifiers()` (called by §4) | lookup (historical matchers) |
| `sym_merged_entity_id` | `sym_merged_entity_id` | `refresh_sym_merged_entity_id()` (called by §4) | pre-fetch, by-entity, SIC check |
| `entity_base_info` | `ent_entity_coverage` + `entity_type_map` + `sym_entity_sector` ∪ `refdata.public.entity_info` | `refresh_entity_base_info()` | pre-fetch, legacy entity search, SIC check |
| `entity_info_with_attributes` | `ent_entity_names` (legal, short, former, DBA, local) + parents | `refresh_entity_info_with_attributes()` | entity-search-by-attributes |
| `ent_entity_identifiers` | `factsetdb2.ent_v1.ent_entity_identifiers` | `refresh_ent_entity_identifiers()` | lookup (entity matchers), search-by-attr |
| `sym_futures_root` | `sym_futures_root` | `refresh_sym_futures_root()` | lookup (futures), pre-fetch, search-by-attr |
| `security_prices` | `fgp_global_prices`, latest 37 rows per (`fsym_id`, currency) | `refresh_security_prices()` | price (recent dates) |
| `ref_calendar_holidays` | `ref_v2.ref_calendar_holidays` | `refresh_ref_calendar_holidays()` | preclear expiration |
| `sec_map` | `refdata.public.sec_map` | `refresh_sec_map()` | security types, custom-security validation, pre-fetch |
| `entity_type_map` | `ref_v2.entity_type_map` | `refresh_entity_type_map()` | entity types |
| `country_map` | `ref_v2.country_map` | `refresh_country_map()` | not used by current code |
| `tbl_securities` | `sym_coverage` etc. | `refresh_tbl_securities()` | not used by current code (v1 search reads the Redshift copy) |
| `security_info` | — (SMA writes) | — | custom securities |

ADMIN DB tables read: `rulesenginedb.trade_configs_v2`, `rulesenginedb.clients_v2`, `brokerdb.trade_process_symbol_map`, `clients`, `brokerdb.account_data`, `disclosures`. Written: `brokerdb.broker_feedback_upload`, `disclosures`, `attribute_extra`.

### `all_securities` key columns
`fsym_id` (any grain), `fsym_security_id` (`-S`), `fsym_regional_id`, `security_description`, `universe_type`, `fref_security_type`, `currency`, `active_flag`, `ticker_region`, `ticker`, `ticker_country`, `sedol`, `cusip`, `isin`, `bbg_ticker`, `bbg_id`, `entity_id`, `entity_iso_country`, `entity_name`, `security_type_code`, `security_type_desc`, `key_hash`.
Indexes: unique `key_hash`; `(fsym_id, universe_type)`; `fsym_security_id`; `entity_id`; `lower(isin|cusip|sedol|ticker)` combined with currency / type / country (`queries/cor_10671_rds_migration.sql`).
Size: ~98.7 M rows (comment in `pg_refresh_all_securities.sql`).

---

## 3. Refresh patterns

| Pattern | Functions | How |
|---|---|---|
| **Truncate + reload** | `sec_map`, `country_map`, `entity_type_map`, `sym_futures_root`, `tbl_securities`, `historical_*` | `TRUNCATE`, `INSERT … FROM dblink(…)`, in one function call (one transaction). `TRUNCATE` holds an exclusive lock until commit, so queries on the table wait during the load (inferred from PostgreSQL locking). |
| **Build + swap** | `ent_entity_identifiers`, `entity_base_info`, `entity_info_with_attributes`, `security_prices`, `ref_calendar_holidays`, `sym_merged_entity_id` | load `new_<t>`, build indexes, rename live → `old_<t>`, `new_<t>` → `<t>`, drop old. `ref_calendar_holidays` aborts if the source returns 0 rows. |
| **Delta merge** | `all_securities` | §4 |

`security_prices` keeps the latest **37** rows per (`fsym_id`, currency): 7-day RDS routing window + 30-day price look-back (`preclear-price-volume.md` §3).

---

## 4. `refresh_all_securities()` — delta merge

File `queries/pg_refresh_all_securities.sql`. Plain full reloads of ~98.7 M rows saturated RDS (502s, 9 h runs), so the diff is done on Redshift and only the delta is applied on RDS.

1. **Build snapshot on Redshift:** `refdata.public.all_securities_new` (`CREATE TABLE AS`, `DISTKEY/SORTKEY key_hash`) with
   - `key_hash` = MD5 of 10 identity columns (`currency, cusip, entity_id, fref_security_type, fsym_id, fsym_security_id, isin, sedol, ticker_country, ticker`);
   - `payload_hash` = MD5 of the other columns.
2. **Guards** (one remote query): `key_hash` must be unique (**RF001**); new row count ≥ 90 % of the last published snapshot (**RF002**, truncated FactSet pull).
3. **Diff on Redshift:** `all_securities_delta_upsert` (new or changed `payload_hash`), `all_securities_delta_delete` (keys gone).
4. **Guards:** upsert delta ≤ 50 % of live (**RF003**, published snapshot missing), delete delta ≤ 50 % of live (**RF004**, mass delete).
5. **Apply on RDS:** pull only the delta into temp tables; `UPSERT` on `key_hash`; call `refresh_sym_merged_entity_id()`; `DELETE` by `key_hash`. Commits between steps.
6. **Promote** on Redshift: `all_securities_published` = this snapshot, only after a clean apply; analyze; clean up.
7. Call `refresh_historical_identifiers()`.

- Each step logs `RAISE NOTICE` with timings.
- Errors raise SQLSTATE `RF001`–`RF004`; monitoring can branch on the code.
- One-time setup: `cor_10671_redshift_migration.sql`, then `cor_10671_rds_migration.sql` (maintenance window, `pg_cron` job 18 paused).

---

## 5. Schedule (`queries/pg_cron_schedule.sql`)

A dump of the `pg_cron` jobs (database `postgres`). Times are UTC (pg_cron default, inferred).

| Job | Time | Command | Active |
|---|---|---|---|
| `daily_refresh_securities` | 03:00 | `refresh_tbl_securities()` | yes |
| `daily_refresh_security_info` | 03:20 | `refresh_security_info()` | **no** |
| `daily_refresh_sym_futures_root` | 03:25 | `refresh_sym_futures_root()` | yes |
| `daily_refresh_entity_identifiers` | 04:15 | `refresh_ent_entity_identifiers()` | yes |
| `refresh_entity_info_with_attributes` | 04:20 | `refresh_entity_info_with_attributes()` | yes |
| `refresh_entity_base_info` | 04:25 | `refresh_entity_base_info()` | yes |
| `daily_refresh_all_securities` | 05:00 | `CALL refresh_all_securities()` | yes |
| `daily_refresh_securities_2` | 12:53 | `refresh_tbl_securities_2()` | **no** |

Not in the dump (schedule unknown): `refresh_security_prices`, `refresh_ref_calendar_holidays`, `refresh_sec_map`, `refresh_entity_type_map`, `refresh_country_map`.

---

## 6. Usage tracking

`queries/redshift_query_history.sql` groups Redshift `sys_query_history` by the `-- QueryName:<NAME>` tag (or by text patterns for old untagged queries) to show which SMA queries cost the most.

---

## 7. Notes and unknowns

- The file dump may not match production `pg_cron` (job ids, extra jobs). Check `cron.job` on the RDS instance.
- `refresh_security_info()` and `refresh_tbl_securities_2()` are scheduled (inactive) but not in the repo.
- `entity_base_info` mixes FactSet entities with `refdata.public.entity_info` rows (`cid` of non-FactSet entities); where `refdata.public.entity_info` is filled is not in this repo.
- If `refresh_all_securities()` fails a guard, RDS keeps the previous data; nothing alerts from inside SMA. Alerting on the job is not in the repo.
- Data freshness: FactSet → Redshift load times are not in the repo; RDS is at best one day behind Redshift.
