#!/usr/bin/env python3
"""Testa o fluxo real do ToggleMaster pelo CloudShell, usando apenas stdlib local."""

import base64
import json
import os
import shutil
import subprocess
import sys


REMOTE_CODE = r'''
import json
import os
import sys
import time
import uuid
from urllib import error, parse, request


class SmokeFailure(Exception):
    pass


def safe_error(exc):
    if isinstance(exc, SmokeFailure):
        return str(exc)
    response = getattr(exc, "response", {})
    code = response.get("Error", {}).get("Code", "") if isinstance(response, dict) else ""
    if isinstance(code, str) and code.replace("_", "").isalnum():
        return type(exc).__name__ + " (" + code[:80] + ")"
    return type(exc).__name__


def http_call(base, path, method, api_key, expected, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = request.Request(base + path, data=body, method=method)
    req.add_header("Authorization", "Bearer " + api_key)
    req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=10) as response:
            if response.status not in expected:
                raise SmokeFailure(method + " " + path + ": HTTP " + str(response.status))
            return response.read()
    except error.HTTPError as exc:
        status = exc.code
        exc.close()
        if status in expected:
            return b""
        raise SmokeFailure(method + " " + path + ": HTTP " + str(status)) from None
    except (error.URLError, TimeoutError, OSError):
        raise SmokeFailure(method + " " + path + ": falha de conexao/timeout") from None


def run_flow(config, api=None, dynamodb=None, sleep=time.sleep):
    namespace = config["namespace"]
    key = config["api_key"]
    suffix = uuid.uuid4().hex[:16]
    flag = "phase4-smoke-" + suffix
    user = "phase4-user-" + suffix
    services = {
        "auth": "http://auth-service." + namespace + ".svc.cluster.local:8001",
        "flag": "http://flag-service." + namespace + ".svc.cluster.local:8002",
        "targeting": "http://targeting-service." + namespace + ".svc.cluster.local:8003",
        "evaluation": "http://evaluation-service." + namespace + ".svc.cluster.local:8004",
    }
    result = {"ok": False, "flag_name": flag, "user_id": user, "checks": [], "cleanup_errors": []}
    created = []
    api = api or http_call

    def checked(message):
        result["checks"].append(message)
        print("[OK] " + message, file=sys.stderr, flush=True)

    def call(service, path, method="GET", expected=(200,), payload=None):
        return api(services[service], path, method, key, expected, payload)

    print("Teste isolado: " + flag + " | " + user, file=sys.stderr, flush=True)
    try:
        table = os.environ.get("AWS_DYNAMODB_TABLE")
        region = os.environ.get("AWS_REGION")
        if not table or not region:
            raise SmokeFailure("AWS_DYNAMODB_TABLE/AWS_REGION ausente no pod analytics")

        call("auth", "/validate")
        checked("auth-service validou a chave existente")

        call("flag", "/flags", "POST", (201,), {
            "name": flag, "description": "Fixture temporaria da Fase 4", "is_enabled": True,
        })
        created.append(("flag", "/flags/" + flag))
        flag_data = json.loads(call("flag", "/flags/" + flag))
        if flag_data.get("name") != flag or flag_data.get("is_enabled") is not True:
            raise SmokeFailure("flag-service nao confirmou a flag habilitada")
        checked("flag-service gravou e leu a flag de teste no PostgreSQL")

        call("targeting", "/rules", "POST", (201,), {
            "flag_name": flag, "is_enabled": True,
            "rules": {"type": "PERCENTAGE", "value": 100},
        })
        created.append(("targeting", "/rules/" + flag))
        rule = json.loads(call("targeting", "/rules/" + flag))
        if rule.get("flag_name") != flag or rule.get("rules") != {"type": "PERCENTAGE", "value": 100}:
            raise SmokeFailure("targeting-service nao confirmou a regra de teste")
        checked("targeting-service gravou e leu a regra de teste no PostgreSQL")

        query = parse.urlencode({"user_id": user, "flag_name": flag})
        evaluation = json.loads(call("evaluation", "/evaluate?" + query))
        if (evaluation.get("result") is not True or evaluation.get("flag_name") != flag
                or evaluation.get("user_id") != user):
            raise SmokeFailure("evaluation-service nao retornou a decisao esperada")
        checked("evaluation-service retornou result=true para a regra de 100%")

        if dynamodb is None:
            import boto3
            from botocore.config import Config
            dynamodb = boto3.Session(region_name=region).client(
                "dynamodb", config=Config(connect_timeout=3, read_timeout=5,
                                         retries={"total_max_attempts": 1}))

        print("Aguardando o evento passar por SQS e analytics-service...", file=sys.stderr, flush=True)
        for attempt in range(12):
            options = {
                "TableName": table,
                "FilterExpression": "#u = :u AND #f = :f",
                "ExpressionAttributeNames": {"#u": "user_id", "#f": "flag_name", "#r": "result"},
                "ExpressionAttributeValues": {":u": {"S": user}, ":f": {"S": flag}},
                "ProjectionExpression": "event_id,#u,#f,#r",
                "ConsistentRead": True,
            }
            for page_number in range(20):
                page = dynamodb.scan(**options)
                for item in page.get("Items", []):
                    if (item.get("user_id", {}).get("S") == user
                            and item.get("flag_name", {}).get("S") == flag
                            and item.get("result", {}).get("BOOL") is True
                            and item.get("event_id", {}).get("S")):
                        checked("Evento exclusivo do teste encontrado no DynamoDB: SQS/analytics comprovados")
                        result["ok"] = True
                        return result
                last_key = page.get("LastEvaluatedKey")
                if not last_key:
                    break
                if page_number == 19:
                    raise SmokeFailure("Verificacao limitada a 20 paginas de Scan; resultado inconclusivo")
                options["ExclusiveStartKey"] = last_key
            if attempt < 11:
                sleep(5)
        raise SmokeFailure("Evento nao confirmado no DynamoDB apos 12 consultas; verificar SQS, consumer e credenciais dos pods")
    except Exception as exc:
        result["error"] = safe_error(exc)
        print("[FALHA] " + result["error"], file=sys.stderr, flush=True)
        return result
    finally:
        for service, path in reversed(created):
            try:
                call(service, path, "DELETE", (204, 404))
            except Exception as exc:
                result["ok"] = False
                result["cleanup_errors"].append(service + ": " + safe_error(exc))
                print("[FALHA] Limpeza da fixture em " + service, file=sys.stderr, flush=True)
        if created and not result["cleanup_errors"]:
            print("[OK] Flag/regra criadas pelo teste foram removidas; evento mantido no DynamoDB", file=sys.stderr, flush=True)


if __name__ == "__main__":
    output = run_flow(json.load(sys.stdin))
    print(json.dumps(output), flush=True)
    sys.exit(0 if output["ok"] else 1)
'''


