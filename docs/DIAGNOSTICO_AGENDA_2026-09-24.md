# Agenda: desempenho — 24/09/2026

## Estado atual: correção construída, testada e aberta

O usuário confirmou engasgos graves nas DUAS listas, inclusive nos eventos do
dia abaixo do calendário, e informou que começaram com a inclusão desse painel.
A thread de Tarefas está trabalhando separadamente; seus arquivos foram preservados.

Comparação controlada em Release, tela com duas colunas e cabeçalho, 1.000 eventos
concentrados no mesmo dia, calendário desligado/ligado:

| Trabalho CPU | Sem painel | Com painel antigo |
| --- | ---: | ---: |
| Rolagem da lista esquerda, passos de 80pt | 3,98 ms | 16,57 ms |
| Atualização de estado | 4,37 ms | 72,34 ms |
| Redimensionamento de 1pt | 8,05 ms | 92,27 ms |

Causa reproduzida: `AgendaDayPanel` montava todos os eventos num `VStack`, inclusive
fora do viewport, ampliando o trabalho da tela inteira. Com eventos distribuídos,
o efeito é menor. A correção usa `LazyVStack` no painel do dia e mantém a projeção
mensal em cache por mês, calendário e eventos completos. Grade, estilos e ações
não foram alterados. Evidência: `/tmp/apollo-month-diagnostics-before.log`.

A lista esquerda também usa NSTableView com alturas explícitas e hosts SwiftUI
reciclados. As comparações anteriores de pixels e âncoras passaram; isso não
substitui prova de FPS. Não há comprovação de 120 FPS sustentados nem aceite do
usuário. A ferramenta de UI falhou com `noWindowsAvailable` ao enviar rolagem,
mesmo na build isolada; capturas sem gesto válido não contam como teste de fluidez.

### Validação final

- `AgendaDayCell` agora publica somente a quantidade de círculos que cabe,
  mantendo a fórmula anterior; mudanças de largura que não mudam essa quantidade
  não invalidam o corpo por `@State`. Nenhuma mudança de desenho ou medida.
- Diagnóstico final: 3 testes, sem falhas. Com 1.000 eventos no mesmo dia,
  rolagem esquerda: mês desligado 4,67 ms / ligado 4,61 ms, eliminando a
  amplificação anterior. Ligado: p95 5,97 ms, máximo 7,46 ms.
- Lista direita: referência congelada 1.010 NSViews / nova 51; p95 de rolagem
  5,24 / 3,50 ms, máximo 12,78 / 5,29 ms no mesmo ensaio.
- O resize final ainda chegou a 18,06 ms. Houve variação também no controle sem
  calendário. Não há prova de 120 FPS em resize ou de ganho adicional desse último
  ajuste de slots; são medidas de CPU, não frames apresentados.
- Paridade mensal: igualdade EXATA em 430/600/850pt, claro/escuro: zero pixels
  diferentes, máximo de diferença por canal zero. Timeline preservada dentro da
  tolerância anterior: 16 pixels acima de 2 níveis, diferença máxima 6.
- 9 XCTest + 5 Swift Testing, zero falhas; os 5 incluem seis casos visuais,
  cache de metadados/fontes/fuso e geometria/âncoras/Hoje/reciclagem da timeline.
- Logs: `/tmp/apollo-month-diagnostics-final.log`,
  `/tmp/apollo-month-validation-final.log`, `/tmp/apollo-agenda-final-release.log`.
- `build/Apollo.app` Release, assinatura/entitlements verificados, executável UUID
  `02FBA4A4-AD00-3D9B-AC53-2CB71D8F4285`. Versão anterior encerrada e nova
  instância PID 79952 aberta na Agenda com dados reais. Captura visual confirmou
  as duas listas, calendário, controles e aparência atual. Nenhuma publicação.
- Corrigida também uma expressão de teste externo em `MyTasksScrollTests` que a
  macro `#expect` não compilava: extração de `compactMap` para variável local,
  sem alterar o teste ou comportamento de Tarefas. Demais mudanças dessa thread
  preservadas. A build final inclui o estado compartilhado presente ao compilar.

Continuidade local, pendente de ingestão: `buscar_memoria` voltou a retornar erro;
`resolver_projeto`/`registrar_report` não estão disponíveis nesta sessão.

## Rejeição e investigação de apresentação

