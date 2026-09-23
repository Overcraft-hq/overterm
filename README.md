# Terminus

> Your terminal for the rails.

A native macOS terminal built around how PromptRails work actually happens:
several worktrees at once, each with an agent (Claude Code, Codex) running in it.

- **Terminal**: [libghostty](https://github.com/ghostty-org/ghostty) via `GhosttyKit`,
  embedded in a Swift/AppKit app. We do not write a terminal emulator.
- **Tabs** (planned): Chrome-style — pin, colour, rename, reorder.
- **Worktrees** (planned): a tab is a worktree + its session; "New task" creates both.
- **Diff panel** (planned): live diff of the active tab's worktree.
- **Sidebar** (planned): file tree, worktrees, snippets — collapsible.

Private, internal tool. Not a product, so no `*rails` name.

## Build

Requirements: macOS 13+, Xcode 16 (the Metal toolchain it ships), [mise](https://mise.jdx.dev).

```sh
mise trust && mise install   # pinned Zig
make ghosttykit     # build Frameworks/GhosttyKit.xcframework from the pinned Ghostty
make run            # build Terminus.app and open it
```

`make ghosttykit` is only needed once, and again after bumping the Ghostty pin.
