# Testing

Two layers. Run both before calling a change done.

```sh
make test   # unit + integration: pure logic, real git in temp repos (~3 s)
make e2e    # end-to-end: every scenario in the real, built app (~15 s, opens windows)
```

Both must run **outside the Bash tool's sandbox** (they spawn git, FSEvents,
and for E2E the app itself).

## Unit / integration — `Tests/TerminusTests`

Pure logic and anything that can run without a window: parsers (worktree,
status, numstat, name-status, branch log, unified diff), `FileTreeModel`,
`DirectoryWatcher` (real FSEvents), `WorktreeModel`, `TaskCreator`,
`DiffModel` (real repos, incl. no HEAD yet, a commit in a linked worktree,
the branch scope, its base without origin/HEAD, and when it has nothing to
compare with), `EditorDocument`,
`SyntaxHighlighter`, snippets, palette ranking, session file, `TabActivity`,
`GhosttyInput`, `TabStore`/`Tab`, and `ClaudeEdits` — Claude Code's edits
and why it made them, from transcript lines in its shape (one content part
per line, results on later lines, a subagent's without `toolUseResult`),
written by `TranscriptFixture` into a scratch projects directory: never the
real `~/.claude`.

Tabs are real: the unit-test process never calls `ghostty_init`, so
`GhosttyRuntime` has no app and every `TerminalView` is surfaceless — no
pty, same object. Don't initialize the runtime in unit tests.

Async models supersede older refreshes by design; wait for them to settle
(`eventually { … }`) rather than asserting right after one call.

## End-to-end — `Sources/Terminus/E2E/E2ERunner.swift` + `Tests/TerminusE2ETests`

`TERMINUS_E2E=<scenario> ./Terminus.app/Contents/MacOS/Terminus` runs one
scenario inside the app and prints `E2E PASS|FAIL <check>` lines, then
`E2E DONE <failures>`, exiting with the failure count. The XCTest target
launches one process per scenario (skipped unless `TERMINUS_E2E_TESTS=1`,
which `make e2e` sets) and turns FAIL lines into test failures.

What makes it end-to-end without being dangerous:

- **Input goes only to its own window**: key events are built with
  `NSEvent.keyEvent` and delivered with `window.sendEvent` (→ `TerminalView.keyDown`
  → `interpretKeyEvents` → libghostty → pty); drags are posted to the app's
  own queue. Never CGEvent/osascript — those reach whatever has focus.
- **Isolated state** (`AppEnvironment`): its own defaults suite (wiped at
  launch), a temp support dir (or `TERMINUS_SUPPORT_DIR` for a prepared
  session), notifications counted not posted, no split autosave, never
  activated (it stays behind your windows).
- **Scratch files** in a temp dir removed at the end; repos are created with
  a throwaway git identity.

Scenarios: `terminal`, `tabs`, `rename`, `pin`, `close`, `editor`, `diff`,
`branchDiff`, `layout`, `session`, `task`, `snippets`, `attention`, `marks`,
`palette`, `reorder`, `info`, `claude`, `disk`, `clipboard`, `openWith`,
`dropFiles`.
`marks` leaves one tab in each activity state; with `TERMINUS_DUMP_PNG=<png>`
it captures the window, for judging the look. Run one by hand while working
on it:

```sh
make app && TERMINUS_E2E=diff ./Terminus.app/Contents/MacOS/Terminus 2>/dev/null | grep ^E2E
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

`TERMINUS_DUMP_LAYOUT` / `TERMINUS_DUMP_PNG` (docs/debugging.md) print the
view tree and capture the real window — use them when a check isn't enough
to see what's wrong.
