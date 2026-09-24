// Exact ports of the native geometry: MyTasksColumnLayout.metrics(totalWidth:)
// and the viewport's row heights/offsets. Header, rows and hit-testing all
// read these, so the SwiftUI column header stays pixel-aligned.

import type { RowPayload, Widths } from "./types";

export const EDGE = 44;
export const GAP = 14;
export const MORE_WIDTH = 18;
export const MEDIA_WIDTH = 92 * 0.7;
export const REVIEW_WIDTH = 76;
export const REVIEW_MEDIA_GAP = 6;
export const TITLE_LEADING = 22;
export const TITLE_TRAILING_GAP = GAP * 1.5;

export interface Metrics {
  titleX: number;
  titleWidth: number;
  reviewX: number;
  mediaX: number;
  priorityX: number;
  priorityWidth: number;
  assigneeX: number;
  assigneeWidth: number;
  dateX: number;
  dateWidth: number;
  moreX: number;
}

export function metrics(totalWidth: number, widths: Widths): Metrics {
  const moreX = totalWidth - EDGE - MORE_WIDTH;
  const dateX = moreX - GAP - widths.date;
  const assigneeX = dateX - GAP - widths.assignee;
  const priorityX = assigneeX - GAP - widths.priority;
  const mediaX = priorityX - GAP - MEDIA_WIDTH;
  const reviewX = mediaX - REVIEW_MEDIA_GAP - REVIEW_WIDTH;
  const titleX = EDGE + TITLE_LEADING;
  const titleWidth = Math.max(0, reviewX - TITLE_TRAILING_GAP - titleX);
  return {
    titleX,
    titleWidth,
    reviewX,
    mediaX,
    priorityX,
    priorityWidth: widths.priority,
    assigneeX,
    assigneeWidth: widths.assignee,
    dateX,
    dateWidth: widths.date,
    moreX,
  };
}

/** A header, a task, or the animated drop slot inserted under a header. */
export type DisplayRow = RowPayload | { k: "d"; id: string; status: string; title: string; color: string };

export const displayKey = (row: DisplayRow) => `${row.k}:${row.id}`;

export function rowHeight(row: DisplayRow) {
  if (row.k === "h") return row.first ? 34 : 52;
  return 36;
}

export function offsetsFor(rows: DisplayRow[], top: number) {
  const offsets = new Float64Array(rows.length + 1);
  let y = top;
  for (let i = 0; i < rows.length; i++) {
    offsets[i] = y;
    y += rowHeight(rows[i]);
  }
  offsets[rows.length] = y;
  return offsets;
}

/** Same binary search as MyTasksViewport.firstIndex(intersecting:). */
export function firstIndexIntersecting(offsets: Float64Array, count: number, y: number) {
  let low = 0;
  let high = count;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (offsets[mid + 1] < y) low = mid + 1;
    else high = mid;
  }
  return low;
}

/** MyTasksViewport.rowIndex(at:): clamps above/below the content. */
export function rowIndexAt(offsets: Float64Array, count: number, y: number) {
  if (count === 0) return null;
  return Math.min(firstIndexIntersecting(offsets, count, y), count - 1);
}

const DRAG_PREFIX = "apollo-task-ids:";
const DRAG_SEPARATOR = "\u001F";

/** MyTasksDragPayload.encode */
export const encodeDragPayload = (ids: string[]) => DRAG_PREFIX + ids.join(DRAG_SEPARATOR);
