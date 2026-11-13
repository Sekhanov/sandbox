-- SMA, read-only. Input: restrictions.json (01). Output: security_hist_entity.json (for 04).
-- Securities whose CID differs from the restriction's CID because FactSet changed the company's CID (A1 -> B2).
-- The engine searched restrictions only by the security's CID, so it missed the restriction.
-- Result columns:
--   security_id    - the security (FactSet fsym_id or local security_id)
--   restricted_cid - CID stored on the restriction
--   security_cid   - CID of the security in SMA; the engine searched by this one
--   merge_date     - date of the CID change
WITH restricted AS (SELECT DISTINCT cid FROM jsonb_to_recordset(current_setting('missed_restriction.restrictions')::jsonb) AS x(cid text)),
pairs AS (
    -- the restriction has the old CID (A1), the security now has the new CID (B2)
    SELECT merged_factset_entity_id AS restricted_cid, to_factset_entity_id AS security_cid, merge_date
    FROM sym_merged_entity_id
    WHERE merged_factset_entity_id IN (SELECT cid FROM restricted)
    UNION
    -- the restriction has the new CID (B2), the security still has the old CID (A1)
    SELECT to_factset_entity_id, merged_factset_entity_id, merge_date
    FROM sym_merged_entity_id
    WHERE to_factset_entity_id IN (SELECT cid FROM restricted))
SELECT s.fsym_id AS security_id, p.*
FROM pairs p
JOIN all_securities s ON s.entity_id = p.security_cid
UNION
SELECT s.security_id, p.*
FROM pairs p
JOIN security_info s ON s.cid = p.security_cid;
