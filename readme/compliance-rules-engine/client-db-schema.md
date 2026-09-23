# Client DB schema

What the **client DB** holds and how `compliance-rules-engine` uses it.
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.

---

## 1. What this database is

- **One PostgreSQL database per client** (tenant). It belongs to the client's compliance app, where employees disclose accounts, request preclearance, and so on.
- **This service does not own the schema.** It has no migrations for the client DB. The tables are created by the client app.
  - The only DDL in this repo is a test copy in `seed/sql/*.sql`. It is used for local runs only (`seed/client/index.ts`), so production may differ.
- **Connection:** `storage/clientDb.ts` → `connectToClientDb(client)`.
  - Credentials: on AWS, assume the client's role and read its Secrets Manager secret (`clients_v2.aws_environment`). On Azure, read Key Vault (`azure_environment.tenantId`). Locally, env vars (database `compliance-<clientId>`).
  - No `search_path` is set, so unqualified table names mean `public`.
- **What the service does here:**
  - **Reads** employees, accounts, preclearances, restriction lists, trading windows, gifts and security data, to run the compliance rules.
  - **Writes** processed trades (`bk_txn*`), holdings (`bk_holdings*`) and account feed-status attributes (`attribute_extra`).

Related docs: `README.md` (index), `central-db-schema.md` (the database shared by all clients), `preclear-rules-engine.md`, `trade-process.md`, `holdings-process.md`, `accounts-and-feedback.md`, `trade-alerts.md`.

---

## 2. Schemas at a glance

| Schema | Holds | Service access |
|---|---|---|
| `userdb` | Employees and their attributes | read |
| `public`: disclosures | Accounts, preclearances, restrictions, gifts, trading windows (one generic model) | read; writes account attributes |
| `public`: trades | Processed trades: `bk_txn`, `bk_txn_extra`, `bk_txn_extra_types` | **write** + read |
| `public`: holdings | Holdings snapshots: `bk_holdings`, `bk_holdings_extra`, `bk_holdings_extra_types` | **write** + read |
| `public`: brokers | `bk_brokers`, `bk_brokers_extra`, `bk_brokers_extra_types` | read |
| `public.account_view` | View: one row per employee account | read |
| `tradedb` | Raw broker / Plaid transactions | used only inside `account_view` |
| `refdata` / `public.company_info` | Security and company reference data | read (rules) |

---

## 3. How the tables connect

```
userdb.users ──user_key──┬── disclosures.created_by (owner on Azure)
     │ user_id           ├── bk_txn.created_by        (owner on Azure)
     ▼                   └── account_view.owner_id
userdb.user_extra ──► user_extra_types

disclosure_types ◄── disclosures ──disc_id── attribute_extra ──► attribute_extra_types
                       │  (account disclosures: disc_id = account id)
                       ├── account_view.account_id
                       ├── bk_txn.pdl_account_id        ◄── central trade_data.pdl_account_code
                       └── bk_holdings.pdl_account_code

bk_txn ──transaction_id── bk_txn_extra ──► bk_txn_extra_types
bk_holdings ──holding_id── bk_holdings_extra ──► bk_holdings_extra_types

attribute_extra[RESTRICTION_LIST_ID] ──► restriction_lists.restriction_list_id
attribute_extra[ACCOUNT_BK_ID]       ──► bk_brokers.bk_id
```

**Key pattern: EAV ("extra" tables).** Most data is stored as key/value rows:
- the `*_types` table names the attribute (e.g. `STATUS`)
- the `*_extra` table holds the value per record
- `is_active = true` marks the current value. Older values are kept with `is_active = false`.

---

## 4. Tables

### 4.1 `userdb`: employees

| Table | Purpose | Key columns |
|---|---|---|
| `users` | One row per employee | `user_id` PK; `user_key` (business id used everywhere as owner); `email_address`; `is_active`; `first_name`, `last_name`; `dept_id` |
| `user_extra_types` | Names of employee attributes | `extra_type_id`, `attribute_type` |
| `user_extra` | Employee attribute values | `user_id` → users, `extra_type_id` → types, `extra_value`, `is_active` |
| `departments` | Departments (not in seed DDL) | `dept_id`, `dept_name` |

