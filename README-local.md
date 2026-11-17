# si-infra

Infraestrutura: docker-compose local (PostgreSQL, Redis, RabbitMQ, Keycloak, MinIO, Mailpit, Open Wearables), configuração do realm Keycloak e scripts de deploy.

Parte do SeniorInsight — ver o Documento de Arquitetura de Software (seção 6) para as convenções.

Branches: `main` (principal, protegida) e `develop` (testes). Trabalhe em branches curtas por issue e abra PR para `develop`.

## Ambiente local

Este repositório é o ponto de entrada do Docker Compose local. Os contextos de build apontam para os repositórios irmãos, e os Dockerfiles ficam junto ao código de cada serviço. O equivalente de produção é `deploy/stack.yml`.

### 1. Clonar os repositórios lado a lado

Os builds usam `../si-<repo>`, então os repositórios precisam estar na mesma pasta que o `si-infra`, com o nome original:

```bash
for r in si-infra si-api-gateway si-care-service si-identity-service si-notification-service \
         si-telemetry-service si-insight-service si-report-service si-billing-service; do
  git clone -b develop https://github.com/SeniorInsight-Project/$r.git
done
```

```
pasta/
├── si-infra/            <- rode o docker compose aqui
├── si-api-gateway/
├── si-care-service/
├── si-identity-service/
├── si-notification-service/
├── si-telemetry-service/
├── si-insight-service/
├── si-report-service/
└── si-billing-service/
```

### 2. Configurar o `.env`

Copie `.env.example` para `.env` (no PowerShell, `Copy-Item .env.example .env`) e troque pelo menos:

- `SI_WEB_CLIENT_SECRET` e `SI_IDENTITY_SERVICE_CLIENT_SECRET` (ex.: `openssl rand -hex 32`);
- `SI_INSIGHT_SERVICE_CLIENT_SECRET`, `SI_NOTIFICATION_SERVICE_CLIENT_SECRET` e `SI_CARE_SERVICE_CLIENT_SECRET`: clients de serviço das chamadas entre serviços (mesmo formato);
- `OPENWEARABLES_VINCULO_SECRET`: pelo menos 32 bytes e nunca trocado depois de haver vínculos.

O Compose não sobe sem essas variáveis. Num `.env` antigo, acrescente os três secrets de serviço e, se o banco do Keycloak já existia, rode `bash deploy/scripts/configurar-clients-de-servico.sh` com o Compose no ar (o realm só é importado em banco novo; ver README.md).

### 3. Subir

```bash
docker compose up -d --build
```

Para encerrar sem apagar os dados, `docker compose down`. Para recriar bancos, filas e arquivos do zero, `docker compose down -v`.

> **Volume antigo:** até esta versão todos os serviços usavam o banco único `seniorinsight`. Os bancos por serviço só são criados num volume novo do Postgres, então quem já tinha o ambiente precisa rodar `docker compose down -v` uma vez.

### O que sobe

| Serviço | Acesso no host | Observação |
| --- | --- | --- |
| `api-gateway` | http://localhost:8080 (`GATEWAY_PORT`) | Única aplicação publicada. Sobe sem esperar os serviços: com um serviço fora do ar, só as rotas dele respondem 5xx |
| `care-service`, `identity-service`, `notification-service`, `telemetry-service`, `insight-service`, `report-service`, `billing-service` | só pela rede interna | Acessados pelo gateway |
| `keycloak` | http://localhost:8180 | Realm `seniorinsight` (ver "Keycloak local" no `README.md`) |
| `postgres` | `localhost:5432` | Um banco e um usuário por serviço |
| `rabbitmq` | `localhost:5672`, painel em http://localhost:15672 | Exchange `si.events` |
| `redis` | `localhost:6379` | Rate limit do gateway e caches |
| `minio` | API em http://localhost:9000, console em http://localhost:9001 | PDFs do report-service, bucket `si-reports` (criado pelo serviço) |
| `mailpit` | http://localhost:8025 | SMTP do Keycloak, do notification e do report; nenhum e-mail sai da máquina |

Todos os serviços validam o token do Keycloak com o issuer público `http://localhost:8180/realms/seniorinsight` (o que vai no token) e buscam as chaves pela rede interna, em `http://keycloak:8080/realms/seniorinsight/protocol/openid-connect/certs` (`SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWKSETURI`).

### Bancos

`postgres/init/02-bancos-por-servico.sh` roda só na primeira subida do volume e cria os bancos e usuários `care`, `identity`, `notification`, `telemetry`, `insight`, `report`, `billing`, `keycloak` (com o schema `keycloak`) e `openwearables`. Como em produção (`deploy/postgres-init/02-bancos-por-servico.sh`), um serviço não conecta no banco de outro. A diferença é a senha: localmente todos usam `DB_PASSWORD`. O usuário `DB_USERNAME` fica só para administração.

### Open Wearables (profile `ow`)

Fica fora da subida padrão. Para incluir a API (http://localhost:8000) e o portal (http://localhost:3000):

```bash
docker compose --profile ow up -d
```

1. Entre no portal com `OW_ADMIN_EMAIL` e `OW_ADMIN_PASSWORD` e crie uma API key.
2. No `.env`, preencha `OPENWEARABLES_API_KEY` e troque `OPENWEARABLES_ENABLED` para `true`.
3. Recrie o telemetry: `docker compose --profile ow up -d telemetry-service`.

Sem o profile, deixe `OPENWEARABLES_ENABLED=false`: o telemetry sobe normalmente e não coleta.

### Score com o Gemini

O `insight-service` sobe com o Score desligado. Para ligar, preencha no `.env` `GEMINI_API_KEY`, `INSIGHT_GEMINI_ENABLED=true` e teto diário e tarifas maiores que zero (`INSIGHT_GEMINI_TETO_DIARIO_MICROS`, `INSIGHT_GEMINI_PRECO_ENTRADA`, `INSIGHT_GEMINI_PRECO_SAIDA`). Com teto ou tarifa zerados, o serviço não chama o modelo. O `.env.example` traz um exemplo de valores.

### Subir só uma parte

Os serviços de negócio dependem só da infraestrutura, não uns dos outros. Para trabalhar num serviço rodando fora do Docker, suba só o que ele usa, por exemplo:

```bash
docker compose up -d postgres rabbitmq redis keycloak mailpit minio
```

### Limitações conhecidas

- As chamadas para `/internal/**` do care-service (vínculo, rede do idoso, contexto do Score) ainda não funcionam: faltam as rotas no care, a role `servico-interno` no realm e os clients de serviço.
- O login do portal depende do BFF no gateway, que ainda não existe.

## Kanban da organização

O workflow `Sincronizar Kanban` (`.github/workflows/sync-kanban.yml`) mantém o quadro único **SeniorInsight Kanban** com as issues abertas que têm a label `mvp` nos repositórios da organização. Para pôr uma issue no quadro, basta a label. Roda a cada 4 horas e pode ser disparado à mão em Actions. Precisa do secret `KANBAN_TOKEN` neste repositório (PAT clássico com os escopos `project`, `repo` e `read:org`).

Colunas: Backlog, A fazer, Em andamento, Em revisão e Concluído. Issue nova entra em Backlog se o título começa com `HU-` e em A fazer se não. Itens já presentes no quadro não são movidos pelo workflow, exceto os que ficaram sem coluna. Issue fechada como concluída vai para Concluído; fechada como duplicada ou não planejada, sem a label ou PR sai do quadro.
