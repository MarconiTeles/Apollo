// Browser-only fixture (Vite dev server). Never part of the hosted path:
// WKWebView always receives real patches from MyTasksReactHost.

import { apply } from "./store";
import type { RowPayload } from "./types";

const statuses = [
  { name: "a fazer", sc: "0.33 0.34 0.49", color: "rgb(84,87,126)" },
  { name: "em andamento", sc: "0.69 0.38 0.18", color: "rgb(176,97,46)" },
  { name: "revisão", sc: "0.48 0.4 0.59", color: "rgb(122,101,151)" },
  { name: "concluído", sc: "0.25 0.42 0.29", color: "rgb(63,107,74)" },
];

export function startDemo() {
  const rows: RowPayload[] = [];
  let n = 0;
  statuses.forEach((status, index) => {
    const tasks = 8 + index * 5;
    rows.push({
      k: "h",
      id: status.name,
      status: status.name,
      title: status.name.toUpperCase(),
      color: status.color,
      sc: status.sc,
      count: tasks,
      collapsed: false,
      first: index === 0,
    });
    for (let i = 0; i < tasks; i++, n++) {
      rows.push({
        k: "t",
        id: `demo-${n}`,
        title: `Tarefa de demonstração ${n + 1} — roteiro, gravação e edição`,
        completed: false,
        status: status.name,
        sc: status.sc,
        priority: n % 3 === 0 ? { label: "URGENTE", color: "rgb(168,57,42)" } : undefined,
        assignee: { name: "Marconi", initials: "MR", background: "rgb(122,101,151)" },
        date: n % 4 === 0 ? { text: "Hoje", tone: "today" } : { text: "12 out", tone: "soft" },
        media: {
          label: "ANEXAR",
          phase: null,
          progress: 0,
          showProgress: false,
          badge: 0,
          small: false,
          usesAccent: false,
          titleColor: "rgba(20,20,22,0.7)",
          background: "rgba(20,20,22,0.031)",
          progressColor: "rgb(0,122,255)",
          hoverBackground: "rgba(0,122,255,0.12)",
          hoverTitleColor: "rgb(0,122,255)",
        },
        review: n % 7 === 0 ? "update" : "hidden",
      });
    }
  });
  apply({
    seq: 1,
    order: rows.map((row) => `${row.k}:${row.id}`),
    upsert: rows,
    theme: {
      paper: "#F5F5F6",
      card: "#FAFAFB",
      ink: "#141416",
      "ink-soft": "rgba(20,20,22,0.7)",
      "ink-mute": "rgba(20,20,22,0.42)",
      "ink-faint-85": "rgba(20,20,22,0.187)",
      "rule-50": "rgba(20,20,22,0.05)",
      "rule-soft": "rgba(20,20,22,0.06)",
      accent: "rgb(0,122,255)",
      "accent-075": "rgba(0,122,255,0.075)",
      "accent-042": "rgba(0,122,255,0.42)",
      "accent-082": "rgba(0,122,255,0.82)",
      red: "rgb(255,59,48)",
      green: "rgb(40,205,65)",
      "green-18": "rgba(40,205,65,0.18)",
      "green-04": "rgba(40,205,65,0.04)",
      orange: "rgb(255,149,0)",
      "orange-16": "rgba(255,149,0,0.16)",
      "success-fill": "rgb(214,245,224)",
      "success-ink": "rgb(11,87,43)",
    },
    insets: { top: 92, bottom: 12, occlusion: 82, mode: "padding" },
  });
  document.body.style.background = "#F5F5F6";
}
