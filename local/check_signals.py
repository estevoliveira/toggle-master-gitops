"""Read-only proof that the local stack receives metrics and application logs."""
import json
import subprocess
import time
import urllib.parse


def query(service, path):
    url = '/api/v1/namespaces/observability/services/' + service + '/proxy' + path
    return json.loads(subprocess.check_output(['kubectl', '--context', 'kind-toggle-floci', 'get', '--raw', url]))

expected = {'auth-service', 'flag-service', 'targeting-service', 'evaluation-service', 'analytics-service'}
for attempt in range(45):
    result = query('monitoring-prometheus:9090', '/api/v1/query?' + urllib.parse.urlencode({
        'query': 'count by(service_name)(toggle_http_requests_total)'}))
    names = {item['metric'].get('service_name') for item in result.get('data', {}).get('result', [])}
    logs = query('loki:3100', '/loki/api/v1/query_range?' + urllib.parse.urlencode({
        'query': '{service_namespace="toggle-master"}', 'limit': 5, 'since': '10m'}))
    if expected <= names and logs.get('data', {}).get('result'):
        print('Metrics received from all five services; application logs received by Loki.')
        break
    time.sleep(2)
else:
    raise SystemExit('Missing telemetry: metrics services=' + repr(names) + '; Loki app logs not confirmed')
