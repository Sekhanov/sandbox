-- SMA, read-only. Input: restricted_cids.json. Output: security_hist_entity.json (for 04).
-- Securities whose restriction the engine missed after an ID change (old A1 -> new B2):
-- engine_entity_id = ID the engine checked, historical_entity_id = restricted ID it missed.
WITH restricted AS (SELECT cid FROM jsonb_to_recordset(current_setting('cor11327.restricted_cids')::jsonb) AS x(cid text)),
pairs AS (
    -- restriction on old ID A1, shares carry B2
    SELECT merged_factset_entity_id AS historical_entity_id, to_factset_entity_id AS engine_entity_id, merge_date
    FROM sym_merged_entity_id
    WHERE merged_factset_entity_id IN (SELECT cid FROM restricted) AND merged_factset_entity_id <> to_factset_entity_id
    UNION
    -- restriction on new ID B2, shares still carry A1
    SELECT to_factset_entity_id, merged_factset_entity_id, merge_date
    FROM sym_merged_entity_id
    WHERE to_factset_entity_id IN (SELECT cid FROM restricted) AND merged_factset_entity_id <> to_factset_entity_id
)
SELECT s.fsym_id AS security_id, p.* FROM pairs p JOIN all_securities s ON s.entity_id = p.engine_entity_id
UNION
SELECT s.security_id, p.* FROM pairs p JOIN security_info s ON s.cid = p.engine_entity_id;
