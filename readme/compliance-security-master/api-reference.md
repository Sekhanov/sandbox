# API reference

Every endpoint: path, role, input, data source and output.
Real URL = `https://<host>/<NODE_ENV>/<path>`. All responses use the envelope `{ status, message, data }` (`runtime-overview.md` §4). Validation errors return **406**.

Related docs: `runtime-overview.md`, `security-lookup.md`, `search.md`, `preclear-price-volume.md`, `custom-securities-and-feedback.md`, `data-and-replication.md`.
Code: routes in `routes/`, handlers in `controllers/securityController.ts`, logic in `services/securityService.ts` unless stated. Joi schemas: `validators/securityValidator.ts`. Swagger: `swagger/securityDocs.yaml`, `swagger/customSecurities.yaml`.

---

## 1. Endpoint map

Prefix **F** = `/security-master/factset`, **F2** = `/v2/security-master/factset`.

| Method | Path | Role | DB | Purpose | Doc |
|---|---|---|---|---|---|
| GET | F`/health-check` | none | — | Liveness | — |
| POST | F`/security-lookup` | READ | RDS + ADMIN | Bulk match raw broker rows → `security_id` / `cid` | `security-lookup.md` |
| POST | F`/pre-fetch` | READ | RDS | Security + entity details for a list of ids | §2.1 |
| GET | F`/security-match` | READ | RDS | All `fsym_id`s of the same share class | §2.2 |
| POST | F`/security-match` | READ | RDS | Same, bulk (≤ 1000 ids) | §2.2 |
| GET | F`/security-preclear-match` | READ | RDS | Do two ids share a share class? | `preclear-price-volume.md` |
| GET | F`/get-preclear-expiration-date` | READ | ADMIN + RDS | Preclear expiry in business days | `preclear-price-volume.md` |
| GET | F`/security-price` | READ | RDS or Redshift | Latest price on/before a date | `preclear-price-volume.md` |
| GET | F`/security-average-daily-volume` | READ | Redshift | Average daily volume | `preclear-price-volume.md` |
| POST | F`/fetch-healthcare-sic-codes` | READ | RDS | Entity's primary SIC matches patterns? | `preclear-price-volume.md` |
| GET | F`/get-security-types` | READ | RDS | `sec_map` | §2.3 |
| GET | F`/get-entity-types` | READ | RDS | `entity_type_map` | §2.3 |
| GET | F`/get-securities-by-entity-id` | READ | RDS | Securities of a company | §2.4 |
| POST | F`/get-security-id-from-security-info` | READ | RDS | Custom security ids by type + attributes | §2.5 |
| GET | F`/security-search-by-attr` | READ | RDS | Exact lookup by CUSIP / ISIN / SEDOL / ticker / entity code | §2.6 |
| GET | F`/security-search` | READ | Redshift + RDS | Free-text security search (v1) | `search.md` |
| GET | F2`/security-search` | READ | OpenSearch | Free-text security search (v2) | `search.md` |
| GET | F`/entity-search` | READ | OpenSearch (or RDS) | Free-text company search | `search.md` |
| GET | F2`/entity-search` | READ | OpenSearch | Same, always OpenSearch | `search.md` |
| GET | F`/entity-search-by-attributes` | READ | RDS | Companies by ticker / CUSIP / ISIN | §2.7 |
| GET | F`/entity-search-by-code` | READ | Redshift | Companies by CIK / CRD / RSSD / EIN | §2.8 |
| POST | F`/get-security-info` | READ | Redshift | Full FactSet security details | §2.9 |
| GET | F`/get-security-details` | READ | Redshift | One `sym_coverage` row | §2.9 |
| POST | F`/get-entity-info` | READ | Redshift | Full FactSet entity profile | §2.10 |
| GET | F`/corp-tree-search` | READ | Redshift | Corporate tree of an entity | §2.10 |
| POST | `/security-master/central-custom/security` | READ (+WRITE, not enforced) | RDS | Create custom securities | `custom-securities-and-feedback.md` |
| DELETE | `/security-master/central-custom/security` | READ (+WRITE, not enforced) | RDS | Delete custom securities | `custom-securities-and-feedback.md` |
| POST | `/broker/broker-account/upload-feedback-in-bulk` | WRITE | ADMIN | XLSX broker feedback upload | `custom-securities-and-feedback.md` |

