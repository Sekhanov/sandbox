-- Client DB, read-only. Inputs: client_rules.json, security_hist_entity.json, --fix-date. Output: candidates.csv.
-- Trades processed before the fix that missed a restriction on the other entity ID of their security.
-- One row per trade; remediable = true means safe to fix with 05, otherwise review_reason says why not.
WITH cfg AS (  -- input files as rows
    SELECT current_setting('cor11327.client_rules')::jsonb -> 0 -> 'rules' AS doc),
ref_sec_hist AS (SELECT * FROM jsonb_to_recordset(current_setting('cor11327.security_hist_entity')::jsonb)
                 AS x(security_id text, historical_entity_id text, engine_entity_id text, merge_date text)),
rules AS (  -- client rules in engine order: list name patterns and the status an IN hit sets
    SELECT r.ord AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(CASE jsonb_typeof(r.rule -> 'LIST_NAME')
                     WHEN 'array' THEN r.rule -> 'LIST_NAME' ELSE jsonb_build_array(r.rule -> 'LIST_NAME') END)) AS list_patterns,
           cfg.doc -> 'trade_status_config' ->> (r.rule -> 'ACTION' ->> 'IN') AS proposed_status,
           (r.rule -> 'ATTRIBUTE_TYPE') IS NOT NULL OR (r.rule -> 'AUTH0_CHECK_RULE') IS NOT NULL AS has_employee_filter
    FROM cfg, jsonb_array_elements(cfg.doc -> 'restriction_rules') WITH ORDINALITY r(rule, ord)
),
extra AS NOT MATERIALIZED (  -- active trade rows by type
    SELECT e.transaction_id, t.attribute_type, e.attribute_value, e.created_date
    FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
    WHERE e.is_active IS NOT FALSE
),
attr AS NOT MATERIALIZED (  -- restriction fields by type, live and deleted (all rows: the engine ignores is_active)
    SELECT a.attribute_id, t.attribute_type, a.attribute_value, a.created_date, false AS deleted
    FROM attribute_extra a JOIN attribute_extra_types t USING (attribute_extra_type_id)
    UNION ALL
    SELECT a.attribute_id, t.attribute_type, a.attribute_value, a.created_date, true
    FROM migdb.deleted_attribute_extra a JOIN attribute_extra_types t USING (attribute_extra_type_id)
),
trades AS (  -- client trades of affected securities that went through the restriction check before the fix
    SELECT bt.transaction_id, bt.trade_id, bt.trade_date::date AS trade_date, right(bt.account_number, 4) AS account_last4,
           bt.symbol, bt.security_name, bt.transaction_type, bt.quantity, sec.attribute_value AS security_id,
           h.engine_entity_id, h.historical_entity_id, h.merge_date::date AS merge_date,
           rs.attribute_value AS rule_status, rs.created_date AS processed_at,
           (SELECT min(f[1]::int) FROM regexp_matches(rs.attribute_value, 'RESTRICTION_CHECK_(\d+): true', 'g') f) AS first_fired_rule
    FROM bk_txn bt
    JOIN extra sec ON sec.transaction_id = bt.transaction_id AND sec.attribute_type = 'SECURITY_ID'
    JOIN ref_sec_hist h ON h.security_id = sec.attribute_value
    JOIN extra rs ON rs.transaction_id = bt.transaction_id AND rs.attribute_type = 'RULE_STATUS'
                 AND rs.attribute_value LIKE '%RESTRICTION_CHECK_%' AND rs.created_date < current_setting('cor11327.fix_date')::date
    WHERE lower(bt.pdl_client_code) = lower((SELECT doc ->> 'client_id' FROM cfg))
),
restrictions AS (  -- restrictions by CID with their list, live or deleted
    SELECT DISTINCT cid.attribute_id AS disc_id, cid.attribute_value AS cid, rl.restriction_list_name, cid.deleted AS restriction_deleted
    FROM attr cid
    JOIN (SELECT disc_id, disc_type FROM disclosures UNION ALL SELECT disc_id, disc_type FROM migdb.deleted_disclosures) d
         ON d.disc_id = cid.attribute_id
    JOIN disclosure_types dt ON dt.disc_type_id = d.disc_type AND dt.disc_type = 'RESTRICTION'
    JOIN attr lid ON lid.attribute_id = d.disc_id AND lid.attribute_type = 'RESTRICTION_LIST_ID'
    JOIN restriction_lists rl ON rl.restriction_list_id::text = lid.attribute_value
    WHERE cid.attribute_type = 'CID'
),
hits AS (  -- restriction on the missed ID: not found by the engine, active on the trade date, on a list of a relevant rule
    SELECT t.*, r.disc_id, r.restriction_list_name, r.restriction_deleted, ru.rule_index, ru.proposed_status, ru.has_employee_filter
    FROM trades t
    JOIN restrictions r ON r.cid = t.historical_entity_id
    JOIN rules ru ON r.restriction_list_name LIKE ANY (ru.list_patterns)
    WHERE NOT EXISTS (  -- the engine found it: a CID or SECURITY_ID row it searched by existed at processing time
            SELECT 1 FROM attr f
            WHERE f.attribute_id = r.disc_id AND f.created_date <= t.processed_at
              AND ((f.attribute_type = 'CID' AND f.attribute_value = t.engine_entity_id)
                OR (f.attribute_type = 'SECURITY_ID' AND f.attribute_value = t.security_id)))
      AND EXISTS (  -- Active by the end of the trade date, and not Cleared/Inactive before it (as the engine)
            SELECT 1 FROM attr a
            WHERE a.attribute_id = r.disc_id AND a.attribute_type = 'STATUS' AND a.attribute_value = 'Active'
              AND a.created_date < t.trade_date + 1
              AND NOT EXISTS (SELECT 1 FROM attr i
                              WHERE i.attribute_id = r.disc_id AND i.attribute_type = 'STATUS'
                                AND i.attribute_value IN ('Cleared', 'Inactive')
                                AND i.created_date >= a.created_date AND i.created_date < t.trade_date))
      AND position(format('RESTRICTION_CHECK_%s: false (AUTH0_FALSE)', ru.rule_index) IN t.rule_status) = 0
      AND (   (ru.proposed_status IS NOT NULL AND coalesce(t.first_fired_rule >= ru.rule_index, true))  -- IN would have fired
           OR position(format('RESTRICTION_CHECK_%s: true (Not on', ru.rule_index) IN t.rule_status) > 0)  -- NOT_IN fired wrongly
),
first_hit AS (
    SELECT DISTINCT ON (transaction_id) h.*,
           (SELECT string_agg(attribute_value, ';') FROM extra WHERE transaction_id = h.transaction_id AND attribute_type = 'STATUS') AS current_status,
           (SELECT count(*) FROM bk_txn_extra e JOIN bk_txn_extra_types et USING (extra_type_id)
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
