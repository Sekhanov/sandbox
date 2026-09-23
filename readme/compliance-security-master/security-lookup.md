# Security lookup (bulk matching)

How `POST /security-master/factset/security-lookup` turns raw broker rows into a FactSet `security_id` and company `cid`.
Code: `services/securityLookup/` (pipeline in `bulk/index.ts`, matchers in `bulk/matchers/`), loaders in `storage/rds/`.

Related docs: `api-reference.md`, `data-and-replication.md`, `../compliance-rules-engine/security-master.md` §4 (the caller side).

---

## 1. Request and response

```http
POST /dev/security-master/factset/security-lookup?debug=true
{ "data": [
    { "universe_type": "EQ", "isin": "US0378331005", "ticker": "AAPL", "currency_code": "USD" },
    { "universe_type": "OPTIONS", "broker_code": "GPB", "ticker": "2AAPL 240621C00190000", "currency_code": "USD" },
    { "universe_type": "FUTURES", "broker_code": "VERI", "ticker": "ESZ4", "currency_code": "USD" }
] }
```

- Query: `debug` (bool, default false). `mode` (`rds`/`redshift`) is accepted and ignored — lookup always uses RDS.
- Body check: `data` must be an array of objects. Each item is validated later, one by one.
- Response `data` = one entry per input item, **in input order**:

```json
{ "security_id": "MH33D6-S", "cid": "000C7F-E",
  "status": "Success: Found single equity security in FactSet by isin",
  "payload": { ...validated input item... } }
```

- `payload` is the item **after** Joi validation (e.g. `identifier` trimmed). The rules engine maps answers back by `JSON.stringify(payload)` (see the rules-engine doc).
- `security_id` / `cid` are missing when not found. `cid` is also missing for custom securities (`NOENTITY`).

### Item fields per `universe_type` (`validators/securityValidator.ts`)

| `universe_type` | Required | Optional |
|---|---|---|
| `EQ` | — | `isin`, `cusip`, `sedol`, `ticker`, `ticker_country`, `currency_code`, `security_name`, `identifier` |
| `OPTIONS` | — | `ticker`, `ticker_country`, `currency_code`, `broker_code`, `identifier`, `security_name` |
| `FUTURES` | `ticker`, `currency_code` | `broker_code`, `description`, `security_name` |
| `FX` | `currency_code` | `ticker`, `security_name` |
| `CRYPTO` | `ticker` | `security_name` |
| `*` | — | all EQ fields + `broker_code`, `crd`, `cik`, `rssd`, `ein`, `lei`, `jcn`, `ukch` |

Unknown fields make the item **invalid**.

---

## 2. Item status

| Internal status | `status` text in response | Final? |
|---|---|---|
| `invalid` | `Validation Failed: <joi messages>` | yes |
| `pending` | `Not Enough Data` — no matcher could build a key | — |
| `non_matched` | `Security Not Found` — a matcher tried and found nothing | no, later matchers still try |
| `matched` | `Success: Found single <universe> security in <source> by <keys>` | yes |
| `ambiguous` | `Warning: Found multiple <universe> securities in <source> by <keys>` | yes — `security_id` = first of the set (order not defined) |

`<source>` = `FactSet`, `FactSet (historical)` or `security info` (custom securities).

---

## 3. Pipeline

```
validate items ──► for each matcher, in fixed order:
                     1. take items not yet matched / ambiguous / invalid
                     2. keep items whose universe_type = matcher's, or '*'
                     3. build the compound key from the item; no key → skip item
                     4. de-duplicate by key
                     5. load candidates from RDS in chunks of 500 (IN (...))
                     6. build the same key from each loaded row
                     7. key → set of ids:  0 = non_matched, 1 = matched, >1 = ambiguous
                 ──► map to response (+ debug stats)
```

- First match wins: once an item is `matched` or `ambiguous`, later matchers skip it.
- A matcher that throws is logged and skipped; its items keep their previous status.
- Matchers run one after another (no parallelism).

