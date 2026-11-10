-- Client DB, read-only. Trades that missed a restriction on the other entity ID of their security.
-- Inputs: <CLIENT_RULES_JSON> = client_rules.json; temp table ref_sec_hist = security_hist_entity.csv.
-- One row per trade (the first rule that applies). Rows with remediable = true can go to script 04.
WITH cfg AS (SELECT '<CLIENT_RULES_JSON>'::jsonb AS doc),
rules AS (  -- client rules in engine order: list name patterns and the status that a hit sets
    SELECT r.ord AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(CASE jsonb_typeof(r.rule -> 'LIST_NAME')
                     WHEN 'array' THEN r.rule -> 'LIST_NAME' ELSE jsonb_build_array(r.rule -> 'LIST_NAME') END)) AS list_patterns,
           cfg.doc -> 'trade_status_config' ->> (r.rule -> 'ACTION' ->> 'IN') AS proposed_status,
           (r.rule -> 'ATTRIBUTE_TYPE') IS NOT NULL OR (r.rule -> 'AUTH0_CHECK_RULE') IS NOT NULL AS has_employee_filter
    FROM cfg, jsonb_array_elements(cfg.doc -> 'restriction_rules') WITH ORDINALITY r(rule, ord)
),
extra AS NOT MATERIALIZED (  -- active trade rows by type
    SELECT e.transaction_id, t.attribute_type, e.attribute_value
    FROM bk_txn_extra e JOIN bk_txn_extra_types t USING (extra_type_id)
    WHERE e.is_active IS NOT FALSE
),
attr AS NOT MATERIALIZED (  -- restriction fields by type
    SELECT a.attribute_id, t.attribute_type, a.attribute_value, a.is_active, a.created_date
    FROM attribute_extra a JOIN attribute_extra_types t USING (attribute_extra_type_id)
),
trades AS (  -- client trades of affected securities that went through the restriction check
    SELECT bt.transaction_id, bt.trade_id, bt.trade_date::date AS trade_date, right(bt.account_number, 4) AS account_last4,
           bt.symbol, bt.security_name, bt.transaction_type, bt.quantity, sec.attribute_value AS security_id,
           h.historical_entity_id, h.merge_date::date AS merge_date, rs.attribute_value AS rule_status
    FROM bk_txn bt
    JOIN extra sec ON sec.transaction_id = bt.transaction_id AND sec.attribute_type = 'SECURITY_ID'
    JOIN ref_sec_hist h ON h.security_id = sec.attribute_value
    JOIN extra rs ON rs.transaction_id = bt.transaction_id AND rs.attribute_type = 'RULE_STATUS'
                 AND rs.attribute_value LIKE '%RESTRICTION_CHECK_%'
    WHERE lower(bt.pdl_client_code) = lower((SELECT doc ->> 'client_id' FROM cfg))
),
restrictions AS (  -- restrictions on a company; deleted ones count, as in the engine
    SELECT d.disc_id, cid.attribute_value AS cid, rl.restriction_list_name,
           (d.is_active AND cid.is_active AND lid.is_active) IS NOT TRUE AS restriction_deleted
    FROM disclosures d
    JOIN disclosure_types dt ON dt.disc_type_id = d.disc_type AND dt.disc_type = 'RESTRICTION'
    JOIN attr cid ON cid.attribute_id = d.disc_id AND cid.attribute_type = 'CID'
    JOIN attr lid ON lid.attribute_id = d.disc_id AND lid.attribute_type = 'RESTRICTION_LIST_ID'
    JOIN restriction_lists rl ON rl.restriction_list_id::text = lid.attribute_value
),
hits AS (  -- restriction on the other ID: active on the trade date, covered by a rule, not in the engine result
    SELECT t.*, r.disc_id, r.restriction_list_name, r.restriction_deleted, ru.rule_index, ru.proposed_status, ru.has_employee_filter,
           (SELECT string_agg(attribute_value, ';') FROM extra WHERE transaction_id = t.transaction_id AND attribute_type = 'STATUS') AS current_status,
           (SELECT string_agg(attribute_value, ';') FROM extra WHERE transaction_id = t.transaction_id AND attribute_type = 'MATCHING_PRE_CLEAR_ID') AS preclear_id,
           (SELECT min(f[1]::int) FROM regexp_matches(t.rule_status, 'RESTRICTION_CHECK_(\d+): true', 'g') f) AS first_fired_rule
    FROM trades t
    JOIN restrictions r ON r.cid = t.historical_entity_id
    JOIN LATERAL (SELECT * FROM rules WHERE r.restriction_list_name LIKE ANY (list_patterns)
                  ORDER BY proposed_status IS NULL, rule_index LIMIT 1) ru ON true
    WHERE EXISTS (  -- Active by the end of the trade date, and not Cleared/Inactive before it
            SELECT 1 FROM attr a
            WHERE a.attribute_id = r.disc_id AND a.attribute_type = 'STATUS' AND a.attribute_value = 'Active'
              AND a.created_date < t.trade_date + 1
              AND NOT EXISTS (SELECT 1 FROM attr i
                              WHERE i.attribute_id = r.disc_id AND i.attribute_type = 'STATUS'
                                AND i.attribute_value IN ('Cleared', 'Inactive')
                                AND i.created_date >= a.created_date AND i.created_date < t.trade_date))
      AND NOT EXISTS (  -- the engine result "(On List A,List B)" already names this list
            SELECT 1 FROM regexp_matches(t.rule_status, '\(On ([^)]*)\)', 'g') o
            WHERE r.restriction_list_name = ANY (string_to_array(o[1], ',')))
),
scored AS (
    SELECT h.*,
           -- the rule sets a status, no earlier rule decided, its user check did not fail, the status differs
           (proposed_status IS NOT NULL
            AND coalesce(first_fired_rule >= rule_index, true)
            AND position(format('RESTRICTION_CHECK_%s: false (AUTH0_FALSE)', rule_index) IN rule_status) = 0
            AND current_status IS DISTINCT FROM proposed_status) AS status_would_change,
           -- a person must decide
           (has_employee_filter OR preclear_id IS NOT NULL OR restriction_deleted OR trade_date < merge_date
            OR current_status = (SELECT doc -> 'trade_status_config' ->> 'MATCH_STATUS' FROM cfg)) IS TRUE AS needs_review
    FROM hits h
)
SELECT DISTINCT ON (transaction_id) *, status_would_change AND NOT needs_review AS remediable
FROM scored
ORDER BY transaction_id, status_would_change DESC, rule_index, disc_id;
