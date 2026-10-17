# Overgit — design brief

Paste this whole file into the design agent, with these attached:

- `shipped.png` — **what is there now**: the panel built to this brief, with
  the commit's detail open in the right-hand pane. This is the thing to
  improve, not a blank page.
- `frame.png` — the window with the three places marked.
- `frame-plain.png` — the same window, unmarked.

The build is working and complete; what it wants is the design pass. The
mark in `shipped.png` is a placeholder drawn in code, and the rows, the
graph gutter and the commit pane are all first drafts.

## What you are designing for

**Overterm** is a macOS terminal built for agent-driven work: several
checkouts open at once, an agent (Claude Code, Codex) in each. It is
Swift/AppKit with SwiftUI inside the panels — not a web app. Everything you
draw will be rebuilt in SwiftUI by hand, so **a design that needs a web
layout engine cannot ship**: no CSS grid tricks, no blurred glass stacks, no
web fonts.

**Overgit** is a new git panel in the app's left sidebar. Think GitLens —
commit graph, branches, pull requests, stashes — but as one calm panel in a
terminal's chrome, not a second IDE. The annotated screenshot marks three
places:

1. **the sidebar's icon bar** — four icons today (Files, Worktrees,
   Sessions, Snippets); the Overgit mark becomes the second, and the
   Worktrees icon goes away (worktrees become a section *inside* Overgit);
2. **the panel body** — everything below the 34 pt header: the eight
   sections;
3. **the right-hand pane's tab row** — `Changes · Pull Request · Usage`
   today; `Commit` joins it, and that is where a commit's own diff opens.

## The hard constraint: colours are tokens, not hex

The whole chrome is derived at run time from **two colours** — the
terminal theme's background and foreground. A user switching themes
recolours the sidebar with no relaunch. So every colour in your design must
name one of these tokens. Do not invent a palette; do not hand back hex.

| token | what it is | how it is derived |
|---|---|---|
| `win` | the window ground, visible only *between* the cards | background, darkened (0.35 dark / 0.08 light) |
| `card` | a panel's own ground — the sidebar is one | background ± 0.02 |
| `term` | the terminal's background | the background, verbatim |
| `border` | hairline around a card, and header/body rules | white or black at 8 % |
| `text` | body text | the foreground |
| `text2` | secondary: a label beside the thing it names | foreground at 62 % |
| `text3` | metadata you read only when you look for it | foreground at 54 % |
| `rowSel` | a selected row | white/black veil at 8 % / 6 % |
| `rowHover` | a hovered row | white/black veil at 5 % / 4 % |
| `iconBg` | the tile behind a small glyph | veil at 8 % / 6 % |
| `orangeText`, `greenText`, `accentText` | the only three accents, legible on `win` in both themes | fixed pairs |

"Veil" means white in a dark theme, black in a light one, so one alpha works
over any ground. **There is no brand colour.** If a lane in the graph needs
six distinct colours, say where they come from (a fixed hue ring at a fixed
saturation, derived once per theme) rather than naming six hex values.

## The metrics you are designing against

These are the real numbers in the shipping app. Match them; a design that
needs other ones has to say why.

- sidebar column: 180–520 pt wide, ~260 pt typical (what the screenshot
  shows). Panels must survive 180 pt.
- icon bar: 40 pt tall, 28 pt tall buttons, 13 pt glyphs, 2 pt apart,
  6 pt side padding, selected button = `rowSel` behind a 6 pt radius.
- panel header: 34 pt tall, title 11 pt semibold **uppercase** in `text2`,
  12 pt leading / 8 pt trailing padding, 22 pt square icon buttons at the
  right in `text2`.
- rows: 26 pt (file tree), 34 pt (snippets), ~38 pt for a two-line row
  (worktrees: name + subtitle). Body text 12 pt, metadata 11 pt, SF Pro;
  monospaced only for code-ish things (a sha, a `#123`).
- a selection or hover pill is a `RoundedRectangle(cornerRadius: 6)` inset
  4 pt from the panel's sides, so it floats rather than touching the edges.
