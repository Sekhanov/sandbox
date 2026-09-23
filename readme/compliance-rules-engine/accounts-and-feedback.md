# Accounts and broker feedback

How employee accounts are copied into the central DB (account load) and how broker feedback about those accounts is uploaded and written to the client DB.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

Related docs: `README.md` (index), `trade-process.md`, `holdings-process.md`, `trade-alerts.md`, `central-db-schema.md`, `client-db-schema.md`, `client-config.md`, `runtime-overview.md`.

---

## 1. Overview

Two flows, both about **employee accounts**:

| Flow | Entry point | Direction | Purpose |
|---|---|---|---|
| **A. Account load** | job `account-job` → `tasks/loadAccountData` | client DB `public.account_view` → central `brokerdb.account_data` | Gives central preprocess a list of known accounts (client code, active/inactive) |
| **B. Broker feedback** | private API `POST v1/attributes/bulk-upload-feedback` (`serverless/private/functions/bulkFeedback`) and job `feedback-process-job` (`tasks/feedbackProcess`) | central `public` feedback disclosures → client DB account attributes | Records what the broker said about an account (closed, no activity, on feed, …) |

```
           CLIENT DB (one per client)                         CENTRAL DB
 ┌──────────────────────────────────────┐         ┌──────────────────────────────────────┐
 │ disclosures (BROKER_ACCOUNT, …)      │         │                                      │
 │ attribute_extra (STATUS, FEED_STATUS,│  (A)    │ brokerdb.account_data                │
 │   COMMENT, COMPLIANCE_NOTE, …)       │ account │   ▲ read by fn_process_trades /      │
 │        │                             │  -job   │   │ fn_process_holdings (client code,│
 │        ▼                             │ ──────► │   │ ACEX, INACTIVE_*)                │
 │ public.account_view ─────────────────┼─────────┼───┘                                  │
 │        ▲                             │         │                                      │
 │        │ (B3) ACCOUNT_FEED_STATUS,   │         │ brokerdb.broker_feedback_upload (B1) │
 │        │      COMMENT, COMPLIANCE_   │         │        │ processStaged                │
 │        │      NOTE (support user)    │         │        ▼                             │
 │        │                             │         │ public.disclosures (BROKER_FEEDBACK) │
 │        │                             │         │ public.attribute_extra (STATUS=      │
 │        │                             │         │   Pending, ACCOUNT_ID, …)            │
 │        │                             │         │        │ public.broker_feedback view │
 │        │                             │  (B2)   │        ▼                             │
 │        └─────────────────────────────┼─────────┼── updateAttribute()                  │
 │                                      │         │     ├─ STATUS → Processed            │
 │                                      │         │     └─ "no activity" only:           │
 │                                      │         │        brokerdb.trade_data           │
 │                                      │         │        ACT_RECORD placeholder row    │
 └──────────────────────────────────────┘         └──────────────────────────────────────┘
 (B2) is called inline by the bulk upload, and later by feedback-process-job for rows still Pending.
```

Feedback reaches central `brokerdb.account_data` indirectly: it changes `account_view.feed_status` / `last_support_comment`, which the next account load copies (section 3.3).

---

## 2. Words used in this document

| Term | Meaning |
|---|---|
| **Account** | Employee brokerage account. In the client DB: a `disclosures` row of type `BROKER_ACCOUNT` / `BROKER_MANAGED_ACCOUNT`; `disc_id` = account id. In central: `brokerdb.account_data.account_id`, `trade_data.pdl_account_code`. |
| **Broker feedback** | A note from the broker (via ops/compliance) about one account, e.g. "Account has been closed.". Stored in the central DB as a disclosure of type `BROKER_FEEDBACK`. |
| **Feedback type** | One of the fixed strings of `FeedbackType` (`serverless/public/functions/rulesEngineV2/attributes/types.ts`). The **string value** is stored, not the enum key. |
| **Support user** | `userdb.users` row with `email_address = 'support@paragondatalabs.com'`. Author (`created_by`/`modified_by`) of every row this code writes, in both DBs. |
| **Placeholder trade / ACT_RECORD** | Fake `brokerdb.trade_data` row inserted for "no activity" feedback (section 8). |

