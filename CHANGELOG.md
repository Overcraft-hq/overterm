# Changelog

What changed in each version of Terminus, newest first. `VERSION` is the
version ([SemVer](https://semver.org)): a commit that changes the app bumps it
— major, minor or patch, as CLAUDE.md's Commits section sets out — with
`Scripts/bump-version.sh`, which adds the line here. The commit that brings a
version is tagged `v<version>`. 1.0.0 is the original Terminus as imported
(bfb55fb); its lines are the commits up to it.

## 1.32.3 — 2026-10-15

- keys: ⌘F is the terminal's search again

## 1.32.2 — 2026-10-15

- editor: files open beside the terminal again, and ⌘P is left alone

## 1.32.1 — 2026-10-14

- editor: review fixes — vim undo across keys, stale completions, shared language-server documents

## 1.32.0 — 2026-10-14

- editor: Zed's editor in the pane — tree-sitter colours, tabs, zoom, language servers, Zed's keys, vim

## 1.31.1 — 2026-10-14

- build: tree-sitter and the editor's grammars, pinned with Helix's queries

## 1.31.0 — 2026-10-14

- build: the app is Overterm

## 1.30.5 — 2026-10-14

- build: the repository moved to Overcraft-hq/overterm

## 1.30.4 — 2026-10-14

- window: a shut column no longer eats 10 pt of the window

## 1.30.3 — 2026-10-14

- tabs: no Agent Overview button in the strip

## 1.30.2 — 2026-10-14

- tabs: ⌘T doesn't read an island's folder binding

## 1.30.1 — 2026-10-11

- tabs: an island restored from an older session comes back unbound

## 1.30.0 — 2026-10-11

- tabs: stop new tabs from being swallowed by an island

## 1.29.0 — 2026-10-09

- splits: drop a tab onto a pane to split with it

## 1.28.0 — 2026-10-09

- palette: ⌘K over what you have run, your snippets and the app's actions

## 1.27.0 — 2026-10-09

- agents: ask an agent about what you selected

## 1.26.0 — 2026-10-08

- terminal: live ports, and the link under the pointer

## 1.25.0 — 2026-10-08

- agents: an inbox for everything waiting on you

## 1.24.0 — 2026-10-08

- terminal: command blocks and a scroll map

## 1.23.1 — 2026-10-08

- terminal: read the scrollbar, the cell size and the selection

## 1.23.0 — 2026-10-08

- tabs: settle a new island, drag tabs into one, and reach them with ⌃⌘1…9

## 1.22.0 — 2026-10-08

- sidebar: one panel header, and rows that say what is happening in them

## 1.21.0 — 2026-10-08

- splits: give every pane a header

## 1.20.0 — 2026-10-08

- tabs: redraw the strip — what a tab is, what it wants, and which island it is in

## 1.19.0 — 2026-10-08

- window: float the sidebar, the terminal and the panes as cards

## 1.18.1 — 2026-10-08

- window: a colour vocabulary for the chrome

## 1.18.0 — 2026-10-08

- tabs: group tabs into islands in the strip

## 1.17.0 — 2026-10-07

- settings: a Settings tab, as Warp's, over settings.json and keybindings.json, as VS Code's — every shortcut can be changed

## 1.16.0 — 2026-10-07

- tabs: peek at every tab's live terminal with a three-finger swipe

## 1.15.28 — 2026-09-28

- agents: an agent's notification no longer crashes the app while it is in the background

## 1.15.27 — 2026-09-28

- diff: the changes pane renders nothing while hidden — closing it over a big diff froze the window

## 1.15.26 — 2026-09-28

- agents: reading a big Claude transcript holds one chunk at a time, not the whole file

## 1.15.25 — 2026-09-28

- tabs: a terminal is paired only with a login process, never with a git the app runs

## 1.15.24 — 2026-09-28

- agents: transcript parse state is kept for the latest 120 Claude sessions, not every one ever read

## 1.15.23 — 2026-09-28

- diff: the badge keeps up while a build writes, refreshes run one at a time, and only in repositories

## 1.15.22 — 2026-09-28

- merge: the keyboard-layout E2E fix (tagged v1.15.19) together with 1.15.19-1.15.21

## 1.15.21 — 2026-09-28

- editor: the line-number gutter no longer covers the start of lines

## 1.15.20 — 2026-09-28

- editor: a 4 MB file opens and types without stalling

## 1.15.19 — 2026-09-28

Two commits took this number at once; the tag is the first.

- e2e: the Keyboard Shortcuts check follows the keyboard layout — ⌘, is ⌘Ö on Turkish Q (tagged v1.15.19)
- search: ⌘F ranks off the main thread, and a superseded or runaway git grep is stopped

## 1.15.18 — 2026-09-28

- merge: the Xcode 27 build fix (tagged v1.15.14) together with 1.15.14-1.15.17

## 1.15.17 — 2026-09-28

- sidebar: a busy watched folder (a tab in ~) no longer costs 35-50% CPU

## 1.15.16 — 2026-09-28

- diff: a file's diff builds its lines lazily — a 3000-line diff froze the window 9 s

## 1.15.15 — 2026-09-27

- sidebar: the file tree sorts a folder 2.5x faster

## 1.15.14 — 2026-09-27

Two commits took this number at once; the tag is the first.

- build: builds with Xcode 27 (Swift 6.4) — the saved split layout declares Sendable (tagged v1.15.14)
- agents: the 2 s polls skip a tick while the last scan still runs

## 1.15.13 — 2026-09-27

- diff: counting untracked files' lines no longer stalls the window

## 1.15.12 — 2026-09-27

- tabs: working and waiting marks animate in Core Animation — five working tabs no longer cost 9% CPU

## 1.15.11 — 2026-09-27

- editor: opening a FIFO or a device no longer hangs the app

## 1.15.10 — 2026-09-27

- editor: saving asks before overwriting a change made on disk, and keeps symlinks

## 1.15.9 — 2026-09-27

- session: an unreadable session or snippets file is set aside, not written over

## 1.15.8 — 2026-09-27

- session: autosave keeps saving while agents work, and stops after the final save

## 1.15.7 — 2026-09-27

- splits: closing a pane that has already gone no longer closes its tab

## 1.15.6 — 2026-09-27

- terminal: pasted files are shell-quoted like dropped ones

## 1.15.5 — 2026-09-27

- terminal: the clipboard sheet sets its own keys — Return refuses, Allow and Paste take a click

## 1.15.4 — 2026-09-27

- git: a hung git or gh is killed after two minutes, and a burst of calls can no longer deadlock

## 1.15.3 — 2026-09-27

- worktrees: Clean Up keeps a gone branch with commits no remote has, and worktrees an agent works in

## 1.15.2 — 2026-09-27

- editor: unsaved changes are asked about on ⌘Q and keep the window when its last tab closes

## 1.15.1 — 2026-09-27

- terminal: Ghostty's close keys no longer free a terminal from inside its own callback

## 1.15.0 — 2026-09-26

- settings: About — version, what's new, updates from GitHub releases; View Latest Changelog (⌥⌘O)

## 1.14.0 — 2026-09-26

- settings: Keyboard Shortcuts — the menus', the terminal's from your Ghostty config, and the mouse's, searchable

## 1.13.0 — 2026-09-26

- settings: Agents — arguments for Claude and Codex, New Task's agent, worktree location and base

## 1.12.1 — 2026-09-26

- sidebar: a folder with thousands of entries no longer crashes the app

## 1.12.0 — 2026-09-26

- settings: a Settings window (⌘,) — General and Appearance, applied as they change

## 1.11.1 — 2026-09-26

- build: releases take the version from VERSION and their notes from CHANGELOG.md

## 1.11.0 — 2026-09-26

- docs: README, About and docs describe Terminus on its own
- build: bundle id io.github.terminus-app.terminus; settings carried over once from the old id
- build: a Release workflow, run by hand — tag, notes, DMG

## 1.10.0 — 2026-09-26

- build: version the app — VERSION, changelog, About shows version and commit

## 1.9.0 — 2026-09-26

- diff: start cards folded when many files changed

## 1.8.0 — 2026-09-26

- diff: colour diffs like code and mark what changed within a line

## 1.7.0 — 2026-09-26

- diff: show why each changed file changed

## 1.6.1 — 2026-09-26

- agents: read why Claude made each edit from its session transcripts

## 1.6.0 — 2026-09-26

- terminal: drop files onto a pane to insert references to them

## 1.5.3 — 2026-09-26

- diff: Branch finds main when there is no origin/HEAD

## 1.5.2 — 2026-09-26

- window: the ± badge opens the scope it counts

## 1.5.1 — 2026-09-26

- agents: an agent exiting mid-poll no longer crashes the app

## 1.5.0 — 2026-09-26

- window: make the changes pane easy to find

## 1.4.0 — 2026-09-26

- diff: show what the branch changed, not only what is uncommitted

## 1.3.2 — 2026-09-26

- diff: refresh the changes pane after a commit in a linked worktree

## 1.3.1 — 2026-09-25

- build: sign installs with a stable identity so privacy grants survive updates

## 1.3.0 — 2026-09-25

- build: let programs running in Terminus ask for the microphone

## 1.2.0 — 2026-09-25

- editor: open files in the app the user picked, not the per-type default

## 1.1.1 — 2026-09-25

- window: the find bar takes the keyboard only when a search starts

## 1.1.0 — 2026-09-25

- terminal: ask before a program reads the clipboard or pastes unsafe text

## 1.0.0 — 2026-09-25

- sessions: list the repository's Claude sessions and resume one
- finder: open files and folders in Terminus from Finder
- agents: Esc closes the overview wherever the keyboard is
- session: a shell pane's text comes back on the next launch
- agents: an overview of every tab (⇧⌘A)
- diff: wrap long lines instead of centring them off the pane
- github: pull requests and CI for worktrees, and a Pull Request pane
- session: a split tab comes back split
- splits: split a tab into panes (⌘D, ⇧⌘D)
- e2e: survive keys lost mid-command, and output not yet drawn
- worktrees: mark merged worktrees and clean them up in one step
- editor: reading the selected line before any file was opened trapped
- docs: ⌘F search and ⌘-click file links
- terminal: ⌘-click a file path to open it in the editor, at its line
- e2e: type only after the shell has reported its first prompt
- window: centre the tabs in the title bar, no empty band under them
- search: ⌘F searches the terminal, file names and contents in one overlay
- tabs: open a new tab in the directory the tab already knows
- docs: how a tab picks its checkout; the @Published trap
- worktrees: follow the agent into its worktree; attach / detach
- build(deps): bump actions/checkout from 4 to 7
- build: weekly Ghostty release check opens an issue
- build: dependabot config (GitHub Actions, weekly, grouped)
- tabs: dragging reorders without flip-flopping
- docs: Tab Info, typing into shells in E2E, verbatim numbers
- info: the checkout's disk use, biggest entries first
- info: the Claude session's token use
- diff: print change counts verbatim
- info: listening ports, with Open
- e2e: type only at a settled prompt; don't depend on the app being inactive
- info: Tab Info — where a tab is and what it is running
- info: find and measure a tab's processes
- e2e: raise the failure mark from a background tab
- window: exit closes a tab silently even when libghostty is late
- tabs: drag to reorder actually works
- docs: tab activity marks; the marks scenario
- tabs: show what an agent is doing — working, waiting, done, failed
- docs: testing guide — unit, integration and end-to-end
- e2e: end-to-end scenarios run inside the real app
- app: isolate test and diagnostic runs from the real state
- tests: tab logic on real Tabs, input translation, agents
- docs: changes pane on the right, new diagnostic switches, lessons
- window: always confirm closing a tab, the window, or the app
- tabs: renaming no longer loses focus the moment it starts
- diff: Warp-style changes pane on the right, ± badge in the title bar
- docs: CLAUDE.md, architecture, Ghostty embedding, debugging
- window: grabbable dividers; terminal can't be squeezed to 0
- editor: make the text, header and gutter actually render
- editor: syntax colours
- editor: open files in a resizable pane beside the terminal
- sidebar: Warp-style icon tabs for Files, Worktrees, Snippets
- tabs: working right-click menu, Chrome-style pinned tabs
- build: make install copies the app into /Applications
- sidebar: dim gitignored entries
- agents: note why Claude Code needs no setup for tab flags
- keys: route Ghostty's close-window and palette bindings
- readme: what Terminus does and its keys
- diff: stage, discard and commit from the panel
- palette: ⌘P over actions, tabs, worktrees and snippets
- snippets: sidebar section, editor, placeholder prompt
- snippets: model, store and fuzzy matching
- diff: live diff panel above the terminal
- git: status, numstat and unified-diff parsing
- agents: flag tabs that want you
- session: restore tabs on launch, agents resume
- tasks: New Task — a worktree, a branch and an agent in one step
- agents: open a Claude or Codex tab
- sidebar: worktrees of the tab's repository
- git: a libdispatch-backed git runner and worktree parsing
- sidebar: stop the FSEvents stream when a watcher is freed
- sidebar: live refresh via FSEvents
- tests: path quoting, tree root and file tree model
- sidebar: file actions
- sidebar: collapsible file tree of the tab's checkout
- tabs: drag to reorder
- tabs: pin
- tabs: colour marks
- tabs: rename in place
- tabs: several terminals in one window, strip in the title bar
- icon: a signal-yellow cursor on a terminal prompt
- terminal: embed a libghostty surface in the window
- ghosttykit: stage terminfo and shell integration, bundle them
- app: SwiftPM skeleton with an empty window
- ghosttykit: build the xcframework from a pinned Ghostty release
- repo: scaffold
