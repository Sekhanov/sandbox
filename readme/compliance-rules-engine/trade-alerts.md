# Trade alerts

Three daily Slack messages that answer: **are trades reaching our clients?**
Paths are relative to `compliance-rules-engine/lambdas/rules-engine-3.0/src/`.
Related docs: `README.md` (index), `trade-process.md` (how trades move), `central-db-schema.md`, `client-db-schema.md`.

| # | Slack title | Question | Reads |
|---|---|---|---|
| 1 | `TradeAlertService` | Is each broker still sending trade files? | central DB |
| 2 | `PendingTradesAlert` | Which trades are not delivered yet? | central DB |
| 3 | `TradeLoadAlert` | How many trades did each client receive? | each client DB |

Key rule: in `brokerdb.trade_data`, **`processed = 'NO'` means the trade has not reached the client yet.**

---

## 1. How it runs

- `trade-alerts-job` → `tasks/tradeAlerts/tradeAlertsController.ts` runs messages 1, 2, 3 in order.
  - On Azure, message 3 is sent at the end of `trade-process-job` instead.
- Locally: `npm run dev:task trade-alerts-job`. The schedule is not in this repo.
- Slack, when `SLACK_ENABLED=true`:
  - messages go to `SLACK_CHANNEL_ID`
  - message 3 goes to its own channel, hardcoded in `tasks/tradeProcess/services/tradeAlertsService.ts`
- With Slack off: AWS sends to SNS, Azure sends nothing.
- If a query fails, the error is posted and the job stops.

---

## 2. Message 1: broker file freshness

Query: `tradeAlertsQuery` in `tasks/tradeAlerts/tradeAlertsQuery.ts`.

```sql
/*
  PURPOSE:
  For every active broker, find how fresh its trade (TRN) data is:
    - when its latest TRN file was received (file date) and processed
    - the most recent transaction date actually loaded into trade_data
    - how long ago that file was processed (used to raise "stale data" alerts)
*/

-- 1) broker_map: active brokers and their Electra ID.
--    The central "extra" table is key/value (EAV) style, so it is joined
--    several times to read different attributes of the same broker.
WITH broker_map AS (
    SELECT
        bc.bk_id,
        bc.extra_value AS broker_id,      -- Electra ID, used to match file names
        b.broker_name
    FROM public.bk_brokers_central_extra bc
    -- Keep only the rows whose type is BK_ELECTRA_ID
    JOIN public.bk_brokers_central_extra_types t
      ON bc.extra_type_id = t.extra_type_id
     AND t.extra_type = 'BK_ELECTRA_ID'
    -- Second join to the same table to read the same broker's STATUS row
    JOIN public.bk_brokers_central_extra bc_status
      ON bc_status.bk_id = bc.bk_id
    JOIN public.bk_brokers_central b
      ON b.bk_id = bc.bk_id
    WHERE bc.is_active = true
      -- bc_status must be the STATUS attribute...
      AND bc_status.extra_type_id = (
          SELECT extra_type_id
          FROM public.bk_brokers_central_extra_types
          WHERE extra_type = 'STATUS'
      )
      -- ...and its value must be 'Active' (the broker is active)
      AND bc_status.extra_value = 'Active'
      AND bc_status.is_active = true
),

-- 2) files: every uploaded trade file (name ends with TRN) of an active broker.
--    File name convention: <yyyymmdd>_<brokerId>_..._TRN
--      part 1 = file date, part 2 = broker ID (matched to broker_map)
files AS (
    SELECT
      bm.broker_id,
      bm.broker_name,
      DATE(f.processingdate) AS processing_date,                        -- when we processed the file
      f.filename,
      f.numberrecordsprocessed,                                         -- rows loaded from the file
      TO_DATE(split_part(f.filename, '_', 1), 'yyyymmdd') AS file_date  -- date parsed from the file name
    FROM brokerdb.fileuploadtracker f
    JOIN broker_map bm
      ON bm.broker_id = split_part(f.filename, '_', 2)
    WHERE f.filename LIKE '%TRN'
),

-- 3) latest: one row per broker, its most recently processed file.
--    DISTINCT ON keeps the first row per broker_id according to ORDER BY:
--    newest processing date first, ties broken by newest file date.
latest AS (
  SELECT DISTINCT ON (broker_id)
         broker_id,
         filename,
         broker_name,
         numberrecordsprocessed,
         processing_date AS most_recent_processed_date,
         file_date       AS most_recent_file_date
  FROM files
  ORDER BY broker_id, processing_date DESC, file_date DESC
),

-- Case 1: the latest file contained records.
-- Look only at trades loaded from that exact file and take the newest transaction date.
broker_data_with_records AS (
  SELECT
    l.broker_id,
    l.most_recent_file_date,
    l.most_recent_processed_date,
    MAX(DATE(td.transaction_date)) AS most_recent_txn_date
  FROM latest l
  JOIN brokerdb.trade_data td
    ON td.file_name = l.filename
  WHERE l.numberrecordsprocessed > 0
  GROUP BY l.broker_id, l.most_recent_file_date, l.most_recent_processed_date
),

-- Case 2: the latest file was empty (0 records).
-- There are no trades from that file, so fall back to the newest transaction date
-- across ALL of the broker's files (broker matched via the file name's 2nd part).
broker_data_fallback AS (
  SELECT
    l.broker_id,
    l.most_recent_file_date,
    l.most_recent_processed_date,
    MAX(DATE(td.transaction_date)) AS most_recent_txn_date
  FROM latest l
  JOIN brokerdb.trade_data td
    ON split_part(td.file_name, '_', 2) = l.broker_id
  WHERE l.numberrecordsprocessed = 0
  GROUP BY l.broker_id, l.most_recent_file_date, l.most_recent_processed_date
)

-- Final result: combine both cases (they are mutually exclusive per broker,
-- so UNION ALL is safe) and calculate the alert metrics.
SELECT
  broker_id,
  most_recent_file_date,
  most_recent_processed_date,
  most_recent_txn_date,
  -- Processing lag: days between the file's date and when it was processed
  (most_recent_processed_date - DATE(most_recent_file_date)) AS days_since_file_received_and_processed,
  -- Staleness: days since the broker's last successful processing until today
  (CURRENT_DATE - DATE(most_recent_processed_date)) AS days_since_last_processed
FROM (
  SELECT * FROM broker_data_with_records
  UNION ALL
  SELECT * FROM broker_data_fallback
) t
-- There is one row per broker, so in practice the result is sorted by broker_id
ORDER BY broker_id, days_since_last_processed, days_since_file_received_and_processed DESC;
```

