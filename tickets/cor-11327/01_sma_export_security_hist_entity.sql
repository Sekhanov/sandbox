-- Lists the affected securities and the other entity ID of their company. Read-only. Runs on the SMA database.
-- Affected security: its company changed its entity ID once (old ID -> new ID), and the engine checked only
-- the ID that the SMA returned for the security. Chains of changes (old -> new -> newer) are not considered.
-- Save the result as security_hist_entity.csv (with a header row). Script 03 loads it for every client of the region.
-- Output columns:
--   security_id          the security
--   sma_entity_id        the entity ID that the SMA returns (the only ID the engine checked before the fix)
--   current_entity_id    the new ID of the change
--   historical_entity_id the other ID of the change; the engine did not check it before the fix
--   merge_date           the date of the change

WITH merges AS (
    -- One ID change: old ID -> new ID (self-merges skipped).
    SELECT merged_factset_entity_id::text AS old_id, to_factset_entity_id::text AS new_id, merge_date
    FROM sym_merged_entity_id
    WHERE merged_factset_entity_id <> to_factset_entity_id
),
securities AS (
    -- FactSet securities and custom securities with their entity. UNION removes duplicate pairs.
    SELECT fsym_id::text AS security_id, entity_id::text AS entity_id FROM all_securities WHERE entity_id IS NOT NULL
    UNION
    SELECT security_id::text, cid::text FROM security_info WHERE cid IS NOT NULL
)
-- The security has the new ID: the engine missed restrictions on the old ID.
SELECT s.security_id, s.entity_id AS sma_entity_id, m.new_id AS current_entity_id, m.old_id AS historical_entity_id, m.merge_date
FROM securities s
JOIN merges m ON m.new_id = s.entity_id
UNION ALL
-- The security still has the old ID: the engine missed restrictions on the new ID.
SELECT s.security_id, s.entity_id, m.new_id, m.new_id, m.merge_date
FROM securities s
JOIN merges m ON m.old_id = s.entity_id;
