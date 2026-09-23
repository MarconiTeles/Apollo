# Apollo — plano do quadro AppKit em build DEV

Data: 23/09/2026. Estado: **planejamento; implementação, build e medições novas não executadas**.

Pedido: substituir somente o conteúdo rolável do quadro por AppKit, com paridade visual e funcional 1:1 e desempenho substancialmente superior. Lista de tarefas, sidebar, toolbar, materiais, popups e serviços de negócio ficam fora da reimplementação.

## 1. Referência e limites

- Checkout inspecionado: `/Users/marconi/.t3/worktrees/t3/t3code-b7040236`, branch `t3code/diagnose-apollo-scroll-performance`, HEAD `63d54f7747cc8b70da88acf2554d97d9da788611`.
- Há alterações locais da tentativa anterior em AppDelegate, TaskReviewUpdateStore, VisualEffectView e testes. Preservá-las neste checkout; não misturá-las silenciosamente ao experimento nem revertê-las aqui.
- Referência visual **confirmada pelo usuário nesta conversa**: Apollo público 2.0.1 (99), anterior à tentativa rejeitada, incluindo a translucidez original do cabeçalho. O HEAD contém o estado de release; a proveniência do executável e dos recursos deve ser conferida na etapa inicial. A captura enviada na conversa mostra a lista, portanto não substitui referências do quadro.
- Abrir um checkout de implementação isolado, com base explicitamente registrada. Registrar também a revisão da dependência local `apollo-review-swift` e preservar sua resolução relativa. Não iniciar com uma cópia indiscriminada da árvore suja.
- Os dois lados do A/B usam a base pública confirmada, com hashes registrados. O objetivo é comparar renderizadores, não combinar a troca com o patch anterior de reviews ou de material. A build local rejeitada não é referência visual nem baseline principal.
- Não migrar linguagem, versão de Swift, sistema de observação global ou arquitetura de sincronização nesta tarefa.
- “Superior” será um critério de aceitação medido. A escolha de AppKit não comprova, por si só, que o objetivo foi alcançado.

## 2. Contrato de paridade antes da implementação

Capturar a versão de referência em claro e escuro, na mesma tela, escala, tamanho de janela, posição de scroll e conjunto de dados. Gerar imagens, pequenos vídeos das interações e uma tabela de geometria. Guardar referência imutável por commit/build.

### Geometria e desenho encontrados no código

| Elemento | Contrato inicial extraído do código |
| --- | --- |
| Colunas | 260 pt, distância horizontal de 20 pt; scroll vertical independente |
| Documento horizontal | Margem inicial de 258 pt e final de 28 pt; viewport passa sob a sidebar |
| Cards | Distância vertical de 12 pt; padding interno de 12 pt; padding horizontal do conteúdo da coluna de 10 pt |
| Topo e rodapé | Margem superior do conteúdo `headerChromeHeight + 20`; inferior de 24 pt; preservar também paddings internos e externos existentes |
| Título | Até três linhas, altura variável; mesma quebra, truncamento, baseline e peso; `Editorial.sans(13, .semibold)` aplica `typeScale = 0.85` |
| Superfície | Mesmos tokens dinâmicos, borda de 0,5 pt e curva contínua; raio atual `Editorial.popupRadius(8)` = 16,2 pt |
| Conteúdo | Status, breadcrumb, prioridade, responsáveis, fotos/iniciais, datas e símbolos com a mesma composição |
| Hover | Escala X 1,018 / Y 1,055, deslocamento Y -1; sombra semântica; mola response 0,30 / damping 0,73 |
| Seleção | Mesmo fill, borda, brilho semântico e mola do `TaskSelectionSurfaceModifier` |
| Arrasto | Card de origem com opacidade 0,35 e escala 0,98; mesmo preview e animação de rearranjo |
| Coluna de destino | Mesmo wash, contorno e transição de 0,12 s |
| Vazio/carregando | Mesmo “Adicionar card”, skeletons e transições; nenhuma nova mensagem ou ação |

Esses números não dispensam medição da hierarquia final. Padding de conteúdo, clip e coordenadas invertidas de AppKit não são intercambiáveis. Não somar margens por aproximação nem substituir alturas variáveis por constantes para ganhar FPS.

Comparação visual: diferenças de geometria, fontes, quebra de texto, cor, raio, sombras, alinhamento ou hit target reprovam. Diferenças de rasterização serão examinadas em sobreposição; nenhuma tolerância numérica ampla poderá esconder mudança perceptível. Para materiais dinâmicos, comparar o mesmo conteúdo de fundo e vídeos, pois dois screenshots isolados não demonstram equivalência.

