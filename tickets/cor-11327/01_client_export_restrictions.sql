-- Client DB, read-only. Output: restrictions.json (for 02, 04).
-- Every CID the client's restrictions ever had: live, edited (inactive) and deleted
-- (the app copies deleted restrictions to migdb.deleted_* in the same DB).
-- Deleted ones count: a restriction deleted later could still be active on the trade date. Two kinds:
--   hard-deleted (before AWS2609): removed from the live tables, only the migdb copy is left;
--   soft-deleted (since AWS2609): migdb copy + live rows with is_active = false, so they are in both parts.
-- Result columns:
--   disc_id             - the restriction
--   cid                 - company ID on it (FactSet entity ID)
--   restriction_deleted - true: deleted in the app (copy in migdb)
WITH cid_type AS (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID'),
restriction_type AS (SELECT disc_type_id FROM disclosure_types WHERE disc_type = 'RESTRICTION')
SELECT rcid.disc_id, rcid.cid,
       bool_or(rcid.deleted) AS restriction_deleted -- soft-deleted ones are in both parts
FROM (SELECT attr.attribute_id AS disc_id, attr.attribute_value AS cid, false AS deleted -- live
      FROM attribute_extra attr
      JOIN disclosures disclosure ON disclosure.disc_id = attr.attribute_id
      WHERE attr.attribute_extra_type_id IN (SELECT * FROM cid_type)
        AND disclosure.disc_type IN (SELECT * FROM restriction_type)
      UNION ALL
      SELECT attr.attribute_id, attr.attribute_value, true -- deleted
      FROM migdb.deleted_attribute_extra attr
      JOIN migdb.deleted_disclosures disclosure ON disclosure.disc_id = attr.attribute_id
      WHERE attr.attribute_extra_type_id IN (SELECT * FROM cid_type)
        AND disclosure.disc_type IN (SELECT * FROM restriction_type)) rcid
GROUP BY rcid.disc_id, rcid.cid
ORDER BY rcid.cid, rcid.disc_id;
