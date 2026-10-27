# Testing

Two layers. Run both before calling a change done.

```sh
make test   # unit + integration: pure logic, real git in temp repos (~3 s)
make e2e    # end-to-end: every scenario in the real, built app (~15 s, opens windows)
```

Both must run **outside the Bash tool's sandbox** (they spawn git, FSEvents,
and for E2E the app itself).

## Unit / integration — `Tests/OvertermTests`

Pure logic and anything that can run without a window: parsers (worktree,
status, numstat, name-status, branch log, unified diff), `FileTreeModel`,
`DirectoryWatcher` (real FSEvents), `WorktreeModel`, `TaskCreator`,
`DiffModel` (real repos, incl. no HEAD yet, a commit in a linked worktree,
the branch scope, its base without origin/HEAD, when it has nothing to
compare with, and which cards start folded and stay so), `DiffHighlight`
(colours per hunk side, a line's changed part, which lines pair; one capped
file's cost), `EditorDocument`,
`SyntaxHighlighter`, snippets, palette ranking, session file, `TabActivity`,
`GhosttyInput`, `TabStore`/`Tab`, and `ClaudeEdits` — Claude Code's edits
and why it made them, from transcript lines in its shape (one content part
per line, results on later lines, a subagent's without `toolUseResult`),
written by `TranscriptFixture` into a scratch projects directory: never the
real `~/.claude`.

The version (`VersioningTests`, `AboutPanelTests`): `VERSION` is SemVer and
`CHANGELOG.md`'s top entry, the changelog newest first; About's credits;
`Scripts/bump-version.sh` run for real on a scratch copy (with `/bin/bash`,
macOS's 3.2 — each part's arithmetic, the entry on top, a second run adding
to the same version, bad input changing nothing); and the hooks in a scratch
repository whose `core.hooksPath` is this checkout's `.githooks` (an app change
without VERSION refused, with it or docs-only committed, the escape hatch,
`v<VERSION>` tagged once). Those runs get no global git config and no
`SKIP_VERSION_CHECK` from the caller.

Tabs are real: the unit-test process never calls `ghostty_init`, so
`GhosttyRuntime` has no app and every `TerminalView` is surfaceless — no
pty, same object. Don't initialize the runtime in unit tests.

Async models supersede older refreshes by design; wait for them to settle
(`eventually { … }`) rather than asserting right after one call.

### Database drivers

`DatabaseDriverTests` talks to real servers. SQLite runs always; PostgreSQL,
MySQL and ClickHouse need Docker:

```
Scripts/database-test-servers.sh            # PostgreSQL :55432, MySQL :53306, ClickHouse :58123
OVERTERM_DB_TESTS=1 swift test --filter DatabaseDriverTests
Scripts/database-test-servers.sh stop
```

Without `OVERTERM_DB_TESTS=1` those three are skipped, so `make test` and
CI need no Docker. BigQuery's signing and its answers are tested offline.

It also starts an SSH bastion (:52222, on a Docker network with
PostgreSQL) for `SSHTunnelTests` and the `databaseTunnel` scenario; both
keep the host key out of your `~/.ssh/known_hosts`.

The same script starts an S3 server (RustFS, :59000) for
`StorageClientTests` (`OVERTERM_DB_TESTS=1`) and the `storage` scenario,
which skips itself when nothing answers there.

### Docker

`DockerTransportTests` and the Docker scenarios talk to `FakeDockerEngine`
(`Sources/Overterm/Docker/`): Docker's Engine API on a unix socket of its
own in `/tmp` (a socket's path must stay under 104 bytes), with containers,
images, volumes and networks held as values, events sent as the engine
sends them, logs framed, files as tar. Nothing touches your Docker.

```
OVERTERM_DOCKER_TESTS=1 swift test --filter DockerTransportTests
```

adds read-only calls (`_ping`, `info`, the lists) to the engine your
terminal's `docker` reaches, to check that the models still read what it
answers.

## End-to-end — `Sources/Overterm/E2E/E2ERunner.swift` + `Tests/OvertermE2ETests`

`OVERTERM_E2E=<scenario> ./Overterm.app/Contents/MacOS/Overterm` runs one
scenario inside the app and prints `E2E PASS|FAIL <check>` lines, then
`E2E DONE <failures>`, exiting with the failure count. The XCTest target
launches one process per scenario (skipped unless `OVERTERM_E2E_TESTS=1`,
which `make e2e` sets) and turns FAIL lines into test failures.

What makes it end-to-end without being dangerous:

- **Input goes only to its own window**: key events are built with
  `NSEvent.keyEvent` and delivered with `window.sendEvent` (→ `TerminalView.keyDown`
  → `interpretKeyEvents` → libghostty → pty); drags are posted to the app's
  own queue. Never CGEvent/osascript — those reach whatever has focus.
- **Isolated state** (`AppEnvironment`): its own defaults suite (wiped at
  launch), a temp support dir (or `OVERTERM_SUPPORT_DIR` for a prepared
  session), notifications counted not posted, no split autosave, never
  activated (it stays behind your windows), and Claude Code's transcripts an
  empty projects directory of its own until a scenario points
  `ClaudeUsageReader.projectsDirectory` at the ones it wrote — never the
  real `~/.claude`.
- **Scratch files** in a temp dir removed at the end; repos are created with
  a throwaway git identity.

Scenarios: `terminal`, `tabs`, `rename`, `pin`, `close`, `editor`, `diff`,
`branchDiff`, `why`, `diffStyle`, `layout`, `session`, `task`, `snippets`, `attention`,
`marks`, `palette`, `reorder`, `info`, `claude`, `disk`, `clipboard`,
`openWith`, `dropFiles`, `peek`, `groups`, `blocks`, `inbox`, `askAgent`,
`dropSplit`, `settings`, `themes`, `browser` (the browser column, its tabs, a page's console,
and the MCP server over real HTTP as an agent would use it), `fileActions` (the file tree's New File…, Rename…,
Move to Trash…, through their sheets), `editorZed` (the editor as Zed's: zoom, tabs,
tree-sitter, editing commands, pickers, vim, and a language server —
`Tests/OvertermTests/Fixtures/fake-lsp.py`, through `LanguageServers.discoveryOverride`).
`terminal` also checks the bundle: its version is the `VERSION` next to
`Overterm.app` (the run's app is the checkout's), the build a positive
integer, the commit named — and that About Overterm shows them, opened
through its menu item, without bringing the app forward.
`marks` leaves one tab in each activity state; with `OVERTERM_DUMP_PNG=<png>`
it captures the window, for judging the look. Run one by hand while working
on it:

```sh
make app && OVERTERM_E2E=diff ./Overterm.app/Contents/MacOS/Overterm 2>/dev/null | grep ^E2E
```

### Typing into a shell

- **Wait for the shell.** `waitForPrompt()` waits for its first OSC 7 (shell
  integration, from the first prompt) — "no running command" is also true
  while it still reads its rc files. `settledPrompt()` adds 400 ms, and
  1.2 s after that first report: the first prompt keeps working (the theme's
  git status, deferred integration init) and keys typed then were lost.
- **Run commands with `run(_:until:)`** (or `runAndExpect`): it types, presses
  Return, and if the condition doesn't hold, sends Ctrl-C and types it once
  more. A prompt redraw can flush keys *mid-command* — once, 40 characters
  vanished from the middle and left zsh at `for>`; a plain retry then typed
  into the continuation prompt. Only for commands that are fine to run twice.
- **Keep typed lines short**: put code in a script and run the script.
- **`clipboard` is the scenario this hits most.** Ten runs at load 6 on
  2026-09-28: 7 clean; 2 lost the `python3 …` line entirely, retry
  included (the terminal showed only "Last login"), and every later check
  failed in a chain; 1 answered Deny in the sheet — the app completed the
  request — yet the reader had no reply after 35 s. With logging on
  (`confirmClipboard` → complete, each time) that one did not recur, so it
  is open: a lost reply, or the reader stuck restoring the tty. Rerun
  before suspecting the app; if it recurs, log what the reader receives.
- **Output on disk isn't output on screen.** A file the command wrote can
  exist before libghostty's IO thread has drawn the output; wait on
  `TerminalView.visibleText` before clicking at a screen position.
- Typing goes to the *selected* tab.

### GitHub without the network

The `pullRequest` scenario writes a stand-in `gh` (a Python script answering
`pr list`, `pr view` and the comments API from fixtures, logging what it is
asked to post) and points `GitHub.executableOverride` at it: the app's real
calls and parsing run, nothing reaches GitHub. New gh calls need a branch in
that script, or the scenario fails with "fake gh: unexpected".

### Other apps without launching them

Opening a file in another app goes through `ExternalOpener`, whose catalog in
an isolated run is `IsolatedApps`: the `openWith` scenario installs two
stand-in apps (bundle ids and names only) and checks what it *would* have
opened; `SystemApps.launched` stays 0. A new way of opening a file
elsewhere goes through the opener too, or a scenario driving it would launch
a real app.

### Drags without the system's drag

`dropFiles` calls a pane's own `NSDraggingDestination` methods (entered,
updated, exited; prepare, perform, conclude, ended) with `E2EDraggingInfo`,
whose pasteboard is a private, named one — never the drag pasteboard or the
clipboard. What runs in a pane is found by its processes, so Claude Code is a
stand-in: `exec -a claude cat > file`, argv[0] `claude` in the foreground,
which also records what the drop typed (Ctrl-D hands cat the line, no
newline). ⌥ comes from `TerminalView.dropModifierFlags`. A file promise is
kept only at the end of a real drag, which a run can't start:
`TerminalDrop.keepPromise` stands in for the source and writes the file
where asked. The sidebar's rows get in-process clicks at their position, and
their menu comes from `menu(for:)` without being shown.

### Clicks in the changes pane

In-process mouse events that land in the pane's SwiftUI `ScrollView` don't
reach its gestures (the run's window is never key): a card header's fold and
its why strip ignore them, and a mouseDown on a diff line (selectable text)
starts a tracking loop that waits for a real mouseUp — the run hangs. Its
accessibility tree is empty in-process too. Scenarios there call the model
action the gesture or button calls (`toggleWhy`, `toggleFold`, `expandAll`)
and check what a card is given (`DiffModel.why(for:)`, `isFolded`) and what a
line is given (`FileDiff.style(of:)`, in `diffStyle`), which the view renders
as it is.

### Adding a scenario

1. Add a method on `E2ERunner` and register it in `scenarios`.
2. Drive it through the same entry points the UI uses (menu `@objc`
   actions, `menu(for:)` items, `openInEditor`, `type`/`pressReturn`, sheet
   buttons via `clickSheetButton`) — not by setting model state directly,
   or the test skips the wiring it exists to cover.
3. Check outcomes a person would see: files written by the shell, tab
   order, first responder, sheet text, git log.
4. Add `func testX() throws { try run("x") }` to `E2ETests`.

Every user-visible feature gets a scenario; every bug found by hand gets a
check that would have caught it (the rename focus loss, the 0-wide editor,
closing without asking, the no-HEAD diff all have one).

## Looking at the UI

`OVERTERM_DUMP_LAYOUT` / `OVERTERM_DUMP_PNG` (docs/debugging.md) print the
view tree and capture the real window — use them when a check isn't enough
to see what's wrong.

### The title bar and full screen

`OVERTERM_E2E_ACTIVATE=1` brings an isolated run to the front for the
`fullScreen` scenario — full screen's title bar window only shows for the
app in front — and takes the keyboard for a few seconds, so ask first.
`OVERTERM_E2E_FULLSCREEN=1` runs `reorder` with the window full screen.
What macOS does itself with a real pointer — moving a window by its title
bar, the title bar coming down in full screen — no in-process event
reaches; the scenarios check what a press would hit from the frame view
down, and the rest is tried by hand (an Overterm Dev build, with its own
bundle id and `OVERTERM_SUPPORT_DIR`).
