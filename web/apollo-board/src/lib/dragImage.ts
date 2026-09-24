// Multi-card drag image: three stacked cards with the lane colour and
// "N tarefas", drawn at device resolution (a single card drags as itself).

import { read } from "./store";

export function drawStackImage(
  canvas: HTMLCanvasElement,
  count: number,
  color: string,
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
  // Canvas cannot resolve CSS variables: fall back to the theme values.
  const resolved = color.startsWith("var(") ? (theme["accent"] ?? "#7b68ee") : color;
  const cardWidth = size.width - 16;
  for (let index = 2; index >= 0; index--) {
    const offset = index * 5;
    ctx.beginPath();
    ctx.roundRect(offset, (2 - index) * 6, cardWidth - offset, 44, 8);
    ctx.fillStyle = theme["page"] ?? "#ffffff";
    ctx.shadowColor = "rgba(0, 0, 0, 0.10)";
    ctx.shadowBlur = 8;
    ctx.shadowOffsetY = 2;
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = theme["card-border"] ?? "rgba(0,0,0,0.12)";
    ctx.lineWidth = 0.75;
    ctx.stroke();
  }
  ctx.fillStyle = resolved;
  ctx.beginPath();
  ctx.roundRect(12, 24, 22, 16, 8);
  ctx.fill();
  ctx.fillStyle = "#fff";
  ctx.font = "600 11px -apple-system, system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(String(count), 23, 36);
  ctx.textAlign = "left";
  ctx.fillStyle = theme["ink"] ?? "#1d1d1f";
  ctx.font = "500 13px -apple-system, system-ui, sans-serif";
  ctx.fillText(`${count} tarefas`, 42, 37);
}
