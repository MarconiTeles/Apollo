# Quadro em React — build DEV isolada, pareada com o Board do ClickUp (24/09/2026)

> Handoff local, PENDENTE DE INGESTÃO: `resolver_projeto` e `buscar_memoria` do Segundo Cérebro falharam nesta sessão.
> Base: `main` `6a61361`, branch `t3code/reconstruir-quadros-react`. Referências (não versionadas no `main`): `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/t3/docs/auditoria-quadro-clickup-2026-09-24.md` e `plano-pareamento-quadro-clickup-2026-09-24.md`.

## O que existe

- `web/apollo-board/` — React 19 + Vite, arquivo único em `Sources/DayPanel/Resources/ApolloBoard/index.html`.
- `Sources/DayPanel/Views/Home/BoardReact/` (tudo sob `#if APOLLO_BOARD_REACT`):
  - `BoardReactView.swift` — WKWebView compartilhado, payload com diff, cores do AppKit, menu de contexto nativo, mutações, esquema `apollo-cover:` (miniaturas com cache em disco de 256 MB).
  - `BoardCardMetadataStore.swift` — anexos, capa e checklist via `getTask` só dos cards visíveis, um por vez com espaçamento, pausa de 30 s em falha, cache em `Caches/ApolloBoard` por `date_updated`. Sem hidratação = "desconhecido", nunca zero.
  - `BoardReactPreferences.swift` — configuração por lista (`dp_board_react_prefs_v1`) e ordem manual por grupo (`dp_board_react_order_v1`); lê a ordem antiga `dp_board_cardOrder_v1` como fallback, sem reescrevê-la.
- `EditorialBoardView` escolhe o renderer; produção continua com `BoardAppKitViewport` e não compila nada disso.
- `CUTask.Attachment` ganhou `thumbnailURL` e `dateAdded` (campos opcionais; caches antigos continuam decodificando).
- `script/build_dev_board_react.sh` — "Apollo DEV Board React", `com.painellunar.app.dev.board-react`, `build/dev-board-react`, cache `.build-dev-board-react`. Tarefas e Agenda também em React, como em produção. `--board-renderer=appkit` volta ao quadro nativo no mesmo binário. `APOLLO_BOARD_URL=http://localhost:5321/` (só DEV) carrega o Vite.

## Controles nativos (macOS 27) — segunda etapa

A página não tem mais barra própria nem popovers web; o React ficou só com colunas, cards, criação inline e arraste.

- Toolbar da janela, rota Quadro: grupo de vidro (`ToolbarGlassGroup`) com três `Menu` nativos — Agrupar por, Ordenar (campo + direção) e Opções de exibição (subtarefas, tamanho, campos no card, capas, campos vazios, fechadas, recolher vazios/todos/expandir). O ícone fica na cor de destaque quando a opção sai do padrão, como o filtro de Comentários. `BoardReactToolbar.swift`.
- Busca: `.searchable(placement: .toolbar)` nativo; o botão de busca global some nessa rota para não duplicar (⌘K continua abrindo a paleta pelo menu). Contagem visível como `navigationSubtitle` ("163 tarefas").
- "+ Tarefa" removido: o botão Nova tarefa do header já existe. Criação por coluna continua no card.
- Prioridade, etiquetas e responsáveis: `NSMenu` (bandeiras coloridas, pontos de cor, avatares, ✓). Vencimento: `NSPopover` com atalhos + `DatePicker` gráfico. Menu "…" da coluna: `NSMenu`.
- `BoardReactPreferences` virou `ObservableObject` (toolbar e página editam a mesma configuração da lista ativa).
- Página: cores semânticas do AppKit (label/secondary/tertiary, separator, system fills), texto 13 pt, checkbox no formato do NSButton, campo de criação com anel de foco do NSTextField, sem dica de teclado.
- Barra de seleção em lote: flutua sozinha sobre as colunas, que seguem até o fim da janela passando por trás do vidro. Só a rolagem de cada coluna ganha 96 pt de folga no fim (`insets.overlay`) enquanto há seleção.
- `searchToolbarBehavior(.minimize)` não existe no macOS; o campo de busca recolhe à lupa sozinho quando falta espaço.

