// A note's reading view: markdown-it with Obsidian's syntax on top —
// [[wikilinks]] and ![[embeds]], #tags, ==highlights==, %%comments%%,
// $math$, - [ ] tasks, > [!callouts], mermaid — sanitized by DOMPurify.
// Swift resolves what a link means and hands it over (NoteReaderView);
// this only draws, and posts back what was clicked.
"use strict";

(function () {
  const post = (message) => window.webkit?.messageHandlers?.note?.postMessage(message);
  let payload = { text: "", links: {}, embeds: {}, properties: [], lineOffset: 0, vault: "", base: "", breaks: true };
  const mermaidCache = new Map();
  // A diagram's source, by index: not in an attribute, where DOMPurify
  // drops any value with `-->` in it — every flowchart arrow.
  let mermaidSources = [];
  let mermaidReady = false;

  const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const vaultURL = (path) => payload.vault + path.split("/").map(encodeURIComponent).join("/");

  // MARK: Wikilinks and embeds

  function parseInner(inner) {
    inner = inner.replace(/\\\|/g, "|");
    let alias = null;
    const bar = inner.indexOf("|");
    if (bar >= 0) { alias = inner.slice(bar + 1); inner = inner.slice(0, bar); }
    let target = inner, anchor = null;
    const hash = inner.indexOf("#");
    if (hash >= 0) { target = inner.slice(0, hash); anchor = inner.slice(hash + 1); }
    return { target: target.trim(), anchor, alias };
  }

  function wikilinks(md) {
    md.inline.ruler.before("link", "wikilink", (state, silent) => {
      const src = state.src;
      let start = state.pos, embed = false;
      if (src.charCodeAt(start) === 0x21 && src.startsWith("[[", start + 1)) { embed = true; start += 1; }
      else if (!src.startsWith("[[", start)) return false;
      const end = src.indexOf("]]", start + 2);
      if (end < 0 || end > state.posMax) return false;
      const inner = src.slice(start + 2, end);
      if (!inner || inner.includes("\n") || inner.includes("[[")) return false;
      if (!silent) {
        const token = state.push("wikilink", "", 0);
        token.meta = { inner, embed };
      }
      state.pos = end + 2;
      return true;
    });
    md.renderer.rules.wikilink = (tokens, idx, _options, env) => {
      const { inner, embed } = tokens[idx].meta;
      const link = parseInner(inner);
      return embed ? renderEmbed(md, link, inner, env) : renderLink(link);
    };
  }

  function renderLink({ target, anchor, alias }) {
    const resolved = target === "" ? { path: payload.path, kind: "note" } : payload.links[target];
    let text = alias;
    if (!text) {
      const shownAnchor = anchor && anchor.startsWith("^") ? null : anchor;
      text = target === "" ? (shownAnchor ?? anchor ?? "") : shownAnchor ? `${target} > ${shownAnchor}` : target;
    }
    const classes = "internal-link" + (resolved ? "" : " unresolved");
    return `<a href="#" class="${classes}" data-target="${escapeHtml(target)}" data-anchor="${escapeHtml(anchor ?? "")}">${escapeHtml(text)}</a>`;
  }

  function renderEmbed(md, link, inner, env) {
    const resolved = link.target === "" ? { path: payload.path, kind: "note" } : payload.links[link.target];
    if (!resolved) return `<span class="embed missing">${escapeHtml(inner)}</span>`;
    if (resolved.kind === "image") {
      let size = "";
      const m = link.alias && link.alias.match(/^(\d+)(?:x(\d+))?$/);
      if (m) size = ` width="${m[1]}"` + (m[2] ? ` height="${m[2]}"` : "");
      const alt = link.alias && !m ? link.alias : link.target;
      return `<img src="${escapeHtml(vaultURL(resolved.path))}" alt="${escapeHtml(alt)}"${size}>`;
    }
    if (resolved.kind === "note") {
      const key = link.target + (link.anchor ? "#" + link.anchor : "");
      const text = payload.embeds[key];
      const depth = (env && env.depth) || 0;
      if (text === undefined || depth >= 3) return renderLink(link);
      const title = `<a href="#" class="embed-title internal-link" data-target="${escapeHtml(link.target)}" data-anchor="${escapeHtml(link.anchor ?? "")}">${escapeHtml(link.alias || key)}</a>`;
      return `<div class="embed">${title}${md.render(text, { depth: depth + 1 })}</div>`;
    }
    return `<div class="embed file">${renderLink(link)}</div>`;
  }

  // MARK: Tags, highlights, comments, math

  function tags(md) {
    md.inline.ruler.after("wikilink", "tag", (state, silent) => {
      const src = state.src, pos = state.pos;
      if (src.charCodeAt(pos) !== 0x23) return false;
      if (pos > 0 && !/[\s(]/.test(src[pos - 1])) return false;
      const m = src.slice(pos + 1).match(/^[\p{L}\p{N}_\/-]+/u);
      if (!m || !/[^\p{N}]/u.test(m[0])) return false;
      if (!silent) {
        const token = state.push("tag", "", 0);
        token.content = m[0].replace(/\/+$/, "");
      }
      state.pos = pos + 1 + m[0].length;
      return true;
    });
    md.renderer.rules.tag = (tokens, idx) =>
      `<a href="#" class="tag" data-tag="${escapeHtml(tokens[idx].content)}">#${escapeHtml(tokens[idx].content)}</a>`;
  }

  /** `==text==`, and `%%hidden%%` within a line. */
  function marks(md) {
    md.inline.ruler.before("emphasis", "mark", (state, silent) => {
      const src = state.src, pos = state.pos;
      if (src.charCodeAt(pos) !== 0x3d || src.charCodeAt(pos + 1) !== 0x3d) return false;
      const end = src.indexOf("==", pos + 2);
      if (end < 0 || end > state.posMax || end === pos + 2) return false;
      if (/\s/.test(src[pos + 2]) || /\s/.test(src[end - 1])) return false;
      if (!silent) {
        state.push("mark_open", "mark", 1);
        const max = state.posMax;
        state.pos = pos + 2;
        state.posMax = end;
        state.md.inline.tokenize(state);
        state.posMax = max;
        state.push("mark_close", "mark", -1);
      }
      state.pos = end + 2;
      return true;
    });
    md.inline.ruler.before("emphasis", "comment", (state, silent) => {
      const src = state.src, pos = state.pos;
      if (!src.startsWith("%%", pos)) return false;
      const end = src.indexOf("%%", pos + 2);
      if (end < 0 || end > state.posMax) return false;
      state.pos = end + 2;
      return true;
    });
    // A comment that is whole lines: `%%` to the line that ends it.
    md.block.ruler.before("paragraph", "comment_block", (state, startLine, endLine, silent) => {
      const first = state.src.slice(state.bMarks[startLine] + state.tShift[startLine], state.eMarks[startLine]);
      if (!first.startsWith("%%")) return false;
      let line = startLine;
      let rest = first.slice(2);
      while (!rest.includes("%%")) {
        line += 1;
        if (line >= endLine) return false;
        rest = state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
      }
      if (silent) return true;
      state.line = line + 1;
      return true;
    });
  }

  function renderMath(source, display) {
    try {
      return katex.renderToString(source, { displayMode: display, throwOnError: false, output: "htmlAndMathml" });
    } catch (error) {
      return `<span class="math-error">${escapeHtml(source)}</span>`;
    }
  }

  function math(md) {
    md.inline.ruler.after("escape", "math_inline", (state, silent) => {
      const src = state.src, pos = state.pos;
      if (src.charCodeAt(pos) !== 0x24) return false;
      const display = src.charCodeAt(pos + 1) === 0x24;
      const open = display ? 2 : 1;
      if (!display && /\s/.test(src[pos + 1] ?? " ")) return false;
      let end = pos + open;
      for (;;) {
        end = src.indexOf(display ? "$$" : "$", end);
        if (end < 0 || end > state.posMax) return false;
        if (src[end - 1] !== "\\") break;
        end += 1;
      }
      if (end === pos + open) return false;
      if (!display && (/\s/.test(src[end - 1]) || /\d/.test(src[end + 1] ?? ""))) return false;
      if (!silent) {
        const token = state.push("math", "", 0);
        token.content = src.slice(pos + open, end);
        token.meta = { display };
      }
      state.pos = end + open;
      return true;
    });
    md.block.ruler.before("fence", "math_block", (state, startLine, endLine, silent) => {
      const start = state.bMarks[startLine] + state.tShift[startLine];
      const first = state.src.slice(start, state.eMarks[startLine]);
      if (!first.startsWith("$$")) return false;
      const sameLine = first.slice(2);
      if (sameLine.trimEnd().endsWith("$$") && sameLine.trim().length > 2) {
        if (!silent) {
          const token = state.push("math_block", "", 0);
          token.content = sameLine.trimEnd().slice(0, -2);
          token.map = [startLine, startLine + 1];
        }
        state.line = startLine + 1;
        return true;
      }
      let line = startLine + 1;
      const body = sameLine.trim() ? [sameLine] : [];
      for (; line < endLine; line++) {
        const text = state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
        if (text.trimEnd().endsWith("$$")) {
          body.push(text.trimEnd().slice(0, -2));
          break;
        }
        body.push(text);
      }
      if (line >= endLine) return false;
      if (silent) return true;
      const token = state.push("math_block", "", 0);
      token.content = body.join("\n");
      token.map = [startLine, line + 1];
      state.line = line + 1;
      return true;
    });
    md.renderer.rules.math = (tokens, idx) => renderMath(tokens[idx].content, tokens[idx].meta.display);
    md.renderer.rules.math_block = (tokens, idx) => `<div class="math-block">${renderMath(tokens[idx].content, true)}</div>`;
  }

  // MARK: Tasks, headings, fences

  /** `- [ ] text`: a checkbox that knows its line in the file, so a click
   *  ticks it there. Inside an embed it only shows. */
  function tasks(md) {
    md.core.ruler.after("inline", "tasks", (state) => {
      const tokens = state.tokens;
      const depth = (state.env && state.env.depth) || 0;
      for (let i = 2; i < tokens.length; i++) {
        const inline = tokens[i];
        if (inline.type !== "inline" || tokens[i - 1].type !== "paragraph_open" || tokens[i - 2].type !== "list_item_open") continue;
        const m = inline.content.match(/^\[(.)\][ \t]/);
        if (!m) continue;
        const item = tokens[i - 2];
        const status = m[1];
        const done = status === "x" || status === "X";
        item.attrJoin("class", "task" + (done ? " done" : ""));
        item.attrSet("data-status", status.toLowerCase() === "x" ? "x" : status);
        const first = inline.children[0];
        if (first && first.type === "text") first.content = first.content.replace(/^\[.\][ \t]/, "");
        const line = item.map ? item.map[0] + payload.lineOffset : -1;
        const box = new state.Token("html_inline", "", 0);
        const attributes = depth > 0 || line < 0 ? " disabled" : ` data-line="${line}"`;
        box.content = `<input type="checkbox" class="task"${done ? " checked" : ""}${attributes}>`;
        inline.children.unshift(box);
      }
    });
  }

  function headings(md) {
    md.core.ruler.push("heading_ids", (state) => {
      const seen = new Map();
      for (let i = 0; i < state.tokens.length - 1; i++) {
        if (state.tokens[i].type !== "heading_open") continue;
        const text = state.tokens[i + 1].content;
        let slug = text.toLowerCase().trim().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "") || "section";
        const count = seen.get(slug) || 0;
        seen.set(slug, count + 1);
        if (count) slug += "-" + count;
        state.tokens[i].attrSet("id", slug);
        state.tokens[i].attrSet("data-heading", text);
      }
    });
  }

  function fences(md) {
    const fallback = md.renderer.rules.fence;
    md.renderer.rules.fence = (tokens, idx, options, env, self) => {
      const token = tokens[idx];
      const language = token.info.trim().split(/\s+/)[0].toLowerCase();
      if (language === "mermaid") return `<div class="mermaid" data-diagram="${mermaidSources.push(token.content) - 1}"></div>`;
      if (language === "math" || language === "latex" && token.content.trim().startsWith("\\begin")) {
        return `<div class="math-block">${renderMath(token.content, true)}</div>`;
      }
      return fallback(tokens, idx, options, env, self);
    };
  }

  function highlight(code, language) {
    if (language && window.hljs && hljs.getLanguage(language)) {
      try {
        return hljs.highlight(code, { language, ignoreIllegals: true }).value;
      } catch (error) {}
    }
    return "";
  }

  let md = null;
  function makeRenderer(breaks) {
    return window.markdownit({ html: true, linkify: true, breaks, highlight })
      .use(window.markdownitFootnote)
      .use(wikilinks)
      .use(tags)
      .use(marks)
      .use(math)
      .use(tasks)
      .use(headings)
      .use(fences);
  }

  // MARK: After rendering: callouts, links, mermaid

  const calloutIcons = {
    note: "✎", abstract: "☰", summary: "☰", tldr: "☰", info: "ℹ", todo: "☑", tip: "🔥", hint: "🔥", important: "🔥",
    success: "✓", check: "✓", done: "✓", question: "?", help: "?", faq: "?", warning: "⚠", caution: "⚠", attention: "⚠",
    failure: "✗", fail: "✗", missing: "✗", danger: "⚡", error: "⚡", bug: "🐞", example: "☷", quote: "❝", cite: "❝",
  };

  /** `> [!type]± Title` blockquotes into callouts — foldable with + or -. */
  function callouts(root) {
    for (const quote of [...root.querySelectorAll("blockquote")].reverse()) {
      const first = quote.firstElementChild;
      if (!first || first.tagName !== "P") continue;
      const m = first.innerHTML.match(/^\[!([\w-]+)\]([+-]?)[ \t]*([^\n<]*(?:<(?!br)[^\n]*?)?)(?:<br>\n?|\n|$)/);
      if (!m) continue;
      const type = m[1].toLowerCase();
      const fold = m[2];
      const titleHTML = m[3].trim() || escapeHtml(type.charAt(0).toUpperCase() + type.slice(1));
      first.innerHTML = first.innerHTML.slice(m[0].length);
      if (!first.innerHTML.trim()) first.remove();
      const box = document.createElement(fold ? "details" : "div");
      box.className = "callout";
      box.dataset.callout = type;
      if (fold === "+") box.open = true;
      const title = document.createElement(fold ? "summary" : "div");
      title.className = "callout-title";
      title.innerHTML = `<span class="callout-icon">${calloutIcons[type] ?? "✎"}</span><span>${titleHTML}</span>`;
      const content = document.createElement("div");
      content.className = "callout-content";
      while (quote.firstChild) content.appendChild(quote.firstChild);
      box.append(title, content);
      quote.replaceWith(box);
    }
  }

  function setUpMermaid() {
    if (mermaidReady || !window.mermaid) return;
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: payload.dark ? "dark" : "default", fontFamily: "-apple-system, sans-serif" });
    mermaidReady = true;
  }

  let mermaidSerial = 0;
  async function drawMermaid(root) {
    const nodes = [...root.querySelectorAll(".mermaid[data-diagram]")];
    const sources = mermaidSources;
    if (!nodes.length) return;
    setUpMermaid();
    for (const node of nodes) {
      const source = sources[Number(node.dataset.diagram)];
      if (source === undefined) continue;
      const key = (payload.dark ? "d:" : "l:") + source;
      if (!mermaidCache.has(key)) {
        try {
          const { svg } = await mermaid.render("mermaid-" + ++mermaidSerial, source);
          mermaidCache.set(key, { svg });
        } catch (error) {
          mermaidCache.set(key, { error: String(error?.message ?? error) });
          document.getElementById("dmermaid-" + mermaidSerial)?.remove();
        }
      }
      if (!node.isConnected) continue;
      const drawn = mermaidCache.get(key);
      if (drawn.svg) node.innerHTML = drawn.svg;
      else node.innerHTML = `<div class="mermaid-error">${escapeHtml(drawn.error)}</div>`;
      node.removeAttribute("data-diagram");
    }
    post({ rendered: true, mermaid: root.querySelectorAll(".mermaid svg").length });
  }

  function properties() {
    if (!payload.properties.length) return "";
    const rows = payload.properties.map(([key, value, list]) => {
      const shown = list ? list.map((item) => `<span class="pill">${escapeHtml(item)}</span>`).join("") : escapeHtml(value);
      return `<div class="property"><span class="key">${escapeHtml(key)}</span><span class="value">${shown}</span></div>`;
    });
    return `<div class="properties">${rows.join("")}</div>`;
  }

  const purifyOptions = {
    ADD_ATTR: ["data-target", "data-anchor", "data-tag", "data-line", "data-status", "data-diagram", "data-heading", "data-callout", "checked", "disabled"],
    FORBID_TAGS: ["style", "form", "iframe", "object", "embed"],
    // DOMPurify's own list, and the app's scheme the vault's images come by.
    ALLOWED_URI_REGEXP: /^(?:(?:(?:f|ht)tps?|mailto|tel|overterm-note):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
  };

  // MARK: Showing

  function render(next) {
    const breaksChanged = !md || payload.breaks !== next.breaks;
    const darkChanged = payload.dark !== next.dark;
    payload = next;
    if (breaksChanged) md = makeRenderer(next.breaks);
    if (darkChanged) {
      mermaidReady = false;
      document.documentElement.classList.toggle("light", !next.dark);
    }
    for (const [name, value] of Object.entries(next.colors || {})) document.documentElement.style.setProperty("--" + name, value);
    const base = document.querySelector("base") || document.head.appendChild(document.createElement("base"));
    base.href = next.base;
    const main = document.getElementById("note");
    mermaidSources = [];
    const html = properties() + md.render(next.text, { depth: 0 });
    main.innerHTML = window.DOMPurify ? DOMPurify.sanitize(html, purifyOptions) : html;
    callouts(main);
    // Markdown images by Obsidian's rules (Swift resolved them), not the
    // browser's: `![](assets/x.png)` in Projects/ may mean the vault's assets/.
    for (const img of main.querySelectorAll("img[src]")) {
      const src = img.getAttribute("src");
      if (/^[a-z][a-z0-9+.-]*:/i.test(src)) continue;
      let written = src;
      try { written = decodeURIComponent(src); } catch (error) {}
      const resolved = payload.links["md:" + written] || payload.links["md:" + written.replace(/^\.\//, "")];
      if (resolved) img.setAttribute("src", vaultURL(resolved.path));
    }
    for (const a of main.querySelectorAll("a[href]")) {
      const href = a.getAttribute("href");
      if (/^[a-z][a-z0-9+.-]*:/i.test(href) && !href.startsWith("overterm-note:")) a.classList.add("external");
    }
    post({ rendered: true });
    drawMermaid(main);
  }

  function scrollToAnchor(anchor) {
    if (!anchor) return false;
    const main = document.getElementById("note");
    let target = null;
    if (anchor.startsWith("^")) {
      const id = anchor.slice(1);
      target = [...main.querySelectorAll("p, li, blockquote, .callout, td")].find((node) => node.textContent.trimEnd().endsWith("^" + id));
    } else {
      const wanted = anchor.toLowerCase().trim();
      target = [...main.querySelectorAll("[data-heading]")].find((node) => node.dataset.heading.toLowerCase().trim() === wanted);
    }
    if (!target) return false;
    target.scrollIntoView({ block: "start" });
    target.classList.remove("flash");
    void target.offsetWidth;
    target.classList.add("flash");
    return true;
  }

  document.addEventListener("click", (event) => {
    const box = event.target.closest("input.task");
    if (box) {
      event.preventDefault();
      if (box.dataset.line) post({ toggleTask: Number(box.dataset.line) });
      return;
    }
    const a = event.target.closest("a");
    if (!a) return;
    event.preventDefault();
    if (a.dataset.tag) return post({ tag: a.dataset.tag });
    if (a.dataset.target !== undefined) {
      if (a.dataset.target === "" && a.dataset.anchor) return void scrollToAnchor(a.dataset.anchor);
      return post({ open: a.dataset.target, anchor: a.dataset.anchor || null, newTab: event.metaKey });
    }
    const href = a.getAttribute("href") || "";
    if (href.startsWith("#fn") || href.startsWith("#fnref")) {
      document.getElementById(href.slice(1))?.scrollIntoView({ block: "center" });
      return;
    }
    if (href.startsWith("#")) return void scrollToAnchor(decodeURIComponent(href.slice(1)));
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return post({ external: href });
    // A Markdown link into the vault, relative to the note.
    const [path, anchor] = decodeURIComponent(href).split("#");
    post({ open: path, anchor: anchor || null, markdown: true, newTab: event.metaKey });
  });

  window.OT = {
    render,
    scrollToAnchor,
    scrollFraction: () => {
      const max = document.documentElement.scrollHeight - innerHeight;
      return max > 0 ? scrollY / max : 0;
    },
    scrollToFraction: (fraction) => window.scrollTo(0, fraction * (document.documentElement.scrollHeight - innerHeight)),
    /** The first source line on screen, for keeping the place in the text. */
    topLine: () => {
      for (const node of document.querySelectorAll("[data-line]")) if (node.getBoundingClientRect().top >= 0) return Number(node.dataset.line);
      return null;
    },
    text: () => document.getElementById("note").innerText,
  };
  post({ ready: true });
})();
