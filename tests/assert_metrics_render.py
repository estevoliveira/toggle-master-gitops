"""Verifica o contrato operacional dos manifests realmente renderizados pelo Helm."""
import json
from pathlib import Path
import sys
import yaml


class KubernetesLoader(yaml.SafeLoader):
    """CRDs usam '=' como string; PyYAML atribui a tag YAML 1.1 'value'."""


KubernetesLoader.add_constructor("tag:yaml.org,2002:value", KubernetesLoader.construct_scalar)
documents = [obj for obj in yaml.load_all(Path(sys.argv[1]).read_text(), Loader=KubernetesLoader)
             if isinstance(obj, dict)]
expected_host = "grafana.example.test"


def one(kind, name=None):
    matches = [obj for obj in documents if obj.get("kind") == kind
               and (name is None or obj.get("metadata", {}).get("name") == name)]
    assert len(matches) == 1, (kind, name, [obj.get("metadata", {}).get("name") for obj in matches])
    return matches[0]


grafana = one("Deployment", "grafana")
assert grafana["metadata"]["namespace"] == "observability"
container = next(c for c in grafana["spec"]["template"]["spec"]["containers"] if c["name"] == "grafana")
environment = {item["name"]: item for item in container["env"]}
assert environment["GF_SECURITY_ADMIN_PASSWORD"]["valueFrom"]["secretKeyRef"] == {
    "name": "grafana-admin", "key": "admin-password"}
assert environment["GF_SERVER_ROOT_URL"]["valueFrom"]["configMapKeyRef"] == {
    "name": "grafana-public-url", "key": "root-url"}
assert environment["GF_SECURITY_COOKIE_SECURE"]["value"] == "true"
assert one("Service", "grafana")["spec"].get("type", "ClusterIP") == "ClusterIP"

prometheus = one("Prometheus")
assert prometheus["spec"]["replicas"] == 1
assert prometheus["spec"]["retention"] == "24h"
assert prometheus["spec"]["enableOTLPReceiver"] is True
assert prometheus["spec"]["storage"]["emptyDir"] == {}
assert one("Service", "monitoring-prometheus")["spec"].get("type", "ClusterIP") == "ClusterIP"

ingress = one("Ingress", "grafana")
assert ingress["spec"]["ingressClassName"] == "nginx"
assert ingress["spec"]["rules"][0]["host"] == expected_host
assert ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"] == {
    "name": "grafana", "port": {"number": 80}}
assert ingress["spec"]["tls"] == [{"hosts": [expected_host], "secretName": "grafana-tls"}]
assert one("ConfigMap", "grafana-public-url")["data"]["root-url"] == "https://grafana.example.test/"

dashboard = json.loads(one("ConfigMap", "grafana-togglemaster-dashboard")["data"]["togglemaster.json"])
assert dashboard["uid"] == "togglemaster-fase4"
assert len(dashboard["panels"]) == 4
assert all(panel["targets"][0]["expr"] for panel in dashboard["panels"])
assert any(panel["targets"][0]["legendFormat"] == "{{instance}}" for panel in dashboard["panels"])

datasources = []
for obj in documents:
    if obj.get("kind") == "ConfigMap" and "datasource.yaml" in obj.get("data", {}):
        datasources += yaml.safe_load(obj["data"]["datasource.yaml"]).get("datasources", [])
source = next(ds for ds in datasources if ds.get("uid") == "prometheus")
assert source["url"].startswith("http://monitoring-prometheus.observability:9090")
assert source["isDefault"] is True

assert not any(obj.get("kind") in ("PersistentVolumeClaim", "Alertmanager", "PrometheusRule") for obj in documents)
for obj in documents:
    if obj.get("kind") == "Service":
        assert obj["spec"].get("type", "ClusterIP") == "ClusterIP", obj["metadata"]["name"]
    if obj.get("kind") in ("Deployment", "DaemonSet", "StatefulSet", "Job"):
        assert obj["metadata"]["namespace"] == "observability", obj["metadata"]["name"]
    if obj.get("kind") == "Secret":
        assert "admin-password" not in obj.get("data", {}), "Senha de admin nao deve ser gerada pelo chart"

application = yaml.safe_load(Path("argocd/observability-metrics.yaml").read_text())
assert application["spec"]["source"]["path"] == "apps/observability-metrics"
assert application["spec"]["destination"]["namespace"] == "observability"
assert "ServerSideApply=true" in application["spec"]["syncPolicy"]["syncOptions"]
print("Render validado: datasource, dashboard, HTTPS, Secrets referenciados, recursos privados e namespace isolado.")
