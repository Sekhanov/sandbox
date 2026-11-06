-- Export security -> every other entity id of its merged-entity chain from the SMA RDS. Read-only.
-- Tenant-agnostic reference data; output feeds 03 for every client of the same region.
-- Usage: psql "service=sma_ro" -f 01_sma_export_security_hist_entity.sql   (writes ./security_hist_entity.csv)
-- UNION (not UNION ALL) in "securities" drops duplicate (security, entity) pairs across both sources.
-- FETCH_COUNT streams the result through a cursor instead of holding it in psql memory.
-- VERIFY: the CSV header appears only once with FETCH_COUNT (grep -c '^security_id,' security_hist_entity.csv).
-- Columns:
--   sma_entity_id        entity_id SMA returns for the security (what the pre-fix engine checked)
--   current_entity_id    surviving id at the end of the chain
--   historical_entity_id another id of the same chain; depth = hops to the surviving id
--                        (depth 0 = the surviving id itself, listed only when sma_entity_id is stale)
--   merge_date           date historical_entity_id was merged
-- VERIFY: tables resolve through the SMA user's search_path (public), as in compliance-security-master/utils/queries.ts.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
\pset format csv
\set FETCH_COUNT 10000
\o security_hist_entity.csv

WITH RECURSIVE walk AS (
    SELECT merged_factset_entity_id::text                                       AS historical_entity_id,
           to_factset_entity_id::text                                           AS current_entity_id,
           merge_date,
           1                                                                    AS depth,
           ARRAY[merged_factset_entity_id::text, to_factset_entity_id::text]    AS path
    FROM sym_merged_entity_id
    WHERE merged_factset_entity_id <> to_factset_entity_id
    UNION ALL
    SELECT w.historical_entity_id,
           m.to_factset_entity_id::text,
           w.merge_date,
           w.depth + 1,
           w.path || m.to_factset_entity_id::text
    FROM walk w
    JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = w.current_entity_id
    WHERE m.to_factset_entity_id::text <> ALL (w.path)   -- cycle guard
),
terminal AS (
    -- The deepest hop is the surviving entity.
    SELECT DISTINCT ON (historical_entity_id) historical_entity_id, current_entity_id, merge_date, depth
    FROM walk
    ORDER BY historical_entity_id, depth DESC
),
chain AS (
    SELECT current_entity_id, historical_entity_id AS entity_id, merge_date, depth FROM terminal
    UNION ALL
    SELECT DISTINCT current_entity_id, current_entity_id, NULL::date, 0 FROM terminal
),
securities AS (
    SELECT fsym_id::text AS security_id, entity_id::text AS entity_id FROM all_securities WHERE entity_id IS NOT NULL
    UNION
    SELECT security_id::text, cid::text FROM security_info WHERE cid IS NOT NULL
),
resolved AS (
    SELECT s.security_id, s.entity_id AS sma_entity_id, COALESCE(t.current_entity_id, s.entity_id) AS current_entity_id
    FROM securities s
    LEFT JOIN terminal t ON t.historical_entity_id = s.entity_id
)
SELECT r.security_id,
       r.sma_entity_id,
       c.current_entity_id,
       c.entity_id AS historical_entity_id,
       c.merge_date,
       c.depth
FROM resolved r
JOIN chain c ON c.current_entity_id = r.current_entity_id
WHERE c.entity_id <> r.sma_entity_id;

\o
ROLLBACK;
