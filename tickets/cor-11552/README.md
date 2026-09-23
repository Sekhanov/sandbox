# COR-11552: Trade alerts and stuck trades

Ticket: https://intapp.atlassian.net/browse/COR-11552
Branch: `cor-11552` in `compliance-rules-engine`. Paths below are relative to `lambdas/rules-engine-3.0/src/`.

## Pending trades alert (AC 1, AC 3)

Files: `tasks/tradeAlerts/tradeAlertsQuery.ts` (`pendingTradesQuery`), `tasks/tradeAlerts/services/tradeAlertsService.ts` (`pendingTradesAlert`).

The alert runs one query for all clients of the current stage (`clients_v2.stage = NODE_ENV`). The old alert used the same client scope.
The query counts only trades with `processed != 'YES'`.

| Column | Counts |
|---|---|
| Pending | Status `PENDING`, no open exception, created less than `STUCK_TRADE_DAYS` ago |
| Exceptions | Open trade exception, created less than `STUCK_EXCEPTION_DAYS` ago |
| StuckExc | Open trade exception, created `STUCK_EXCEPTION_DAYS` or more ago. Flagged when more than 0 |
| ACEX | Status `ACEX`, no open exception (current total, not last 24 hours) |
| Inactive | Status `INACTIVE_ACCOUNT`, no open exception |
| Preproc | Status `TRADE` or `RNR%`, no open exception, created less than `STUCK_TRADE_DAYS` ago |
| Stuck | Created `STUCK_TRADE_DAYS` or more ago, or no `create_date`. Not ACEX, not INACTIVE_ACCOUNT, no open exception. Flagged when more than 10 |

An open exception is an active trade exception (`EXCEPTION_TYPE = 'TRADE'`) with the status New, Open, Reviewed, Awaiting Match or Failed.
The age of an exception is the creation time of its first `bk_txn_extra` row, not the date of the trade.
The old columns Staged, RNR, NullTxn and NullCrt are removed. Trades with a missing date now count as Stuck.

## Processed flag (AC 2)

Files: `tasks/tradeProcess/queries.ts` (`buildMarkUnfetchedTradesProcessedQuery`), `tasks/tradeProcess/services/tradeProcessService.ts` (`markUnfetchedTradesProcessed`), `tasks/tradeProcess/tradeProcessController.ts`, `storage/repositories/ExceptionsRepository.ts`.

For each client, `processTrades` runs this step before it fetches the trades. The step sets `processed = 'YES'` and `processed_date = NOW()`. The `loaded` column stays `false`.

| Rule | Condition |
|---|---|
| RNR | `status LIKE 'RNR%'` and the client `tradeStatus` does not fetch it. Clients that load RNR (for example MRCM) are not affected |
| Cutoff date | `DATE(transaction_date) < transactionDate` of the client, any status |

In the same transaction, the step closes the open trade exceptions of the marked trades, with the comment "Closed: trade is marked as processed without loading (RNR or outside the configured transaction date range)". It works in chunks of 500.
If the step fails, the job sends the alert `ERROR: TRADE PROCESS V2 | <client>`. The fetch and the processing of that client continue.

Trades with a missing `transaction_date` are not marked. They show as Stuck.

## Configuration

| Env var | Default | Used by |
|---|---|---|
| `STUCK_TRADE_DAYS` | 2 | Existing. Pending, Preproc, Stuck |
| `STUCK_EXCEPTION_DAYS` | 7 | New. Exceptions, StuckExc. Must be added to the job configuration, which is not in this repo |

