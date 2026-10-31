#!/bin/sh
# Roda só na primeira subida do volume do Postgres.
# Cria o usuário e o banco do Open Wearables (CREATEDB porque ele também cria o banco do Svix).
set -eu

OW_DB_PASSWORD="$(tr -d '\r\n' < /run/secrets/OW_DB_PASSWORD)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE openwearables LOGIN CREATEDB PASSWORD '${OW_DB_PASSWORD}';
CREATE DATABASE openwearables OWNER openwearables;
SQL
