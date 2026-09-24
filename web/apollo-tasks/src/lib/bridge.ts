// Swift ↔ list contract.
//
// Swift → JS: `MyTasksReactHost` injects the boot patch as
// `window.__APOLLO_TASKS__` at document start and then pushes diffs through
// `window.apolloTasks.update(patch)`. File drags from Finder never reach the
// page (the native web view intercepts them); Swift only asks which task is
// under the pointer and which row should show the drop target.
// JS → Swift: `window.webkit.messageHandlers.apolloTasks.postMessage(...)`.

import type { Patch } from "./types";

type NativeHandler = { postMessage(message: unknown): void };

export interface ViewRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type OutboundMessage =
  | { type: "boot" }
  | { type: "rendered"; seq: number }
  | { type: "activate"; id: string; shift: boolean; command: boolean; rect: ViewRect }
  | { type: "toggle"; status: string }
  | { type: "statusPicker"; id: string; rect: ViewRect }
  | { type: "media"; id: string; rect: ViewRect }
  | { type: "review"; id: string }
  | { type: "menu"; id: string; x: number; y: number }
  | { type: "more"; id: string; rect: ViewRect }
  | { type: "clearSelection" }
  | { type: "dragBegin"; id: string }
  | { type: "dragEnd"; completed: boolean }
  | { type: "drop"; raw: string; status: string }
  | { type: "visible"; ids: string[] }
  | { type: "error"; message: string };

declare global {
  interface Window {
    __APOLLO_TASKS__?: Patch;
    apolloTasks?: {
      update(patch: Patch): void;
      taskAt(x: number, y: number): string | null;
      setFileDrop(id: string | null): void;
    };
    webkit?: { messageHandlers?: { apolloTasks?: NativeHandler } };
  }
}

const native = (): NativeHandler | undefined => window.webkit?.messageHandlers?.apolloTasks;

export const isHosted = native() !== undefined;

export function post(message: OutboundMessage) {
  const handler = native();
  if (handler) handler.postMessage(message);
  else if (import.meta.env.DEV) console.debug("[apollo-tasks]", message);
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message ?? "unknown") });
});
