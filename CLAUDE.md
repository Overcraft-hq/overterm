# Overterm

macOS terminal for agent-driven work — Swift/AppKit around libghostty
(`GhosttyKit`), built for several worktrees at once, each with an agent
(Claude Code, Codex) in it. Repository: `Overcraft-hq/overterm` (private).

## Quick reference

```
mise trust && mise install   # pinned Zig (only needed to build GhosttyKit)
make ghosttykit              # Frameworks/GhosttyKit.xcframework + GhosttyResources (once; ~2 min)
make treesitter              # Frameworks/TreeSitterKit.xcframework + the editor's queries (once; ~1 min)
make hooks                   # .githooks: VERSION bump check, v<VERSION> tags (once per clone)
make test                    # unit + integration tests (~3 s)
make e2e                     # end-to-end scenarios in the real app (~15 s, opens windows)
                             # both: run OUTSIDE the Bash sandbox — docs/testing.md
make app                     # Overterm.app in the repo
make install                 # …and copy it to /Applications, re-signed with
                             # $SIGN_IDENTITY (env or untracked local.mk) if set;
                             # a stable identity keeps privacy grants (mic)
make icon                    # Resources/AppIcon.png → AppIcon.icns
make themes                  # Resources/themes: the themes Ghostty v1.3.1
                             # doesn't ship (Scripts/fetch-themes.sh; checked in)
make app dmg                 # dist/Overterm-<VERSION>.dmg; a release is the Release
                             # workflow, run by hand: VERSION's tag, its CHANGELOG
                             # entry as notes, the DMG attached
```

## Layout

