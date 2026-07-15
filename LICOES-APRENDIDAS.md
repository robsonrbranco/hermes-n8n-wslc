# Lições aprendidas — n8n no WSL Containers (Hermes)

Este arquivo reaproveita, para o contexto do n8n, as descobertas técnicas
feitas primeiro no projeto irmão **[Cerbero](../cerbero)** (OpenClaw no
mesmo `wslc.exe`) — ver o
[LICOES-APRENDIDAS.md original](../cerbero/LICOES-APRENDIDAS.md) para o
detalhamento completo de cada causa-raiz, com logs e timeline reais. Aqui
ficam só as lições que valem para **qualquer** container WSLC (não
específicas do OpenClaw), já traduzidas para as decisões deste pacote, mais
o que for descoberto especificamente rodando o Hermes.

## 1. virtiofs e bind mounts do Windows quebram locking de arquivo

A causa-raiz mais importante do Cerbero se aplica igualzinho aqui: o WSLC
monta pastas do Windows dentro da VM Linux via **virtiofs**, que (a) reporta
todo arquivo como `mode=777` (NTFS não tem bits de permissão Unix reais) e
(b) não segura `flock`/`fcntl` de forma confiável.

No Cerbero isso quebrou plugins npm, o auth-profile-store e o state
principal (todos SQLite ou dependentes de lock de arquivo). No Hermes, o
risco é o mesmo e recai sobre um único lugar crítico: `database.sqlite`
dentro de `/home/node/.n8n`, onde o n8n guarda workflows, execuções e
credenciais criptografadas. Um lock falho aqui não é cosmético — pode
corromper o banco.

**Decisão aplicada desde o início** (não precisou ser descoberta por erro,
já veio pronta do Cerbero): `/home/node/.n8n` inteiro mora num **volume
nomeado do WSLC** (`hermes-data`), nunca em bind mount de pasta do Windows.
Ver `setup-hermes-wslc.ps1` e o README, seção "Dados persistentes".

## 2. `wslc build --pull`, não só `wslc build`

O Cerbero ficou preso numa versão velha da imagem base do OpenClaw por um
tempo porque `wslc build` (sem `--pull`) reusa uma camada em cache local
indefinidamente, mesmo quando o `latest` real no registry já mudou — isso
quebrou a instalação de um plugin que exigia uma versão mais nova do core.

Mesma lógica se aplica a qualquer `FROM <imagem>:latest`, incluindo
`docker.n8n.io/n8nio/n8n:latest` deste pacote. `setup-hermes-wslc.ps1` já
usa `--pull` por padrão.

## 3. CMD do Dockerfile precisa do subcomando completo, não do binário "pelado" — **mas isso depende do ENTRYPOINT de cada imagem, ver ressalva na lição 12**

No Cerbero, `CMD ["node", "dist/index.js"]` sem o subcomando `gateway`
caía num modo de onboarding interativo que exige TTY e trava o container
quando rodado com `-d`. Isso levou à decisão original aqui de escrever
`CMD ["n8n", "start"]` no Dockerfile do Hermes, por analogia direta.

