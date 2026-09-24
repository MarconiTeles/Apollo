# Plano de pareamento visual e funcional do Quadro

24/09/2026 · Apollo · Base verificada: `main`, `6a61361`.

Este plano transforma os [62 itens da auditoria](auditoria-quadro-clickup-2026-09-24.md) em entregas executáveis. Nenhuma implementação foi iniciada. As estimativas são julgamento de engenharia, não resultados de medição nem promessa de prazo.

## Resultado pretendido

O usuário abre no Apollo a vista correspondente do ClickUp, reconhece o mesmo quadro, encontra as mesmas tarefas e executa as operações cotidianas com comportamento equivalente. A meta visual é a captura enviada: cards, capas, campos, cores, colunas e controles internos. A estrutura externa do Apollo — janela, sidebar, Agenda e demais áreas — permanece fora desta mudança.

Três dimensões serão acompanhadas separadamente:

1. **Visual:** composição, geometria, conteúdo e estados dos controles próximos da referência.
2. **Funcional:** ações completas, incluindo teclado, arraste, erros, desfazer quando suportado e persistência.
3. **Dados:** mesma view, mesmos IDs, filtros, grupos, membros e valores no ClickUp e no Apollo.

Não usar um percentual único de paridade: os 62 itens têm tamanhos e riscos muito diferentes. Cada item terá estado `não iniciado`, `em implementação`, `validado localmente`, `validado com ClickUp` ou `limitado pela API`, acompanhado de evidência. Não declarar 1:1 absoluto enquanto houver diferenças materiais abertas.

## Escopo e decisões de arquitetura

- Manter o viewport AppKit virtualizado. O problema comprovado está nas capacidades do quadro, não na necessidade de outro motor de renderização.
- Manter SwiftUI para configuração, menus, popovers e estado da tela; AppKit recebe uma projeção imutável e devolve intenções. Não duplicar estado de tarefa/configuração no coordinator.
- Acrescentar áreas de interação independentes no card. Clicar no vencimento abre seu editor; clicar no título abre a tarefa; iniciar drag não dispara edição.
- Criar configuração específica do Board, identificada por workspace + escopo + view. Não modificar o comportamento compartilhado de `TaskSurfaceScope.openTasks` para todas as telas apenas para habilitar fechadas no quadro.
- Preservar os serviços de mutação existentes, seleção múltipla e fluxo de detalhe. Expandir ações comuns onde necessário, com regressão nas superfícies que as reutilizam.
- Aplicar cores e geometria novas no Board. Não alterar globalmente os tokens editoriais e as cores das outras telas.
- Usar API oficial para integrar views. Preferência local e configuração compartilhada precisam de proveniência distinta; uma não será apresentada como se estivesse sincronizada na outra.
- Preservar campos desconhecidos ao atualizar uma view; não serializar apenas o subconjunto conhecido sobre toda a configuração. Implementar proteção contra sobrescrever uma edição remota concorrente conforme as capacidades reais do endpoint.
- Migrar as preferências antigas de forma versionada, sem apagar a ordenação anterior. IDs de grupos devem carregar campo, valor e escopo; nomes de status isolados não bastam para múltiplas listas.

