import { createRoot } from "react-dom/client";
import { App } from "./App";
import { resolveCreated } from "./components/Composer";
import { isHosted, post } from "./lib/bridge";
import { apply } from "./lib/store";
import "./styles.css";

async function boot() {
  window.apolloBoard = { update: apply, created: resolveCreated };
  // Plain browser (Vite dev server): a deterministic fixture board that
  // answers like the host, so the page can be iterated without the app.
  if (!isHosted && import.meta.env.DEV) {
    const { startDemo } = await import("./lib/demo");
    startDemo();
  }
  createRoot(document.getElementById("root")!).render(<App />);
  post({ type: "boot" });
  // Vite dev server only: `?diag=scroll` pans every column up and down so
  // the header band can be inspected mid-scroll inside the app.
  if (import.meta.env.DEV && new URLSearchParams(location.search).get("diag") === "scroll") {
    let t = 0;
    window.setInterval(() => {
      t += 1;
      const y = 180 + 180 * Math.sin(t / 40);
      for (const el of document.querySelectorAll<HTMLElement>("[data-column-scroll]")) el.scrollTop = y;
    }, 16);
  }
}

void boot();