## Linguagem visual do Apollo — terceira etapa

O visual deixou de copiar o ClickUp (lanes coloridas, pílulas sólidas, chips com borda) e passou a seguir o Quadro nativo do app:

- Header: o mesmo `finderHeaderMaterial` nativo do Quadro atual (toolbar + faixa de grupos + filete), por cima do web view; os cards passam por baixo e o AppKit desfoca. A primeira tentativa com `backdrop-filter` na página espalhava manchas e piscava perto do topo durante a rolagem (reproduzido no app com `?diag=scroll`); foi descartada.
- Cápsulas de grupo são SwiftUI (`BoardReactHeaderTrack`, reusa `StatusGlassPill`), posicionadas pela geometria que a página informa (mensagem `layout`: largura do documento e x/largura de cada coluna). A rolagem horizontal é um `NSScrollView` nativo em volta do web view (o gesto horizontal é repassado a ele; o vertical fica nas colunas da página); o relay move as cápsulas no mesmo quadro, como no quadro nativo. Arraste de card perto das bordas rola o `NSScrollView`.
- Medido contra o Quadro nativo (mesma janela, fixtures 169, 2x): filete do header no mesmo y (184 px), cápsulas no mesmo x, topo do card no mesmo pixel com o mesmo tom de filete (métrica `BoardColumnMetrics`: header + 34 pt; filete de 0,5 por dentro).
- Busca: `.searchable` e depois um campo inline foram descartados (alargavam a toolbar, jogavam "Minhas tarefas" no menu ">>" e não recolhiam, porque a página não toma o foco). A lupa abre um popover nativo com `NSSearchField`; fecha com clique fora, Esc (o primeiro limpa, o segundo fecha) ou Return; com filtro ativo a lupa fica na cor de destaque. A largura da toolbar não muda.
- Recuo: o grupo inicial do header ganhou 10 pt em todas as telas (`windowToolbar`, placement `.navigation`) e a primeira coluna do quadro React acompanha (`leadingMargin + 10`).
- Card = `BoardCard`: `Editorial.page`, filete de 0,5, raio 13,2, padding 12; linha de ponto + breadcrumb "WORKSPACE · LISTA" (ou tarefa-pai); chip só para URGENTE/ALTA; título semibold 11,05; rodapé com avatares + primeiro nome e data com seta (hoje na cor de destaque, atrasada em vermelho). Hover com sombra na cor do status; seleção com preenchimento de 7,5% e anel de 58%.
- Paleta de status do Apollo (`displayHex` + vibrância no escuro), no lugar das cores cruas do ClickUp (o item Q23 volta a ser uma decisão de design, não um requisito).
- Sem checkbox nem botões sobrepostos: seleção por ⌘/⇧-clique, menu pelo clique direito. Campos vazios aparecem no hover ("Mostrar campos vazios" deixa sempre visível; o padrão agora é desligado).
- Colunas sem ancoragem de rolagem (`overflow-anchor: none`): uma coluna abria rolada.

## Tela em branco ao entrar (Tarefas, Agenda, Quadro)

Causa: as três superfícies React escondem o web view (alpha 0) até a página confirmar que desenhou o snapshot da montagem. Em Tarefas a confirmação usava dois `requestAnimationFrame` cancelados a cada patch novo; numa rajada de patches (sync, mídia, reviews) ela nunca saía. Não havia reenvio nem esqueleto para essa espera, então a rota ficava vazia.

Correção:
- `WebRevealGate` (Views/Common): esconde na montagem, reenvia o snapshot completo se não houver confirmação em 0,9 s (até 2 vezes) e revela de qualquer jeito na terceira espera; informa o estado para o SwiftUI.
- Tarefas: a página confirma o último seq sem cancelar; `EditorialMyTasksView` mostra o `SyncLoadingSurface(.tasks)` por cima da lista enquanto ela não está pronta. Bundle `ApolloTasks/index.html` regerado.
- Quadro React: a cena de carregamento do quadro cobre a espera (`showsLoadingScene`).
- Agenda React: trava com reenvio e revelação garantida (não há cena de carregamento própria da Agenda).
- Atinge produção: Tarefas e Agenda em React são compiladas na versão pública.

