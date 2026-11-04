#!/bin/bash
# Cria ou atualiza o provedor "google" no realm seniorinsight de um Keycloak que já está rodando.
#
# O --import-realm só importa o realm na primeira subida (banco vazio). Numa VM que já tinha o realm,
# o identityProviders do realm-seniorinsight.json não é aplicado; este script faz isso pela API admin,
# lendo o client secret do Docker secret si_google_client_secret (montado no Keycloak como
# GOOGLE_CLIENT_SECRET). Nenhum secret passa pela linha de comando nem pelo histórico do shell.
#
# Uso, na VM, depois do deploy que monta o secret no Keycloak:
#   bash deploy/scripts/configurar-login-google.sh
set -euo pipefail

REALM_JSON="$(cd "$(dirname "$0")/../.." && pwd)/keycloak/realm-seniorinsight.json"
# O client ID é público e fica no realm; lê de lá para não haver dois lugares a trocar.
GOOGLE_CLIENT_ID="$(grep -oE '[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com' "$REALM_JSON" | head -1)"
[ -n "$GOOGLE_CLIENT_ID" ] || { echo "client ID do Google não encontrado em $REALM_JSON"; exit 1; }

KEYCLOAK="$(docker ps -q -f name=seniorinsight_keycloak | head -1)"
[ -n "$KEYCLOAK" ] || { echo "o serviço seniorinsight_keycloak não está rodando"; exit 1; }

docker exec -i -e GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" "$KEYCLOAK" bash -s <<'EOF'
set -euo pipefail
ler() { tr -d '\r\n' < "/run/secrets/$1"; }

[ -f /run/secrets/GOOGLE_CLIENT_SECRET ] || { echo "secret GOOGLE_CLIENT_SECRET não montado: faça o deploy do si-infra antes"; exit 1; }
SECRET="$(ler GOOGLE_CLIENT_SECRET)"
[ "$SECRET" != "nao-configurado" ] || { echo "si_google_client_secret ainda é o marcador; crie o secret com o valor real (deploy/README.md)"; exit 1; }

kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
kc config credentials --server http://localhost:8080/auth --realm master --user admin \
  --password "$(ler KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

ATRIBUTOS=(
  -s alias=google -s providerId=google -s displayName=Google -s enabled=true
  -s trustEmail=true -s storeToken=false -s firstBrokerLoginFlowAlias="first broker login"
  -s config.clientId="$GOOGLE_CLIENT_ID" -s config.clientSecret="$SECRET"
  -s 'config.defaultScope=openid profile email' -s config.syncMode=IMPORT -s config.guiOrder=1
)

if kc get identity-provider/instances/google -r seniorinsight >/dev/null 2>&1; then
  kc update identity-provider/instances/google -r seniorinsight "${ATRIBUTOS[@]}"
  echo "provedor google atualizado"
else
  kc create identity-provider/instances -r seniorinsight "${ATRIBUTOS[@]}"
  echo "provedor google criado"
fi
rm -f /tmp/kcadm.config
EOF
