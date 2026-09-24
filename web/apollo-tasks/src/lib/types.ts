// Swift → JS contract (MyTasksReactList.swift, `MyTasksReactPayload`).
//
// Every colour arrives already resolved by AppKit under the web view's
// effective appearance, so light/dark, the system accent and the vibrant
// status palette are the exact values the native row would have painted.

export type ReviewState = "hidden" | "update" | "reviewed";
export type DateTone = "today" | "overdue" | "soft";

export interface MediaPayload {
  label: string;
  /** TaskMediaTransferStore.Phase name; absent (or null) for ANEXAR. */
  phase?: string | null;
  /** Mask fraction 0…1 (1 for ENVIAR, 0 when idle). */
  progress: number;
  showProgress: boolean;
  badge: number;
  small: boolean;
  usesAccent: boolean;
  titleColor: string;
  background: string;
  progressColor: string;
  hoverBackground: string;
  hoverTitleColor: string;
}

export interface TaskRowPayload {
  k: "t";
  id: string;
  title: string;
  completed: boolean;
  /** Lower-cased status name: drop target and header lookup. */
  status: string;
  /** Display-P3 components ("r g b") of the vibrant status colour. */
  sc: string;
  priority?: { label: string; color: string };
  assignee?: { name: string; initials: string; background: string; photo?: string };
  date?: { text: string; tone: DateTone };
  media: MediaPayload;
  review: ReviewState;
}

export interface HeaderRowPayload {
  k: "h";
  /** CUStatus.id (the status name). */
  id: string;
  status: string;
  title: string;
  color: string;
  /** Display-P3 components of `color` (drop slot alphas). */
  sc: string;
  count: number;
  /** Open tasks past due (collapsed-group summary). */
  overdue: number;
  collapsed: boolean;
  first: boolean;
}

export type RowPayload = TaskRowPayload | HeaderRowPayload;

export interface Glyph {
  url: string;
  width: number;
  height: number;
}

export interface Widths {
  priority: number;
  assignee: number;
  date: number;
}

export interface Insets {
  top: number;
  bottom: number;
  /** Top band covered by the SwiftUI page header (no hover there). */
  occlusion: number;
  /** "obscured": WKWebView.obscuredContentInsets carry the insets. */
  mode: "obscured" | "padding";
}

/** Heights of the native NSTextField cells (cellSize.height). */
export interface FontBoxes {
  title: number;
  priority: number;
  assignee: number;
  date: number;
  headerTitle: number;
  headerCount: number;
  slot: number;
}

export interface Patch {
  seq: number;
  /** Full snapshot: forget every row the page held before. */
  reset?: boolean;
  /** Row keys ("t:<id>" / "h:<id>") in display order. */
  order?: string[];
  upsert?: RowPayload[];
  remove?: string[];
  selected?: string[];
  popupOpen?: boolean;
  windowKey?: boolean;
  theme?: Record<string, string>;
  dark?: boolean;
  widths?: Widths;
  insets?: Insets;
  glyphs?: Record<string, Glyph>;
  fonts?: FontBoxes;
  /** Reflow surviving rows (collapse/expand/status moves). */
  animate?: boolean;
  resetScroll?: boolean;
  /** A native drop finished: remove the insertion slot. */
  dropDone?: boolean;
}

export const rowKey = (row: RowPayload) => `${row.k}:${row.id}`;