---

## 3. Flow A: account load (`account-job`)

### 3.1 Which clients

`tasks/loadAccountData/accountController.ts` → `clientConfigService.getClientsForAccountsLoad()`:
- `rulesenginedb.clients_v2` rows with `tasks_config.accountsLoad.enabled = true`
- and `environment`, `stage`, `region` equal to the running job's `APP_ENV`, `NODE_ENV`, `REGION`.

The setting was added by migration `02_add_accounts_load_config.ts`.

### 3.2 Steps per client (`services/accountService.ts`)

Clients are processed **one by one**, sequentially.

1. **Read** (`fetchAccountDataPerClient`): connect to the client DB and run
   ```sql
   SELECT account_id, owner_id, user_status, is_active AS account_is_active, broker_name, bk_id,
          pref_collection_method, account_status, disclosed_date, account_owner, last_hold, last_trade,
          last_trade_txn, last_plaid_txn, account_type, account_type_value, monitored, feed_status,
          statement_collection, upload, $1 AS client_code, $2 AS client,   -- $1 = clients_v2.id, $2 = clients_v2.name
          pref_manual_coll, last_support_comment
   FROM account_view;
   ```
   All rows, no filter. Inactive accounts are included.
2. **If 0 rows:** log "No account records to update" and **return without deleting** anything.
3. **Write** (`updateAccountData`), in **one central-DB transaction**:
   ```sql
   DELETE FROM brokerdb.account_data WHERE client_code = :clientId;
   INSERT INTO brokerdb.account_data (...) VALUES (...), (...), ...   -- chunks of 1000 rows
   ON CONFLICT (account_id) DO NOTHING;
   ```
   Commit at the end; rollback and rethrow on any error.

`account_id` is the **primary key across all clients**. With `DO NOTHING`, a row whose `account_id` already exists (for another client, or twice in one view) is silently skipped.

### 3.3 Column mapping (`account_view` → `brokerdb.account_data`)

| `brokerdb.account_data` | From `account_view` | Notes |
|---|---|---|
| `account_id` | `account_id` (account `disc_id`) | PK |
| `owner_id` | `owner_id` (`users.user_key`) | Holdings: becomes `holding_data.account_owner_id` |
| `user_status` | `user_status` (`Active`/`Inactive` from `users.is_active`) | ACEX/INACTIVE checks |
| `account_is_active` | `is_active` (disclosure flag) | Column is `text`; not read by this repo |
| `broker_name`, `bk_id` | same | `bk_id` column is `text` |
| `pref_collection_method` | same (`bk_brokers_extra` `BK_SOURCE`) | |
| `account_status` | same (account `STATUS` attribute) | ACEX/INACTIVE checks |
| `disclosed_date`, `account_owner` | `disclosures.created_date`, `created_by` | |
| `last_hold`, `last_trade`, `last_trade_txn`, `last_plaid_txn` | same | Latest dates from `bk_holdings`, `bk_txn`, `tradedb.*` |
| `account_type`, `account_type_value`, `monitored`, `statement_collection`, `upload`, `pref_manual_coll` | same | |
| `feed_status` | same (active `ACCOUNT_FEED_STATUS`) | **Written by broker feedback** |
| `last_support_comment` | same (latest `COMMENT` by the support user) | **Written by broker feedback** |
| `client_code` | `clients_v2.id` (bind `$1`; fallback `clientId`) | Used for the per-client `DELETE` |
| `client` | `clients_v2.name` (fallback `''`) | |
| `first_name`, `last_name`, `account_number`, `account_owner_name` | **not copied** (exist in view and table) | Stay `NULL` |

