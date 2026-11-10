-- Lists the affected securities and the old entity IDs of their company. Read-only. Runs on the SMA database.
-- Affected security: its company has entity IDs that the SMA did not return, so the engine processed
-- its trades without checking them. Securities of companies without merges are not read.
-- Save the result as security_hist_entity.csv (with a header row). Script 03 loads it for every client of the region.
-- Output columns:
--   security_id          the security
--   sma_entity_id        the entity ID that the SMA returns (the only ID the engine checked before the fix)
--   current_entity_id    the surviving ID at the end of the merge chain
--   historical_entity_id an old ID of the same company; the engine did not check it before the fix
--   merge_date           the date when historical_entity_id was merged
--   depth                merge steps from historical_entity_id to current_entity_id (0 = the current ID itself)

WITH RECURSIVE walk AS (
    -- Start: every merge "old ID -> new ID" (self-merges skipped).
    SELECT merged_factset_entity_id::text                                    AS historical_entity_id,
           to_factset_entity_id::text                                        AS current_entity_id,
           merge_date,
           1                                                                 AS depth,
           ARRAY[merged_factset_entity_id::text, to_factset_entity_id::text] AS path
    FROM sym_merged_entity_id
    WHERE merged_factset_entity_id <> to_factset_entity_id
    UNION ALL
    -- Next step: the new ID was merged again. The path array stops loops.
    SELECT w.historical_entity_id,
           m.to_factset_entity_id::text,
           w.merge_date,
           w.depth + 1,
           w.path || m.to_factset_entity_id::text
    FROM walk w
    JOIN sym_merged_entity_id m ON m.merged_factset_entity_id = w.current_entity_id
    WHERE m.to_factset_entity_id::text <> ALL (w.path)
),
terminal AS (
    -- For each old ID, keep the last step: its surviving ID.
    SELECT DISTINCT ON (historical_entity_id) historical_entity_id, current_entity_id, merge_date, depth
    FROM walk
    ORDER BY historical_entity_id, depth DESC
),
chain AS (
    -- All IDs of each surviving company: its old IDs, plus the surviving ID itself (depth 0).
    SELECT current_entity_id, historical_entity_id AS entity_id, merge_date, depth FROM terminal
    UNION ALL
    SELECT DISTINCT current_entity_id, current_entity_id, NULL::date, 0 FROM terminal
),
securities AS (
    -- Affected securities only: FactSet and custom securities whose entity ID is part of a merge chain.
    -- Other securities have one entity ID, so the engine missed nothing for them. UNION removes duplicate pairs.
    SELECT fsym_id::text AS security_id, entity_id::text AS entity_id
    FROM all_securities
    WHERE entity_id::text IN (SELECT entity_id FROM chain)
    UNION
    SELECT security_id::text, cid::text
    FROM security_info
    WHERE cid::text IN (SELECT entity_id FROM chain)
),
resolved AS (
    -- The surviving ID of each security (its own entity ID if that was never merged).
    SELECT s.security_id, s.entity_id AS sma_entity_id, COALESCE(t.current_entity_id, s.entity_id) AS current_entity_id
    FROM securities s
    LEFT JOIN terminal t ON t.historical_entity_id = s.entity_id
)
-- One row per security and each ID of its company that the SMA does not return.
SELECT r.security_id,
       r.sma_entity_id,
       c.current_entity_id,
       c.entity_id AS historical_entity_id,
       c.merge_date,
       c.depth
FROM resolved r
JOIN chain c ON c.current_entity_id = r.current_entity_id
WHERE c.entity_id <> r.sma_entity_id;
