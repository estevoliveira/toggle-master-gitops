# Bloco 1 - Metricas reais com Prometheus e Grafana

Objetivo: instalar a fundacao de metricas no EKS e entender uma coleta antes de adicionar logs, traces e resposta automatica.

## O que este bloco instala

| Componente | Papel |
| --- | --- |
| Prometheus | Coleta e armazena series temporais: numeros com horario e labels. |
| node-exporter | Expoe metricas dos nos Linux, como CPU e memoria. |
| kube-state-metrics | Expoe o estado declarado/observado dos objetos Kubernetes, como pods prontos. |
| Prometheus Operator | Converte os objetos Prometheus e ServiceMonitor em configuracao e workloads de monitoramento. |
| Grafana | Consulta o Prometheus e apresenta os resultados em paineis. |
| Argo CD + Helm | Argo CD acompanha o chart e os values no Git e reconcilia os recursos do cluster. |

O chart oficial kube-prometheus-stack esta fixado em 92.17.0 dentro do chart local `apps/observability-metrics`. O codigo do projeto controla a configuracao; nao e necessario instalar Helm no CloudShell.

## Executar no CloudShell

```bash
aws eks update-kubeconfig --region us-east-1 --name toggle-cluster
curl -fsSL --connect-timeout 10 --max-time 60 \
  https://raw.githubusercontent.com/ramondata/toggle-master-gitops/master/scripts/fase4-install-metrics.sh \
  -o /tmp/fase4-install-metrics.sh
bash /tmp/fase4-install-metrics.sh
```

Para reproduzir o bootstrap de um commit especifico, definir `GITOPS_REF` com seu SHA. A Application continua acompanhando `master`, permitindo evoluir values, dashboard e recursos por GitOps.

O bootstrap valida o contexto, descobre o DNS do Load Balancer NGINX existente e cria o namespace `observability`, a credencial aleatoria do Grafana e um certificado autoassinado de laboratorio. Ele registra a Application, aguarda a sincronizacao e verifica o Grafana e o pod do Prometheus. A instalacao pode levar varios minutos por causa do download das imagens e da criacao dos recursos pelo Operator.

O acesso publico utiliza uma regra HTTPS para o hostname do NGINX. Os Services do Grafana e Prometheus continuam ClusterIP. O bootstrap verifica conflitos de rota antes de aplicar; nao cria outro Load Balancer AWS.

## Entrar no Grafana

- URL: impressa pelo bootstrap, no formato `https://<DNS-do-NGINX>`.
- Certificado proprio do laboratorio: no navegador, usar Advanced > Proceed.
- Usuario inicial: `admin`.
- Consultar a senha no proprio CloudShell:

```bash
kubectl -n observability get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

A senha nao e impressa automaticamente no diagnostico nem versionada. Nao e necessario compartilhar a senha para continuar o trabalho.

## Aula pratica de cinco minutos

1. Abrir **Explore**, selecionar **Prometheus** e consultar `up`.
2. Cada serie representa um alvo de coleta. O valor 1 indica que o scrape funcionou; 0 indica falha na coleta desse alvo. Isso nao substitui o teste funcional de negocio.
3. Expandir uma serie e observar labels como `job` e `instance`. Eles identificam e permitem filtrar o que esta sendo medido.
4. Consultar `node_memory_MemAvailable_bytes / 1024 / 1024`. O resultado e memoria disponivel em MiB para cada serie do node-exporter.
5. Abrir o dashboard **ToggleMaster - Fase 4**. Ele usa consultas reais para mostrar CPU dos nos, memoria dos nos, pods prontos e memoria dos pods das aplicacoes.

Perguntas que voce deve conseguir explicar: quem armazena os numeros? Quem consulta? O que identifica uma serie? Por que ter dados no Grafana nao comprova que o consumidor gravou no DynamoDB?

## Escopo e continuidade

Este bloco implementa metricas de infraestrutura e os paineis iniciais. Taxa de requisicoes dos microsservicos, painel de logs, Loki, OTel Collector, instrumentacao, APM, alertas e self-healing ainda serao adicionados. O receiver OTLP do Prometheus esta habilitado internamente para a proxima integracao com o Collector.

A validacao funcional da etapa 2 permanece um checkpoint da entrega. Podemos coletar metricas enquanto verificamos esse fluxo; o resultado de negocio precisa ser comprovado antes da gravacao final.

As configuracoes usam uma replica de Prometheus e armazenamento temporario para laboratorio. Reiniciar o pod pode perder o historico local. O dashboard e provisionado pelo Git, e a credencial fica no Secret. Futuras regras e configuracoes de alertas tambem devem ser versionadas para reproduzir a demonstracao.

Os componentes reservam aproximadamente 0,45 CPU e 0,8 GiB, distribuidos entre os pods, incluindo um node-exporter por no para o ultimo cenario de tres nos. Esse e um orcamento de requests, nao uma garantia de consumo real. O bootstrap consulta a disponibilidade atual dos nos; a saida dos pods e dos eventos continua necessaria para confirmar a instalacao.

## Conferir e enviar o resultado

```bash
kubectl -n argocd get application observability-metrics
kubectl -n observability get pods
kubectl -n observability get ingress grafana
```

Confirmar Application Synced/Healthy, Prometheus e Grafana prontos, acesso ao painel e dados reais em `up`. Se o bootstrap parar, enviar os erros e o estado impresso; ele nao redefine a senha de um Secret existente nem altera as imagens dos cinco microsservicos.
