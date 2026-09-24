# Agenda em React — build isolada (24/09/2026)

Handoff local, PENDENTE DE INGESTÃO no Segundo Cérebro (`resolver_projeto` falhou).

## O que existe

- Build DEV isolada: `script/build_dev_agenda_react.sh` (`-DAPOLLO_AGENDA_REACT`,
  bundle `com.painellunar.app.dev.agenda-react`, saída `build/dev-agenda-react`).
  Não toca produção, Sparkle nem releases. `--agenda-renderer=native` = A/B no mesmo binário.
- Web: `web/apollo-agenda` (React 19 + Vite, single-file) → `Sources/DayPanel/Resources/ApolloAgenda/index.html`.
- Swift: `Sources/DayPanel/Views/Home/AgendaReact/AgendaReactBody.swift` (host WKWebView,
  payloads, fetch mensal, menu nativo, detalhe, fotos via `apollo-avatar:`).
- Iteração sem recompilar: `npx vite --port 5320` em `web/apollo-agenda` e abrir o app com
  `open -n --env APOLLO_AGENDA_URL=http://localhost:5320/ "<app>" --args --agenda-fixtures=60 --route=today`.

## Paridade medida (fixtures, claro, mesma janela, diff de pixels contra o nativo)

- Geometria de cartões, células, discos e painel: idêntica (bordas nos mesmos pixels).
- Baselines: SwiftUI arredonda a caixa de cada linha e põe a baseline em ponto inteiro;
  o Swift mede cada estilo (`AgendaReactResources.metrics`, `<nome>` e `<nome>-dy`). Deslocamentos verticais: 0px.
- Cantos `.continuous`: curva contínua da Apple em SVG (`lib/squircle.tsx`), dentro do ruído de antialiasing.
- Sombras: SVG `feGaussianBlur` σ = radius (perfil ±1 nível). `filter: drop-shadow` do WebKit recortava de forma instável.
- Restante: antialiasing de texto e 1px horizontal no número do dia da coluna de datas.

## Mudanças pedidas pelo usuário (fora da paridade 1:1)

- Glow do cartão não é mais recortado no topo (o nativo recortava na primeira linha do dia).
- Lista da esquerda: só dias do mês selecionado (mês atual: de hoje ao fim do mês).
- Painel do dia redesenhado: horário, barra de cor, tag de local, "Agora", participantes
  (organizador primeiro com anel de destaque, foto do ClickUp quando houver), tag Meet/Zoom/Entrar.

## Pendências

- FPS com trackpad real NÃO medido: eventos sintéticos de rolagem são bloqueados (sem Acessibilidade).
- Identidade DEV sem contas conectadas; teste com dados reais exige conectar Google/ClickUp nela.
- Commit `f24ecf2` (autor Marconi, 08:44) contém estado intermediário; o trabalho posterior está sem commit.
