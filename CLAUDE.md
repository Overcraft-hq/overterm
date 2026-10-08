# Terminus

macOS terminal for agent-driven work — Swift/AppKit around libghostty
(`GhosttyKit`), built for several worktrees at once, each with an agent
(Claude Code, Codex) in it. Repository: `terminus-app/terminus` (private).

## Quick reference

```
mise trust && mise install   # pinned Zig (only needed to build GhosttyKit)
make ghosttykit              # Frameworks/GhosttyKit.xcframework + GhosttyResources (once; ~2 min)
make hooks                   # .githooks: VERSION bump check, v<VERSION> tags (once per clone)
make test                    # unit + integration tests (~3 s)
make e2e                     # end-to-end scenarios in the real app (~15 s, opens windows)
                             # both: run OUTSIDE the Bash sandbox — docs/testing.md
make app                     # Terminus.app in the repo
make install                 # …and copy it to /Applications, re-signed with
                             # $SIGN_IDENTITY (env or untracked local.mk) if set;
                             # a stable identity keeps privacy grants (mic)
make icon                    # Resources/AppIcon.svg → AppIcon.icns
make app dmg                 # dist/Terminus-<VERSION>.dmg; a release is the Release
                             # workflow, run by hand: VERSION's tag, its CHANGELOG
                             # entry as notes, the DMG attached
```

## Layout

