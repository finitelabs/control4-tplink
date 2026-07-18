#!/usr/bin/env node
// Convert a Markdown file to a self-contained GitHub-styled HTML file.
// Drop-in replacement for `generate-md --layout github` (markdown-styles).
//
// Usage: node tools/render-md.mjs <input.md> <output-dir>
//        (matches the CLI shape used by generate-md; writes <output-dir>/index.html)

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const markdownIt = (await import("markdown-it")).default;
const hljs = (await import("highlight.js")).default;

const [, , input, outDir] = process.argv;
if (!input || !outDir) {
  console.error("Usage: render-md.mjs <input.md> <output-dir>");
  process.exit(1);
}

const inputPath = resolve(input);
const outputPath = join(resolve(outDir), "index.html");

const md = markdownIt({
  html: true,
  linkify: true,
  typographer: true,
  highlight: (str, lang) => {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return `<pre><code class="hljs language-${lang}">${hljs.highlight(str, { language: lang, ignoreIllegals: true }).value}</code></pre>`;
      } catch {}
    }
    return `<pre><code class="hljs">${md.utils.escapeHtml(str)}</code></pre>`;
  },
});

const source = await readFile(inputPath, "utf8");
const bodyHtml = md.render(source);

const githubMarkdownCss = readFileSync(
  require.resolve("github-markdown-css/github-markdown-light.css"),
  "utf8"
);
const hljsCss = readFileSync(
  require.resolve("highlight.js/styles/github.css"),
  "utf8"
);

const title = basename(inputPath, ".md");
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
${githubMarkdownCss}
${hljsCss}
.markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
@media (max-width: 767px) { .markdown-body { padding: 15px; } }
</style>
</head>
<body class="markdown-body">
${bodyHtml}
</body>
</html>
`;

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, html, "utf8");
