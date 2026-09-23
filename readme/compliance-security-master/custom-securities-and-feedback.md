# Custom securities and broker feedback

The two write paths of the service:

| Endpoint | Role enforced | Writes to |
|---|---|---|
| `POST /security-master/central-custom/security` | `SMA_READ` (`SMA_WRITE` requested but not enforced) | RDS `public.security_info` |
| `DELETE /security-master/central-custom/security` | same | RDS `public.security_info` |
| `POST /broker/broker-account/upload-feedback-in-bulk` | `SMA_WRITE` | ADMIN DB `brokerdb.broker_feedback_upload`, `disclosures`, `attribute_extra` |

Related docs: `runtime-overview.md` §3 (roles), `security-lookup.md`, `data-and-replication.md`, `../compliance-rules-engine/exceptions.md` ("New Security"), `../compliance-rules-engine/accounts-and-feedback.md`.

---

## 1. Custom securities

A custom security is a row in RDS `public.security_info` for an instrument FactSet does not cover (crypto, FX pairs, private shares, manual entries). It gets a generated id `XXXXXX-SS` (6 chars from `A–Z0–9`) and `cid = 'NOENTITY'`.
Once created, it is found by `security-lookup` (custom matchers), `pre-fetch`, v1 `security-search` and `get-security-id-from-security-info`.

Main caller: rules-engine exception resolution "New Security" (`createCustomSecurities`).

### 1.1 Create — `POST /security-master/central-custom/security`

```json
{ "data": [
  { "security_name": "Acme Private Co", "security_type_code": "PRIV", "ticker": "ACME",
    "currency_code": "USD", "iso_country": "US", "created_by": "jdoe" }
] }
```

Per-item fields (`validators/securityValidator.ts:customSecurity`, unknown fields allowed):

| Field | Rule |
|---|---|
| `security_name` | required |
| `security_type_code` | required; must exist in `sec_map` and have a `universe_type` (exact case) |
| `currency_code` | optional, 3 letters, uppercased |
| `ticker` | optional, trimmed, uppercased |
| `cusip` / `isin` | optional, alphanumeric, length 9 / 12, uppercased |
| `sedol` | not validated; stored as sent |
| `iso_country` | optional, 2 letters |
| `created_by` | used only for service-account callers |

Flow (`services/customSecurityService.ts:createCustomSecurities`). Every item has a status; each step works only on items still `pending`:

1. Load all security types (`sec_map`).
2. **Validate** each item → `invalid` on Joi error or unknown type code.
   - Non-crypto item with a ticker and no currency → currency `USD`.
   - `created_by` = body `created_by` if the token's `client_id` = `KEYCLOAK_CLIENT_ID` (service account), else the token's `preferred_username`. Fallback at insert: `'SMA'`.
   - `universe_type` taken from `sec_map`.
3. **Duplicates inside the request** (case-insensitive), in this order: `security_name`, `ticker`+`currency_code`, `isin`, `cusip`, `sedol` → later copies `duplicate`.
4. **Duplicates in the DB:** run `security-lookup` (`security-lookup.md`) with `security_name`, `ticker`, `isin`, `cusip`, `currency_code` and `universe_type` = the type's universe if `EQ` / `CRYPTO` / `FX`, else `*`.
   - found → `duplicate` with the existing `security_id`;
   - lookup status other than `Security Not Found` (e.g. `Not Enough Data`) → `error`;
   - lookup throws → all `error`.
5. **Insert** all pending items in **one** `INSERT` (`storage/rds/rdsSecurityInfo.ts:insertCustomSecurities`), `is_active = true`. Unique-index clash on `security_id` → new ids for all, up to 3 attempts. Any other error → all pending `error`.
6. **Confirm:** run `security-lookup` again; found → `created` with the found id; not found → `error` "Security not found after creation" (the row stays in the table).

Response:

| Result | HTTP | `message` |
|---|---|---|
| all created | 201 | All securities were created successfully |
| some created | 207 | Created N out of M securities |
| none created | 400 | No securities were created |

`data` = one entry per input: `{ security_id, status_type, status, payload }`, `status_type` ∈ `created`, `duplicate`, `invalid`, `error`.

### 1.2 Delete — `DELETE /security-master/central-custom/security`

Body `{ "security_ids": ["ABC123-SS"] }` (≥ 1).
- `DELETE FROM security_info WHERE security_id IN (...) RETURNING security_id` — hard delete, no audit row.
- Per id `deleted` / `not_found`. All deleted → 200; some → 207; none → 404.

### 1.3 Table `public.security_info`

DDL: `queries/pg_create_security_info.sql`.

