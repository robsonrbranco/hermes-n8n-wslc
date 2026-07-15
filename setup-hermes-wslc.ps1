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
    wslc run --rm --user root `
        -v ${DataVolume}:/home/node/.n8n `
        --entrypoint chown $ImageTag -R node:node /home/node/.n8n 2>$null | Out-Null
}
Repair-VolumeOwnership

# --- 4b. Rede nomeada compartilhada (opcional, para outros containers WSLC alcancarem o Hermes) ---
# Cada container WSLC vive isolado por padrao - de fora do host, so a porta
# publicada (-p) e alcancavel; outro container WSLC (ex.: cerbero-gateway) nao
# enxerga o Hermes automaticamente, nem por IP nem por nome, a menos que os
# dois estejam na MESMA rede nomeada (mesmo mecanismo do Docker: rede default
# nao da DNS entre containers, rede nomeada/definida pelo usuario da). Ver
# LICOES-APRENDIDAS.md para o raciocinio completo.
$NetworkArgs = @()
if ($SharedNetwork -and $SharedNetwork.Trim() -ne "") {
    Write-Step "Rede compartilhada ($SharedNetwork)"
    try { wslc network create $SharedNetwork 2>$null | Out-Null } catch {}
    # --network-alias registra $Hostname como o nome resolvivel na rede
    # compartilhada, DESACOPLADO do --name tecnico do container
    # ($ContainerName). Assim, se -Hostname virar um dominio de verdade no
    # futuro (migracao pra nuvem), o "endereco" que outros containers usam
    # pra falar com o Hermes muda com ele, sem precisar tocar em
    # -ContainerName (que e so um detalhe interno do wslc). Best-effort: a
    # doc publica do "wslc network" nao confirma exaustivamente este flag -
    # se falhar nesta preview, o container ainda fica alcancavel pelo
    # --name de qualquer forma.
    $NetworkArgs = @("--network", $SharedNetwork, "--network-alias", $Hostname)
}

# --- 5. (Re)inicia o container ------------------------------------------------
Write-Step "Subindo o n8n ($ContainerName)"

Write-Host "Parando/removendo container anterior (se existir)..."
try { wslc container stop $ContainerName 2>$null | Out-Null } catch {}
try { wslc container rm $ContainerName 2>$null | Out-Null } catch {}

$runArgs = @(
    "run", "-d",
    "--name", $ContainerName,
    "-p", "${Port}:5678",
    "-v", "${DataVolume}:/home/node/.n8n"
) + $NetworkArgs + $EnvArgs + @($ImageTag)

wslc @runArgs
if ($LASTEXITCODE -ne 0) { Write-Host "Falha ao iniciar o container." -ForegroundColor Red; exit 1 }

# --- 6. Healthcheck -----------------------------------------------------------
Write-Step "Verificando saude do n8n"
# n8n expoe GET /healthz nativamente (retorna 200 {"status":"ok"}). Mesma
# logica de retry do Cerbero: ate 5 tentativas com 4s entre elas, porque uma
# unica checagem logo apos subir o processo gera falso-negativo (n8n ainda
# esta migrando o banco/inicializando).
$healthy = $false
for ($i = 1; $i -le 5; $i++) {
    Start-Sleep -Seconds 4
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 10
        Write-Host "healthz: $($health.StatusCode) $($health.Content)" -ForegroundColor Green
        $healthy = $true
        break
    } catch {
        Write-Host "Ainda sem resposta em /healthz (tentativa $i/5)..." -ForegroundColor DarkYellow
    }
}
if (-not $healthy) {
    Write-Host "Nao consegui bater em /healthz. Rode: wslc container logs $ContainerName" -ForegroundColor Yellow
}

Write-Step "Pronto"
Write-Host "Editor n8n: http://${Hostname}:$Port/  (requer scripts\add-hosts-entries.ps1 rodado uma vez como Administrador)"
Write-Host "Fallback sem hosts configurado: http://127.0.0.1:$Port/"
Write-Host ""
Write-Host "No primeiro acesso o proprio n8n pede para criar o usuario owner (nome, e-mail, senha) - nao ha .env de usuario/senha a preencher para isso."
if ($SharedNetwork -and $SharedNetwork.Trim() -ne "") {
    Write-Host ""
    Write-Host "Rede compartilhada '$SharedNetwork' ativa - de dentro de outro container WSLC" -ForegroundColor Cyan
    Write-Host "conectado na mesma rede, o Hermes deve ser alcancavel em:"
    Write-Host "  http://${Hostname}:5678   (Hostname configurado, porta INTERNA - nao a $Port publicada no host)"
    Write-Host "Se o nome nao resolver, confira o IP com: wslc container inspect $ContainerName"
}
Write-Host ""
Write-Host "Para acessar http://${Hostname}:$Port direto do navegador do Windows (nao so entre" -ForegroundColor Cyan
Write-Host "containers), rode uma vez como Administrador: .\scripts\add-hosts-entries.ps1"
Write-Host ""
Write-Host "Comandos uteis de operacao:"
Write-Host "  wslc container ps"
Write-Host "  wslc container logs -f $ContainerName"
Write-Host "  wslc container stop $ContainerName"
Write-Host "  wslc container start $ContainerName"
