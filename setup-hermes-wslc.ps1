<#
.SYNOPSIS
  Sobe o n8n num unico container no WSL Containers (wslc.exe), sem depender de
  docker compose - script idempotente, pode rodar de novo a qualquer momento
  (rebuild de imagem, troca de porta, etc.) sem quebrar o que ja esta
  configurado.

.NOTES
  Segue as mesmas convencoes/licoes do projeto irmao Cerbero (OpenClaw no
  WSLC), documentadas em LICOES-APRENDIDAS.md deste pacote:

  - Sem docker-compose: a preview atual do wslc.exe nao documenta suporte a
    Compose como capacidade confirmada. Como o n8n roda muito bem como
    container unico com SQLite embutido (nao precisamos de Postgres/Redis
    separados para uso pessoal), isso nem chega a ser uma limitacao real
    aqui - a arquitetura "single-container" e simplesmente a forma natural
    de rodar n8n sozinho.
  - Volume NOMEADO (nao bind mount de pasta do Windows) para
    /home/node/.n8n: o virtiofs do WSLC reporta bind mounts do Windows como
    mode=777 e nao segura flock/fcntl direito - o n8n guarda credenciais e
    o proprio banco (database.sqlite) dentro dessa pasta, entao um volume
    nomeado real (ext4 dentro da VM do WSLC) evita corrupcao/lock de banco
    e problemas de permissao. Trade-off aceito: a pasta nao aparece
    navegavel no Explorer do Windows.
  - "wslc build --pull": forca checar de novo o registry pela imagem base
    em vez de reusar uma camada antiga em cache local (o Cerbero ficou
    preso numa versao velha do OpenClaw por confiar soh no cache).
  - "N8N_ENCRYPTION_KEY" e gerado uma vez e validado no .env - nunca deve
    mudar depois que houver credenciais salvas (ver comentario no
    .env.example).

.PARAMETER BaseDir
  Pasta no Windows onde fica o .env do Hermes (persistente). Default:
  C:\wslc\data\hermes - mesmo layout agnostico do Cerbero (fonte em
  C:\wslc\projects\hermes, dados em C:\wslc\data\hermes). Note que os DADOS
  do n8n em si (banco, credenciais, workflows) NAO ficam aqui - vivem no
  volume nomeado "hermes-data" (ver acima), so o .env fica neste BaseDir.

.PARAMETER SharedNetwork
  Nome de uma rede nomeada do WSLC (wslc network create/connect) compartilhada
  com outros containers WSLC no mesmo host (ex.: o cerbero-gateway do projeto
  irmao). Sem isso, cada container WSLC so e alcancavel de fora via a porta
  publicada no host (127.0.0.1:<porta>) - dois containers WSLC NAO se
  enxergam automaticamente entre si por nome/IP interno a menos que estejam
  na mesma rede nomeada. Ver LICOES-APRENDIDAS.md para o motivo. Passe
  -SharedNetwork "" (string vazia) para nao conectar a nenhuma rede extra.

.PARAMETER Hostname
  O NOME PELO QUAL o Hermes e endereçado - por outros containers na
  -SharedNetwork, pelo host Windows (via scripts/add-hosts-entries.ps1) e
  pelo proprio n8n em suas URLs auto-referenciadas (N8N_HOST/
  N8N_WEBHOOK_URL no .env). Default: igual a -ContainerName ("hermes-n8n"),
  mas e um parametro SEPARADO de proposito - este pacote e autossuficiente
  (nao depende do projeto Cerbero pra nada, nem o contrario), e o objetivo
  de ter -Hostname destacado e que, no dia de migrar o n8n pra uma infra na
  nuvem (um dominio de verdade, tipo hermes.suaempresa.com), a mudanca fique
  concentrada num unico parametro em vez de espalhada por varios arquivos
  hardcoded com "hermes-n8n"/"localhost". Ao trocar -Hostname, lembre de
  tambem atualizar N8N_HOST/N8N_WEBHOOK_URL no .env (ver README) - o script
  NAO sobrescreve o .env sozinho, so avisa.

.EXAMPLE
  .\setup-hermes-wslc.ps1
  .\setup-hermes-wslc.ps1 -Port 5678
  .\setup-hermes-wslc.ps1 -SharedNetwork hermes-cerbero-net
  .\setup-hermes-wslc.ps1 -Hostname hermes.suaempresa.com
#>

param(
    [string]$BaseDir = "C:\wslc\data\hermes",
    [string]$ImageTag = "hermes:local",
    [string]$ContainerName = "hermes-n8n",
    [string]$DataVolume = "hermes-data",
    [int]$Port = 5678,
    [string]$SharedNetwork = "hermes-cerbero-net",
    [string]$Hostname = "hermes-n8n"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "== $msg ==" -ForegroundColor Cyan
}