## Cenas de carregamento — tolerância e Agenda

- Tolerância de 0,5 s em todas as telas: `SyncLoadingSurface` só aparece depois de meio segundo contínuo de espera (Tarefas, Quadro, Comentários, Inbox, Agenda). Trabalho mais rápido que isso nunca pisca uma cena.
- Agenda: cena nova `.agenda` (Swift `SyncLoadingSnapshot` + `web/apollo-loading/src/scenes/AgendaScene.tsx`) e esqueleto nativo `AgendaLoadingPlaceholder` na mesma geometria: console (lua, etapas Eventos / Agendas compartilhadas / Mês, contagem de eventos), cápsulas por dia na coluna de eventos, grade do mês (7×5) e painel do dia. Aparece sempre que a página não está desenhada (`WebRevealGate`) ou os eventos ainda não chegaram (Google conectado, online, nenhum evento e leitura da agenda ativa ou primeira sync da sessão pendente). Testes em `SyncLoadingSnapshotTests`. Captura: `docs/qa-loading-agenda.png`.
- Quadro: a cena e o esqueleto nativo usam o card atual (cantos de 13,2, filete interno de 0,5); no Quadro React o card tem a linha de indicadores (128 pt, `SyncLoadingLayout.boardReactCard`) e as colunas começam 10 pt adiante. Captura: `docs/qa-loading-board-react.png`. O Quadro nativo de produção também passou a usar o raio e o filete do card real.

## Cenas só com formas

Nenhuma cena de carregamento mostra texto, números ou progresso (título, contexto, etapas, contagem, tempo, lua, cápsula do Quadro, nomes de status): só esqueletos, cores de status nos pontos e o brilho em onda. As reservas de espaço desse bloco foram zeradas nos esqueletos nativos (Tarefas 93→0, Agenda 74→0, Comentários 112→0, Inbox 166,5→0, folga do Quadro 108→24), então tudo começa onde o conteúdo real começa. O snapshot do Swift continua calculando as etapas: move os estados visuais (pontos tingidos, luz a cada lote) e o rótulo de acessibilidade.

## Itens da auditoria cobertos

- Q01/Q02 capa: primeira imagem/vídeo anexado (regra padrão do ClickUp). Capa fixada manualmente não vem pela API pública — limitação registrada.
- Q04/Q05 descrição, anexos (só os do ClickUp, sem links da descrição nem arquivos técnicos) e checklist. Dependências ainda não.
- Q06 quatro prioridades + editar; Q07 etiquetas; Q08 responsáveis, vencimento, prioridade e etiquetas editáveis no próprio card.
- Q12 tarefa-pai; Q13 tamanhos P/M/G; Q14 campos visíveis e campos vazios; Q15/Q16 hierarquia e rodapé do card.
- Q17/Q18 criação na coluna (topo pelo "+" ou fim pelo "Adicionar Tarefa"), Enter salva e mantém aberto, herda o valor do grupo.
- Q19 menu "…" da coluna; Q20 checkbox e "Selecionar todas"; Q21 recolher grupo, todos e vazios.
- Q22–Q24 lane tingida, pílula na cor real do workspace, "+ Adicionar Tarefa" colorido.
- Q27 barra do quadro; Q28 agrupar por status, responsável, prioridade, etiqueta e vencimento; Q30 soltar altera o campo do grupo (responsável/etiqueta: troca só o da coluna de origem); Q31 ordenação e direção; Q36 busca local (⌘F).
- Q37 subtarefas como cards, dentro da tarefa-pai ou ocultas; Q38 "Nova subtarefa" no menu do card.
- Q39 opção de incluir fechadas (escopo próprio do quadro, sem mexer em `TaskSurfaceScope`); Q41 tarefas com a lista ativa em `locations` entram no quadro.

Não feito nesta etapa: views do ClickUp pela API (Q55–Q62), `include_timl` na consulta (Q41 completo), paginação acima de 10 páginas (Q45), custom fields (Q09–Q11), filtros avançados (Q32–Q35), raias (Q29), WIP (Q25/Q26), ações em lote adicionais (Q47–Q54).

