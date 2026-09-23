// Swift ↔ scene contract.
//
// Swift → JS: `SyncLoadingController` injects the first snapshot as
// `window.__APOLLO_LOADING__` at document start, then pushes every change
// through `window.apolloLoading.update(snapshot)`.
// JS → Swift: `window.webkit.messageHandlers.apollo.postMessage(...)`.
//
// Outside WKWebView (Vite dev server in a browser) `demo.ts` plays a
// scripted sync so each scene can be iterated without rebuilding the app.

import type { Snapshot } from "./types";

type NativeHandler = { postMessage(message: unknown): void };

declare global {
  interface Window {
    __APOLLO_LOADING__?: Snapshot;
    apolloLoading?: { update(snapshot: Snapshot): void };
    webkit?: { messageHandlers?: { apollo?: NativeHandler } };
  }
}

const native = (): NativeHandler | undefined => window.webkit?.messageHandlers?.apollo;

export const isHosted = native() !== undefined;

export type OutboundMessage = { type: "ready" } | { type: "error"; message: string };

export function post(message: OutboundMessage) {
  const handler = native();
  if (handler) handler.postMessage(message);
  else if (import.meta.env.DEV) console.debug("[apollo-loading]", message);
}

// A tiny external store: `useSyncExternalStore` reads it, Swift writes it.
let current: Snapshot | undefined = window.__APOLLO_LOADING__;
const listeners = new Set<() => void>();

export function publish(snapshot: Snapshot) {
  current = snapshot;
  listeners.forEach((listener) => listener());
}

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export const read = () => current;

window.apolloLoading = { update: publish };

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message ?? "unknown") });
});
