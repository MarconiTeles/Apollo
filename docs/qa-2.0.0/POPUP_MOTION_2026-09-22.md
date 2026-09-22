# Movimento dos popups do fluxo de anexos

Base: `d6d8b37`, Apollo 2.0.0 (98). Pedido explícito: todas as janelas do fluxo do PR devem subir a partir de baixo na entrada e descer na saída, como o popup de tarefas.

## Correção

As folhas nativas `.sheet` dos anexos individuais, anexos em lote e seletor de reviews foram substituídas por apresentação na camada da janela, mantendo os cartões e suas dimensões. O cartão de adicionar/substituir passou a usar a mesma transição. As etapas internas (classificação, corte, substituição, envio) continuam dentro do mesmo popup.

`TaskMediaPopupMotion` replica os parâmetros da referência `TaskDetailOverlay` / `AppState.closeTaskDetail`: deslocamento positivo de `max(alturaDaJanela, 900)` até zero na entrada, mola de 0,34 s com amortecimento 0,86; na saída, zero até o mesmo deslocamento positivo, ease-in de 0,30 s. Nenhuma nova folha nativa decide a direção desses popups.

O fechamento por botões e Escape usa callbacks explícitos. Escape continua bloqueado durante o envio em lote. Cliques fora não descartam a operação. O backdrop mantém a entrega de arquivos ao inbox do lote durante a animação. O retorno da substituição para a pergunta aguarda a saída do cartão anterior.

## Validação

A suíte Debug executou 199 testes: 195 aprovados, quatro E2E externos pulados, zero falhas. Não houve gravação de anexos ou comentários de teste no backend. A compilação universal Release concluiu para arm64 e x86_64. Assinatura Developer ID com timestamp, entitlements e `codesign --verify --deep --strict` aprovados. Os hashes dos fontes e do executável estão em `popup-motion-build-audit.json`.

A automação de acessibilidade do macOS está desabilitada nesta sessão. Código, testes e build não equivalem a inspeção visual quadro a quadro; a build final é aberta para conferência do usuário.

Continuidade: relatório local, pendente de ingestão no Segundo Cérebro; `buscar_memoria` retornou erro e as ferramentas de registro não estão disponíveis. Fontes e testes desta sessão são a proveniência.
