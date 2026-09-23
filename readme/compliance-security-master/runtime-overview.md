# Runtime overview

How the service is built, starts, authenticates callers, talks to its databases, and is deployed and tested.

Related docs: `README.md` (index), `api-reference.md`, `data-and-replication.md`.

---

## 1. Architecture

```
  compliance-rules-engine ─┐                       ┌──► RDS (PostgreSQL)          most reads; custom securities
  (service account)        │                       │      all_securities, security_info, entity_base_info, …
                           ├─► SMA (Express, :3010)┼──► Redshift (FactSet)        some legacy reads, history
  Client UI / Swagger ─────┘   Keycloak bearer     │      factsetdb1 / factsetdb2 / refdata
  (public OAuth client)                            ├──► ADMIN DB (central PG)     client configs, translation map,
                                                   │      rulesenginedb, brokerdb    broker feedback
                                                   └──► OpenSearch                v2 security / entity search

  Redshift ──(pg_cron + dblink, nightly)──► RDS      see data-and-replication.md
```

- One process, no background jobs in Node. All scheduled work runs inside RDS as `pg_cron` jobs (SQL in `queries/`).
- Stateless. The only in-process cache is the translation map (5 min, `services/securityLookup/bulk/translate.ts`).

### Code layout

| Folder | Content |
|---|---|
| `index.ts` | Entry point: DB init, Express setup, routes |
| `routes/` | Route tables. `index.ts` mounts groups and applies role checks |
| `controllers/` | Read request params, call a service, send the response envelope |
| `services/` | Business logic. `securityService.ts` holds most endpoints; `securityLookup/` is the bulk matcher |
| `storage/` | Sequelize connection factory, `DatabaseService.query()` with retry, knex query builder, `rds/*` loaders for the matcher |
| `validators/` | Joi schemas for every endpoint |
| `middlewares/` | Role auth, Joi validation, file upload, response envelope, error handler |
| `config/` | Keycloak, OpenSearch client and search request, Swagger, DB connection init |
| `utils/` | Env constants, SQL strings (`queries.ts`), date helpers, logging |
| `queries/` | SQL deployed manually to RDS / Redshift: refresh functions, `pg_cron` schedule, migrations |
| `swagger/` | OpenAPI YAML served at `/api-docs` |
| `thirdPartyServces/` | AWS Secrets Manager reader; Redis client (not used, see §9) |

---

## 2. Startup (`index.ts`)

1. `initializeDbConnections()` (`config/connectionConfig.ts`):
   - registers `REDSHIFT` from env `PG_*`;
   - registers `RDS` from env `RDS_*`;
   - reads AWS Secrets Manager secret `ADMIN_DB_SECRETS` in region **`us-east-1`** (hard-coded) and registers `ADMIN` from its `host`, `port`, `dbname`, `username`, `password`.
   If the secret read fails, the promise rejects and Express never starts (no catch).
2. Express middleware, in order:
   1. JSON body limit `30mb`, URL-encoded `15mb`;
   2. `keycloak.middleware()` — validates any bearer token and attaches it as `req.kauth.grant` (invalid token → no grant);
   3. `GET /swagger.json` and Swagger UI at `/api-docs` (OAuth client = `KEYCLOAK_PUBLIC_CLIENT_ID`). In `prod`, the custom-securities spec is hidden;
   4. `cors()` (all origins);
   5. `morgan` access log via `logInfo`, health-check skipped.
3. Routes:
   - `GET /<NODE_ENV>/security-master/factset/health-check` — no auth, returns `200 Ok`;
   - everything else under `/<NODE_ENV>` (see `api-reference.md`).
4. `errorHandler` → `500` with the error message.
5. Listen on `PORT` (default `3010`).

---

## 3. Authentication and roles

Code: `config/keycloak.ts`, `middlewares/auth/roleAuth.ts`.

- Keycloak, `bearer-only`. Realm `KEYCLOAK_REALM`, server `KEYCLOAK_SERVER_URL`.
- `requireRoles(...roles)` per route group:
  1. `REQUIRE_AUTH` false → skip all checks (default is **true**).
  2. No valid token → `401 "No access token provided or token is invalid"`.
  3. Token `azp` must be `KEYCLOAK_CLIENT_ID` (service account) or `KEYCLOAK_PUBLIC_CLIENT_ID` (UI) → else `401`.
  4. Logs `client_id`, `preferred_username`, roles, URL.
  5. Sets `req.user = preferred_username`, `req.clientId = client_id`.
  6. Calls `keycloak.protect('<KEYCLOAK_PUBLIC_CLIENT_ID>:<ROLE>')` → role missing → `403 "Insufficient permissions"` with `{ required, userRoles }`.
