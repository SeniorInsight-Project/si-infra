#!/bin/bash
# Atualiza a stack do Swarm a partir deste repositório. Roda no runner da VM
# (workflow .github/workflows/deploy.yml) ou à mão: bash deploy/scripts/deploy-stack.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DESTINO=/opt/seniorinsight/infra
export SI_HOST="${SI_HOST:-seniorinsight-api.eastus.cloudapp.azure.com}"
export SI_ACME_EMAIL="${SI_ACME_EMAIL:-luanhsouzaf@gmail.com}"
# Portal si-web na Vercel: origem liberada no CORS do gateway e destino da raiz do domínio.
export SI_WEB_URL="${SI_WEB_URL:-$(cat /opt/seniorinsight/si-web-url 2>/dev/null || echo https://github.com/SeniorInsight-Project)}"
[ -f /opt/seniorinsight/si-web-url ] || echo "::warning::defina a URL do si-web na Vercel em /opt/seniorinsight/si-web-url"
# Nome atual de cada Docker secret de terceiros (SI_SECRET_*), mantido por deploy/scripts/definir-segredos.sh.
if [ -f /opt/seniorinsight/segredos.env ]; then set -a; . /opt/seniorinsight/segredos.env; set +a; fi

echo "== copiando $REPO para $DESTINO"
rsync -a --delete --exclude .git --exclude .github "$REPO"/ "$DESTINO"/
chmod +x "$DESTINO"/deploy/entrypoints/*.sh "$DESTINO"/deploy/postgres-init/*.sh

echo "== docker stack deploy"
# As imagens do GHCR são públicas. Remove qualquer credencial antiga do ghcr.io: um token
# expirado salvo na VM faz o registry responder "denied" até para pacote público.
docker logout ghcr.io >/dev/null 2>&1 || true

docker stack deploy --prune --resolve-image always \
  -c "$DESTINO/deploy/stack.yml" seniorinsight

# O Caddy lê o Caddyfile na subida: recarrega para pegar mudanças sem derrubar o HTTPS.
CADDY="$(docker ps -q -f name=seniorinsight_caddy | head -1)"
if [ -n "$CADDY" ]; then
  docker exec "$CADDY" caddy reload --config /etc/caddy/si/Caddyfile --adapter caddyfile || true
fi

docker stack services seniorinsight
