# Terminus

Private macOS terminal for PromptRails work — Swift/AppKit around libghostty
(`GhosttyKit`), built for several worktrees at once, each with an agent
(Claude Code, Codex) in it. Not a product: no `*rails` name, no remote users.

## Quick reference

```
mise trust && mise install   # pinned Zig (only needed to build GhosttyKit)
make ghosttykit              # Frameworks/GhosttyKit.xcframework + GhosttyResources (once; ~2 min)
make test                    # swift test — run OUTSIDE the Bash sandbox (see docs/debugging.md)
make app                     # Terminus.app in the repo
make install                 # …and copy it to /Applications
make icon                    # Resources/AppIcon.svg → AppIcon.icns
```

## Layout

| Path | What |
|---|---|
| `Sources/Terminus/Ghostty/` | libghostty embedding: `GhosttyRuntime` (app + C callbacks + actions), `TerminalView` (one surface: keys, IME, mouse), `GhosttyInput` |
| `Sources/Terminus/Tabs/` | `Tab`, `TabStore` (order, selection, pin invariant), tab strip, `TabActivity` (needs-you flags), `Agent`, tab context menu |
| `Sources/Terminus/Window/` | `TerminalWindowController` (owns everything below; layout; menu actions), `ChromeTheme`, `AttentionNotifier`, split controllers |
| `Sources/Terminus/Sidebar/` | Files / Worktrees / Snippets panels, `FileTreeModel`, `WorktreeModel`, `DirectoryWatcher` (FSEvents) |
| `Sources/Terminus/Diff/` | changes pane on the right + ± badge, `DiffModel` (live counts, per-file diffs, stage/commit) |
| `Sources/Terminus/Editor/` | editor pane beside the terminal, `EditorDocument`, gutter, `SyntaxHighlighter` |
| `Sources/Terminus/Git/` | `Git.run` (libdispatch-backed), porcelain / numstat / unified-diff parsers, `Worktree` |
| `Sources/Terminus/Tasks/` | New Task: worktree + branch + agent |
| `Sources/Terminus/Snippets/`, `Palette/`, `Session/` | snippets store + sheets, ⌘P palette, session save/restore |
| `Scripts/` | GhosttyKit build, app bundling, icon |

More: `docs/architecture.md`, `docs/ghostty.md`, `docs/debugging.md`.

## Rules

- **Never drive the UI with synthetic input** (osascript `keystroke`, System Events, CGEvent). It types into whatever has focus — once it typed into the user's own Claude Code prompt. To check layout or behaviour, use the in-app diagnostic mode (`TERMINUS_DUMP_LAYOUT`, docs/debugging.md), which only touches its own window, or ask the user.
- **libghostty C callbacks must be built in a `nonisolated` context** (`GhosttyRuntime.runtimeConfig()`). `wakeup_cb` comes from the renderer thread; a closure written inside a `@MainActor` type traps under Swift 6.
- **Git goes through `Git.run`** — a GCD thread per call, never a blocked Swift-concurrency thread (the cooperative pool starves; signalbox froze that way).
- **Ghostty is pinned to v1.3.1** (`Scripts/build-ghosttykit.sh`, SHA-checked) with Zig 0.15.2 (`mise.toml`): Ghostty main needs Xcode 26. Bump both together; check `ghostty.h` for API changes.
- **Views don't clip by default since macOS 14.** A subview drawing past its bounds (the editor gutter did) paints over neighbours — set `clipsToBounds` where content is taller than the view.
- **The tab strip lives in the title bar**, which swallows right-clicks before SwiftUI sees them. Context menus there go through the window's local event monitor (`installTabRightClick`), not `.contextMenu`.
- **Split dividers are 1 pt**; `WideDividerSplitViewController` widens the grab area. Autosave key `TerminusColumns.v2` — bump the version whenever the column set changes, or stale positions are applied to new columns.
- **Closing always asks** (tab, window, app); only a shell's own `exit` closes silently. Keep it that way — it was asked for.
- **Don't re-publish selection**: `TabStore.select` is a no-op for the selected tab; a selection change takes the keyboard for the terminal, which kills an in-place rename.
- **Typing text then running it**: `insertText` is a bracketed paste, so a trailing newline is literal. Use `pressReturn()`.
- Keep features built-in (Claude, Codex, the snippet starters); no plugin slots.
- Tests: pure logic and real-git integration (temp repos) live in `Tests/TerminusTests`. `Tab`/`TabStore` aren't unit-tested: a `Tab` owns a real surface.

## Commits

`area: what changed` subject (areas: `terminal`, `tabs`, `sidebar`, `diff`, `editor`, `git`, `agents`, `session`, `palette`, `snippets`, `window`, `keys`, `build`, `docs`…), body says why. One fix per commit. Author `bahattincinic@gmail.com`; no `Co-Authored-By` trailer. Run `swift format --in-place --recursive Sources Tests` and `make test` before committing.