- The **support user** (`email_address = 'support@paragondatalabs.com'`) is the author of everything the service writes.
- Attribute types used: `AUTH0_ROLE`, `CDS_DEPARTMENT_NAME`, `COVERED_PARTY_PRECLEAR_OVERRIDE`, plus any `ATTRIBUTE_TYPE` from rule config.
- Used by rules: `auth0_check_rule`, `covered_party_bypass_rule`, department context (`storage/clientDataFetcher.ts`).

### 4.2 `public` disclosures: accounts, preclearances, restrictions, gifts, windows

Everything an employee or compliance officer "discloses" is a **disclosure**: a header row plus EAV attributes.

| Table | Purpose | Key columns |
|---|---|---|
| `disclosure_types` | Kind of disclosure | `disc_type_id`, `disc_type` |
| `disclosures` | One row per disclosure | `disc_id` PK; `disc_type` → types; `created_by` (owner `user_key`); `created_date`; `is_active`; `owner` (Azure only) |
| `attribute_extra_types` | Names of disclosure attributes | `attribute_extra_type_id`, `attribute_type` |
| `attribute_extra` | Attribute values | `attribute_id` (= `disc_id`), `attribute_extra_type_id`, `attribute_value`, `created_date`, `is_active` |
| `restriction_lists` | Named lists (Restriction List, Watch List, …) | `restriction_list_id`, `restriction_list_name` |

**`disc_type` values and their attributes:**

| `disc_type` | What it is | Main attributes (`attribute_type`) | Used by |
|---|---|---|---|
| `BROKER_ACCOUNT`, `BROKER_MANAGED_ACCOUNT` | Employee brokerage account. **`disc_id` = account id** | `ACCOUNT_NUMBER`, `ACCOUNT_BK_ID`, `STATUS`, `ACCOUNT_MANAGED`, `ACCOUNT_HOLDS_COVERED_SEC`, `ACCOUNT_TYPE`, `ACCOUNT_FEED_STATUS`, `ACCOUNT_MONITORED`, `ACCOUNT_OWNER`, `COMMENT`, `COMPLIANCE_NOTE`, … | `account_view`, managed-account check, feedback |
| `TRADE_PRECLEARANCE` | Employee's request to trade | `ACCOUNT_ID`, `SECURITY_ID`, `PRECLEAR_ACTION` (Buy/Sell…), `PRECLEAR_QUANTITY`, `PRECLEAR_OPTIONS`, `STATUS` (Approved/Denied/In Review) | trade matching (`tradeProcessV2/service.ts`), `pre_clear_frequency_rule` |
| `RESTRICTION` | Security on a restriction list | `RESTRICTION_LIST_ID`, `SECURITY_ID`, `CID`, `STATUS`, audience attributes (e.g. `RESTRICTION_MNPI_INSIDERS`) | `RestrictionRepository`, rulesEngineV2 |
| `GIFT_ENTERTAINMENT` | Gift or entertainment | `GE_VALUE`, `GE_DATE`, `GE_PARTICIPANT_LIST`, `GE_CATEGORY`, `GE_DIRECTION`, `STATUS` | `annual_gift_limit_rule` |
| *(not filtered)* | Trading window | `WINDOW_OPEN`, `WINDOW_CLOSE`, `WINDOW_TYPE`, `STATUS` | rulesEngineV2 context loader (`TRADING_WINDOW_*_OPEN`, checked via `comparison_rule`). See `preclear-rules-engine.md` |

**Only write by the service:** account feedback (`rulesEngineV2/attributes/service.ts`).
1. Deactivate the old `ACCOUNT_FEED_STATUS`.
2. Insert new `ACCOUNT_FEED_STATUS`, `COMMENT` and `COMPLIANCE_NOTE` rows, authored by the support user.

### 4.3 `public.account_view`: one row per employee account (view)

A flat view over account disclosures, joining `users`, account attributes, `bk_brokers`, and the latest holding and trade dates.

