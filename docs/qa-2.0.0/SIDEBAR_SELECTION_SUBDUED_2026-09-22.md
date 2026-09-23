# Seleção lateral menos branca — macOS 27 dark

Pedido: harmonizar cápsulas selecionadas com o material lateral escurecido, exclusivamente no modo escuro do macOS major 27.

Base: 617a09b; checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`, branch `codex/apollo-2.0.0`.

Implementado em `EditorialSidebar.swift`: receita comum privada para SidebarNavRow e SidebarDotRow. No Liquid Glass do macOS 27 dark, usa o mesmo SidebarLuminanceGlass nativo do painel com ganho RGB 0.65, alfa identidade e blur nativo. A borda branca adicional passa de 0.42 a 0.14 somente nesse modo/OS. Os demais caminhos mantêm a receita anterior; Reduce Transparency mantém seu material sólido. Rótulos, ícones/accent/glow, contadores, dimensões, hit regions, drag/drop e navegação não foram alterados. Ganho do painel permanece 0.31555.

Validação: build Release concluída, entitlements aprovados e `codesign --verify --deep --strict` aprovado. `git diff --check` sem erros. Sonda isolada compila o modifier real extraído do fonte e SidebarLuminanceGlass real, com SDK de compatibilidade 14 igual ao app, em janela darkAqua: `sidebar-selection-subdued-probe.png` inspecionado lado a lado com receita anterior. Resultado: superfície/borda menos brancas, seleção ainda distinguível e foreground preservado. Sonda: `local-tools/sidebar-selection-probe.swift`. Não equivale a teste completo de navegação.

Build local reaberta, PID 20920, janela 3405, captura `sidebar-selection-subdued-window.png`. App estava em modo claro com popup Novo Evento aberto; estado não foi manipulado. Preferências globais não foram alteradas. App instalado em /Applications e release pública não foram substituídos. Log: `build-sidebar-selection-subdued.log`.

Continuidade: session_report local pendente de ingestão no Segundo Cérebro, indisponível nesta sessão. Nenhuma publicação remota. Pendência anterior de textura/tamanho modernos dos traffic lights permanece fora deste ajuste.
