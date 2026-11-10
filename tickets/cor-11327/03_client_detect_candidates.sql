-- Finds the trades of one client that missed a restriction on an old entity ID. Runs on ONE client DB.
-- Changes no data: it creates only temporary tables, which disappear when the session ends.
-- Run all steps in the same session.

-- Step 1. Load the client rules: replace <CLIENT_RULES_JSON> with the content of client_rules.json (script 02).
CREATE TEMP TABLE client_rules AS
SELECT '{
  "stage": "DEV",
  "region": "eastus",
  "client_id": "lkmo",
  "environment": "AZURE",
  "restriction_rules": [
    {
      "ACTION": {
        "IN": "PENDING_MATCH_STATUS",
        "NOT_IN": false
      },
      "LIST_NAME": [
        "Restricted List"
      ]
    }
  ],
  "trade_status_config": {
    "MATCH_STATUS": "Matched",
    "MANAGED_ACCOUNT": "Managed Account",
    "PRECLR_NOT_NEEDED": "Preclear Not Needed",
    "PENDING_MATCH_STATUS": "Pending Match"
  },
  "trade_config_version": "0669fb94-8042-45c1-a725-3a2d0e82aa15",
  "trade_config_published": true
}'::jsonb AS doc;
-- SELECT '<CLIENT_RULES_JSON>'::jsonb AS doc;

-- Step 2. Check: must return true. False means the rules file belongs to another client DB.
SELECT EXISTS (
    SELECT 1 FROM bk_txn
    WHERE lower(pdl_client_code) = lower((SELECT doc ->> 'client_id' FROM client_rules))
) AS client_matches;

-- Step 3. Create the table for the old entity IDs, then import security_hist_entity.csv (script 01)
--         into it with your database tool.
CREATE TEMP TABLE ref_sec_hist (
    security_id          text NOT NULL,
    sma_entity_id        text NOT NULL,
    current_entity_id    text NOT NULL,
    historical_entity_id text NOT NULL,
    merge_date           date,
    depth                int  NOT NULL
);
CREATE INDEX ON ref_sec_hist (security_id);

-- Step 4. Select the trades that reached the restriction check and whose security has old entity IDs.
CREATE TEMP TABLE scan_trades AS
    SELECT bt.transaction_id, bt.trade_id, bt.trade_date::date AS trade_date, bt.pdl_account_id, bt.account_number,
           bt.symbol, bt.security_name, bt.transaction_type, bt.quantity,
           sec.attribute_value AS security_id,
           rs.attribute_value  AS rule_status,          -- result text, e.g. "RESTRICTION_CHECK_1: true (On List A)"
           rs.modified_date    AS processed_at,
           lower(bt.pdl_client_code) = lower((SELECT doc ->> 'client_id' FROM client_rules)) AS own_client
    FROM bk_txn bt
    JOIN bk_txn_extra sec
      ON sec.transaction_id = bt.transaction_id
     AND sec.is_active IS NOT FALSE
     AND sec.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'SECURITY_ID')
    JOIN bk_txn_extra rs
      ON rs.transaction_id = bt.transaction_id
     AND rs.is_active IS NOT FALSE
     AND rs.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'RULE_STATUS')
     AND rs.attribute_value LIKE '%RESTRICTION_CHECK_%'
    WHERE EXISTS (SELECT 1 FROM ref_sec_hist h WHERE h.security_id = sec.attribute_value);

