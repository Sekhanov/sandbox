-- Client DB, read-only. Every CID a restriction ever had: live, edited (inactive) and deleted (migdb.deleted_*).
-- Save as restricted_cids.csv. bad_format = true: spaces or lowercase, will not match SMA.
SELECT DISTINCT a.attribute_value AS cid, a.attribute_value <> upper(btrim(a.attribute_value)) AS bad_format
FROM (SELECT disc_id, disc_type FROM disclosures UNION SELECT disc_id, disc_type FROM migdb.deleted_disclosures) d
JOIN disclosure_types dt ON dt.disc_type_id = d.disc_type AND dt.disc_type = 'RESTRICTION'
JOIN (SELECT attribute_id, attribute_extra_type_id, attribute_value FROM attribute_extra
      UNION SELECT attribute_id, attribute_extra_type_id, attribute_value FROM migdb.deleted_attribute_extra) a ON a.attribute_id = d.disc_id
JOIN attribute_extra_types t ON t.attribute_extra_type_id = a.attribute_extra_type_id AND t.attribute_type = 'CID'
ORDER BY bad_format DESC, cid;
