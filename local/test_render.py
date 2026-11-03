"""Local deployment contracts: no AWS images, correct URLs, real local telemetry."""
import sys
import yaml

def read(path):
    return [x for x in yaml.safe_load_all(open(path)) if x]

apps, metrics, aws, telemetry = map(read, sys.argv[1:])
services = [x for x in apps if x['kind'] == 'Deployment' and x['metadata']['name'].endswith('-service')]
assert len(services) == 5
for obj in services:
    container = obj['spec']['template']['spec']['containers'][0]
    assert container['image'].startswith('toggle-local/')
    assert container['imagePullPolicy'] == 'Never'
assert not any(x['kind'] == 'Ingress' for x in metrics)
for docs, expected in [(metrics,'http://localhost:3000/'), (aws,'https://aws.example.test/')]:
    config = next(x for x in docs if x['metadata']['name'] == 'grafana-public-url')
    assert config['data']['root-url'] == expected, config
config = next(x for x in telemetry if x['metadata']['name'] == 'gateway-config')
gateway = yaml.safe_load(config['data']['config.yaml'])
assert gateway['service']['pipelines']['traces']['exporters'] == ['debug']
assert 'otlphttp/newrelic' not in gateway['exporters']
print('Local contracts passed; AWS defaults preserved.')
