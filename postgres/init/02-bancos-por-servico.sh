#!/bin/sh
# Roda só na primeira subida do volume do Postgres local (docker compose down -v recria).
# Mesmo desenho de produção (deploy/postgres-init/02-bancos-por-servico.sh): cada serviço tem banco e usuário
# próprios e não conecta no banco dos outros. Diferença local: a senha de todos os usuários é DB_PASSWORD
# (SI_DB_SENHA_SERVICOS no compose.yaml), em vez de um secret por serviço.
set -eu

SERVICOS="${SI_DB_SERVICOS:-care identity notification telemetry insight report billing keycloak}"
SENHA="${SI_DB_SENHA_SERVICOS:?SI_DB_SENHA_SERVICOS não definida}"

for s in $SERVICOS; do
  echo "== banco $s"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE "$s" LOGIN PASSWORD '${SENHA}';
CREATE DATABASE "$s" OWNER "$s";
REVOKE CONNECT, TEMPORARY ON DATABASE "$s" FROM PUBLIC;
SQL
done

# O Keycloak usa o schema "keycloak" (KC_DB_SCHEMA) dentro do banco dele.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname keycloak \
  -c 'CREATE SCHEMA IF NOT EXISTS keycloak AUTHORIZATION keycloak;'

# Open Wearables (profile "ow"): CREATEDB porque ele também cria o banco do Svix.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE openwearables LOGIN CREATEDB PASSWORD '${SENHA}';
CREATE DATABASE openwearables OWNER openwearables;
REVOKE CONNECT, TEMPORARY ON DATABASE openwearables FROM PUBLIC;
SQL

# O banco de administração (POSTGRES_DB) não é usado pelos serviços.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "REVOKE CONNECT, TEMPORARY ON DATABASE \"$POSTGRES_DB\" FROM PUBLIC;"
