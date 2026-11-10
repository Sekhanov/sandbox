-- Reads the restriction rules of one client from the central database rulesenginedb. Read-only.
-- Replace <CLIENT_ID> with the client ID in both queries.

-- 1. Check: client_found and has_rules must both be true. If has_rules is false, the client has nothing to check.
SELECT count(*) = 1 AS client_found,
       COALESCE(bool_and(jsonb_array_length(COALESCE(tc.parameters -> 'RESTRICTION_RULE', '[]'::jsonb)) > 0), false) AS has_rules
FROM rulesenginedb.clients_v2 c
LEFT JOIN rulesenginedb.trade_configs_v2 tc
       ON tc.version = c.trade_config_version   -- the active configuration of the client
      AND lower(tc.client_id) = lower(c.id)
WHERE lower(c.id) = lower('lkmo');
-- WHERE lower(c.id) = lower('<CLIENT_ID>');

-- 2. Export: one JSON document. Save it as client_rules.json. Scripts 03 and 04 use its content.
SELECT jsonb_pretty(jsonb_build_object(
           'client_id',              c.id,
           'environment',            c.environment,          -- AWS or AZURE
           'stage',                  c.stage,
           'region',                 c.region,
           'trade_config_version',   c.trade_config_version,
           'trade_config_published', tc.is_published,
           'trade_status_config',    c.trade_status_config,  -- status names of the client
           'restriction_rules',      tc.parameters -> 'RESTRICTION_RULE'))
FROM rulesenginedb.clients_v2 c
JOIN rulesenginedb.trade_configs_v2 tc
  ON tc.version = c.trade_config_version
 AND lower(tc.client_id) = lower(c.id)
WHERE lower(c.id) = lower('lkmo');
-- WHERE lower(c.id) = lower('<CLIENT_ID>');
