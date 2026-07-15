# Hermes - n8n para WSL Containers (wslc.exe)
# -----------------------------------------------------------------------------
# Imagem oficial do n8n, sem modificacoes de sistema (a base "n8nio/base" nao
# tem gerenciador de pacote nenhum - nem apk nem apt-get - ver
# LICOES-APRENDIDAS.md secoes 10-11 e 15). Qualquer necessidade de Python/
# Playwright/certificado digital para scraping/automacao vive no projeto
# irmao "Argos" (C:\wslc\projects\argos), chamado pelo n8n via HTTP Request
# node quando os dois estao na mesma -SharedNetwork.
# -----------------------------------------------------------------------------
FROM ghcr.io/n8n-io/n8n:latest

# Diferente do Cerbero (que renomeou o usuario "node" para "cerbero"): AQUI
# decidimos NAO renomear o usuario nao-root da imagem oficial - a imagem do
# n8n ja vem com o usuario "node" (uid 1000) pronto e com as permissoes
# certas em /home/node/.n8n; renomear so adicionaria trabalho sem ganho.
USER node

EXPOSE 5678

# CMD e so os ARGUMENTOS do n8n, NAO o comando completo - o
# docker-entrypoint.sh oficial ja faz "exec n8n \"$@\"" (ver
# LICOES-APRENDIDAS.md secao 12). CMD ["n8n", "start"] duplicaria o binario
# e falharia com "Command \"n8n\" not found".
CMD ["start"]
