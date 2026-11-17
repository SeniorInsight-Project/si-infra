#!/bin/bash
# Aplica a role servico-interno, o client scope billing.trial.write e os clients de serviço
# (si-insight-service, si-notification-service e care-service) num Keycloak que já está rodando
# (o --import-realm só importa na primeira subida). Pode ser repetido: o que já existe é atualizado.
#
# Lê as definições de keycloak/realm-seniorinsight.json para não haver dois lugares a manter.
# Os secrets dos clients vêm do container do Keycloak: /run/secrets/<VARIAVEL> na stack ou a variável
# de ambiente de mesmo nome no Docker Compose. Por isso, na VM, rode bootstrap-vm.sh e faça o deploy
# da stack antes deste script, para o Keycloak já ter os secrets novos montados.
#
# Uso, na VM ou na máquina local (com o Compose no ar):
#   bash deploy/scripts/configurar-clients-de-servico.sh
set -euo pipefail

REALM_JSON="$(cd "$(dirname "$0")/../.." && pwd)/keycloak/realm-seniorinsight.json"
[ -f "$REALM_JSON" ] || { echo "arquivo não encontrado: $REALM_JSON"; exit 1; }

CLIENTS=(si-insight-service si-notification-service care-service)

# Uma linha por item: ROLE <json>, SCOPE <json> e CLIENT <clientId> <variável do secret> <roles> <scopes> <json>.
DEFINICOES="$(python3 - "$REALM_JSON" "${CLIENTS[@]}" <<'PY'
import json, re, sys

with open(sys.argv[1], encoding="utf-8") as f:
    realm = json.load(f)
alvos = sys.argv[2:]

def unico(itens, campo, valor, onde):
    achados = [i for i in itens if i.get(campo) == valor]
    if len(achados) != 1:
        raise SystemExit(f"{onde}: esperado um item com {campo}={valor} em realm-seniorinsight.json")
    return achados[0]

role = unico(realm["roles"]["realm"], "name", "servico-interno", "roles.realm")
print("ROLE", json.dumps(role, ensure_ascii=False))
scope = unico(realm.get("clientScopes", []), "name", "billing.trial.write", "clientScopes")
print("SCOPE", json.dumps(scope, ensure_ascii=False))

padrao = set(realm.get("defaultDefaultClientScopes", []))
for cid in alvos:
    client = dict(unico(realm["clients"], "clientId", cid, "clients"))
    m = re.fullmatch(r"\$\{([A-Z0-9_]+)\}", client.get("secret", ""))
    if not m:
        raise SystemExit(f"client {cid}: o secret precisa ser uma variável, como ${{SI_..._CLIENT_SECRET}}")
    # Scopes padrão do realm já entram sozinhos na criação; aqui vão só os específicos do client.
    extras = [s for s in client.pop("defaultClientScopes", []) if s not in padrao]
    client.pop("optionalClientScopes", None)
    usuario = unico(realm["users"], "serviceAccountClientId", cid, "users")
    roles = usuario.get("realmRoles", [])
    print("CLIENT", cid, m.group(1), ",".join(roles) or "-", ",".join(extras) or "-",
          json.dumps(client, ensure_ascii=False))
PY
)"

KEYCLOAK="$(docker ps -q -f name=seniorinsight_keycloak | head -1)"
if [ -z "$KEYCLOAK" ]; then
  KEYCLOAK="$(docker ps -q -f name=seniorinsight-keycloak | head -1)"
fi
[ -n "$KEYCLOAK" ] || { echo "o serviço seniorinsight_keycloak não está rodando"; exit 1; }

docker exec -i -e DEFINICOES="$DEFINICOES" "$KEYCLOAK" bash -s <<'EOF'
set -euo pipefail
ler() { tr -d '\r\n' < "/run/secrets/$1"; }

# Secret pelo nome da variável: Docker secret (stack) ou variável de ambiente (Compose).
valor_secreto() {
  if [ -f "/run/secrets/$1" ]; then
    ler "$1"
  elif [ -n "${!1:-}" ]; then
    printf '%s' "${!1}"
  else
    echo "secret $1 não encontrado no Keycloak (/run/secrets/$1 ou variável de ambiente)" >&2
    return 1
  fi
}

ADMIN_PASS="$(valor_secreto KEYCLOAK_ADMIN_PASSWORD 2>/dev/null || valor_secreto KC_BOOTSTRAP_ADMIN_PASSWORD)"
ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
KC_URL="http://localhost:8080${KC_HTTP_RELATIVE_PATH:-}"
R=seniorinsight

kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm-servicos.config; }
trap 'rm -f /tmp/kcadm-servicos.config' EXIT
kc config credentials --server "$KC_URL" --realm master --user "$ADMIN_USER" \
  --password "$ADMIN_PASS" >/dev/null

id_scope() { # a imagem do Keycloak não tem awk nem jq
  local id nome
  while IFS=, read -r id nome; do
    [ "${nome%$'\r'}" = "$1" ] && { printf '%s' "$id"; return; }
  done < <(kc get client-scopes -r "$R" --fields id,name --format csv --noquotes)
  return 0
}

while read -r tipo resto; do
  case "$tipo" in
    ROLE)
      if kc get roles/servico-interno -r "$R" >/dev/null 2>&1; then
        echo "role servico-interno: já existe"
      else
        kc create roles -r "$R" -f - <<<"$resto" && echo "role servico-interno: criada"
      fi
      ;;
    SCOPE)
      if [ -n "$(id_scope billing.trial.write)" ]; then
        echo "client scope billing.trial.write: já existe"
      else
        kc create client-scopes -r "$R" -f - <<<"$resto" >/dev/null && echo "client scope billing.trial.write: criado"
      fi
      ;;
    CLIENT)
      read -r cid var roles extras json <<<"$resto"
      segredo="$(valor_secreto "$var")"
      marcador='${'"$var"'}'
      json="${json//"$marcador"/"$segredo"}"

      uuid="$(kc get clients -r "$R" -q "clientId=$cid" --fields id --format csv --noquotes | tr -d '\r\n')"
      if [ -n "$uuid" ]; then
        kc update "clients/$uuid" -r "$R" -f - <<<"$json"
        echo "client $cid: atualizado (secret de $var)"
      else
        kc create clients -r "$R" -f - <<<"$json" >/dev/null
        uuid="$(kc get clients -r "$R" -q "clientId=$cid" --fields id --format csv --noquotes | tr -d '\r\n')"
        echo "client $cid: criado (secret de $var)"
      fi

      if [ "$extras" != "-" ]; then
        for s in ${extras//,/ }; do
          sid="$(id_scope "$s")"
          [ -n "$sid" ] || { echo "client scope $s não existe no realm"; exit 1; }
          kc update "clients/$uuid/default-client-scopes/$sid" -r "$R"
          echo "client $cid: client scope padrão $s"
        done
      fi

      # A service account criada pela Admin API ganha os papéis padrão (que incluem familiar);
      # aqui ela fica só com os papéis de realm do realm-seniorinsight.json.
      sa="service-account-$cid"
      kc remove-roles -r "$R" --uusername "$sa" --rolename default-roles-seniorinsight 2>/dev/null || true
      if [ "$roles" != "-" ]; then
        for papel in ${roles//,/ }; do
          kc add-roles -r "$R" --uusername "$sa" --rolename "$papel"
          echo "client $cid: service account com a role $papel"
        done
      fi
      ;;
  esac
done <<<"$DEFINICOES"
EOF
