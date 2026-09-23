// Swift ↔ splash contract.
//
// Swift → JS: `LunarSplashController` injects `window.__APOLLO_SPLASH__`
// at document start and later calls `window.apolloSplash.start()` /
// `.exit()` through `evaluateJavaScript`.
// JS → Swift: `window.webkit.messageHandlers.apollo.postMessage(...)`.
//
// Outside WKWebView (the Vite dev server in a browser) the bridge runs the
// splash on its own so the scene can be iterated without rebuilding the app.

export type SplashConfig = {
  /** sRGB hex of the user's macOS accent colour (the rule under the wordmark). */
  accent: string;
  /** When false, the scene holds its first frame until `start()`. */
  autostart: boolean;
};

export type OutboundMessage =
  | { type: "ready" }
  | { type: "introComplete" }
  | { type: "revealStart" }
  | { type: "finished" }
  | { type: "error"; message: string };

export type Command = "start" | "exit";

type NativeHandler = { postMessage(message: unknown): void };

declare global {
  interface Window {
    __APOLLO_SPLASH__?: Partial<SplashConfig>;
    apolloSplash?: { start(): void; exit(): void };
    webkit?: { messageHandlers?: { apollo?: NativeHandler } };
  }
}

const native = (): NativeHandler | undefined => window.webkit?.messageHandlers?.apollo;

export const isHosted = native() !== undefined;

export const config: SplashConfig = {
  accent: "#0A84FF",
  autostart: !isHosted,
  ...window.__APOLLO_SPLASH__,
};

export function post(message: OutboundMessage) {
  const handler = native();
  if (handler) handler.postMessage(message);
  else if (import.meta.env.DEV) console.debug("[apollo-splash]", message.type);
}

// Commands can arrive before React mounts (Swift calls `start()` as soon as
// it receives `ready`), so they queue until a listener subscribes.
const listeners = new Set<(command: Command) => void>();
const queued: Command[] = [];

function dispatch(command: Command) {
  if (listeners.size === 0) queued.push(command);
  else listeners.forEach((listener) => listener(command));
}

window.apolloSplash = {
  start: () => dispatch("start"),
  exit: () => dispatch("exit"),
};

export function onCommand(listener: (command: Command) => void) {
  listeners.add(listener);
  queued.splice(0).forEach(listener);
  return () => {
    listeners.delete(listener);
  };
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message ?? "unknown") });
});
