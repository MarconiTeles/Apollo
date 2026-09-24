// Tiny external store read through `useSyncExternalStore`. Swift sends whole
// sections when they change; `share` keeps the identity of every unchanged
// day, cell and event so memoised components skip rendering entirely.

import type { Glyph, Layout, Metrics, MonthPayload, Patch, ScrollCommand, TimelineDay } from "./types";

export interface AgendaState {
  seq: number;
  theme: Record<string, string>;
  dark: boolean;
  metrics: Metrics;
  glyphs: Record<string, Glyph>;
  layout: Layout;
  timeline: TimelineDay[];
  month: MonthPayload | null;
  error: string | null;
  reduceMotion: boolean;
  todayToken: number;
  scroll: ScrollCommand | null;
}

let state: AgendaState = {
  seq: 0,
  theme: {},
  dark: false,
  metrics: {
    cardTitle: 17,
    cardSubtitle: 12,
    avatar: 11,
    dateLabel: 11,
    dateNumber: 29,
    empty: 14,
    weekday: 11,
    cellNumber: 13,
    cellMonth: 12,
    folio: 11,
    relative: 12,
    rowTitle: 13,
    rowDetail: 12,
    panelEmpty: 12,
    banner: 12,
  },
  glyphs: {},
  layout: { agendaTop: 106, monthTop: 106, occlusion: 81 },
  timeline: [],
  month: null,
  error: null,
  reduceMotion: false,
  todayToken: 0,
  scroll: null,
};

const listeners = new Set<() => void>();

/** Returns `prev` when `next` is structurally equal; otherwise `next` with
 *  every equal sub-tree replaced by its previous object. */
function share<T>(prev: T, next: T): T {
  if (prev === next) return prev;
  if (Array.isArray(prev) && Array.isArray(next)) {
    let same = prev.length === next.length;
    const out = next.map((item, index) => {
      const shared = index < prev.length ? share(prev[index], item) : item;
      if (shared !== prev[index]) same = false;
      return shared;
    });
    return (same ? prev : out) as T;
  }
  if (prev && next && typeof prev === "object" && typeof next === "object" && !Array.isArray(prev) && !Array.isArray(next)) {
    const a = prev as Record<string, unknown>;
    const b = next as Record<string, unknown>;
    const keys = Object.keys(b);
    let same = keys.length === Object.keys(a).length;
    const out: Record<string, unknown> = {};
    for (const key of keys) {
      const shared = key in a ? share(a[key], b[key]) : b[key];
      if (shared !== a[key]) same = false;
      out[key] = shared;
    }
    return (same ? prev : out) as T;
  }
  return next;
}

export function apply(patch: Patch) {
  const next: AgendaState = { ...state, seq: patch.seq };
  if (patch.theme) next.theme = share(state.theme, patch.theme);
  if (patch.dark !== undefined) next.dark = patch.dark;
  if (patch.metrics) next.metrics = share(state.metrics, patch.metrics);
  if (patch.glyphs) next.glyphs = share(state.glyphs, patch.glyphs);
  if (patch.layout) next.layout = share(state.layout, patch.layout);
  if (patch.timeline) next.timeline = share(state.timeline, patch.timeline);
  if (patch.month) next.month = share(state.month, patch.month);
  if (patch.error !== undefined) next.error = patch.error;
  if (patch.reduceMotion !== undefined) next.reduceMotion = patch.reduceMotion;
  if (patch.todayToken !== undefined) next.todayToken = patch.todayToken;
  if (patch.scroll) next.scroll = patch.scroll;
  state = next;
  listeners.forEach((listener) => listener());
}

export const read = () => state;

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
