-- Client DB, read-only. Inputs: client_rules.json, restrictions.json, security_hist_entity.json, --fix-date. Output: candidates.json (for 05).
-- Trades processed before the fix that missed a restriction on the other entity ID of their security.
-- One row per trade; remediable = true means safe to fix with 05, otherwise review_reason says why not.
-- Cost: one pass over the SECURITY_ID rows of bk_txn_extra (no index on the value); everything else is by index or small.
-- Result columns:
--   transaction_id, trade_id, trade_date, account_last4, symbol, security_name, transaction_type, quantity - the trade
--   security_id, security_cid, restricted_cid, merge_date - from 02
--   rule_status          - engine result text (RULE_STATUS)
--   processed_at         - when the engine wrote it (US Eastern, as the restriction dates)
--   first_fired_rule     - first rule that fired then (empty: none)
--   disc_id, restriction_deleted, restriction_list_name - the missed restriction
--   rule_index           - first rule that would have changed the result
--   proposed_status      - status that rule sets (empty: NOT_IN rule)
--   has_employee_filter  - the rule filters by employee attribute (ATTRIBUTE_TYPE)
--   current_status       - status now
--   status_rows          - number of STATUS rows (more than 1: changed after processing)
--   preclear_id          - linked preclear, if any
--   review_reason        - why a person must decide (empty: safe)
--   remediable           - true: 05 fixes it
WITH cfg AS ( -- client_rules.json
    SELECT doc,
           doc -> 'trade_status_config' ->> 'MATCH_STATUS'         AS match_status,
           doc -> 'trade_status_config' ->> 'PENDING_MATCH_STATUS' AS pending_status,
           jsonb_array_length(doc -> 'sic_rules') > 0              AS has_sic_rules
    FROM (SELECT current_setting('missed_restriction.client_rules')::jsonb AS doc) x),
sec_hist AS ( -- security_hist_entity.json
    SELECT *
    FROM jsonb_to_recordset(current_setting('missed_restriction.security_hist_entity')::jsonb)
             AS x(security_id text, restricted_cid text, security_cid text, merge_date text)),
rules AS ( -- client rules in engine order
    SELECT r.ord                                                              AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(r.rule -> 'LIST_NAME'))     AS list_patterns,
           cfg.doc -> 'trade_status_config' ->> (r.rule -> 'ACTION' ->> 'IN') AS proposed_status,
           r.rule ? 'ATTRIBUTE_TYPE'                                          AS has_employee_filter
    FROM cfg, jsonb_array_elements(cfg.doc -> 'restriction_rules') WITH ORDINALITY r(rule, ord)),
txn_type AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
trades AS ( -- trades of those securities that the engine checked for restrictions before the fix
    SELECT bt.transaction_id, bt.trade_id, bt.trade_date::date AS trade_date, right(bt.account_number, 4) AS account_last4,
           bt.symbol, bt.security_name, bt.transaction_type, bt.quantity,
           h.security_id, h.security_cid, h.restricted_cid, h.merge_date::date AS merge_date,
           rs.attribute_value AS rule_status,
           (rs.modified_date AT TIME ZONE 'UTC') AT TIME ZONE 'US/Eastern' AS processed_at, -- engine writes UTC, the app US Eastern; created_date is the trade date
           (SELECT min(m[1]::int)
            FROM regexp_matches(rs.attribute_value, 'RESTRICTION_CHECK_(\d+): true', 'g') m) AS first_fired_rule
    FROM sec_hist h
    JOIN bk_txn_extra sec ON sec.attribute_value = h.security_id AND sec.is_active IS NOT FALSE
        AND sec.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'SECURITY_ID')
    JOIN bk_txn_extra rs ON rs.transaction_id = sec.transaction_id AND rs.is_active IS NOT FALSE
        AND rs.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'RULE_STATUS')
        AND rs.attribute_value LIKE '%RESTRICTION_CHECK_%'
        AND (rs.modified_date AT TIME ZONE 'UTC') AT TIME ZONE 'US/Eastern' < current_setting('missed_restriction.fix_date')::date
    JOIN bk_txn bt ON bt.transaction_id = sec.transaction_id),
restrictions AS MATERIALIZED ( -- restrictions.json, only those with a missed CID
    SELECT *
    FROM jsonb_to_recordset(current_setting('missed_restriction.restrictions')::jsonb)
             AS x(disc_id text, cid text, restriction_deleted boolean)
    WHERE cid IN (SELECT restricted_cid FROM sec_hist)),
