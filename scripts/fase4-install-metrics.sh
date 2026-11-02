#!/usr/bin/env bash
# Bootstrap de Prometheus/Grafana; o Argo CD gerencia os workloads.
set -euo pipefail
set +x
umask 077

cluster="${TARGET_CLUSTER:-toggle-cluster}"
region="${TARGET_REGION:-us-east-1}"
git_ref="${GITOPS_REF:-master}"
namespace=observability
context_validated=false
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

diagnose() {
  if [[ "$context_validated" != true ]]; then return; fi
  printf '\nA instalacao nao foi confirmada. Estado para diagnostico:\n' >&2
  kubectl --request-timeout=10s -n argocd get application observability-metrics \
    -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,MESSAGE:.status.conditions[*].message' >&2 || true
  kubectl --request-timeout=10s -n "$namespace" get pods -o wide >&2 || true
  kubectl --request-timeout=10s -n "$namespace" get events --field-selector type=Warning \
    --sort-by=.lastTimestamp >&2 || true
}
trap diagnose ERR

for dependency in aws kubectl jq curl openssl; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'Comando ausente: %s\n' "$dependency" >&2
    exit 2
  fi
done
if [[ ! "$git_ref" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  printf 'GITOPS_REF invalido\n' >&2
  exit 2
fi

printf '1. Confirmando sessao e contexto EKS\n'
aws sts get-caller-identity --region "$region" --no-cli-pager >/dev/null
expected="$(aws eks describe-cluster --name "$cluster" --region "$region" \
  --query cluster.endpoint --output text --no-cli-pager)"
actual="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ -z "$expected" || "$expected" == None || "$actual" != "$expected" ]]; then
  printf 'Conecte primeiro: aws eks update-kubeconfig --region %s --name %s\n' "$region" "$cluster" >&2
  exit 2
fi
context_validated=true
kubectl --request-timeout=15s get nodes -o json > "$work_dir/nodes.json"
if ! jq -e 'any(.items[]; .spec.unschedulable != true and
  any(.status.conditions[]?; .type == "Ready" and .status == "True"))' "$work_dir/nodes.json" >/dev/null; then
  printf 'Nenhum no Ready com agendamento habilitado\n' >&2
  exit 1
fi
kubectl --request-timeout=15s get ingressclass nginx >/dev/null
kubectl -n argocd rollout status deployment/argocd-server --timeout=90s

printf '\n2. Descobrindo o endereco do NGINX existente\n'
kubectl --request-timeout=15s -n ingress-nginx get services -o json > "$work_dir/services.json"
jq '[.items[] | select(.spec.type == "LoadBalancer") |
  select(any(.spec.ports[]; .port == 443)) |
  select(.status.loadBalancer.ingress[0].hostname != null)]' "$work_dir/services.json" > "$work_dir/lbs.json"
if [[ "$(jq length "$work_dir/lbs.json")" != 1 ]]; then
  printf 'Esperado um Load Balancer NGINX com HTTPS e DNS atribuido; envie a lista de services do ingress-nginx.\n' >&2
  exit 1
