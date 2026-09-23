# Aplicação do plano — 23/09/2026

Branch: `t3code/diagnose-apollo-scroll-performance`, base `63d54f7`.

## Implementado

- Header: superfície fosca `Editorial.paper` (escuro `#141415`, claro `#F5F5F6`), derivada da cor que já dominava o antigo véu de 85%. Elimina o backdrop customizado apenas de `finderHeaderMaterial`. Mesmos tamanhos, extensões, bordas, offsets, preferência de posição e controles. `OfficialHeaderMaterial` dos popups e todos os demais estilos foram preservados.
- Reviews: igualdade por conteúdo completo, incluindo identidade/versão, para evitar publicação e escrita repetidas. Mudança legítima com timestamp igual continua aplicada. Aliases e latches mantêm sua semântica.
- Persistência: snapshots de valor imutáveis, fila serial, coalescência de 75 ms, ordenação e JSON fora do MainActor. Conclusão crítica e encerramento drenam a fila. Escritas antigas não podem ressuscitar uma pendência concluída.
- Entrada reproduzível de build/execução em `script/build_and_run.sh`; build local em `build/Apollo.app`, assinada e aberta. Nenhuma instalação, publicação ou alteração de release/feed.

## Verificação

- `swift test -c release`: 205 testes, 4 ignorados por exigir `REVIEW_E2E=1`, zero falhas; portanto 201 passaram. Todos os 40 testes de TaskReviewUpdateTests passaram.
- Testes novos: 50 reaplicações idênticas através de três caminhos não publicam nem gravam novamente; mudança de conteúdo com timestamp igual persiste; lote preserva a última revisão; relaunch lê o estado correto; conclusão e quit drenam sem permitir restauração de estado antigo; gravação verificada fora da main thread.
- Build Release, codesign deep/strict e `git diff --check` passaram. Logs completos em `build/scroll-tests.log` e `build/scroll-final-build.log`.
- Lista e quadro inspecionados na build local com 169 tarefas reais. A inspeção observou o material fosco, com controles/alinhamentos preservados. Não houve alteração de tarefas para testar drag/drop ou aprovação.

## Limites da medição final

As séries de `fix-metrics.json` NÃO demonstram queda consistente de CPU/GPU. CPU média do Apollo: lista 21,7% antes / 41,5% depois; quadro 58,1% / 54,2%. GPU global: lista 3,4% / 66,7%; quadro 70,2% / 69,4%. São séries curtas por automação, com quantidade de comandos diferente, linhas visíveis diferentes na lista e atividade do sistema não controlada. Não tratá-las como prova de ganho, nem como benchmark isolado de regressão. Elas impedem declarar eliminação do stuttering.

Uma primeira tentativa `list-after-fix` foi descartada porque havia duas instâncias de Apollo; o comando top rejeitou os dois PIDs. Ela não participa dos resultados. Em seguida a original foi encerrada, a build local selecionada explicitamente e `list-after-fix-valid` / `board-after-fix` mediram exclusivamente o PID 61494.

A captura Animation Hitches durante scroll concluiu e foi exportada após uma finalização demorada. O erro inicial `Document Missing Template Error` ocorreu ao tentar exportar antes da conclusão; não foi uma falha final. Trace: `build/scroll-fixed-board.trace`; tabelas exportadas: `build/scroll-board-hitches.xml` e `build/scroll-board-frames.xml`. A tabela registra 587 hitches atribuídos ao DayPanel no ensaio de 15 segundos, 3 acima de 50 ms. São eventos de hitch sob instrumentação, não FPS nem duração de cada frame. **Persistem hitches no quadro; não considerar o problema de fluidez integralmente resolvido.**

Estado: correções implementadas e testes funcionais aprovados; desempenho final ainda não confirmado. Qualquer investigação restante deve respeitar a restrição de não modificar aparência fora do material do header.

## Continuidade

Segundo Cérebro: nova tentativa de buscar_memoria também falhou e as ferramentas de resolver projeto/report não estão expostas. Este é o handoff local, pendente de ingestão; não foi afirmada gravação no MCP.
