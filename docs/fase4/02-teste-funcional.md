# Fase 4 - Etapa 2: comprovar o fluxo funcional

O diagnostico inicial mostrou tres nos Ready, oito pods das aplicacoes prontos e as seis Applications Synced/Healthy. O flag-service da imagem publicada devolve `status: OK`; o preflight foi corrigido para aceitar tanto `ok` quanto `OK`, mantendo a rejeicao de status de erro e de tipos inesperados.

## Objetivo

Comprovar uma operacao de negocio envolvendo os cinco microsservicos e observar o evento produzido pela aplicacao chegar ao DynamoDB. Este mesmo teste podera gerar trafego para mostrar traces depois da instrumentacao.

## Executar no CloudShell

```bash
curl -fsSL --connect-timeout 10 --max-time 30 \
  https://raw.githubusercontent.com/ramondata/toggle-master-gitops/master/scripts/fase4-smoke.py \
  -o /tmp/fase4-smoke.py
python3 /tmp/fase4-smoke.py
```

O CloudShell precisa de Python 3, AWS CLI e kubectl. O script confirma o contexto EKS antes de executar o teste. Ele usa o boto3 que ja existe no container do analytics-service.

## O que o teste faz

1. Le a chave existente em `academy-databases/service-api-key`, sem imprimi-la nem coloca-la nos argumentos do processo remoto.
2. Executa um programa auxiliar no pod do analytics-service. A configuracao privada e transmitida pelo stdin do `kubectl exec`.
3. Valida a chave no auth-service.
4. Cria uma flag habilitada com identificador exclusivo, prefixado por `phase4-smoke-`, e confirma sua leitura no flag-service.
5. Cria uma regra PERCENTAGE=100 para essa flag e confirma sua leitura no targeting-service.
6. Faz uma chamada ao evaluation-service com um usuario exclusivo e verifica `result=true`.
7. Aguarda o evento dessa operacao aparecer no DynamoDB, correlacionando `user_id`, `flag_name` e `result`. O teste apenas consulta a tabela; quem publica no SQS e grava o evento e a aplicacao.
8. Tenta remover somente a flag e a regra que o proprio teste conseguiu criar. O evento de avaliacao permanece no DynamoDB.

Isso escreve dados temporarios de demonstracao nas APIs e produz um evento real. O teste nao publica imagens, nao altera deployments e nao cria chaves novas de API. Uma criacao rejeitada com HTTP 409 nao autoriza a exclusao de dados preexistentes.

## Explicacao minima

O evaluation-service consulta a flag e a regra, usa Redis na logica de cache e publica o resultado em uma fila SQS. O analytics-service consome essa fila e grava no DynamoDB. Encontrar um registro com os identificadores exclusivos do teste comprova a passagem do evento por essa cadeia; um simples `/health` nao demonstra isso.

O teste nao mede a eficacia do cache nem comprova a propagacao de contexto de traces. Essas evidencias pertencem as proximas etapas de observabilidade.

## Interpretacao

- `RESULTADO: FLUXO FUNCIONAL CONFIRMADO`: as operacoes e a persistencia do evento foram confirmadas e a limpeza da fixture passou.
- HTTP 401/403: conferir chave de servico e sua validade no auth-service.
- HTTP 500/502 ou timeout: identificar a etapa impressa e verificar a dependencia correspondente.
- Evento nao encontrado: investigar publicacao SQS, processamento do consumidor, tabela e credenciais usadas pelos pods. O HTTP 200 do evaluation-service sozinho nao confirma a parte assincrona.
- `AccessDeniedException` durante Scan: falta permissao para a verificacao de leitura; isso, isoladamente, nao prova que PutItem esta falhando. Nao ampliar permissoes automaticamente.
- Falha de limpeza: usar o identificador exclusivo impresso para revisar os dados de demonstracao que restaram.

A verificacao faz ate 12 rodadas de leitura, com intervalo de cinco segundos e paginacao limitada a 20 paginas por rodada. O resultado e inconclusivo se atingir esse limite. Em laboratorio pequeno, normalmente termina assim que o consumidor grava o evento.

## Validacao do codigo

Os testes de contrato locais/CI usam APIs simuladas para verificar isolamento das fixtures, limpeza, correlacao do evento, paginacao e caminhos de erro. Eles nao substituem a execucao real no EKS. O workflow tambem compila o Python e valida o Bash com ShellCheck.
