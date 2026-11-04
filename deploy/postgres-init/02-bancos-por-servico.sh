#!/bin/sh
# Roda só na primeira subida do volume do Postgres (VM nova).
# Cada microsserviço tem o próprio banco e o próprio usuário: um serviço não consegue
# conectar no banco de outro (CONNECT revogado de PUBLIC). Os dados de um serviço só
# chegam aos outros pela API dele ou pelos eventos da exchange si.events.
#
# A senha de cada usuário vem do secret do Swarm montado em /run/secrets/DB_<SERVICO>_PASSWORD.
# Para uma VM que já tinha o banco único "seniorinsight", use deploy/scripts/migrar-bancos-por-servico.sh.
set -eu

SERVICOS="${SI_DB_SERVICOS:-care identity notification telemetry insight report billing keycloak}"

for s in $SERVICOS; do
  VAR="DB_$(echo "$s" | tr '[:lower:]' '[:upper:]')_PASSWORD"
  SENHA="$(tr -d '\r\n' < "/run/secrets/$VAR")"
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

# O banco "seniorinsight" (POSTGRES_DB) fica só para administração.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "REVOKE CONNECT, TEMPORARY ON DATABASE \"$POSTGRES_DB\" FROM PUBLIC;"
