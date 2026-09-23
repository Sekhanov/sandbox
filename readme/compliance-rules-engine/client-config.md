# Client configuration and onboarding

How a client is described in the central DB, how the code reads that config, and how to add or change it.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `central-db-schema.md`, `client-db-schema.md`, `preclear-rules-engine.md`, `trade-process.md`, `trade-alerts.md`, `holdings-process.md`, `accounts-and-feedback.md`, `runtime-overview.md`.

---

## 1. Overview

A client's config lives in three tables of the `rulesenginedb` schema in the **central DB**:

```
rulesenginedb.clients_v2  (one row per client)
  ├─ environment / stage / region      → which deployment's jobs pick the client up
  ├─ aws_environment / azure_environment → how to reach the client DB
  ├─ tasks_config                      → which jobs run for the client, and how
  ├─ trade_status_config / preclear_status_config → status labels written to the client DB
  ├─ preclear_config_version ──► preclear_configs_v2.version  (preclear rules, many versions)
  └─ trade_config_version ─────► trade_configs_v2.version     (trade-process parameters, many versions)
```

| Question | Answer |
|---|---|
| Who reads it | Every job and API, through `services/ClientConfigService.ts` (section 6) |
| Who writes it | Migrations, `scripts/migrateConfigs.ts`, the local seeders, `rulesenginedb.fn_migrate_config_to_azure()`, manual SQL (section 8) |
| Is there an API to edit configs | **No.** The config endpoints are read only (`GET rules-engine/v2.0/fetch-client-rule-config-v2`, `GET rules-engine/v3.0/fetch-client-config`) |
| Versioning | Config rows are versioned by UUID. A published version can't be updated. A client points to one published version of each type (section 3) |
| Caching | None for config. Each job run, SQS message and API call reads the rows again (section 6.4) |

---

## 2. `rulesenginedb.clients_v2`

### 2.1 Columns

| Column | DB type | Null | Meaning | Added by |
|---|---|---|---|---|
| `id` | CITEXT PK | no | Client code, e.g. `sand`. Compared case-insensitively with `trade_data.pdl_client_code`. The `Client` model lowercases it (`models/client/Client.ts`), so rows written by the repository have lowercase ids | 00 |
| `name` | VARCHAR | no | Display name. `fn_migrate_config_to_azure` appends ` \| sandbox` / ` \| prod` | 00 |
| `environment` | `rulesenginedb.environment_enum` | no | `AWS` / `AZURE`. Which cloud's jobs process the client | 01 |
| `stage` | `rulesenginedb.stage_enum` | no | `LOCAL`, `DEV`, `TST`, `SAND`, `PROD` | 05 |
| `region` | `rulesenginedb.region_enum` | yes | `westeurope`, `eastus`, `uaenorth` (13), `canadacentral` (17). Only filtered on Azure. AWS clients have `NULL` | 06 |
| `preclear_config_version` | UUID FK → `preclear_configs_v2.version` | yes | Active preclear config. `ON DELETE SET NULL` | 00 |
| `trade_config_version` | UUID FK → `trade_configs_v2.version` | yes | Active trade config. `ON DELETE SET NULL` | 00 |
| `trade_status_config` | JSONB | no | Trade result labels (2.2) | 00 |
| `preclear_status_config` | JSONB | no | Preclear decision labels (2.3) | 00 |
| `aws_environment` | JSONB | no | AWS client DB access (2.4) | 00 |
| `azure_environment` | JSONB | no | Azure client DB access (2.4). Migration 01 set `{"tenantId": <id>}` for every existing row | 01 |
| `tasks_config` | JSONB | yes | Per-job settings (2.5) | 01 |
| `created_at`, `updated_at` | timestamptz | no | Sequelize timestamps | 00 |

Trigger `trg_check_client_configs_published` (BEFORE INSERT OR UPDATE) runs `check_client_configs_published()`: a non-null version must be a **published** config **of the same client** (`client_id = NEW.id`), otherwise the statement fails.

### 2.2 `trade_status_config`

The labels the trade process writes as `match_status` into the client's `bk_txn`. The rules use the **keys**; the client sees the **values**.

| Key | Set when (`serverless/public/functions/tradeProcessV2/tradeProcess.ts`) |
|---|---|
| `PENDING_MATCH_STATUS` | Default after `cookData`; holding-period hit; no approved preclear found |
| `MATCH_STATUS` | Preclear matched (only this value keeps `disc_id`) |
| `PRECLR_NOT_NEEDED` | Non-trade (RNR), US government, security type / universe / option close |
| `MANAGED_ACCOUNT` | Managed account and `MANAGED_ACCOUNT_APPLY_RULES = false` |

```json
{ "MATCH_STATUS": "Matched", "PENDING_MATCH_STATUS": "Pending Match",
  "PRECLR_NOT_NEEDED": "Preclear Not Needed", "MANAGED_ACCOUNT": "Managed Account" }
```

Schema: `tradeStatusConfigSchema = z.record(tradeStatusSchema, z.string())` in `libs/tradeRules/validation.ts`. With `zod/v4` a record keyed by an enum is exhaustive, so **all four keys are required** (empty strings pass).

### 2.3 `preclear_status_config`

Labels for preclear decisions, used by the rules engine and by trade matching (`preclearStatusConfig.APPROVE` is the status of approved preclears that `ownerMatch` / `preClrApprvd` look for).

```json
{ "APPROVE": "Approved", "DENY": "Denied", "REVIEW": "In Review", "OTHER": "Other" }
```

Schema: `preclearStatusConfigSchema = z.record(preclearStatusSchema, z.string().nonempty())` in `libs/rules/validation.ts`. All four keys are required and must not be empty.

### 2.4 `aws_environment` and `azure_environment`

Schemas in `storage/models/ClientStorage.ts`. **Both columns are always required and validated**, whatever the client's `environment`.