- Roles are client roles of `KEYCLOAK_PUBLIC_CLIENT_ID`: **`SMA_READ`**, **`SMA_WRITE`**.

| Route group | Required role |
|---|---|
| `/security-master/factset/*`, `/v2/security-master/factset/*` | `SMA_READ` |
| `/security-master/central-custom/security` (POST, DELETE) | `SMA_READ` — see note below |
| `/broker/*` | `SMA_WRITE` |

> **Note:** the custom-security routes call `requireRoles(SMA_READ, SMA_WRITE)`. `keycloak.protect()` (keycloak-connect 26.1.1) takes only one spec, so only `SMA_READ` is enforced. A read-only caller can create and delete custom securities (seen in code, not tested).

---

## 4. Response envelope

Code: `middlewares/response/resSend.ts`, `msgs.ts`.

```json
{ "status": true, "message": "Security Match Data fetched", "data": [...], "__debug": {...} }
```

- `status` = `true` for 200/201, `false` otherwise (also `false` for `207`).
- `data` / `__debug` are omitted when undefined.
- Codes used: `200`, `201`, `207`, `400`, `401`, `403`, `404`, `406` (Joi validation error), `500`.
- Validation errors → **`406`** with the Joi message (not 400).
- Unhandled errors → `500` with `error.message` (DB error text can reach the caller).

---

## 5. Database access

Code: `storage/`.

- Sequelize, dialect `postgres` for all three connections (Redshift speaks the PG protocol).
- Pool per connection: `max 250`, `min 10`, `acquire 45 s`, `idle 60 s`.
- `databaseService.query(db, sql, params?, { retry?, retryAttempts? })`:
  - params: positional array → `bind` (`$1…`), or `{ replacements }` (`:name`);
  - always `QueryTypes.SELECT`, returns `{ rows }`;
  - **retry**: up to 3 attempts, 1 s apart, on any error (not only timeouts). `retry: false` disables it (used for inserts);
  - logs: slow query (≥ `SQL_SLOW_QUERY_MS`, default 2000 ms), timeouts, pool saturation (`waiting > 0`).
- Query building: raw SQL strings in `utils/queries.ts` and in services; `pg-format` (`%L`, `%I`) for lists; knex (`storage/qb.ts`) builds SQL text for the matcher loaders, then runs it through Sequelize.
- Most SQL tags itself with `-- QueryName:<NAME>` so Redshift usage can be tracked (`queries/redshift_query_history.sql`).

Which DB each endpoint uses: `api-reference.md`.

---

## 6. Environment variables

From `utils/constants.ts`. Values per environment are not in the repo (deployed `app.env` comes from S3, see §7).

