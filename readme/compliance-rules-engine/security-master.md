# Security master (SMA)

How the service talks to the security master ("SMA", Security Master & Analytics): what it asks, what it gets back, and what happens when a call fails.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `trade-process.md`, `holdings-process.md`, `exceptions.md`, `preclear-rules-engine.md`, `client-db-schema.md`, `central-db-schema.md`, `opensearch-sync.md`.

---

## 1. Overview

- **SMA is an external HTTP service.** This repo only calls it. Its code, its data and its database are not here.
- **One client for all calls:** `libs/sma/` (`smaClient.ts` = HTTP + auth + retry, `smaService.ts` = one function per endpoint, `index.ts` re-exports `smaService`).
- All endpoints live under `SMA_URL` + `/security-master/...`. Most are under `/security-master/factset/...`, so the data is FactSet-based (inferred from the paths).
- SMA is used in four places:

```
                                  ┌──────────────────────────────────────────────┐
 full-preprocess / trade-preprocess│ securityLookupMatch  (batch: raw → security_id)
 holdings-preprocess  ───────────►│                                              │
   brokerdb.trade_data            │                                              │
   brokerdb.holding_data          │                                              │
                                  │                                              │
 trade-process (tradeProcess())  ►│ preFetchSecurityInfo, fetchMatchingSecurities│
                                  │ fetchHealthcareSicCodes,                     │     SMA
                                  │ getPreclearSecurityMatchedStatus,            │──►  (HTTP, Keycloak
                                  │ fetchPreclearExpirationDate                  │      bearer token)
                                  │                                              │
 preclear rules engine (API)  ───►│ preFetchSecurityInfo, fetchMatchingSecurities│
 client rule config (API)         │ fetchSecurityTypes, fetchSecurityPrice       │
                                  │                                              │
 exception resolution (API)  ────►│ preFetchSecurityInfo, fetchSecurityTypes,    │
                                  │ createCustomSecurities                       │
                                  └──────────────────────────────────────────────┘
```

---

## 2. The HTTP client (`libs/sma/smaClient.ts`)

- One `SmaClient` instance per process (module-level in `smaService.ts`), using `axios` with `baseURL = SMA_URL`.
- **Auth** (only if `SMA_AUTH` is true, the default):
  - Keycloak client-credentials grant: `POST <SMA_KEYCLOAK_SERVER_URL>/realms/<SMA_KEYCLOAK_REALM>/protocol/openid-connect/token` with `SMA_KEYCLOAK_CLIENT_ID` and the client secret.
  - Client secret: on **AWS** from Secrets Manager, secret `SMA_KEYCLOAK_CLIENT_SECRET_NAME_AWS`, field `clientSecret`, region `AWS_REGION`. On **Azure** (and any non-AWS `APP_ENV`) from env var `SMA_KEYCLOAK_CLIENT_SECRET`.
  - The token is cached in memory and sent as `Authorization: Bearer <token>`. It is dropped only after a `401`/`403`; there is no expiry check.
- **Retry** (`retry()` in `libs/helper.ts`): up to **5 attempts**, `SMA_RETRY_DELAY` ms apart (default `5000`).

  | Error | Retried? |
  |---|---|
  | `401` / `403` | yes, with a new token |
  | other `4xx` | no, the original axios error is thrown |
  | `5xx`, network error, timeout | yes |
  | Missing secret env var (`EnvironmentVariableMissingError`) | no |

  After 5 failed attempts the error is `API call FAILED after 5 attempts.` The original cause is not kept.

---

## 3. Endpoints used

All in `libs/sma/smaService.ts`. "Envelope" = SMA answers `{ status, message, data }`.

