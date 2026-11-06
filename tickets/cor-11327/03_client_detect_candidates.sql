-- List trades whose restriction check missed a CID restriction placed on another entity id of the
-- security's merged-entity chain. Runs against ONE client DB. No persistent writes: only session TEMP objects.
-- Usage (from the folder holding security_hist_entity.csv; out must be a file path):
--   psql "service=client_ro_ACME" -v client_rules="$(cat out/ACME/client_rules.json)" \
--        -v out=out/ACME/candidates.csv -f 03_client_detect_candidates.sql
-- Restriction semantics mirror storage/repositories/clientDb/RestrictionRepository.ts (soft-deleted rows included, flagged).
-- Only rows with is_winning_hit = true (one per trade) may go into the approved CSV for 04.
\set ON_ERROR_STOP on
\if :{?client_rules} \else \echo 'Missing -v client_rules' \quit \endif
\if :{?out} \else \echo 'Missing -v out' \quit \endif

-- Guard against running a client's config on another client's DB (trade task matches pdl_client_code to client id).
-- VERIFY: engine-loaded trades keep pdl_client_code = client id (renamed clients: see brokerdb.client_code_history).
SELECT EXISTS (
    SELECT 1 FROM bk_txn WHERE lower(pdl_client_code) = lower(:'client_rules'::jsonb ->> 'client_id')
) AS client_matches \gset
\if :client_matches \else \echo 'client_rules.client_id does not match this DB' \quit \endif

-- VERIFY: the role has TEMP privilege and the DB is not a read-only replica (else use the jsonb fallback in README).
CREATE TEMP TABLE ref_sec_hist (
    security_id          text NOT NULL,
    sma_entity_id        text NOT NULL,
    current_entity_id    text NOT NULL,
    historical_entity_id text NOT NULL,
    merge_date           date,
    depth                int  NOT NULL
);
\copy ref_sec_hist FROM 'security_hist_entity.csv' WITH (FORMAT csv, HEADER true)
CREATE INDEX ON ref_sec_hist (security_id);
ANALYZE ref_sec_hist;

-- Trades that reached the restriction check (outcome string contains RESTRICTION_CHECK_n).
CREATE TEMP VIEW scan_trades AS
SELECT bt.transaction_id, bt.trade_id, bt.trade_date::date AS trade_date, bt.pdl_account_id, bt.account_number,
       bt.symbol, bt.security_name, bt.transaction_type, bt.quantity,
       sec.attribute_value AS security_id,
       rs.attribute_value  AS rule_status,
       rs.modified_date    AS processed_at,
       lower(bt.pdl_client_code) = lower(:'client_rules'::jsonb ->> 'client_id') AS own_client
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