A documentação confirma endpoints para [ler a view](https://developer.clickup.com/reference/getview), [ler suas tarefas](https://developer.clickup.com/reference/getviewtasks) e [alterar sua configuração](https://developer.clickup.com/reference/updateview). Ela não prova suporte completo a toda preferência, à ordem manual individual dos cards, às capas fixadas ou às permissões do produto.

## Fases, dependências e esforço

Premissa: um engenheiro sênior dedicado, com assistência de IA, familiaridade com Swift/AppKit e acesso de desenvolvimento funcional. Dias são **dias úteis de engenharia**, incluindo testes focados e inspeção da build local. Não representam tempo de execução do agente. Estimativas incluem integrações previstas; reservar mais 25% para retrabalho, regressões e ajustes visuais. Esperas de acesso e recursos sem API comprovada não têm prazo garantido.

| Fase | Entrega | Dependência | Esforço base |
|---|---|---|---:|
| F0 | Contrato visual e prova de capacidades da API | Auditoria | 2–3 dias |
| F1 | Correções e base de dados/configuração do quadro | F0 | 3–5 dias |
| F2 | Pareamento visual dos cards e colunas | F0; contrato de F1 | 5–8 dias |
| F3 | Interações diárias diretamente no quadro | F1 + F2 | 4–6 dias |
| F4 | Agrupamentos, filtros e subtarefas completos | F1 + F3 | 8–12 dias |
| F5 | Campos e operações avançadas | F3 + contrato de F4 | 8–12 dias |
| F6 | Vistas, escopos e recursos condicionais | F4 + F5; provas de API | 10–18 dias |
| F7 | Convergência, regressão e preparação da entrega | Todas as capacidades habilitadas | 4–6 dias |

Total aritmético: **44–70 dias**, ou **55–88 dias com reserva**, aproximadamente **11–18 semanas** para uma pessoa. É uma faixa de planejamento para o escopo implementável confirmado; não um compromisso para recursos bloqueados pelo fornecedor. Reestimar ao concluir F0 e novamente após a primeira build utilizável.

### F0 — fixar o alvo e eliminar incertezas caras

Entregáveis:

- Identificar a lista e o `view_id` exatos da referência. Conferir menus de Customize, campos, filtros, ordenação, subtarefas, agrupamento e ClickApps realmente usados nessa view.
- Capturar a referência no mesmo viewport, escala e tema da comparação. Medir largura da coluna, gap, padding, raio, altura/recorte da capa, linhas de título, posição dos indicadores e dimensões dos alvos de clique. A imagem enviada é a referência inicial; não deduzir pontos macOS diretamente de seus pixels.
- Montar amostra representativa: sem/com capa; título curto/longo; sem/múltiplos responsáveis; vencida/hoje/sem data; quatro prioridades; etiquetas; subtarefa; fechada; vínculo em outra lista; anexos com arquivos técnicos do Apollo.
- Fazer prova de leitura da view e paginação, identidade dos grupos, campos e tarefas. Conferir a origem da capa e o que realmente chega no payload.
- Preparar prova de escrita em view/tarefas de teste dedicadas, na futura execução: configuração, ordem, responsável, datas, tags e tipos de campo prioritários. Testar atualização e releitura, sem usar a view de produção como experimento.
- Classificar capacidades em: leitura+escrita comprovadas; apenas leitura; comportamento exclusivamente local; não exposto pela API. Capas fixadas, ordem manual, WIP, templates, proteção e compartilhamento entram obrigatoriamente nessa matriz.

**Saída:** especificação visual, amostra de comparação e matriz de capacidades. Uma dependência sem API não paralisa cards/controles independentes; mantém apenas aquele item explicitamente pendente. Nenhum fallback que modifique a semântica aprovada será adotado silenciosamente.

### F1 — reparar controles e garantir o universo correto

Cobertura principal: **Q17, Q19, Q39, Q40, Q41, Q43, Q45, Q55**; inicia Q57.

- Ligar criação por coluna a uma intenção tipada contendo view, lista e grupo. O formulário deve receber o status correto, não escolher o primeiro status disponível.
- Implementar menu real da coluna com comandos funcionais. Selecionar/recolher será completado em F3.
- Introduzir `BoardViewConfiguration` e um adaptador de views no serviço ClickUp. Persistir identidade da view sem ainda exigir toda a interface de gestão.
- Separar tarefas fechadas, arquivadas, filtros e subtarefas; permitir o escopo correto do Board sem mudar Agenda/Tarefas.
- Resolver múltiplas listas com memberships corretas e identidade única da tarefa.
- Paginar até o fim comprovado. Se houver cancelamento, rate limit ou limite defensivo, marcar o resultado como incompleto; nunca publicá-lo como conjunto completo.
- Definir precedência da ordem remota/local e isolamento por view conforme F0. Se a ordem manual remota não tiver escrita suportada, não apresentar reordenação local como pareamento concluído.

**Aceite:** mesmos IDs e contagens na amostra, criação na coluna certa, configuração isolada e ausência de controles sem ação. Sucesso remoto seguido de leitura consistente; erro preserva o estado anterior.

### F2 — reproduzir a aparência da referência

Cobertura: **Q01–Q07, Q12–Q16, Q22–Q24, Q44**.

- Refazer a composição do card: capa opcional, título, indicadores e faixa compacta de campos. Tirar o breadcrumb obrigatório do papel de informação principal e torná-lo configurável.
- Mostrar todas as prioridades, etiquetas, indicadores relevantes e identificação do pai.
- Reproduzir cabeçalho, contador, fundo de coluna e ação Adicionar tarefa. Usar as cores corretas do workspace no Board.
- Introduzir variantes de tamanho e opções de composição em um único modelo de layout compartilhado por desenho, hit testing e cálculo de altura.
- Carregar miniaturas fora da thread principal, com cache limitado, cancelamento ao reutilizar o card e chave que impeça imagem de outra tarefa. Preservar posição de scroll ao atualizar metadata/altura.
- Separar anexo real, link na descrição e artefato técnico para que capa e contagem não mintam. “Ainda não carregado” não equivale a zero.

**Aceite:** build local com os casos da amostra comparados lado a lado. Tolerância proposta de até 2 pt para alinhamentos e espaçamentos medidos, sem cortes/overlaps; diferenças de rasterização tipográfica são avaliadas separadamente. Aprovação visual é por inspeção, não só por teste de pixels.

### F3 — tornar o quadro utilizável sem abrir cada tarefa

Cobertura: **Q08, Q18, Q20, Q21, Q27, Q36**.

- Editar responsáveis, vencimento, prioridade e etiquetas pelo próprio card, reutilizando as mutações e os pickers existentes quando atendam ao fluxo.
- Criação curta por coluna com Enter/Escape e criação sequencial. Herdar filtros somente quando houver valor determinístico; OR, exclusões e faixas ambíguas não devem inventar valores.
- Selecionar por checkbox e por coluna, mantendo Command/Shift; recolher colunas e vazias com persistência por view.
- Toolbar do quadro com busca local e acessos a agrupamento, ordenação e personalização conforme forem entregues. Ações ainda ausentes não aparecem como controles demonstrativos.
- Separar clique do card, clique do campo, seleção e drag. Dar nomes acessíveis, foco e navegação de teclado aos novos controles.

**Aceite:** executar criação, atribuição, agendamento, prioridade, etiquetagem, busca, seleção e movimentação sem abrir o detalhe; reler os valores no ClickUp e testar falha de rede.

**Marco A — primeira entrega utilizável:** F0–F3, 14–22 dias base; **18–28 dias com reserva, cerca de 4–6 semanas**. O objetivo é que o quadro por status da referência já se pareça e funcione como esperado no trabalho diário. Ainda não significa cobertura integral dos 62 itens.

### F4 — completar organização e projeção

Cobertura: **Q28–Q35, Q37, Q38**.

- Implementar motor de agrupamento por campo: status, responsável, prioridade, etiquetas, datas e campos suportados. Tratar múltiplos valores e grupos sem valor conforme comportamento observado no Board, não por suposição baseada na List view.
- Acrescentar ordenação explícita e estável, direção e desempate. Definir o comportamento de arraste com ordenação automática; não gravar silenciosamente uma ordem manual invisível.
- Arrastar para um grupo altera o campo correspondente. Em campos múltiplos, validar se a operação adiciona, remove ou substitui valores; não apagar outros responsáveis/etiquetas por engano.
- Expandir os filtros para uma expressão estruturada de operadores, AND/OR e grupos. Renderizar apenas condições suportadas; uma expressão remota desconhecida não pode ser descartada e ampliar silenciosamente o conjunto de tarefas.
- Acrescentar subtarefas expandidas/recolhidas/separadas e criação pelo card.
- Implementar raias como incremento do viewport: navegação por duas dimensões, cálculo de altura e drop em interseções. Esse é o trecho de maior risco de layout/performance; fazer primeiro uma raia e duas dimensões antes de generalizar.

**Aceite:** matrizes de agrupamento/filtro/subtarefas produzem os mesmos IDs/grupos do ClickUp; drop altera somente os campos esperados; seleção e contagens não duplicam tarefas indevidamente.

### F5 — completar campos e operações avançadas

Cobertura: **Q09–Q11, Q47–Q51, Q53**.

- Catálogo de campos e editores tipados. Ordem de implementação: dropdown existente; texto/número/data/checkbox; labels/pessoas; demais tipos realmente usados. Campos calculados e somente leitura preservam essa condição.
- Datas de início/vencimento livres em lote, movimentação entre listas, edição de campos e relações/dependências.
- Conversão de tarefas/subtarefas, mesclagem e duplicação com seleção de conteúdo, apenas onde F0 comprovar suporte oficial e semântica segura.
- Reutilizar uma execução em lote com resultado por tarefa. Tratar permissão negada, sucesso parcial e retry sem repetir operações já concluídas. Não anunciar sucesso total só porque parte do lote funcionou.

**Aceite:** editar e reler cada tipo de campo da amostra; validar lote parcialmente rejeitado e duplicação sem conteúdo perdido ou tarefas duplicadas por retry.

**Marco B — paridade operacional ampla:** F0–F5, 30–46 dias base; **38–58 dias com reserva, cerca de 8–12 semanas**. A promessa final desse marco depende da prova das operações avançadas, não só do desenvolvimento da UI.

### F6 — completar vistas e recursos condicionais

Cobertura: **Q25, Q26, Q42, Q52, Q54, Q56–Q62**.

- Vistas independentes, persistência remota, duplicação e restauração de configurações. Diferenciar personalização pessoal e alteração compartilhada.
- Escopos Folder/Space/Everything com permissões, status de listas diferentes e paginação corretos.
- Métricas/capacidade WIP e tipos, marcos, estimativas, seguidores e opções de notificação conforme suporte comprovado.
- Favoritos, templates, proteção, padrão e compartilhamento de views conforme a matriz da API.

**Aceite:** configuração não vaza entre views, alterações concorrentes não são sobrescritas silenciosamente, permissões são respeitadas e cada recurso habilitado tem leitura/escrita verificadas. Recursos indisponíveis ficam registrados como limitações do pareamento, sem UI fictícia ou substituto local não acordado.

### F7 — validar o conjunto e preparar entrega

Cobertura: **Q46**, regressão de todos os itens habilitados e pendências transversais da auditoria.

- Validar atualização em duas sessões, invalidação de cache e convergência após edição concorrente. Não prometer tempo real só porque existe atualização otimista local.
- Repetir amostra visual e tarefas operacionais na build integrada. Conferir light/dark, janela estreita/larga, tamanhos de card e conteúdo extenso.
- Medir scroll antes/depois em hardware, escala e fixtures iguais. Meta inicial: não regredir tempo de frame p95 em mais de 10%, não introduzir bloqueio >100 ms causado por imagem/layout e manter quantidade de views proporcional ao viewport. Ajustar orçamento absoluto após medir F0; não alegar FPS antes do benchmark.
- Testar 200, 1.000 e 3.000 tarefas em fixtures; não criar esse volume no workspace real. Verificar estabilidade de memória após ciclos repetidos de scroll e troca de views.
- Regressão focada em Tarefas, Agenda, detalhe, criação global, filtros compartilhados, seleção e rotas de mídia usadas pelo quadro.
- Preparar build candidata, evidências e notas de diferenças restantes. Build, inspeção, instalação e publicação são estados separados. Distribuição pública não faz parte deste pedido de planejamento.

## Pacotes de implementação e proteção contra regressões

Na execução futura, trabalhar em checkout isolado da base então vigente, com branch e build DEV próprias. Reutilizar o script [build_dev_board_appkit.sh](../script/build_dev_board_appkit.sh) com identidade e diretório específicos desta iniciativa, evitando colidir com outro DEV em uso. Verificar a dependência irmã `apollo-review-swift` no checkout escolhido.

Dividir as fases em mudanças revisáveis: intenção de criação; configuração/escopo; layout; capas; campos interativos; seleção/colunas; busca/ordenação; agrupamentos; filtros; subtarefas; lotes; views. Não juntar migração de dados, troca de motor de scroll e redesenho em um único patch.

Arquivos centrais existentes:

- [EditorialBoardView.swift](../Sources/DayPanel/Views/Home/EditorialBoardView.swift): estado da tela, seleção, composição e encaminhamento de ações.
- [BoardProjection.swift](../Sources/DayPanel/Views/Home/BoardAppKit/BoardProjection.swift): projeção pura, identidade dos grupos e ordenação.
- [BoardCardLayout.swift](../Sources/DayPanel/Views/Home/BoardAppKit/BoardCardLayout.swift) e [BoardCardView.swift](../Sources/DayPanel/Views/Home/BoardAppKit/BoardCardView.swift): geometria, desenho e interação.
- [BoardAppKitViewport.swift](../Sources/DayPanel/Views/Home/BoardAppKit/BoardAppKitViewport.swift): virtualização e integração, alterada incrementalmente para raias.
- [ClickUpService.swift](../Sources/DayPanel/Services/ClickUpService.swift): adaptador oficial; [CUTask.swift](../Sources/DayPanel/Models/CUTask.swift): metadados necessários.
- [TaskBulkActions.swift](../Sources/DayPanel/Views/Common/TaskBulkActions.swift): ampliação das ações compartilhadas com testes das outras superfícies.

Testes devem verificar contratos: IDs/grupos, filtros, criação contextual, reuso de imagem, persistência, erros e lotes parciais. Os testes atuais de paridade AppKit/SwiftUI usam o Apollo como referência; após o redesenho, manter seus contratos de interação/virtualização e acrescentar referências do alvo ClickUp, em vez de congelar o layout antigo como oráculo.

## Sequência inicial concreta

1. Capturar a configuração real e produzir matriz de capacidades, com ênfase em capa, ordem e view.
2. Abrir branch/build DEV isoladas; registrar baseline visual e de scroll.
3. Entregar correção do “+”/Adicionar tarefa e menu real da coluna.
4. Introduzir identidade/configuração do Board e validar mesmos IDs no cenário de referência.
5. Entregar uma coluna completa com cards reais, com/sem capa e edição de campos; então generalizar para o quadro inteiro.

Essa sequência mostra uma build utilizável cedo e evita investir em dezenas de controles antes de confirmar a origem dos dados. A meta integral continua registrada na matriz; os marcos são pontos verificáveis de entrega, não redução silenciosa do escopo.

## Continuidade

Plano local, sem alterações no produto. Proveniência: auditoria desta sessão, código `6a61361`, documentação oficial reconsultada e skill `build-macos-apps:appkit-interop`. A busca no Segundo Cérebro falhou novamente; resolução de projeto e registro de report não estão expostos nas ferramentas disponíveis. Ingestão canônica pendente; este arquivo é o handoff local. Chave proposta: `apollo-board-parity-plan-20260924-6a61361`; `truth_state`: session_report. Próximo passo: F0, seguido da implementação isolada quando solicitada.
