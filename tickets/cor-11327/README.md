# Missed restrictions on merged FactSet entity IDs

This folder holds the remediation plan for the spike COR-11327 and the draft scripts for it. The plan answers two questions:

1. Which trades did trade processing approve, although a restriction applied to them?
2. How do we correct those trades?

An example of such a trade:

1. A compliance officer adds the company Acme to a restriction list. Employees must not trade Acme shares. At that time, the FactSet ID of Acme is `X`, so the restriction stores `X`.
2. Later, Acme merges with another company. FactSet removes the ID `X` and gives the company the new ID `Y`. The restriction still stores `X`.
3. An employee buys Acme shares. Trade processing asks the security master which company the share belongs to. The answer is `Y`.
4. Trade processing looks for restrictions on `Y`. It finds none, because the restriction is on `X`. It approves the trade, for example with the status `Matched`.

The correct result was the status `Pending Match`, so that compliance reviews the trade. This is a missed violation.

The fix in COR-11307 also checks old IDs such as `X`, but only for new trades. Trades that the engine processed before the fix keep the wrong result. Question 1 is how to find all these trades. Question 2 is what to do with them.

Nobody ran these scripts against a database yet. No branch or pull request contains this folder. Before anyone runs a script, read the sections "Known issues in the scripts" and "Facts to confirm before the run".

All code references point to the `origin/main` branch of the repository `compliance-rules-engine`, in the folder `lambdas/rules-engine-3.0/src/`. The section "Code references" at the end lists the exact files and lines. The main text explains the behavior in words, so you do not have to read the code.

## Terms

The document uses these terms:

| Term | Meaning |
|---|---|
| FactSet | The vendor that supplies the security and company data. |
| Entity ID (CID) | The FactSet ID of a company, for example `0A1B2C-E`. The compliance app calls it CID. |
| Security ID | The FactSet ID of one tradable instrument (a share, a bond). The column name is `fsym_id`. Each security belongs to one entity. |
| Merge | FactSet replaces an old entity ID with a new one, for example after an acquisition. The old ID stops to exist in FactSet data. |
| SMA | The security master service (repository `compliance-security-master`). It tells the rules engine which entity a security belongs to. It has its own database (SMA RDS), one per region. |
| Restriction | A record that forbids employees to trade the securities of a company. A restriction on a company stores the entity ID of the company. |
| Restriction list | A named group of restrictions, for example "Watch list". |
| Restriction rule | A part of the configuration of a client. It says which restriction lists to check and which trade status to set when a trade hits a restriction. |
| Trade status | The status of a personal trade in the compliance app, for example `Matched` or `Pending Match`. |
| Preclear | A request that an employee submits before a trade. When a trade matches an approved preclear, the trade status becomes `Matched`. |
| Client DB | The database of one client (tenant). It holds the trades and the restrictions of that client only. |
| Central DB | The shared database `rulesenginedb`. It holds the configuration of all clients. |
| SP ticket | A ticket that asks for access rights. |
| CNG ticket | A change ticket. Every change in production needs an approved CNG ticket. |

## The problem

A restriction stores the entity ID that the company had on the day somebody created the restriction. Later, FactSet can merge that ID into a new ID. The restriction still holds the old ID.

When a trade arrives, the rules engine asks the SMA for the entity of the traded security. The SMA returns the current entity ID only. Before the fix in COR-11307, the engine compared only this current ID with the restrictions. A restriction on the old ID did not match, and the engine approved the trade.

Example:

1. A compliance officer restricts company A. Its entity ID is `X`.
2. FactSet merges `X` into `Y`.
3. An employee buys a share of company A. The SMA says that the share belongs to `Y`.
4. The engine looks for restrictions on `Y` only. It does not find the restriction on `X`, and the trade passes.

## What the fix changed and what it still misses

The fix in COR-11307 went to the development branch on 2026-09-22 (commit `e6645005`). It went to `main` with the release Prod 2610 on 2026-10-14 (commit `dbfac0e5`). The production deploy date for each region is not known yet.

After the fix, the SMA returns a list `all_entity_ids`. The engine compares every ID in that list with the restrictions.

The list contains the current ID and the IDs that FactSet merged directly into it. It does not contain older IDs. If FactSet merged `X` into `Y` and later `Y` into `Z`, the list for a security of `Z` is `Z, Y`. A restriction on `X` is still missed. This document calls this case a chain with more than one step.