| Column | Meaning |
|---|---|
| `account_id` | Account `disc_id`. **Matches central `trade_data.pdl_account_code`** |
| `owner_id`, `first_name`, `last_name`, `user_status` | Employee who owns the account |
| `account_status`, `is_active` | `STATUS` attribute, disclosure active flag |
| `account_type` | `Account Cannot Hold Covered Securities` / `Managed Account` / `Owner Directed Account` |
| `broker_name`, `bk_id`, `account_number` | Broker and account number |
| `feed_status`, `monitored`, `statement_collection`, `upload`, … | Account attributes |
| `last_hold`, `last_trade`, `last_trade_txn`, `last_plaid_txn` | Latest dates from `bk_holdings`, `bk_txn`, `tradedb` |

How the service uses it:
- **Trade process**:
  - checks that the account exists (`validateAccountIdExists`); the trade fails if it doesn't
  - takes `owner_id`, which becomes the trade owner
  - takes `account_status` and `account_type`, used by `EXCLUDE_RULE`
- **Account load job** (`tasks/loadAccountData`): copies the whole view into central `brokerdb.account_data`.

### 4.4 `public` trades: `bk_txn*` (written by trade process)

| Table | Purpose |
|---|---|
| `bk_txn` | One row per trade delivered to the client |
| `bk_txn_extra` | Trade attributes (EAV), linked by `transaction_id` |
| `bk_txn_extra_types` | Attribute names |

**`bk_txn`: main columns**

| Column | Filled from (central `brokerdb.trade_data`) |
|---|---|
| `transaction_id` PK | `trade_data.transaction_id`, or a generated hash |
| `trade_id` | `trade_data.trade_id` (link back to central) |
| `pdl_account_id` | `pdl_account_code` (= account `disc_id`) |
| `pdl_client_code`, `bk_code` | client code, broker code |
| `trade_date`, `order_date`, `created_date` | `transaction_date` |
| `security_*`, `isin`, `cusip`, `symbol`, `exchange`, `currency_code` | security fields |
| `transaction_type`, `price`, `quantity`, `amount`, `commission_*` | trade fields |
| `created_by`, `modified_by` (`owner` on Azure) | account owner (`account_view.owner_id`) |
| `processed_date` | load time (default now, US/Eastern) |

**`bk_txn_extra`: rows written per trade** (`insertIntoBkTxnExtra`, `tradeProcessV2/service.ts`)

| `attribute_type` | Value |
|---|---|
| `STATUS` | compliance result (`match_status`): e.g. `Matched`, `Pending Match`, `Preclear Not Needed`, `Managed Account` (strings come from client config) |
| `SECURITY_ID` | matched security, or `RNR_<reason>` |
| `BK_ACCOUNT_ID` | account id |
| `RULE_STATUS` | rule audit trail (`|COOK_DATA:true|…`) |
| `MATCHING_PRE_CLEAR_ID` | matched preclearance `disc_id` (if any) |
| `COMMENT` | only for preclear flips |

- **Written by:** trade process `loadToTarget`, in one client transaction. It is skipped when the `transaction_id` already exists, for managed accounts (unless `LOAD_MANAGED_ACCOUNTS`), and for accounts excluded by `EXCLUDE_RULE`.
- **Read by:**
  - preclear quantity matching (`MATCHING_PRE_CLEAR_ID`)
  - holding period and past-transaction rules (`SECURITY_ID`, `trade_date`)
  - trade load alert counts (`processed_date`, `SECURITY_ID LIKE 'RNR_%'`)

### 4.5 `public` holdings: `bk_holdings*` (written by holdings process)

| Table | Purpose | Key columns |
|---|---|---|
| `bk_holdings` | Holdings snapshot per account and date | `holding_id` PK (generated), `pdl_account_code`, `as_of_date`, `security_id`, `quantity`, `price`, `amount`, `holding_number` (= central `holding_data.holding_number`), `source`, `owner` (Azure) |
| `bk_holdings_extra` | Holding attributes | `holding_id`, `extra_type_id`, `attribute_value`, `is_active` |
| `bk_holdings_extra_types` | Attribute names | only `STATUS` is used |

- **Written by:**
  - `services/holdings/holdingsService.ts`: copies central `holding_data` rows (status `TRADE`) in batches of 200.
  - `holdingsStatusUpdateService.ts`: sets `STATUS` to `Active` / `Inactive` by comparing snapshots. The old row is deactivated and a new one inserted.
