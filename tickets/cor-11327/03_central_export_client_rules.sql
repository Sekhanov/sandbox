-- Central DB, read-only. The client's active restriction rules and status names. Save as client_rules.json.
-- No row: the client does not exist. restriction_rules null: nothing to check.
SELECT jsonb_pretty(jsonb_build_object(
           'client_id',           c.id,
           'environment',         c.environment,
           'region',              c.region,
           'trade_status_config', c.trade_status_config,
           'restriction_rules',   tc.parameters -> 'RESTRICTION_RULE',
           'sic_rules',           tc.parameters -> 'SIC_RULES'))
FROM rulesenginedb.clients_v2 c
JOIN rulesenginedb.trade_configs_v2 tc ON tc.version = c.trade_config_version AND lower(tc.client_id) = lower(c.id)
WHERE lower(c.id) = lower('<CLIENT_ID>');
