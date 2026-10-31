#!/bin/sh
# Lê a senha do Swarm (/run/secrets) e chama o entrypoint original da imagem do RabbitMQ.
set -eu

RABBITMQ_DEFAULT_PASS="$(tr -d '\r\n' < /run/secrets/RABBITMQ_PASSWORD)"
export RABBITMQ_DEFAULT_PASS

exec docker-entrypoint.sh "$@"