`account_view` summary (local seed `seed/sql/accountView.sql`; production DDL is not in the repo): one row per `BROKER_ACCOUNT` / `BROKER_MANAGED_ACCOUNT` disclosure (no `is_active` filter), joined to `userdb.users` (owner), active account attributes (`ACCOUNT_NUMBER`, `ACCOUNT_BK_ID`, `STATUS`, `ACCOUNT_FEED_STATUS`, `ACCOUNT_MONITORED`, …), `bk_brokers`, and latest dates from `bk_holdings`, `bk_txn`, `tradedb`. `account_type` is derived: `ACCOUNT_HOLDS_COVERED_SEC = 'No'` → `Account Cannot Hold Covered Securities`; `ACCOUNT_MANAGED = 'Yes'` → `Managed Account`; else `Owner Directed Account`. See `client-db-schema.md` 4.3.

### 3.4 Why it matters: who reads `account_data`

| Reader | Columns | Effect (see `trade-process.md` 1A, `holdings-process.md`) |
|---|---|---|
| `brokerdb.fn_process_trades` | `account_id`, `client_code` | Overwrites `trade_data.pdl_client_code` (logs old value in `brokerdb.client_code_history`) |
| | `account_id` | Unknown account → `status='ACEX'` (unprocessed rows); known again → `ACEX` back to `PENDING` |
| | `account_status`, `user_status` | `'Inactive'` → `status='INACTIVE_ACCOUNT'` (only `PENDING`, `processed='NO'`) |
| `brokerdb.fn_process_holdings` | `owner_id`, `client_code` | Sets `account_owner_id` (if null) and `pdl_client_code` |
| | `user_status`, `account_status` | `INACTIVE_USER` / `INACTIVE_ACCOUNT` with `processed='YES'` |
| | `account_id` | `ACEX` set / reset like trades |
| `brokerdb.cleanup_electra_portal` | `owner_id`, `client` | Not called by code |

The trade process itself (`tradeProcessV2`) checks the account in the **client DB** `account_view`, not in `account_data`.

### 3.5 Failure handling

| Failure | Result |
|---|---|
| One client fails (client DB connect, view query, insert) | Transaction rolled back → that client keeps its **previous** rows. Alert `Account Load \| <clientId>`. Loop continues. |
| Central DB connect or client list fails | Alert `Account Load`, error rethrown → job fails. |
| View returns 0 rows | No delete, no insert → previous rows stay. No alert. |
| Client disabled (`accountsLoad.enabled=false`) | Its rows are never deleted → stay as last loaded. |

Central DB connection is closed in `finally`.

### 3.6 Timing (stale accounts)

There is no schedule in this repo (inferred: set in the deployment, outside this repo). `account_data` is a **snapshot** from the last successful run per client, so:
- **New account** added in the client after the last load → its trades and holdings become `ACEX` at the next preprocess. They return to `PENDING` only after a load **and** a later preprocess.
- **Account removed** from the client view → stays in `account_data` until the next load; then unprocessed trades for it become `ACEX`.
- **Account / user set inactive** → takes effect only after the next load. `INACTIVE_ACCOUNT` on trades is never reset by `fn_process_trades`; on holdings it is final (`processed='YES'`). So a stale `Inactive` row can block trades permanently, even after reactivation.
- Running the account load **before** preprocess reduces these cases (inferred).
- During the load transaction, readers see the old rows until commit (PostgreSQL MVCC), so preprocess never sees a half-empty client.

---

## 4. Flow B: what broker feedback is

- Ops/compliance learn from the broker the state of an employee account (closed, no activity, wrong number, onboarding pending, …).
- It is recorded in the **central DB** as a `BROKER_FEEDBACK` disclosure with EAV attributes (`central-db-schema.md` 4.6):

| `attribute_extra_types.attribute_type` | Value |
|---|---|
| `BROKER_FEEDBACK_CLIENT_CODE` | Client code |
| `ACCOUNT_ID` | Account `disc_id` in the client DB |
| `BROKER_FEEDBACK_TYPE` | `FeedbackType` string |
| `COMMENT` | Optional free text (`additional_comment`) |
| `COMPLIANCE_NOTE` | Optional; never written by this repo (inferred: written by another app) |
| `STATUS` | `Pending` → `Processed` |

- The view `public.broker_feedback` flattens these (`disc_id`, `client_code`, `account_id`, `feedback_type`, `add_comment`, `comp_note`, `status`, `created_date`), only for active `BROKER_FEEDBACK` disclosures and active attributes (`seed/sql/brokerFeedback.sql`).
- Applying feedback = writing account attributes in the **client DB** (section 7).

