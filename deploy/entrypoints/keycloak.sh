#!/bin/bash
# Lê os segredos do Swarm (/run/secrets) e sobe o Keycloak em modo de produção.
set -euo pipefail

ler() { tr -d '\r\n' < "/run/secrets/$1"; }

export KC_DB_PASSWORD="$(ler DB_PASSWORD)"
export KC_BOOTSTRAP_ADMIN_PASSWORD="$(ler KEYCLOAK_ADMIN_PASSWORD)"
# Usados pelo realm-seniorinsight.json (${SI_WEB_CLIENT_SECRET} e ${SI_IDENTITY_SERVICE_CLIENT_SECRET}).
export SI_WEB_CLIENT_SECRET="$(ler SI_WEB_CLIENT_SECRET)"
export SI_IDENTITY_SERVICE_CLIENT_SECRET="$(ler SI_IDENTITY_SERVICE_CLIENT_SECRET)"

exec /opt/keycloak/bin/kc.sh start --import-realm "$@"
