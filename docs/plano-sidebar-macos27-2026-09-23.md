# Plano: fundo do painel lateral no padrão macOS 27 (referência: Finder)

Data: 2026-09-23 · Branch: `t3code/83fd403d` · Estado: **plano, nada implementado**
Handoff local, pendente de ingestão no Segundo Cérebro (o MCP falhou nesta sessão).

## Escopo

**Muda só a estrutura do fundo (contêiner + material).** A organização dos itens fica
como está: marca "APOLLO", seções Edição/Listas/Filtros, linhas, contagens, seleção,
filtros embutidos, rodapé do usuário, arrastar e soltar. O conteúdo do `VStack` de
`EditorialSidebar` (`navList`, `userFooter`, a faixa de 74pt do topo) não é tocado.

## Diferenças de fundo: Apollo × Finder 27

| Aspecto | Apollo hoje | Finder macOS 27 |
| --- | --- | --- |
| Posição | Cartão afastado 10pt da borda (`.padding(.leading/.vertical, 10)`) | Coluna colada no topo, na base e à esquerda da janela |
| Cantos | Raio próprio de 12 (27) ou 16 (26) | Segue os cantos da janela; do lado do conteúdo, a divisa é reta |
| Sombra / borda | Sombra de 18pt + contorno branco de 0.5pt | Nenhuma |
| Material | `glassEffect(.regular)` ou `SidebarLuminanceGlass` com ganho RGB fixo de 0.31555 no modo escuro | Material de sidebar do sistema, que acompanha claro/escuro, a transparência e a janela ativa/inativa |
| Conteúdo por baixo | A tela principal é full-width e passa sob o painel (vários offsets fixos de 220pt) | O conteúdo começa depois da coluna |
| Botões da janela | Reposicionados à mão para o recuo de 30pt (`SidebarTrafficLights`) | Posição nativa |

## Arquitetura

### Opção A (recomendada): coluna de sidebar do sistema
`NavigationSplitView { EditorialSidebar(...) } detail: { chrome atual }`, com a
`EditorialSidebar` atual dentro da coluna **sem a camada de fundo própria**. Quem desenha
o fundo, as bordas, os cantos, os botões da janela e o recolhimento é o sistema. Essa é a
única forma de ficar idêntico ao Finder em todas as situações.

### Opção B (plano de contingência): manter o overlay com material nativo
Manter o `ZStack` atual e trocar só a superfície: altura total, sem inset, raio, sombra
nem borda, fundo `VisualEffectView(material: .sidebar, blendingMode: .behindWindow)`
(o wrapper já existe em `Views/Common/VisualEffectView.swift`). É mais barata, mas imita
o sistema; no macOS 27 o material `.sidebar` do AppKit pode não bater com o da coluna real.

A Fase 0 decide entre as duas com medição; a Opção B só entra se a A esbarrar na janela
personalizada.

## Fases

### Fase 0: medição (sem tocar em produção)
- No `ApolloPreviewCatalog` / Studio, montar as duas opções com a `EditorialSidebar` real,
  dentro da mesma `NSWindow` do `AppDelegate` (`.fullSizeContentView`, título oculto,
  `NSToolbar` vazio unificado, `backgroundColor = .clear`, `isOpaque = false`).
- Capturar lado a lado com o Finder no macOS 27: escuro/claro, janela ativa/inativa,
  Reduzir Transparência. Comparar a cor do material, a divisa, os cantos e a posição dos
  botões da janela.
- Confirmar que a faixa de 74pt do topo (marca APOLLO) continua alinhada com os botões
  na posição nativa. Se não estiver, ajusta-se **só a altura dessa faixa**, sem mexer nos
  botões.

### Fase 1: tirar a camada de fundo da `EditorialSidebar`
Em `Views/Home/EditorialSidebar.swift` (`body`, linhas 74–124):
- Remover `shape`, `sidebarCornerRadius`, `darkenSidebarMaterial`, o `.background` sólido,
  `.modifier(SidebarGlassSurface…)`, `.clipShape`, o `.overlay` de borda, `.shadow`,
  `.padding(.leading, 10)` e `.padding(.vertical, 10)`.
- `.frame(width: 220)` sai (a largura vem da coluna, via
  `.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)`), e a sidebar ocupa a
  altura total.