Sources of feedback:
- **This repo:** the bulk upload API (section 5).
- **Outside this repo (inferred):** `types.ts` says `ACCNT_ACTIVE_ON_FEED` is a "Legacy value still sent by compliance-app" for its single/bulk UI. So compliance-app also creates central feedback rows that only the feedback job applies.

---

## 5. Bulk upload API (`serverless/private/functions/bulkFeedback`)

### 5.1 Request

| Item | Value |
|---|---|
| Endpoint | `POST v1/attributes/bulk-upload-feedback`, service `compliance-rules-engine-v3-private` (`endpointType: 'PRIVATE'`, `serverless/private/serverless.ts`) |
| Body | `multipart/form-data`, field `file` = XLSX (`middyfyMultipart`) |
| Sheet | First sheet only. Row 1 = headers. Blank rows skipped. `row_number` = Excel row number. |
| Columns | `client_code`, `account_id`, `feedback_type`, `additional_comment` (exact header names) |
| `feedback_type` | Full string value, e.g. `Account has been closed.` (section 7.2) |
| Timeout | Lambda 59 s, API Gateway 60 s |
| Azure | No equivalent route in `server/` (AWS only) |

Early `400` responses: no file (`file is required.`), not an XLSX, no data rows.

### 5.2 Validation (`service.ts` → `processBulkFeedback`)

Per row, in order. The first failed check gives the row's `message`:

| # | Check | Error message |
|---|---|---|
| 1 | Joi `schema.ts`: `client_code` required (uppercased), `account_id` required, `feedback_type` in `FeedbackType` values, `additional_comment` optional | Joi message |
| 2 | Client has `tasks_config.feedbackProcess.enabled = true` (same env/stage/region), case-insensitive | `client_code is invalid, inactive, or not enabled for feedback processing.` |
| 3 | Account is an **active** disclosure (`is_active = true`, type `BROKER_ACCOUNT`/`BROKER_MANAGED_ACCOUNT`) in the client DB. Checked once per client for all rows. | `account_id is invalid or account is inactive.` |
| 4 | **30-day duplicate** (section 5.3) | `Feedback already exists within 30 days time frame.` |
| 5 | Same `(client_code, account_id, feedback_type, additional_comment)` earlier in the same file | `Duplicate feedback in the same upload.` |

Check 3 uses the disclosure flag, not the account `STATUS` attribute.

### 5.3 Staging and 30-day duplicate check (`repo.ts`, `queries.ts`)

Duplicate check (central DB):
```sql
select 1 from brokerdb.broker_feedback_upload u
join disclosures d on d.disc_id = u.disc_id
where u.client_code = $1 and u.account_id = $2 and u.feedback_type = $3
  and u.additional_comment is not distinct from $4
  and d.created_date >= CURRENT_DATE - INTERVAL '30 days'
limit 1;
```
- Counts only uploads that reached `public.disclosures` (i.e. were copied, section 5.4), `Pending` or `Processed`.
- A different comment is **not** a duplicate.
- Feedback created outside `broker_feedback_upload` (e.g. compliance-app) is not checked (inferred from the join).

Staging: each valid row is inserted one by one:
```sql
insert into brokerdb.broker_feedback_upload (uid, disc_id, client_code, account_id, feedback_type, additional_comment)
values (floor(random() * 1000000000)::int, upper(substr(md5(random()::text), 1, 16)), $1, $2, $3, $4)
returning disc_id;
```
`disc_id` is a random 16-char uppercase hex string; it becomes the central feedback `disc_id`. `is_loaded` defaults to `false`. Table: migration `19_add_broker_feedback_upload_table.ts` (no keys or constraints).

### 5.4 Copy into central `public` (`processStaged`, one transaction)