# --- 0. Pre-checagem: wslc disponivel? -------------------------------------
Write-Step "Verificando wslc.exe"
try {
    $null = wslc version
} catch {
    Write-Host "wslc.exe nao encontrado. Rode primeiro:" -ForegroundColor Red
    Write-Host "  wsl --update --pre-release" -ForegroundColor Yellow
    Write-Host "e reabra o PowerShell." -ForegroundColor Yellow
    exit 1
}

# --- 1. Pasta para o .env ----------------------------------------------------
Write-Step "Preparando pasta em $BaseDir"
if (-not (Test-Path $BaseDir)) {
    New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
    Write-Host "Criado: $BaseDir"
}

# --- 2. Segredos (.env) ------------------------------------------------------
Write-Step "Segredos (.env)"

$EnvFile = Join-Path $BaseDir ".env"
if (-not (Test-Path $EnvFile)) {
    Copy-Item ".\.env.example" $EnvFile
    Write-Host ""
    Write-Host "Criei $EnvFile a partir do .env.example." -ForegroundColor Yellow
    Write-Host "Preencha N8N_ENCRYPTION_KEY (openssl rand -hex 24) e ajuste GENERIC_TIMEZONE," -ForegroundColor Yellow
    Write-Host "depois rode este script de novo." -ForegroundColor Yellow
    exit 0
}

$EnvVars = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $k, $v = $line.Split("=", 2)
        $EnvVars[$k.Trim()] = $v.Trim()
    }
}
if (-not $EnvVars.ContainsKey("N8N_ENCRYPTION_KEY") -or $EnvVars["N8N_ENCRYPTION_KEY"] -match "^troque-por") {
    Write-Host "Preencha um valor real para N8N_ENCRYPTION_KEY em $EnvFile antes de continuar (openssl rand -hex 24)." -ForegroundColor Red
    Write-Host "IMPORTANTE: gere uma vez so e nunca troque depois - ver comentario no .env.example." -ForegroundColor Red
    exit 1
}

# Aviso (nao bloqueia) se o .env ainda referencia "localhost" enquanto
# -Hostname foi customizado - sinal de que a troca de hostname (ex.: rumo a
# uma migracao pra nuvem) ficou pela metade, so no script e nao no .env.
if ($Hostname -ne "hermes-n8n" -and $Hostname -ne "localhost") {
    foreach ($k in @("N8N_HOST", "N8N_WEBHOOK_URL")) {
        if ($EnvVars.ContainsKey($k) -and $EnvVars[$k] -notmatch [regex]::Escape($Hostname)) {
            Write-Host "Aviso: -Hostname e '$Hostname', mas $k no .env ainda e '$($EnvVars[$k])' - considere atualizar $EnvFile." -ForegroundColor DarkYellow
        }
    }
}

$EnvArgs = @()
foreach ($k in $EnvVars.Keys) {
    $EnvArgs += @("-e", "$k=$($EnvVars[$k])")
}

# --- 3. Build da imagem ------------------------------------------------------
Write-Step "Build da imagem ($ImageTag)"
# --pull forca checar de novo o registry pela imagem base
# (docker.n8n.io/n8nio/n8n:latest) em vez de reusar uma camada em cache local -
# mesma licao do Cerbero (ficou preso numa versao velha do core do OpenClaw
# so confiando no cache).
wslc build --pull -t $ImageTag -f Dockerfile .
if ($LASTEXITCODE -ne 0) { Write-Host "Build falhou." -ForegroundColor Red; exit 1 }

# --- 4. Volume nomeado para /home/node/.n8n ----------------------------------
# Um unico volume nomeado guarda TUDO que o n8n precisa persistir: banco
# (database.sqlite), credenciais criptografadas, workflows, binary data,
# nodes de comunidade instalados. Nao usamos bind mount do Windows aqui pelo
# mesmo motivo documentado no Cerbero (LICOES-APRENDIDAS.md secao 1): o
# virtiofs reporta mode=777 e nao segura lock de sqlite direito - com um
# volume nomeado, dono/permissao ficam corretos e o SQLite do n8n nao corre
# risco de corrupcao por lock falho.
Write-Step "Volume nomeado ($DataVolume)"
try { wslc volume create $DataVolume 2>$null | Out-Null } catch {}

function Repair-VolumeOwnership {
    # Mesma cautela do Cerbero: volumes novos as vezes nascem/voltam a ser
    # donos de root entre execucoes. Chamado antes de toda subida do
    # container, custo baixo (container descartavel rapido).
