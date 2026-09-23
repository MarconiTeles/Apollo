# Contraste do switch nativo — correção local após 2.0.0

Pedido: ligado com fundo azul bem claro, desligado escuro; formato e comportamento nativos do SwiftUI.

A alteração final em `MyTasksFilterToggle.swift` mantém `Toggle` com `.toggleStyle(.switch)` e a tint azul clara já aprovada. A aparência clara é aplicada somente ao controle para que o trilho desligado fique escuro inclusive no tema escuro. O brilho do controle aumenta 0.4 apenas quando o filtro está ligado, compensando o escurecimento da tint clara observado no renderer nativo usado pela build. A cápsula externa usa os mesmos material, tint, glow e dimensões.

Não há ToggleStyle customizado, máscara, trilho desenhado, botão substituto nem sobreposição no código final. A tentativa intermediária de pintura do trilho foi removida antes da entrega, conforme correção explícita do usuário.

## Evidência

- Diagnóstico visual reproduziu os estados enviados pelo usuário ao compilar com deployment/SDK 14.0, iguais ao executável distribuído. A primeira sonda ligada ao SDK atual desenhava um controle diferente; ela não foi usada como validação final.
- `toggle-native-states.png`: fonte exata de `MyTasksFilterToggle.swift` compilada em processo temporário com estado isolado, em ambos os temas e estados, usando a compatibilidade 14.0. O controle final renderiza o trilho claro ligado e escuro desligado, com thumb, foco e formato nativos.
- A hierarquia AppKit da inspeção contém quatro `NSSwitch` reais, com estados `[0, 1, 0, 1]`, confirmando controles nativos desligado/ligado nos dois temas.
- O processo de inspeção usa stores locais mínimos e não acessa ClickUp. A captura valida o componente; não representa um teste ponta a ponta do filtro autenticado.
- Alteração de produto restrita a dois modificadores de aparência. Binding, ações, autenticação e modelo de filtro permanecem intactos.

## Entrega

Correção local; a release pública 2.0.0 e seus arquivos publicados permanecem identificados pelo commit e hashes originais. Build e assinatura desta correção registrados na auditoria correspondente após compilação.

## Continuidade

Session_report local pendente de ingestão. Segundo Cérebro retornou erro em `buscar_memoria`; operações de registro não expostas. Proveniência: pedido do usuário, diff da fonte, captura do componente nativo e build local.

Build Release local arm64 concluída, assinatura Developer ID e entitlements verificados, aplicativo reaberto. Não foram adicionados testes de constantes visuais. Auditoria: `toggle-native-contrast-build-audit.json`.
