-- SMA DB, read-only. Chains of ID changes (abc -> def -> xyz). Must be 0: the scripts cover single changes only.
SELECT count(*) AS chained_changes
FROM sym_merged_entity_id a
JOIN sym_merged_entity_id b ON b.merged_factset_entity_id = a.to_factset_entity_id
WHERE a.merged_factset_entity_id <> a.to_factset_entity_id
  AND b.merged_factset_entity_id <> b.to_factset_entity_id;
