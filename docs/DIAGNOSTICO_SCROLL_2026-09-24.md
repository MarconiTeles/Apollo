# Scroll de Tarefas — causa reproduzida e correção

Checkout: `/Users/marconi/.t3/worktrees/t3/t3code-0713810d`, branch `t3code/reduce-task-list-padding`, base `208e996`.
Validação isolada: `/Users/marconi/.t3/worktrees/t3/t3code-scroll-fix-20260924`, mesma base, contendo somente a correção de reviews e testes; mudanças paralelas de agenda não entram na candidata.

## Causa e diferença para o Quadro

A virtualização, o pool de células, o desenho agrupado e o bloqueio de hover da 2.0.2 (`731db18`) permanecem. O cabeçalho foi explicitamente excluído pelo usuário e não foi alterado.

A lista registra cada linha em `TaskReviewUpdateStore.watch` e assina `objectWillChange` global do store. Os cards AppKit do Quadro não fazem isso. Dois defeitos no serviço acrescentavam trabalho ao scroll:

1. `unwatch` apagava também a data da última consulta. Voltar a uma linha reciclada ignorava o intervalo de 45 segundos e sondava novamente.
2. `applyProbeResult` aceitava conteúdo idêntico porque `isNewer` aceita timestamps iguais. Publicava novamente, ordenava/codificava o catálogo inteiro e o gravava em UserDefaults no MainActor. Cada publicação ainda notificava todas as linhas assinantes.

A reprodução real funcionou depois de elevar a janela com AX Raise. Amostra `/tmp/apollo-tasks-live-scroll.sample.txt`, processo 48758, 12 segundos: 1.020 amostras inclusivas em `persistPendingUpdates` na thread principal, contra 77 em `MyTasksViewport.tile`; caminho `ReviewWatcher.poll → recordDiscoveredUpdate → applyProbeResult → persistPendingUpdates`. Há também custo da automação/AX nessa captura; estes números não são FPS nem um benchmark de apresentação.

## Correção

- Histórico de consultas de até 256 tarefas fora da tela. O retorno da mesma tarefa conserva o prazo; conteúdo alterado invalida a reutilização. O polling normal e `probeVisibleNow` continuam funcionando.
- Respostas idênticas deixam de publicar e persistir. Igualdade cobre conteúdo completo; metadata diferente no mesmo timestamp continua válida, e remoção de aliases continua durável.
- O guard contra resposta idêntica já estava em uma edição paralela do checkout quando esta investigação foi retomada. Foi preservado, validado em isolamento e complementado com a correção da reciclagem e testes do caminho real do watcher.
- Nenhum arquivo de interface, cabeçalho, layout, cor ou animação foi alterado na candidata.

## Prova antes/depois

`ReviewPollingScrollTests` foi executado contra código anterior e corrigido, em Release:

| Cenário | Antes | Depois |
| --- | --- | --- |
| 200 respostas idênticas, 40 reviews | 200 gravações + 200 publicações | 0 + 0 |
| CPU do mesmo lote no MainActor | 29,54 ms | 0,35 ms |
| 20 ciclos de reciclagem da mesma tarefa | 21 consultas | 1 consulta |

O teste também exige consulta imediata no retorno explícito e ao alterar a tarefa; mudança real com mesmo timestamp é persistida e recuperada após recriar o store.

Comando final: `swift test -c release -Xswiftc -DAPOLLO_DEV --filter 'ReviewPollingScrollTests|TaskReviewUpdateTests|MyTasksScrollTests|ScrollActivityDeadlineTests'`.
Resultado: 40 XCTest + 15 Swift Testing, zero falhas. Inclui versões/aliases/conclusão de review, viewport com 169/1.000/5.000 tarefas, identidade/colapso e preservação dos pixels das linhas. `git diff --check` passou.

Logs: `/tmp/apollo-scroll-poll-before.log`, `/tmp/apollo-scroll-recycle-before.log`, `/tmp/apollo-scroll-final-tests.log`, `/tmp/apollo-scroll-fix-build.log`.

A implementação corrige dois mecanismos reproduzidos; não equivale a afirmar 120 FPS contínuos ou aprovação perceptual do usuário. A passagem inicial sem reprodução, registrada antes, foi superada pelos testes e pela captura acima.

Segundo Cérebro indisponível: `buscar_memoria` falhou, `resolver_projeto` e `registrar_report` não estão expostos. Este documento é a continuidade local pendente de ingestão.

## Build e execução final

Build Release de produção e `codesign --verify --deep --strict` passaram. Candidata local aberta: `/Users/marconi/.t3/worktrees/t3/t3code-scroll-fix-20260924/build/Apollo Scroll Fix.app`, PID 84215, com 162 tarefas reais. A instância antiga foi encerrada normalmente; não houve publicação, instalação em /Applications ou alteração de tarefas remotas.

