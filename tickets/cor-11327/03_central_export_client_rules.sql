-- Central DB, read-only. Input: --client. Output: client_rules.json (for 04, 05).
-- The client's active restriction rules, SIC rules and status names. No row: unknown client.
-- Result columns:
--   rules - JSON: client_id, trade_status_config (status key -> status name),
--           restriction_rules (in engine order), sic_rules
SELECT jsonb_build_object(
           'client_id',           c.id,
           'trade_status_config', c.trade_status_config,
           'restriction_rules',   tc.parameters -> 'RESTRICTION_RULE',
           'sic_rules',           tc.parameters -> 'SIC_RULES') AS rules
FROM rulesenginedb.clients_v2 c
JOIN rulesenginedb.trade_configs_v2 tc ON tc.version = c.trade_config_version AND lower(tc.client_id) = lower(c.id)
WHERE lower(c.id) = lower(current_setting('cor11327.client_id'));
