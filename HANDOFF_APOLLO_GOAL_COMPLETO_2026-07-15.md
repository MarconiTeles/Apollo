# Apollo — contexto total, estado do goal e handoff

Data do handoff: **15 de julho de 2026, aproximadamente 01:00 BRT**  
Workspace: `/Users/marconi/Documents/PROJETOS/CLOUDE/daypanel-swift`  
Branch: `redesign/editorial-plus`  
Commit-base atual: `d5cf1af`  
Goal ativo no Codex: **“implemente, valide, teste até que a UX/UI fique Industry leading”**

## 1. Regra principal desta etapa

- Para validação com dados reais, **somente a tarefa `TESTE 3` pode ser alterada**.
- Nenhuma outra tarefa pode receber comentário, anexo, mudança de status, responsável, data ou qualquer outra mutação. As demais tarefas são projetos reais.
- Não publicar release, appcast ou nova versão pública até o usuário encerrar o lote de funcionalidades e autorizar explicitamente.
- A versão local continua identificada como `1.8.15`; este lote ainda não deve ser distribuído.
- Build e teste automatizado não bastam. A aceitação exige validação no Apollo instalado, observando a interface e o estado real no ClickUp.
- O Mac deve permanecer acordado durante o trabalho. Nesta sessão foi iniciado `caffeinate -dimsu`.

## 2. O que o usuário pediu ao longo da sessão

### 2.1. Filosofia geral de produto e design

- Abandonar a aparência excessivamente editorial e adotar uma linguagem nativa de macOS, com cápsulas, geometria mais orgânica e Liquid Glass usado com intenção.
- Popups aproximadamente 35% mais arredondados.
- Liquid Glass somente nas regiões estruturais apropriadas:
  - barra superior de tarefas;
  - barra superior de eventos;
  - barras superior e inferior do popup de notificações;
  - painel esquerdo de Configurações, mantendo o painel direito sólido.
- Conteúdo rolado deve passar por baixo das barras Liquid Glass e produzir transparência real.
- Evitar “vidro dentro de vidro” e materiais pesados.
- Sombras coloridas somente nos cards do Quadro.
- Listas, Inbox, notificações e demais superfícies devem usar sombra neutra.
- Reduzir em cerca de 50% a área/comprimento visual das sombras e evitar qualquer corte nas bordas.
- Sombras devem manter o deslocamento, mas projetadas para baixo, não para cima.
- Hover não pode deslocar a célula; manter apenas escala, material, borda e sombra quando aplicáveis.
- Todos os hovers devem ser desativados durante scroll em todas as telas do app e não podem permanecer presos depois do scroll.
- Foco azul retangular padrão não deve aparecer nos controles customizados.
- Botões e filtros precisam compartilhar altura, raio, padding, tipografia, ícones e estados coerentes.

### 2.2. Lista, Quadro, seleção e drag and drop

- Categorias/status vazios não podem desaparecer, pois continuam sendo destinos de drag and drop.
- Paridade total entre lista e Quadro para seleção múltipla, drag, ações em lote e feedback visual.
- Todas as tarefas selecionadas devem aparecer durante o drag.
- Drag precisa de atraso de ativação de **0,04 segundo**, evitando conflito com clique comum.
- `Esc` deve limpar a seleção.
- Abrir a lista não pode restaurar uma tarefa antiga indevidamente selecionada.
- Toda a linha deve ser clicável, inclusive o quarto inferior e áreas próximas ao rodapé.
- A cápsula de ações em lote deve ser centralizada no canvas útil, considerando o painel lateral.
- A largura original das colunas do Quadro deve ser preservada; a tentativa de alargar o canvas foi rejeitada e deveria ser revertida sem remover a melhoria das sombras.
- Durante drag no Quadro, o preview não pode apresentar sombra cortada ou artefatos.
- Cards do Quadro mantêm sombra colorida; cards/listas fora do Quadro não.

### 2.3. Popups e animações

