# Pedido: build com lista em React Native (23/09/2026) — pendente de ingestão no Segundo Cérebro

Estado: não executado. Motivo: projeto é SwiftPM puro (sem .xcodeproj), CocoaPods ausente, lista atual já é NSCollectionView nativa (MyTasksAppKitList.swift + TaskRowCellView.swift, ~5.200 linhas). React Native macOS renderiza nos mesmos NSViews e mantém o material do cabeçalho e o trabalho de reviews na main thread, as duas causas medidas em DIAGNOSTICO.md.
Próximo passo proposto: build A/B com (1) idempotência/lote de reviews e (2) cabeçalho sem backdrop .withinWindow, medida com frame times.
resolver_projeto do MCP retornou erro nesta sessão.
