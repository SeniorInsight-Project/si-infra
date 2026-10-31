#!/bin/bash
# Instala o runner self-hosted da organização na VM, como serviço do systemd.
# Uso (na VM, como azureuser): bash deploy/scripts/install-runner.sh <TOKEN_DE_REGISTRO>
#
# O token sai em https://github.com/organizations/SeniorInsight-Project/settings/actions/runners/new
# (vale 1 hora). Quem tem o token roda este script; ele não fica salvo em nenhum arquivo do repo.
set -euo pipefail

TOKEN="${1:?Informe o token de registro do runner}"
VERSAO="${RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | grep -oP '"tag_name": "v\K[^"]+')}"
DIR="$HOME/actions-runner"

mkdir -p "$DIR" && cd "$DIR"
if [ ! -f ./config.sh ]; then
  curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${VERSAO}/actions-runner-linux-x64-${VERSAO}.tar.gz"
  tar xzf runner.tar.gz && rm runner.tar.gz
fi

./config.sh --unattended --replace \
  --url https://github.com/SeniorInsight-Project \
  --token "$TOKEN" \
  --name vm-seniorinsight \
  --labels azure-vm,swarm \
  --work _work

sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status --no-pager | head -5
