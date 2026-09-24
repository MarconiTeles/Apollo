# Correção após rejeição visual — 23/09/2026

Checkout: `/Users/marconi/.t3/worktrees/t3/t3code-83fd403d`.
Branch: `t3code/macos27-sidebar-design`; base: `917edc9`.

A primeira atualização foi rejeitada pelo usuário: controles internos ainda usavam o desenho anterior e havia uma faixa de pixels vazando entre sidebar e conteúdo. A validação inicial não detectou/tratou adequadamente esses defeitos; não representa aceitação visual.

## Causa e mudança

- O `HStack` continha um separador de 0,5 pt como filho independente, preenchido por `Editorial.rule`, que tem alpha baixo. Não havia fundo opaco nessa faixa: pixels do app subjacente apareciam diretamente. Removida a largura de layout; a linha agora é um overlay de 1 pt sobre o fundo opaco do conteúdo. Sidebar e conteúdo se encostam em coordenada inteira, preservando o material da sidebar.
- `GlassFormRow` ainda desenhava retângulos de raio 4 com borda de 1 pt dentro dos grupos de Settings. Substituído apenas nesta tela por linhas sem caixa e separadores sutis.
- Botões de sair, selecionar lista, cancelar, conectar, salvar chaves e verificar runtime passam a usar os estilos nativos glass/glassProminent em cápsula. Nenhum botão interno permanece como link de texto solto.
- Menus de frequência/provedor/mapeamento Done usam controles glass; modelos de IA usam grupos de seleção nativos. Campos, tipografia, estados de erro e cartões locais foram alinhados.
- Não alterados componentes compartilhados, materiais globais, serviços, credenciais, lógica de sync ou outras telas. Os callbacks de preferências, conexão/desconexão, seleção de lista, Keychain e mapeamento continuam presentes.

## Evidências

- `swift build`: passou; `/tmp/apollo-settings-internals-debug.log`.
- `swift test`: exit 0; log `/tmp/apollo-settings-internals-tests.log`.
- Verificação da quantidade de chamadas dos setters, auth e Keychain antes/depois: idêntica; inspeção das closures confirmou preservação dos argumentos. Seleção de modelos continua gravando a mesma chave de UserDefaults e OpenAI continua chamando `setBackend(.openai)`.
- Release e inspeção visual: pendentes ao início deste registro; resultado final abaixo.

## Continuidade

Handoff local pendente de ingestão no Segundo Cérebro. A nova tentativa de `buscar_memoria` retornou erro; ferramentas de report/resolução continuam indisponíveis. Não foi declarada gravação remota.

## Resultado final

- Release passou; assinatura Developer ID validada por `codesign --verify --deep --strict`, com identidade DEV isolada. Log: `/tmp/apollo-settings-internals-release.log`.
- XCTest: 249 testes, 4 pulados, 0 falhas; Swift Testing: mais 13 testes aprovados.
- Inspeção da build final no DEV escuro: divisória contínua sem os traços coloridos anteriormente visíveis; linhas ClickUp sem caixas aninhadas; Sair/Selecionar e frequência em cápsulas; menu de frequência com os cinco valores corretos e checkmark na preferência atual; Done expandido com os dez status e novos menus. Nenhuma preferência ou destino foi alterado nessa inspeção.
- A captura do menu de frequência foi cancelada pela ação nativa `Cancel` e o painel permaneceu aberto. Ao passar para IA, a ferramenta de UI informou alteração concorrente pelo usuário e bloqueou novas ações; a inspeção adicional de IA/claro nesta revisão não foi concluída. Os controles dessas áreas foram compilados/testados, mas não são declarados visualmente conferidos nesta revisão.
- Escopo permanece local em `SettingsView.swift`; nenhuma publicação/merge ou modificação da produção.
