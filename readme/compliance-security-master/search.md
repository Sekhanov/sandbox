# Security and entity search

Free-text search for type-ahead UIs. Two generations exist side by side:

| Endpoint | Engine | Code |
|---|---|---|
| `GET /security-master/factset/security-search` (v1) | SQL: Redshift `refdata.public.tbl_securities` + RDS | `services/securityService.ts:securitySearchMv` |
| `GET /v2/security-master/factset/security-search` | OpenSearch, index `OS_INDEX_NAME` | `services/securitySearchService.ts`, `config/opensearch.ts` |
| `GET /security-master/factset/entity-search` | OpenSearch (default) or SQL on RDS (`LEGACY_ENTITY_SEARCH=true`) | `controllers/securityController.ts:entitySearch` |
| `GET /v2/security-master/factset/entity-search` | OpenSearch, index `OS_ENTITY_INDEX_NAME` | `services/entitySearchService.ts` |

The OpenSearch indexes are filled by the `compliance-rules-engine` sync job (`../compliance-rules-engine/opensearch-sync.md`). Index mappings are not in this repo.

Related docs: `api-reference.md`, `data-and-replication.md`.

---

## 1. Security search v2 (OpenSearch)

### Input
| Param | Rule |
|---|---|
| `input_string` | required, lowercased, ≤ 100 chars, then trimmed |
| `security_type` | 0..n of `SHARE`, `ETF`, `DR`, `MF`, `PRIV` (single value or repeated param) |
| `universe_type` | 0..n of `EQ`, `FI`, `FUT`, `CRYPTO`, `FX`, `OTH` |
| `debug` | bool; adds `__debug.score` only when `NODE_ENV = dev` |

### Query
- **Filters** (must match):
  - `universe_type` ∈ given list;
  - `fref_security_type` ∈ mapped list:

    | `security_type` | `fref_security_type` |
    |---|---|
    | `SHARE` | `SHARE`, `PREF`, `PREFEQ`, `WARRANT` |
    | `ETF` | `ETF_ETF`, `ETF_UVI`, `ETF_NAV` |
    | `DR` | `ADR`, `NVDR`, `GDR` |
    | `MF` | `MF_O`, `MF_C` |
    | `PRIV` | `PRIV` |

- **Scoring clauses** (any may match):

  | Condition on input | Clause | Score |
  |---|---|---|
  | no space, exactly one `-` (e.g. `aapl-us`) | term `all_ticker_regions` | 200 |
  | no space, no `-` | term `ticker` | 100 |
  | no space, no `-` | term `all_tickers` | 50 |
  | no space, no `-`, length 7 / 9 / 12 | term `sedol` / `cusip` / `isin` | relevance |
  | length ≥ 3 | term `security_description.keyword` | relevance |
  | length ≥ 3 | match `security_description` | relevance |
  | length ≥ 3 | prefix `security_description.keyword` | 50 |

- `function_score`: US tickers (`ticker_country = 'us'`) get weight **1.5** (multiplied).
- `collapse` on `collapse_id` (one hit per group; grouping defined by the indexer).
- Sort: score desc, then `security_description.keyword` asc. Size `OS_LIMIT` (100).

### Output
`security_id, entity_id, security_description, security_type_code, universe_type, cusip, isin, sedol, ticker, ticker_country, fref_security_type, category, currency, all_ticker_regions`.

---

## 2. Security search v1 (SQL)

### Input
`input_string` (required, lowercased), `security_type` ∈ `SHARE, ETF, DR, MF, PRIV, OTH, *`, `universe_type` ∈ `EQ, FI, FUT, CRYPTO`.

### Flow
1. **`FUT`**: input < 3 chars → `[]`. Else Redshift `factsetdb1.sym_v1.sym_futures_root` where `root = input` or `root_name ILIKE %input%`.
2. **`CRYPTO`**: input < 3 chars → `[]`. Else RDS `security_info` + `sec_map` by ticker or description.
3. **Other** (`EQ`, `FI`, empty): Redshift `refdata.public.tbl_securities`, `active_flag = 1`, plus:
   - `FI` → `universe_type = 'FI'`;
   - else → optional `universe_type` filter, exclude types `ALIEN, RIGHT, STRUCT, UNIT, WARRANT, TEMP, DR`, and a `security_type` filter (`SHARE` → `SHARE, PREF, PREFEQ`; `ETF` → `ETF_*`; `DR` → `ADR, NVDR, DR, GDR`; `MF` → `MF_O, MF_C`; `OTH` → `ALIEN, RIGHT, …`; `PRIV` → `PRIV`).
   - Text condition by input length:

     | Length | Matches on |
     |---|---|
     | < 3 | ticker exact |
     | 7 | description `LIKE %x%`, ticker exact, SEDOL exact |
     | 9 | description, ticker, CUSIP |
     | 12 | description, ticker, ISIN |
     | other | description, ticker |

