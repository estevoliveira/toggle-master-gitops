#!/usr/bin/env bash
# Execute a partir de um arquivo; as chaves sao digitadas no terminal e nao entram no Git.
set -euo pipefail
set +x
umask 077
region="${TARGET_REGION:-us-east-1}"
cluster="${TARGET_CLUSTER:-toggle-cluster}"
ref="${GITOPS_REF:-master}"
work_dir="$(mktemp -d)"
held_nodes=()
cleanup() {
  for node in "${held_nodes[@]}"; do kubectl uncordon "$node" || true; done
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
for command in aws kubectl jq curl openssl; do command -v "$command" >/dev/null; done
[[ "$ref" =~ ^[a-zA-Z0-9._/-]+$ ]]
aws sts get-caller-identity --no-cli-pager >/dev/null
expected="$(aws eks describe-cluster --name "$cluster" --region "$region" --query cluster.endpoint --output text)"
actual="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$expected" == "$actual" ]] || { echo 'Conecte o kubectl ao toggle-cluster antes de continuar.'; exit 2; }
kubectl -n observability rollout status deployment/grafana --timeout=90s
kubectl -n observability rollout status deployment/monitoring-operator --timeout=90s

if [[ "${ROTATE_INTEGRATIONS:-false}" == true ]] || ! kubectl -n observability get secret fase4-integrations >/dev/null 2>&1; then
  printf '\nDigite as credenciais das SUAS contas; nenhuma sera mostrada ou salva no Git.\n'
  read -rsp 'New Relic INGEST license key: ' nr_key </dev/tty; printf '\n'
  read -rsp 'PagerDuty Events API v2 routing key: ' pd_key </dev/tty; printf '\n'
  read -rsp 'Discord webhook URL: ' discord_url </dev/tty; printf '\n'
  [[ ${#nr_key} -ge 10 && "$pd_key" =~ ^[a-zA-Z0-9]{32}$ ]] || { echo 'Chave New Relic/PagerDuty invalida.'; exit 2; }
  [[ "$discord_url" =~ ^https://discord[.]com/api/webhooks/[0-9]+/[a-zA-Z0-9._-]+$ ]] || { echo 'Webhook deve ser uma URL oficial do Discord.'; exit 2; }
  printf %s "$nr_key" > "$work_dir/nr"
  printf %s "$pd_key" > "$work_dir/pd"
  printf %s "$discord_url" > "$work_dir/discord"
  unset nr_key pd_key discord_url
  if kubectl -n observability get secret fase4-integrations >/dev/null 2>&1; then
    kubectl -n observability get secret fase4-integrations -o jsonpath='{.data.heal-token}' | base64 -d > "$work_dir/heal"
  else
    openssl rand -hex 32 | tr -d '\n' > "$work_dir/heal"
  fi
  kubectl -n observability create secret generic fase4-integrations \
    --from-file=new-relic-license-key="$work_dir/nr" --from-file=pagerduty-routing-key="$work_dir/pd" \
    --from-file=discord-webhook-url="$work_dir/discord" --from-file=heal-token="$work_dir/heal" \
    --dry-run=client -o yaml | kubectl apply --server-side --field-manager=fase4-bootstrap -f -
fi
if ! kubectl -n toggle-master get secret fase4-demo >/dev/null 2>&1; then
  openssl rand -hex 32 | tr -d '\n' > "$work_dir/demo"
  kubectl -n toggle-master create secret generic fase4-demo --from-file=demo-token="$work_dir/demo"
fi
# Reserva uma vaga por no para o DaemonSet de logs. O cluster pequeno tem limite de 17 pods/no.
# Move somente uma replica de um servico que tem pelo menos duas replicas disponiveis.
kubectl get nodes -o json > "$work_dir/nodes.json"
while IFS=$'\t' read -r node max_pods; do
  if [[ -n "$(kubectl -n observability get pods -l app=otel-logs --field-selector "spec.nodeName=$node" -o name)" ]]; then
    continue
  fi
  kubectl get pods -A --field-selector "spec.nodeName=$node" -o json > "$work_dir/node-pods.json"
  used="$(jq '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")] | length' "$work_dir/node-pods.json")"
  if (( used < max_pods )); then continue; fi
  selected=""
  for service in auth-service flag-service targeting-service; do
    available="$(kubectl -n toggle-master get deployment "$service" -o jsonpath='{.status.availableReplicas}')"
    if (( ${available:-0} < 2 )); then continue; fi
    selected="$(jq -r --arg service "$service" '[.items[] |
      select(.metadata.namespace == "toggle-master" and .metadata.labels.app == $service) |
      select(.metadata.deletionTimestamp == null) |
      select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet")) |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))][0].metadata.name // empty' "$work_dir/node-pods.json")"
    if [[ -n "$selected" ]]; then break; fi
  done
  if [[ -z "$selected" ]]; then
    printf 'No %s lotado e sem replica redundante para mover. Envie kubectl get pods -A -o wide.\n' "$node"
    exit 1
  fi
  original="$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}')"
  if [[ "$original" != true ]]; then
    held_nodes+=("$node")
    kubectl cordon "$node"
  fi
  printf 'Liberando uma vaga de agente no no %s, redistribuindo %s.\n' "$node" "$selected"
  kubectl -n toggle-master delete pod "$selected"
  kubectl -n toggle-master rollout status "deployment/$service" --timeout=180s
done < <(jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | [.metadata.name,.status.allocatable.pods] | @tsv' "$work_dir/nodes.json")

base="https://raw.githubusercontent.com/ramondata/toggle-master-gitops/$ref"
for file in observability-telemetry applicationset; do
  curl -fsSL --connect-timeout 10 --max-time 60 "$base/argocd/$file.yaml" -o "$work_dir/$file.yaml"
done
nr_region="${NEW_RELIC_REGION:-US}"
case "$nr_region" in
  US) nr_endpoint=https://otlp.nr-data.net:4318 ;;
  EU) nr_endpoint=https://otlp.eu01.nr-data.net:4318 ;;
  *) echo 'NEW_RELIC_REGION deve ser US ou EU.'; exit 2 ;;
esac
# Usa a origem versionada e preenche somente o parametro da regiao da conta.
kubectl apply -f "$work_dir/observability-telemetry.yaml"
kubectl -n argocd patch application observability-telemetry --type merge -p \
  "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"newRelicEndpoint\",\"value\":\"$nr_endpoint\"}]}}}}"
kubectl apply -f "$work_dir/applicationset.yaml"
kubectl -n argocd annotate application observability-telemetry argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd wait application/observability-telemetry --for=jsonpath='{.status.sync.status}'=Synced --timeout=600s
kubectl -n argocd wait application/observability-telemetry --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
for node in "${held_nodes[@]}"; do kubectl uncordon "$node"; done
held_nodes=()
# Recria o pod para carregar o Secret novo; o Deployment permanece gerenciado pelo Argo CD.
kubectl -n observability delete pods -l app.kubernetes.io/name=grafana
kubectl -n observability rollout status deployment/grafana --timeout=300s
for service in auth-service flag-service targeting-service evaluation-service analytics-service; do
  kubectl -n toggle-master rollout status "deployment/$service" --timeout=300s
done
kubectl -n observability get pods -o wide
printf '\nTelemetria instalada. Ainda e necessario validar os dados, a conta APM e o fluxo real de incidente.\n'
printf 'Grafana: '
kubectl -n observability get ingress grafana -o jsonpath='https://{.spec.rules[0].host}{"\n"}'
printf 'Acompanhe o Collector: kubectl -n observability logs deployment/otel-gateway --tail=30\n'
printf 'O proximo comando de demonstracao sera fase4-demo.sh start.\n'
