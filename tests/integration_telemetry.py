"""Exercita os binarios reais: OTLP -> Collector -> Prometheus/Loki/APM de teste."""
import json
import time
import urllib.parse
import urllib.request


def send(path, payload):
    req = urllib.request.Request('http://localhost:4318/v1/' + path,
                                 data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as response:
        assert response.status == 200


now = time.time_ns()
resource = {'attributes': [{'key': 'service.name', 'value': {'stringValue': 'evaluation-service'}},
                           {'key': 'service.namespace', 'value': {'stringValue': 'toggle-master'}}]}
send('metrics', {'resourceMetrics': [{'resource': resource, 'scopeMetrics': [{'metrics': [{
    'name': 'toggle_http_requests', 'sum': {'aggregationTemporality': 2, 'isMonotonic': True,
    'dataPoints': [{'asInt': '7', 'timeUnixNano': str(now), 'startTimeUnixNano': str(now - 1000000000),
                    'attributes': [{'key': 'status_code', 'value': {'stringValue': '500'}}]}]}}]}]}]})
send('logs', {'resourceLogs': [{'resource': resource, 'scopeLogs': [{'logRecords': [{
    'timeUnixNano': str(now), 'body': {'stringValue': 'fase4-real-pipeline-test'}, 'severityNumber': 9}]}]}]})
send('traces', {'resourceSpans': [{'resource': resource, 'scopeSpans': [{'spans': [{
    'traceId': '0123456789abcdef0123456789abcdef', 'spanId': '0123456789abcdef',
    'name': 'GET /evaluate', 'kind': 2, 'startTimeUnixNano': str(now),
    'endTimeUnixNano': str(now + 1000000)}]}]}]})

for attempt in range(30):
    try:
        with urllib.request.urlopen('http://localhost:8889/metrics', timeout=5) as response:
            metrics = response.read().decode()
        assert 'toggle_http_requests_total' in metrics
        assert 'service_name="evaluation-service"' in metrics
        assert 'status_code="500"' in metrics
        query = urllib.parse.urlencode({'query': '{service_namespace="toggle-master"} |= "fase4-real-pipeline-test"'})
        with urllib.request.urlopen('http://localhost:3100/loki/api/v1/query_range?' + query, timeout=5) as response:
            logs = json.load(response)
        assert logs['data']['result'], 'Loki nao retornou o log enviado pelo Collector'
        with urllib.request.urlopen('http://localhost:9000/count', timeout=5) as response:
            assert json.load(response)['traces'] > 0
        print('PASS: OTLP de metricas, logs e traces atravessou Collector e backends reais de teste.')
        break
    except (OSError, AssertionError):
        if attempt == 29:
            raise
        time.sleep(2)
