// MyTasksNativeRowView.multiTaskDragImage: three stacked cards, the status
// dot, rectangle.stack.fill and "N tarefas", drawn at device resolution.

import { read } from "./store";

const images = new Map<string, HTMLImageElement>();

function glyphImage(url: string) {
  let image = images.get(url);
  if (!image) {
    image = new Image();
    image.src = url;
    images.set(url, image);
  }
  return image;
}

/** Warm the symbol so the synchronous dragstart can draw it. */
export function preloadDragGlyphs() {
  const stack = read().glyphs.stack;
  if (stack) glyphImage(stack.url);
}

function roundedRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
}

export function drawStackImage(
  canvas: HTMLCanvasElement,
  count: number,
  sc: string,
  size: { width: number; height: number },
) {
  const scale = window.devicePixelRatio || 2;
  canvas.width = Math.ceil(size.width * scale);
  canvas.height = Math.ceil(size.height * scale);
  canvas.style.width = `${size.width}px`;
  canvas.style.height = `${size.height}px`;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
  ctx.clearRect(0, 0, size.width, size.height);
  const theme = read().theme;
  const tint = (alpha: number) => `color(display-p3 ${sc} / ${alpha})`;
  const cardWidth = size.width - 10;
  for (let index = 2; index >= 0; index--) {
    const offset = index * 4;
    roundedRect(ctx, offset, (2 - index) * 5, cardWidth - offset, 44, 12);
    ctx.fillStyle = theme["window-94"] ?? "rgba(236,236,236,0.94)";
    ctx.fill();
    ctx.strokeStyle = tint(index === 0 ? 0.45 : 0.22);
    ctx.lineWidth = index === 0 ? 1 : 0.7;
    ctx.stroke();
  }
  ctx.fillStyle = tint(1);
  ctx.beginPath();
  ctx.ellipse(19, 22, 4, 4, 0, 0, Math.PI * 2);
  ctx.fill();
  const stack = read().glyphs.stack;
  if (stack) {
    const image = glyphImage(stack.url);
    if (image.complete) ctx.drawImage(image, 31, 14, 16, 16);
  }
  ctx.fillStyle = theme["label"] ?? "#000";
  ctx.font = "600 12.5px -apple-system, system-ui, sans-serif";
  ctx.textBaseline = "alphabetic";
  ctx.fillText(`${count} tarefas`, 56, 14 + 12.5 * 0.952);
}
