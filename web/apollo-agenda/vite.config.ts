import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// Same shipping model as the splash, loading and task-list pages: one
// inlined index.html loaded from the signed bundle through `loadFileURL`.
// Every colour, label and glyph arrives from Swift, so the page itself
// never touches the network.
const contentSecurityPolicy: Plugin = {
  name: "apollo-agenda-csp",
  apply: "build",
  transformIndexHtml: () => [
    {
      tag: "meta",
      attrs: {
        "http-equiv": "Content-Security-Policy",
        content:
          "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'",
      },
      injectTo: "head-prepend",
    },
  ],
};

export default defineConfig({
  plugins: [react(), viteSingleFile(), contentSecurityPolicy],
  base: "./",
  build: {
    outDir: "../../Sources/DayPanel/Resources/ApolloAgenda",
    emptyOutDir: true,
    target: "safari18",
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    reportCompressedSize: true,
  },
});