- Popup de status deve ser compacto, sem duas camadas visuais.
- Animação do popup de status deve se comportar como bolha de Liquid Glass expandindo/contraindo.
- Agulha do popup do botão Done deve ficar alinhada à esquerda quando necessário para manter o conteúdo dentro do canvas.
- Altura do popup deve corresponder à quantidade de opções, sem espaço vazio inferior.
- Status em menus e submenus devem ter ponto e cor semântica.
- Popup de tarefa deve usar a mesma animação de entrada/saída do popup de evento.
- Restaurar o carrossel anterior/próxima tarefa sem quebrar a animação in/out do popup.
- Popup de evento segue o mesmo princípio estrutural de barra Liquid Glass e conteúdo rolando sob ela.
- Scrollbar da área de Comentários/Atividade da tarefa deve ficar oculta.

### 2.4. Inbox e notificações

- `Hoje` foi renomeado para `Inbox`.
- `Minhas tarefas` foi renomeado para `Tarefas`.
- Notificações do Inbox e do popup devem usar cápsulas, não linhas editoriais.
- Retirar o ponto colorido solto da notificação e compactar o espaçamento vertical.
- Aplicar tint muito leve às cápsulas para apoiar leitura, sem sombra colorida.
- Ponto, origem `APOLLO`/`CLICKUP`, título e metadados devem permanecer alinhados.
- Popup de notificações deve ser leve e manter FPS alto, inclusive com muitas notificações.
- Somente header e footer usam Liquid Glass; lista interna passa por baixo.
- Implementar lista de uploads com progresso real.
- Implementar cápsula ao vivo de upload com nome, arquivo, porcentagem, barra e cancelamento.
- Hovers no Inbox também precisam ser suspensos durante scroll.

### 2.5. Comentários atribuídos

- Substituir a antiga categoria `Próximos` por `Comentários` no painel lateral.
- Criar página de comentários em que o usuário foi marcado/atribuído, inspirada nas funções principais do ClickUp:
  - atribuídos a mim;
  - delegados por mim;
  - resolvidos;
  - intervalo de data;
  - busca;
  - filtros;
  - resolver;
  - reações;
  - salvar para depois;
  - encaminhar;
  - atribuir;
  - marcar como lido;
  - copiar link;
  - lembrar mais tarde.
- Não sincronizar mais de 3.000 comentários de uma vez; paginação deve ser em lotes de **30**.

### 2.6. Sidebar e marca

- Adicionar a escrita/logo `APOLLO` na área vazia acima do label `Edição`.
- Ao final do lote, trocar o ícone pelo arquivo:
  `/Users/marconi/Documents/PROJETOS/CLOUDE/cópia de APOLLO_ICON_06.pxd`.
- A troca de ícone ainda precisa de validação do formato/exportação e não autoriza release.

### 2.7. Fluxo rápido de mídia solicitado

O usuário forneceu e aprovou o plano “Envio rápido, composição incremental e revisões versionadas”. Requisitos consolidados:

- Cada tarefa tem ação `ANEXAR`.
- Menu:
  - `Adicionar arquivos`;
  - `Substituir arquivo`.
- Finder aceita seleção múltipla na adição.
- Classificar arquivos como `HOOK`, `BODY` ou `VIDEO`.
- Detecção inicial pelo nome, mas ambiguidades exigem confirmação.
- Composição incremental:
  - 5 HOOKs × 2 BODYs = 10 vídeos;
  - adicionar 1 BODY produz apenas 5 novas combinações;
  - adicionar 1 HOOK produz apenas as combinações ainda inéditas;
  - `VIDEO` direto não entra na matriz.
- SHA-256 impede duplicatas.
- Substituição deve ser **visualmente explícita e separada**:
  - `SUBSTITUIR HOOK`;
  - `SUBSTITUIR BODY`;
  - `SUBSTITUIR AMBOS`;
  - substituição integral para vídeo direto.
