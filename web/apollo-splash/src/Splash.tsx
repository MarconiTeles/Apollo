import { useLayoutEffect, useRef, type CSSProperties } from "react";
import gsap from "gsap";
import { config, isHosted, onCommand, post } from "./lib/bridge";
import { EASE_IN_OUT, EASE_OUT, LINEAR } from "./lib/ease";
import { MoonRenderer } from "./scene/MoonRenderer";
import { Motes } from "./scene/Motes";
import { NebulaRenderer } from "./scene/NebulaRenderer";
import { OrbitRig } from "./scene/OrbitRig";
import { Starfield } from "./scene/Starfield";
import { computeLayout, createScene, PHASE_REST, type Layout } from "./scene/state";

const LETTERS = ["A", "p", "o", "l", "l", "o"];
/** Grace period after the intro before the "still syncing" hint appears. */
const WAITING_HINT_DELAY = 900;
/** Resting rotation speed, rad/s — clearly turning, never distracting. */
const SPIN_RATE = 0.11;

/**
 * The Apollo launch splash.
 *
 * Intro (≈3 s, then holds until Swift says the data is ready):
 *   the camera pulls back from a blurred, close-up moon while every layer —
 *   nebula, stars, dust, mist — settles with parallax; the sun ignites on the
 *   limb with an anamorphic flare and the terminator sweeps from a thin
 *   crescent to a half moon while the disc spins down to its resting turn;
 *   a shockwave rolls out, two orbits trace in, the spacecraft (the icon's
 *   four-point star) begins to circle, a meteor crosses as the wordmark
 *   tracks in letter by letter.
 * Exit: the moon flares and opens into an iris that reveals the dashboard
 *   already rendered underneath the transparent WKWebView.
 */
