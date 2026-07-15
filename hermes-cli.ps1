<#
.SYNOPSIS
  Roda um comando avulso do n8n CLI (export/import de workflows e
  credenciais, user-management:reset, etc.) num container descartavel que
  reusa o mesmo volume de dados do Hermes (hermes-data), sem precisar mexer
  no container que ja esta rodando.

.NOTES
  Mesmo padrao do cerbero-cli.ps1 no projeto irmao: comandos de CLI que so
  leem/escrevem dentro de /home/node/.n8n nao precisam falar com o processo
  do n8n em execucao - so precisam enxergar o mesmo volume nomeado.

  Parametro -Args usa Position=0 explicito para nao acionar o bug de
  binding posicional do PowerShell 5.1 (declarar Position em um parametro
  desliga a numeracao automatica dos demais) - mesma licao documentada no
  cerbero-cli.ps1 original.

.EXAMPLE
  .\hermes-cli.ps1 export:workflow --all --output=/home/node/.n8n/backup.json
  .\hermes-cli.ps1 import:workflow --input=/home/node/.n8n/backup.json
  .\hermes-cli.ps1 user-management:reset
  .\hermes-cli.ps1 list:workflow
#>

param(
    [string]$ImageTag = "hermes:local",
    [string]$DataVolume = "hermes-data",
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"

if (-not $Args -or $Args.Count -eq 0) {
    Write-Host "Uso: .\hermes-cli.ps1 <comando n8n> [args...]" -ForegroundColor Yellow
    Write-Host "Ex.:  .\hermes-cli.ps1 export:workflow --all --output=/home/node/.n8n/backup.json"
    exit 1
}

# --- Auto-correcao de ownership do volume nomeado ---------------------------
# Mesma cautela do cerbero-cli.ps1: corrige o dono ANTES de toda invocacao
# (custo pequeno, container descartavel rapido).
wslc run --rm --user root `
    -v ${DataVolume}:/home/node/.n8n `
    --entrypoint chown $ImageTag -R node:node /home/node/.n8n 2>$null | Out-Null

$runArgs = @(
    "run", "--rm", "-i", "-t",
    "-v", "${DataVolume}:/home/node/.n8n",
    "--entrypoint", "n8n",
    $ImageTag
) + $Args

wslc @runArgs