| Path | What |
|---|---|
| `Sources/Terminus/Ghostty/` | libghostty embedding: `GhosttyRuntime` (app + C callbacks + actions), `TerminalView` (one surface: keys, IME, mouse, drops), `GhosttyInput`, `TerminalDrop` (what a drop types in) |
| `Sources/Terminus/Tabs/` | `Tab`, `TabStore` (order, selection, pin invariant), tab strip, `TabKind` (what a tab's icon says it is), `TabActivity` (needs-you flags), `AttentionChip` ("N need you"), `Agent`, tab context menu |
| `Sources/Terminus/Groups/` | tab groups: `TabGroup`/`TabStrip`, `TabStore+Groups` (the contiguous-run invariant), `GroupFocus` (holding other groups' notices), `BroadcastModel`, the island views, the ⌃⌘G switcher |
| `Sources/Terminus/Window/` | `TerminalWindowController` (owns everything below; layout; menu actions), `ChromeTheme` (the chrome's colour vocabulary), `CardColumn`/`GapSplitView` (the columns as cards on the window), `AttentionNotifier`, split controllers |
| `Sources/Terminus/Sidebar/` | Files / Worktrees / Snippets panels, `FileTreeModel`, `WorktreeModel`, `DirectoryWatcher` (FSEvents) |
| `Sources/Terminus/Diff/` | changes pane on the right + ± badge, `DiffModel` (live counts, per-file diffs, stage/commit) |
| `Sources/Terminus/Editor/` | editor pane beside the terminal, `EditorDocument`, gutter, `SyntaxHighlighter`; `ExternalOpener`/`OpenWith` (files in the app the user picked) |
| `Sources/Terminus/Git/` | `Git.run` (libdispatch-backed), porcelain / numstat / unified-diff parsers, `Worktree` |
| `Sources/Terminus/Tasks/` | New Task: worktree + branch + agent |
| `Sources/Terminus/Info/` | Tab Info (⌘I): processes, ports, Claude tokens, disk — see docs/architecture.md |
| `Sources/Terminus/Agents/` | ⇧⌘A agent overview: `AgentOverviewModel` (cards, ordering), view; `Info/ClaudeActivity` reads what a session is doing |
| `Sources/Terminus/GitHub/` | PRs and CI via `gh`: parsers (`PullRequest.swift`), the Pull Request pane (`PullRequestModel`/`View`) |
| `Sources/Terminus/Settings/` | ⌘, — a tab over settings.json + keybindings.json (VS Code's files): `SettingsSchema` (every setting), `Settings` (the store, Ghostty overrides), `SettingsJSON` (JSON5, edited in place), `Keybindings` (`KeyCombo`, `KeyCommands`, menus + Ghostty keybinds), `SettingsPage` (the tab), `Updates` |
| `Sources/Terminus/Peek/` | Tab Peek: `TabPeek` (pure card geometry and the layer transform), `TabPeekGesture` (the three-finger state machine), `TabPeekController`, the chrome over the hosts |
| `Sources/Terminus/Inbox/` | ⌘I: `AgentPrompt` (pure — reads an agent's question and its choices off the screen), `InboxModel`, `InboxView` |
| `Sources/Terminus/Blocks/` | what a pane has run: `CommandLedger` (pure — the title, `COMMAND_FINISHED` and the scrollbar assembled into commands), `ScrollMapView`, `BlockFrameView` |
| `Sources/Terminus/Splits/` | a tab's panes: `SplitTree` (pure layout logic), `SplitHostView` (frames, dividers, dim) and `PaneHeaderView` (every pane's 38 pt bar) |
| `Sources/Terminus/Search/` | ⌘F overlay: terminal + file names + contents (`SpotlightModel`, `CheckoutSearch`); the terminal half is `Ghostty/TerminalSearch` |
| `Sources/Terminus/Snippets/`, `Palette/`, `Session/` | snippets store + sheets, ⌘P palette, session save/restore |
| `Scripts/` | GhosttyKit build, app bundling (with the build metadata About shows), icon, `bump-version.sh` |
| `VERSION`, `CHANGELOG.md`, `.githooks/` | the app's version, what each version changed, the hooks that keep them in step (Commits) |

More: `docs/architecture.md`, `docs/ghostty.md`, `docs/testing.md`, `docs/debugging.md`.

## Rules

- **Never drive the UI with synthetic input** (osascript `keystroke`, System Events, CGEvent). It types into whatever has focus — once it typed into the user's own Claude Code prompt. To check layout or behaviour, use the in-app diagnostic mode (`TERMINUS_DUMP_LAYOUT`, docs/debugging.md), which only touches its own window, or ask the user.
- **libghostty C callbacks must be built in a `nonisolated` context** (`GhosttyRuntime.runtimeConfig()`). `wakeup_cb` comes from the renderer thread; a closure written inside a `@MainActor` type traps under Swift 6.
- **The same goes for Apple completion handlers** (UserNotifications, and any API that answers on its own queue): a closure written in a `@MainActor` type is main-actor-isolated, and Swift 6 traps when the system calls it elsewhere — `EXC_BREAKPOINT` in `dispatch_assert_queue`. It took the app down at an agent's notification (`AttentionNotifier.authorized`). Build such closures in a `nonisolated` function, or use the `async` variant.
- **Clipboard confirmations complete *confirmed*** — the text, or `""` to refuse (`ClipboardConfirmation.reply`). Completed unconfirmed, libghostty asks again at once: that looped until the stack overflowed, crashing the app on any OSC 52 read.
- **Git goes through `Git.run`** — a GCD thread per call, never a blocked Swift-concurrency thread (the cooperative pool starves; signalbox froze that way).
- **Ghostty is pinned to v1.3.1** (`Scripts/build-ghosttykit.sh`, SHA-checked) with Zig 0.15.2 (`mise.toml`): Ghostty main needs Xcode 26. Bump both together; check `ghostty.h` for API changes. A weekly workflow (`ghostty-release-check`, the repo's only one — macOS CI is too expensive) opens an issue with the steps when Ghostty tags a newer release.
- **Views don't clip by default since macOS 14.** A subview drawing past its bounds (the editor gutter did) paints over neighbours — set `clipsToBounds` where content is taller than the view.
- **The tab strip lives in the title bar**, which swallows right-clicks before SwiftUI sees them. Context menus there go through the window's local event monitor (`installTabRightClick`), not `.contextMenu`.
- **Split dividers are 1 pt**; `WideDividerSplitViewController` widens the grab area. Autosave key `TerminusColumns.v2` — bump the version whenever the column set changes, or stale positions are applied to new columns.
- **Closing always asks** by default (tab, window, app); only a shell's own `exit` closes silently. Keep "Always" the default — it was asked for. Settings ▸ General can make it "only when something is running" (`needsCloseConfirmation`); any new close path goes through that.
- **`@Published` emits before the property changes.** In a Combine sink, use the emitted values; reading the object back gives the old value (bit twice: selection, and attach). A new subscriber also gets the current value at once — `dropFirst()` when only a change should act (the find bar's rebinding on every terminal focus took the keyboard back, so Esc never closed it).
- **`tab.terminal` is the focused pane**, not "the tab's terminal". Anything about the whole tab (closing, its processes, busy checks) must go over `tab.terminals`, or it silently ignores the other panes of a split. Find a pane's tab with `tab(containing:)`.
- **Don't re-publish selection**: `TabStore.select` is a no-op for the selected tab; a selection change takes the keyboard for the terminal, which kills an in-place rename.
- **SwiftUI `Text("…\(number)")` localizes the number** (Turkish locale: `:54.631`, `+1.234`). Use `Text(verbatim:)` for counts, ports, pids.
- **No `lazy.compactMap(…).first` over live state** (process trees, files): on a collection it runs the transform twice for the element it returns and force-unwraps the second answer — an agent exiting in between crashed the app. Loop and read once (`firstAgent(in:tree:)`).
- **Never `pkill -f <pattern>` in tests** — it once killed the shell running them. Kill the exact pids you found.
- **Typing text then running it**: `insertText` is a bracketed paste, so a trailing newline is literal. Use `pressReturn()`.
- Keep features built-in (Claude, Codex, the snippet starters); no plugin slots.
- **Tests are part of the change**: unit/integration in `Tests/TerminusTests` (tabs are real but surfaceless there — never `ghostty_init` in unit tests), and an E2E scenario in `E2ERunner` for anything a person would see; a bug found by hand gets a check. `make test && make e2e` before calling it done. docs/testing.md.
- **A new setting is a `SettingsSchema` entry** (key, section, kind, default): the page, validation and search follow. A new shortcut is a `KeyCommands` entry — and, for a menu item, `MainMenu.command(…, id)`. Never read UserDefaults for a setting.
- **Isolated runs** (`TERMINUS_E2E`, `TERMINUS_DUMP_LAYOUT`) go through `AppEnvironment` for every piece of persistent state; new state must too, or tests will write into the user's real app.

## Commits

`area: what changed` subject (areas: `terminal`, `tabs`, `sidebar`, `diff`, `editor`, `git`, `agents`, `session`, `palette`, `snippets`, `window`, `keys`, `build`, `docs`…), body says why. One fix per commit. No `Co-Authored-By` trailer. Run `swift format --in-place --recursive Sources Tests`, `make test` and `make e2e` before committing.

**Versioning.** `VERSION` is the app's version (SemVer), `CHANGELOG.md` what each version changed; About Terminus shows it with the commit (docs/architecture.md, Build metadata).

- A commit that changes the app bumps VERSION in the same commit. "Changes the app": anything under `Sources/`, `Resources/` or `Scripts/`, or `Package.swift`, the `Makefile` or `mise.toml`.
- **MAJOR**: incompatible — a saved-state format older versions can't read (session.json, snippets.json…), or a removed feature or shortcut.
- **MINOR**: a new user-visible feature or capability.
- **PATCH**: a fix, performance work, polish, or an internal step of a larger feature.
- Docs- and tests-only commits don't bump.
- Bump with `Scripts/bump-version.sh major|minor|patch "<the commit's subject>"`: it sets VERSION and adds the line to CHANGELOG.md under the new version and today's date; commit both with the change. Run again before committing, it adds a line to the same entry — it counts from the committed VERSION, so it never bumps twice.
- `make hooks` (once per clone) turns on `.githooks`: pre-commit refuses an app change without VERSION (`SKIP_VERSION_CHECK=1` lets one through — e.g. amending a commit that bumped already: the check compares with HEAD), post-commit tags the commit `v<VERSION>`. Tags stay local; push them yourself (`git push origin v1.10.0`).
