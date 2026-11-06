-- Undo 04 on ONE client DB from the backup table. Dry run (ROLLBACK) unless -v apply=true.
-- Reactivates the old STATUS row and deletes the STATUS/COMMENT rows 04 inserted.
-- A trade is skipped when its status changed after 04 (the inserted STATUS row is no longer the only active one).
-- Usage: psql "service=client_rw_ACME" [-v apply=true] -f 05_client_rollback_status.sql
\set ON_ERROR_STOP on
\if :{?apply} \else \set apply false \endif

BEGIN;

-- VERIFY: no triggers or FKs on bk_txn_extra that block or need extra handling for the DELETE.
WITH target AS (
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
    UPDATE bk_txn_extra e
    SET is_active = true
    FROM target t
    WHERE e.extra_id = t.old_extra_id
),
removed AS (
    DELETE FROM bk_txn_extra e
    USING target t
    WHERE e.extra_id IN (t.new_status_extra_id, t.new_comment_extra_id)
)
UPDATE public.remediation_cor11327_status_backup b
SET rolled_back_at = now()
FROM target t
WHERE b.transaction_id = t.transaction_id
  AND b.rolled_back_at IS NULL;

\echo 'Rolled back in this run'
SELECT count(*) AS rolled_back FROM public.remediation_cor11327_status_backup WHERE rolled_back_at = now();

\echo 'Skipped (status changed after remediation)'
SELECT b.transaction_id, b.old_status, b.new_status,
       (SELECT string_agg(s.attribute_value, ';')
        FROM bk_txn_extra s
        WHERE s.transaction_id = b.transaction_id
          AND s.is_active
          AND s.extra_type_id = (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS')
       ) AS active_status_now
FROM public.remediation_cor11327_status_backup b
WHERE b.rolled_back_at IS NULL;

\if :apply
COMMIT;
\echo 'ROLLED BACK. Next: request the targeted PERSONAL_TRADE cache refresh (see README).'
\else
ROLLBACK;
\echo 'DRY RUN: nothing changed. Re-run with -v apply=true under the approved CNG.'
\endif
