# si-infra

Infraestrutura: docker-compose local (PostgreSQL, Redis, RabbitMQ, Keycloak, Open Wearables, Grafana), configuração do realm Keycloak e scripts de deploy.

Parte do SeniorInsight — ver o Documento de Arquitetura de Software (seção 6) para as convenções.

Branches: `main` (principal, protegida) e `develop` (testes). Trabalhe em branches curtas por issue e abra PR para `develop`.

## Keycloak local (realm `seniorinsight`)

### Como subir

1. Copie `.env.example` para `.env` e troque os valores de `SI_WEB_CLIENT_SECRET` e `SI_IDENTITY_SERVICE_CLIENT_SECRET` (por exemplo, `openssl rand -hex 32`). O Compose não sobe sem essas variáveis.
2. Para subir só a parte de identidade, sem os repositórios irmãos:

   ```bash
   docker compose up -d postgres mailpit keycloak
   ```

3. Acesse:
   - Keycloak (console de administração): http://localhost:8180 (usuário e senha de `KEYCLOAK_ADMIN` e `KEYCLOAK_ADMIN_PASSWORD`);
   - Conta do usuário no realm: http://localhost:8180/realms/seniorinsight/account;
   - Mailpit (caixa de entrada de desenvolvimento): http://localhost:8025. O Keycloak envia por SMTP para `mailpit:1025`; nenhum e-mail sai da máquina.

O realm é importado de `keycloak/realm-seniorinsight.json` apenas quando ainda não existe no banco. Depois de alterar o arquivo, recrie o banco com `docker compose down -v` ou apague o realm pelo console antes de subir de novo. Os secrets dos clients vêm das variáveis de ambiente do container (`${SI_WEB_CLIENT_SECRET}` no JSON).

### O que o realm configura

| Item | Configuração |
| --- | --- |
| Papéis | `familiar`, `medico`, `idoso`, `gestor`, `admin`. Quem se cadastra pela tela recebe `familiar` (papel padrão) |
| `si-mobile` | Público, Authorization Code + PKCE `S256`, redirect `seniorinsight://auth` |
| `si-web` | Confidencial, para o BFF do api-gateway; redirect `http://localhost:8080/login/oauth2/code/*`; secret em `SI_WEB_CLIENT_SECRET` |
| `si-identity-service` | Confidencial com service account (`manage-users`, `view-users`, `query-users`, `query-groups`, `impersonation` do `realm-management`) e token exchange padrão habilitado; secret em `SI_IDENTITY_SERVICE_CLIENT_SECRET` |
| Cadastro | Aberto, e-mail como usuário, verificação de e-mail obrigatória, link válido por 24 horas (RF-001) |
| Recuperação de senha | Ligada ("Esqueceu sua senha?") |
| Política de senha | Mínimo de 10 caracteres, ao menos uma letra e um número, diferente do e-mail (HU-001) |
| Força bruta | 5 erros em 15 minutos bloqueiam a conta por 15 minutos (RF-002) |
| Idioma | Tema `seniorinsight` (pasta `keycloak/themes/seniorinsight`), pt-BR padrão e inglês opcional |

### Como testar

1. **Cadastro e confirmação:** abra http://localhost:8180/realms/seniorinsight/account, clique em **Cadastre-se** e preencha o formulário com uma senha como `SenhaTeste2026`. A tela pede a verificação do e-mail. Abra o Mailpit, clique no link de "Confirme seu e-mail no SeniorInsight" e você entra na conta. Saia e entre de novo com e-mail e senha.
2. **Política de senha:** no cadastro, `apenasletras` é recusada por falta de número e `curta1` por ter menos de 10 caracteres.
3. **Bloqueio:** na tela de login, erre a senha 5 vezes. Na 6ª tentativa, mesmo com a senha certa, aparece "Conta bloqueada por 15 minutos...". Um administrador pode desbloquear em *Users > usuário > Brute force*.
4. **Recuperação de senha:** em **Esqueceu sua senha?**, informe o e-mail e use o link que chega no Mailpit.

## Kanban da organização

O workflow `Sincronizar Kanban` (`.github/workflows/sync-kanban.yml`) mantém o quadro único **SeniorInsight Kanban** com as issues abertas que têm a label `mvp` nos repositórios da organização. Para pôr uma issue no quadro, basta a label. Roda a cada 4 horas e pode ser disparado à mão em Actions. Precisa do secret `KANBAN_TOKEN` neste repositório (PAT clássico com os escopos `project`, `repo` e `read:org`).

Colunas: Backlog, A fazer, Em andamento, Em revisão e Concluído. Issue nova entra em Backlog se o título começa com `HU-` e em A fazer se não. Itens já presentes no quadro não são movidos pelo workflow, exceto os que ficaram sem coluna. Issue fechada como concluída vai para Concluído; fechada como duplicada ou não planejada, sem a label ou PR sai do quadro.