O usuário rejeitou a entrega: nenhum ganho percebido, alvo de 120 FPS sem quedas.
Os resultados de layout abaixo NÃO constituem comprovação de fluidez/aceitação.
Nova captura da janela real no display interno de 120 Hz, PID 1736:
`/tmp/apollo-agenda-hitches-before.trace` (Animation Hitches, ~20,54s).
359 hitches, 6.229ms acumulados; updates externos p95 21,93ms, máximo 251,32ms;
128/578 updates acima de 8,33ms. Render p95 4,68ms. Predomina custo CPU.
`sample` sem subárvores de acessibilidade: 1.122 amostras em NSHostingView.layout,
1.855 em commit CA (contagens inclusivas/sobrepostas). A automação AX contaminou
2.140 amostras; precisa ser controlada no comparativo. Cadência de superfícies
de ~119/s NÃO comprova 119 FPS fluidos, pois existem hitches explícitos.
Resumo/script: `/tmp/apollo-agenda-hitches-before-summary.json`,
`/tmp/summarize-agenda-hitches.py`. Essas capturas também tiveram interferência
de navegação para Tarefas e não servem como comparação controlada da Agenda.

Checkout `/Users/marconi/.t3/worktrees/t3/t3code-0713810d`, branch
`t3code/reduce-task-list-padding`, base `208e996`. Sem publicação.

## Evidência

- Perfil do processo real 48758: `/tmp/apollo-agenda-scroll-active.sample`.
  A thread principal teve 818/9053 amostras em `ReviewWatcher.poll`,
  659 delas em persistência síncrona. A captura não mede FPS; aproximadamente
  81,5% das amostras estavam ociosas. Não prova lentidão contínua de CPU.
- Benchmark Release offline com as views reais: 100/1.000 eventos.
  Redimensionamento da timeline: média 23,01/512,06 ms; p95 em 1.000: 596,45 ms.
  Invalidação sem mudança nos eventos: 2,27/16,51 ms. Rolagem programática:
  0,97/2,96 ms. Grade mensal: invalidação 2,19/5,45 ms.
  Arquivo `/tmp/apollo-agenda-benchmark-baseline.log`.
- A lista recicla dias inteiros; cada dia monta todos os seus cartões num VStack.
  Portanto, a quantidade de eventos por dia amplia o trabalho de layout.
  No ensaio final offline, havia 1.000 cartões montados para 1.000 eventos
  numa janela de 430×800pt, inclusive após percorrer a lista.
- IDs Google repetidos em agendas distintas colidiam no ForEach da timeline.
  No benchmark de 1.000 eventos, colisões elevaram a montagem de 786 a 1.454 ms,
  mas não explicaram o custo sustentado de redimensionamento.

## Correções aplicadas e limites

- Identidade visual composta por calendário e ID; ID de API preservado.
- Igualdade do cartão inclui o evento completo, preservando ações e metadados.
- Probes de review idênticos/antigos não republicam nem regravam o estado.
  Mudanças reais com timestamp igual e limpeza de aliases continuam aceitas.
- Dois ensaios de fixedSize (cartão e pilha diária) foram descartados: 511/514 ms,
  sem ganho relevante. Nenhuma mudança de aparência/dimensões foi mantida.
- Release final compilado: 49 testes de Agenda/review e os dois cenários do
  benchmark passaram. `/tmp/apollo-agenda-final-tests.log`. Layout com 1.000
  eventos ainda custa 527,71 ms em média; alturas dos cartões (47pt) e documento
  (53.639pt) preservadas. Isto confirma que as correções parciais não resolvem
  o gargalo de dimensionamento.

Esse resultado intermediário motivou a solicitação de autorização para mudar
a reciclagem interna de dia para evento. O usuário autorizou explicitamente,
condicionando a mudança à preservação visual.

## Reciclagem por evento autorizada e implementada

- List passa a reciclar cada evento. Cartões, inset superior, margens, material,
  fade e callbacks existentes preservados; gap de 6pt entre eventos e 22pt entre dias.
- Data de 52pt fica em overlay para não aumentar o primeiro cartão de 47pt;
  dias vazios/com evento único mantêm mínimo de 52pt.
- Âncora da primeira linha continua sendo a data. `scrollTo` usa explicitamente
  `AnyHashable`, o mesmo tipo do ID misto: o teste encontrou e corrigiu um salto
  por data que não movia a lista quando recebia `Date` diretamente.
