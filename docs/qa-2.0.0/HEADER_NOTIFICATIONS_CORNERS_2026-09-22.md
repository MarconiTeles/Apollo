# Ajustes solicitados: notificações e raio da lateral

Base local: `08e43d2`, branch `codex/apollo-2.0.0`, checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`.

## Alteração e limite de escopo

- Notificações transitórias e de upload: a posição anterior usava 52 + 12 pontos, ignorando os 30 pontos da linha de colunas. O header de cada rota agora informa seu limite inferior em coordenadas da janela; os avisos usam esse limite + 12 pontos. A medição não modifica o layout do header.
- Ambos os avisos usam `officialHeaderMaterial`, a mesma receita do header: fullScreenUI, withinWindow, blur 5/30 e Editorial.paper a 0.85. Dimensões, texto, fechar, abrir notificações, progresso, hover e transição existentes preservados.
- Somente no macOS major 27, a lateral consulta o raio da janela inteira via API pública `GeometryProxy.concentricCornerRadii(in:)`. A consulta usa o frame da janela, não o frame inset da lateral: o pedido foi raio igual, não subtrair a margem para torná-lo concêntrico. O sistema instalado retorna 16 pontos, igual ao valor fixo anterior; portanto não se inventou uma redução visual. Outras versões mantêm 16 pontos. Material, margem de 10 pontos, largura 220 e curva contínua preservados.
- Incluído o refinamento de contraste do toggle já solicitado: brilho ON 0.4 → 0.22; ver relatório separado. Não alterados filtros, ações, dados, rede ou publicação.

## Verificação

Sonda isolada compilada com os arquivos reais `BellPill.swift` e `VisualEffectView.swift`, compatibilidade SDK/deployment 14.0. Modelos de notificação/upload e cenário externos ao produto são fixtures; não houve upload nem alteração de dados reais. Capturas inspecionadas em claro/escuro e notificações normais/de upload. Alturas do header 82 → 99 → 52 pontos resultaram em posições estabilizadas 94 → 111 → 64, sempre gap de 12. A preferência passa por um ciclo de atualização de layout antes da posição estabilizada; o aviso não altera a medida do header.

Evidências locais: `notifications-header-dark.png`, `notifications-header-light-upload.png`, `notifications-header-toolbar-only.png`, `notifications-header-probe.log` e script em `local-tools/notification-probe.swift`. A sonda omite o hover, que não foi modificado no produto.

Sonda SwiftUI/AppKit, com a mesma compatibilidade SDK, confirmou raio nativo 16 nos quatro cantos da janela e raio concêntrico local 6 no lado esquerdo de uma vista inset em 10 pontos. A implementação usa o primeiro valor. Evidência: `sidebar-corners-probe.log`. API: https://developer.apple.com/documentation/swiftui/geometryproxy/concentriccornerradii(in:)

Janela autenticada final aberta e inspecionada em `header-notifications-corners-final-window.png`, processo 80888: lateral, labels/contagens neutros, ícones accent, lupa e switch nativo desligado. Não havia toast nessa captura; a verificação visual do toast é a sonda descrita acima.

Build e assinatura finais registrados em `header-notifications-corners-audit.json`. Não constitui prova de ausência absoluta de regressões nem execução em versões anteriores do macOS.

## Continuidade

Session_report local pendente de ingestão no Segundo Cérebro: MCP indisponível nesta sessão. Integração em main local por fast-forward após validação; sem push, alteração da tag, appcast ou dos binários públicos da v2.0.0 (98). A instalação estável em /Applications não foi substituída.