Seis gestos de scroll de ida e volta foram executados na candidata. A amostra de 12 segundos posterior não contém `persistPendingUpdates` (antes: 1.020 amostras inclusivas). Tiling: 77 antes/71 depois; binding das linhas: 24/23. É evidência complementar de remoção do trabalho observado, não promessa de FPS: os instantes de polling e a instrumentação não formam um ensaio controlado de frames apresentados. A aparência foi inspecionada na tela; nenhum fonte visual mudou.

Evidência preservada em `build/scroll-diagnostics-2026-09-24/`, incluindo traces, logs e `evidence.json` com hashes e resultados. A candidata não contém as edições paralelas da agenda.

## Continuação após rejeição de fluidez

O usuário informou que a candidata de reviews ainda estava longe do mínimo aceitável. As duas correções anteriores eram reais, mas insuficientes; não considerar essa candidata aceita.

A comparação direta com o Quadro encontrou o opt-out explícito `MyTasksScrollView.isCompatibleWithResponsiveScrolling = false`. A lista também ignorava o retângulo recebido em `prepareContent(in:)`. O Quadro herda o modo responsivo e popula a região solicitada em `BoardColumnView.tile(prepared:)`.

Correção adicional restrita a `MyTasksAppKitList.swift`: retirar o opt-out e encaminhar a região de preparação ao tiling, usando a união com o overscan visível como o Quadro. Mantidos o pool, identidade, controles, fontes, cores, geometria, animações e cabeçalho.

Teste `nativeScrollPreparesUpcomingContent`: antes falhou em compatibilidade e ausência das linhas futuras; depois passou, incluindo viewport imóvel, área limitada e ausência de rebind redundante. Suíte Release direcionada: 16 Swift Testing, zero falhas, incluindo igualdade de pixels claro/escuro e reciclagem de 5.000 tarefas. Build Release e assinatura deep/strict passaram.

Evidência de execução: amostra anterior em `/tmp/apollo-tasks-fixed-scroll.sample.txt` usava `NSScrollingBehaviorSingleThreadedVBL`. Na candidata nativa, `apollo-native-scroll-isolated.sample.txt` registra `NSScrollingBehaviorConcurrentVBL` com `MyTasksViewport.tile(prepared:...)` na pilha. Isso prova a troca efetiva de mecanismo, não uma taxa de frames apresentados nem aceitação perceptual.

Durante a validação, outra tarefa recompilou/abriu a instância principal e a automação de mesmo bundle id passou a alcançar a janela errada. As capturas iniciais da candidata sem atividade de scroll não são válidas. A candidata foi isolada e medida novamente. A build principal, recompilada às 01:58:52, já contém `tile(prepared:)`, não contém o opt-out e contém as duas correções de review, conforme inspeção de símbolos. Ao final foi mantida apenas a instância principal `build/Apollo.app` (PID 1736); as candidatas separadas foram encerradas. Alterações paralelas de agenda foram preservadas.

A tentativa de Animation Hitches retornou tabela vazia e não fundamenta nenhuma alegação de ganho. A amostragem e os testes não substituem o retorno do usuário sobre fluidez. Avaliação solicitada na conversa; aceitação ainda pendente. O usuário passou a navegar entre as páginas durante a conferência final, e a automação não deve disputar esse controle.

