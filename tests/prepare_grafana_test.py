from pathlib import Path
import sys
import yaml

objects = list(yaml.safe_load_all(Path(sys.argv[1]).read_text()))
grafana = next(x for x in objects if isinstance(x, dict) and x.get('kind') == 'Deployment' and x['metadata']['name'] == 'grafana')
image = next(c['image'] for c in grafana['spec']['template']['spec']['containers'] if c['name'] == 'grafana')
Path('/tmp/grafana-image').write_text(image)
Path('/tmp/fase4-datasource.yaml').write_text(yaml.safe_dump({'apiVersion': 1, 'datasources': [
    {'name': 'Prometheus', 'uid': 'prometheus', 'type': 'prometheus', 'access': 'proxy', 'url': 'http://prometheus:9090', 'isDefault': True}]}))
