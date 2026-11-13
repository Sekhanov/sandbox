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
WITH config AS ( -- client_rules.json
    SELECT client_rules.doc,
           client_rules.doc -> 'trade_status_config' ->> 'MATCH_STATUS'         AS match_status,
           client_rules.doc -> 'trade_status_config' ->> 'PENDING_MATCH_STATUS' AS pending_status,
           jsonb_array_length(client_rules.doc -> 'sic_rules') > 0              AS has_sic_rules
    FROM (SELECT current_setting('missed_restriction.client_rules')::jsonb AS doc) client_rules),
sec_hist AS ( -- security_hist_entity.json
    SELECT *
    FROM jsonb_to_recordset(current_setting('missed_restriction.security_hist_entity')::jsonb)
             AS security(security_id text, restricted_cid text, security_cid text, merge_date text)),
rules AS ( -- client rules in engine order
    SELECT client_rule.ord                                                                 AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(client_rule.rule -> 'LIST_NAME'))        AS list_patterns,
           config.doc -> 'trade_status_config' ->> (client_rule.rule -> 'ACTION' ->> 'IN') AS proposed_status,
           client_rule.rule ? 'ATTRIBUTE_TYPE'                                             AS has_employee_filter
    FROM config, jsonb_array_elements(config.doc -> 'restriction_rules') WITH ORDINALITY client_rule(rule, ord)),
txn_type AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
trades AS ( -- trades of those securities that the engine checked for restrictions before the fix
    SELECT trade.transaction_id, trade.trade_id, trade.trade_date::date AS trade_date, right(trade.account_number, 4) AS account_last4,
           trade.symbol, trade.security_name, trade.transaction_type, trade.quantity,
           sec_hist.security_id, sec_hist.security_cid, sec_hist.restricted_cid, sec_hist.merge_date::date AS merge_date,
           rule_status.attribute_value AS rule_status,
           (rule_status.modified_date AT TIME ZONE 'UTC') AT TIME ZONE 'US/Eastern' AS processed_at, -- engine writes UTC, the app US Eastern; created_date is the trade date
           (SELECT min(fired[1]::int)
            FROM regexp_matches(rule_status.attribute_value, 'RESTRICTION_CHECK_(\d+): true', 'g') fired) AS first_fired_rule
    FROM sec_hist
    JOIN bk_txn_extra trade_security ON trade_security.attribute_value = sec_hist.security_id AND trade_security.is_active IS NOT FALSE
        AND trade_security.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'SECURITY_ID')
    JOIN bk_txn_extra rule_status ON rule_status.transaction_id = trade_security.transaction_id AND rule_status.is_active IS NOT FALSE
        AND rule_status.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'RULE_STATUS')
        AND rule_status.attribute_value LIKE '%RESTRICTION_CHECK_%'
        AND (rule_status.modified_date AT TIME ZONE 'UTC') AT TIME ZONE 'US/Eastern' < current_setting('missed_restriction.fix_date')::date
    JOIN bk_txn trade ON trade.transaction_id = trade_security.transaction_id),
restrictions AS MATERIALIZED ( -- restrictions.json, only those with a missed CID
    SELECT *
    FROM jsonb_to_recordset(current_setting('missed_restriction.restrictions')::jsonb)
             AS restriction(disc_id text, cid text, restriction_deleted boolean)
    WHERE restriction.cid IN (SELECT restricted_cid FROM sec_hist)),
restriction_fields AS MATERIALIZED ( -- all fields of those restrictions, live and deleted (the engine ignores is_active)
    SELECT attr.attribute_id, attr_type.attribute_type, attr.attribute_value, attr.created_date
    FROM (SELECT attribute_id, attribute_extra_type_id, attribute_value, created_date FROM attribute_extra
          UNION ALL
          SELECT attribute_id, attribute_extra_type_id, attribute_value, created_date FROM migdb.deleted_attribute_extra) attr
    JOIN attribute_extra_types attr_type USING (attribute_extra_type_id)
    WHERE attr.attribute_id IN (SELECT disc_id FROM restrictions)),