For all staged `disc_id`s with `is_loaded = false`:
1. `public.disclosures`: one row, `disc_type` = `BROKER_FEEDBACK`, `created_date`/`modified_date` = `current_date`, author = support user.
2. `public.attribute_extra` (support user, `current_date`):
   - `BROKER_FEEDBACK_CLIENT_CODE` = `client_code` (if not null)
   - `ACCOUNT_ID` = `account_id`
   - `BROKER_FEEDBACK_TYPE` = `feedback_type`
   - `COMMENT` = `additional_comment` (if not null; an empty string is stored)
   - `STATUS` = `Pending`
3. `broker_feedback_upload.is_loaded = true`.

If this transaction fails: every successful row's message becomes `Staged but not processed: <error>`, and the staged rows stay `is_loaded = false` (nothing retries them).

### 5.5 Inline apply (`applyFeedback`)

After the copy, each staged row is applied **immediately and sequentially** via `updateAttribute(...)` (section 7) with:
- `clientId` = `clients_v2.id` (resolved case-insensitively), `feedbackDate` = now (ISO), `comment` = `additional_comment`, `complianceNote` = `null`.

Errors are logged and alerted (`Broker Bulk Feedback`) but not returned. The row stays `Pending` for the feedback job, unless the failure happened after the status change (section 7.4).

### 5.6 Response

HTTP `200`, body `{ status, message, data: [ { row_number, client_code, account_id, feedback_type, additional_comment, success, message } ] }`.
- `message`: `All feedbacks are processed`, or `Feedback staging failed during processing` if step 5.4 failed.
- `status` in the body is always `true` for `200` (`libs/api-gateway.ts` derives it from the HTTP code).
- Skipped rows are logged (`logger.warn`). Unexpected errors → alert + `unhandledError`.

---

## 6. Feedback job (`feedback-process-job`, `tasks/feedbackProcess`)

1. Clients: `clientConfigService.getClientsForFeedbackProcess()` → `tasks_config.feedbackProcess.enabled = true` and the job's env/stage/region (migration `09_add_feedback_process_config.ts`). None → log and exit.
2. Read from the central DB (`queries.ts`):
   ```sql
   SELECT bf.* FROM broker_feedback bf
   WHERE bf.status = 'Pending' AND lower(bf.client_code) IN (:clientIds);
   ```
3. For each row, sequentially: `updateAttribute(centralDb, { clientId: client_code, accountId: account_id, disclosureId: disc_id, feedbackType: feedback_type, feedbackDate: created_date, comment: add_comment, complianceNote: comp_note })`.
4. A failed row → log + alert `Feedback Job | <NODE_ENV> | <APP_ENV> | <client> | <disc_id>`, continue. The row stays `Pending` → retried on the next run.
5. A failure outside the loop → alert, rethrow → job fails.

Difference from the inline path: `feedbackDate` = central `created_date` (a date), and `comp_note` is passed.

---

## 7. Applying feedback (`serverless/public/functions/rulesEngineV2/attributes`)

`service.ts` → `updateAttribute(centralDb, dto)`. Used only by the bulk upload and the feedback job (no HTTP route of its own).

### 7.1 Steps

| # | DB | Query (`queries.ts`) | What it does |
|---|---|---|---|
| 1 | central | `clientConfigService.getClientConfig(clientId)` | Load client by primary key (`clients_v2.id`) |
| 2 | client | `SET_ACTIVE_FALSE_ATTRIBUTE_EXTRA` (`'ACCOUNT_FEED_STATUS'`, accountId) | Deactivates **all** `ACCOUNT_FEED_STATUS` rows of the account. Always runs. |
| 3 | client | `INSERT_INTO_ATTRIBUTE_EXTRA` | New active `ACCOUNT_FEED_STATUS` = mapped feed status (if mapped) |
| 4 | client | same | `COMMENT` = mapped static comment (if mapped) |
| 5 | client | same | `COMMENT` = user comment (if present) |
| 6 | client | same | `COMPLIANCE_NOTE` = compliance note (if present; job path only) |
| 7 | central | `INSERT_ACTIVITY_RECORD` | Only for `ACCNT_OPEN_BUT_NO_ACTVT` (section 8) |
| 8 | central | `SET_EXISTING_PENDING_AS_FALSE` | Feedback `STATUS='Pending'` → `is_active = false` |
| 9 | central | `SET_PROCESS_TRUE_IN_CENTRAL` | Insert active `STATUS='Processed'` (timestamps `CURRENT_TIMESTAMP AT TIME ZONE 'EST'`) |
| 10 | client | `FETCH_ACCOUNT_DETAILS` | Reads active feed status rows; the result is not used by either caller |

