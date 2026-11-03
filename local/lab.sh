#!/usr/bin/env bash
set -euo pipefail
set +x
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${FLOCI_LAB_STATE:-$HOME/.toggle-floci-lab}"
mkdir -p "$STATE"
chmod 700 "$STATE"
export KUBECONFIG="$STATE/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=docker
CLUSTER=toggle-floci
REF="${GITOPS_REF:-$(git -C "$ROOT" rev-parse HEAD)}"
REPO=https://github.com/ramondata/toggle-master-gitops.git
umask 077
k() { kubectl --context kind-toggle-floci "$@"; }
check() {
  for dep in docker kind kubectl helm git python3 curl; do
    command -v "$dep" >/dev/null || { echo "Instale $dep antes de continuar."; exit 1; }
  done
  docker info >/dev/null
}
namespace() { k create namespace "$1" --dry-run=client -o yaml | k apply -f -; }
secret() { local ns="$1" name="$2"; shift 2; k -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | k apply -f -; }
wait_app() {
  local name="$1"
  for ((i=0;i<180;i++)); do
    if [[ "$(k -n argocd get application "$name" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" == Synced/Healthy ]]; then return; fi
    sleep 5
  done
  k -n argocd get application "$name" -o yaml
  k get pods -A
  echo "Timeout: estado preservado. Corrija o erro e execute novamente."
  return 1
}
application() {
  local name="$1" path="$2" ns="$3" values="$4"
  cat <<YAML | k apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $REPO
    targetRevision: $REF
    path: $path
    helm:
      values: |
$(printf '%s\n' "$values" | sed 's/^/        /')
  destination:
    server: https://kubernetes.default.svc
    namespace: $ns
  ignoreDifferences:
    - group: apps
      kind: Deployment
      name: evaluation-service
      namespace: toggle-master
      jsonPointers: [/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt]
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true, RespectIgnoreDifferences=true]
YAML
}
build_images() {
  while read -r service revision; do
    local dir="$STATE/sources/$service/$revision" image="toggle-local/$service:$revision"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      if [[ ! -d "$dir/.git" ]]; then
        mkdir -p "$dir"
        git -C "$dir" init -q
        git -C "$dir" remote add origin "https://github.com/ramondata/$service.git"
      fi
      git -C "$dir" fetch --depth 1 origin "$revision"
      git -C "$dir" checkout --detach FETCH_HEAD
      docker build -t "$image" "$dir"
    fi
    kind load docker-image --name "$CLUSTER" "$image"
  done < "$ROOT/local/sources.lock"
}
init_floci() {
  # Explicit endpoint and fake credentials: never calls the real AWS.
  k -n toggle-master exec deployment/floci -- env AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url http://localhost:4566 sqs create-queue --queue-name feature-evaluation-events > "$STATE/queue.json"
  queue="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["QueueUrl"])' "$STATE/queue.json")"
  [[ "$queue" == http://floci.toggle-master.svc.cluster.local:4566/* ]] || { echo 'QueueUrl inesperada; interrompido.'; exit 1; }
  if ! k -n toggle-master exec deployment/floci -- env AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url http://localhost:4566 dynamodb describe-table --table-name user-events >/dev/null 2>&1; then
    k -n toggle-master exec deployment/floci -- env AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
      aws --endpoint-url http://localhost:4566 dynamodb create-table --table-name user-events \
      --attribute-definitions AttributeName=event_id,AttributeType=S --key-schema AttributeName=event_id,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
  fi
  k -n toggle-master create configmap local-aws \
    --from-literal=AWS_ACCESS_KEY_ID=test --from-literal=AWS_SECRET_ACCESS_KEY=test \
    --from-literal=AWS_REGION=us-east-1 --from-literal=AWS_DEFAULT_REGION=us-east-1 \
    --from-literal=AWS_EC2_METADATA_DISABLED=true \
    --from-literal=AWS_ENDPOINT_URL=http://floci.toggle-master.svc.cluster.local:4566 \
    --from-literal=AWS_SQS_URL="$queue" --from-literal=AWS_DYNAMODB_TABLE=user-events \
    --dry-run=client -o yaml | k apply -f -
}
case "${1:-up}" in
  up)
    check
    mem="$(docker info --format '{{.MemTotal}}')"
    if (( mem < 7500000000 )); then
      echo 'Reserve pelo menos 8 GiB de RAM para o Docker (12 GiB se disponivel).'; exit 1
    fi
    if ! kind get clusters | grep -qx "$CLUSTER"; then
      kind create cluster --name "$CLUSTER" --config "$ROOT/local/kind.yaml" \
        --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed --wait 180s
    else
      kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
    fi
    namespace argocd; namespace toggle-master; namespace observability
    if ! k -n argocd get deployment argocd-server >/dev/null 2>&1; then
      k apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml
    fi
    k -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
    k -n argocd patch service argocd-server --type merge -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"nodePort":30080}]}}'
    k -n argocd rollout restart deployment/argocd-server
    k -n argocd rollout status deployment/argocd-server --timeout=300s
    k wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
    # Preserve tokens/passwords across reruns.
    if ! k -n observability get secret grafana-admin >/dev/null 2>&1; then
      python3 -c 'import secrets; print(secrets.token_urlsafe(24),end="")' > "$STATE/grafana-password"
      secret observability grafana-admin --from-literal=admin-user=admin --from-file=admin-password="$STATE/grafana-password"
    fi
    if ! k -n observability get secret fase4-integrations >/dev/null 2>&1; then
      python3 -c 'import secrets; print(secrets.token_urlsafe(32),end="")' > "$STATE/heal-token"
      secret observability fase4-integrations --from-file=heal-token="$STATE/heal-token" \
        --from-literal=new-relic-license-key=disabled --from-literal=pagerduty-routing-key=disabled --from-literal=discord-webhook-url=disabled
    fi
    if ! k -n toggle-master get secret fase4-demo >/dev/null 2>&1; then
      python3 -c 'import secrets; print(secrets.token_urlsafe(32),end="")' > "$STATE/demo-token"
      secret toggle-master fase4-demo --from-file=demo-token="$STATE/demo-token"
    fi
    secret toggle-master academy-databases --from-literal=service-api-key=local-demo-api-key
    # On rerun do not remove already running app Deployments.
    if ! k -n argocd get application toggle-local >/dev/null 2>&1; then
      application toggle-local local/chart toggle-master 'appsEnabled: false'
    fi
    wait_app toggle-local
    init_floci
    build_images
    application observability-metrics apps/observability-metrics observability "$(cat "$ROOT/local/metrics-values.yaml")"
    wait_app observability-metrics
    external=false
    [[ -f "$STATE/integrations-enabled" ]] && external=true
    application observability-telemetry apps/observability-telemetry observability "externalIntegrationsEnabled: $external"
    wait_app observability-telemetry
    application toggle-local local/chart toggle-master 'appsEnabled: true'
    wait_app toggle-local
    echo 'Base local instalada. Grafana http://localhost:3000 | Argo CD http://localhost:8080'
    echo 'Use: bash local/lab.sh passwords; bash local/lab.sh demo start'
    echo 'Integracoes externas e evidencias finais ainda precisam ser verificadas.'
    ;;
  integrations)
    check
    for item in 'new-relic-license-key:New Relic INGEST key' 'pagerduty-routing-key:PagerDuty Events v2 routing key' 'discord-webhook-url:Discord webhook URL'; do
      key="${item%%:*}"; label="${item#*:}"
      read -r -s -p "$label: " value </dev/tty; printf '\n'
      [[ -n "$value" ]] || { echo 'Valor vazio.'; exit 1; }
      printf '%s' "$value" > "$STATE/$key"; unset value
    done
    k -n observability get secret fase4-integrations -o jsonpath='{.data.heal-token}' | python3 -c 'import sys,base64;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$STATE/heal-token"
    secret observability fase4-integrations --from-file=heal-token="$STATE/heal-token" \
      --from-file=new-relic-license-key="$STATE/new-relic-license-key" --from-file=pagerduty-routing-key="$STATE/pagerduty-routing-key" \
      --from-file=discord-webhook-url="$STATE/discord-webhook-url"
    rm -f "$STATE/new-relic-license-key" "$STATE/pagerduty-routing-key" "$STATE/discord-webhook-url"
    endpoint=https://otlp.nr-data.net:4318
    [[ "${NEW_RELIC_REGION:-US}" == EU ]] && endpoint=https://otlp.eu01.nr-data.net:4318
    application observability-telemetry apps/observability-telemetry observability "externalIntegrationsEnabled: true
