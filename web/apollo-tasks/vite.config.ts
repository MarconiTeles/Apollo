import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// Same shipping model as the splash and loading scenes: one inlined
// index.html loaded from the signed bundle through `loadFileURL`. Avatars
// arrive through the native `apollo-avatar:` scheme (AvatarStore), so the
// page itself never touches the network.
const contentSecurityPolicy: Plugin = {
  name: "apollo-tasks-csp",
  apply: "build",
  transformIndexHtml: () => [
    {
      tag: "meta",
      attrs: {
        "http-equiv": "Content-Security-Policy",
        content:
          "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: apollo-avatar:; connect-src 'none'",
      },
      injectTo: "head-prepend",
    },
  ],
};

export default defineConfig({
  plugins: [react(), viteSingleFile(), contentSecurityPolicy],
  base: "./",
  build: {
    outDir: "../../Sources/DayPanel/Resources/ApolloTasks",
    emptyOutDir: true,
    target: "safari18",
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    reportCompressedSize: true,
  },
});
