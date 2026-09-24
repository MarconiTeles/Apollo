// One board card in Apollo's editorial language (the native BoardCard):
// optional cover, a meta row (status dot, parent/list crumb, priority chip),
// the semibold title, indicators, tags and the footer (avatars + first name,
// relative date with the turn arrow). The ClickUp field editors live on
// those same elements: each opens its native AppKit editor. Empty fields
// appear only on hover (or always, from View Options), so a card never
// carries decoration it doesn't need. Selection is ⌘/⇧-click, like Tarefas.

import { memo, useEffect, useRef, useState } from "react";
import type { DragEvent as ReactDragEvent, MouseEvent as ReactMouseEvent, ReactNode } from "react";
import { post, rectOf } from "../lib/bridge";
import { dateTone, relativeDate } from "../lib/dates";
import type { CardPayload, CardSize, Person, TagPayload } from "../lib/types";
import { AvatarStack } from "./Avatar";
import { Composer } from "./Composer";
import { Icon, StatusGlyph } from "./Icon";

export interface CardHandlers {
  activate(card: CardPayload, event: ReactMouseEvent, element: HTMLElement): void;
  menu(card: CardPayload, x: number, y: number): void;
  dragStart(card: CardPayload, event: ReactDragEvent<HTMLElement>): void;
  dragEnd(event: ReactDragEvent<HTMLElement>): void;
  observe(element: HTMLElement | null, id: string): void;
}

interface CardProps {
  card: CardPayload;
  members: ReadonlyMap<number, Person>;
  tags: ReadonlyMap<string, TagPayload>;
  size: CardSize;
  covers: boolean;
  emptyFields: boolean;
  hidden: readonly string[];
  selected: boolean;
  dragging: boolean;
  inert: boolean;
  /** Status colour (Apollo palette): meta dot and hover shadow. */
  tint: string;
  subtasks?: CardPayload[];
  statusColor?: (key: string) => string;
  subtaskComposerToken?: number;
  handlers: CardHandlers;
}

type Field = "assignee" | "due" | "priority" | "tags";

const PRIORITY_LABEL: Record<number, string> = { 1: "URGENTE", 2: "ALTA", 3: "NORMAL", 4: "BAIXA" };

/** Swallows the press so a field never opens the task or starts a drag. */
const stop = (event: { stopPropagation(): void }) => event.stopPropagation();

/** A card element that opens the native editor for `field` under itself. */
function FieldButton({
  field,
  id,
  label,
  className,
  children,
}: {
  field: Field;
  id: string;
  label: string;
  className: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      className={className}
      aria-label={label}
      title={label}
      draggable={false}
      onMouseDown={stop}
      onClick={(event) => {
        event.stopPropagation();
        post({ type: "field", field, id, rect: rectOf(event.currentTarget) });
      }}
    >
      {children}
    </button>
  );
}

const firstName = (name: string) => {
  const token = name.split(/[\s._@-]+/)[0] ?? "";
  return token ? token.charAt(0).toUpperCase() + token.slice(1) : "";
};

