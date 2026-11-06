-- Export one client's restriction rule config from the central rulesenginedb. Read-only.
-- Usage (out must be a file path):
--   psql "service=central_ro" -v client_id=ACME -v out=out/ACME/client_rules.json -f 02_central_export_client_rules.sql
-- Active trade config = clients_v2.trade_config_version (same as TradeConfigRepository isActive filter).
\set ON_ERROR_STOP on
\if :{?client_id} \else \echo 'Missing -v client_id' \quit \endif
\if :{?out} \else \echo 'Missing -v out' \quit \endif
BEGIN TRANSACTION READ ONLY;

SELECT count(*) = 1 AS client_found,
       COALESCE(bool_and(jsonb_array_length(COALESCE(tc.parameters -> 'RESTRICTION_RULE', '[]'::jsonb)) > 0), false) AS has_rules
FROM rulesenginedb.clients_v2 c
LEFT JOIN rulesenginedb.trade_configs_v2 tc
       ON tc.version = c.trade_config_version
      AND lower(tc.client_id) = lower(c.id)
WHERE lower(c.id) = lower(:'client_id') \gset
\if :client_found \else \echo 'Client not found:' :'client_id' \quit \endif
\if :has_rules \else \echo 'No RESTRICTION_RULE in the active trade config of' :'client_id' '- nothing to detect' \quit \endif

\pset format unaligned
\pset tuples_only on
\o :out
SELECT jsonb_pretty(jsonb_build_object(
           'client_id',              c.id,
           'environment',            c.environment,
           'stage',                  c.stage,
           'region',                 c.region,
           'trade_config_version',   c.trade_config_version,
           'trade_config_published', tc.is_published,
           'trade_status_config',    c.trade_status_config,
           'restriction_rules',      tc.parameters -> 'RESTRICTION_RULE'))
FROM rulesenginedb.clients_v2 c
JOIN rulesenginedb.trade_configs_v2 tc
  ON tc.version = c.trade_config_version
 AND lower(tc.client_id) = lower(c.id)
WHERE lower(c.id) = lower(:'client_id');
\o

ROLLBACK;