missed AS ( -- restriction the engine did not find, active on the trade date
    SELECT trades.*, restriction.disc_id, restriction.restriction_deleted
    FROM trades
    JOIN restrictions restriction ON restriction.cid = trades.restricted_cid
    WHERE NOT EXISTS ( -- the engine found it: a CID or SECURITY_ID row it searched by existed at processing time
            SELECT 1 FROM restriction_fields found
            WHERE found.attribute_id = restriction.disc_id AND found.created_date <= trades.processed_at
              AND ((found.attribute_type = 'CID' AND found.attribute_value = trades.security_cid)
                OR (found.attribute_type = 'SECURITY_ID' AND found.attribute_value = trades.security_id)))
      AND EXISTS ( -- Active by the end of the trade date ...
            SELECT 1 FROM restriction_fields active
            WHERE active.attribute_id = restriction.disc_id AND active.attribute_type = 'STATUS' AND active.attribute_value = 'Active'
              AND active.created_date < trades.trade_date + 1
              AND NOT EXISTS ( -- ... and not ended before the trade date
                    SELECT 1 FROM restriction_fields ended
                    WHERE ended.attribute_id = restriction.disc_id AND ended.attribute_type = 'STATUS'
                      AND ended.attribute_value IN ('Cleared', 'Inactive')
                      AND ended.created_date >= active.created_date AND ended.created_date < trades.trade_date))),
hits AS ( -- rules whose list has the missed restriction and that would have changed the result
    SELECT missed.*, list.restriction_list_name, rules.rule_index, rules.proposed_status, rules.has_employee_filter
    FROM missed
    JOIN restriction_fields list_id ON list_id.attribute_id = missed.disc_id AND list_id.attribute_type = 'RESTRICTION_LIST_ID'
    JOIN restriction_lists list ON list.restriction_list_id::text = list_id.attribute_value
    JOIN rules ON list.restriction_list_name LIKE ANY (rules.list_patterns)
    WHERE missed.rule_status NOT LIKE '%RESTRICTION_CHECK_' || rules.rule_index || ': false (AUTH0_FALSE)%' -- rule skipped for this employee
      AND ((rules.proposed_status IS NOT NULL AND coalesce(missed.first_fired_rule >= rules.rule_index, true)) -- IN rule would have fired
        OR missed.rule_status LIKE '%RESTRICTION_CHECK_' || rules.rule_index || ': true (Not on%')), -- NOT_IN rule fired wrongly
first_hit AS ( -- the engine stops at the first rule with an action
    SELECT DISTINCT ON (transaction_id) * FROM hits ORDER BY transaction_id, rule_index, disc_id),
state AS ( -- trade state now
    SELECT first_hit.*, trade_extra.*
    FROM first_hit,
         LATERAL (
             SELECT string_agg(extra.attribute_value, ';') FILTER (WHERE extra_type.attribute_type = 'STATUS' AND extra.is_active IS NOT FALSE)                AS current_status,
                    count(*) FILTER (WHERE extra_type.attribute_type = 'STATUS')                                                                               AS status_rows,
                    string_agg(extra.attribute_value, ';') FILTER (WHERE extra_type.attribute_type = 'MATCHING_PRE_CLEAR_ID' AND extra.is_active IS NOT FALSE) AS preclear_id
             FROM bk_txn_extra extra
             JOIN txn_type extra_type USING (extra_type_id)
             WHERE extra.transaction_id = first_hit.transaction_id) trade_extra),
reviewed AS (
    SELECT state.*,
           NULLIF(concat_ws(',',
               CASE WHEN state.has_employee_filter THEN 'employee_filter' END,
               CASE WHEN state.preclear_id IS NOT NULL OR state.current_status = config.match_status THEN 'preclear_linked' END,
               CASE WHEN state.status_rows > 1 THEN 'status_changed_by_user' END,
               CASE WHEN state.proposed_status = config.pending_status THEN 'pending_match_action' END,
               CASE WHEN config.has_sic_rules THEN 'sic_rules' END,
               CASE WHEN state.proposed_status IS NULL THEN 'not_in_rule' END,
               CASE WHEN state.restriction_deleted THEN 'deleted_restriction' END,
               CASE WHEN state.processed_at < state.merge_date THEN 'processed_before_merge' END), '') AS review_reason
    FROM state, config)
SELECT reviewed.*,
       reviewed.review_reason IS NULL AND reviewed.current_status IS DISTINCT FROM reviewed.proposed_status AS remediable
FROM reviewed
ORDER BY reviewed.transaction_id;