READ / WRITE = Keycloak client roles `SMA_READ` / `SMA_WRITE`.

Callers seen in `compliance-rules-engine` (`libs/sma/smaService.ts`): `security-lookup`, `pre-fetch`, `security-match` (GET), `fetch-healthcare-sic-codes`, `security-preclear-match`, `get-preclear-expiration-date`, `get-security-types`, `security-price`, custom-security POST/DELETE, `get-securities-by-entity-id`. Other endpoints are called by the UI or other services (inferred).

---

## 2. Endpoint details

### 2.1 `POST /pre-fetch`

Body:
```json
{ "security_ids": ["MH33D6-R", "ABC123-SS"], "entity_ids": ["000C7F-E"], "universe_type": "EQ" }
```
All optional. Empty / null ids are dropped.

Returns `{ security_info: [...], entity_info: [...] }` (both queries run in parallel).

**`security_info`** — one `UNION ALL` query on RDS over three sources, matched on the given ids:

| Source | Match | `security_id` | Notes |
|---|---|---|---|
| `all_securities` (FactSet) | `fsym_id = ANY(ids)` | `fsym_id` | `iso_country` = entity country → ISIN prefix → `'99'` |
| `security_info` (custom) | `security_id = ANY(ids)` | `security_id` | type description from `sec_map` |
| `sym_futures_root` | `root = ANY(ids)` | `root` | only when `universe_type` is empty or `FUT`; `security_type_code = 'FUTURES'`, `universe_type = 'FUT'` |

- If `universe_type` is given, the first two sources are filtered by it.
- Columns: `fsym_security_id, security_id, entity_id, all_entity_ids, security_description, ticker, currency, security_type_code, security_type, isin, cusip, bbg_ticker, bbg_id, universe_type, iso_country, is_active, sedol`.
- `all_entity_ids` = `entity_id` + every merged (old) entity id that points to it (from `sym_merged_entity_id`); `{}` if no entity.

**`entity_info`** — `utils/queries.ts:preFetchEntityInfo`:
- each input id is resolved to its current id through `sym_merged_entity_id` (old ids still work);
- joined to `entity_base_info`;
- returns `entity_id` (as sent), `current_entity_id`, `entity_name`, `country_code`, `entity_type`, `entity_type_desc`, `all_entity_ids`.
- Ids with no row in `entity_base_info` are left out.

### 2.2 `GET /security-match?security_id=` and `POST /security-match`

- GET: all `all_securities` rows whose `fsym_security_id` equals that of the input `fsym_id`. Returns `[{ security_id, fsym_security_id }]`. Input not found → `[]`.
- POST body `{ "security_ids": [..] }` (1–1000). Returns `{ "<input id>": [{ security_id, fsym_security_id }], ... }`; every input id is a key, unmatched → `[]`.
- Use: "is this trade in the same security as that holding / restriction" across listings (`-L`), regions (`-R`) and the share class (`-S`).
- Custom securities (`-SS`) and futures are not in `all_securities`, so they return `[]`.

### 2.3 `GET /get-security-types`, `GET /get-entity-types`

- Security types: `select security_type_code, universe_type, security_type_desc, security_type_long_desc from sec_map`.
- Entity types: `select entity_type_code, entity_type_desc from entity_type_map`.
- No parameters.

### 2.4 `GET /get-securities-by-entity-id?entity_id=&limit=`

- `limit` default `10000`.
- Merged entity id → resolved to the current id first.
- Returns `all_securities` rows: `security_id` (= `fsym_id`), `entity_id` (as sent), `current_entity_id`, description, ticker (`ticker_region`), currency, type, identifiers, `universe_type`, `is_active`.

### 2.5 `POST /get-security-id-from-security-info`

Searches **custom** securities (`public.security_info`).
```json
{
  "security_type_codes": ["CRYPTO"],
  "query_type": "IN",
  "additional_where": [{ "key": "ticker", "value": "BTC" }]
}
```
- `query_type`: `IN` / `NOT IN` on `upper(security_type_code)`.
- `additional_where` (≥ 1): `key` ∈ `isin, cusip, currency, sedol, ticker, security_description`; each adds `upper(<key>) = <VALUE>` (values uppercased by Joi).
- Returns `[{ security_id }]`.

