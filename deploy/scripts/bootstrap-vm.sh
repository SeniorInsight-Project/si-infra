#!/bin/bash
# Preparação única da VM da Azure para o SeniorInsight. Pode ser repetido sem efeito colateral.
# Uso (na VM): sudo bash deploy/scripts/bootstrap-vm.sh
#
# - aumenta a swap para 4 GB (a VM tem 8 GB de RAM para ~20 containers)
# - liga o Docker Swarm de um nó
# - cria a pasta /opt/seniorinsight/infra (cópia deste repositório usada pela stack)
# - cria os segredos do Swarm que ainda não existem, com valores aleatórios gerados aqui
#   (ninguém precisa ver nem digitar as senhas)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Rode com sudo."; exit 1; }
DONO="${SUDO_USER:-azureuser}"

echo "== swap"
if [ "$(swapon --show=SIZE --bytes --noheadings | awk '{s+=$1} END {print s+0}')" -lt 4000000000 ]; then
  swapoff -a || true
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10 && echo 'vm.swappiness=10' > /etc/sysctl.d/99-seniorinsight.conf
fi
swapon --show

echo "== swarm"
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  docker swarm init --advertise-addr "$(hostname -I | awk '{print $1}')"
fi
docker node ls

echo "== pastas"
install -d -o "$DONO" -g "$DONO" /opt/seniorinsight /opt/seniorinsight/infra

echo "== segredos"
segredo() { # nome valor
  if docker secret inspect "$1" >/dev/null 2>&1; then
    echo "  $1: já existe"
  else
    printf '%s' "$2" | docker secret create "$1" - >/dev/null && echo "  $1: criado"
  fi
}
aleatorio() { openssl rand -hex 32; }

segredo si_db_password            "$(aleatorio)"
segredo si_rabbitmq_password      "$(aleatorio)"
segredo si_keycloak_admin_password "$(aleatorio)"
segredo si_web_client_secret      "$(aleatorio)"
segredo si_identity_client_secret "$(aleatorio)"
segredo si_minio_root_password    "$(aleatorio)"
segredo si_care_jwt_secret        "$(aleatorio)"
segredo si_ow_db_password         "$(aleatorio)"
segredo si_ow_secret_key          "$(aleatorio)"
segredo si_ow_admin_password      "$(aleatorio)"
# Chaves de terceiros: começam com um marcador e são trocadas depois (ver deploy/README.md).
segredo si_gemini_api_key         "nao-configurado"
segredo si_openwearables_api_key  "nao-configurado"

echo "Pronto."
