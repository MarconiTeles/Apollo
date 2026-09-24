# Settings compacta — 23/09/2026

Checkout: `/Users/marconi/.t3/worktrees/t3/t3code-83fd403d`.
Branch: `t3code/macos27-sidebar-design`; base: `917edc9`.

## Alteração

Mudança restrita a `Sources/DayPanel/Views/SettingsView.swift`:

- Painel limitado a 860 × 620 pt, reduzido conforme a área disponível; sidebar de 190 pt com as métricas de ícones/linhas do app.
- Tipografia SF, cartões arredondados com tokens dinâmicos, botões nativos glass e navegação sem números romanos.
- Geral reúne aparência real (Claro/Escuro/Sistema), menu bar, notificações nativas e reabertura do tutorial. Sincronização permanece em Integrações, sem duplicação.
- Removidos todos os controles de protótipo `emBreve`/bindings constantes: edição fictícia do perfil, Gmail/Slack, wake/offline, comportamento/histórico de IA, tipografia/densidade, lembretes, telemetria/debug, exportação/limpeza e changelog sem ação.
- Mantidos conta/sair, ClickUp, Google Calendar, mapeamento Done, seletor de listas, configurações reais dos provedores de IA, atalhos verificados no código e atualização do app.
- Mapeamento Done recolhível: os 10 status da fixture e seus menus continuam acessíveis; a frequência de sincronização fica visível sem rolar.
- Provedores usam um menu nativo com a mesma lista `userSelectable` e o mesmo `setBackend`.
- Nenhuma alteração a AppState, serviços, Keychain, modelos, tema global, toolbar, tarefas ou quadro.

## Verificação

- `swift test`: exit 0; 249 testes XCTest, 4 pulados, 0 falhas; mais 13 testes Swift Testing passaram.
- Log: `/tmp/apollo-settings-tests.log`. Avisos preexistentes de depreciação e mensagens do serviço de Contatos não causaram falha.
- Comparação dos blocos preservados: `doneActionMappingRow` e configurações individuais dos provedores idênticos à base; handlers de conexão/seleção preservados. As duas ocorrências de sincronização/notificações foram reduzidas a uma cada, usando os mesmos setters.
- `git diff --check`: passou.
- Build DEV Release final: exit 0; assinatura Developer ID validada com `codesign --verify --deep --strict`; identidade DEV e ausência de feed de produção verificadas pelo script. Log: `/tmp/apollo-settings-build.log`.
- Artefato atualizado e aberto: `build/dev-sidebar27/Apollo DEV Sidebar 27.app`; manifesto final em `build/dev-sidebar27/DEV-sidebar27-manifest.final.json`.
- Inspeção real da interface DEV: modos claro/escuro, troca de aparência, seis abas, menu dos provedores, abertura/fechamento do seletor de listas e retorno a Settings, fechamento por Escape e pelo botão, reabertura, expansão/recolhimento do Done e menu com destinos existentes. O menu de mapeamento foi cancelado sem modificar o destino.
- A build final foi conferida com o Done recolhido e expandido; Integrações mostra a sincronização sem rolar quando recolhido. Settings ficou aberta no DEV em modo escuro.
- Limite de evidência: DEV com `--board-fixtures=169`, sem autenticação real ClickUp/Google. O seletor mostrou corretamente o estado sem conexão. Não foram feitas alterações de credenciais, desconexões, pedidos de permissão de notificações nem publicação. Não se afirma validação de sincronização remota ou aceitação visual pelo usuário.

## Continuidade

Handoff local **pendente de ingestão** no Segundo Cérebro: `buscar_memoria` retornou erro e `resolver_projeto`/`registrar_report` não estão expostos nesta sessão. Nenhuma gravação remota foi declarada concluída.
