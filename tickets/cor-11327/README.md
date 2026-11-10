# Missed restrictions on merged FactSet entity IDs (COR-11327)

The remediation plan and the scripts for this question: which personal trades did the rules engine approve, although a restriction applied to them, and how do we correct them?

Status: draft. Nobody ran the full set against production yet. Read "Open points" first.

## The problem in one example

1. A compliance officer restricts the company Acme. The restriction stores the FactSet entity ID of Acme on that day: `abc_id`.
2. Later, FactSet merges Acme: the ID `abc_id` becomes `def_id`.
3. An employee buys Acme shares. The rules engine asks the security master (SMA) for the entity of the share. The answer is `def_id`.
4. Before the fix COR-11307, the engine looked for restrictions on `def_id` only. It did not find the restriction on `abc_id` and approved the trade (for example `Matched` instead of `Pending Match`).

The fix (main: release Prod 2610, 2026-10-14) also checks the IDs that were merged directly into the current ID. It applies only to trades processed after the deploy. The older trades keep the wrong result. These scripts find them.

Scope: only single ID changes (`abc_id -> def_id`). Chains (`abc_id -> def_id -> xyz_id`) are out of scope; script `00` tells if they exist.

## Terms

| Term | Meaning |
|---|---|
| Entity ID (CID) | The FactSet ID of a company. Restrictions on a company store it. |
| Security ID | The FactSet ID of a share or bond (`fsym_id`). Each security belongs to one entity. |
| Merge | FactSet replaces an old entity ID with a new one. Table `sym_merged_entity_id(merged_factset_entity_id, to_factset_entity_id, merge_date)` in the SMA database. |
| SMA | The security master service and its database, one per region. |
| Central DB | `rulesenginedb`: the configuration of all clients. |
| Client DB | The database of one client: its trades and restrictions. |
| Restriction rule | Client configuration: which restriction lists to check, and which status to set on a hit (`ACTION.IN`). |
| CNG / SP ticket | Change ticket for production / ticket for access rights. |

## How the engine records a result

The engine writes each trade to the client DB: `bk_txn` (the trade) and typed rows in `bk_txn_extra`:

- `STATUS`: the trade status. Only one row is active; a change adds a new active row and sets the old one inactive.
- `RULE_STATUS`: the result text, for example `RESTRICTION_CHECK_1: true (On Watch List)`. The number is the rule, the names in brackets are the lists that matched.
- `SECURITY_ID`, `MATCHING_PRE_CLEAR_ID`.

There is no separate exception record. The rules run in order; the first rule with a hit and an action sets the status. After that, the SIC check can change the status, and a preclear match changes `Pending Match` to `Matched`.

A restriction applies on the trade date when it had an `Active` status row by the end of that day and was not set `Cleared` or `Inactive` before it. The engine ignores the `is_active` flag, so deleted restrictions still apply. The scripts do the same and show the flags.

## The scripts

| Script | Database | What it does | Output |
|---|---|---|---|
| `00` | SMA | Counts the merges and the chains (must be 0: only single changes are covered). | counts |
| `01` | SMA | Affected securities: entity ID is one side of a change, with the other ID. Once per region, no client data. | `security_hist_entity.csv` |
| `02` | Central | The client's restriction rules and status names. No row: unknown client. | `client_rules.json` |
| `03` | Client | Trades where a restriction on the other ID applied, a rule covers its list, and the engine result did not name it. Read-only. | `candidates.csv` |
| `04` | Client | Option B: sets the new status of the approved trades, with a comment row and a backup. | approved trades, `applied` |
| `05` | Client | Undoes `04` from the backup table. | changed trades, `rolled_back` |

Placeholders: `<CLIENT_ID>` (`02`), `<CLIENT_RULES_JSON>` (`03`, `04`: the content of `client_rules.json`). Input CSV files are temp tables with text columns. `04` and `05` end with `ROLLBACK` (dry run).

### Main columns of `candidates.csv` (one row per trade)