```json
// aws_environment
{ "db": { "roleArn": "<iam-role-arn>", "secretName": "<secret-name>", "region": "us-east-1" },
  "backendUrl": "<optional, stored but not read by any code>" }

// azure_environment
{ "tenantId": "<tenant-alias>" }
```

How they are used (`storage/clientDb.ts`). The choice depends on the **running** cloud (`APP_ENV`), not on the client's `environment` column:

| Runtime | Credentials come from |
|---|---|
| `DB_LOCAL`-style local mode (`localClientDbConnection.local`) | env vars; database `compliance-<id>` unless set |
| AWS | assume `db.roleArn`, then read Secrets Manager secret `db.secretName` in `db.region` |
| Azure | Key Vault secrets `<ENVIRONMENT>-<tenantId>-compliance-{host,port,dbname,user,password}` (`serverless/public/functions/tradeProcessV2/azure/tenantCredentials.ts`). `ENVIRONMENT` is an env var; its values are not in this repo |

Azure clients created by `fn_migrate_config_to_azure` get the placeholder `{"db":{"region":"","roleArn":"","secretName":""}}` (passes validation, never used).

### 2.5 `tasks_config`

Schema `tasksConfigSchema` in `storage/models/ClientStorage.ts` (nullable; every task block optional). Matching TS types: `models/client/Client.ts`.

| Path | Type | Req. | Default | Effect | Read by |
|---|---|---|---|---|---|
| `tradeProcess.enabled` | boolean | yes | – | Client is picked by `trade-process-job` | `ClientRepository` filter `tradeTaskEnabled` |
| `tradeProcess.tradeStatus` | string | yes | – | **Raw SQL** pasted into `{{STATUS_REPLACE}}` of `FETCH_TRADE_RECORDS`, e.g. `status = 'TRADE'` or `(status = 'TRADE' OR status like '%RNR%')`. Also used by the Stuck / pending alert query | `tasks/tradeProcess/services/tradeProcessService.ts`, `tasks/tradeAlerts/tradeAlertsQuery.ts` |
| `tradeProcess.transactionDate` | string (date) | yes | – | Only trades with `DATE(transaction_date) >= <value>` are fetched | same |
| `tradeProcess.manualUploadOnly` | boolean | no | `false` | Adds `AND source = 'Manual Upload'` (only manual uploads are processed) | `tradeProcessService.ts` |
| `holdingsProcess.enabled` | boolean | yes | – | Client is picked by `holdings-process-job` | filter `holdingsProcessTaskEnabled` |
| `holdingsProcess.postProcess` | boolean | yes | – | After loading, run holdings status update (deactivate old / activate new holdings) | `services/holdings/holdingsService.ts` |
| `holdingsProcess.manualUploadOnly` | boolean | no | `false` | **Skips loading holdings entirely** (returns no rows). Different from the trade flag of the same name | `holdingsService.ts` `getNonProcessedHoldings` |
| `holdingsProcess.deactivationUser` | string | no | `'holding-process'` (Zod default at read time) | User recorded as the deactivator in the status update | `services/holdings/holdingsStatusUpdateService.ts` |
| `accountsLoad.enabled` | boolean | yes | – | Client is picked by `account-job` | filter `accountsLoadTaskEnabled` |
| `feedbackProcess.enabled` | boolean | yes | – | Client is picked by `feedback-process-job` and accepted by the bulk-feedback API | filter `feedbackProcessTaskEnabled` |

Example:
```json
{
  "tradeProcess":   { "enabled": true, "tradeStatus": "status = 'TRADE'", "transactionDate": "2024-04-01", "manualUploadOnly": false },
  "holdingsProcess": { "enabled": true, "postProcess": true, "manualUploadOnly": false },
  "accountsLoad":   { "enabled": true },
  "feedbackProcess": { "enabled": true }
}
```

Notes:
- A task block that is missing, or `tasks_config = NULL`, means the job skips the client (the filters test `tasks_config.<task>.enabled = true`).
- Unknown keys are dropped by Zod on read (inferred from default `z.object` behaviour). The old key `holdingsPostProcess` (migration 04) was removed by migration 07.

### 2.6 Validation behaviour

`storage/repositories/ClientRepository.ts` validates every JSON column with the schemas above **on read and on write**.

| Call | On invalid JSON |
|---|---|
| `getById` | throws (Zod error) |
| `getAll` (all job filters) | logs `Error building client model` and **silently drops the client** from the list |
| `upsert` | throws before writing |

The DB itself has no JSON checks, so a hand-written bad row disappears from all jobs without an alert (only a log line).

---

## 3. Versioned configs: `preclear_configs_v2` and `trade_configs_v2`

### 3.1 Columns

Both tables have the same shape (migration 00, `storage/models/PreclearConfigStorage.ts`, `TradeConfigStorage.ts`):

| Column | Type | Meaning |
|---|---|---|
| `version` | UUID PK, default `uuid_v4` | Version id |
| `client_id` | CITEXT FK → `clients_v2.id`, `ON DELETE CASCADE` | Owner client |
| `name` | VARCHAR | Free text, by convention the ticket (e.g. `COR-6031: Migrated config from AWS`, or `p_ticket_name` of the Azure migration) |
| `is_published` | BOOLEAN | Published = frozen and usable as active version |
| `rules` (preclear) / `parameters` (trade) | JSONB | Section 5 / section 4 |
| `created_at`, `updated_at` | timestamptz | Timestamps |

### 3.2 Publishing rules (triggers)

| Trigger | On | Rule |
|---|---|---|
| `trg_forbid_update_if_published_preclear`, `trg_forbid_update_if_published_trade` → `forbid_update_if_published()` | BEFORE UPDATE on each config table | If `OLD.is_published = TRUE` → `Cannot update a published config`. Also fires for `INSERT … ON CONFLICT DO UPDATE` (Sequelize `upsert`) |
| `trg_check_client_configs_published` → `check_client_configs_published()` | BEFORE INSERT OR UPDATE on `clients_v2` | Active versions must be published and belong to the client |

