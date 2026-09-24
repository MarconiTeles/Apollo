// Swift → JS contract (BoardReactView.swift, `BoardReactPatch`).
//
// Swift owns the task universe (active list + other lists the task was
// added to, sidebar filters, archived/closed scope), every colour (resolved
// by AppKit under the web view's appearance) and every mutation. The page
// owns grouping, sorting, local search, collapse state presentation,
// composers, pickers and drag & drop.

export type DateTone = "overdue" | "today" | "soon" | "soft";
export type GroupBy = "status" | "assignee" | "priority" | "tag" | "due";
export type SortField = "manual" | "due" | "priority" | "title" | "created" | "updated";
export type CardSize = "s" | "m" | "l";
export type SubtaskMode = "cards" | "nested" | "hidden";

export interface Person {
  id: number;
  name: string;
  initials: string;
  /** Resolved CSS colour. */
  background: string;
  /** `apollo-avatar:` URL. */
  photo?: string;
}

export interface TagPayload {
  name: string;
  fg: string;
  bg: string;
}

export interface CardPayload {
  id: string;
  title: string;
  /** Lower-cased status name. */
  status: string;
  closed: boolean;
  /** 0 = none, 1 urgent … 4 low (ClickUp numbering). */
  priority: number;
  assignees: number[];
  tags: string[];
  /** Due date, epoch ms. */
  due?: number;
  start?: number;
  created?: number;
  updated?: number;
  hasDescription: boolean;
  /** Visible attachments; null = not loaded yet (never shown as zero). */
  attachments: number | null;
  checklist?: { done: number; total: number } | null;
  comments?: number | null;
  /** `apollo-cover:` URL of the first image/video attachment. */
  cover?: string;
  parentId?: string;
  parentTitle?: string;
  /** Home list name when the task lives in another list (TIML). */
  otherList?: string;
  /** "WORKSPACE · LIST" (native card breadcrumb), already uppercased. */
  crumb?: string;
}

export interface StatusPayload {
  key: string;
  name: string;
  /** Workspace colour as CSS (ClickUp's own hue, not the editorial remap). */
  color: string;
  /** Display-P3 components ("r g b") of `color`. */
  sc: string;
  closed: boolean;
}

export interface Prefs {
  groupBy: GroupBy;
  sort: SortField;
  desc: boolean;
  size: CardSize;
  covers: boolean;
  emptyFields: boolean;
  collapseEmpty: boolean;
  showClosed: boolean;
  subtasks: SubtaskMode;
  /** Collapsed group keys, `${groupBy}:${key}`. */
  collapsed: string[];
  /** Card fields the user can hide (Customize → Campos). */
  hidden: string[];
}

export interface Insets {
  top: number;
  leading: number;
  bottom: number;
  /** Floating native chrome over the lanes' bottom: scroll room only. */
  overlay?: number;
}

export interface Glyph {
  url: string;
  width: number;
  height: number;
}

export interface Patch {
  seq: number;
  reset?: boolean;
  upsert?: CardPayload[];
  remove?: string[];
  /** Card ids in Swift's scope order (the fallback for manual order). */
  order?: string[];
  statuses?: StatusPayload[];
  members?: Person[];
  tags?: TagPayload[];
  /** Manual order per group, keyed `${groupBy}:${key}`. */
  orders?: Record<string, string[]>;
  prefs?: Prefs;
  selected?: string[];
  me?: number | null;
  listName?: string;
  popupOpen?: boolean;
  windowKey?: boolean;
  theme?: Record<string, string>;
  dark?: boolean;
  insets?: Insets;
  glyphs?: Record<string, Glyph>;
  resetScroll?: boolean;
  /** Board-only menu entry "Nova subtarefa" asks the card for a composer. */
  subtaskComposer?: string;
  /** Native toolbar search field. */
  query?: string;
  /** Native control command: "collapseAll", "expandAll", "compose:<gk>". */
  command?: string;
}

export const DEFAULT_PREFS: Prefs = {
  groupBy: "status",
  sort: "manual",
  desc: false,
  size: "m",
  covers: true,
  emptyFields: false,
  collapseEmpty: false,
  showClosed: false,
  subtasks: "cards",
  collapsed: [],
  hidden: [],
};
