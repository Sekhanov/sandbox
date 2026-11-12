-- Client DB. Inputs: client_rules.json, candidates.json (04). Fixes the rows with remediable = true.
-- Sets the new status as the app does: old STATUS row inactive, new STATUS + COMMENT rows,
-- each change saved in the backup table (for 06). Dry run unless --commit.
-- Result columns:
--   transaction_id  - the trade
--   current_status  - status found by 04
--   proposed_status - status to set
--   applied         - true: changed now; false: skipped (status changed since 04, preclear link, or already fixed)
--   status_now      - status after this run
BEGIN;

WITH cfg AS (SELECT current_setting('missed_restriction.client_rules')::jsonb -> 0 -> 'rules' AS doc),
fixes AS (
    SELECT * FROM jsonb_to_recordset(current_setting('missed_restriction.candidates')::jsonb)
                  AS x(transaction_id text, current_status text, proposed_status text, remediable boolean)
    WHERE remediable
),
types AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
support AS (SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com'),
target AS (  -- trades still safe to change; the result below shows the skipped ones
    SELECT f.transaction_id, s.extra_id AS old_extra_id, s.attribute_value AS old_status, f.proposed_status AS new_status
    FROM fixes f
    JOIN bk_txn bt ON bt.transaction_id = f.transaction_id
                  AND lower(bt.pdl_client_code) = lower(NULLIF((SELECT doc ->> 'client_id' FROM cfg), ''))  -- this client
    JOIN bk_txn_extra s ON s.transaction_id = f.transaction_id AND s.is_active
                       AND s.extra_type_id IN (SELECT extra_type_id FROM types WHERE attribute_type = 'STATUS')
                       AND s.attribute_value = f.current_status                                            -- unchanged since 04
    WHERE f.proposed_status IN (SELECT value FROM cfg, jsonb_each_text(doc -> 'trade_status_config'))       -- known status
      AND NOT EXISTS (SELECT 1 FROM bk_txn_extra o                                                          -- one active status
                      WHERE o.transaction_id = s.transaction_id AND o.extra_type_id = s.extra_type_id
                        AND o.is_active AND o.extra_id <> s.extra_id)
      AND NOT EXISTS (SELECT 1 FROM bk_txn_extra p                                                          -- no preclear link
                      WHERE p.transaction_id = s.transaction_id AND p.is_active IS NOT FALSE
                        AND p.extra_type_id IN (SELECT extra_type_id FROM types WHERE attribute_type = 'MATCHING_PRE_CLEAR_ID'))
      AND NOT EXISTS (SELECT 1 FROM public.missed_restriction_status_backup b                              -- not changed yet
                      WHERE b.transaction_id = f.transaction_id AND b.rolled_back_at IS NULL)
    FOR UPDATE OF s
),
deactivated AS (UPDATE bk_txn_extra e SET is_active = false FROM target t WHERE e.extra_id = t.old_extra_id),
new_status AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id, (SELECT extra_type_id FROM types WHERE attribute_type = 'STATUS'), t.new_status, u.user_key, u.user_key, true
    FROM target t, support u
    RETURNING extra_id, transaction_id
),
new_comment AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id, (SELECT extra_type_id FROM types WHERE attribute_type = 'COMMENT'),
           'Status re-evaluated: restriction on a merged FactSet entity ID was not applied at processing time',
           u.user_key, u.user_key, true
    FROM target t, support u
    RETURNING extra_id, transaction_id
)
INSERT INTO public.missed_restriction_status_backup
       (transaction_id, old_extra_id, old_status, new_status, new_status_extra_id, new_comment_extra_id)
SELECT t.transaction_id, t.old_extra_id, t.old_status, t.new_status, ns.extra_id, nc.extra_id
FROM target t JOIN new_status ns USING (transaction_id) JOIN new_comment nc USING (transaction_id);

-- Result: every remediable trade, whether it changed now, and its status now.
SELECT f.transaction_id, f.current_status, f.proposed_status, b.transaction_id IS NOT NULL AS applied,
       (SELECT string_agg(e.attribute_value, ';') FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
        WHERE e.transaction_id = f.transaction_id AND e.is_active AND t.attribute_type = 'STATUS') AS status_now
FROM jsonb_to_recordset(current_setting('missed_restriction.candidates')::jsonb)
     AS f(transaction_id text, current_status text, proposed_status text, remediable boolean)
LEFT JOIN public.missed_restriction_status_backup b ON b.transaction_id = f.transaction_id AND b.applied_at = now()
WHERE f.remediable;

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