-- Step 5. Find all trade/restriction pairs that the engine missed and save them in a temporary table.
CREATE TEMP TABLE scan_hits AS
WITH cfg AS (
    SELECT doc FROM client_rules
),
-- The restriction rules of the client, numbered in order (the engine checks them in this order).
rules AS (
    SELECT r.ord::int AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(
               CASE jsonb_typeof(r.rule -> 'LIST_NAME')
                   WHEN 'array' THEN r.rule -> 'LIST_NAME'
                   ELSE jsonb_build_array(r.rule -> 'LIST_NAME')
               END))                                                       AS list_patterns,
           NULLIF(NULLIF(r.rule -> 'ACTION' ->> 'IN', 'false'), '')        AS action_in,       -- status to set on a hit
           COALESCE(r.rule ->> 'ATTRIBUTE_TYPE', '') <> ''                 AS has_attribute_filter,
           COALESCE(jsonb_typeof(r.rule -> 'AUTH0_CHECK_RULE') = 'object', false) AS has_auth0_check
    FROM cfg, jsonb_array_elements(cfg.doc -> 'restriction_rules') WITH ORDINALITY AS r(rule, ord)
),
attr_types AS (
    SELECT
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'RESTRICTION_LIST_ID') AS restriction_list_id_type,
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'STATUS') AS status_type,
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID') AS cid_type
),
-- Restrictions on a company (CID) with their list. Deleted rows are kept, as the engine does, and flagged.
cid_restrictions AS (
    SELECT d.disc_id,
           d.is_active   AS disclosure_is_active,
           cid.attribute_value AS cid,
           cid.is_active AS cid_attribute_is_active,
           lid.is_active AS list_attribute_is_active,
           rl.restriction_list_name
    FROM disclosures d
    JOIN disclosure_types dt ON dt.disc_type_id = d.disc_type AND dt.disc_type = 'RESTRICTION'
    JOIN attribute_extra cid ON cid.attribute_id = d.disc_id AND cid.attribute_extra_type_id = (SELECT cid_type FROM attr_types)
    JOIN attribute_extra lid ON lid.attribute_id = d.disc_id AND lid.attribute_extra_type_id = (SELECT restriction_list_id_type FROM attr_types)
    JOIN restriction_lists rl ON rl.restriction_list_id::text = lid.attribute_value
),
-- Trades whose old entity ID has a restriction that was active on the trade date.
hits AS (
    SELECT t.*,
           h.sma_entity_id, h.current_entity_id, h.historical_entity_id, h.merge_date, h.depth,
           r.disc_id, r.restriction_list_name, r.disclosure_is_active, r.cid_attribute_is_active, r.list_attribute_is_active
    FROM scan_trades t
    JOIN ref_sec_hist h ON h.security_id = t.security_id
    JOIN cid_restrictions r ON r.cid = h.historical_entity_id
    WHERE t.own_client
      -- Active on the trade date: an Active status by the end of that day, not cleared or set inactive before it.
      AND EXISTS (
        SELECT 1
        FROM attribute_extra a
        WHERE a.attribute_id = r.disc_id
          AND a.attribute_extra_type_id = (SELECT status_type FROM attr_types)
          AND a.attribute_value = 'Active'
          AND a.created_date < t.trade_date + 1
          AND NOT EXISTS (
              SELECT 1
              FROM attribute_extra i
              WHERE i.attribute_id = r.disc_id
                AND i.attribute_extra_type_id = (SELECT status_type FROM attr_types)
                AND i.attribute_value IN ('Cleared', 'Inactive')
                AND i.created_date >= a.created_date
                AND i.created_date < t.trade_date))
),
-- Adds the rule that covers the list, the current state of the trade, and whether the engine already saw the list.
scored AS (
    SELECT x.*,
           x.trade_date < x.merge_date AS trade_before_merge,
           m.rule_index, m.action_in,
           (SELECT doc FROM cfg) -> 'trade_status_config' ->> m.action_in AS proposed_status,
           m.has_attribute_filter, m.has_auth0_check,
           ff.first_fired_rule, cs.current_status, pc.matching_preclear_id,
           -- The original run already named this list in "(On List A,List B)".
           EXISTS (
               SELECT 1
               FROM regexp_matches(x.rule_status, '\(On ([^)]*)\)', 'g') AS o(g)
               WHERE x.restriction_list_name = ANY (string_to_array(o.g[1], ','))
           ) AS already_matched
    FROM hits x
    -- First rule that covers the list, preferring one with an action. No rule: the engine never checks this list.
    LEFT JOIN LATERAL (
        SELECT ru.*
        FROM rules ru
        WHERE x.restriction_list_name LIKE ANY (ru.list_patterns)
        ORDER BY ru.action_in IS NULL, ru.rule_index
        LIMIT 1
    ) m ON true
    -- First rule that found a restriction in the original run.
    CROSS JOIN LATERAL (
        SELECT min(f.g[1]::int) AS first_fired_rule
        FROM regexp_matches(x.rule_status, 'RESTRICTION_CHECK_(\d+): true', 'g') AS f(g)
    ) ff
    -- Current trade status.
    CROSS JOIN LATERAL (
        SELECT string_agg(st.attribute_value, ';') AS current_status
        FROM bk_txn_extra st
        WHERE st.transaction_id = x.transaction_id
          AND st.is_active IS NOT FALSE
          AND st.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS')
    ) cs
    -- Preclear that the trade matched, if any.
    CROSS JOIN LATERAL (
        SELECT string_agg(pe.attribute_value, ';') AS matching_preclear_id
        FROM bk_txn_extra pe
        WHERE pe.transaction_id = x.transaction_id
          AND pe.is_active IS NOT FALSE
          AND pe.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'MATCHING_PRE_CLEAR_ID')
    ) pc
)
SELECT s.*,
       -- The missed restriction changes the status: the rule has an action, no earlier rule decided,
       -- the user account check did not fail, and the status is different today.
       (s.action_in IS NOT NULL
        AND (s.first_fired_rule IS NULL OR s.first_fired_rule >= s.rule_index)
        AND position(format('RESTRICTION_CHECK_%s: false (AUTH0_FALSE)', s.rule_index) IN s.rule_status) = 0
        AND s.current_status IS DISTINCT FROM s.proposed_status
       ) AS status_would_change,
       -- A person must look at the trade: employee filters, a preclear match, a trade before the merge,
       -- or a deleted restriction.
       (s.has_attribute_filter OR s.has_auth0_check
        OR s.matching_preclear_id IS NOT NULL
        OR (s.current_status = (SELECT doc FROM cfg) -> 'trade_status_config' ->> 'MATCH_STATUS') IS TRUE
        OR s.trade_before_merge IS TRUE
        OR (s.disclosure_is_active AND s.cid_attribute_is_active AND s.list_attribute_is_active) IS NOT TRUE
       ) AS needs_review