| Function | Request | Returns | On SMA error / `status = false` | Used by |
|---|---|---|---|---|
| `securityLookupMatch(data[])` | `POST /security-master/factset/security-lookup`, body `{ data: RawSecurity[] }` | `response.data.data` (array of `SecurityLookupResponse`) | throws | trade and holdings preprocess (section 4) |
| `preFetchSecurityInfo(securityId)` | `POST /security-master/factset/pre-fetch`, body `{ security_ids: [id] }` | `data.security_info[0]`, or `{}` if none | throws `message` | trade process, preclear rules engine V2/V3, exception resolution |
| `fetchMatchingSecurities(securityId)` | `GET /security-master/factset/security-match?security_id=` | list of related `security_id`s, always including the input id | throws `No data or invalid response …` | trade process, preclear rules engine V2 |
| `fetchHealthcareSicCodes(sicCodes, entityId)` | `POST …/fetch-healthcare-sic-codes`, body `{ sicCodes, entityId }` | `true` if `data` is non-empty | throws | trade process `sicCheck`, `libs/rulesV3.0/sic_restriction_rule.ts` |
| `getPreclearSecurityMatchedStatus(preclearSecId, tradeSecId)` | `GET …/security-preclear-match` | `data` or `false` | throws | trade process `preclearMatch` |
| `fetchPreclearExpirationDate(date, client, days)` | `GET …/get-preclear-expiration-date` | `data[0].preclear_expiration_date` or `''` | **returns `''`** (never throws) | trade process `preclearMatch` |
| `fetchSecurityTypes()` | `GET …/get-security-types` | `data` | throws | preclear rules engine V2, client rule config V2, exception resolution |
| `fetchSecurityPrice(id, currency, date)` | `GET …/security-price` | `data.price`, or `0` | **returns `0`** (never throws) | preclear rules engine V2 (`CURRENT_SECURITY_PRICE`) |
| `createCustomSecurities(list)` | `POST /security-master/central-custom/security`, body `{ data }` | `data` (array with `status_type`: `created` / `duplicate` / `error` / `invalid`) | returns the error response's `data`, or `[]` | exception resolution "New Security" |
| `fetchSecuritiesByEntityId(entityId)` | `GET …/get-securities-by-entity-id` | `data` | throws | no caller outside tests |
| `deleteCustomSecurities(ids)` | `DELETE /security-master/central-custom/security` | – | throws | no caller outside tests |

---

## 4. Security matching in preprocess (`securityLookupMatch`)

Code: `tasks/tradeProcess/services/tradePreprocessService.ts` (trades) and `tasks/holdingsPreprocess/services/holdingsPreprocessService.ts` (holdings). The steps around it are in `trade-process.md`, section 4.

### 4.1 Request

`RawSecurity` (all fields optional except `universe_type`):
`universe_type`, `currency_code`, `identifier`, `broker_code`, `isin`, `cusip`, `sedol`, `ticker`, `crd`, `cik`, `rssd`, `security_name`, `description`.
`UniverseType` = `'EQ' | 'OPTIONS' | 'FUTURES' | 'CRYPTO' | 'FX' | '*'` (`'*'` is not used by any caller).

What each matcher sends (all values trimmed, `NULL` → `''`):

| Matcher | Rows (+ `LOWER(status) = 'pending'`; holdings also `processed = 'no'`) | `universe_type` | Fields sent: **trades** | Fields sent: **holdings** |
|---|---|---|---|---|
| FUTURES | `is_future = 'yes'` | `FUTURES` | `broker_code`, `description`, `ticker` (first word of `symbol`), `security_name`, `currency_code` | same, `ticker` = whole `symbol` |
| OPTIONS | `is_option = 'yes'` | `OPTIONS` | `ticker`, `security_name`, `currency_code`, `broker_code` | same + `identifier` |
| FX | `security_type = 'fx'` | `FX` | `ticker` (= `symbol`), `currency_code`, `security_name` | `ticker` = `currency_code` (default `USD`), `currency_code` = `'USD'`, `security_name` |
| CRYPTO | `security_type = 'crypto'` | `CRYPTO` | `ticker`, `security_name` | same |
| EQUITIES | not option, not future, `security_type NOT IN ('crypto','fx')` | `EQ` | `isin`, `cusip`, `sedol`, `ticker`, `security_name`, `currency_code` | same + `identifier` |

