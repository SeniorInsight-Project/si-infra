# Deploy na VM da Azure (Docker Swarm)

Tudo que chega na `main` de um repositório vai sozinho para a VM `vm-seniorinsight`
(Azure, East US, Ubuntu 24.04, 2 vCPU / 8 GB + 4 GB de swap).

Endereço público: `https://seniorinsight-api.eastus.cloudapp.azure.com`

| Caminho | Vai para |
|---|---|
| `/` | portal si-web |
| `/api/**` | api-gateway → serviços |
| `/login/**`, `/oauth2/**`, `/logout` | api-gateway (BFF do portal) |
| `/auth/**` | Keycloak (realm `seniorinsight`) |
| `:8443` | API do Open Wearables |
| `:3443` | portal do Open Wearables |
| `:9443` | MinIO (só as URLs assinadas dos relatórios) |

O certificado HTTPS é emitido e renovado pelo Caddy.

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
| si-web | `web` |

## Segredos

Ficam no Swarm (`docker secret ls`), gerados na própria VM pelo `bootstrap-vm.sh`; ninguém precisa
conhecer as senhas. Os serviços Spring leem `/run/secrets` como `configtree`: um secret montado como
`DB_PASSWORD` resolve o `${DB_PASSWORD}` do `application.yml`.

Para trocar uma chave de terceiros (ex.: Gemini), na VM:

```bash
printf '%s' 'NOVA_CHAVE' | docker secret create si_gemini_api_key_v2 -
# no stack.yml, aponte o secret para o nome novo (si_gemini_api_key_v2) e faça o deploy do si-infra
```

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
