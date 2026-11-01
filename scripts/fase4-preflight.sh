#!/usr/bin/env bash
# Diagnostico de leitura para o ToggleMaster no AWS Academy.
set -euo pipefail
set +x
umask 077

cluster="${TARGET_CLUSTER:-toggle-cluster}"
region="${TARGET_REGION:-us-east-1}"
app_namespace="${APP_NAMESPACE:-toggle-master}"
argo_namespace="${ARGO_NAMESPACE:-argocd}"
services=(auth-service flag-service targeting-service evaluation-service analytics-service)
failures=0
warnings=0

section() { printf '\n%s\n' "$1"; }
ok() { printf '[OK] %s\n' "$1"; }
fail() { printf '[FALHA] %s\n' "$1"; failures=$((failures + 1)); }
warn() { printf '[AVISO] %s\n' "$1"; warnings=$((warnings + 1)); }

for dependency in aws kubectl jq; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf '[FALHA] Comando ausente: %s\n' "$dependency" >&2
    exit 2
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

read_json() {
  local destination="$1"
  shift
  if ! kubectl --request-timeout=15s "$@" -o json > "$destination"; then
    fail "Nao foi possivel consultar: kubectl $*"
    return 1
  fi
}

inspect() {
  if ! kubectl --request-timeout=15s "$@"; then
    warn "Consulta complementar indisponivel: kubectl $*"
  fi
}

