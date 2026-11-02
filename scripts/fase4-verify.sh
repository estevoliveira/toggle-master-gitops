#!/usr/bin/env bash
# Apenas leitura; gera verificacoes sem expor Secrets.
set -euo pipefail
region="${TARGET_REGION:-us-east-1}"
cluster="${TARGET_CLUSTER:-toggle-cluster}"
expected="$(aws eks describe-cluster --name "$cluster" --region "$region" --query cluster.endpoint --output text)"
actual="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$actual" == "$expected" ]] || { echo 'Contexto diferente do EKS esperado.'; exit 2; }
kubectl -n argocd get applications
kubectl -n observability get pods -o wide
kubectl -n toggle-master get deployments
printf '\nContadores HTTP que chegaram ate o Prometheus:\n'
query='count by (service_name) (toggle_http_requests_total)'
encoded="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$query")"
kubectl get --raw "/api/v1/namespaces/observability/services/http:monitoring-prometheus:9090/proxy/api/v1/query?query=$encoded" |
  jq -e '.status == "success" and ([.data.result[].metric.service_name] | unique | sort == ["analytics-service","auth-service","evaluation-service","flag-service","targeting-service"])' >/dev/null
kubectl get --raw "/api/v1/namespaces/observability/services/http:monitoring-prometheus:9090/proxy/api/v1/query?query=$encoded" |
  jq -r '.data.result[] | [.metric.service_name,.value[1]] | @tsv'
printf '\nNamespaces com logs de containers no Loki:\n'
kubectl get --raw '/api/v1/namespaces/observability/services/http:loki:3100/proxy/loki/api/v1/label/k8s_namespace_name/values' |
  jq -e '.status == "success" and (.data | length > 0)' >/dev/null
kubectl get --raw '/api/v1/namespaces/observability/services/http:loki:3100/proxy/loki/api/v1/label/k8s_namespace_name/values' | jq '.data'
printf '\nErros recentes do Collector (se houver):\n'
kubectl -n observability logs deployment/otel-gateway --tail=20
printf '\nVerificar manualmente no New Relic: cinco servicos, Service Map e trace do evaluation.\n'
printf 'Validar incidente, Discord e recuperacao com fase4-demo.sh; nao estao comprovados por este script.\n'
