# Runtime overview

The whole service on one page: what runs where, how it is built, configured, tested and monitored. Start here.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`. Paths outside `src/` (repo root files, `lambdas/utilities`, `monitoring`, `.azuredevops`) are relative to `compliance-rules-engine/` and are written that way.

Related docs: `README.md` (index), `trade-process.md`, `trade-alerts.md`, `central-db-schema.md`, `client-db-schema.md`, `preclear-rules-engine.md`, `exceptions.md`, `holdings-process.md`, `client-config.md`, `accounts-and-feedback.md`, `opensearch-sync.md`, `security-master.md`.

---

## 1. Overview

**What the service does.** `rules-engine-3.0` is the compliance back end for the employee-compliance product. It (a) evaluates **preclearance requests** against each client's rules and returns a terminal status (Approved / Denied / In Review, mapped per client), (b) runs **batch jobs** that clean, security-match and copy broker **trades** and **holdings** from the central DB into each client DB, check trades against trade rules, and manage **exceptions** for the ops team, (c) syncs **accounts** and **broker feedback** between client DBs and the central DB, and (d) loads security data into **OpenSearch**. It is multi-tenant: one central DB for all clients, one client DB per client.

**One codebase, two runtimes** (selected by `APP_ENV`):

| | AWS (`APP_ENV=AWS`, default) | Azure (`APP_ENV=AZURE`) |
|---|---|---|
| HTTP API | Lambda functions behind API Gateway (Serverless Framework v3) | Express server (`server/index.ts`) |
| Batch jobs | Same job runner (`tasks/index.ts`) in a container | Same job runner in a container |
| Status (root `README.md`) | "main version" | "on hold. Only 2 clients are using it" |

```
                       ┌──────────────────────── AWS ─────────────────────────┐
 Callers (inferred:    │ API Gateway (REGIONAL)  ──► public Lambdas           │
  client app, admin) ─►│ API Gateway (PRIVATE)   ──► private Lambdas          │
                       │ SQS trade queue ──► tradeProcessV2 Lambda            │
                       │ Container: npm run task <job>  (trade-process-job    │
                       │            fills the SQS queue)                      │
                       └───────┬──────────────────────────────────────────────┘
                               │            ┌──────────── Azure ─────────────┐
                               │            │ Express server (npm run server)│
                               │            │ Container: npm run task <job>  │
                               │            │ (trades processed in-process)  │
                               │            └──────┬─────────────────────────┘
             ┌─────────────────┴──────────┬────────┴─────────┬───────────────────┐
             ▼                            ▼                  ▼                   ▼
   central DB (PostgreSQL)      client DBs (PostgreSQL,   SMA HTTP API       Alerts:
   rulesenginedb, brokerdb, ... one per client)           (Keycloak token)   AWS: SNS ──► utilities/slackAlert ──► Slack
   creds: Secrets Manager (AWS) creds: STS + Secrets Mgr                      Azure: Slack Web API directly
          or DB_* env (Azure)          (AWS) / Key Vault (Azure)
