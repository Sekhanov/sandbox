-- Client DB. Input: candidates.json (04). Fixes the rows with remediable = true.
-- Sets the new status as the engine's status change does (ExceptionsRepository.bulkUpdateExceptionStatus):
-- active STATUS and COMMENT rows inactive, new STATUS + COMMENT rows. Each change is saved in the backup table (for 06).
-- Dry run unless --commit.
-- Result columns:
--   transaction_id  - the trade
--   current_status  - status found by 04
--   proposed_status - status to set
--   applied         - true: changed now; false: skipped (status is no longer the one 04 found, e.g. already fixed)
--   status_now      - status after this run
BEGIN;

WITH fixes AS (
    SELECT *
    FROM jsonb_to_recordset(current_setting('missed_restriction.candidates')::jsonb)
             AS candidate(transaction_id text, current_status text, proposed_status text, remediable boolean)
    WHERE candidate.remediable),
txn_type AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
support AS (SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com'),
target AS ( -- active status still the one 04 found (any change since, incl. this fix, adds a new status row)
    SELECT fixes.transaction_id, fixes.proposed_status AS new_status, support.user_key,
           old_status.extra_id AS old_extra_id, old_status.attribute_value AS old_status,
           ARRAY(SELECT old_comment.extra_id FROM bk_txn_extra old_comment
                 WHERE old_comment.transaction_id = fixes.transaction_id AND old_comment.is_active IS NOT FALSE
                   AND old_comment.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'COMMENT')) AS old_comment_extra_ids
    FROM fixes
    JOIN bk_txn_extra old_status ON old_status.transaction_id = fixes.transaction_id AND old_status.is_active IS NOT FALSE
        AND old_status.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'STATUS')
        AND old_status.attribute_value = fixes.current_status
    CROSS JOIN support -- no support user: nothing is changed
    FOR UPDATE OF old_status),
deactivated AS (
    UPDATE bk_txn_extra extra SET is_active = false
    FROM target
    WHERE extra.extra_id = target.old_extra_id OR extra.extra_id = ANY (target.old_comment_extra_ids)),
new_status AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT target.transaction_id, (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'STATUS'), target.new_status,
           target.user_key, target.user_key, true
    FROM target
    RETURNING extra_id, transaction_id),
new_comment AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT target.transaction_id, (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'COMMENT'),
           'Status re-evaluated: restriction on a merged FactSet entity ID was not applied at processing time',
           target.user_key, target.user_key, true
    FROM target
    RETURNING extra_id, transaction_id)
INSERT INTO public.missed_restriction_status_backup
    (transaction_id, old_extra_id, old_comment_extra_ids, old_status, new_status, new_status_extra_id, new_comment_extra_id)
SELECT target.transaction_id, target.old_extra_id, target.old_comment_extra_ids, target.old_status, target.new_status,
       new_status.extra_id, new_comment.extra_id
FROM target
JOIN new_status USING (transaction_id)
JOIN new_comment USING (transaction_id);

-- Result: every remediable trade, whether it changed now, and its status now.
SELECT candidate.transaction_id, candidate.current_status, candidate.proposed_status,
       backup.transaction_id IS NOT NULL AS applied,
       (SELECT string_agg(status.attribute_value, ';')
        FROM bk_txn_extra status JOIN bk_txn_extra_types status_type USING (extra_type_id)
        WHERE status.transaction_id = candidate.transaction_id AND status.is_active IS NOT FALSE
          AND status_type.attribute_type = 'STATUS') AS status_now
FROM jsonb_to_recordset(current_setting('missed_restriction.candidates')::jsonb)
         AS candidate(transaction_id text, current_status text, proposed_status text, remediable boolean)
LEFT JOIN public.missed_restriction_status_backup backup
    ON backup.transaction_id = candidate.transaction_id AND backup.applied_at = now()
WHERE candidate.remediable;

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
