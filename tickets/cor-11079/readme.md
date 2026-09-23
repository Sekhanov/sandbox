
There are two main approaches to triggering a Kubernetes cron job and following its execution.

### 1.1 kubectl Approach

##### Precondition:
- installed kubectl CLI utility


The testing was performed on the [aks-dev1-alfa-eastus](https://portal.azure.com/#@intappinc.onmicrosoft.com/resource/subscriptions/11b16e25-0e5f-4e76-87bc-5f2e9adb26df/resourceGroups/aks-dev1-alfa-eastus/providers/Microsoft.ContainerService/managedClusters/aks-dev1-alfa-eastus/overview) AKS cluster in the `reporting` namespace

1. create yaml file for the cornjob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: test-cronjob
  namespace: reporting
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          imagePullSecrets:
            - name: artifactory.play.intapp.com
          containers:
            - name: test-cronjob
              image: artifactory.play.intapp.com/reporting-docker-upstreams-dev/library/busybox:1.37.0
              command:
                - sh
                - -c
                - "echo 'Job started'; sleep 60; echo 'Job finished after 1 minute'"
```

2. apply cronjob in the cluster

```sh
kubectl apply -f test-cronjob.yaml
```

3. run the script

```sh
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
```

This approach is preferable when the script runs from a context where Kubernetes authentication is already available, e.g.:
- A pod running in the same namespace as the CronJob.
- An Azure DevOps pipeline. For example, the job in the Reporting project below is implemented using this approach: https://dev.azure.com/intappdevops/Reporting/_git/sisense-cicd?path=/.azure-devops/utils/execute-kubectl-command.yaml

4. remove the cronjob
```sh
kubectl delete cronjob test-cronjob -n reporting
```

---

### 2 Argo Workflows REST API Approach

Interacting directly with the argo-server REST API allows language-agnostic triggers and status tracking.

##### Precondition:
- installed argocd, curl CLIs

The testing was performed on https://argo-cd.play.intapp.com/ argo-cd server in the `reporting-management-service-aks-dev1-alfa-eastus-reporting` Argo-cd application

1. create new cronJob in the context of tested Argo-cd application

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: test-cronjob
  namespace: reporting
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          imagePullSecrets:
            - name: artifactory.play.intapp.com
          containers:
            - name: test-cronjob
              image: artifactory.play.intapp.com/reporting-docker-upstreams-dev/library/busybox:1.37.0
              command:
                - sh
                - -c
                - "echo 'Job started'; sleep 60; echo 'Job finished after 1 minute'"
```

2. Create `ARGO_TOKEN` env var
   - login to argo cd server `argocd login argo-cd.play.intapp.com --sso`
   - print received token `cat ~/.config/argocd/config`
   - put the token into envVar `export <your_auth-token>`

3. Run the script

```shell
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
```

4. Remove the cronJob created on the step 1 in the context of tested Argo-cd application