Script `00` counts these chains. If it finds any, the SMA needs a follow-up change (see "Tickets").

The fix applies only to trades that the engine processes after the deploy. Trades that the engine processed before the deploy keep their old result. This plan is about those old trades.

## How the engine records a restriction hit

The engine processes a trade in these steps, in this order:

1. Prepare the trade data.
2. Check for a managed account.
3. Check that the record is a trade.
4. Check for a US government security.
5. Check the holding period.
6. Check if the trade needs a preclear.
7. Check the restrictions.
8. Check the SIC code (the industry code of the company).
9. Match the trade to a preclear.
10. Save the result.

Steps 3, 4 and 5, and step 2 for a managed account with the rules turned off, can stop the processing. In that case, the restriction check does not run. Step 6 does not stop the processing.

The restriction check goes through the restriction rules of the client in order. The first rule that finds a restriction and has an action sets the trade status. In the seed configuration, the action sets `Pending Match`.

Two later steps can change that status again:

- The SIC check (step 8) can set a different status.
- The preclear match (step 9) runs only while the status is `Pending Match`. If it finds a matching preclear, the status becomes `Matched`.

The engine saves the result in the client DB, in the table `bk_txn_extra`. One trade gets several rows there. Each row has a type and a value:

| Row type | Value |
|---|---|
| `STATUS` | The trade status, for example `Pending Match`. |
| `RULE_STATUS` | A text that lists the result of each check. For the restriction check, the text looks like `RESTRICTION_CHECK_1: true (On List A,List B)`. The number is the rule number. `true` means that the rule found a restriction. The names in brackets are the restriction lists that matched. |
| `SECURITY_ID` | The security ID of the trade. |
| `MATCHING_PRE_CLEAR_ID` | The preclear that the trade matched, if any. |

Only one `STATUS` row of a trade is active (`is_active = true`). When the status changes, the app adds a new active row and sets the old row to inactive.

The engine does not create a separate exception record or action item for a restriction hit. The only trace of the hit is the `STATUS` and `RULE_STATUS` rows. The central table `brokerdb.trade_data` keeps a copy of `RULE_STATUS`. The central table `exceptions` has no relation to this problem. It holds only the trades whose security the app did not identify.

Note: the test steps in COR-11307 expect that the app creates an action item for a restricted trade. The rules engine code does not create one. Perhaps the compliance app creates it from the trade status. See "Facts to confirm before the run".

## When a restriction applies to a trade

A restriction has no start date and no end date columns. The engine reads its history from its `STATUS` rows instead. Each status change adds a row with a creation date.

The engine applies a restriction to a trade when both of these conditions are true:

1. The restriction has an `Active` status row that somebody created before the end of the trade date.
2. After that `Active` row and before the trade date, nobody set the restriction to `Cleared` or `Inactive`.

The engine uses the calendar day in UTC as the trade date.

The engine does not look at the `is_active` flag of the restriction rows. A restriction that somebody deleted (the app sets `is_active = false`) still applies. The scripts do the same, and they show the flag in the output so that a reviewer can decide.

## Where the data is

### SMA database (one per region)

| Table | Content |
|---|---|
| `all_securities(fsym_id, entity_id)` | The FactSet securities and their current entity. The `SECURITY_ID` of a trade is the `fsym_id`. |
| `security_info(security_id, cid)` | Custom securities that clients created, with their entity. |
| `sym_merged_entity_id(merged_factset_entity_id, to_factset_entity_id, merge_date)` | Each row says: on `merge_date`, FactSet merged the first ID into the second ID. A job copies this table from the FactSet database `factsetdb1.sym_v1.sym_merged_entity_id`. Each old ID has only one row. |

The client DBs do not hold the merge history. Only the SMA has it.

### Central database `rulesenginedb`

| Table | Content |
|---|---|
| `clients_v2` | One row per client: `id`, `environment` (AWS or AZURE), `stage`, `region`, `trade_config_version` (the active configuration), `trade_status_config` (the status names of the client). |
| `trade_configs_v2` | The configuration versions of each client. The field `parameters` holds the restriction rules under `RESTRICTION_RULE`. |

A restriction rule has these parts:

- `LIST_NAME`: one or more name patterns for restriction lists, for example `Watch%`.
- `ACTION.IN`: the status to set when the trade hits a restriction. `false` or empty means no action.
- `ACTION.NOT_IN`: the status to set when the trade does not hit a restriction.
- `ATTRIBUTE_TYPE` (optional): the rule applies only to employees with a given attribute.
- `AUTH0_CHECK_RULE` (optional): an additional check on the user account.

### Client DB (one per client)

| Table | Content |
|---|---|
| `bk_txn` | One row per trade: `transaction_id`, `trade_id`, `trade_date`, `account_number`, `pdl_account_id`, `pdl_client_code`, symbol, quantity and more. |
| `bk_txn_extra` | The typed rows of each trade (see the table in "How the engine records a restriction hit"). The type names are in `bk_txn_extra_types`. |
| `disclosures` | One row per restriction (`disc_type` points to the type `RESTRICTION` in `disclosure_types`). |
| `attribute_extra` | The fields of a restriction. Each row has a type from `attribute_extra_types`: `CID` (the entity ID), `SECURITY_ID`, `RESTRICTION_LIST_ID` and `STATUS`. |
| `restriction_lists` | The restriction lists: `restriction_list_id` and `restriction_list_name`. |
| `userdb.users` | The app users. Script `04` writes its changes as the support user, as the engine does. |

The table structure comes from the seed scripts in the repository. The production structure is not confirmed (see "Facts to confirm before the run").

## How the scripts find the affected trades

The search has four scripts. Scripts `00` and `01` run once for each region on the SMA database. Scripts `02` and `03` run once for each client. No script in this part changes data.

### Script 00: measure the merge history

Script `00_sma_chain_check.sql` reads the merge table and prints:

- The number of merged IDs, the number of surviving IDs, and the first and last merge date.
- The number of merges whose target ID was merged again later. A value above 0 means that chains with more than one step exist. The fix misses them.
- The longest chain, the number of IDs in a chain with more than one step, and the number of IDs in a loop. A loop is a data error, for example `X` merged into `Y` and `Y` merged into `X`.
- The number of securities whose current entity ID is itself an old, merged ID.
- The approximate number of rows that script `01` will write.

Use these numbers to decide if the SMA needs the follow-up change, and to estimate the size of the export.

### Script 01: export the old IDs of each security

Script `01_sma_export_security_hist_entity.sql` follows each merge chain to its end. It stops if it finds a loop. Then it joins the result with the securities. It writes the file `security_hist_entity.csv`. Each row says: "this security belongs to an entity that also had this old ID."

| Column | Meaning |
|---|---|
| `security_id` | The security. |
| `sma_entity_id` | The entity ID that the SMA returns for the security. Before the fix, the engine checked only this ID. |
| `current_entity_id` | The ID at the end of the merge chain. |
| `historical_entity_id` | An old ID of the same entity. The engine did not check this ID before the fix. |
| `merge_date` | The date when FactSet merged `historical_entity_id`. |
| `depth` | The number of merge steps from `historical_entity_id` to `current_entity_id`. A value of 0 means that the row is the current ID itself. Such a row exists only when the SMA still returns an old ID for the security. |

The file holds only FactSet data and no client data. One file serves all clients of the region.

### Script 02: export the rules of one client

Script `02_central_export_client_rules.sql` reads the configuration of one client from the central DB. It writes the file `client_rules.json` with these fields: client ID, environment, stage, region, active configuration version, status names, and restriction rules.

The script stops if the client does not exist. It also stops if the active configuration has no restriction rules, because then the client has nothing to check.

### Script 03: find the candidate trades of one client

Script `03_client_detect_candidates.sql` runs on the client DB. It loads `security_hist_entity.csv` and `client_rules.json`. It does not change data. It creates only temporary tables, which the database deletes at the end of the session.

First, the script makes sure that the rules file belongs to this client DB. It stops if no trade in the DB has the client ID of the rules file. It also ignores every trade whose `pdl_client_code` is not the client ID of the rules file. With this check, an output file can never contain the trades of another client.

Then it selects the trades that meet all of these conditions:

1. The restriction check ran for the trade. The `RULE_STATUS` text contains `RESTRICTION_CHECK_`.
2. The security of the trade is in `security_hist_entity.csv`. This means that the entity of the security has at least one old ID.
3. A restriction exists on one of the old IDs, and it applied on the trade date (see "When a restriction applies to a trade").
4. A restriction rule of the client covers the list of that restriction.
5. The original result did not already name that list in `(On ...)`. If it did, the engine found the restriction anyway, for example through the security ID.