- `broker_code` = second part of `file_name` (`split_part(file_name, '_', 2)`). For options from Plaid with no broker code it is `PLAID`.
- Crypto rows with an empty or `NULL` symbol are **not sent**. They get `process_outcome = 'Fail: Correct Symbol could not be extracted. Skipping this row'`.

### 4.2 Batching

1. The rows of one matcher are cut into chunks of `SECURITIES_CHUNK_SIZE` rows (default `1000`, read from env var **`CHUNK_SIZE`**, `libs/globalConstants.ts:82`).
2. Inside a chunk, rows with the same payload are grouped. The key is `JSON.stringify(payload)`, so one security is sent once with the list of its `trade_id`s / `holding_number`s.
3. One `securityLookupMatch` call per chunk. Chunks run one after another; the five matchers run in parallel.
4. Updates are written in `DO $$ … $$` blocks of up to 100 statements. Each statement has its own `EXCEPTION WHEN OTHERS THEN RAISE NOTICE`, so one failing `UPDATE` does not stop the others.

### 4.3 Response → `process_outcome` / `security_id`

`SecurityLookupResponse`: `{ security_id?, cid?, status?, payload }`. `payload` must be the request item echoed back: it is matched to the request group by `JSON.stringify(payload)`.

| SMA answer for a group | `UPDATE` on `brokerdb.trade_data` / `brokerdb.holding_data` (only rows still `pending`) |
|---|---|
| `security_id` present | `security_id = <id>`, `process_outcome = <status>`, `status = 'TRADE'` |
| `security_id` empty or missing | `security_id = ''`, `process_outcome = 'Fail: Could Not Find Matching Security ID'` (SMA `status` is ignored) |
| Group not in the response, or `payload` not echoed exactly | **nothing**. The row stays `PENDING` with no outcome and is retried on the next run. |
| Whole call fails (after retries) | Matcher stops. Alert `TRADE PROCESS V2 \| <matcher>` (trades, topic `trade-error`) or `HOLDINGS PREPROCESS \| <matcher>` (holdings). Rows wait for the next run. |

- The values of `status` (the match status shown in `process_outcome`) come from SMA. They are not listed anywhere in this repo.
- `cid` in the response is not used.
- Holdings that match also get `status = 'TRADE'` in `holding_data`.

---

## 5. SMA in trade process (`tradeProcess()`)

Code: `serverless/public/functions/tradeProcessV2/tradeProcess.ts`. The rule order is in `trade-process.md`, section 6.2.

| Rule | SMA call | What is used |
|---|---|---|
| `cookData` | `preFetchSecurityInfo(security_id)` | Kept as `securityPayload`. Empty → **`SecurityNotFoundError`** (below). |
| `cookData` | `fetchMatchingSecurities(security_id)` | `tradeData.matched_securities`: related listings of the same security, used by restriction and preclear matching |
| `usGovCheck` | – | `securityPayload.entity_id` = `US_GOV_ENTITY_ID` → preclear not needed |
| `preclearNotNeeded` | – | `securityPayload.security_type_code`, `universe_type` |
| `restrictionCheck` | – | `securityPayload.all_entity_ids`, or `[entity_id]` |
| `sicCheck` | `fetchHealthcareSicCodes(SIC_CODES, entity_id)` | only if `SIC_RULES` is set and the security has an `entity_id` |
| `preclearMatch` | `getPreclearSecurityMatchedStatus(preclear security, trade security)` | per candidate disclosure: does the preclearance cover this security? |
| `preclearMatch` | `fetchPreclearExpirationDate(...)` | end of the approval window. On error `''`, so the date check fails and the trade is treated as not precleared (inferred from `isDateInRange`). |

### `SecurityNotFoundError`
- Defined in `libs/errors/ValidationError.ts`. Thrown in `cookData` (`tradeProcess.ts:132-135`) when SMA returns no security info for the trade's `security_id`.
- It is not caught inside `tradeProcess()`, so `loadToTarget` never runs: no `INSERT` into the client DB and **no `UPDATE` of `trade_data`**. The trade stays `processed = 'NO'`.
- An alert is sent (topic `trade-error`): AWS `ERROR: TRADE PROCESS V2 | <client> | <trade>` (`tradeProcessV2/handler.ts`), Azure `TRADE PROCESS V2 | <client> | <trade>` (`tasks/tradeProcess/services/tradeProcessService.ts`, message includes the trade JSON).
- The next `trade-process-job` run fetches the trade again and fails again, until SMA knows the id. This is one of the "stuck forever" reasons in `trade-process.md`, section 7.
- Any other SMA error in these calls (5xx after retries, `status = false`) has the same effect.

