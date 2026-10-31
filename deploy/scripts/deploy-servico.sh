#!/bin/bash
# Troca a imagem de um serviço da stack e espera o Swarm convergir (com rollback automático).
# Uso: deploy-servico.sh <servico> <imagem:tag>   ex.: deploy-servico.sh care-service ghcr.io/seniorinsight-project/si-care-service:sha-abc1234
set -euo pipefail

SERVICO="seniorinsight_${1:?serviço}"
IMAGEM="${2:?imagem}"

if ! docker service inspect "$SERVICO" >/dev/null 2>&1; then
  echo "O serviço $SERVICO ainda não existe na stack. Rode o deploy do si-infra primeiro."
  exit 1
fi

docker service update --quiet --with-registry-auth --image "$IMAGEM" "$SERVICO"

# Espera até 6 minutos: os serviços Java demoram a ficar saudáveis na VM.
for _ in $(seq 1 72); do
  ESTADO="$(docker service inspect "$SERVICO" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}completed{{end}}')"
  case "$ESTADO" in
    completed) echo "Deploy de $SERVICO concluído com $IMAGEM"; exit 0 ;;
    rollback_completed|rollback_paused|paused)
      echo "::error::O Swarm desfez o deploy de $SERVICO (estado: $ESTADO)."
      docker service ps --no-trunc "$SERVICO" | head -5
      exit 1 ;;
  esac
  sleep 5
done
echo "::error::Tempo esgotado esperando $SERVICO."
docker service ps --no-trunc "$SERVICO" | head -5
exit 1