What this allows:
- Draft (`is_published = false`) rows can be edited freely, and published by `UPDATE … SET is_published = true` (OLD is still `false`).
- Published rows can't be edited or unpublished. **DELETE is not blocked.** Deleting the active version sets the client's version column to `NULL` (FK `SET NULL`), and the jobs then fail with "No configuration found".
- Deleting a client deletes all its configs (CASCADE).

Function bodies live in `plpgsql/pre-migrations/rulesenginedb.*.sql` (deployed by `storage/applyDbFunctions.ts`) and were first created in migration 00.

### 3.3 How the active version is chosen

`ClientConfigService.getPreclearConfig(clientId, configVersion?)` / `getTradeConfig(...)`:

| `configVersion` | Filter (`storage/repositories/PreclearConfigRepository.ts`, `TradeConfigRepository.ts`) |
|---|---|
| not given (all jobs) | `client_id = :id AND (version, client_id) IN (SELECT <type>_config_version, id FROM rulesenginedb.clients_v2)`, i.e. the version the client points to |
| given | `client_id = :id AND version = :configVersion`. **No `is_published` check**: any version of that client, drafts included |

`configVersion` can be passed to:
- `rulesEngineV2` (preclear rules engine) request body: preclear config only
- `clientRuleConfigV2` query: used for **both** preclear and trade lookups. A UUID can only match one table, so the other comes back `null` (inferred)
- `tradeProcessV2/api` query: trade config only

There is no history of which version was active when. Only the current pointer is stored.

---

## 4. `trade_configs_v2.parameters`

Schema: `tradeParametersSchema` (`libs/tradeRules/validation.ts`), validated on read and write by `TradeConfigRepository`. An invalid row throws when it is loaded. Used by `tradeProcess()` in `serverless/public/functions/tradeProcessV2/tradeProcess.ts` (step names as in `trade-process.md` §6.2), unless stated otherwise.

"Status key" below means one of `MATCH_STATUS`, `PENDING_MATCH_STATUS`, `PRECLR_NOT_NEEDED`, `MANAGED_ACCOUNT`, or `false` (= do nothing). It is turned into a label through `trade_status_config`.

| Key | Type (req.) | Meaning | Used in |
|---|---|---|---|
| `EXCLUDE_RULE` | bool (yes) | Don't load trades of accounts whose `account_status` is `INACTIVE` or whose `account_type` is `ACCOUNT CANNOT HOLD COVERED SECURITIES` | `loadToTarget` |
| `SET_VALUES_ZERO` | bool (yes) | Turn on `ZERO_VALUES` | `cookData`, `updateElectraDb` (`tradeProcessV2/service.ts`) |
| `ZERO_VALUES` | string[] (yes) | Trade fields set to `0` before loading (e.g. `price`, `quantity`, `amount`). The zeroed values are also written back to `brokerdb.trade_data` | same |
| `LOAD_MANAGED_ACCOUNTS` | bool (yes) | Load trades whose `match_status` is the `MANAGED_ACCOUNT` label. If `false`, they are marked processed but not loaded | `loadToTarget` |
| `MANAGED_ACCOUNT_APPLY_RULES` | bool (yes) | `true`: run all rules for managed accounts too. `false`: managed account → `MANAGED_ACCOUNT`, done | `managedAccount` |
| `PRECLEAR_NOT_NEEDED_US_GOV` | bool (yes) | Security's `entity_id` = US government → `PRECLR_NOT_NEEDED`, done | `usGovCheck` |
| `PRECLEAR_NOT_NEEDED_SEC_TYPE` | string[] (yes) | Security type codes (e.g. `ETF_ETF`, `MF_O`) → `PRECLR_NOT_NEEDED` | `preclearNotNeeded` |
| `PRECLEAR_NOT_NEEDED_SEC_TYPE_WITH_REGION` | `{SEC_TYPES[], AUTH0_CHECK_RULE{ATTRIBUTE_TYPE, ATTRIBUTE_VALUES[], ACTION{IN,NOT_IN}}}[]` (yes) | Security type matches **and** the account owner's user attribute check (e.g. `REGION` = `Canada`) gives a status key → that status | `preclearNotNeeded` |
| `PRECLEAR_NOT_NEEDED_UNIVERSE_TYPE` | string[] (yes) | Security universe types (e.g. `FI`) → `PRECLR_NOT_NEEDED` | `preclearNotNeeded` |
| `PRECLEAR_NOT_NEEDED_OPTION_CLOSE` | bool (yes) | Option/future with a closing transaction type (`sell`, `buy to close`, `sell to cover`, …) → `PRECLR_NOT_NEEDED` | `preclearNotNeeded` |
| `RESTRICTION_RULE` | array (yes) | Restriction-list checks, first rule with an action wins. Per item: `LIST_NAME[]` (matched with LIKE), `ACTION{IN,NOT_IN}`, optional `AUTH0_CHECK_RULE` (rule is skipped if the user check is false), optional `ATTRIBUTE_TYPE` / `ATTRIBUTE_VALUE` / `ATTRIBUTE_VALUE_KEY` (value taken from context data) / `ATTRIBUTE_OPERATOR` / `ATTRIBUTE_PARSE` / `ATTRIBUTE_DATA_PATH` to filter restrictions by their attributes | `restrictionCheck`, `tradeProcessV2/rules/securityListRule.ts` |
| `HOLDING_PERIOD` | bool (yes) | Enable the holding-period check. If `true`, `HOLDING_PERIOD_DAYS` must be > 0 (schema `refine`) | `holdingPeriodPreCheck`, `preclearMatch` |
| `HOLDING_PERIOD_DAYS` | number ≥ 0 (no) | Length of the holding period | same (`holdPeriodCheck`) |
| `HOLDING_PERIOD_DIRECTION` | `NoEarlySell` / `NoEarlyBuy` / `Both` (no) | Which opposite trade inside the period is a violation. Default in code: `NoEarlySell` | same |
| `HOLDING_PERIOD_ORDER` | `BEFORE_PRECLEAR_NOT_NEEDED` / `AFTER_PRECLEAR_MATCH` (no) | `BEFORE_PRECLEAR_NOT_NEEDED`: check runs before the "not needed" rules, a hit → `PENDING_MATCH_STATUS`, done. Anything else (incl. missing): check runs inside preclear matching, per matched preclear | same |
| `APPROVAL_WINDOW_BUS_DAYS` | number (yes) | Business days after the approval date during which a preclear covers a trade (approval day = day 0) | `preclearMatch` (`ownerMatch`, `fetchPreclearExpirationDate`) |
| `TIME_BASED_APPROVAL_WINDOW` | bool (yes) | Approvals after `RULE_TIME` get one extra business day | `preclearMatch` |
| `RULE_TIME` | string `HH:MM` (yes, may be `''`) | Cut-off time for `TIME_BASED_APPROVAL_WINDOW` | `preclearMatch` |
| `MATCHING_RESULTS` | `{VALUES: bool[3], ACTION: string}[]` (yes) | Which combinations of *[account match, transaction type match, quantity covered]* count as a match. `ACTION` is the **literal label** written as `match_status` (e.g. `"Matched"`), not a status key. First matching entry wins | `preclearMatch` → `combinationRule` (`tradeProcessV2/service.ts`) |
| `SIC_RULES` | `{SIC_CODES[], ACTION{IN,NOT_IN}}[]` (yes) | Issuer SIC code in list (`%` wildcards allowed, e.g. `28%`) → `IN` status, else `NOT_IN` status. Every rule runs; the last one that sets a status wins | `sicCheck` |
| `IGNORE_TRANSACTION_TYPE_MATCH` | `{FIELD_NAME, EXPECTED_VALUES[]}` (no) | In the schema and type only. **Not read by any code** | – |