---

## 6. Other SMA uses

### 6.1 Preclear rules engine
- **V2** (`serverless/public/functions/rulesEngineV2/service.ts`): `fetchSecurityTypes()` once per request. Lazy context values:

  | Context key | Source |
  |---|---|
  | `SECURITY_INFO` | `preFetchSecurityInfo(SECURITY_ID)` |
  | `MATCHED_SECURITIES` | `fetchMatchingSecurities(SECURITY_ID)`, `[]` without a `SECURITY_ID` |
  | `ENTITY_ID` | disclosure `CID`, else `SECURITY_INFO.entity_id`, else `null` |
  | `CURRENT_SECURITY_PRICE` | `fetchSecurityPrice(SECURITY_ID, CURRENCY_CODE or 'USD', DISCLOSURE_CREATED_DATE)`, `0` on error |

  An SMA error that throws fails the request (`unhandledError`) and sends an alert (`rulesEngineV2/handler.ts`).
- **V3** (`serverless/public/functions/rulesEngineV3/handler.ts`): one `preFetchSecurityInfo(SECURITY_ID)`, passed to each rule as `SecurityDetails`.
- **Client rule config V2** (`serverless/public/functions/clientRuleConfigV2/service.ts`): `fetchSecurityTypes()`.

Details: `preclear-rules-engine.md`.

### 6.2 Exception resolution
`services/ExceptionResolvingService.ts`, called by `serverless/private/functions/exceptionResolvingV1/exceptionResolvingHandler.ts`:

| Resolution | SMA call | Result |
|---|---|---|
| Not a Trade | `fetchSecurityTypes()`: the RNR code must exist with `universe_type = 'RNR'` | `status = 'RNR \| <code>'`, `security_id = 'RNR_<code>'` |
| Matched to Existing Security | `preFetchSecurityInfo(id)` → `fsym_security_id` | `status = 'TRADE'`, `security_id = <fsym_security_id>`. Not found → `ValidationError('Security not found')`. SMA error → `ApplicationError`. |
| New Security | `createCustomSecurities([...])` | `created` / `duplicate` → exception `Awaiting Match` (trade untouched; matched by a later preprocess run, inferred). Otherwise `ApplicationError`. |

Details: `exceptions.md`.

---

## 7. Security data that does not come from SMA

