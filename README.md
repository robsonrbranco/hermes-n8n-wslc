# Hermes — n8n no WSLC (WSL Containers)

Este pacote sobe o [n8n](https://n8n.io) (automação de workflows) num único
container Linux usando o **WSL Containers** da Microsoft (`wslc.exe`), em
preview público desde 30/06/2026 (GA prevista para o outono de 2026).

Projeto irmão de [Cerbero](../cerbero) (que sobe o OpenClaw no mesmo tipo de
container) — este README assume as mesmas convenções e reaproveita as lições
descobertas lá. Detalhes técnicos e causas-raiz em
**[LICOES-APRENDIDAS.md](./LICOES-APRENDIDAS.md)**.

Este pacote usa a imagem **oficial** do n8n, sem modificações de sistema
(ela não tem gerenciador de pacote nenhum — ver LICOES-APRENDIDAS.md seções
10-11). Qualquer necessidade de Python/Playwright/certificado digital para
scraping/automação vive num terceiro projeto irmão, **[Argos](../argos)**,
chamado pelo n8n via HTTP Request node quando os dois estão na mesma
`-SharedNetwork` (ver LICOES-APRENDIDAS.md seção 15).

## Convenções deste projeto

Mesmas duas regras do Cerbero, aplicadas aqui:

1. **Vocabulário — "wslc", não "docker", para a nossa própria infraestrutura.**
   Reservamos "docker"/"Docker" só para referências factuais reais (a imagem
   oficial `docker.n8n.io/n8nio/n8n`, o Docker Engine/Hub, o formato de build
   `Dockerfile`). Nossas próprias ações e artefatos são descritas com
   "wslc"/"container".
2. **Nome do projeto fixo em tudo que for possível: `hermes`.** Tag de
   imagem (`hermes:local`), nome do container (`hermes-n8n`), volume de
   dados (`hermes-data`), pasta de segredos (`C:\wslc\data\hermes`) e os
   próprios scripts (`setup-hermes-wslc.ps1`, `hermes-cli.ps1`). Evita
   colisão de nomes com outros containers WSLC no mesmo host (ex.: o
   `cerbero-gateway`).

## Layout do projeto

```
C:\wslc\
├── projects\cerbero\   <- código-fonte do Cerbero (OpenClaw)
├── projects\hermes\    <- código-fonte deste pacote (n8n)
└── data\hermes\         <- só o .env (segredos); os DADOS do n8n em si
                            (banco, credenciais, workflows) vivem no volume
                            nomeado "hermes-data" dentro do WSLC, não aqui
```

## 0. Por que não Docker Compose (e por que aqui isso nem é um problema)

Assim como o Cerbero, este pacote não usa `docker compose` porque o
`wslc.exe`, no estado atual do preview, não documenta suporte a Compose como
capacidade confirmada. No caso do OpenClaw isso exigiu replicar módulos na
mão; aqui isso quase nem chega a ser uma limitação: o n8n roda muito bem
sozinho, com o banco SQLite embutido no próprio container — não há um
segundo serviço (Postgres/Redis) a orquestrar para uso pessoal. A
arquitetura "single-container" é simplesmente a forma natural de rodar n8n
standalone.

## 1. Pré-requisitos

```powershell
wsl --update --pre-release
wslc version
```

Se `wslc version` não responder, o preview não está ativo na sua máquina —
pare aqui e atualize o WSL primeiro.

`gh` (GitHub CLI) confirmado instalado neste host — usado para publicar este
repositório (`gh repo create ...`, ver seção de contribuição/publicação, se
houver) e útil para qualquer fluxo futuro de PR/release deste projeto.

## 2. Arquivos deste pacote

| Arquivo | Papel |
| --- | --- |
| `Dockerfile` | Camada fina sobre a imagem oficial `ghcr.io/n8n-io/n8n:latest` (ver LICOES-APRENDIDAS.md, seções 9-11, para o porquê deste registry específico e por que não instala mais ferramentas de diagnóstico) |
| `.env.example` | Template da chave de criptografia e config de rede/timezone |
| `setup-hermes-wslc.ps1` | Build + volume nomeado + sobe o container — idempotente, roda de novo sem medo |
| `hermes-cli.ps1` | Roda qualquer comando `n8n ...` avulso (export/import de workflow, reset de usuário) reusando o mesmo volume |
| `scripts/watchdog-hermes.ps1` + `register-watchdog-task.ps1` + `run-watchdog-hidden.vbs` | Watchdog opcional (Agendador de Tarefas do Windows) — reinicia o container se `/healthz` parar de responder |

### Dados persistentes

Tudo que o n8n precisa guardar (banco `database.sqlite`, credenciais
criptografadas, workflows, execuções, nodes de comunidade instalados) vive
no **volume nomeado do WSLC** `hermes-data`, montado em
`/home/node/.n8n` dentro do container. Sobrevive a `wslc container
rm`/rebuild de imagem.

**Por que volume nomeado e não bind mount de pasta do Windows** (mesma
causa-raiz do Cerbero, ver LICOES-APRENDIDAS.md): o WSLC monta pastas do
Windows via virtiofs, que reporta tudo como `mode=777` e não segura
`flock`/`fcntl` de forma confiável — o SQLite do n8n depende de lock de
arquivo para não corromper o banco. Um volume nomeado vive em ext4 de
verdade dentro da VM do WSLC, com permissões e locking reais. Trade-off
aceito: não aparece navegável no Explorer do Windows (use
`hermes-cli.ps1` para exportar/importar dados quando precisar tirá-los de
lá).

`C:\wslc\data\hermes\.env` não é um volume montado — é só lido pelo script
a cada execução e injetado como variável de ambiente do processo (`-e`).

## 3. Preencher os segredos

1. Rode `.\setup-hermes-wslc.ps1` uma primeira vez — ele cria
   `C:\wslc\data\hermes\.env` a partir do `.env.example` e para aí.
2. Abra esse `.env` e preencha `N8N_ENCRYPTION_KEY`:
   ```powershell
   openssl rand -hex 24
   ```
   **Importante**: gere esse valor uma única vez e nunca troque depois que
   houver credenciais salvas no n8n — trocar a chave torna toda credencial
   existente ilegível, sem forma de recuperar sem a chave antiga.
3. Ajuste `GENERIC_TIMEZONE`/`TZ` se não estiver em `America/Sao_Paulo`.

## 4. Subir o container (build + bootstrap)

```powershell
.\setup-hermes-wslc.ps1
```

O script, de forma idempotente:

- builda a imagem (`wslc build --pull`), com a tag `hermes:local`
- cria (se não existir) o volume nomeado `hermes-data` e corrige a
  permissão dele
- cria/recria o container `hermes-n8n` com a porta e o volume corretos
- confere `/healthz`

Ao final, abra `http://127.0.0.1:5678/`. No primeiro acesso o próprio n8n
pede para você criar o usuário "owner" (nome, e-mail, senha) — não há
usuário/senha pré-configurado via `.env` para isso (o n8n moderno usa gestão
de usuário própria, não `N8N_BASIC_AUTH_*`).

Comandos úteis de operação:

```powershell
wslc container ps                  # status
wslc container logs -f hermes-n8n  # logs
wslc container stop hermes-n8n
wslc container start hermes-n8n
```

## 5. CLI avulso (backup/restore de workflows, reset de usuário)

```powershell
.\hermes-cli.ps1 export:workflow --all --output=/home/node/.n8n/backup.json
.\hermes-cli.ps1 import:workflow --input=/home/node/.n8n/backup.json
.\hermes-cli.ps1 list:workflow
.\hermes-cli.ps1 user-management:reset
```

Como o volume `hermes-data` não é navegável pelo Explorer, para tirar um
backup do Windows use `wslc container cp` (ou rode o export apontando para
dentro do próprio volume e depois copie de dentro do container em
execução):

```powershell
wslc container cp hermes-n8n:/home/node/.n8n/backup.json .\backup.json
```

## 6. Watchdog (opcional, recomendado para uso contínuo)

Mesma lição prática do Cerbero: após um `SIGTERM`/reload de config, o
container do WSLC às vezes não volta sozinho. Um watchdog externo, via
Agendador de Tarefas do Windows a cada 5 min, bate em `/healthz` e reinicia
o container se necessário — com trava anti crash-loop (3+ restarts em 30
min → para e só alerta).

Registrar uma vez:

```powershell
.\scripts\register-watchdog-task.ps1
```

Remover:

```powershell
Unregister-ScheduledTask -TaskName "Hermes Watchdog" -Confirm:$false
```

## 6b. Nome do serviço (`-Hostname`) e acesso pelo nome no navegador

Este projeto é autossuficiente: tudo que ele precisa (build, volume, rede,
resolução de nome) está nos próprios scripts, sem depender de nenhum outro
projeto WSLC no host.

O container é endereçado pelo parâmetro `-Hostname` (default `hermes-n8n`,
igual a `-ContainerName`). Esse valor é usado consistentemente em três
lugares: como alias na rede compartilhada (se `-SharedNetwork` estiver
ativo), como sugestão para `N8N_HOST`/`N8N_WEBHOOK_URL` no `.env` (o script
avisa se ficarem dessincronizados), e como a entrada que
`scripts/add-hosts-entries.ps1` cria no arquivo hosts do Windows. Trocar só
esse parâmetro (ex.: `-Hostname hermes.suaempresa.com` numa futura migração
para nuvem) mantém tudo apontando pro mesmo nome, sem precisar caçar
`"hermes-n8n"`/`"localhost"` hardcoded em vários arquivos.

A rede compartilhada (`-SharedNetwork`, seção 4) só resolve nomes **entre
containers** — o host Windows não participa dela e continua enxergando o
container só pela porta publicada em `127.0.0.1`. Para abrir
`http://hermes-n8n:5678` (em vez de `http://127.0.0.1:5678`) direto no
navegador do Windows, rode uma vez, **como Administrador**:

```powershell
.\scripts\add-hosts-entries.ps1
```

O script adiciona `hermes-n8n` apontando para `127.0.0.1` no arquivo hosts
do Windows (`C:\Windows\System32\drivers\etc\hosts`), faz backup automático
antes de escrever, e é idempotente (não duplica se rodar de novo). Se não
estiver elevado, ele mesmo reabre com UAC.

### Comunicação com outros containers WSLC no mesmo host (opcional)

Se este host também rodar outro container WSLC com quem o Hermes precise
falar diretamente (por exemplo, o projeto irmão [Cerbero](../cerbero)/
OpenClaw, acionado por um workflow via HTTP Request node), o parâmetro
`-SharedNetwork` (default `hermes-cerbero-net`) conecta o Hermes numa rede
nomeada do WSLC compartilhada — mas isso é opcional e só faz sentido se o
outro projeto também estiver configurado para usar a mesma rede. Nenhum dos
dois projetos depende do outro para funcionar sozinho; cada um tem seu
próprio `scripts/add-hosts-entries.ps1`, sem compartilhar arquivo nenhum.
Detalhes técnicos em `LICOES-APRENDIDAS.md`, seções 5b e 5c.

## 7. Verificação final

- [ ] `wslc container ps` mostra `hermes-n8n` como `Up`
- [ ] `http://127.0.0.1:5678/healthz` responde 200
- [ ] O editor abre e permite criar/logar o usuário owner
- [ ] Um workflow simples salva e executa sem erro
- [ ] (se usar watchdog) `Get-ScheduledTask -TaskName "Hermes Watchdog" | Get-ScheduledTaskInfo` mostra execuções recentes sem erro
