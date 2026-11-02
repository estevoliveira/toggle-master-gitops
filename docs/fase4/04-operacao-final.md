# Fase 4: operacao simples e verificacao

## O que esta no codigo

- Prometheus + Grafana instalados pelo chart ja existente.
- Loki monolitico, com armazenamento temporario e retencao de 24h.
- Collector gateway: recebe OTLP e encaminha metricas ao exporter Prometheus, logs ao Loki e traces ao New Relic.
- Collector DaemonSet: le stdout/stderr de todos os containers de cada no e encaminha logs ao gateway. Checkpoints ficam no no; nao sao backup.
- SDKs OTel nos cinco repositorios; requests HTTP propagam traceparent. Evaluation inclui o contexto nas MessageAttributes da SQS e analytics extrai esse contexto ao consumir.
- Dashboard com infraestrutura, requisicoes HTTP/s (inclui probes de saude) e logs. Explore > Loki > Live mostra logs ao vivo.
- Grafana avalia 5xx/total > 5% por 45s, usando janela de 2m. Ausencia de dados nao dispara o runbook; falhas de datasource nao autorizam restart.
- Webhook interno autenticado abre incidente PagerDuty Events v2, notifica Discord e pede rollout restart do evaluation. RBAC permite get/patch apenas nesse Deployment.
- Cooldown de 10 minutos evita restarts repetidos enquanto a janela de erros ainda nao normalizou. Estado e em memoria e e perdido se o proprio healer for recriado.

## Contas externas (uma vez)

1. New Relic: criar conta, selecionar a regiao US ou EU e obter uma chave **INGEST license key**, nao uma user/API key administrativa. Os cinco service.name devem aparecer no mesmo account.
2. PagerDuty: criar Service com integracao **Events API v2**, escalation policy que notifique o responsavel e copiar a Integration/Routing Key de 32 caracteres. Conferir que o servico nao esta em manutencao.
3. Discord: em um canal de teste, Integrations > Webhooks > criar webhook e copiar a URL. As mensagens de teste e incidente irao para esse canal.

Nao colocar essas chaves no Git nem enviar pelo chat. O instalador solicita no terminal com entrada oculta. Use NEW_RELIC_REGION=EU se a conta for europeia; padrao US. Para trocar chaves, ROTATE_INTEGRATIONS=true.

## Instalacao (CloudShell)

Com a sessao Academy valida, publique as imagens pela esteira existente dos cinco servicos (branch aws-cloud-k8s). Se a sessao expirar, atualize AWS_ACADEMY_CREDENTIALS nos repositorios e reexecute os workflows que falharam. As versoes antigas nao exportam telemetria; nao basta instalar o Collector.

Baixe scripts/fase4-install-telemetry.sh do commit revisado e execute com bash. O script usa o cluster toggle-cluster em us-east-1, prepara Secrets e registra a Application observability-telemetry. Nunca copia a chave comercial para os microsservicos.

Reaplica o ApplicationSet com a excecao da anotacao de restart para evitar o Argo CD desfazer a mitigacao. O ConfigMap fase4-telemetry configura o endpoint dos cinco servicos. Os Deployments existentes fazem referencia opcional a ele, preservando o bootstrap da fase anterior.

## Verificacao obrigatoria antes de gravar

- kubectl -n argocd get applications: observar Synced/Healthy.
- kubectl -n observability get pods: nenhum Pending, CrashLoop ou ImagePullBackOff.
- kubectl -n observability logs deployment/otel-gateway --tail=50: procurar erros de exportacao; 401/403 do New Relic requerem corrigir chave/regiao.
- Grafana Explore > Prometheus: consultar `toggle_http_requests_total`; conferir service_name dos cinco servicos apos gerar trafego.
- Grafana Explore > Loki: `{service_namespace="toggle-master"}` para logs OTLP; `{k8s_namespace_name="kube-system"}` para logs coletados de outros namespaces.
- Explore > Loki > Live para a demonstracao de logs em tempo real. Dashboard atualiza a cada 15s.
- New Relic > APM & Services: conferir os cinco servicos e Service Map. Buscar o trace_id impresso pela carga. O cache de 30s pode fazer alguns traces nao passarem por flag/targeting/auth; usar uma requisicao com cache miss (primeira ou apos TTL).
- O trace da fila e assincrono: aguardar o consumo no analytics antes de procurar os spans completos. Um trace do evaluation com cache miss conecta evaluation -> flag/targeting -> auth e evaluation -> SQS -> analytics.

## Prova real de incidente

Em CloudShell, baixe scripts/fase4-demo.sh do mesmo commit.

1. `bash /tmp/fase4-demo.sh start`: cria Job de carga de 8 minutos (~1 requisicao/s), flag e regra exclusivas, usando a API key existente. Um Job anterior com o mesmo nome deve terminar e ser removido antes de criar outro.
2. `bash /tmp/fase4-demo.sh logs`: acompanhar respostas 200 e guardar um trace_id.
3. Abrir Grafana Alerting > EvaluationHighErrorRate, PagerDuty e o canal Discord.
4. `bash /tmp/fase4-demo.sh fail`: injeta falha apenas na rota /evaluate. Probes continuam OK. A falha e em memoria; restart a remove.
5. Aguardar a janela/coleta/pendencia (tipicamente alguns minutos). Mostrar estado Firing, incidente PagerDuty e mensagem Discord. Nao executar restart manual.
6. `kubectl -n observability logs deployment/self-healer --tail=50`: mostrar alert_received, notification_sent e restart_requested. PATCH aceito nao e confirmacao do rollout.
7. `kubectl -n toggle-master rollout status deployment/evaluation-service --timeout=180s`: mostrar pods novos e sucesso. Job deve voltar a registrar 200.
8. Mostrar alerta normalizado e incidente resolvido. A janela de 2m precisa esvaziar antes da resolucao.
9. Se algo falhar, `bash /tmp/fase4-demo.sh recover` desativa a falha manualmente. Isso e recuperacao de emergencia, nao evidencia de self-healing.
10. A carga remove somente a flag/regra que criou ao terminar normalmente. Se o Job for interrompido, conferir o nome fase4-demo-* nos logs e limpar apenas essas fixtures. Eventos de avaliacao permanecem na tabela como evidencia do fluxo real.

O teste de integracao no GitHub usa um receptor APM de teste para verificar o transporte, sem credenciais. Isso NAO comprova ingestao comercial, Service Map, notificacao externa ou EKS: esses itens so ficam concluidos apos a verificacao acima.

## Limites assumidos do laboratorio

Single replica, dados temporarios, certificados autoassinados e amostragem de traces 100%. Nao e configuracao de producao. Nao cria novos Load Balancers nem bancos AWS. Consome pods/memoria adicionais nos nos existentes. Verificar capacidade e saldo antes de executar. Encerrar sessao Academy nao deve ser tratado como garantia de custo zero.

## Entrega

O roteiro final do video (ate 25min) e o PDF com nomes/RMs/usernames/links e quatro prints serao fechados apos o teste real. Nao marcar integrações, Service Map ou recuperacao como demonstrados sem evidencia. Fontes: enunciado Fase 4, docs oficiais OpenTelemetry, Prometheus, Grafana Loki, New Relic OTLP e PagerDuty Events API v2.
