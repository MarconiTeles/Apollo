# Placeholders de sincronização do Apollo (23/09/2026)

> Handoff local: ingestão no Segundo Cérebro pendente. O MCP `segundo-cerebro` falhou em `resolver_projeto` e `registrar_report` nesta sessão.

## Pedido do Marconi
- Uma animação de placeholder nova para cada uma destas telas: lista de tarefas, quadro, comentários e inbox.
- Requisitos: polida, em React híbrido, extremamente profissional e informativa sobre a sincronização.
- Bug apontado: "Conecte sua conta ClickUp" aparecia com o ClickUp conectado.

## Correção do bug
- **Causa:** tarefas e comentários tratavam `userId == nil` como "desconectado". O id pode faltar no Keychain, por exemplo quando o `/user` falhou na conexão, ou chegar depois do cache.
- **Correção:**
  - o gate passou a ser `isConnected`;
  - `ClickUpAuthService.restoreUserId` busca só o id e, se falhar, não sobrescreve nomes;
  - `AppState` checa o auth antes de publicar o cache e propaga o `objectWillChange` do auth;
  - com conta conectada e id ainda sendo resolvido, a tela mostra o placeholder com "Confirmando sua conta".

## Arquitetura
- `Services/SyncJournal.swift` registra as etapas reais do sync: `structure`, `tasks`, `calendar` e `changes`.
  - Também conta as páginas streamadas do `syncList`, mas só da lista ativa; os prefetches não entram.
- `Views/Extensions/SyncLoading/`:
  - `SyncLoadingSnapshot`: função pura e testada. Todo fato e toda frase em pt-BR são decididos no Swift. O progresso tem um "teto" e nunca declara trabalho não concluído.
  - `SyncLoadingController`: `WKWebView` transparente que não intercepta cliques. Também cuida do timeout de 1,5 s e do fallback.
  - `SyncLoadingSurface`: faz o crossfade do skeleton nativo para a cena quando ela avisa `ready`.
- `web/apollo-loading` (Vite, React 19 e TypeScript):
  - gera um `index.html` único, de 251 KB (77 KB gzip), com CSP offline;
  - o bundle vai para `Resources/ApolloLoading`;
  - `build.sh` e `Package.swift` foram atualizados;
  - para desenvolver: `npm run dev` e abrir `http://localhost:5318/?scene=tasks|board|comments|inbox&theme=light&at=2.2`;
  - em DEBUG, `APOLLO_LOADING_URL` aponta o app para o Vite.

## Cenas
- **Marca comum:** a lua em fase mostra o progresso, com um satélite em órbita. A varredura lunar fica ancorada na janela e em fase com o `LunarSkeleton` nativo.
- **Tarefas:**
  - console com título, workspace e lista, contador de tarefas recebidas e tempo decorrido;
  - trilho segmentado por etapa;
  - nomes reais dos status aparecem nos grupos;
  - uma onda de luz passa a cada página recebida.
- **Quadro:**
  - cards fantasmas na grade nativa: 258/260/20/240;
  - ponto com a cor do status da coluna;
  - pacotes de luz descem do header enquanto os cards chegam;
  - cápsula flutuante centrada no canvas.
- **Comentários:**
  - anel com a leitura "X de 90 tarefas";
  - cada comentário encontrado acende a lombada de um cartão;
  - cadência de digitação no cartão sendo lido.
- **Inbox:**
  - livro-razão das fontes (ClickUp, Google Agenda, Comparando alterações), com pontilhado editorial e estado por fonte;
  - as cápsulas mostram que o app está "escutando";
  - o Inbox vazio só vira "Inbox em dia" depois da primeira comparação da sessão.

## Iteração 2 (pedido: corpo mais elaborado e ocupar a tela toda)
- A varredura única saiu. Agora cada osso tem o próprio reflexo, com atraso por linha (`--r`, 70 ms) e por posição na linha (`--c`, 55 ms): uma onda diagonal a cada 3,2 s, só com `transform`.
- Entradas em cascata:
  - linhas e headers: 32 ms por item;
  - cards do quadro: coluna × card;
  - cartões de comentários;
  - cápsulas do Inbox, que "caem" como notificações chegando.
- Em Tarefas, o anel de status de cada linha acende na cor do grupo, uma linha após a outra, quando as tarefas começam a chegar. Grupos além dos status reais ficam sem nome.
- A quantidade de itens é calculada pela altura da janela (`lib/viewport.ts`) e acompanha o redimensionamento.
- Os fallbacks nativos seguem a mesma sequência (3, 6, depois 5s; 12 cards; 12 comentários; 22 cápsulas), recortados na borda.
- `LunarSkeletonSurface` agora mede pelas próprias formas e alinha a máscara ao topo, para o conteúdo passar da borda para baixo em vez de centralizar.
- O campo `origin` saiu do snapshot.

## Iteração 3
- **Regra de itens inteiros:** só aparecem itens que cabem inteiros, sem nada cortado pela borda e sem nada atrás da cápsula do Quadro. O cálculo está em `SyncLoadingLayout` (Swift) e `lib/viewport.ts` (web), e os fallbacks nativos medem a própria altura para contar do mesmo jeito.
- **Quadro:** os cards param acima da cápsula (reserva de 108 pt); com 800 pt de altura, ficam 4 fileiras.
- **Comentários, coreografia de leitura:**
  - o balão tem duas linhas de texto;
  - no cartão sendo lido, as linhas se "escrevem" em loop, um cabeçote de destaque varre o cartão e três pontos animados aparecem;
  - cada cartão encontrado ganha a lombada, o anel no avatar e um selo com check que salta e se desenha;
  - no anel do console, uma ponta luminosa pulsa na frente do arco.

## Evidência
- `swift build`: sem avisos novos.
- `swift test --skip ReviewBackendE2ETests`: 235 testes, 0 falhas, incluindo 12 em `SyncLoadingSnapshotTests`.
- Harness `WKWebView` (`/tmp/loading-harness`):
  - `ready` em cerca de 0,43 s;
  - capturas das quatro cenas nos temas escuro e claro;
  - na iteração 2, as capturas mostram as cenas preenchendo até a borda e a onda de brilho no meio da passagem.
- As reservas nativas batem com a web: grupos em 93 pt, console de comentários com 100 + 12 pt, cápsulas do Inbox em 166,5 pt.

## Pendências
- Validar no app completo com uma partida a frio real. O Apollo de produção aberto usa o mesmo bundle id.
- Commit e PR.
