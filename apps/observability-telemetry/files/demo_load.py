"""Carga pequena com fixtures proprias; nao altera flags existentes."""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

KEY = os.environ['SERVICE_API_KEY']
NAME = 'fase4-demo-' + uuid.uuid4().hex[:12]
USER = 'fase4-user-' + uuid.uuid4().hex[:12]
BASES = {'flag': 'http://flag-service:8002', 'rule': 'http://targeting-service:8003'}


def call(base, path, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={'Authorization': 'Bearer ' + KEY,
                                          'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=8) as response:
            return response.status, response.headers.get('X-Trace-ID', '')
    except urllib.error.HTTPError as error:
        return error.code, ''


owned = []
try:
    status, _ = call(BASES['flag'], '/flags', 'POST',
                     {'name': NAME, 'description': 'Fixture exclusiva fase4', 'is_enabled': True})
    if status != 201:
        raise SystemExit('Nao foi possivel criar a flag da demonstracao; HTTP ' + str(status))
    owned.append(('flag', '/flags/' + NAME))
    status, _ = call(BASES['rule'], '/rules', 'POST',
                     {'flag_name': NAME, 'is_enabled': True, 'rules': {'type': 'PERCENTAGE', 'value': 100}})
    if status != 201:
        raise SystemExit('Nao foi possivel criar a regra; HTTP ' + str(status))
    owned.append(('rule', '/rules/' + NAME))
    # 8 minutos permitem mostrar baseline, erro, Firing, restart e normalizacao.
    for index in range(480):
        # Limpa somente o cache da fixture? Nao: o cache natural de 30s e preservado.
        query = urllib.parse.urlencode({'user_id': USER, 'flag_name': NAME})
        try:
            status, trace = call('http://evaluation-service:8004', '/evaluate?' + query)
            print(json.dumps({'request': index, 'status': status, 'trace_id': trace,
                              'flag': NAME}), flush=True)
        except OSError:
            print(json.dumps({'request': index, 'status': 'connection_error'}), flush=True)
        time.sleep(1)
finally:
    for service, path in reversed(owned):
        try:
            status, _ = call(BASES[service], path, 'DELETE')
            print(json.dumps({'cleanup': service, 'status': status}), flush=True)
        except OSError:
            print(json.dumps({'cleanup': service, 'status': 'failed', 'fixture': NAME}), flush=True)