The script prints these counts:

| Count | Meaning |
|---|---|
| `trades_with_merged_entity_security` | Trades of this client whose security has old entity IDs. |
| `trades_other_client_code` | Trades with another client code. The script ignores them. A value above 0 needs an explanation. |
| `raw_hits` | Trade and restriction pairs before the rule check. |
| `hits_no_rule_covers_list` | Pairs that no rule covers. The engine never checks these lists, so they are not missed violations. |
| `hits_already_matched` | Pairs that the engine found anyway. |
| `candidate_rows` | Pairs in the output file. |

The output file `candidates.csv` has one row for each trade, restriction and rule. One trade can have several rows. The most important columns are:

| Column | Meaning |
|---|---|
| `transaction_id`, `trade_id`, `trade_date`, `processed_at` | The trade and the time when the engine processed it. |
| `pdl_account_id`, `account_last4` | The account. The script shows only the last four digits of the account number. |
| `symbol`, `security_name`, `transaction_type`, `quantity` | What the employee traded. |
| `security_id`, `sma_entity_id`, `current_entity_id`, `historical_entity_id`, `depth`, `merge_date` | The merge chain (see script `01`). |
| `trade_before_merge` | `true` if the trade happened before the merge. Before the merge, the restricted company and the traded company were possibly different companies. |
| `disc_id`, `restriction_list_name` | The restriction that the engine missed and its list. |
| `disclosure_is_active`, `cid_attribute_is_active`, `list_attribute_is_active` | `false` if somebody deleted the restriction or one of its fields. |
| `rule_index`, `action_in`, `proposed_status` | The rule that applies and the status that it sets. The script uses the first rule that covers the list and has an action. |
| `has_attribute_filter`, `has_auth0_check` | `true` if the rule depends on employee data that the script cannot see. |
| `first_fired_rule` | The first rule that found a restriction in the original run, if any. |
| `status_would_change` | `true` if the missed restriction changes the status. This is the case when the rule has an action, no earlier rule already set the status, the user account check of the rule did not fail, and the current status is different from `proposed_status`. |
| `needs_review` | `true` if a person must look at the trade before any change. See the list below. |
| `is_winning_hit` | `true` for exactly one row of each trade. This row is the hit that the engine applies first: a hit that changes the status, then the lowest rule number, then the lowest restriction ID. |
| `current_status`, `matching_preclear_id`, `rule_status` | The current state of the trade. |

`needs_review` is `true` when one of these conditions applies:

- The rule has an attribute filter or a user account check.
- The trade matched a preclear, or its status is the match status of the client. Then the trade possibly passed because of the missed restriction (see "Known limits").
- The trade happened before the merge.
- Somebody deleted the restriction or one of its fields.

## How to correct the trades

There are three options.

### Option A: run the engine again

The engine has an API call `POST v2/process-trade?readOnly=true`. It shows what the engine decides for a trade today, without saving.

This option cannot correct trades. The engine does not insert a trade a second time. For a trade that already exists, it changes only the copy of `RULE_STATUS` in the central DB. The batch job also selects only trades that are not processed yet.

The API exists only on AWS. Azure has no such call, and adding it needs a code change. The call also uses the configuration, preclears and employee data of today, not of the trade date.

Use option A only to compare the result of script `03` with the engine, for AWS clients.

### Option B: change the status directly in the client DB

Scripts `04` and `05` do this. For each approved trade, script `04`:

1. Adds a new active `STATUS` row with the new status.
2. Adds a `COMMENT` row with the text "Status re-evaluated: restriction on a merged FactSet entity ID was not applied at processing time".
3. Sets the old `STATUS` row to inactive.
4. Writes the old and new row IDs to a backup table.

This is the same method that the compliance app uses when it changes a status (`fn_process_trade_data_direct.sql`).

The risks of this option:

- It changes the status of old trades that are possibly settled.
- It does not repeat the SIC check.
- It needs the approval of the client and a CNG ticket for each client.

### Option C: report only

The support team sends `candidates.csv` to the compliance officers of the client. The officers decide in the app what to do with each trade. Nobody changes production data.

This option needs manual work for each client. But it is the only option that handles the rules with employee filters and the preclear cases correctly, because a person decides.

