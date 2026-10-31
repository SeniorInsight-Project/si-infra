#!/bin/sh
# Lê os segredos do Swarm (/run/secrets) e executa o script de start do Open Wearables
# passado como comando (scripts/start/app.sh, worker.sh ou beat.sh).
set -eu

ler() { tr -d '\r\n' < "/run/secrets/$1"; }

DB_PASSWORD="$(ler OW_DB_PASSWORD)"
SECRET_KEY="$(ler OW_SECRET_KEY)"
ADMIN_PASSWORD="$(ler OW_ADMIN_PASSWORD)"
export DB_PASSWORD SECRET_KEY ADMIN_PASSWORD

exec "$@"
