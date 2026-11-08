-- Measures the FactSet merge history on the SMA database. Read-only.
-- Run each query separately and note the results.

-- 1. Size of the merge table: how many old IDs were merged, into how many surviving IDs, and over which period.
SELECT count(*)                             AS merged_ids,
       count(DISTINCT to_factset_entity_id) AS surviving_ids,
       min(merge_date)                      AS first_merge,
       max(merge_date)                      AS last_merge
FROM sym_merged_entity_id;

-- 2. Merges whose target ID was merged again later (X -> Y, then Y -> Z).
--    A result above 0 means chains of more than one step exist. The COR-11307 fix still misses them.
SELECT count(*) AS multi_hop_edges
FROM sym_merged_entity_id a
JOIN sym_merged_entity_id b ON b.merged_factset_entity_id = a.to_factset_entity_id;

-- 3. Follows every chain to its end: the longest chain, the IDs in chains of more than one step,
--    and the IDs in a loop (X -> Y -> X, a data error).
WITH RECURSIVE walk AS (
    -- Start: one row per merge.
    SELECT merged_factset_entity_id::text                  AS start_id,
           to_factset_entity_id::text                      AS cur_id,
           1                                               AS depth,
           ARRAY[merged_factset_entity_id::text]           AS path,
           merged_factset_entity_id = to_factset_entity_id AS is_cycle
    FROM sym_merged_entity_id
    UNION ALL
    -- Next step: the current ID was merged again. Stop when an ID repeats (loop).
    SELECT w.start_id,
           m.to_factset_entity_id::text,
           w.depth + 1,
           w.path || w.cur_id,
           m.to_factset_entity_id::text = ANY (w.path || w.cur_id)
    FROM walk w
    JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = w.cur_id
    WHERE NOT w.is_cycle
)
SELECT max(depth)                                        AS max_depth,
       count(DISTINCT start_id) FILTER (WHERE depth > 1) AS ids_with_multi_hop_chain,
       count(DISTINCT start_id) FILTER (WHERE is_cycle)  AS ids_in_cycles
FROM walk;

-- 4. Securities whose entity ID is itself an old, merged ID (the SMA still returns a retired ID for them).
SELECT (SELECT count(*) FROM all_securities s
        JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = s.entity_id) AS stale_factset_securities,
       (SELECT count(*) FROM security_info si
        JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = si.cid)      AS stale_custom_securities;

-- 5. Approximate number of rows that script 01 returns: securities of entities that absorbed other IDs.
SELECT count(*) AS securities_with_merged_entity
FROM all_securities s
WHERE s.entity_id IN (SELECT to_factset_entity_id FROM sym_merged_entity_id);