**Essa analogia se mostrou errada na prática** (incidente real, ver lição
12): nem toda imagem tem um `ENTRYPOINT` "puro" como o do Cerbero. A imagem
oficial do n8n tem um `docker-entrypoint.sh` que já prefixa `n8n` sozinho
antes de rodar o `CMD` como argumentos — repetir o nome do binário no `CMD`
duplicava o comando. A lição de fundo continua válida ("não deixe o
comportamento default de um binário genérico decidir se o processo vira
daemon ou modo interativo"), mas a forma certa de aplicá-la é **ler o
`ENTRYPOINT`/`docker-entrypoint.sh` real da imagem base antes de escrever o
`CMD`**, não replicar cegamente o padrão de outro projeto.

## 4. Sem suporte a `docker compose` no preview atual do `wslc.exe`

Confirmado no Cerbero: `wslc.exe` documenta bem operações de container
único (`run`, `build`, `image ls`, `container ps/stop`), mas não lista
`docker compose` como capacidade confirmada nas release notes.

No Hermes isso quase não pesa: n8n roda muito bem sozinho com SQLite
embutido, sem precisar de um segundo serviço orquestrado (diferente do
OpenClaw, que tinha dois serviços — gateway e CLI — no compose oficial). Se
no futuro este projeto crescer para precisar de Postgres/Redis dedicados
(fila de execução com múltiplos workers, por exemplo), essa limitação volta
a valer e a mesma estratégia do Cerbero (replicar volumes/portas na mão, um
container por serviço) seria o caminho.

## 5. Particularidades do `wslc.exe` (preview) — válidas para qualquer container

- **Sem `--format`** (Go template) em `container list`/`volume list`.
- **Sem subcomando `restart`.** Só `stop` + `start` separados.
- **`wslc system session terminate`** reseta a sessão/VM inteira — mais
  cirúrgico que `wsl --shutdown` quando a rede da VM trava.
- **Containers descartáveis não compartilham namespace de rede** com um
  container de longa duração já rodando. Se algum dia um comando de CLI do
  n8n precisar falar com o processo em execução (não é o caso hoje — os
  comandos de `hermes-cli.ps1` só leem/escrevem em `~/.n8n`), o caminho é
  `wslc container exec hermes-n8n n8n <comando>` em vez de um container
  avulso.
- **O ID do container muda a cada recriação** (reload de config, restart
  manual). O watchdog (`scripts/watchdog-hermes.ps1`) já foi escrito levando
  isso em conta desde o início (retry com espera entre tentativas de
  `start`), reaproveitando a lição que custou investigação no Cerbero.

## 5b. Dois containers WSLC não se enxergam entre si por padrão (15/07/2026)

Situação real: com o Hermes (`hermes-n8n`) e o Cerbero (`cerbero-gateway`)
rodando ao mesmo tempo no mesmo host, um precisava chamar o outro
internamente (ex.: um workflow do n8n acionando o gateway do OpenClaw).
`localhost` de dentro de um container aponta pra ele mesmo, não pro host
Windows nem pro outro container — comportamento padrão de qualquer runtime
de container, não bug do WSLC.

**Confirmado pesquisando a arquitetura do `wslc.exe`**: todos os containers
WSLC de um mesmo host rodam dentro da **mesma VM Hyper-V dedicada**, com um
Docker Engine por baixo cuja API é literalmente proxied via Hyper-V sockets
(`WSLC_UNIX_CONNECT` relay pro `/var/run/docker.sock` do guest) — ou seja, o
`wslc` não é "parecido" com Docker, ele **é** Docker Engine por baixo, com o
mesmo modelo de rede: `wslc network` suporta os mesmos verbos
(`create`/`connect`/`ls`/`inspect`/`prune`) e os mesmos tipos por container
(`bridge`, `host`, `none`, ou compartilhar o namespace de outro container).

Isso implica a mesma regra do Docker: dois containers na rede **default**
não resolvem um ao outro por nome (sem DNS embutido), só por IP interno; dois
containers numa rede **nomeada/definida pelo usuário** resolvem um ao outro
pelo **nome do container**, na porta **interna** do container (não a porta
publicada no host com `-p`).

**Fix aplicado**: parâmetro `-SharedNetwork` (default `hermes-cerbero-net`)
em `setup-hermes-wslc.ps1` — cria a rede nomeada (idempotente, `wslc network
create` ignorando erro se já existir) e conecta o container nela via
`--network` no `wslc run`. Mesmo parâmetro espelhado em
`../cerbero/setup-cerbero-wslc.ps1`. Depois de rodar os dois setups:

```powershell
# de dentro do hermes-n8n, alcançar o Cerbero:
http://cerbero-gateway:18789
# de dentro do cerbero-gateway, alcançar o Hermes:
http://hermes-n8n:5678
```

**Ressalva de preview**: a documentação oficial do `wslc network` ainda é
escassa (CLI reference público não detalha `create`/`connect` em profundidade
no momento desta lição) — se a resolução por nome não funcionar na prática
(DNS embutido do Docker pode não estar totalmente maduro nesta build), o
fallback é pegar o IP interno via `wslc container inspect <nome>` (procurar
`NetworkSettings.Networks.<rede>.IPAddress` no JSON) e usar IP:porta-interna
diretamente em vez do nome.

**Por que não foi assim desde o início**: os dois projetos nasceram
independentes (um não sabia do outro na hora do design original), e cada
`wslc run` sem `--network` explícito cai na rede default — só virou problema
quando os dois precisaram conversar entre si. Ambos os scripts agora
suportam `-SharedNetwork ""` (string vazia) pra quem só usa um dos dois
projetos e não precisa dessa rede extra.

## 5c. A rede compartilhada (5b) não resolve nomes no HOST Windows, só entre containers (15/07/2026)

Depois de resolver a lição 5b, o pedido seguinte foi acessar
`http://hermes-n8n:5678` e `http://cerbero-gateway:18789` **direto do
navegador no Windows**, não só de dentro de outro container. Isso não
funciona com a rede compartilhada sozinha: a rede nomeada do `wslc network`
é uma rede **interna da VM Hyper-V** (é onde os containers vivem) — o host
Windows não é um membro dessa rede, só enxerga cada container através da
porta publicada em `127.0.0.1` (`-p` no `wslc run`). Sem um resolvedor de
nomes no lado Windows para `hermes-n8n`/`cerbero-gateway`, o navegador
tentava resolver esses nomes como um domínio de internet normal e falhava
(`DNS_PROBE_FINISHED_NXDOMAIN` ou equivalente).

**Fix aplicado**: `scripts/add-hosts-entries.ps1` — edita
`C:\Windows\System32\drivers\etc\hosts` (arquivo de sistema, fora de
qualquer pasta que eu tenha acesso direto; só o usuário, com Administrador,
pode escrever nele) mapeando `hermes-n8n` para `127.0.0.1`. Como a porta
publicada no host já é a mesma usada na URL (5678), só o nome precisava
resolver — a porta na URL continua sendo a porta do host, não muda. Detalhes
de implementação:

- **Auto-elevação**: o script checa se já está rodando como Administrador
  (`WindowsPrincipal`/`WindowsBuiltInRole::Administrator`); se não, reinicia
  a si mesmo via `Start-Process -Verb RunAs`, disparando o prompt UAC, em vez
  de simplesmente falhar com "acesso negado" ao tentar escrever no hosts.
- **Backup automático** do hosts antes de qualquer escrita
  (`hosts.bak-<timestamp>`), mesma disciplina de segurança já aplicada em
  outras partes destes dois projetos (nunca mexer em algo que não dá pra
  desfazer sem ter uma cópia de antes).
- **Idempotência via regex**: antes de adicionar uma entrada, verifica se já
  existe uma linha não-comentada com aquele hostname (`(?m)^\s*[^#\r\n]+\s+
  <nome>\s*$`) — evita duplicar entradas em execuções repetidas, e avisa em
  vez de sobrescrever se o hostname já estiver mapeado (possivelmente para
  outro IP, o que mereceria revisão manual em vez de decisão automática).
- **`ipconfig /flushdns`** no final, para o Windows não continuar servindo
  uma resposta de "não existe" que ficou em cache de uma tentativa anterior
  (comportamento comum de resolver de nomes do Windows cachear falhas por um
  tempo).

**Correção de design (15/07/2026, mesmo dia)**: a primeira versão deste
script gerenciava as entradas dos DOIS projetos (`hermes-n8n` e
`cerbero-gateway`) num arquivo só, mantido aqui no Hermes, com o README do
Cerbero apontando pra cá. Ajuste pedido depois: cada projeto WSLC deve ser
autossuficiente — resolver sozinho todas as suas próprias necessidades de
infra, sem exigir que outro repositório esteja clonado ao lado. Corrigido:
este script agora cuida só da entrada `hermes-n8n`, parametrizado por
`-Hostname` (default `hermes-n8n`, o mesmo valor default de `-Hostname` em
`setup-hermes-wslc.ps1` — ver lição 5d). O Cerbero tem sua própria cópia
independente em `../cerbero/scripts/add-hosts-entries.ps1`, cuidando só de
`cerbero-gateway`. Pequena duplicação de código aceita deliberadamente em
troca de zero acoplamento entre os dois pacotes — cada um roda sozinho, e
migrar/copiar só o Hermes (ou só o Cerbero) pra outra máquina não deixa
nada faltando.

## 5d. `-Hostname`: nome do serviço desacoplado do `-ContainerName`, pensando em migração futura (15/07/2026)

Mesmo ajuste de design da lição 5c, aplicado de forma mais ampla: em vez de
espalhar o literal `"hermes-n8n"` pelo `--network-alias`, pelo `.env`
(`N8N_HOST`/`N8N_WEBHOOK_URL`) e pelo `add-hosts-entries.ps1`
separadamente, o setup ganhou um parâmetro `-Hostname` (default
`hermes-n8n`, independente de `-ContainerName` embora comece igual) que
concentra "qual é o nome pelo qual este serviço é conhecido".

Motivação declarada: se um dia o Hermes migrar pra uma infraestrutura na
nuvem (um domínio real, tipo `hermes.suaempresa.com`, com DNS de verdade),
a mudança fica concentrada em `-Hostname` — os outros parâmetros
(`-ContainerName`, que é só um detalhe técnico de identificação pro
`wslc.exe`, não precisa mudar junto).

**Implementação**:

1. `--network-alias $Hostname` ao conectar na `-SharedNetwork` (best-effort
   — mesma ressalva da lição 5b: doc pública do `wslc network` não confirma
   exaustivamente esse flag nesta preview).
2. Checagem (não bloqueante) no script: se `N8N_HOST`/`N8N_WEBHOOK_URL` no
   `.env` não contêm o valor de `-Hostname`, avisa que os dois podem estar
   dessincronizados — não sobrescreve o `.env` sozinho (é arquivo do
   usuário), só chama atenção.
3. Valor default de `-Hostname` em `scripts/add-hosts-entries.ps1` (ver
   lição 5c) igual ao de `setup-hermes-wslc.ps1`, pra ficar óbvio que os
   dois devem andar juntos se customizados.

## 6. Auto-restart pós-SIGTERM é inconsistente — por isso o watchdog já nasce incluído

No Cerbero, depois de um `SIGTERM` (de reload de config ou outro motivo), o
container às vezes voltava sozinho e às vezes não, sem causa raiz
identificada no supervisor do próprio `wslc.exe` (fora do escopo
investigar). Como não há motivo para achar que esse comportamento é
específico do OpenClaw — é do runtime do WSLC — o Hermes já nasce com o
mesmo watchdog externo (`scripts/watchdog-hermes.ps1` +
`register-watchdog-task.ps1` + `run-watchdog-hidden.vbs`), em vez de esperar
o mesmo bug se repetir para só então reagir.

Detalhes de implementação já carregados do Cerbero (evitam re-descobrir os
mesmos bugs):

- `New-ScheduledTaskTrigger -RepetitionDuration ([TimeSpan]::MaxValue)`
  falha (schema do Agendador não aceita) — usar uma duração grande porém
  válida (`New-TimeSpan -Days 3650`).
- `Register-ScheduledTask` não é `-ErrorAction Stop` por padrão — sempre
  envolver em `try/catch` com `-ErrorAction Stop`, senão um erro de registro
  pode passar batido.
- `-WindowStyle Hidden` direto na ação da tarefa ainda deixa o
  `conhost.exe` piscar uma janela por um frame; usar `wscript.exe` +
  `.vbs` com `WScript.Shell.Run(cmd, 0, True)` evita isso de vez.
- `Add-Content` sem `-Encoding UTF8` corrompe acento na saída do `wslc.exe`
  no log (console do PowerShell 5.1 usa codepage OEM por padrão).
- Grace period pós-boot (`$StartupGraceSec`, padrão 300s): o serviço do
  WSLC demora para subir depois que o Windows reinicia; sem essa checagem,
  o watchdog gasta tentativas do contador anti crash-loop por falhas que não
  são reais.

## 7. Diferença deliberada em relação ao Cerbero: usuário do container não foi renomeado

O Cerbero renomeou o usuário não-root da imagem oficial (`node` → `cerbero`)
porque o nome do agente aparece em vários lugares do próprio OpenClaw. No
Hermes, decidimos **não** renomear (`node` continua `node`): o
`docker-entrypoint.sh` oficial do n8n faz ajustes de permissão assumindo
esse usuário e `HOME=/home/node` especificamente, e renomear arriscaria
quebrar esse script numa atualização futura de imagem sem trazer benefício
real. Todo identificador que **nós** criamos (imagem, container, volume,
scripts) ainda segue a convenção de nome fixo `hermes` — só o usuário
*dentro* da imagem oficial ficou como veio.

## 8. `N8N_ENCRYPTION_KEY`: mesma classe de risco que o `.env` do Cerbero, mas mais crítica

O Cerbero já ensinou que dado sensível/persistente tem que morar só no
`.env` local, nunca em default de script. Aqui isso é ainda mais crítico:
`N8N_ENCRYPTION_KEY` não é só uma credencial de acesso — é a chave simétrica
que criptografa todas as credenciais salvas dentro do n8n (tokens de API de
outros serviços, senhas, etc.). Trocar essa chave depois que já existem
credenciais salvas as torna permanentemente ilegíveis, sem forma de
recuperar. `setup-hermes-wslc.ps1` valida que o valor não ficou no
placeholder antes de subir o container, mas não existe (nem pode existir)
validação automática contra "trocar por engano uma chave que já estava em
uso" — vale reforçar isso para quem for operar o Hermes no dia a dia: nunca
regenerar esse valor num `.env` já em uso.

## 9. Incidente real: `429 Too Many Requests` no `FROM` durante o build (15/07/2026)

Primeira execução de `setup-hermes-wslc.ps1` falhou logo no `wslc build
--pull` com:

```
failed to solve: docker.n8n.io/n8nio/n8n:latest: unexpected status from HEAD
request to https://docker.n8n.io/v2/n8nio/n8n/manifests/latest: 429 Too Many
Requests
```

**Causa**: rate limit do próprio registry `docker.n8n.io` (não é um erro de
configuração deste pacote, nem do WSLC/virtiofs — é o registry recusando a
requisição HEAD que resolve a tag `latest` antes mesmo de baixar qualquer
camada). Pode acontecer com qualquer registry de container sob throttling
temporário, mais visível logo depois de várias tentativas de build seguidas
(cada `--pull` força uma nova checagem contra o registry, por desenho — ver
lição 2 deste arquivo).

**O que fazer quando acontecer:**

1. Esperar alguns minutos e rodar `.\setup-hermes-wslc.ps1` de novo — na
   maioria dos casos o throttling é temporário e passa sozinho.
2. Se persistir, a n8n publica a mesma imagem em mais dois registries
   oficiais (confirmado em 15/07/2026 — não são mirrors de terceiros, fazem
   parte do próprio pipeline de release da n8n, ver Referências):
   ```dockerfile
   FROM ghcr.io/n8n-io/n8n:latest   # GitHub Container Registry - preferir este
   FROM n8nio/n8n:latest            # Docker Hub - segunda opção
   ```
   **GHCR primeiro**: o nome da org muda para `n8n-io` (com hífen), diferente
   de `n8nio` usado no registry próprio e no Docker Hub — reparar nesse
   detalhe ao trocar o `FROM`. Publicado desde a v0.213.0 do n8n (2023,
   pedido pela comunidade especificamente por causa de rate limit em outro
   registry), com rate limit tipicamente bem mais folgado que Docker Hub.
   Confirmei a tag `latest` ativa e atualizada há poucas horas antes de
   escrever esta lição.

   Docker Hub como segunda opção porque também tem rate limit próprio para
   pulls anônimos (100 pulls/6h por IP) — só ajuda se o throttling for
   específico do `docker.n8n.io` e não da rede/IP do host; se os três
   registries estiverem throttlando ao mesmo tempo, o problema provavelmente
   é do lado do host, não dos registries.
3. Alternativa mais robusta a longo prazo, em qualquer um dos três
   registries: fixar uma tag de versão exata (ex.:
   `FROM ghcr.io/n8n-io/n8n:2.30.5`) em vez de `latest` — reduz a frequência
   de re-resolução de manifest em rebuilds futuros que não precisam de
   imagem nova.

**Desfecho real**: a espera de alguns minutos (passo 1) **não** resolveu — o
`429` persistiu numa segunda tentativa de `.\setup-hermes-wslc.ps1`. Trocamos
o `FROM` do `Dockerfile` para `ghcr.io/n8n-io/n8n:latest` (passo 2, primeira
opção). Se o GHCR também throttlar no futuro, a lição acima já documenta o
Docker Hub como próximo fallback. Ainda não temos evidência de que o
`docker.n8n.io` tenha throttling estrutural/persistente (pode ter sido uma
janela ruim específica) — vale tentar voltar para ele em builds futuros antes
de assumir que está permanentemente inviável.

## 10. Incidente real: `apk: not found` — a imagem oficial do n8n deixou de ser Alpine (15/07/2026)

Depois de trocar o registry para GHCR (lição 9), o build passou do `FROM`
mas quebrou no `RUN apk add ...`:

```
[2/2] RUN apk add --no-cache git curl jq
process "/bin/sh -c apk add --no-cache git curl jq" did not complete
successfully: exit code: 127
  | /bin/sh: apk: not found
```

**Causa**: a suposição original deste `Dockerfile` (herdada da documentação
histórica da n8n — imagem baseada em Alpine, gerenciador `apk`) não é mais
verdadeira para a build resolvida (`ghcr.io/n8n-io/n8n:latest`, digest
`sha256:450853cd...`, tag `2.30.5` no momento). Essa build não tem `apk`
instalado — ou a n8n migrou a base da imagem oficial para Debian/Ubuntu em
algum ponto entre a série 1.x e a 2.x/3.x atual, ou essa build específica do
GHCR difere da que está em `docker.n8n.io`/Docker Hub. Não confirmamos qual
das duas — não valia a pena inspecionar a imagem manualmente só para essa
decisão, porque a correção abaixo funciona nos dois casos de qualquer forma.

**Fix tentado (não resolveu)**: reescrever o `RUN` para detectar o
gerenciador disponível (`command -v apk` vs. `command -v apt-get`) em vez de
assumir Alpine. Rodando de novo, esse `RUN` caiu no `else` — **nem `apk` nem
`apt-get` existem nesta imagem**:

```
Gerenciador de pacote desconhecido nesta imagem base (nem apk nem apt-get).
```

## 11. `ghcr.io/n8n-io/n8n:latest` (2.30.5) não tem gerenciador de pacote nenhum

Não é uma troca simples de Alpine para Debian/Ubuntu (lição 10) — a build
atual não expõe `apk` nem `apt-get`, o que sugere uma imagem mínima
(possivelmente estilo distroless, ou um base custom só com o runtime Node +
n8n, sem ferramental de SO). Isso é coerente com a mudança de versionamento
observada no GHCR na mesma investigação (tags `2.30.5`, `v3-nightly` — a n8n
parece ter reestruturado a arquitetura de imagens/releases em algum ponto
entre a série 1.x conhecida e a atual, possivelmente separando também um
"runner image" à parte, como sugerido por uma thread não relacionada da
comunidade). Não investigamos further porque não era necessário para o
objetivo real deste pacote.

**Fix aplicado**: removida a instalação de `git`/`curl`/`jq` do `Dockerfile`
por completo, em vez de tentar contornar a ausência de gerenciador de pacote
(ex.: baixar binários estáticos por fora — complexidade desnecessária). Esses
pacotes nunca foram exigidos pelo n8n para funcionar, eram só conveniência
para diagnóstico manual dentro do container; sem eles, `wslc container exec
hermes-n8n <comando>` ainda funciona para qualquer binário que já vier na
imagem. Efeito colateral: o `Dockerfile` não usa mais `USER root` em lugar
nenhum, porque essa era a única razão dele existir.

**Lição prática mais ampla**: ao adaptar convenções de um projeto irmão
(aqui, o `Dockerfile` do Cerbero, que assumia Alpine porque a imagem do
OpenClaw realmente era Alpine), não assumir que a mesma característica vale
para a nova imagem base só porque "imagens Node costumam ser Alpine" — vale
conferir  a build real antes de commitar a suposição, em vez de descobrir
via build falhando.

## 12. Incidente real: `Error: Command "n8n" not found` — CMD duplicava o binário (15/07/2026)

Depois do build passar (lições 9-11), o container subiu e morreu quase
imediatamente (`wslc container ps -a` mostrava `exited`). O log real
(`wslc container logs hermes-n8n`) mostrou:

```
Error: Command "n8n" not found
```

**Causa**: o `Dockerfile` tinha `CMD ["n8n", "start"]` (ver lição 3, decisão
original por analogia com o Cerbero). O `ENTRYPOINT` da imagem oficial do
n8n (herdado de `n8nio/base`, confirmado lendo o
[`Dockerfile`](https://github.com/n8n-io/n8n/blob/master/docker/images/n8n/Dockerfile)
e o
[`docker-entrypoint.sh`](https://github.com/n8n-io/n8n/blob/master/docker/images/n8n/docker-entrypoint.sh)
reais do projeto n8n) é:

```dockerfile
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
```

```sh
# docker-entrypoint.sh
if [ "$#" -gt 0 ]; then
  exec n8n "$@"      # $@ = o CMD inteiro
else
  exec n8n
fi
```

Ou seja, o script **já prefixa `n8n`** antes de executar o `CMD` como lista
de argumentos. Com `CMD ["n8n", "start"]`, o comando final executado era
`n8n n8n start` — o segundo `n8n` virava um argumento inválido para o CLI
real, daí `Command "n8n" not found`.

**Fix aplicado**: `CMD ["start"]` — só o subcomando, sem repetir o nome do
binário. O entrypoint monta `exec n8n start`, que é o comando correto.

**Lição de processo, não só técnica**: este bug só existiu porque a decisão
de `CMD ["n8n", "start"]` foi tomada por analogia com o Cerbero (lição 3)
sem checar o `ENTRYPOINT`/`docker-entrypoint.sh` reais da imagem base do
n8n antes. O `ENTRYPOINT` do Cerbero (OpenClaw) roda o binário "cru", sem
prefixar nada — por isso lá o `CMD` precisava do comando completo. Já o
n8n tem um wrapper que prefixa o binário sozinho. **Regra a seguir daqui
para frente, em qualquer novo projeto WSLC**: antes de escrever `CMD` num
`Dockerfile` que parte de uma imagem de terceiros, ler o `ENTRYPOINT`
efetivo dela (na própria imagem ou no Dockerfile upstream, se público) em
vez de assumir que segue o mesmo padrão de um projeto anterior.

## 13. Deprecations reais da versão 2.30.5 pegas no primeiro boot bem-sucedido (15/07/2026)

Com o container finalmente saudável (`n8n ready on ::, port 5678`,
`/healthz` 200), o log ainda mostrou avisos de deprecação para variáveis
que este pacote já vinha configurando desde o `.env.example` original:

```
- N8N_RUNNERS_ENABLED -> Remove this environment variable; it is no longer needed.
- WEBHOOK_URL -> Use N8N_WEBHOOK_URL instead, which sets the base URL for both test and production webhooks.
```

**Causa**: o `.env.example` original foi escrito com base na documentação
histórica do n8n (série 1.7x, onde `N8N_RUNNERS_ENABLED=true` era
obrigatório e `WEBHOOK_URL` era o nome correto da variável). A versão
resolvida por este pacote (2.30.5) já não exige mais habilitar runners
explicitamente (comportamento agora é o default) e renomeou a variável de
webhook.

**Fix aplicado**: removida `N8N_RUNNERS_ENABLED` do `.env.example` e do
`.env` real; `WEBHOOK_URL` renomeada para `N8N_WEBHOOK_URL` nos dois
arquivos. Após a mudança, `wslc container stop hermes-n8n` + `start` (ou
rodar `.\setup-hermes-wslc.ps1` de novo) aplica as novas variáveis.

Avisos de deprecação que ficaram de fora de propósito (não exigem ação,
só mudam um *default* no futuro — quem quiser manter o comportamento atual
pode setar explicitamente, mas não é obrigatório hoje):
`N8N_UNVERIFIED_PACKAGES_ENABLED`, `N8N_RUNNERS_TASK_TIMEOUT`,
`N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES`,
`N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES`.

Também apareceu, sem ser erro: `Failed to start Python task runner in
internal mode ... Python 3 is missing from this system` — inofensivo para
quem só usa nodes padrão em JavaScript (o caso de uso deste pacote); só
importa se algum workflow futuro precisar rodar código Python dentro do
n8n, o que exigiria um runner externo (fora do escopo deste setup inicial).

## 14. Ferramentas confirmadas disponíveis neste host (15/07/2026)

Registro simples, sem incidente por trás — só para não precisar redescobrir
em sessões futuras: `gh` (GitHub CLI) está instalado e autenticado neste
host, confirmado ao publicar tanto este repositório quanto o do Cerbero via
`gh repo create ... --push`. Relevante para qualquer automação futura que
precise interagir com o GitHub (releases, PRs, issues) sem precisar
verificar disponibilidade do zero.

## 15. Necessidade de Python/Playwright/certificado digital: por que virou um projeto separado (Argos), não um Dockerfile maior aqui (15/07/2026)

Surgiu a necessidade de rodar scraping autenticado (certificado digital A1,
consultas no CAV da Receita Federal) a partir de workflows do n8n. Como as
lições 10-11 já tinham estabelecido que a imagem oficial do n8n não tem
gerenciador de pacote nenhum, a primeira tentativa foi reconstruir o Hermes
inteiro `FROM debian:bookworm-slim`, instalando Node+n8n via `npm install -g`
e Python+Playwright+Chromium por cima — funcionou (build passou, container
saudável), mas trocava a manutenção automática da imagem oficial (updates de
segurança do n8n, versões testadas pelo próprio time) por manutenção manual
da dupla Node/n8n daqui pra frente.

**Decisão final**: reverter o Hermes para a imagem oficial (`ghcr.io/n8n-io/n8n`,
lições 9-12, sem nenhuma dependência extra) e criar um projeto irmão,
**Argos** (`../argos`), só para o scraper — mesmo padrão de autossuficiência
de Cerbero/Hermes (`Dockerfile` próprio sobre Debian completo, `setup-argos-wslc.ps1`,
`-Hostname argos-scraper`). O acoplamento entre os dois é só uma chamada HTTP
(`scraper-server.py` do Argos expõe `/scrape`), na mesma `-SharedNetwork` já
usada com o Cerbero (lição 5b) — nenhuma tecnologia nova, só reaproveitar o
padrão de rede nomeada.

**Achado de segurança durante a migração**: os dois scripts Python do
scraper tinham a senha do certificado A1 hardcoded como valor default
(`DEFAULT_PASS = "..."`), e viviam em `scripts/`, pasta que **não** estava
protegida pelo `.gitignore` (só `certs/` tinha proteção, e olhe lá, foi
adicionada depois de já existir sem ela). Como nenhum desses arquivos tinha
sido commitado ainda, deu pra corrigir sem deixar rastro no histórico: senha
passou a vir exclusivamente de `os.environ.get("CERT_PASSWORD", "")`, e o
`.gitignore` do Argos já nasce com `certs/` protegido desde o primeiro
commit. Ver `../argos/LICOES-APRENDIDAS.md` para o detalhamento completo.

**Lição de processo**: `.gitignore` cobre pastas de dados óbvias (`certs/`,
`.env`), mas não protege contra um valor sensível parar em lugar
inesperado, como o default de um argumento de função dentro de um script
`.py` "normal". Vale revisar o conteúdo de qualquer arquivo novo que lide
com credenciais antes do primeiro `git add`, não confiar só no `.gitignore`.

## Referências usadas

- `../cerbero/LICOES-APRENDIDAS.md` — registro original de todas as
  causas-raiz acima, com logs e timeline reais da primeira instalação no
  WSLC.
- [docs.n8n.io/hosting](https://docs.n8n.io/hosting/) — variáveis de
  ambiente, `/healthz`, `N8N_ENCRYPTION_KEY`, task runners.
- [community.n8n.io — pedido original de publicar em GHCR](https://community.n8n.io/t/please-consider-publishing-your-docker-image-to-another-registry-in-addition-to-dockerhub/22119)
  — histórico de por que o GHCR existe como opção (mesmo motivo: rate limit),
  PR mesclado e lançado na v0.213.0.
- [github.com/n8n-io/n8n/pkgs/container/n8n](https://github.com/n8n-io/n8n/pkgs/container/n8n)
  — página oficial do pacote GHCR, usada para confirmar que a tag `latest`
  está ativa.
