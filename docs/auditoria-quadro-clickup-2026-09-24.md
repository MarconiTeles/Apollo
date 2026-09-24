# Auditoria de paridade: Quadro do Apollo × Board do ClickUp

Data: 24/09/2026. Objetivo solicitado: aproximar a vista de quadros de 1:1.

## Base e limites da evidência

- Código: `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/t3`, branch `main`, commit `6a61361`. O checkout estava limpo no início. Outros worktrees de desenvolvimento não foram considerados funcionalidades entregues.
- Interface: `/Applications/Apollo.app`, versão **2.0.4 (104)**, janela **Quadro** inspecionada por screenshot e acessibilidade. A instalação e o código foram inspecionados separadamente; não foi feita comparação binária entre ambos.
- Referência visual: captura enviada pelo usuário, `39e6dfe8-f74f-4f68-8496-96dddbc526ab-89d95296-c67a-41a0-be8f-2d69fe5aa6b0.png`.
- Referência funcional: documentação oficial do ClickUp consultada nesta data, com links em cada bloco. A disponibilidade varia por plano, papel e ClickApps. Os menus da conta ClickUp do usuário não foram percorridos; a captura não mostra suas configurações completas.
- Foi uma auditoria, sem alteração do produto, criação de tarefas, movimentação de cards, publicação ou testes de escrita no ClickUp. Testes existentes foram lidos, não executados.
- O Apollo estava com **Minhas tarefas ativado**. Diferenças de contagem para a captura do ClickUp não demonstram perda de dados. É necessário igualar lista, filtros, subtarefas, tarefas fechadas e momento da sincronização antes de comparar totais.
- “Ausente no quadro” não significa necessariamente “ausente no Apollo”: o detalhe da tarefa já contém funções que o card não oferece.

## Diagnóstico central

O Apollo oferece um kanban de tarefas da lista ativa, com colunas fixadas nos status, cards de estrutura fixa e algumas preferências locais. Não representa uma vista salva do ClickUp: não lê seu identificador, sua configuração ou suas tarefas pelo endpoint de views. A diferença abrange conteúdo, interação, seleção de dados e persistência, além da aparência.

A base existente deve ser preservada: avatares múltiplos, datas relativas, mudança de status por arraste, reordenação local, seleção Command/Shift, ações em lote, menu contextual, filtro Minhas tarefas e filtros da sidebar. A virtualização AppKit já existe; reescrever o motor de scroll não é requisito demonstrado por esta auditoria.

Legenda: **Defeito** = controle existente sem cumprir a ação; **Ausente** = sem implementação na superfície auditada; **Parcial** = existe parte do comportamento; **Visual** = diferença para a referência enviada. P0 = corrigir funcionamento/fidelidade dos dados; P1 = paridade de uso diário e da captura; P2 = completar configuração e operações; P3 = administração e colaboração avançada.

## 1. Aparência e conteúdo dos cards

