import { createRoot } from "react-dom/client";
import { Splash } from "./Splash";
import "./styles.css";

// No StrictMode: its dev-only double mount would tear down and re-create the
// WebGL context on the same canvas, which WebKit refuses after loseContext().
createRoot(document.getElementById("root")!).render(<Splash />);

// Dev only: a hot update would re-run the scene on canvases whose WebGL
// contexts were already released, dropping to the no-WebGL fallback. A full
// reload is the honest preview of a cold launch anyway.
import.meta.hot?.on("vite:beforeUpdate", () => location.reload());
