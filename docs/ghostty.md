# Embedding libghostty

## Build

`Scripts/build-ghosttykit.sh` clones Ghostty at `GHOSTTY_REF`, refuses to build
if the tag no longer resolves to `GHOSTTY_SHA`, and runs

```
zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
```

producing `Frameworks/GhosttyKit.xcframework` (static lib + `ghostty.h` +
module map; ~135 MB, gitignored) and `Frameworks/GhosttyResources`
(`terminfo/`, `ghostty/` shell integration + themes), which `make-app.sh`
copies into `Contents/Resources`. libghostty finds its resources by climbing
from the executable to `Contents/Resources` with `terminfo/78/xterm-ghostty`
as the sentinel — so only a bundled app gets `TERM=xterm-ghostty` and shell
integration; a bare `.build/debug/Overterm` falls back to `xterm-256color`.

Pinned to **v1.3.1 / Zig 0.15.2** because Ghostty main needs Xcode 26 and the
macOS 26 SDK (this machine: Xcode 16.4). The pin is the macOS *app's*
requirement; the library builds with Xcode 16.

`Package.swift` links `c++` and the system frameworks libghostty's Zig code
uses (Carbon, CoreText, Metal, QuartzCore, IOSurface, UniformTypeIdentifiers).
The `libtool: duplicate member name 'ext.o'` warning and dsymutil's "could not
find symbol ImGui…" are harmless.

## Reference implementation

Ghostty's own macOS app is the reference for how libghostty wants to be fed —
`vendor/ghostty/macos/Sources/Ghostty/` after a build:

- `Surface View/SurfaceView_AppKit.swift` — key path (`performKeyEquivalent` →
  `keyDown` → `interpretKeyEvents` → `NSTextInputClient`), mouse, IME. Overterm
  ports it rather than simplifying it: translation mods, reusing the original
  NSEvent for Korean IME, the `lastPerformKeyEvent` round-trip for ⌘/⌃ keys.
- `Ghostty.App.swift` — runtime callbacks, action handling.
- `src/config/Config.zig` — default keybinds (search `.key = .{ .unicode`).

## Threads and isolation

- `ghostty_init` first (main.swift), then one `ghostty_app_t` (`GhosttyRuntime.shared`).
- `wakeup_cb` is called from **any thread** (the renderer's, typically) → hop
  to main and `ghostty_app_tick`. Every other callback runs inside a tick or a
  surface call, i.e. on main.
- Swift 6: the callback closures are built in a `nonisolated static` function.
  Written inside the `@MainActor` class they are inferred main-actor isolated,
  and Swift inserts an executor check that traps on the renderer thread (the
  app aborted on its first frame — `swift_task_isCurrentExecutorImpl` in
  thread `renderer`). Raw pointers crossing into `MainActor.assumeIsolated`
  are re-bound `nonisolated(unsafe)`.
- `ghostty_surface_new` gets the NSView (unretained) as `nsview` and
  `userdata`; libghostty installs its own Metal layer. Free the surface
  (`TerminalView.close()`) before the view goes away.

## Keybind collisions

A Ghostty binding is consumed in `performKeyEquivalent` before the menu sees
the key. If the action is then unhandled, the key does **nothing**. Checked
against v1.3.1 defaults:

| Key | Ghostty action | Overterm |
|---|---|---|
| ⌘T / ⌘W / ⌥⌘W | new_tab / close_surface / close_tab | handled → Overterm tabs |
| ⇧⌘W, ⌥⇧⌘W | close_window, close_all_windows | handled → window close |
| ⇧⌘P | toggle_command_palette | handled → Overterm palette |
| ⌘K | clear_screen | Ghostty's (so the palette is ⌘P) |
| ⌘N | new_window | unhandled (one window) |
| ⌘D, ⇧⌘D | new_split | unhandled (no splits yet) |
| ⌘P, ⌘B, ⌥⌘C/X/D, ⇧⌘N, ⌘S | — | free; Overterm menu items |

When adding a shortcut, grep `Config.zig` first. The user's own
`~/Library/Application Support/com.mitchellh.ghostty/config` (or
`~/.config/ghostty/config`) applies too.

## Clipboard

A paste libghostty flags (a line break no bracketed paste frames, or the
bracketed-paste end sequence inside it) and a program reading the clipboard
(OSC 52, under the default `clipboard-read = ask`) come to
`confirm_read_clipboard_cb`. `ClipboardConfirmation` says what to ask, and
the window asks in a sheet: for the selected tab only, one sheet at a time —
anything else is refused at once — and only a click hands anything over
(Return answers Deny, Esc answers Cancel). Both answers complete the request
*confirmed*, with the text or `""`: completed unconfirmed, libghostty asks
again at once, and Overterm once looped that way until the stack overflowed.
A write with `confirm = true` (`clipboard-write = ask`) is still dropped.

The macOS "selection clipboard" is a private named pasteboard. An isolated
run (E2E) gets a private standard clipboard too, so tests never touch the
user's.