- Substituir uma fonte regenera somente as combinações afetadas.
- Substituição simultânea de HOOK + BODY deve gerar a combinação compartilhada uma vez.
- Substituições em operações separadas avançam novamente a linhagem: V1 → V2 → V3.
- Versões anteriores e seus comentários/links permanecem acessíveis.
- O usuário escolhe o nome final de cada vídeo antes do envio.
- Estados da cápsula:
  `ANEXAR → CLASSIFICAR → PREPARANDO N/M → ENVIAR → ENVIANDO → ENVIADO`.
- Botão `ENVIAR` usa accent e mostra o número de vídeos em badge no canto superior direito.
- O próprio botão deve representar o progresso, como barra de loading.
- Hover do botão deve ser premium, sem outline azul e sem aparência de botão cinza padrão.
- Publicação pergunta quem mencionar, com busca inteligente e seleção múltipla, priorizando responsáveis da tarefa.
- Cada resultado deve gerar exatamente:
  - um anexo real;
  - um comentário final;
  - um link/botão `REVISAR`.
- Nunca criar comentários provisórios ou incompletos.
- Cancelar mantém o lote preparado.
- Falha parcial mostra apenas pendentes e oferece `Tentar novamente` e `Descartar`.
- Renderização em background, serial, sem degradar FPS.
- Até dois uploads simultâneos somente depois de tornar o retorno dos anexos seguro para concorrência.
- Compositor:
  - HOOK seguido de BODY;
  - corte seco;
  - canvas, orientação e FPS definidos pelo BODY;
  - HOOK em aspect-fill centralizado;
  - MOV H.265/HEVC;
  - portar apenas geometria/progresso auditados do Galileo, sem incorporar EditKit completo.

## 3. Arquitetura implementada no worktree atual

### 3.1. Novos arquivos

- `Sources/DayPanel/Models/TaskMedia.swift`
  - `TaskMediaAsset`: identidade lógica permanente da fonte.
  - `TaskMediaRevision`: revisão, SHA-256, arquivo local/remoto e attachment id.
  - `TaskMediaOutputLineage`: par lógico HOOK + BODY ou VIDEO direto.
  - `TaskMediaOutputVersion`: V1/V2/V3 e fontes usadas.
  - `TaskMediaPlan` e planner incremental.
  - importação determinística de anexos antigos como VIDEO direto.
- `Sources/DayPanel/Services/TaskMediaTransferStore.swift`
  - estado por tarefa fora de células recicláveis;
  - preparação, render, upload, retry e descarte;
  - lote e progresso em background;
  - catálogo e manifest técnico por tarefa.
- `Sources/DayPanel/Services/TaskVideoComposer.swift`
  - composição AVFoundation/HEVC;
  - geometria derivada do BODY;
  - aspect-fill do HOOK;
  - exportação e progresso.
- `Sources/DayPanel/Views/Home/TaskMediaFlowSheet.swift`
  - classificação;
  - seleção/substituição;
  - confirmação de impacto;
  - nomes finais;
  - menções;
  - status, retry e descarte.
- Testes novos:
  - `TaskMediaPlannerTests.swift`;
  - `TaskMediaTransferStoreTests.swift`;
  - `TaskVideoComposerGeometryTests.swift`.

### 3.2. Arquivos existentes alterados

- `Sources/DayPanel/Models/CUTask.swift`
- `Sources/DayPanel/Services/ClickUpService.swift`
- `Sources/DayPanel/ViewModels/AppState.swift`
- `Sources/DayPanel/Views/Dashboard/TaskDetailSheet.swift`
- `Sources/DayPanel/Views/Dashboard/TaskDetailView.swift`
- `Sources/DayPanel/Views/Home/EditorialMyTasksView.swift`
- `Sources/DayPanel/Views/Home/MyTasksAppKitList.swift`
- `Tests/DayPanelTests/UploadActivityTests.swift`

### 3.3. Funcionalidades de mídia já implementadas em código

