#!/usr/bin/env bash

set -euo pipefail

# Configuration Variables
NAMESPACE="reporting"
CRONJOB_NAME="test-cronjob"
JOB_NAME="${CRONJOB_NAME}-manual-$(date +%s)"
TIMEOUT="${TIMEOUT:-600s}"

echo "--> Creating job ${JOB_NAME} from cronjob/${CRONJOB_NAME}..."
kubectl create job "${JOB_NAME}" --from="cronjob/${CRONJOB_NAME}" -n "${NAMESPACE}" > /dev/null

echo "--> Waiting up to ${TIMEOUT} for job completion..."

if kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${NAMESPACE}" --timeout="${TIMEOUT}" > /dev/null 2>&1; then
  echo "--> SUCCESS: Job ${JOB_NAME} completed successfully."
  exit 0
else
  echo "--> ERROR: Job ${JOB_NAME} failed or timed out." >&2

  echo "----- Job Status & Events -----"
  kubectl describe "job/${JOB_NAME}" -n "${NAMESPACE}" || true

  echo "----- Pod Logs -----"
  kubectl logs -n "${NAMESPACE}" -l "job-name=${JOB_NAME}" --all-containers --tail=200 || true

  exit 1
fi