# Apollo DEV-01 — implementação e validação

08/09/2026. Candidata de testes, instalada separadamente do Apollo 1.9.9 (97).

## Código e execução

- Código: `/Users/marconi/Documents/PROJETOS/CLOUDE/daypanel-swift-dev-01`, branch `dev/01-optimization`, base `dcf22830944bbe93f6787a08eff3c90077b4d2d8`.
- Aplicativo: `/Applications/Apollo DEV-01.app`, versão 1.9.9 (9801), bundle `com.painellunar.app.dev01`, executável `ApolloDEV01`.
- Dados DEV: `~/Library/Application Support/Apollo DEV-01`; preferências separadas. Atualizador automático desabilitado.
- Executáveis principal e Apollo Review compilados dos fontes. Ícones/runtime imutáveis vêm dos recursos da instalação 97. `Contents/Resources/DEV-01-provenance.json` registra commits, configuração e hashes dos executáveis compilados.
- O checkout original `daypanel-swift`, a instalação `/Applications/Apollo.app` e tarefas remotas foram preservados nesta implementação.

O botão Run do ambiente usa `./script/build_and_run.sh`. O padrão é Release; `APOLLO_DEV_CONFIGURATION=debug` seleciona Debug para iterações locais.

```sh
# Compilar e instalar/abrir a candidata conectável
./script/build_and_run.sh

# Apenas compilar/empacotar
./script/build_and_run.sh --build-only

# Abrir a interface real com fixtures locais e resposta de status atrasada
open -n '/Applications/Apollo DEV-01.app' --args --fixtures --tasks=8 --latency=2

# Suíte determinística, sem os testes que escrevem no backend real de review
swift test --skip ReviewBackendE2ETests
swift test -c release --skip ReviewBackendE2ETests

# Eventos de diagnóstico e intervalos Points of Interest
./script/build_and_run.sh --telemetry
```

O modo `--fixtures` usa ContentView, o renderer AppKit e os filtros reais, mas transporte local e bloqueio de rede. A janela e a barra dizem `DEV-01 · DADOS DE TESTE`. Nenhuma tarefa DEV representa uma tarefa ClickUp do usuário. O modo comum usa os serviços reais e requer conexão própria.

## Layout solicitado durante a implementação

O contrato mais recente substitui os desenhos anteriores:

`+ Evento · + Tarefa · Hoje · Lista … Buscar · Notificações · Ajustes | Minhas tarefas [toggle]`

- `+ Tarefa` usa exatamente `TBButtonStyle`, como `+ Evento`, e conserva o formulário e a origem da animação de criação. O botão circular da direita foi removido.
- `Minhas tarefas` aciona exclusivamente `TaskFilters.assigneeIds = [userId]`. Desligar limpa responsáveis e conserva as outras dimensões. Lista e Quadro compartilham o estado, sem sync extra nem mudança para `myWork`.
- ID indisponível desconecta o controle; mudança de conta remove a seleção exclusiva do usuário anterior. Selecionar apenas o próprio ID no filtro lateral também liga o toggle.
- A configuração de janela foi extraída para `ApolloWindowChrome`, usada pelo app conectado e pelas fixtures. A toolbar nativa `.unified` define a geometria inicial. A instrução posterior acrescenta 15 pixels de tela aos recuos superior e esquerdo dos controles nativos, convertidos para pontos pela escala da tela; o deslocamento usa a posição-base e não se acumula em redimensionamentos.
- O painel lateral usa raio de 26 pt no macOS 26 e 16 pt no macOS 27 ou anterior ao 26; conserva o recuo de 10 pt. Este ambiente executa macOS 27.0 (26A5425a). O raio externo continua sendo desenhado pelo WindowServer; macOS 26 não foi executado nesta validação.

## Alterações de consistência e desempenho