- a disclosure chevron is 8 pt semibold, in a 10 pt wide slot, and keeps
  its slot when there is nothing to disclose, so labels stay aligned.
- cards elsewhere in the window: 10 pt corner radius, 10 pt apart.

## The eight sections

All collapsible, their open/shut state remembered. Each needs: the collapsed
header row, the open state, an **empty** state, a **loading** state, and
what an **error** looks like (git failed, `gh` is not installed). Also: what
the whole panel looks like when the folder **is not a git repository at
all** — that is a real state, not an edge case.

1. **Overview** — not collapsible, the card at the top. The branch, its
   upstream and how far ahead/behind, the working-tree count (`+12 −3`),
   the pull request if there is one (`#123` + a CI glyph), and the
   checkout's name. This is the row a person reads first; it should answer
   "where am I and is anything broken" without scrolling.
2. **Commits** — the history, newest first, with a **graph gutter** down
   the left: 36–44 pt wide, at most 6 lanes, lane lines 2 pt, the commit's
   own dot 7 pt. Row: subject (12 pt `text`), then short sha and relative
   date (11 pt `text3`); the author only if it is not you. Refs
   (`main`, `origin/main`, a tag) ride the row as small pills. Show me how
   a merge reads, how a branch point reads, and what 6 lanes look like at
   180 pt wide — that is the hardest case in the whole design.
3. **Branches** — local first, then remotes, grouped as a tree by `/`
   (`feature/x`, `feature/y` under `feature`). Per row: name, ahead/behind
   arrows, a mark when it is checked out in a worktree, last commit's age.
4. **Pull requests** — open PRs: `#123`, title, state pill, CI glyph,
   whether review was requested. One line, two at most.
5. **Worktrees** — exists today, moves in unchanged: branch name, the
   folder, which tabs are working in it, and an orange subtitle when an
   agent in it is waiting on a person.
6. **Stashes** — `stash@{0}`, message, age.
7. **Tags** — name, the commit it points at, age.
8. **Remotes** — name and URL, host-aware (GitHub, GitLab) if a glyph
   helps.

## The mark

A single glyph named **Overgit**. It sits in the icon bar beside
`doc.on.doc`, `bubble.left.and.text.bubble.right` and `text.alignleft` —
Apple's SF Symbols — so it has to look like their sibling: one weight, no
fill/outline mixing, no gradient, no colour. It is tinted `text` when the
panel is open and `text2` when it is not, so **monochrome, single path**.

- legible at **13×13 pt** (26×26 px at 2×) — that is the real size;
- idea space: the "over" of Overterm (an arc, a chevron, a horizon) crossed
  with git's branch — but do not just redraw `arrow.triangle.branch`;
- hand it back as **one `<path>` on a 24×24 viewBox**, no strokes (convert
  strokes to outlines), no transforms, no groups. We translate it to a
  SwiftUI `Path` by hand: the repo has no asset catalog and no SVG
  pipeline, and we are not adding one.

## What to hand back

- `overgit-sidebar-dark.png` and `overgit-sidebar-light.png` — the sidebar
  at 260 pt wide, 2×, every section open, real-looking git data.
- `overgit-sidebar-narrow.png` — the same at 180 pt, to prove the graph
  survives.
- `overgit-commit-pane.png` — the right-hand pane showing one commit:
  subject, body, author, date, sha, and its changed files as diff cards.
  The existing changes pane in `frame-plain.png` is the shape to stay close
  to; we reuse its file cards verbatim.
- `overgit-states.png` — empty, loading, error, not-a-repository.
- `overgit-mark.svg` — the glyph, as specified above.
- a short note naming, for every colour you used, which token it is.

## References

GitLens' own screenshots are the closest existing thing, and worth reading
before you start — but Overterm is quieter and much narrower, so copy the
*information*, not the chrome:

- the side bar views (commits, branches, remotes, stashes, tags, worktrees):
  <https://help.gitkraken.com/gitlens/side-bar/>
- the commit graph: <https://help.gitkraken.com/gitlens/gl-commit-graph/>