- Inserted client rows: `attribute_id` = account id, `created_date` = `modified_date` = `feedbackDate`, author = client DB support user, `is_active = true`.
- Old `COMMENT` / `COMPLIANCE_NOTE` rows are **never deactivated**; they accumulate.
- No transaction: steps 2–10 commit one by one, across two DBs.
- The client DB connection is closed in `finally`.

### 7.2 Feedback mapping (`feedbackMapping.ts`, `types.ts`)

| Enum key | `feedback_type` (stored value) | `ACCOUNT_FEED_STATUS` written | Static `COMMENT` written | Placeholder trade |
|---|---|---|---|---|
| `INVALID_NUMBER` | `Account number provided is not a valid account number.` | `Onboarding Direct Feed - Pending Client Review` | `The account number you provided doesn't match the format required for automated broker feed eligibility. Please update the account number to match exactly what appears on your statements.` | no |
| `NOT_ELIGIBLE_FR_DIRECT_FEED` | `Account type is not eligible for the direct feed.` | `No Feed` | `This type of account is not eligible for the direct feed with this broker.` | no |
| `ACCNT_CLOSED` | `Account has been closed.` | `No Feed - Inactive Account` | `Account has been closed, per the broker.` | no |
| `ACCNT_OPEN_BUT_NO_ACTVT` | `Account confirmed open, but has no activity.` | `Active Direct Feed - No Activity` | `Account confirmed open, but has no activity.` | **yes** |
| `ACCNT_ACTIVE_ON_FEED` (legacy, COR-11190 / COR-11191) | `Account active on electra.` | `Active - Direct Feed` | `Account confirmed on direct feed. No employee action required.` | no |
| `ACCNT_CONFIRMED_DIRECT_FEED` | `Account confirmed on direct feed. No employee action required.` | `Active - Direct Feed` | `Account confirmed on direct feed. No employee action required.` | no |
| `NAME_DOESNT_MATCH_BROKER` | `Account name provided does not match broker records.` | `Onboarding Direct Feed - Pending Client Review` | `The account name and/or number you provided doesn't match broker records. Please update the account name and/or number to match exactly what appears on your statements.` | no |
| `ONBOARD_PENDING` | `Onboarding is pending employee consent.` | `Onboarding Direct Feed - Pending Client Review` | `Account onboarding is on hold pending employee consent.` | no |
| `ONBOARD_PENDING_ACTION` | `Onboarding is pending compliance action.` | `Onboarding Direct Feed - Pending Client Review` | `Account onboarding is pending compliance action to add accounts to the portal.` | no |
| `ONBOARD_PENDING_EMPLOYEE_SIGNATURE` | `Onboarding is pending employee signature.` | `Onboarding Direct Feed - Pending Client Review` | `Account onboarding is on hold pending employee signature.` | no |
| *(unknown string, job path only)* | anything else | **none** (old one still deactivated) | none | no |

For every type, optional extras: user `COMMENT` (`additional_comment` / `add_comment`) and `COMPLIANCE_NOTE` (`comp_note`). Feedback never changes the account `STATUS` or the disclosure `is_active` flag. So "Account has been closed." does not make trades `INACTIVE_ACCOUNT`.

### 7.3 Effect on the client account

- `account_view.feed_status` = new feed status.
- `account_view.last_support_comment` = latest `COMMENT` by the support user = the user comment if given, else the static comment (inferred from insert order and `max(attribute_extra_id)`).
- Both reach central `brokerdb.account_data` at the next account load.

### 7.4 Marking Processed in central

`SET_EXISTING_PENDING_AS_FALSE` then `SET_PROCESS_TRUE_IN_CENTRAL`, keyed by `disc_id`. After this the row has `status = 'Processed'` in `public.broker_feedback` and is ignored by the job. These two statements are separate; see section 10.

