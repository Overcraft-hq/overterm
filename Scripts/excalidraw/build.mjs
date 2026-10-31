// Bundles entry.js into one script the page can load from overterm-note:
// (Excalidraw 0.18 is ESM importing bare packages, which a page without a
// bundler can't resolve). Left out: mermaid-to-excalidraw (mermaid itself
// is megabytes, and the reading view has its own) and every locale but
// English, which is built in.
import { build } from "esbuild";

const [out] = process.argv.slice(2);

const leaveOut = {
  name: "leave-out",
  setup(b) {
    b.onResolve({ filter: /^@excalidraw\/mermaid-to-excalidraw$/ }, () => ({ path: "mermaid", namespace: "stub" }));
    b.onResolve({ filter: /\/locales\/[a-zA-Z-]+-[A-Z0-9]+\.js$/ }, (args) => ({ path: args.path, namespace: "stub" }));
    b.onLoad({ filter: /.*/, namespace: "stub" }, (args) => ({
      contents:
        args.path === "mermaid"
          ? 'export const parseMermaidToExcalidraw = () => { throw new Error("not in this build"); };'
          : "export default {};",
    }));
  },
};

await build({
  entryPoints: ["entry.js"],
  bundle: true,
  minify: true,
  format: "iife",
  platform: "browser",
  target: "safari16",
  conditions: ["production"],
  define: { "process.env.NODE_ENV": '"production"' },
  loader: { ".woff2": "empty", ".css": "empty" },
  plugins: [leaveOut],
  outfile: out,
  logLevel: "warning",
});