### Recommendation

Use option C for all clients. Use option B only for the trades that a client approved after the review. Use option A only as a cross-check for AWS clients.

## Safety checks in the scripts

The scripts protect the data in these ways:

- Each client script works on one client DB. No query joins the data of two clients.
- Scripts `00` to `03` run in read-only transactions.
- Scripts `04` and `05` roll back all changes unless you start them with `-v apply=true`. Run each of them without this flag first. Read the output, then run it again with the flag.
- Script `04` stops if the backup table does not exist.
- Script `04` stops if an approved trade belongs to another client.
- Script `04` stops if a new status is not one of the status names of the client. A typing error in the approved file cannot write an unknown status.
- Script `04` skips a trade in these cases:
  - The status changed after the review (the current status is not the expected status).
  - The trade has more than one active `STATUS` row.
  - The trade has an active preclear link. The compliance officers handle such trades in the app.
  - Script `04` already changed the trade, and nobody rolled the change back.
- Script `04` locks the rows that it changes, so that a status change at the same time cannot create two active `STATUS` rows.
- Script `04` prints the approved and the changed counts, and lists each skipped trade with its current status.
- Script `05` skips a trade if its status changed after script `04`.

## Runbook

### Before you start

You need:

- psql version 12 or later.
- The approved SP ticket and CNG tickets (see "Tickets").
- Connection entries in `~/.pg_service.conf`, for example `sma_ro`, `central_ro`, `client_ro_<client>` and `client_rw_<client>`. Use `sslmode=verify-full` and `sslrootcert` in each entry.
- The passwords in `~/.pgpass`, with file mode `600`.

Do not write connection URLs or passwords on the command line. Other users of the machine can see the command line.

Run all commands from this folder. The scripts write to `out/<client>/`. The value of `-v out` must be a file path.

The output files contain employee trade data. Run `umask 077` first, so that only you can read the new files. Do not commit the files, and do not post them in Slack or Jira.

### Steps

1. Set the file mode for new files:

   ```zsh
   umask 077
   ```

2. On the SMA database of the region, run script `00` and read the counts:

   ```zsh
   psql "service=sma_ro" -f 00_sma_chain_check.sql
   ```

3. On the same SMA database, run script `01`. It writes `./security_hist_entity.csv`:

   ```zsh
   psql "service=sma_ro" -f 01_sma_export_security_hist_entity.sql
   ```

4. For each client, set the client ID and create the output folder. Replace `ACME` with the client ID:

   ```zsh
   C=ACME; mkdir -p out/$C
   ```

5. On the central DB, run script `02` for the client:

   ```zsh
   psql "service=central_ro" -v client_id=$C -v out=out/$C/client_rules.json -f 02_central_export_client_rules.sql
   ```

6. On the client DB, run script `03`. Run it from this folder, because it reads `security_hist_entity.csv` from here:

   ```zsh
   psql "service=client_ro_$C" -v client_rules="$(cat out/$C/client_rules.json)" \
        -v out=out/$C/candidates.csv -f 03_client_detect_candidates.sql
   ```

7. Send `out/$C/candidates.csv` to the compliance officers through the support team, on an approved secure channel.

8. If the client wants option B, the compliance officers return the file `out/$C/approved_status_changes.csv`. It has three columns: `transaction_id`, `expected_status` (the `current_status` from `03`) and `new_status` (the `proposed_status` from `03`). It must contain only rows with `is_winning_hit = true` and `status_would_change = true`.

9. A DBA creates the backup table (see "Backup table"). This is part of CNG 2.

10. On the client DB, run script `04` without `apply` and read the output. Run it from `out/$C/`, because it reads `approved_status_changes.csv` from there:

    ```zsh
    cd out/$C
    psql "service=client_rw_$C" -v client_rules="$(cat client_rules.json)" -f ../../04_client_remediate_status.sql
    ```

11. If the output is correct, run script `04` again with `apply`:

    ```zsh
    psql "service=client_rw_$C" -v client_rules="$(cat client_rules.json)" -v apply=true -f ../../04_client_remediate_status.sql
    ```

12. Ask the operations team for the cache refresh (see "Cache refresh").

### Backup table

PostgreSQL 15 and later do not let every user create tables in the schema `public`. For this reason, the schema owner or a DBA must create the backup table before script `04` runs:

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