Referências oficiais: [compatibilidade com scroll responsivo](https://developer.apple.com/documentation/appkit/nsview/iscompatiblewithresponsivescrolling), [preparação da região futura](https://developer.apple.com/documentation/appkit/nsview/preparecontent(in:)).

## Continuação: melhora parcial, engasgos em saltos longos e primeira entrada

Retorno do usuário: a versão responsiva melhorou, mas ainda engasga; piora com movimentos descendentes longos e no começo da lista. Não considerar a versão anterior aceita.

Falha reproduzida na adaptação anterior: `prepareContent` montava linhas futuras, mas `layout()` voltava ao overscan menor e as reciclava. Vinte alternâncias sem mover a lista causaram 660 rebinds; teste vermelho em `/tmp/apollo-prepared-retention-before.log`. A captura real `/tmp/apollo-retention-before-live.sample.txt` também mostra trabalho de preparação, binding e layout durante gestos.

A tentativa de reaproveitar diretamente `NSView.preparedContentRect` foi REJEITADA pelos testes: em saltos programáticos, esse retângulo pode abranger a origem antiga e a nova e montar milhares de células. Não foi entregue nem aberta em uma build do aplicativo.

A implementação em validação guarda apenas a última região solicitada, conserva-a entre preparação/layout enquanto contém o viewport e a descarta ao saltar para fora. Limita a preparação antecipada a uma tela adicional em cada direção e informa esse limite ao AppKit por `super.prepareContent(in:)`. Isso impede que os pedidos crescentes de overdraw virem criação de todas as linhas numa única passagem. Não altera desenho, geometria, cabeçalho, controles ou dados.

Contrato oficial consultado: [prepareContent(in:)](https://developer.apple.com/documentation/appkit/nsview/preparecontent(in:)) permite devolver uma região limitada e interrompe o crescimento quando o mesmo limite é devolvido; [preparedContentRect](https://developer.apple.com/documentation/appkit/nsview/preparedcontentrect) descreve a área anunciada como pronta.

Validação final da preparação limitada: `swift test -c release -Xswiftc -DAPOLLO_DEV --filter 'MyTasksScrollTests|ScrollActivityDeadlineTests|ReviewPollingScrollTests'`, 16 testes/3 suítes aprovados. `TASKS_PREPARED_REBINDS=0`; saltos de 0 para 10.000, 25.000, 2.000 e 0 pontos com pedido de preparação do documento inteiro: `TASKS_LONG_JUMP_MAX_MOUNTED=68`. O teste exige que toda a região anunciada ao AppKit permaneça populada. Reciclagem com 5.000 tarefas: máximo de 47 subviews no percurso sem pedido extra de preparação. Comparação de pixels claro/escuro, seleção/colapso, controles e polling também passou. Log: `build/scroll-diagnostics-2026-09-24/apollo-bounded-preparation-tests.log`.

Os 660 rebinds do primeiro teste usavam pedido de três alturas de viewport. A suíte final valida a região limitada anunciada ao AppKit e também pedidos do documento inteiro; não interpretar a contagem como taxa de frames ou tempo de apresentação.

Build Release gerada no checkout principal, preservando as alterações paralelas de Agenda. Assinatura deep/strict verificada. A build validada está em `build/Apollo.app`, processo 16337; a anterior foi preservada em `build/Apollo Before Scroll Buffer.app`. SHA-256 do executável atual: `4cac91388a3d95a83cdbb862b86204de6cb1f277210da5ace12f5f02429e8ad9`.

Execução conferida: após a primeira entrada em Tarefas, seis gestos de três páginas alternando descida/subida, mais um salto descendente de três páginas. Screenshot via CUA mostrou linhas, botões, nomes, datas e avatares populados no destino (A GRAVAR/ARQUIVADO), com geometria preservada. A amostra `apollo-bounded-after-live.sample.txt` confirma o scroll responsivo e o novo caminho de preparação limitada em execução. Ela ainda mostra trabalho nativo de binding/layout dos controles ao entrar em linhas novas; não atribuir ganho de FPS a essa amostra. As capturas antes/depois usaram distâncias diferentes de gesto e não são um benchmark comparativo de latência.

Retorno perceptual sobre esta última build solicitado. Até ele chegar, a melhora parcial relatada pelo usuário continua sendo a última avaliação confirmada; não declarar a fluidez resolvida a 100%. Continuidade local pendente de ingestão no Segundo Cérebro, como acima.

## Continuação: engasgos residuais após preparação limitada

Usuário confirmou nova melhora, ainda com algum engasgo. A captura após saltos longos mostra custo em criação de células e layout nativo de seus controles. Foram identificadas atribuições redundantes de `media.title` e `media.attributedTitle` durante o rebind, mesmo quando duas tarefas exibem exatamente o mesmo ANEXAR.

Teste novo `recyclingKeepsUnchangedMediaButtonLayoutClean`: falhou antes porque reciclar a linha invalidava o layout do botão sem alterar o título/formatação; passou após comparar título e conteúdo atribuído antes dos setters. Alteração limitada a essas duas atribuições. Não usa cache de imagem, não muda desenho nem substitui controles. Mudanças reais de título/cor seguem sendo aplicadas.

17 testes/3 suítes Release aprovados; pixels e virtualização preservados. Percurso com 5.000 tarefas: 1.509,90 ms na execução anterior e 1.408,46 ms nesta execução. Com 1.000 tarefas houve pequena variação para cima (532,30 → 544,35 ms). São execuções individuais com outras compilações ativas: NÃO tratá-las como benchmark controlado nem como prova de ganho percentual/FPS. Evidência decisiva é a eliminação da invalidação desnecessária, não uma declaração de fluidez perfeita. Logs `apollo-button-before.log` e `apollo-button-after.log` preservados.

Build de produção desta etapa compilada e verificada com codesign deep/strict. Também conferida a ausência dos símbolos exclusivos da instrumentação DEV. `build/Apollo.app` atualizado e aberto; build anterior preservada em `build/Apollo Before Button Layout.app`. SHA-256 atual: `a50a4c96fca3dca8681f5f7772dfd7b24ad5240398a06be7aab6e8f69b56cef9`. Alterações paralelas de Agenda preservadas. O teste vermelho/verde demonstra a correção, mas o usuário ainda não avaliou a fluidez desta última build. Não declarar resolução total dos engasgos.

## Correção estrutural após rejeição das entregas parciais

Usuário rejeitou a fluidez das versões anteriores, exigiu resultado integral e questionou a decisão de fazer builds de produção. Em seguida instruiu expressamente a não fazer novas medições de engasgo, mas corrigir. Após essa instrução, nenhuma nova captura de desempenho foi iniciada. Mantida a verificação funcional/visual.

Mudança: retirada de `layoutSubtreeIfNeeded()` por célula do caminho síncrono de `tile()`. O AppKit passa a agrupar os layouts pendentes antes do desenho, como faz normalmente, em vez de forçar uma travessia por linha/evento. A transação sem animações passa a envolver a reciclagem inteira. Células que saem e são reaproveitadas na mesma passagem não são mais ocultadas/reexibidas; apenas as sobras no pool ficam ocultas ao final.

Validação Release/APOLLO_DEV isolada: 17 testes/3 suítes aprovados. Teste ampliado confere, após saltos em listas de 169/1.000/5.000 tarefas, o título correto da tarefa em cada posição, geometria final dos textos e área dos botões, além de identidade, colapso, seleção, preparação limitada e pixels claro/escuro. Não alterados o cabeçalho, o desenho das linhas nem as ações. A versão para execução desta etapa é DEV, com identidade `com.painellunar.app.dev.board-appkit` já usada no projeto e saída separada; não substitui a build principal.


## Continuação: avaliação 8,5/10 e descarte prematuro no pool

Usuário relatou melhora significativa, mas ainda insuficiente (8,5/10); não considerar fluidez aceita. Nova causa reproduzida: a capacidade do pool era aplicada antes de reutilizar as células que saíam da tela. Nos saltos longos com região preparada, células necessárias no destino eram removidas e reconstruídas na mesma passagem. Teste antes da correção falhou quatro vezes: 70 controles iniciais passaram a 74, 77, 81, 81. Log: `/tmp/apollo-reserve-before.log`.

Correção: reciclar toda a leva, consumir no destino e limitar apenas as sobras ao final. Reserva de linhas vazias preparada uma por vez durante ociosidade, com capacidade derivada da altura do viewport e contagem de tarefas. Não vincula tarefas nem inicia watches de review. Suspensa durante gesto/inércia pelo ScrollGate/ScrollStateObserver e cancelada ao desmontar a lista. O limite acompanha a região preparada, inclusive ao sair de grupos vazios para tarefas densas. Mantidos os controles, desenho e cabeçalho.

A build estrutural anterior foi aberta como `Apollo DEV Scroll`, identidade DEV isolada. Essa identidade não tinha conta ClickUp conectada; a verificação visual usou explicitamente `--board-fixtures=169 --route=tasks`. Não equivale a validação com dados reais. Nenhuma credencial foi copiada, nenhum novo perfil de desempenho foi capturado e a build principal não foi substituída nesta etapa. A suíte ampliada da reserva e nova build DEV estão em validação.


Validação da reserva concluída: 18 testes/3 suítes passaram (`/tmp/apollo-reserve-after.log`). Saltos longos não criaram controles adicionais após a reserva; teste adicional cobre 40 grupos vazios, ida para tarefas densas, retorno ao início e novo salto. Reserva sem vínculo com tarefa, linhas ocultas e descarte ao detach verificados. Pixels de linha claro/escuro e geometria passaram. Primeiro compile do novo teste falhou no macro `#expect` com keypath em `allSatisfy`; corrigido para closure explícita, sem mudança no app.

Enquanto a candidata seguinte compilava, usuário reprovou a janela DEV atual. Processo conferido: PID 45136, iniciado 02:35:55 com fixtures, anterior à correção da reserva. Reprovação registrada; não tratar a build estrutural anterior como aceita. Nova compilação DEV ainda pendente neste ponto. Proibição de novas medições de engasgo mantida.


## Reprovação da reserva e pista sobre o fim da inércia

DEV da reserva compilada, assinatura deep/strict válida, executável SHA-256 `3f562fb54931c0729fda9c5d65af5d64934c3e219b7a1347733ce88fc8d11d17`. Aberta após encerrar PID 45136. Inspeção funcional com fixture 169 mostrou início e destino completos, mas usuário reprovou a fluidez novamente: 7,5/10. Em seguida informou que o engasgo é praticamente certo no final da desaceleração/inércia; nos demais momentos é intermitente. Esta build NÃO foi aceita.

Revisão direta do Quadro: `BoardCardView` desenha conteúdo em uma camada com painter; a lista mantém textos e botões AppKit. A reserva de controles vazios não eliminava a reconstrução do conteúdo. Teste vermelho de 169 tarefas, com reserva pronta: sete saltos aumentaram os bindings de 32 para 419 (+387), `/tmp/apollo-retained-before.log`.

Nova correção em validação: listas com até 256 linhas retêm as linhas reais preenchidas/renderizadas por identidade, preparadas uma por vez em ociosidade. Listas maiores preservam a virtualização limitada pelo viewport. Atualizações de dados, seleção, largura e remoção/colapso continuam aplicadas às linhas retidas. Tradeoff explícito: até 256 linhas nativas residentes nas listas pequenas, em vez de reciclagem frequente de cerca de 47–68. Nenhuma troca do desenho/controle nem edição de cabeçalho.

Preparação de fundo agora exige também 350 ms sem mudança REAL da posição do clip, além dos gates de eventos. Isso evita considerar o viewport ocioso apenas porque chegou uma notificação de fim enquanto ainda há animação. Teste move o clip com gates inativos e confirma que a preparação é recusada antes do período quieto. Esta proteção é coerente com a pista do usuário, mas não é uma comprovação isolada da causa de todos os engasgos finais.

Primeira suíte desta etapa: retenção, ausência de rebind, proteção de cauda e pixels passaram; um teste encontrou largura antiga numa linha fora da tela após resize. Corrigido com controle da última largura efetivamente aplicada, independente do tamanho que NSScrollView atribui ao documento. Suíte completa novamente em execução. Nenhuma nova medição de FPS ou captura de engasgos.


Validação após ajuste de largura: 19 testes/3 suítes aprovados em `/tmp/apollo-retained-after.log`. A DEV foi atualizada a partir do executável local já compilado pelos testes para evitar nova compilação integral. A primeira montagem manual omitiu o rpath de Sparkle e falhou antes de abrir a aplicação (DYLD Library missing; relatórios `DayPanel-2026-09-24-030144.ips` e `030153.ips`). Aplicado o mesmo `install_name_tool -add_rpath @executable_path/../Frameworks` de `build.sh`, reassinado com os entitlements DEV existentes e verificado deep/strict. Aplicação abriu; hash desta intermediária `21b4cc3fbba25fc5ed5f34e1b09611b93e245d5903e76efb6a30ceb70dc40b3e`, PID 76804.

A checagem UI detectou árvore AX sem controles expostos na automação embora as linhas estivessem desenhadas. Teste local mostrou que reter a lista expandia os filhos AX de 247 para 1.305. Correção restrita à exposição da lista: `accessibilityChildren()` retorna os controles nativos não ignorados que intersectam o viewport; as linhas fora dele continuam retidas somente para renderização. Teste acrescentado exige filhos presentes e quantidade limitada. Nova suíte final em execução. A fluidez desta intermediária não foi declarada aceita; não há prova de 120 FPS.


## Estado da ultima candidata verificada

19 testes/3 suítes aprovados (`apollo-retained-final.log`), incluindo ausência de novos bindings após preparar a lista de 169 tarefas, bloqueio de preparação enquanto o clip ainda se move, atualização fora da tela, resize, colapso, limite em listas de 1.000/5.000 tarefas e pixels claro/escuro. `git diff --check` passou. Fontes de scroll/review e testes conferidos iguais entre checkout principal e checkout isolado.

DEV recompilada e aberta, com rpath Sparkle aplicado antes de assinar; codesign deep/strict passou. SHA-256 do executável: `bfb9a07ac17b6b06c356376067beaeb8d22003408be640c989dab67b60713d12`. Recibo em `build/scroll-diagnostics-2026-09-24/retained-dev-receipt.json`.

Verificação pela UI após reabertura: controles ANEXAR novamente presentes na árvore AX; salto de cinco páginas e retorno de oito páginas ao início executados, com tarefas, botões, textos e avatares completos nas capturas. Janela deixada aberta em Tarefas. A identidade DEV usa fixture de 169 tarefas, com 163 não concluídas; não está conectada à conta real. Aplicativo principal não substituído.

Ainda não houve aceitação do usuário desta última candidata. As versões anteriores permanecem reprovadas (última nota 7,5/10). Não houve nova medição de FPS/engasgos, conforme instrução. Não afirmar 120 FPS garantidos ou nota 10 com base nesses testes. Continuidade local pendente de ingestão: registrar_report/resolver_projeto continuam indisponíveis no MCP desta sessão.


## Meta continua e nova reprovacao — 24/09/2026

Usuario reprovou tambem a candidata de retencao (SHA bfb9a07...) por desempenho irregular e abaixo do ideal. Meta explicita criada nesta sessao: corrigir Tarefas/scroll visando 120 FPS consistentes; nao declarar sucesso por testes funcionais. Mantida a instrucao anterior de nao capturar novas medicoes de engasgos. Cabecalho/aparencia fora do escopo de alteracao.

Falha adicional reproduzida: MyTasksMediaButton.mouseEntered invocava onHover mesmo durante ScrollStateObserver ativo. A verificacao posterior em setMediaHover/setReviewHover bloqueava a cor de hover, mas ainda escrevia propriedades de CALayer e titulos. Teste antes da correcao: 100 pares de entrada/saida produziram 200 callbacks; /tmp/apollo-hover-before-isolated.log. A saida da linha tambem reescrevia fundo/camadas mesmo quando a entrada tinha sido suprimida.

Correcao em validacao: bloquear entradas antes do callback; ignorar saida sem estado ativo e atualizacao de elevacao ja identica. Estender o bloqueio dos controles nativos ao movimento real do clip da propria lista (mesma janela quieta de 350 ms), para nao depender somente das notificacoes de fim do gesto. Preservados controles, acao e desenho; feedback normal volta depois do repouso.

Removida reconciliacao redundante de linhas: lista pequena inteiramente preparada retorna antes de percorrer hierarquia/abrir transacao; lista virtualizada retorna quando faixa preparada, dados e geometria nao mudaram. Invalidacao em rebuild/detach, mudancas de largura e dados preservada. Testes cobrem saltos, atualizacao fora da tela, resize e colapso. Primeira suite passou 20 testes/3 suites em /tmp/apollo-scroll-noop-after.log; cobertura ampliada para cauda real do clip em execucao.

Um comando inicial de teste foi lancado por engano no checkout principal e interrompido imediatamente (exit 130); toda validacao concluida ocorre no checkout isolado. Sem build/instalacao principal. MCP buscar_memoria falhou novamente; resolver_projeto e registrar_report nao constam das ferramentas disponiveis. Continuidade local pendente de ingestao, sem gravacao afirmada no Segundo Cerebro.


### Candidata com bloqueio de hover na cauda — validacao concluida

Suite final: 20 testes/3 suites passaram (`build/scroll-diagnostics-2026-09-24/apollo-tail-hover-after.log`). O teste novo confere 0 callbacks durante scroll, inclusive com flags globais encerradas e clip em movimento, e retorno do hover normal apos repouso. Testes de reconciliacao verificam 0 passagens para lista inteiramente preparada e faixa virtualizada inalterada; updates/resize/colapso continuam aplicados. Comparacao de pixels claro/escuro passou. `git diff --check` e igualdade das fontes/testes entre checkouts passaram.

DEV atualizada e assinatura deep/strict validada. Executavel SHA-256 `aecbe1d6904b28a1c4ab554435ebeba2b2bb729ffc6f1ba702ca5fc7a382ea63`; recibo `build/scroll-diagnostics-2026-09-24/tail-hover-dev-receipt.json`. Executavel anterior preservado em `DayPanel-retained-rejected-bfb9a07` nesse diretorio. Usa 169 fixtures, nao conta real. Nenhuma modificacao no aplicativo principal.

UI real da DEV: salto de 6 paginas ate ARQUIVADO/BACKLOG mostrou textos, avatares, botoes e datas completos; retorno de 9 paginas chegou ao inicio (scroll bar 0). ANEXAR abriu seletor nativo "Escolha HOOKs, BODYs e videos completos" e Escape fechou sem selecionar/enviar arquivos. Janela deixada em Tarefas no inicio. Captura estatica/contadores NAO sao evidencia de 120 FPS. A meta continua ativa; esta candidata ainda sem avaliacao do usuario.


## Continuacao da meta — notificacoes de midia/review por tarefa

Turno anterior classificado como progresso: codigo alterado, teste causal vermelho/verde, candidata assinada e inspecionada. Sem nova avaliacao do usuario da candidata aecbe1d; nao considera-la aceita nem rejeitada por inferencia.

Custo adicional demonstrado: cada MyTasksNativeRowView assinava objectWillChange global dos stores e agendava duas etapas na main queue/run loop, mesmo se a mudanca fosse de outra tarefa. updateMediaButton sempre marcava needsLayout e reescrevia camadas. A retencao de ate 256 linhas aumentava o alcance desse broadcast. Teste vermelho: 100 descartes de um ID inexistente (publicacoes reais de batches, nenhum arquivo/remocao real) sujaram as 20 linhas montadas; log apollo-media-fanout-before.log.

Correcao exclusivamente em MyTasksAppKitList.swift: projetar batches para os campos visuais da tarefa e aplicar removeDuplicates antes do receive; reviews projetam somente a presenca de pendencia e o estado revisado da tarefa. A leitura no sink usa o estado corrente para evitar desenhar estados intermediarios enfileirados. Cancelamento/recriacao das assinaturas quando a identidade muda ou a linha e reciclada. Nenhuma mudanca de desenho, cabecalho, servico de envio, ack de review ou persistencia.

Validacao final: 69 testes passaram (22 Swift Testing/3 suites + 47 XCTest: 7 TaskMediaTransferStoreTests e 40 TaskReviewUpdateTests), log build/scroll-diagnostics-2026-09-24/apollo-capsule-scoped-after.log. Teste causal passou de 20 layouts alheios para 0; falha real de substituicao em fixture offline atualizou somente a linha afetada para REPETIR; reciclagem impediu resposta da tarefa anterior e restaurou ANEXAR. Projecao de todas as fases/progresso/composicao, pixels claro/escuro, geometria, saltos, colapso e acessibilidade passaram. Um compile inicial falhou por captura de self.phase antes de badgeCount ser inicializado no struct; trocado para $0.phase, compilacao final aprovada.

DEV atualizada, assinatura deep/strict valida; executavel SHA-256 4f8cde0f422c72888380e22778004cf8056fd67164a50f52d870795c695f11df. Recibo scoped-capsules-dev-receipt.json no mesmo diretorio; executavel anterior preservado em DayPanel-tail-hover-aecbe1d. Identidade isolada com 169 fixtures; aplicativo principal nao substituido. UI: salto de 5 paginas para 0.609375, captura com linhas/botoes/avatares completos, retorno de 8 paginas para scroll bar 0, deixada em Tarefas no inicio. Nao e comprovacao de 120 FPS nem aceitacao de fluidez. Meta continua ativa. Continuidade local pendente de ingestao no Segundo Cerebro.


## Auditoria de conclusao da meta — primeira lacuna de validacao

Turno anterior: progresso comprovado (fanout 20 -> 0, atualizacoes pertinentes preservadas, 69 testes, DEV atualizada). Neste turno a fonte e o binario foram revalidados contra scoped-capsules-dev-receipt.json: ambos iguais, processo DEV 65569 em execucao com --board-fixtures=169 --route=tasks. git diff --check passou. Comparacao textual confirmou MyTasksHeaderView identica a HEAD e EditorialMyTasksView sem diff. Consulta somente de hardware revelou um painel integrado Color LCD 3024x1964; nao forneceu taxa de apresentacao nem mediu engasgos.

Auditoria requisito/evidencia: mecanismos corrigidos possuem regressao vermelho/verde; controles/identidade/dados/resize/pixels cobertos pelos testes e inspecao UI anterior; preservacao do cabecalho confirmada por diff; conta real nao coberta (DEV em fixture); fluidez/120 FPS permanecem SEM evidencia suficiente. Nao ha neste turno um novo defeito causal confirmado que autorize inventar mais uma mudanca. Nenhuma nova medicao, alteracao de codigo ou substituicao de aplicativo.

Pergunta assincrona enviada para localizar o sintoma remanescente na candidata das 07:32 (fim da inercia versus outros momentos versus rolagem lisa); resposta pendente. A meta nao foi concluida. Primeira recorrencia de impasse de validacao apos o ultimo progresso: sem verificacao dinamica autorizada nem feedback da candidata atual, nao e possivel atestar a exigencia de 120 FPS ou atribuir novo defeito com seguranca. Manter ativa neste ponto; nao marcar blocked antes de tres turnos consecutivos com a mesma condicao e sem proximo passo util. Continuidade local pendente de ingestao no MCP.


Segunda recorrencia consecutiva do impasse de validacao: candidata e fonte revalidadas e identicas ao recibo scoped-capsules; DEV continua executando com fixtures. Turno anterior classificado como sem progresso na fluidez (auditoria confirma limites, nao resolve 120 FPS); aplicativo aberto nao e um job de validacao pendente. Sem resposta nova a pergunta assincrona, sem autorizacao para medir e sem outro defeito causal confirmado. Nenhum teste/build/edicao de codigo repetido. Meta mantida ativa, nao concluida; blocked ainda nao aplicado (2/3).


Terceira recorrencia consecutiva do mesmo impasse de validacao. Turno anterior sem progresso na fluidez; neste turno hashes de binario/fonte e processo DEV revalidados, sem mudanca. Nenhum feedback novo da candidata, nenhuma captura dinamica autorizada e nenhum novo mecanismo causal confirmado. As condicoes de bloqueio foram auditadas em tres turnos consecutivos; meta deve ser marcada blocked, nunca complete. Reabrir o diagnostico com o retorno sobre a candidata 4f8cde0 (pergunta assincrona ja enviada) ou com nova evidencia/autorizacao de verificacao dinamica. A comprovacao literal de 120 FPS ainda exige evidencia de apresentacao, que os 69 testes e screenshots nao fornecem. Codigo, candidata, backups e evidencias preservados; aplicativo principal intacto por esta tarefa. Continuidade local pendente de ingestao no Segundo Cerebro.


## Retorno do usuario: candidata 07:32 ainda pior — diagnostico retomado

Usuario respondeu a pergunta pendente: "esta ate pior". Candidata 4f8cde0 formalmente REPROVADA; nao reapresentar os 69 testes como aceitacao. O feedback trouxe informacao nova e o trabalho foi retomado; o contador de impasse anterior nao se aplica a esta retomada. A API de goals nao permite ao agente reativar um goal blocked; nao foi afirmado que seu status tecnico mudou nem que foi concluido.

Removida a estrategia introduzida de reter todas as linhas para listas <=256. Teste vermelho contra essa candidata confirmou: 32 bindings iniciais passavam a 170 em ociosidade, com 170 linhas montadas/subviews. Essa estrategia reduzia rebinds ao custo de ampliar hierarquia, tracking e watches; a piora percebida foi relatada pelo usuario, sem atribuir uma taxa de FPS ao contador. Log apollo-retention-removal-before.log.

Virtualizacao agora limitada pelo viewport para qualquer tamanho de lista. A reserva ociosa prepara apenas controles vazios e limitados; nao vincula tarefas fora da tela nem inicia seus watches. Primeira rodada passou 69 testes e confirmou mounted=32/subviews=70 apos reserva (apollo-retention-removal-after.log). Testes antigos que premiavam reter 170 linhas foram substituidos por limites de hierarquia e atualizacao correta ao retornar a uma tarefa.

A volta ao pool tambem exige evitar uma regressao da etapa anterior: assinaturas filtradas capturavam ID fixo e eram recriadas a cada bind. Ajustadas para manter a assinatura por linha/AppState, projetar a identidade corrente antes de agendar e descartar callbacks de identidades antigas. Comparacao com o estado visual agendado continua suprimindo broadcasts alheios. Teste novo exige uma assinatura de midia por controle ao longo dos saltos e confirma que a assinatura acompanha a tarefa nova. Suite final em execucao. Nenhum cabeçalho/desenho alterado; nenhuma medicao de engasgos iniciada.


Validacao final da retomada: 69 testes aprovados (22 Swift Testing + 47 XCTest), log apollo-bounded-stable-observers.log preservado em build/scroll-diagnostics-2026-09-24. 32 linhas vinculadas/70 subviews apos reserva, broadcasts alheios causam 0 layouts, assinatura de midia criada no maximo uma vez por controle ao longo dos saltos; troca de tarefa continua recebendo falha real da tarefa nova. Fontes/testes conferidos iguais nos dois checkouts e git diff --check passou.

DEV atualizada as 07:51 local, assinatura deep/strict valida, executavel SHA-256 a2444aea9c34ea1882f15602d3dc2d62ad62be1a654d30c07ba034c0dd815c8c. Recibo bounded-reuse-dev-receipt.json; binario reprovado anterior preservado em DayPanel-rejected-scoped-4f8cde0. Continua usando 169 fixtures, sem conta real. Aplicativo principal nao substituido.

Verificacao UI: Tarefas abriu com botoes ANEXAR acessiveis. O usuario comecou a rolar antes do salto automatizado; a protecao CUA recusou a acao por mudanca de estado. Nenhum novo gesto automatizado foi enviado depois disso. Leitura/screenshot atuais mostram linhas, avatares, datas e controles completos na secao A EDITAR. Janela deixada sob controle do usuario, sem forcar retorno ao inicio. Esta candidata ainda nao foi aceita e nao possui comprovacao de 120 FPS; testes nao substituem fluidez. Continuidade local pendente de ingestao no Segundo Cerebro.

### Rejeicao da candidata 07:51 e avaliacao de alternativa React

Usuario: "nao esta bom. estou pensando em reescrever a lista em outra linguagem como react". A candidata a2444aea esta REPROVADA. O objetivo de fluidez continua nao atingido; nao reapresentar testes ou limites de alocacao como sucesso de desempenho.

Avaliacao pontual, sem nova mudanca de implementacao: Apollo ja incorpora React em WKWebView no splash e no loading (LunarSplashController.swift e SyncLoadingController.swift). LunarSplashController.makeWebView registra canal WKScriptMessageHandler chamado apollo. Isso comprova infraestrutura de incorporacao web existente, nao desempenho de uma lista React. Documentacao oficial consultada: https://react.dev/learn/add-react-to-an-existing-project e https://developer.apple.com/documentation/webkit/wkscriptmessagehandler.

Escopo proposto para eventual alternativa: apenas superficie da lista em React/TypeScript, mantendo Swift como dono dos dados/acoes, cabecalho nativo intacto e contrato visual atual. Exige paridade de selecao, teclado, menus, arrastar arquivos, uploads e review; sem mensagens Swift/JS a cada tick de scroll. Nao houve autorizacao inequivoca para iniciar reescrita completa nem promessa de 120 FPS pela troca de tecnologia. Nenhum build, mudanca de UI ou nova medicao nesta avaliacao. Continuidade permanece local, pendente de ingestao no Segundo Cerebro indisponivel.
