#!/bin/bash
# Migração única de uma VM que já rodava com o banco compartilhado "seniorinsight"
# (um schema por serviço, todos com o mesmo usuário) para um banco e um usuário por serviço.
#
# Uso (na VM, como azureuser, ANTES do deploy do stack.yml novo):
#   bash deploy/scripts/migrar-bancos-por-servico.sh
#   bash deploy/scripts/deploy-stack.sh
#
# O que faz, serviço por serviço (pode ser repetido; o que já foi migrado é pulado):
#   1. backup completo do Postgres em /opt/seniorinsight/backup
#   2. para o serviço (réplicas 0) para ninguém escrever durante a cópia
#   3. gera a senha, cria o usuário e o banco do serviço e o secret si_db_<serviço>_password
#   4. copia o schema do serviço do banco "seniorinsight" para o banco novo, já com o dono certo
# O banco "seniorinsight" antigo não é apagado: fica como cópia até confirmar que está tudo certo.
set -euo pipefail

STACK=seniorinsight
ADMIN=seniorinsight          # POSTGRES_USER da stack (superusuário, só administração)
ANTIGO=seniorinsight         # banco compartilhado de antes
BACKUP_DIR=/opt/seniorinsight/backup

# serviço:schema-de-origem-no-banco-antigo:serviço-na-stack
MAPA="
care:public:care-service
identity:identity:identity-service
notification:notification:notification-service
telemetry:telemetry:telemetry-service
insight:insight:insight-service
report:report:report-service
billing:billing:billing-service
keycloak:keycloak:keycloak
"

PG="$(docker ps -q -f name=${STACK}_postgres | head -1)"
[ -n "$PG" ] || { echo "Container do Postgres da stack não encontrado."; exit 1; }
psql_admin() { docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -qtA -U "$ADMIN" "$@"; }

if [ "${1:-}" = "--limpar-antigo" ]; then
  # Apaga do banco antigo as cópias dos schemas já migrados (depois de conferir que tudo funciona).
  for linha in $MAPA; do
    IFS=: read -r S ORIGEM _ <<< "$linha"
    [ "$(psql_admin -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$S'")" = "1" ] || continue
    if [ "$ORIGEM" = "public" ]; then
      psql_admin -d "$ANTIGO" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner;"
    else
      psql_admin -d "$ANTIGO" -c "DROP SCHEMA IF EXISTS \"$ORIGEM\" CASCADE"
    fi
    echo "  schema $ORIGEM removido de $ANTIGO"
  done
  exit 0
fi

echo "== backup"
mkdir -p "$BACKUP_DIR"
ARQ="$BACKUP_DIR/antes-banco-por-servico-$(date +%Y%m%d-%H%M%S).sql.gz"
docker exec "$PG" pg_dumpall -U "$ADMIN" | gzip > "$ARQ"
echo "  $ARQ ($(du -h "$ARQ" | cut -f1))"

for linha in $MAPA; do
  IFS=: read -r S ORIGEM SVC <<< "$linha"
  SECRET="si_db_${S}_password"
  echo "== $S (schema de origem: $ORIGEM)"

  ROLE_EXISTE="$(psql_admin -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname='$S'")"
  if docker secret inspect "$SECRET" >/dev/null 2>&1; then
    if [ "$ROLE_EXISTE" = "1" ]; then echo "  já migrado, pulando"; continue; fi
    echo "::error::o secret $SECRET existe mas o usuário $S não; não há como saber a senha. Remova o secret e rode de novo."
    exit 1
  fi

  if docker service inspect "${STACK}_${SVC}" >/dev/null 2>&1; then
    docker service scale -d "${STACK}_${SVC}=0" >/dev/null && echo "  ${SVC} parado"
  fi

  # Banco novo sempre limpo: se uma rodada anterior parou no meio (o secret só é criado no fim),
  # o banco é refeito a partir do antigo, que continua intacto.
  SENHA="$(openssl rand -hex 32)"
  psql_admin -d postgres -c "DROP DATABASE IF EXISTS \"$S\" WITH (FORCE)"
  if [ "$ROLE_EXISTE" = "1" ]; then
    psql_admin -d postgres -c "ALTER ROLE \"$S\" LOGIN PASSWORD '$SENHA'"
  else
    psql_admin -d postgres -c "CREATE ROLE \"$S\" LOGIN PASSWORD '$SENHA'"
  fi
  psql_admin -d postgres -c "CREATE DATABASE \"$S\" OWNER \"$S\""
  psql_admin -d postgres -c "REVOKE CONNECT, TEMPORARY ON DATABASE \"$S\" FROM PUBLIC"

  [ "$S" = "care" ] && psql_admin -d care -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"'

  TABELAS="$(psql_admin -d "$ANTIGO" -c "SELECT count(*) FROM pg_tables WHERE schemaname='$ORIGEM'")"
  if [ "${TABELAS:-0}" -gt 0 ]; then
    # --no-owner: os objetos passam a ser do usuário do serviço, que é quem restaura.
    # O schema public e as extensões já existem no banco novo.
    docker exec "$PG" pg_dump -U "$ADMIN" -d "$ANTIGO" -n "$ORIGEM" --no-owner --no-privileges \
      | grep -v -e '^CREATE EXTENSION' -e '^COMMENT ON EXTENSION' -e '^CREATE SCHEMA public;' \
      | docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -q -U "$S" -d "$S" >/dev/null
    echo "  $TABELAS tabela(s) copiada(s)"
  else
    echo "  nada para copiar (o Flyway cria o schema na primeira subida)"
  fi

  # Por último: o secret marca o serviço como migrado.
  printf '%s' "$SENHA" | docker secret create "$SECRET" - >/dev/null && echo "  secret $SECRET criado"
done

psql_admin -d postgres -c "REVOKE CONNECT, TEMPORARY ON DATABASE \"$ANTIGO\" FROM PUBLIC"

echo
echo "Pronto. Agora rode: bash deploy/scripts/deploy-stack.sh"
echo "Os schemas antigos continuam no banco \"$ANTIGO\" como cópia. Depois de conferir os serviços,"
echo "apague-os com: bash deploy/scripts/migrar-bancos-por-servico.sh --limpar-antigo"
