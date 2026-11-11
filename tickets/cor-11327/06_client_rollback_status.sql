-- Client DB. Undoes script 05 from the backup table. Skips a trade whose status changed after script 05.
BEGIN;

WITH target AS (
    SELECT b.transaction_id, b.old_extra_id, b.new_status_extra_id, b.new_comment_extra_id
    FROM public.remediation_cor11327_status_backup b
    JOIN bk_txn_extra ns ON ns.extra_id = b.new_status_extra_id AND ns.is_active AND ns.attribute_value = b.new_status
    WHERE b.rolled_back_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM bk_txn_extra o
                      WHERE o.transaction_id = b.transaction_id AND o.extra_type_id = ns.extra_type_id
                        AND o.is_active AND o.extra_id <> ns.extra_id)
),
reactivated AS (UPDATE bk_txn_extra e SET is_active = true FROM target t WHERE e.extra_id = t.old_extra_id),
removed AS (DELETE FROM bk_txn_extra e USING target t WHERE e.extra_id IN (t.new_status_extra_id, t.new_comment_extra_id))
UPDATE public.remediation_cor11327_status_backup b SET rolled_back_at = now()
FROM target t
WHERE b.transaction_id = t.transaction_id AND b.rolled_back_at IS NULL;

-- Result: every changed trade, whether it was rolled back now, and its status now.
SELECT b.transaction_id, b.old_status, b.new_status, b.rolled_back_at IS NOT NULL AS rolled_back,
       (SELECT string_agg(e.attribute_value, ';') FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
        WHERE e.transaction_id = b.transaction_id AND e.is_active AND t.attribute_type = 'STATUS') AS status_now
FROM public.remediation_cor11327_status_backup b
WHERE b.rolled_back_at IS NULL OR b.rolled_back_at = now();

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