Base ClickUp: a captura enviada, [capas de anexos](https://help.clickup.com/hc/en-us/articles/6310349813015-Pin-a-Cover-Image), [edição de campos no Board](https://help.clickup.com/hc/en-us/articles/6303576489239-Set-Custom-Fields-on-tasks) e [tempo registrado nas views](https://help.clickup.com/hc/en-us/articles/15479699552151-Use-views-for-time-reporting).

| ID | Estado / prioridade | Defasagem no Apollo e resultado necessário |
|---|---|---|
| Q01 | Ausente · P1 | **Capas de imagem/miniaturas**. REVIEW perde a identificação visual dos materiais mostrada na captura. O renderer só desenha texto e avatares. |
| Q02 | Ausente · P1 | **Escolha e persistência da capa**. Não há representação de anexo fixado como capa; não basta escolher arbitrariamente a primeira URL. Confirmar a metadata disponibilizada pela API antes de prometer sincronização exata. |
| Q03 | Ausente · P2 | **Capa por descrição / sem capa**, como opções da vista. |
| Q04 | Ausente · P1 | **Indicadores de descrição e anexos, com contagem**. Os ícones e números presentes na referência não aparecem nos cards, apesar de haver dados no modelo. |
| Q05 | Ausente · P2 | **Indicadores de checklist e dependências**. O quadro não os desenha; o detalhe já tem modelos correspondentes. |
| Q06 | Parcial · P1 | **Prioridades visíveis**. Apenas urgente/alta geram chip. Normal, baixa e ausência de prioridade não têm a representação editável da referência. O menu contextual já permite alterar todos os níveis. |
| Q07 | Ausente · P1 | **Etiquetas no card**. São carregadas e filtráveis, mas não exibidas nem editáveis diretamente no card. |
| Q08 | Parcial · P1 | **Edição direta de responsável, vencimento e prioridade**. Avatar/data são desenhos; clicar abre a tarefa. Alterações existem no detalhe, menu contextual ou seleção em lote, com mais etapas. |
| Q09 | Ausente · P2 | **Campos personalizados no card** e seleção de quais mostrar. O modelo existe, mas não integra o layout. |
| Q10 | Parcial · P2 | **Edição tipada de Custom Fields**. Além da ausência no quadro, `CustomField.isEditable` restringe a edição existente a dropdown. Outros tipos precisam de editores e payloads próprios. |
| Q11 | Ausente · P2 | **Campos adicionais escolhidos pelo usuário**, como tipo de tarefa e tempo registrado. O card tem um conjunto fixo e não há catálogo de campos da vista. Não confundir o timer do detalhe com sua exibição no quadro. |
| Q12 | Ausente · P2 | **Nome da tarefa-pai e identificação visual da subtarefa**. O modelo mantém os IDs, mas o card não os apresenta. |
| Q13 | Ausente · P1 | **Tamanhos pequeno/médio/grande**. Colunas de 260 pt e cards de 240 pt são fixos. |
| Q14 | Ausente · P2 | **Organização de campos**: empilhamento, campos vazios e visibilidade de propriedades/localização. Não existe configuração por vista. |
| Q15 | Visual · P1 | **Hierarquia do card**. Apollo coloca breadcrumb em caixa alta e ponto de status antes do título; a captura privilegia título, indicadores e linha de ações. O título usa peso semibold e limite de três linhas. Reproduzir a hierarquia da referência exige rever o layout. |
| Q16 | Visual · P1 | **Rodapé e acabamento**. Apollo usa primeiro nome, data com seta, raio e espaçamentos próprios; a captura usa avatar e controles compactos de calendário/bandeira/etiqueta. Ajustar com comparação na mesma escala; não inferir medidas em pt pelos pixels de screenshots com escalas diferentes. |

Evidência Apollo: [layout e geometria](../Sources/DayPanel/Views/Home/BoardAppKit/BoardCardLayout.swift), [desenho e interação](../Sources/DayPanel/Views/Home/BoardAppKit/BoardCardView.swift), [modelo da tarefa](../Sources/DayPanel/Models/CUTask.swift).

## 2. Colunas, criação e toolbar

Base ClickUp: captura, [criação e ações do Board](https://help.clickup.com/hc/en-us/articles/6310080798615-Create-and-share-a-Board-view), [grupos recolhíveis](https://help.clickup.com/hc/en-us/articles/6310202447511-Use-grouping-in-views) e [limites de trabalho em andamento](https://help.clickup.com/hc/en-us/articles/6304619369623-Work-in-Progress-Limits).

| ID | Estado / prioridade | Defasagem no Apollo e resultado necessário |
|---|---|---|
| Q17 | **Defeito · P0** | **“+” da coluna e “Adicionar card” não abrem criação**. Ambos foram acionados na coluna A GRAVAR na versão instalada; a árvore da interface permaneceu idêntica. Ambos publicam `dp.editorial.board.createCard`, sem receptor encontrado no código Swift. O botão global de nova tarefa usa outro caminho, existente. |
| Q18 | Ausente · P1 | **Criação rápida no contexto da coluna**. Além de corrigir Q17, herdar status e critérios aplicáveis do grupo/filtro, oferecer entrada curta e criação sequencial. `CreateTaskSheet` começa pelo primeiro status e não recebe contexto da coluna. |
| Q19 | **Defeito · P0** | **Menu “…” das colunas é decorativo**. É um `Image`, explicitamente reservado para implementação futura; a acessibilidade também o identifica como imagem. |
| Q20 | Ausente · P1 | **Selecionar todos da coluna** e seleção por checkbox visível. A seleção Command/Shift existente não oferece os mesmos pontos de entrada. |
| Q21 | Ausente · P1 | **Recolher grupos e recolher colunas vazias**. Mesmo BACKLOG vazio ocupa uma coluna completa. |
| Q22 | Visual · P1 | **Fundo das colunas e cabeçalho**. Falta a área de cor suave por status mostrada na captura; cabeçalho usa cápsula de vidro com contador interno, em vez da composição da referência. |
| Q23 | Visual · P1 | **Cores originais**. `CUStatus.displayHex` substitui nomes conhecidos por uma paleta editorial, inclusive REVIEW. Preservar as cores do workspace exige remover/remodelar esse remapeamento na superfície pretendida. |
| Q24 | Visual · P1 | **Adicionar tarefa** tem apresentação diferente: área tracejada “¶ Adicionar card” versus ação textual colorida da captura. |
| Q25 | Ausente · P2 | **Limite WIP e capacidade por coluna**, incluindo indicadores de aproximação/excesso. Não existe configuração nem renderização. É recurso condicionado a plano/ClickApp; não um requisito provado na conta do usuário. |
| Q26 | Ausente · P2 | **Métrica do cabeçalho** além da quantidade: estimativas, pontos e campos numéricos usados pelo WIP. Hoje o valor é somente `cards.count`. |
| Q27 | Parcial · P1 | **Toolbar específica do quadro**. Filtros existem na sidebar, Me Mode existe como Minhas tarefas e criação global existe. Faltam entradas do quadro para agrupamento, ordenação, campos e personalização; a engrenagem atual é de ajustes do app. |

Evidência Apollo: [headers e notificações](../Sources/DayPanel/Views/Home/EditorialBoardView.swift), [botão nativo Adicionar card](../Sources/DayPanel/Views/Home/BoardAppKit/BoardColumnView.swift), [criação global](../Sources/DayPanel/Views/ContentView.swift), [formulário](../Sources/DayPanel/Views/Forms/CreateTaskSheet.swift), [paleta](../Sources/DayPanel/Models/CUHierarchy.swift).

## 3. Organização, filtros e busca

Base ClickUp: [subgrupos](https://help.clickup.com/hc/en-us/articles/8352728309271-Use-subgroups-in-Board-view), [agrupamentos do Board](https://help.clickup.com/hc/en-us/articles/40674788220311-Set-up-a-Kanban-board-for-task-tracking), [filtros específicos](https://help.clickup.com/hc/en-us/articles/6310208036503-Filter-tasks-in-Board-View), [busca e operadores](https://help.clickup.com/hc/en-us/articles/6308875427223-Use-filters-to-search-tasks) e [ordenação por responsáveis](https://help.clickup.com/hc/en-us/articles/6309029762583-Multiple-Assignees).

| ID | Estado / prioridade | Defasagem no Apollo e resultado necessário |
|---|---|---|
| Q28 | Ausente · P1 | **Agrupar por responsável, prioridade, etiquetas, vencimento, tipo ou Custom Field**. A projeção atual só cria buckets pelo texto do status. |
| Q29 | Ausente · P2 | **Subgrupos / raias horizontais** e inversão dos eixos. Falta a segunda dimensão de organização. |
| Q30 | Parcial · P2 | **Arraste conforme o agrupamento**. Hoje altera status; outros agrupamentos exigem alterar o campo correspondente, sem simplesmente mudar status. Arraste múltiplo já existe. |
| Q31 | Ausente · P1 | **Ordenação configurável**, direção e critérios. Há somente ordem manual local e ordem recebida como fallback; não há menu Sort no Board. A lista exata de critérios adicionais deve ser validada no Board do workspace, sem transplantar funções exclusivas da List view. |
| Q32 | Parcial · P2 | **Filtros**: existem prioridade, responsável, etiqueta, vencimento, criador, criação e encerramento. Faltam status na projeção do Board, início, atualização, duração, comentários atribuídos, recorrência, seguidores, dependências, arquivadas, estimativa, tempo registrado, Custom Fields, última mudança de status e relações personalizadas. |
| Q33 | Parcial · P2 | **Operadores de datas**: os filtros atuais usam poucos intervalos predefinidos. Faltam datas arbitrárias, antes/depois e faixas configuráveis. |
| Q34 | Parcial · P2 | **Semântica de etiquetas e responsáveis**: etiquetas só correspondem a qualquer item escolhido; faltam todas/nenhuma/não contém. Responsável não oferece critério para sem responsável; Teams não tem modelo equivalente na seleção atual. |
| Q35 | Ausente · P2 | **AND/OR escolhidos pelo usuário, exclusões e grupos aninhados**. Hoje há AND fixo entre dimensões e OR dentro de conjuntos. |
| Q36 | Ausente · P1 | **Busca dentro do quadro** preservando suas colunas e filtros. A lupa atual abre a command palette global; não filtra `BoardRenderSnapshot`. Faltam também os escopos título/descrição/Custom Fields da busca da vista. |

Evidência Apollo: [projeção](../Sources/DayPanel/Views/Home/BoardAppKit/BoardProjection.swift), [filtros e universo de tarefas](../Sources/DayPanel/Models/TaskFilters.swift), [toolbar e openSearch](../Sources/DayPanel/Views/ContentView.swift).

## 4. Subtarefas e fidelidade dos dados

Base ClickUp: [subtarefas em List e Board](https://help.clickup.com/hc/en-us/articles/6310382044567-Create-and-edit-subtasks-in-List-and-Board-view), [níveis da vista](https://help.clickup.com/hc/en-us/articles/6310314670359-List-view-vs-Board-view) e [personalização](https://help.clickup.com/hc/en-us/articles/35342044832279-Customize-Board-view).

| ID | Estado / prioridade | Defasagem no Apollo e resultado necessário |
|---|---|---|
| Q37 | Parcial · P2 | **Modos de subtarefas**. Só há mostrar como cards independentes ou ocultar. Faltam expansão/recolhimento sob a tarefa-pai e controles por tarefa. |
| Q38 | Ausente · P2 | **Criar subtarefa no card**. Hoje é necessário usar outra superfície; não há ação no card ou menu contextual do quadro. |
| Q39 | Ausente · P0 | **Incluir tarefas fechadas e subtarefas fechadas**. `TaskSurfaceScope.openTasks` remove `isCompleted` antes de qualquer filtro. Colunas de status fechado podem existir vazias. O filtro Data de encerramento não substitui uma opção para incluir fechadas. |
| Q40 | Ausente · P2 | **Incluir arquivadas reais**. O mesmo escopo remove `archived`; a consulta padrão não pede arquivadas. Uma coluna chamada ARQUIVADO não é prova de suporte ao atributo `archived`. |
| Q41 | Parcial · P0 | **Tasks/Subtasks in Multiple Lists**. O modelo guarda `locations`, mas o quadro compara apenas a lista de origem (`listId`); a consulta de lista não solicita `include_timl`. A tarefa pode pertencer à lista e ainda ficar fora do quadro. O caso exato deve ser validado com um exemplo real antes de declarar perda observada. |
| Q42 | Ausente · P2 | **Quadro de Folder/Space/Everything** como escopo explícito. A interface opera a lista ativa. O ramo que aceita `activeListId` vazio no filtro não implementa navegação, coleta e normalização de um workspace inteiro. |
| Q43 | Parcial · P0 | **Mesma ordenação do ClickUp**. `dp_board_cardOrder_v1` é local, indexado pelo nome do status; não é a ordem da view remota e não é enviado ao ClickUp. Faltam identidade e persistência por vista. |
| Q44 | Parcial · P2 | **Dados prontos antes de abrir o detalhe**. Metadados de anexos, checklist e campos podem depender de hidratação. A presença de structs não garante que todos os cards disponham desses dados. Distinguir desconhecido de vazio e evitar uma requisição por card a cada render. |
| Q45 | Limite confirmado · P2 | **Completude em listas grandes**. `syncList` limita-se a dez páginas de cem tarefas. Atingir o teto pode publicar um universo incompleto sem comprovar o fim da paginação. Não foi reproduzido com uma lista >1.000 nesta sessão. |
| Q46 | Parcial · P2 | **Atualização remota**. Apollo usa polling ativo de 30 segundos e sincronização periódica, sem integração de configuração da view. Não foi medido atraso comparativo no ClickUp. Paridade de colaboração e convergência precisa de teste em duas sessões. |

Evidência Apollo: [escopo](../Sources/DayPanel/Models/TaskFilters.swift), [serviço de lista e parser](../Sources/DayPanel/Services/ClickUpService.swift), [syncList e timers](../Sources/DayPanel/ViewModels/AppState.swift), [preferências do Board](../Sources/DayPanel/Views/Home/EditorialBoardView.swift).

## 5. Ações individuais e em lote

Base ClickUp: [operações da Bulk Action Toolbar](https://help.clickup.com/hc/en-us/articles/6309768265495-Manage-tasks-with-the-Bulk-Action-Toolbar).

| ID | Estado / prioridade | Defasagem no Apollo e resultado necessário |
|---|---|---|
| Q47 | Parcial · P2 | **Datas em lote**. Há hoje/amanhã/próxima semana/limpar vencimento. Falta início e escolha livre de data/hora no fluxo em lote. |
| Q48 | Ausente · P2 | **Custom Fields em lote**, com os limites de escopo e permissões pertinentes. |
| Q49 | Ausente · P2 | **Dependências e relações em lote**. Não constam da barra/menu do Apollo. |
| Q50 | Parcial · P2 | **Mover/adicionar/remover de listas pela barra**. Existe arraste para listas na sidebar e suporte a operações de lista no modelo/detalhe; faltam os comandos equivalentes na barra do quadro. |
| Q51 | Ausente · P2 | **Converter em subtarefas e mesclar tarefas** pelo fluxo de seleção do quadro. |
| Q52 | Ausente · P3 | **Marcos, tipos, estimativas e seguidores em lote**. Não estão no conjunto de ações atual. |
| Q53 | Parcial · P2 | **Duplicação configurável/completa**. A operação atual recria título, descrição, status, prioridade, datas, responsáveis e tags. Não oferece seleção de conteúdo nem clona automaticamente subtarefas, anexos, checklists e Custom Fields. |
| Q54 | Ausente · P3 | **Controle de envio de notificações** durante edição em lote. |

Não contar como faltantes: status, responsáveis, prioridades, etiquetas, copiar títulos/links, abrir no ClickUp, duplicar de forma básica, arquivar e excluir. Essas ações já existem, com diferenças entre o menu do card e a barra de seleção.

Evidência Apollo: [menu individual](../Sources/DayPanel/Views/Common/TaskContextMenu.swift), [ações em lote](../Sources/DayPanel/Views/Common/TaskBulkActions.swift), [movimentação pela sidebar](../Sources/DayPanel/Views/Home/EditorialSidebar.swift), [duplicateTask](../Sources/DayPanel/ViewModels/AppState.swift).

## 6. Identidade, persistência e gestão da vista

As opções de gestão abaixo são documentadas em [Customize Board view](https://help.clickup.com/hc/en-us/articles/35342044832279-Customize-Board-view). São funções da vista, diferentes de fixar uma lista na sidebar ou copiar o link de uma tarefa.

| ID | Estado / prioridade | Defasagem no Apollo e resultado necessário |
|---|---|---|
| Q55 | Ausente · P0 | **Carregar uma view ClickUp existente**. Não há objeto de configuração/ID de view nem uso dos endpoints de views no serviço auditado. Sem isso não se pode assumir que “mesma lista” produz “mesmo quadro”. |
| Q56 | Ausente · P2 | **Múltiplas vistas nomeadas**, com ícone e configurações independentes. Há uma rota Quadro. |
| Q57 | Parcial · P2 | **Salvar/autosalvar a configuração da view**. Ordem e toggle de subtarefas são preferências locais globais; filtros vivem no AppState compartilhado. Não há equivalente à vista salva e sincronizada. |
| Q58 | Ausente · P2 | **Duplicar vista, restaurar padrões e defaults**. |
| Q59 | Ausente · P3 | **Templates da vista**: criar/aplicar/atualizar. |
| Q60 | Ausente · P3 | **Fixar/favoritar/copiar link da view**. |
| Q61 | Ausente · P3 | **Vista privada, protegida e padrão do workspace**. |
| Q62 | Ausente · P3 | **Compartilhamento e permissões da view**, incluindo link público quando disponível. |

Há API pública para [listar views da lista](https://developer.clickup.com/reference/getlistviews), [ler uma view](https://developer.clickup.com/reference/getview), [buscar suas tarefas](https://developer.clickup.com/reference/getviewtasks) e [atualizar agrupamento, filtros, campos, ordem e configurações](https://developer.clickup.com/reference/updateview). Isso permite investigar uma integração verdadeira. Não prova que todos os controles do produto, capas fixadas, WIP ou permissões tenham round-trip completo pela API pública; cada um precisa de prova específica.

## 7. Itens a verificar, sem classificá-los como bugs confirmados

- Scroll horizontal/vertical, comportamento nos limites, autoscroll durante drag, drop ao fim da coluna e preservação de posição: requerem teste comparativo. A captura estática não define o comportamento do ClickUp e o Apollo já tem virtualização e testes de viewport.
- Ordem manual das colunas, ações exatas do menu de status e ícones de progresso: conferir a configuração real da conta antes de reproduzir detalhes não mostrados na captura.
- Métricas de FPS, latência, memória e carregamento de miniaturas: sem benchmark nesta sessão; não declarar o Apollo lento apenas pela diferença visual.
- Acessibilidade e teclado: o card AppKit expõe principalmente título/ação de botão; a futura edição de campos deve expor controles, foco e nomes próprios. A paridade completa de atalhos com o ClickUp ainda não foi testada.
- Fidelidade das contagens de anexos: Apollo mescla anexos reais, links extraídos da descrição e oculta arquivos técnicos de mídia. `attachments.count` não deve ser assumido igual à contagem do ClickUp.
- Campos condicionados a plano/ClickApp, tipos de tarefa, equipes, estimativas e WIP: validar disponibilidade e payloads. Não adicionar comportamentos da List view ao Board por suposição; por exemplo, a opção de um grupo por valor de campos múltiplos é documentada como exclusiva da List view.
- Reprodução exata das capas da captura: confirmar se são imagens anexadas, capas fixadas ou previews gerados; não inferir reprodução de vídeo pelo fato de a miniatura mostrar um frame.

## Ordem recomendada para chegar perto de 1:1

1. **Contrato de dados e correções**: Q17/Q19; definir se o quadro abre uma view real, tratar Q39/Q41/Q43/Q55 e estabelecer um conjunto de tarefas idêntico ao ClickUp. Não misturar defeitos de contagem com filtros diferentes.
2. **Paridade da captura**: capas, indicadores, etiquetas, quatro prioridades, campos editáveis, fundo/cor das colunas, criação por coluna e geometria configurável. Usar a mesma lista e os mesmos filtros na comparação visual.
3. **Paridade operacional**: agrupamentos, ordenação, busca local, seleção por coluna, subtarefas e filtros completos. Adicionar as ações em lote faltantes.
4. **Paridade da vista salva**: configurações independentes, sincronização, presets e gestão. Validar API de cada opção, sem substituir silenciosamente configuração remota por preferência local.
5. **Recursos condicionais**: WIP, tipos/estimativas, templates e compartilhamento conforme o workspace.

## Critérios de aceite propostos

- Mesmos IDs de tarefas, subtarefas e grupos sob o mesmo escopo; contagens consistentes após sincronização.
- “+” e ação no fim da coluna criam na coluna correta; filtros aplicáveis são herdados; falha não deixa card fantasma.
- Cards de REVIEW mostram a capa correta; metadados ausentes ainda não carregados não viram falsos zeros.
- Alterar responsável/data/prioridade/tag/campo no card faz round-trip e aparece no ClickUp.
- Arraste individual/múltiplo atualiza o campo correto, mantém ordem e desfaz com coerência; testar rejeição e sucesso parcial.
- Configuração da view sobrevive a relançamento sem contaminar outra view da mesma lista.
- Subtarefas preservam pais; fechadas, arquivadas e tarefas em múltiplas listas obedecem às opções escolhidas.
- Comparação visual lado a lado na mesma escala, incluindo coluna vazia, card sem data, prioridade baixa, múltiplos responsáveis e card com capa.
- Medir scroll com capas e listas grandes mantendo a virtualização; testar o teto de paginação antes de declarar completude.

Os testes `BoardAppKitParityTests` existentes comparam AppKit com o renderer SwiftUI do próprio Apollo. **O nome “parity” não comprova paridade com o ClickUp.** Este documento é o inventário para essa paridade; nenhuma correção listada foi implementada nesta sessão.

## Continuidade local — pendente de ingestão

Projeto: Apollo. Proveniência: esta sessão, código/commit e interface identificados acima; fontes oficiais linkadas. `truth_state`: session_report; cada achado indica seu nível de confirmação. Chave proposta: `apollo-board-clickup-audit-20260924-6a61361`.

O MCP Segundo Cérebro retornou `Error executing tool buscar_memoria` em duas consultas. `resolver_projeto` e `registrar_report` não estavam disponíveis entre as ferramentas expostas. Não foi gravada nem confirmada atualização canônica. Este arquivo preserva diagnóstico, evidências, pendências e próximo passo como handoff local pendente de ingestão.