| Área do plano | Implementação na candidata |
| --- | --- |
| Lista / drag | IDs estáveis, `NSCollectionViewDiffableDataSource`, snapshots serializados e atualização pendente coalescida. Preview por CALayer sem inserir/remover uma linha fictícia durante o gesto. Destino é lista + status, não IndexPath guardado. |
| Commit local | Uma transação por lote atualiza tarefas, atribuídas, índices, cache por lista e detalhes. O drop aplica antes de aguardar rede. Mudança para o mesmo status não publica nem enfileira. |
| Undo / erros | Undo disponível após commit local, inclusive com PUT pendente; rejeição parcial remove do undo as tarefas recusadas. Cada operação tem ID monotônico e baseline de rollback. Falha antiga não desfaz intenção nova. |
| Offline / réplica | Fila aguardável, FIFO, retry com backoff enquanto online, persistência do contexto de status. GET antigo ou que ainda não reflete o PUT não apaga a intenção local, inclusive quando omite a tarefa. |
| Grupos | Destinos vazios mantidos; drop abre grupo recolhido. Status presentes nas tarefas mas ausentes dos metadados ganham grupo/coluna. Colapsos guardados por lista. Status fechado mantém o escopo de abertas, com feedback de conclusão. |
| Projeção / células | Projeção memorizada por revisão, filtros, lista, status e minuto. Seleção não reaplica snapshot. Subscriptions e avatares preservados durante rebind da mesma identidade. Removida espera fixa de 220 ms ao montar Lista. |
| Sync | Calendário e ClickUp publicam independentemente. Leituras por conta/lista coalescidas; tickets protegem publicação e cache. Catálogo de status por lista. HTTP não-2xx e JSON inválido não viram lista vazia. Paginação completa ou erro explícito de limite. |
| Rede | Orçamento global de 4 requisições ClickUp; respeita Retry-After e X-RateLimit-Reset sem teto artificial de 15 s. Escritas de status ordenadas. |
| Cache / imagens | Persistência coalescida e marcador avançado só após escrita bem-sucedida. Avatares com registro atômico de requests, limpeza em erro e thumbnail ImageIO, orçamento por pixels decodificados. |
| Mídia / review | Eventos por taskID, progresso limitado a 10 Hz com terminal imediato, escrita de catálogos em fila serial, leitura do catálogo no fluxo de hidratação fora do MainActor, cache local limitado. Watchers e hidratação de review limitados/encerrados. |
| IA | Conversa observa AIAgentService diretamente. Tokens e texto de pensamento deixam de invalidar o AppState inteiro; configuração/atividade continuam atualizando o chrome. |
| Diagnóstico | Intervalos `StatusCommit`, `TaskProjection` e `ListSnapshot`, eventos de começo/fim/aceitação do drag. Fixtures sem inicialização de serviços de produção; CNContactStore agora lazy. |

## Evidência obtida

- Suíte Debug: 143 testes, zero falhas, incluindo modelo, coleção AppKit real, fila, HTTP, cache, avatares, throttle, undo imediato e rejeição parcial.
- Suíte Release: 142 testes, zero falhas, antes do último ajuste de janela. O teste adicional de recuo foi executado em Debug.
- Teste de IA: 100 emissões de texto na conversa geram 100 eventos no serviço e zero invalidações globais; a transição de atividade ainda chega ao chrome.
- A atualização de 50 tarefas gera uma revisão do índice por lote. O diagnóstico inicial do padrão antigo tinha 150 reconstruções para o mesmo número de tarefas.
- Inspeção na aplicação instalada: filtro mostra 4 das 8 tarefas de fixture; alternância Lista → Quadro conserva as 4 tarefas próprias. `+ Tarefa` abre o formulário sem atribuição automática. Barra, traffic lights e raio lateral conferidos em modo escuro.
- Houve um drop observado A FAZER → EM ANDAMENTO vazio: contagens 7/1 e tarefa visível sem sair da tela, antes da resposta local atrasada em 2 s.
- Repetições de gestos via ferramenta de UI também terminaram sem `acceptDrop`; os logs distinguiram começo e fim com `accepted=false`. Isso impede considerar concluída a aceitação de todos os gestos. Não atribuir automaticamente essa inconsistência ao usuário ou à ferramenta sem nova evidência.

Os tempos do ensaio `DEV01_PERF` medem a transação do modelo com espelhos, em 10 iterações por escala. Não medem drop até pixels, FPS, ganho global do aplicativo ou uma comparação controlada com o binário 97. Ensaio Release: p95 de 0,341 ms (100 tarefas), 0,759 ms (330), 2,584 ms (1.000) e 10,325 ms (5.000), sempre movendo 50 tarefas. Resumos da suíte em `testes-debug.txt` e `testes-release.txt`; o manifesto de build acompanha o aplicativo.

## Limites e trabalho seguinte

1. Validar a candidata com a conta real e apenas a tarefa explicitamente reservada para testes. O macOS negou acesso à cópia local de credenciais da instalação de produção (`Operation not permitted`); nenhum segredo foi impresso/copiado e nenhuma proteção foi contornada. A conexão normal dentro da DEV-01 precisa ser feita pelo usuário.
2. Concluir os cenários de gesto físico: voltar ao primeiro grupo, último item, destino recolhido, seleção múltipla, Escape, undo durante atraso e resposta de sync concorrente. O teste de snapshot prova o renderer sem remount, mas não substitui essas interações.
3. Medir Release com Instruments: drop até célula visível, primeiro frame útil, CPU/alocações/retensão, janelas estreitas/claro e ciclos de abrir/fechar player. Não há evidência de FPS ou ausência de vazamentos.
4. O orçamento de rede limita concorrência, mas ainda não possui classes explícitas de prioridade para gesto, hidratação e prefetch. A fila persistente legada continua sem partição por conta: não validar troca de contas com operações pendentes como cenário aprovado.
5. Permanecem leituras síncronas no caminho frio de alguns acessos estáticos ao catálogo e na busca de linhagem de review; remover exige preservar resolução de versões. Os warnings restantes de concorrência em autenticação/IA e a migração ampla de isolamento não foram concluídos.

Esta é uma build de testes. A instalação, a passagem da suíte e a inspeção da interface não equivalem a aprovação visual de Marconi nem à aceitação completa do plano ou à liberação de uma versão de produção.