Steps 4–5 apply only to case 3 (`FUT` and `CRYPTO` return before them).

4. **Custom securities first:** RDS `security_info` rows where ticker / ISIN / SEDOL / CUSIP = input and `universe_type` = given (default `EQ`). These rows are put at the top unchanged.
5. **Post-processing** of the FactSet rows:
   1. ignore a leading `"the "` when sorting;
   2. exact description match first, then prefix matches, then the rest, each alphabetical;
   3. `EQ`: drop `universe_type = 'OTH'`;
   4. exact identifier matches (ticker, plus SEDOL/CUSIP/ISIN by length) go first, US tickers first among them;
   5. **if any row's ticker equals the input, return only that row**; otherwise strip `ticker` / `ticker_country` and de-duplicate;
   6. de-duplicate by description + universe + type.
6. Controller returns the first **100** rows.

---

## 3. Entity search

### Input (both versions)
`input_string` (required, lowercased); `entity_type` and `entity_type_order` — 0..n FactSet entity type codes (`PUB`, `PVT`, `SUB`, `HOL`, `MUT`, … 41 codes in `validators/securityValidator.ts`).

### v2 / default (OpenSearch)
- Input trimmed; < 3 chars → `[]`.
- Filter: `entity_type` ∈ list (lowercased).
- Scoring: exact `entity_name.keyword` (100), prefix `entity_name.keyword` (50), `match entity_name` with all words (1). At least one must match.
- Sort: position in `entity_type_order` (types not listed last), then score, then name.
- Size `OS_LIMIT`. Output: `entity_id, entity_name, country_code, entity_type, entity_type_desc`.

### Legacy (`LEGACY_ENTITY_SEARCH=true`, `/entity-search` only)
- RDS `entity_base_info`, input trimmed; < 4 chars → `[]`.
- `lower(entity_name) LIKE %input%` (trigram index `entity_base_info_name_trgm_idx_lower`), optional `entity_type = ANY(...)`.
- Order: `entity_type_order` position, exact name, prefix, name. Leading `"the "` removed from the returned name. Limit 100.

---

## 4. What uses which

- `/entity-search` and `/v2/entity-search` return the same results unless `LEGACY_ENTITY_SEARCH=true`.
- v1 security search still reads Redshift for every non-crypto query. RDS has a `tbl_securities` copy (`queries/pg_refresh_tbl_securities.sql`), but v1 does not use it.
- Which UI uses v1 or v2 is not visible in this repo.

---

## 5. Notes and unknowns

- **SQL injection risk (v1):** `input_string` is pasted into SQL text (`LIKE '%${input_string}%'`, `= '${input_string}'`) for the Redshift and crypto queries. Joi only lowercases it. A `'` breaks the query; crafted input could change it (seen in code, not tested).
- **v1 crypto query precedence:** `universe_type = 'CRYPTO' and lower(ticker) = x OR description ilike %x%` — the `OR` is not bracketed, so description matches of any universe (e.g. FX) are returned.
- **v1 `security_type=OTH`** adds `IN ('ALIEN', …)` on top of `NOT IN ('ALIEN', …)` → always empty. `universe_type` `FX` / `OTH` branches in code are unreachable (Joi rejects them).
- **v1 `security_type=DR`** includes `DR`, which the base filter excludes, so only `ADR`, `NVDR`, `GDR` come back.
- **v2 short input with a space** (e.g. `"a b"`) or with more than one `-` adds no scoring clause. An empty `should` inside `must` matches every document, so the top 100 by sort are returned (inferred from OpenSearch semantics).
- **v2 term queries** use the lowercased input on `ticker`, `isin`, etc. This works only if the index stores those fields lowercased (inferred; mapping not in repo).
- OpenSearch client uses `ssl.rejectUnauthorized: false` (`config/opensearch.ts`).