restriction_fields AS MATERIALIZED ( -- all fields of those restrictions, live and deleted (the engine ignores is_active)
    SELECT a.attribute_id, t.attribute_type, a.attribute_value, a.created_date
    FROM (SELECT attribute_id, attribute_extra_type_id, attribute_value, created_date FROM attribute_extra
          UNION ALL
          SELECT attribute_id, attribute_extra_type_id, attribute_value, created_date FROM migdb.deleted_attribute_extra) a
    JOIN attribute_extra_types t USING (attribute_extra_type_id)
    WHERE a.attribute_id IN (SELECT disc_id FROM restrictions)),
missed AS ( -- restriction the engine did not find, active on the trade date
    SELECT t.*, r.disc_id, r.restriction_deleted
    FROM trades t
    JOIN restrictions r ON r.cid = t.restricted_cid
    WHERE NOT EXISTS ( -- the engine found it: a CID or SECURITY_ID row it searched by existed at processing time
            SELECT 1 FROM restriction_fields found
            WHERE found.attribute_id = r.disc_id AND found.created_date <= t.processed_at
              AND ((found.attribute_type = 'CID' AND found.attribute_value = t.security_cid)
                OR (found.attribute_type = 'SECURITY_ID' AND found.attribute_value = t.security_id)))
      AND EXISTS ( -- Active by the end of the trade date ...
            SELECT 1 FROM restriction_fields active
            WHERE active.attribute_id = r.disc_id AND active.attribute_type = 'STATUS' AND active.attribute_value = 'Active'
              AND active.created_date < t.trade_date + 1
              AND NOT EXISTS ( -- ... and not ended before the trade date
                    SELECT 1 FROM restriction_fields ended
                    WHERE ended.attribute_id = r.disc_id AND ended.attribute_type = 'STATUS'
                      AND ended.attribute_value IN ('Cleared', 'Inactive')
                      AND ended.created_date >= active.created_date AND ended.created_date < t.trade_date))),
hits AS ( -- rules whose list has the missed restriction and that would have changed the result
    SELECT m.*, rl.restriction_list_name, ru.rule_index, ru.proposed_status, ru.has_employee_filter
    FROM missed m
    JOIN restriction_fields list ON list.attribute_id = m.disc_id AND list.attribute_type = 'RESTRICTION_LIST_ID'
    JOIN restriction_lists rl ON rl.restriction_list_id::text = list.attribute_value
    JOIN rules ru ON rl.restriction_list_name LIKE ANY (ru.list_patterns)
    WHERE m.rule_status NOT LIKE '%RESTRICTION_CHECK_' || ru.rule_index || ': false (AUTH0_FALSE)%' -- rule skipped for this employee
      AND ((ru.proposed_status IS NOT NULL AND coalesce(m.first_fired_rule >= ru.rule_index, true)) -- IN rule would have fired
        OR m.rule_status LIKE '%RESTRICTION_CHECK_' || ru.rule_index || ': true (Not on%')), -- NOT_IN rule fired wrongly
first_hit AS ( -- the engine stops at the first rule with an action
    SELECT DISTINCT ON (transaction_id) * FROM hits ORDER BY transaction_id, rule_index, disc_id),
state AS ( -- trade state now
    SELECT f.*, extra.*
    FROM first_hit f,
         LATERAL (
             SELECT string_agg(e.attribute_value, ';') FILTER (WHERE t.attribute_type = 'STATUS' AND e.is_active IS NOT FALSE)                AS current_status,
                    count(*) FILTER (WHERE t.attribute_type = 'STATUS')                                                                       AS status_rows,
                    string_agg(e.attribute_value, ';') FILTER (WHERE t.attribute_type = 'MATCHING_PRE_CLEAR_ID' AND e.is_active IS NOT FALSE) AS preclear_id
             FROM bk_txn_extra e
             JOIN txn_type t USING (extra_type_id)
             WHERE e.transaction_id = f.transaction_id) extra),
reviewed AS (
    SELECT s.*,
           NULLIF(concat_ws(',',
               CASE WHEN has_employee_filter THEN 'employee_filter' END,
               CASE WHEN preclear_id IS NOT NULL OR current_status = c.match_status THEN 'preclear_linked' END,
               CASE WHEN status_rows > 1 THEN 'status_changed_by_user' END,
               CASE WHEN proposed_status = c.pending_status THEN 'pending_match_action' END,
               CASE WHEN c.has_sic_rules THEN 'sic_rules' END,
               CASE WHEN proposed_status IS NULL THEN 'not_in_rule' END,
               CASE WHEN restriction_deleted THEN 'deleted_restriction' END,
               CASE WHEN processed_at < merge_date THEN 'processed_before_merge' END), '') AS review_reason
    FROM state s, cfg c)
SELECT *, review_reason IS NULL AND current_status IS DISTINCT FROM proposed_status AS remediable
FROM reviewed
ORDER BY transaction_id;