### Contrato de interação

- Clique abre o detalhe com a mesma ordem de navegação e `style: .bottomSlide` efetivamente usado hoje; preservar o retângulo de origem sem se basear apenas nos comentários antigos sobre morph.
- Command alterna seleção; Shift usa o intervalo na ordem global de colunas e cards; preservar prioridade dos modificadores e âncora de seleção.
- Clique no fundo, Escape, mudança de tarefas visíveis e conclusão de drop limpam/reconciliam seleção conforme o comportamento atual.
- Seleção múltipla alimenta a mesma toolbar e ações; menus de contexto usam as funções existentes.
- Arrasto simples/múltiplo preserva o payload `MyTasksDragPayload` e a ordem de `TaskDragSelectionResolver`.
- Reordenação dentro da mesma coluna continua local, inclusive sua persistência e o comportamento observado quando um gesto é cancelado. Não inventar uma nova semântica de cancelamento.
- Mudança de coluna mantém `updateTaskStatuses`, atualização otimista, falhas parciais, rollback e undo. Drop em card, fundo de coluna, coluna vazia, gutter, cabeçalho e sidebar deve ter o mesmo destino/efeito que na referência.
- Preservar criação de tarefa por coluna via `editorialBoardCreateCard`, filtros, subtarefas, colunas fechadas e estados sem dados.
- Preservar teclado, acessibilidade, foco, tooltips, bloqueio por popup e hover suspenso durante scroll.
- Catalogar tipos de drop realmente aceitos pelo quadro. Não copiar funcionalidades exclusivas da lista, como upload por drop de arquivo em uma linha, sem evidência de que já existem no quadro.

## 3. Arquitetura proposta

```text
EditorialBoardView — shell atual, filtros, toolbar e popups
  ├─ Cabeçalho/status labels existentes + adaptador do offset X
  └─ BoardAppKitViewport — NSViewRepresentable
       └─ NSScrollView horizontal
            └─ BoardDocumentView — layout de colunas, pool limitado
                 └─ BoardColumnView — uma por coluna montada
                      └─ NSScrollView vertical
                           └─ NSCollectionView
                                └─ BoardCardItem / BoardCardView reutilizáveis
```

### Documento e scroll

- Usar rolagem/momentum nativos. Tratar corretamente trackpad, mouse, gesto diagonal, fase de momentum e roteamento horizontal pelo conteúdo das colunas; não sintetizar física própria nem enviar o evento duas vezes.
- Manter o documento horizontal com a dimensão integral das colunas, montando apenas colunas que intersectam o viewport mais uma margem pequena de antecipação. Fixar temporariamente a coluna envolvida em drag/foco para evitar destruição de estado durante a interação.
- Armazenar offset vertical por identidade de coluna/lista enquanto a referência o preservar; reciclar uma coluna não pode transferir seu scroll para outro status. Navegação entre listas deve reproduzir a política atual, não criar persistência nova.
- Cada coleção vertical reutiliza cards. Dimensões, offsets acumulados e atributos de layout ficam em cache; consultar itens visíveis deve depender da região visível, sem percorrer todas as tarefas a cada tick.
- Propor um layout vertical de coluna única, com alturas medidas e índices de offsets. Busca da faixa visível por índice/busca binária; recomputar alturas só quando conteúdo ou métricas relevantes mudarem.
- Investigar compatibilidade real de NSScrollView/NSClipView/documentView com responsive scrolling. Não retornar `true` indiscriminadamente sem satisfazer o contrato de desenho/preparação do AppKit.
- Preservar área de desenho sob cabeçalho/sidebar e espaço das sombras. Não virtualizar com base apenas no retângulo que sobra abaixo do cabeçalho: isso faz cards desaparecerem antes de atravessar o material.

### Cards AppKit

