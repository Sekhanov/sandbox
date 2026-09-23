# COR-11552: unresolved PR comments

- PR: [#141807](https://dev.azure.com/intappdevops/Compliance/_git/compliance-rules-engine/pullrequest/141807) (`cor-11552` → `dev`)
- Reviewer: Dmitrii Shulaikin
- State as of 2026-10-21. Paths are relative to `lambdas/rules-engine-3.0/src`.

## Decide first

1370557 (close exceptions or not) affects 1370568 and 1372434.

## Threads

| Thread | File | Status |
|---|---|---|
| 1370557 | `tasks/tradeProcess/services/tradeProcessService.ts:74` | Fixed locally (closing removed), not committed, no reply yet |
| 1370568 | `tasks/tradeProcess/services/tradeProcessService.ts:22` | Not needed: code removed by 1370557, no reply yet |
| 1372151 | `libs/globalConstants.ts:186` | Fixed locally, not committed, no reply yet |
| 1372212 | `tasks/tradeProcess/queries.ts:30` | Open |
| 1372329 | `tasks/tradeProcess/tradeProcessController.ts:31` | Fixed locally, not committed, no reply yet |
| 1372367 | `seed/central/data/trades.ts:1380` | Fixed locally, not committed, no reply yet |
| 1372369 | `seed/central/data/trades.ts:1384` | Fixed locally, not committed, no reply yet |
| 1372434 | `tests/integration/helpers/localDbHelper.ts:50` | Fixed locally, not committed, no reply yet |

### 1376071: make Stuck the default case

> Can we make stuck default case? So if trade does not count towards any of the other categories it will be considered stuck?

- `tasks/tradeAlerts/tradeAlertsQuery.ts:123`. The `CASE` has no `ELSE`. A fresh trade with a status not in the list (NULL or any other value) gets `category = NULL` and is in no column.
- **Proposal:** agree. Add `ELSE 'STUCK'`. Keep `WHEN is_old THEN 'STUCK'` before `PENDING`/`PREPROCESSED`, so old pending trades stay Stuck.
- Check the seeded `pdl3` counts in `tradeAlerts.azure.test.ts` after the change.

**Fixed locally:** `ELSE 'STUCK'` added. Seeded counts unchanged; no new seed trade. Not committed, no reply yet.

Suggested reply:

> Agreed, added `ELSE 'STUCK'`: a trade that matches no other category now counts as Stuck.

### Artem Shipitsyn: SELECT + RETURNING instead of UPDATE type

> Minor: a bit unusual to use SELECT and RETURNING, instead of using Update type

- `tasks/tradeProcess/services/tradeProcessService.ts:56`. Only the count is used; `QueryTypes.UPDATE` returns `[undefined, rowCount]` on Postgres.

**Fixed locally:** removed `RETURNING trade_id`, uses `QueryTypes.UPDATE` and returns the affected row count; unit test updated. Not committed, no reply yet.

Suggested reply:

> Agreed, switched to `QueryTypes.UPDATE` and use the affected row count; removed `RETURNING`.

### 1370557: why close exceptions?

> Why do we need to close exceptions? It may be a good change, but seems unrelated for this ticket...

- Why the code closes them: when a trade is marked `processed = 'YES'`, its open exception stays open in the Exceptions UI forever. Nothing processes that trade again.
- This PR does not make that worse. Before the PR, these trades already stayed unprocessed forever, and their exceptions stayed open. The alert skips processed trades, so these exceptions do not affect the metrics.
- **Proposal:** agree. Remove the closing from this PR and create a follow-up ticket. This removes:
  - `ExceptionsRepository.findOpenTradeExceptionIds`
  - the `transaction` parameter in `bulkUpdateExceptionStatus`
  - the chunking and the transaction in `markUnfetchedTradesProcessed`
  - the closed-exception test in `tradeProcess.azure.test.ts`
  - the seeded `Open` exception on `unfetchedTrades.beforeCutoffDate`

**Fixed locally:** all of the above removed; `ExceptionsRepository.ts` and `localDbHelper.ts` are now identical to `dev`. Not committed, no reply yet. Follow-up ticket for closing exceptions: not created yet.

Suggested reply:

> Agreed, it is out of scope here: the alert ignores processed trades, so these exceptions do not affect the metrics. Removed it from this PR; I'll create a separate ticket for closing exceptions of trades marked as processed without loading.

Suggested reply for 1370568:

> Not needed anymore: the exception closing was removed (see the other thread).

### 1370568: use the `ExceptionStatus` enum

> If we decide to keep it, can we use enum `ExceptionStatus` from `services/ExceptionResolvingService.ts`

- If 1370557 removes the closing, this is not needed. Reply that the code was removed.
- If we keep the closing, use `[ExceptionStatus.New, ExceptionStatus.Reviewed, ExceptionStatus.AwaitingMatch, ExceptionStatus.Failed]`. The enum has no `Open` value, so add `Open: 'Open'`.
- The alert query (`tasks/tradeAlerts/tradeAlertsQuery.ts`) has the same list written in SQL. Leave it as plain SQL.

### 1372151: shouldn't min be 1?

> Shouldn't min be 1?

- **Proposal:** agree. `0` means "older than now", so every unprocessed trade or open exception would count as stuck.
- Change `.min(0)` to `.min(1)` in `daysSchema`. Because of `.catch`, `0` then falls back to the default (2 or 7 days).

**Fixed locally:** `.min(1)` in `daysSchema`. Not committed, no reply yet.

Suggested reply:

> Agreed, changed to `min(1)`. A value below 1 now falls back to the default (2 days for trades, 7 days for exceptions).

### 1372212: replace `tradeStatus` with a `LOAD_RNR_TRANSACTIONS` flag

> I want to get rid of tradeStatus. I think adding chunks of SQL in DB is ugly design. [...] I think we can add rule in trade config `LOAD_RNR_TRANSACTIONS` [...] This will require migration to set `LOAD_RNR_TRANSACTIONS` flag for some clients though

- I agree with the design: SQL fragments stored in the database are fragile.
- But the change touches `FETCH_TRADE_RECORDS` for every client and needs a migration for clients like MRCM. That is too risky for a PR about alert metrics.
- **Proposal:** reply that we agree and create a separate ticket. Keep `tradeStatus` in this PR.

### 1372329: move the marking after `handleTradesAWS`/`handleTradesAzure`

> I don't think it matters, but can we move this towards the end (after handleTradesAWS/handleTradesAzure)?

- **Proposal:** agree. The marked trades and the fetched trades never overlap:
  - the marking skips RNR trades that the client loads;
  - fetching skips trades before the cutoff date.
- Catch: if fetching fails, the loop skips the rest with `continue`. Make sure the marking is not skipped too.

**Fixed locally:** the marking now runs after `handleTradesAWS`/`handleTradesAzure`. Not committed, no reply yet. If fetching fails, the marking is skipped for that client in that run (accepted: it runs again on the next run). Unit tests updated (`tradeProcessController.test.ts`).

Suggested reply:

> Moved it after the trade handling.

### 1372367: don't be afraid of id change

> We shouldn't be afraid of id change.

- **Proposal:** agree. Remove the `// Keep last: ...` comment and keep the current order.

**Fixed locally:** comment removed. Not committed, no reply yet.

Suggested reply:

> Agreed, removed the comment.

### 1372369: move exceptions to a separate file

> Let's move exceptions to separate file

- **Proposal:** agree. Move `pendingAlertExceptions` to a new `seed/central/data/tradeExceptions.ts`.
- Export `daysAgo` from `trades.ts` so the new file can use it.
- Update the import in `seed/central/data/index.ts`.

**Fixed locally:** `pendingAlertExceptions` moved to `seed/central/data/tradeExceptions.ts`; `daysAgo` exported from `trades.ts`; `index.ts` import updated. Not committed, no reply yet.

Suggested reply:

> Done, moved the exception seeds to `seed/central/data/tradeExceptions.ts`.

### 1372434: why `insertTradeExceptionInCentral` if the seed has exceptions?

> Why do we need this function if we already create exceptions in the seed data?

**Fixed locally:** not committed and no reply yet. Type-check and ESLint pass. The integration tests have not been run.

- `localDbHelper.ts`: removed `insertTradeExceptionInCentral`. Kept `findActiveTradeExceptionAttribute`.
- `tradeAlerts.azure.test.ts`: removed the inserted `99000xx` trades and the before/after comparison. The test now checks the exact counts on the seeded `pdl3` row.
- `seed/central/data/trades.ts`: added an `Open` exception on `unfetchedTrades.beforeCutoffDate` to `pendingAlertExceptions`.
- `tradeProcess.azure.test.ts`: removed the manual exception insert.
- CI follow-up (run 1072020): preprocessing sets `ACEX` on the seeded `pdl3` trades (no known account), so 5 counts failed. The `pdl3` test now reseeds (`setupLocalDatabase`) and runs only `pendingTradesAlert`, without preprocessing.

Suggested reply:

> Agreed, removed `insertTradeExceptionInCentral`. The pending trades alert test now asserts the seeded `pdl3` trades and exceptions directly, and the open exception for the trade before the cutoff date is part of the seed data.

## Already resolved

- 1370531 (`ExceptionsRepository.ts:134`, "Do we need this comment?"): `// language=PostgreSQL` removed in `74f293f6`.
- CodeRabbit 1368101 (timezone of `created_date`): answered and closed as won't fix. The `EXCEPTION_TYPE` row gets its `created_date` from the column default `CURRENT_TIMESTAMP AT TIME ZONE 'EST'`, and the query cutoff uses the same expression.