check_deployments() {
  local file="$1"
  shift
  local name desired available updated generation observed
  for name in "$@"; do
    if ! jq -e --arg name "$name" '.items[] | select(.metadata.name == $name)' "$file" >/dev/null; then
      fail "Deployment ausente: $name"
      continue
    fi
    read -r desired available updated generation observed < <(
      jq -r --arg name "$name" '.items[] | select(.metadata.name == $name) |
        [(.spec.replicas // 1), (.status.availableReplicas // 0),
         (.status.updatedReplicas // 0), .metadata.generation,
         (.status.observedGeneration // 0)] | @tsv' "$file"
    )
    if (( desired > 0 && available >= desired && updated == desired && observed >= generation )); then
      ok "$name: $available/$desired replicas disponiveis e rollout observado"
    else
      fail "$name: desejadas=$desired disponiveis=$available atualizadas=$updated geracao=$observed/$generation"
    fi
  done
}

section '1. Sessao AWS e cluster alvo'
if ! aws sts get-caller-identity --region "$region" --no-cli-pager >/dev/null; then
  printf '[FALHA] Nao foi possivel validar a sessao AWS. Confira a sessao do Academy.\n' >&2
  exit 2
fi
if ! expected_endpoint="$(aws eks describe-cluster --region "$region" --name "$cluster" \
  --query 'cluster.endpoint' --output text --no-cli-pager)"; then
  exit 2
fi
if ! current_endpoint="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"; then
  exit 2
fi
if [[ -z "$expected_endpoint" || "$expected_endpoint" == None || "$current_endpoint" != "$expected_endpoint" ]]; then
  printf '[FALHA] O contexto kubectl nao corresponde ao cluster %s em %s.\n' "$cluster" "$region" >&2
  printf 'Conecte com: aws eks update-kubeconfig --region %s --name %s\n' "$region" "$cluster" >&2
  exit 2
fi
ok "Sessao AWS valida; contexto conectado a $cluster em $region"

section '2. Nos e capacidade'
if ! read_json "$work_dir/nodes.json" get nodes; then exit 2; fi
jq -r '.items[] | . as $node |
  ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown") as $ready |
  "\($node.metadata.name): Ready=\($ready), scheduling=\(if .spec.unschedulable == true then "bloqueado" else "liberado" end), CPU=\(.status.allocatable.cpu), memoria=\(.status.allocatable.memory), limitePods=\(.status.allocatable.pods)"' "$work_dir/nodes.json"
schedulable="$(jq '[.items[] | select(.spec.unschedulable != true) |
  select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' "$work_dir/nodes.json")"
if (( schedulable > 0 )); then
  ok "$schedulable no(s) Ready com agendamento liberado"
else
  fail 'Nenhum no Ready aceita novos pods'
fi
if ! kubectl --request-timeout=15s describe nodes | awk '
  /^Name:/ { node=$2 }
  /^Allocated resources:/ { print "\nReservas do no " node; show=1 }
  /^Events:/ { show=0 }
  show { print }
'; then
  warn 'Reservas de recursos dos nos indisponiveis'
fi
inspect top nodes

section '3. Microsservicos, pods, HPA e quota'
if read_json "$work_dir/deployments.json" -n "$app_namespace" get deployments; then
  check_deployments "$work_dir/deployments.json" "${services[@]}"
fi
inspect -n "$app_namespace" get pods -o wide
inspect -n "$app_namespace" get hpa
inspect -n "$app_namespace" get resourcequota

section '4. Endpoints prontos e health checks'
if read_json "$work_dir/slices.json" -n "$app_namespace" get endpointslices && \
   read_json "$work_dir/services.json" -n "$app_namespace" get services; then
  proxy_allowed=false
  if kubectl --request-timeout=15s auth can-i get services/proxy -n "$app_namespace" --quiet; then
    proxy_allowed=true
  else
    warn 'Sem permissao services/proxy: os testes HTTP ficarao inconclusivos'
  fi
  for service in "${services[@]}"; do
    ready="$(jq --arg name "$service" '[.items[] |
      select(.metadata.labels["kubernetes.io/service-name"] == $name) |
      .endpoints[]? | select(.conditions.ready == true and .conditions.terminating != true)] | length' "$work_dir/slices.json")"
    port="$(jq -r --arg name "$service" '.items[] | select(.metadata.name == $name) | .spec.ports[0].port' "$work_dir/services.json")"
    if [[ -z "$port" || "$port" == null ]] || (( ready == 0 )); then
      fail "$service: Service ausente ou nenhum endpoint pronto"
      continue
    fi
    ok "$service: $ready endpoint(s) pronto(s), porta $port"
    if [[ "$proxy_allowed" == true ]]; then
      if response="$(kubectl --request-timeout=10s get --raw "/api/v1/namespaces/$app_namespace/services/http:$service:$port/proxy/health" 2> "$work_dir/health-error.txt")" && \
         jq -e '.status == "ok"' <<< "$response" >/dev/null 2>&1; then
        ok "$service /health respondeu status=ok via API do Kubernetes"
      else
        fail "$service /health nao foi confirmado via proxy; verificar aplicacao, RBAC e conectividade"
      fi
    fi
  done
fi

section '5. Argo CD e sincronizacao GitOps'
if read_json "$work_dir/argo-deployments.json" -n "$argo_namespace" get deployments; then
  check_deployments "$work_dir/argo-deployments.json" argocd-server
fi
if read_json "$work_dir/applications.json" -n "$argo_namespace" get applications.argoproj.io; then
  jq -r '.items[] | [.metadata.name, (.status.sync.status // "Unknown"),
    (.status.health.status // "Unknown")] | @tsv' "$work_dir/applications.json"
  for application in platform "${services[@]}"; do
    if jq -e --arg name "$application" '.items[] | select(.metadata.name == $name) |
      select(.status.sync.status == "Synced" and .status.health.status == "Healthy")' "$work_dir/applications.json" >/dev/null; then
      ok "GitOps $application: Synced/Healthy"
    else
      fail "GitOps $application: ausente, fora de sincronismo ou nao saudavel"
    fi
  done
fi
if read_json "$work_dir/argo-service.json" -n "$argo_namespace" get service argocd-server; then
  argo_host="$(jq -r '.status.loadBalancer.ingress[0] | .hostname // .ip // empty' "$work_dir/argo-service.json")"
  if [[ -n "$argo_host" ]]; then
    printf 'URL declarada do Argo CD: https://%s\n' "$argo_host"
  else
    warn 'argocd-server ainda nao tem endereco de Load Balancer'
  fi
fi

section '6. Eventos recentes do namespace das aplicacoes'
inspect -n "$app_namespace" get events --field-selector type=Warning \
  --sort-by=.lastTimestamp

section 'Resumo da etapa 1'
printf 'Falhas: %s | Avisos: %s\n' "$failures" "$warnings"
printf 'Escopo: disponibilidade inicial, endpoints, /health, recursos e estado do GitOps.\n'
printf 'O /health atual nao comprova o fluxo de negocio nem consumo SQS/gravacao DynamoDB.\n'
printf 'Ainda vamos validar esse fluxo antes de considerar a base completa.\n'
if (( failures > 0 )); then
  printf 'RESULTADO: CORRIGIR AS FALHAS ANTES DE INSTALAR A STACK.\n'
  exit 1
fi
if (( warnings > 0 )); then
  printf 'RESULTADO: SEM FALHAS DETECTADAS; CONFERIR OS AVISOS E A CAPACIDADE.\n'
else
  printf 'RESULTADO: CHECAGENS INICIAIS OK; CONFERIR CAPACIDADE E FLUXO FUNCIONAL.\n'
fi
