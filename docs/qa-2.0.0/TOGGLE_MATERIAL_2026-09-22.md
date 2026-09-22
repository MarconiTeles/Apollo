# Material da cápsula e cor do switch Minhas tarefas

Pedido explícito do usuário: a cápsula deve usar o material do antigo botão Nova tarefa; o switch ligado deve ser verde para não se confundir com o azul da cápsula.

Base: `f4c48d2`, Apollo 2.0.0 (98).

Alteração restrita a `MyTasksFilterToggle.swift`:

- Mesma receita do botão anterior conferida em `ba851db:ContentView.swift`: `liquidGlassCapsule(tint: Editorial.accent, tintOpacity: 0.9)` e `accentGlow()`.
- Texto branco para manter o contraste dessa superfície, como no botão anterior.
- `.tint(.green)` no switch nativo, separada da cor explícita da cápsula. A API foi conferida no SDK local e na documentação oficial: https://developer.apple.com/documentation/swiftui/view/tint(_:).
- Nenhuma alteração de filtro, ação, posição, tamanho ou estado de autenticação.

Esta etapa é somente visual. Não foram criados testes que repetem constantes de estilo; a validação usa build Release universal e verificação da assinatura. A renderização do switch ligado requer conferência na janela ativa; uma captura desligada não prova sua cor ativa.

Continuidade: relatório local pendente de ingestão. O MCP Segundo Cérebro retornou erro em `buscar_memoria` e não expôs resolver/registrar. Proveniência: pedido e captura do usuário, diff Git e build desta sessão.

Validação concluída: build Release universal (arm64 e x86_64), Apollo 2.0.0 (98), assinatura Developer ID CU544M36UD com timestamp e `codesign --verify --deep --strict` aprovado. Aplicativo reaberto a partir de `apollo-2.0.0/build/Apollo.app`, PID 83730. Captura real `toggle-material.png` confirma cápsula azul com brilho e texto branco; o switch estava desligado. Detalhes e hashes em `toggle-material-build-audit.json`.

## Revisão solicitada: azul bem claro

O usuário rejeitou o verde e pediu azul bem claro no fundo do switch. Substituída somente a tint por `#BFE9FF` em `MyTasksFilterToggle.swift`, mantendo o material azul da cápsula e o comportamento do filtro. Base: `7d50c7d`. Build e assinatura serão registrados em `toggle-light-blue-build-audit.json`. Segundo Cérebro voltou a retornar erro; continuidade local pendente de ingestão.

Build universal concluída. O serviço de timestamp da Apple falhou na primeira assinatura; repetir somente a assinatura com os mesmos parâmetros passou, incluindo entitlements e verificação profunda. Build reaberta. A cor ligada ainda não foi conferida visualmente nesta revisão.