- Comparação de pixels detectou que `NSTableRowView` cortava a sombra acima dos
  cartões de continuação. Um probe restrito à própria linha mantém clipping
  no início do dia e permite a sobreposição nas continuações, reaplicando no
  reuso. O clipping do viewport não muda.
- Testes usam uma referência independente da lista antiga, verificando geometria,
  altura total após percorrer as linhas, dias vazios, âncoras/Hoje, identidade de
  agendas compartilhadas, quantidade limitada de cartões e paridade de pixels.
- Benchmark final isolado, com sombras preservadas e 1.000 eventos: 33 cartões
  montados, montagem 114,19ms (antes ~794ms), resize médio 47,01ms/p95 68,25ms
  (antes 527,71ms/p95 ~618ms): redução de 91% no custo médio de resize.
  Rolagem em passos de 80pt: média 5,85ms/p95 9,98ms. Saltos grandes percorrendo
  todo o documento custam 45,62ms em média, pois agora materializam novas linhas.
  São tempos de trabalho/layout, não FPS da tela.
  Evidência: `/tmp/apollo-agenda-recycling-benchmark-final.log`.
- 54 testes funcionais passaram (49 XCTest + 5 Swift Testing) e os dois cenários
  do benchmark passaram. Comparação visual: somente 16 pixels ultrapassaram a
  tolerância de 2 níveis/canal; máximo de 6, consistente com arredondamento de
  composição. O defeito de sombra teria 18.156 pixels acima dessa tolerância.
  Âncora de dia medida em 1.772pt, exatamente igual ao deslocamento observado;
  documento de referência e novo, após percorridos: 2.586pt.
  Evidência: `/tmp/apollo-agenda-correctness-final.log`,
  `/tmp/apollo-agenda-current.png`, `/tmp/apollo-agenda-reference.png`.

## Entrega local

- `./build.sh release` concluiu com assinatura e entitlements verificados:
  `/tmp/apollo-agenda-production-build-final.log`.
- Bundle atualizado em `build/Apollo.app`; processo real 1736 confirmou o mesmo
  UUID do executável final: `F5192B05-F9AF-3DC6-8230-0A3F497D50EC`.
  Evidência: `/tmp/apollo-agenda-final-live.sample` e `dwarfdump --uuid`.
- Agenda real aberta e inspecionada por captura: cartões, datas, grade e controles
  presentes com as mesmas medidas. O modo de aparência atual do sistema é escuro;
  nenhuma preferência de aparência foi alterada nesta tarefa.
- A navegação manual completa não pôde ser isolada: outra sessão também manipula
  Apollo, com dois processos usando o mesmo bundle ID. A tela mudou para Tarefas
  durante a tentativa de rolagem. Parei de disputar a interface; navegação/Hoje
  estão cobertos pelos testes nativos. Não há medição de FPS de apresentação.
- Alterações de MyTasks de outra sessão foram preservadas e não pertencem a este
  diagnóstico. Nenhum push, release remoto ou distribuição foi realizado.

Segundo Cérebro indisponível: `buscar_memoria` retornou erro; resolução/report
não estão expostos. Continuidade local pendente de ingestão, sem gravação remota.


## Meta explicita de 120 FPS — nova investigacao (24/set, manha)

Meta criada e ATIVA: corrigir a Agenda, sobretudo as duas rolagens, e comprovar
120 FPS reais sem mudar aparencia/interacoes. Usuario rejeitou a build anterior.
Nao existe comprovacao de cumprimento. Pergunta sobre trackpad/mouse pendente.

- Processo anterior confirmado: 79952, neste checkout. Capturas Hitches/sample
  em `/tmp/apollo-agenda-goal-{baseline,clean,wheel,pages}.{trace,sample}`.
  Baseline incluiu consulta AX: contaminado por materializacao de acessibilidade.
  Gestos CUA por paginas nao equivalem a inercia de trackpad. Paginas fracionarias
  nao deram deslocamento confiavel; pixels sao rejeitados pelo CUA no macOS.
  Compilacao simultanea tambem contamina as ultimas capturas. NAO converter
  contagem agregada dos tres surface-id em FPS do aplicativo.
