-- SMA, read-only. Run once per region.
-- FactSet can replace a company's entity ID (old -> new). The scripts handle one change only,
-- so chained_changes (abc -> def -> xyz) must be 0.
SELECT count(*) AS chained_changes
FROM sym_merged_entity_id a
JOIN sym_merged_entity_id b ON b.merged_factset_entity_id = a.to_factset_entity_id  -- a's new ID was changed again by b
WHERE a.merged_factset_entity_id <> a.to_factset_entity_id                           -- ignore rows where old = new
  AND b.merged_factset_entity_id <> b.to_factset_entity_id;