- Ação `ANEXAR` na lista.
- Estados de cápsula e badge.
- Atraso de drag de 0,04 segundo coberto por teste.
- Planejamento 5×2, incremento, deduplicação e versionamento.
- Composição real HEVC coberta por teste de arquivo sintético.
- Nome de saída editável.
- Upload em background e progresso.
- Catálogo técnico persistido como anexo reservado.
- Migração de anexos de vídeo antigos para VIDEO direto substituível.
- Separação lógica entre attachment id e URL, eliminando o estado global inseguro de “último anexo”.
- Picker de substituição para fontes realmente persistidas.
- Último ajuste implementado na UI:
  - três ações visíveis para um vídeo composto: HOOK, BODY e AMBOS;
  - `AMBOS` abre duas escolhas explícitas e só grava a seleção se as duas forem concluídas;
  - cancelar qualquer uma deixa a seleção anterior intacta.

## 4. Falha crítica encontrada e correção atual

### 4.1. Sintoma real na tarefa TESTE 3

Ao substituir vídeos, o histórico recebeu três comentários como:

`@Marconi Reis`  
`V2 · Testes · V2.mov`

Esses comentários não tinham anexo nem link REVIEW. Depois surgiu um quarto comentário correto com MOV e REVIEW.

### 4.2. Causa raiz

O fluxo antigo fazia:

1. criar comentário placeholder;
2. tentar enviar o arquivo associado ao comentário;
3. atualizar o texto/link;
4. tratar estados intermediários como passíveis de retry.

Quando o ClickUp não vinculava o anexo ao comentário, o texto já havia sido publicado. Cada retry criava outro placeholder.

### 4.3. Correção implementada

O fluxo agora faz:

1. upload do arquivo como attachment da tarefa;
2. recebe `attachmentId` + URL reais;
3. cria o comentário final uma única vez, com attachment segment e link `REVISAR`;
4. relê os comentários do servidor;
5. confirma que o comentário contém `REVISAR` **e** o attachment id esperado;
6. só então marca o output como publicado;
7. se o comentário final vier incompleto, ele é removido e o lote permanece retryable.

O UI de falha não usa mais um anel falso travado em 0%. Exibe `PUBLICAÇÃO INCOMPLETA`, mensagem do erro, `TENTAR NOVAMENTE` e `DESCARTAR`.

### 4.4. Limpeza de placeholders

- Foi adicionada identificação de comentários incompletos criados pelo próprio usuário.
- O padrão reconhecido é o formato Apollo `Vn · nome · Vn.ext`, sem attachments e sem `REVISAR`.
- O código também reconhece o mesmo V2/V3 após o usuário renomear o arquivo.
- **Pendência importante:** os três comentários inválidos já existentes na TESTE 3 ainda precisam ser verificados e removidos no fluxo real. A limpeza atual roda antes de uma nova publicação compatível; deve-se confirmar no ClickUp que ela realmente remove todos os três sem tocar comentários válidos.
- Se a nova publicação avançar de V2 para V3, revisar se a limpeza deve remover placeholders incompletos de qualquer versão Apollo, e não somente da versão corrente. A regra segura é: mesmo autor + regex Apollo completa + zero anexos + ausência de REVIEW.

## 5. Validação executada nesta sessão

### 5.1. Automatizada

Comando:

```bash
swift test
```

Resultado mais recente:

- **60 testes executados**;
- **0 falhas**;
- incluindo teste real de composição HEVC;
- incluindo paginação de comentários em 30;
- incluindo atraso de drag de 0,04 s;
- incluindo retry, placeholders e verificação attachment + REVIEW.

Também executados:

```bash
git diff --check
./build.sh debug
```

Resultado:

- `git diff --check`: sem erro;
- bundle gerado e assinado em `build/Apollo.app`;
- entitlements obrigatórios verificados.

### 5.2. Apollo instalado/em execução

- Build debug relançado a partir de:
  `/Users/marconi/Documents/PROJETOS/CLOUDE/daypanel-swift/build/Apollo.app`.
- PID observado nesta etapa: `49803`.
- A tela `Tarefas` abriu com 333 tarefas.
- `TESTE 3` foi localizada na seção `A EDITAR`.
- O menu `ANEXAR` da TESTE 3 expôs:
  - `Adicionar arquivos`;
  - `Substituir arquivo`.
