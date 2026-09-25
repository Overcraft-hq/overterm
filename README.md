# Terminus

> Your terminal for the rails.

A native macOS terminal built around how PromptRails work actually happens:
several worktrees at once, each with an agent (Claude Code, Codex) running in it.

The terminal itself is [libghostty](https://github.com/ghostty-org/ghostty)
(`GhosttyKit`) in a Swift/AppKit app — your `~/.config/ghostty/config` (font,
theme, keybinds) applies as-is. Private, internal tool.

## What's in it

- **Tabs** in the title bar, Chrome-style: rename (double-click), colour, pin
  (pinned = protected from ⌘W), drag to reorder. Tabs, their names, colours,
  pins and directories come back on relaunch, shell panes with their text
  (the last 2000 lines); agent tabs resume their last conversation
  (`claude --continue`, `codex resume --last`).
- **Agents**: open a Claude or Codex tab; the agent runs inside a normal shell,
  so quitting it leaves the tab usable.
- **New Task**: branch name in, `git worktree add` next to the repo
  (`<repo>-wt-<branch>`), a tab named after the branch, agent started.
- **Needs you**: a tab whose agent rings, notifies, or finishes work while
  you're elsewhere gets a yellow dot; in the background also a macOS
  notification (click → that tab) and a Dock badge.
- **Sidebar** (⌘B): the repo's worktrees, the file tree of the tab's checkout
  (follows `cd`, live), and snippets.
- **Diff panel** (⌥⌘D) above the terminal: changed files of the tab's
  worktree, live diff, stage / discard / commit.
- **Snippets** with `{{placeholders}}`; click to type in, Run to execute.
- **Command palette** (⌘P) over actions, tabs, worktrees and snippets.
- **Merged worktree clean-up**: merged worktrees (merged into the default
  branch, or deleted on the remote after a squash) get a purple mark; one
  click removes them and their branches, keeping any with changes or a tab.
- **From Finder**: right-click → Open With → Terminus (a folder opens as a
  tab, a file in the editor, in the tab already in its repository), or
  Services → **New Terminus Tab Here**; dropping on the Dock icon works too.
  Terminus is never made the default app for anything.
- **Agent overview** (⇧⌘A, or the grid button in the title bar): every tab
  as a card — who is waiting for you, working, done or failed, where, the
  branch's PR, and for Claude what the session is about, what you asked and
  what it is doing now.
- **Pull requests** (via your `gh`): PR number and CI on each worktree and in
  the title bar; the right pane's Pull Request view shows checks, the
  conversation and review threads, and lets you comment and reply.
- **Splits** (⌘D, ⇧⌘D, or ⌘P): panes in a tab, draggable dividers, zoom,
  equalize; Ghostty's split keybinds work, and a split tab comes back split.
- **Search** (⌘F): one overlay over the terminal's scrollback, the checkout's
  file names and their contents; ⌘-click a `path:line` in the terminal to open
  it in the editor at that line.

## Keys

| | |
|---|---|
| ⌘T / ⌘W | New / close tab (plus your Ghostty tab keybinds) |
| ⌥⌘C / ⌥⌘X | New Claude / Codex tab in this directory |
| ⇧⌘N | New Task (worktree + branch + agent) |
| ⌘1…9, ⇧⌘[ ⇧⌘] | Go to tab |
| ⌘B | Sidebar |
| ⌥⌘D | Diff panel |
| ⌘P | Command palette (↵ run, ⌥↵ insert snippet) |
| ⌘D / ⇧⌘D | Split right / down (⌘[ ⌘] or ⌥⌘arrows move between panes, ⇧⌘↩ zooms one) |
| ⇧⌘A | Agent overview |
| ⌘F | Search terminal + files (↵ open; the terminal row keeps a find bar) |
| ⌘-click | Open a printed `path:line` in the editor |

## Build

Requirements: macOS 13+, Xcode 16, [mise](https://mise.jdx.dev).

```sh
mise trust && mise install   # pinned Zig
make ghosttykit              # GhosttyKit from the pinned Ghostty (once, ~2 min)
make test                    # unit + integration tests
make e2e                     # end-to-end scenarios in the real app
make run                     # build Terminus.app and open it
make install                 # …and copy it to /Applications (Launchpad, Spotlight)
```

Details: `docs/` (architecture, Ghostty embedding, debugging).

Ghostty is pinned to v1.3.1 in `Scripts/build-ghosttykit.sh`: main needs
Xcode 26. State lives in `~/Library/Application Support/Terminus/`
(`session.json`, `snippets.json`).
