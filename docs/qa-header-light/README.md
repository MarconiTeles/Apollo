# Header claro — 23/09/2026

Checkout: `/Users/marconi/.t3/worktrees/t3/t3code-83fd403d`
Branch: `t3code/macos27-sidebar-design`; base `bca0f3b`.

## Contrato confirmado pelo usuário

O fundo do header claro deve usar o **background inteiro da sidebar**, e não o vidro dos controles/seleção. A aparência sem foco é a referência. O escuro já foi aprovado e não deve mudar.

## Causa e correção

`NSGlassEffectView.style = .regular` sozinho cria a receita dos controles. Identificar apenas a classe da view foi insuficiente e levou a tentativas rejeitadas. O filtro RGB anterior (`gain: 0.4`, `bias: 0.6`) também alterava o material.

A inspeção de um `NavigationSplitView` nativo neste macOS mostrou:

| Superfície | Classe | `_variant` | `_adaptiveAppearance` |
| --- | --- | --- | --- |
| Background da sidebar, sob `_NSSplitViewItemViewWrapper` | NSGlassEffectView | 17 | 1 |
| Platter de botão da toolbar | NSGlassEffectView | 0 | 2 |

Evidência: `native-sidebar-hierarchy.txt`, produzida por `inspect-native-sidebar.swift`. O programa inspeciona uma janela de diagnóstico não exibida; não acessa dados do usuário.

O material claro usa agora a receita 17/1, sem filtro RGB, e `_subduedState = 1` para manter a aparência atenuada. A primeira implementação dessa receita ainda mostrou refração na borda superior e foi rejeitada pelo usuário (captura de 19:25:34). O fundo agora se estende 64 pt além de cada borda, com recorte no tamanho do header: o perímetro refrativo fica fora do recorte, preservando o interior do material. A view decorativa continua transparente a cliques e scroll. O ramo escuro foi comparado textualmente com HEAD e permanece byte a byte igual.

## Verificação

- Build Release de `Apollo DEV Sidebar 27.app` concluído; assinatura Developer ID e `codesign --verify --deep --strict` passaram.
- Manifesto: `build/dev-sidebar27/DEV-sidebar27-manifest.final.json`.
- Log de build: `/tmp/apollo-header-white-blur-build.log`.
- Conferência visual da base no app: Quadro, conteúdo rolando sob o header, foco/sem foco e Tarefas. Após o refinamento de blur/cor, nova conferência em Tarefas com a lista rolada.
- Capturas da base: `after-active.png`, `after-inactive.png` e `tasks.png`. Captura do refinamento: `tasks-white-reduced-blur.png`.
- A alternância normal de aparência dos botões foi preservada. A receita 17 sozinha não removia a refração de borda; o recorte do interior é necessário para a superfície plana. Não se afirma igualdade de todos os pixels: controles e conteúdo amostrado pelo material são dinâmicos.
- DEV aberto com `--board-fixtures=169 --route=tasks --appearance=light`; dados de teste offline. Não houve publicação, merge ou alteração do app de produção.

## Limites e continuidade

A receita exata usa propriedades internas do AppKit e parâmetros do filtro de backdrop, verificados no macOS 27 instalado. Elas não são API pública e exigem revalidação em outra versão do sistema; macOS 26 não foi validado nesta sessão. O usuário aprovou a base sem refração às 19:30:29 ("Ok, agora falta diminuir o blur e deixar mais branco"). O refinamento posterior de blur/cor ainda não foi aprovado pelo usuário.

Registro local pendente de ingestão: os métodos `resolver_projeto` e `registrar_report` do Segundo Cérebro não estão expostos nesta sessão. A sessão anterior foi lida pelo MCP (`ses_01a0d04d059b7db694efdb93d7440e8f`), mas está vinculada a `apollo-review`; o Git deste checkout aponta para `MarconiTeles/Apollo`. Não foi feita gravação sob uma associação presumida.

## Refinamento após aprovação da base

Mantido o mesmo material e recorte. Os parâmetros `glassBackground.inputBlurRadius` e `inputBlurFillBlurRadius` são escalados por 0.4 a partir do valor nativo, de forma idempotente. A captura do backdrop passa de escala 0.5 para 1, evitando suavização adicional por redução de resolução. Véu branco de 35% aplicado apenas ao fundo claro.

Uma inspeção isolada compilando o componente exato leu raio 8, raio do preenchimento 3.2 e escala 1. Isso verifica os parâmetros do componente; a verificação visual do app continua separada. Evidência: `blur-verification.txt`.

## Pareamento com o modo escuro

O usuário apontou que o primeiro refinamento ainda tinha mais blur que o escuro. A inspeção da implementação escura, com estado ativo forçado somente no programa de diagnóstico, confirmou `gaussianBlur.inputRadius = 4.8` (30 × 0.16), captura em escala 1. O claro estava em raio 8; foi reduzido para 4.8 (20 × 0.24), com preenchimento proporcional em 1.92 e escala 1. Véu branco de 35%, receita 17/1, estado atenuado e recorte de 64 pt preservados. O ramo escuro permanece idêntico ao HEAD.

Os filtros dos dois materiais são distintos; o pareamento numérico não é uma afirmação de igualdade perceptual entre shaders. A aceitação visual final cabe ao usuário.

Build deste ajuste: `/tmp/apollo-header-paired-blur-build.log`.

## Redução adicional de 35%