| Column | Meaning |
|---|---|
| `transaction_id`, `trade_date`, `account_last4`, `symbol`, `quantity` | The trade (last 4 digits of the account only). |
| `historical_entity_id`, `merge_date` | The ID the engine missed and the date of the change. |
| `disc_id`, `restriction_list_name` | The missed restriction. |
| `rule_index`, `proposed_status` | The first rule that covers the list and the status it sets. |
| `current_status`, `status_would_change` | Today's status; `true` if the missed restriction changes it. |
| `needs_review` | A person must decide: employee filter on the rule, preclear match, trade before the merge, or deleted restriction. |
| `remediable` | `status_would_change` and not `needs_review`. Only these rows may go to script `04`. |

## How to correct the trades

- **Option A, run the engine again** (`POST v2/process-trade?readOnly=true`): shows today's decision only, cannot correct a trade, exists on AWS only. Use it as a cross-check.
- **Option B, change the status** (scripts `04`, `05`): adds a new `STATUS` row and a `COMMENT` row, sets the old row inactive, as the compliance app does. Needs client approval and a CNG per client. It does not repeat the SIC check.
- **Option C, report only**: the support team sends `candidates.csv` to the compliance officers, who decide in the app.

Recommendation: C for all clients; B only for the trades a client approved; A as a cross-check on AWS.

Script `04` skips a trade when its status changed since the review, it has more than one active status, it has a preclear link, or it was already changed. It locks the rows it changes. Script `05` skips a trade whose status changed after script `04`.

## Runbook

The app in `app/run.js` loads the input CSV files into temp tables, fills in the placeholders, runs the script, and saves every result as CSV.

### Setup

```zsh
cd app && npm ci        # Node 20.12+; libraries: pg, pg-copy-streams, csv-stringify
cp .env.example .env    # fill in SMA_DB_URL, CENTRAL_DB_URL, CLIENT_DB_URL
umask 077               # output files hold employee trade data
```

`.env` holds the connection strings; it is in `.gitignore`. Keep passwords in `~/.pgpass` (mode 600), not in `.env`. A variable set in the shell overrides `.env`, for example `CLIENT_DB_URL=... npm run 03 -- --dir ...` for another client.

### Steps

Run one script at a time. Each run prints every result (first 20 rows) and saves it to `<dir>/steps/<script>.<n>.csv`.

```zsh
npm run 00 -- --dir ../out/eu                       # counts
npm run 01 -- --dir ../out/eu                       # out/eu/security_hist_entity.csv
npm run 02 -- --dir ../out/eu/ACME --client ACME    # out/eu/ACME/client_rules.json
npm run 03 -- --dir ../out/eu/ACME                  # candidates.csv
```

Script `03` finds `security_hist_entity.csv` in its folder or the parent folder. Send `candidates.csv` to the compliance officers on an approved secure channel.

For option B (under CNG 2):

1. The officers return `approved_status_changes.csv` with the columns `transaction_id, expected_status, new_status` (from `candidates.csv` rows with `remediable = true`: `current_status`, `proposed_status`).
2. A DBA creates the backup table (below).
3. `npm run 04 -- --dir ../out/eu/ACME`: dry run. Check the `applied` column; `false` means skipped.
4. `npm run 04 -- --dir ../out/eu/ACME --commit`: applies the changes.
5. Ask the operations team for the cache refresh: `GET <ADMIN_PORTAL_BASE_URL>/pdl/secured/config/cat/RELOAD_CACHE_EXTERNAL?cacheToUpdate=PERSONAL_TRADE` with the `apiKey` header.

Rollback: `npm run 05 -- --dir ../out/eu/ACME`, then with `--commit`, then the cache refresh.

Without the app, run the scripts in a DB tool: import the input CSV files as temp tables and replace the placeholders.

### Backup table and rights (option B)

