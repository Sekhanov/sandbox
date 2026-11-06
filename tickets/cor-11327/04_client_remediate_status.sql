-- Apply compliance-approved status changes to ONE client DB. Dry run (ROLLBACK) unless -v apply=true.
-- Convention (compliance-app fn_process_trade_data_direct.sql): insert a new active STATUS row, deactivate the old one.
-- Input: ./approved_status_changes.csv with header transaction_id,expected_status,new_status
--   Only 03 rows with is_winning_hit = true; expected_status = current_status, new_status = proposed_status.
-- Usage (from out/<client>/, after the backup table DDL in README):
--   psql "service=client_rw_ACME" -v client_rules="$(cat client_rules.json)" [-v apply=true] -f ../../04_client_remediate_status.sql
-- Rows are skipped when the trade's status changed since review, it has several active STATUS rows,
-- it has an active preclear link (MATCHING_PRE_CLEAR_ID: compliance handles it in the app),
-- or it was already remediated and not rolled back.
\set ON_ERROR_STOP on
\if :{?client_rules} \else \echo 'Missing -v client_rules' \quit \endif
\if :{?apply} \else \set apply false \endif

SELECT to_regclass('public.remediation_cor11327_status_backup') IS NOT NULL AS backup_ok \gset
\if :backup_ok \else \echo 'Backup table missing: run the DDL from README first' \quit \endif

BEGIN;

SELECT user_key AS support_user FROM userdb.users WHERE email_address = 'support@paragondatalabs.com' \gset

CREATE TEMP TABLE approved (
    transaction_id  text PRIMARY KEY,
    expected_status text NOT NULL,
    new_status      text NOT NULL
) ON COMMIT DROP;
\copy approved FROM 'approved_status_changes.csv' WITH (FORMAT csv, HEADER true)

SELECT NOT EXISTS (
           SELECT 1 FROM approved a
           JOIN bk_txn bt ON bt.transaction_id = a.transaction_id
           WHERE lower(bt.pdl_client_code) <> lower(:'client_rules'::jsonb ->> 'client_id')) AS client_ok,
       NOT EXISTS (
           SELECT 1 FROM approved a
           WHERE NOT EXISTS (
               SELECT 1 FROM jsonb_each_text(:'client_rules'::jsonb -> 'trade_status_config') c
               WHERE c.value = a.new_status)) AS status_ok \gset
\if :client_ok \else \echo 'Approved trades belong to another client' \quit \endif
\if :status_ok \else \echo 'new_status must be a value of trade_status_config' \quit \endif

-- VERIFY: bk_txn_extra_types has a COMMENT row in every client DB (not in seed; used by preclear flip in service.ts).
-- VERIFY: no triggers or FKs on bk_txn_extra that need extra handling.
WITH target AS (
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
    FOR UPDATE OF s
),
deactivated AS (
    UPDATE bk_txn_extra e
    SET is_active = false
    FROM target t
    WHERE e.extra_id = t.old_extra_id
      AND e.is_active
),
new_status AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id,
           (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS'),
           t.new_status, :'support_user', :'support_user', true
    FROM target t
    RETURNING extra_id, transaction_id
),
new_comment AS (
    INSERT INTO bk_txn_extra (transaction_id, extra_type_id, attribute_value, created_by, modified_by, is_active)
    SELECT t.transaction_id,
           (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'COMMENT'),
           'Status re-evaluated: restriction on a merged FactSet entity ID was not applied at processing time',
           :'support_user', :'support_user', true
    FROM target t
    RETURNING extra_id, transaction_id
)
INSERT INTO public.remediation_cor11327_status_backup
    (transaction_id, old_extra_id, old_status, new_status, new_status_extra_id, new_comment_extra_id)
SELECT t.transaction_id, t.old_extra_id, t.old_status, t.new_status, ns.extra_id, nc.extra_id
FROM target t
JOIN new_status ns USING (transaction_id)
JOIN new_comment nc USING (transaction_id);

\echo 'Approved vs applied in this run'
SELECT (SELECT count(*) FROM approved) AS approved,
       (SELECT count(*) FROM public.remediation_cor11327_status_backup WHERE applied_at = now()) AS applied;

\echo 'Skipped (status changed, several active statuses, preclear link, or already remediated)'
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

\if :apply
COMMIT;
\echo 'APPLIED. Next: request the targeted PERSONAL_TRADE cache refresh (see README).'
\else
ROLLBACK;
\echo 'DRY RUN: rolled back. Re-run with -v apply=true under the approved CNG.'
\endif
