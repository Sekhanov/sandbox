-- SMA DB, read-only. Size of the FactSet ID changes (old ID -> new ID).

-- Merges and their period.
SELECT count(*) AS merges, min(merge_date) AS first_merge, max(merge_date) AS last_merge
FROM sym_merged_entity_id
WHERE merged_factset_entity_id <> to_factset_entity_id;

-- Chains (abc -> def -> xyz). Must be 0: the scripts cover single changes only.
SELECT count(*) AS chained_changes
FROM sym_merged_entity_id a
JOIN sym_merged_entity_id b ON b.merged_factset_entity_id = a.to_factset_entity_id
WHERE a.merged_factset_entity_id <> a.to_factset_entity_id
  AND b.merged_factset_entity_id <> b.to_factset_entity_id;