---

## 8. The `INSERT_ACTIVITY_RECORD` placeholder trade

**When:** only for `ACCNT_OPEN_BUT_NO_ACTVT`, before the feedback is marked `Processed`.

**What** (central DB):
```sql
INSERT INTO brokerdb.trade_data (...)
SELECT 'xxx' AS broker_code, 0 AS price, 0 AS quantity, 0 AS amount, 0 AS commission_price,
       'USD' AS commission_currency, CAST(NOW() AS DATE) AS transaction_date,
       'ACT_RECORD' AS security_type, 'Account Status Confirmation' AS security_name, 'USD' AS currency_code,
       'Account status confirmed with broker. Account is open.' AS description,
       account_id AS pdl_account_code, client_code AS pdl_client_code,
       CONCAT(DATE_PART('year', NOW()), DATE_PART('month', NOW()), DATE_PART('day', NOW()), '_CONFIRM') AS file_name,
       NOW() AS create_date, 'RNR' AS status, 'YES' AS processed
FROM public.broker_feedback
WHERE feedback_type = 'Account confirmed open, but has no activity.'
  AND account_id = $1 AND lower(status) = 'pending';
```
- One row **per matching Pending feedback** for that account id (any client, any `disc_id`), not per call.
- `file_name` example: `20261013_CONFIRM` (on 2026-10-13); month/day are not zero-padded (`2026103_CONFIRM` on 2026-10-03).
- `source`, `security_id`, `transaction_id` stay `NULL`; `trade_id` from the identity.

**What happens to it:**

| Stage | Effect |
|---|---|
| `fn_process_trades` | `pdl_client_code` aligned to `account_data.client_code` (this statement has no `processed` filter). All status steps need `processed='NO'` or `status='PENDING'` → no change. Unknown-status guard skips it (`processed='YES'`). |
| Security match / exceptions | Not picked (not `PENDING`). |
| Trade process (`FETCH_TRADE_RECORDS`, `processed = 'NO'`) | **Never delivered** to the client DB. |
| Trade alerts | Counted in the 24 h `RNR` count (`status LIKE '%RNR%'`, `tasks/tradeAlerts/tradeAlertsQuery.ts`). |

Purpose (inferred): a central record that the broker confirmed the account is open, for consumers outside this repo. A commented-out check in `fn_exception_mgmnt_refresh` excludes `ACT_RECORD` rows from "RNR without security" counts.

---

## 9. End-to-end example

Client `SAND` (enabled for feedback), active account `ab12-cd34-567`. The XLSX has one data row:

| client_code | account_id | feedback_type | additional_comment |
|---|---|---|---|
| sand | ab12-cd34-567 | Account confirmed open, but has no activity. | Checked with broker 10/12 |

1. **Validate:** Joi uppercases to `SAND`; client enabled; account active in the SAND client DB; no copy of the same 4 values in the last 30 days; not duplicated in the file.
2. **Stage:** `brokerdb.broker_feedback_upload` gets `(uid=<random>, disc_id='3F9AC01B7D2E44A1', 'SAND', 'ab12-cd34-567', <type>, 'Checked with broker 10/12', is_loaded=false)`.
3. **Copy (central, one transaction):** `public.disclosures` `3F9AC01B7D2E44A1` (`BROKER_FEEDBACK`); `attribute_extra`: `BROKER_FEEDBACK_CLIENT_CODE=SAND`, `ACCOUNT_ID=ab12-cd34-567`, `BROKER_FEEDBACK_TYPE=<type>`, `COMMENT=Checked with broker 10/12`, `STATUS=Pending`; `is_loaded=true`.
4. **Apply inline (`updateAttribute`):**
   - SAND client DB: old `ACCOUNT_FEED_STATUS` rows → inactive; new `ACCOUNT_FEED_STATUS=Active Direct Feed - No Activity`; `COMMENT=Account confirmed open, but has no activity.`; `COMMENT=Checked with broker 10/12`.
   - Central: `brokerdb.trade_data` gets one `ACT_RECORD` row (`pdl_account_code='ab12-cd34-567'`, `pdl_client_code='SAND'`, `status='RNR'`, `processed='YES'`).
   - Central: `STATUS=Pending` → inactive; `STATUS=Processed` inserted.
