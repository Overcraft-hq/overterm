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
| `RING_BELL`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `COMMAND_FINISHED` | `TabActivity`: `isWorking` + a ranked mark (waiting > failed > done) → tab strip (breathing glyph + sliding bar / ringing yellow dot / green check / red mark), notification, Dock badge |
| `OPEN_URL`, `MOUSE_SHAPE`, `QUIT` | handled directly |
| anything else (splits, new window, …) | returns false: unhandled |

`close_surface_cb` (shell exited, or Ghostty's ⌘W) → `closeTab` (pinned tabs
ignore it unless the process actually exited).

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