- Samples clean/wheel mostram ReviewWatcher -> recordDiscoveredUpdate ->
  persistPendingUpdates ainda ocupando a main thread (277/7747 e 1060/11859
  amostras, respectivamente). Ha custo real de persistencia, mas isso nao prova
  sozinho a causa da lentidao sustentada. Dados privados nao foram copiados.
- Hardware verificado: painel interno 3024x1964, 1512x982 @120 Hz; powermode=0,
  sem aviso termico/de desempenho. `/tmp/apollo-agenda-displays.json`.
- Candidato NSHostingView separado para o mes: seis snapshots exatos, mas ganho
  pequeno no teste A/B. DESCARTADO; ContentView voltou a nao ter diff.
  `/tmp/apollo-agenda-isolation-{visual,ab}.log`.
- Candidato drawingGroup na grade: alterou 12.619–60.595 pixels, maximo 34 niveis
  por canal. DESCARTADO; desenho original preservado.
  `/tmp/apollo-agenda-grid-raster-visual.log`.
- Mudanca atual: AgendaDayCell Equatable, comparando todos os dados visuais e
  eventos completos. isToday agora e entrada explicita, preservando atualizacao
  de data. A closure so seleciona o mesmo dia na mesma localizacao de State.
  Evita reconstruir circulos/tooltips de celulas inalteradas em publicacoes
  irrelevantes do AppState; hover e geometria continuam em State local.
- Validacao: seis comparacoes claro/escuro x430/600/850pt com diferenca ZERO;
  quatro testes Swift Testing de projecao/timeline e XCTest do modelo passaram.
  Logs `/tmp/apollo-agenda-equality-visual.log` e
  `/tmp/apollo-agenda-120-functional.log`.
- Diagnostico CPU/layout, 1000 eventos no mesmo dia: scroll80pt media3,43ms,
  p95=4,98, max=6,67; invalidacao media4,74ms. Com eventos distribuidos:
  invalidacao3,15ms (controle sem calendario2,24ms). Antes, no ensaio A/B,
  invalidacao4,85ms (controle2,39ms). Sao sinais de reducao no trabalho do
  calendario, NAO FPS apresentados. `/tmp/apollo-agenda-equality-bench.log`.
- Outra thread voltou a alterar MyTasksAppKitList neste checkout. Corrigido
  mecanicamente `batch.map { phase ... }` para `$0.phase` na inicializacao de
  badgeCount, evitando captura de self antes da inicializacao. Sem mudar logica.
- Snapshot isolado criado em `/tmp/apollo-agenda-120-20260924`, detached208e996,
  com diff atual e fontes/testes novos. O segredo local de build e apenas
  referenciado por symlink ao arquivo original ignorado; conteudo nao lido/exposto.
  Build Release em andamento; destino autorizado local:
  `build/agenda-120/Apollo.app`. Log `/tmp/apollo-agenda-120-release.log`.
  Nenhuma publicacao, push ou commit. Proximo passo: terminar build, verificar
  UUID em execucao, medir rolagem sem compilacao/AX concorrentes e continuar
  atacando gargalos ate comprovar a meta. Nao declarar resultado concluido.

Segundo Cerebro: buscar_memoria novamente falhou; resolver_projeto e
registrar_report nao expostos. Este handoff continua pendente de ingestao.


### Build isolada aberta e captura com trackpad pendente de confirmacao

Release concluido, assinatura/entitlements verificados; bundle
`build/agenda-120/Apollo.app`, UUID7B124880-7BF7-3233-A4F9-70D2A237572C,
PID69510. Sample `/tmp/apollo-agenda-120-live.sample` confirma UUID carregado.
Conta real carregou; Agenda aberta via CUA. Tarefas DEV de outra thread nao foi
encerrado. Build anterior PID79952 encerrada sem dialogos de edicao.

Captura por 12 gestos CUA de uma pagina (SEM AX/compilacao concorrente):
`/tmp/apollo-agenda-120-live.trace`; ainda512 hitches. Render~17,55ms, GPU~2,1ms.
Ha duplicacao de renders containment-level0/1: nao somar ambos. SurfaceIDs473,
674,850 persistem entre processos e nao devem ser interpretados como tres
janelas/cadencias de aplicativo independentes. Fase de composicao merece
investigacao; nao afirmar que isso identifica sozinho a causa raiz.
Sample de WindowServer419 negado por privilegio; sudo-n solicita senha.
Nao alterar permissoes nem insistir: preferir os instrumentos disponiveis.

