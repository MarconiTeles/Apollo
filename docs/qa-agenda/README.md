# Agenda mensal — 23/09/2026

Checkout: `/Users/marconi/.t3/worktrees/t3/t3code-83fd403d`, branch `t3code/macos27-sidebar-design`, base `917edc9`.

- Inbox renomeado para Agenda na sidebar, título da janela e Studio. Rota interna preservada para compatibilidade; ícone de calendário e contagem apenas de eventos de hoje.
- Coluna esquerda mantém a agenda existente; coluna direita agora mostra o calendário mensal, com segunda-feira como início da semana, Hoje, mês anterior/próximo, eventos clicáveis e lista diária para excedentes. Usa tokens Editorial e controles glass do app; referência fornecida somente como layout.
- Projeção local cobre mês completo e dias adjacentes; eventos de vários dias respeitam fim exclusivo. Carregamento por mês consulta Google e calendários compartilhados existentes, com paginação, cancelamento e erro/retry. Eventos do mês não substituem o cache usado pela timeline. Ao abrir um evento primário fora do cache, ele é adicionado para compatibilidade com as ações existentes no detalhe.
- Notificações permanecem no sino; componentes e lógica de Settings desta sessão preservados.
- `swift test`: 254 XCTest, 4 pulados, 0 falhas; mais 13 Swift Testing passaram. Cinco novos testes cobrem grid/virada de ano/ano bissexto/DST/fim exclusivo/ordenação. Log `/tmp/apollo-agenda-tests.log`.
- Debug compilado: `/tmp/apollo-agenda-debug.log`. Release/inspeção final: resultado abaixo.

Continuidade local pendente de ingestão: Segundo Cérebro retornou erro em `buscar_memoria`; resolução/report não expostos. Não houve gravação remota declarada.

## Correção após inspeção do usuário (21h27–21h28)

- Causa do encaixe ruim: toolbar mensal dentro do body começava sob o header fixo. Mês/Hoje/setas agora pertencem ao header, com o mês compartilhado por binding com a grade. O body reserva 110pt e dimensiona as semanas conforme a altura disponível; meses de seis semanas reduzem os chips visíveis e mantêm acesso aos demais eventos pelo popover.
- Coluna de eventos ampliada de 34% (teto 330pt) para 43% (teto 440pt); margens da lista forwardOnly reduzidas para 20/16pt. Demais modos da timeline preservados.
- Revalidação: debug compilado; 254 XCTest (4 pulados, 0 falhas) e 13 Swift Testing passaram novamente; `git diff --check` limpo.
- Release DEV assinado e aberto com fixtures (`--board-fixtures=169 --route=inbox --appearance=dark`), log `/tmp/apollo-agenda-release.log`. Inspeção visual a 1100×714pt: controles totalmente visíveis no header, títulos dos três eventos completos na coluna esquerda e grade inteira encaixada abaixo. Agosto/2026 (seis semanas) também coube sem cortar a última semana.
- Interações verificadas: mês anterior, Hoje, popover com os três eventos e abertura/fechamento do detalhe pelo calendário. DEV deixado na Agenda, setembro/2026. Google real não exercitado: esta validação usa fixtures isoladas. Sem merge/publicação.