CREATE TEMP VIEW scan_hits_v AS
WITH rules AS (
    SELECT r.ord::int AS rule_index,
           ARRAY(SELECT jsonb_array_elements_text(
               CASE jsonb_typeof(r.rule -> 'LIST_NAME')
                   WHEN 'array' THEN r.rule -> 'LIST_NAME'
                   ELSE jsonb_build_array(r.rule -> 'LIST_NAME')
               END))                                                       AS list_patterns,
           NULLIF(NULLIF(r.rule -> 'ACTION' ->> 'IN', 'false'), '')        AS action_in,
           COALESCE(r.rule ->> 'ATTRIBUTE_TYPE', '') <> ''                 AS has_attribute_filter,
           COALESCE(jsonb_typeof(r.rule -> 'AUTH0_CHECK_RULE') = 'object', false) AS has_auth0_check
    FROM jsonb_array_elements(:'client_rules'::jsonb -> 'restriction_rules') WITH ORDINALITY AS r(rule, ord)
),
attr_types AS (
    SELECT
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'RESTRICTION_LIST_ID') AS restriction_list_id_type,
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'STATUS') AS status_type,
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID') AS cid_type
),
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
hits AS (
    SELECT t.*,
           h.sma_entity_id, h.current_entity_id, h.historical_entity_id, h.merge_date, h.depth,
           r.disc_id, r.restriction_list_name, r.disclosure_is_active, r.cid_attribute_is_active, r.list_attribute_is_active
    FROM scan_trades t
    JOIN ref_sec_hist h ON h.security_id = t.security_id
    JOIN cid_restrictions r ON r.cid = h.historical_entity_id
    WHERE t.own_client
      -- Active on the trade date: an Active row by end of day, not cleared/inactivated before the trade date.
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
scored AS (
    SELECT x.*,
           x.trade_date < x.merge_date AS trade_before_merge,
           m.rule_index, m.action_in,
           :'client_rules'::jsonb -> 'trade_status_config' ->> m.action_in AS proposed_status,
           m.has_attribute_filter, m.has_auth0_check,
           ff.first_fired_rule, cs.current_status, pc.matching_preclear_id,
           -- The original run already matched this list: outcome format "(On List A,List B)".
           -- VERIFY: the same format for trades from older engine versions.
           EXISTS (
               SELECT 1
               FROM regexp_matches(x.rule_status, '\(On ([^)]*)\)', 'g') AS o(g)
               WHERE x.restriction_list_name = ANY (string_to_array(o.g[1], ','))
           ) AS already_matched
    FROM hits x
    -- Lowest rule covering the list, preferring one with an IN action (the engine skips falsy actions).
    -- No row: no rule covers the list, so the engine never checked it.
    LEFT JOIN LATERAL (
        SELECT ru.*
        FROM rules ru
        WHERE x.restriction_list_name LIKE ANY (ru.list_patterns)
        ORDER BY ru.action_in IS NULL, ru.rule_index
        LIMIT 1
    ) m ON true
    CROSS JOIN LATERAL (
        SELECT min(f.g[1]::int) AS first_fired_rule
        FROM regexp_matches(x.rule_status, 'RESTRICTION_CHECK_(\d+): true', 'g') AS f(g)
    ) ff
    CROSS JOIN LATERAL (
        SELECT string_agg(st.attribute_value, ';') AS current_status
        FROM bk_txn_extra st
        WHERE st.transaction_id = x.transaction_id
          AND st.is_active IS NOT FALSE
          AND st.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'STATUS')
    ) cs
    CROSS JOIN LATERAL (
        SELECT string_agg(pe.attribute_value, ';') AS matching_preclear_id
        FROM bk_txn_extra pe
        WHERE pe.transaction_id = x.transaction_id
          AND pe.is_active IS NOT FALSE
          AND pe.extra_type_id IN (SELECT extra_type_id FROM bk_txn_extra_types WHERE attribute_type = 'MATCHING_PRE_CLEAR_ID')
    ) pc
)
SELECT s.*,
       -- Approximation of the rule loop: the first rule with an action wins.
       (s.action_in IS NOT NULL
        AND (s.first_fired_rule IS NULL OR s.first_fired_rule >= s.rule_index)
        AND position(format('RESTRICTION_CHECK_%s: false (AUTH0_FALSE)', s.rule_index) IN s.rule_status) = 0
        AND s.current_status IS DISTINCT FROM s.proposed_status
       ) AS status_would_change,
       -- A preclear match means the trade ended Matched; the restriction status may have blocked that match.
       (s.has_attribute_filter OR s.has_auth0_check
        OR s.matching_preclear_id IS NOT NULL
        OR (s.current_status = :'client_rules'::jsonb -> 'trade_status_config' ->> 'MATCH_STATUS') IS TRUE
        OR s.trade_before_merge IS TRUE
        OR (s.disclosure_is_active AND s.cid_attribute_is_active AND s.list_attribute_is_active) IS NOT TRUE
       ) AS needs_review
FROM scored s;

CREATE TEMP TABLE scan_hits AS SELECT * FROM scan_hits_v WITH NO DATA;

BEGIN TRANSACTION READ ONLY;
-- Writes to TEMP tables are allowed in a read-only transaction.
INSERT INTO scan_hits SELECT * FROM scan_hits_v;

\echo 'Counts'
SELECT (SELECT count(*) FILTER (WHERE own_client) FROM scan_trades)     AS trades_with_merged_entity_security,
       (SELECT count(*) FILTER (WHERE NOT own_client) FROM scan_trades) AS trades_other_client_code,
       count(*)                                                         AS raw_hits,
       count(*) FILTER (WHERE rule_index IS NULL)                       AS hits_no_rule_covers_list,
       count(*) FILTER (WHERE rule_index IS NOT NULL AND already_matched) AS hits_already_matched,
       count(*) FILTER (WHERE rule_index IS NOT NULL AND NOT already_matched) AS candidate_rows
FROM scan_hits;

\pset format csv
\o :out
SELECT transaction_id, trade_id, trade_date, processed_at,
       pdl_account_id, right(account_number, 4) AS account_last4,
       symbol, security_name, transaction_type, quantity,
       security_id, sma_entity_id, current_entity_id, historical_entity_id, depth, merge_date, trade_before_merge,
       disc_id, restriction_list_name, disclosure_is_active, cid_attribute_is_active, list_attribute_is_active,
       rule_index, action_in, proposed_status, has_attribute_filter, has_auth0_check, first_fired_rule,
       status_would_change, needs_review,
       -- One row per trade: the hit that changes the status, then the lowest rule.
       row_number() OVER (PARTITION BY transaction_id
                          ORDER BY status_would_change DESC NULLS LAST, rule_index, disc_id) = 1 AS is_winning_hit,
       current_status, matching_preclear_id, rule_status
FROM scan_hits
WHERE rule_index IS NOT NULL
  AND NOT already_matched
ORDER BY trade_date, transaction_id, rule_index, disc_id;
\o

ROLLBACK;