- **`company_info` in the client DB** (`refdata.company_info` and `public.company_info`, see `client-db-schema.md` 4.8). Read directly with SQL by:
  - `libs/rules/*`: `sec_type_rule`, `sic_restriction_rule`, `ticker_check_rule`, `check_restricted_countries_rule`, `average_volume_rule`
  - preclear flip (`serverless/public/functions/tradeProcessV2/preclearFlip/service.ts`)
  - `checkPreClrNotNeededUSGov` in `tradeProcessV2/service.ts` (exported, but no caller; the live US-gov check uses SMA's `entity_id`)

  Who fills these tables is not in this repo.
- **DynamoDB (`libs/dynamodb.ts`) is not SMA.** In this repo it is only used by `storage/legacyRepositories/` to read legacy client configs (`DYNAMO_CLIENT_CONFIG`, `DYNAMO_CLIENT_RULE_CONFIG_V1`). The region is hardcoded to `us-east-1`.
- **OpenSearch** indices of securities and entities are built by `open-search-task` (`opensearch-sync.md`). No SMA call in this repo is known to read them.

---

## 8. Settings (env vars)

| Env var | Default | Meaning |
|---|---|---|
| `SMA_URL` | none (undefined) | Base URL of SMA |
| `SMA_AUTH` | `true` | Send a Keycloak bearer token |
| `SMA_RETRY_DELAY` | `5000` | ms between retries |
| `SMA_KEYCLOAK_SERVER_URL`, `SMA_KEYCLOAK_REALM`, `SMA_KEYCLOAK_CLIENT_ID` | `''` | Token endpoint and client |
| `SMA_KEYCLOAK_CLIENT_SECRET_NAME_AWS` | `''` | AWS: Secrets Manager secret holding `clientSecret` |
| `SMA_KEYCLOAK_CLIENT_SECRET` | `''` | Azure / non-AWS: the secret itself |
| `CHUNK_SIZE` | `1000` | Rows per `securityLookupMatch` call (`SECURITIES_CHUNK_SIZE` in code) |
| `APP_ENV` | `AWS` | `AWS` or `AZURE`; picks the secret source |
| `AWS_REGION` | – | Region for Secrets Manager |

Lambdas get `SMA_URL`, `SMA_AUTH`, `SMA_KEYCLOAK_SERVER_URL`, `SMA_KEYCLOAK_REALM`, `SMA_KEYCLOAK_CLIENT_ID` and `SMA_KEYCLOAK_CLIENT_SECRET_NAME_AWS` from `serverless/common/createServerlessConfiguration.ts`. `SMA_RETRY_DELAY` and `CHUNK_SIZE` are not passed there, so Lambdas use the defaults.

---

## 9. AWS vs Azure

| | AWS | Azure |
|---|---|---|
| Keycloak client secret | Secrets Manager (`SMA_KEYCLOAK_CLIENT_SECRET_NAME_AWS`) | env var `SMA_KEYCLOAK_CLIENT_SECRET` |
| Where trade process calls SMA | SQS Lambda, one trade per message | inside `trade-process-job`, trades one by one |
| `SecurityNotFoundError` alert subject | `ERROR: TRADE PROCESS V2 \| <client> \| <trade>` | `TRADE PROCESS V2 \| <client> \| <trade>` |

Endpoints, payloads and status handling are the same.

---

## 10. Notes and unknowns

- **Risks found in code:**
  - `tasks/tradeProcess/services/tradePreprocessService.ts:327` (and `holdingsPreprocessService.ts:322`): `security_id` and SMA `status` are put into SQL by string interpolation. A quote in either breaks the statement (caught by `EXCEPTION WHEN OTHERS`, so those rows silently stay `PENDING`) and is an injection risk.
  - `tradePreprocessService.ts:288` / `holdingsPreprocessService.ts:283`: responses are matched by `JSON.stringify(payload)`. If SMA changes key order or normalizes a value, every result of the chunk is dropped without a log or alert.
  - `tradePreprocessService.ts:246` / `holdingsPreprocessService.ts:95`: `LOWER(security_type) NOT IN ('crypto','fx')` is not true when `security_type` is `NULL`. Today this is safe only because `fn_process_trades` / `fn_process_holdings` first set `NULL` to `'other'` / `'Other'` for `PENDING` rows; a row that reaches matching any other way with `NULL` is skipped by every matcher.
  - Matched group without SMA `status` → `process_outcome = 'undefined'` (the string).
  - `libs/helper.ts:44`: after the last retry the original error is dropped.
  - Token is reused until a `401`/`403`; an expired token costs one failed request per process.
  - RNR trades for clients that process RNR (`security_id = 'RNR_<code>'`) also go through `preFetchSecurityInfo` in `cookData`, before `nonTradeCheck`. Whether SMA returns data for `RNR_*` ids is unknown; if not, they fail with `SecurityNotFoundError`.
- **Docs elsewhere:** `project.md` calls SMA "DynamoDB-backed". This repo only calls SMA over HTTP; its DynamoDB use is legacy client config.
- **Unknown:**
  - the list of match `status` values SMA returns
  - SMA's own data store, and whether it uses the OpenSearch indices
  - request timeouts (none is set in the axios instance)
  - `compliance-rules-engine/tasks/dumpSecuritiesAndEntities` and `refreshSecurities` (outside `rules-engine-3.0`) also call SMA; not covered here.
