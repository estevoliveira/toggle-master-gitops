import json
from pathlib import Path
import sys
import yaml

objects = [x for x in yaml.safe_load_all(Path(sys.argv[1]).read_text()) if isinstance(x, dict)]
by_name = {(x['kind'], x['metadata']['name']): x for x in objects}
for name in ['otel-gateway', 'loki', 'self-healer']:
    deployment = by_name['Deployment', name]
    assert deployment['metadata']['namespace'] == 'observability'
    assert deployment['spec']['replicas'] == 1
assert ('DaemonSet', 'otel-logs') in by_name
role = by_name['Role', 'evaluation-restart']
assert role['metadata']['namespace'] == 'toggle-master'
assert role['rules'] == [{'apiGroups': ['apps'], 'resources': ['deployments'],
                          'resourceNames': ['evaluation-service'], 'verbs': ['get', 'patch']}]
monitor = by_name['ServiceMonitor', 'otel-gateway']
assert monitor['metadata']['labels']['release'] == 'observability-metrics'
assert monitor['spec']['endpoints'][0]['port'] == 'metrics'
for obj in objects:
    if obj['kind'] == 'Service':
        assert obj['spec'].get('type', 'ClusterIP') == 'ClusterIP'
    assert obj['kind'] not in ['Secret', 'PersistentVolumeClaim', 'Ingress']
alerts = yaml.safe_load(by_name['ConfigMap', 'grafana-fase4-alerts']['data']['fase4.yaml'])
rule = alerts['groups'][0]['rules'][0]
assert rule['for'] == '45s'
assert rule['labels']['service'] == 'evaluation-service'
assert rule['noDataState'] == 'OK'
assert alerts['contactPoints'][0]['receivers'][0]['settings']['authorization_credentials'] == '$HEAL_TOKEN'
appset = yaml.safe_load(Path('argocd/applicationset.yaml').read_text())
assert any('/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt' in x.get('jsonPointers', [])
           for x in appset['spec']['template']['spec']['ignoreDifferences'])
dashboard = json.loads(Path('apps/observability-metrics/dashboards/togglemaster.json').read_text())
assert {x['datasource']['uid'] for x in dashboard['panels']} == {'prometheus', 'loki'}
print('PASS: namespaces, acesso privado, RBAC restrito, alerta protegido, dashboard e Argo CD.')
