# COR-11327: trades approved despite a restriction on a merged FactSet ID

**Problem.** The client restricts company ACME, ID `A1`. FactSet later changes ACME's ID to `B2`. Before the fix (COR-11307, Prod 2610, 2026-10-14), the engine checked only `B2`, missed the restriction on `A1`, and approved ACME trades. These scripts find such trades and correct them.

Status: draft, not run on production yet.

## Scripts

Run them in this order, once per client. Each script uses the files made by the scripts before it.

| Step | Database | Question it answers | Uses | Makes |
|---|---|---|---|---|
| `00` | SMA | Did any company change its ID more than once (`A1` → `B2` → `C3`)? Must be 0: only one change is handled. | — | count on screen |
| `01` | Client | Which companies did the client ever restrict (including edited and deleted restrictions)? | — | `restricted_cids.json` |
| `02` | SMA | Which of them changed their ID, and which shares carry the other ID? | `restricted_cids.json` | `security_hist_entity.json` |
| `03` | Central | Which rules does the client use (lists that block a trade, status they set)? | `--client` | `client_rules.json` |
| `04` | Client | Which trades in those shares were approved by mistake before the fix? Shows the correct status, and `remediable` (safe to fix) or `review_reason` (a person decides). Changes nothing. | files from `02`, `03`, `--fix-date` | `candidates.json` |
| `05` | Client | Fix: set the correct status on every `remediable` trade from `04`. Saves the old status. | `candidates.json` | result on screen |
| `06` | Client | Undo `05`. | backup from `05` | result on screen |

`05` and `06` change nothing unless you add `--commit`.

## Run

```zsh
cd app && npm ci && cp .env.example .env   # fill in RDS_* (SMA), DB_* (central), CLIENT_DB_* (client)
umask 077                                   # output files hold employee trade data

npm run 00
npm run 01
npm run 02
npm run 03 -- --client ACME
npm run 04 -- --fix-date 2026-10-14         # date the fix was deployed in the region
```

Files go to `out/` (`--dir <folder>` to change). Each result is also saved as CSV in `out/steps/`.

**Fix (under a CNG):**

1. A DBA creates the backup table (below).
2. `npm run 05` (dry run, check `applied`), then `npm run 05 -- --commit`.
3. Ask operations for the `PERSONAL_TRADE` cache refresh.

Undo: `npm run 06`, then `npm run 06 -- --commit`, then the cache refresh.

```sql
CREATE TABLE public.missed_restriction_status_backup (
    transaction_id text NOT NULL, old_extra_id int NOT NULL, old_status text, new_status text NOT NULL,
    new_status_extra_id int NOT NULL, new_comment_extra_id int NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(), rolled_back_at timestamptz
);
```

## How `04` decides

A trade is listed when all of these hold:
1. Its security is in `security_hist_entity.json` (from `02`).
2. The engine ran the restriction check (`RULE_STATUS` contains `RESTRICTION_CHECK_`) before `--fix-date`.
3. A restriction has the CID the engine missed (`restricted_cid`), live or deleted.
4. The engine could not find that restriction: when the trade was processed, the restriction had no CID row equal to `security_cid` and no `SECURITY_ID` row equal to the trade's security. (After a merge the app may add the new CID; then the engine found it.)
5. The restriction was active on the trade date: an `Active` status row by the end of that day, no `Cleared`/`Inactive` before it.
6. Its list matches a client rule (`LIST_NAME`, `LIKE`), and that rule would have changed the result:
   - an `IN` rule at or before the first rule that fired, or
   - a `NOT_IN` rule (allow-list) that fired because the restriction was missed.
   - Rules skipped for the employee (`AUTH0_FALSE`) are ignored.

Per trade, only the first such rule counts (the engine stops at the first rule with an action). Its `IN` status is `proposed_status`.

`remediable = true` when `proposed_status` is set, differs from `current_status`, and there is no `review_reason`:

| `review_reason` | Why `04` cannot be sure |
|---|---|
| `employee_filter` | The rule has `ATTRIBUTE_TYPE` or `AUTH0_CHECK_RULE`. |
| `preclear_linked` | The trade is linked to a preclear or is `Matched`. |
| `status_changed_by_user` | More than one `STATUS` row: someone changed it after processing. |
| `pending_match_action` | The rule sets Pending Match; preclear matching would decide the final status. |
| `sic_rules` | The client has SIC rules, which can overwrite the status. |
| `not_in_rule` | An allow-list rule fired wrongly; the correct status is unknown. |
| `deleted_restriction` | The restriction was deleted; its end date is unknown. |
| `trade_before_merge` | Trade before the CID change: the engine checked the old CID, not `security_cid`. |

## Known limits

- `04` uses today's rules: there is no history of which rule version was active when.
- Deleted restrictions have no deletion date, so their trades always go to review.

## Why `migdb` is read

A restriction deleted in the app can still have been active on the trade date, so its trades are affected.
- Before release AWS2609, a delete removed the restriction from `disclosures` / `attribute_extra`. The only copy is in `migdb.deleted_disclosures` / `migdb.deleted_attribute_extra`.
- Since AWS2609 (COR-11301), a delete copies to `migdb` and sets `is_active = false`, so the restriction is in both places. `04` counts it once and marks it deleted.
