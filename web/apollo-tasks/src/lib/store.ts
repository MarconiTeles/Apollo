// Tiny external store read through `useSyncExternalStore`. Swift sends
// diffs; unchanged rows keep their object identity so memoised rows skip
// rendering entirely (a media progress tick touches exactly one row).

import type { FontBoxes, Glyph, Insets, Patch, RowPayload, Widths } from "./types";
import { rowKey } from "./types";

export interface ListState {
  seq: number;
  rows: RowPayload[];
  selected: ReadonlySet<string>;
  popupOpen: boolean;
  windowKey: boolean;
  theme: Record<string, string>;
  dark: boolean;
  widths: Widths;
  insets: Insets;
  glyphs: Record<string, Glyph>;
  fonts: FontBoxes;
  /** True when the latest row change should reflow with motion. */
  animate: boolean;
  /** Increments on every row-set change (FLIP trigger). */
  rowsVersion: number;
  resetScrollToken: number;
  dropDoneToken: number;
}

const byKey = new Map<string, RowPayload>();
let order: string[] = [];

let state: ListState = {
  seq: 0,
  rows: [],
  selected: new Set(),
  popupOpen: false,
  windowKey: true,
  theme: {},
  dark: false,
  widths: { priority: 112, assignee: 132, date: 92 },
  insets: { top: 92, bottom: 12, occlusion: 82, mode: "padding" },
  glyphs: {},
  fonts: { title: 16, priority: 11, assignee: 13, date: 13, headerTitle: 13, headerCount: 12, slot: 13 },
  animate: false,
  rowsVersion: 0,
  resetScrollToken: 0,
  dropDoneToken: 0,
};

const listeners = new Set<() => void>();

export function apply(patch: Patch) {
  const next: ListState = { ...state, seq: patch.seq };
  let rowsChanged = false;
  if (patch.reset) {
    byKey.clear();
    order = [];
    rowsChanged = true;
  }
  if (patch.remove) {
    for (const key of patch.remove) byKey.delete(key);
    rowsChanged = true;
  }
  if (patch.upsert) {
    for (const row of patch.upsert) byKey.set(rowKey(row), row);
    rowsChanged = true;
  }
  if (patch.order) {
    order = patch.order;
    rowsChanged = true;
  }
  if (rowsChanged) {
    const rows: RowPayload[] = [];
    for (const key of order) {
      const row = byKey.get(key);
      if (row) rows.push(row);
    }
    next.rows = rows;
    next.rowsVersion = state.rowsVersion + 1;
    next.animate = patch.animate === true;
  }
  if (patch.selected) next.selected = new Set(patch.selected);
  if (patch.popupOpen !== undefined) next.popupOpen = patch.popupOpen;
  if (patch.windowKey !== undefined) next.windowKey = patch.windowKey;
  if (patch.theme) next.theme = patch.theme;
  if (patch.dark !== undefined) next.dark = patch.dark;
  if (patch.widths) next.widths = patch.widths;
  if (patch.insets) next.insets = patch.insets;
  if (patch.glyphs) next.glyphs = { ...state.glyphs, ...patch.glyphs };
  if (patch.fonts) next.fonts = patch.fonts;
  if (patch.resetScroll) next.resetScrollToken = state.resetScrollToken + 1;
  if (patch.dropDone) next.dropDoneToken = state.dropDoneToken + 1;
  state = next;
  listeners.forEach((listener) => listener());
}

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export const read = () => state;
