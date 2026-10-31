# si-infra

Infraestrutura: docker-compose local (PostgreSQL, Redis, RabbitMQ, Keycloak, Open Wearables, Grafana), configuração do realm Keycloak e scripts de deploy.

Parte do SeniorInsight — ver o Documento de Arquitetura de Software (seção 6) para as convenções.

Branches: `main` (principal, protegida) e `develop` (testes). Trabalhe em branches curtas por issue e abra PR para `develop`.

## Ambiente local

Este repositório é o ponto de entrada do Docker Compose local. Os contextos de build apontam para os repositórios irmãos; os Dockerfiles permanecem junto ao código de cada serviço.

1. Copie `.env.example` para `.env` e ajuste as credenciais locais, se necessário.
2. Na raiz de `si-infra-main`, execute:

   ```bash
   docker compose up --build
   ```

   No PowerShell, use `Copy-Item .env.example .env` para criar o arquivo de ambiente.

3. Para encerrar sem apagar os dados, execute `docker compose down`. Para recriar os bancos do zero, execute `docker compose down -v`.

O Compose atual inclui PostgreSQL 17, Redis 7, RabbitMQ 3.13, Keycloak 26, `backend-core`, `identity-service` e `api-gateway`. A única aplicação publicada no host é o gateway (porta padrão `8080`); os serviços backend ficam na rede interna do Compose. PostgreSQL contém os schemas dos serviços e `keycloak`; o volume de inicialização cria o schema Keycloak em uma instalação nova.

O realm `seniorinsight` é importado de `keycloak/realm-seniorinsight.json`. A URL de issuer usada nos tokens locais é `http://localhost:8180/realms/seniorinsight`; o `identity-service` usa o endereço interno do container apenas para buscar as chaves JWKS e valida o issuer público. O realm ainda não configura clientes OIDC: eles serão definidos junto ao gateway e aos canais quando seus identificadores e fluxos estiverem implementados.

O gateway encaminha `/api/v1/**` para o `backend-core` e `/api/v1/identity/**` para o `identity-service`, convertendo este último para a rota interna `/v1/**`. O `backend-core` ainda usa JWT HMAC próprio; o gateway só exige JWT Keycloak nas rotas de identidade para não quebrar o fluxo atual. O serviço de notificações ainda não tem aplicação ou Dockerfile. Open Wearables, Grafana e MinIO também não foram incluídos: não há configuração de execução local desses componentes nos repositórios disponíveis, e o backend atual deixa a integração Open Wearables desativada por padrão.

### Próximos passos de segurança

1. Migrar a autenticação própria do `backend-core` para Keycloak com transição coordenada de emissão, leitura e renovação de tokens.
2. Depois da migração, exigir JWT Keycloak em todas as rotas de negócio no gateway, configurar validação de roles/audience e remover o JWT HMAC legado no backend.
3. Definir os clientes OIDC para app, portal e gateway no realm local e completar os fluxos de login.
4. Definir a política de rate limit por rota/usuário antes de ativar o Redis RateLimiter.
5. Implementar o BFF do portal como mudança separada, incluindo sessão `HttpOnly`, proteção CSRF e cliente OIDC confidencial.

## Kanban da organização

O workflow `Sincronizar Kanban` (`.github/workflows/sync-kanban.yml`) mantém o quadro único **SeniorInsight Kanban** com as issues abertas que têm a label `mvp` nos repositórios da organização. Para pôr uma issue no quadro, basta a label. Roda a cada 4 horas e pode ser disparado à mão em Actions. Precisa do secret `KANBAN_TOKEN` neste repositório (PAT clássico com os escopos `project`, `repo` e `read:org`).

Colunas: Backlog, A fazer, Em andamento, Em revisão e Concluído. Issue nova entra em Backlog se o título começa com `HU-` e em A fazer se não. Itens já presentes no quadro não são movidos pelo workflow, exceto os que ficaram sem coluna. Issue fechada como concluída vai para Concluído; fechada como duplicada ou não planejada, sem a label ou PR sai do quadro.
