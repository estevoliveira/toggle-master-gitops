"""Reject stale Healthy status from a previous Argo CD source configuration."""
import json
import sys

app = json.load(sys.stdin)
source = app['spec']['source']
status = app.get('status', {})
sync = status.get('sync', {})
operation = status.get('operationState', {})
ready = (
    sync.get('status') == 'Synced'
    and status.get('health', {}).get('status') == 'Healthy'
    and sync.get('comparedTo', {}).get('source') == source
    and operation.get('phase') == 'Succeeded'
    and operation.get('syncResult', {}).get('source') == source
)
sys.exit(0 if ready else 1)