- **Read by:** `BkHoldingsRepository` (latest snapshot per account), `account_view.last_hold`.

### 4.6 `public` brokers: `bk_brokers*`

| Table | Purpose | Key columns |
|---|---|---|
| `bk_brokers` | Brokers known to the client | `bk_id`, `broker_name`, `bk_electra_id` |
| `bk_brokers_extra`, `bk_brokers_extra_types` | Broker attributes | only `BK_SOURCE` is used (→ `account_view.pref_collection_method`) |

The account's broker is linked through the `ACCOUNT_BK_ID` attribute. Preclear flip uses `bk_electra_id` as `bk_txn.bk_code`.
These are not the same as central `bk_brokers_central*`.

### 4.7 `tradedb`: raw transactions

`transaction_data_electra` and `transaction_data_plaid` are used **only** by `account_view`, for the latest transaction dates. The service never reads them directly.

### 4.8 Security reference data

| Table | Columns used | Used by |
|---|---|---|
| `refdata.company_info` and `public.company_info` | `security_id`, `cid`, `ticker`, `sec_type`, `security_type`, `company_name`, `cusip`, `isin`, `exchange_code`, `currency`, `country_code` | `libs/rules/*` (security type, ticker, SIC, country, volume rules), preclear flip |
| `refdata.company_extra`, `refdata.company_extra_type` | `cid`, `extra_type` = `COMPANY_SIC`, `extra_value` | `sic_restriction_rule` |

Not in the seed DDL. It's unknown whether these are local or foreign tables.

---

## 5. Value dictionaries

| Where | Values |
|---|---|
| Account `STATUS` | `Active`, `Inactive` (`EXCLUDE_RULE` checks `INACTIVE`) |
| Preclearance `STATUS` | from client `preclearStatusConfig`: e.g. `Approved`, `Denied`, `In Review`, `Other` |
| Restriction `STATUS` | `Active`; `Cleared` / `Inactive` = not in force |
| `ACCOUNT_MANAGED` | `Yes` / `No` |
| `ACCOUNT_HOLDS_COVERED_SEC` | `No` → account type "Account Cannot Hold Covered Securities" |
| `ACCOUNT_FEED_STATUS` (written) | `Onboarding Direct Feed - Pending Client Review`, `No Feed`, `No Feed - Inactive Account`, `Active Direct Feed - No Activity`, `Active - Direct Feed` |
| `bk_txn_extra` `STATUS` | from client `tradeStatusConfig`: `Matched`, `Pending Match`, `Preclear Not Needed`, `Managed Account` (seed values) |
| `bk_holdings_extra` `STATUS` | `Active`, `Inactive` |
| JSON-string attributes | `WINDOW_TYPE` (`["BUY","SELL"]`), `GE_PARTICIPANT_LIST`, `RESTRICTION_MNPI_INSIDERS`, `RESTRICTION_MNPI_DEPARTMENT` |

---

## 6. AWS vs Azure

| | AWS | Azure |
|---|---|---|
| `owner` column on `bk_txn`, `bk_holdings`, `disclosures` | absent | present (`seed/sql/azure.sql`) |
| Owner of a record | `created_by` | `COALESCE(owner, created_by)` (`libs/helper.ts` `getOwnerColumn`) |
| Trade load alert | runs from `trade-alerts-job` | runs at the end of `trade-process-job` |

---

## 7. Notes and unknowns

- **Same-named tables in central.** `users`, `disclosures`, `attribute_extra*` and `bk_txn*` also exist in the central DB with different content. Central `bk_txn*` holds exceptions, for example. Always check which connection a query uses.
- **Production DDL is not in this repo.** Types, constraints and the real `account_view` definition can differ from the seed.
- **Not determined:**
  - `userdb.departments` and `refdata.*` ownership and full schema
  - whether any other system writes `bk_txn*` / `bk_holdings*`
  - the meaning of columns the code never uses (`restriction_lists.restriction_list_type`, `bk_holdings.identifier`, `bk_txn.source`)
- **Seed gaps:** the seed lacks `bk_txn_extra_types.COMMENT` (needed by preclear flip, which throws without it), `BROKER_MANAGED_ACCOUNT` and the `WINDOW_*` attribute types.
