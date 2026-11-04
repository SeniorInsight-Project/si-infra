# Deploy na VM da Azure (Docker Swarm)

Tudo que chega na `main` de um repositório de backend vai sozinho para a VM `vm-seniorinsight`
(Azure, East US, Ubuntu 24.04, 2 vCPU / 8 GB + 4 GB de swap).

Endereço público: `https://seniorinsight-api.eastus.cloudapp.azure.com`

| Caminho | Vai para |
|---|---|
| `/` | redireciona para o portal si-web na Vercel (`www.seniorinsight.com.br`) |
| `/api/**` | api-gateway → serviços |
| `/login/**`, `/oauth2/**`, `/logout` | api-gateway (BFF do portal) |
| `/auth/**` | Keycloak (realm `seniorinsight`) |
| `:8443` | API do Open Wearables |
| `:3443` | portal do Open Wearables |
| `:9443` | MinIO (só as URLs assinadas dos relatórios) |

O certificado HTTPS é emitido e renovado pelo Caddy. O portal si-web não roda na VM: ele é publicado pela Vercel e chama a API em `https://seniorinsight-api.eastus.cloudapp.azure.com/api`.

## Como o deploy acontece

```
push na main do repo X
  └─ deploy.yml do repo X
       └─ si-infra/.github/workflows/servico-build-deploy.yml
            ├─ build (runner do GitHub): imagem em ghcr.io/seniorinsight-project/X:main e :sha-<commit>
            └─ deploy (runner self-hosted na VM): docker service update --image ... seniorinsight_<serviço>
                 └─ o Swarm espera o healthcheck; se falhar, volta sozinho para a versão anterior

push na main do si-infra (deploy/, keycloak/, postgres/)
  └─ .github/workflows/deploy.yml (runner da VM) → deploy/scripts/deploy-stack.sh → docker stack deploy
```

| Repositório | Serviço na stack |
|---|---|
| si-api-gateway | `api-gateway` |
| si-care-service | `care-service` |
| si-identity-service | `identity-service` |
| si-notification-service | `notification-service` |
| si-telemetry-service | `telemetry-service` |
| si-insight-service | `insight-service` |
| si-report-service | `report-service` |
| si-billing-service | `billing-service` |

O portal **si-web** não roda na VM: ele é publicado pela Vercel. A URL dele fica em
`/opt/seniorinsight/si-web-url` na VM e é usada no CORS do gateway e no redirecionamento da raiz.
O app **si-mobile** também não: para testes ele roda numa VM própria do Expo (`deploy/expo/`).

## Bancos de dados (um por serviço)

Um único Postgres, mas cada microsserviço tem **banco e usuário próprios** e não consegue conectar
no banco de outro (`CONNECT` revogado de `PUBLIC`). Dado de outro serviço só chega pela API dele ou
pelos eventos da exchange `si.events`.

| Serviço | Banco / usuário | Schema | Secret da senha |
|---|---|---|---|
| care-service | `care` | `public` | `si_db_care_password` |
| identity-service | `identity` | `identity` | `si_db_identity_password` |
| notification-service | `notification` | `notification` | `si_db_notification_password` |
| telemetry-service | `telemetry` | `telemetry` | `si_db_telemetry_password` |
| insight-service | `insight` | `insight` | `si_db_insight_password` |
| report-service | `report` | `report` | `si_db_report_password` |
| billing-service | `billing` | `billing` | `si_db_billing_password` |
| Keycloak | `keycloak` | `keycloak` | `si_db_keycloak_password` |
| Open Wearables | `openwearables` | `public` | `si_ow_db_password` |

O usuário `seniorinsight` (`si_db_password`) é o superusuário do Postgres e serve só para administração.

Numa VM nova, os bancos são criados na primeira subida do volume por
`deploy/postgres-init/02-bancos-por-servico.sh`. A VM que já existia com o banco único foi migrada
uma vez com `deploy/scripts/migrar-bancos-por-servico.sh` (backup em `/opt/seniorinsight/backup`).

