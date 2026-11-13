-- SMA, read-only. Input: restrictions.json (01). Output: security_hist_entity.json (for 04).
-- Securities whose CID differs from the restriction's CID because FactSet changed the company's CID (A1 -> B2).
-- The engine searched restrictions only by the security's CID, so it missed the restriction.
-- Result columns:
--   security_id    - the security (FactSet fsym_id or local security_id)
--   restricted_cid - CID stored on the restriction
--   security_cid   - CID of the security in SMA; the engine searched by this one
--   merge_date     - date of the CID change
WITH restricted_cids AS (
    SELECT DISTINCT restriction.cid
    FROM jsonb_to_recordset(current_setting('missed_restriction.restrictions')::jsonb) AS restriction(cid text)),
cid_changes AS (
    -- the restriction has the old CID (A1), the security now has the new CID (B2)
    SELECT cid_change.merged_factset_entity_id AS restricted_cid, cid_change.to_factset_entity_id AS security_cid, cid_change.merge_date
    FROM sym_merged_entity_id cid_change
    WHERE cid_change.merged_factset_entity_id IN (SELECT cid FROM restricted_cids)
    UNION
    -- the restriction has the new CID (B2), the security still has the old CID (A1)
    SELECT id_change.to_factset_entity_id, id_change.merged_factset_entity_id, id_change.merge_date
    FROM sym_merged_entity_id id_change
    WHERE id_change.to_factset_entity_id IN (SELECT cid FROM restricted_cids))
SELECT security.fsym_id AS security_id, cid_changes.*
FROM cid_changes
JOIN all_securities security ON security.entity_id = cid_changes.security_cid
UNION
SELECT security.security_id, cid_changes.*
FROM cid_changes
JOIN security_info security ON security.cid = cid_changes.security_cid;
