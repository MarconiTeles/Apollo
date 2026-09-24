import { createRoot } from "react-dom/client";
import { App } from "./App";
import { isHosted, post } from "./lib/bridge";
import { preloadDragGlyphs } from "./lib/dragImage";
import { installMotionTokens } from "./lib/motion";
import { apply, subscribe } from "./lib/store";
import "./styles.css";

async function boot() {
  installMotionTokens();
  window.apolloTasks = { update: apply, taskAt: () => null, setFileDrop: () => {} };
  if (window.__APOLLO_TASKS__) apply(window.__APOLLO_TASKS__);
  subscribe(preloadDragGlyphs);
  preloadDragGlyphs();
  // Plain browser (Vite dev server): a deterministic fixture list so the
  // rows can be iterated without the app.
  if (!isHosted && import.meta.env.DEV) {
    const { startDemo } = await import("./lib/demo");
    startDemo();
  }
  createRoot(document.getElementById("root")!).render(<App />);
  post({ type: "boot" });
}

void boot();
