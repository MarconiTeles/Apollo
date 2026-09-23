# Accent dinâmico, seleção da lateral e lupa — ajuste local

Pedidos explícitos do usuário: fundo do switch adaptável ao accent do macOS; somente o ícone selecionado da lateral usa accent e o mesmo glow da cápsula Minhas tarefas; label continua neutro; Buscar vira lupa.

## Implementação

- `MyTasksFilterToggle.swift`: substituído azul RGB fixo por cor dinâmica AppKit derivada de `NSColor.controlAccentColor`, com 75% de branco. A aparência fornecida ao dynamicProvider é usada ao resolver a cor. Mantidos o Toggle nativo SwiftUI, os estados claro ligado/escuro desligado, dimensões, binding e material da cápsula.
- `EditorialSidebar.swift`: ícones de navegação e listas usam o accent do sistema com o helper compartilhado `accentGlow()` apenas quando selecionados. Labels e contagens usam os mesmos tokens neutros do repouso; itens desabilitados preservam seu estilo apagado. Não foram alteradas ações, fundos de seleção, espaçamentos ou tamanhos.
- `ContentView.swift`: SF Symbol `magnifyingglass`, fonte 15 regular e `TBIconButtonStyle`, como os ícones adjacentes. Mantidas a ação da paleta de comandos e a dica Buscar (⌘K); adicionado nome acessível Buscar.

## Validação

Sonda temporária com a fonte exata do controle e compatibilidade SDK/deployment 14.0, igual à build, nos temas claro/escuro e estados OFF/ON. Capturas locais `toggle-accent-purple.png`, `toggle-accent-blue.png`, `toggle-accent-green.png`. Os accents alternativos foram passados somente por argumento ao processo de inspeção, sem escrever nas preferências globais do usuário. São estados isolados; não equivalem a uma troca manual do accent durante a execução do app autenticado. Hierarquia da sonda contém quatro NSSwitch nativos, estados `[0,1,0,1]`.

A API usada é documentada pela Apple: https://developer.apple.com/documentation/AppKit/NSColor/controlAccentColor e https://developer.apple.com/documentation/appkit/nscolor/init(name:dynamicprovider:).

Build e inspeção da janela final registradas após compilação na auditoria correspondente. Não foram adicionados testes que espelham constantes de estilo.

## Continuidade

Mudanças locais posteriores à release pública 2.0.0. Publicação não realizada nesta etapa. Session_report local pendente de ingestão no Segundo Cérebro: buscar_memoria retornou erro, e os métodos de registro não foram expostos.

Build Release arm64 concluída e assinatura/entitlements aprovados. Aplicativo reaberto (PID 61912). Captura `sidebar-search-accent-window.png` da janela autenticada confirmou os ícones selecionados com accent, labels e contagens neutros, lupa na toolbar e switch ligado com trilho roxo claro. Auditoria: `accent-sidebar-search-build-audit.json`.
