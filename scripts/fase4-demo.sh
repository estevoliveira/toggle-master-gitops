#!/usr/bin/env bash
set -euo pipefail
set +x
mode="${1:-status}"
namespace=toggle-master
case "$mode" in
  start)
    # Job tem prazo e nao e recriado automaticamente pelo GitOps.
    kubectl -n "$namespace" create -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: fase4-demo
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 650
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {app: fase4-demo}
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: python:3.12-slim
          command: [python, -u, /app/demo_load.py]
          env:
            - name: SERVICE_API_KEY
              valueFrom:
                secretKeyRef: {name: academy-databases, key: service-api-key}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits: {cpu: 100m, memory: 128Mi}
          volumeMounts:
            - {name: code, mountPath: /app, readOnly: true}
      volumes:
        - name: code
          configMap: {name: fase4-demo-code}
YAML
    ;;
  fail|recover)
    # Chave segue pelo stdin do exec e nunca aparece nos argumentos nem nos logs.
    payload="$(kubectl -n "$namespace" get secret fase4-demo -o jsonpath='{.data.demo-token}' | base64 -d)"
    printf '%s' "$payload" | kubectl -n "$namespace" exec -i deployment/analytics-service -- \
      python -c 'import sys,urllib.request;token=sys.stdin.read();method="POST" if sys.argv[1]=="fail" else "DELETE";r=urllib.request.Request("http://evaluation-service:8004/demo/failure",method=method,headers={"Authorization":"Bearer "+token});response=urllib.request.urlopen(r,timeout=10);print("Controle da falha: HTTP",response.status)' "$mode"
    unset payload
    ;;
  status)
    kubectl -n "$namespace" get job fase4-demo --ignore-not-found
    kubectl -n "$namespace" get pods -l app=evaluation-service -o wide
    kubectl -n observability logs deployment/self-healer --tail=25
    ;;
  logs)
    kubectl -n "$namespace" logs -f job/fase4-demo
    ;;
  *) echo 'Uso: fase4-demo.sh start|fail|recover|status|logs'; exit 2 ;;
esac