5. **Response:** `200`, row 2 `success: true`, `Feedback successfully Added.`
6. **Feedback job (later):** the row is `Processed` → not selected. Had step 4 failed before step 8 of 7.1, the job would apply it again.
7. **Account load (later):** `brokerdb.account_data` for `ab12-cd34-567` gets `feed_status='Active Direct Feed - No Activity'`, `last_support_comment='Checked with broker 10/12'`.
8. **Preprocess / alerts (later):** the `ACT_RECORD` row is not delivered; it shows up in the next 24 h `RNR` count for SAND.

---

## 10. Notes and unknowns

**Bugs and risks (seen in code, not tested):**
- **`SET_ACTIVE_FALSE_ATTRIBUTE_EXTRA` uses `and` instead of `,`** (`serverless/public/functions/rulesEngineV2/attributes/queries.ts:82`): `set is_active = false and modified_by = (...)` is parsed as `is_active = (false AND (modified_by = ...))`. The result is always `false`, so deactivation works by accident, but `modified_by` (and `modified_date`) are never updated.
- **Step 2 runs even without a mapped feed status** (`service.ts:41-53`): an unknown `feedback_type` (job path, no validation) leaves the account with no active `ACCOUNT_FEED_STATUS`.
- **No transaction in `updateAttribute`** (`service.ts:41-83`, `98-108`):
  - A failure after the client writes but before `Processed` → the job re-applies → duplicate `COMMENT` rows (and a second `ACT_RECORD`).
  - A failure between `SET_EXISTING_PENDING_AS_FALSE` and the `Processed` insert → the feedback has no active `STATUS`, so it is never retried.
- **`INSERT_ACTIVITY_RECORD` matches by account id only** (`queries.ts:57-58`): several Pending "no activity" feedbacks for one account (or the same account id under another client) insert several placeholder rows.
- **`file_name` date is not zero-padded** (`queries.ts:45-50`).
- **Case-sensitive client lookup in the job** (`tasks/feedbackProcess/feedbackProcessController.ts:30` → `ClientRepository.getById`, `findByPk`): the job selects clients case-insensitively, but passes the raw `client_code` from the view. If its case differs from `clients_v2.id`, the error is `Client not found`, an alert is raised every run, and the row stays `Pending`. The bulk path stores `client_code` uppercased, so this hits any client whose id is not uppercase (inferred).
- **Bulk response always `status: true`** for HTTP 200 (`bulkFeedback/handler.ts:47`), even when `processStaged` failed.
- **Staged rows lost on copy failure:** rows with `is_loaded=false` are never retried. A re-upload is allowed because the duplicate check joins `disclosures`.
- **Long uploads (inferred):** inline apply is sequential with a new client DB connection per row. Large files can hit the 59 s Lambda timeout. Rows not yet applied stay `Pending` for the job.
- **Account load:**
  - `ON CONFLICT (account_id) DO NOTHING` (`tasks/loadAccountData/services/accountService.ts:113`) silently drops account ids already loaded for another client. The result depends on client order.
  - An empty view never clears a client (`accountService.ts:51-54`).
- **Typed vs. stored:** `Account.account_is_active` is boolean and `bk_id` a number, but the `account_data` columns are `text` (migration `08`).

**Unknowns:**
- Schedules of `account-job` and `feedback-process-job`, and their order relative to preprocess (not in this repo).
- Production DDL of `account_view`, `broker_feedback`, `account_data` (only seed / `CREATE TABLE IF NOT EXISTS` here).
- Who writes `COMPLIANCE_NOTE` and non-bulk feedback in central (assumed compliance-app).
- Who consumes `ACT_RECORD` rows and `account_data` columns not read here (`feed_status`, `last_*`, `monitored`, …).
- Authentication of the private API beyond `endpointType: 'PRIVATE'` and the allow-all resource policy.
