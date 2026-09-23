# Painel lateral escuro e alinhamento dos traffic lights

Base `c9cbc8b`, checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`, branch `codex/apollo-2.0.0`.

## Feito

- Material lateral: tintura preta com opacidade 0.6 no glassEffect, somente `majorVersion == 27` e `colorScheme == .dark`. Fallbacks sólido/vibrancy recebem a mesma camada preta apenas no fundo. Tema claro e demais versões seguem o caminho anterior. Raio 12 no macOS 27, texto, ícones, seleção, padding e sombra preservados. O valor 60% é a opacidade da tintura nativa; a composição Liquid Glass varia conforme conteúdo/estado da janela.
- Traffic lights: botões existentes de `NSWindow.standardWindowButton` reposicionados com 30 pontos desde a janela, equivalentes a 20 pontos desde o painel inset em 10. Margem superior igual à esquerda. Usa a geometria de alinhamento nativa; não substitui/desenha botões, nem muda targets/actions, tamanho ou espaçamento entre eles. Gate somente macOS 27. Reaplica após resize, ativação e retorno da minimização.

## Conferência

Sonda do helper real confirmou insets visíveis 30/30, idempotência e dimensões nativas preservadas após redimensionamento. `traffic-lights-insets-probe.log` e `traffic-lights-aligned-probe.png`.

Sonda do modificador real do material (extraído sem alterações), com compatibilidade SDK 14 como o produto, inspecionada lado a lado: `sidebar-dark-material-comparison.png`. Somente o fundo recebe a tintura; o conteúdo da sonda é ilustrativo, não a lateral autenticada.

## Pendência explícita: tamanho/textura modernos dos botões

O pedido de tamanho/textura nativos atuais do macOS 27 ainda NÃO foi entregue. Dois executáveis mínimos com a mesma configuração de janela confirmaram diferença por compatibilidade de link: SDK 27 gera controles 14x14, espaçamento 23 e textura moderna; compatibilidade SDK 14, usada no Apollo, gera frames 14x16, espaçamento 20 e desenho antigo. `traffic-lights-sdk27-reference.png` / `traffic-lights-sdk14-reference.png`.

`prefersCompactControlSizeMetrics = false`, appearance explícita e sizeToFit não ativaram isoladamente o desenho moderno na sonda compatível. Nenhuma dessas tentativas entrou no produto. Não foi alterada a compatibilidade global porque o usuário proibiu mudanças visuais fora do escopo; isso também altera controles SwiftUI já aprovados, como o switch. Não foram inseridos desenhos imitados nem controles externos. Próximo passo pendente: uma via nativa isolada comprovada, ou revisão explicitamente ampliada da compatibilidade visual.

Documentação consultada: https://developer.apple.com/documentation/appkit/nswindow/standardwindowbutton(_:) e https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass .

## Entrega e continuidade

Build `./build.sh release` concluído; assinatura profunda/estrita e entitlements aprovados; diff sem erros de whitespace. Janela autenticada reaberta (PID 98907) e inspecionada em `sidebar-dark-traffic-lights-final-window.png`: fundo lateral escurecido, textos/ícones/seleções preservados e controles alinhados com APOLLO. Tamanho/textura modernos permanecem pendentes conforme acima. Log: `build-sidebar-dark-traffic-lights.log`. Sem alteração de release/appcast/artefatos públicos ou da instalação estável. Session_report local pendente de ingestão: Segundo Cérebro indisponível nesta sessão.
