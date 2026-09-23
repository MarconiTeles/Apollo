# Splash e loading lunares do Apollo (23/09/2026)

> Handoff local: ingestão no Segundo Cérebro pendente. O MCP `segundo-cerebro` falhou em `resolver_projeto` e `registrar_report` durante toda a sessão.

## Decisões do Marconi
- Arquitetura híbrida: a splash é React/WebGL numa `WKWebView` transparente; os skeletons são SwiftUI nativo.
- Mesmo nível de polimento e complexidade da home do Webb, mas com elementos próprios.
- A splash fica no mínimo 3 s e depois espera os dados carregarem.
- Iterações visuais pedidas:
  - sem BETA
  - entrada mais dramática
  - névoa como a do Webb
  - mais camadas em movimento
  - lua mais detalhada e girando
  - só uma parte da lua iluminada, com o resto no tom do cenário e não em preto
  - terminador 30% mais difuso, vertical e levemente curvo (meia lua)
  - linha azul virou barra de loading

## Implementado (worktree `t3code/apollo-lunar-loading-splash`, base `63d54f7`, sem commit)

### Web (`web/apollo-splash`)
- **Stack:** Vite 8, React 19, GSAP 3.15 e WebGL2.
- **Build:** `npm run build` gera um único HTML autocontido em `Sources/DayPanel/Resources/ApolloSplash/index.html` (332 KB, 111 KB gzip), com CSP sem rede.
- **Lua** (`scene/MoonRenderer.ts` e `scene/moonShaders.ts`):
  - superfície procedural gerada uma vez (mares nas posições reais, 5 oitavas de crateras, montanhas e raios);
  - sombreamento lunar-Lambert, sombras projetadas no terminador e microrrelevo;
  - luz ambiente no tom do céu e rotação contínua.
- **Camadas e movimento:**
  - `NebulaRenderer`: névoa no estilo Webb, em duas camadas;
  - `Starfield`: estrelas, faixa de poeira, flares do ícone e meteoros;
  - `Motes`: poeira em primeiro plano;
  - `OrbitRig`: duas órbitas, com a nave e oclusão pela lua.
- **Coreografia** (`Splash.tsx`):
  - entrada: câmera recuando, flare anamórfico, varredura do terminador até a meia lua, onda de choque, órbitas e o wordmark entrando letra a letra;
  - espera: a barra de loading continua avançando e aparece "Sincronizando suas tarefas";
  - saída: a barra completa e a lua se abre num círculo que revela o dashboard;
  - redução de movimento: só opacidade.
- **Parâmetros de dev:** `?hold`, `?seek=1.4` e `?reveal=0.5`.

### Swift
- `Views/Onboarding/LunarSplash/`:
  - `LunarSplashController`: `WKWebView`, ponte e fallback;
  - `LunarSplashView`: fundo nativo idêntico ao da web e marca de fallback;
  - `LunarSplashPolicy`: 3 s mínimos, espera `introComplete` e os dados, teto de 12 s, fallback se a web não estiver pronta em 2 s.
- `ContentView`: `welcomeRevealStarted` esconde o fundo de setup e sobe o onboarding antes de a revelação abrir; `welcomeFinished` remove a splash. `WelcomeAnimationView` foi removida.
- `Views/Extensions/LunarSkeleton.swift`: `LunarSkeletonSurface`, uma frente de luz curva sincronizada globalmente em todos os placeholders. Tem atraso de 120 ms para não piscar e respeita "reduzir movimento".
- Skeletons migrados: `MyTasksLoadingPlaceholder`, `EditorialSkeletonRow`/`Stack`/`Card` e `CommentSkeletonCard`.
- `build.sh` recompila a splash se houver `node_modules` e copia o bundle; `Package.swift` exclui o recurso.
- `DEBUG`: `APOLLO_SPLASH_URL=http://localhost:5317` aponta a splash para o servidor Vite.

## Evidência
- `swift test --skip ReviewBackendE2ETests`: 203 testes, 0 falhas. Inclui `LunarSplashPolicyTests`.
- Harness `WKWebView` real (`/tmp/splash-harness`), janela de 1280×800 a 2x:
  - `ready` 0,29 s após o carregamento;
  - 60 fps, pior quadro de 18 ms;
  - `introComplete` em 3,3 s;
  - revelação transparente sobre o conteúdo nativo confirmada por capturas.

## Pendências
- Rodar o app completo. O Apollo de produção estava aberto e usa o mesmo bundle id e container.
- Validação visual dos skeletons no app.
- Commit e PR.
