#!/bin/bash
# Cria a VM de testes do Expo (si-mobile) na Azure. Rodar uma vez, com o Azure CLI logado (az login).
# Uso: bash deploy/expo/criar-vm.sh [caminho-da-chave-publica-ssh]
#
# A VM fica DESLIGADA por padrão para não gastar crédito: ligue só quando for testar
# (deploy/expo/README.md). Ela também desliga sozinha às 02:00 UTC (23:00 em Brasília).
set -euo pipefail

RG="${SI_EXPO_RG:-rg-seniorinsight}"
LOCAL="${SI_EXPO_LOCAL:-eastus}"
NOME="${SI_EXPO_VM:-vm-seniorinsight-expo}"
DNS="${SI_EXPO_DNS:-seniorinsight-expo}"
TAMANHO="${SI_EXPO_TAMANHO:-Standard_B2s}"   # 2 vCPU / 4 GB: o Metro precisa de uns 2 GB no bundle
CHAVE="${1:-$HOME/.ssh/id_ed25519.pub}"
HOST="${DNS}.${LOCAL}.cloudapp.azure.com"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CHAVE" ] || { echo "Chave pública SSH não encontrada: $CHAVE"; exit 1; }

INIT="$(mktemp)"; trap 'rm -f "$INIT"' EXIT
sed "s/__SI_EXPO_HOST__/${HOST}/g" "$DIR/cloud-init.yaml" > "$INIT"

echo "== criando $NOME ($TAMANHO) em $RG"
az vm create \
  --resource-group "$RG" --location "$LOCAL" --name "$NOME" \
  --image Ubuntu2404 --size "$TAMANHO" \
  --admin-username azureuser --ssh-key-values "$CHAVE" \
  --public-ip-sku Standard --public-ip-address-dns-name "$DNS" \
  --os-disk-size-gb 32 --storage-sku StandardSSD_LRS \
  --nsg-rule SSH --custom-data "$INIT" \
  --tags projeto=seniorinsight uso=expo-testes \
  --output table

NSG="${NOME}NSG"
echo "== liberando 80 (página do QR) e 8081 (Metro)"
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n expo-pagina --priority 1010 \
  --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 80 --output none
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n expo-metro --priority 1020 \
  --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 8081 --output none

echo "== desligamento automático às 02:00 UTC"
az vm auto-shutdown -g "$RG" -n "$NOME" --time 0200 --output none

echo
echo "Pronto. O primeiro boot leva uns 10 minutos (Node, npm ci e primeiro bundle)."
echo "QR do Expo Go: http://${HOST}/   ·   URL: exp://${HOST}:8081"
echo "Para não gastar crédito, desligue quando terminar: az vm deallocate -g $RG -n $NOME"
