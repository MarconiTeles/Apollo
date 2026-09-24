// Pure projection: Swift's card universe + preferences + local search →
// the columns on screen. Grouping follows ClickUp's Board: multi-value
// fields (assignees, tags) place the card in every matching column.

import { dueBucket, DUE_BUCKETS } from "./dates";
import type { BoardState } from "./store";
import type { CardPayload, GroupBy, Prefs } from "./types";

export interface Group {
  key: string;
  /** `${groupBy}:${key}` — collapse state and manual-order key. */
  gk: string;
  title: string;
  /** CSS colour of the column's accent. */
  color: string;
  /** Status groups: Display-P3 components for tints; others use color-mix. */
  sc?: string;
  /** Status pill vs avatar/flag/tag header. */
  kind: GroupBy;
  cards: CardPayload[];
  collapsed: boolean;
  /** A new card created here gets a deterministic value for this group. */
  canCreate: boolean;
  /** Dropping into this group can set its value deterministically. */
  canDrop: boolean;
  closed?: boolean;
  memberId?: number;
}

export interface Projection {
  groups: Group[];
  /** Card ids left-to-right, top-to-bottom (Shift range, drags). */
  ordered: string[];
  /** Nested mode: parent id → subtask cards. */
  children: ReadonlyMap<string, CardPayload[]>;
  total: number;
}

export const PRIORITIES: { value: number; label: string; color: string }[] = [
  { value: 1, label: "Urgente", color: "var(--prio-1)" },
  { value: 2, label: "Alta", color: "var(--prio-2)" },
  { value: 3, label: "Normal", color: "var(--prio-3)" },
  { value: 4, label: "Baixa", color: "var(--prio-4)" },
];

export const NONE = "none";

const fold = (text: string) =>
  text
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase();

function matcher(query: string, state: BoardState) {
  const tokens = fold(query).split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return null;
  return (card: CardPayload) => {
    const haystack = fold(
      [
        card.title,
        card.parentTitle ?? "",
        card.otherList ?? "",
        card.tags.join(" "),
        card.assignees.map((id) => state.members.get(id)?.name ?? "").join(" "),
      ].join(" "),
    );
    return tokens.every((token) => haystack.includes(token));
  };
}

function groupKeys(card: CardPayload, groupBy: GroupBy, now: Date): string[] {
  switch (groupBy) {
    case "status":
      return [card.status];
    case "assignee":
      return card.assignees.length ? card.assignees.map(String) : [NONE];
    case "priority":
      return [card.priority >= 1 && card.priority <= 4 ? String(card.priority) : NONE];
    case "tag":
      return card.tags.length ? card.tags : [NONE];
    case "due":
      return [dueBucket(card.due, now)];
  }
}

function baseGroups(state: BoardState, groupBy: GroupBy, present: Map<string, CardPayload[]>): Omit<Group, "cards" | "collapsed" | "gk">[] {
  const neutral = "var(--ink-faint)";
  switch (groupBy) {
    case "status": {
      const out: Omit<Group, "cards" | "collapsed" | "gk">[] = state.statuses.map((s) => ({
        key: s.key,
        title: s.name,
        color: s.color,
        sc: s.sc,
        kind: groupBy,
        canCreate: true,
        canDrop: true,
        closed: s.closed,
      }));
      // Cards whose status is not in the list's workflow (moved lists,
      // stale cache) still get a column instead of disappearing.
      for (const key of present.keys()) {
        if (!out.some((g) => g.key === key)) {
          out.push({ key, title: key, color: neutral, sc: undefined, kind: groupBy, canCreate: false, canDrop: false, closed: false });
        }
      }
      return out;
    }
    case "assignee": {
      const ids = [...present.keys()].filter((k) => k !== NONE).map(Number);
      if (state.me != null && !ids.includes(state.me)) ids.push(state.me);
      const people = ids
        .map((id) => state.members.get(id) ?? { id, name: `#${id}`, initials: "?", background: neutral })
        .sort((a, b) => (a.id === state.me ? -1 : b.id === state.me ? 1 : a.name.localeCompare(b.name, "pt-BR")));
      return [
        { key: NONE, title: "Sem responsável", color: neutral, kind: groupBy, canCreate: true, canDrop: true },
        ...people.map((p) => ({
          key: String(p.id),
          title: p.name,
          color: p.background,
          kind: groupBy,
          canCreate: true,
          canDrop: true,
          memberId: p.id,
        })),
      ];
    }
    case "priority":
      return [
        ...PRIORITIES.map((p) => ({ key: String(p.value), title: p.label, color: p.color, kind: groupBy, canCreate: true, canDrop: true })),
        { key: NONE, title: "Sem prioridade", color: neutral, kind: groupBy, canCreate: true, canDrop: true },
      ];
    case "tag": {
      const names = [...present.keys()].filter((k) => k !== NONE).sort((a, b) => a.localeCompare(b, "pt-BR"));
      return [
        { key: NONE, title: "Sem etiqueta", color: neutral, kind: groupBy, canCreate: true, canDrop: true },
        ...names.map((name) => ({
          key: name,
          title: name,
          color: state.tags.get(name)?.bg ?? neutral,
          kind: groupBy,
          canCreate: true,
          canDrop: true,
        })),
      ];
    }
    case "due":
      return DUE_BUCKETS.map((b) => ({
        key: b.key,
        title: b.label,
        color: b.color,
        kind: groupBy,
        // Only buckets with one unambiguous date accept new/dropped cards.
        canCreate: b.settable,
        canDrop: b.settable,
      }));
  }
}

