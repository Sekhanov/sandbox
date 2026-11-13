-- Client DB. Undoes 05 from the backup table: old STATUS and COMMENT rows active again, rows added by 05 deleted.
-- Skips trades whose status or comment changed after 05. Dry run unless --commit.
-- Result columns:
--   transaction_id - the trade
--   old_status     - status before 05
--   new_status     - status set by 05
--   rolled_back    - true: undone now; false: skipped (status or comment changed after 05)
--   status_now     - status after this run
BEGIN;

WITH target AS ( -- rows added by 05 still active (a later change makes them inactive)
    SELECT b.transaction_id, b.old_extra_id, b.old_comment_extra_ids, b.new_status_extra_id, b.new_comment_extra_id
    FROM public.missed_restriction_status_backup b
    JOIN bk_txn_extra ns ON ns.extra_id = b.new_status_extra_id AND ns.is_active
    JOIN bk_txn_extra nc ON nc.extra_id = b.new_comment_extra_id AND nc.is_active
    WHERE b.rolled_back_at IS NULL),
reactivated AS ( -- old status and comments back
    UPDATE bk_txn_extra e SET is_active = true
    FROM target t
    WHERE e.extra_id = t.old_extra_id OR e.extra_id = ANY (t.old_comment_extra_ids)),
removed AS ( -- rows added by 05
    DELETE FROM bk_txn_extra e USING target t
    WHERE e.extra_id IN (t.new_status_extra_id, t.new_comment_extra_id))
UPDATE public.missed_restriction_status_backup b
SET rolled_back_at = now()
FROM target t
WHERE b.transaction_id = t.transaction_id AND b.rolled_back_at IS NULL;

-- Result: every changed trade, whether it was rolled back now, and its status now.
SELECT b.transaction_id, b.old_status, b.new_status,
       b.rolled_back_at IS NOT NULL AS rolled_back,
       (SELECT string_agg(e.attribute_value, ';')
        FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
        WHERE e.transaction_id = b.transaction_id AND e.is_active IS NOT FALSE AND t.attribute_type = 'STATUS') AS status_now
FROM public.missed_restriction_status_backup b
WHERE b.rolled_back_at IS NULL OR b.rolled_back_at = now();

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