- A tela real de substituição abriu e mostrou quatro vídeos históricos como `VÍDEOS COMPLETOS`:
  - `0710 (1)(2) · V2`;
  - três vídeos `hf_... + BODY ... · V1`.

### 5.3. Verdade sobre os vídeos antigos

Os quatro itens históricos aparecem como VIDEO direto porque o fluxo anterior guardou somente o MOV final. Ele não preservou um catálogo de fontes HOOK/BODY nem os arquivos-fonte separados.

Por isso:

- eles podem ser substituídos integralmente;
- não é tecnicamente honesto oferecer substituição separada de HOOK/BODY nesses itens antigos;
- o Apollo não deve inventar fontes inexistentes;
- vídeos criados pelo novo fluxo, com manifest e fontes preservadas, devem mostrar HOOK, BODY e AMBOS.

Essa distinção precisa aparecer de forma explícita na interface, com mensagem como:

`Fontes originais indisponíveis — este vídeo foi enviado antes do catálogo Apollo e permite apenas substituição integral.`

## 6. O que ainda falta implementar ou validar

### Prioridade P0 — não encerrar sem isso

1. **Executar um fluxo novo completo exclusivamente na TESTE 3**:
   - adicionar HOOK sintético válido;
   - adicionar BODY sintético válido;
   - confirmar classificação;
   - renderizar V1;
   - escolher nome final;
   - enviar;
   - confirmar exatamente um comentário com MOV + REVIEW;
   - confirmar que nenhuma linha placeholder aparece.
2. Reabrir `Substituir arquivo` e confirmar visualmente no item recém-criado:
   - botão `SUBSTITUIR HOOK`;
   - botão `SUBSTITUIR BODY`;
   - botão `SUBSTITUIR AMBOS`;
   - nomes das fontes e revisões R1.
3. Substituir apenas HOOK:
   - gerar somente saídas afetadas;
   - avançar V1 → V2;
   - manter V1 acessível;
   - confirmar anexo + REVIEW.
4. Substituir apenas BODY:
   - regenerar todas as combinações daquele BODY;
   - confirmar versionamento correto.
5. Substituir AMBOS:
   - confirmar seleção atômica;
   - confirmar que a combinação compartilhada renderiza uma única vez.
6. Validar retry real:
   - simular/interromper rede de forma controlada ou usar mock de serviço;
   - garantir que arquivo já anexado não seja reenviado;
   - garantir que comentário incompleto não sobreviva;
   - garantir que não haja duplicata.
7. Limpar e confirmar a remoção dos três placeholders antigos da TESTE 3, sem excluir o comentário válido com MOV + REVIEW.
8. Confirmar que o manifest técnico reaparece depois de reiniciar o Apollo e em nova leitura da tarefa.
9. Confirmar que o novo vídeo composto continua separável depois de reiniciar o app.

### Prioridade P1 — qualidade e desempenho

1. Medir FPS/scroll do Inbox e popup de notificações no app instalado.
2. Confirmar que nenhum hover permanece durante scroll em:
   - Tarefas;
   - Quadro;
   - Inbox;
   - popup de notificações;
   - Comentários;
   - menus e popovers.
3. Verificar sombras sem corte em light e dark mode:
   - status picker em todos os pontos do app;
   - cards do Quadro;
   - drag preview;
   - cápsulas do Inbox;
   - popup de notificações.
4. Confirmar que sombra colorida existe somente no Quadro.
5. Confirmar que a lista mantém sombra neutra.
6. Validar animação in/out de tarefa e evento lado a lado.
7. Validar carrossel de tarefas e abertura/fechamento sem regressão.
8. Validar Escape, seleção, drag de 0,04 s e ausência de seleção restaurada ao abrir a lista.
9. Validar clique em toda a altura da linha, especialmente o quarto inferior.
10. Validar barra Liquid Glass com conteúdo passando por baixo em tarefa, evento e notificações.