### Matcher order (`bulk/index.ts:buildMatchersPipeline`)

| # | Universe | Matcher | Source table (RDS) | Key |
|---|---|---|---|---|
| 1–3 | EQ | FactSet → historical → custom | `all_securities` → `historical_isins` → `security_info` | `isin` |
| 4–6 | EQ | same three | `all_securities` → `historical_cusips` → `security_info` | `cusip` |
| 7 | EQ | FactSet by key + currency | `all_securities` | `ticker` + `ticker_country` |
| 8 | EQ | FactSet by key + currency | `all_securities` | `ticker` + `currency_code` |
| 9 | EQ | custom by key + currency | `security_info` | `ticker` + `currency_code` |
| 10–12 | EQ | FactSet → historical → custom | `all_securities` → `historical_sedols` → `security_info` | `sedol` |
| 13 | EQ | FactSet, translated ticker | translation map → `all_securities` | `ticker` |
| 14 | EQ | custom, translated ticker | translation map → `security_info` | `ticker` |
| 15 | EQ | custom | `security_info` | `security_name` |
| 16–18 | FUTURES | futures root + currency | `sym_futures_root` | `security_name` / `description` / `ticker` + `currency_code` |
| 19–21 | FUTURES | futures, translated | translation map → `sym_futures_root` | `security_name` / `description` / `ticker` |
| 22 | OPTIONS | FactSet by key + currency | `all_securities` | `ticker` + `ticker_country` |
| 23 | OPTIONS | custom by key + currency | `security_info` | `ticker` + `currency_code` |
| 24–25 | OPTIONS | translated (FactSet, custom) | translation map → … | `ticker` |
| 26 | OPTIONS | custom | `security_info` | `security_name` |
| 27–28 | FX | custom | `security_info` (type `fx`) | `ticker`, then `security_name` |
| 29–31 | CRYPTO | custom; translated; custom | `security_info` (type `crypto`) | `ticker`, translated `ticker`, `security_name` |
| 32–38 | EQ | FactSet entity | `ent_entity_identifiers` | `lei`, `crd`, `cik`, `ein`, `rssd`, `ukch`, `jcn` |

- Items with `universe_type: '*'` go through **every** matcher, including FUTURES and CRYPTO ones.
- Entity matchers (32–38) return only `cid`, no `security_id`.
- Matchers 1–14 / 22–26 return the share-class id (`fsym_security_id`, `-S`) from FactSet, or the custom `security_id` (`-SS`) from `security_info`. Futures return the root as stored in `sym_futures_root.root` (e.g. `ES`).

---

## 4. Building keys from the input (`RawSecurity.ts`)

All values are trimmed and **lowercased**, except `lei`, `jcn`, `ukch` (uppercased). Empty → no key → the matcher skips the item.

| Field | Rule |
|---|---|
| `isin` / `cusip` / `sedol` | the field; if empty, `identifier` when its length is 12 / 9 / 7 |
| `ticker_country` (EQ, OPTIONS) | the field; else first 2 letters of `currency_code`; **no key** if currency is empty or `EUR` |
| `ticker` (OPTIONS) | underlying symbol extracted by broker rules (below) |
| `ticker` (FUTURES) | `VERI`: drop the last 2 chars (month + year code); else as is |
| `security_name` / `description` (FUTURES) | only `IVB`: second word; other brokers → no key |
| everything else | the field as is |

### Option underlying symbol (`options.ts`)

| `broker_code` | Symbol |
|---|---|
| empty | `ticker`, part before `/` |
| `OPC`, `FU3` | first word of `identifier` (or `ticker` if identifier has no space) |
| `VERI`, `RBH`, `JPP` | first word of `security_name` |
| `PER`, `LPL`, `JFR`, `MLE`, `TDF` | `ticker` as is |
| `IVB`, `UBR`, `MSL`, `MSL-ETR`, `GPB`, `TDR`, `CSC` | first word of `ticker`; `GPB` also drops a leading `2` |
| `RMJ`, `VGD`, `PLAID` | `ticker` before the `YYMMDD` + `C`/`P` part (OCC style); none → no key |
| `FIR` | text inside the last `( )` of `security_name`; no brackets → `ticker` |
| other | no key (logged) |