fi
grafana_host="$(jq -r '.[0].status.loadBalancer.ingress[0].hostname' "$work_dir/lbs.json")"
if [[ ! "$grafana_host" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
  printf 'Hostname do Load Balancer invalido\n' >&2
  exit 1
fi
kubectl --request-timeout=15s get ingress -A -o json > "$work_dir/ingresses.json"
conflicts="$(jq --arg host "$grafana_host" '[.items[] |
  select((.spec.ingressClassName // .metadata.annotations["kubernetes.io/ingress.class"]) == "nginx") |
  select(.metadata.namespace != "observability" or .metadata.name != "grafana") |
  select(any(.spec.rules[]?; .host == $host and any(.http.paths[]?; .path == "/")))] | length' "$work_dir/ingresses.json")"
if (( conflicts > 0 )); then
  printf 'Ja existe uma rota / para esse hostname no NGINX. Precisamos revisar a rota existente antes de prosseguir.\n' >&2
  exit 1
fi

existing_app="$(kubectl --request-timeout=15s -n argocd get application observability-metrics --ignore-not-found -o json)"
if [[ -n "$existing_app" ]] && ! jq -e '.spec.source.repoURL == "https://github.com/ramondata/toggle-master-gitops.git" and
  .spec.source.path == "apps/observability-metrics"' <<< "$existing_app" >/dev/null; then
  printf 'A Application observability-metrics existente aponta para outra origem.\n' >&2
  exit 1
fi
if [[ -z "$existing_app" ]] && kubectl --request-timeout=15s -n "$namespace" get deployment grafana -o name >/dev/null 2>&1; then
  printf 'Ja existe Grafana nesse namespace sem a Application esperada. Revisar a instalacao existente.\n' >&2
  exit 1
fi

printf '\n3. Preparando namespace e credenciais locais do laboratorio\n'
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
if [[ -z "$(kubectl --request-timeout=15s -n "$namespace" get secret grafana-admin --ignore-not-found -o name)" ]]; then
  printf admin > "$work_dir/admin-user"
  openssl rand -hex 24 | tr -d '\n' > "$work_dir/admin-password"
  kubectl -n "$namespace" create secret generic grafana-admin \
    --from-file=admin-user="$work_dir/admin-user" --from-file=admin-password="$work_dir/admin-password"
fi
kubectl --request-timeout=15s -n "$namespace" get secret grafana-admin -o json |
  jq -e '.data | has("admin-user") and has("admin-password")' >/dev/null

refresh_tls=true
if [[ -n "$(kubectl --request-timeout=15s -n "$namespace" get secret grafana-tls --ignore-not-found -o name)" ]]; then
  kubectl --request-timeout=15s -n "$namespace" get secret grafana-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$work_dir/current.crt"
  if openssl verify -CAfile "$work_dir/current.crt" -verify_hostname "$grafana_host" \
    "$work_dir/current.crt" >/dev/null 2>&1; then
    refresh_tls=false
  else
    owner="$(kubectl --request-timeout=15s -n "$namespace" get secret grafana-tls -o json |
      jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""')"
    if [[ "$owner" != toggle-master-observability ]]; then
      printf 'O certificado existente nao corresponde ao hostname e nao pertence a este bootstrap.\n' >&2
      exit 1
    fi
  fi
fi
if [[ "$refresh_tls" == true ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
    -keyout "$work_dir/tls.key" -out "$work_dir/tls.crt" \
    -subj /CN=grafana-lab -addext "subjectAltName=DNS:$grafana_host" >/dev/null 2>&1
  kubectl -n "$namespace" create secret tls grafana-tls --cert="$work_dir/tls.crt" \
    --key="$work_dir/tls.key" --dry-run=client -o json |
    jq '.metadata.labels={"app.kubernetes.io/part-of":"toggle-master-observability"}' |
    kubectl apply --server-side --field-manager=fase4-bootstrap -f -
fi

printf '\n4. Registrando a Application; o Argo CD instalara o chart\n'
curl -fsSL --connect-timeout 10 --max-time 60 \
  "https://raw.githubusercontent.com/ramondata/toggle-master-gitops/$git_ref/argocd/observability-metrics.yaml" \
  -o "$work_dir/application.yaml"
sed "s/__GRAFANA_HOST__/$grafana_host/g" "$work_dir/application.yaml" | kubectl apply -f -
kubectl -n argocd annotate application observability-metrics argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd wait application/observability-metrics \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=600s
kubectl -n argocd wait application/observability-metrics \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
kubectl -n "$namespace" rollout status deployment/grafana --timeout=300s

deadline=$((SECONDS + 180))
while ! kubectl --request-timeout=10s -n "$namespace" get pods \
  -l app.kubernetes.io/name=prometheus -o json | jq -e '.items | length > 0' >/dev/null; do
  if (( SECONDS >= deadline )); then
    printf 'O operator ainda nao criou o pod Prometheus.\n' >&2
    exit 1
  fi
  sleep 5
done
kubectl -n "$namespace" wait pod -l app.kubernetes.io/name=prometheus \
  --for=condition=Ready --timeout=300s
kubectl -n "$namespace" get pods -o wide

printf '\n5. Confirmando acesso HTTPS ao Grafana\n'
kubectl --request-timeout=15s -n "$namespace" get secret grafana-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$work_dir/check.crt"
grafana_ready=false
for attempt in {1..8}; do
  if curl -fsS --connect-timeout 5 --max-time 10 --cacert "$work_dir/check.crt" \
      "https://$grafana_host/api/health" -o "$work_dir/health.json" 2> "$work_dir/https-error.txt" &&
     jq -e '.database | if type == "string" then ascii_downcase == "ok" else false end' \
       "$work_dir/health.json" >/dev/null 2>&1; then
    grafana_ready=true
    break
  fi
  printf 'Aguardando a rota HTTPS do Grafana (%s/8)...\n' "$attempt"
  sleep 5
done
if [[ "$grafana_ready" != true ]]; then
  printf 'Nao foi possivel confirmar /api/health pelo HTTPS do NGINX.\n' >&2
  cat "$work_dir/https-error.txt" >&2
  diagnose
  exit 1
fi

printf '\nRESULTADO: WORKLOADS DE METRICAS PRONTOS.\n'
printf 'Grafana: https://%s\n' "$grafana_host"
printf 'Usuario: admin\n'
printf 'Para consultar a senha no seu terminal, execute:\n'
printf "kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d\n"
printf 'Certificado autoassinado do laboratorio: use Advanced > Proceed no navegador.\n'
printf 'Abra o dashboard ToggleMaster - Fase 4 ou Explore > Prometheus e consulte: up\n'
printf 'A primeira coleta pode levar cerca de um minuto apos os pods ficarem prontos.\n'