export function Splash() {
  const rootRef = useRef<HTMLDivElement>(null);
  const nebulaRef = useRef<HTMLCanvasElement>(null);
  const dustRef = useRef<HTMLCanvasElement>(null);
  const liveRef = useRef<HTMLCanvasElement>(null);
  const orbitBackRef = useRef<SVGSVGElement>(null);
  const orbitFrontRef = useRef<SVGSVGElement>(null);
  const moonWrapRef = useRef<HTMLDivElement>(null);
  const moonCanvasRef = useRef<HTMLCanvasElement>(null);
  const mistRef = useRef<HTMLCanvasElement>(null);
  const motesRef = useRef<HTMLCanvasElement>(null);
  const flareRef = useRef<HTMLDivElement>(null);
  const shockRef = useRef<HTMLDivElement>(null);
  const titleRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const root = rootRef.current!;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const scene = createScene(reduced);
    const clock = { drift: 0 };

    const starfield = new Starfield(dustRef.current!, liveRef.current!);
    const motes = new Motes(motesRef.current!);
    orbitBackRef.current!.replaceChildren();
    orbitFrontRef.current!.replaceChildren();
    const orbits = [
      new OrbitRig(orbitBackRef.current!, orbitFrontRef.current!, {
        id: "inner",
        rx: 0.8,
        ry: 0.17,
        tilt: -13,
        period: 7.5,
        phase: Math.PI * 0.92,
        craft: "star",
        ringOpacity: 0.34,
      }),
      new OrbitRig(orbitBackRef.current!, orbitFrontRef.current!, {
        id: "outer",
        rx: 1.22,
        ry: 0.3,
        tilt: 9,
        period: -15,
        phase: 0.35,
        craft: "dot",
        ringOpacity: 0.17,
      }),
    ];
    const moon = MoonRenderer.create(moonCanvasRef.current!);
    const nebula = NebulaRenderer.create(nebulaRef.current!, { mode: "veil", scale: 0.32 });
    const mist = NebulaRenderer.create(mistRef.current!, { mode: "mist", scale: 0.26 });
    if (!moon) root.classList.add("no-webgl");

    let layout: Layout = computeLayout(window.innerWidth, window.innerHeight);
    const applyLayout = () => {
      layout = computeLayout(window.innerWidth, window.innerHeight);
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      root.style.setProperty("--moon-d", `${layout.diameter}px`);
      root.style.setProperty("--moon-x", `${layout.cx}px`);
      root.style.setProperty("--moon-y", `${layout.cy}px`);
      starfield.resize(layout, dpr);
      motes.resize(layout, dpr);
      orbits.forEach((orbit) => orbit.resize(layout));
      moon?.resize(layout.diameter, dpr);
      nebula?.resize(layout.width, layout.height);
      mist?.resize(layout.width, layout.height);
    };
    applyLayout();
    window.addEventListener("resize", applyLayout);

    // Dev-only frame inspection: ?seek=1.4 freezes the intro at 1.4 s and
    // ?reveal=0.5 freezes the exit at 0.5 s (after a completed intro).
    const params = new URLSearchParams(location.search);
    const devSeek = import.meta.env.DEV && params.has("seek") ? Number(params.get("seek")) : null;
    const devReveal = import.meta.env.DEV && params.has("reveal") ? Number(params.get("reveal")) : null;
    const frozenAt = devReveal !== null ? 3 : devSeek;

    // ── Render loop ────────────────────────────────────────────────────
    let startedAt: number | null = null;
    let raf = 0;
    let frame = 0;
    const render = (now: number) => {
      // Reduced motion freezes the clock: no twinkle, spin or orbit travel.
      const t = startedAt === null || reduced ? 0 : (frozenAt ?? (now - startedAt) / 1000);
      // Camera: a big pull-back during the intro, then a slow push-in.
      const zoom = scene.pull * 0.28 + clock.drift * 0.03;
      const core = { x: layout.cx / layout.width, y: layout.cy / layout.height };
      const coreRadius = (layout.diameter / layout.height) * 0.75;

      // The gas is soft and slow: 30 fps is indistinguishable and half the cost.
      if (frame++ % 2 === 0 || frozenAt !== null) {
        nebula?.draw(t, scene.nebula, core, coreRadius);
        mist?.draw(t, scene.mist, core, coreRadius);
      }
      starfield.draw(t, scene.stars, zoom);
      moon?.draw({
        phase: scene.phase,
        spin: -0.1 + t * SPIN_RATE + scene.spinExtra,
        exposure: scene.exposure,
        alpha: scene.moon,
      });
      orbits[0].draw(t, scene.orbit, scene.satellite);
      orbits[1].draw(t, scene.orbitOuter, scene.satellite * 0.8);
      motes.draw(t, scene.mist, zoom);
      root.style.setProperty("--halo", String(scene.halo));
      raf = requestAnimationFrame(render);
    };
    raf = requestAnimationFrame((now) => {
      render(now);
      // One painted frame (bake done, sky black) before telling Swift we're
      // ready, so the native backdrop can hand over without a flash.
      requestAnimationFrame(() => post({ type: "ready" }));
    });

    const ctx = gsap.context(() => {}, root);
    let waitingTimer = 0;
    let exiting = false;

    // ── Intro ─────────────────────────────────────────────────────────
    const start = () => {
      if (startedAt !== null) return;
      startedAt = performance.now();
      root.classList.add("is-started");
      ctx.add(() => {
        const intro = (reduced ? introReduced() : introFull()).eventCallback("onComplete", onIntroComplete);
        // The slow camera push-in outlives the intro, so it must not extend
        // the intro timeline (whose completion Swift waits for).
        if (!reduced) gsap.to(clock, { drift: 1, duration: 12, ease: LINEAR, delay: 2.6 });
        if (frozenAt !== null) intro.progress(devReveal !== null ? 1 : 0).seek(frozenAt, false).pause();
      });
    };

    const introFull = () => {
      const d = layout.diameter;
      const fontSize = parseFloat(getComputedStyle(titleRef.current!.firstElementChild!).fontSize);
      return (
        gsap
          .timeline()
          // Atmosphere + camera.
          .to(scene, { stars: 1, duration: 1.2, ease: EASE_OUT }, 0)
          .to(scene, { nebula: 1, duration: 2.2, ease: EASE_OUT }, 0.1)
          .to(scene, { pull: 0, duration: 2.6, ease: EASE_OUT }, 0)
          // The moon: close, blurred and spinning → in focus, settled.
          .fromTo(
            moonWrapRef.current,
            { y: d * 0.12, scale: 1.6, filter: "blur(18px)" },
            { y: 0, scale: 1, filter: "blur(0px)", duration: 2.5, ease: EASE_OUT },
            0.02,
          )
          .to(scene, { moon: 1, duration: 0.5, ease: EASE_OUT }, 0.02)
          .fromTo(scene, { spinExtra: -2.4 }, { spinExtra: 0, duration: 2.9, ease: EASE_OUT }, 0.02)
          .to(scene, { phase: PHASE_REST, duration: 2.4, ease: EASE_IN_OUT }, 0.12)
          // Sunrise on the limb: exposure spike + anamorphic flare.
          .fromTo(scene, { exposure: 2.6 }, { exposure: 1, duration: 1.7, ease: EASE_OUT }, 0.12)
          .fromTo(
            flareRef.current,
            { opacity: 0, scaleX: 0.15 },
            { opacity: 1, scaleX: 1, duration: 0.28, ease: EASE_OUT },
            0.16,
          )
          .to(flareRef.current, { opacity: 0, scaleX: 1.35, duration: 1.4, ease: EASE_OUT }, 0.44)
          .to(scene, { halo: 1, duration: 1.8, ease: EASE_OUT }, 0.35)
          .to(scene, { mist: 1, duration: 1.8, ease: EASE_OUT }, 0.5)
          // Shockwave as the light settles.
          .fromTo(
            shockRef.current,
            { opacity: 0.75, scale: 0.98 },
            { opacity: 0, scale: 2.5, duration: 1.6, ease: EASE_OUT, immediateRender: false },
            0.85,
          )
          // Orbits and spacecraft.
          .to(scene, { orbit: 1, duration: 1.4, ease: EASE_OUT }, 0.8)
          .to(scene, { orbitOuter: 1, duration: 1.8, ease: EASE_OUT }, 0.95)
          .to(scene, { satellite: 1, duration: 0.8, ease: EASE_OUT }, 1.1)
          // Wordmark: letters track in from wide spacing, out of focus.
          .fromTo(
            ".ch",
            {
              x: (i: number) => (i - (LETTERS.length - 1) / 2) * fontSize * 0.42,
              yPercent: 35,
              opacity: 0,
              filter: "blur(14px)",
            },
            {
              x: 0,
              yPercent: 0,
              opacity: 1,
              filter: "blur(0px)",
              duration: 1.35,
              ease: EASE_OUT,
              stagger: { each: 0.05, from: "center" },
            },
            1.0,
          )
          .fromTo(".rule", { opacity: 0, scaleX: 0.1 }, { opacity: 1, scaleX: 1, duration: 0.8, ease: EASE_OUT }, 1.65)
          .fromTo(".rule b", { scaleX: 0 }, { scaleX: 0.68, duration: 1.3, ease: EASE_OUT }, 1.7)
      );
    };

    // Reduced motion: the same composition, arriving by opacity alone.
    const introReduced = () =>
      gsap
        .timeline()
        .to(scene, { stars: 1, nebula: 1, mist: 1, moon: 1, halo: 1, satellite: 1, duration: 0.5, ease: EASE_OUT }, 0)
        .fromTo([".ch", ".rule"], { opacity: 0 }, { opacity: 1, duration: 0.5, ease: EASE_OUT }, 0.1)
        .set(".rule b", { scaleX: 0.68 }, 0.1);

    let creep: gsap.core.Tween | null = null;
    const onIntroComplete = () => {
      post({ type: "introComplete" });
      // Still waiting on data: keep inching forward, never quite finishing.
      ctx.add(() => {
        creep = gsap.to(".rule b", { scaleX: 0.94, duration: 9, ease: EASE_OUT });
      });
      waitingTimer = window.setTimeout(() => {
        if (!exiting) root.classList.add("is-waiting");
      }, WAITING_HINT_DELAY);
    };

    // ── Exit ──────────────────────────────────────────────────────────
    const exit = () => {
      if (exiting) return;
      exiting = true;
      if (startedAt === null) start();
      window.clearTimeout(waitingTimer);
      root.classList.remove("is-waiting");
      creep?.kill();

      const finish = () => {
        post({ type: "finished" });
        cancelAnimationFrame(raf);
        root.style.visibility = "hidden";
      };

      if (reduced) {
        post({ type: "revealStart" });
        ctx.add(() =>
          gsap
            .timeline({ onComplete: finish })
            .to(".rule b", { scaleX: 1, duration: 0.2, ease: EASE_OUT })
            .to(root, { opacity: 0, duration: 0.35, ease: EASE_OUT }),
        );
        return;
      }

      const farthest = Math.max(
        Math.hypot(layout.cx, layout.cy),
        Math.hypot(layout.width - layout.cx, layout.cy),
        Math.hypot(layout.cx, layout.height - layout.cy),
        Math.hypot(layout.width - layout.cx, layout.height - layout.cy),
      );
      ctx.add(() => {
        // The bar completes first; the iris opens as it lands.
        const outro = gsap
          .timeline({ onComplete: finish })
          .to(".rule b", { scaleX: 1, duration: 0.28, ease: EASE_OUT }, 0)
          .to(titleRef.current, { opacity: 0, y: -10, duration: 0.4, ease: EASE_OUT }, 0.26)
          .to(scene, { satellite: 0, orbit: 0, orbitOuter: 0, duration: 0.45, ease: EASE_OUT }, 0.26)
          .to(scene, { exposure: 1.55, duration: 0.3, ease: EASE_OUT }, 0.26)
          .to(moonWrapRef.current, { scale: 1.07, duration: 1.05, ease: EASE_IN_OUT }, 0.26)
          .add(() => {
            root.classList.add("is-revealing");
            post({ type: "revealStart" });
          }, 0.36)
          .fromTo(
            root,
            { "--reveal": "0px" },
            { "--reveal": `${farthest + 120}px`, duration: 0.95, ease: EASE_IN_OUT, immediateRender: false },
            0.36,
          );
        if (devReveal !== null) outro.seek(devReveal, false).pause();
      });
    };

    const unsubscribe = onCommand((command) => (command === "start" ? start() : exit()));
    if (config.autostart) start();
    if (devReveal !== null) exit();

    // Dev server only: hold with ?hold, otherwise play start → exit.
    let devTimer = 0;
    if (!isHosted && import.meta.env.DEV && !params.has("hold") && frozenAt === null) {
      devTimer = window.setTimeout(exit, 5200);
    }

    return () => {
      unsubscribe();
      window.clearTimeout(waitingTimer);
      window.clearTimeout(devTimer);
      window.removeEventListener("resize", applyLayout);
      cancelAnimationFrame(raf);
      ctx.revert();
      moon?.dispose();
      nebula?.dispose();
      mist?.dispose();
    };
  }, []);

  return (
    <div ref={rootRef} className="splash" style={{ "--accent": config.accent } as CSSProperties}>
      <canvas ref={nebulaRef} className="layer nebula" aria-hidden />
      <canvas ref={dustRef} className="layer dust" aria-hidden />
      <canvas ref={liveRef} className="layer live" aria-hidden />
      <svg ref={orbitBackRef} className="layer orbit orbit-back" aria-hidden />

      <div ref={moonWrapRef} className="moon" aria-hidden>
        <div className="moon-halo" />
        <canvas ref={moonCanvasRef} className="moon-canvas" />
        <div className="moon-fallback" />
      </div>
      <div ref={shockRef} className="shock" aria-hidden />

      <svg ref={orbitFrontRef} className="layer orbit orbit-front" aria-hidden />
      <canvas ref={mistRef} className="layer mist" aria-hidden />
      <canvas ref={motesRef} className="layer motes" aria-hidden />

      <div ref={flareRef} className="flare" aria-hidden />

      <div ref={titleRef} className="title" role="img" aria-label="Apollo">
        <div className="wordmark">
          {LETTERS.map((letter, i) => (
            <span key={i} className="ch">
              {letter}
            </span>
          ))}
        </div>
        <div className="rule" role="progressbar" aria-label="Carregando">
          <b />
          <i />
        </div>
        <p className="status">Sincronizando suas tarefas</p>
      </div>

      <div className="reveal-rim" aria-hidden />
    </div>
  );
}
