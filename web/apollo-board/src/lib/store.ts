// External store read through `useSyncExternalStore`. Swift sends diffs;
// unchanged cards keep their object identity so memoised cards skip
// rendering (a cover arriving touches exactly one card).
//
// Local edits (preferences, manual order after a drop) apply immediately and
// are confirmed by the next Swift patch, so the board never waits for a
// round-trip to move.

import { post } from "./bridge";
import type { CardPayload, Glyph, Insets, Patch, Person, Prefs, StatusPayload, TagPayload } from "./types";
import { DEFAULT_PREFS } from "./types";

export interface BoardState {
  seq: number;
  cards: ReadonlyMap<string, CardPayload>;
  /** Swift scope order: the manual-order fallback. */
  order: readonly string[];
  cardsVersion: number;
  statuses: StatusPayload[];
  members: ReadonlyMap<number, Person>;
  memberList: Person[];
  tags: ReadonlyMap<string, TagPayload>;
  tagList: TagPayload[];
  orders: Readonly<Record<string, string[]>>;
  prefs: Prefs;
  selected: ReadonlySet<string>;
  me: number | null;
  listName: string;
  popupOpen: boolean;
  windowKey: boolean;
  theme: Record<string, string>;
  dark: boolean;
  insets: Insets;
  glyphs: Record<string, Glyph>;
  resetScrollToken: number;
  /** Bumped by every full snapshot (a new board mount): geometry is resent. */
  resetToken: number;
  subtaskComposer: { id: string; token: number } | null;
  query: string;
  command: { value: string; token: number } | null;
}

const cards = new Map<string, CardPayload>();

let state: BoardState = {
  seq: 0,
  cards,
  order: [],
  cardsVersion: 0,
  statuses: [],
  members: new Map(),
  memberList: [],
  tags: new Map(),
  tagList: [],
  orders: {},
  prefs: DEFAULT_PREFS,
  selected: new Set(),
  me: null,
  listName: "",
  popupOpen: false,
  windowKey: true,
  theme: {},
  dark: false,
  insets: { top: 52, leading: 232, bottom: 24 },
  glyphs: {},
  resetScrollToken: 0,
  resetToken: 0,
  subtaskComposer: null,
  query: "",
  command: null,
};

const listeners = new Set<() => void>();
const emit = () => listeners.forEach((listener) => listener());

export function apply(patch: Patch) {
  const next: BoardState = { ...state, seq: patch.seq };
  let cardsChanged = false;
  if (patch.reset) {
    cards.clear();
    cardsChanged = true;
    next.resetToken = state.resetToken + 1;
  }
  if (patch.remove) {
    for (const id of patch.remove) cards.delete(id);
    cardsChanged = true;
  }
  if (patch.upsert) {
    for (const card of patch.upsert) cards.set(card.id, card);
    cardsChanged = true;
  }
  if (patch.order) {
    next.order = patch.order;
    cardsChanged = true;
  }
  if (cardsChanged) {
    // A new Map identity lets memoised projections notice the change.
    next.cards = new Map(cards);
    next.cardsVersion = state.cardsVersion + 1;
  }
  if (patch.statuses) next.statuses = patch.statuses;
  if (patch.members) {
    next.memberList = patch.members;
    next.members = new Map(patch.members.map((m) => [m.id, m]));
  }
  if (patch.tags) {
    next.tagList = patch.tags;
    next.tags = new Map(patch.tags.map((t) => [t.name, t]));
  }
  if (patch.orders) next.orders = patch.orders;
  if (patch.prefs) next.prefs = { ...DEFAULT_PREFS, ...patch.prefs };
  if (patch.selected) next.selected = new Set(patch.selected);
  if (patch.me !== undefined) next.me = patch.me;
  if (patch.listName !== undefined) next.listName = patch.listName;
  if (patch.popupOpen !== undefined) next.popupOpen = patch.popupOpen;
  if (patch.windowKey !== undefined) next.windowKey = patch.windowKey;
  if (patch.theme) next.theme = patch.theme;
  if (patch.dark !== undefined) next.dark = patch.dark;
  if (patch.insets) next.insets = patch.insets;
  if (patch.glyphs) next.glyphs = { ...state.glyphs, ...patch.glyphs };
  if (patch.resetScroll) next.resetScrollToken = state.resetScrollToken + 1;
  if (patch.query !== undefined) next.query = patch.query;
  if (patch.command) next.command = { value: patch.command, token: (state.command?.token ?? 0) + 1 };
  if (patch.subtaskComposer) {
    next.subtaskComposer = { id: patch.subtaskComposer, token: (state.subtaskComposer?.token ?? 0) + 1 };
  }
  state = next;
  emit();
}

/** Preference change: applied locally at once, persisted by Swift. */
export function setPrefs(change: Partial<Prefs>) {
  const prefs = { ...state.prefs, ...change };
  state = { ...state, prefs };
  emit();
  post({ type: "prefs", prefs });
}

export function toggleCollapsed(groupKey: string) {
  const collapsed = new Set(state.prefs.collapsed);
  if (collapsed.has(groupKey)) collapsed.delete(groupKey);
  else collapsed.add(groupKey);
  setPrefs({ collapsed: [...collapsed] });
}

/** Optimistic manual order after a drop; Swift echoes the persisted map. */
export function setLocalOrders(change: Record<string, string[]>) {
  state = { ...state, orders: { ...state.orders, ...change } };
  emit();
}

/** Optimistic card edit (field pickers, drops) until Swift's patch lands. */
export function patchCards(changes: { id: string; change: Partial<CardPayload> }[]) {
  for (const { id, change } of changes) {
    const card = cards.get(id);
    if (card) cards.set(id, { ...card, ...change });
  }
  state = { ...state, cards: new Map(cards), cardsVersion: state.cardsVersion + 1 };
  emit();
}

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export const read = () => state;
