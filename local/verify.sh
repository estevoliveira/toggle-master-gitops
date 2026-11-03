#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${FLOCI_LAB_STATE:-$HOME/.toggle-floci-lab}/kubeconfig"
k() { kubectl --context kind-toggle-floci "$@"; }
curl -fsS http://localhost:3000/api/health >/dev/null
curl -fsS http://localhost:8080/healthz >/dev/null
bash "$ROOT/local/lab.sh" demo start
k -n toggle-master wait --for=condition=Ready pod -l job-name=fase4-demo --timeout=120s
for ((i=0;i<45;i++)); do
  if k -n toggle-master logs job/fase4-demo | grep -q '"status": 200'; then break; fi
  sleep 2
done
k -n toggle-master logs job/fase4-demo | grep -q '"status": 200'
# Verify the full asynchronous path: evaluation -> SQS -> analytics -> DynamoDB.
for ((i=0;i<45;i++)); do
  count="$(k -n toggle-master exec deployment/floci -- env AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url http://localhost:4566 dynamodb scan --table-name user-events --select COUNT --query Count --output text)"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then break; fi
  sleep 2
done
(( count > 0 ))
python3 "$ROOT/local/check_signals.py"
before="$(k -n toggle-master get deployment evaluation-service -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')"
bash "$ROOT/local/lab.sh" demo fail
for ((i=0;i<90;i++)); do
  after="$(k -n toggle-master get deployment evaluation-service -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')"
  if [[ -n "$after" && "$after" != "$before" ]]; then break; fi
  sleep 3
done
[[ -n "$after" && "$after" != "$before" ]]
k -n toggle-master rollout status deployment/evaluation-service --timeout=120s
k -n observability logs deployment/self-healer | grep -q restart_requested
sleep 5
k -n toggle-master logs job/fase4-demo --tail=3 | grep -q '"status": 200'
echo 'Verified: HTTP 200 -> SQS -> DynamoDB; injected failure -> Grafana alert -> automatic restart -> HTTP 200.'
echo 'Commercial APM, PagerDuty and Discord remain separate checks with real credentials.'