FROM scored s;

-- Step 6. Counts. trades_other_client_code above 0 needs an explanation (those trades are ignored).
SELECT (SELECT count(*) FILTER (WHERE own_client) FROM scan_trades)     AS trades_with_merged_entity_security,
       (SELECT count(*) FILTER (WHERE NOT own_client) FROM scan_trades) AS trades_other_client_code,
       count(*)                                                                 AS raw_hits,
       count(*) FILTER (WHERE rule_index IS NULL)                               AS hits_no_rule_covers_list,
       count(*) FILTER (WHERE rule_index IS NOT NULL AND already_matched)       AS hits_already_matched,
       count(*) FILTER (WHERE rule_index IS NOT NULL AND NOT already_matched)   AS candidate_rows
FROM scan_hits;

-- Step 7. The candidate list. Save it as candidates.csv for the compliance review.
--         Only rows with is_winning_hit = true (one per trade) go into the approved file for script 04.
SELECT transaction_id, trade_id, trade_date, processed_at,
       pdl_account_id, right(account_number, 4) AS account_last4,
       symbol, security_name, transaction_type, quantity,
       security_id, sma_entity_id, current_entity_id, historical_entity_id, depth, merge_date, trade_before_merge,
       disc_id, restriction_list_name, disclosure_is_active, cid_attribute_is_active, list_attribute_is_active,
       rule_index, action_in, proposed_status, has_attribute_filter, has_auth0_check, first_fired_rule,
       status_would_change, needs_review,
       -- One row per trade: the hit that changes the status, then the lowest rule, then the lowest restriction.
       row_number() OVER (PARTITION BY transaction_id
                          ORDER BY status_would_change DESC NULLS LAST, rule_index, disc_id) = 1 AS is_winning_hit,
       current_status, matching_preclear_id, rule_status
FROM scan_hits
WHERE rule_index IS NOT NULL
  AND NOT already_matched
ORDER BY trade_date, transaction_id, rule_index, disc_id;
