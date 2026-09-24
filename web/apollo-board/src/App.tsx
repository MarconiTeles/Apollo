import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { DragEvent as ReactDragEvent, MouseEvent as ReactMouseEvent } from "react";
import type { ColumnHandlers } from "./components/Column";
import { Column } from "./components/Column";
import { post, rectOf } from "./lib/bridge";
import { bucketDue } from "./lib/dates";
import { drawStackImage } from "./lib/dragImage";
import type { Group } from "./lib/projection";
import { NONE, project } from "./lib/projection";
import { patchCards, read, setLocalOrders, setPrefs, subscribe } from "./lib/store";
import type { CardPayload } from "./lib/types";

const PAYLOAD_PREFIX = "apollo-task-ids:";
const PAYLOAD_SEPARATOR = "\u001f";
/** Auto-scroll band at the edges of a column / the board during a drag. */
const EDGE = 56;
const QUIET_MS = 250;

interface DragSession {
  ids: string[];
  from: string;
  height: number;
}

interface Slot {
  gk: string;
  index: number;
  before: string | null;
}

const EMPTY: ReadonlySet<string> = new Set();

export function App() {
  const state = useSyncExternalStore(subscribe, read);
  const { prefs } = state;
  // Search lives in the native window toolbar (`.searchable`).
  const query = state.query;
  const [composer, setComposer] = useState<{ gk: string; position: "top" | "bottom" } | null>(null);
  const [dragging, setDragging] = useState<ReadonlySet<string>>(EMPTY);
  const [slot, setSlot] = useState<Slot | null>(null);
  const boardRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const session = useRef<DragSession | null>(null);
  const slotRef = useRef<Slot | null>(null);
  const pointer = useRef<{ x: number; y: number; column: HTMLElement | null } | null>(null);

  // ── Theme ───────────────────────────────────────────────────────────
  useLayoutEffect(() => {
    const root = document.documentElement;
    for (const [name, value] of Object.entries(state.theme)) root.style.setProperty(`--${name}`, value);
    root.classList.toggle("dark", state.dark);
  }, [state.theme, state.dark]);

  useLayoutEffect(() => {
    const root = document.documentElement.style;
    root.setProperty("--inset-top", `${state.insets.top}px`);
    root.setProperty("--inset-leading", `${state.insets.leading}px`);
    root.setProperty("--inset-bottom", `${state.insets.bottom}px`);
    root.setProperty("--inset-overlay", `${state.insets.overlay ?? 0}px`);
  }, [state.insets]);

  useLayoutEffect(() => {
    if (state.resetScrollToken === 0) return;
    for (const el of document.querySelectorAll<HTMLElement>("[data-column-scroll]")) el.scrollTop = 0;
  }, [state.resetScrollToken]);

  useEffect(() => {
    post({ type: "rendered", seq: state.seq });
  }, [state.seq]);


  // ── Projection ──────────────────────────────────────────────────────
  const projection = useMemo(() => project(state, query), [state.cards, state.order, state.statuses, state.members, state.tags, state.orders, prefs, state.me, query]); // eslint-disable-line react-hooks/exhaustive-deps
  const live = useRef({ projection, selected: state.selected });
  live.current = { projection, selected: state.selected };

  // Window subtitle ("N tarefas") follows what the board shows.
  useEffect(() => {
    post({ type: "summary", total: projection.total });
  }, [projection.total]);

  // Commands from native controls (toolbar view menu, group menu).
  useEffect(() => {
    const command = state.command?.value;
    if (!command) return;
    const groups = live.current.projection.groups;
    if (command === "collapseAll") {
      setPrefs({ collapsed: groups.map((g) => g.gk) });
    } else if (command === "expandAll") {
      setPrefs({ collapsed: [], collapseEmpty: false });
    } else if (command.startsWith("compose:")) {
      const gk = command.slice("compose:".length);
      setComposer({ gk, position: "top" });
      document.querySelector(`[data-column-scroll="${CSS.escape(gk)}"]`)?.scrollTo({ top: 0, behavior: "smooth" });
    }
  }, [state.command]);

  const statusColor = useCallback(
    (key: string) => state.statuses.find((s) => s.key === key)?.color ?? "var(--ink-faint)",
    [state.statuses],
  );

  // ── Visible cards (cover/attachment hydration) ──────────────────────
  const visible = useRef(new Set<string>());
  const visibleTimer = useRef<number | undefined>(undefined);
  const observer = useMemo(
    () =>
      new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            const id = (entry.target as HTMLElement).dataset.card;
            if (!id) continue;
            if (entry.isIntersecting) visible.current.add(id);
            else visible.current.delete(id);
          }
          window.clearTimeout(visibleTimer.current);
          visibleTimer.current = window.setTimeout(() => post({ type: "visible", ids: [...visible.current] }), QUIET_MS);
        },
        { rootMargin: "240px" },
      ),
    [],
  );
  const observed = useRef(new Map<string, HTMLElement>());

  // ── Keyboard ownership: the web view takes the keyboard only while a
  // text field is focused, so ⌘Z/Esc keep reaching the app otherwise. ─
  useEffect(() => {
    const isField = (el: EventTarget | null) => el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
    const onIn = (event: FocusEvent) => {
      if (isField(event.target)) post({ type: "editing", active: true });
    };
    const onOut = (event: FocusEvent) => {
      if (isField(event.target) && !isField(event.relatedTarget)) post({ type: "editing", active: false });
    };
    document.addEventListener("focusin", onIn);
    document.addEventListener("focusout", onOut);
    return () => {
      document.removeEventListener("focusin", onIn);
      document.removeEventListener("focusout", onOut);
    };
  }, []);

  // ── Drag auto-scroll (vertical; the native scroll view pans sideways) ─
  useEffect(() => {
    if (dragging.size === 0) return;
    let frame = 0;
    const tick = () => {
      const p = pointer.current;
      const column = p?.column;
      if (p && column) {
        const c = column.getBoundingClientRect();
        const top = c.top + state.insets.top;
        if (p.y < top + EDGE) column.scrollTop -= Math.ceil((top + EDGE - p.y) / 4);
        else if (p.y > c.bottom - EDGE) column.scrollTop += Math.ceil((p.y - (c.bottom - EDGE)) / 4);
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [dragging, state.insets.top]);

  // ── Layout for the native side: document width (NSScrollView) and each
  // group's x/width (native pills in the header band). ─────────────────
  const columnsRef = useRef<HTMLDivElement>(null);
  const lastLayout = useRef("");
  const reportLayout = useCallback(() => {
    const columns = columnsRef.current;
    if (!columns) return;
    const byGk = new Map(live.current.projection.groups.map((g) => [g.gk, g]));
    const headers = [...columns.querySelectorAll<HTMLElement>(":scope > section[data-gk]")].flatMap((el) => {
      const group = byGk.get(el.dataset.gk!);
      if (!group) return [];
      return [
        {
          gk: group.gk,
          key: group.key,
          kind: group.kind,
          title: group.title,
          count: group.cards.length,
          x: el.offsetLeft,
          w: el.offsetWidth,
          collapsed: group.collapsed,
          canCreate: group.canCreate,
          ids: group.cards.map((c) => c.id),
        },
      ];
    });
    const message = { type: "layout" as const, width: columns.scrollWidth, headers };
    const json = JSON.stringify(message);
    if (json === lastLayout.current) return;
    lastLayout.current = json;
    post(message);
  }, []);

  useLayoutEffect(() => {
    reportLayout();
  });

  useEffect(() => {
    const columns = columnsRef.current;
    if (!columns) return;
    const observer = new ResizeObserver(() => reportLayout());
    observer.observe(columns);
    return () => observer.disconnect();
  }, [reportLayout]);

  const endDrag = useCallback(() => {
    session.current = null;
    slotRef.current = null;
    pointer.current = null;
    setSlot(null);
    setDragging(EMPTY);
  }, []);

  // ── Handlers (stable identity: cards/columns stay memoised) ─────────
  const handlers = useMemo<ColumnHandlers>(
    () => ({
      activate(card: CardPayload, event: ReactMouseEvent, element: HTMLElement) {
        if (read().popupOpen) return;
        post({
          type: "activate",
          id: card.id,
          shift: event.shiftKey,
          command: event.metaKey,
          rect: rectOf(element),
          ordered: live.current.projection.ordered,
        });
      },
      menu(card, x, y) {
        if (read().popupOpen) return;
        post({ type: "menu", id: card.id, x, y });
      },
      observe(element, id) {
        const previous = observed.current.get(id);
        if (previous && previous !== element) {
          observer.unobserve(previous);
          observed.current.delete(id);
          visible.current.delete(id);
        }
        if (element) {
          observed.current.set(id, element);
          observer.observe(element);
        }
      },
      dragStart(card, event) {
        const { projection: p, selected } = live.current;
        const ids = selected.has(card.id) ? p.ordered.filter((id) => selected.has(id)) : [card.id];
        const from = (event.currentTarget.closest("[data-column-scroll]") as HTMLElement | null)?.dataset.columnScroll ?? "";
        event.dataTransfer.setData("text/plain", PAYLOAD_PREFIX + ids.join(PAYLOAD_SEPARATOR));
        event.dataTransfer.effectAllowed = "move";
        const height = event.currentTarget.getBoundingClientRect().height;
        if (ids.length > 1 && canvasRef.current) {
          const group = p.groups.find((g) => g.gk === from);
          drawStackImage(canvasRef.current, ids.length, group?.color ?? "var(--accent)", { width: 240, height: 64 });
          event.dataTransfer.setDragImage(canvasRef.current, 24, 24);
        }
        session.current = { ids, from, height: Math.min(height, 180) };
        post({ type: "dragBegin", ids });
        // Restyle the source after WebKit has captured the drag image.
        requestAnimationFrame(() => setDragging(new Set(ids)));
      },
      dragEnd(event) {
        post({ type: "dragEnd", completed: event.dataTransfer.dropEffect !== "none" });
        endDrag();
      },
      dragOver(group: Group, event: ReactDragEvent<HTMLElement>, list: HTMLElement | null) {
        const s = session.current;
        if (!s) return; // Finder files etc. stay with the native view.
        if (!group.canDrop && group.gk !== s.from) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = "move";
        const scroller = list?.parentElement ?? null;
        pointer.current = { x: event.clientX, y: event.clientY, column: scroller };
        let index = group.cards.length;
        if (list && prefs.sort === "manual") {
          const slots = [...list.querySelectorAll<HTMLElement>(":scope > .card-slot")];
          index = slots.length;
          for (let i = 0; i < slots.length; i++) {
            const r = slots[i].getBoundingClientRect();
            if (event.clientY < r.top + r.height / 2) {
              index = i;
              break;
            }
          }
        }
        const before = group.cards.slice(index).find((c) => !s.ids.includes(c.id))?.id ?? null;
        const next: Slot = { gk: group.gk, index: prefs.sort === "manual" ? index : -1, before };
        const current = slotRef.current;
        if (!current || current.gk !== next.gk || current.index !== next.index || current.before !== next.before) {
          slotRef.current = next;
          setSlot(next);
        }
      },
      drop(group: Group, event: ReactDragEvent<HTMLElement>) {
        const s = session.current;
        const target = slotRef.current;
        if (!s || !target || target.gk !== group.gk) return;
        event.preventDefault();
        const moving = s.ids;
        const groupBy = read().prefs.groupBy;
        const destIds = group.cards.map((c) => c.id).filter((id) => !moving.includes(id));
        const at = target.before ? destIds.indexOf(target.before) : destIds.length;
        const order = [...destIds.slice(0, at < 0 ? destIds.length : at), ...moving, ...destIds.slice(at < 0 ? destIds.length : at)];
        const sourceGroup = live.current.projection.groups.find((g) => g.gk === s.from);
        const crossing = s.from !== group.gk;
        const sourceOrder = crossing && sourceGroup ? sourceGroup.cards.map((c) => c.id).filter((id) => !moving.includes(id)) : undefined;
        if (read().prefs.sort === "manual") {
          const change: Record<string, string[]> = { [group.gk]: order };
          if (sourceOrder && sourceGroup) change[sourceGroup.gk] = sourceOrder;
          setLocalOrders(change);
        }
        if (crossing) optimisticMove(moving, groupBy, s.from.slice(groupBy.length + 1), group.key);
        post({
          type: "drop",
          ids: moving,
          groupBy,
          from: s.from ? s.from.slice(groupBy.length + 1) : null,
          to: group.key,
          before: target.before,
          order,
          sourceOrder,
        });
        endDrag();
      },
      toggleCollapsed(group) {
        const collapsed = new Set(read().prefs.collapsed);
        if (group.collapsed && !collapsed.has(group.gk)) {
          // Collapsed only because it is empty: expanding means turning the
          // automatic rule off, not remembering a manual collapse.
          setPrefs({ collapseEmpty: false });
          return;
        }
        if (collapsed.has(group.gk)) collapsed.delete(group.gk);
        else collapsed.add(group.gk);
        setPrefs({ collapsed: [...collapsed] });
      },
      openMenu(group, anchor) {
        post({
          type: "columnMenu",
          gk: group.gk,
          title: group.title,
          canCreate: group.canCreate,
          ids: group.cards.map((c) => c.id),
          rect: rectOf(anchor),
        });
      },
      create(group, title, token, position) {
        post({ type: "create", token, title, groupBy: group.kind, group: group.key, position });
      },
      setComposer(gk, position) {
        setComposer(gk ? { gk, position } : null);
      },
    }),
    [observer, endDrag, prefs.sort],
  );


  return (
    <div className="app" data-size={prefs.size} data-dragging={dragging.size ? "" : undefined} data-inert={state.popupOpen ? "" : undefined}>
      <div
        ref={boardRef}
        className="board"
        onClick={(event) => {
          if (event.target === event.currentTarget || (event.target as HTMLElement).classList.contains("columns")) {
            if (state.selected.size) post({ type: "clearSelection" });
          }
        }}
        onDragLeave={(event) => {
          if (!event.relatedTarget && slotRef.current) {
            slotRef.current = null;
            setSlot(null);
          }
        }}
      >
        <div ref={columnsRef} className="columns">
          {projection.groups.map((group) => (
            <Column
              key={group.gk}
              group={group}
              prefs={prefs}
              members={state.members}
              tags={state.tags}
              selected={state.selected}
              dragging={dragging}
              slot={slot && slot.gk === group.gk ? { index: slot.index, height: session.current?.height ?? 72 } : null}
              composer={composer?.gk === group.gk ? composer.position : null}
              children={projection.children}
              statusColor={statusColor}
              subtaskComposer={state.subtaskComposer}
              inert={state.popupOpen}
              handlers={handlers}
            />
          ))}
          {query && projection.total === 0 && <div className="empty-search">Nenhuma tarefa corresponde a “{query}”.</div>}
        </div>
      </div>
      <canvas ref={canvasRef} className="drag-canvas" aria-hidden="true" />
    </div>
  );
}

/** Mirror of the Swift mutation so the card lands in its column at once. */
function optimisticMove(ids: string[], groupBy: string, from: string, to: string) {
  const { cards } = read();
  const changes: { id: string; change: Partial<CardPayload> }[] = [];
  for (const id of ids) {
    const card = cards.get(id);
    if (!card) continue;
    switch (groupBy) {
      case "status":
        changes.push({ id, change: { status: to } });
        break;
      case "priority":
        changes.push({ id, change: { priority: to === NONE ? 0 : Number(to) } });
        break;
      case "assignee": {
        const without = card.assignees.filter((a) => String(a) !== from);
        const next = to === NONE ? without : [...new Set([...without, Number(to)])];
        changes.push({ id, change: { assignees: next } });
        break;
      }
      case "tag": {
        const without = card.tags.filter((t) => t !== from);
        const next = to === NONE ? without : [...new Set([...without, to])];
        changes.push({ id, change: { tags: next } });
        break;
      }
      case "due": {
        const due = bucketDue(to);
        if (due !== undefined) changes.push({ id, change: { due: due ?? undefined } });
        break;
      }
    }
  }
  if (changes.length) patchCards(changes);
}