## Verificação

- `npx tsc --noEmit`, `npm run build` e `script/build_dev_board_react.sh --build-only`: sem erros; isolamento DEV e `codesign --verify --deep --strict` OK.
- App com `--board-fixtures=60` e `=169`: capturas da janela conferidas.
- No navegador (fixture): prioridade, data, criação, arraste entre colunas, reordenação, agrupamentos, busca, personalização e menu da coluna exercitados por script.
- Bundle de produção no Chromium com 2.000 cards: abertura 814 → 160 ms depois da paginação por coluna (36 cards por passo); atualização de um card ~16 ms; rolagem p95 ~10 ms. Não medido no WKWebView nem com trackpad real.

## Pendências

- Uso real com conta conectada: capas vindas do ClickUp, taxa de requisições, criação/edição com round-trip, desfazer.
- Eventos sintéticos não chegam ao app (sem Acessibilidade): cliques, arraste, menus e popover nativos, busca da toolbar, foco de teclado do composer e soltar na sidebar não foram testados dentro do app.
- Modo escuro só pelo tema; não comparado em captura.
- Nada commitado.

## Placeholder do Quadro e Agenda — 24/09 16:30 (pendente de ingestão no Segundo Cérebro)

- Causa medida do placeholder do Quadro 47pt abaixo do real: `SyncLoadingController.push` chamava
  `window.apolloLoading.update` antes de o bundle carregar; a atualização se perdia e `lastPushed` já
  a marcava como entregue. A cena ficava para sempre com o `headerChromeHeight` provisório (140 → top 174)
  em vez do medido (93 → top 127). Diagnóstico: DOM `innerHeight` 714, insets do WebKit 0, coluna em 174.
- Correção: `push` só guarda até o `ready`; no `ready` o último snapshot é entregue e a cena só aparece
  depois disso (`deliver(_:then:)`). Vale para todas as cenas (Tarefas, Quadro, Comentários, Inbox, Agenda).
- Medido: primeiro card placeholder 127pt = real 127pt; colunas em x 237,5pt nas duas; 4 fileiras cabem.
- Header do Quadro durante o loading: `BoardHeaderSkeletonTrack` (pílula fantasma por coluna + `+`/`···`),
  mesmos insets da linha real (10 + 4 horizontal, 2 vertical): topo 60pt, base 81pt, x 242pt, igual à real.
- Agenda: `SharedCalendarSearchBar` (chips + botão flutuante) agora faz parte da camada da página, abaixo da
  cena de loading e oculta junto com ela (inclusive durante a tolerância de 0,5s). Verificado com loading forçado.
- DEV: rota da Agenda é `--route=today` (não `agenda`). Capturas: docs/qa-loading-board-react.png,
  docs/qa-board-react-real-169.png, docs/qa-loading-agenda.png.

## Entrada em cascata dos placeholders — 24/09 17:00 (pendente de ingestão)

- Causa medida: as animações CSS das cenas começavam no carregamento da página (~0,2s), escondidas atrás
  da tolerância de 0,5s; no Quadro/Agenda terminavam antes de aparecer e os itens surgiam de uma vez.
- Correção: a página mantém todas as animações pausadas no primeiro quadro até `data-play`, que o Swift
  (`SyncLoadingController.play()`) aplica quando a superfície aparece (tolerância + ready). O fallback nativo
  só monta ao fim da tolerância, para a cascata dele também rodar visível.
- Quadro: cards com a cascata de Tarefas (`cascade-in`) em onda diagonal, (coluna + 1,5 × linha) × 60ms;
  fallback nativo e pílulas do header com o mesmo ritmo. Agenda: cabeçalho dos dias e linhas do painel
  entraram na cascata; o fallback nativo ganhou a mesma cascata (cápsulas 40ms, mês diagonal 35ms).
- Medido em runtime: Quadro do 1º card (~0,41s) ao último (~0,86s); Agenda das cápsulas/células (~0,57s → ~0,89s).
