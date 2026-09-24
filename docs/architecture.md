# Architecture

One process, one window (for now), everything on the main thread except
libghostty's own threads and git calls.

## Window layout

```
┌──────────── tab strip (SwiftUI, in the title bar) ─────── ± +N −M ┐
├──────────┬──────────────────────────┬──────────────┬──────────────┤
│ sidebar  │ terminal container       │ editor pane  │ changes pane │
│ Files /  │ (every tab's TerminalView;│ (opens on a  │ (± badge or  │
│ Worktrees│  only the selected one   │  file click) │  ⌥⌘D; Warp-  │
│ Snippets │  visible)                │              │  style cards)│
│ (⌘B)     │                          │              │              │
└──────────┴──────────────────────────┴──────────────┴──────────────┘
      + ⌘P palette: an overlay over the whole content view
      + ⌘F search: an overlay over the terminal container; a compact find
        bar in its top-right corner while a terminal search is kept
```

- One split (`split`, vertical, autosave `TerminusColumns.v2`): sidebar | terminal | editor | changes. Bump the key's version whenever the column set changes, or stale positions get applied to the new columns.
- It is a `WideDividerSplitViewController` (grabbable 1 pt dividers). The terminal column keeps ≥ 240 pt.
- Sidebar, diff panel, tab strip, palette: SwiftUI in `NSHostingView`/`NSHostingController`. Terminal, editor text, editor header: AppKit.

## Ownership

`AppDelegate` → one `TerminalWindowController`, which owns:

| Object | Role |
|---|---|
| `TabStore` | ordered `Tab`s, selection, pinned-first invariant, drag reorder |
| `Tab` | a `TerminalView` + title, custom name, colour, pin, agent, cwd, `TabActivity` |
| `FileTreeModel` | tree of the selected tab's checkout; lazy listings, FSEvents invalidation, gitignore dimming |
| `WorktreeModel` | `git worktree list` of that repository |
| `DiffModel` | status, counts (always live — the ± badge), per-file diffs (only while the pane is open), stage/discard/commit of that checkout; works before the first commit (empty-tree base) |
| `SnippetStore` | `~/Library/Application Support/Terminus/snippets.json` |
| `PaletteModel` | ⌘P query and ranking |
| `SpotlightModel` | ⌘F: one query over the selected terminal's scrollback, the checkout's file names and their contents |
| `EditorViewController` + `EditorDocument` | the file open in the editor pane |

"That checkout" is `Tab.checkoutSource`, in order: an **attached** checkout
(Worktrees → Attach to This Tab), else where the tab's **agent** works
(`Tab.agentDirectory`, polled every 2 s from the claude/codex process's cwd —
Claude Code chdirs into a worktree on EnterWorktree), else the **shell's**
directory (OSC 7 → `Tab.workingDirectory`). Each is turned into a root by
`FileTreeModel.treeRoot(for:)`: the nearest ancestor with a `.git` (a file in a
linked worktree), never promoted to `$HOME`.

## Terminal events → UI

libghostty → `GhosttyRuntime.perform(target:action:)` → the surface's
`TerminalView` → closures set by the window controller:

