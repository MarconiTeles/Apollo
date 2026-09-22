# Apollo 2.0.0 (98) — integração do PR #1

Ajustes posteriores solicitados pelo usuário: [tamanho de Anexar, diálogo opaco e arrasto sem expansão](UI_ADJUSTMENTS_2026-09-22.md). As auditorias abaixo são o retrato do merge anterior a esses ajustes.

Movimento posterior dos popups: [entrada por baixo e saída para baixo](POPUP_MOTION_2026-09-22.md), conforme pedido do usuário.

Controles adicionados posteriormente por solicitação explícita: [Minhas tarefas e + Tarefa na toolbar](TOOLBAR_CONTROLS_2026-09-22.md).

Ajuste visual posterior do filtro: [cápsula de ação azul e switch azul claro](TOGGLE_MATERIAL_2026-09-22.md).

Publicação autorizada pelo usuário: [release 2.0.0](RELEASE_2.0.0_2026-09-22.md).

## Contrato do merge inicial

Base exclusiva: **Apollo estável 1.9.9 (97)**, commit `dcf22830944bbe93f6787a08eff3c90077b4d2d8`. O aplicativo instalado também foi conferido como 1.9.9 (97). No merge inicial, nenhum código ou controle de DEV-01 foi incorporado. Os controles de toolbar foram portados posteriormente por solicitação explícita, conforme o relatório acima.

PR de origem: https://github.com/MarconiTeles/Apollo/pull/1, head original `db87ba582a3d31ff72602c731f4b5436267f9d29`. A branch main anterior recebia o feed de distribuição; a integração incorpora o código da estável e os anexos em lote na main, preservando o feed público existente.

A instrução final preserva **todas as mudanças visuais originais do PR do Gabriel**. Somente as alterações visuais acrescentadas durante esta revisão foram retiradas. Os botões, glow, avisos e comportamento visual durante arrasto permanecem como no PR original. Naquela integração, nenhuma toolbar ou controle de DEV foi incorporado.

## Correções de integração

- Nomes ambíguos exigem escolha; não são enviados implicitamente a todas as tarefas.
- Remover uma tarefa de destino mantém o arquivo pendente, mesmo quando resta somente uma tarefa.
- Retry mantém o mesmo lote e seu registro de publicações. Uma falha parcial ou do manifesto não recria anexos já publicados; tarefas concluídas são preservadas.
- Projeções capturam todos os destinos antes de aguardar rede/disco. Respostas antigas não sobrescrevem a configuração mais recente.
- Remover todos os arquivos limpa o plano; não permanece um envio antigo habilitado.
- Envio simultâneo e lotes pendentes de outra operação são protegidos. Descartar o lote não apaga o preparo de outra operação.
- Substituição e adição no mesmo drop usam um plano único. Arquivos com alvo duplicado continuam representados como adições.
- O progresso de tarefas concluídas permanece visível após o store liberar seu estado temporário.
- A composição mantém a correção para clipes mudos. Os testes adicionais decodificam o áudio exportado e verificam sua posição na linha do tempo.

O script de build universal passou a consultar `--show-bin-path` e guardar cada fatia antes de compilar a seguinte: o SwiftPM atual reutiliza o diretório de produtos entre arquiteturas, quebrando os caminhos fixos anteriores.

## Evidência

`pr-visual-audit.json` registra SHA-256 e comparação byte a byte de **81 de 84 arquivos de views idênticos ao PR original**. As três views restantes têm somente correções de estado, ações, contagem e proteção do envio, revisadas no diff. O renderer compartilhado de cápsulas e avisos permanece byte a byte idêntico ao PR. Esta auditoria de código não equivale a uma aprovação visual do usuário.

A suíte de origem passou com 182 testes, quatro externos pulados. Novos testes de roteamento falharam antes da correção. As suítes finais Debug e Release passaram, cada uma com **199 testes: 195 aprovados, quatro externos pulados, zero falhas**. Os quatro testes dependem de `REVIEW_E2E=1` e gravam sessões/comentários no backend; não foram executados. Os testes de retry usam falhas controladas no limite do motor, sem publicar anexos ClickUp.

O bundle `build/Apollo.app` é **2.0.0 (98)**. Apollo e o helper Apollo Review contêm arm64 e x86_64, com mínimo macOS 14.0. A assinatura Developer ID, timestamp e entitlements foram verificados por `codesign --verify --deep --strict`; hashes estão em `build-audit.json`. O serviço de timestamp da Apple falhou intermitentemente: a compilação e montagem concluíram, e a assinatura foi repetida por componente com os mesmos parâmetros até concluir. Timestamp e hardened runtime permaneceram habilitados. O pacote não foi notarizado, instalado nem publicado.

Os logs de testes/build e o host temporário de inspeção estão somente no checkout local, fora da alteração de produto. As imagens do host anterior foram retiradas da evidência de aparência final: não representam a versão final e não aprovam mudanças estéticas. O host foi fechado e seu entrypoint removido do aplicativo.

Não houve alteração de credenciais, instalação sobre Apollo/DEV, publicação de feed ou envio de comentários de teste a clientes. `GoogleAuthSecrets.swift` usa o arquivo de configuração existente por vínculo ignorado pelo Git; nenhum segredo foi copiado para este relatório ou para o commit.

## Continuidade

Proveniência: session_report desta revisão, inspeção Git, saídas dos testes e auditoria estática. Segundo Cérebro indisponível (`buscar_memoria` retornou erro; `resolver_projeto` e `registrar_report` não foram expostos). Este relatório é o handoff local, pendente de ingestão.
