# Roteiro de gravacao — laboratorio local com Floci

Use este roteiro depois de instalar e validar o ambiente no Mac. O video final
pode ter no maximo 25 minutos. Sugestao: 12 a 18 minutos, mostrando o sistema real.

## Antes de gravar

- Execute `bash local/lab.sh up` e confira `bash local/lab.sh status`.
- Configure as integracoes com `bash local/lab.sh integrations`. As chaves sao
  digitadas ocultas. Nunca grave o cadastro, a listagem de Secrets ou as senhas.
- Abra Grafana (http://localhost:3000), Argo CD (http://localhost:8080), New Relic,
  PagerDuty e o canal Discord. Faca login antes de iniciar a gravacao.
- Se ja demonstrou a falha, aguarde o cooldown de dez minutos. Confirme que nao
  existe um Job `fase4-demo` em execucao antes de iniciar outro.
- Confirme manualmente um trace distribuido e o Service Map no New Relic. O modo
  inicial com exporter debug nao atende ao requisito de APM comercial.

## 1. Contexto e repositorios (2 minutos)

Diga: "O projeto tem cinco microsservicos. A infraestrutura original foi feita
na AWS. Como os creditos do Academy terminaram, esta demonstracao usa Kubernetes
local com kind e Floci para SQS e DynamoDB. PostgreSQL e Redis tambem rodam localmente."

Mostre os repositorios dos servicos e o GitOps, a pasta `local`, o chart de
observabilidade e o workflow de validacao. Explique: Git armazena a configuracao;
Argo CD aplica essa configuracao no cluster; Helm organiza os manifestos.

## 2. GitOps e funcionamento (2 minutos)

Mostre as tres Applications no Argo CD sincronizadas e saudaveis. Rode:

```bash
bash local/lab.sh status
bash local/lab.sh demo start
bash local/lab.sh demo logs
```

Mostre respostas HTTP 200. A carga cria uma flag/regra exclusiva e dura oito
minutos. Ela precisa continuar ativa enquanto voce mostra o alerta e a recuperacao.
Se oito minutos forem insuficientes, encerre essa demonstracao e prepare outra
execucao limpa; nao dependa de carga que ja terminou.

## 3. Metricas e logs (2 minutos)

Abra o dashboard ToggleMaster no Grafana. Mostre CPU, memoria, pods e taxa de
requisicoes. No Explore selecione Loki e consulte:

```logql
{service_namespace="toggle-master"}
```

Ative Live para mostrar logs chegando. Explique: os SDKs e o agente enviam dados
ao Collector; Prometheus guarda metricas; Loki guarda logs; Grafana consulta ambos.
Tire o print do dashboard com dados reais.

## 4. Trace e mapa (2 minutos)

No New Relic, procure os servicos `evaluation-service`, `flag-service`,
`targeting-service`, `auth-service` e `analytics-service`. Abra um trace originado
no evaluation. O cache pode pular flag/targeting/auth em algumas requisicoes;
escolha uma requisicao apos expirar o cache ou a primeira requisicao da fixture.

Mostre as chamadas HTTP e o processamento assincrono via SQS/analytics. Mostre o
Service Map com os cinco servicos. Tire o print do trace. Se algum elo estiver
faltando, isso ainda precisa ser corrigido; nao apresente apenas cinco nomes
isolados como prova de propagacao distribuida.

## 5. Falha, incidente e recuperacao (4 a 6 minutos)

Com a carga ainda rodando, em outro terminal na pasta do GitOps:

```bash
bash local/lab.sh demo fail
bash local/lab.sh demo status
```

Mostre a sequencia:

1. HTTP 500 na carga e aumento da taxa de erros no Grafana.
2. Regra `EvaluationHighErrorRate` entra em Pending e depois Firing.
3. Incidente real no PagerDuty e mensagem detalhada no Discord.
4. Log `restart_requested` no self-healer e novo pod do evaluation.
5. Carga volta a HTTP 200 e o alerta normaliza apos a janela de avaliacao.

Explique: "A falha fica apenas na memoria do processo. O alerta aciona um webhook
interno autenticado. Ele abre o incidente, notifica o canal e solicita o restart
somente do evaluation. Reiniciar remove a falha simulada. Os health checks
permanecem saudaveis durante a falha para demonstrar a automacao pelo alerta."

Nao use `demo recover` ou restart manual para afirmar que a recuperacao foi
automatica. Use-os somente para diagnostico, fora da demonstracao final. O PATCH
aceito sozinho nao prova sucesso: mostre o pod saudavel e a resposta HTTP 200.

Tire os prints do incidente/chat e da execucao/recuperacao automatica.

## 6. Encerramento e PDF (1 minuto)

Explique as escolhas: Floci para continuar o laboratorio sem AWS; Prometheus e
Loki para metricas/logs; OpenTelemetry para instrumentacao e transporte; Grafana
para visualizacao/alerta; New Relic para APM; PagerDuty e Discord para incidente e
comunicacao; RBAC limita o self-healer a um Deployment.

No PDF final inclua nomes, RMs e usuarios dos integrantes, links dos repositorios
e do video, arquitetura e justificativas, e os quatro prints exigidos: dashboard,
trace, incidente no chat e recuperacao automatica. Indique explicitamente que a
demonstracao final e local. Evidencias locais nao comprovam Kubernetes gerenciado
em nuvem; inclua as evidencias anteriores do EKS que realmente possuir.

## O que esta automatizado e o que depende de voce

O instalador prepara o cluster e a stack. O teste local exercita aplicacao,
SQS/DynamoDB, metricas, logs, alerta e restart. Contas/chaves externas, conferencias
no APM/PagerDuty/Discord, instalacao ARM64 no Mac, capturas, gravacao e dados dos
integrantes precisam ser concluidos no ambiente da entrega.
