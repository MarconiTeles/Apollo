# Remover vídeo — no envio e depois de enviado

Pedido da Joana: com o envio de vários vídeos de uma vez, um vídeo errado entrava sem querer e não havia como tirar, nem na conferência nem depois de publicado.

## Capturas

Telas reais do app (`TaskMediaFlowSheet` e `TaskDetailView`), montadas num teste temporário com `AppState.preview()`, tarefa e arquivos de exemplo, clicando nos botões de verdade. Nenhum upload ao ClickUp.

Antes de enviar:

- `01-conferencia.png`: "x" em cada arquivo; um da Calça entrou por engano.
- `02-removido.png`: depois do "x", "PREPARAR 2 VÍDEOS".
- `03-preparados.png` e `04-envio.png`: "Ajustar vídeos" no pós-preparo e na tela de envio.
- `05-voltou.png`: "Ajustar vídeos" volta com a lista intacta, e o lote pronto é descartado.
- `07-tarefa-com-videos.png` e `08-tarefa-removido.png`: o mesmo numa tarefa que já tem vídeos.

Depois de enviado:

- `12-detalhe.png`: lixeira ao lado do "Substituir" (tarefa espelhando a do print da Joana).
- `13-confirmacao.png`: confirmação. Diz que o arquivo continua no ClickUp.
- `15-janela.png`: "x" em JÁ NESTA TAREFA (HOOKs, BODYs, combinações e diretos).
- `16-confirmacao-hook.png`: tirar um HOOK avisa quantas combinações saem junto.

As capturas 13 e 16 foram feitas com `.alert`. Depois a confirmação passou a usar `.confirmationDialog`, o mesmo padrão de "Excluir evento?", e não foi capturada de novo.

## Validação

- `swift test -Xswiftc -DAPOLLO_TASKS_REACT -Xswiftc -DAPOLLO_AGENDA_REACT -Xswiftc -DAPOLLO_BOARD_REACT --no-parallel`: 274 XCTest (5 pulados, 0 falhas).
- Nas Swift Testing, só `AgendaTimelineTests.renderedCardsPreserveOriginalPositionsAndEmptyDaySpacing` falha na suíte completa. Passa isolado, com e sem esta mudança.
- `TaskMediaRemovalTests` (11) cobre:
  - o que sai do catálogo;
  - a não reimportação como legado;
  - troca de BODY sem ressuscitar combinação;
  - envio preparado antes da remoção (`carryingRemovals`);
  - fonte removida;
  - versão antiga só escondida;
  - manifest antigo decodificando.
- A remoção no ClickUp real não foi exercida: a build de debug precisa do login. O caminho rodou até o upload do manifest, que falhou por falta de token, e a mensagem certa apareceu sem nada apagado.
