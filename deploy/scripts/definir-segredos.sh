#!/bin/bash
# Pede as chaves de terceiros (sem mostrar na tela nem gravar no histórico) e cria os Docker secrets
# que a stack usa. Docker secret não pode ser alterado: uma chave que já existe ganha uma versão nova
# (si_gemini_api_key_v2, _v3, ...) e o nome em uso fica em /opt/seniorinsight/segredos.env, que o
# deploy-stack.sh lê para montar o stack.yml. Assim a troca não exige editar o repositório.
#
# Uso, na VM:  bash deploy/scripts/definir-segredos.sh
# Enter em branco pula a chave. No fim, pergunta se aplica com o deploy-stack.sh.
set -euo pipefail

VERSOES=/opt/seniorinsight/segredos.env

# nome base do secret | variável usada no stack.yml | o que é
CHAVES=(
  "si_google_client_secret|SI_SECRET_GOOGLE|Client secret do Google (login com Google no Keycloak)"
  "si_gemini_api_key|SI_SECRET_GEMINI|Chave da API do Gemini (insight-service)"
  "si_openwearables_api_key|SI_SECRET_OPENWEARABLES|API key do Open Wearables (telemetry e care)"
)

docker info >/dev/null 2>&1 || { echo "sem acesso ao Docker: rode com sudo ou com um usuário do grupo docker"; exit 1; }
touch "$VERSOES" && chmod 644 "$VERSOES"   # guarda só nomes de secrets, nunca valores

existe() { docker secret inspect "$1" >/dev/null 2>&1; }
nome_atual() { # variavel nome_base
  local v
  v="$(grep -E "^$1=" "$VERSOES" | tail -1 | cut -d= -f2-)"
  echo "${v:-$2}"
}

alterou=0
for item in "${CHAVES[@]}"; do
  IFS='|' read -r base var descricao <<< "$item"
  atual="$(nome_atual "$var" "$base")"
  if existe "$atual"; then situacao="existe como $atual"; else situacao="ainda não existe"; fi

  echo
  echo "== $descricao"
  echo "   secret $base: $situacao"
  read -rsp "   Cole o valor (Enter em branco para pular): " valor
  echo
  if [ -z "$valor" ]; then echo "   pulado"; continue; fi

  if existe "$atual"; then
    n=2
    while existe "${base}_v$n"; do n=$((n + 1)); done
    novo="${base}_v$n"
  else
    novo="$atual"
  fi

  printf '%s' "$valor" | docker secret create "$novo" - >/dev/null
  unset valor
  sed -i "/^$var=/d" "$VERSOES"
  [ "$novo" = "$base" ] || echo "$var=$novo" >> "$VERSOES"
  echo "   criado: $novo"
  alterou=1
done

echo
echo "== Nomes em uso ($VERSOES)"
if [ -s "$VERSOES" ]; then cat "$VERSOES"; else echo "(todos com o nome base)"; fi

if [ "$alterou" = 1 ]; then
  echo
  read -rp "Aplicar agora com o deploy-stack.sh? [s/N] " resposta
  if [ "${resposta:-n}" = "s" ] || [ "${resposta:-n}" = "S" ]; then
    bash "$(dirname "$0")/deploy-stack.sh"
  else
    echo "Ficou para o próximo deploy (merge na main ou bash deploy/scripts/deploy-stack.sh)."
  fi
fi
