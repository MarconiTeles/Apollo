// One board group: its cards (the group pill, "+" and "…" are native, in
// the header band, placed from the geometry this page reports). Collapsed
// groups fold into a narrow strip that still accepts drops.

import { memo, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties, DragEvent as ReactDragEvent } from "react";
import { EASE_OUT, prefersReducedMotion } from "../lib/motion";
import type { Group } from "../lib/projection";
import type { CardPayload, Person, Prefs, TagPayload } from "../lib/types";
import { Card } from "./Card";
import type { CardHandlers } from "./Card";
import { Composer } from "./Composer";
import { Icon } from "./Icon";

export interface ColumnHandlers extends CardHandlers {
  toggleCollapsed(group: Group): void;
  openMenu(group: Group, anchor: HTMLElement): void;
  create(group: Group, title: string, token: string, position: "top" | "bottom"): void;
  setComposer(gk: string | null, position: "top" | "bottom"): void;
  dragOver(group: Group, event: ReactDragEvent<HTMLElement>, list: HTMLElement | null): void;
  drop(group: Group, event: ReactDragEvent<HTMLElement>): void;
}

interface ColumnProps {
  group: Group;
  prefs: Prefs;
  members: ReadonlyMap<number, Person>;
  tags: ReadonlyMap<string, TagPayload>;
  selected: ReadonlySet<string>;
  dragging: ReadonlySet<string>;
  /** Insertion slot while a drag hovers this group. */
  slot: { index: number; height: number } | null;
  composer: "top" | "bottom" | null;
  children: ReadonlyMap<string, CardPayload[]>;
  statusColor: (key: string) => string;
  subtaskComposer: { id: string; token: number } | null;
  inert: boolean;
  handlers: ColumnHandlers;
}

const REFLOW_MS = 220;
/** Cards that appear on screen (first paint, filters, moves, new tasks)
 * rise into place in a short cascade, capped so long columns never wait. */
const ENTER_MS = 280;
const ENTER_STAGGER_MS = 34;
const ENTER_STAGGER_CAP_MS = 300;
/** Cards mounted per step: a 1.000-task column opens with the first page
 * and grows as its end approaches (ClickUp also pages long columns). */
const PAGE = 36;

export const Column = memo(function Column(props: ColumnProps) {
  const { group, prefs, handlers, slot, composer } = props;
  const listRef = useRef<HTMLDivElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  const tops = useRef(new Map<string, number>());
  const [limit, setLimit] = useState(PAGE);
  const hasMore = group.cards.length > limit;

  useEffect(() => {
    const target = sentinel.current;
    if (!target || !hasMore) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) setLimit((value) => value + PAGE);
      },
      { root: target.closest(".column-scroll"), rootMargin: "0px 0px 900px 0px" },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, [hasMore, limit]);

  const flipKey = `${slot ? slot.index : -1}|${group.cards.map((c) => c.id).join(",")}`;
  useLayoutEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const next = new Map<string, number>();
    const reduced = prefersReducedMotion();
    const scroller = list.parentElement;
    const viewTop = scroller?.scrollTop ?? 0;
    const viewBottom = viewTop + (scroller?.clientHeight ?? window.innerHeight);
    let entering = 0;
    for (const element of list.querySelectorAll<HTMLElement>(":scope > [data-flip]")) {
      const key = element.dataset.flip!;
      const top = element.offsetTop;
      next.set(key, top);
      const before = tops.current.get(key);
      if (before == null) {
        // Only real cards that land inside the visible part of the column.
        if (key.startsWith("__") || top > viewBottom || top + element.offsetHeight < viewTop) continue;
        const delay = Math.min(entering * ENTER_STAGGER_MS, ENTER_STAGGER_CAP_MS);
        entering += 1;
        element.animate(
          reduced
            ? [{ opacity: 0 }, { opacity: 1 }]
            : [
                { opacity: 0, transform: "translateY(10px) scale(0.97)" },
                { opacity: 1, transform: "none" },
              ],
          { duration: ENTER_MS, easing: EASE_OUT, delay, fill: "backwards" },
        );
        continue;
      }
      if (reduced) continue;
      const delta = before - top;
      if (Math.abs(delta) < 1) continue;
      element.animate([{ transform: `translateY(${delta}px)` }, { transform: "translateY(0)" }], {
        duration: REFLOW_MS,
        easing: EASE_OUT,
      });
    }
    tops.current = next;
  }, [flipKey]);

  const tint = { "--lane": group.color } as CSSProperties;

  if (group.collapsed) {
    return (
      <section
        className="column column-collapsed"
        style={tint}
        data-kind={group.kind}
      data-gk={group.gk}
        data-drop={slot ? "" : undefined}
        onDragOver={(event) => handlers.dragOver(group, event, null)}
        onDrop={(event) => handlers.drop(group, event)}
      >
        <button type="button" className="collapsed-strip" onClick={() => handlers.toggleCollapsed(group)} aria-label={`Expandir ${group.title}`}>
          <span className="collapsed-count">{group.cards.length}</span>
          <span className="collapsed-label">{group.title}</span>
        </button>
      </section>
    );
  }

  // A drop slot beyond the mounted page still needs its neighbours.
  const shown = slot && slot.index > limit ? group.cards.slice(0, slot.index + 1) : group.cards.slice(0, limit);
  const cardNodes = shown.map((card) => (
    <div key={card.id} data-flip={card.id} className="card-slot">
      <Card
        card={card}
        members={props.members}
        tags={props.tags}
        size={prefs.size}
        covers={prefs.covers}
        emptyFields={prefs.emptyFields}
        hidden={prefs.hidden}
        selected={props.selected.has(card.id)}
        tint={props.statusColor(card.status)}
        dragging={props.dragging.has(card.id)}
        inert={props.inert}
        subtasks={props.children.get(card.id)}
        statusColor={props.statusColor}
        subtaskComposerToken={props.subtaskComposer?.id === card.id ? props.subtaskComposer.token : undefined}
        handlers={handlers}
      />
    </div>
  ));
  if (slot) {
    cardNodes.splice(
      Math.min(slot.index, cardNodes.length),
      0,
      <div key="__slot" data-flip="__slot" className="drop-slot" style={{ height: slot.height }} />,
    );
  }

  const composerNode = (position: "top" | "bottom") =>
    composer === position ? (
      <div data-flip={`__composer-${position}`} className="column-composer">
        <Composer
          onSubmit={(title, token) => handlers.create(group, title, token, position)}
          onClose={() => handlers.setComposer(null, position)}
        />
      </div>
    ) : null;

  return (
    <section
      className="column"
      style={tint}
      data-kind={group.kind}
      data-gk={group.gk}
      data-drop={slot ? "" : undefined}
      aria-label={group.title}
      onDragOver={(event) => handlers.dragOver(group, event, listRef.current)}
      onDrop={(event) => handlers.drop(group, event)}
    >
      <div className="column-scroll" data-column-scroll={group.gk}>
        <div ref={listRef} className="column-list">
          {composerNode("top")}
          {cardNodes}
          {hasMore && <div ref={sentinel} className="column-more" aria-hidden="true" style={{ height: 1 }} />}
          {composerNode("bottom")}
          {group.canCreate && composer !== "bottom" && (
            <button
              type="button"
              data-flip="__add"
              className="add-task"
              onClick={() => handlers.setComposer(group.gk, "bottom")}
            >
              <Icon name="plus" size={11} stroke={1.6} />
              Adicionar tarefa
            </button>
          )}
        </div>
      </div>
    </section>
  );
});

