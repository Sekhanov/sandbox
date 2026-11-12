-- Client DB, read-only. Output: restricted_cids.json (for 02).
-- All company IDs (CID) the client ever restricted: live, edited (inactive) and deleted
-- (the app copies deleted restrictions to migdb.deleted_* in the same DB).
-- Reads only CID rows (index on the type) and joins each to its disclosure by id.
-- Result columns:
--   cid - restricted company ID (FactSet entity ID), one row per ID
WITH cid_type AS (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID'),
restriction_type AS (SELECT disc_type_id FROM disclosure_types WHERE disc_type = 'RESTRICTION')
SELECT a.attribute_value AS cid
FROM attribute_extra a JOIN disclosures d ON d.disc_id = a.attribute_id
WHERE a.attribute_extra_type_id IN (SELECT * FROM cid_type) AND d.disc_type IN (SELECT * FROM restriction_type)
UNION
SELECT a.attribute_value
FROM migdb.deleted_attribute_extra a JOIN migdb.deleted_disclosures d ON d.disc_id = a.attribute_id
WHERE a.attribute_extra_type_id IN (SELECT * FROM cid_type) AND d.disc_type IN (SELECT * FROM restriction_type)
ORDER BY cid;
