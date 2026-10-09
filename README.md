# si-infra

Infraestrutura: docker-compose local (PostgreSQL, Redis, RabbitMQ, Keycloak, Open Wearables, Grafana), configuração do realm Keycloak e scripts de deploy.

Parte do SeniorInsight — ver o Documento de Arquitetura de Software (seção 6) para as convenções.

Branches: `main` (principal, protegida) e `develop` (testes). Trabalhe em branches curtas por issue e abra PR para `develop`.

## Kanban da organização

O workflow `Sincronizar Kanban` (`.github/workflows/sync-kanban.yml`) mantém o quadro único **SeniorInsight Kanban** com as issues abertas que têm a label `mvp` nos repositórios da organização. Para pôr uma issue no quadro, basta a label. Roda a cada 4 horas e pode ser disparado à mão em Actions. Precisa do secret `KANBAN_TOKEN` neste repositório (PAT clássico com os escopos `project`, `repo` e `read:org`).

Colunas: Backlog, A fazer, Em andamento, Em revisão e Concluído. Issue nova entra em Backlog se o título começa com `HU-` e em A fazer se não. Itens já presentes no quadro não são movidos pelo workflow. Issue fechada como concluída vai para Concluído; fechada como duplicada ou não planejada, sem a label ou PR sai do quadro.
