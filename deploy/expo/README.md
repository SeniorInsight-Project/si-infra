# VM de testes do app (Expo)

O **si-mobile** não vai para a VM da stack: em produção ele é buildado e publicado nas lojas.
Para testar, existe uma VM pequena só para ele, `vm-seniorinsight-expo` (D2as_v4, 2 vCPU / 8 GB; a série B não tem capacidade na Azure for Students),
que roda o servidor do Expo com a `main` do si-mobile.

- QR para o Expo Go: **https://seniorinsight-expo.eastus.cloudapp.azure.com/**
- URL direta: `exp://seniorinsight-expo.eastus.cloudapp.azure.com:8081`
- API usada pelo app: `https://seniorinsight-api.eastus.cloudapp.azure.com` (a stack da outra VM)

O endereço é fixo, então o QR é sempre o mesmo e pode ser colado no grupo da equipe.

## Ligar e desligar

A VM fica **desligada** e só gasta crédito enquanto está ligada (o disco e o IP custam centavos por dia).
Ligue antes de testar e desligue ao terminar, pelo portal da Azure (Iniciar / Parar) ou:

```bash
az vm start      -g rg-seniorinsight -n vm-seniorinsight-expo
az vm deallocate -g rg-seniorinsight -n vm-seniorinsight-expo   # "Parar" no portal faz o mesmo
```

Ao ligar, ela baixa a `main` mais recente do si-mobile, roda `npm ci` se o `package-lock.json` mudou e
sobe o Expo. Leva de 2 a 5 minutos; a página do QR mostra "no ar" quando estiver pronto.
Esqueceu ligada? Ela desliga sozinha às 02:00 UTC (23:00 em Brasília).

## Como testar

1. Instale o **Expo Go** (Play Store / App Store), na versão compatível com o SDK do app (57).
2. Abra https://seniorinsight-expo.eastus.cloudapp.azure.com/ e escaneie o QR.

No **iPhone**, o Expo Go (SDK 57+) só abre o projeto se estiver logado na **mesma conta Expo**
do CLI da VM. A VM usa um token de acesso da conta `luandeferreira777`, gravado em
`/etc/si-expo-token.env` (só root lê). Quem testar no iPhone entra no Expo Go com essa conta.
No Android isso ainda não é exigido.

Para trocar o token: crie outro em expo.dev → Access tokens e grave na VM
`EXPO_TOKEN=<token>` em `/etc/si-expo-token.env` (`chmod 600`), depois `sudo systemctl restart si-expo`.

Login pelo Keycloak dentro do Expo Go: o redirect do Expo Go é `exp://...`, e o client `si-mobile`
do realm só aceita `seniorinsight://auth`. Para o login funcionar no Expo Go, o client precisa aceitar
também `exp://seniorinsight-expo.eastus.cloudapp.azure.com:8081/--/*`.

## Operação

```bash
ssh azureuser@seniorinsight-expo.eastus.cloudapp.azure.com
sudo journalctl -u si-expo -f            # log do Expo/Metro
sudo systemctl restart si-expo           # pega a main de novo sem reiniciar a VM
sudoedit /etc/si-expo.env                # trocar branch (SI_MOBILE_BRANCH) ou URL da API
```

Criação (já feita; só numa VM nova): `bash deploy/expo/criar-vm.sh <chave-publica.pub>`.

O Metro fica aberto na internet enquanto a VM está ligada, como qualquer servidor de desenvolvimento
exposto: ele só serve o código do app, que já é público, mas é mais um motivo para deixá-la desligada
quando ninguém estiver testando.
