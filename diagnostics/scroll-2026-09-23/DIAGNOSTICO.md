# Apollo — diagnóstico de scroll, 23/09/2026

Escopo: investigar e propor; nenhuma correção foi aplicada ao aplicativo instalado. Checkout `t3code/diagnose-apollo-scroll-performance`, commit `63d54f7`. Aplicativo observado: Apollo 2.0.1 (99), macOS 27.0 (26A428). Testes com dados reais, lista Video, 169 tarefas, janela de dimensões constantes. A instância de produção foi reaberta ao terminar.

## Conclusão e limites

Há dois mecanismos concretos que devem ser corrigidos: composição cara do material do cabeçalho e processamento redundante de reviews na main thread. O primeiro teve contribuição de GPU isolada por A/B nas duas telas. O segundo foi observado no perfil mesmo sem interação e tem um erro de idempotência verificável no código. Ainda não há prova de que esses dois pontos expliquem todos os stutters, nem validação de uma correção completa com frame times. Não prometer FPS constante a partir destes dados.

## 1. Material do cabeçalho: contribuição de GPU confirmada

`EditorialBoardView.swift:171` e `EditorialMyTasksView.swift:223` usam `finderHeaderMaterial`. A implementação em `Views/Common/VisualEffectView.swift:109` incorpora `NSVisualEffectView(.fullScreenUI, .withinWindow)` ao background SwiftUI. O backdrop depende do conteúdo que se move sob o cabeçalho. `TintlessVisualEffectView` ainda modifica filtros privados e força `CABackdropLayer.scale = 1` (linha 324); log real registra a troca de 0.125 para 1.0. Essa alteração sozinha não explica toda a carga.

A ablação mais restrita acrescentou somente `v.isHidden = true` à superfície de efeito usada nesse caminho, preservando GeometryReader, preference, overlay, dimensões e controles. O código e a flag estão em `diagnostic-final.patch`; somente a cópia diagnóstica em `/private/tmp/apollo-diag` foi modificada.

| Tela | GPU total, efeito ativo | GPU total, somente efeito oculto | CPU WindowServer, ativo → oculto |
|---|---:|---:|---:|
| Quadro | 63,0% | 24,6% | 72,1% → 43,2% |
| Lista | 64,8% | 24,9% | 68,0% → 43,7% |

São médias de 18 leituras de utilização global da GPU (`ioreg`) e 17 intervalos válidos do `top`; a primeira leitura zero de CPU é excluída. GPU global não equivale à GPU exclusiva do Apollo. A redução repetida nas duas telas, com a superfície isolada, confirma uma contribuição importante desse efeito. Ensaios sequenciais não constituem benchmark de FPS ou controle perfeito de outros processos.

**A CPU do Apollo não caiu nesse A/B**: quadro 59,3% → 73,3%; lista 28,3% → 35,3%. Retirar o componente inteiro na repetição também não reduziu a CPU. Não usar esses testes para prometer redução de CPU.

## 2. Reviews: publicação e persistência redundantes na main thread

O perfil `noheader-idle.sample.txt`, capturado sem comandos de scroll, contém esta cadeia:

`ReviewWatcher.poll → MainActor → recordDiscoveredUpdate → applyProbeResult → persistPendingUpdates → JSONEncoder / NSUserDefaults.set`.

Evidência de código:

- `Services/ReviewWatcher.swift:154–193`: o watcher percorre o registro a cada ciclo de 120 segundos e entrega resultados ao store na main thread. Há também probes das linhas, com ciclo de 30 segundos.
- `Services/TaskReviewUpdateStore.swift:11,131`: store `@MainActor`, dicionário de updates `@Published`.
- `TaskReviewUpdateStore.swift:1190`: `isNewer` usa `>=` para `updatedAt`. Uma revisão com timestamp idêntico é aceita novamente como nova.
- `TaskReviewUpdateStore.swift:795–798`: resultado aceito reatribui o dicionário publicado e chama persistência; esta chamada acontece inclusive quando o ramo de atribuição não executa.
- `TaskReviewUpdateStore.swift:812–823`: cada persistência reúne, ordena e serializa **todas** as pendências, depois escreve UserDefaults, no MainActor. O log registrou 240 pendências restauradas.