### 2.6 `GET /security-search-by-attr?key=&value=&currency_code=&sec_type=`

`key` ∈ `CUSIP, ISIN, TICKER, SEDOL, CIK, CRD, RSSD, EIN`. All values lowercased by Joi.

| `key` | Query (RDS) | `value` format |
|---|---|---|
| `CIK` | `ent_entity_identifiers` type `CIK`, match on `factset_entity_id` or value without leading zeros | JSON array string, e.g. `["320193"]` |
| `CRD`, `RSSD`, `EIN` | `ent_entity_identifiers` of that type, match on entity id or value | JSON array string |
| any, `sec_type=future` | `sym_futures_root`: `TICKER` + currency → `root` and `currency`; `TICKER` only → `root` | plain |
| `CUSIP` / `ISIN` / `SEDOL` | `all_securities` by that column; optional `currency`; `sec_type` → `fref_security_type`, else excludes `FX`, `CRYPTO` | plain |
| `TICKER` | `all_securities` by `ticker` and `ticker_country` = first 2 letters of `currency_code` (default `us`), `currency is not null` | plain |

Returns entity rows (`factset_entity_id, entity_id_value`), futures roots (`*`), or `{ security_id (= fsym_security_id), fsym_security_id, security_description, security_type_code, currency, universe_type }`.

### 2.7 `GET /entity-search-by-attributes?ticker=&cusip=&isin=`

- At least one parameter. Conditions are ANDed.
- Finds `entity_id`s in `all_securities` matching the identifiers, then returns their rows from `entity_info_with_attributes`: `entity_id, legal_name, short_name, country_code, entity_type, former_name, dba_name, local_name, parent_entity_id, parent_legal_name, ultimate_parent_entity_id, ultimate_parent_legal_name`.

### 2.8 `GET /entity-search-by-code?key=&value=`

- `key` ∈ `CIK, EIN, CRD, RSSD`; `value` = JSON array string.
- Same logic as the entity branch of §2.6, but on Redshift `factsetdb2.ent_v1.ent_entity_identifiers`.

### 2.9 `POST /get-security-info`, `GET /get-security-details`

- `get-security-info` body `{ "security_ids": [...] }`: Redshift join of `sym_coverage` with CUSIP, ISIN, ticker-region, SEDOL, Bloomberg, entity and `sec_map`, only rows where `fsym_security_id = fsym_id` (i.e. `-S` ids). Returns description, entity id and name, ticker, `fsym_regional_id`, listing exchange, currency, type, identifiers, `universe_type`, `is_active`, `iso_country`.
- `get-security-details?security_id=`: one `sym_coverage` row by `fsym_id` (any grain). Returns `{}` if not found.

### 2.10 `POST /get-entity-info`, `GET /corp-tree-search`

- `get-entity-info` body `{ "entity_ids": [...] }`: large Redshift join of entity tables (address, coordinates, affiliates, market value, NAICS, changes, profiles, coverage, contacts, relationships, status). One entity can return many rows (one per joined child). Filters `hq = 1`, latest `mv_date`, `naics.rank = 1` — entities missing any of these return **no rows** (inferred from the WHERE on left-joined tables).
- `corp-tree-search?entity_id=`: all entities with the same ultimate parent as the input, from `ent_entity_structure`. Returns `factset_ultimate_parent_entity_id, factset_parent_entity_id, entity_id`.

---

## 3. Notes and unknowns

- **SQL built by string concatenation** with request values in v1 `security-search` (`input_string`) and `security-search-by-attr` (`currency_code`, `sec_type`, and `currency_code` inside `left('…',2)`). Joi only lowercases them. These are injection risks (seen in code, not tested). See `search.md` §5.
- `security-search-by-attr` futures branch with `currency_code` and a non-`TICKER` key filters on `currency_code`, a column `sym_futures_root` does not have → SQL error (inferred from the table DDL).
- `get-securities-by-entity-id` default limit is `10000`, so a large issuer returns a large payload.
- Who calls the Redshift-backed endpoints (§2.8–2.10) is not visible in this repo or in `compliance-rules-engine`.