- Views reutilizáveis com texto AppKit e camadas Core Animation; nenhum `NSHostingView` por card no caminho normal de scroll.
- Medir texto com os mesmos atributos usados no desenho; cache com chave de conteúdo, largura, fonte/escala e ambiente relevante. Títulos longos, emoji, múltiplos responsáveis e datas são casos obrigatórios de paridade.
- Resolver cores no `effectiveAppearance` correto e atualizar em troca de tema; CGColor armazenado não se adapta automaticamente.
- Separar conteúdo, seleção, hover e drag: mudar seleção não deve refazer assinaturas, imagens ou layout textual.
- Evitar escritas redundantes em frames/layers; não disparar animações implícitas em bind/reuse. Manter animações intencionais com duração, trajetória e interrupção equivalentes às existentes.
- Usar cache de imagens existente inicialmente. Qualquer preparação adicional necessária será local ao quadro, com cancelamento e verificação de identidade/revisão antes de instalar a imagem numa célula reciclada. Não degradar fotos ou texto para melhorar métricas.
- Calcular o retângulo atual do card na hora de ativação, convertendo para o sistema de coordenadas esperado pelo detalhe. Testar após scroll nos dois eixos e resize. Não manter `@State` de posição por card.
- Tracking areas estáveis e descarte completo de estado transitório em reuse; preservar acessibilidade e os callbacks existentes.
- O preview de drag pode reutilizar a view SwiftUI atual renderizada uma vez por gesto, fora da atualização contínua das células, desde que materiais e resultado sejam equivalentes. Não substituir material dinâmico por bitmap opaco sem validar a aparência em movimento.

### Dados e ações

- Introduzir `BoardRenderSnapshot` com valores imutáveis: colunas/IDs, cards, apresentação, seleção, revisões e estado de loading. UI e mutações AppKit no MainActor.
- Filtrar, agrupar e ordenar uma vez por mudança das entradas relevantes; decodificar `cardOrderRaw` somente quando mudar. Evitar recalcular todas as colunas em cada callback de scroll.
- Reutilizar `TaskSurfaceScope`, filtros, resolvers de seleção/drag e APIs de AppState. Extrair as regras de ordenação/reorder para funções compartilhadas, com testes de equivalência antes da troca.
- Atualizações diferenciais por ID/revisão. Alteração visual de um card atualiza esse card; insert/delete/move atualizam as colunas afetadas e preservam a âncora visível. Seleção deve ser tratada à parte do snapshot completo de conteúdo.
- Não aplicar `reloadData()` completo por scroll, hover, seleção ou publicação não relacionada. Sincronização e mutações continuam funcionando durante rolagem.
- O primeiro desenho usa trabalho simples e medido; só mover preparação pesada para execução concorrente se o perfil justificar. Nesse caso, snapshots de valor e descarte de resultados obsoletos, sem views nem AppState atravessando atores.

### Cabeçalho e limite de escopo

- Preservar o desenho SwiftUI dos labels e o material escolhido como referência. Inicialmente conectar o offset X nativo ao relay isolado já existente.
- Se houver atraso ou custo relevante desse relay, adaptar somente a posição do host existente via AppKit, mantendo a mesma view SwiftUI para desenhar os labels. Não fazer a raiz inteira do quadro observar cada deslocamento.
- A equivalência do movimento entre cabeçalho e colunas é um gate: ausência de atraso de um frame, desalinhamento ou flicker.
- O material do cabeçalho/sidebar pode continuar limitando a composição. Se o perfil mostrar que o limite restante está fora do viewport substituído, registrar a evidência e o resultado insuficiente. Não esconder o efeito, trocar transparência, limitar FPS ou declarar a tarefa concluída.

## 4. Build DEV e comparação reversível

- Nome proposto: `Apollo DEV Board AppKit.app`; bundle ID próprio, por exemplo `com.painellunar.app.dev.board-appkit`; configuração otimizada Release com flag específica de DEV, independente de `DEBUG`.
- Caminho de saída próprio em `build/dev-board-appkit/`; não substituir `/Applications/Apollo.app` nem reaproveitar uma DEV anterior. Publicação e feed de produção não participam desta tarefa.
- Seletor de renderizador por argumento de lançamento/configuração DEV: `swiftui` ou `appkit`. Sem toggle novo na interface de produto. Mesmo binário, mesmos dados, mesma configuração fora do viewport; executar uma instância por vez nas medições.
- Manter o renderizador SwiftUI disponível durante o experimento. Voltar à referência não pode exigir desfazer dados ou reinstalar produção.
- Manifesto da build: branch/commit, patch se houver, revisão ReviewKit, SDK/macOS mínimo, otimização, identidade, renderizador, SHA-256 do executável e assinatura.
- Isolar preferências, caches graváveis, arquivos de ordem e namespace de credenciais da DEV. O código inspecionado usa o serviço fixo `com.painellunar.app.secrets` e caminhos fixos sob Apollo/DayPanel; mudar só CFBundleIdentifier não resolve. Acrescentar somente a configuração necessária para DEV, com o comportamento de produção inalterado e testado.
- Não copiar, migrar ou expor segredos da produção. Login da DEV usa o fluxo normal com identidade separada; autenticação pessoal, se exigida, é a única intervenção externa indispensável.
- Isolar identificação do helper Review e roteamento de URLs onde necessário. Atualizador DEV não pode baixar/substituir a versão pública.
- Fixtures/replay determinístico servem para comparação e testes de mutação. A build entregue continua sendo o app funcional; replay não substitui validação com dados reais, serviços ativos e operação normal.

