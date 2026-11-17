# si-infra

Infraestrutura: docker-compose local (PostgreSQL, Redis, RabbitMQ, Keycloak, MinIO, Mailpit, Open Wearables), configuração do realm Keycloak e scripts de deploy.

Parte do SeniorInsight — ver o Documento de Arquitetura de Software (seção 6) para as convenções.

Branches: `main` (principal, protegida) e `develop` (testes). Trabalhe em branches curtas por issue e abra PR para `develop`.

## Ambiente local completo

O `compose.yaml` sobe a infraestrutura e todos os serviços (gateway, care, identity, notification, telemetry, insight, report e billing), com um banco por serviço, MinIO, Mailpit e o Open Wearables num profile opcional (`ow`). Os builds usam os repositórios clonados lado a lado (`../si-<repo>`). Passo a passo, portas e limitações em [README-local.md](README-local.md).

## Keycloak local (realm `seniorinsight`)

### Como subir

1. Copie `.env.example` para `.env` e troque os valores de `SI_WEB_CLIENT_SECRET`, `SI_IDENTITY_SERVICE_CLIENT_SECRET`, `SI_INSIGHT_SERVICE_CLIENT_SECRET`, `SI_NOTIFICATION_SERVICE_CLIENT_SECRET`, `SI_CARE_SERVICE_CLIENT_SECRET` e `OPENWEARABLES_VINCULO_SECRET` (por exemplo, `openssl rand -hex 32`). O Compose não sobe sem essas variáveis.
2. Para subir só a parte de identidade, sem os repositórios irmãos:

   ```bash
   docker compose up -d postgres mailpit keycloak
   ```

3. Acesse:
   - Keycloak (console de administração): http://localhost:8180 (usuário e senha de `KEYCLOAK_ADMIN` e `KEYCLOAK_ADMIN_PASSWORD`);
   - Conta do usuário no realm: http://localhost:8180/realms/seniorinsight/account;
   - Mailpit (caixa de entrada de desenvolvimento): http://localhost:8025. O Keycloak envia por SMTP para `mailpit:1025`; nenhum e-mail sai da máquina.

O Keycloak usa o banco `keycloak` (schema `keycloak`), criado por `postgres/init/02-bancos-por-servico.sh`. O realm é importado de `keycloak/realm-seniorinsight.json` apenas quando ainda não existe no banco. Depois de alterar o arquivo, recrie o banco com `docker compose down -v` ou apague o realm pelo console antes de subir de novo (para atualizar apenas os tempos de sessão sem apagar o banco, rode `bash deploy/scripts/configurar-tempos-de-sessao.sh`). Os secrets dos clients vêm das variáveis de ambiente do container (`${SI_WEB_CLIENT_SECRET}` no JSON).

### O que o realm configura

| Item | Configuração |
| --- | --- |
| Papéis | `familiar`, `medico`, `idoso`, `gestor`, `admin`. Quem se cadastra pela tela recebe `familiar` (papel padrão). `servico-interno` é só das service accounts que chamam rotas `/internal/**` de outro serviço (o care-service exige essa role, `care.seguranca.papel-servico`) |
| `si-mobile` | Público, Authorization Code + PKCE `S256`, redirect `seniorinsight://auth`. No Docker Compose também aceita o Expo Go (`exp://*`) e o Expo web (`http://localhost:8081/auth`, web origin `http://localhost:8081`), via `SI_MOBILE_DEV_*` no `compose.yaml`; no deploy essas variáveis não existem e fica só `seniorinsight://auth` |
| `si-web` | Confidencial, para o BFF do api-gateway; redirect `http://localhost:8080/login/oauth2/code/*`; secret em `SI_WEB_CLIENT_SECRET` |
| `si-identity-service` | Confidencial com service account (`manage-users`, `view-users`, `query-users`, `query-groups`, `impersonation` do `realm-management`) e token exchange padrão habilitado; secret em `SI_IDENTITY_SERVICE_CLIENT_SECRET` |
| `si-insight-service` | Confidencial, só service account (client credentials, sem fluxo de navegador); a service account tem a role `servico-interno` para o `/internal/**` do care-service; secret em `SI_INSIGHT_SERVICE_CLIENT_SECRET` (no serviço: `INSIGHT_CARE_TOKEN_URL`, `INSIGHT_CARE_CLIENT_ID`, `INSIGHT_CARE_CLIENT_SECRET`) |
| `si-notification-service` | Igual ao `si-insight-service`: só service account, role `servico-interno`; secret em `SI_NOTIFICATION_SERVICE_CLIENT_SECRET` (no serviço: `NOTIFICATION_CARE_TOKEN_URL`, `NOTIFICATION_CARE_CLIENT_ID`, `NOTIFICATION_CARE_CLIENT_SECRET`) |
| `care-service` | Só service account, com o client scope padrão `billing.trial.write`: o token sai com esse scope e `azp = care-service`, que o billing-service exige em `POST /internal/familias/{sub}/trial`. Não tem `servico-interno`. Secret em `SI_CARE_SERVICE_CLIENT_SECRET` (no serviço: `CARE_BILLING_TOKEN_URL`, `CARE_BILLING_CLIENT_ID`, `CARE_BILLING_CLIENT_SECRET`) |
| Client scopes | Os padrão do Keycloak 26.3 mais `billing.trial.write`. Como o JSON declara `clientScopes`, o Keycloak não cria os padrão sozinho: por isso o arquivo traz a lista completa e os clients nativos (`account`, `account-console`, `admin-cli`, `broker`, `realm-management`, `security-admin-console`), como num export do realm |
| Cadastro | Aberto, e-mail como usuário, verificação de e-mail obrigatória, link válido por 24 horas (RF-001) |
| Recuperação de senha | Ligada ("Esqueceu sua senha?") |
| Login com Google | Identity provider `google` (OAuth client do projeto `seniorinsight-auth` no Google Cloud). E-mail do Google tratado como verificado (*trust email*) e quem entra recebe `familiar`. Client ID no realm; secret em `GOOGLE_CLIENT_SECRET` (no `.env`, valor no Vaultwarden) |
| Política de senha | Mínimo de 10 caracteres, ao menos uma letra e um número, diferente do e-mail (HU-001) |
| Força bruta | 5 erros em 15 minutos bloqueiam a conta por 15 minutos (RF-002) |
| Tempos de sessão | Realm: 30 dias de ociosidade (`2592000` s) e 365 dias no máximo (`31536000` s), herdados pelo `si-identity-service` (sessão do idoso). `si-mobile` e `si-web` sobrescrevem para 30 min (`1800` s) e 10 h (`36000` s) |
| Idioma | Tema `seniorinsight` (pasta `keycloak/themes/seniorinsight`), pt-BR padrão e inglês opcional |