No sample de quatro segundos em repouso, 224 amostras passam por `ReviewWatcher.poll`, 215 por `recordDiscoveredUpdate`, 180 por persistência, das quais 100 chegam a `NSUserDefaults.set`. São contagens aninhadas, não porcentagens aditivas nem número de chamadas. O caminho está na main thread. Isso explica trabalho de CPU concorrendo com layout e apresentação mesmo sem novos gestos. Sua contribuição exata para os hitches requer o A/B da correção.

O sample `board-noheader.sample.txt` também registra serialização de tarefas na fila `com.painellunar.cache`; essa parte ocorre fora da main thread. É um fator de confusão nos totais de CPU, não prova de bloqueio direto da UI.

## Hipóteses que não sustentaram uma causa dominante

Artefatos recuperados da tentativa interrompida estão em `recovered-interrupted-run/`. Os testes anteriores tinham driver de 120 ticks/s, dez segundos, deslocamentos comparáveis. Naquela série: CPU Apollo base 88,3%; sem captureFrame 81,5%; escala nativa 82,4%; sem filtro da sidebar 86,3%; sem material inteiro 28,9%. A queda de CPU da última variante **não se reproduziu** na série atual, que sofreu atividade de sincronização e tem outro modo de geração dos gestos. Não misturar as séries ou selecionar só o melhor resultado.

O quadro usa `captureFrame`, mas contagens observadas não sustentam reconstrução de todos os cards a cada pixel como causa dominante. A lista atual já utiliza `MyTasksAppKitList` com reutilização AppKit; recomendar simplesmente virtualização seria incorreto. Recriação de tracking areas foi observada, porém não isolada como principal gargalo.

## Correção estrutural proposta

1. Tornar aplicação de resultados de review idempotente: comparar identidade canônica, versão e conteúdo semanticamente relevante; revisão realmente igual deve ser no-op, sem publicação e sem escrita. Não trocar cegamente `>=` por `>`: mudanças válidas com timestamp igual e reconciliação de aliases precisam continuar funcionando.
2. Aplicar mudanças de um ciclo em lote, publicar somente tarefas alteradas e persistir uma vez por lote. Serializar um snapshot imutável fora do MainActor, mantendo ordem de gravação e preservando o latch de review até conclusão explícita. Não desativar o watcher como solução.
3. Retirar o backdrop customizado `.withinWindow` do cabeçalho compartilhado. Uma superfície estática na cor atual elimina o processamento de blur sobre o conteúdo móvel, mas altera a translucidez. Se a translucidez exata for requisito, prototipar material público em host AppKit fixo separado e medir: **a eficácia dessa alternativa ainda não foi demonstrada**. Não prometer que só mudar `scale`, `drawsAsynchronously` ou limitar FPS resolverá.
4. Validar em Release, após estabilização da sincronização, com ciclos de review incluídos no ensaio: repetição de revisões iguais produz zero publicações/escritas; mudança real mantém notificações e estado; rolagem vertical/horizontal, seleção, abertura e drag/drop preservados. Medir frame times/hitches no Instruments em ambos os modos, além de CPU/GPU. Só então considerar a solução completa.

## Proveniência e continuidade

`metrics.json`, arquivos `.top`, `.gpu.json`, `.sample.txt` e patches preservam os resultados. `measure.py` apenas lê métricas; os gestos desta etapa foram executados pela ferramenta de UI. A primeira amostragem de lista contém custo de leitura de acessibilidade; a segunda foi separada para reduzir essa interferência. LLDB não conseguiu anexar ao binário de produção, conforme `lldb-attach.txt`.

Consulta `buscar_memoria` do Segundo Cérebro retornou erro, e `resolver_projeto` / `registrar_report` não estavam expostos. Este documento é o handoff local **pendente de ingestão**, não uma alegação de gravação bem-sucedida no MCP.

Documentação primária consultada: [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) e [NSTrackingInVisibleRect](https://developer.apple.com/documentation/appkit/nstrackingareaoptions/nstrackinginvisiblerect). Servem de apoio às recomendações; as atribuições de custo acima vêm dos perfis e ablações locais.
