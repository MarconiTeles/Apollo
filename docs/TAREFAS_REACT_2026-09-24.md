# Tarefas em React — build DEV isolada (24/09/2026)

> Handoff local pendente de ingestão: `registrar_report`/`resolver_projeto` do Segundo Cérebro falharam nesta sessão.

## O que existe

- `web/apollo-tasks/` — lista em React 19 + Vite, bundle de arquivo único em `Sources/DayPanel/Resources/ApolloTasks/index.html`.
- `Sources/DayPanel/Views/Home/TasksReact/MyTasksReactList.swift` — WKWebView compartilhado (pré-aquecido na montagem da rota), ponte de mensagens, diff do payload, cores resolvidas pelo AppKit (Display P3), SF Symbols como máscaras, alturas de célula do `NSTextField` e todas as ações nativas (NSMenu, bolha de status, mídia, review, soltar em status + desfazer, arquivos do Finder, avatares via `apollo-avatar:` → `AvatarStore`).
- Tudo sob `#if APOLLO_TASKS_REACT`; `EditorialMyTasksView` escolhe a lista. Produção e as outras variantes DEV continuam só com `MyTasksAppKitList`.
- `script/build_dev_tasks_react.sh` — app "Apollo DEV Tasks React", bundle `com.painellunar.app.dev.tasks-react`, saída `build/dev-tasks-react`, cache `.build-dev-tasks-react`. `build.sh` só copia o bundle web com `APOLLO_BUNDLE_TASKS_REACT=1`.
- `--tasks-renderer=appkit` no mesmo binário volta para a lista nativa (A/B). `APOLLO_TASKS_URL` (só DEV) aponta a página para o Vite ou para um `file://`.

## Rolagem

A rolagem é a rolagem threaded do WebKit: nenhuma linha é recriada nem vinculada na thread principal do app durante o gesto. `obscuredContentInsets` + a SPI `_addReasonToHideTopScrollPocket:` (protegida por `responds(to:)`, com fallback para padding) mantêm o conteúdo rolando sob o cabeçalho de vidro e a barra de rolagem abaixo dele, como o `NSScrollView`. Validado com protótipo isolado.

## Paridade verificada

Comparação por diferença de pixels contra `--tasks-renderer=appkit`, mesmo binário, 169 fixtures, modo escuro, Retina 2x: ANEXAR, prioridade, nome do responsável, data, reticências e títulos dos grupos coincidem no pixel. Desvios medidos e calibrados: título (−0,5pt), chevron (−1pt, limite do arredondamento para pixel de tela), contagem após o título (largura arredondada para pixel de tela, como o `sizeToFit`), iniciais (+0,25pt) e gradiente do círculo DONE (o `NSGradient` interpola com alfa pré-multiplicado; a camada passou para CSS). Pixels divergentes na área da lista: 27.162 → 12.323 de 2.499.000 (0,49%). O restante é antialiasing do texto: as extensões dos títulos, inclusive os truncados, batem dentro de 1 pixel de tela.

Limite do teste: eventos sintéticos de mouse não chegam a partir desta sessão (sem permissão de Acessibilidade), então hover, cliques e arrastos não foram exercitados por automação. `APOLLO_TASKS_URL=file://…` não funciona porque o App Sandbox bloqueia a leitura fora do bundle; use `http://localhost:5319/` (`npm run dev`).

## Pendente

- Conferir em uso real: arrastar entre status (slot "SOLTAR EM"), arquivos do Finder (1 tarefa e lote), menus, seletor de status, estados de mídia/review, modo claro.
- Nó do Apollo Studio (`tasks.row.*`) não foi portado (é ferramenta de desenvolvimento).
- A avaliação de fluidez fica com o usuário.

## Animações e design (24/09/2026, segunda etapa)

- Recolher/expandir: as linhas que saem viram "fantasmas" que somem em 140ms atrás das que sobem; as que entram descem 6pt com opacidade em 200ms, escalonadas a cada 12ms (teto de 120ms). O reflow passou a usar `cubic-bezier(0.23, 1, 0.32, 1)` em 220ms.
- O chevron é um único `chevron.right` que gira até 90° em 200ms. Botões ANEXAR, VER REVIEW e "…" encolhem a 0,97 ao pressionar. Tarefa que muda de status pulsa em accent 7,5% por 450ms. Linhas arrastadas ficam a 42% de opacidade. ENVIADO ganhou o mesmo pulso verde do REVISADO.
- O slot de soltura entra com `@starting-style` em vez de keyframes. Há `prefers-reduced-motion`.
- Design: grupos vazios discretos (opacidade 0,45, espaçador de 10pt); ANEXAR sem pílula em repouso, que aparece no hover ou na seleção; datas de hoje e atrasadas em pílula; anel de 0,5pt nos avatares; "· N atrasadas" no grupo recolhido; faixa do grupo fixa sob o cabeçalho da página (fundo opaco, sem desfoque).
- Correções: o Swift omite `phase` quando não há lote, então o JS agora normaliza ausente como nulo (isso também corrige a dica "Anexar nas N tarefas selecionadas"). O `overflow-x` passou a `clip`, porque `hidden` impedia o sticky.
- Vão sob o cabeçalho: o WebKit corta elementos fixos na borda do `obscuredContentInsets`. A área encoberta passou a ser só o cabeçalho (82pt) e os 10pt de respiro viraram padding da página. Medido: faixa de 82 a 116pt, colada na linha do cabeçalho (81pt); o repouso é idêntico ao nativo.
- O relato de linhas visíveis para acompanhar reviews espera 350ms de lista parada.