```

---

## 2. Repo layout (`src/`)

| Folder | What it holds |
|---|---|
| `libs/` | Shared code: env config (`globalConstants.ts`), logger, alerts (`alert.ts`, `slackNotifier.ts`), AWS wrappers (`secrets`, `sts`, `sqs`, `sns`, `s3`, `dynamodb`), SMA client (`sma/`), Admin Portal client (`disclosureAppServer/`), preclear rules (`rules/`, `rulesV3.0/`), trade rules (`tradeRules/`), OTel metrics (`monitoring/`). |
| `migrations/` | Umzug migrations for the central DB (`00_initial.ts` … `20_add_default_status_value.ts`, 21 files). |
| `models/` | Domain models: `client`, `preclearConfig`, `tradeConfig`. |
| `plpgsql/` | SQL functions for the central DB: `pre-migrations/` (3 files) and `post-migrations/` (9 files). |
| `scripts/` | CLI scripts: migrations, DB functions, seeding, config migration from legacy AWS storage, AWS credential refresh, two ad-hoc JS helpers. |
| `seed/` | Local-only seeding of the central DB and client DBs (`central/`, `client/`, `common/`, `sql/`, `api/`). |
| `server/` | Express app for Azure: bootstrap, routes, controllers, error middleware, Swagger. |
| `serverless/` | AWS Lambda stacks: `common/` (shared config builder + API Gateway timeout plugin), `public/`, `private/`. |
| `services/` | Business services: `ClientConfigService`, `ExceptionResolvingService`, `RestrictionService`, `AttributeMatcher`, `contextData/`, `holdings/`. |
| `storage/` | DB access: `centralDb.ts`, `clientDb.ts`, `sequelize.ts`, Sequelize models, repositories, `legacyRepositories/` (DynamoDB + S3, used only by scripts/seed), Umzug setup, `applyDbFunctions.ts`. |
| `tasks/` | Batch job runner (`index.ts`, `Job.ts`) and one folder per job. |
| `tests/` | `unit/`, `integration/`, `system/` test suites (see section 11). |

Import aliases (`tsconfig.paths.json`): `@libs`, `@models`, `@storage`, `@services`, `@server`, `@seed`, `@tasks`, `@tests`, and `@functions` → `serverless/public/functions`.

---

## 3. AWS Lambda stacks

`lambdas/rules-engine-3.0/serverless-compose.ts` composes two Serverless services:

| Compose name | Path | Service name | API Gateway type | Local port (`serverless-offline`) |
|---|---|---|---|---|
| `public-serverless` | `serverless/public` | `compliance-rules-engine-v3` | `REGIONAL` | 3000 (lambda port 3001) |
| `private-serverless` | `serverless/private` | `compliance-rules-engine-v3-private` | `PRIVATE` (resource policy: `execute-api:Invoke` for any principal; reachable only through a VPC endpoint, inferred) | 3020 (lambda port 3021) |

Shared settings (`serverless/common/createServerlessConfiguration.ts`): runtime `nodejs20.x`, stage = `NODE_ENV`, IAM role = `DEFAULT_FUNCTION_ROLE`, optional VPC (`VPC_SECURITY_GROUP_IDS` + `VPC_SUBNET_IDS`), deployment bucket `SERVERLESS_DEPLOYMENT_BUCKET_NAME`, plugins `serverless-esbuild` (target `node14`), `serverless-offline`, `serverless-dotenv-plugin` (reads `lambdas/rules-engine-3.0/.env`), and a local plugin `updateIntegrationTimeout.ts` that adds a per-route `timeout` to API Gateway integrations (Serverless v3 workaround). Timeouts: `AWS_LAMBDA_TIMEOUT_SECONDS = 59`, `AWS_API_GATEWAY_TIMEOUT_SECONDS = 60`.

### 3.1 Functions

| Stack | Function | Trigger | Purpose | Handler | Details in |
|---|---|---|---|---|---|
| public | `rulesEngineV2` | `POST /v1/rules/create` | Preclear evaluation (main path). Runs client's preclear rules, returns terminal status. Sends alert on failure. | `serverless/public/functions/rulesEngineV2/handler.ts` | `preclear-rules-engine.md` |
| public | `rulesEngineV3` | `POST /rules-engine/v3.0/submit-preclear` | Older "3.0" preclear evaluation from `rulesenginedb.preclear_rules`, rules in `libs/rulesV3.0`. | `rulesEngineV3/handler.ts` | `preclear-rules-engine.md` |
| public | `clientRuleConfigV2` | `GET /rules-engine/v2.0/fetch-client-rule-config-v2` (CORS `*`) | Returns a client's rule config. | `clientRuleConfigV2/handler.ts` | `client-config.md` |
| public | `clientRuleConfigV3` | `GET /rules-engine/v3.0/fetch-client-config` | Returns active "3.0" rules from `rulesenginedb.preclear_rules`. | `clientRuleConfigV3/handler.ts` | `client-config.md` |
| public | `tradeProcessV2` | **SQS** `TRADE_PROCESS_SQS_ARN`, `batchSize: 1`, `maximumConcurrency: 10`, timeout 300 s | Processes one trade (`{ ClientID, TradeData }`) into the client DB. Failed messages are not retried (`batchItemFailures: []`). Role `TRADE_PROCESS_ROLE`. | `tradeProcessV2/handler.ts` | `trade-process.md` |
| public | `tradeProcessApiV2` | `POST /v2/process-trade` | Processes one trade synchronously. `readOnly` is forced to `true` in PROD and SAND. | `tradeProcessV2/api/handler.ts` | `trade-process.md` |
| public | `preclearFlip` | `POST /v1/preclear-flip` | Builds a trade from a preclear disclosure and runs `tradeProcess()` on it. | `tradeProcessV2/preclearFlip/handler.ts` | `trade-process.md` |
| public | `holdingsApi` | `POST /v1/holdings`, `GET /v1/holdings` | Create holdings in the central DB / query holdings by `account_code` (+ `as_of_date`). | `holdingProcessApi/handler.ts` | `holdings-process.md` |
| private | `exceptionsResolvingV1` | `POST /v1/exceptions/resolve` | Manual exception resolution (`NotATrade`, `MatchedToExistingSecurity`, `NewSecurity`). | `serverless/private/functions/exceptionResolvingV1/exceptionResolvingHandler.ts` | `exceptions.md` |
| private | `bulkFeedback` | `POST /v1/attributes/bulk-upload-feedback` (multipart, XLSX file) | Applies broker feedback rows from an uploaded XLSX to account attributes. | `serverless/private/functions/bulkFeedback/handler.ts` | `accounts-and-feedback.md` |

**Auth.** No function defines an API Gateway authorizer, API key (`private: true`) or IAM auth, and handlers do not check tokens. Access control is therefore outside this repo (network / API Gateway settings), or absent (inferred). The private stack is protected only by being a `PRIVATE` endpoint.

**Error responses.** `libs/api-gateway.ts`: `{ status, message, data }` on success; validation/500 errors include `stack` except in PROD and SAND.

---

## 4. Background jobs

**Runner:** `tasks/index.ts`. The first CLI argument is the job key (`Job.ts`). Unknown key → logs the list of jobs, sends an alert, exits 1. A failing job → alert with subject = job key, exit 1. Uncaught exceptions are also alerted.

| Job key (`Job.ts`) | Entry function | What it does | Details in |
|---|---|---|---|
| `account-job` | `tasks/loadAccountData/accountController.ts` → `initiateAccountLoad` | For each client with accounts load enabled: reads `account_view` from the client DB, replaces that client's rows in `brokerdb.account_data` (central DB). | `accounts-and-feedback.md` |
| `feedback-process-job` | `tasks/feedbackProcess/feedbackProcessController.ts` → `loadAndDumpFeedbackRecords` | Reads pending broker feedback from the central DB for clients with feedback process enabled and applies it to account attributes (`updateAttribute`). | `accounts-and-feedback.md` |
| `trade-preprocess-job` | `tasks/tradeProcess/tradePreprocessController.ts` | Trade preprocess only (`brokerdb.fn_process_trades` + security matching). | `trade-process.md` |
| `full-preprocess-job` | `tasks/tradeProcess/fullPreprocessController.ts` | Trades and holdings preprocess + exception steps (see `trade-process.md`, section 2). | `trade-process.md`, `exceptions.md` |
| `trade-process-job` | `tasks/tradeProcess/tradeProcessController.ts` → `processTrades` | Per client: fetch ready trades. **AWS:** purge the SQS queue, then one SQS message per trade. **Azure:** process in-process, then send the trade-load alert. | `trade-process.md`, `trade-alerts.md` |
| `trade-alerts-job` | `tasks/tradeAlerts/tradeAlertsController.ts` | Broker-file alert, pending-trades alert; on AWS also the trade-load alert. | `trade-alerts.md` |
| `holdings-preprocess-job` | `tasks/holdingsPreprocess/holdingsPreprocessController.ts` | Holdings security matching + historical exception resolution (`RUN_HISTORICAL_EXCEPTION_RESOLUTION`). | `holdings-process.md` |
| `holdings-process-job` | `tasks/holdingsProcess/holdingsController.ts` → `initiateHoldingsTransfer` | Per client: copies holdings into the client DB and updates holding statuses; sends a summary notification per client. | `holdings-process.md` |
| `open-search-task` | `tasks/openSearchSync/openSearchSyncController.ts` | Initial load (`JOB_TYPE=initialLoad`) of securities and entities from a separate security-data PostgreSQL ("Factset RDS" in code, `PG_*`) into new OpenSearch indexes behind aliases. | `opensearch-sync.md` |

Clients for each job come from `services/ClientConfigService.ts`, filtered by `environment = APP_ENV`, `stage = NODE_ENV`, `region = REGION` and the job's enabled flag (see `client-config.md`).

**Schedules are not in this repo.** Neither ECS task definitions nor cron/EventBridge rules nor Azure job definitions exist here.

**How to run:** locally `npm run dev:task <job-key>`; in the image `npm run task <job-key>` (section 6).

---

## 5. Azure Express server (`server/`)

| File | Role |
|---|---|
| `server/index.ts` | Connects to the central DB first, then starts the app on `PORT` (default 3000). Exits 1 if the DB connection fails. |
| `server/bootstrapServer.ts` | `express.json()`, Swagger UI at `/api-docs`, routes, `errorHandler`. |
| `server/routes/*.ts` | Route table (below). |
| `server/controllers/*.ts` | `RulesEngineController`, `HoldingsController`, `HealthController`. They reuse the Lambda services (`@functions/rulesEngineV2/service`, `clientRuleConfigV2/service`, `holdingProcessApi/schema`). |
| `server/middlewares/errorHandler.ts` | Maps `HttpError` (`BadRequest`, `NotFound`, `InternalServerError` in `server/response.ts`) and other errors to `{ status, message, data, debug, error }`. Stack traces hidden in PROD and SAND. |
| `server/swagger/*.ts` | JSDoc OpenAPI specs; loaded from `SWAGGER_SPEC_PATH` (default `/app/dist/src/server/swagger/*.js`, i.e. the compiled files in the image). Server URL = `RULES_ENGINE_API_BASE_URL`. |

| Method + route | Controller | Same logic as Lambda |
|---|---|---|
| `POST /rules-engine/v1/rules/create` | `RulesEngineController.submitPreclear` (forces `disclosureData.SMA = 'true'`) | `rulesEngineV2` (`/v1/rules/create`) |
| `GET /rules-engine/v2.0/fetch-client-rule-config-v2` | `RulesEngineController.fetchClientConfig` | `clientRuleConfigV2` |
| `POST /v1/holdings` | `HoldingsController.createHoldings` | `holdingsApi` |
| `GET /v1/holdings` | `HoldingsController.getHoldingsByAccount` | `holdingsApi` |
| any `/health` | `HealthController.healthCheck` → `{ status, service, version, uptime }` | — |
| `GET /api-docs` | Swagger UI | — |

Not available on Azure: trade process API, preclear flip, `rulesEngineV3`, `clientRuleConfigV3`, exception resolving, bulk feedback.

**Auth:** no auth middleware. Swagger declares a `bearerAuth` scheme, but nothing enforces it.

---

## 6. Build and deploy

| File (relative to `compliance-rules-engine/`) | Builds / deploys | Steps |
|---|---|---|
| `lambdas/rules-engine-3.0/buildspec.yml` (AWS CodeBuild) | Lambda stacks + central DB schema | Node 20.18.2 → `npm i` → global `serverless@3.38.0` → **pre_build:** `npm run db:func -- --pre`, `npm run db:up -- --force`, `npm run db:func -- --post` → **build:** `serverless deploy --stage $NODE_ENV` (from the folder with `serverless-compose.ts`, so both stacks, inferred). |
| `lambdas/rules-engine-3.0/buildspec-tasks.yml` (AWS CodeBuild) | Job-runner image in ECR | Node 22 → `npm ci` → `npm run build:job-executor` (`tsc` → `dist/`) → `docker build --build-arg BASE_IMAGE=$BASE_IMAGE` → tag/push `$REPO_NAME:$IMAGE_TAG` to ECR. |
| `lambdas/rules-engine-3.0/Dockerfile` | The image | Base `<artifactory>/…/node22-alpine` (overridable `BASE_IMAGE`). Copies `package.json`, lock file, tsconfigs, `node_modules` and `dist` into `/app/dist`. `ENTRYPOINT ["npm","run"]`, so the container command picks the script: `server` (Express) or `task <job-key>` (job runner). `node_modules` is copied from the build host, not installed in the image. |
| `.azuredevops/pipelines/ci.yaml` (Azure DevOps) | CI for every branch | Node 22. Jobs: unit tests (+coverage, Allure), Azure integration tests (Postgres container, SMA secret from Key Vault), system tests (only `release/qa`, `main`, or parameter `runSystemTests`), lint, and **build**: `npm run build:job-executor`, prod-only deps, Docker build/push/promote to Artifactory. Where the Artifactory image runs on Azure is not in the repo. |
| `.azuredevops/pipelines/mirror-to-codecommit.yaml` | Mirrors the repo to AWS CodeCommit (per its name; CodeBuild source, inferred). | — |

DB migrations run **only in `buildspec.yml`** (AWS). How the central DB schema is updated for Azure is not in the repo.

### 6.1 Sibling folder `lambdas/utilities`

A separate Serverless service `utilities` (`lambdas/utilities/serverless.ts`, runtime `nodejs16.x`, region `us-east-1`, deployed by `lambdas/utilities/buildspec.yml` with Node 18).

| Function | Trigger | Purpose |
|---|---|---|
| `codePipeline` | `POST /pdl/aws/codepipeline/invoke` | Starts an AWS CodePipeline (name in header `pipeline_name`) when a PR is `completed`. |
| `s3Trigger` | S3 `ObjectCreated` on `S3_TRIGGER_SOURCE_BUCKET` | Copies an uploaded file `<clientCode>/<folder>/<file>` from the central bucket to the client's bucket, with per-client rules. |
| `slackAlert` | **SNS** topic `AWS_SNS_ERROR_TOPIC_ARN` | Posts SNS messages (and CloudWatch alarms) to Slack (`SLACK_BOT_TOKEN`, channel by alarm name). This is how AWS alerts from the rules engine reach Slack (inferred from the shared topic env name). |

---

## 7. AWS vs Azure at runtime

| Area | AWS | Azure | Code |
|---|---|---|---|
| HTTP hosting | API Gateway + Lambda | Express in a container (`npm run server`) | `serverless/`, `server/` |
| Jobs | Container `npm run task <job>` (ECR image; ECS per `tasks/README.md`, not defined here) | Same image from Artifactory (inferred) | `tasks/index.ts` |
| Central DB credentials | Secrets Manager secret `CENTRAL_DB_SECRET` (region hard-coded `us-east-1`), unless `DB_LOCAL=true` | `DB_*` env vars | `storage/centralDb.ts` |
| Client DB credentials | STS assume `clients_v2.aws_environment.db.roleArn`, then Secrets Manager `db.secretName` in `db.region` | Key Vault `KEY_VAULT_ENDPOINT`, secrets `<ENVIRONMENT>-<tenantId>-compliance-{host,port,dbname,user,password}`, `DefaultAzureCredential` | `storage/clientDb.ts`, `serverless/public/functions/tradeProcessV2/azure/` |
| Local override (both) | `CLIENT_DB_LOCAL=true` → `CLIENT_DB_*` env, DB name default `compliance-<clientId>` | same | `storage/clientDb.ts` |
| SMA client secret | Secrets Manager `SMA_KEYCLOAK_CLIENT_SECRET_NAME_AWS` (key `clientSecret`) | `SMA_KEYCLOAK_CLIENT_SECRET` env | `libs/sma/smaClient.ts` |
| Trade hand-off | SQS queue (`TRADE_PROCESS_SQS_URL`) → `tradeProcessV2` Lambda | In-process loop | `tasks/tradeProcess/` |
| Alerts | SNS (`AWS_SNS_ERROR_TOPIC_ARN`, or `AWS_SNS_TRADES_ERROR_TOPIC_ARN` for topic `trade-error`) unless `SLACK_ENABLED=true` | Slack Web API (`SLACK_TOKEN`, `SLACK_CHANNEL_ID`) when `SLACK_ENABLED=true`, otherwise nothing is sent | `libs/alert.ts`, `libs/slackNotifier.ts` |
| Trade-load alert | `trade-alerts-job` | end of `trade-process-job` | `tasks/tradeAlerts/`, `tasks/tradeProcess/` |
| Central DB TCP keepalive | off by default | on by default (Azure Firewall workaround for long `fn_process_trades`) | `libs/globalConstants.ts`, `storage/sequelize.ts` |
| TLS to DB | driver default | hosts ending `azure.com` get `ssl: { rejectUnauthorized: false }` | `storage/sequelize.ts` |
| `REGION` | `undefined` | `westeurope` / `eastus` (default) / `uaenorth` / `canadacentral` | `libs/globalConstants.ts` |
| Log format | Winston `simple` | Winston JSON + timestamp | `libs/logger.ts` |

---

## 8. External dependencies

| Dependency | Used for | Where in code |
|---|---|---|
| **central DB** (PostgreSQL) | Client registry and configs, staging of trades/holdings, exceptions, accounts copy, feedback | `storage/centralDb.ts`; see `central-db-schema.md` |
| **client DBs** (PostgreSQL, one per client) | Rule input data; target of trades, holdings, account attributes | `storage/clientDb.ts`; see `client-db-schema.md` |
| **SMA** (Security Master API, HTTP) | Security info, matching securities, prices, SIC codes. Bearer token from Keycloak (`client_credentials`) when `SMA_AUTH=true`; 5 retries, `SMA_RETRY_DELAY` ms. | `libs/sma/`; see `security-master.md` |
| **Keycloak** | Token for SMA | `libs/sma/smaClient.ts` |
| **AWS Secrets Manager** | Central DB creds, client DB creds, SMA client secret, Admin Portal API key | `libs/secrets.ts` |
| **AWS STS** | Assume client role for client DB secrets | `libs/sts.ts` |
| **AWS SQS** | Trade queue (send, purge) | `libs/sqs.ts`, `tasks/tradeProcess/` |
| **AWS SNS** | Alerts on AWS | `libs/sns.ts`, `libs/alert.ts` |
| **AWS DynamoDB + S3** | **Legacy** client / rule config storage (`DYNAMO_CLIENT_CONFIG`, `DYNAMO_CLIENT_RULE_CONFIG_V1`, `RE_S3_BUCKET_V1` + `RE_S3_PATH_V1`). Read only by `scripts/migrateConfigs.ts` (and a helper used by seed). Not on the request path. | `storage/legacyRepositories/`, `libs/dynamodb.ts`, `libs/s3.ts` |
| **Azure Key Vault** | Client DB creds on Azure | `serverless/public/functions/tradeProcessV2/azure/keyvault.ts` |
| **Slack** | Alerts (direct on Azure; via SNS → `utilities/slackAlert` on AWS) | `libs/slackNotifier.ts` |
| **Admin Portal** (central admin instance of DisclosureAppServer) | `GET <ADMIN_PORTAL_BASE_URL>/pdl/secured/config/cat/RELOAD_CACHE_EXTERNAL?cacheToUpdate=PERSONAL_TRADE` after exception status sync; API key from Secrets Manager | `libs/disclosureAppServer/AdminPortalClient.ts`, `tasks/tradeProcess/services/exceptionStatusSyncService.ts` |
| **OpenSearch** | Securities / entities search indexes | `tasks/openSearchSync/` |
| **Security-data PostgreSQL** ("Factset RDS") | Source for OpenSearch sync (`public.security_info`, `public.tbl_securities`, `public.sym_futures_root`, `public.entity_base_info`) | `tasks/openSearchSync/databases/postgres.ts` |
| **Average volume API** | `average_volume_rule` (v3.0 rules), key `AVERAGE_VOLUME_API_KEY` | `libs/rulesV3.0/average_volume_rule.ts` |
| **OTel collector** | Metrics export (see section 12) | `libs/monitoring/metrics.ts` |
| **Auth0** | **No API calls.** `auth0_check_rule` only reads the user's `AUTH0_ROLE` attribute (or department) from the client DB. | `libs/rules/auth0_check_rule.ts` |

---

## 9. Environment variables

Defaults are from code. "—" = no default (empty / `undefined`). Real values live in `.env` (git-ignored), CodeBuild / pipeline variables, or the hosting platform; none are in the repo except test fixtures.

### 9.1 Common (`libs/globalConstants.ts`)

| Variable | Meaning | Default |
|---|---|---|
| `APP_ENV` | Runtime: `AWS` or `AZURE` | `AWS` |
| `NODE_ENV` | Stage: `LOCAL`, `DEV`, `TST`, `SAND`, `PROD` (case-insensitive). PROD/SAND hide stacks and force `readOnly` in `/v2/process-trade`. Also Serverless stage. | `PROD` (if missing or invalid) |
| `REGION` | Azure region for client filtering | `eastus` on Azure; unset on AWS |
| `APP_NAME` | STS session name | `rules-engine` |
| `PORT` | Express port | `3000` |
| `RULES_ENGINE_API_BASE_URL` | Swagger server URL | `http://localhost:<PORT>` |
| `SWAGGER_SPEC_PATH` | Glob for Swagger JSDoc files | `/app/dist/src/server/swagger/*.js` |
| `LOG_ARGS` | Print log metadata in LOCAL console format | `true` (anything but `false`) |
| `CHUNK_SIZE` | Batch size for security matching (`SECURITIES_CHUNK_SIZE` constant) | `1000` |
| `npm_package_version` | Version shown in health, Slack footer, Swagger (set by npm) | `unknown` |

### 9.2 Central DB (Azure and local)

| Variable | Meaning | Default |
|---|---|---|
| `DB_LOCAL` | `true` → read `DB_*` even on AWS | `false` |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD` | Central DB connection | —, `5432`, —, —, — |
| `DB_KEEPALIVE_IDLE` / `_INTERVAL` / `_COUNT` | TCP keepalive (seconds / seconds / probes). Setting `DB_KEEPALIVE_IDLE` enables it on any runtime. | `150` / `10` / `3`; enabled only on Azure by default |

### 9.3 Client DB (local / tests)

| Variable | Meaning | Default |
|---|---|---|
| `CLIENT_DB_LOCAL` | `true` → use `CLIENT_DB_*` for every client | `false` |
| `CLIENT_DB_HOST`, `CLIENT_DB_PORT`, `CLIENT_DB_NAME`, `CLIENT_DB_USERNAME`, `CLIENT_DB_PASSWORD` | Client DB connection | —, `5432`, `compliance-<clientId>`, —, — |

### 9.4 AWS

| Variable | Meaning | Default |
|---|---|---|
| `AWS_REGION` | Region for STS, SMA secret | `us-east-1` |
| `CENTRAL_DB_SECRET` | Secrets Manager name of central DB creds | — |
| `TRADE_PROCESS_SQS_URL` / `TRADE_PROCESS_SQS_ARN` | Trade queue (URL for the job, ARN for the Lambda trigger) | — |
| `AWS_SNS_ERROR_TOPIC_ARN` | Alert topic (Slack via `utilities`) | falls back to `TRADE_PROCESS_SNS_ARN` |
| `AWS_SNS_TRADES_ERROR_TOPIC_ARN` | Alert topic for `trade-error` alerts (email, per code comment) | falls back to `TRADE_PROCESS_SNS_ARN` |
| `TRADE_PROCESS_SNS_ARN` | Legacy single topic ("should be removed") | — |
| `DYNAMO_CLIENT_CONFIG`, `DYNAMO_CLIENT_RULE_CONFIG_V1`, `RE_S3_BUCKET_V1`, `RE_S3_PATH_V1` | Legacy config storage (scripts only) | — |
| `ADMIN_PORTAL_BASE_URL` | Admin Portal base URL | — |
| `ADMIN_PORTAL_API_KEY_SECRET_NAME` / `_REGION` | Secret with `{ apiKey }` | — / `us-west-2` |

Deploy-time only (`serverless/…/index.ts`, `createServerlessConfiguration.ts`): `DEFAULT_FUNCTION_ROLE`, `TRADE_PROCESS_ROLE`, `SERVERLESS_DEPLOYMENT_BUCKET_NAME`, `VPC_SECURITY_GROUP_IDS`, `VPC_SUBNET_IDS`, `APP_VERSION`, `DEBUG`. Local only: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `CREDENTIALS_EXPIRATION`, `CREDENTIALS_TYPE` (written into `.env` by `scripts/refreshAwsCredentials.ts`).

### 9.5 Azure

| Variable | Meaning | Default |
|---|---|---|
| `KEY_VAULT_ENDPOINT` | Key Vault URL for client DB secrets | — (throws) |
| `ENVIRONMENT` | Prefix of Key Vault secret names | — |

### 9.6 SMA

| Variable | Meaning | Default |
|---|---|---|
| `SMA_URL` | SMA base URL | — |
| `SMA_AUTH` | Send Keycloak bearer token | `true` |
| `SMA_RETRY_DELAY` | Delay between 5 retries, ms | `5000` |
| `SMA_KEYCLOAK_SERVER_URL`, `SMA_KEYCLOAK_REALM`, `SMA_KEYCLOAK_CLIENT_ID` | Keycloak token endpoint | — |
| `SMA_KEYCLOAK_CLIENT_SECRET` | Client secret (Azure) | — |
| `SMA_KEYCLOAK_CLIENT_SECRET_NAME_AWS` | Secrets Manager name with `{ clientSecret }` (AWS) | — |

### 9.7 Alerts

| Variable | Meaning | Default |
|---|---|---|
| `SLACK_ENABLED` | `true` → send to Slack directly (also on AWS, bypassing SNS) | `false` |
| `SLACK_TOKEN` | Slack bot token | — |
| `SLACK_CHANNEL_ID` | Default channel | — |

### 9.8 Jobs

| Variable | Meaning | Default |
|---|---|---|
| `RUN_MANUALLY_RESOLVED_EXCEPTIONS_UPDATE` | Step 6 of `full-preprocess-job` | `false` |
| `RUN_EXCEPTION_STATUS_SYNC` | Step 9 of `full-preprocess-job` (+ Admin Portal cache refresh) | `false` |
| `RUN_HISTORICAL_EXCEPTION_RESOLUTION` | Historical exception resolution in holdings preprocess | `false` |
| `STUCK_TRADE_DAYS` | Threshold for the pending-trades alert | `2` |
| `PG_HOST`, `PG_PORT`, `PG_DATABASE`, `PG_USERNAME`, `PG_PASSWORD` | Security-data PostgreSQL for `open-search-task` | —, `5432`, —, —, — |
| `OPENSEARCH_PROTOCOL`, `OPENSEARCH_HOST`, `OPENSEARCH_USER`, `OPENSEARCH_PASSWORD` | OpenSearch connection | `https`, —, —, — |
| `OPENSEARCH_ALIAS` / `OPENSEARCH_ENTITY_ALIAS` | Index aliases | `securities` / `entities` |
| `BATCH_SIZE` | OpenSearch sync batch size | `50000` |
| `JOB_TYPE` | OpenSearch sync mode; only `initialLoad` is implemented | `initialLoad` |

### 9.9 Other

| Variable | Meaning | Default | Where |
|---|---|---|---|
| `AVERAGE_VOLUME_API_KEY` | API key for `average_volume_rule` (v3.0) | — | `libs/rulesV3.0/average_volume_rule.ts` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP/HTTP metrics endpoint (`/v1/metrics` appended) | `http://localhost:4318` | `libs/monitoring/metrics.ts` |
| `SKIP_TEST_SERVER`, `SKIP_SEED`, `TEST_ENV` | Test-only switches | — | test setup / helpers |

---

## 10. Database tooling

| Command | What it does |
|---|---|
| `npm run db:up -- [--to <name>] [--force]` | Umzug `up` (`scripts/runMigrations.ts` → `storage/umzug.ts`). Migrations glob `src/migrations/*.ts` (relative to the current folder: run from `lambdas/rules-engine-3.0`). Log table `rulesenginedb.SequelizeMeta`. Non-`localhost` host requires `--force`. |
| `npm run db:down -- --to <name or 0> [--force]` | Umzug `down`; `--to` is required. |
| `npm run db:func -- --pre` / `--post` | `scripts/applyDbFunctions.ts` → `storage/applyDbFunctions.ts`. Runs every `plpgsql/<folder>/<schema>.<name>.sql` (schema must be `brokerdb` or `rulesenginedb`) in **one transaction**. A file is **skipped** when the function comment equals the file's short git hash (`git log -1 --format=%h`). After creating, it writes `COMMENT ON FUNCTION … IS '<hash>'`. If git is unavailable the hash is `unknown` and the file is always re-applied. A failed `CREATE` rolls back everything and sets exit code 1. |
| `npm run db:seed [-- --central \| --client] [-- --clientId <id>]` | `scripts/runSeeders.ts`. **Local only** (refuses non-`localhost` central DB; skips non-local client DBs). Central: drop + recreate schemas `public, rulesenginedb, brokerdb, refdata, userdb`, create a `paragon` role, pre-functions, all migrations, post-functions, mock tables from `seed/sql/*.sql`, configs, data, reset sequences. Client: drop + create database per seeded client, schemas `userdb, tradedb`, mock tables (+ `azure.sql` for Azure clients), configs, data. |
| `npm run migrate-configs [-- --clientId <id>]` | Refreshes AWS user credentials, then copies client / preclear / trade configs from legacy DynamoDB + S3 into the central DB (`scripts/migrateConfigs.ts`). |

Deploy order in `buildspec.yml`: pre-functions → migrations (`--force`) → post-functions.

---

## 11. Local development and tests

### 11.1 Setup (from `compliance-rules-engine/README.md`)

1. `cd lambdas/rules-engine-3.0`
2. Start PostgreSQL 14 on `localhost:5432`, database `rules-engine`, trust auth. The README uses `docker run … postgres:14.17-alpine`; with Podman the same works as `podman run -d -e POSTGRES_DB=rules-engine -e POSTGRES_HOST_AUTH_METHOD=trust -p 5432:5432 --name db docker.io/library/postgres:14.17-alpine`. There is no compose file in the repo.
3. `npm ci`
4. Create `.env` (the README says `cp .env.example .env`, but **there is no `.env.example`** in the repo). Minimal local set (from test setup and CI): `APP_ENV`, `NODE_ENV=local`, `DB_LOCAL=true`, `DB_HOST=localhost`, `DB_NAME=rules-engine`, `DB_USERNAME=postgres`, `CLIENT_DB_LOCAL=true`, `CLIENT_DB_HOST=localhost`, `CLIENT_DB_USERNAME=postgres`, plus `SMA_*` for rules that call SMA.
5. `npm run db:seed`

### 11.2 Scripts (`package.json`)

| Script | What it does |
|---|---|
| `dev` | Express server with `ts-node-dev` (watch). |
| `dev:task <job>` | Run a job with `ts-node`. |
| `debug` / `debug:private` | Refresh AWS creds into `.env` (`scripts/refreshAwsCredentials.ts`, assumes a dev role), then `serverless public-serverless:offline` (port 3000) / `private-serverless:offline` (port 3020). |
| `aws` | Only refresh AWS creds. |
| `build:job-executor` | `tsc` → `dist/`. |
| `server` / `task <job>` | Run compiled code (used in the image). |
| `db:up`, `db:down`, `db:func`, `db:seed`, `migrate-configs` | Section 10. |
| `lint` / `lint-ts` | ESLint / `tsc --noEmit`. |
| `test:unit` | Unit tests. |
| `test:integration`, `test:integration:aws`, `test:integration:azure`, `test:integration:debug` | Integration tests. |
| `test:system` | System tests. |
| `test:all` | Unit + integration. |

All test scripts set `TZ=UTC`.

### 11.3 Test layers

| Layer | Config / setup | Needs |
|---|---|---|
| Unit (`tests/unit/**/*.test.ts`) | `jest.unit.config.mjs`, `setupTests.ts` (sets `APP_ENV=AZURE`, `NODE_ENV=local`, fake SMA vars) | Nothing external. |
| Integration AWS (`*.aws.test.ts`) | `jest.integration.config.mjs` project "AWS Integration Tests", `setupAwsTests.ts` (`APP_ENV=AWS`, `DB_LOCAL=true`), `setupAwsTestServer.ts` | Local Postgres. The setup **starts both `serverless … offline` stacks itself** and seeds the local DB (`SKIP_TEST_SERVER=true` to skip the servers). Some tests need AWS creds (Admin Portal secret, inferred). |
| Integration Azure (`*.azure.test.ts`) | project "Azure Integration Tests", `setupAzureTests.ts` (`APP_ENV=AZURE`, `DB_LOCAL=true`) | Local Postgres; `CLIENT_DB_LOCAL=true` + `CLIENT_DB_*`; real SMA creds (CI reads them from Key Vault). |
| System (`tests/system/*.system.test.ts`) | `jest.system.config.mjs`, `setupSystemTests.ts` (`APP_ENV=AZURE`, `NODE_ENV=TST`) | Shared QA central DB and one QA client DB (`DB_*`, `CLIENT_DB_*` from Key Vault), SMA creds. Runs serially, cleans up its data. |

Reports: JUnit in `test-results/`, Allure in `allure-results/`.

---

## 12. Logging and monitoring

- **Logger** (`libs/logger.ts`): Winston to console. `NODE_ENV=LOCAL` → colored text with timestamps; AWS → `simple`; Azure → JSON. `useLogger(service, meta)` makes a child logger; `withAsyncLogs` / `@AsyncLogs` log `<name> starting / completed / failed` with duration. Errors are normalized (`libs/error.ts`).
- **SQL logging:** every Sequelize query on central and client DBs is logged at `info` with its `replacements` / `bind` values (`storage/centralDb.ts`, `storage/clientDb.ts`, `storage/sequelize.ts`).
- **Alerts** (`libs/alert.ts`): `alert()` (red, "Issue:") and `notify()` (green, "Success:"). Routing in section 7. Errors inside alert sending are swallowed.
- **Metrics** (`libs/monitoring/metrics.ts`): OTel `MeterProvider` with OTLP/HTTP exporter, 30 s interval, service `compliance/rules-engine`. **`initMetrics()` is never called** in `src/`, so no metrics are exported today.
- **OTel collector** (`monitoring/otel-collector.cfn.yaml`, `monitoring/README.md`): CloudFormation stack, ECS Fargate collector behind an internal NLB, receives OTLP metrics over HTTP (port 4318) and writes them to S3. Metrics pipeline only, no traces or logs. Environments `devcp1` / `prodcp1`. Producers set `OTEL_EXPORTER_OTLP_ENDPOINT` to the collector DNS name.
- Lambda logs go to CloudWatch (platform default, inferred). Azure log sink is not in the repo.

---

## 13. What is outdated in existing READMEs

| Doc (relative to `compliance-rules-engine/`) | Statement | Reality |
|---|---|---|
| `lambdas/rules-engine-3.0/README.md` | Requires Node `lts/fermium (v14.15.0)`; `.nvmrc` = `lts/fermium` | `package.json` `engines.node >= 20.15.0`, `@types/node 20.15.0`, Lambda runtime `nodejs20.x`, CodeBuild 20.18.2 / 22, CI and Docker base Node 22. (esbuild `target: node14` is also stale.) |
| same | "Template features": `src/functions`, `webpack.config.js`, `serverless.ts` at root, `json-schema-to-ts`, Yarn / `npx sls deploy` | Generated template text. Real layout: section 2; build is esbuild; config is `serverless-compose.ts`. |
| same | Testing section (unit / integration / system) | Accurate. Note: AWS integration tests start serverless-offline themselves. |
| `README.md` (root) | `lambdas/rules-engine` (v1.0) exists | Folder no longer exists. |
| same | `cp ./.env.example ./.env` | No `.env.example` in the repo. |
| same | Node v20.15, Docker; integration tests need the emulator running manually | Node 22 in CI; emulator is started by the test setup. |
| same | Jenkins CI link | CI is Azure DevOps (`.azuredevops/pipelines/ci.yaml`). |
| `lambdas/rules-engine-3.0/src/tasks/README.md` | Title "Load Account Data Process"; `docker run <image> account-job` | The image runs all jobs. With `ENTRYPOINT ["npm","run"]` the command must be `task account-job` (inferred: `account-job` alone is not an npm script). |

---

## 14. Notes and unknowns

**Unknown (not in repo):**
- Job schedules and where jobs run (ECS task definitions, Azure job/container setup).
- Where and how the Azure Express server is hosted, and how Azure gets central DB migrations.
- Access control for the public API Gateway and the Express server (no auth in code).
- Real values of environment variables; whether `.env` is present at deploy time (it decides what `serverless-dotenv-plugin` adds to Lambda env, inferred).

**Risks noticed:**
- `libs/globalConstants.ts:126` reads `AWS_SNS_TRADES_ERROR_TOPIC_ARN`, but `alertTopicEnvs` passes it to Lambdas under the key `AWS_SNS_TRADE_ERROR_TOPIC_ARN` (`:128-132`). In Lambdas, `trade-error` alerts may fall back to `TRADE_PROCESS_SNS_ARN` (inferred).
- `libs/globalConstants.ts:98`: `!!process.env.DB_KEEPALIVE_IDLE` – any non-empty value (even `0`) enables keepalive; it cannot be turned off on Azure.
- `storage/sequelize.ts:76`: Azure DB TLS without certificate verification (`rejectUnauthorized: false`).
- SQL `replacements`/`bind` and full trade / disclosure payloads are logged at `info` (section 12), so client data can reach logs.
- `server/index.ts:15`: `.catch(({ error }) => …)` destructures the error, so the logged `error` is `undefined`.
- `storage/applyDbFunctions.ts:73-97`: `addCommentToFunction` never returns `true`, so line 147 always `continue`s and "Applied database function successfully" is never logged. If the comment step fails inside the shared transaction, the final commit may fail (inferred).
- `libs/monitoring/metrics.ts`: metrics are defined but never initialized.
- `tasks/openSearchSync/openSearchSyncController.ts:54`: `process.exit()` inside the logged wrapper, so the job's "completed" log is not written.
- `tradeProcessV2/preclearFlip/handler.ts:28` does not force `readOnly` in PROD/SAND, unlike `/v2/process-trade` (`api/handler.ts:38`). May be intended.
- Lambdas without `timeout` (`clientRuleConfigV2/V3`, `exceptionsResolvingV1`) use the Serverless default (6 s, inferred).