| Path | What |
|---|---|
| `Sources/Overterm/Ghostty/` | libghostty embedding: `GhosttyRuntime` (app + C callbacks + actions), `TerminalView` (one surface: keys, IME, mouse, drops), `GhosttyInput`, `TerminalDrop` (what a drop types in) |
| `Sources/Overterm/Tabs/` | `Tab`, `TabStore` (order, selection, pin invariant), tab strip, `TabKind` (what a tab's icon says it is), `TabActivity` (needs-you flags), `AttentionChip` ("N need you"), `Agent`, tab context menu |
| `Sources/Overterm/Groups/` | tab groups: `TabGroup`/`TabStrip`, `TabStore+Groups` (the contiguous-run invariant), `NewTabGroup` (which island a new tab joins), `GroupFocus` (holding other groups' notices), `BroadcastModel`, the island views, the ⌃⌘G switcher |
| `Sources/Overterm/Window/` | `TerminalWindowController` (owns everything below; layout; menu actions), `ChromeTheme` (the chrome's colour vocabulary), `CardColumn`/`GapSplitView` (the columns as cards on the window), `AttentionNotifier`, split controllers |
| `Sources/Overterm/Sidebar/` | Files / Overgit / Sessions / Snippets panels, `SidebarModel` (which one shows), `FileTreeModel`, `WorktreeModel`, `DirectoryWatcher` (FSEvents) |
| `Sources/Overterm/Diff/` | changes pane on the right + ± badge, `DiffModel` (live counts, per-file diffs, stage/commit) |
| `Sources/Overterm/Editor/` | the editor pane, Zed's way — docs/architecture.md, Editor: `EditorViewController` (+Editing, +Navigation, +Intelligence), `EditorBuffer` (one open file), `CodeTextView`, `EditorGutter`, `EditCommands` (pure), `Syntax/` (tree-sitter, Helix queries, One Dark), `LSP/` (language servers), `Vim/` (pure); `SyntaxHighlighter` is the changes pane's; `ExternalOpener`/`OpenWith` (files in the app the user picked) |
| `Sources/Overterm/Browser/` | the browser column (⇧⌘B) — docs/architecture.md, Browser: `BrowserWorkspace` (a terminal tab's pages), `BrowserSession` (one page: WKWebView, console, what an agent does), `BrowserViewController` (toolbar, tab strip, console), `BrowserLinks` (which links open here), `BrowserMCP` + `BrowserBridge` (the MCP server agents reach it by) |
| `Sources/Overterm/API/` | the API client (⌥⌘R) — docs/architecture.md, API client: `BruFile`/`BruRequest` (Bruno's format, written back byte for byte), `BrunoCollection`, `APIVariables` (layers, keychain secrets), `APIRequestPlan` (pure) + `APIClient` (URLSession), `APIScriptRuntime` (JavaScriptCore, Bruno's `bru`/`req`/`res`/`expect`), `APIExecution`, `APIWorkspace` (a window's), `APIRequestModel`/`View` (a `.bru` in the editor), `APIRunner`, the importers (`OpenAPIImporter`, `PostmanImporter`, `HTTPFileImporter`, `CurlParser`, `YAMLReader`), `APIDiscovery`, `APIMCP` |
| `Sources/Overterm/Notes/` | the notes vault (⌥⌘N) — docs/architecture.md, Notes: `NotesVault`/`NoteFiles` (Obsidian's folder, coordinated IO, iCloud placeholders), `NoteParser` (pure), `NotesIndex`/`LinkResolver` (Obsidian's link rules), `NotesModel` (the app's one vault), the panel, `NoteReaderView` (reading view; `Resources/notes`), `NoteLivePreview` (Live Preview as attributes), `NoteRename`, `NotesMCP`, `NotesGraph` |
| `Sources/Overterm/Database/` | the database client (⌥⌘B) — docs/architecture.md, Database: `DatabaseConnection`/`DatabaseStore` (connections.json, secrets in the keychain), `DatabaseDriver` and its six (PostgresNIO, MySQLNIO, libsqlite3, ClickHouse HTTP, BigQuery REST), `DatabaseModel`/`DatabaseSession`, the panel and form, `SQLConsole`/`SQLConsoleView` (a `.sql` file's console), `ResultGrid`, `SQLText`/`SQLCompletion`/`ResultExport` (pure) |
| `Sources/Overterm/Simulator/` | the iOS simulator in the browser's column, live and clickable — docs/architecture.md, Simulator: `SimulatorHost` (Xcode's private CoreSimulator/SimulatorKit, loaded at runtime), `SimulatorScreen` (the device's IOSurface), `SimulatorInput` (taps and keys), `SimulatorMirror` (live, else `simctl` screenshots), `SimulatorList`/`SimulatorControl` (simctl), `SimulatorViewController` |
| `Sources/Overterm/Git/` | `Git.run` (libdispatch-backed), porcelain / numstat / unified-diff parsers, `Worktree`; and what Overgit reads — `CommitLog`, `CommitGraph` (pure lane layout), `Refs`, `Stashes`, `CommitDetail` |
| `Sources/Overterm/Overgit/` | the git panel in the sidebar (⌥⌘G) — docs/architecture.md, Overgit: `OvergitModel` (lazy per section), `OvergitView`/`OvergitRows`, `GraphGutter`, `OvergitMark`, `CommitDetailModel`/`View` (the commit in the right-hand pane) |
| `Sources/Overterm/Tasks/` | New Task: worktree + branch + agent |
| `Sources/Overterm/Info/` | Tab Info (⌘I): processes, ports, Claude tokens, disk — see docs/architecture.md |
| `Sources/Overterm/Agents/` | ⇧⌘A agent overview: `AgentOverviewModel` (cards, ordering), view; `Info/ClaudeActivity` reads what a session is doing |
| `Sources/Overterm/GitHub/` | PRs and CI via `gh`: parsers (`PullRequest.swift`), the Pull Request pane (`PullRequestModel`/`View`) |
| `Sources/Overterm/Usage/` | what the agents have spent: `UsageTailScanner` (logs read backwards, bounded by the window), `ClaudeUsageSource` / `CodexUsageSource` (quota meters off the files each agent writes), `ModelPricing`, the pane and the strip's gauge |
| `Sources/Overterm/Themes/` | Settings ▸ Themes: `TerminalTheme` (a Ghostty theme file, parsed), `ThemeCatalog` (the bundled ones and the user's), `ThemePreview` (a theme drawn as a little window), the gallery |
| `Sources/Overterm/Settings/` | ⌘, — a tab over settings.json + keybindings.json (VS Code's files): `SettingsSchema` (every setting), `Settings` (the store, Ghostty overrides), `SettingsJSON` (JSON5, edited in place), `Keybindings` (`KeyCombo`, `KeyCommands`, menus + Ghostty keybinds), `SettingsPage` (the tab), `Updates` |
| `Sources/Overterm/Peek/` | Tab Peek: `TabPeek` (pure card geometry and the layer transform), `TabPeekGesture` (the three-finger state machine), `TabPeekController`, the chrome over the hosts |
| `Sources/Overterm/AskAgent/` | ⌘L: the strip over a selection, and the sheet that hands it to an agent with the command it came from |
| `Sources/Overterm/Inbox/` | ⌘I: `AgentPrompt` (pure — reads an agent's question and its choices off the screen), `InboxModel`, `InboxView` |
| `Sources/Overterm/Blocks/` | what a pane has run: `CommandLedger` (pure — the title, `COMMAND_FINISHED` and the scrollbar assembled into commands), `ScrollMapView`, `BlockFrameView` |
| `Sources/Overterm/Splits/` | a tab's panes: `SplitTree` (pure layout logic), `SplitHostView` (frames, dividers, dim) and `PaneHeaderView` (every pane's 38 pt bar) |
| `Sources/Overterm/Search/` | ⌘F overlay: terminal + file names + contents (`SpotlightModel`, `CheckoutSearch`); the terminal half is `Ghostty/TerminalSearch` |
| `Sources/Overterm/Snippets/`, `Palette/`, `Session/` | snippets store + sheets, ⌘K palette (`CommandHistory`: what this machine has run), session save/restore |
| `Scripts/` | GhosttyKit build, app bundling (with the build metadata About shows), icon, `bump-version.sh` |
| `VERSION`, `CHANGELOG.md`, `.githooks/` | the app's version, what each version changed, the hooks that keep them in step (Commits) |

More: `docs/architecture.md`, `docs/ghostty.md`, `docs/testing.md`, `docs/debugging.md`.

## Rules

- **Never drive the UI with synthetic input** (osascript `keystroke`, System Events, CGEvent). It types into whatever has focus — once it typed into the user's own Claude Code prompt. To check layout or behaviour, use the in-app diagnostic mode (`OVERTERM_DUMP_LAYOUT`, docs/debugging.md), which only touches its own window, or ask the user.
- **libghostty C callbacks must be built in a `nonisolated` context** (`GhosttyRuntime.runtimeConfig()`). `wakeup_cb` comes from the renderer thread; a closure written inside a `@MainActor` type traps under Swift 6.
- **The same goes for Apple completion handlers** (UserNotifications, and any API that answers on its own queue): a closure written in a `@MainActor` type is main-actor-isolated, and Swift 6 traps when the system calls it elsewhere — `EXC_BREAKPOINT` in `dispatch_assert_queue`. It took the app down at an agent's notification (`AttentionNotifier.authorized`). Build such closures in a `nonisolated` function, or use the `async` variant.
- **Clipboard confirmations complete *confirmed*** — the text, or `""` to refuse (`ClipboardConfirmation.reply`). Completed unconfirmed, libghostty asks again at once: that looped until the stack overflowed, crashing the app on any OSC 52 read.
- **A block for a queue is spelled `@Sendable () -> Void`.** Left to inference, the block `Git.run` gave `OperationQueue.addOperation` was typed `@MainActor` (its mangled name ends `ScMYc`); Swift's lenient check let it run on the Git queue until WebKit was loaded, then every git call trapped in `dispatch_assert_queue`. `nm … | swift-demangle | grep MainActor` shows such closures.
- **Ghostty's crash handler (Sentry/Breakpad) swallows crashes**: the app exits with the signal's number (6) and macOS writes no report — the report is in `~/.local/state/ghostty/crash/`. Run with `XDG_CACHE_HOME` pointing at a plain file to switch it off and get macOS's symbolicated `.ips`.
- **Git goes through `Git.run`** — a GCD thread per call, never a blocked Swift-concurrency thread (the cooperative pool starves; signalbox froze that way).
- **Tree-sitter and the grammars are pinned as a set with Helix's queries** (`Scripts/build-treesitter.sh`): each grammar at the revision that Helix release pins. Later query patterns win (Helix 25.07+). A query that doesn't compile leaves its language plain — `SyntaxDocumentTests` compiles every one.
- **Never walk up directories comparing paths with "/"**: `/`'s `deletingLastPathComponent` is `/../`, so the loop never ends — one took 51 GB and the machine down. Stop on `pathComponents.count <= 1`, and bound the loop.
- **Ghostty is pinned to v1.3.1** (`Scripts/build-ghosttykit.sh`, SHA-checked) with Zig 0.15.2 (`mise.toml`): Ghostty main needs Xcode 26. Bump both together; check `ghostty.h` for API changes. A weekly workflow (`ghostty-release-check`) opens an issue with the steps when Ghostty tags a newer release.
- **Views don't clip by default since macOS 14.** A subview drawing past its bounds paints over neighbours — the editor gutter did, and the editor's status bar filling its whole dirty rect blanked the pane above it. Set `clipsToBounds` where content may be taller than the view, and fill `dirtyRect.intersection(bounds)`.
- **The tab strip lives in the title bar**, which swallows right-clicks before SwiftUI sees them. Context menus there go through the window's local event monitor (`installTabRightClick`), not `.contextMenu`.
- **The window's split dividers measure nothing**; the 10 pt gap between the cards belongs to the cards (`CardColumn.gap`), because a divider is measured even for a collapsed item — as a 10 pt one, it left 30 pt dead down the right of the window. `WideDividerSplitViewController` widens the divider to a grab band over the gap. Autosave key `OvertermColumns.v4` — bump the version whenever the column set changes, or stale positions are applied to new columns.
- **The right of the window is one slot** (`RightSlot`): the browser column (and the simulator in it) or the pane the changes, the pull request and the usage share — never both. Open together they left every column too narrow to work in, the browser squeezed into the middle. Opening one takes the slot and remembers what it took it from; closing it gives the slot back. A new right-hand pane joins the slot, it does not add a column.
- **The strip's empty space must move the window and zoom it** (`TabStripHostingView.hitTest`): it is the title bar. It has been lost three times, twice silently — a view with `mouseDownCanMoveWindow` drags the window but AppKit never zooms for a background drag, so a check that only asks "is something draggable under there" passes while double-clicking does nothing. Whatever answers for that space is handed to `WindowDragView`, and the `layout` scenario checks the view that answers, in three places.
- **A sidebar panel reads nothing while it is not the panel on screen.** Overgit runs git; four of five times the sidebar is on something else, and a panel that reads anyway pays for every tab switch in every window. `SidebarModel` holds which panel is showing so the window can say when (`updateOvergitVisibility`), and `OvergitModel` reads only the sections that are open — `@AppStorage` inside the view could not tell anybody. What a panel can get from a model the window already has (`WorktreeModel`'s pull requests, `DiffModel`'s counts) it must not ask git or `gh` for a second time.
- **The API client's files are Bruno's.** A collection is `bruno.json` and `.bru` files committed with the code; Overterm keeps nothing of its own on disk for it (secrets go to the keychain), and never rewrites a block it didn't change — `BruFile` round-trips byte for byte, which `BruFileTests` checks. A request in the editor is an edit to the buffer's text (`replaceText`), never a parallel model saved some other way.
- **Closing always asks** by default (tab, window, app); only a shell's own `exit` closes silently. Keep "Always" the default — it was asked for. Settings ▸ General can make it "only when something is running" (`needsCloseConfirmation`); any new close path goes through that.
- **`ChromeTheme` is one object per window, and the views observe it**: a
  theme picked in Settings ▸ Themes recomputes it in place and the chrome
  follows without a relaunch (`applyTerminalColors` repaints the layers
  nobody binds — the window, the cards, the pane dividers). It says nothing
  when the two colours it derives from are unchanged: the config is reloaded
  for reasons that have nothing to do with colour, and redrawing every
  SwiftUI root for nothing took the keyboard off the terminal (every
  scenario that types broke).
- **`@Published` emits before the property changes.** In a Combine sink, use the emitted values; reading the object back gives the old value (bit twice: selection, and attach). A new subscriber also gets the current value at once — `dropFirst()` when only a change should act (the find bar's rebinding on every terminal focus took the keyboard back, so Esc never closed it).
- **A new tab never inherits the selected tab's island.** Which group it joins is `NewTabGroup.placement` and nothing else decides (docs/architecture.md, Tab groups): a group is usually a checkout, so it soon holds every tab, and inheriting it swallowed every new tab silently. A new way of opening a tab goes through `addTab`, which asks the rule.
- **`tab.terminal` is the focused pane**, not "the tab's terminal". Anything about the whole tab (closing, its processes, busy checks) must go over `tab.terminals`, or it silently ignores the other panes of a split. Find a pane's tab with `tab(containing:)`.
- **Don't re-publish selection**: `TabStore.select` is a no-op for the selected tab; a selection change takes the keyboard for the terminal, which kills an in-place rename.
- **SwiftUI `Text("…\(number)")` localizes the number** (Turkish locale: `:54.631`, `+1.234`). Use `Text(verbatim:)` for counts, ports, pids.
- **No `lazy.compactMap(…).first` over live state** (process trees, files): on a collection it runs the transform twice for the element it returns and force-unwraps the second answer — an agent exiting in between crashed the app. Loop and read once (`firstAgent(in:tree:)`).
- **Never `pkill -f <pattern>` in tests** — it once killed the shell running them. Kill the exact pids you found.
- **Typing text then running it**: `insertText` is a bracketed paste, so a trailing newline is literal. Use `pressReturn()`.
- **A vault is Obsidian's folder, not ours**: `.obsidian/` is read, never written; nothing of Overterm's is kept in the vault; every read and write goes through `NoteFiles` (NSFileCoordinator — iCloud and Obsidian write the same files). A link means what `LinkResolver` says, which is what Obsidian says; a rename writes again only the links it would break (`NoteRename`).
- **Live Preview never inserts text**: the note's text is the file, styled with attributes. Hidden markup is the `.noteHidden` attribute (laid out as nothing by `EditorLineHeight`), not a list of ranges — attributes move with edits, ranges don't.
- **The reading view loads only `overterm-note:`** (the app's `Resources/notes`, the vault) and shows a note's HTML through DOMPurify — the page talks back to the app. DOMPurify drops attribute values containing `-->`: never carry a note's content in an attribute (mermaid's source broke that way). The bundled scripts are pinned and SHA-checked in `Scripts/fetch-notes-web.sh`; change a version there.
- **A database secret is never written to disk**: a password or a service account key goes to the keychain (`DatabaseSecrets`, keyed by the connection's id) and nowhere else — not `connections.json`, not a log, not the history. `DatabaseStoreTests` checks the file never holds one.
- **A driver gives values as text** (`QueryResult`), whatever their type: the grid, the exports and completion read one shape. PostgresNIO answers binary even for a simple query — a new type goes through `PostgresText`, said as psql would. Drivers are tested against real servers (`Scripts/database-test-servers.sh`, `OVERTERM_DB_TESTS=1`), not mocks.
- Keep features built-in (Claude, Codex); no plugin slots.
- **Tests are part of the change**: unit/integration in `Tests/OvertermTests` (tabs are real but surfaceless there — never `ghostty_init` in unit tests), and an E2E scenario in `E2ERunner` for anything a person would see; a bug found by hand gets a check. `make test && make e2e` before calling it done. docs/testing.md.
- **Nobody is asked about usage over the network.** Both agents write their
  own quota to disk — Claude caches the API's answer in `~/.claude.json`,
  Codex puts the server's `rate_limits` in every rollout's `token_count` —
  and the money is their logs at list prices, labelled an estimate. Those
  numbers go stale (eight hours is normal) and a window whose `resets_at`
  has passed says nothing about the one running now: show the age, show
  "rolled over", never a stale percentage as if it were current.
- **Agent logs are read backwards** (`UsageTailScanner`): 643 MB of
  transcripts, most of it written today, so a day costs 0.1 MB a file this
  way and everything forwards. Only a line that carries usage may stop the
  walk — attachments are written out of order by hours.
- **A theme is a file, not code**: Ghostty resolves `theme = "<name>"` in
  `Contents/Resources/ghostty/themes` (its own 463, plus `Resources/themes`
  beside them) and `~/.config/ghostty/themes`. Settings ▸ Themes reads the
  same files to draw each one — adding a theme is `Scripts/fetch-themes.sh`,
  never a palette in Swift. `appearance.theme` keeps its key under the new
  page: it is in people's settings.json.
- **A new setting is a `SettingsSchema` entry** (key, section, kind, default): the page, validation and search follow. A new shortcut is a `KeyCommands` entry — and, for a menu item, `MainMenu.command(…, id)`. Never read UserDefaults for a setting.
- **Isolated runs** (`OVERTERM_E2E`, `OVERTERM_DUMP_LAYOUT`) go through `AppEnvironment` for every piece of persistent state; new state must too, or tests will write into the user's real app.

## Commits

`area: what changed` subject (areas: `terminal`, `tabs`, `sidebar`, `diff`, `editor`, `git`, `agents`, `session`, `palette`, `snippets`, `window`, `keys`, `build`, `docs`…), body says why. One fix per commit. No `Co-Authored-By` trailer. Run `swift format --in-place --recursive Sources Tests`, `make test` and `make e2e` before committing. CI (`.github/workflows/ci.yml`) runs the lint, the unit tests and the bundle on every pull request and push to main, with the release's Xcode 16.4 (Swift 6.1); E2E stays local.

**Versioning.** `VERSION` is the app's version (SemVer), `CHANGELOG.md` what each version changed; About Overterm shows it with the commit (docs/architecture.md, Build metadata).

- A commit that changes the app bumps VERSION in the same commit. "Changes the app": anything under `Sources/`, `Resources/` or `Scripts/`, or `Package.swift`, the `Makefile` or `mise.toml`.
- **MAJOR**: incompatible — a saved-state format older versions can't read (session.json, snippets.json…), or a removed feature or shortcut.
- **MINOR**: a new user-visible feature or capability.
- **PATCH**: a fix, performance work, polish, or an internal step of a larger feature.
- Docs- and tests-only commits don't bump.
- Bump with `Scripts/bump-version.sh major|minor|patch "<the commit's subject>"`: it sets VERSION and adds the line to CHANGELOG.md under the new version and today's date; commit both with the change. Run again before committing, it adds a line to the same entry — it counts from the committed VERSION, so it never bumps twice.
- `make hooks` (once per clone) turns on `.githooks`: pre-commit refuses an app change without VERSION (`SKIP_VERSION_CHECK=1` lets one through — e.g. amending a commit that bumped already: the check compares with HEAD), post-commit tags the commit `v<VERSION>`. Tags stay local; push them yourself (`git push origin v1.10.0`).