## Segredos

Ficam no Swarm (`docker secret ls`), gerados na própria VM pelo `bootstrap-vm.sh`; ninguém precisa
conhecer as senhas. Os serviços Spring leem `/run/secrets` como `configtree`: um secret montado como
`DB_PASSWORD` resolve o `${DB_PASSWORD}` do `application.yml`.

### Chaves de terceiros (Google, Gemini, Open Wearables)

São as únicas digitadas por alguém; os valores ficam no Vaultwarden. Para criar ou trocar, na VM:

```bash
cd ~/si-infra && git pull && bash deploy/scripts/definir-segredos.sh
```

O script pede cada chave sem mostrar na tela (Enter em branco pula). Docker secret não pode ser
alterado, então uma chave que já existe ganha uma versão nova (`si_gemini_api_key_v2`, `_v3`...) e o
nome em uso fica em `/opt/seniorinsight/segredos.env`. O `deploy-stack.sh` lê esse arquivo e o
`stack.yml` usa `${SI_SECRET_GEMINI:-si_gemini_api_key}`, então a troca não exige mudar o repositório.
No fim, o script pergunta se já aplica com o `deploy-stack.sh`.

## Login com Google

O realm traz o identity provider `google`; o client secret vem do Docker secret `si_google_client_secret`
(lido pelo `deploy/entrypoints/keycloak.sh` como `GOOGLE_CLIENT_SECRET`). O valor está no Vaultwarden
(`[prod] Google OAuth client`). Numa VM nova, o `bootstrap-vm.sh` cria o secret com o marcador
`nao-configurado`; troque pelo valor real antes do primeiro login.

**Antes do deploy que traz esta mudança**, crie o secret na VM com `deploy/scripts/definir-segredos.sh`
(seção Segredos); sem ele, `docker stack deploy` falha.

**Na VM que já existia**, o `--import-realm` não reimporta o realm, então o provedor não aparece sozinho.
Depois do deploy, rode uma vez (cria ou atualiza o provedor pela API admin, lendo o secret montado):

```bash
bash deploy/scripts/configurar-login-google.sh
```

Para trocar o secret: rode o `definir-segredos.sh` de novo (cria a versão nova e faz o deploy) e depois
o `configurar-login-google.sh`. Redirect URI cadastrado no Google:
`https://seniorinsight-api.eastus.cloudapp.azure.com/auth/realms/seniorinsight/broker/google/endpoint`.

## Preparação da VM (já feita; repetir só numa VM nova)

```bash
git clone -b main https://github.com/SeniorInsight-Project/si-infra ~/si-infra && cd ~/si-infra
sudo bash deploy/scripts/bootstrap-vm.sh               # swap, Swarm, pastas e segredos
bash deploy/scripts/install-runner.sh <TOKEN>          # token em Settings → Actions → Runners → New runner
bash deploy/scripts/deploy-stack.sh                    # primeira subida da stack
```

## Operação

```bash
docker stack services seniorinsight                    # estado de todos os serviços
docker service logs -f --tail 100 seniorinsight_care-service
docker service ps --no-trunc seniorinsight_care-service # por que uma tarefa caiu
docker service rollback seniorinsight_care-service      # volta para a imagem anterior
```

## Limites

- A VM desliga sozinha às 02:00 UTC (23:00 em Brasília). Com ela desligada, os jobs de deploy
  ficam na fila do GitHub até o runner voltar (até 24 h). Ao ligar, o Swarm sobe tudo de novo.
- 8 GB de RAM para cerca de 20 containers: cada serviço Spring tem limite de 384 MB. Se aparecer
  `OOMKilled` em `docker service ps`, o próximo passo é a D4as v4 (16 GB).
- O Open Wearables recomenda Postgres 18; aqui ele usa o Postgres 17 da stack, em banco próprio.
