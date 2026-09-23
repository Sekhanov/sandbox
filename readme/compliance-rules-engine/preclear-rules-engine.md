# Preclearance rules engine

How an employee's preclearance request (a `TRADE_PRECLEARANCE` disclosure) gets a decision: Approved, Denied, In Review or Other.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `client-config.md`, `central-db-schema.md`, `client-db-schema.md`, `trade-process.md`, `security-master.md`, `runtime-overview.md`.

---

## 1. Overview

**In one sentence:** the client app sends one disclosure to the engine. The engine loads the client's rule chain from the central DB, runs the rules in order against the client DB and the security master (SMA), and returns the first decision a rule produces.

```
client app (inferred)                 THIS REPO
  POST disclosure  ───────────►  rulesEngineV2 Lambda (AWS)  /  Express route (Azure)
                                      │
                                      ├─ central DB: rulesenginedb.clients_v2          (client, preclear_status_config)
                                      │              rulesenginedb.preclear_configs_v2 (rule chain)
                                      ├─ SMA: security types, security info, matches, price
                                      ├─ client DB: restrictions, trading windows, users, bk_txn, gifts, company_info
                                      │
                                      ▼
                     rule 1 ─► rule 2 ─► … ─► first rule with a status ─► APPROVE / DENY / REVIEW / OTHER
                                                                              │ preclear_status_config
  ◄──────────── 200 { TerminalStatus: 'Approved', RuleName, Config, executionHistory, … }
```

- The engine **only reads**. It does not write the decision anywhere. Saving the status on the disclosure is up to the caller (inferred: the client app).
- The same endpoint and the same rule chain serve **every disclosure type** (`TRADE_PRECLEARANCE`, `GIFT_ENTERTAINMENT`, …). The config is not filtered by disclosure type. Rules that need fields the disclosure lacks return "no decision" or fail (section 7).
- There are two generations:
  - **V2** (current): `serverless/public/functions/rulesEngineV2`, rules in `libs/rules/*`, config in `rulesenginedb.preclear_configs_v2`. Runs on AWS and Azure.
  - **V3** (legacy, AWS only): `serverless/public/functions/rulesEngineV3`, rules in `libs/rulesV3.0/*`, config in the legacy tables `rulesenginedb.clients` / `rulesenginedb.preclear_rules`. See section 11.

---

## 2. Words used in this document

| Term | Meaning |
|---|---|
| **Disclosure** | A record an employee submits in the client app. Preclearance = `TRADE_PRECLEARANCE`. Stored in the client DB (`disclosures` + `attribute_extra`), see `client-db-schema.md`. |
| **Rule chain** | The client's ordered list of rules (`preclear_configs_v2.rules`). |
| **Terminal status** | What a rule returns when it decides: one of the keys `APPROVE`, `DENY`, `REVIEW`, `OTHER`. `false` = "no decision, go to the next rule". |
| **Status label** | The client's display text for a terminal status, from `clients_v2.preclear_status_config`, e.g. `APPROVE` → `Approved`. |
| **IN / NOT IN** | Every rule checks a condition. Condition true → it returns its `action_in`. False → its `action_not_in`. A missing action = `false`. |
| **Context value** | Data a rule asks for by key (`SECURITY_INFO`, `RESTRICTION_LIST_RECORDS`, …), loaded on demand. See section 6. |
| **SMA** | Security master service (`libs/sma`). Also the name of a request flag `SMA = 'true'` that tells some rules to use SMA data instead of the client DB tables `company_info`. |

---

## 3. Entry points

| Endpoint | AWS (API Gateway → Lambda) | Azure (Express, `server/`) | Code |
|---|---|---|---|
| Run rules (V2) | `POST v1/rules/create` | `POST /rules-engine/v1/rules/create` | `rulesEngineV2/handler.ts`, `server/controllers/rulesEngineController.ts` → `rulesEngineV2/service.ts` `executeRulesEngine()` |
| Read config (V2) | `GET rules-engine/v2.0/fetch-client-rule-config-v2` | `GET /rules-engine/v2.0/fetch-client-rule-config-v2` | `clientRuleConfigV2/{handler,service}.ts` |
| Run rules (V3, legacy) | `POST rules-engine/v3.0/submit-preclear` | – | `rulesEngineV3/handler.ts` |
| Read config (V3, legacy) | `GET rules-engine/v3.0/fetch-client-config` | – | `clientRuleConfigV3/handler.ts` |

(All `serverless/public/functions/...` paths shortened to the function folder.)

- **AWS:** the four functions are registered in `serverless/public/serverless.ts`. Lambda timeout 59 s, API Gateway timeout 60 s (`libs/globalConstants.ts`). Body parsing and the last-resort error handler come from `libs/lambda.ts` (`middyfy`).
- **Azure:** `server/index.ts` connects to the central DB once, then starts Express on `PORT` (`server/bootstrapServer.ts`). Swagger UI is at `/api-docs` (`server/swagger/rulesEngineSwagger.ts`). Run with `npm run server` (built) or `npm run dev`.

---

## 4. Request and response (V2)

