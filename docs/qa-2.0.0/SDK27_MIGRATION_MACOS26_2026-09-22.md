# SDK 27, mínimo macOS 26 e contraste do diálogo

Autorização: usuário aprovou migrar SDK 27 com revisão dos controles afetados e restringiu suporte a macOS 26+. Depois pediu distinguir o fundo/contorno de Adicionar e Substituir no modo claro.

## Implementação

- Package.swift: deployment 26.0, link explícito SDK 27.0. Resolve o binário anteriormente marcado SDK 14 apesar do compilador atual.
- Info.plist: mínimo 26.0; build replica esse mínimo no bundle do helper Review. O helper mantém seu toolchain/link independente; não houve migração de seu código ou SDK.
- build.sh verifica SDK instalado e metadata de cada arquitetura antes de empacotar; release.sh passa a extrair o mínimo do bundle assinado para novos itens do appcast.
- Diálogo: no modo claro, ambos os botões usam preenchimento preto 5,5%; contorno neutro 18% em Substituir e accent 50% em Adicionar. Geometria, ações, hover e modo escuro preservados.
- Sem redesenhar traffic lights: continuam standardWindowButton, com geometria nativa e alinhamento existente.

## Evidência

- Build Release universal concluída: build-sdk27-universal.log. vtool confirma minos 26.0/sdk 27.0 nas slices x86_64 e arm64. Assinatura deep/strict e entitlements aprovados. Info.plist principal e helper mínimo 26.0.
- REVIEW_E2E=0 swift test: 202 testes, 4 ignorados, zero falhas (198 aprovados); tests-sdk27-macos26.log. Inclui preservação de identidade, dimensões, espaçamento, ações e hit targets dos traffic lights em resize repetido. E2Es que escrevem em servidor não executados.
- App real autenticado aberto em macOS 27, screenshot sdk27-production-window.png: textura nativa atual dos traffic lights, header e sidebar.
- Harness offline carrega ApolloRuntime real com fixtures: lista, quadro, filtro Minhas tarefas e abertura de Nova tarefa em escuro; formulário de tarefa/evento e configurações em claro. Capturas sdk27-newtask-click-light.png, sdk27-newevent-light.png, sdk27-settings-light.png. Não foram criadas tarefas/eventos nem feitos uploads reais.
- sdk27-decision-light-final.png: componente real isolado confirma preenchimentos e contornos distinguíveis no claro. Captura externa corrigiu falha de permissão do screencapture iniciado pelo próprio harness; imagens antigas recortadas eram problema da janela do harness e foram substituídas nas verificações finais em claro.
- Sintaxe de scripts e git diff --check aprovados. Gerador do mínimo do appcast verificado sem publicar.

## Limites e continuidade

Executado em macOS 27 Apple Silicon; macOS 26 e Mac Intel não tiveram execução física. Compilação universal não substitui essa verificação. Não há garantia absoluta de ausência de regressões. Nova metadata permite adoção global dos controles nativos, conforme autorização.

Build local atualizada; versão pública, appcast publicado e /Applications/Apollo.app não modificados nesta etapa. Integração na main local após validação.

Session_report pendente de ingestão: Segundo Cérebro retornou erro nesta sessão e não expõe registrar_report. Continuidade preservada neste documento dentro do projeto Apollo, branch codex/apollo-2.0.0, base d41a2c3.
