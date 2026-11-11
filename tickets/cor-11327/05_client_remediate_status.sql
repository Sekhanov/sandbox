-- Client DB, option B. Sets the new status of the approved trades, as the compliance app does: a new active
-- STATUS row and a COMMENT row, the old STATUS row inactive, all recorded in the backup table (for script 06).
-- Inputs: <CLIENT_RULES_JSON> = client_rules.json; temp table approved = approved_status_changes.csv
--         (transaction_id, expected_status, new_status) from the remediable rows of script 04.
BEGIN;

WITH cfg AS (SELECT '<CLIENT_RULES_JSON>'::jsonb AS doc),
types AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
support AS (SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com'),
target AS (  -- approved trades that are safe to change; the result below lists the skipped ones
    SELECT a.transaction_id, s.extra_id AS old_extra_id, s.attribute_value AS old_status, a.new_status
    FROM approved a
    JOIN bk_txn bt ON bt.transaction_id = a.transaction_id
                  AND lower(bt.pdl_client_code) = lower(NULLIF((SELECT doc ->> 'client_id' FROM cfg), ''))  -- this client
    JOIN bk_txn_extra s ON s.transaction_id = a.transaction_id AND s.is_active
                       AND s.extra_type_id IN (SELECT extra_type_id FROM types WHERE attribute_type = 'STATUS')
                       AND s.attribute_value = a.expected_status                                           -- unchanged since review
    WHERE a.new_status <> a.expected_status
      AND a.new_status IN (SELECT value FROM cfg, jsonb_each_text(doc -> 'trade_status_config'))            -- known status
      AND NOT EXISTS (SELECT 1 FROM bk_txn_extra o                                                          -- one active status
                      WHERE o.transaction_id = s.transaction_id AND o.extra_type_id = s.extra_type_id
                        AND o.is_active AND o.extra_id <> s.extra_id)
      AND NOT EXISTS (SELECT 1 FROM bk_txn_extra p                                                          -- no preclear link
                      WHERE p.transaction_id = s.transaction_id AND p.is_active IS NOT FALSE
                        AND p.extra_type_id IN (SELECT extra_type_id FROM types WHERE attribute_type = 'MATCHING_PRE_CLEAR_ID'))
      AND NOT EXISTS (SELECT 1 FROM public.remediation_cor11327_status_backup b                              -- not changed yet
                      WHERE b.transaction_id = a.transaction_id AND b.rolled_back_at IS NULL)
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
INSERT INTO public.remediation_cor11327_status_backup
       (transaction_id, old_extra_id, old_status, new_status, new_status_extra_id, new_comment_extra_id)
SELECT t.transaction_id, t.old_extra_id, t.old_status, t.new_status, ns.extra_id, nc.extra_id
FROM target t JOIN new_status ns USING (transaction_id) JOIN new_comment nc USING (transaction_id);

-- Result: every approved trade, whether it changed, and its status now.
SELECT a.*, b.transaction_id IS NOT NULL AS applied,
       (SELECT string_agg(e.attribute_value, ';') FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
        WHERE e.transaction_id = a.transaction_id AND e.is_active AND t.attribute_type = 'STATUS') AS status_now
FROM approved a
LEFT JOIN public.remediation_cor11327_status_backup b ON b.transaction_id = a.transaction_id AND b.applied_at = now();

-- Dry run. Under the CNG use COMMIT (app: --commit), then ask for the PERSONAL_TRADE cache refresh.
ROLLBACK;