### Access rights for scripts 04 and 05

The database role for scripts `04` and `05` needs only these rights:

- `SELECT` on `bk_txn`, `bk_txn_extra_types` and `userdb.users`.
- `SELECT`, `INSERT` and `UPDATE` on `bk_txn_extra`. Script `05` also needs `DELETE`.
- The rights on the backup table from the grant above.
- `TEMP` on the database.

### Cache refresh

The admin portal keeps a cache of personal trades. After script `04` or `05` changes data, the operations team must refresh it with this call:

```
GET <ADMIN_PORTAL_BASE_URL>/pdl/secured/config/cat/RELOAD_CACHE_EXTERNAL?cacheToUpdate=PERSONAL_TRADE
```

The call needs the `apiKey` header with the key from the admin portal API key secret. Do not paste the key into a ticket. Do not run the full preprocessing job instead. That job runs the complete trade pipeline again.

### If temporary tables are not allowed

Script `03` loads the CSV file into a temporary table. This fails in these cases:

- The role has no `TEMP` right.
- The database is a read-only replica.
- The role has `default_transaction_read_only = on`.

In these cases, change the scripts as follows:

1. In script `01`, wrap the final query in `SELECT json_agg(t) FROM (...) t`. Write the result with `\pset format unaligned` and `\pset tuples_only on` to `security_hist_entity.json`.
2. In script `03`, remove every `CREATE TEMP ...`, `\copy`, `CREATE INDEX`, `ANALYZE` and `INSERT INTO scan_hits` line.
3. Load the file with ``\set ref `cat security_hist_entity.json` ``. The backticks avoid the size limit of the shell for command arguments.
4. Write one statement. Its first CTE is `ref_sec_hist AS (SELECT * FROM jsonb_to_recordset(:'ref'::jsonb) AS r(security_id text, sma_entity_id text, current_entity_id text, historical_entity_id text, merge_date date, depth int))`. The next CTEs are the bodies of `scan_trades` and `scan_hits_v`. The final `SELECT` reads from the `scan_hits_v` CTE.

In this form, the counts query is optional. psql holds the whole file in memory, so look at the export size from script `00` first.

## Rollback

Scripts `00` to `03` save nothing, so there is nothing to roll back.

To undo script `04`, run script `05_client_rollback_status.sql` from `out/<client>/`. Run it first without `apply` and read the output. Then run it with `-v apply=true`. For each changed trade, the script:

1. Sets the old `STATUS` row to active again.
2. Deletes the `STATUS` and `COMMENT` rows that script `04` added.
3. Writes the rollback time to the backup table.

The script skips a trade if somebody changed its status after script `04`. After the rollback, ask for the cache refresh. The backup table stays until CNG 3.

## Tickets

1. SP ticket: read-only access to the SMA database in each region, to the central DB `rulesenginedb`, and to the client DBs in scope, with the `TEMP` right on the client DBs. Alternative: a DBA or SRE runs the scripts.
2. CNG 1: the read-only search in production (scripts `00` to `03`) for all regions and clients in scope.
3. Secure hand-off: the support team sends each `candidates.csv` to the compliance officers on an approved secure channel. The files contain employee trade data.
4. CNG 2, for each client that chooses option B:
   - The backup table and its grants, and the role with the minimum rights.
   - Script `04`, with the output of the dry run attached.
   - The rollback plan with script `05`.
   - The cache refresh.
5. CNG 3: drop `public.remediation_cor11327_status_backup` after the agreed retention period. Delete `out/<client>/` on every machine that ran the scripts.
6. Development follow-ups (no CNG):
   - SMA: make `all_entity_ids` follow the complete merge chain, and replace old IDs on securities. This is necessary if script `00` finds chains with more than one step or old IDs on securities.
   - Holdings: the rules engine has no restriction check for holdings. Find out if the compliance app checks them.
   - The US government check compares only the current entity ID.
   - Azure: a read-only call to run the engine again, if an exact engine result is necessary there. This needs a pull request.

## Known limits

