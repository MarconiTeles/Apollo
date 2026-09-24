// Browser-only fixture (Vite dev server). Never part of the hosted path:
// WKWebView always receives real patches from MyTasksReactHost. It answers
// toggles and status moves the way the host does, so motion can be judged.

import { apply } from "./store";
import type { HeaderRowPayload, RowPayload, TaskRowPayload } from "./types";

const statuses = [
  { name: "cancelado", sc: "0.69 0.25 0.17", color: "rgb(176,64,44)", tasks: 0 },
  { name: "a fazer", sc: "0.33 0.34 0.49", color: "rgb(84,87,126)", tasks: 8 },
  { name: "em andamento", sc: "0.69 0.38 0.18", color: "rgb(176,97,46)", tasks: 13 },
  { name: "revisão", sc: "0.48 0.4 0.59", color: "rgb(122,101,151)", tasks: 18 },
  { name: "concluído", sc: "0.25 0.42 0.29", color: "rgb(63,107,74)", tasks: 23 },
];

const media = {
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
};

const collapsed = new Set<string>();
const tasks: TaskRowPayload[] = [];
let seq = 1;

function build(): RowPayload[] {
  const rows: RowPayload[] = [];
  statuses.forEach((status, index) => {
    const own = tasks.filter((task) => task.status === status.name);
    const header: HeaderRowPayload = {
      k: "h",
      id: status.name,
      status: status.name,
      title: status.name.toUpperCase(),
      color: status.color,
      sc: status.sc,
      count: own.length,
      overdue: own.filter((task) => task.date?.tone === "overdue").length,
      collapsed: collapsed.has(status.name),
      first: index === 0,
    };
    rows.push(header);
    if (!collapsed.has(status.name)) rows.push(...own);
  });
  return rows;
}

function push(animate: boolean, extra: Record<string, unknown> = {}) {
  const rows = build();
  apply({ seq: ++seq, reset: !animate, order: rows.map((row) => `${row.k}:${row.id}`), upsert: rows, animate, ...extra });
}

export function startDemo() {
  let n = 0;
  statuses.forEach((status) => {
    for (let i = 0; i < status.tasks; i++, n++) {
      tasks.push({
        k: "t",
        id: `demo-${n}`,
        title: `Tarefa de demonstração ${n + 1} — roteiro, gravação e edição`,
        completed: false,
        status: status.name,
        sc: status.sc,
        priority: n % 3 === 0 ? { label: "URGENTE", color: "rgb(168,57,42)" } : undefined,
        assignee: { name: "Marconi", initials: "MR", background: "rgb(58,58,64)" },
        date:
          n % 5 === 0
            ? { text: "3 de set.", tone: "overdue" }
            : n % 4 === 0
              ? { text: "Hoje", tone: "today" }
              : { text: "12 out", tone: "soft" },
        media,
        review: n % 7 === 0 ? "update" : "hidden",
      });
    }
  });
  window.__apolloTasksDemo = (message) => {
    if (message.type === "toggle") {
      if (collapsed.has(message.status)) collapsed.delete(message.status);
      else collapsed.add(message.status);
      push(true);
    } else if (message.type === "drop") {
      const ids = message.raw.replace("apollo-task-ids:", "").split("\u001F");
      tasks.forEach((task, index) => {
        if (ids.includes(task.id)) tasks[index] = { ...task, status: message.status };
      });
      push(true);
    }
  };
  push(false, {
    theme: {
      paper: "#F5F5F6",
      card: "#FAFAFB",
      ink: "#141416",
      "ink-soft": "rgba(20,20,22,0.7)",
      "ink-mute": "rgba(20,20,22,0.42)",
      "ink-faint": "rgba(20,20,22,0.22)",
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
