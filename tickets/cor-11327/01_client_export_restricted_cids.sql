-- Client DB, read-only. Every CID a restriction ever had: live, edited (inactive) and deleted (migdb.deleted_*).
-- Result 1: format check (rows with spaces or lowercase do not match SMA). Result 2: save as restricted_cids.csv.
CREATE TEMP VIEW restriction_cid AS
SELECT DISTINCT a.attribute_value AS cid
FROM (SELECT disc_id, disc_type FROM disclosures UNION SELECT disc_id, disc_type FROM migdb.deleted_disclosures) d
JOIN disclosure_types dt ON dt.disc_type_id = d.disc_type AND dt.disc_type = 'RESTRICTION'
JOIN (SELECT attribute_id, attribute_extra_type_id, attribute_value FROM attribute_extra
      UNION SELECT attribute_id, attribute_extra_type_id, attribute_value FROM migdb.deleted_attribute_extra) a ON a.attribute_id = d.disc_id
JOIN attribute_extra_types t ON t.attribute_extra_type_id = a.attribute_extra_type_id AND t.attribute_type = 'CID';

SELECT count(*) AS cids, count(*) FILTER (WHERE cid <> upper(btrim(cid))) AS bad_format FROM restriction_cid;
SELECT cid FROM restriction_cid ORDER BY cid;