Pedido seguinte do usuário: diminuir o blur em 35%. Aplicado somente ao header claro: multiplicador 0.24 × 0.65 = 0.156, raio 4.8 → 3.12 e preenchimento 1.92 → 1.248. Branco, material, recorte e modo escuro preservados. Build: `/tmp/apollo-header-blur-minus35-build.log`.

## Redução adicional de 50%

Pedido seguinte do usuário: reduzir o blur atual em 50%. Multiplicador do header claro: 0.156 × 0.5 = 0.078; raio 3.12 → 1.56, preenchimento 1.248 → 0.624. Branco, material, recorte e modo escuro preservados. Build: `/tmp/apollo-header-blur-minus50-build.log`.

## Redução de opacidade de 40%

Pedido seguinte do usuário: diminuir a opacidade em 40%. Reduzido o véu branco do header claro de 0.35 para 0.21 (0.35 × 0.6). Material nativo, blur atual (raio 1.56), recorte e modo escuro preservados. Build: `/tmp/apollo-header-opacity-minus40-build.log`.

## Material compartilhado entre headers

O usuário pediu que todos os headers usem a definição em ajuste. Auditoria: Inbox (`ContentView`), Tarefas (`EditorialMyTasksView`), Quadro (`EditorialBoardView`) e Comentários (`AssignedCommentsView`) já usam `finderHeaderMaterial` → `AppHeaderMaterial`. O seletor de listas também usa `AppHeaderMaterial`.

Corrigidos os caminhos restantes com materiais de header independentes: `OfficialHeaderMaterial` agora encaminha o modo claro para `AppHeaderMaterial` (detalhes de tarefa/evento, notificações e demais consumidores desse componente). Headers de mídia, mídia em lote e revisão agora usam o mesmo caminho no claro. Cada ramo escuro mantém sua implementação anterior. Parâmetros centrais atuais: blur × 0.078 (raio 1.56), véu branco 0.21.

Build conjunto: `/tmp/apollo-shared-headers-build.log`. Popups dependentes de dados não tiveram todos os fluxos percorridos visualmente; a cobertura desses headers foi verificada pelas chamadas de código e pelo build.

## Bug de reconstrução do material e interação sob o header

Relato: alternar páginas às vezes muda o material; mover a janela entre telas o restaura. Gravação fornecida pelo usuário (`Gravação de Tela 2026-09-23 às 20.07.25.mov`) também mostra hover em card sob o header do Quadro.

Diagnóstico verificado em teste isolado: ao reaplicar raio 20/preenchimento 8/escala 0.5 na camada nativa, hooks de view (`layout`, `updateLayer`, `viewWillDraw`) não bastaram para restaurar o efeito; permaneceu no valor nativo até a view ser recriada. Observação KVO de `CALayer.filters`/`sublayers` detecta a alteração e restaura raio 1.56, preenchimento 0.624 e escala 1 no próximo ciclo, sem troca de página. Os alvos agora são absolutos, independentes do primeiro raio capturado. `updateNSView`, mudança de aparência/backing e remontagem reaplicam a receita. Passagens são coalescidas e alterações só acontecem quando o valor diverge; não há timer.

Interação: o material é decorativo e não fazia bloqueio de input; a viewport nativa e tracking areas ainda incluíam cards sob o header. Quadro e Tarefas agora excluem a faixa do header de hit-testing e hover. O conteúdo continua desenhando atrás do material. Teste `BoardAppKitViewportTests/testHeaderRejectsHitTestingButKeepsContentInteractive` cobre card parcialmente oculto, parte exposta e mudança da altura do header.

A reprodução isolada é da reconfiguração do backdrop; não equivale a reproduzir fisicamente a troca entre os monitores do usuário.

## Ajuste após correção de estabilidade

O usuário respondeu “ok” e pediu +35% de blur e +20% de opacidade. Aplicado na definição central dos headers claros: raio 1.56 × 1.35 = 2.106, preenchimento 0.624 × 1.35 = 0.8424; véu branco 0.21 × 1.20 = 0.252. A observação do backdrop e a exclusão de interação sob o header foram preservadas.

Validação anterior da correção: 9 testes de `BoardAppKitViewportTests` e 10 de `MyTasksScrollTests` passaram; navegação Tarefas → Quadro observada no DEV. Não houve teste físico entre monitores. Build do novo ajuste: `/tmp/apollo-header-blur35-opacity20-build.log`.

## Novo aumento de blur de 35%

Aplicado ao material compartilhado dos headers claros: raio 2.106 × 1.35 = 2.8431; preenchimento 0.8424 × 1.35 = 1.13724. Opacidade branca preservada em 0.252, com as correções de estabilidade e interação mantidas. Build: `/tmp/apollo-header-blur-plus35-build.log`.

## Aumento adicional de blur de 40%

Aplicado ao material compartilhado dos headers claros: raio 2.8431 × 1.40 = 3.98034; preenchimento 1.13724 × 1.40 = 1.592136. Opacidade branca mantida em 0.252. Build: `/tmp/apollo-header-blur-plus40-build.log`.

## Header escuro ao perder foco

Novo relato do usuário: header escuro fica opaco quando a janela perde foco. A receita preservada anteriormente usava `.followsWindowActiveState`. Comparação nativa em janela sem foco: esse estado remove o backdrop gaussiano; `.active` mantém raio 4.8 e escala 1. Ajustados `AppHeaderMaterial` e o ramo escuro de `OfficialHeaderMaterial` para `.active`, preservando seus materiais, tintas e blur. Esta alteração do comportamento escuro foi solicitada explicitamente agora.

Evidência: `dark-focus-verification.txt`. Build: `/tmp/apollo-dark-header-focus-build.log`.
