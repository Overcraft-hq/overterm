# Architecture

One process, one window (for now), everything on the main thread except
libghostty's own threads and git calls.

## Window layout

```
┌───────────── tab strip (SwiftUI, in the title bar) ─────────────┐
├──────────┬──────────────────────────────────┬───────────────────┤
│ sidebar  │ diff panel (collapsible, ⌥⌘D)    │ editor pane       │
│ Files /  ├──────────────────────────────────┤ (collapsible,     │
│ Worktrees│ terminal container               │  opens on a file  │
│ Snippets │ (every tab's TerminalView;       │  click)           │
│ (⌘B)     │  only the selected one visible)  │                   │
└──────────┴──────────────────────────────────┴───────────────────┘
      + ⌘P palette: an overlay over the whole content view
```

- Outer split (`split`, vertical, autosave `TerminusColumns`): sidebar | terminal column | editor.
- Terminal column (`terminalSplit`, horizontal, autosave `TerminusDiff`): diff | terminal container.
- Both are `WideDividerSplitViewController`s (grabbable 1 pt dividers).
- Sidebar, diff panel, tab strip, palette: SwiftUI in `NSHostingView`/`NSHostingController`. Terminal, editor text, editor header: AppKit.

## Ownership

`AppDelegate` → one `TerminalWindowController`, which owns:

| Object | Role |
|---|---|
| `TabStore` | ordered `Tab`s, selection, pinned-first invariant, drag reorder |
| `Tab` | a `TerminalView` + title, custom name, colour, pin, agent, cwd, `TabActivity` |
| `FileTreeModel` | tree of the selected tab's checkout; lazy listings, FSEvents invalidation, gitignore dimming |
| `WorktreeModel` | `git worktree list` of that repository |
| `DiffModel` | status/diff/stage/commit of that checkout, only while the panel is open |
| `SnippetStore` | `~/Library/Application Support/Terminus/snippets.json` |
| `PaletteModel` | ⌘P query and ranking |
| `EditorViewController` + `EditorDocument` | the file open in the editor pane |

"That checkout" = `FileTreeModel.treeRoot(for: cwd)`: the nearest ancestor with
a `.git` (a file in a linked worktree), never promoted to `$HOME`. The selected
tab's cwd comes from shell integration (OSC 7) via `Tab.workingDirectory`.

## Terminal events → UI

libghostty → `GhosttyRuntime.perform(target:action:)` → the surface's
`TerminalView` → closures set by the window controller:

| Ghostty action | Goes to |
|---|---|
| `SET_TITLE`, `PWD` | tab title, tab cwd (→ tree, worktrees, diff follow) |
| `NEW_TAB`, `CLOSE_TAB`, `GOTO_TAB`, `MOVE_TAB` | the window's tab operations (the user's Ghostty keybinds drive Terminus tabs) |
| `CLOSE_WINDOW`, `CLOSE_ALL_WINDOWS` | window close (with confirmation) |
| `TOGGLE_COMMAND_PALETTE` | Terminus palette |
| `RING_BELL`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `COMMAND_FINISHED` | `TabActivity` → dot / spinner / notification / Dock badge |
| `OPEN_URL`, `MOUSE_SHAPE`, `QUIT` | handled directly |
| anything else (splits, new window, …) | returns false: unhandled |

`close_surface_cb` (shell exited, or Ghostty's ⌘W) → `closeTab` (pinned tabs
ignore it unless the process actually exited).

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
| Divider positions | `UserDefaults` split autosave (`TerminusColumns`, `TerminusDiff`) |

Bundle id `ai.promptrails.terminus`.
