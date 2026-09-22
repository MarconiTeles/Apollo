# Filtro Minhas tarefas e botão + Tarefa

Pedido explícito do usuário em 22/09/2026: adicionar à versão atual a implementação anterior do filtro Minhas tarefas e da realocação do botão de nova tarefa.

Base desta alteração: `ba851db`, Apollo 2.0.0 (98), já contendo as correções dos anexos e das animações de popup.

Fonte recuperada e conferida no Git: `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-dev-01`, commit `4d5880c865828d3bfeef82e8f1424c7ceff8fb34`. Somente o delta dos controles foi portado:

- `+ Tarefa` usa o mesmo estilo de `+ Evento`, imediatamente ao seu lado, mantendo a ação e a captura de origem do formulário.
- `Minhas tarefas` ocupa a direita da toolbar em Lista e Quadro. Usa o usuário conectado no filtro de responsáveis existente, mantendo os demais filtros. Fica desabilitado sem usuário conectado e limpa o filtro anterior ao trocar de usuário.
- `MyTasksFilterToggle.swift`, `TaskFilters.swift` e `TaskFiltersTests.swift` são byte a byte iguais à versão recuperada. A alteração de `ContentView` está restrita à toolbar e preserva os popups corrigidos anteriormente.

A suíte executou 201 testes: 197 aprovados, quatro externos pulados, zero falhas. Os dois testes recuperados cobrem a combinação com outros filtros e a ausência de usuário conectado. Não houve chamadas de publicação de anexos ou comentários durante os testes.

Compilação Release universal concluída para arm64 e x86_64. Assinatura Developer ID com timestamp e entitlements verificados; `codesign --verify --deep --strict` passou. A build local foi reaberta. A captura da janela real `toolbar-controls.png` confirmou os dois controles, com + Tarefa ao lado de + Evento e Minhas tarefas à direita; a captura foi feita durante o carregamento inicial e não representa teste interativo do filtro. Hashes registrados em `toolbar-build-audit.json`.

Continuidade registrada neste relatório local, pendente de ingestão: o MCP Segundo Cérebro retornou erro em `buscar_memoria` e não expôs as operações de resolução/registro. Proveniência: sessão atual, Git dos dois checkouts e resultados locais de testes/build.
