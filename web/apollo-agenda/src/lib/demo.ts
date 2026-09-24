// Vite dev server only: a deterministic agenda (the screenshot of 24/09)
// in the dark Studio palette, so the page can be iterated in a browser.

import { apply } from "./store";
import type { EventPayload, MonthCell, TimelineDay } from "./types";

const WEEK = ["DOM", "SEG", "TER", "QUA", "QUI", "SEX", "SÁB"];
const MONTHS = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"];
const LONG_WEEK = ["Domingo", "Segunda-feira", "Terça-feira", "Quarta-feira", "Quinta-feira", "Sexta-feira", "Sábado"];
const LONG_MONTHS = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"];

const blue = "0.23 0.53 0.86";
const graphite = "0.38 0.38 0.38";
const key = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

function event(id: string, title: string, start: string, end: string, location: string, accepted: boolean, initials: string): EventPayload {
  const range = `${start} – ${end}`;
  return {
    key: `primary|${id}`,
    title,
    subtitle: location ? `${range} · ${location}` : range,
    detail: location ? `${range} · ${location}` : range,
    time: start,
    accepted,
    declined: false,
    cardc: accepted ? blue : graphite,
    dot: "color(display-p3 0.36 0.78 0.98)",
    darkInk: false,
    monogram: title.match(/[\p{L}\p{N}]/u)?.[0]?.toUpperCase() ?? "•",
    initials,
    start,
    end,
    allDay: false,
    location: location || undefined,
    join: accepted ? { label: "Meet" } : undefined,
    people: [
      { name: "Júlia Prado (organizador)", initials: "JP", color: "#7986CB", organizer: true },
      { name: "Marconi Reis", initials: "MR", color: "#33B679", organizer: false },
      { name: "Eduardo Lima", initials: "EL", color: "#E67C73", organizer: false },
      ...(accepted ? [] : [
        { name: "Vitória Alves", initials: "VA", color: "#F4511E", organizer: false },
        { name: "Pedro Nasser", initials: "PN", color: "#039BE5", organizer: false },
        { name: "Ana Souza", initials: "AS", color: "#8E24AA", organizer: false },
      ]),
    ],
    phase: start === "10:00" ? "now" : start === "09:30" && title.startsWith("Daily Receita") ? "past" : undefined,
  };
}

function eventsFor(date: Date): EventPayload[] {
  const day = date.getDay();
  if (day === 0 || day === 6) return [];
  const list = [event(`daily-${key(date)}`, "Daily Receita Minimal {MKT Minimal}", "09:30", "10:00", "Boteco", false, "J")];
  if (date.getDate() === 24) list.push(event("grav", "Gravação - Perpetuo Minimal", "10:00", "18:00", "Estúdio", true, "E"));
  if (day === 1 || day === 5) list.push(event(`copy-${key(date)}`, "Daily de Copy / Vídeo", day === 1 ? "15:30" : "14:15", day === 1 ? "16:00" : "14:45", day === 1 ? "4. Sala de reunião" : "", true, "V"));
  if (day === 2) list.push(event(`allhands-${key(date)}`, "All Hands Moon Ventures 🚀", "11:30", "12:00", "", true, "A"));
  return list;
}

export function startDemo() {
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  const today = new Date(2026, 8, 24);
  const theme = dark
    ? {
        paper: "#141415", "paper-c": "0.078 0.078 0.082", page: "#1B1B1C", ink: "#E8E8EA", "ink-c": "0.91 0.91 0.918",
        "ink-soft": "#A0A0A6", "ink-mute": "#7A7A80", "ink-faint": "#56565B", "rule-c": "1 1 1", "rule-a": "0.07",
        accent: "#0A84FF", "accent-c": "0.04 0.52 1", label: "rgb(255 255 255 / 0.85)", "secondary-label": "rgb(255 255 255 / 0.55)",
        orange: "#FF9F0A", link: "#419CFF",
      }
    : {
        paper: "#F5F5F6", "paper-c": "0.96 0.96 0.965", page: "#FFFFFF", ink: "#141416", "ink-c": "0.078 0.078 0.086",
        "ink-soft": "rgb(20 20 22 / 0.7)", "ink-mute": "rgb(20 20 22 / 0.42)", "ink-faint": "rgb(20 20 22 / 0.22)", "rule-c": "0.078 0.078 0.086", "rule-a": "0.10",
        accent: "#007AFF", "accent-c": "0 0.48 1", label: "rgb(0 0 0 / 0.85)", "secondary-label": "rgb(0 0 0 / 0.5)",
        orange: "#FF9500", link: "#0068DA",
      };

  const timeline: TimelineDay[] = Array.from({ length: 31 }, (_, offset) => {
    const date = new Date(today);
    date.setDate(today.getDate() + offset);
    return {
      key: key(date),
      label: offset === 0 ? "HOJE" : WEEK[date.getDay()],
      day: String(date.getDate()),
      today: offset === 0,
      past: false,
      events: eventsFor(date),
    };
  });

  const first = new Date(2026, 8, 1);
  const offset = (first.getDay() + 6) % 7;
  const start = new Date(first);
  start.setDate(1 - offset);
  const count = Math.ceil((offset + 30) / 7) * 7;
  const cells: MonthCell[] = Array.from({ length: count }, (_, index) => {
    const date = new Date(start);
    date.setDate(start.getDate() + index);
    const events = eventsFor(date);
    const diff = Math.round((date.getTime() - today.getTime()) / 86_400_000);
    return {
      key: key(date),
      number: String(date.getDate()),
      monthLabel: date.getDate() === 1 ? MONTHS[date.getMonth()] : undefined,
      inMonth: date.getMonth() === 8,
      today: diff === 0,
      title: `${LONG_WEEK[date.getDay()]}, ${date.getDate()} de ${LONG_MONTHS[date.getMonth()]}`,
      relative: diff === 0 ? "Hoje" : diff === 1 ? "Amanhã" : diff === -1 ? "Ontem" : diff > 1 ? `Em ${diff} dias` : `Há ${-diff} dias`,
      tooltip: events.map((e) => `${e.time}  ${e.title}`).join("\n"),
      a11y: key(date),
      events,
    };
  });

  apply({
    seq: 1,
    theme,
    dark,
    layout: { agendaTop: 106, monthTop: 106, occlusion: 81 },
    timeline,
    month: { key: "2026-09", title: "Setembro de 2026", cells, fallback: key(today) },
    error: null,
  });
}
