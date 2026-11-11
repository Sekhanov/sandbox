-- SMA DB, read-only. Securities whose other entity ID (one ID change) is a restricted CID. Save as security_hist_entity.csv.
-- Input: temp table restricted_cids (cid) from script 01.
-- engine_entity_id: the security's entity ID now, which the engine checked. historical_entity_id: the restricted ID it missed.
WITH pairs AS (
    SELECT merged_factset_entity_id AS historical_entity_id, to_factset_entity_id AS engine_entity_id, merge_date
    FROM sym_merged_entity_id WHERE merged_factset_entity_id IN (SELECT cid FROM restricted_cids)
    UNION
    SELECT to_factset_entity_id, merged_factset_entity_id, merge_date
    FROM sym_merged_entity_id WHERE to_factset_entity_id IN (SELECT cid FROM restricted_cids)
)
SELECT s.fsym_id AS security_id, p.* FROM pairs p JOIN all_securities s ON s.entity_id = p.engine_entity_id
WHERE p.historical_entity_id <> p.engine_entity_id
UNION
SELECT s.security_id, p.* FROM pairs p JOIN security_info s ON s.cid = p.engine_entity_id
WHERE p.historical_entity_id <> p.engine_entity_id;
