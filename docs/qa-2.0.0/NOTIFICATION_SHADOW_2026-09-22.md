# Sombra suave nos popups de notificação

Pedido: separar visualmente do conteúdo de fundo os blocos de notificação no canto superior direito.

Base: 3bc7764; checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`, branch `codex/apollo-2.0.0`.

Alteração limitada a BellPill.swift: sombra preta a 22%, raio 12 pt, deslocamento vertical 5 pt, aplicada exclusivamente ao OfficialHeaderMaterial das notificações comuns e de upload. A receita do material é a mesma; textos, ícones, dimensões, padding, hover, transições e ações permanecem no código existente. Não há alteração no header nem no painel lateral.

Verificação visual com os arquivos reais BellPill.swift e VisualEffectView.swift em sonda isolada, compatibilidade SDK/deployment 14 igual ao app. Modelos e dados da sonda são fixtures; nenhuma notificação foi injetada na conta nem upload real executado. Capturas inspecionadas em claro/escuro: notification-shadow-dark.png e notification-shadow-light-upload.png. Posições estabilizadas conferidas no log notification-shadow-probe.log: 94, 111 e 64 pt para headers de 82, 99 e 52 pt, sempre com gap de 12 pt. A sonda omite o hover, que não foi modificado. Script existente: local-tools/notification-probe.swift.

Continuidade: session_report local pendente de ingestão. Segundo Cérebro buscar_memoria retornou erro nesta sessão e não há ferramentas de registro expostas. Release pública e instalação /Applications/Apollo.app permanecem intactas.

Build Release concluída em build-notification-shadow.log. Entitlements e assinatura profunda/estrita aprovados; git diff --check sem erros. Build local reaberta após a compilação. Alteração integrada somente na main local; sem publicação remota.
