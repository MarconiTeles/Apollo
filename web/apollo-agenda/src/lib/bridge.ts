// Swift ↔ agenda contract.
//
// Swift → JS: `AgendaReactHost` pushes patches through
// `window.apolloAgenda.update(patch)` once the page posted `boot`.
// JS → Swift: `window.webkit.messageHandlers.apolloAgenda.postMessage(...)`.

import type { Patch } from "./types";

type NativeHandler = { postMessage(message: unknown): void };

export type OutboundMessage =
  | { type: "boot" }
  | { type: "rendered"; seq: number }
  /** Timeline card click. */
  | { type: "open"; key: string }
  /** Month panel row click. */
  | { type: "openMonth"; key: string }
  /** Timeline card right-click, page coordinates. */
  | { type: "menu"; key: string; x: number; y: number }
  | { type: "retry" }
  | { type: "error"; message: string };

declare global {
  interface Window {
    apolloAgenda?: { update(patch: Patch): void };
    webkit?: { messageHandlers?: { apolloAgenda?: NativeHandler } };
  }
}

const native = (): NativeHandler | undefined => window.webkit?.messageHandlers?.apolloAgenda;

export const isHosted = native() !== undefined;

export function post(message: OutboundMessage) {
  const handler = native();
  if (handler) handler.postMessage(message);
  else if (import.meta.env.DEV) console.debug("[apollo-agenda]", message);
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message ?? "unknown") });
});
