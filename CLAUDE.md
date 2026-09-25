# Terminus

Private macOS terminal for PromptRails work — Swift/AppKit around libghostty
(`GhosttyKit`), built for several worktrees at once, each with an agent
(Claude Code, Codex) in it. Not a product: no `*rails` name, no remote users.

## Quick reference

```
mise trust && mise install   # pinned Zig (only needed to build GhosttyKit)
make ghosttykit              # Frameworks/GhosttyKit.xcframework + GhosttyResources (once; ~2 min)
make test                    # unit + integration tests (~3 s)
make e2e                     # end-to-end scenarios in the real app (~15 s, opens windows)
                             # both: run OUTSIDE the Bash sandbox — docs/testing.md
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
| `Sources/Terminus/Info/` | Tab Info (⌘I): processes, ports, Claude tokens, disk — see docs/architecture.md |
| `Sources/Terminus/Agents/` | ⇧⌘A agent overview: `AgentOverviewModel` (cards, ordering), view; `Info/ClaudeActivity` reads what a session is doing |
| `Sources/Terminus/GitHub/` | PRs and CI via `gh`: parsers (`PullRequest.swift`), the Pull Request pane (`PullRequestModel`/`View`) |
| `Sources/Terminus/Splits/` | a tab's panes: `SplitTree` (pure layout logic) and `SplitHostView` (frames, dividers, dim) |
| `Sources/Terminus/Search/` | ⌘F overlay: terminal + file names + contents (`SpotlightModel`, `CheckoutSearch`); the terminal half is `Ghostty/TerminalSearch` |
| `Sources/Terminus/Snippets/`, `Palette/`, `Session/` | snippets store + sheets, ⌘P palette, session save/restore |
| `Scripts/` | GhosttyKit build, app bundling, icon |

More: `docs/architecture.md`, `docs/ghostty.md`, `docs/testing.md`, `docs/debugging.md`.

## Rules

- **Never drive the UI with synthetic input** (osascript `keystroke`, System Events, CGEvent). It types into whatever has focus — once it typed into the user's own Claude Code prompt. To check layout or behaviour, use the in-app diagnostic mode (`TERMINUS_DUMP_LAYOUT`, docs/debugging.md), which only touches its own window, or ask the user.
- **libghostty C callbacks must be built in a `nonisolated` context** (`GhosttyRuntime.runtimeConfig()`). `wakeup_cb` comes from the renderer thread; a closure written inside a `@MainActor` type traps under Swift 6.
- **Clipboard confirmations complete *confirmed*** — the text, or `""` to refuse (`ClipboardConfirmation.reply`). Completed unconfirmed, libghostty asks again at once: that looped until the stack overflowed, crashing the app on any OSC 52 read.
- **Git goes through `Git.run`** — a GCD thread per call, never a blocked Swift-concurrency thread (the cooperative pool starves; signalbox froze that way).
- **Ghostty is pinned to v1.3.1** (`Scripts/build-ghosttykit.sh`, SHA-checked) with Zig 0.15.2 (`mise.toml`): Ghostty main needs Xcode 26. Bump both together; check `ghostty.h` for API changes. A weekly workflow (`ghostty-release-check`, the repo's only one — macOS CI is too expensive) opens an issue with the steps when Ghostty tags a newer release.
- **Views don't clip by default since macOS 14.** A subview drawing past its bounds (the editor gutter did) paints over neighbours — set `clipsToBounds` where content is taller than the view.
- **The tab strip lives in the title bar**, which swallows right-clicks before SwiftUI sees them. Context menus there go through the window's local event monitor (`installTabRightClick`), not `.contextMenu`.
- **Split dividers are 1 pt**; `WideDividerSplitViewController` widens the grab area. Autosave key `TerminusColumns.v2` — bump the version whenever the column set changes, or stale positions are applied to new columns.
- **Closing always asks** (tab, window, app); only a shell's own `exit` closes silently. Keep it that way — it was asked for.
- **`@Published` emits before the property changes.** In a Combine sink, use the emitted values; reading the object back gives the old value (bit twice: selection, and attach).
- **`tab.terminal` is the focused pane**, not "the tab's terminal". Anything about the whole tab (closing, its processes, busy checks) must go over `tab.terminals`, or it silently ignores the other panes of a split. Find a pane's tab with `tab(containing:)`.
- **Don't re-publish selection**: `TabStore.select` is a no-op for the selected tab; a selection change takes the keyboard for the terminal, which kills an in-place rename.
- **SwiftUI `Text("…\(number)")` localizes the number** (Turkish locale: `:54.631`, `+1.234`). Use `Text(verbatim:)` for counts, ports, pids.
- **Never `pkill -f <pattern>` in tests** — it once killed the shell running them. Kill the exact pids you found.
- **Typing text then running it**: `insertText` is a bracketed paste, so a trailing newline is literal. Use `pressReturn()`.
- Keep features built-in (Claude, Codex, the snippet starters); no plugin slots.
- **Tests are part of the change**: unit/integration in `Tests/TerminusTests` (tabs are real but surfaceless there — never `ghostty_init` in unit tests), and an E2E scenario in `E2ERunner` for anything a person would see; a bug found by hand gets a check. `make test && make e2e` before calling it done. docs/testing.md.
- **Isolated runs** (`TERMINUS_E2E`, `TERMINUS_DUMP_LAYOUT`) go through `AppEnvironment` for every piece of persistent state; new state must too, or tests will write into the user's real app.

## Commits

`area: what changed` subject (areas: `terminal`, `tabs`, `sidebar`, `diff`, `editor`, `git`, `agents`, `session`, `palette`, `snippets`, `window`, `keys`, `build`, `docs`…), body says why. One fix per commit. Author `bahattincinic@gmail.com`; no `Co-Authored-By` trailer. Run `swift format --in-place --recursive Sources Tests`, `make test` and `make e2e` before committing.