- Apagar o `struct SidebarGlassSurface` (l. 450–474).
- Atualizar as propriedades do nó Studio `shell.sidebar`: tirar Raio e Sombra; Material
  passa a ser "sistema".
- **Não mexer** em `SidebarSelectionSurface`, nas linhas, nas seções nem no rodapé.

### Fase 2: encaixar no host (`ContentView.swift`)
- Trocar o `ZStack` chrome | sidebar (l. ~192–368) por uma `NavigationSplitView` cuja
  coluna de detalhe é o chrome atual.
- Manter `EventDetailOverlay`, os `FloatingModal`s e o fundo de boas-vindas **fora** da
  split view, no `ZStack` externo, para continuarem cobrindo a janela inteira.
- Remover os offsets que existiam só porque o conteúdo passava sob o painel:
  - `ContentView.swift`: l. 241, 291, 311 (toolbar), 1573, 1579, 1616;
  - `EditorialBoardView.swift`: l. 113, 234 (230), 558;
  - `EditorialMyTasksView.swift`: l. 223–226;
  - `AssignedCommentsView.swift`: l. 119–122 (`finderHeaderMaterial(leadingExtension: 220)`
    + `.padding(.leading, -220)`).
- Esconder o botão automático de recolher a sidebar, que não existe na organização atual:
  `.toolbar(removing: .sidebarToggle)`. Recolher com ⌃⌘S fica como bônus do sistema.

### Fase 3: janela (`AppDelegate.swift`) e limpeza
- Apagar `Views/Common/SidebarTrafficLights.swift` e as chamadas em `AppDelegate`
  (l. 932, 1060–1078): os botões voltam para a posição do sistema, como no Finder.
- Reavaliar `w.backgroundColor = .clear` / `w.isOpaque = false` (l. 819–820): só existiam
  para o cartão de vidro receber vibração de trás da janela. Se a coluna do sistema não
  precisar deles, voltam ao padrão.
- `SidebarLuminanceGlass.swift` **fica**: ainda é usado pela seleção das linhas
  (`SidebarSelectionSurface`, l. 514), que está fora do escopo.

### Fase 4: verificação
- `./build.sh` sem avisos novos; rodar o `.app` real no macOS 27.
- Capturas lado a lado com o Finder: escuro/claro, janela ativa/inativa, Reduzir
  Transparência, janela no tamanho mínimo (`windowMinFrameSize`).
- Conferir que nada da organização mudou: marca APOLLO, seções, contagens, seleção
  (rota + lista), filtros embutidos sem vazar dos 220pt, rodapé, arrastar tarefa para uma
  lista + desfazer, bloqueio por `anyPopupOpen`.
- Conferir telas que dependiam do offset: Quadro, Tarefas, Inbox, Comentários e a toolbar
  ("+ Evento" colado na divisa, sem sobreposição).
- Ponto de atenção: a seleção de vidro das linhas (`SidebarLuminanceGlass` 0.65) sobre o
  material novo. Se destoar, reportar com captura; não alterar sem aprovação, porque está
  fora do escopo.

## Estado (23/09, fim da sessão): build DEV implementada
- App: `build/dev-sidebar27/Apollo DEV Sidebar 27.app` (bundle `com.painellunar.app.dev.sidebar27`,
  assinatura ad-hoc, porque o Developer ID falhou). Base 2.0.3, sem commit.
- Build: `APOLLO_OLLAMA_RUNTIME_SOURCE=/Applications/Apollo.app/Contents/Resources/ollama script/build_dev_sidebar_macos27.sh --run --board-fixtures=169 --route=tasks --appearance=dark`
  (o download do Ollama pelo GitHub foi bloqueado no ambiente).
- Opção A implementada: `NavigationSplitView` com largura fixa de 220pt (com um único valor
  para `navigationSplitViewColumnWidth`, a coluna ficou em ~144pt; precisou de min/ideal/max +
  `.frame(width:)`). Material medido: #2A2C31 no Apollo, #31333B no Finder.
- Pendentes: modo claro; rotas Inbox/Tarefas/Comentários; arraste da janela pela faixa
  superior da sidebar; `swift test`.

