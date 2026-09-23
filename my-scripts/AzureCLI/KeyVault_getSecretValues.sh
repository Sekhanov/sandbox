#!/bin/bash
vault_name="reporting13bjqz1801fzkoi" # dev"
#vault_name=""reportingl0zm0nnywuu9swv" # qa"
key_names_list=(


"reporting-dev-eastus-multitenant-db-admin-password"
"reporting-dev-eastus-multitenant-db-admin-role"
"reporting-dev-eastus-multitenant-db-dba-password"
"reporting-dev-eastus-multitenant-db-endpoint"
"reporting-dev-eastus-multitenant-db-intapp-sql-runner-password"
"reporting-dev-eastus-multitenant-db-intapp-sql-runner-role"
"reporting-dev-eastus-multitenant-db-master-password"
"reporting-dev-eastus-multitenant-db-master-role"
"reporting-dev-eastus-multitenant-db-port"
"reporting-dev-eastus-multitenant-db-postgres-exporter-password"
"reporting-dev-eastus-multitenant-db-reader-password"
"reporting-dev-eastus-multitenant-db-reader-role"
"reporting-dev-eastus-multitenant-db-writer-password"
"reporting-dev-eastus-multitenant-db-writer-role"







    )

for key_name in "${key_names_list[@]}"; do
  value=$(az keyvault secret show --name "$key_name" --vault-name "$vault_name" --query 'value' --output tsv)
  echo "Key: $key_name, Value: $value"
done