Usuario confirmou TRACKPAD INTERNO. Foi solicitada rolagem fisica durante uma
captura de60s, incluindo inercia. Arquivo `/tmp/apollo-agenda-120-trackpad.trace`
concluido; retorno sobre execucao dos gestos ainda pendente. Registrou0hitches,
mas pode estar ocioso: NAO interpretar como prova de120FPS. Ferramenta CUA
nao emula trackpad com fases/inercia; so paginas (pixels nao suportados no Mac).
Proximo foco: confirmar gesto capturado e limites de preparacao/rolagem responsiva
nos NSScrollViews reais; medir o caminho do trackpad, sem substituir por saltos.
Meta permanece ATIVA, sem 120FPS comprovados. Sem novo pedido de permissao.

## Captura fisica confirmada e candidato de prefetch — 24/09 07:48

Usuario confirmou "Terminei a rolagem agora" enquanto xctrace estava ativo.
Captura encerrada e salva: `/tmp/apollo-agenda-trackpad-confirmed.trace`, PID69510,
125,09s. Sem consultas AX durante gesto. 1037 hitches, max141,67ms.
Trecho com atualizacoes custosas: segundos75–110 (inferido da atividade, nao marca
manual do gesto):843 hitches;1715 updates externos, p9541,85ms,max91,90ms,
984 acima8,33ms. Renders containment0 unidos por swapID: p9531,50ms.
Resumo `/tmp/confirmed-active-summary.json`. Nao converter lifecycle em FPS.
Captura Hitches NAO contem stacks de CPU: nao atribuir causa exata sem perfil.

Diagnostico de responsividade: lista direita HostingScrollView declara
isCompatibleWithResponsiveScrolling=false; esquerda NSScrollView/NSTableView=true.
Log `/tmp/apollo-agenda-responsive.log`. Isso e pista, nao prova causal isolada.
Candidato SwiftUI List direita falhou seis comparacoes visuais: sombras dos discos
mudam (ate19 niveis/canal). DESFEITO; copia somente em
`/tmp/AgendaMonthView-list-candidate.swift`. Mantido LazyVStack anterior.
Esquerda: prepareContent limita preparacao a viewport atual e uma tela acima/abaixo.
Teste1000eventos passou, incluindo preparedContentRect<=3viewports e montagem<100.
Nova verificacao apos desfazer List: `/tmp/apollo-agenda-prefetch-parity.log`.
Build aberta ainda nao inclui prefetch; nao substituir antes de validar.
Meta120FPS continua ativa. Nenhuma melhoria de FPS comprovada nesta etapa.
Proximo perfil deve capturar CPU junto com Hitches durante o mesmo gesto;
os agregados atuais identificam custo de update/render, nao funcoes responsaveis.
Registro local; Segundo Cerebro indisponivel, ingestao pendente.

Verificacao concluida:4 testes em2 suites passaram;6 snapshots mensais com
ZERO pixels diferentes. Diagnosticos3 testes passaram em5,87s
(`/tmp/apollo-agenda-prefetch-diagnostics.log`). Scroll sintetico1000eventos,
calendario visivel: media3,00–3,01ms,p953,95–3,99ms. NAO e FPS real.
preparedContentRect inicial continua848pt para viewport800pt; teste de prefetch
explicito passa, mas efeito automatico no gesto fisico ainda nao comprovado.
Nenhuma nova build entregue neste turno; buildPID69510 permanece aberta.

## Perfil de CPU sincronizado — captura em andamento

Amostra automatizada `/tmp/agenda-cpu-scroll-3.sample`30s: saltos por pagina
passam por NSScrollingBehaviorConcurrentVBL e criacao/remocao de NSHostingView;
nao reproduzem a carga sustentada observada no trackpad. Nao usar como prova.
Iniciada captura conjunta Time Profiler+Hitches PID69510, xctracePID93394,
PTY46113, `/tmp/apollo-agenda-cpu-trackpad.trace`. Sem limite de tempo;
parar com Ctrl-C SOMENTE apos resposta de conclusao do gesto. Pergunta async
solicitou15s nas duas listas e explicou falta de stacks da captura anterior.
Nenhuma compilacao/AX durante o gesto. Aguardar mesmo handle, nao reiniciar.