| Slack column | Field | ❌ when |
|---|---|---|
| Broker | `broker_id` | |
| File Date | `most_recent_file_date` | |
| Processed | `most_recent_processed_date` | |
| Last Txn | `most_recent_txn_date` | |
| Recd & Proc | `days_since_file_received_and_processed` | > 3 |
| Last Proc | `days_since_last_processed` | > 2 |

Note: a broker with no `TRN` file at all is not in the result, so its absence is not flagged.

---

## 3. Message 2: trades not delivered yet

Query: `pendingTradesQuery` in `tasks/tradeAlerts/tradeAlertsQuery.ts`. It runs once per client of the current stage.

```sql
/*
  PURPOSE:
  For one client, count trades that have not reached the client yet,
  plus recent ACEX / RNR trades and rows with missing dates.

  Placeholders, filled per client:
    ${tradeStatus}     the client's "ready" condition, from tasks_config.tradeProcess.tradeStatus
                       (default when tradeProcess is missing: status = 'TRADE')
    ${dateCondition}   AND DATE(transaction_date) >= '<tasks_config.tradeProcess.transactionDate>'
                       (empty when transactionDate is not set)
    ${stuckSinceDays}  STUCK_TRADE_DAYS env var, default 2
*/
SELECT LOWER(pdl_client_code) AS client_code,

       -- Staged: ready, not delivered yet
       COUNT(CASE WHEN processed != 'YES' AND ${tradeStatus} ${dateCondition} THEN 1 END) AS trade_status_count,

       -- Stuck: Staged, and created before midnight N days ago
       COUNT(CASE WHEN processed != 'YES' AND ${tradeStatus} ${dateCondition}
                   AND create_date < (CURRENT_DATE - INTERVAL '${stuckSinceDays} day') THEN 1 END) AS stuck_trade_count,

       -- Pending: not matched to a security yet (includes trades waiting on an exception)
       COUNT(CASE WHEN processed != 'YES' AND status = 'PENDING' ${dateCondition} THEN 1 END) AS pending_status_count,

       -- ACEX (unknown account) / RNR (not a real trade): created in the last 24h, processed or not
       COUNT(CASE WHEN status LIKE '%ACEX%' AND create_date >= NOW() - INTERVAL '1 day' THEN 1 END) AS acex_count,
       COUNT(CASE WHEN status LIKE '%RNR%'  AND create_date >= NOW() - INTERVAL '1 day' THEN 1 END) AS rnr_count,

       -- Bad data: missing dates, any row of the client, processed or not
       COUNT(CASE WHEN transaction_date IS NULL THEN 1 END) AS null_txn_date_count,
       COUNT(CASE WHEN create_date IS NULL THEN 1 END) AS null_create_date_count

FROM brokerdb.trade_data
WHERE LOWER(pdl_client_code) = LOWER(:clientId)
  -- Read only rows that at least one counter above can use
  AND (
    (processed != 'YES' AND (${tradeStatus} OR status = 'PENDING') ${dateCondition})
    OR
    ((status LIKE '%ACEX%' OR status LIKE '%RNR%') AND create_date >= NOW() - INTERVAL '1 day')
    OR (transaction_date IS NULL OR create_date IS NULL)
  )
-- One row per client. A client with no matching rows is missing from the table.
GROUP BY LOWER(pdl_client_code);
```

