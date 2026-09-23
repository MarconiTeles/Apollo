import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// Same shipping model as the launch splash: loaded from the signed app bundle
// through `WKWebView.loadFileURL`, where WebKit refuses ES-module imports
// across file:// URLs — so JS and CSS are inlined into one index.html that
// build.sh copies verbatim. Offline by construction (CSP below, build only,
// so the Vite dev server keeps its scripts and websocket).
const contentSecurityPolicy: Plugin = {
  name: "apollo-loading-csp",
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
    outDir: "../../Sources/DayPanel/Resources/ApolloLoading",
    emptyOutDir: true,
    target: "safari17",
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    reportCompressedSize: true,
  },
});
