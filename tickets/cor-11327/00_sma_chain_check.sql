-- Profile the FactSet merge table on the SMA RDS before the export. Read-only.
-- Usage: psql "service=sma_ro" -f 00_sma_chain_check.sql
-- VERIFY: tables resolve through the SMA user's search_path (public), as in compliance-security-master/utils/queries.ts.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;

\echo 'Merge table size'
SELECT count(*)                                 AS merged_ids,
       count(DISTINCT to_factset_entity_id)     AS surviving_ids,
       min(merge_date)                          AS first_merge,
       max(merge_date)                          AS last_merge
FROM sym_merged_entity_id;

-- > 0 means chains longer than one hop exist; SMA all_entity_ids (one hop) misses them even after the fix.
\echo 'Merge targets that were merged again'
SELECT count(*) AS multi_hop_edges
FROM sym_merged_entity_id a
JOIN sym_merged_entity_id b ON b.merged_factset_entity_id = a.to_factset_entity_id;

\echo 'Chain depth and cycles'
WITH RECURSIVE walk AS (
    SELECT merged_factset_entity_id::text                    AS start_id,
           to_factset_entity_id::text                        AS cur_id,
           1                                                 AS depth,
           ARRAY[merged_factset_entity_id::text]             AS path,
           merged_factset_entity_id = to_factset_entity_id   AS is_cycle
    FROM sym_merged_entity_id
    UNION ALL
    SELECT w.start_id,
           m.to_factset_entity_id::text,
           w.depth + 1,
           w.path || w.cur_id,
           m.to_factset_entity_id::text = ANY (w.path || w.cur_id)
    FROM walk w
    JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = w.cur_id
    WHERE NOT w.is_cycle
)
SELECT max(depth)                                         AS max_depth,
       count(DISTINCT start_id) FILTER (WHERE depth > 1)  AS ids_with_multi_hop_chain,
       count(DISTINCT start_id) FILTER (WHERE is_cycle)   AS ids_in_cycles
FROM walk;

-- Securities whose own entity_id is already a merged (stale) id.
\echo 'Stale entity ids on securities'
SELECT (SELECT count(*) FROM all_securities s
        JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = s.entity_id) AS stale_factset_securities,
       (SELECT count(*) FROM security_info si
        JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = si.cid)      AS stale_custom_securities;

\echo 'Approximate export size for 01 (securities of entities with merged ids)'
SELECT count(*) AS securities_with_merged_entity
FROM all_securities s
WHERE s.entity_id IN (SELECT to_factset_entity_id FROM sym_merged_entity_id);

ROLLBACK;
