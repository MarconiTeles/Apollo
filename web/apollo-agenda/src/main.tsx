import { createRoot } from "react-dom/client";
import { App } from "./App";
import { isHosted, post } from "./lib/bridge";
import { installMotionTokens } from "./lib/motion";
import { apply } from "./lib/store";
import "./styles.css";

async function boot() {
  installMotionTokens();
  window.apolloAgenda = { update: apply };
  // Plain browser (Vite dev server): deterministic fixtures so the page can
  // be iterated without the app.
  if (!isHosted && import.meta.env.DEV) {
    const { startDemo } = await import("./lib/demo");
    startDemo();
  }
  createRoot(document.getElementById("root")!).render(<App />);
  post({ type: "boot" });
}

void boot();
