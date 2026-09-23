# compliance-security-master docs

Index of the docs for the `compliance-security-master` service ("SMA", Security Master API), plus the terms they all share.

- Repo: `dev.azure.com/intappdevops/Compliance/_git/compliance-security-master` (mirrored to AWS CodeCommit `azure-security-master`).
- Paths in every doc are relative to the repo root, unless stated otherwise.

---

## 1. What the service does

SMA is a Node.js / Express HTTP API. It answers "which security or company is this?" for the compliance product. The data comes from FactSet.

1. **Matches raw broker data to securities.** Takes ISIN / CUSIP / SEDOL / ticker / name rows from broker files and returns a FactSet security id (`security_id`) and company id (`cid`). See `security-lookup.md`.
2. **Searches** securities and companies by free text, for UI type-ahead. See `search.md`.
3. **Returns reference data**: security and entity details, related securities (same share class), corporate tree, security types, entity types.
4. **Gives compliance helpers** to the rules engine: preclearance expiration date, security price, average daily volume, preclear-vs-trade match, healthcare SIC check. See `preclear-price-volume.md`.
5. **Stores custom securities** that FactSet does not cover (crypto, FX, private, manual). See `custom-securities-and-feedback.md`.
6. **Accepts broker feedback** uploads (XLSX) and turns them into disclosures. See `custom-securities-and-feedback.md`.

The main caller is `compliance-rules-engine` (see `../compliance-rules-engine/security-master.md`). The client UI calls the search endpoints (inferred from the Swagger OAuth public client).

---

## 2. The docs

| Doc | Read it for |
|---|---|
| `runtime-overview.md` | **Start here.** Architecture, startup, auth, databases, env vars, build, deploy, CI, local dev and tests |
| `api-reference.md` | Every endpoint: path, role, input, data source, output |
| **Core logic** | |
| `security-lookup.md` | The bulk matcher pipeline behind `POST /security-lookup` |
| `search.md` | Security and entity search: v1 (SQL) and v2 (OpenSearch), ranking rules |
| `preclear-price-volume.md` | Preclear expiration date, security price, average daily volume, preclear match, SIC check |
| `custom-securities-and-feedback.md` | Create/delete custom securities; broker feedback XLSX upload |
| **Data** | |
| `data-and-replication.md` | RDS and Redshift tables the service reads, and the `pg_cron` jobs that copy FactSet data from Redshift into RDS |

Suggested reading order: `runtime-overview.md` → `api-reference.md` → `security-lookup.md` → `data-and-replication.md`, then the doc for your area.

---

## 3. Shared glossary

| Term | Meaning |
|---|---|
| **SMA** | This service. Security Master (& Analytics) API. |
| **FactSet** | Market-data vendor. Its tables live in Redshift databases `factsetdb1` / `factsetdb2` (schemas `sym_v1`, `ent_v1`, `ref_v2`, `fgp_v1`). |
| **Redshift** | AWS data warehouse with the full FactSet data. Connection `DbType.REDSHIFT`. |
| **RDS** | PostgreSQL with copies of the FactSet tables SMA needs, plus SMA's own `security_info`. Connection `DbType.RDS`. Most endpoints read only RDS. |
| **ADMIN DB** | The compliance central PostgreSQL (`rulesenginedb`, `brokerdb`, `clients`, `disclosures`, …). Connection `DbType.ADMIN`. Same DB as "central DB" in the rules-engine docs (inferred). |
| **`fsym_id`** | FactSet symbology id, 8 chars + suffix: `-S` security (share class), `-R` regional, `-L` listing. |
| **`fsym_security_id`** | The `-S` id that groups all regional (`-R`) and listing (`-L`) ids of one share class. |
| **`security_id`** | What SMA returns as the security key. For FactSet securities: an `fsym_id` (lookup returns the `-S` id). For custom securities: `XXXXXX-SS`. For futures: the futures root (e.g. `ES`). |
| **`cid` / `entity_id`** | FactSet entity (company) id, e.g. `000C7F-E`. Custom securities have `cid = 'NOENTITY'`, which SMA hides in responses. |
| **Merged entity** | A FactSet entity id that was merged into another one. `sym_merged_entity_id` maps old → current id. |
| **Universe type** | Asset class of a request or security: `EQ`, `OPTIONS`, `FUTURES`, `CRYPTO`, `FX`, `*` (lookup). FactSet / `security_info` values: `EQ`, `FI`, `FUT`, `CRYPTO`, `FX`, `OTH`, … |
| **Security type code** | `fref_security_type`, e.g. `SHARE`, `ETF_ETF`, `ADR`, `MF_O`. Described in `sec_map`. |
| **Custom security** | A row in RDS `public.security_info` created through SMA, not from FactSet. Id ends in `-SS`. |
| **Translation map** | `brokerdb.trade_process_symbol_map` (ADMIN DB): broker symbol → FactSet ticker + currency. |

---

## 4. Conventions in these docs

- **Paths:** endpoint paths omit the env prefix. Real URL = `https://<host>/<NODE_ENV>/<path>`, e.g. `/dev/security-master/factset/security-match`.
- **"(inferred)"** marks a statement concluded from code but not confirmed. Each doc ends with **"Notes and unknowns"**.
- **Sources:** facts come from reading the code and SQL in the repo. Nothing was run. Deployed env values, production schedules and table contents are not in the repo.
- **Bugs and risks** the docs mention are seen in code and not tested.
- The repo's own `README.md` mentions `tests/integration/redshift/` and `npm run test:integration:no-redshift`. Neither exists on this branch.
