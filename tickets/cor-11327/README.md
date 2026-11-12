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
| `05` | Client | Fix: set the correct status on every `remediable` trade from `04`. Saves the old status. | `candidates.json`, `client_rules.json` | result on screen |
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
CREATE TABLE public.remediation_cor11327_status_backup (
    transaction_id text NOT NULL, old_extra_id int NOT NULL, old_status text, new_status text NOT NULL,
    new_status_extra_id int NOT NULL, new_comment_extra_id int NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(), rolled_back_at timestamptz
);
```

## Known limits

- Chains of ID changes are not covered (step `00`).
- `04` uses today's rules: there is no history of which rule version was active when.
- Deleted restrictions have no deletion date, so their trades always go to review.