- Preclear. The preclear match runs only while the status is `Pending Match`. If the missed restriction sets another status, it blocks the preclear match. So a trade that is `Matched` today possibly passed only because the engine missed the restriction. If the missed restriction sets `Pending Match`, a valid preclear still changes the status to `Matched`, and the result is the same. Script `03` marks all trades with a preclear link as `needs_review`. Script `04` skips them.
- SIC check. The SIC check runs after the restriction check and can overwrite its status. Script `03` does not repeat the SIC check.
- Rule order. Script `03` imitates the rule order of the engine. It finds the first rule that already found a restriction in the original run. Rules with employee filters depend on data that the script cannot see, so their rows get `needs_review`.
- Configuration. Script `03` uses the configuration of today, not the configuration on the trade date.
- Merge date. The SMA links a security only to its current entity. Before the merge, the restricted company was possibly another company. For this reason, rows with `trade_before_merge = true` need a review.
- Deleted restrictions. The scripts include deleted restrictions, as the engine does, and show the flags in the output.
- Trades that the scripts do not see:
  - Trades without `RULE_STATUS`. Older loaders, for example `fn_process_trade_data_direct` in the compliance app, and engine versions before V2 did not write it.
  - Trades that exist only in the central table `brokerdb.trade_data`. The engine did not load them into the client DB, because of an exclusion rule (inactive accounts, or accounts that cannot hold covered securities) or because they belong to a managed account while the loading of managed accounts is off. The restriction check ran for these trades, but the result is not in the client DB.
- Trades after the fix. Script `03` has no date limit. Trades that the engine processed after the fix appear only for chains with more than one step or for old IDs on securities.
- List names. Script `03` reads the list names from the `(On ...)` text. It splits the names at commas and stops at `)`. A list name that contains `,` or `)` breaks this check.
- The `is_active` flag. Script `03` treats an empty (NULL) flag as active. Scripts `04` and `05` accept only `true`. So script `04` skips a trade whose `STATUS` row has an empty flag, and lists it as skipped.
- Central copy. Script `04` does not change the copy of `RULE_STATUS` in `brokerdb.trade_data`. That copy keeps the original result.

## Known issues in the scripts

The second review found these issues. Nobody fixed them yet. Fix the first three before CNG 2.

1. Script `03` sets `is_winning_hit` for one row of each trade, also when `status_would_change` is `false`. A reviewer can approve such a row by mistake. Fix: add a column `remediable` that is `true` only if `is_winning_hit`, `status_would_change` and not `needs_review` are all true. Until then, use only rows where `is_winning_hit` and `status_would_change` are both `true` (runbook step 8).
2. Script `04` skips a trade with a preclear link only if the link row has `is_active = true`. Script `03` also counts an empty flag as active. Fix: use `p.is_active IS NOT FALSE` in the preclear check of script `04`.
3. The client check of script `04` passes when `client_rules.json` has no `client_id`. Fix: also require that `client_id` is not empty.
4. Script `03` reports `status_would_change = true` for a trade with a preclear link when the missed restriction sets `Pending Match`. In this case the preclear match still changes the status to `Matched`, so nothing changes. Script `04` skips these trades, so there is no risk to the data. Fix: set `status_would_change` to `false` in this case.
5. If an earlier rule covered the same list and fired its `NOT_IN` action, script `03` thinks that this rule already decided. Then it reports `status_would_change = false` for a later rule that actually applies. This case is rare, and the row is still in the output. Fix: ignore `NOT_IN` results when the script compares rule numbers.
6. The comment in script `01` says that `FETCH_COUNT` keeps the memory use low. psql versions before 17 possibly ignore it for queries that start with `WITH`. Fix: remove the claim, or say that it applies to psql 17 and later.
7. The role in "Access rights for scripts 04 and 05" also needs `USAGE` on the schemas `userdb` and `public`. If `extra_id` uses a sequence (`serial`), it also needs `USAGE` on that sequence.

These smaller points from the first review also stay open:

- When a check stops a script (for example "Missing -v client_rules"), psql exits with code 0. A wrapper script does not see the failure. This is not a problem for a manual run.
- Script `04` leaves `created_date` to the column default and does not set `modified_date`. The engine sets `created_date` to the trade date, and the compliance app uses the current time. It is not known if a screen sorts by `created_date`.

## Facts to confirm before the run

The scripts mark these assumptions with `-- VERIFY:`. Nobody confirmed them, because no database was available.

