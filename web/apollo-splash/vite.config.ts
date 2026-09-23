import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// The splash is loaded from the signed app bundle through
// `WKWebView.loadFileURL`. WebKit refuses ES-module imports across
// file:// URLs, so everything (JS + CSS) is inlined into one
// self-contained index.html that build.sh copies verbatim.
// Offline by construction: the shipped splash never touches the network.
// Injected only into the production build so the Vite dev server (which
// serves scripts and a websocket) keeps working in a normal browser.
const contentSecurityPolicy: Plugin = {
  name: "apollo-splash-csp",
  apply: "build",
  transformIndexHtml: () => [
    {
      tag: "meta",
      attrs: {
        "http-equiv": "Content-Security-Policy",
        content:
          "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'",
      },
      injectTo: "head-prepend",
    },
  ],
};

export default defineConfig({
  plugins: [react(), viteSingleFile(), contentSecurityPolicy],
  base: "./",
  build: {
    outDir: "../../Sources/DayPanel/Resources/ApolloSplash",
    emptyOutDir: true,
    target: "safari17",
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    reportCompressedSize: true,
  },
});
