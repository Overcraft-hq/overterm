# Debugging

## Look at the UI without touching the screen

Don't script clicks or keystrokes (osascript, System Events, CGEvent): they go
to whatever has focus, which may be the user's own terminal. Use the built-in
diagnostic mode instead — it only acts on its own window:

```sh
make app
TERMINUS_DUMP_LAYOUT=$PWD/README.md \
TERMINUS_DUMP_PNG=/tmp/terminus.png \
  ./Terminus.app/Contents/MacOS/Terminus
```

It starts a fresh window (no session restore, no autosave, divider positions
neither restored nor saved), opens the file in the editor after 1 s, and after
another 1.5 s:

1. prints the view tree with frames (and `HIDDEN`) plus each outer split
   item's width to stderr;
2. with `TERMINUS_DUMP_PNG`, writes a capture of the **composited window**
   (`CGWindowListCreateImage` of its own window — no Screen Recording
   permission needed). `cacheDisplay(in:to:)` is useless here: it misses
   layer-backed content (the editor text, AppKit headers) and draws a fake
   white strip;
3. drags both split dividers 80 pt with in-process mouse events (posted to
   its own queue) 3 pt off the drawn line, and prints widths before/after;
4. exits.

Run it from the **bundle** (`Terminus.app/Contents/MacOS/Terminus`): a bare
`.build/debug/Terminus` crashes in `UNUserNotificationCenter` ("bundleProxy
ForCurrentProcess is nil") and lacks terminfo/shell integration.

Extend `dumpLayoutIfRequested()` in `TerminalWindowController` when a new
layout question comes up, rather than asking the user for screenshots first.

## Crashes

- Exit status 6 with no output = abort (often a Swift isolation trap). Get a
  backtrace:
  ```sh
  printf 'process launch\nthread backtrace all\nkill\n' > /tmp/lldb.cmds
  lldb -b -s /tmp/lldb.cmds .build/debug/Terminus
  ```
  (needs to run outside the Bash tool's sandbox).
- libghostty's embedded crash reporter writes
  `~/.local/state/ghostty/crash/*.ghosttycrash` (~800 KB each, local only).
  Clear them after a crash-debugging session.

## Logs

```sh
log stream --level debug --predicate 'subsystem == "ai.promptrails.terminus" OR subsystem == "com.mitchellh.ghostty"'
```

libghostty logs config diagnostics, the resources dir it found ("ghostty
terminfo not found" = not running from a bundle), shell integration, renderer.

## Tests

```sh
make test          # = swift test
```

Must run **outside the Bash tool's sandbox**: tests spawn git (`Process`) and
FSEvents, and the sandboxed run dies with signal 11. They create temp repos and
clean up. Async models (`DiffModel`) supersede older refreshes by design —
tests wait for the model to settle (`eventually { … }`) instead of asserting
right after one call.

A past bug the suite caught: `DirectoryWatcher` freed without stopping its
FSEvents stream → the next event called into freed memory. Watchers now stop
in `deinit`.

## State on disk

| Reset | How |
|---|---|
| Tabs | delete `~/Library/Application Support/Terminus/session.json` |
| Snippets | delete `…/Terminus/snippets.json` (starters come back) |
| Divider positions | `defaults delete ai.promptrails.terminus "NSSplitView Subview Frames TerminusColumns"` (or `…TerminusDiff`) |
| Panels shown | `defaults delete ai.promptrails.terminus sidebarVisible` / `diffVisible` / `sidebarPanel` |

## Things that looked like bugs elsewhere

| Symptom | Cause |
|---|---|
| Right-click on a tab does nothing | Title bar eats right-clicks; handled by the window's event monitor, not SwiftUI `.contextMenu`. |
| Divider "can't be dragged" | 1 pt hit area; `WideDividerSplitViewController`. Also check a stale autosave with a different column count. |
| A pane shows only line numbers | Text container of width 0; or the text view autoresizing with the clip view (scrolled into the middle). |
| Something paints over a neighbour | macOS 14+ views don't clip; `clipsToBounds = true`. |
| Snippet "Run" doesn't run | Bracketed paste: newline is literal → `pressReturn()`. |
| A key does nothing | A Ghostty default binding consumed it and the action is unhandled — see docs/ghostty.md. |
| `git check-ignore -z` fails | `-z` only works with `--stdin`; parse lines. |
| App not in Launchpad | `make install` (the build lands in the repo). |
