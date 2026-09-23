import type { Layout } from "./state";

type Star = {
  x: number;
  y: number;
  r: number;
  alpha: number;
  speed: number;
  offset: number;
  depth: number;
  color: string;
};

type Flare = { x: number; y: number; size: number; offset: number; depth: number };

const TINTS = ["#ffffff", "#ffffff", "#ffffff", "#dce9ff", "#cfe3ff", "#fff1dc"];

/** Deterministic PRNG so the sky is identical on every launch. */
function mulberry32(seed: number) {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function gaussian(rand: () => number) {
  return Math.sqrt(-2 * Math.log(rand() + 1e-9)) * Math.cos(2 * Math.PI * rand());
}

/**
 * Two canvases:
 * - `dust`: the faint galactic band and the dim star population, painted
 *   once per resize. Its camera zoom is a CSS transform (compositor only).
 * - `live`: ~100 bright stars that twinkle, plus four "brand" flares drawn
 *   as the four-point star from the Apollo icon. Repainted every frame.
 */
export class Starfield {
  private readonly dustCtx: CanvasRenderingContext2D;
  private readonly liveCtx: CanvasRenderingContext2D;
  private stars: Star[] = [];
  private flares: Flare[] = [];
  private layout: Layout | null = null;
  private dpr = 1;

  constructor(
    private readonly dust: HTMLCanvasElement,
    private readonly live: HTMLCanvasElement,
  ) {
    const dustCtx = dust.getContext("2d", { alpha: true });
    const liveCtx = live.getContext("2d", { alpha: true });
    if (!dustCtx || !liveCtx) throw new Error("Canvas 2D unavailable");
    this.dustCtx = dustCtx;
    this.liveCtx = liveCtx;
  }

  resize(layout: Layout, dpr: number) {
    this.layout = layout;
    this.dpr = dpr;
    for (const canvas of [this.dust, this.live]) {
      canvas.width = Math.round(layout.width * dpr);
      canvas.height = Math.round(layout.height * dpr);
      canvas.style.width = `${layout.width}px`;
      canvas.style.height = `${layout.height}px`;
    }
    this.dust.style.transformOrigin = `${layout.cx}px ${layout.cy}px`;
    this.seed(layout);
    this.paintDust(layout);
  }

  /** `visible` 0…1 fades the whole sky; `zoom` ≥ 0 is the camera push (0 = rest). */
  draw(time: number, visible: number, zoom: number) {
    const layout = this.layout;
    if (!layout) return;
    const ctx = this.liveCtx;
    const { dpr } = this;

    this.dust.style.opacity = String(visible);
    this.dust.style.transform = `scale(${1 + zoom})`;

    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.live.width, this.live.height);
    if (visible <= 0.001) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    for (const star of this.stars) {
      const twinkle = 0.62 + 0.38 * Math.sin(time * star.speed + star.offset);
      const push = 1 + zoom * star.depth;
      const x = layout.cx + (star.x - layout.cx) * push;
      const y = layout.cy + (star.y - layout.cy) * push;
      ctx.globalAlpha = star.alpha * twinkle * visible * this.glare(x, y);
      ctx.fillStyle = star.color;
      ctx.beginPath();
      ctx.arc(x, y, star.r, 0, Math.PI * 2);
      ctx.fill();
    }

    this.drawMeteors(ctx, time, visible);

    for (const flare of this.flares) {
      const pulse = 0.7 + 0.3 * Math.sin(time * 0.9 + flare.offset);
      const push = 1 + zoom * flare.depth;
      const x = layout.cx + (flare.x - layout.cx) * push;
      const y = layout.cy + (flare.y - layout.cy) * push;
      const alpha = visible * pulse * this.glare(x, y);
      this.drawFlare(ctx, x, y, flare.size * (0.9 + 0.1 * pulse), alpha);
    }
    ctx.globalAlpha = 1;
  }

  // ── Internals ─────────────────────────────────────────────────────────

  /**
   * Shooting stars on a fixed schedule — the first one is choreographed to
   * cross the sky just as the wordmark starts landing, then roughly every
   * three seconds while the splash holds.
   */
  private drawMeteors(ctx: CanvasRenderingContext2D, time: number, visible: number) {
    const layout = this.layout!;
    const FIRST = 1.45;
    const EVERY = 3.1;
    const LIFE = 0.75;
    if (time < FIRST) return;
    const index = Math.floor((time - FIRST) / EVERY);
    const age = time - FIRST - index * EVERY;
    if (age > LIFE) return;

    const rand = mulberry32(0x3e7e0 + index * 977);
    const fromLeft = index % 2 === 1;
    const startX = layout.width * (fromLeft ? 0.08 + rand() * 0.25 : 0.62 + rand() * 0.3);
    const startY = layout.height * (0.06 + rand() * 0.22);
    const angle = (fromLeft ? 0.42 : Math.PI - 0.42) + (rand() - 0.5) * 0.18;
    const speed = Math.max(layout.width, 900) * 1.25;
    const progress = age / LIFE;
    // Fast ignition, gentle burn-out.
    const intensity = Math.sin(Math.min(progress * 1.25, 1) * Math.PI) * visible;
    const headX = startX + Math.cos(angle) * speed * age;
    const headY = startY + Math.sin(angle) * speed * age;
    const tail = 200 + 220 * Math.sin(progress * Math.PI);
    const tailX = headX - Math.cos(angle) * tail;
    const tailY = headY - Math.sin(angle) * tail;

    ctx.save();
    ctx.globalAlpha = intensity;
    const streak = ctx.createLinearGradient(tailX, tailY, headX, headY);
    streak.addColorStop(0, "rgba(170, 225, 255, 0)");
    streak.addColorStop(0.75, "rgba(200, 238, 255, 0.45)");
    streak.addColorStop(1, "rgba(255, 255, 255, 0.95)");
    ctx.strokeStyle = streak;
    ctx.lineWidth = 2;
    ctx.lineCap = "round";
    ctx.beginPath();
    ctx.moveTo(tailX, tailY);
    ctx.lineTo(headX, headY);
    ctx.stroke();
    const head = ctx.createRadialGradient(headX, headY, 0, headX, headY, 12);
    head.addColorStop(0, "rgba(255, 255, 255, 0.9)");
    head.addColorStop(1, "rgba(160, 230, 255, 0)");
    ctx.fillStyle = head;
    ctx.fillRect(headX - 12, headY - 12, 24, 24);
    ctx.restore();
  }

  /** Stars wash out in the moon's glare, as they do to the eye. */
  private glare(x: number, y: number) {
    const layout = this.layout!;
    const d = Math.hypot(x - layout.cx, y - layout.cy) / (layout.diameter * 0.5);
    return Math.min(1, Math.max(0, (d - 1.05) / 0.9));
  }

  private seed(layout: Layout) {
    const rand = mulberry32(0xa9011);
    const area = layout.width * layout.height;
    const liveCount = Math.min(140, Math.round(area / 16000));
    this.stars = Array.from({ length: liveCount }, () => {
      const depth = rand();
      return {
        x: rand() * layout.width,
        y: rand() * layout.height,
        r: 0.45 + Math.pow(rand(), 3) * 1.05,
        alpha: 0.35 + rand() * 0.6,
        speed: 0.7 + rand() * 1.9,
        offset: rand() * Math.PI * 2,
        depth: 0.4 + depth * 1.6,
        color: TINTS[Math.floor(rand() * TINTS.length)],
      };
    });
    // Four brand flares, placed by hand-tuned fractions so they frame the
    // moon instead of landing on top of the wordmark.
    const spots = [
      [0.16, 0.2, 9],
      [0.82, 0.14, 7],
      [0.9, 0.62, 10],
      [0.11, 0.71, 6],
    ] as const;
    this.flares = spots.map(([fx, fy, size], i) => ({
      x: fx * layout.width,
      y: fy * layout.height,
      size,
      offset: i * 1.7,
      depth: 1.4,
    }));
  }

  private paintDust(layout: Layout) {
    const ctx = this.dustCtx;
    const { dpr } = this;
    const rand = mulberry32(0x5eed);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.dust.width, this.dust.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    const { width, height } = layout;
    // Galactic band: a long diagonal behind the moon.
    const angle = -0.42;
    const ux = Math.cos(angle);
    const uy = Math.sin(angle);
    const span = Math.hypot(width, height);
    const bandWidth = Math.min(width, height) * 0.16;

    // Soft nebular glow along the band.
    ctx.globalCompositeOperation = "lighter";
    for (let i = 0; i < 7; i++) {
      const t = (i / 6 - 0.5) * span * 0.9;
      const x = layout.cx + ux * t + gaussian(rand) * bandWidth * 0.3;
      const y = layout.cy + uy * t + gaussian(rand) * bandWidth * 0.3;
      const radius = bandWidth * (1.6 + rand() * 1.6);
      const glow = ctx.createRadialGradient(x, y, 0, x, y, radius);
      const tint = i % 3 === 0 ? "92, 120, 170" : i % 3 === 1 ? "70, 150, 175" : "110, 100, 160";
      glow.addColorStop(0, `rgba(${tint}, 0.075)`);
      glow.addColorStop(1, `rgba(${tint}, 0)`);
      ctx.fillStyle = glow;
      ctx.fillRect(x - radius, y - radius, radius * 2, radius * 2);
    }
    ctx.globalCompositeOperation = "source-over";

    // Dust: thousands of sub-pixel stars concentrated in the band.
    const dustCount = Math.min(4200, Math.round((width * height) / 420));
    for (let i = 0; i < dustCount; i++) {
      const t = (rand() - 0.5) * span;
      const off = gaussian(rand) * bandWidth * (0.5 + rand() * 0.6);
      const x = layout.cx + ux * t - uy * off;
      const y = layout.cy + uy * t + ux * off;
      const inBand = Math.exp(-(off * off) / (2 * bandWidth * bandWidth));
      const d = Math.hypot(x - layout.cx, y - layout.cy) / (layout.diameter * 0.5);
      const glare = Math.min(1, Math.max(0, (d - 1.05) / 0.9));
      ctx.globalAlpha = (0.08 + 0.34 * inBand * rand()) * glare;
      ctx.fillStyle = TINTS[i % TINTS.length];
      const size = 0.35 + rand() * 0.55;
      ctx.fillRect(x, y, size, size);
    }

    // Dim background population, uniform across the sky.
    const dimCount = Math.min(700, Math.round((width * height) / 3200));
    for (let i = 0; i < dimCount; i++) {
      const x = rand() * width;
      const y = rand() * height;
      const d = Math.hypot(x - layout.cx, y - layout.cy) / (layout.diameter * 0.5);
      const glare = Math.min(1, Math.max(0, (d - 1.05) / 0.9));
      ctx.globalAlpha = (0.12 + rand() * 0.3) * glare;
      ctx.fillStyle = TINTS[i % TINTS.length];
      ctx.beginPath();
      ctx.arc(x, y, 0.3 + rand() * 0.5, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  /** The Apollo icon's four-point star: concave astroid + hot core. */
  private drawFlare(ctx: CanvasRenderingContext2D, x: number, y: number, size: number, alpha: number) {
    if (alpha <= 0.01) return;
    ctx.save();
    ctx.translate(x, y);
    ctx.globalAlpha = alpha;
    const halo = ctx.createRadialGradient(0, 0, 0, 0, 0, size * 1.8);
    halo.addColorStop(0, "rgba(150, 235, 255, 0.35)");
    halo.addColorStop(1, "rgba(150, 235, 255, 0)");
    ctx.fillStyle = halo;
    ctx.fillRect(-size * 2, -size * 2, size * 4, size * 4);

    const k = size * 0.16;
    ctx.beginPath();
    ctx.moveTo(0, -size);
    ctx.quadraticCurveTo(k, -k, size, 0);
    ctx.quadraticCurveTo(k, k, 0, size);
    ctx.quadraticCurveTo(-k, k, -size, 0);
    ctx.quadraticCurveTo(-k, -k, 0, -size);
    ctx.closePath();
    ctx.fillStyle = "rgba(225, 250, 255, 0.95)";
    ctx.fill();
    ctx.restore();
  }
}
