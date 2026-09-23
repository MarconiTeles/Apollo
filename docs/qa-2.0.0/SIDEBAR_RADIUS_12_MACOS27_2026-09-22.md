# Raio do painel lateral: 12 pontos no macOS 27

Pedido explícito posterior substitui o vínculo com o raio nativo implementado em `8172fa2`.

Única alteração de produto: `EditorialSidebar.swift` usa 12 pontos quando a versão major do macOS é 27; demais versões mantêm 16 pontos. Removida a medição dinâmica substituída pelo valor fixo solicitado. A mesma forma continua aplicada ao vidro, recorte e borda. Material, curva contínua, dimensões, margens, sombra, seleção e ações preservados.

Checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`, branch `codex/apollo-2.0.0`; integração por fast-forward na main local. Validação: `./build.sh release` concluído, `codesign --verify --deep --strict` aprovado, `git diff --check` limpo. Build aberta (PID 85616), janela real capturada e inspecionada em `sidebar-radius-12-final-window.png`. Log: `build-sidebar-radius-12.log`. Sem republicação dos artefatos da v2.0.0.

Session_report local pendente de ingestão no Segundo Cérebro, indisponível nesta sessão.