| Var | Default | Use |
|---|---|---|
| `NODE_ENV` | — | URL prefix (`/dev`, `/tst`, `/prod`), Swagger base path; `prod` hides custom-security docs; `dev` enables search `__debug` |
| `PORT` | `3010` | HTTP port |
| `HOST` | `''` | Swagger host |
| `DEBUG` | — | `debug` namespaces, e.g. `log:*` (logs are silent without it) |
| `PG_HOST`, `PG_PORT`, `PG_DATABASE`, `PG_USERNAME`, `PG_PASSWORD` | — | Redshift |
| `RDS_HOST`, `RDS_PORT`, `RDS_DATABASE`, `RDS_USERNAME`, `RDS_PASSWORD` | — | RDS |
| `ADMIN_DB_SECRETS` | `''` | AWS Secrets Manager secret name for the ADMIN DB |
| `REQUIRE_AUTH` | `true` | `'false'` disables role checks |
| `KEYCLOAK_SERVER_URL`, `KEYCLOAK_REALM` | `''` | Keycloak |
| `KEYCLOAK_CLIENT_ID` | `''` | Service-account client allowed as `azp`; marks service-account calls in custom-security create |
| `KEYCLOAK_PUBLIC_CLIENT_ID` | `''` | UI client; owner of the `SMA_*` roles |
| `OS_URL` | `''` | OpenSearch node. Empty → v2 search throws |
| `OS_INDEX_NAME` | `''` | Security index |
| `OS_ENTITY_INDEX_NAME` | `''` | Entity index |
| `OS_LIMIT` | `100` | Max hits per search |
| `LEGACY_ENTITY_SEARCH` | `false` | `'true'` → `/entity-search` uses the old SQL search |
| `SQL_SLOW_QUERY_MS` | `2000` | Slow-query log threshold |
| `SQL_LOG_QUERY_MAX_LENGTH` / `SQL_LOG_BIND_PREVIEW_MAX_LENGTH` / `REQUEST_PAYLOAD_LOG_MAX_LENGTH` | `500` / `200` / `500` | Log truncation |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_SSL`, `OS_SSL`, `SWAGGER_SPEC_PATH` | — | Defined but unused |

AWS SDK credentials (for Secrets Manager) come from the host role / default chain (inferred).

---

## 7. Build and deploy

### Build
- `npm run build` = `tsc && tsc-alias` → `dist/`. `npm start` = `node -r dotenv/config dist/index.js`.
- `Dockerfile`: two-stage, **`node:18-alpine`**, copies `dist/` and `swagger/*.yaml`, `npm install --production`, exposes `PORT`.
- Node versions disagree: Dockerfile 18, Azure CI 22, repo README "v20".

### Deploy (AWS, from repo files)
1. **CodeBuild** (`buildspec.yml`): `docker-compose build`, tag and push `<NODE_ENV>-compliance-security-master-image:latest` to ECR (`AWS_ACCOUNT_NUMBER`, `AWS_REGION`).
2. **CodeDeploy** (`appspec.yml`) runs `deploy.sh` on an EC2 host as `ubuntu`:
   - deployment group name is parsed as `<node_env>-<port>-<account>`;
   - logs into ECR, stops and removes the old container, `docker system prune -a -f`;
   - pulls `:latest`, downloads env file `s3://pdl-cat-internal-<node_env>/paragon-app/compliance-security-master/app.env`;
   - `docker run --restart=always -p <port>:<port> --env-file app.env`, logs to CloudWatch group `/intapp/ec/<node_env>/security-master`.
- Hosts seen in tests: `https://dev-sma.apps.paragondatalabs.com/dev`, `https://tst-sma.apps.paragondatalabs.com/tst`.
- How CodeBuild is triggered (the CodeCommit mirror, see below) is not in the repo (inferred).

### Pipelines
| File | What it does |
|---|---|
| `.azuredevops/pipelines/ci.yaml` (used by `.azure-devops/ci.yml`) | Every branch: git version; Node 22; install from Artifactory; read `KEYCLOAK-CLIENT-SECRET` from Key Vault; unit tests; integration tests against **dev** SMA (`tst` on branch `tst`); publish JUnit, coverage, Allure. Separate lint job (`eslint`, `tsc --noEmit`). |
| `.azuredevops/pipelines/mirror-to-codecommit.yaml` | Every branch: `git push --mirror` to AWS CodeCommit `azure-security-master` (us-east-1). |
| `Jenkinsfile` | Older Jenkins pipeline: lint, unit tests, integration tests with secret from Vault. Possibly unused (inferred). |

---

## 8. Local development and tests

```zsh
npm install
npm run dev                 # tsx watch, loads .env
npm run lint && npm run lint-ts
npm run test:unit
npm run test:integration    # --runInBand
```

- `.env` in repo root supplies all env vars (never commit it).
- **Unit tests** (`tests/unit/`): Jest + ts-jest, DB and OpenSearch mocked.
- **Integration tests** (`tests/integration/`): HTTP calls through `supertest` with a real Keycloak token (`client_credentials`, `KEYCLOAK_CLIENT_ID` + `KEYCLOAK_CLIENT_SECRET`, only if `REQUIRE_AUTH=true`). Target (`setupTestServer.ts`):

  | Setting | Target |
  |---|---|
  | `SMA_BASE_URL` set | that URL (e.g. a local SMA `http://localhost:3010/dev`) |
  | `TEST_ENV=tst` | TST server |
  | `TEST_ENV=local` | in-process Express with real DB connections (needs DB creds) |
  | otherwise | DEV server |

- So CI integration tests test the **already deployed** dev/tst service, not the branch code (unless `TEST_ENV=local`).
- Reports: `test-results/junit*.xml`, `allure-results/{unit,integration}`.
- The Keycloak secret for local runs: Key Vault secret `KEYCLOAK-CLIENT-SECRET` in subscription `Development 1` (repo README, steps 1–3).

---

## 9. Notes and unknowns

- **Dead code / unused deps:** `thirdPartyServces/redis.ts` (only mocked in tests; `ioredis` still a dependency), `typesense`, `validators/entityValidator.ts`, `generateCompanyId`, `utils/queries.ts:healthcareSicCodes`, `securityLookupCrdCikRssd`.
- **ADMIN secret region** is hard-coded to `us-east-1`.
- **`SMA_WRITE` not enforced** on custom-security routes (§3).
- **Retry on every error** in `DatabaseService` also retries non-transient errors (syntax, constraint) 3 times.
- `keycloak.middleware()` also registers keycloak-connect's default `/logout` and admin callback routes (library default; inferred harmless with `bearer-only`).
- Deployed env values, the S3 `app.env`, EC2 host layout, and RDS `pg_cron` state are not in the repo.
