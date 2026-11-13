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
    SELECT backup.transaction_id, backup.old_extra_id, backup.old_comment_extra_ids,
           backup.new_status_extra_id, backup.new_comment_extra_id
    FROM public.missed_restriction_status_backup backup
    JOIN bk_txn_extra new_status ON new_status.extra_id = backup.new_status_extra_id AND new_status.is_active
    JOIN bk_txn_extra new_comment ON new_comment.extra_id = backup.new_comment_extra_id AND new_comment.is_active
    WHERE backup.rolled_back_at IS NULL),
reactivated AS ( -- old status and comments back
    UPDATE bk_txn_extra extra SET is_active = true
    FROM target
    WHERE extra.extra_id = target.old_extra_id OR extra.extra_id = ANY (target.old_comment_extra_ids)),
removed AS ( -- rows added by 05
    DELETE FROM bk_txn_extra extra USING target
    WHERE extra.extra_id IN (target.new_status_extra_id, target.new_comment_extra_id))
UPDATE public.missed_restriction_status_backup backup
SET rolled_back_at = now()
FROM target
WHERE backup.transaction_id = target.transaction_id AND backup.rolled_back_at IS NULL;

-- Result: every changed trade, whether it was rolled back now, and its status now.
SELECT backup.transaction_id, backup.old_status, backup.new_status,
       backup.rolled_back_at IS NOT NULL AS rolled_back,
       (SELECT string_agg(status.attribute_value, ';')
        FROM bk_txn_extra status JOIN bk_txn_extra_types status_type USING (extra_type_id)
        WHERE status.transaction_id = backup.transaction_id AND status.is_active IS NOT FALSE
          AND status_type.attribute_type = 'STATUS') AS status_now
FROM public.missed_restriction_status_backup backup
WHERE backup.rolled_back_at IS NULL OR backup.rolled_back_at = now();

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
