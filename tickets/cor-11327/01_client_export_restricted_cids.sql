-- Client DB, read-only. Output: restricted_cids.json (for 02).
-- All company IDs (CID) the client ever restricted: live, edited (inactive) and deleted
-- (the app copies deleted restrictions to migdb.deleted_* in the same DB).
SELECT DISTINCT a.attribute_value AS cid
FROM (SELECT disc_id, disc_type FROM disclosures UNION SELECT disc_id, disc_type FROM migdb.deleted_disclosures) d
JOIN disclosure_types dt ON dt.disc_type_id = d.disc_type AND dt.disc_type = 'RESTRICTION'  -- restrictions only
JOIN (SELECT attribute_id, attribute_extra_type_id, attribute_value FROM attribute_extra
      UNION SELECT attribute_id, attribute_extra_type_id, attribute_value FROM migdb.deleted_attribute_extra) a ON a.attribute_id = d.disc_id
JOIN attribute_extra_types t ON t.attribute_extra_type_id = a.attribute_extra_type_id AND t.attribute_type = 'CID'  -- the CID field
ORDER BY cid;
