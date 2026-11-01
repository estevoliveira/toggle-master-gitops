# Fase 4 - Etapa 1: verificar a base

Objetivo: verificar a disponibilidade inicial do ToggleMaster e levantar capacidade antes de adicionar Prometheus, Loki, Grafana e OTel Collector.

## O que ja existe no codigo

- Os cinco charts Helm sao declarados no ApplicationSet de `argocd/applicationset.yaml`.
- O GitOps acompanha `master`. As ultimas publicacoes de imagens dos microsservicos ocorreram na branch `aws-cloud-k8s`.
- Os workflows reutilizaveis possuem testes, lint, SCA com Trivy e SAST com gosec/Bandit.
- O modulo Terraform do AWS Academy declara o EKS e um node group de duas instancias `t3.medium`, com minimo 1 e maximo 3. O script consulta o estado real; ele pode diferir dessa declaracao.
- A stack de observabilidade ainda sera adicionada ao GitOps nas proximas etapas.

## Executar no AWS CloudShell

```bash
aws eks update-kubeconfig --region us-east-1 --name toggle-cluster
curl -fsSL --connect-timeout 10 --max-time 30 \
  https://raw.githubusercontent.com/ramondata/toggle-master-gitops/master/scripts/fase4-preflight.sh \
  -o /tmp/fase4-preflight.sh
bash /tmp/fase4-preflight.sh
```

O script usa AWS CLI, kubectl e jq. Ele consulta a sessao AWS, compara o endpoint do contexto com o cluster alvo e verifica:

1. Nos Ready, agendamento habilitado, recursos reservados e uso atual quando Metrics Server estiver disponivel.
2. Replicas disponiveis e rollout observado dos cinco deployments.
3. Pods, HPAs e ResourceQuota do namespace `toggle-master`.
4. EndpointSlices com destinos prontos e `GET /health` de cada servico, pelo proxy autenticado da API Kubernetes.
5. Disponibilidade do `argocd-server`, estado Synced/Healthy das seis Applications e URL declarada de seu Load Balancer.
6. Eventos Warning das aplicacoes.

O diagnostico faz consultas de leitura e chamadas GET de health. Nao aplica manifests, nao reinicia workloads e nao consulta objetos Secret nem imprime variaveis de ambiente ou logs das aplicacoes. O comando `update-kubeconfig` modifica somente a configuracao local de acesso.

## Como interpretar

- `[OK]`: a verificacao passou.
- `[FALHA]`: existe um bloqueio ou nao foi possivel confirmar uma verificacao obrigatoria. O script termina com codigo 1 quando encontra falhas.
- `[AVISO]`: uma verificacao complementar ficou indisponivel ou precisa ser avaliada. Ausencia de Metrics Server e falta de permissao `services/proxy` aparecem como avisos; portanto, zero falhas com avisos nao significa que todos os testes foram executados.
- Codigo 2: dependencia local, sessao AWS ou contexto de cluster impediram a execucao.

Enviar a saida do diagnostico, principalmente as linhas FALHA/AVISO, a capacidade dos nos e o resumo final. O script nao corrige os problemas encontrados automaticamente.

## Explicacao minima

- **Deployment:** declara quantas replicas da aplicacao devem executar e qual versao deve estar nos pods.
- **Ready:** o pod pode receber trafego. Um pod Running ainda pode nao estar Ready.
- **Service:** fornece um endereco estavel e seleciona os pods que atenderao as chamadas.
- **EndpointSlice:** registra os enderecos dos pods por tras do Service e sua prontidao.
- **Requests:** recursos reservados usados pelo scheduler para decidir onde o pod cabe. Uso baixo agora nao garante espaco para novos requests.
- **Synced/Healthy:** o Argo CD reconhece a configuracao sincronizada e os recursos saudaveis.

Os endpoints `/health` atuais devolvem status simples. Eles nao comprovam todas as operacoes de PostgreSQL, Redis, SQS e DynamoDB. Depois deste diagnostico, o proximo checkpoint e validar um fluxo funcional real antes de marcar a base completa.

## Criterio de pronto desta etapa

Saida analisada, bloqueios iniciais identificados/corrigidos e capacidade avaliada. O resultado do script, sozinho, nao substitui o teste funcional nem a demonstracao das fases anteriores.
