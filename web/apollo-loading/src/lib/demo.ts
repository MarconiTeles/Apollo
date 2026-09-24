// Dev-only scripted sync for designing the scenes in a browser:
//   http://localhost:5318/?scene=board&theme=light
//   &at=2.4   freeze the timeline at 2.4 s
// Mirrors the copy `SyncLoadingSnapshot.make` produces in Swift.

import { publish } from "./bridge";
import type { SceneId, Snapshot, Step, StepState } from "./types";

const params = new URLSearchParams(location.search);
const scene = (params.get("scene") ?? "tasks") as SceneId;
const theme: Snapshot["theme"] = params.get("theme") === "light" ? "light" : "dark";
const frozenAt = params.has("at") ? Number(params.get("at")) : undefined;
const LOOP = 7;

const STATUSES = [
  { name: "a fazer", color: "#87909E" },
  { name: "em andamento", color: "#5F55EE" },
  { name: "revisão", color: "#E16B16" },
  { name: "aprovado", color: "#1090E0" },
  { name: "publicado", color: "#008844" },
  { name: "concluído", color: "#008844" },
];

const pick = (t: number, marks: [number, StepState][]): StepState =>
  marks.reduce<StepState>((state, [at, next]) => (t >= at ? next : state), "pending");

function stream(t: number, from: number, to: number, pages: number[]) {
  if (t < from) return undefined;
  const span = (to - from) / pages.length;
  const index = Math.min(pages.length - 1, Math.floor((t - from) / span));
  return pages[index];
}

function progressOf(steps: Step[]) {
  const counted = steps.filter((s) => s.state !== "skipped");
  const slice = 1 / counted.length;
  let progress = 0;
  let ceiling = 0;
  for (const step of counted) {
    if (step.state === "done" || step.state === "failed") progress += slice;
    else if (step.state === "active") ceiling = Math.max(ceiling, progress + slice * 0.92);
  }
  return { progress, ceiling: Math.max(progress, ceiling) };
}

