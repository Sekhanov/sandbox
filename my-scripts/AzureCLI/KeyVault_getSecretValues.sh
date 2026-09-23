#!/bin/bash
vault_name="reporting13bjqz1801fzkoi" # dev"
#vault_name=""reportingl0zm0nnywuu9swv" # qa"

# One key name per line, no quotes
key_names_list=$(cat <<'KEYS'

reporting-dev-eastus-pendo-service-domain
reporting-dev-eastus-pendo-service-integration-key
reporting-dev-eastus-pendo-service-track-event-secret-key


KEYS
)

while read -r key_name; do
  [ -z "$key_name" ] && continue
  value=$(az keyvault secret show --name "$key_name" --vault-name "$vault_name" --query 'value' --output tsv)
  echo "Key: $key_name, Value: $value"
done <<< "$key_names_list"
