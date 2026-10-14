# Terminus

> A terminal for working with agents.

A native macOS terminal built around how agent-driven work actually happens:
several worktrees at once, each with an agent (Claude Code, Codex) running in it.

The terminal itself is [libghostty](https://github.com/ghostty-org/ghostty)
(`GhosttyKit`) in a Swift/AppKit app — your `~/.config/ghostty/config` (font,
theme, keybinds) applies as-is.

## What's in it

- **Settings** (⌘,) — a tab, as in Warp, over two files you can also edit
  by hand, as in VS Code: `settings.json` and `keybindings.json` in
  `~/Library/Application Support/Terminus/` (only what you changed is in
  them; comments are fine; a hand edit applies at once). Every section
  switches between controls and its JSON. General (reopening tabs and their
  text, where new tabs open, when closing asks, Tab Peek), Appearance and
  Terminal (font, theme, cursor, padding, ⌥ as Alt, copy on select,
  scrollback, clipboard — over your Ghostty config, applied to open
  terminals at once), Agents, Editor, Notifications (which events notify),
  Keyboard Shortcuts (click a shortcut, press the new keys; menus and the
  terminal's keys alike, clashes flagged), and About — the version, what's
  new, and updates from GitHub releases (⌥⌘O: the changelog; a chip in the
  title bar when a newer version is out).
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
- **Open in your editor**: double-click a file in the tree (or ↗ in the
  editor pane) and it opens in the app you picked — asked once, remembered;
  **Open With ▸** in the file's menu, or right-click on ↗, switches it.
- **Changes** on the right (the ± badge in the title bar, View ▸ Changes, or
  ⌥⌘D): changed files of the tab's worktree with +N −M, live diff.
  **Uncommitted** (stage / discard / commit), or **Branch**: everything since
  the branch left the default branch, its commits listed too — an agent's
  work stays visible after it commits. The badge shows in any repository: the
  uncommitted totals, else the branch's, else a plain ±; a click on it opens
  the scope it counts. Each file says **why** it changed: what Claude said
  when it edited it (from Claude Code's session transcripts on this Mac,
  subagents' included; nothing leaves it), two lines and when — a click shows
  it all and what it said at the edits before — and in Branch the commits
  that touched it.
- **Drop files on a terminal** — from Finder, the Desktop, another app,
  Photos or Safari (their images are saved first), or the sidebar's file
  tree: a shell gets their quoted paths; where Claude Code runs, other files
  and folders become `@`-mentions (relative to where it works) and images
  their paths, which it attaches as `[Image #N]`. Hold ⌥ for plain paths.
  Text and links go in as text. Nothing runs until you press Return.
- **Snippets** with `{{placeholders}}`; click to type in, Run to execute.
- **Command palette** (⌘P) over actions, tabs, worktrees and snippets.
- **Merged worktree clean-up**: merged worktrees (merged into the default
  branch, or squash-merged by a pull request) get a purple mark; one click
  removes them and their branches, keeping any with changes, a tab, or
  commits no remote has.
- **From Finder**: right-click → Open With → Terminus (a folder opens as a
  tab, a file in the editor, in the tab already in its repository), or
  Services → **New Terminus Tab Here**; dropping on the Dock icon works too.
  Terminus is never made the default app for anything.
- **Claude sessions** (sidebar, speech-bubble icon): every conversation run
  in this repository's worktrees, newest first, with Claude's title for it;
  a click goes to the tab it runs in, or resumes it (`claude --resume`) in a
  new tab where it ran.
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
- **Microphone** for programs in the terminal (Claude Code's `/voice`): macOS
  asks the first time one wants it. Refused, or never asked? Allow Terminus in
  System Settings ▸ Privacy & Security ▸ Microphone.

## Keys

| | |
|---|---|
| ⌘T / ⌘W | New / close tab (plus your Ghostty tab keybinds) |
| ⌥⌘C / ⌥⌘X | New Claude / Codex tab in this directory |
| ⇧⌘N | New Task (worktree + branch + agent) |
| ⌘1…9, ⇧⌘[ ⇧⌘] | Go to tab |
| ⌘B | Sidebar |
| ⌥⌘D | Changes |
| ⌘P | Command palette (↵ run, ⌥↵ insert snippet) |
| ⌘D / ⇧⌘D | Split right / down (⌘[ ⌘] or ⌥⌘arrows move between panes, ⇧⌘↩ zooms one) |
| ⇧⌘A | Agent overview |
| ⌘, / ⌥⌘O | Settings / the changelog |
| ⌘F | Search terminal + files (↵ open; the terminal row keeps a find bar) |
| ⌘-click | Open a printed `path:line` in the editor |
| ⌥ while dropping files | Plain quoted paths, even where Claude Code runs |

## Install

**Without Xcode: the release DMG.** Download `Terminus-<version>.dmg` from
[Releases](https://github.com/Overcraft-hq/overterm/releases), open it and
drag **Terminus** to **Applications** (Apple Silicon, macOS 13+). It is signed
ad hoc and not notarized, so macOS stops the first open: right-click → **Open**
(macOS 15 and later: System Settings → Privacy & Security → **Open Anyway**),
or `xattr -dr com.apple.quarantine /Applications/Terminus.app`. Releases are
published by hand (Releasing, below).

**With Xcode: build from source.** The Command Line Tools alone can't build
GhosttyKit: it needs `xcodebuild` and the Metal compiler. With the
requirements under Build:

```sh
mise trust && mise install   # pinned Zig
make ghosttykit              # GhosttyKit from the pinned Ghostty (once, ~2 min)
make install                 # build Terminus.app and copy it to /Applications
```

## Build

Requirements: macOS 13+, Xcode 16 or 26.2, [mise](https://mise.jdx.dev).
Newer SDKs don't work yet: the pinned Zig 0.15.2 can't link against the macOS
26.5 and 27 SDKs (their libSystem lists only arm64e), and Xcode 27's SwiftPM
builds an app that macOS runs in 13.0 compatibility mode. With such an Xcode
selected, point the shell at a supported one; the system's choice stays:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.app/Contents/Developer  # that Xcode's path
```

Xcode 26 downloads the Metal compiler separately. If `make ghosttykit` can't
find `metal`: `xcodebuild -downloadComponent MetalToolchain`.

```sh
mise trust && mise install   # pinned Zig
make ghosttykit              # GhosttyKit from the pinned Ghostty (once, ~2 min)
make hooks                   # git hooks: version bump check, release tags (once)
make test                    # unit + integration tests
make e2e                     # end-to-end scenarios in the real app
make run                     # build Terminus.app and open it
make install                 # …and copy it to /Applications (Launchpad, Spotlight)
```

Builds are signed ad hoc, which makes each one a new app to macOS: a
permission such as the microphone would be asked for again after every
update. With `SIGN_IDENTITY` set — in the environment, or in an untracked
`local.mk` next to the Makefile — `make install` re-signs the installed copy
with that identity, and the grants stay (`make app`, `test` and `e2e` stay ad
hoc and never touch the keychain):

```make
# local.mk (gitignored); list yours with: security find-identity -v -p codesigning
SIGN_IDENTITY ?= Apple Development: Your Name (TEAMID1234)
```

The first signing asks for the keychain's permission to use the key
(Always Allow).

## Releasing

Push the commit (and its `v<VERSION>` tag: `git push origin main --tags`),
then GitHub → Actions → **Release** → Run workflow. On a macOS runner it runs
the unit tests, builds the app and a DMG, and publishes release `v<VERSION>`
— on that tag, or a new one on the commit it ran on — with the version's
`CHANGELOG.md` entry as notes and the DMG attached. It refuses a version
already released: bump first. Only by hand: nothing triggers it on push.
Locally, the same pieces: `make app dmg` and `Scripts/release-notes.sh`.

The release is signed ad hoc and not notarized: its notes say how to open it
the first time, as Install does above.

Details: `docs/` (architecture, Ghostty embedding, debugging).

Ghostty is pinned to v1.3.1 in `Scripts/build-ghosttykit.sh`: main needs
Xcode 26. State lives in `~/Library/Application Support/Terminus/`
(`session.json`, `snippets.json`).

## Versioning

`VERSION` holds the version ([SemVer](https://semver.org)), `CHANGELOG.md`
what each version changed, and the commit that brings a version is tagged
`v<version>`. **Terminus ▸ About Terminus** shows it — "Version 1.10.0 (103)",
the number in brackets counting commits — and under it the commit the app was
built from and the day: `commit 7e68283 · 26 Sep 2026`, with `-dirty` after the
hash when it was built with uncommitted changes.

Every commit that changes the app bumps the version as its effect warrants —
major, minor or patch; the rules are in CLAUDE.md (Commits):

```sh
make hooks                                          # once per clone
Scripts/bump-version.sh minor "tabs: what changed"  # or patch, major
git add VERSION CHANGELOG.md                        # commit them with the change
```

The pre-commit hook refuses a change to the app without a new VERSION
(`SKIP_VERSION_CHECK=1 git commit …` lets one through), and the post-commit
hook adds the tag. Tags stay local until pushed: `git push origin v1.10.0`.