```sql
CREATE TABLE public.remediation_cor11327_status_backup (
    transaction_id       text        NOT NULL,
    old_extra_id         int         NOT NULL,
    old_status           text,
    new_status           text        NOT NULL,
    new_status_extra_id  int         NOT NULL,
    new_comment_extra_id int         NOT NULL,
    applied_at           timestamptz NOT NULL DEFAULT now(),
    rolled_back_at       timestamptz
);
GRANT SELECT, INSERT, UPDATE ON public.remediation_cor11327_status_backup TO <remediation_role>;
```

The role also needs: `SELECT` on `bk_txn`, `bk_txn_extra_types`, `userdb.users`; `SELECT, INSERT, UPDATE` (and `DELETE` for `05`) on `bk_txn_extra`; `USAGE` on the schemas `public`, `userdb` and on the `extra_id` sequence; `TEMP` on the database.

## Tickets

1. SP: read access to the SMA (each region), the central DB and the client DBs in scope, with `TEMP` on the client DBs.
2. CNG 1: the read-only search (scripts `00`–`03`).
3. Secure hand-off of `candidates.csv` to the compliance officers.
4. CNG 2 per client with option B: backup table and role, script `04` with the dry-run output, rollback with `05`, cache refresh.
5. CNG 3: drop the backup table after the retention period; delete the `out/` folders.
6. Development follow-ups: SMA `all_entity_ids` to follow full chains (if script `00` finds any); holdings have no restriction check; the US government check uses only the current entity ID; a read-only engine call on Azure.

## Open points

Limits of the search:

- Chains of ID changes are not covered.
- Script `03` does not repeat the SIC check and uses today's configuration.
- It does not see trades without `RULE_STATUS` (older loaders) or trades that exist only in the central table `brokerdb.trade_data`.
- List names that contain `,` or `)` break the "already matched" check.
- A rule whose earlier `NOT_IN` action fired can hide a later rule (rare; the row still appears).
- A trade with a preclear link where the missed rule sets `Pending Match` shows `status_would_change = true`, although the preclear would still match. It is `needs_review`, and script `04` skips it.
- Script `04` does not change the `RULE_STATUS` copy in `brokerdb.trade_data`, and leaves `created_date` to the column default.

To confirm before the run:

1. The SMA tables are in the search path of the SMA user.
2. `pdl_client_code` equals the client ID (renamed clients fail the check).
3. Older engine versions write the same `RULE_STATUS` text.
4. Every client DB has the `COMMENT` type in `bk_txn_extra_types`.
5. No trigger or foreign key on `bk_txn_extra` blocks scripts `04` and `05`.
6. The `PERSONAL_TRADE` cache refresh is enough after a direct change (or the OpenSearch sync is also needed), and whether it refreshes one client or all.
7. The production tables match the seed scripts.
8. Whether the compliance app creates an action item for a restricted trade (COR-11307 expects one). If yes, option B must create it too.
9. Which clients run on AWS and which on Azure, and the deploy date of the fix per region.

## Code references

In `compliance-rules-engine/lambdas/rules-engine-3.0/src/` unless noted.

| Topic | Location |
|---|---|
| Order of the trade checks | `serverless/public/functions/tradeProcessV2/tradeProcess.ts:89-121` |
| Restriction check and rule loop | `tradeProcess.ts:326-369` |
| SIC check, preclear match | `tradeProcess.ts:374-407`, `:569-571` |
| Save to `bk_txn` / `bk_txn_extra`, support user | `serverless/public/functions/tradeProcessV2/service.ts:586-719`, `:50-62` |
| Restriction time window and query | `storage/repositories/clientDb/RestrictionRepository.ts:29-41`, `:105-123` |
| Rule matching | `rules/securityListRule.ts:10-131` |
| Read-only engine call (AWS) | `api/handler.ts:38` |
| Cache refresh call | `libs/disclosureAppServer/AdminPortalClient.ts:14-21` |
| `all_entity_ids`, one step only | `compliance-security-master/services/securityService.ts:63-75` |
| SMA security queries | `compliance-security-master/utils/queries.ts:19-59` |
| Status change convention of the app | `compliance-app/backend/cron-jobs/reference-data/sql/functions/CLIENTDB/fn_process_trade_data_direct.sql:322-329` |