function snapshotAt(t: number, startedAt: number): Snapshot {
  const base = {
    scene,
    theme,
    accent: "#0A84FF",
    online: true,
    columns: [] as Snapshot["columns"],
    startedAt,
    lastSyncedAt: Date.now() - 1000 * 60 * 14,
  };

  if (scene === "comments") {
    const scanned = Math.max(0, Math.min(90, Math.round((t - 0.8) * 16)));
    const found = [1.4, 2.3, 3.9, 4.6].filter((at) => t >= at).length;
    const indexing = t < 0.8;
    const steps: Step[] = [
      { id: "window", label: "Tarefas com atividade", detail: indexing ? "Ordenando por atividade recente" : "214 tarefas", state: indexing ? "active" : "done" },
      { id: "read", label: "Lendo conversas", detail: indexing ? null : `${scanned} de 90`, state: indexing ? "pending" : scanned < 90 ? "active" : "done" },
      { id: "match", label: "Separando o que é seu", detail: indexing ? null : `${found} ${found === 1 ? "comentário" : "comentários"}`, state: indexing ? "pending" : scanned < 90 ? "active" : "done" },
    ];
    const slice = 1 / 3;
    const progress = indexing ? 0 : slice + slice * (scanned / 90) + (scanned >= 90 ? slice : 0);
    return {
      ...base,
      headline: "Lendo comentários",
      context: "Mais recentes primeiro",
      steps,
      progress,
      ceiling: Math.min(1, progress + slice * 0.3),
      metric: { value: found, label: found === 1 ? "encontrado" : "encontrados" },
      scan: indexing ? null : { done: scanned, target: 90, found },
    };
  }

  if (scene === "inbox") {
    const tasks = stream(t, 0.2, 1.8, [100, 200, 287]);
    const clickup = pick(t, [[0, "active"], [1.8, "done"]]);
    const calendar = pick(t, [[1.8, "active"], [2.7, "done"]]);
    const changes = pick(t, [[2.7, "active"], [3.4, "done"]]);
    const steps: Step[] = [
      { id: "clickup", label: "ClickUp", detail: clickup === "done" ? "287 tarefas" : tasks ? `${tasks} tarefas…` : "Lendo", state: clickup },
      { id: "calendar", label: "Google Agenda", detail: calendar === "done" ? "42 eventos" : calendar === "active" ? "Lendo" : "Na fila", state: calendar },
      { id: "changes", label: "Comparando alterações", detail: changes === "done" ? "3 novidades" : changes === "active" ? "Comparando com a última leitura" : "Na fila", state: changes },
    ];
    return { ...base, headline: "Buscando novidades", context: "Última sincronização às 14:32", steps, ...progressOf(steps) };
  }

  if (scene === "agenda") {
    const calendar = pick(t, [[0.3, "active"], [3.2, "done"]]);
    const events = stream(t, 1.0, 3.2, [8, 19, 31]);
    const month = pick(t, [[3.2, "active"], [4.0, "done"]]);
    const steps: Step[] = [
      { id: "google", label: "Google Agenda", detail: "Conectada", state: "done" },
      { id: "events", label: "Eventos", detail: calendar === "done" ? "31 eventos" : events ? `${events} eventos…` : "Lendo", state: calendar },
      { id: "shared", label: "Agendas compartilhadas", detail: "9 agendas", state: calendar === "done" ? "done" : calendar },
      { id: "month", label: "Mês", detail: month === "active" ? "Carregando o mês" : null, state: month },
    ];
    return {
      ...base,
      headline: "Montando sua agenda",
      context: "quinta-feira, 24 de setembro",
      steps,
      ...progressOf(steps),
      metric: events ? { value: calendar === "done" ? 31 : events, label: "eventos" } : null,
      agenda: { eventsTop: 106, monthTop: 106 },
    };
  }

  const structure = pick(t, [[0.2, "active"], [1.0, "done"]]);
  const tasksState = pick(t, [[1.0, "active"], [4.2, "done"]]);
  const received = stream(t, 1.5, 4.2, [100, 200, 300, 346]);
  const isBoard = scene === "board";
  const steps: Step[] = [
    { id: "account", label: "Conta ClickUp", detail: "Moon Ventures", state: "done" },
    {
      id: "structure",
      label: isBoard ? "Colunas" : "Status da lista",
      detail: structure === "done" ? (isBoard ? "6 colunas" : "6 status") : structure === "active" ? "Solicitando ao ClickUp" : null,
      state: structure,
    },
    {
      id: "tasks",
      label: isBoard ? "Cartões" : "Tarefas",
      detail: tasksState === "active" ? (received ? `${received} ${isBoard ? "recebidos" : "recebidas"}…` : "Solicitando ao ClickUp") : tasksState === "done" ? `346 ${isBoard ? "recebidos" : "recebidas"}` : null,
      state: tasksState,
    },
  ];
  return {
    ...base,
    headline: isBoard ? "Montando o quadro" : structure === "active" ? "Lendo a estrutura da lista" : "Sincronizando tarefas",
    context: "Moon Ventures · Edição",
    steps,
    ...progressOf(steps),
    metric: received ? { value: tasksState === "done" ? 346 : received, label: isBoard ? "cartões" : "tarefas" } : null,
    columns: structure === "done" || isBoard ? (structure === "done" ? STATUSES : STATUSES.map(() => ({ name: "", color: "transparent" }))) : [],
    geometry: isBoard
      ? params.get("board") === "react"
        ? { top: 124, leading: 220, columnX: 227.5, columnWidth: 260, columnGap: 20, cardWidth: 240, cardHeight: 128, indicators: true }
        : { top: 150, leading: 220, columnX: 258, columnWidth: 260, columnGap: 20, cardWidth: 240 }
      : null,
  };
}

// In the app the scene is transparent over the native canvas and SwiftUI
// supplies the insets; the demo stands in for both.
const DEMO_CSS = `
  html[data-theme="dark"] body { background: #141415; }
  html[data-theme="light"] body { background: #f5f5f6; }
  .scene-tasks, .scene-comments { top: 82px; left: 220px; }
  .scene-inbox { top: 150px; left: calc(50% + 110px); }
  .scene-agenda { left: 220px; }
`;

export function startDemo() {
  const style = document.createElement("style");
  style.textContent = DEMO_CSS;
  document.head.appendChild(style);
  // Keeps preview tooling snapshots small; never applies in the app.
  document.getElementById("root")?.setAttribute("aria-hidden", "true");
  let startedAt = Date.now();
  const tick = () => {
    let t = (Date.now() - startedAt) / 1000;
    if (frozenAt !== undefined) t = frozenAt;
    else if (t > LOOP) {
      startedAt = Date.now();
      t = 0;
    }
    publish(snapshotAt(t, startedAt));
  };
  tick();
  window.setInterval(tick, 100);
}
