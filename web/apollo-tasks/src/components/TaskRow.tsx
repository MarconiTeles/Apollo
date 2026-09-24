import { memo, useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { post } from "../lib/bridge";
import { clientToViewY, viewRect } from "../lib/interaction";
import type { Glyph, TaskRowPayload } from "../lib/types";
import { DoneCircle } from "./DoneCircle";
import { MediaCapsule } from "./MediaCapsule";
import { ReviewCapsule } from "./ReviewCapsule";

// MyTasksNativeRowView: DONE | title | review · ANEXAR | priority |
// avatar + assignee | date | ellipsis, on a 36pt row with the hover capsule
// inset 28pt from both edges.

/** ReviewCapsule's dismissal: fade 260ms, hidden at 270ms. */
const REVIEW_EXIT_MS = 270;

export interface RowHandlers {
  register(key: string, element: HTMLElement | null): void;
  dragStart(event: React.DragEvent<HTMLDivElement>, row: TaskRowPayload): void;
  dragEnd(event: React.DragEvent<HTMLDivElement>): void;
}

interface Props {
  row: TaskRowPayload;
  selected: boolean;
  bulkCount: number;
  fileDrop: boolean;
  /** Part of the drag in flight (dimmed like the SwiftUI list's drag state). */
  dragging: boolean;
  inert: boolean;
  glyphs: Record<string, Glyph>;
  handlers: RowHandlers;
}

export const TaskRow = memo(function TaskRow({
  row,
  selected,
  bulkCount,
  fileDrop,
  dragging,
  inert,
  glyphs,
  handlers,
}: Props) {
  const more = useRef<HTMLButtonElement>(null);
  // The title takes the review slot only once no capsule occupies it: when
  // a review is concluded it waits for the capsule's 270ms exit first.
  const hasReview = row.review !== "hidden";
  const [reviewSlotFree, setReviewSlotFree] = useState(!hasReview);
  useEffect(() => {
    if (hasReview) {
      setReviewSlotFree(false);
      return;
    }
    const timer = window.setTimeout(() => setReviewSlotFree(true), REVIEW_EXIT_MS);
    return () => window.clearTimeout(timer);
  }, [hasReview]);
  const ellipsis = glyphs.ellipsis;
  const key = `t:${row.id}`;

  return (
    <div
      ref={(element) => handlers.register(key, element)}
      className={`row${selected ? " selected" : ""}${row.completed ? " completed" : ""}${dragging ? " dragging" : ""}${
        reviewSlotFree ? " no-review" : ""
      }`}
      data-key={key}
      role="listitem"
      draggable={!inert}
      style={{ "--sc": row.sc } as CSSProperties}
      onDragStart={(event) => handlers.dragStart(event, row)}
      onDragEnd={handlers.dragEnd}
      onClick={(event) => {
        if (inert || event.button !== 0) return;
        const element = event.currentTarget;
        post({
          type: "activate",
          id: row.id,
          shift: event.shiftKey,
          command: event.metaKey,
          rect: viewRect(element),
        });
      }}
      onContextMenu={(event) => {
        event.preventDefault();
        if (inert) return;
        post({ type: "menu", id: row.id, x: event.clientX, y: clientToViewY(event.clientY) });
      }}
    >
      <span className="bg" />
      <span className="rule" />
      <DoneCircle taskId={row.id} sc={row.sc} completed={row.completed} disabled={inert} check={glyphs.checkmark} />
      <span className="label title" title={row.title}>
        {row.title}
      </span>
      <ReviewCapsule taskId={row.id} state={row.review} disabled={inert} />
      <MediaCapsule taskId={row.id} media={row.media} bulkCount={bulkCount} fileDrop={fileDrop} disabled={inert} />
      {row.priority && (
        <span className="label priority" style={{ color: row.priority.color }}>
          {row.priority.label}
        </span>
      )}
      {row.assignee && (
        <>
          <span className="avatar" style={{ background: row.assignee.background }}>
            <span className="initials">{row.assignee.initials}</span>
            {row.assignee.photo && <img src={row.assignee.photo} alt="" draggable={false} />}
          </span>
          <span className="label assignee">{row.assignee.name}</span>
        </>
      )}
      {row.date && (
        <span className={`label date ${row.date.tone}`}>
          {row.date.tone === "soft" ? row.date.text : <span className="pill">{row.date.text}</span>}
        </span>
      )}
      <button
        ref={more}
        type="button"
        className="more"
        aria-label="Mais"
        disabled={inert}
        draggable={false}
        onMouseDown={(event) => event.stopPropagation()}
        onClick={(event) => {
          event.stopPropagation();
          if (inert || !more.current) return;
          post({ type: "more", id: row.id, rect: viewRect(more.current) });
        }}
      >
        {ellipsis && (
          <span
            className="glyph"
            style={{
              width: ellipsis.width,
              height: ellipsis.height,
              WebkitMaskImage: `url(${ellipsis.url})`,
              maskImage: `url(${ellipsis.url})`,
            }}
          />
        )}
      </button>
    </div>
  );
});
