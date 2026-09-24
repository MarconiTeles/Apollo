# Seletor de listas — 23/09/2026

Checkout: `/Users/marconi/.t3/worktrees/t3/t3code-83fd403d`, branch `t3code/macos27-sidebar-design`.

Pedido: fundo sólido no seletor de listas; atualizar botões, layout e iconografia para o design system atual do Apollo/macOS 27.

## Alterações

- `CUListPickerSheet` e sua linha foram extraídos de `SettingsView.swift` para `Views/Settings/CUListPickerSheet.swift`.
- Fundo `Editorial.page` opaco e adaptativo, independente de `AppHeaderMaterial`. Cantos usam o token de popup, com sombra e contorno discretos.
- Tipografia SF, hierarquia de título/subtítulo, colunas com ícones e contagens, estados vazios centralizados, busca em campo arredondado e seleção com destaque azul suave.
- Ações nativas `.glass` para fechar, tentar novamente e listas fixadas; controles de seleção e pinagem separados, com rótulos de acessibilidade e foco de teclado.
- Mensagens de erro compreensíveis e nova tentativa no nível atual. A lógica de conexão, escolha de lista e persistência permanece existente.
- Não altera os materiais dos headers de páginas.

## Validação

Build: `/tmp/apollo-list-picker-solid-build.log`.
O DEV usa `--board-fixtures=169`; a conexão ClickUp não está configurada nesse ambiente. A captura de erro/vazio é real nesse DEV, não uma lista simulada apresentada como conectada. Não se afirma validação de navegação com dados reais do ClickUp.

## Continuidade

Registro local pendente de ingestão no Segundo Cérebro. `buscar_memoria` retornou erro nesta etapa; `resolver_projeto` e `registrar_report` não estão expostos. Nenhuma gravação de memória remota foi declarada concluída.

Build final conjunto (inclui correção de foco do header escuro): `/tmp/apollo-dark-header-focus-build.log`; compilação e assinatura passaram. Seletor conferido visualmente no claro e no escuro; ação de fechar verificada. Captura final escura: `final-dark.png`.