1. The SMA tables are in the search path of the SMA user (schema `public`). Scripts `00` and `01`.
2. With `FETCH_COUNT`, the header line appears only once in the CSV file. Check with `grep -c '^security_id,' security_hist_entity.csv`. The result must be 1. Script `01`.
3. The role for the client DB has the `TEMP` right, and the database is not a read-only replica. Script `03`.
4. For trades that the engine loaded, `pdl_client_code` is equal to the client ID. A renamed client fails the client check (see `brokerdb.client_code_history`). Scripts `03` and `04`.
5. Trades from older engine versions use the same `RULE_STATUS` text, `RESTRICTION_CHECK_n: true (On A,B)`. Script `03`.
6. Every client DB has the type `COMMENT` in `bk_txn_extra_types`. The engine uses it, but the seed scripts do not create it. Script `04`.
7. No trigger or foreign key on `bk_txn_extra` needs special handling for the insert and update of script `04` and the delete of script `05`.
8. The compliance app shows the one active `STATUS` row of a trade. Find out if the `PERSONAL_TRADE` cache refresh is enough after a direct change in the database, or if the OpenSearch sync is also necessary. Also find out if `RELOAD_CACHE_EXTERNAL` refreshes one client or all clients of the environment.
9. The tables in production have the same structure as the seed scripts (`bk_txn`, `bk_txn_extra`, `disclosures`, `attribute_extra`, `restriction_lists`).
10. The compliance app creates an action item for a restricted trade, as COR-11307 expects, or it does not. If it does, option B must also create the action item.

Two more questions are open:

- Which clients in scope run on AWS and which on Azure. Script `02` writes `environment` and `region`. The answer decides where option A is possible and which SMA database script `01` must use.
- The production deploy date of the fix in each region. It is only for the report. The search has no date limit.

## Code references

Paths without a repository name are in `compliance-rules-engine`, folder `lambdas/rules-engine-3.0/src/`.

| Topic | Location |
|---|---|
| Order of the trade checks | `serverless/public/functions/tradeProcessV2/tradeProcess.ts:89-121` |
| Restriction check, list of entity IDs after the fix | `tradeProcess.ts:326-339` |
| Rule loop, first rule with an action sets the status | `tradeProcess.ts:342-369` |
| `RULE_STATUS` text for the restriction check | `tradeProcess.ts:352`, `:359-361` |
| SIC check | `tradeProcess.ts:374-407` |
| Preclear match only while `Pending Match` | `tradeProcess.ts:569-571` |
| Trades that the engine does not load into the client DB | `tradeProcess.ts:637-689` |
| No second insert for an existing trade | `tradeProcess.ts:650-656`, `:695` |
| US government check with the current entity ID | `tradeProcess.ts:226` |
| Trade date in UTC | `tradeProcess.ts:165-167` |
| Save to `bk_txn` and `bk_txn_extra` | `serverless/public/functions/tradeProcessV2/service.ts:586-719` |
| Copy to `brokerdb.trade_data` | `service.ts:721-762` |
| Support user | `service.ts:50-62` |
| Restriction time window | `storage/repositories/clientDb/RestrictionRepository.ts:29-41` |
| Restriction query with all entity IDs | `RestrictionRepository.ts:105-123` |
| Rule matching | `rules/securityListRule.ts:10-131` |
| Active configuration version | `storage/repositories/TradeConfigRepository.ts:49-55` |
| Client and configuration tables | `storage/models/ClientStorage.ts:8-21`, `TradeConfigStorage.ts:5-11` |
| Batch job selects only unprocessed trades | `tasks/tradeProcess/queries.ts:17-20` |
| Read-only engine call on AWS | `api/handler.ts:38` |
| Cache refresh call | `libs/disclosureAppServer/AdminPortalClient.ts:14-21` |
| Seed table structure | `seed/sql/bkTxn.sql`, `seed/sql/disclosures.sql`, `seed/sql/restrictionLists.sql` |
| `all_entity_ids` with one step only | `compliance-security-master/services/securityService.ts:63-75` |
| SMA security queries | `compliance-security-master/utils/queries.ts:19-59` |
| Copy of the FactSet merge table | `compliance-security-master/queries/pg_refresh_sym_merged_entity_id.sql:8-46` |
| Status change convention of the app | `compliance-app/backend/cron-jobs/reference-data/sql/functions/CLIENTDB/fn_process_trade_data_direct.sql:322-329` |
| Fix commits | `e6645005` (development, 2026-09-22), `dbfac0e5` (Prod 2610, 2026-10-14) |