| Ghostty action | Goes to |
|---|---|
| `SET_TITLE`, `PWD` | tab title, tab cwd (→ tree, worktrees, diff follow) |
| `NEW_TAB`, `CLOSE_TAB`, `GOTO_TAB`, `MOVE_TAB` | the window's tab operations (the user's Ghostty keybinds drive Terminus tabs) |
| `CLOSE_WINDOW`, `CLOSE_ALL_WINDOWS` | window close (with confirmation) |
| `TOGGLE_COMMAND_PALETTE` | Terminus palette |
| `START_SEARCH` | the ⌘F overlay (with Ghostty's needle, if any) |
| `END_SEARCH`, `SEARCH_TOTAL`, `SEARCH_SELECTED` | `TerminalSearch` → the overlay's terminal row and the compact bar's `3/12` |
| `RING_BELL`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `COMMAND_FINISHED` | `TabActivity`: `isWorking` + a ranked mark (waiting > failed > done) → tab strip (breathing glyph + sliding bar / ringing yellow dot / green check / red mark), notification, Dock badge |
| `OPEN_URL` | ⌘-click on a link libghostty matched: `FileLink` (shell dir, then checkout; `:line[:col]`, `(line,col)`) → the editor at that line; URLs, directories, binaries → system opener |
| `MOUSE_SHAPE`, `QUIT` | handled directly |
| `NEW_SPLIT`, `GOTO_SPLIT`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM` | the tab's splits (Ghostty's defaults: ⌘D, ⇧⌘D, ⌘[ ⌘], ⌥⌘arrows, ⌃⌘arrows, ⌃⌘=, ⇧⌘↩) |
| anything else (new window, …) | returns false: unhandled |

`close_surface_cb` (shell exited, or Ghostty's ⌘W) → `closeTab` (pinned tabs
ignore it unless the process actually exited).

## Splits

A tab is a `SplitTree<TerminalView>` (`Sources/Terminus/Splits/`): a
binary tree, panes at the leaves, each split an axis and a ratio. The tree is
pure (insert, remove, spatial neighbours, resize, equalize — unit-tested with
plain objects); `SplitHostView`, one per tab, lays it out: panes by frame,
1 pt gaps where its background shows as the divider, grabbable ±4 pt (its own
tracking loop, `acceptsFirstMouse`), unfocused panes under a dim.

- `Tab.terminal` is the **focused pane** — typing, ⌘F, links, the tab's title
  and directory follow it (`TerminalView.onFocus` → `Tab.focus`). What means
  the whole tab goes over `Tab.terminals`: closing and its warning, Tab Info's
  processes, finding the agent to follow, quitting.
- ⌘W closes the focused pane of a split tab (asking only if something runs in
  it), else the tab (always asking). `exit` closes just its pane.
- Zoom shows one pane alone; the others are occluded, not closed.

## Merged worktrees

`MergedWorktrees` (`Sources/Terminus/Git/`) decides which linked worktrees
are done with; `WorktreeModel.merged` holds it, refreshed with the list.
A branch is merged when

- its upstream is `[gone]` — pushed, then deleted on the remote: GitHub's
  delete-on-merge, and the only trace a squash merge leaves; or
- it has an upstream and its tip is reachable from the default branch
  (`origin/HEAD`, else the main worktree's branch).

Never pushed never counts: a New Task branch with no commits is reachable
from main too. A worktree whose folder was deleted by hand (`prunable`) is
cleanable as well. Rows get a purple merge mark; the Worktrees header gets a
count that runs **Clean Up Merged Worktrees…** (also File menu, ⌘P, a row's
menu): `git fetch --prune` (ssh in BatchMode), then one sheet listing what
goes and what stays — kept: a tab in it, uncommitted changes, locked. It runs
`git worktree remove` without `--force` and, if ticked, `git branch -D`
(`-d` refuses a squash-merged branch). The Worktrees reload button fetches too.

## Search (⌘F)

`SpotlightModel` (`Sources/Terminus/Search/`), rows in this order:

| Row | Source | Return |
|---|---|---|
| Terminal | libghostty's own search (`search:<needle>` binding action; totals come back as `SEARCH_TOTAL`) — highlights live behind the overlay | keeps the search, shows `TerminalSearchBar` (Return / ⇧Return / Esc) |
| File | `git ls-files --cached --others --exclude-standard` of the checkout (`diff.root ?? tree.root`), loaded once per open, fuzzy-ranked with the name weighted over the path | opens it in the editor |
| In file | `git grep -F -i -I --untracked`, ≥ 2 characters, 150 ms debounce, capped per file and in total | opens it at that line (`EditorViewController.go(toLine:)`) |

Without a checkout only the terminal row is shown. Esc (or a click outside)
ends the terminal search too; only choosing the terminal row keeps it.

## Tab Info (⌘I, or Show Info… on a tab)

A popover per tab, live while open (`TabInfoModel`, `Sources/Terminus/Info/`):

| Section | Source |
|---|---|
| Location | tab cwd → checkout, branch, worktree-of, changed files (git) |
| Running | `ProcessInspector`: everything under the tab's `login` (paired to its surface by `SurfaceProcesses`, since libghostty doesn't expose the pid), plus anything tagged `TERMINUS_TAB_ID` that left the tree. CPU% from task-time deltas (Mach ticks → ns), resident memory. Links via sysctl KERN_PROC — proc_pidinfo refuses root's `login`. |
| Listening | `lsof` on the tab's pids, every 3 s; Open → localhost |
| Claude session | `ClaudeUsageReader` on `~/.claude/projects/<cwd as ->/<session>.jsonl`: streamed, incremental, ends-of-line byte search, replies de-duplicated by id |
| Disk | `DiskUsage` of the checkout only, cancellable, cached 60 s |

macOS hides the environment of Apple-signed binaries (zsh, sleep, git) from
other processes, so the env tag alone can't find a shell — hence the tree.

## Agents

`Agent` is a closed enum (Claude, Codex). An agent starts by typing its command
into a fresh login shell (`initial_input`), so quitting it leaves a shell.
Restore types `resumeCommand` (`claude --continue`, `codex resume --last`).
Claude Code needs no configuration for tab flags: with `TERM_PROGRAM=ghostty`
its default notification channel is OSC 777 and its progress bar (OSC 9;4) is
on by default (checked against 2.1.280).

## Persistence

| What | Where |
|---|---|
| Tabs (cwd, name, colour, pin, agent) + selection | `~/Library/Application Support/Terminus/session.json` (1 s debounced + on quit) |
| Snippets | `…/Terminus/snippets.json` |
| Sidebar/diff visible, sidebar panel | `UserDefaults` (`sidebarVisible`, `diffVisible`, `sidebarPanel`) |
| Divider positions | `UserDefaults` split autosave (`TerminusColumns.v2`) |

Bundle id `ai.promptrails.terminus`.
