# Traffic lights nativos do macOS 27: diagnóstico e limite de escopo

Base local 2cb23ec, branch codex/apollo-2.0.0, checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`.

O pedido de tamanho/textura modernos ainda não foi corrigido no app. A implementação existente apenas reposiciona os standardWindowButton do AppKit. Confirmação atual por `xcrun vtool -show-build build/Apollo.app/Contents/MacOS/DayPanel`: deployment 14.0 e SDK de link 14.0, embora o compilador instalado seja Swift 6.4/Xcode 27. O SDK de link seleciona comportamento visual legado do processo.

## Evidência nova

Dois executáveis mínimos idênticos, ambos deployment 14.0, comparados no mesmo macOS 27. SDK 14 explicitado com `-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 14.0`; SDK atual por link padrão.

- SDK 14: standardWindowButton de instância e factory retornam frames 14x16, desenho plano, distância 20 entre origens dos controles da janela.
- SDK 27: controles regulares 14x14, textura nativa atual, distância 23 entre origens dos controles da janela.
- Factory, controlSize large/small, bezelStyle glass/textured e isBordered false não ativam o estilo moderno sob SDK 14. Testes isolados, nenhuma dessas mutações entrou no produto.
- `prefersCompactControlSizeMetrics = false` em toda a árvore do frame/titlebar, seguido de layout e sizeToFit, também mantém 14x16/desenho antigo. A raiz NSThemeFrame inicialmente reporta true, mas desligá-la não troca a receita de desenho.
- Comparação adicional usando o arquivo real MyTasksFilterToggle.swift e fixtures externas: SDK 27 altera também o desenho do switch, campo de texto e botão padrão, inclusive com `prefersCompactControlSizeMetrics = true` no NSHostingView. Portanto uma migração global silenciosa viola o pedido explícito de não mudar o restante do visual. Capturas: traffic-lights-compat-sdk14.png / traffic-lights-compat-sdk27.png.

Referências oficiais consultadas: https://developer.apple.com/documentation/appkit/nswindow/standardwindowbutton(_:for:), https://developer.apple.com/videos/play/wwdc2025/310/ e https://developer.apple.com/videos/play/wwdc2026/289/. Nenhuma API pública de adoção por traffic light foi encontrada nas headers/documentação consultadas; isso é limite da investigação, não prova de inexistência absoluta.

## Estado e próximo passo

Nenhum código de produto alterado nesta investigação; nenhuma build com SDK global diferente instalada, aberta como Apollo ou publicada. Os experimentos foram janelas isoladas encerradas automaticamente. Opção comprovada: migrar o link para SDK atual e revisar o restante dos controles afetados; requer resolver com o usuário o conflito com a restrição de mudanças visuais. Não aplicar imitação gráfica nem API privada como substituto silencioso.

A sombra solicitada anteriormente está entregue na build local e commit 2cb23ec, integrada na main local. Release pública e /Applications/Apollo.app preservados.

Session_report local pendente de ingestão: Segundo Cérebro indisponível (buscar_memoria retornou erro; ferramentas de gravação não expostas).