## 5. Etapas e critérios de passagem

| Etapa | Entrega | Critério para avançar |
| --- | --- | --- |
| 0 — referência | Manifesto, imagens/vídeos e baseline novo de desempenho | Referência inequívoca e comparação reproduzível; não reutilizar as séries antigas como baseline quantitativo |
| 1 — DEV e regras | Identidade isolada, chave de renderizador, snapshot/regras comuns | SwiftUI continua visual e funcionalmente equivalente; DEV não grava no estado local da produção |
| 2 — card nativo | Card normal/selecionado/hover/drag + texto variável | Paridade visual de cada estado, antes de multiplicar células |
| 3 — viewport vertical e horizontal | Reuse, layout, clipping, labels e materiais reais | Sem sumiços, flashes, saltos, descompasso do header ou crescimento de views com o total de cards |
| 4 — comportamento completo | Seleção, menus, criação, drag/drop, undo e acessibilidade | Mesmas regras e efeitos, inclusive cancelamento/falha, sem alterações colaterais na lista |
| 5 — desempenho e entrega | Trace A/B, vídeos, resultados por máquina e DEV identificada | Cumprir metas abaixo; aprovação visual permanece separada da aprovação dos testes |

Na etapa 3 fazer uma primeira medição completa, com o chrome real. Se a arquitetura não demonstrar vantagem, investigar antes de terminar todo o port. Não investir na expansão de um protótipo que só fica rápido escondendo material, sombras ou funções.

## 6. Protocolo de desempenho

### Condições iguais

- Medir Release; baseline e AppKit no mesmo Mac, tela, escala/resolução, tamanho de janela e dataset. Registrar modo de energia, sistema, SDK e carga externa.
- Usar o conjunto real equivalente ao cenário de 169 tarefas da investigação anterior, mais fixtures com 1.000 e 5.000 cards distribuídos/desbalanceados entre colunas e com títulos variáveis. Não presumir que o conjunto real atual ainda tem exatamente 169.
- Separar primeiro scroll de cache aquecido; incluir imagens frias, sincronização, reviews, transferências e mudanças reais/reproduzidas de estado. Congelar dados apenas nas séries determinísticas, não durante a validação normal do app.
- Gestos vertical longo, horizontal longo, diagonal, inversão, momentum e bordas; testar também movimento com seleção e durante drag. Repetir em A/B/A/B, pelo menos cinco séries de 30 segundos por cenário principal; ensaio prolongado de 5 minutos para memória/temperatura.
- Registrar distância, duração e velocidade de entrada. Número de comandos de automação ou callbacks de display link não é FPS apresentado. Evitar inspeção contínua de acessibilidade e captura de tela pesada na mesma série quantitativa; vídeos de paridade em ensaios separados.
- Usar Instruments para relacionar hitches a trabalho de UI, layout, renderização e compositor. CPU/GPU médias são métricas complementares, não a prova principal de fluidez. Exportação de frame lifetimes não pode ser convertida cegamente em FPS: identificar a semântica e atribuição dos eventos.

### Metas propostas de aceitação

Metas de engenharia para este experimento, não resultados já obtidos nem garantias universais:

| Dimensão | Critério |
| --- | --- |
| ProMotion durante movimento contínuo | Alvo de 120 FPS; média de pelo menos 118 FPS nos segmentos de demanda a 120 Hz, com no mínimo 90 FPS em cada janela móvel de 1 s desses segmentos |
| Regularidade | Registrar p50/p95/p99 dos intervalos apresentados e prazos perdidos; média alta não compensa travadas |
| Hitches | Hitch-time ratio de no máximo 5 ms/s no protocolo; nenhum hitch atribuível ao app acima de 50 ms |
| Superioridade sobre a referência | Reduzir o hitch-time ratio em pelo menos 50% nos cenários em que a referência falha; não regredir p95/p99 nem os cenários já fluidos. Se a referência já estiver no piso de medição, tratar como empate nessa métrica |
| Tela de 60 Hz | Sustentar a cadência disponível; não impor o critério fisicamente impossível de 90 quadros visíveis |
| CPU/GPU e latência | Não introduzir regressão material de uso ou resposta; separar ruído de sistema com repetições e intervalos, além de reportar valores absolutos |
| Memória e escalabilidade | Views vivas limitadas pelo viewport/prefetch, descarte sob pressão e ausência de crescimento contínuo em scroll de ida/volta; reportar custo de caches e pico de memória |
| Visual e funções | Paridade 1:1; nenhuma função, efeito, detalhe ou animação removida para atingir as metas |

