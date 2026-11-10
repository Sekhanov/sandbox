-- SMA DB, read-only. Affected securities: their entity ID is one side of an ID change.
-- historical_entity_id is the other side, which the engine did not check. Save as security_hist_entity.csv.
WITH merges AS (
    SELECT merged_factset_entity_id::text AS old_id, to_factset_entity_id::text AS new_id, merge_date
    FROM sym_merged_entity_id
    WHERE merged_factset_entity_id <> to_factset_entity_id
),
securities AS (  -- FactSet and custom securities
    SELECT fsym_id::text AS security_id, entity_id::text AS entity_id FROM all_securities
    UNION
    SELECT security_id::text, cid::text FROM security_info
)
SELECT s.security_id, m.old_id AS historical_entity_id, m.merge_date  -- security has the new ID
FROM securities s JOIN merges m ON m.new_id = s.entity_id
UNION ALL
SELECT s.security_id, m.new_id, m.merge_date                          -- security still has the old ID
FROM securities s JOIN merges m ON m.old_id = s.entity_id;
