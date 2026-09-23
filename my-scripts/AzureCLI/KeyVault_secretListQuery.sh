#!/bin/bash
# List Key Vault secret names matching a substring.
#
# NOTE: this vault has ~3700 secrets. `az keyvault secret list` pages through
# all of them and can intermittently return a PARTIAL set when throttled, which
# makes a client-side --query filter look like it "found nothing". The retry
# loop below guards against that: it re-runs until matches are found (or it
# gives up after N attempts).

set -euo pipefail

vault_name="reporting13bjqz1801fzkoi"   # dev¡
#vault_name="reportingl0zm0nnywuu9swv"  # qa

filter="reporting-dev-eastus-multitenant-db"                       # substring to match in secret names
query="[?contains(name, '${filter}')].name"

max_attempts=5
attempt=1

while (( attempt <= max_attempts )); do
  echo "Attempt ${attempt}/${max_attempts}: listing secrets matching '${filter}'..." >&2

  names=$(az keyvault secret list \
            --vault-name "$vault_name" \
            --query "$query" \
            --output tsv 2>/dev/null || true)

  if [[ -n "$names" ]]; then
    echo "$names" | sort
    count=$(echo "$names" | grep -c .)
    echo "Found ${count} secret(s)." >&2
    exit 0
  fi

  echo "No matches this attempt (possibly a throttled/partial list); retrying..." >&2
  ((attempt++))
  sleep 3
done

echo "No secrets matching '${filter}' after ${max_attempts} attempts." >&2
exit 1
