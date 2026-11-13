-- Client DB, read-only. Output: restrictions.json (for 02, 04).
-- Every CID the client's restrictions ever had: live, edited (inactive) and deleted
-- (the app copies deleted restrictions to migdb.deleted_* in the same DB).
-- Result columns:
--   disc_id             - the restriction
--   cid                 - company ID on it (FactSet entity ID)
--   restriction_deleted - true: deleted in the app (copy in migdb)
WITH cid_type AS (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID'),
restriction_type AS (SELECT disc_type_id FROM disclosure_types WHERE disc_type = 'RESTRICTION')
SELECT disc_id, cid, bool_or(deleted) AS restriction_deleted -- soft-deleted ones are in both parts
FROM (SELECT a.attribute_id AS disc_id, a.attribute_value AS cid, false AS deleted -- live
      FROM attribute_extra a
      JOIN disclosures d ON d.disc_id = a.attribute_id
      WHERE a.attribute_extra_type_id IN (SELECT * FROM cid_type)
        AND d.disc_type IN (SELECT * FROM restriction_type)
      UNION ALL
      SELECT a.attribute_id, a.attribute_value, true -- deleted
      FROM migdb.deleted_attribute_extra a
      JOIN migdb.deleted_disclosures d ON d.disc_id = a.attribute_id
      WHERE a.attribute_extra_type_id IN (SELECT * FROM cid_type)
        AND d.disc_type IN (SELECT * FROM restriction_type)) x
GROUP BY disc_id, cid
ORDER BY cid, disc_id;