### Prioridade P2 — fechamento visual e escopo acumulado

1. Auditoria de coerência dos botões/filtros da página Comentários.
2. Verificar página Comentários contra as funcionalidades principais especificadas.
3. Confirmar paginação 30 a 30 no app, não apenas no teste.
4. Verificar sidebar, logo APOLLO e nomes Inbox/Tarefas/Comentários.
5. Exportar o novo ícone a partir do PXD, aplicar ao bundle e validar todos os tamanhos.
6. Só depois da autorização do usuário:
   - atualizar versão/build;
   - commit final;
   - gerar release;
   - appcast;
   - disponibilizar aos usuários.

## 7. Riscos e decisões que não podem ser esquecidos

- Não usar outra tarefa além da TESTE 3 para testes reais.
- Não afirmar “validado” com base apenas em testes unitários ou build.
- Não reconstruir HOOK/BODY de vídeo legado se as fontes não foram preservadas.
- Não criar comentário antes de o attachment real existir.
- Não considerar comentário enviado sem reler o servidor e confirmar attachment id + REVIEW.
- Não apagar comentário de outro usuário.
- Não apagar comentário com attachment ou REVIEW.
- Não perder o estado do lote ao reciclar células ou navegar.
- Não depender de um singleton “último anexo” para uploads concorrentes.
- Não aumentar novamente a largura das colunas do Quadro.
- Não lançar atualização pública durante este lote.

## 8. Comandos úteis para continuar

```bash
cd /Users/marconi/Documents/PROJETOS/CLOUDE/daypanel-swift
swift test
git diff --check
./build.sh debug
open -n build/Apollo.app
```

Para manter o Mac acordado:

```bash
caffeinate -dimsu
```

Para inspecionar o estado local:

```bash
git status --short
git diff --stat
```

## 9. Estado do worktree no momento do handoff

Há alterações não commitadas e arquivos novos. Isso é intencional: o usuário pediu acumular as funcionalidades e só lançar ao final do lote.

Arquivos modificados:

- `Sources/DayPanel/Models/CUTask.swift`
- `Sources/DayPanel/Services/ClickUpService.swift`
- `Sources/DayPanel/ViewModels/AppState.swift`
- `Sources/DayPanel/Views/Dashboard/TaskDetailSheet.swift`
- `Sources/DayPanel/Views/Dashboard/TaskDetailView.swift`
- `Sources/DayPanel/Views/Home/EditorialMyTasksView.swift`
- `Sources/DayPanel/Views/Home/MyTasksAppKitList.swift`
- `Tests/DayPanelTests/UploadActivityTests.swift`

Arquivos novos:

- `Sources/DayPanel/Models/TaskMedia.swift`
- `Sources/DayPanel/Services/TaskMediaTransferStore.swift`
- `Sources/DayPanel/Services/TaskVideoComposer.swift`
- `Sources/DayPanel/Views/Home/TaskMediaFlowSheet.swift`
- `Tests/DayPanelTests/TaskMediaPlannerTests.swift`
- `Tests/DayPanelTests/TaskMediaTransferStoreTests.swift`
- `Tests/DayPanelTests/TaskVideoComposerGeometryTests.swift`

## 10. Critério de conclusão do goal

O goal só pode ser marcado como concluído quando:

- todas as rotinas de mídia funcionarem de ponta a ponta na TESTE 3;
- HOOK, BODY e AMBOS estiverem explícitos e corretos;
- não existir nenhum comentário intermediário/duplicado;
- cada vídeo publicado tiver anexo e REVIEW confirmados no servidor;
- retry e falhas parciais forem seguros;
- as regressões visuais e de interação acumuladas forem revisitadas no app instalado;
- desempenho do Inbox/notificações for aceitável;
- nenhuma tarefa real tiver sido alterada;
- o usuário revisar o lote e autorizar o fechamento/publicação.

Até lá, o estado correto é: **goal ativo, implementação avançada, validação real ainda incompleta**.