newRelicEndpoint: $endpoint"
    wait_app observability-telemetry
    k -n observability rollout restart deployment/otel-gateway deployment/self-healer
    k -n observability rollout status deployment/otel-gateway --timeout=180s
    k -n observability rollout status deployment/self-healer --timeout=180s
    touch "$STATE/integrations-enabled"
    echo 'Integracoes configuradas; confirme recebimento no New Relic, PagerDuty e Discord.'
    ;;
  passwords)
    python3 - "$KUBECONFIG" <<'PY'
import base64,json,subprocess
for ns,name,key in [('argocd','argocd-initial-admin-secret','password'),('observability','grafana-admin','admin-password')]:
    obj=json.loads(subprocess.check_output(['kubectl','--context','kind-toggle-floci','-n',ns,'get','secret',name,'-o','json']))
    print(ns+' | usuario admin | senha '+base64.b64decode(obj['data'][key]).decode())
PY
    ;;
  status) k -n argocd get applications; k get pods -A ;;
  demo) shift; kubectl config use-context kind-toggle-floci >/dev/null; bash "$ROOT/scripts/fase4-demo.sh" "${1:-status}" ;;
  *) echo 'Uso: bash local/lab.sh up|integrations|passwords|status|demo [start|fail|recover|logs|status]'; exit 2 ;;
esac