### Ajustes pedidos na revisão (23/09)
- Ícones de todas as linhas (navegação, listas e filtros embutidos) na cor de realce, não só no selecionado.
- Quadro: a rota `.board` ignora o safe area à esquerda e volta a desenhar sob a sidebar; as
  margens originais foram mantidas (`leadingMargin` 258 / `contentMargins` 258), então em
  repouso os cards começam depois do painel. O teste com margem de 40pt confirmou os cards
  visíveis sob o material do sistema.
- Marca "APOLLO" removida; a faixa superior caiu de 74 para 52pt.
- `SidebarRowMetrics`: ícones +10% (14→15.4; filtros 13→14.3), passo único de 31pt em todas as linhas.
- Toolbar: + Evento, + Tarefa, Hoje, Lista, Buscar, Notificações e Ajustes trocaram
  `TBButtonStyle`/`TBIconButtonStyle` por `.buttonStyle(.glass)` nativo (`controlSize(.large)`;
  ícones com `buttonBorderShape(.circle)`), em dois `GlassEffectContainer` (grupo à esquerda e
  à direita). O toggle "Minhas tarefas" ficou como estava.
- Toolbar (revisão 2): janela principal usa a toolbar NATIVA (`.toolbar` + `NSHostingController.sceneBridgingOptions = [.toolbars]`,
  ambiente `apolloUsesWindowToolbar`); popover da barra de menus, prévias e Studio mantêm a barra embutida.
  Itens só com ícone, alinhados à direita: [Novo evento, Nova tarefa] · [Lista ⌄] · [Buscar, Notificações (badge), Ajustes] ·
  "Minhas tarefas" (pílula própria com texto, `sharedBackgroundVisibility(.hidden)`). Botão "Hoje" removido.
  Anel de foco proibido: `focusable(false)` + `focusEffectDisabled()` em todos os itens. As origens dos modais
  vêm do clique (`MouseOriginCapture`).
- Toolbar (revisão 3): [Novo evento, Nova tarefa] à esquerda + título nativo da página (`navigationTitle`,
  `sceneBridgingOptions = [.toolbars, .title]`, `titleVisibility = .visible`); Lista, Buscar/Notificações/Ajustes e
  Minhas tarefas à direita. Grupos com vidro próprio (`ToolbarGlassGroup`: `.glassEffect(.regular.interactive())` +
  camada preta de 40% no escuro); a cápsula foi de #484A4F para #29292C (−43%).
- Diagnóstico (dump da hierarquia): a sidebar do sistema é `NSGlassEffectView` (style regular, raio 0); os fundos
  da toolbar nativa também (raio 18).
- `AppHeaderMaterial`: `.sidebar` withinWindow, blur × 0.4 (−60%) e véu preto de 30%. É usado em todos os
  headers de página (`finderHeaderMaterial`) e no fundo do seletor de listas (`CUListPickerSheet`).
  `TintlessVisualEffectView.stripsTint` permite escalar o blur sem remover a cor do material.
- Header: blur reduzido mais 60% (raio × 0.16). O véu preto de 30% vale só no modo escuro; no claro o
  header mediu #E6E7E9 contra #E9EAEC do painel. Revisão com UMA instância seguindo a aparência do sistema.
- `AppHeaderMaterial` (estado atual): ÚNICO material base `.sidebar` withinWindow, blur × 0.16.
  Escuro = véu preto de 30% (aprovado pelo Marconi; NÃO mexer). Claro = o mesmo material a 55% de opacidade,
  sem véu branco (header #EBEBED contra fundo #F5F5F7). A tentativa com `NSGlassEffectView` no header foi rejeitada e desfeita.
- Anéis de foco: `.focusEffectDisabled()` na raiz do ContentView, nas duas colunas do split, no command palette,
  no updater e no SubtaskRow; linhas da sidebar com `focusable(false)`; `FocusRingSuppressor` (swizzle de
  `NSView.focusRingType` → `.none`) instalado no launch.
- Header no claro (correção): o material `.sidebar` ativo tem backdrop (blur) + preenchimento + camada de blend.
  Escuro: preenchimento #282828 α0.80 + lighten #242424. Claro: preenchimento #F6F6F6 α0.84 + darken #E9E9E9
  (a darken prende o conteúdo branco em cinza → parecia 100% opaco). Claro agora: mesmo material com
  preenchimento × 0.7 e camada darken × 0.3 (`tintOpacity`/`blendOpacity` em `VisualEffectView`); header #EEEFF0
  contra fundo #F7F7F7. Escuro inalterado.