export const Card = memo(function Card(props: CardProps) {
  const { card, members, tags, size, covers, emptyFields, hidden, selected, dragging, handlers } = props;
  const ref = useRef<HTMLElement>(null);
  // The cover that finished loading; a new URL shows the shimmer again.
  const [loadedCover, setLoadedCover] = useState<string | null>(null);
  const [expanded, setExpanded] = useState(false);
  const [subtaskComposer, setSubtaskComposer] = useState(false);
  const show = (field: string) => !hidden.includes(field);

  useEffect(() => {
    handlers.observe(ref.current, card.id);
    return () => handlers.observe(null, card.id);
  }, [handlers, card.id]);

  useEffect(() => {
    if (props.subtaskComposerToken) setSubtaskComposer(true);
  }, [props.subtaskComposerToken]);

  const people = card.assignees.map((id) => members.get(id)).filter((p): p is Person => p != null);
  const priority = show("priority") && card.priority >= 1 && card.priority <= 4 ? card.priority : 0;
  const tone = card.due != null ? dateTone(card.due, card.closed) : undefined;
  const cover = covers && show("cover") ? card.cover : undefined;
  const subtasks = props.subtasks ?? [];
  // Native breadcrumb row: the parent for subtasks, else workspace · list.
  const crumb =
    show("parent") && card.parentTitle ? card.parentTitle : show("list") ? (card.crumb ?? card.otherList ?? null) : null;
  // Like the native card, only URGENTE/ALTA earn a chip; normal and low
  // stay a quiet coloured flag in the footer.
  const chip = priority === 1 || priority === 2;

  // ── Indicators ───────────────────────────────────────────────────────
  const indicators: ReactNode[] = [];
  if (show("description") && card.hasDescription) {
    indicators.push(
      <span key="d" className="indicator" title="Tem descrição">
        <Icon name="description" size={12} />
      </span>,
    );
  }
  if (show("attachments") && card.attachments) {
    indicators.push(
      <span key="a" className="indicator" title={`${card.attachments} anexos`}>
        <Icon name="attachment" size={12} />
        {card.attachments}
      </span>,
    );
  }
  if (show("checklist") && card.checklist && card.checklist.total > 0) {
    const done = card.checklist.done === card.checklist.total;
    indicators.push(
      <span key="c" className="indicator" data-done={done ? "" : undefined} title="Checklist">
        <Icon name="checklist" size={12} />
        {card.checklist.done}/{card.checklist.total}
      </span>,
    );
  }
  if (subtasks.length > 0) {
    indicators.push(
      <button
        key="s"
        type="button"
        className="indicator indicator-button"
        aria-expanded={expanded}
        aria-label={`${subtasks.length} subtarefas`}
        draggable={false}
        onMouseDown={stop}
        onClick={(event) => {
          event.stopPropagation();
          setExpanded((v) => !v);
        }}
      >
        <Icon name="subtask" size={12} />
        {subtasks.length}
        <Icon name="chevronDown" size={10} className="indicator-chevron" />
      </button>,
    );
  }

  return (
    <article
      ref={ref}
      className="card"
      data-card={card.id}
      data-size={size}
      data-selected={selected ? "" : undefined}
      data-dragging={dragging ? "" : undefined}
      data-closed={card.closed ? "" : undefined}
      data-empty-fields={emptyFields ? "" : undefined}
      style={{ ["--tint" as string]: props.tint }}
      draggable={!props.inert}
      aria-selected={selected}
      tabIndex={-1}
      onClick={(event) => {
        if (event.defaultPrevented) return;
        handlers.activate(card, event, event.currentTarget);
      }}
      onContextMenu={(event) => {
        event.preventDefault();
        handlers.menu(card, event.clientX, event.clientY);
      }}
      onDragStart={(event) => handlers.dragStart(card, event)}
      onDragEnd={handlers.dragEnd}
    >
      {cover && (
        <div className="card-cover" data-ready={loadedCover === cover ? "" : undefined}>
          <img
            src={cover}
            alt=""
            draggable={false}
            decoding="async"
            ref={(img) => {
              if (img?.complete && img.naturalWidth > 0) setLoadedCover(cover);
            }}
            onLoad={() => setLoadedCover(cover)}
          />
        </div>
      )}
      <div className="card-body">
        {(crumb || chip) && (
          <div className="card-meta">
            <span className="status-dot" />
            <span className="crumb" title={crumb ?? undefined}>
              {crumb}
            </span>
            {chip && (
              <FieldButton
                field="priority"
                id={card.id}
                label={`Prioridade: ${PRIORITY_LABEL[priority].toLowerCase()}`}
                className={`priority-chip p${priority}`}
              >
                <span className="priority-dot" />
                <span>{PRIORITY_LABEL[priority]}</span>
              </FieldButton>
            )}
          </div>
        )}
        <div className="card-title">{card.title}</div>
        {indicators.length > 0 && <div className="card-indicators">{indicators}</div>}
        {show("tags") && card.tags.length > 0 && (
          <FieldButton field="tags" id={card.id} label="Etiquetas" className="tag-row">
            {card.tags.map((name) => {
              const tag = tags.get(name);
              return (
                <span key={name} className="tag" style={tag ? { color: tag.fg, background: tag.bg } : undefined}>
                  {name}
                </span>
              );
            })}
          </FieldButton>
        )}
        {expanded && subtasks.length > 0 && (
          <ul className="subtask-list">
            {subtasks.map((sub) => (
              <li key={sub.id}>
                <button
                  type="button"
                  className="subtask-row"
                  draggable={false}
                  onMouseDown={stop}
                  onClick={(event) => {
                    event.stopPropagation();
                    handlers.activate(sub, event, event.currentTarget);
                  }}
                >
                  <span className="subtask-status" style={{ color: props.statusColor?.(sub.status) }}>
                    <StatusGlyph closed={sub.closed} size={10} />
                  </span>
                  <span className="subtask-title">{sub.title}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        <div className="card-footer">
          {show("assignees") && (
            <FieldButton
              field="assignee"
              id={card.id}
              label="Responsáveis"
              className={people.length ? "assignee" : "assignee unassigned"}
            >
              {people.length > 0 ? (
                <>
                  <AvatarStack people={people} size={size === "s" ? 16 : 18} />
                  <span className="assignee-name">{firstName(people[0].name)}</span>
                </>
              ) : (
                <>
                  <span className="avatar avatar-empty">
                    <Icon name="person" size={10} />
                  </span>
                  <span className="assignee-name">Sem responsável</span>
                </>
              )}
            </FieldButton>
          )}
          <span className="footer-spacer" />
          {/* Unset fields: quiet icons revealed on hover (always with
              "Mostrar campos vazios"). */}
          {show("priority") && !chip && (
            <FieldButton
              field="priority"
              id={card.id}
              label={priority ? `Prioridade: ${PRIORITY_LABEL[priority].toLowerCase()}` : "Definir prioridade"}
              className={priority ? `ghost-icon set p${priority}` : "ghost-icon"}
            >
              <Icon name="flag" size={12} />
            </FieldButton>
          )}
          {show("tags") && card.tags.length === 0 && (
            <FieldButton field="tags" id={card.id} label="Adicionar etiqueta" className="ghost-icon">
              <Icon name="tag" size={12} />
            </FieldButton>
          )}
          {show("due") &&
            (card.due != null ? (
              <FieldButton field="due" id={card.id} label="Vencimento" className="due">
                <span className="due-text" data-tone={tone}>
                  {relativeDate(card.due)}
                </span>
                <Icon name="turnArrow" size={10} stroke={1.5} className="due-arrow" />
              </FieldButton>
            ) : (
              <FieldButton field="due" id={card.id} label="Definir vencimento" className="ghost-icon">
                <Icon name="calendar" size={12} />
              </FieldButton>
            ))}
        </div>
        {subtaskComposer && (
          <div onMouseDown={stop} onClick={stop} className="card-composer">
            <Composer
              compact
              placeholder="Nome da subtarefa"
              onSubmit={(title, token) => post({ type: "createSubtask", token, title, parent: card.id })}
              onClose={() => setSubtaskComposer(false)}
            />
          </div>
        )}
      </div>
    </article>
  );
});
