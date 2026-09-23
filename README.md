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
  pins and directories come back on relaunch; agent tabs resume their last
  conversation (`claude --continue`, `codex resume --last`).
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

## Build

Requirements: macOS 13+, Xcode 16, [mise](https://mise.jdx.dev).

```sh
mise trust && mise install   # pinned Zig
make ghosttykit              # GhosttyKit from the pinned Ghostty (once, ~2 min)
make test                    # unit tests
make run                     # build Terminus.app and open it
make install                 # …and copy it to /Applications (Launchpad, Spotlight)
```

Details: `docs/` (architecture, Ghostty embedding, debugging).

Ghostty is pinned to v1.3.1 in `Scripts/build-ghosttykit.sh`: main needs
Xcode 26. State lives in `~/Library/Application Support/Terminus/`
(`session.json`, `snippets.json`).