Plus one query for the header, across all clients (`unrecognizedStatusCountQuery`):

```sql
-- Unprocessed trades with a status preprocess does not know.
-- fn_process_trades sets this outcome when status is none of
-- PENDING, DUP, ACEX, INACTIVE_ACCOUNT, TRADE, INACTIVE_CLIENT, 'RNR | …'
SELECT COUNT(*) AS unrecognized_status_count
FROM brokerdb.trade_data
WHERE processed = 'NO'
  AND process_outcome = 'FAIL: Unrecognized status';
```

| Slack column | Field | 🚨 when |
|---|---|---|
| Client | `client_code` | |
| Staged | `trade_status_count` | |
| Pending | `pending_status_count` | |
| Stuck | `stuck_trade_count` | > 10 |
| ACEX | `acex_count` | |
| RNR | `rnr_count` | |
| NullTxn | `null_txn_date_count` | > 0 |
| NullCrt | `null_create_date_count` | > 0 |

The header shows the sum of each column, plus `Unrecognized status`.

---

## 4. Message 3: trades delivered to each client

Queries: `tasks/tradeProcess/tradeAlertsQueries.ts`.
- Run in each client DB, for clients of the current cloud (and region, on Azure).
- A client whose DB fails shows ⚠️.

```sql
-- 1) Trades delivered yesterday, in the last 7 days, and today
SELECT
    COUNT(*) FILTER (WHERE DATE(processed_date) = (NOW() - INTERVAL '1 day')::date) AS since_yesterday,
    COUNT(*) FILTER (WHERE processed_date >= NOW() - INTERVAL '7 day') AS since_last_week,
    COUNT(*) FILTER (WHERE DATE(processed_date) = CURRENT_DATE) AS loaded_today
FROM public.bk_txn;

-- 2) RNR trades delivered in the last 24h.
--    The security id is an EAV attribute (SECURITY_ID) in bk_txn_extra;
--    RNR trades have a security id starting with 'RNR_'.
SELECT COUNT(*) AS rnr_count
FROM public.bk_txn bt
    INNER JOIN public.bk_txn_extra bte
    ON bt.transaction_id = bte.transaction_id
        AND bte.is_active = true          -- current value only
        AND bte.extra_type_id = (
            SELECT extra_type_id FROM public.bk_txn_extra_types
            WHERE attribute_type = 'SECURITY_ID'
        )
WHERE bte.attribute_value LIKE 'RNR_%'
AND bt.processed_date >= NOW() - INTERVAL '1 day';

-- 3) Normal volume: average for today's weekday over the last 3 weeks (today excluded)
WITH daily AS (
    SELECT DATE(processed_date) AS load_day, COUNT(*) AS cnt
    FROM public.bk_txn
    WHERE DATE(processed_date) >= CURRENT_DATE - INTERVAL '3 weeks'
      AND DATE(processed_date) < CURRENT_DATE
      AND EXTRACT(DOW FROM processed_date) = EXTRACT(DOW FROM CURRENT_DATE)  -- same weekday
    GROUP BY DATE(processed_date)
)
-- Always divided by 3, so a weekday with no trades counts as 0
SELECT COALESCE(ROUND(SUM(cnt) / 3.0), 0) AS avg_for_weekday FROM daily;
```

| Slack column | Field |
|---|---|
| Client / Env | client id; `AWS` or `AZURE` |
| Active | `tasks_config.tradeProcess.enabled` |
| Today (Azure) / Yest (AWS) | `loaded_today` / `since_yesterday` |
| Avg Day | `avg_for_weekday` |
| Week | `since_last_week` |
| RNR | `rnr_count` |

Today/Yest far below Avg Day means trades stopped reaching this client.

---

## 5. Known gaps (COR-11552)

- Stuck counts only the "ready" status. Trades stuck as `PENDING`, ACEX, unrecognized status, etc. are not counted as stuck.
- Pending mixes new trades with trades waiting on an exception.
- ACEX / RNR count the last 24h; the other columns count current totals.
- NullTxn / NullCrt include processed rows.
- RNR trades (when `tradeStatus` is only `TRADE`) and trades before `transactionDate` are never processed, so they stay `processed = 'NO'` forever. See `trade-process.md`, section 7.
- Message 2 always has a red bar, even when everything is fine.
