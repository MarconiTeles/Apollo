// Swift ↔ board contract.
//
// Swift → JS: `BoardReactHost` pushes diffs through
// `window.apolloBoard.update(patch)`; composer results come back through
// `window.apolloBoard.created(token, ok)`.
// JS → Swift: `window.webkit.messageHandlers.apolloBoard.postMessage(...)`.

import type { GroupBy, Patch, Prefs } from "./types";

type NativeHandler = { postMessage(message: unknown): void };

export interface ViewRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface DropTarget {
  groupBy: GroupBy;
  /** Group key the cards left (first dragged card), null from outside. */
  from: string | null;
  to: string;
  /** Card the dragged ones land in front of; null = end of the group. */
  before: string | null;
  /** Full manual order of the destination group after the drop. */
  order: string[];
  /** Manual order of the source group after the drop (cross-group). */
  sourceOrder?: string[];
}

export type OutboundMessage =
  | { type: "boot" }
  | { type: "rendered"; seq: number }
  | { type: "activate"; id: string; shift: boolean; command: boolean; rect: ViewRect; ordered: string[] }
  | { type: "select"; ids: string[]; additive: boolean }
  | { type: "clearSelection" }
  | { type: "menu"; id: string; x: number; y: number }
  | { type: "field"; field: "assignee" | "due" | "priority" | "tags"; id: string; rect: ViewRect }
  | {
      type: "columnMenu";
      gk: string;
      title: string;
      canCreate: boolean;
      ids: string[];
      rect: ViewRect;
    }
  | { type: "summary"; total: number }
  | {
      type: "layout";
      width: number;
      headers: {
        gk: string;
        key: string;
        kind: string;
        title: string;
        count: number;
        x: number;
        w: number;
        collapsed: boolean;
        canCreate: boolean;
        ids: string[];
      }[];
    }
  | { type: "create"; token: string; title: string; groupBy: GroupBy; group: string; position: "top" | "bottom" }
  | { type: "createSubtask"; token: string; title: string; parent: string }
  | ({ type: "drop"; ids: string[] } & DropTarget)
  | { type: "dragBegin"; ids: string[] }
  | { type: "dragEnd"; completed: boolean }
  | { type: "prefs"; prefs: Prefs }
  | { type: "visible"; ids: string[] }
  | { type: "editing"; active: boolean }
  | { type: "error"; message: string };

declare global {
  interface Window {
    /** Vite dev server only: the browser fixture answers like the host. */
    __apolloBoardDemo?: (message: OutboundMessage) => void;
    apolloBoard?: {
      update(patch: Patch): void;
      created(token: string, ok: boolean): void;
    };
    webkit?: { messageHandlers?: { apolloBoard?: NativeHandler } };
  }
}

const native = (): NativeHandler | undefined => window.webkit?.messageHandlers?.apolloBoard;

export const isHosted = native() !== undefined;

export function post(message: OutboundMessage) {
  const handler = native();
  if (handler) handler.postMessage(message);
  else if (import.meta.env.DEV) {
    console.debug("[apollo-board]", message);
    window.__apolloBoardDemo?.(message);
  }
}

export function rectOf(element: Element): ViewRect {
  const r = element.getBoundingClientRect();
  return { x: r.left, y: r.top, width: r.width, height: r.height };
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message ?? "unknown") });
});
