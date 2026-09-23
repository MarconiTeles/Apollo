# Contraste entre trilho e ponta do switch

Após o usuário apontar que o estado ligado estava claro demais e pedir conferência, o ganho de brilho do controle ligado foi reduzido de 0.4 para 0.22. O accent dinâmico, a mistura com branco, o estado desligado, o controle nativo e a cápsula foram preservados. Base `08e43d2`.

## Conferência visual

Fonte exata de `MyTasksFilterToggle.swift`, compilada no processo de inspeção com compatibilidade SDK/deployment 14.0. Três accents (roxo, azul e verde), ambos os temas e ambos os estados. Todas as capturas foram abertas e inspecionadas: a ponta branca se distingue do trilho ligado; o desligado continua mais escuro. Os quatro controles da sonda são NSSwitch reais com estados `[0,1,0,1]`. Accents alternativos por argumento do processo, sem alterações nas preferências globais.

Evidências locais: `toggle-contrast-refined-purple.png`, `toggle-contrast-refined-blue.png`, `toggle-contrast-refined-green.png`. A sonda usa estado isolado; a janela autenticada da build foi aberta e capturada em `toggle-refined-actual-window.png`: o estado desligado, a lupa e os ícones da lateral foram inspecionados. O estado ligado foi conferido na sonda do componente, não nessa captura da janela autenticada.

A alteração de produto é somente o valor do brilho ligado. Ícones selecionados da lateral, labels/contagens neutros, glow compartilhado e lupa permanecem na implementação previamente conferida.

## Continuidade

Correção local, sem publicação de nova release. Session_report local pendente de ingestão: Segundo Cérebro indisponível nesta sessão. Evidência de build, assinatura e janela final na auditoria correspondente.
