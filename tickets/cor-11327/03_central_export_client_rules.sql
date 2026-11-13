-- Central DB, read-only. Input: --client. Output: client_rules.json (for 04).
-- The client's active restriction rules, SIC rules and status names. No row: unknown client.
-- Result columns:
--   rules - JSON: trade_status_config (status key -> status name),
--           restriction_rules (in engine order), sic_rules
SELECT jsonb_strip_nulls(jsonb_build_object('trade_status_config', client.trade_status_config,
                          'restriction_rules', trade_config.parameters -> 'RESTRICTION_RULE',
                          'sic_rules', trade_config.parameters -> 'SIC_RULES')) AS rules -- strip: a missing key stays missing, not JSON null
FROM rulesenginedb.clients_v2 client
JOIN rulesenginedb.trade_configs_v2 trade_config
    ON trade_config.version = client.trade_config_version AND lower(trade_config.client_id) = lower(client.id)
WHERE lower(client.id) = lower(current_setting('missed_restriction.client_id'));
