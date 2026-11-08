-- Changes the status of the compliance-approved trades on ONE client DB (option B).
-- Method (same as the compliance app): add a new active STATUS row and a COMMENT row, set the old STATUS row inactive,
-- and record both in the backup table, so that script 05 can undo the change.
-- The script ends with ROLLBACK (dry run). Replace ROLLBACK with COMMIT only under the approved CNG.
-- Run all steps in the same session.

-- Step 1. Check: must return true. False means the DBA has not created the backup table yet (see README).
SELECT to_regclass('public.remediation_cor11327_status_backup') IS NOT NULL AS backup_ok;

-- Step 2. Load the client rules: replace <CLIENT_RULES_JSON> with the content of client_rules.json (script 02).
CREATE TEMP TABLE client_rules AS
SELECT '<CLIENT_RULES_JSON>'::jsonb AS doc;

-- Step 3. Create the table for the approved changes, then import approved_status_changes.csv into it
--         with your database tool. Only rows with is_winning_hit = true from script 03:
--         expected_status = current_status, new_status = proposed_status.
CREATE TEMP TABLE approved (
    transaction_id  text PRIMARY KEY,
    expected_status text NOT NULL,
    new_status      text NOT NULL
);

-- Step 4. Checks: both must be true.
--   client_ok: every approved trade belongs to this client.
--   status_ok: every new status is one of the status names of the client (stops typing errors).
SELECT NOT EXISTS (
           SELECT 1 FROM approved a
           JOIN bk_txn bt ON bt.transaction_id = a.transaction_id
           WHERE lower(bt.pdl_client_code) <> lower((SELECT doc ->> 'client_id' FROM client_rules))) AS client_ok,
       NOT EXISTS (
           SELECT 1 FROM approved a
           WHERE NOT EXISTS (
               SELECT 1 FROM client_rules r, jsonb_each_text(r.doc -> 'trade_status_config') c
               WHERE c.value = a.new_status)) AS status_ok;

-- Step 5. Apply the changes inside a transaction.
BEGIN;

WITH target AS (
    -- Trades to change. A trade is skipped when its status changed since the review, it has several
    -- active STATUS rows, it has an active preclear link (compliance handles it in the app),
    -- or this script already changed it and nobody rolled it back.
    SELECT a.transaction_id, s.extra_id AS old_extra_id, s.attribute_value AS old_status, a.new_status
    FROM approved a
    JOIN bk_txn_extra s
      ON s.transaction_id = a.transaction_id
     AND s.extra_type_id = (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS')
     AND s.is_active
    WHERE s.attribute_value = a.expected_status
      AND s.attribute_value <> a.new_status
      AND NOT EXISTS (
          SELECT 1 FROM bk_txn_extra o
          WHERE o.transaction_id = s.transaction_id
            AND o.extra_type_id = s.extra_type_id
            AND o.is_active
            AND o.extra_id <> s.extra_id)
      AND NOT EXISTS (
          SELECT 1 FROM bk_txn_extra p
          WHERE p.transaction_id = s.transaction_id
            AND p.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'MATCHING_PRE_CLEAR_ID')
            AND p.is_active)
      AND NOT EXISTS (
          SELECT 1 FROM public.remediation_cor11327_status_backup b
          WHERE b.transaction_id = a.transaction_id AND b.rolled_back_at IS NULL)
    -- Lock the rows, so that a status change at the same time cannot create a second active status.
    FOR UPDATE OF s
),
deactivated AS (
    -- Set the old STATUS row inactive.
    UPDATE bk_txn_extra e
    SET is_active = false
    FROM target t
    WHERE e.extra_id = t.old_extra_id
      AND e.is_active
),
new_status AS (
    -- Add the new active STATUS row, written as the support user (as the engine does).
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id,
           (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS'),
           t.new_status, u.user_key, u.user_key, true
    FROM target t
    CROSS JOIN (SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com') u
    RETURNING extra_id, transaction_id
),
new_comment AS (
    -- Add a COMMENT row that explains the change to the compliance officers.
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id,
           (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'COMMENT'),
           'Status re-evaluated: restriction on a merged FactSet entity ID was not applied at processing time',
           u.user_key, u.user_key, true
    FROM target t
    CROSS JOIN (SELECT user_key FROM userdb.users WHERE email_address = 'support@paragondatalabs.com') u
    RETURNING extra_id, transaction_id
)
-- Record the old and new rows in the backup table.
INSERT INTO public.remediation_cor11327_status_backup
    (transaction_id, old_extra_id, old_status, new_status, new_status_extra_id, new_comment_extra_id)
SELECT t.transaction_id, t.old_extra_id, t.old_status, t.new_status, ns.extra_id, nc.extra_id
FROM target t
JOIN new_status ns USING (transaction_id)
JOIN new_comment nc USING (transaction_id);

-- Step 6. Result: approved trades vs trades changed in this transaction.
SELECT (SELECT count(*) FROM approved) AS approved,
       (SELECT count(*) FROM public.remediation_cor11327_status_backup WHERE applied_at = now()) AS applied;

-- Step 7. Skipped trades with their status today.
SELECT a.transaction_id, a.expected_status, a.new_status,
       (SELECT string_agg(s.attribute_value, ';')
        FROM bk_txn_extra s
        WHERE s.transaction_id = a.transaction_id
          AND s.is_active
          AND s.extra_type_id = (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS')
       ) AS active_status_now
FROM approved a
WHERE NOT EXISTS (
    SELECT 1 FROM public.remediation_cor11327_status_backup b
    WHERE b.transaction_id = a.transaction_id AND b.applied_at = now());

-- Step 8. Dry run: undo everything. Under the approved CNG, replace with COMMIT,
--         then ask for the PERSONAL_TRADE cache refresh (see README).
ROLLBACK;
