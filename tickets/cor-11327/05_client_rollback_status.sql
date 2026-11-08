-- Undoes script 04 on ONE client DB, using the backup table.
-- The script ends with ROLLBACK (dry run). Replace ROLLBACK with COMMIT only under the approved CNG.

BEGIN;

-- Step 1. Undo the changes.
WITH target AS (
    -- Changed trades that nobody rolled back yet. A trade is skipped when its status changed after script 04
    -- (the row from script 04 is no longer the only active status, or its value is different).
    SELECT b.transaction_id, b.old_extra_id, b.new_status_extra_id, b.new_comment_extra_id
    FROM public.remediation_cor11327_status_backup b
    JOIN bk_txn_extra ns
      ON ns.extra_id = b.new_status_extra_id
     AND ns.is_active
     AND ns.attribute_value = b.new_status
    WHERE b.rolled_back_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM bk_txn_extra o
          WHERE o.transaction_id = b.transaction_id
            AND o.extra_type_id = ns.extra_type_id
            AND o.is_active
            AND o.extra_id <> ns.extra_id)
),
reactivated AS (
    -- Make the old STATUS row active again.
    UPDATE bk_txn_extra e
    SET is_active = true
    FROM target t
    WHERE e.extra_id = t.old_extra_id
),
removed AS (
    -- Delete the STATUS and COMMENT rows that script 04 added.
    DELETE FROM bk_txn_extra e
    USING target t
    WHERE e.extra_id IN (t.new_status_extra_id, t.new_comment_extra_id)
)
-- Mark the trades as rolled back in the backup table.
UPDATE public.remediation_cor11327_status_backup b
SET rolled_back_at = now()
FROM target t
WHERE b.transaction_id = t.transaction_id
  AND b.rolled_back_at IS NULL;

-- Step 2. Result: trades rolled back in this transaction.
SELECT count(*) AS rolled_back FROM public.remediation_cor11327_status_backup WHERE rolled_back_at = now();

-- Step 3. Skipped trades (status changed after script 04) with their status today.
SELECT b.transaction_id, b.old_status, b.new_status,
       (SELECT string_agg(s.attribute_value, ';')
        FROM bk_txn_extra s
        WHERE s.transaction_id = b.transaction_id
          AND s.is_active
          AND s.extra_type_id = (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS')
       ) AS active_status_now
FROM public.remediation_cor11327_status_backup b
WHERE b.rolled_back_at IS NULL;

-- Step 4. Dry run: undo everything. Under the approved CNG, replace with COMMIT,
--         then ask for the PERSONAL_TRADE cache refresh (see README).
ROLLBACK;