---

## 5. Loading candidates (`storage/rds/`)

All loaders: `SELECT DISTINCT`, `lower(column) IN (chunk of 500)`, run on RDS.

| Loader | Table | Extra filter |
|---|---|---|
| `loadFactSetSecuritiesByKey` | `all_securities` | — |
| `loadFactSetSecuritiesByKeyAndCurrency` | `all_securities` | key `ticker`: `lower(ticker_country) = first 2 letters of the currency key`; other keys: `lower(currency) = currency key`. Items are grouped by currency first. |
| `loadHistoricalByKey` | `historical_isins` / `_cusips` / `_sedols` | — |
| `loadSecuritiesInfoByKey` | `security_info` | `security_type_code`: `= 'fx'` (FX), `= 'crypto'` (CRYPTO), else `NOT IN ('crypto','fx')` |
| `loadSecuritiesInfoByKeyAndCurrency` | `security_info` | same type filter + `lower(currency) = currency` |
| `loadFactsetFuturesByKeyAndCurrency` | `sym_futures_root` | `lower(root) IN …` and `lower(currency) = currency` |
| `loadFactSetEntityIdentifiersByKey` | `ent_entity_identifiers` | `entity_id_type = upper(key)`, `entity_id_value IN …` (no `lower()`) |

The loaded row must produce the **same key** as the input. Example: matcher 8 (`ticker` + `currency_code`) needs the FactSet row's ticker **and** its `currency` to equal the input; the SQL already limits `ticker_country` to the first 2 letters of that currency.

### Translated tickers (`bulk/translate.ts`)

1. Load `brokerdb.trade_process_symbol_map` from the **ADMIN DB** (`broker_value, factset_value, currency, sec_type`), cached in memory for 5 min.
2. Find the row where `lower(broker_value)` = input ticker and `sec_type` = `eq` (EQ, OPTIONS), `future`, `crypto` or `fx`.
3. Query by `factset_value` + the map's `currency`.
4. Map loaded rows back to the original broker ticker, so the key matches.

---

## 6. Debug output (`?debug=true`)

- Per item `__debug`: `keys` (the key built by each matcher that saw the item), and `allMatchedSecurities` when ambiguous.
- Top-level `__debug`:
  - `total`: counts and % of `matched`, `ambiguous`, `non_matched`, `pending`, `invalid`;
  - `matchers.<matcherKey>`: class, duration, items processed, unique keys, matched / non-matched / ambiguous.
- `matcherKey` format: `<universe>-<source>[-translated]-<keys>`, e.g. `eq-factset-ticker-currency_code`.

---

## 7. Also used by

`services/customSecurityService.ts` calls `lookupSecuritiesInRds()` twice when creating custom securities: before insert (duplicate check) and after insert (to confirm the new id). See `custom-securities-and-feedback.md`.

---

## 8. Notes and unknowns

- **Ambiguous picks the first id** of a `Set` built from DB row order, which is not stable. The rules engine treats it as a match.
- **`identifier` is trimmed by Joi**, so `payload` can differ from what the caller sent. The rules engine keys by exact `JSON.stringify(payload)`; such rows would stay `PENDING` (inferred).
- **`EUR`** cannot give a ticker country, so EQ/OPTIONS ticker matching by country (matchers 7, 22) does nothing for EUR rows; matcher 8 still tries `ticker_country = 'eu'` (inferred: rarely matches).
- **FactSet before custom:** for the same key, `security_info` is tried only after the FactSet and historical matchers found nothing. A custom security that duplicates a FactSet identifier is never returned.
- **Entity identifiers** are compared without `lower()`. CIK values with leading zeros must match exactly (unlike `security-search-by-attr`, which strips them).
- Translation map changes take up to 5 minutes to apply, per process.
