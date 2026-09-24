import { createRoot } from "react-dom/client";
import { App } from "./App";
import { isHosted } from "./lib/bridge";
import "./styles.css";

async function boot() {
  // In a plain browser (Vite dev server) play a scripted sync so the scenes
  // can be designed without the app. Never bundled into the hosted path's
  // behaviour: WKWebView always has the native handler.
  if (!isHosted && import.meta.env.DEV) {
    const { startDemo } = await import("./lib/demo");
    startDemo();
  }
  // Hosted, Swift starts the motion when the surface is on screen.
  if (!isHosted) document.documentElement.dataset.play = "";
  createRoot(document.getElementById("root")!).render(<App />);
}

void boot();
