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
             AS x(transaction_id text, current_status text, proposed_status text, remediable boolean)
    WHERE remediable),
types AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
support AS (SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com'),
target AS ( -- active status still the one 04 found (any change since, incl. this fix, adds a new status row)
    SELECT f.transaction_id, f.proposed_status AS new_status, u.user_key,
           s.extra_id AS old_extra_id, s.attribute_value AS old_status,
           ARRAY(SELECT c.extra_id FROM bk_txn_extra c
                 WHERE c.transaction_id = f.transaction_id AND c.is_active IS NOT FALSE
                   AND c.extra_type_id IN (SELECT extra_type_id FROM types WHERE attribute_type = 'COMMENT')) AS old_comment_extra_ids
    FROM fixes f
    JOIN bk_txn_extra s ON s.transaction_id = f.transaction_id AND s.is_active IS NOT FALSE
        AND s.extra_type_id IN (SELECT extra_type_id FROM types WHERE attribute_type = 'STATUS')
        AND s.attribute_value = f.current_status
    CROSS JOIN support u -- no support user: nothing is changed
    FOR UPDATE OF s),
deactivated AS (
    UPDATE bk_txn_extra e SET is_active = false
    FROM target t
    WHERE e.extra_id = t.old_extra_id OR e.extra_id = ANY (t.old_comment_extra_ids)),
new_status AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id, (SELECT extra_type_id FROM types WHERE attribute_type = 'STATUS'), t.new_status, t.user_key, t.user_key, true
    FROM target t
    RETURNING extra_id, transaction_id),
new_comment AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id, (SELECT extra_type_id FROM types WHERE attribute_type = 'COMMENT'),
           'Status re-evaluated: restriction on a merged FactSet entity ID was not applied at processing time',
           t.user_key, t.user_key, true
    FROM target t
    RETURNING extra_id, transaction_id)
INSERT INTO public.missed_restriction_status_backup
    (transaction_id, old_extra_id, old_comment_extra_ids, old_status, new_status, new_status_extra_id, new_comment_extra_id)
SELECT t.transaction_id, t.old_extra_id, t.old_comment_extra_ids, t.old_status, t.new_status, ns.extra_id, nc.extra_id
FROM target t
JOIN new_status ns USING (transaction_id)
JOIN new_comment nc USING (transaction_id);

-- Result: every remediable trade, whether it changed now, and its status now.
SELECT f.transaction_id, f.current_status, f.proposed_status,
       b.transaction_id IS NOT NULL AS applied,
       (SELECT string_agg(e.attribute_value, ';')
        FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
        WHERE e.transaction_id = f.transaction_id AND e.is_active IS NOT FALSE AND t.attribute_type = 'STATUS') AS status_now
FROM jsonb_to_recordset(current_setting('missed_restriction.candidates')::jsonb)
         AS f(transaction_id text, current_status text, proposed_status text, remediable boolean)
LEFT JOIN public.missed_restriction_status_backup b ON b.transaction_id = f.transaction_id AND b.applied_at = now()
WHERE f.remediable;

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