### Aplicar os clients de serviço num realm já importado

O import do realm só roda em banco novo, então um Keycloak que já estava no ar não ganha a role `servico-interno`, o scope `billing.trial.write` nem os clients `si-insight-service`, `si-notification-service` e `care-service`. Sem apagar o banco, rode uma vez com o Keycloak no ar:

```bash
bash deploy/scripts/configurar-clients-de-servico.sh
```

O script lê as definições do `keycloak/realm-seniorinsight.json` e os secrets do container do Keycloak (variáveis do `.env` no Compose; `/run/secrets` na stack), cria o que falta e atualiza o que já existe (pode ser repetido). As service accounts ficam só com os papéis do JSON, sem o papel padrão `familiar`. Na VM, rode antes o `bootstrap-vm.sh` e faça o deploy da stack (ver `deploy/README.md`).

Para conferir, peça um token de serviço e veja `realm_access.roles` (insight e notification) ou `scope` e `azp` (care):

```bash
curl -s -d grant_type=client_credentials -d client_id=si-insight-service -d "client_secret=$SI_INSIGHT_SERVICE_CLIENT_SECRET" \
  http://localhost:8180/realms/seniorinsight/protocol/openid-connect/token
```

### Como testar

1. **Cadastro e confirmação:** abra http://localhost:8180/realms/seniorinsight/account, clique em **Cadastre-se** e preencha o formulário com uma senha como `SenhaTeste2026`. A tela pede a verificação do e-mail. Abra o Mailpit, clique no link de "Confirme seu e-mail no SeniorInsight" e você entra na conta. Saia e entre de novo com e-mail e senha.
2. **Política de senha:** no cadastro, `apenasletras` é recusada por falta de número e `curta1` por ter menos de 10 caracteres.
3. **Bloqueio:** na tela de login, erre a senha 5 vezes. Na 6ª tentativa, mesmo com a senha certa, aparece "Conta bloqueada por 15 minutos...". Um administrador pode desbloquear em *Users > usuário > Brute force*.
4. **Recuperação de senha:** em **Esqueceu sua senha?**, informe o e-mail e use o link que chega no Mailpit.
5. **Login com Google:** com `GOOGLE_CLIENT_SECRET` preenchido no `.env`, a tela de login mostra o botão **Google**. A conta precisa estar em *Test users* no Google Auth Platform enquanto o app do Google estiver em modo de teste. Sem o secret, o botão aparece, mas o Google recusa com `invalid_client`.

## Kanban da organização

O workflow `Sincronizar Kanban` (`.github/workflows/sync-kanban.yml`) mantém o quadro único **SeniorInsight Kanban** com as issues abertas que têm a label `mvp` nos repositórios da organização. Para pôr uma issue no quadro, basta a label. Roda a cada 4 horas e pode ser disparado à mão em Actions. Precisa do secret `KANBAN_TOKEN` neste repositório (PAT clássico com os escopos `project`, `repo` e `read:org`).

Colunas: Backlog, A fazer, Em andamento, Em revisão e Concluído. Issue nova entra em Backlog se o título começa com `HU-` e em A fazer se não. Itens já presentes no quadro não são movidos pelo workflow, exceto os que ficaram sem coluna. Issue fechada como concluída vai para Concluído; fechada como duplicada ou não planejada, sem a label ou PR sai do quadro.