`serverless/public/functions/clientRuleConfigV2/service.ts` also reads these keys to render the config for the UI (friendly names in `RuleFriendlyNameMapping`).

Minimal valid example (the seed's `baseConfig`, `seed/central/configs/tradeConfigs.ts`):
```json
{
  "EXCLUDE_RULE": false, "SET_VALUES_ZERO": false, "ZERO_VALUES": [],
  "LOAD_MANAGED_ACCOUNTS": false, "MANAGED_ACCOUNT_APPLY_RULES": false,
  "PRECLEAR_NOT_NEEDED_US_GOV": false, "PRECLEAR_NOT_NEEDED_SEC_TYPE": [],
  "PRECLEAR_NOT_NEEDED_SEC_TYPE_WITH_REGION": [], "PRECLEAR_NOT_NEEDED_UNIVERSE_TYPE": [],
  "PRECLEAR_NOT_NEEDED_OPTION_CLOSE": false, "RESTRICTION_RULE": [],
  "HOLDING_PERIOD": false, "APPROVAL_WINDOW_BUS_DAYS": 0,
  "TIME_BASED_APPROVAL_WINDOW": false, "RULE_TIME": "",
  "MATCHING_RESULTS": [{ "VALUES": [true, true, true], "ACTION": "Matched" }],
  "SIC_RULES": []
}
```

The trade config is **required** for the trade process: `getTradeConfig` throws `No trade configuration found` if the client has no active version.

---

## 5. `preclear_configs_v2.rules` (high level)

Rule details, parameters and evaluation: `preclear-rules-engine.md`.

**Stored shape** (snake_case, `preclearRulesStorageSchema` in `storage/models/PreclearConfigStorage.ts`): a flat array. Children of a `multi_rule` point to it with `parent_id`.

```json
[
  { "id": "<uuid-1>", "key": "security_list_rule", "action_in": "DENY", "action_not_in": "APPROVE",
    "parameters": { "LIST_NAME": "Restriction List", "COMPARISON_OPERATOR": "LIKE" } },
  { "id": "<uuid-2>", "key": "multi_rule", "parameters": { "MULTI_RULE_MODE": "AND" } },
  { "id": "<uuid-3>", "parent_id": "<uuid-2>", "key": "sec_type_rule", "action_in": "REVIEW",
    "parameters": { "VALUES": ["MF_O"] } },
  { "id": "<uuid-4>", "key": "catchall_setinreview_rule" }
]
```

- **Model shape**: the repository maps it to camelCase (`parentId`, `actionIn`, `actionNotIn`) and validates it with `preclearRulesSchema` (`libs/rules/validation.ts`), a discriminated union on `key` with one parameter schema per rule key.
- `action_in` / `action_not_in` are preclear status **keys** (`APPROVE`, `DENY`, `REVIEW`, `OTHER`), turned into labels through `preclear_status_config`.
- `models/preclearConfig/PreclearConfig.ts` builds a tree. Top-level rules (no `parent_id`) keep array order. Each rule gets an `order` number, assigned depth-first.
  - At least one top-level rule is required.
  - A `multi_rule` needs at least one child.
  - An unknown `key` throws.
- Rule keys accepted: `annual_gift_limit_rule`, `auth0_check_rule`, `average_volume_rule`, `catchall_setinreview_rule`, `check_past_transaction_rule`, `check_restricted_countries_rule`, `comparison_rule`, `covered_party_bypass_rule`, `family_member_check_rule`, `key_comparison_rule`, `multi_rule`, `pre_clear_frequency_rule`, `sec_type_rule`, `security_list_rule`, `wildcard_security_list_rule`, `sic_restriction_rule`, `ticker_check_rule`, `trading_window_rule`.

The preclear config is required by the preclear rules engine (`rulesEngineV2`: `Preclear Config not found for Client`). The trade process doesn't use it.

---

## 6. How code reads config

### 6.1 `services/ClientConfigService.ts`

| Method | Filter on `clients_v2` | Callers |
|---|---|---|
| `getClientConfig(id)` | `findByPk(id)` (CITEXT, case-insensitive); throws `Client not found` | trade process (job, SQS Lambda, API), rules engine, rule-config API, feedback attributes, holdings API |
| `getClientsTradeTaskConfig()` | `environment = APP_ENV`, `stage = NODE_ENV`, `region = REGION`, `tradeProcess.enabled` | `trade-process-job` |
| `getClientsForHoldingsJob()` | same + `holdingsProcess.enabled` | `holdings-process-job` |
| `getClientsForAccountsLoad()` | same + `accountsLoad.enabled` | `account-job` |
| `getClientsForFeedbackProcess()` | same + `feedbackProcess.enabled` | `feedback-process-job`; `bulkFeedback` API |
| `getAllClientsTradeTaskConfig(env?, region?)` | `stage = NODE_ENV`, plus env/region if given. No task filter | `trade-alerts-job` (no env/region: **all clouds of this stage**); Azure trade-load alert (`APP_ENV`, `REGION`) |
| `getPreclearConfig` / `getTradeConfig(id, version?)` | section 3.3; throw if not found | rules engine, trade process |
| `findPreclearConfig` / `findTradeConfig` | same, but return `null` on **any** error (incl. validation errors) | rules engine, rule-config API |

A filter is skipped when its value is `undefined`. On AWS `REGION` is `undefined`, so AWS jobs don't filter by region.

### 6.2 Repositories (`storage/repositories/`)

| Repository | Reads | Writes |
|---|---|---|
| `ClientRepository` | `getAll(filters)`, `getById(id)`; validates all JSON (2.6) | `upsert(client)`: full-row `INSERT … ON CONFLICT DO UPDATE` |
| `PreclearConfigRepository` | `getOne({versions, clientIds, isActive})`; validates storage and model schemas | `upsert(config)` |
| `TradeConfigRepository` | `getOne(...)`; validates `tradeParametersSchema` | `upsert(config)` |

The only callers of the `upsert` methods are `scripts/migrateConfigs.ts`, the seeders and tests.

### 6.3 Legacy repositories (`storage/legacyRepositories/`)

Used **only** by `scripts/migrateConfigs.ts`; the seeders import just `generateConfigUuid`. They read the pre-v2 AWS config:

| Repository | Source | Builds |
|---|---|---|
| `LegacyClientRepository` | DynamoDB table `prod-client-config` (name hardcoded). For `DYNAMO_CLIENT_CONFIG = dev-client-config` / `tst-client-config` the DB secret, region and role are replaced with hardcoded dev/tst values | `Client` with `environment = 'AWS'`, `stage = NODE_ENV`, `region = REGION`, `azure_environment = {tenantId: <id>}`, **`tasks_config = null`**. Status labels come from the S3 JSON (`CONFIG.DECISION_CONFIG`, default `Approve`/`Deny`/`Review`/`Other`; `TRADE_PROCESS.STATUS`, default `''`) |
| `LegacyPreclearConfigRepository` | DynamoDB `DYNAMO_CLIENT_RULE_CONFIG_V1` (rule order: `ID`, `RuleName`, `ParamValue`, `PriorityIndex`) + S3 JSON `RE_S3_BUCKET_V1`/`RE_S3_PATH_V1`/`<id>.json` | Published `PreclearConfig`. Version = `uuidv5('<id>_preclear')`, rule ids = `uuidv5(ID)`. Legacy `ACTION` / `IN` / `NOTIN` / `YES` / `NO` are converted to `actionIn` / `actionNotIn`. Has its own, more lenient parameter schemas with defaults |
| `LegacyTradeConfigRepository` | S3 JSON `TRADE_PROCESS.RULE_CONFIG` | Published `TradeConfig`, version `uuidv5('<id>_trade')` |

Both migrated configs are named `COR-6031: Migrated config from AWS`.

Legacy tables `rulesenginedb.clients` and `rulesenginedb.preclear_rules` are still read by `rulesEngineV3` and `clientRuleConfigV3` (raw SQL). Nothing in this repo writes them.

### 6.4 Caching

- **No config cache.** The trade SQS Lambda reloads the client and the trade config for every message (`tradeProcessV2/handler.ts` → `connectToClientAndCentral`). Azure loads them once per client per job run (`handleTradesAzure`). The rules engine loads them per request.
- A config change therefore applies at the next job run, message or request (inferred).
- The only memo is in `serverless/private/functions/bulkFeedback/repo.ts`: `CentralDbRepo` keeps the feedback-enabled client list for the life of the repo instance.

---

## 7. Environment, stage and region

Runtime values (`libs/globalConstants.ts`):

| Constant | From | Values | Fallback |
|---|---|---|---|
| `APP_ENV` | `APP_ENV` env | `AWS`, `AZURE` | `AWS` |
| `NODE_ENV` | `NODE_ENV` env, upper-cased | `LOCAL`, `DEV`, `TST`, `SAND`, `PROD` | **`PROD`** (also for an invalid value) |
| `REGION` | `REGION` env, Azure only | `westeurope`, `eastus`, `uaenorth`, `canadacentral` | `eastus` on Azure; `undefined` on AWS |

DB enums (same values): `rulesenginedb.environment_enum` (01), `stage_enum` (05), `region_enum` (06, +`uaenorth` in 13, +`canadacentral` in 17).

Which clients each job sees:

| Job / entry | environment | stage | region | Extra filter |
|---|---|---|---|---|
| `trade-process-job` | = `APP_ENV` | = `NODE_ENV` | = `REGION` (Azure only) | `tradeProcess.enabled` |
| `holdings-process-job` | same | same | same | `holdingsProcess.enabled` |
| `account-job` | same | same | same | `accountsLoad.enabled` |
| `feedback-process-job`, `bulkFeedback` API | same | same | same | `feedbackProcess.enabled` |
| `trade-alerts-job` (Stuck / pending, `tasks/tradeAlerts`) | any | = `NODE_ENV` | any | none |
| Azure trade-load alert (end of `trade-process-job`) | = `APP_ENV` | = `NODE_ENV` | = `REGION` | none |
| Preprocess jobs, exceptions | not per client | | | |
| APIs (rules engine, trade API, config API) | any | any | any | client id from the request |

Migration 05 set `stage = NODE_ENV` of the runner for every existing row. So each central DB probably started with a single stage, and SAND rows were added later next to PROD rows by `fn_migrate_config_to_azure` (inferred).

---

## 8. How configs are created and changed

### 8.1 Migrations (`migrations/`, Umzug, log table `rulesenginedb."SequelizeMeta"`)

On AWS, `buildspec.yml` runs `db:func --pre`, `db:up --force`, `db:func --post` before `serverless deploy`. How migrations run for Azure is not in this repo.

`isProductionOrSandbox` below = `NODE_ENV` of the **migration runner** is `PROD` or `SAND`.

| # | Change |
|---|---|
| 00 | `CREATE EXTENSION citext`; create `clients_v2` (no environment/stage/region/tasks/azure yet), `preclear_configs_v2`, `trade_configs_v2`; FKs (`SET NULL` / `CASCADE`); functions and triggers `check_client_configs_published`, `forbid_update_if_published` |
| 01 | `environment_enum`; add `environment` (existing rows `AWS`), `tasks_config`, `azure_environment` (set to `{"tenantId": id}`). For each client in `tasks/tradeProcess/liveClients.ts` (68 entries) set `tasks_config = {tradeProcess: {enabled: isProductionOrSandbox ? Live : false, transactionDate, tradeStatus}}`. This **replaces** `tasks_config` for those rows |
| 02 | Merge `accountsLoad: {enabled: isProductionOrSandbox}` into every row |
| 03 | Merge `holdingsProcess: {enabled: isProductionOrSandbox}` into every row |
| 04 | Merge `holdingsPostProcess: {enabled: false}` (wrong key, removed in 07) |
| 05 | `stage_enum`; add `stage` and set it to the runner's `NODE_ENV` for all rows |
| 06 | `region_enum ('westeurope','eastus')`; add nullable `region`; `eastus` for all `AZURE` rows |
| 07 | Remove `holdingsPostProcess`; set `holdingsProcess = {enabled: isProductionOrSandbox, postProcess: true}` on **every** row (replaces the whole block) |
| 08 | Not config: tracks existing `brokerdb` / `refdata` tables and `fn_process_trades` (see `central-db-schema.md`) |
| 09 | Merge `feedbackProcess: {enabled: isProductionOrSandbox}` into every row |
| 13, 17 | Add `uaenorth`, `canadacentral` to `region_enum` |

Migrations 10–12, 14–16 and 18–20 don't touch the config tables.

### 8.2 `scripts/migrateConfigs.ts` (legacy AWS → v2 tables)

Run: `npm run migrate-configs [-- --clientId <id>]`. It first refreshes AWS credentials (`scripts/refreshAwsCredentials.ts --user`). It needs `DYNAMO_CLIENT_CONFIG`, `DYNAMO_CLIENT_RULE_CONFIG_V1`, `RE_S3_BUCKET_V1`, `RE_S3_PATH_V1` and central DB access.

For each legacy client (one client, or all clients in DynamoDB):
1. `clientRepository.upsert(client)`: AWS row, `tasks_config = null`.
2. Load the preclear config from DynamoDB + S3, upsert it (published).
3. Load the trade config from S3, upsert it (published).
4. Set the version columns to whatever succeeded, upsert the client again.
5. Log per-type success / failure counts.

This is a one-time migration (ticket COR-6031 by the config names). Re-running it for a client that already exists is unsafe (inferred, not tested):
- Step 1 overwrites `environment`, `stage`, `region` and **`tasks_config` (→ `NULL`)**.
- Steps 2–3 fail, because the deterministic version already exists and is published (`forbid_update_if_published`).

### 8.3 Seeders (local only)

`npm run db:seed [-- --central | --client] [--clientId <id>]` (`scripts/runSeeders.ts`). The central seeder refuses any host other than `localhost`. It drops and recreates the schemas, runs functions and migrations, then seeds configs:

| File | Content |
|---|---|
| `seed/central/configs/clients.ts` | `pdl`, `pdl2`, `pdl3` (AWS, `region null`) and `poc1`–`poc6` (AZURE, `eastus`). All `stage = LOCAL`, all tasks enabled. `pdl2`, `poc1`, `poc6` use `tradeStatus` with RNR; `feedbackProcess` is only in the common block |
| `seed/central/configs/tradeConfigs.ts` | Named parameter sets (`default`, `testConfig`, `sicRules`, `allRules`, holding-period variants, …). Version = `generateConfigUuid('<client>_<name>', 'trade')`, all published; one per client activated |
| `seed/central/configs/preclearConfigs.ts` | 15 rule sets, **only for `poc1`** (active: `restrictionList`). The other local clients have no preclear config |

`activateTradeConfigForClient` / `activatePreclearConfigForClient` switch the active version (used by tests). The client seeder (`seed/client/index.ts`) creates a local client DB `compliance-<id>` for every client whose credentials point to `localhost`.

### 8.4 `rulesenginedb.fn_migrate_config_to_azure()` (manual AWS → Azure copy)

File: `plpgsql/post-migrations/rulesenginedb.fn_migrate_config_to_azure.sql`. It is deployed as a DB function and run by hand in SQL.

```sql
SELECT rulesenginedb.fn_migrate_config_to_azure(
    p_source_id        := '<aws-client-id>',
    p_target_id        := '<target-client-id>',      -- must equal source for PROD
    p_target_tenant_id := '<azure-tenant-alias>',
    p_target_region    := 'eastus',
    p_target_stage     := 'SAND',                    -- only SAND or PROD
    p_ticket_name      := '<ticket> <description>',  -- becomes the config name
    p_dry_run          := TRUE);                     -- default TRUE
```

**Checks:**
- the source exists
- the stage is `SAND` or `PROD`
- for PROD, target id = source id
- the tenant id is not used by another client (`azure_environment->>'tenantId'`)

| | `SAND` | `PROD` |
|---|---|---|
| Existing target row | **Deleted** (its configs cascade) | Kept and updated in place |
| Backup | none | Copy of the source row as `<id>_aws` (versions `NULL`) if it doesn't exist yet |
| Target row | New copy of source: `environment = AZURE`, `stage = SAND`, name + ` \| sandbox`, `azure_environment = {tenantId}`, empty `aws_environment`, `region = p_target_region` | Same fields updated on the original row, name + ` \| prod` |
| `tasks_config` | Copied, then `tradeProcess.manualUploadOnly = true` and `holdingsProcess.manualUploadOnly = true` (only if those blocks exist) | Kept as is |
| Config copies (new `gen_random_uuid()`, `name = p_ticket_name`) | Attached to the new SAND client and set active | Attached to the **`_aws` backup** and set active there. The Azure row keeps its original config versions |

**Dry run:**
- All the work is done, and the result is printed with `RAISE NOTICE` (client, versions, tenant, AWS fields, tasks flags, config counts).
- Then `RAISE EXCEPTION 'DRY RUN …'` rolls everything back.
- Use `p_dry_run := FALSE` to commit.

**Effects after a real run:**
- **PROD:** the original id now belongs to the Azure jobs. The `_aws` backup keeps `environment = AWS`, `stage = PROD` and the source's `tasks_config` (including `enabled` flags), so AWS PROD jobs will pick up `<id>_aws` (inferred). Trades are matched with `lower(pdl_client_code) = lower('<id>_aws')`, which no trade has, so it probably finds nothing (inferred).
- **SAND:** with `manualUploadOnly = true`, the sandbox trade process loads only `Manual Upload` trades, and the holdings process loads no holdings (2.5).

### 8.5 `libs/json/re/v2/{dev,tst,prod}/*.json`

- Per-client JSON files in the **legacy S3 format** that `LegacyPreclearConfigRepository` / `LegacyTradeConfigRepository` read:
  - top-level rule blocks `SECURITY_LIST_RULE`, `SEC_TYPE_RULE`, `MULTI_RULE`, …
  - `CONFIG` (`DECISION_CONFIG`, legacy DB pointers)
  - `TRADE_PROCESS` (`RULE_CONFIG`, `STATUS`)
- About 77 to 79 files per stage. `trade-process.json` (and `prod/trade-processBak.json`) is an older global trade-process config (`DEFAULT` plus per-client overrides, target tables).
- **No code, script or buildspec in this repo references these files.** They look like a copy of the S3 sources (inferred). Changing them changes nothing at runtime.

---

## 9. AWS vs Azure differences

| Topic | AWS | Azure |
|---|---|---|
| `environment` | `AWS` | `AZURE` |
| `region` | `NULL`, not filtered | Required in practice; jobs filter by `REGION` (default `eastus`) |
| Client DB credentials | `aws_environment.db` (assume role + Secrets Manager) | `azure_environment.tenantId` → Key Vault `<ENVIRONMENT>-<tenantId>-compliance-*` |
| Unused column | `azure_environment` (must still be valid; migration 01 filled `{tenantId: id}`) | `aws_environment` (placeholder with empty strings) |
| Trade config load | Per SQS message in the Lambda | Once per client per job run |
| Missing or invalid trade config | That message fails (the trade is fetched again next run) | `handleTradesAzure` throws outside the per-trade `try`, which ends the job for the remaining clients (inferred from `tasks/tradeProcess/tradeProcessController.ts`) |
| Migrations | `buildspec.yml` | Unknown |
| How clients got here | `migrate-configs` from DynamoDB/S3 | `fn_migrate_config_to_azure` from an AWS row, or manual |

---

## 10. How to onboard a new client

The repo has **no onboarding script or API**. The steps below are the minimum the code requires. Steps marked *(unknown)* happen outside this repo.

1. **Client DB exists** and holds the client app schema *(unknown: created by the client app / platform)*.
2. **Credentials:**
   - AWS: an assumable role plus a Secrets Manager secret.
   - Azure: Key Vault secrets `<ENVIRONMENT>-<tenantId>-compliance-{host,port,dbname,user,password}`.

   *(unknown: who creates them)*
3. **Insert the client** with no active versions (the trigger allows `NULL`):
   ```sql
   INSERT INTO rulesenginedb.clients_v2
     (id, name, environment, stage, region, trade_status_config, preclear_status_config,
      aws_environment, azure_environment, tasks_config, created_at, updated_at)
   VALUES ('newc', 'New Client', 'AZURE', 'PROD', 'eastus',
     '{"MATCH_STATUS":"Matched","PENDING_MATCH_STATUS":"Pending Match","PRECLR_NOT_NEEDED":"Preclear Not Needed","MANAGED_ACCOUNT":"Managed Account"}',
     '{"APPROVE":"Approved","DENY":"Denied","REVIEW":"In Review","OTHER":"Other"}',
     '{"db":{"region":"","roleArn":"","secretName":""}}',
     '{"tenantId":"<tenant-alias>"}',
     '{"tradeProcess":{"enabled":false,"tradeStatus":"status = ''TRADE''","transactionDate":"<go-live-date>"},
       "holdingsProcess":{"enabled":false,"postProcess":true},
       "accountsLoad":{"enabled":false},"feedbackProcess":{"enabled":false}}',
     now(), now());
   ```
   - Fill **all four** keys of both status configs.
   - Fill both environment columns, or the client is dropped by `getAll`.
4. **Insert the configs** as published rows. The JSON must pass sections 4 and 5:
   ```sql
   INSERT INTO rulesenginedb.trade_configs_v2 (version, client_id, name, is_published, parameters, created_at, updated_at)
   VALUES (gen_random_uuid(), 'newc', '<ticket>: initial trade config', true, '<parameters-json>', now(), now())
   RETURNING version;
   -- same for preclear_configs_v2 with rules = '<rules-json>'
   ```
5. **Activate:** `UPDATE rulesenginedb.clients_v2 SET trade_config_version = '<v>', preclear_config_version = '<v>', updated_at = now() WHERE id = 'newc';`
6. **Check:**
   - `GET rules-engine/v2.0/fetch-client-rule-config-v2?ClientID=newc` returns the rendered config (inferred: the query parameter name comes from `clientRuleConfigV2/schema.ts`).
   - Optionally, try the rules engine and the trade API with `configVersion` first.
7. **Accounts first:** turn on `tasks_config.accountsLoad.enabled`. Trades stay `ACEX` until `brokerdb.account_data` has the client's accounts (`trade-process.md` §3, d).
8. **Turn on the other jobs:** `tradeProcess.enabled`, `holdingsProcess.enabled`, `feedbackProcess.enabled`. Pick `tradeStatus` / `transactionDate` with care: trades before the date are never processed.
9. **Broker feeds, Plaid, preclear UI wiring** *(unknown: outside this repo)*. Also, the client code mapping in `fn_process_trades` is hardcoded and needs a code change if the broker sends a different code (`trade-process.md` §3, b).

---

## 11. How to change a config

| Change | How |
|---|---|
| Task flags, `tradeStatus`, `transactionDate`, labels, environment JSON | Plain `UPDATE rulesenginedb.clients_v2 SET tasks_config = jsonb_set(tasks_config, '{tradeProcess,enabled}', 'true') …`. No versioning or audit for these columns |
| Trade or preclear rules | New version (published configs can't be edited): |

1. Copy the active row into a draft:
   ```sql
   INSERT INTO rulesenginedb.trade_configs_v2 (version, client_id, name, is_published, parameters, created_at, updated_at)
   SELECT gen_random_uuid(), client_id, '<ticket>: <what changed>', false, parameters, now(), now()
     FROM rulesenginedb.trade_configs_v2 t
     JOIN rulesenginedb.clients_v2 c ON c.trade_config_version = t.version AND c.id = t.client_id
    WHERE c.id = '<id>'
   RETURNING version;
   ```
2. Edit the draft (`UPDATE … SET parameters = jsonb_set(...) WHERE version = '<draft>'`). Allowed while `is_published = false`.
3. Test the draft by version: the trade API and rules engine accept `configVersion`, with no publish check (3.3).
4. Publish: `UPDATE … SET is_published = true WHERE version = '<draft>'`.
5. Switch: `UPDATE rulesenginedb.clients_v2 SET trade_config_version = '<draft>' WHERE id = '<id>'`. Roll back by pointing to the old version again.
6. Don't delete old versions that are still active anywhere (FK `SET NULL` silently disables the client's processing).

Changes take effect on the next job run, message or request (6.4). The DB doesn't validate the JSON, so check it against the Zod schemas first. A bad trade config makes the client's trades fail. A bad client row removes the client from every job (2.6).

---

## 12. Notes and unknowns

- **Unknown:**
  - who runs onboarding in production, and with which tooling (SQL by hand is assumed)
  - who creates client DBs, Key Vault secrets and AWS roles
  - the values of the Azure `ENVIRONMENT` env var
  - how migrations are applied on Azure
- **Unknown:** how Sequelize `upsert` treats `undefined` version fields. If it writes `NULL`, the first `upsert` in `migrateConfigs.ts` also clears the active versions of an existing client.
- **Raw SQL in config.** `tasks_config.tradeProcess.tradeStatus` is pasted into queries (`tasks/tradeProcess/services/tradeProcessService.ts:24`, `tasks/tradeAlerts/tradeAlertsQuery.ts:100`). `transactionDate` is also interpolated in the alert query (`tradeAlertsQuery.ts:97`). Whoever can write `clients_v2` can run SQL through the jobs.
- **`NODE_ENV` falls back to `PROD`** when unset or invalid (`libs/globalConstants.ts:73`). A misconfigured local or test run would select PROD clients and run PROD-gated migrations.
- **Silent drops.**
  - `ClientRepository.getAll` skips clients with invalid JSON (log only).
  - `findPreclearConfig` / `findTradeConfig` turn any error into `null`.
- **Seeder race.** `seedTradeConfig` / `seedPreclearConfig` call `activateConfig` without `await` (`seed/central/configs/tradeConfigs.ts:367`, `preclearConfigs.ts:282`). Both do read-modify-write of the whole client row, so one activation can overwrite another (local only).
- **`IGNORE_TRANSACTION_TYPE_MATCH`** is validated but never used. `aws_environment.backendUrl` is stored but never read.
- **Hardcoded legacy values.** `LegacyClientRepository` hardcodes the DynamoDB table name and dev/tst role ARNs and secret names. `seed/central/configs/clients.ts` hardcodes a dev role ARN.
- **Holdings vs trades `manualUploadOnly`.** The holdings flag disables holdings loading entirely, while the trade flag restricts to manual uploads. SAND clients created by `fn_migrate_config_to_azure` therefore receive no holdings from the holdings job.
- **PROD Azure migration** leaves an active-looking `<id>_aws` AWS PROD row with the old `tasks_config` (8.4). Whether AWS jobs were switched off for it is unknown.