| Column | Note |
|---|---|
| `identity` | uuid PK |
| `security_id` | unique index `security_info_security_id_idx` |
| `cid` | `NOENTITY` for custom rows |
| `security_description`, `ticker`, `currency`, `security_type_code`, `isin`, `cusip`, `sedol`, `bbg_ticker`, `bbg_id`, `universe_type`, `iso_country` | |
| `is_active`, `created_date`, `modified_date`, `created_by`, `modified_by` | |

Unique indexes on ISIN, CUSIP and ticker+currency are commented out ("TODO: clean up duplicates in DB").

### 1.4 Notes

- **Role:** a token with only `SMA_READ` can create and delete (`runtime-overview.md` §3).
- **No DB uniqueness on identifiers:** two parallel requests for the same ISIN can both pass the lookup and both insert.
- **Delete accepts any id** in `security_info`, not only `-SS` ids. The `pg_cron` job `daily_refresh_security_info` (inactive) suggests the table once held non-custom rows too; its function is not in the repo.
- **Swagger** hides these endpoints in `prod`, but they are active there.
- `sedol` is stored without trimming or case change, while the matcher compares `lower(sedol)` — works, but in-request duplicate check on `sedol` is case-insensitive and DB uniqueness is not checked.

---

## 2. Broker feedback upload

`POST /broker/broker-account/upload-feedback-in-bulk`, `multipart/form-data`, field **`file`**.
Code: `routes/brokerRoutes.ts`, `middlewares/request/uploadFiles.ts`, `services/brokerService.ts`, SQL in `utils/queries.ts`.

### 2.1 File

- MIME `application/vnd.ms-excel` or `…spreadsheetml.sheet` (XLS / XLSX) — despite the name `uploadSingleCSVDocument`.
- Size limit `3000 * 3000` = **9,000,000 bytes** (message says "3MB").
- First sheet; first row = headers. Columns:

| Column | Rule |
|---|---|
| `client_code` | uppercased; must exist in ADMIN `clients` |
| `account_id` | required; must be an active `brokerdb.account_data` row (case-insensitive) |
| `feedback_type` | required; exactly one of the sentences below |
| `additional_comment` | optional |

`feedback_type` values (`utils/constants.ts:FEEDBACK_TYPES`):
- `Account number provided is not a valid account number.`
- `Account type is not eligible for the direct feed.`
- `Account has been closed.`
- `Account confirmed open, but has no activity.`
- `Account name provided does not match broker records.`
- `Onboarding is pending employee consent.`
- `Onboarding is pending compliance action.`
- `Onboarding is pending employee signature.`

### 2.2 Flow (ADMIN DB)

For each row, in order:
1. Validate the row (Joi).
2. `clients` has `client_code` (existence only; no active flag checked).
3. `brokerdb.account_data` has `account_id` with `account_is_active = 'true'`.
4. Same `client_code` + `account_id` + `feedback_type` + `additional_comment` already in `brokerdb.broker_feedback_upload` → check its disclosure age (see note).
5. Insert into `brokerdb.broker_feedback_upload (uid = random int, client_code, account_id, feedback_type, additional_comment)`.
6. Row result `{ row_number, ...row, success, message }`; a row error does not stop the others.

Then once (`funcProcessUploadedFeedbackQ`), for **all** rows with `is_loaded = false` (not only this upload):
1. set `disc_id` = 16 random uppercase hex chars where missing;
2. insert a `disclosures` row of type `BROKER_FEEDBACK`;
3. insert `attribute_extra` rows: `BROKER_FEEDBACK_CLIENT_CODE`, `ACCOUNT_ID`, `BROKER_FEEDBACK_TYPE`, `COMMENT` (if any), `STATUS = 'Pending'`;
4. set `is_loaded = true`.
Created/modified by is the fixed user `xby-admin-1-x5d4qx`.

Response: `200 "All feedbacks are processed"`, `data` = per-row results.
How the feedback is used afterwards: `../compliance-rules-engine/accounts-and-feedback.md`.

### 2.3 Notes

- **30-day duplicate check looks inverted:** `checkDiscMoreThan30Days` returns a row when the disclosure was created **within** the last 30 days. The code throws "Feedback already exists within 30 days time frame." when **no** such row is found. So a recent duplicate is accepted and an older one is rejected (seen in code, not tested).
- **SQL injection risk:** `additional_comment` is pasted into the duplicate-check SQL (`= '${additional_comment}'`). A `'` in a comment breaks the row; crafted text could change the query.
- `client_code` is optional in Joi but required by step 2, so rows without it fail with "client_code is invalid or client is inactive."
- `uid` is `floor(random() * 1e9)`; no unique key on the table (per the rules-engine doc), so collisions are possible but harmless (inferred).
- The final step sends several statements in one call (one implicit transaction, inferred); if it fails, rows stay `is_loaded = false` and are processed by the next upload.
