-- Client DB, read-only. Inputs: client_rules.json, security_hist_entity.json, --fix-date. Output: candidates.json (for 05).
-- Trades processed before the fix that missed a restriction on the other entity ID of their security.
-- One row per trade; remediable = true means safe to fix with 05, otherwise review_reason says why not.
-- Cost: one pass over the SECURITY_ID rows of bk_txn_extra (no index on the value); everything else is by index or small.
-- Result columns:
--   transaction_id, trade_id, trade_date, account_last4, symbol, security_name, transaction_type, quantity - the trade
--   security_id, engine_entity_id, historical_entity_id, merge_date - from 02
--   rule_status          - engine result text (RULE_STATUS)
--   processed_at         - when the engine wrote it
--   first_fired_rule     - first rule that fired then (empty: none)
--   disc_id, restriction_list_name, restriction_deleted - the missed restriction
--   rule_index           - first rule that would have changed the result
--   proposed_status      - status that rule sets (empty: NOT_IN rule)
--   has_employee_filter  - the rule filters by employee
--   current_status       - status now
--   status_rows          - number of STATUS rows (more than 1: changed after processing)
--   preclear_id          - linked preclear, if any
--   review_reason        - why a person must decide (empty: safe)
--   remediable           - true: 05 fixes it
WITH cfg AS (SELECT current_setting('cor11327.client_rules')::jsonb -> 0 -> 'rules' AS doc),  -- client_rules.json
ref_sec_hist AS (  -- security_hist_entity.json as rows
    SELECT * FROM jsonb_to_recordset(current_setting('cor11327.security_hist_entity')::jsonb)
                  AS x(security_id text, historical_entity_id text, engine_entity_id text, merge_date text)
),
rules AS (  -- client rules in engine order: list name patterns and the status an IN hit sets
    SELECT r.ord AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(CASE jsonb_typeof(r.rule -> 'LIST_NAME')
                     WHEN 'array' THEN r.rule -> 'LIST_NAME' ELSE jsonb_build_array(r.rule -> 'LIST_NAME') END)) AS list_patterns,
           cfg.doc -> 'trade_status_config' ->> (r.rule -> 'ACTION' ->> 'IN') AS proposed_status,
           (r.rule -> 'ATTRIBUTE_TYPE') IS NOT NULL OR (r.rule -> 'AUTH0_CHECK_RULE') IS NOT NULL AS has_employee_filter
    FROM cfg, jsonb_array_elements(cfg.doc -> 'restriction_rules') WITH ORDINALITY r(rule, ord)
),
txn_type AS (SELECT attribute_type, extra_type_id FROM bk_txn_extra_types),
extra AS NOT MATERIALIZED (  -- active trade rows by type; only used per transaction_id (index)
    SELECT e.transaction_id, t.attribute_type, e.attribute_value
    FROM bk_txn_extra e JOIN txn_type t USING (extra_type_id)
    WHERE e.is_active IS NOT FALSE
),
trades AS (  -- trades of the affected securities that went through the restriction check before the fix
    SELECT bt.transaction_id, bt.trade_id, bt.trade_date::date AS trade_date, right(bt.account_number, 4) AS account_last4,
           bt.symbol, bt.security_name, bt.transaction_type, bt.quantity, sec.attribute_value AS security_id,
           h.engine_entity_id, h.historical_entity_id, h.merge_date::date AS merge_date,
           rs.attribute_value AS rule_status, rs.created_date AS processed_at,
           (SELECT min(f[1]::int) FROM regexp_matches(rs.attribute_value, 'RESTRICTION_CHECK_(\d+): true', 'g') f) AS first_fired_rule
    FROM bk_txn_extra sec
    JOIN ref_sec_hist h ON h.security_id = sec.attribute_value
    JOIN bk_txn_extra rs ON rs.transaction_id = sec.transaction_id AND rs.is_active IS NOT FALSE
                        AND rs.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'RULE_STATUS')
                        AND rs.attribute_value LIKE '%RESTRICTION_CHECK_%'
                        AND rs.created_date < current_setting('cor11327.fix_date')::date
    JOIN bk_txn bt ON bt.transaction_id = sec.transaction_id
    WHERE sec.extra_type_id IN (SELECT extra_type_id FROM txn_type WHERE attribute_type = 'SECURITY_ID')
      AND sec.is_active IS NOT FALSE
      AND lower(bt.pdl_client_code) = lower((SELECT doc ->> 'client_id' FROM cfg))
),
restrictions AS MATERIALIZED (  -- restrictions whose CID is a missed ID; deleted if a copy is in migdb (soft-deleted ones are in both)
    SELECT a.attribute_id AS disc_id, a.attribute_value AS cid, bool_or(a.deleted) AS restriction_deleted
    FROM (SELECT attribute_id, attribute_extra_type_id, attribute_value, false AS deleted FROM attribute_extra
          UNION ALL
          SELECT attribute_id, attribute_extra_type_id, attribute_value, true FROM migdb.deleted_attribute_extra) a
    JOIN (SELECT disc_id, disc_type FROM disclosures UNION ALL SELECT disc_id, disc_type FROM migdb.deleted_disclosures) d
         ON d.disc_id = a.attribute_id
    WHERE a.attribute_extra_type_id IN (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID')
      AND d.disc_type IN (SELECT disc_type_id FROM disclosure_types WHERE disc_type = 'RESTRICTION')
      AND a.attribute_value IN (SELECT historical_entity_id FROM ref_sec_hist)
    GROUP BY a.attribute_id, a.attribute_value
),
rattr AS MATERIALIZED (  -- all fields of those restrictions, read once (the engine ignores is_active)
    SELECT a.attribute_id, t.attribute_type, a.attribute_value, a.created_date
    FROM attribute_extra a JOIN attribute_extra_types t USING (attribute_extra_type_id)
    WHERE a.attribute_id IN (SELECT disc_id FROM restrictions)
    UNION ALL
    SELECT a.attribute_id, t.attribute_type, a.attribute_value, a.created_date
    FROM migdb.deleted_attribute_extra a JOIN attribute_extra_types t USING (attribute_extra_type_id)
    WHERE a.attribute_id IN (SELECT disc_id FROM restrictions)
),
lists AS (  -- list name of each restriction
    SELECT DISTINCT a.attribute_id AS disc_id, rl.restriction_list_name
    FROM rattr a JOIN restriction_lists rl ON rl.restriction_list_id::text = a.attribute_value
    WHERE a.attribute_type = 'RESTRICTION_LIST_ID'
),
hits AS (  -- restriction on the missed ID: not found by the engine, active on the trade date, on a list of a relevant rule
    SELECT t.*, r.disc_id, l.restriction_list_name, r.restriction_deleted, ru.rule_index, ru.proposed_status, ru.has_employee_filter
    FROM trades t
    JOIN restrictions r ON r.cid = t.historical_entity_id
    JOIN lists l USING (disc_id)
    JOIN rules ru ON l.restriction_list_name LIKE ANY (ru.list_patterns)
    WHERE NOT EXISTS (  -- the engine found it: a CID or SECURITY_ID row it searched by existed at processing time
            SELECT 1 FROM rattr f
            WHERE f.attribute_id = r.disc_id AND f.created_date <= t.processed_at
              AND ((f.attribute_type = 'CID' AND f.attribute_value = t.engine_entity_id)
                OR (f.attribute_type = 'SECURITY_ID' AND f.attribute_value = t.security_id)))
      AND EXISTS (  -- Active by the end of the trade date, and not Cleared/Inactive before it (as the engine)
            SELECT 1 FROM rattr a
            WHERE a.attribute_id = r.disc_id AND a.attribute_type = 'STATUS' AND a.attribute_value = 'Active'
              AND a.created_date < t.trade_date + 1
              AND NOT EXISTS (SELECT 1 FROM rattr i
                              WHERE i.attribute_id = r.disc_id AND i.attribute_type = 'STATUS'
                                AND i.attribute_value IN ('Cleared', 'Inactive')
                                AND i.created_date >= a.created_date AND i.created_date < t.trade_date))
      AND position(format('RESTRICTION_CHECK_%s: false (AUTH0_FALSE)', ru.rule_index) IN t.rule_status) = 0
      AND (   (ru.proposed_status IS NOT NULL AND coalesce(t.first_fired_rule >= ru.rule_index, true))  -- IN would have fired
           OR position(format('RESTRICTION_CHECK_%s: true (Not on', ru.rule_index) IN t.rule_status) > 0)  -- NOT_IN fired wrongly
),
first_hit AS (  -- first rule per trade, plus its current state (by transaction_id index)
    SELECT DISTINCT ON (transaction_id) h.*,
           (SELECT string_agg(attribute_value, ';') FROM extra WHERE transaction_id = h.transaction_id AND attribute_type = 'STATUS') AS current_status,
           (SELECT count(*) FROM bk_txn_extra e JOIN txn_type et USING (extra_type_id)
            WHERE e.transaction_id = h.transaction_id AND et.attribute_type = 'STATUS') AS status_rows,
           (SELECT string_agg(attribute_value, ';') FROM extra WHERE transaction_id = h.transaction_id AND attribute_type = 'MATCHING_PRE_CLEAR_ID') AS preclear_id
    FROM hits h
    ORDER BY transaction_id, rule_index, disc_id
),
reviewed AS (
    SELECT f.*, NULLIF(concat_ws(',',
        CASE WHEN has_employee_filter THEN 'employee_filter' END,
        CASE WHEN preclear_id IS NOT NULL OR current_status = c.doc -> 'trade_status_config' ->> 'MATCH_STATUS' THEN 'preclear_linked' END,
        CASE WHEN status_rows > 1 THEN 'status_changed_by_user' END,
        CASE WHEN proposed_status = c.doc -> 'trade_status_config' ->> 'PENDING_MATCH_STATUS' THEN 'pending_match_action' END,
        CASE WHEN jsonb_typeof(c.doc -> 'sic_rules') = 'array' AND jsonb_array_length(c.doc -> 'sic_rules') > 0 THEN 'sic_rules' END,
        CASE WHEN proposed_status IS NULL THEN 'not_in_rule' END,
        CASE WHEN restriction_deleted THEN 'deleted_restriction' END,
        CASE WHEN trade_date < merge_date THEN 'trade_before_merge' END), '') AS review_reason
    FROM first_hit f, cfg c
)
SELECT *, proposed_status IS NOT NULL AND current_status IS DISTINCT FROM proposed_status AND review_reason IS NULL AS remediable
FROM reviewed
ORDER BY transaction_id;
