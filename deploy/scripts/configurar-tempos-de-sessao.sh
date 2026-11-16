#!/bin/bash
# Aplica os tempos de sessão do realm seniorinsight e dos clients si-mobile e si-web
# num Keycloak que já está rodando (o --import-realm só importa na primeira subida).
#
# Lê os valores diretamente de keycloak/realm-seniorinsight.json para não haver dois
# lugares a manter. Lê a senha do admin de /run/secrets/KEYCLOAK_ADMIN_PASSWORD (ou
# KC_BOOTSTRAP_ADMIN_PASSWORD em ambiente local), sem passar segredos na linha de comando.
#
# Uso, na VM:
#   bash deploy/scripts/configurar-tempos-de-sessao.sh
set -euo pipefail

REALM_JSON="$(cd "$(dirname "$0")/../.." && pwd)/keycloak/realm-seniorinsight.json"
[ -f "$REALM_JSON" ] || { echo "arquivo não encontrado: $REALM_JSON"; exit 1; }

VALORES="$(python3 - "$REALM_JSON" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    realm = json.load(f)

clients = {c["clientId"]: c.get("attributes", {}) for c in realm.get("clients", [])}

def req(val, nome):
    if val is None or val == "":
        raise SystemExit(f"campo obrigatório ausente em realm-seniorinsight.json: {nome}")
    return str(val)

print(req(realm.get("ssoSessionIdleTimeout"), "ssoSessionIdleTimeout"))
print(req(realm.get("ssoSessionMaxLifespan"), "ssoSessionMaxLifespan"))
for cid in ("si-mobile", "si-web"):
    attrs = clients.get(cid, {})
    print(req(attrs.get("client.session.idle.timeout"), f"{cid}.attributes['client.session.idle.timeout']"))
    print(req(attrs.get("client.session.max.lifespan"), f"{cid}.attributes['client.session.max.lifespan']"))
PY
)"

mapfile -t V <<<"$VALORES"
REALM_IDLE="${V[0]}"
REALM_MAX="${V[1]}"
MOBILE_IDLE="${V[2]}"
MOBILE_MAX="${V[3]}"
WEB_IDLE="${V[4]}"
WEB_MAX="${V[5]}"

KEYCLOAK="$(docker ps -q -f name=seniorinsight_keycloak | head -1)"
if [ -z "$KEYCLOAK" ]; then
  KEYCLOAK="$(docker ps -q -f name=seniorinsight-keycloak | head -1)"
fi
[ -n "$KEYCLOAK" ] || { echo "o serviço seniorinsight_keycloak não está rodando"; exit 1; }

docker exec -i \
  -e REALM_IDLE="$REALM_IDLE" \
  -e REALM_MAX="$REALM_MAX" \
  -e MOBILE_IDLE="$MOBILE_IDLE" \
  -e MOBILE_MAX="$MOBILE_MAX" \
  -e WEB_IDLE="$WEB_IDLE" \
  -e WEB_MAX="$WEB_MAX" \
  "$KEYCLOAK" bash -s <<'EOF'
set -euo pipefail
ler() { tr -d '\r\n' < "/run/secrets/$1"; }

if [ -f /run/secrets/KEYCLOAK_ADMIN_PASSWORD ]; then
  ADMIN_PASS="$(ler KEYCLOAK_ADMIN_PASSWORD)"
elif [ -n "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ]; then
  ADMIN_PASS="$KC_BOOTSTRAP_ADMIN_PASSWORD"
else
  echo "senha do admin não encontrada (/run/secrets/KEYCLOAK_ADMIN_PASSWORD ou KC_BOOTSTRAP_ADMIN_PASSWORD)"
  exit 1
fi

ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_URL="http://localhost:8080${KC_HTTP_RELATIVE_PATH:-}"

kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
kc config credentials --server "$KC_URL" --realm master --user "$ADMIN_USER" \
  --password "$ADMIN_PASS" >/dev/null

kc update realms/seniorinsight \
  -s "ssoSessionIdleTimeout=$REALM_IDLE" \
  -s "ssoSessionMaxLifespan=$REALM_MAX"
echo "realm seniorinsight atualizado: ssoSessionIdleTimeout=$REALM_IDLE, ssoSessionMaxLifespan=$REALM_MAX"

atualizar_client() {
  local cid="$1" idle="$2" max="$3"
  local uuid
  uuid="$(kc get clients -r seniorinsight -q "clientId=$cid" --fields id --format csv --noquotes | tr -d '\r\n')"
  [ -n "$uuid" ] || { echo "client $cid não encontrado no realm seniorinsight"; exit 1; }
  kc update "clients/$uuid" -r seniorinsight \
    -s "attributes.\"client.session.idle.timeout\"=$idle" \
    -s "attributes.\"client.session.max.lifespan\"=$max"
  echo "client $cid atualizado: client.session.idle.timeout=$idle, client.session.max.lifespan=$max"
}

atualizar_client "si-mobile" "$MOBILE_IDLE" "$MOBILE_MAX"
atualizar_client "si-web" "$WEB_IDLE" "$WEB_MAX"

rm -f /tmp/kcadm.config
EOF