O orçamento a 120 Hz é cerca de 8,33 ms por apresentação. CPU e GPU têm estágios sobrepostos: medir cumprimento do prazo, não somar durações de estágios ingenuamente. ProMotion é adaptativo; medir segmentos de movimento e a cadência efetivamente disponível. Não forçar 120 em repouso.

Validar no Mac ProMotion do usuário e em aparelhos representativos do piso suportado, incluindo Apple silicon de menor desempenho e Intel se o artefato universal atual continuar suportando essa arquitetura. Cobrir macOS 26 e 27. Um único Mac não comprova desempenho excepcional em todo o parque; registrar exatamente a matriz executada e o que faltar.

## 7. Testes necessários

- Modelos: mesmo scope, ordem, filtros, subtarefas, statuses fechados, payload, seleção/âncora e regras de reorder antes/depois; atualização obsoleta nunca sobrescreve a nova.
- Layout: títulos de 1/2/3 linhas, truncamento, emoji, escala da tela, resize, offsets independentes, âncora após insert/delete/move e retorno de coluna reciclada.
- Reuse: sem avatar/hover/seleção de outro card, assinaturas sem multiplicação, cancelamento correto e ausência de referências retidas.
- Integração: menus, toolbar, detalhe/origem, criação, drag múltiplo, coluna vazia, sidebar, cancelamento, undo, falha parcial de API e persistência após relaunch. Mutação automatizada usa fixtures/conta de teste, sem modificar tarefas reais incidentalmente.
- Visual: snapshots comparáveis e vídeos dos estados/transições; comparação humana final de aparência continua necessária.
- Instrumentação DEV: contadores de criação/reuse, binds, recalculo de alturas, publicações e reaplicações de snapshots; signposts de intervalos, sem log por tick no ensaio final.
- Regressão estreita: lista de tarefas e demais superfícies iguais à base; testes existentes relevantes, build Release e assinatura verificados.

## 8. Arquivos previstos

Nomes propostos para a implementação, ainda não criados:

- `Views/Home/BoardAppKit/BoardAppKitViewport.swift`: bridge e ciclo de vida.
- `Views/Home/BoardAppKit/BoardDocumentView.swift`: documento horizontal e montagem de colunas.
- `Views/Home/BoardAppKit/BoardColumnView.swift`: scroll vertical e coleção.
- `Views/Home/BoardAppKit/BoardColumnLayout.swift`: alturas/atributos e consultas por região.
- `Views/Home/BoardAppKit/BoardCardView.swift`: desenho, reuse e acessibilidade.
- `Views/Home/BoardAppKit/BoardInteractionCoordinator.swift`: eventos para as ações existentes.
- `Views/Home/BoardAppKit/BoardRenderSnapshot.swift`: projeção de dados e revisões.
- `EditorialBoardView.swift`: ponto de troca de renderizador, snapshot e bridge dos labels; shell preservado.
- Script/configuração de empacotamento DEV e testes do quadro, com mudanças mínimas nos pontos de configuração de identidade/armazenamento.

Não assumir que os nomes exigem abstrações extras. Consolidar componentes pequenos quando isso reduzir complexidade sem misturar desenho, estado e regras de negócio.

## 9. Evidência e continuidade

Fontes locais inspecionadas: `EditorialBoardView.swift`, `MyTasksAppKitList.swift`, `TaskBulkActions.swift`, `EditorialTheme.swift`, `KeychainHelper.swift`, `build.sh`, `script/build_and_run.sh`, `docs/dev-01/verificacao-build.json` e os diagnósticos anteriores.

Documentação de apoio:
- Apple, NSCollectionView: https://developer.apple.com/documentation/appkit/nscollectionview
- Apple, responsive scrolling: https://developer.apple.com/documentation/appkit/nsview/iscompatiblewithresponsivescrolling
- Apple, SwiftUI/Instruments: https://developer.apple.com/videos/play/wwdc2025/306/
- Apple, hitches de renderização: https://developer.apple.com/videos/play/tech-talks/10857/

Segundo Cérebro: `buscar_memoria` retornou erro; `resolver_projeto` e `registrar_report` não estão disponíveis nesta sessão. Este plano serve também como handoff local **pendente de ingestão**; nenhuma gravação bem-sucedida no MCP foi alegada. Não há build DEV nova ou ganho de desempenho comprovado nesta etapa.