def capture(arguments):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, timeout=30, check=False)
    if result.returncode:
        raise RuntimeError("Falha ao executar " + arguments[0] + "; confira a mensagem acima")
    return result.stdout.strip()


def main():
    for executable in ("aws", "kubectl"):
        if not shutil.which(executable):
            raise RuntimeError("Comando ausente: " + executable)
    cluster = os.getenv("TARGET_CLUSTER", "toggle-cluster")
    region = os.getenv("TARGET_REGION", "us-east-1")
    namespace = os.getenv("APP_NAMESPACE", "toggle-master")
    endpoint = capture(["aws", "eks", "describe-cluster", "--name", cluster,
                        "--region", region, "--query", "cluster.endpoint", "--output", "text", "--no-cli-pager"])
    current = capture(["kubectl", "config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}"])
    if not endpoint or endpoint == "None" or endpoint != current:
        raise RuntimeError("Contexto diferente do cluster alvo; reconecte ao " + cluster)

    encoded_key = capture(["kubectl", "--request-timeout=15s", "-n", namespace, "get", "secret",
                           "academy-databases", "-o", "jsonpath={.data.service-api-key}"])
    if not encoded_key:
        raise RuntimeError("Secret academy-databases/service-api-key ausente ou vazio")
    api_key = base64.b64decode(encoded_key, validate=True).decode()
    if not api_key:
        raise RuntimeError("A chave de servico existente esta vazia")

    print("Teste funcional dos cinco servicos. Cria flag/regra temporarias e observa um evento real.", flush=True)
    command = ["kubectl", "-n", namespace, "exec", "-i", "deployment/analytics-service", "--", "python", "-c", REMOTE_CODE]
    completed = subprocess.run(command, input=json.dumps({"namespace": namespace, "api_key": api_key}),
                               text=True, stdout=subprocess.PIPE, timeout=180, check=False)
    try:
        output = json.loads(completed.stdout)
    except (ValueError, TypeError):
        raise RuntimeError("Sem resultado JSON do teste remoto; conferir permissao de exec e disponibilidade do pod analytics") from None
    if completed.returncode == 0 and output.get("ok") is True:
        print("RESULTADO: FLUXO FUNCIONAL CONFIRMADO. Podemos seguir para a stack de observabilidade.")
        return 0
    print("RESULTADO: TESTE FUNCIONAL NAO CONCLUIDO. Envie as linhas FALHA e o identificador da fixture.")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.TimeoutExpired:
        print("[FALHA] Tempo limite do comando; o processo remoto pode ainda estar finalizando a fixture.", file=sys.stderr)
        sys.exit(2)
    except Exception as exc:
        # Mensagens de validacao sao controladas; valores de Secrets e respostas HTTP nao sao impressos.
        message = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        print("[FALHA] " + message, file=sys.stderr)
        sys.exit(2)
