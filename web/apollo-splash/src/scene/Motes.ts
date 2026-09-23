import type { Layout } from "./state";

type Mote = {
  x: number;
  y: number;
  size: number;
  alpha: number;
  drift: number;
  wobble: number;
  offset: number;
  depth: number;
};

function mulberry32(seed: number) {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Out-of-focus dust drifting between the camera and the moon — the nearest
 * moving layer. Motes brighten as they pass through the moonlight, which is
 * what ties this layer to the scene instead of reading as a screen overlay.
 */
export class Motes {
  private readonly ctx: CanvasRenderingContext2D;
  private motes: Mote[] = [];
  private layout: Layout | null = null;
  private dpr = 1;
  private sprite: HTMLCanvasElement;

  constructor(private readonly canvas: HTMLCanvasElement) {
    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) throw new Error("Canvas 2D unavailable");
    this.ctx = ctx;
    // One pre-rendered bokeh disc, scaled per mote with drawImage.
    this.sprite = document.createElement("canvas");
    this.sprite.width = this.sprite.height = 64;
    const s = this.sprite.getContext("2d")!;
    const g = s.createRadialGradient(32, 32, 0, 32, 32, 32);
    g.addColorStop(0, "rgba(215, 238, 255, 1)");
    g.addColorStop(0.55, "rgba(185, 225, 255, 0.45)");
    g.addColorStop(1, "rgba(160, 215, 255, 0)");
    s.fillStyle = g;
    s.fillRect(0, 0, 64, 64);
  }

  resize(layout: Layout, dpr: number) {
    this.layout = layout;
    this.dpr = dpr;
    this.canvas.width = Math.round(layout.width * dpr);
    this.canvas.height = Math.round(layout.height * dpr);
    this.canvas.style.width = `${layout.width}px`;
    this.canvas.style.height = `${layout.height}px`;
    const rand = mulberry32(0xd057);
    const count = Math.min(34, Math.round((layout.width * layout.height) / 42000));
    this.motes = Array.from({ length: count }, () => ({
      x: rand() * layout.width,
      y: rand() * layout.height,
      size: 2 + Math.pow(rand(), 2.2) * 12,
      alpha: 0.06 + rand() * 0.2,
      drift: 6 + rand() * 16,
      wobble: 4 + rand() * 10,
      offset: rand() * Math.PI * 2,
      depth: 0.6 + rand() * 1.4,
    }));
  }

  draw(time: number, visible: number, zoom: number) {
    const layout = this.layout;
    const { ctx } = this;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    if (!layout || visible <= 0.001) return;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    const reach = layout.diameter * 0.95;

    for (const mote of this.motes) {
      // Rise slowly, sway, and push outward with the camera (the nearest
      // layer moves the most — that's the parallax).
      const push = 1 + zoom * 4 * mote.depth;
      let x = mote.x + Math.sin(time * 0.35 + mote.offset) * mote.wobble;
      let y = mote.y - time * mote.drift;
      y = ((y % layout.height) + layout.height) % layout.height;
      x = layout.cx + (x - layout.cx) * push;
      y = layout.cy + (y - layout.cy) * push;
      const lit = Math.exp(-((x - layout.cx) ** 2 + (y - layout.cy) ** 2) / (reach * reach));
      ctx.globalAlpha = Math.min(1, mote.alpha * (0.6 + lit * 2.2)) * visible;
      const size = mote.size * push;
      ctx.drawImage(this.sprite, x - size, y - size, size * 2, size * 2);
    }
    ctx.globalAlpha = 1;
  }
}
