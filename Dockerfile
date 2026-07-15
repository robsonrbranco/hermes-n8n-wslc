# Hermes - n8n para WSL Containers (wslc.exe)
# -----------------------------------------------------------------------------
# Mesma filosofia do Cerbero (OpenClaw): em vez de compilar n8n do source,
# partimos da imagem oficial ja publicada, mantendo este arquivo como uma
# camada fina. Menos "magica" de build = menor chance de esbarrar numa
# limitacao ainda nao madura do runtime (WSLC ainda esta em preview).
#
# Registry: GitHub Container Registry (ghcr.io), nao o registry proprio da
# n8n (docker.n8n.io) nem o Docker Hub. Trocado em 15/07/2026 depois de
# "429 Too Many Requests" persistente em docker.n8n.io mesmo apos esperar e
# tentar de novo (ver LICOES-APRENDIDAS.md, secao 9) - o GHCR e publicado
# pela propria n8n desde a v0.213.0 (2023), nao e um mirror de terceiros, e
# tem rate limit tipicamente bem mais folgado. Reparar que o nome da org
# muda para "n8n-io" (com hifen) aqui, diferente de "n8nio" usado no
# registry proprio e no Docker Hub.
#
# Se ESTE registry tambem der 429/erro de rate limit, os outros dois oficiais
# continuam disponiveis como fallback:
#   FROM docker.n8n.io/n8nio/n8n:latest   - registry proprio da n8n (original)
#   FROM n8nio/n8n:latest                  - Docker Hub (100 pulls/6h por IP anonimo)
# Tags disponiveis em qualquer um dos tres: "latest", "next"/"nightly"
# (canary) ou uma versao fixa (ex.: 2.30.5) - prefira fixar uma versao em
# producao; "latest" fica bom para uso pessoal com upgrades manuais via
# "wslc build --pull".
#
# Nota de vocabulario (mesma convencao do Cerbero): o nome "Dockerfile" e so o
# formato de build que o "wslc build" tambem entende - o runtime alvo deste
# projeto e o WSLC, nao o Docker. No restante deste pacote (scripts, README)
# evitamos a palavra "docker" para descrever nossa propria infraestrutura,
# porque esta maquina pode ter Docker de verdade rodando ao lado, e
# "wslc"/"container" deixa claro qual runtime esta em jogo.
#
# Nao usamos "# syntax=docker/dockerfile:1" de proposito (mesma razao do
# Cerbero): essa diretiva faz o builder buscar o frontend na Docker Hub antes
# mesmo de comecar o build, o que falha se a rede do WSLC nao alcancar
# registry-1.docker.io nesse momento. Este Dockerfile so usa instrucoes
# basicas (FROM/USER/RUN/ENV/WORKDIR/EXPOSE/CMD), que o frontend padrao ja
# resolve sem precisar buscar nada.

FROM ghcr.io/n8n-io/n8n:latest

# -----------------------------------------------------------------------------
# git/curl/jq de diagnostico foram REMOVIDOS de proposito (existiam ate
# 15/07/2026). A build atual desta imagem (2.30.5, GHCR, digest
# sha256:450853cd...) nao tem "apk" (deixou de ser Alpine) NEM "apt-get" -
# nao e so troca de base Alpine->Debian, e uma imagem sem gerenciador de
# pacote nenhum (possivelmente minimal/distroless-like a partir da serie
# 2.x/3.x - ver LICOES-APRENDIDAS.md, secao 11). Como esses pacotes eram so
# para diagnostico manual (nunca foram exigidos pelo n8n em si para
# funcionar), a solucao foi remover a etapa em vez de tentar instalar
# binarios estaticos por fora de um gerenciador - complexidade desnecessaria
# para uma conveniencia opcional. Efeito colateral: nao ha mais "USER root"
# neste Dockerfile, porque so existia para essa instalacao.
# -----------------------------------------------------------------------------
# Diferente do Cerbero (que renomeou o usuario "node" para "cerbero"): AQUI
# decidimos NAO renomear o usuario nao-root da imagem oficial (ainda chamado
# "node", uid/gid 1000). Motivo: o docker-entrypoint.sh oficial do n8n faz
# checagens/ajustes de permissao assumindo especificamente esse usuario e
# HOME=/home/node; renomear arriscaria quebrar esse script em uma futura
# atualizacao de imagem sem trazer beneficio real (o Cerbero renomeou porque
# o OpenClaw expõe o nome do usuario em varios lugares do agente; o n8n nao).
# Todo identificador que NOS criamos (imagem, container, volume, pasta de
# dados, scripts) ainda usa o nome do projeto "hermes" - ver README.
USER node

EXPOSE 5678

# CMD e so os ARGUMENTOS do n8n, NAO o comando completo - diferente do
# Cerbero (CMD ["node", "dist/index.js", "gateway", ...] la, porque o
# ENTRYPOINT do OpenClaw roda o entrypoint puro sem prefixar nada). Aqui o
# ENTRYPOINT da imagem oficial (definido em n8nio/base, nao neste arquivo) e
# ["tini", "--", "/docker-entrypoint.sh"], e esse script JA faz
# "exec n8n \"$@\"" com o CMD como $@. CMD ["n8n", "start"] (a tentativa
# original, por analogia direta com a licao do Cerbero) executava de fato
# "n8n n8n start" - o proprio "n8n" virava um argumento invalido, causando
# "Error: Command \"n8n\" not found" no container (incidente real,
# 15/07/2026 - ver LICOES-APRENDIDAS.md secao 12). Fix: CMD so com o
# subcomando, sem repetir o nome do binario.
CMD ["start"]
