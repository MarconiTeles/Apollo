# Correção: luminância do material, sem aumentar sua opacidade

Base `8445c73`, checkout `/Users/marconi/Documents/PROJETOS/AGENTS/Apollo/apollo-2.0.0`, branch `codex/apollo-2.0.0`.

## Pedido e tentativa rejeitada

O usuário pediu reduzir o escurecimento anterior em 35% e corrigiu explicitamente o mecanismo: não aumentar opacidade. A tintura preta de 60% em 8445c73 foi inadequada. A tentativa intermediária com tintura de 39% chegou a compilar, mas não foi aberta nem publicada; foi substituída por esta implementação.

## Implementação final

- Removida a tintura preta e suas overlays de opacidade do fundo lateral.
- Modo escuro somente no macOS major 27: `SidebarLuminanceGlass` usa `NSGlassEffectView.style = .regular` sem tintColor. Uma matriz de cor pública `CIColorMatrix` no contêiner decorativo multiplica somente RGB por 0.61. Alfa identidade `(0,0,0,1)`; sem overlay preto, mudança de opacity ou escala do blur.
- 0.61 é o ganho restante: escurecimento de 0.60 reduzido em 35% = 0.39, ganho = 1 − 0.39. O resultado visual continua sujeito à composição e espaço de cor nativos.
- Texto, ícones e seleções permanecem fora da matriz, na hierarquia SwiftUI existente. Material decorativo retorna nil em hitTest. Raio 12, dimensões, bordas externas, sombra e ações existentes preservados.
- Claro e outras versões do macOS preservam o caminho anterior. Fallbacks sólido/vibrancy usam multiplicação de cor, sem tintura/overlay preto.

## Verificação e evidência

Comparação com faixas coloridas idênticas atrás de três painéis: glassEffect SwiftUI original, NSGlassEffectView sem filtro, e NSGlassEffectView com a matriz final. O segundo preserva a aparência/desfoque do primeiro; o terceiro escurece o material e mantém o desfoque e o conteúdo atrás visível. Textos/ícones permanecem iguais. A captura `sidebar-luminance-final-probe.png` foi aberta e inspecionada. A sonda compila o arquivo real `SidebarLuminanceGlass.swift` com a mesma compatibilidade SDK/deployment 14.0 do produto; estado do cenário isolado e sem dados externos. Script local em `local-tools/sidebar-luminance-native-probe.swift`.

Descartado o candidato SwiftUI colorMultiply aplicado diretamente ao glassEffect: a comparação mostrou alteração do perfil de desfoque. Tentativa com compositingGroup também descartada. Nenhuma foi aberta na build autenticada. A matriz no contêiner AppKit preservou o comportamento óptico observado.

Build final `./build.sh release` concluído, assinatura profunda/estrita e entitlements aprovados, diff sem erros de whitespace. Janela autenticada aberta (PID 6823) e captura `sidebar-luminance-final-window.png` inspecionada: material corrigido e textos/ícones/seleções preservados. Log `build-sidebar-luminance-native.log`. Sem publicação. A pendência anterior de tamanho/textura modernos dos traffic lights continua fora desta alteração.

Session_report local pendente de ingestão: Segundo Cérebro indisponível nesta sessão.