### 4.1 Request
```json
{
  "ClientID": "SAND",
  "configVersion": "2f9f68af-…",          // optional: test a specific config instead of the active one
  "ParamValue": {
    "DISCLOSURE_TYPE": "TRADE_PRECLEARANCE",
    "DISCLOSURE_ID": "<disclosure-id>",
    "DISCLOSURE_CREATED_BY": "h-pdl-knbi",  // employee user_key
    "DISCLOSURE_CREATED_DATE": "2024-08-28",
    "SECURITY_ID": "C4C0BL-R",
    "ACCOUNT_ID": "<account-id>",
    "PRECLEAR_ACTION": "Sell",
    "PRECLEAR_QUANTITY": "4",
    "SMA": "true"
  }
}
```

Validation (`rulesEngineV2/schema.ts`, `parseDisclosurePayload`):
- `ParamValue.DISCLOSURE_TYPE` is required. It is copied to the top-level `DISCLOSURE_TYPE` (any top-level value is overwritten).
- `ClientID` is required and upper-cased.
- Always required in `ParamValue`: `DISCLOSURE_TYPE`, `DISCLOSURE_ID`. Optional: `DISCLOSURE_CREATED_BY`, `DISCLOSURE_CREATED_DATE`.
- `TRADE_PRECLEARANCE`: `SECURITY_ID` required; `PRECLEAR_ACTION`, `PRECLEAR_QUANTITY` optional.
- `GIFT_ENTERTAINMENT`: `GE_VALUE`, `GE_PARTICIPANT_LIST`, `GE_CATEGORY`, `GE_DIRECTION`, `GE_DATE` optional.
- Unknown fields are allowed and passed to the rules (`.unknown()`). Fields the code knows are listed in `libs/DisclosureData.ts`.
- `SECURITY_ID` and `CID` together → error.

Fields are optional at the API level, but a rule that needs one throws `MissingDisclosureParameterError` (HTTP 400) when it is missing (`getDisclosureData`, `libs/rules-engine-helper.ts`).

### 4.2 Response (200)
```json
{
  "status": true,
  "message": "Terminal Status Reached",
  "data": {
    "DISCLOSURE_ID": "<disclosure-id>",
    "TerminalStatus": "Approved",              // label from preclear_status_config
    "RuleName": "multi_rule",                  // key of the top-level rule that decided
    "RuleFriendlyName": "Multi Rule",
    "Purpose": "Set preclear status based on combination of attributes",
    "Config": ["Securities: … & Trading Window Buy Open: Yes"],
    "TerminalStatusHistory": "Multi Rule:APPROVE|",
    "executionHistory": [ { "ruleId": "…", "ruleKey": "sec_type_rule", "terminalStatus": "APPROVE", "executionTimeMs": 12.3 }, … ]
  }
}
```
- `RuleFriendlyName` / `Purpose` come from `RuleFriendlyNameMapping` (`libs/globalConstants.ts`). `Config` is a human-readable summary of the deciding rule (`getConfigAndAction`, `libs/rules-engine-helper.ts`).
- `TerminalStatusHistory` holds only the deciding rule, with the status **key** (`APPROVE`), not the label.
- `executionHistory`: one entry per executed rule, children of a `multi_rule` included (section 9).

---

## 5. Loading the client config (V2)

`executeRulesEngine()` loads three things in parallel:

| What | How | Fails when |
|---|---|---|
| Client | `clientConfigService.getClientConfig(clientId)` → `rulesenginedb.clients_v2` by `id` (CITEXT, case-insensitive) | client not found → 500 |
| Rule chain | `clientConfigService.findPreclearConfig(clientId, configVersion)` → `rulesenginedb.preclear_configs_v2` | not found or invalid → `Preclear Config not found for Client` → 500 |
| Security types | `fetchSecurityTypes()` (SMA `GET /security-master/factset/get-security-types`), used only for display text | SMA down → 500 |

**Which config** (`storage/repositories/PreclearConfigRepository.ts`):
- No `configVersion`: the client's active config, i.e. `(version, client_id) IN (SELECT preclear_config_version, id FROM rulesenginedb.clients_v2)`.
- With `configVersion`: that version of this client. It is **not** checked to be published or active.

