#!/usr/bin/env bash

set -euo pipefail

# Configuration Variables
APP_NAME="reporting-management-service-aks-dev1-alfa-eastus-reporting"
CRONJOB_NAME="test-cronjob"
ARGO_HOST="https://argo-cd.play.intapp.com"
POLL_INTERVAL=5
MAX_TIMEOUT_SECONDS=600

if [ -z "${ARGO_TOKEN:-}" ]; then
  echo "Error: ARGO_TOKEN environment variable is required." >&2
  exit 1
fi

echo "--> Triggering CronJob execution..."
curl -s --fail --request POST \
  --url "${ARGO_HOST}/api/v1/applications/${APP_NAME}/resource/actions/v2" \
  --header "Authorization: Bearer ${ARGO_TOKEN}" \
  --header "content-type: application/json" \
  --data "{\"name\":\"${APP_NAME}\",\"appNamespace\":\"argocd\",\"project\":\"reporting\",\"namespace\":\"reporting\",\"resourceName\":\"${CRONJOB_NAME}\",\"group\":\"batch\",\"version\":\"v1\",\"kind\":\"CronJob\",\"action\":\"create-job\"}" > /dev/null

echo "--> Job trigger request submitted. Waiting for resource registration..."
sleep 3

ELAPSED=0
while [ $ELAPSED -lt $MAX_TIMEOUT_SECONDS ]; do
  # Fetch latest REST API-created job (matches 10-digit YYMMDDHHMM suffix)
  JOB_NODE=$(curl -s --request GET \
    --url "${ARGO_HOST}/api/v1/applications/${APP_NAME}/resource-tree" \
    --header "Authorization: Bearer ${ARGO_TOKEN}" \
    | jq -c "[.nodes[] | select(.kind==\"Job\" and (.name | test(\"${CRONJOB_NAME}-[0-9]{10}\$\")))] | sort_by(.createdAt) | last")

  if [ "$JOB_NODE" != "null" ] && [ -n "$JOB_NODE" ]; then
    JOB_NAME=$(echo "$JOB_NODE" | jq -r '.name')
    STATUS=$(echo "$JOB_NODE" | jq -r '.health.status // "Unknown"')

    echo "[${ELAPSED}s] Tracking Job: ${JOB_NAME} | Status: ${STATUS}"

    case "$STATUS" in
      "Healthy")
        echo "--> SUCCESS: Job ${JOB_NAME} completed successfully."
        exit 0
        ;;
      "Degraded")
        echo "--> ERROR: Job ${JOB_NAME} failed (Degraded status)." >&2
        exit 1
        ;;
    esac
  else
    echo "[${ELAPSED}s] Waiting for job node to appear in Argo CD resource tree..."
  fi

  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo "--> ERROR: Timeout reached (${MAX_TIMEOUT_SECONDS}s) waiting for job completion." >&2
exit 1