function compare(field: Prefs["sort"], a: CardPayload, b: CardPayload): number {
  const missingLast = (x?: number, y?: number) =>
    x == null && y == null ? 0 : x == null ? 1 : y == null ? -1 : x - y;
  switch (field) {
    case "due":
      return missingLast(a.due, b.due);
    case "priority":
      return missingLast(a.priority || undefined, b.priority || undefined);
    case "title":
      return a.title.localeCompare(b.title, "pt-BR", { numeric: true });
    case "created":
      return missingLast(a.created, b.created);
    case "updated":
      return missingLast(a.updated, b.updated);
    default:
      return 0;
  }
}

export function project(state: BoardState, query: string, now = new Date()): Projection {
  const { prefs } = state;
  const match = matcher(query, state);
  const rank = new Map(state.order.map((id, index) => [id, index]));
  const children = new Map<string, CardPayload[]>();

  const scope: CardPayload[] = [];
  for (const id of state.order) {
    const card = state.cards.get(id);
    if (!card) continue;
    if (card.parentId && prefs.subtasks !== "cards") {
      // Nested: shown inside the parent card when the parent is on the
      // board; an orphan subtask (parent filtered out) stays a card.
      if (prefs.subtasks === "hidden") continue;
      if (state.cards.has(card.parentId)) {
        const list = children.get(card.parentId) ?? [];
        list.push(card);
        children.set(card.parentId, list);
        continue;
      }
    }
    if (match && !match(card)) continue;
    scope.push(card);
  }

  const buckets = new Map<string, CardPayload[]>();
  for (const card of scope) {
    for (const key of groupKeys(card, prefs.groupBy, now)) {
      const list = buckets.get(key) ?? [];
      list.push(card);
      buckets.set(key, list);
    }
  }

  const collapsed = new Set(prefs.collapsed);
  const groups: Group[] = baseGroups(state, prefs.groupBy, buckets).map((base) => {
    const gk = `${prefs.groupBy}:${base.key}`;
    let list = buckets.get(base.key) ?? [];
    if (prefs.sort === "manual") {
      const saved = state.orders[gk];
      if (saved?.length) {
        const position = new Map(saved.map((id, index) => [id, index]));
        list = [...list].sort((a, b) => {
          const pa = position.get(a.id);
          const pb = position.get(b.id);
          if (pa != null && pb != null) return pa - pb;
          if (pa != null) return -1;
          if (pb != null) return 1;
          return (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0);
        });
      }
    } else {
      const direction = prefs.desc ? -1 : 1;
      list = [...list].sort(
        (a, b) => compare(prefs.sort, a, b) * direction || (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0),
      );
    }
    const isCollapsed = collapsed.has(gk) || (prefs.collapseEmpty && list.length === 0 && !query);
    return { ...base, gk, cards: list, collapsed: isCollapsed };
  });

  const seen = new Set<string>();
  const ordered: string[] = [];
  for (const group of groups) {
    if (group.collapsed) continue;
    for (const card of group.cards) {
      if (seen.has(card.id)) continue;
      seen.add(card.id);
      ordered.push(card.id);
    }
  }
  return { groups, ordered, children, total: scope.length };
}
