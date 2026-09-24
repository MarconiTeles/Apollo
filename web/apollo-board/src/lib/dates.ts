// Dates the way the board reads them: relative words close to today
// ("Hoje", "Ontem", "Amanhã", weekday), day + month beyond.

import type { DateTone } from "./types";

const DAY = 86_400_000;

export const startOfDay = (date: Date) => new Date(date.getFullYear(), date.getMonth(), date.getDate());

/** End of the local day (23:59): Apollo's convention for "due on". */
export const endOfDay = (date: Date) =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 0).getTime();

export const addDays = (date: Date, days: number) =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);

const dayDiff = (value: number, now: Date) =>
  Math.round((startOfDay(new Date(value)).getTime() - startOfDay(now).getTime()) / DAY);

const weekday = new Intl.DateTimeFormat("pt-BR", { weekday: "short" });
const dayMonth = new Intl.DateTimeFormat("pt-BR", { day: "numeric", month: "short" });
const dayMonthYear = new Intl.DateTimeFormat("pt-BR", { day: "numeric", month: "short", year: "numeric" });

const clean = (text: string) => {
  const t = text.replace(/\./g, "").replace(" de ", " ");
  return t.charAt(0).toUpperCase() + t.slice(1);
};

export function relativeDate(value: number, now = new Date()): string {
  const diff = dayDiff(value, now);
  if (diff === 0) return "Hoje";
  if (diff === -1) return "Ontem";
  if (diff === 1) return "Amanhã";
  const date = new Date(value);
  if (diff > 1 && diff < 7) return clean(weekday.format(date));
  if (date.getFullYear() !== now.getFullYear()) return clean(dayMonthYear.format(date));
  return clean(dayMonth.format(date));
}

export function dateTone(value: number, closed: boolean, now = new Date()): DateTone {
  if (closed) return "soft";
  const diff = dayDiff(value, now);
  if (diff < 0) return "overdue";
  if (diff === 0) return "today";
  if (diff <= 2) return "soon";
  return "soft";
}

export const DUE_BUCKETS: { key: string; label: string; color: string; settable: boolean }[] = [
  { key: "overdue", label: "Atrasadas", color: "var(--overdue)", settable: false },
  { key: "today", label: "Hoje", color: "var(--accent)", settable: true },
  { key: "tomorrow", label: "Amanhã", color: "var(--ink-soft)", settable: true },
  { key: "week", label: "Próximos 7 dias", color: "var(--ink-mute)", settable: false },
  { key: "later", label: "Depois", color: "var(--ink-mute)", settable: false },
  { key: "none", label: "Sem data", color: "var(--ink-faint)", settable: true },
];

export function dueBucket(due: number | undefined, now: Date): string {
  if (due == null) return "none";
  const diff = dayDiff(due, now);
  if (diff < 0) return "overdue";
  if (diff === 0) return "today";
  if (diff === 1) return "tomorrow";
  if (diff < 8) return "week";
  return "later";
}

/** Due value for a settable bucket (null clears the date). */
export function bucketDue(key: string, now = new Date()): number | null | undefined {
  if (key === "today") return endOfDay(now);
  if (key === "tomorrow") return endOfDay(addDays(now, 1));
  if (key === "none") return null;
  return undefined;
}

export const monthTitle = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric" });