**Rule JSON** in `preclear_configs_v2.rules` (JSONB array, snake_case in storage, camelCase in code):
```json
[
  { "id": "r1", "key": "security_list_rule", "action_in": "DENY",
    "parameters": { "LIST_NAME": "Restriction List", "COMPARISON_OPERATOR": "LIKE" } },
  { "id": "m1", "key": "multi_rule", "parameters": { "MULTI_RULE_MODE": "AND" } },
  { "id": "c1", "parent_id": "m1", "key": "sec_type_rule", "action_in": "APPROVE", "parameters": { "VALUES": ["SHARE"] } },
  { "id": "c2", "parent_id": "m1", "key": "comparison_rule", "action_in": "APPROVE",
    "parameters": { "KEY": "TRADING_WINDOW_BUY_OPEN", "VALUES": ["Yes"], "OPERATOR": "EQUAL_TO" } },
  { "id": "z9", "key": "catchall_setinreview_rule" }
]
```
- Validated twice with Zod: storage shape (`storage/models/PreclearConfigStorage.ts`), then per-rule parameters (`libs/rules/validation.ts`). `action_in` / `action_not_in` must be `APPROVE`, `DENY`, `REVIEW` or `OTHER`.
- Unknown parameter keys are dropped by Zod `z.object` (inferred from Zod's default strip behaviour).
- An unknown `key` fails validation. The config is then treated as "not found".
- Tree building (`models/preclearConfig/*.ts`):
  - rules without `parent_id` form the top-level chain, in array order
  - rules with `parent_id = X` become the children of rule `X`, in array order
  - a config needs at least one top-level rule, and a `multi_rule` at least one child
  - only `multi_rule` runs its children. Children attached to any other rule are never executed, but they still count in `getAllRules()` (used for the restriction lookup window, section 7.3).

**`preclear_status_config`** (`clients_v2`, JSON): maps keys to labels, e.g. seed values `APPROVE: 'Approved'`, `DENY: 'Denied'`, `REVIEW: 'In Review'`, `OTHER: 'Other'` (`seed/central/configs/clients.ts`). Validated by `preclearStatusConfigSchema`; with Zod v4 an enum-keyed record requires all four keys (inferred from Zod v4 behaviour). Used for:
- the response `TerminalStatus` label
- the "approved" label in SQL of `pre_clear_frequency_rule` and `annual_gift_limit_rule`
- `Config` text

Then the client DB is opened (`storage/clientDb.ts`, `connectToClientDb`) and closed in `finally`.

---

## 6. Context data (V2)

Rules get one object, `contextData` (type `libs/ContextData.ts`). It holds:
- all request `ParamValue` fields (e.g. `contextData.SECURITY_ID`)
- `getDisclosureData(key)`: returns a non-empty string field or throws `MissingDisclosureParameterError`
- `getDisclosureDataOptional(key)`: returns the field or `undefined`
- `getContextValue(key)`: loads extra data on demand (`rulesEngineV2/service.ts`)
- `logger`, `ruleKey`, `executionHistory`, `securityTypes`

**`getContextValue` keys**

| Key | Source | Value |
|---|---|---|
| `SECURITY_INFO` | SMA `POST /security-master/factset/pre-fetch` for `SECURITY_ID` (required) | object: `security_type_code`, `ticker`, `entity_id`, `iso_country`, … (`SecurityInfoProps`, `libs/types.ts`); `{}` if unknown |
| `SECURITY_INFO_IS_EMPTY` | `SECURITY_INFO` | `true` if no `SECURITY_ID` or the info is empty |
| `MATCHED_SECURITIES` | SMA `GET /security-master/factset/security-match` | ids of the same security on other listings, plus `SECURITY_ID` itself; `[]` without `SECURITY_ID` |
| `ENTITY_ID` | request `CID`, else `SECURITY_INFO.entity_id` | issuer id or `null` |
| `RESTRICTION_LIST_RECORDS` | client DB, see 7.3 | `{ activeRestrictions, clearedRestrictions }` |
| `TRADING_WINDOW_BUY_OPEN`, `TRADING_WINDOW_SELL_OPEN` | client DB, see 7.4. Needs `DISCLOSURE_CREATED_DATE` | `'Yes'` / `'No'` |
| `CURRENT_SECURITY_PRICE` | SMA `GET /security-master/factset/security-price` (`SECURITY_ID`, `CURRENCY_CODE` or `USD`, `DISCLOSURE_CREATED_DATE`) | number; `0` when missing or on error |
| `CDS_DEPARTMENT_NAME` | client DB `userdb.user_extra` type `CDS_DEPARTMENT_NAME` of `DISCLOSURE_CREATED_BY` (`storage/clientDataFetcher.ts`) | string or `undefined` |
| any other key | the request field with that name | e.g. `PRECLEAR_ACTION` |

- Values are cached on the context object after the first load.
- **Caching is per top-level rule.** Each top-level rule gets a fresh shallow copy (`{ ...disclosureValues, logger, ruleKey }`, `rulesEngineV2/service.ts`), so a value loaded by rule 1 is loaded again by rule 2. Children of a `multi_rule` share their parent's copy.
- `services/contextData/*` (`ContextData`, `TradeContextDataFactory`) is a different mechanism used only by the trade process (`tradeProcessV2/tradeProcess.ts`), not by preclearance.

---

## 7. How the rule chain runs (V2)

`executeRulesEngine()` → for each top-level rule, in order → `executeRule()` (`libs/rules/index.ts`):

1. Build the rule's config: `parameters` + `ACTION = { IN: action_in, NOTIN: action_not_in }` + `DECISION_CONFIG = preclear_status_config` + `rules` (children) (`generateJSONValueV2`).
2. Run the rule function by `key`. Unknown keys fall to `catchall_setinreview_rule` (unreachable in practice: validation rejects unknown keys).
3. Append an `executionHistory` entry (section 9).
4. If the rule returned a terminal status → stop, map it to its label, return 200.
5. If it returned `false` → next rule.
6. No rule decided → error `Rules Engine failed to determine terminal status.` → 500 + alert. A chain should therefore end with `catchall_setinreview_rule`.

**Rule semantics in short**
- Each rule checks one condition → `action_in` (true) or `action_not_in` (false). Leaving one action empty makes the rule "pass-through" on that side.
- Rules that need a missing optional field (e.g. no `SECURITY_ID`) usually return `false` and log a warning. Rules that use `getDisclosureData` throw → 400.

### 7.1 `multi_rule`: AND / OR of child rules
Parameters: `MULTI_RULE_MODE` = `AND` | `OR`. Children = rules with `parent_id` = this rule's `id`. Children can be `multi_rule` too.

| Mode | Runs children in order and… | Result |
|---|---|---|
| `AND` | stops at the first child with `false` | `false` if any child is `false`; else the **last** child's status |
| `OR` | stops at the first child with a status | that status; `false` if none |

- The multi_rule's own `action_in` / `action_not_in` are **ignored** at run time. Only the children's actions matter. They are used only in the `Config` display text.
- Each child is run through `executeRule()`, so children appear in `executionHistory` (before their parent).

### 7.2 Rules reference (`libs/rules/*`)

"SMA path" = request field `SMA = 'true'` (always on Azure, section 10). "DB path" = otherwise. All DB reads are on the **client DB**.

| Rule (`key`) · friendly name | Parameters | Condition is true (→ `action_in`) when… | Data read |
|---|---|---|---|
| `sec_type_rule` · Security Type Check | `VALUES`: security type codes, e.g. `["SHARE","CRYPTO"]` | the security's type is in `VALUES` | SMA: `SECURITY_INFO.security_type_code`. DB: `UPPER(sec_type)` from `refdata.company_info` ∪ `public.company_info` by `security_id` (first row). No `SECURITY_ID` → `false`. |
| `ticker_check_rule` · Ticker Check | `STOCK_SYMBOLS` | the security's ticker is in the list | SMA: `SECURITY_INFO.ticker`. DB: `refdata.company_info` ∪ `public.company_info` with `ticker IN (…)` and (`security_id` or `cid` = `SECURITY_ID`). |
| `security_list_rule` · List Rule | `LIST_NAME` (default `%`), `COMPARISON_OPERATOR`, optional `NO_OF_DAYS`, `ATTRIBUTE_*` | the security is on a matching restriction list (active, or cleared within `NO_OF_DAYS`) | `RESTRICTION_LIST_RECORDS`. See 7.3. Needs `SECURITY_ID` or `CID`, else `false`. |
| `wildcard_security_list_rule` · List Rule | same | same | Same code as `security_list_rule`. Only the result key differs (`listNames` stored under this key), so `Config` can show the matched list names when `LIST_NAME = '%'`. |
| `covered_party_bypass_rule` · Covered Party Bypass Check | none | the employee has a `COVERED_PARTY_PRECLEAR_OVERRIDE` user attribute | `disclosures d` owned by `DISCLOSURE_CREATED_BY` (required) ⨝ `userdb.users` ⨝ `user_extra` ⨝ `user_extra_types`. Any row counts: the attribute's value and `is_active` are not checked, and the user must own at least one disclosure. |
| `trading_window_rule` · Trading Window Check | `DATE`: list of date strings | `DISCLOSURE_CREATED_DATE` (required) equals one of `DATE` (exact string) | none. It does **not** read trading-window disclosures; those are used through `comparison_rule` (7.4). |
| `comparison_rule` · Comparison Check | `KEY`, `VALUES`, `OPERATOR` | see 7.5 | `getContextValue(KEY)` |
| `key_comparison_rule` · Key Comparison Check | `KEY1`, `KEY2`, `OPERATOR` = `LESS_THAN` \| `GREATER_THAN` | `parseInt(contextData[KEY1]) <op> parseInt(contextData[KEY2])` | Request fields only (no context loading). A missing key throws (`.toString()` on undefined) → 500 (inferred). |
| `average_volume_rule` · Average Volume Check | none | `PRECLEAR_QUANTITY` > 0.1 % of the security's latest volume | Ticker: SMA pre-fetch (SMA path) or `refdata.company_info` by `security_id`/`cid`. Volume: external marketstack API `v1/intraday/latest` (HTTP, API key hardcoded in the file). No `SECURITY_ID`, quantity, ticker or volume → `false`. Despite the name, it uses the latest intraday volume, not an average. |
| `sic_restriction_rule` · SIC Restriction Check | `VALUES`: SIC `LIKE` patterns; default `283%, 80%, 632%, 0273%, 0279%, 0741%, 0742%, 0752%, 2077%, 64%` (healthcare) | the issuer's SIC code matches | SMA: `POST /security-master/factset/fetch-healthcare-sic-codes` with `VALUES` + `entity_id`. DB: `cid` from `company_info`, then `refdata.company_extra` type `COMPANY_SIC` with the **hardcoded** default patterns (`VALUES` ignored). |
| `family_member_check_rule` · Family Member Check | `ATTRIBUTE_TYPE`, an account attribute | the preclearance's account has `ATTRIBUTE_TYPE` = `yes` (case-insensitive) | `attribute_extra`: the disclosure's (`DISCLOSURE_ID`) active `ACCOUNT_ID` → that account disclosure's active `ATTRIBUTE_TYPE` value. |
| `check_past_transaction_rule` · Holding Period Rule | `NO_OF_DAYS`, `TRANSACTION_TYPE` = `buy`\|`sell`, `PRICE_CHECK` (default `false`), `PRICE_CHECK_OPERATOR` (default `LESS_THAN`) | the employee has a `TRANSACTION_TYPE` trade in the same security (any listing) within the last `NO_OF_DAYS` days (from now, not from the disclosure date) | `bk_txn` ⨝ `bk_txn_extra` `SECURITY_ID` ∈ `MATCHED_SECURITIES`, owner = `DISCLOSURE_CREATED_BY`. With `PRICE_CHECK`: also `bt.price <op> CURRENT_SECURITY_PRICE`. **Price 0 (unknown) → returns `REVIEW` directly**, ignoring the actions. No `MATCHED_SECURITIES` → `false`. `PRECLEAR_ACTION` is not used. |
| `check_restricted_countries_rule` · Restricted Countries Check | `COUNTRIES` (ISO codes) | the security's country is in the list | SMA: `SECURITY_INFO.iso_country`. DB: `refdata.company_info.country_code` for any of `MATCHED_SECURITIES`; **throws** if there are none. |
| `auth0_check_rule` · Role Check | `ROLES`, `ATTRIBUTE_TYPE` (e.g. `AUTH0_ROLE`, or `DEPARTMENT`) | the employee has one of `ROLES` | `DEPARTMENT`: `userdb.users` ⨝ `userdb.departments`, `dept_name IN ROLES`. Otherwise: active `userdb.user_extra` values of type `ATTRIBUTE_TYPE`. Needs `DISCLOSURE_CREATED_BY`. |
| `pre_clear_frequency_rule` | `VALUE` (number) | the employee already has ≥ `VALUE` approved preclearances this month | Counts active `STATUS` attributes equal to the `APPROVE` label on `TRADE_PRECLEARANCE` disclosures owned by `DISCLOSURE_CREATED_BY`, with `created_date` in the same calendar month as `DISCLOSURE_CREATED_DATE`. Both fields required. |
| `annual_gift_limit_rule` · Annual Gift Limit Rule | `LIMIT` (number), `CHECK_PERIOD` = `YEAR` (optional) | the gift stays **within** the limit (note: IN = OK) | See 7.6. |
| `multi_rule` · Multi Rule | `MULTI_RULE_MODE` | see 7.1 | children |
| `catchall_setinreview_rule` · Exception Rule | none | always: returns `REVIEW` (actions ignored) | none |

Owner of a disclosure or trade = `created_by` on AWS, `COALESCE(owner, created_by)` on Azure (`getOwnerColumn`, `libs/helper.ts`).

### 7.3 Restrictions (`security_list_rule`, `wildcard_security_list_rule`)
**Loading** (`getRestrictionListData`, `rulesEngineV2/service.ts`), once per top-level rule that asks for it:
- Finds `RESTRICTION` disclosures (`disclosures` ⨝ `disclosure_types`) that are `is_active` and whose active attributes include:
  - `SECURITY_ID` ∈ `MATCHED_SECURITIES`, or `CID` = `ENTITY_ID`
  - a `RESTRICTION_LIST_ID` → `restriction_lists.restriction_list_name` (the list name)
- **Active restrictions**: no active `STATUS` of `Cleared` / `Inactive`. Returned with all their active attributes.
- **Cleared restrictions**: only loaded when some list rule in the config has `NO_OF_DAYS`. Active `STATUS` `Cleared`/`Inactive` set within the largest `NO_OF_DAYS` of all list rules. Returned with the clear date, without attributes.
- Neither security nor entity known → no restrictions.
- Restrictions are firm-wide lists. "Who is restricted" is expressed through attributes (below), not through the query.

**Matching** (`security_list_rule.ts`, `services/RestrictionService.ts`, `services/AttributeMatcher.ts`):
1. Keep restrictions whose list name matches `LIST_NAME` with `COMPARISON_OPERATOR`:
   - `LIKE` / `NOT LIKE`: SQL-style `%` and `_` wildcards, case-sensitive
   - `EQUAL_TO` / `NOT_EQUAL_TO`: case-insensitive
2. With `NO_OF_DAYS`: also keep cleared restrictions cleared in the last `NO_OF_DAYS` days.
3. With `ATTRIBUTE_TYPE`: keep only restrictions whose attribute `ATTRIBUTE_TYPE` matches:
   - target value = context value of `ATTRIBUTE_VALUE_KEY` (e.g. `DISCLOSURE_CREATED_BY`, `CDS_DEPARTMENT_NAME`), else `ATTRIBUTE_VALUE`. No target value → the restriction is dropped.
   - `ATTRIBUTE_PARSE = true`: the attribute is a JSON array; with `ATTRIBUTE_DATA_PATH` each object is reduced to that path (lodash `get`). Use `ATTRIBUTE_OPERATOR = CONTAINS` to test membership.
   - Cleared restrictions have no attributes, so an attribute filter always drops them.
4. Any restriction left → IN. Matched list names go to `executionDetails.listNames`.

Example: "deny if the employee is an MNPI insider on this security":
```json
{ "key": "security_list_rule", "action_in": "DENY",
  "parameters": { "LIST_NAME": "%", "COMPARISON_OPERATOR": "LIKE",
                  "ATTRIBUTE_TYPE": "RESTRICTION_MNPI_INSIDERS", "ATTRIBUTE_VALUE_KEY": "DISCLOSURE_CREATED_BY",
                  "ATTRIBUTE_OPERATOR": "CONTAINS", "ATTRIBUTE_PARSE": true, "ATTRIBUTE_DATA_PATH": "value" } }
```
(the attribute name comes from `client-db-schema.md`; the `ATTRIBUTE_DATA_PATH` value is illustrative)

### 7.4 Trading windows
- `TRADING_WINDOW_BUY_OPEN` / `TRADING_WINDOW_SELL_OPEN` (`getTradingWindowData`, query `TRADING_WINDOW_QUERY` in `rulesEngineV2/queries.ts`):
  - pivots `attribute_extra` rows of types `WINDOW_OPEN`, `WINDOW_CLOSE`, `WINDOW_TYPE`, `STATUS` per `attribute_id`
  - keeps windows with `STATUS = 'Active'` and `window_open <= DISCLOSURE_CREATED_DATE <= window_close`
  - a `WINDOW_TYPE` JSON array (`["BUY","SELL"]`) containing `BUY` / `SELL` sets that flag to `'Yes'`
- Details that matter:
  - The comparison is on **text** values, so dates must be in a sortable format such as `YYYY-MM-DD` (inferred).
  - No `disc_type` filter. Any disclosure with these attributes counts.
  - `WINDOW_OPEN` rows are read even when `is_active = false`; the largest value wins (`MAX`).
- To use it, put the flag in a `comparison_rule`, e.g. `KEY: TRADING_WINDOW_BUY_OPEN, VALUES: ['Yes'], OPERATOR: EQUAL_TO` (inferred usage; no seed config does this).
- `trading_window_rule` is unrelated: it compares the creation date against a static `DATE` list in the config.

### 7.5 `comparison_rule` operators
`value = await getContextValue(KEY)`.

| `OPERATOR` | IN when |
|---|---|
| `EQUAL_TO` | `VALUES` includes `value` (exact, case-sensitive) |
| `NOT_EQUAL_TO` | `VALUES` does not include `value` |
| `LESS_THAN`, `LESS_THAN_EQUAL_TO`, `GREATER_THAN`, `GREATER_THAN_EQUAL_TO` | `parseInt(value) <op> parseInt(VALUES[0])` |
| `IS_EMPTY` | `value` is **truthy** (despite the name). With `KEY: SECURITY_INFO_IS_EMPTY` this reads as "security info is empty". |

### 7.6 Gifts (`annual_gift_limit_rule`)
For `GIFT_ENTERTAINMENT` disclosures.
1. `GE_VALUE` (required) is the gift value. `GE_PARTICIPANT_LIST` is a JSON array; each item gives an employee `EMPLOYEE_NAME.value` (user key) and/or a company `CID.value`.
2. No participants → IN if `GE_VALUE <= LIMIT`, else NOT IN.
3. With `CHECK_PERIOD = YEAR` (needs `GE_CATEGORY`, `GE_DIRECTION`, `GE_DATE`, `DISCLOSURE_CREATED_BY`), it also loads the employee's past gifts. These are active `GIFT_ENTERTAINMENT` disclosures with:
   - active `STATUS` = the `APPROVE` label
   - `GE_DATE LIKE '<year>-%'`
   - the same `GE_CATEGORY` and `GE_DIRECTION`
4. Each gift's value (past gifts and the current one) is split evenly across its participants, then summed per employee and per company.
5. Any employee or company total > `LIMIT` → NOT IN; else IN.

(V3 additionally has `ge_participant_rule`, section 11.)

---

## 8. Reading the config (`clientRuleConfigV2`)

`GET …/fetch-client-rule-config-v2?ClientID=sand&UI=true&configVersion=…` (`clientRuleConfigV2/service.ts`). Read-only summary, used to display a client's setup (inferred: by the client app or admin UI).
- `re`: one row per top-level preclear rule: `Order`, `RuleName`, `RuleFriendlyName`, `Purpose`, `Config`, `Action` (labels).
  - `UI=true`: a `multi_rule` is one row.
  - `UI=false` (default): one row per child, with `ChildOrder`.
- `tp`: the trade-process settings from `trade_configs_v2.parameters` and `trade_status_config` (keys in `TP_KEYS`). See `trade-process.md`.
- `configVersion` is applied to **both** the preclear and the trade config lookup. A preclear version id will usually find no trade config, so `tp` comes back empty (inferred).
- The swagger response schema (`rules`, `configVersion`) does not match the real response (`client`, `re`, `tp`).

---

## 9. Execution details and logging

**`executionHistory` entry** (`libs/ruleExecutionDetails.ts`):

| Field | Meaning |
|---|---|
| `ruleId`, `ruleKey` | rule from the config |
| `terminalStatus` | key or `false` |
| `executionTimeMs` | duration, 3 decimals |
| `executionDetails` | `multi_rule`: `{ childRules: [statuses] }`; list rules: `{ listNames }`; others: none |

**Logging** (`libs/logger.ts`):
- Child logger with `disclosureId`, `configVersion`, `clientId`.
- Per rule: a child logger with `service = <rule key>` and `ruleId`; it logs the rule's parameters.
- Logged: the whole request `ParamValue` (`Recieved disclosure request`), every loaded context value, SMA calls, and every central and client DB query with its bind values (the `createDBConnections` log callback).
- The loaded config is logged by `ClientConfigService` (`@logger.AsyncLogs`).

---

## 10. Errors, alerts, AWS vs Azure

### 10.1 Errors (V2)

| Case | HTTP | Alert |
|---|---|---|
| Body fails validation (`parseDisclosurePayload`) | 400 `REQUEST_VALIDATION_ERROR` | yes |
| A rule needs a missing field (`MissingDisclosureParameterError`, a `ValidationError`) | 400 | yes |
| Client / config not found, SMA failure, DB error, no rule decided, rule exception | 500 `INTERNAL_SERVER_ERROR` | yes |
| Invalid JSON body (Lambda, `middyfy`) | 400 | no |

- Stack traces are left out of responses on `PROD` and `SAND` (`isProductionOrSandbox`).
- **Alert** = `alert()` (`libs/alert.ts`), subject `Rules Engine Express | <CLIENT> | <DISCLOSURE_TYPE>` (also on the AWS Lambda). With Slack on, it goes to `SLACK_CHANNEL_ID`. With Slack off, it goes to the SNS error topic on AWS and nowhere on Azure.
- SMA calls are retried up to 5 times, `SMA_RETRY_DELAY` ms apart (default 5000), except 4xx responses other than 401/403 (`libs/sma/smaClient.ts`). With several slow SMA calls this can approach the 59 s Lambda timeout (inferred).

### 10.2 AWS vs Azure

| | AWS | Azure |
|---|---|---|
| Runtime | Lambda behind API Gateway | Express server (`server/`) |
| V3 endpoints | yes | no |
| `SMA` flag | taken from the request | **forced to `'true'`** (`rulesEngineController.ts`, "temporary workaround") |
| Owner column in rule SQL | `created_by` | `COALESCE(owner, created_by)` |
| Central DB | Secrets Manager `CENTRAL_DB_SECRET`; connection closed after each request | `DB_*` env vars; one connection kept for the server's life |
| Client DB | assume role + Secrets Manager | Key Vault (`tenantId`) |
| Alerts without Slack | SNS | not sent |

---

## 11. Legacy V3 (`rulesEngineV3`, `clientRuleConfigV3`, `libs/rulesV3.0`)

AWS only. Uses the legacy tables, which this repo does not create (`central-db-schema.md`).

**Config:**
```sql
SELECT pr."order", pr.rule_name, pr.rule_config, pr.action_in, pr.action_not_in, c.client_config
  FROM rulesenginedb.preclear_rules pr JOIN rulesenginedb.clients c ON pr.client_id = c.client_id
 WHERE pr.client_id = :client_id AND pr.disclosure_type = :disclosure_type AND c.is_active = true
 ORDER BY pr."order";
```
- Rules are filtered **by disclosure type** (unlike V2). Labels come from `clients.client_config.DECISION_CONFIG`.
- `clientRuleConfigV3` only returns `{ activeRules: { <rule_name>: { status: true } } }` for the client (all disclosure types).

**How it differs from V2:**
- **No client DB.** All data comes from the request (`ParamValue`) plus one SMA pre-fetch of `SECURITY_ID` (`SecurityDetails`). The caller must send precomputed data, e.g. `RESTRICTION_LISTS`, `USER_DATA`, `LAST_BUY_TRADE_DETAILS`, `CURRENT_SECURITY_PRICE`.
- A rule returns a status key or a falsy value. The first truthy one wins. No rule decided → `REVIEW` label with `PriorityIndex = rowCount + 1`, plus an alert `No Rule reached Terminal Status`.
- Response: `PriorityIndex`, `TerminalStatus`, `RuleFriendlyName`, `Purpose`, `TerminalStatusHistory`. No `executionHistory`.
- `ClientID` max 10 characters.

| V3 rule | Condition true when | Differs from V2 |
|---|---|---|
| `sec_type_rule` | `SecurityDetails.security_type_code` ∈ `VALUES` | SMA only |
| `ticker_check_rule` | `SecurityDetails.ticker` ∈ `VALUES` | parameter `VALUES`, not `STOCK_SYMBOLS` |
| `security_list_rule` | a `VALUES` list name ∈ request `RESTRICTION_LISTS` | lists come from the request; with `action_not_in` set it decides on the first list only |
| `comparison_rule` | `ParamValue[KEY]` ∈ `VALUES`, or `LT`/`GT`/`GTE`/`LTE` vs `VALUES` | short operator names; numeric check uses only the first value |
| `auth0_check_rule` | `USER_DATA[KEY]` ∈ `VALUES` | user data from the request |
| `check_past_transaction_rule` | Sell: last buy within `NO_OF_DAYS` and current price > buy price. Buy: last sell within `NO_OF_DAYS` and current price < sell price. | trade details from the request; uses `PRECLEAR_ACTION` |
| `sic_restriction_rule` | SMA healthcare SIC check on `entity_id` | SMA only |
| `average_volume_rule` | same threshold as V2 | API key from env `AVERAGE_VOLUME_API_KEY`; throws without `PRECLEAR_QUANTITY` |
| `ge_participant_rule` | a participant in `GE_PARTICIPANT_LIST` has `KEY` (default `PARTICIPANT_TYPE`) ∈ `VALUES` | V3 only |
| `multi_rule` | children = keys of `rule_config` (except `RULE_NAME`, `MULTI_RULE_MODE`, `ACTION`); each child names its `RULE_NAME` and may override `ACTION.IN/NOTIN`. AND: any falsy → parent `action_not_in`; else the last result. OR: first truthy. | children inline in JSON, not by `parent_id` |

A `rule_name` without a `RuleFriendlyNameMapping` entry, or without a function in `libs/rulesV3.0`, makes the handler throw → 500.

---

## 12. Worked example (V2)

Config (from section 5): `r1` restriction list → `m1` (AND: `c1` share, `c2` buy window open) → `z9` catch-all.
Client SAND on Azure (so `SMA = 'true'`); `preclear_status_config.APPROVE = 'Approved'`.

Request: employee `h-pdl-knbi` wants to buy security `C4C0BL-R` on `2024-08-28`.

| Step | What happens | Result |
|---|---|---|
| 0 | Validate body. Load `clients_v2` SAND, its active `preclear_configs_v2`, and SMA security types. Open the SAND client DB. | – |
| 1 | `r1` `security_list_rule`: loads `MATCHED_SECURITIES` (SMA security-match), `SECURITY_INFO` → `ENTITY_ID`, then `RESTRICTION_LIST_RECORDS` (client DB). No active restriction on a list named like `Restriction List`. | NOT IN, no `action_not_in` → `false`, continue |
| 2 | `m1` `multi_rule` AND, child `c1` `sec_type_rule`: `SECURITY_INFO` is loaded **again** (new top-level rule), `security_type_code = 'SHARE'` ∈ `["SHARE"]` | `APPROVE` |
| 3 | child `c2` `comparison_rule`: `TRADING_WINDOW_BUY_OPEN` → query on `attribute_extra` for 2024-08-28 finds an active window with `["BUY"]` → `'Yes'` ∈ `["Yes"]` | `APPROVE` |
| 4 | AND finished: all children decided → last child's status | `m1` = `APPROVE` → stop |
| 5 | `z9` is not run. Map `APPROVE` → `Approved`. Close the client DB. | 200 |

Response `data` (abridged):
```json
{ "DISCLOSURE_ID": "…", "TerminalStatus": "Approved", "RuleName": "multi_rule",
  "RuleFriendlyName": "Multi Rule", "TerminalStatusHistory": "Multi Rule:APPROVE|",
  "executionHistory": [
    { "ruleKey": "security_list_rule", "terminalStatus": false, "executionDetails": { "listNames": [] } },
    { "ruleKey": "sec_type_rule", "terminalStatus": "APPROVE" },
    { "ruleKey": "comparison_rule", "terminalStatus": "APPROVE" },
    { "ruleKey": "multi_rule", "terminalStatus": "APPROVE", "executionDetails": { "childRules": ["APPROVE", "APPROVE"] } } ] }
```
If the buy window had been closed, `c2` would return `false`, the AND would return `false`, and `z9` would return `REVIEW` → `In Review`.

---

## 13. Settings

| Setting | Where | Used for |
|---|---|---|
| `clients_v2.preclear_config_version` | central DB | active rule chain |
| `clients_v2.preclear_status_config` | central DB | status labels |
| `preclear_configs_v2.rules` | central DB | the rule chain |
| `rulesenginedb.clients.client_config.DECISION_CONFIG`, `rulesenginedb.preclear_rules` | central DB (legacy) | V3 |
| `APP_ENV` (`AWS`/`AZURE`), `NODE_ENV` (stage) | env | owner column, credentials, alerts, stack traces |
| `CENTRAL_DB_SECRET` (AWS), `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`, `DB_LOCAL` | env | central DB |
| `CLIENT_DB_LOCAL`, `CLIENT_DB_*` | env | local client DB |
| `SMA_URL`, `SMA_AUTH` (default true), `SMA_RETRY_DELAY` (default 5000), `SMA_KEYCLOAK_*` | env | SMA calls |
| `SLACK_ENABLED`, `SLACK_TOKEN`, `SLACK_CHANNEL_ID`, `AWS_SNS_ERROR_TOPIC_ARN` | env | alerts |
| `PORT` (default 3000), `RULES_ENGINE_API_BASE_URL`, `SWAGGER_SPEC_PATH` | env | Azure Express server and Swagger |
| `DEFAULT_FUNCTION_ROLE` | env at deploy time | Lambda IAM role |
| `AVERAGE_VOLUME_API_KEY` | env | V3 `average_volume_rule` only |

**Tests:** unit tests for the rules, the helper and V3 rules are in `tests/unit/functions/libs/{rules,rulesV3.0}`, `tests/unit/rulesEngineV2`. Run `npm run test:unit` from `rules-engine-3.0/`. Integration tests: `npm run test:integration[:aws|:azure]`.

---

## 14. Notes and unknowns

- **Who calls the engine and saves the decision** is not in this repo. Inferred: the client compliance app, which then writes the disclosure `STATUS`.
- **Unexpected behaviour seen in code:**
  - The context cache does not survive between top-level rules (section 6), so SMA and DB lookups repeat.
  - `comparison_rule` `IS_EMPTY` is IN for non-empty values.
  - `sic_restriction_rule` ignores `VALUES` on the DB path.
  - `check_past_transaction_rule` returns `REVIEW` when the price is unknown, whatever its actions.
  - The trading-window query has no disclosure-type filter, compares dates as text, and includes inactive `WINDOW_OPEN` values.
  - `covered_party_bypass_rule` ignores the attribute's value and `is_active`.
  - `TerminalStatusHistory` shows the status key, not the label.
  - The `Config` text of `family_member_check_rule` shows `action_in` for both YES and NO.
- **Not determined:**
  - real security type codes (`sec_type_rule.VALUES`) beyond the seed values `SHARE`, `CRYPTO`
  - the disclosure type that holds trading windows
  - the date format the client app sends in `DISCLOSURE_CREATED_DATE` and window attributes
  - whether any production config attaches children to a non-`multi_rule` rule
  - whether API Gateway requires an API key or authorizer for these routes (nothing in `serverless/public/serverless.ts` shows one)
  - the production content of the legacy tables `rulesenginedb.clients` / `preclear_rules`, and whether V3 is still called
- `average_volume_rule` (V2) calls an external API over plain HTTP with a key hardcoded in source.
