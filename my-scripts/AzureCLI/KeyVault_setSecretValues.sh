#!/bin/bash

# Define your Azure Key Vault and secrets
keyVaultName="reporting13bjqz1801fzkoi"
secrets=(
reporting-dev-eastus-pendo-service-track-event-secret-key
  "reporting-dev-eastus-pendo-service-integration-key:7b44d47a-e806-45da-6795-b8697479f51c.us"
  "reporting-dev-eastus-pendo-service-track-event-secret-key:0a41f5f7-0046-4b6f-7e36-66df27795836"
)

# Authenticate with Azure CLI (if not already authenticated)
# az login

# Loop through the secrets and set their values
for secret in "${secrets[@]}"; do
  secretName="${secret%%:*}"
  secretValue="${secret##*:}"

  az keyvault secret set --name "$secretName" --vault-name "$keyVaultName" --value "$secretValue"

  if [ $? -eq 0 ]; then
    echo "Secret '$secretName' set successfully."
  else
    echo "Failed to set secret '$secretName'."
  fi
done