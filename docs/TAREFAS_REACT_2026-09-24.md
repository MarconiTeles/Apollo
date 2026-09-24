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
