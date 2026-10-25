# Architecture

One process, one window (for now), everything on the main thread except
libghostty's own threads and git calls.

## Window layout

```
┌─ tab strip (SwiftUI, in the title bar) ──── 3 need you ─ ± +N −M ─┐
│  ╭──────────╮ ╭──────────────────────────╮ ╭─────────╮ ╭────────╮ │
│  │ sidebar  │ │ pane header  ⊞ ⊟ ⤢ ✕     │ │ editor  │ │ right  │ │
│  │ Files /  │ ├──────────────────────────┤ │ pane    │ │ pane   │ │
│  │ Overgit /│ │ terminal container       │ │(opens on│ │(changes│ │
│  │Sessions /│ │ (every tab's SplitHostView;│ a file │ │ PR,    │ │
│  │ Snippets │ │  only the selected one   │ │  click) │ │ usage, │ │
│  │ (⌘B)     │ │  visible)                │ │         │ │ commit)│ │
│  ╰──────────╯ ╰──────────────────────────╯ ╰─────────╯ ╰────────╯ │
└───────────────────────────────────────────────────────────────────┘
      + ⌘K palette: an overlay over the whole content view
      + ⌘F search: an overlay over the terminal container; a compact find
        bar in its top-right corner while a terminal search is kept
      + Tab Peek (⇧⌘E, three fingers down): every tab's host scaled into a
        card inside the terminal container, chrome drawn over them
```

- Each column is a **card** (`CardColumn`): rounded 10 pt, hairlined, clipping its content, and on a light ground casting a shadow. What shows between two cards is the window's own colour (`ChromeTheme.win`), and **each card keeps half the 10 pt gap on each side** (`CardColumn.gap`). The split view's divider measures and draws nothing (`GapSplitView`), and `WideDividerSplitViewController` widens it to a 10 pt grab band over that gap, so the columns can still be dragged.

  The gap was the divider first — one number, and a grab area for free — but **a divider is measured even for a collapsed item**: with the editor, the changes pane and the inbox all shut, 30 pt of window went dead down the right-hand side, and a shut column *between* two open ones doubled the gap there. A card's own margin is only spent when the card is on screen. The `layout` E2E scenario measures both.
- A card's top reaches into the title bar, which is taller than the strip. So it refuses to drag the window and zeroes the safe-area inset SwiftUI would otherwise add, and is otherwise transparent to what it wraps — flipped, and it hands on a context menu it does not have.
- One split (`split`, vertical, autosave `OvertermColumns.v5`): sidebar | terminal | editor | browser | inbox | right pane. Bump the key's version whenever a column's width means something new, or stale positions get applied.
- **The right of the window is one slot** (`RightSlot`, `TerminalWindowController+Browser`): the browser column (the simulator with it) and the pane the changes, the pull request and the usage share. Opening one takes the slot from the other and remembers it (`displacedSlot`); closing it gives the slot back. Open together, the browser sat between the terminal and the pane with all four columns too narrow to work in. A pane that only stepped aside is not a choice to close it — `setRightPaneShown(_:remember:)` writes the "changes pane is open" default for your own ⌥⌘D, not for the browser's.
- **The strip's empty space is the drag area, whatever is over it** (`TabStripHostingView.hitTest`). It is the title bar: it has to move the window, and zoom it when double-clicked. The tabs scroll, and the scroll view's clip view answered for the space beside them — `mouseDownCanMoveWindow` moves the window, but AppKit zooms no window for a background drag, so double-clicking the title bar quietly stopped zooming. Such an answer is handed to `WindowDragView`, which does both. The `layout` scenario checks the view that answers, in three places along the strip, and that that view zooms: "something draggable is under there" passed through the whole regression.
- The **tab strip is 52 pt** (`TabStripHostingView.height`). The unified toolbar's title bar measures 66, but AppKit centres the traffic lights in the top 52 — so the strip is that row and the tabs line up with the lights; the 14 pt below is title bar the cards take.
- Every terminal pane carries a **38 pt header** (`PaneHeaderView`): what is running there, its island, its status, its ports, and split / split / zoom / close. The terminal gives up the room, not the pane's share of the tab. The host frames it; the window supplies it (`SplitHostView.makeHeader`), because what goes in it needs the tab and the window's actions.
- Colours come from `ChromeTheme`, one object per window built from libghostty's background and foreground and held by every SwiftUI root. Three grounds a step apart — `win` (between the cards), `card` (a panel), `term` (the terminal) — then text in three weights, fills, and the status colours. A theme picked in Settings ▸ Themes reloads the config, and `TerminalWindowController.applyTerminalColors` recomputes the object: the views observe it, and the layers nobody binds (the window's background, the cards' fills, the pane dividers) are repainted by hand.
- **The sidebar's panels are a rail down its left edge** (`SidebarRail`, 44 pt): Files, Overgit, Sessions and Snippets, the open one marked by a bar on the edge the way VS Code's activity bar marks it, and Settings and Hide Sidebar at its foot. They were a row of icons across the top, which cost the panel a band of its height and read as part of whichever panel was open; the foot is somewhere for what belongs to no panel. The rail is chrome of a fixed width at every sidebar width, so the **column's minimum is the rail plus a panel that can still be read** (`SidebarRail.minimumSidebarWidth` = 44 + 176), not the old panel minimum with the rail taken out of it — that truncated every file name at the narrowest width. The `layout` scenario checks it.
- Sidebar, diff panel, tab strip, pane headers, palette: SwiftUI in `NSHostingView`/`NSHostingController`. Terminal, editor text, editor header: AppKit.

## Ownership

`AppDelegate` → one `TerminalWindowController`, which owns:

| Object | Role |
|---|---|
| `TabStore` | ordered `Tab`s, selection, pinned-first invariant, drag reorder |
| `Tab` | a `TerminalView` + title, custom name, colour, pin, agent, cwd, `TabActivity` |
| `FileTreeModel` | tree of the selected tab's checkout; lazy listings, FSEvents invalidation, gitignore dimming |
| `WorktreeModel` | `git worktree list` of that repository |
| `DiffModel` | that checkout's changes — uncommitted, or everything on its branch (see Changes pane) — counts (always live — the ± badge), per-file diffs and why each file changed (only while the pane is open), stage/discard/commit; works before the first commit (empty-tree base) |
| `SnippetStore` | `~/Library/Application Support/Overterm/snippets.json` |
| `PaletteModel` | ⌘K query and ranking |
| `SpotlightModel` | ⌘F: one query over the selected terminal's scrollback, the checkout's file names and their contents |
| `EditorViewController` + `EditorDocument` | the file open in the editor pane |

"That checkout" is `Tab.checkoutSource`, in order: an **attached** checkout
(Worktrees → Attach to This Tab), else where the tab's **agent** works
(`Tab.agentDirectory`, polled every 2 s from the claude/codex process's cwd —
Claude Code chdirs into a worktree on EnterWorktree), else the **shell's**
directory (OSC 7 → `Tab.workingDirectory`). Each is turned into a root by
`FileTreeModel.treeRoot(for:)`: the nearest ancestor with a `.git` (a file in a
linked worktree), never promoted to `$HOME`.

## Terminal events → UI

libghostty → `GhosttyRuntime.perform(target:action:)` → the surface's
`TerminalView` → closures set by the window controller:

| Ghostty action | Goes to |
|---|---|
| `SET_TITLE`, `PWD` | tab title, tab cwd (→ tree, worktrees, diff follow) |
| `NEW_TAB`, `CLOSE_TAB`, `GOTO_TAB`, `MOVE_TAB` | the window's tab operations (the user's Ghostty keybinds drive Overterm tabs) |
| `CLOSE_WINDOW`, `CLOSE_ALL_WINDOWS` | window close (with confirmation) |
| `TOGGLE_COMMAND_PALETTE` | Overterm palette |
| `START_SEARCH` | the ⌘F overlay (with Ghostty's needle, if any) |
| `END_SEARCH`, `SEARCH_TOTAL`, `SEARCH_SELECTED` | `TerminalSearch` → the overlay's terminal row and the compact bar's `3/12` |
| `RING_BELL`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `COMMAND_FINISHED` | `TabActivity`: `isWorking` + a ranked mark (waiting > failed > done) → tab strip (breathing glyph + sliding bar / ringing yellow dot / green check / red mark), notification, Dock badge |
| `OPEN_URL` | ⌘-click on a link libghostty matched: `FileLink` (shell dir, then checkout; `:line[:col]`, `(line,col)`) → the editor at that line; URLs, directories, binaries → system opener |
| `MOUSE_SHAPE`, `QUIT` | handled directly |
| `NEW_SPLIT`, `GOTO_SPLIT`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM` | the tab's splits (Ghostty's defaults: ⌘D, ⇧⌘D, ⌘[ ⌘], ⌥⌘arrows, ⌃⌘arrows, ⌃⌘=, ⇧⌘↩) |
| anything else (new window, …) | returns false: unhandled |

`close_surface_cb` (shell exited, or Ghostty's ⌘W) → `closeTab` (pinned tabs
ignore it unless the process actually exited).

## Tab groups (islands)

A group is a name, a colour and a set of tabs (`Sources/Overterm/Groups/`).
It owns nothing: the tabs stay in `TabStore.tabs`, each carrying its group's
id, and the store keeps two invariants — pinned tabs first and never grouped,
and **a group's tabs are one contiguous run** — so everything that walks the
tabs (the session, closing, tab peek, the agent overview) stays unaware that
groups exist. `TabStore+Groups` restores both in `normalize()` after every
operation.

**Which island a new tab joins** is one pure rule, `NewTabGroup.placement`,
and every way of opening a tab asks it (`TerminalWindowController.addTab`).
Chrome's rule — inherit the island of the tab you opened from — was wrong
here: a group is usually a checkout, so it ends up holding every tab, and
from then on ⌘T, the strip's +, the palette and the sidebar all dropped
their tab into it with no way out but a drag. So a tab joins only where the
intent is unmistakable:

| | |
|---|---|
| the strip is focused on an island (⌃⌘F) | it joins — a loose tab would open out of sight |
| **a folder** was opened (the sidebar, a worktree row, Finder) and it is under a folder someone bound to an island (`TabGroup.folder`, ticked in the group popover — never set by default) | it joins |
| the island was asked and said yes (`TabGroup.takesNewTabs`) | it joins |
| the island holds every tab in the strip | the tab opens **loose** and the window asks under the chip (`NewTabPrompt`); the answer is the island's, so it is asked once |
| anything else | loose — inserted after the anchor, which `normalize` then slides past the anchor's island |

Saying "in this island" outright is the island's own `+` and its chip menu
(`newTab(in:)`), which pass the group and never ask.

The binding is read only for an opening that **names** a folder
(`NewTabGroup.Opening.folder`), never for ⌘T, the strip's `+` or the palette
(`.here`). Those inherit their directory from the tab you are in, which
inside a bound island is always the island's own folder — so reading the
binding there sent every ⌘T straight back into the group, which is the thing
this rule exists to undo.

## Splits

A tab is a `SplitTree<TerminalView>` (`Sources/Overterm/Splits/`): a
binary tree, panes at the leaves, each split an axis and a ratio. The tree is
pure (insert, remove, spatial neighbours, resize, equalize — unit-tested with
plain objects); `SplitHostView`, one per tab, lays it out: panes by frame,
1 pt gaps where its background shows as the divider, grabbable ±4 pt (its own
tracking loop, `acceptsFirstMouse`), unfocused panes under a dim.

- `Tab.terminal` is the **focused pane** — typing, ⌘F, links, the tab's title
  and directory follow it (`TerminalView.onFocus` → `Tab.focus`). What means
  the whole tab goes over `Tab.terminals`: closing and its warning, Tab Info's
  processes, finding the agent to follow, quitting.
- ⌘W closes the focused pane of a split tab (asking only if something runs in
  it), else the tab (always asking). `exit` closes just its pane.
- Zoom shows one pane alone; the others are occluded, not closed.
- The session saves a split tab's layout (`PaneLayout`: each pane's
  directory, each split's axis and ratio) and which pane had the keyboard.
  On restore the first pane resumes the tab's agent.

## Merged worktrees

`MergedWorktrees` (`Sources/Overterm/Git/`) decides which linked worktrees
are done with; `WorktreeModel.merged` holds it, refreshed with the list.
A branch is merged when

- its upstream is `[gone]` (pushed, then deleted on the remote: GitHub's
  delete-on-merge) **and** its tip is on some remote ref — every commit is
  pushed (`pushedBranches`: one `rev-list --branches --not --remotes`);
  a gone branch with commits no remote has (made after a squash merge) is
  never deleted on that alone; or
- it has an upstream and its tip is reachable from the default branch
  (`origin/HEAD`, else the main worktree's branch); or
- `gh` reports a merged pull request whose head is exactly the branch's tip
  (`mergedByPullRequest`) — how a squash merge is recognised.

Never pushed never counts: a New Task branch with no commits is reachable
from main too. A worktree whose folder was deleted by hand (`prunable`) is
cleanable as well. Rows get a purple merge mark; the Worktrees header gets a
count that runs **Clean Up Merged Worktrees…** (also File menu, ⌘K, a row's
menu): `git fetch --prune` (ssh in BatchMode), then one sheet listing what
goes and what stays — kept: a tab in it (a shell's directory or where its
agent works), uncommitted changes, locked. It runs
`git worktree remove` without `--force` and, if ticked, `git branch -D`
(`-d` refuses a squash-merged branch). The Worktrees reload button fetches too.

## Changes pane

The fourth column (`Sources/Overterm/Diff/`): `DiffModel` for the selected
tab's checkout, `DiffPanelView` its Warp-style cards. A switch under its
header picks what it lists, remembered (`diffScope` in `AppEnvironment.defaults`):

| Scope | Against | From |
|---|---|---|
| Uncommitted | HEAD (the empty tree before the first commit) | `status --porcelain=v1 -z` + `diff --numstat -z HEAD`. Stage, discard and commit act here only |
| Branch | `merge-base(HEAD, base)` | `diff --name-status -z -M <mb>` + its `--numstat` (committed, staged and unstaged; renames paired), untracked files from status; above the cards the commits `<mb>..HEAD`, newest first (`BranchLog`: subject and short SHA; a click shows the date, message and files) |

- The base is `MergedWorktrees.base`: origin/HEAD, else the main worktree's
  branch — the one merged worktrees are judged by. Where that is missing or
  is the branch itself — a repository pushed from a local init has no
  origin/HEAD, and its main checkout may be on a feature branch — it is the
  first of origin/main, origin/master, main, master that exists and isn't
  (`DiffModel.branchBase`; `MergedWorktrees.base` stays as it is, clean-up
  relies on it). With no HEAD, no base, HEAD on the base branch itself (main,
  or its own origin/main), or no merge-base (unrelated history), Branch has
  nothing to compare with: the pane says why ("On main — nothing to compare
  with") and lists Uncommitted.
- Both lists' counts are always live. The ± badge shows in any git
  repository, so the pane is one click away: the uncommitted totals while
  there are any, else the branch's — an agent's work stays in sight after it
  commits — else a plain ± (`DiffModel.badge`). A click on it opens the pane
  on the Changes view, in the scope it counts (`Badge.scope`, picked as the
  switch would; the plain ± keeps the one picked last). View ▸ Changes (⌥⌘D,
  the palette's Changes) toggles the pane on the scope picked last and is
  ticked while it shows. Diff text loads only while the pane is open, for the
  scope shown, from that scope's base.
- It refreshes on FSEvents under the checkout and, for a linked worktree,
  under its git dir (`.git/worktrees/<name>`: index, HEAD) and the
  repository's `refs/` — a commit there writes nothing inside the checkout.
  A burst of events is one refresh (400 ms debounce); the window becoming
  key refreshes too.
- With more than 8 files (`DiffModel.startFoldedAbove`) the cards start
  folded: the pane reads as a list of files with their +N −M, and a click on
  one opens it. A card starts as it is when first shown with the pane open
  (closed, none is: opened on many files, the pane is a list, however they
  came); after that only the user changes it — a click on its header, or
  Collapse All / Expand All in the pane's header, for every card and those
  shown after. So a refresh never folds or opens a card: the list growing
  past 8 folds only the cards that come then, not the one being read. The
  folds are the checkout's, in either scope; another checkout, or coming
  back, starts afresh.

### How a diff reads

As in the Claude Code desktop app: in the editor's colours, with what
changed inside an edited line marked. `DiffModel.FileDiff(parsing:path:)`
works it out as each file's diff loads, off the main thread
(`DiffModel.fileDiff`), into compact ranges per line
(`FileDiff.style(of:)`); `DiffLineView` only puts them on the text
(`DiffPalette`), once per line drawn — it is equatable, so a refresh that
leaves a line alone doesn't redo it.

- **Colours** (`DiffHighlight.syntaxTokens`): `SyntaxHighlighter` for the
  file's language over each hunk's two sides, each tokenized as one text —
  the old (context and removed lines) and the new (context and added) — so
  a block comment or a string spanning lines is one token, then split per
  line. Context lines take the new side's: they read as the file now does.
  Only the hunk is read: a comment opened above it isn't seen. The palette
  is the editor's (`SyntaxPalette`: comments the text colour faded, in
  italics); the line keeps its green/red tint. A file the highlighter
  doesn't know stays plain, and so does a side past the editor's limit
  (`SyntaxHighlighter.maxLength`).
- **What changed in a line** (`DiffHighlight.pairs`, `changedRanges`): in a
  hunk, a run of removed lines pairs in order with the run of added lines
  right after it (git writes a change as its removals, then its additions);
  the rest of the longer run has no pair. A pair's changed part is what lies
  between their common prefix and suffix, counted in characters — never
  splitting an emoji, a flag or a letter from its accent — and drawn as
  UTF-16 ranges, stronger than the line's tint. Lines sharing under 40% of
  the longer were replaced rather than edited, and get no mark; nor do
  lines over 10,000 UTF-16 units.
- **Cost**, one capped file (3,000 lines, 133 KB, a third of them changed and
  paired), release build: 11 ms off the main thread (parsing 1.6, tokens 8.3,
  changed parts 0.5); drawing adds about 6 µs a line. Kept as attributed text
  instead of ranges, such a file's lines would take 6 MB.

### Why each file changed

Under each card's header, quiet: what Claude said when it edited the file —
two lines of the newest and when, `+N` for more; a click (`toggleWhy`) shows
every one in full — and in Branch the commits that touched it
(`BranchLog.byFile`). Nothing when there is nothing to say. The card shows
`DiffModel.why(for:)` as it is; `reasons` is read only while the pane is open.

- **Which transcripts** (`ClaudeEditsReader`, `Sources/Overterm/Info/ClaudeEdits.swift`):
  the sessions started in the checkout or below it, found by folder name as
  the Sessions panel finds them (`ClaudeSessions.transcripts`; both spellings
  of a path under a symlink, `/var` and `/private/var` — Claude Code names
  the folder after its resolved cwd); in a linked worktree also those
  started in the main checkout: a session keeps its transcript where it
  started, also after EnterWorktree moved it. With each, its subagents'
  (`<session>/subagents/agent-*.jsonl`, whose edits count as the session's).
- **How much**: only transcripts written since the branch left its base — the
  merge-base or the branch's oldest commit, whichever is older (a rebase
  moves the merge-base, not the work) — else a week back; the newest 60.
  Edits from before then are dropped too.
- **How**: off the main thread, one read at a time (a refresh meanwhile asks
  for one more, so a busy agent can't starve a slow first read), incremental
  per transcript like `ClaudeUsageReader` — its byte offset and the parser's
  state are kept, so a refresh parses only what was appended. A byte search
  picks the lines worth parsing (assistant text, edit calls, an edit's
  result, prompts, titles); tool output, thinking and most attachments are
  never parsed as JSON. 200 MB: 0.3 s the first time, a millisecond after.
- **What** (`ClaudeEdits.Parser`, measured on 2.1.1xx–2.1.28x transcripts):
  an Edit, Write, MultiEdit or NotebookEdit call paired with its
  `tool_result` on a later line (`tool_use_id`); `is_error`, or no result,
  and it changed nothing. Its reason: the nearest assistant text before it
  since the last prompt typed — Claude writes a message's parts on lines of
  their own, and one text often covers several edits — else that prompt,
  else the session's title (`custom-title`, `ai-title`, an old `summary`).
  Thinking is never a reason. A slash command, a background task's notice
  start a turn nobody typed; reminders, caveats, command output and a
  compaction's summary are no turn at all; a coordinator's message is a
  subagent's prompt, a prompt queued while Claude worked (`queued_command`)
  one too. `ClaudeEdits.byFile` keys them by path in the checkout (symlinks
  resolved, a file's own name kept), newest first, one per reason, three per
  file.

## Settings (⌘,)

A tab, as Warp's; files behind it, as VS Code's (`Sources/Overterm/Settings/`).

**The tab.** `TabStore.settingsOpen` / `settingsShowing` put a Settings tab
after the terminal tabs (`SettingsTabItem` in the strip). It is a page, not
a terminal: `SettingsPageView` covers the window's body under the strip,
and the terminal tab under it stays `selectedID` — so nothing that assumes
"a tab has terminals" changes. Choosing any terminal tab (a click, ⌘T,
⇧⌘]) uncovers it; ⌘W while it shows closes only it (`closeSelectedTab`).
Ghostty's `open_config` (its ⌘,) opens it too.

**settings.json.** `Settings` reads `Application Support/Overterm/settings.json`
(isolated runs: their own). Only what differs from the defaults is in it —
`SettingsSchema` holds every setting: key, section, group, title, kind,
default, and for Ghostty's options the option it writes. The page's rows
are made from that list, and so are validation and search. The file is
JSON5 (comments, trailing commas); the page edits it in place
(`SettingsJSON.setting`: the key's own line, so comments and order stay),
rewriting it whole only when it isn't laid out one key per line. A
`DirectoryWatcher` applies a hand edit at once. A file that doesn't parse
is never written over: the last good settings stay, the page says why.
A value that doesn't fit its setting is listed and its default applies;
an unknown key is listed and left alone. `changes` names the keys that
changed, for whatever acts on them. Before 1.17 settings were UserDefaults
(`settings.*`): `Settings.migrate` carries them over once.

Appearance and Terminal are Ghostty's own settings: unset, the user's
Ghostty config decides; set, `writeGhosttyOverrides` puts them in
`ghostty-overrides.conf`, which `GhosttyRuntime.makeConfig()` loads after
the user's config, and `reloadConfig()` hands every open surface the new
config (`ghostty_app_update_config`). The chrome's colours (ChromeTheme)
are read at launch.

**keybindings.json.** VS Code's form: a list of `{ "key", "command" }`; a
`"-command"` entry removes that key from it; the last word on a command
wins (one key each: a menu item holds one). `KeyCommands` lists every
command — a menu item (its `identifier` is the command id, `MainMenu`
gives it the default key), a Ghostty action, or both. A command without a
default of its own takes Ghostty's (`GhosttyRuntime.defaultTrigger`: a
config built without Settings' overrides, so the user's Ghostty keybinds
count). `Keybindings.apply(to:)` puts the keys on the menus. Ghostty sees
keys first in the terminal (`performKeyEquivalent` asks
`ghostty_surface_key_is_binding`), so `ghosttyLines` adds to the overrides
file: for a menu command, `unbind` of its old key and of its new one (the
menu does it); for a terminal-only command, `unbind` of the old and the
new key bound to the action. Keys are written by position on a US layout
(`KeyCombo(event:)` reads key codes): AppKit shows ⌘, as ⌘Ö on a Turkish
Q, and it is still `cmd+,`.

About: `UpdateChecker` asks `gh api repos/Overcraft-hq/overterm/releases/latest`
(private: the user's gh login), compares SemVer with CFBundleShortVersionString,
downloads the DMG with `gh release download`; once a day at launch when
allowed, a title-bar chip when newer (it opens Settings ▸ About).
`make-app.sh` bundles `CHANGELOG.md` for "What's new" and View Latest
Changelog (⌥⌘O).

## Agent overview (⇧⌘A)

Every tab as a card over the window (`Sources/Overterm/Agents/`), refreshed
every 2 s while shown, waiting-for-you first, then failed, working, done,
idle agents, plain shells. Per card: the tab's `TabActivity` (and the
notification text), the agent — the tab's own, or one found running in any
pane (process tree, as Tab Info) — where it works and the branch (read from
`.git/HEAD`, following a linked worktree's `.git` file: no git process per
card every 2 s), the branch's PR from `WorktreeModel.pullRequests`, and for
Claude `ClaudeActivity` from the last 512 KB of the session transcript:
`ai-title` (Claude Code's title for the session), the last prompt, the last
reply, and the tool call after it if there is one — what it is doing now.
A card selects its tab; Esc (the host takes the keyboard) closes.

## Tab peek (⇧⌘E, three fingers down)

Every tab's terminal at once, live (`Sources/Overterm/Peek/`). Three fingers
down the trackpad opens it a stage at a time: first a row of previews under
the tab strip with the selected terminal pushed down below it, then — if the
fingers carry on — a grid. A card is the tab's **real** terminal, so it keeps
drawing, splits included.

- **No new rendering path, and no reflow.** Every tab's `SplitHostView`
  already fills `container`, pinned to its four edges; the peek only puts a
  `CATransform3D` on its layer. A layer transform moves pixels without
  changing a frame, so `TerminalView.setFrameSize` → `ghostty_surface_set_size`
  never runs and no pty is resized. Opening it un-occludes every pane
  (`setVisible(true)`), which libghostty answers with an immediate draw — so
  a card is current, not the frame left over from when the tab was hidden.
  Past `TabPeek.liveLimit` (12 panes) the rest stay occluded and are drawn
  by hand at 6 Hz (`TerminalView.drawNow` → `ghostty_surface_draw`, the one
  call that renders an occluded surface).
- **`TabPeek` is pure** — `Stage`, `placements(tabs:selected:progress:in:)`,
  `grid`, `move`, `transform` — in a top-left origin space, like
  `SplitTree.layout`. The controller turns a placement into a transform and
  the SwiftUI chrome draws that card's title bar and border from the same
  rectangle, so the two can't drift. `progress` runs 0…2 and the stages are
  interpolated, so there is no jump at 1.
- **Two measured AppKit facts the transform depends on** (both learned the
  hard way, both checked by `TabPeekTests`): AppKit anchors a layer-backed
  view's layer at (0, 0), not its centre; and the host's layer has its
  geometry flipped while its superlayer's is not, so x is top-left and y is
  mirrored. AppKit also **resets the transform** when it syncs the layer to
  the view's geometry — it had silently undone the scale on every host but
  the first — so `SplitHostView` owns it (`peekTransform`) and puts it back
  in `viewWillDraw`.
- **`container.clipsToBounds`** goes on when the peek opens: since macOS 14
  a view doesn't clip, and the pushed-down terminal would paint over the
  editor and changes panes.
- **The gesture is one direction.** `TabPeekGesture` is a pure state machine
  fed finger counts and positions (`NSTouch`, `allowedTouchTypes =
  [.indirect]` on `TerminalView` and on the peek's own host, so a swipe
  started over a terminal carries on once the peek is over it). Down opens
  the strip, down again the grid, and a **fresh** swipe down at the grid
  takes it back out: macOS claims three *and* four fingers up for Mission
  Control, and WindowServer recognizes it before any app sees a touch.
  Settings ▸ General picks three fingers, four, or off; ⇧⌘E, Esc, a click
  outside and picking a card work either way. Two-finger scrolling is
  untouched — it is a scroll event and never reaches this.
- **The keyboard**: ⇧⌘E toggles (free in Ghostty v1.3.1; ⇧⌘↓ would never
  arrive, `jump_to_prompt` eats it), arrows and ⇥ move the highlight, Return
  picks, Esc closes. As with the agent overview, Esc goes through a window
  event monitor as well: its host having the keyboard was not enough.
  `showSelectedTab` leaves first responder alone while the peek shows —
  selection is published a turn late, and a peek opened right after a tab
  switch lost the keyboard to the terminal behind it.

⇧⌘A agent overview stays separate: peek shows a terminal's **shape**, the
overview its agent's **state**.

## Dropping a tab onto a pane

Dragging a tab out of the strip and over the panes offers five targets in
one rectangle (`Splits/DropZone`, pure): the four edges say which way to
split, and the middle — the big, easy one — just puts it in the tab. The
pane is **moved**, not recreated: its pty, its scrollback, whatever is
running in it and its command ledger all come with it, which is the only
reason to do this rather than press ⌘D.

Not "swap with this pane", which the designs draw. Swapping two tabs'
panes is a no-op unless both are already split, and when the one being
dragged is a whole tab it would empty it.

It rides the strip's existing drag monitor rather than a real dragging
session — the monitor already sees the whole gesture, and a session would
mean teaching panes a new pasteboard type beside the file drops they
already take.

## The palette (⌘K)

One search over what you have run, your snippets, your tabs and
worktrees, and the app's own actions, with scope chips to narrow it and a
detail pane beside the list (a snippet's `{{placeholder}}`s to fill in, or
when a command last ran and how it went).

`Palette/CommandHistory` is new: Overterm had no history at all, and the
thing you most often want to run again is the thing you ran an hour ago.
It is fed by the command ledger — which already records every command with
its exit, its duration and its folder — and seeded once from the shell's
own history file so it is not empty on day one. Ranking is "this folder
first", then recency, then how often; it is pure, because the ranking *is*
the feature.

History rows are ranked below everything else in the palette itself: a
history row is a guess at what you meant, and an action named for what you
typed is not (a long command containing n, c and l somewhere outranked
"New Claude Tab" for "ncl").

**⌘K is Ghostty's `clear_screen`**, and Ghostty answers keys in
`performKeyEquivalent` before the menu sees them — so clearing moves to
⇧⌘K and `Keybindings.ghosttyLines` writes the unbind. That unbind is not
conditional on the user having changed anything, which is what the old
code assumed; a key Overterm always wanted elsewhere never looked
"changed" and the line was never written. It is still not written for a
key a terminal command deliberately shares (⌘F is the editor's find *and*
the terminal's search).

## Asking an agent about a selection (⌘L)

What you want to tell an agent is usually on screen already — a failing
test, a stack trace. Selecting it puts a strip over it (Ask Agent, Copy,
Copy as Markdown, Search the Web), and ⌘L opens a sheet: which agent tab,
what to include (the selection, the command it came out of, that
command's exit code, the git diff), and a line about what to do.

The strip can be placed because the selection is the **one** region
libghostty reports a position for (`ghostty_text_s.tl_px_x/y`), and only
while it is on screen — which is also the only time a strip over it would
mean anything.

What gets built is one string (`AskAgentModel.prompt`), which is the part
worth testing; it is **typed, not sent**, so what to do with it is still
yours to finish.

## Live ports and links

A pane's header shows what anything in its process tree is listening on
(`Info/ListeningPorts`, an `lsof`, run on every third tick of the poll
that already walks the selected tab). A pill opens a popover with the
process, its pid, and Open / Copy URL / Kill — the exact pid, never a
pattern. A tab that listens is a server, which is what its icon then says
(`TabKind`).

No preview of the page, which the design draws: that is a WebView per
pill for a thumbnail, and the process name answers the question the
thumbnail was asking ("which of my two servers is this").

Links are libghostty's: it detects and underlines them, and ⌘-click
arrives as `GHOSTTY_ACTION_OPEN_URL`, which Overterm resolves as a file
link first (`Editor/FileLink`) and opens in the editor at its line.
Hovering one arrives as `GHOSTTY_ACTION_MOUSE_OVER_LINK`, which carries
the URL and **no rectangle** — so there is nothing to anchor a popover
to, and one placed at the pointer would fight selecting the text it is
over. The pane header says what is under the pointer instead.

## Agent Inbox (⌘I)

A column of everything waiting on you, to the right of the terminal. The
marks in the strip say *which* tab wants you; the inbox puts the question
in front of you — what the agent is asking, the diff or command it is
about, and its own choices as buttons. Answering types the number and
Return into that pane.

It only ever offers choices it **read off that pane's screen**
(`Inbox/AgentPrompt`, pure): the last run of numbered lines, the sentence
above them, and the block above that. A question it cannot parse gets
"Open tab" and nothing else — typing a number at an agent that was asking
something different is the one mistake this must not make. "Deny" and
"don't ask again" are found by their words, never by their position.

A tab reaches the inbox only when `TabActivity` says it needs you; the
inbox is the attention list, not a screen scraper. It polls (1.5 s) only
while it is open, because reading a question means reading the screen.

Also the Dock badge (as before) and, while anything waits, a menu bar
item — which goes again when nothing does.

## Command blocks and the scroll map

libghostty exposes **none** of OSC 133 over its C API — no prompt marks,
no command boundaries, no jump target. What it does push is the title the
shell integration sets, `COMMAND_FINISHED` (exit code and duration) and
`GHOSTTY_ACTION_SCROLLBAR` (total rows, the viewport's top row, its
height). `Blocks/CommandLedger` is those three assembled into a list of
commands, and it is pure — every case in it is row arithmetic.

Three things about it are not obvious and all three were found the hard
way:

- **The title is the command *and* the directory.** Shell integration sets
  it to the command while one runs and back to the cwd at the prompt, so
  half of what arrives is a path. `CommandLedger.isPrompt` tells them
  apart; without it every prompt made a block, and each one stole the rows
  of the command before it.
- **`total` does not count lines.** It is the scrollback plus the screen,
  and the screen is a fixed height — so it does not move until output
  starts falling off the top. A command whose output fits on screen has no
  row of its own, and says so (`CommandBlock.isLocated`): nothing
  row-based draws for one.
- **The scrollbar lags the exit.** The renderer recomputes it on its own
  cadence, so the scroll caused by a command's last lines can arrive after
  `COMMAND_FINISHED`. A finished block stays open for the one scrollbar
  update that follows.

Reading a command's output is **not** done by row: `ghostty_selection_s`
takes exact points and libghostty clamps their y to the active screen's
height (`embedded.zig`, `Point.pin`), so a scrollback row cannot be
addressed at all. The whole region is readable, and the output is
everything after the last line that *ends with* the command.

The map (`Blocks/ScrollMapView`) draws over the terminal's right edge
rather than beside it — libghostty owns the grid, and insetting it would
cost every pane two columns forever for something you look at while
scrolling. It follows the system's scrollbar rule: visible while you
scroll, unless you have asked for scrollbars always. While invisible it
takes no clicks, or selecting text at the edge of a pane would hit it.

A failed command gets a ring over its rows (`Blocks/BlockFrameView`,
AppKit and inert — it lies over live text), and the three things you then
want are in the pane header, which does not scroll away.

## Overgit (⌥⌘G, sidebar)

One git home: the sidebar panel beside Files, Sessions and Snippets, with
a commit's own diff in the right-hand pane. `Sources/Overterm/Overgit/`;
the readers it uses are in `Sources/Overterm/Git/`.

- **What it reads.** `CommitLog` (`git log -z … --decorate=full`) for the
  history with its parents; `Refs` (`for-each-ref`, `remote -v`) for
  branches with ahead/behind, tags and remotes; `Stashes`; `CommitShow` for
  one commit. `--decorate=full` is not decoration: short names cannot be
  told apart — `feature/x` is a local branch and `origin/x` is not — and
  the full refname says which without guessing.
- **Nothing is read unless it is being looked at.** The panel is one of
  four and most of the time it is not the one on screen, so `OvergitModel`
  reads only while `visible` **and** only the sections that are open — the
  inbox's rule, a section at a time. Shutting a section keeps what it read,
  so reopening it does not blink. Which panel is showing had to leave the
  view for this: `@AppStorage` inside `SidebarView` could not tell the
  window when to start and stop, so it is `SidebarModel` (same key).
- **Pull requests are not read here at all.** `WorktreeModel` already asks
  `gh` once a minute for the whole repository; a second asker would double
  the rate limit for the same answer. The overview's uncommitted counts
  are `DiffModel`'s, for the same reason.
- **The graph.** `GraphLayout` is pure: a lane is a column some commit is
  expected in; a commit takes the lowest lane already waiting for it, else
  the lowest free one; its first parent inherits that lane and the others
  take their own; a lane nobody waits in is free at once. So six lanes
  serve a repository with a hundred branches as long as only six overlap.
  Past that budget lanes are drawn on top of the last one rather than
  widening the sidebar without end — the panel beside the rail can be
  176 pt, and an exact graph there is worth less than a subject you can
  read. A row says what passes it, what ends at it and what leaves it;
  `GraphGutter` draws that in a `Canvas` per row, which is why the commit
  rows are a fixed 36 pt — the lines have to meet.
- **Worktrees moved in** and gave up its icon. A sidebar left on the old
  panel comes back on Overgit (`SidebarPanel(stored:)`), not empty.
- **A commit opens in the right-hand pane**, a fourth tab beside Changes,
  Pull Request and Usage — not a column, so the "right of the window is
  one slot" rule holds and the browser steps aside as it does for the
  changes pane. `CommitDetailModel` runs three `git show` calls for the
  commit and one per file; `GitStatus` and `FileDiff` parse all of it
  unchanged, and `FileCard` (lifted out of the changes pane into
  `Diff/FileDiffView.swift`) draws it without the stage box or Discard. A
  merge is shown against its first parent — what it brought in — and the
  pane says so.
- **The mark** is drawn in code (`OvergitMark`), not loaded: there is no
  asset catalog and no SVG pipeline, and one glyph is not reason enough to
  add either.

## Claude sessions (sidebar)

`ClaudeSessions.list` finds transcripts in `~/.claude/projects` for the
repository's worktrees and folders below them. Claude flattens paths into
folder names (every non-alphanumeric is `-`), so a folder is a candidate by
prefix and kept only if the transcript's `cwd` is really inside a worktree —
`repo-other` is not `repo`. Only the newest 60 are read, 128 KB of each end
(`ClaudeActivity`). `SessionsModel.running` pairs tabs' Claude processes with
sessions: the id after `--resume` in its command, else the newest session in
its directory. A click selects that tab, else opens one with
`claude --resume <id>` (`Agent.claudeResume`, UUIDs only — it is typed into
a shell).

## Pull requests

Everything GitHub goes through the user's own `gh` (`Sources/Overterm/GitHub/`;
`GitHub.executable` looks in Homebrew's paths — a GUI app's PATH has none).

- `WorktreeModel.pullRequests`: one `gh pr list --state all --json …` per
  repository, cached a minute, asked again every minute while the app is
  active and on the Worktrees reload. Per branch an open PR wins over an old
  merged one. Shown on worktree rows (number in its state's colour, CI glyph)
  and as a chip in the title bar for the current checkout's branch.
- A merged PR makes its worktree cleanable (`.pullRequestMerged`) only if the
  branch still points at the PR's merged head (`headRefOid`) — a reused branch
  name with new work on it is not merged. This covers squash merges whose
  remote branch was kept.
- The right pane switches between Changes and **Pull Request**
  (`PullRequestModel`, loaded only while shown, again each time it is shown):
  `gh pr view <branch> --json …` (checks, description, comments, reviews) and
  `gh api repos/{owner}/{repo}/pulls/N/comments --paginate` (inline comments,
  grouped into threads by their root; `--paginate` prints one array per page,
  back to back). A thread's `file:line` opens in the editor.
- Writing: `gh pr comment N --body …`, and a reply in a thread with
  `gh api …/pulls/N/comments/<root>/replies -f body=…` (`-f`, not `-F`: a
  body starting with `@` must not be read as a file).
- CI parsing: gh's rollup mixes CheckRuns (`status`/`conclusion`) and
  StatusContexts (`state`); skipped/neutral count for nothing.

## Search (⌘F)

`SpotlightModel` (`Sources/Overterm/Search/`), rows in this order:

| Row | Source | Return |
|---|---|---|
| Terminal | libghostty's own search (`search:<needle>` binding action; totals come back as `SEARCH_TOTAL`) — highlights live behind the overlay | keeps the search, shows `TerminalSearchBar` (Return / ⇧Return / Esc) |
| File | `git ls-files --cached --others --exclude-standard` of the checkout (`diff.root ?? tree.root`), loaded once per open, fuzzy-ranked with the name weighted over the path | opens it in the editor |
| In file | `git grep -F -i -I --untracked`, ≥ 2 characters, 150 ms debounce, capped per file and in total | opens it at that line (`EditorViewController.go(toLine:)`) |

Without a checkout only the terminal row is shown. Esc (or a click outside)
ends the terminal search too; only choosing the terminal row keeps it.

## Tab Info (⌘I, or Show Info… on a tab)

A popover per tab, live while open (`TabInfoModel`, `Sources/Overterm/Info/`):

| Section | Source |
|---|---|
| Location | tab cwd → checkout, branch, worktree-of, changed files (git) |
| Running | `ProcessInspector`: everything under the tab's `login` (paired to its surface by `SurfaceProcesses`, since libghostty doesn't expose the pid), plus anything tagged `OVERTERM_TAB_ID` that left the tree. CPU% from task-time deltas (Mach ticks → ns), resident memory. Links via sysctl KERN_PROC — proc_pidinfo refuses root's `login`. |
| Listening | `lsof` on the tab's pids, every 3 s; Open → localhost |
| Claude session | `ClaudeUsageReader` on `~/.claude/projects/<cwd as ->/<session>.jsonl`: streamed, incremental, ends-of-line byte search, replies de-duplicated by id |
| Disk | `DiskUsage` of the checkout only, cancellable, cached 60 s |

macOS hides the environment of Apple-signed binaries (zsh, sleep, git) from
other processes, so the env tag alone can't find a shell — hence the tree.

## Agents

`Agent` is a closed enum (Claude, Codex). An agent starts by typing its command
into a fresh login shell (`initial_input`), so quitting it leaves a shell.
Restore types `resumeCommand` (`claude --continue`, `codex resume --last`).
Claude Code needs no configuration for tab flags: with `TERM_PROGRAM=ghostty`
its default notification channel is OSC 777 and its progress bar (OSC 9;4) is
on by default (checked against 2.1.280).

## Usage

What is left of each agent's quota, and what the work would have cost, in
the right pane beside Changes and Pull Request (⌥⌘U, or the gauge at the
right of the strip). Nothing is asked over the network: both agents write
their own numbers down.

| | Where it comes from |
|---|---|
| Claude's windows | `~/.claude.json` → `cachedUsageUtilization`: `five_hour`, `seven_day`, and whatever code-named allowance is live beside them (one of them is a real $250). Claude Code caches the API's answer there and refreshes it only while it runs, so `fetchedAtMs` is shown as an age. The newer `limits` array wins when it is there. These are **account-wide** — the same file's breakdown counts chat and the desktop app — which is why the pane says "Claude", not "Claude Code". |
| Codex's windows | the last `event_msg`/`token_count` in the newest `~/.codex/sessions/**/rollout-*.jsonl`: `rate_limits` with `used_percent`, `window_minutes` and `resets_at`, plus `plan_type`. Which window is which is read off the minutes — "primary" is the weekly one early in a session. |
| What it cost | the tokens in those same logs, priced by `ModelPricing` (list prices, the two cache TTLs apart, an unknown model left unpriced rather than free). |

`UsageTailScanner` reads a log **backwards** in 256 KB steps and stops at the
first line with usage older than the window — a day costs about 0.1 MB a
file, where reading forwards would cost the 643 MB those transcripts come
to. It is safe because the lines that carry usage are written in order;
other lines are not, by up to five hours, so only those may stop the walk.
A scan is kept against the file's size and modification date.

Three ways to count the same tokens twice, all of them avoided and all of
them tested: Claude repeats a reply once per content block (deduped by
`message.id`), a Task agent's tokens are in `…/<session>/subagents/*.jsonl`
and nowhere else (walked as well), and Codex's `total_token_usage` is a
running total for the session with `cached_input_tokens` *inside*
`input_tokens` (so the per-turn `last_token_usage` is what counts, cached
part taken out and charged at the cache rate).

`UsageModel` reads in two tiers: the meters whenever the app is in front
(for the strip's gauge), the walk over the logs only while the pane shows.

## Opening from Finder

`Info.plist` (`Scripts/make-app.sh`) declares folders and text/source/any
files at `LSHandlerRank` Alternate — listed under Open With, never the default
— and an `NSServices` entry, "New Overterm Tab Here" (`NSRequiredContext`
makes it on by default). `AppDelegate.application(_:open:)` and
`AppDelegate.newTabHere` (the service; `NSApp.servicesProvider = self`) both
call `TerminalWindowController.open(_:)`. `make install` runs `lsregister -f`
and `pbs -update` so Finder sees a change at once. `public.data` alone did not
get files listed; the explicit text types did.

## Microphone and other privacy prompts

macOS charges what a program in the terminal asks for to Overterm, the app
it runs in. `Info.plist` therefore carries `NSMicrophoneUsageDescription`,
`NSSpeechRecognitionUsageDescription` and `NSAudioCaptureUsageDescription`
(Ghostty's wording): without them macOS refused the microphone without asking
— Claude Code's `/voice` got silence, and Overterm never appeared in System
Settings ▸ Privacy & Security ▸ Microphone. Now the first request asks; the
setting is there to change it. The `terminal` scenario checks the keys.
An ad-hoc signed build is a new app to macOS each time, so the answer would
not survive a reinstall; `make install` re-signs the installed copy with
`SIGN_IDENTITY` (environment or the untracked `local.mk`) when it is set, and
one identity keeps the grant (README, Build). The simulator pane asks for
nothing: it reads the device's own framebuffer rather than the Mac's screen,
so no Screen Recording grant is involved (Simulator).

## Build metadata

`Scripts/make-app.sh` writes what About Overterm shows into `Info.plist`:

| Key | From |
|---|---|
| `CFBundleShortVersionString` | `VERSION` — SemVer, bumped by each commit that changes the app (CLAUDE.md, Commits) |
| `CFBundleVersion` | `git rev-list --count HEAD`: the build number, growing with every commit on main |
| `OvertermCommit` | `git rev-parse --short HEAD`, plus `-dirty` when `git status --porcelain` lists anything |
| `OvertermBuildDate` | the day it was built, `YYYY-MM-DD` |

`VERSION` and `BUILD` in the environment override the first two. Without git
(a copy of the tree, no repository) the build is 1 and the commit `unknown`.

About Overterm (`AppDelegate.showAbout` → `AboutPanel.show`) is the standard
panel, which prints "Version 1.10.0 (103)" from the first two keys itself,
with credits from the other two: `commit 7e68283 · 26 Sep 2026`
(`AboutPanel.credits`, pure: English in any locale, what is missing left out,
no credits for a bundle with neither key). The credits get an explicit
colour: the panel draws them as given, black in dark mode otherwise.

`CHANGELOG.md` is the history; the commit that brings a version carries an
annotated tag `v<version>`, made by the post-commit hook (`.githooks`,
`make hooks`).

## Dropping onto a terminal

Every pane (`TerminalView`) is a drag destination for file URLs, file
promises and text (`Sources/Overterm/Ghostty/TerminalDrop.swift`). A drop is
a paste (`insertText`), never Return: the references separated by spaces,
with a trailing space; the pane gets the keyboard.

- **What a drag carries** (`TerminalDrop.payload`), in order: file URLs
  (Finder, the Desktop, the sidebar — reference URLs resolved to paths);
  else file promises (Photos, Safari, the screenshot thumbnail), received
  into a folder of their own under `AppEnvironment.dropsDirectory`
  (~/Library/Caches/io.github.overcraft-hq.overterm/Drops; an isolated run's own);
  else web URLs, else text, both inserted as they are, less line breaks at
  either end.
- **What goes in** (`TerminalDrop.insertion`, pure) depends on what has the
  pane's keyboard. Claude Code: an image (png, jpg, jpeg, gif, webp) as its
  absolute path, whitespace and backslashes escaped with a backslash; any
  other file or a folder (with a `/`) as `@path`, relative to where Claude
  works when inside it, else absolute — `@"path"` where the plain form would
  be cut (whitespace; an ending that isn't a letter, digit or `_`), the plain
  quoted path where neither carries it (`#`, a quote with whitespace).
  Anything else — a shell, vim, Codex — and any drop with ⌥ held: shell-quoted
  absolute paths (`shellQuoted`), as Terminal does.
- **Why those forms** (Claude Code 2.1.282, read from its bundle): a paste is
  split before each ` /` and at line breaks; a part that, trimmed, stripped of
  one pair of surrounding quotes and backslash-unescaped, ends in an image
  extension is read and becomes `[Image #N]`, placed before what is left of
  the paste. Only backslash escapes survive several images (a quoted path
  isn't split off), so images go last and the rest starts with a space — an
  `@` right after `]` is no mention. On submit it attaches
  `(^|\s)@"([^"]+)"` and `(^|\s)@([^\s]+)\b`, cutting a `#L…` range off;
  its own completion quotes a path with a space.
- **What runs in a pane** (`TerminalDrop.program`): the pane's process tree
  (`ProcessInspector.tree` under its login) holds a Claude process — by name
  or argv[0], as the agent overview finds one — in the tty's foreground
  process group (the login's `e_tpgid`); one left running in the background
  doesn't count. Per pane, looked at afresh at each drop and on entering, on
  a serial queue: pairing a new pane with its login lists the app's children
  off the main thread too. Drops are typed in the order they came
  (`pendingDrops`), whatever each waited for.
- **While dragging**: `DropHighlightView`, over the pane's frame in its
  superview, above a split's dims — an accent border and a label, "Drop to
  insert path" / "Drop to insert @ reference" / "Drop to insert text", with a
  count for several files. It clips to the pane, never takes a click, a drag
  or the keyboard, and goes on exit or drop.
- **The sidebar**: file tree rows (files and folders) drag their file URL
  (`FileTreeDrag`, SwiftUI `onDrag`); click, double-click and the row's menu
  are unchanged.

## Editor

The pane beside the terminal is meant to save the trip to Zed: Zed's colours,
keys, pickers and language servers, over an `NSTextView` (TextKit 1) — IME,
undo, accessibility and find come with it, and none of what makes Zed feel
like Zed needs a GPU renderer.

- **Files** are `EditorBuffer`s: a text storage each (the layout manager
  swaps it in), an undo manager, a syntax tree, the selection and scroll to
  come back to, problems and git marks. A file opens in a tab after the one
  showing; ⌘W in the editor closes a tab (asking about edits), not the
  terminal.
- **Zoom**: a file opens beside the terminal; ⇧⎋ or the header's ⤢ shuts
  the terminal, inbox and changes columns (Settings ▸ Editor can open every
  file that way). ⇧⎋ or ⤢ again, choosing a tab,
  searching the terminal or giving it the keyboard brings them back as they
  were. Instant, not animated: an animated collapse finishing after a quick
  un-zoom hid the terminal again.
- **Colours** (`Syntax/`): tree-sitter with Helix's queries, and the grammar
  revisions that Helix release pins (`Scripts/build-treesitter.sh`), so the
  queries compile. `SyntaxDocument` parses on its own queue, in UTF-16 (a
  byte offset is twice an `NSRange` location); edits in one run-loop pass
  merge into one tree edit (`SyntaxEdit`). Injections are parsed as their
  language over just their ranges of the document: markdown's inline text,
  a fence's language, HTML's script. Only what is on screen (and a screen
  either side) is coloured, after each parse and on scroll; spans for an
  older text are dropped. Later patterns win, as Helix 25.07's queries
  expect. The palette is Zed's One Dark / One Light (`EditorTheme`), picked by
  the terminal's background; a capture takes its nearest named ancestor.
- **Line height** is a layout-manager delegate (`EditorLineHeight`), not a
  paragraph style, so the extra space is shared above and below the text.
- **Keys**: the editor's commands are `KeyCommands` with `editor: true` —
  Zed's (VS Code keymap) defaults, a scope of their own. `CodeTextView` takes
  them in `performKeyEquivalent` (⌘ keys, before the menu: ⌘D is Add Next
  Match here and Split Right in the terminal) and in `keyDown` (the rest:
  ⌥↑, F12, ⌃G). They are never menu key equivalents: ⌥↑ there would be taken
  from the terminal too. ⌘F is left as it was: the editor's find bar (the
  menu's Find…) there, the terminal's search overlay in the terminal. Order in `keyDown`: the completion list, vim, the
  shortcuts. The editing itself (auto-indent, pairs, comments, moving and
  duplicating lines, ⌘D) is `EditCommands`: pure, text and selections in, one
  undoable change out.
- **Language servers** (`LSP/`): one per language and project root, started
  on a file's first open, found on Homebrew/Go/Cargo paths, through `xcrun`,
  or among the servers Zed downloaded. Full-text sync, debounced, flushed
  before any request; UTF-16 positions. Diagnostics, completion (with the
  file's own words, `CompletionMatch`), hover, definition, references,
  symbols, formatting. Nothing launches in tests or isolated runs unless
  `discoveryOverride` hands in a fake.
- **Vim** (`Vim/`, Settings ▸ Editor): a pure engine over a `VimBuffer`, which
  the pane is; Zed's choices — yanks go to the clipboard.
- **Markdown preview** (⇧⌘V, the header's eye on a markdown file): the
  file rendered by Foundation's own parser (`AttributedString(markdown:)`,
  full syntax — no web view, no bundled script) into TextKit 1 blocks
  (`MarkdownRenderer`): code and quotes on a surface, tables as
  `NSTextTable`s. A block needs a width (`setContentWidth` 100 %), or it is
  as narrow as it can be. It follows the file as it changes; a relative
  link opens in the editor.
- **Git gutter**: the file at HEAD (`git show HEAD:./name`), diffed by line
  (`LineDiff`) off the main thread a moment after typing stops.

## Browser

A browser beside the terminal (⇧⌘B, View ▸ Browser; off entirely with
Settings ▸ Browser), so a dev server's page, its console and an agent
driving it are in the same window as the code.

- **WebKit, the system's**: a WKWebView per page — nothing bundled. Web
  Inspector is the toolbar's 🔨 (or a right-click). Cookies and storage
  persist and are shared by every page (an isolated run uses a
  non-persistent store).
- **Per terminal tab**: each tab has a `BrowserWorkspace`, its pages as the
  browser's own tabs (strip under the toolbar; ⌘T ⌘W ⌘L ⌘R ⌘[ ⌘] ⌃⇥ ⌘1…9
  while the browser has the keyboard; target=_blank and window.open open a
  page, with WebKit's configuration so the opener keeps its handle). The
  column shows the selected tab's; a background tab's pages are parked in
  an off-screen window, so they keep running and an agent can still use
  them. The session keeps every page's address (not file: pages).
- **Links**: ⌘-click in the terminal, Tab Info's and a pane's ports open
  here or in your browser by `BrowserLinks.Policy` — localhost and private
  addresses here by default. The empty column offers the tab's ports.
- **Console**: an injected script reports console calls, uncaught errors
  and rejections; the strip at the bottom counts errors and opens the log.
- **Reload on save** (off by default): an editor save, or the checkout's
  files changing under an agent, reloads a local page.
- **Agents** (`BrowserBridge`, `BrowserMCP`): an MCP server (streamable
  HTTP, JSON answers) on 127.0.0.1, a random port and a bearer token, one
  path per pane — `/mcp/<the pane's OVERTERM_TAB_ID>` — so an agent reaches
  its own tab's browser. Each pane gets `OVERTERM_MCP_CONFIG`, a Claude Code
  config file (0600) written for it, and Overterm starts `claude` with
  `--mcp-config "$OVERTERM_MCP_CONFIG"`. Tools: navigate, snapshot (text and
  the controls, each with a ref), click, type, screenshot, console,
  evaluate, back, reload, and the tabs (list, new, select, close). Ask
  Agent (✦) sends a page's address, errors and a screenshot the ⌘L way.

## API client (⌥⌘R, sidebar)

Bruno's collections, sent and tested beside the terminal (the rail's ⇄,
View ▸ API Client; off entirely with Settings ▸ API Client). The point is
that it is **Bruno's files**: a collection is a folder with `bruno.json`,
its requests `.bru` files committed with the code, and the same collection
opens in Bruno and runs under `bru run` — nothing of Overterm's own on disk.

- **The format** (`BruFile`, `BruRequest`): blocks — `name { … }`, or
  `name [ … ]` for a list — and whatever is between them, kept as read. A
  file read and written back with nothing changed is the same bytes; an
  edit rewrites only its block, laid out as Bruno's writer lays it (two
  spaces in; every line of a text block indented, empty ones too), so the
  diff is the edit. A new block goes where Bruno's writer puts it
  (`BruFile.order`). Requests, `folder.bru`, `collection.bru` and
  environments are all this one format.
- **A collection** (`BrunoCollection`): found under the checkout (four
  folders down at most, never in node_modules, never inside another);
  its tree in Bruno's sidebar order — folders first, each list by `seq`
  then name; `folder.bru` names and orders a folder; `bruno.json`'s
  `ignore` honoured.
- **Variables** (`APIVariables`): runtime over request over folder over
  environment over collection, as Bruno's docs layer them;
  `{{process.env.X}}` from the collection's `.env` first; `{{$guid}}` and
  the like fresh each send; an unknown name left as written, so it shows
  in what was sent (and the timeline names it). **Secrets** — the names an
  environment lists under `vars:secret` — live in the keychain
  (`KeychainSecretStore`), never in the file, as Bruno keeps them in its
  app data; an isolated run gets a store that forgets.
- **Sending** (`APIRequestPlan`, `APIClient`): the plan is pure — the
  collection's, each folder's, then the request's headers (the nearest
  wins, case aside), auth from the request or inherited from the nearest
  folder that sets one, every body Bruno has — so tests and Copy as cURL
  see exactly what Send would. AWS, digest, NTLM and OAuth 2 are kept in
  the file and say "run with bru". One `URLSession` per collection keeps
  its cookies together; its delegates are plain classes, called on the
  session's queue (CLAUDE.md).
- **Scripts and tests** (`APIScriptRuntime`, `APIScriptPrelude`,
  `APIExecution`): each script in a fresh JavaScriptCore context on a
  queue of its own, with JSC's execution time limit (looked up with
  `dlsym` — it is only in the private headers) so a loop that never ends is
  stopped, not the app. The prelude is Bruno's API — `bru`, `req`, `res`,
  `test` (async ones awaited), a Chai-style `expect`, `assert` — over JSON
  handed in and read back. A run is Bruno's: pre-request scripts on the
  request as written (variables filled in after them), the request as they
  left it, `vars:post-response`, post-response scripts, the assert block,
  tests — "sandwich" or "sequential" as `bruno.json`'s `scripts.flow` says.
  `require` of an npm package says to use bru; with bru installed, the
  Runner's Run with bru runs the same in a terminal tab.
- **In the editor** (`APIRequestModel`, `APIRequestView`,
  `EditorViewController+API`): a request `.bru` opens as a request over its
  text, as Markdown's preview does — the eye shows the text. The file stays
  the editor's buffer: every edit in the request view is a minimal edit to
  its text, through the text view, so ⌘S, undo, the unsaved mark and an
  agent's rewrite on disk work as for any file. The URL's query and the
  params are kept in step; `:name` segments are the path params.
  `folder.bru`, `collection.bru` and environments open as text.
- **The panel and the Runner** (`APIWorkspace`, `APIPanelView`,
  `APIRunner`): one workspace per window, following the checkout the
  selected tab shows, reading the disk only while its panel is on screen
  (`updateAPIVisibility`). A run of the collection or a folder goes to the
  right-hand pane's Runner tab — the slot the changes and the browser share
  — with `setNextRequest`, skip and stop honoured and a thousand steps at
  most.
- **Importing** (`APIImport`, `OpenAPIImporter`, `PostmanImporter`,
  `HTTPFileImporter`, `CurlParser`, `APIDiscovery`): each importer makes
  an `APIImport`, written as the checkout's collection (`bruno/`) or as a
  folder of the one it has, its environments added and none replaced.
  YAML is read by the editor's tree-sitter grammar (`YAMLReader`). The
  panel offers what it finds: documents in the checkout, and the API the
  selected tab serves, asked for at the paths frameworks publish their
  OpenAPI document at (localhost only; Settings can turn it off).
- **Agents** (`APIMCP`): the browser's MCP server carries the API client's
  tools too — `api_collections`, `api_send`, `api_request`, `api_run` —
  about the agent's own tab's checkout (`agentAPI(forPane:)`). The server
  runs while either tool set is given (`BrowserBridge.update`). The
  response's ✦ hands a request and what came back to an agent.

## Notes (⌥⌘N, sidebar)

A notes vault beside the terminal: a folder of Markdown that is an
Obsidian vault as it is — the same folder opens in Obsidian, on the phone
through iCloud, and here (Settings ▸ Notes names it; empty is "Overterm
Notes" in iCloud Drive; the panel's header switches between the vaults
Obsidian lists in its `obsidian.json`). Overterm keeps nothing of its own
in it, and `.obsidian/` is read for where things go, never written.

- **The files** (`NotesVault`, `NoteFiles`): every read and write goes
  through `NSFileCoordinator`, so a write never lands in the middle of a
  sync or of Obsidian's own; a file iCloud hasn't downloaded (a
  `.Name.md.icloud` placeholder) is listed under its real name and fetched
  when opened. The tree is Obsidian's order — folders first, names as
  Finder sorts them — without hidden files and "Excluded files".
  `ObsidianSettings` reads `app.json`, `daily-notes.json` and
  `templates.json`: where new notes and attachments go, Markdown links or
  wikilinks, the "New link format", strict line breaks, daily notes and
  templates (moment.js formats, `MomentFormat`).
- **A note** (`NoteParser`, pure): frontmatter (through `YAMLReader`),
  `[[links#heading|alias]]`, `#^blocks`, embeds, Markdown links into the
  vault, tags by Obsidian's rule, headings, tasks with the range of their
  status character — nothing from code. Ranges are UTF-16, as the editor
  counts; the text is parsed as a native `NSString` and code ranges are
  binary-searched (agents' transcripts are 2.6 MB notes).
- **The index** (`NotesIndex`, `LinkResolver`): a value built off the main
  thread, the notes whose date is unchanged kept. A link means what
  Obsidian decides: a path from the note's folder, then the vault's root,
  then a name — the closest file with it, in the note's own folder, else
  the shortest path. Backlinks, tags (nested ones counted for their
  parents), tasks and unresolved links are lookups.
- **`NotesModel`** is one for the app — the vault isn't a checkout's — and
  reads only while some window shows the panel, or when something needs
  the index now (a note open, ⌘F, an agent): `whenLoaded`. Obsidian's
  settings are read again with every reload; its workspace file, rewritten
  on nearly every click, wakes nothing.
- **Reading view** (`NoteReaderView`, `Resources/notes`): a WKWebView with
  markdown-it, DOMPurify, KaTeX, highlight.js and mermaid, bundled, pinned
  and SHA-checked (`Scripts/fetch-notes-web.sh`). Swift resolves every link
  and cuts every embed (`NoteRenderPayload`, `NoteSections`); the script
  only draws and posts back what was clicked. The page loads only through
  `overterm-note:` — the app's files and the vault's, a path leaving either
  refused — and a note's HTML is sanitized, because the page talks back to
  the app. DOMPurify drops any attribute value with `-->` in it: a mermaid
  diagram's source is kept in a table, not an attribute.
- **Live Preview** (`NoteLivePreview`): the note's own text, styled with
  attributes — nothing inserted. Markup carries `.noteHidden`, which the
  layout manager's delegate (`EditorLineHeight`) lays out as nothing, on
  every line but the ones the selection touches; in Live Preview the same
  delegate makes each line as tall as its largest font. Boxes, dots, quote
  bars and rules are `.noteDecoration`, drawn by `CodeTextView`; links carry
  `.noteLink`/`.noteURL` for a click. An attribute, not a list of ranges:
  it moves with every edit. The caret moving restyles the lines it left
  and the ones it is on.
- **Writing** (`NoteRename`, `NoteEdits`, `NoteTemplate`, `NoteAppend`):
  a rename writes again only the links it would break, in the shape they
  were written; a task ticked anywhere is its `[ ]` in the text (the open
  buffer's, else the file's); templates, daily notes, pasted images,
  terminal text and branch notes go where Obsidian's settings put them.
- **Agents** (`NotesMCP`): `notes_search` and `notes_read` beside the
  browser's and the API client's tools on the same MCP server, read-only,
  naming only the index's notes. Settings ▸ Notes ▸ "Agents can read the
  notes".
- **Elsewhere**: ⌘F lists notes after the checkout (`NotesSearch`); the
  Graph View (`NotesGraph`, deterministic force layout off the main thread)
  joins the right-hand slot; the panel's lower half is backlinks, outline,
  tags and tasks (`NotesDetailView`).

## Database (⌥⌘B, sidebar)

A database client beside the terminal, DataGrip's work in the sidebar and
the editor: PostgreSQL, MySQL, SQLite, Redshift, ClickHouse and BigQuery
(Settings ▸ Database turns it off; its rows fetched and asking before a
destroying statement are there too).

- **Connections** (`DatabaseConnection`, `DatabaseStore`): a name, a kind,
  host, port, user, database, an SSL mode as libpq names them, SQLite's
  file, BigQuery's project, location and how it signs in (a service
  account's key, or `gcloud` on this Mac), read-only. `connections.json` in
  Application Support/Overterm/Database holds them; **a password or a
  service account key is never in it** — the login keychain holds it
  (`KeychainDatabaseSecrets`, account `<id>|password`), and loses it with
  the connection. An isolated run keeps secrets in memory.
- **Drivers** (`DatabaseDriver`): one actor a connection, the same four
  things each — a statement (columns, types, rows as text, the row limit
  kept and whether there were more) and the catalog (schemas, tables, a
  schema's every column, at once, for the tree and completion).
  PostgreSQL and Redshift are PostgresNIO: results come binary even for a
  simple query, so `PostgresText` says each type as psql would; an empty
  read's columns are asked of a temporary view. MySQL is MySQLNIO, reads as
  simple queries (text), writes as queries (rows changed). SQLite is the
  system's libsqlite3. ClickHouse is HTTP (JSONCompact; the server stops at
  the limit). BigQuery is REST (`jobs.query`, its results until done), the
  service account's JWT signed with swift-crypto's RSA. Read-only is the
  database's own where it has one, and refused before sending everywhere.
- **The model** (`DatabaseModel`, `DatabaseSession`): one for the app; a
  session a connection, opened when the panel or a console needs it — a
  statement run while it opens waits for that; tables and columns read a
  schema at a time, as the tree opens or completion asks; the history.
- **A console** (`SQLConsole`, `SQLConsoleView`, `EditorViewController+Database`):
  any `.sql` file in the editor, its connection remembered by its path; a
  connection's own console is a file in Overterm's folder. Under the text,
  in `consoleHost` between it and the status bar: the connection and
  schema, Run (⌘↩ — the statement at the caret, `SQLText.statement`, or
  the selection; elsewhere ⌘↩ inserts a line) and Run All; a tab a
  statement; the rows in `ResultGrid` (NSTableView — a SwiftUI list of
  thousands of rows doesn't scroll), sorted, copied (`ResultExport`).
- **SQL as text** (`SQLText`, `SQLCompletion`, pure): statements split
  outside strings, quoted names, comments and `$tag$` bodies; whether one
  only reads, whether it destroys; what the caret is writing — a table
  after FROM, a column after `alias.` — and the candidates from the
  catalog, a schema not read yet read and the list asked again.
- **Tests**: `DatabaseDriverTests` run PostgreSQL, MySQL and ClickHouse in
  Docker (`Scripts/database-test-servers.sh`, then `OVERTERM_DB_TESTS=1`);
  SQLite always; BigQuery's signing and answers offline. The `database`
  scenario runs the panel and a console on SQLite.

### Storage

S3 and GCS are connections in the same panel (`DatabaseKind.s3`, `.gcs`),
their buckets where a database's schemas would be.

- **S3** (`S3Client`, `S3Signer`): every S3-compatible service — AWS,
  DigitalOcean Spaces, MinIO, R2, B2, Wasabi, any endpoint
  (`StorageProvider` fills the endpoint from the region and says whether
  the bucket goes in the path). SigV4 is ours, checked against AWS's own
  examples (`S3SignerTests`); no SDK. Keys come from the form (the secret
  in the keychain, as a password) or a profile in `~/.aws/credentials`
  (`AWSProfile`). Uploads stream from the file with their SHA-256 worked
  out first, downloads go to a file; a batch delete carries its
  Content-MD5 and falls back to one at a time where a server lacks it.
- **GCS** (`GCSClient`): the JSON API, signed in as BigQuery is — a
  service account's key or `gcloud` (`BigQueryDriver.token`, by scope).
- **The session** (`StorageSession`): buckets, each folder's listing by
  `bucket/prefix` a page at a time, the transfers with their progress.
  A folder is a prefix: New Folder writes a `name/` marker, and deleting a
  folder lists every key under it first and says how many. A read-only
  connection refuses every write here too.
- **A file** (`StorageObjectModel`, `StorageObjectView`) opens in the right
  of the window — the right slot's `.object` mode, read only while it
  shows. Its metadata, then a preview (`FilePreview`, pure): CSV/TSV as
  rows in `ResultGrid`, JSON(L), logs and code as text — the first 2 MB,
  by a ranged read — images and PDFs whole up to 30 MB. Open in Editor
  opens a copy from the cache.
- **Tests**: `StorageClientTests` against the RustFS container
  (`Scripts/database-test-servers.sh`); the `storage` scenario makes a
  bucket, uploads a file and a folder, previews both, deletes — skipped
  when nothing answers on :59000.

## Simulator

The browser's column shows one of two things, and the title bar has a
button for each: the globe for the tab's browser, the phone beside it for
the iOS simulator (`BrowserColumnController`; a sixth column would have
cost every window the width and `OvertermColumns`' saved positions). Either
button, pressed while the column already shows it, closes the column.

It is the simulator, not a picture of one: the device's screen is live and
clicks, drags, the wheel and the keyboard go to it.

- **Xcode's own frameworks do it** (`SimulatorHost`). There is no public
  API — `simctl` boots a device and takes screenshots, and that is all —
  so, like every tool that puts a simulator in its own window (Radon IDE,
  idb), Overterm loads `CoreSimulator` and this Mac's Xcode's
  `SimulatorKit` at runtime and uses what Simulator.app uses. Nothing is
  bundled, nothing is linked at build time (a missing class is a `nil`
  here, not a launch failure), and every step is failable.
- **The picture** is the device's own `IOSurface`
  (`SimDisplayIOSurfaceRenderable.framebufferSurface`), put in a layer as
  it is: no capture, no copy, no encoding, and no Screen Recording grant,
  because nothing of the Mac's screen is read. CoreSimulator says when it
  has drawn (`registerCallbackWithUUID:damageRectanglesCallback:`) and the
  layer is told to look again (`setContentsChanged`); a rotation or resize
  arrives as a new surface.
- **The input** is SimulatorKit's own event builders —
  `IndigoHIDMessageForMouseNSEvent` and
  `IndigoHIDMessageForKeyboardArbitrary`, the C functions Simulator.app's
  window calls when you click in it — carried to the device by
  `SimDeviceLegacyHIDClient`. So the wire format is never written here,
  only asked for. A click is a touch at a ratio of the screen (0…1 from
  the top left, `SimulatorDisplayView.ratio`), a drag is down/moved/up, the
  wheel is a swipe that ends when it stops, and `NSEvent.keyCode` is
  already the code the keyboard builder wants.
- **It looks like a device**: the screen is drawn with the device's own
  corner rounding inside a body, the way Simulator.app draws one — a
  phone's corners are famously round (iPhone 17 Pro: 55 pt on a 402 pt
  screen), an iPad's barely, and the proportions say which it is without a
  table of models to keep up to date (`SimulatorDisplayView.layout`, pure).
  The toolbar's 🏠 is the device's own Home button
  (`ButtonEventSourceHomeButton` to the hardware service), which works on a
  device whose body hasn't had one since the iPhone X.
- **From Xcode 27** (CoreSimulator 1155.4) the guest drops this input for
  the whole boot: the bytes arrive, correctly, and nothing happens (idb hit
  it first). `SimulatorHost.suppressesLegacyInput` is that rule, compared
  numerically. Whether the device takes anything at all is one answer,
  `SimulatorViewController.takesInput` — this Xcode builds the events and
  its CoreSimulator still carries them — and the Home button, the cursor
  and the note that offers Simulator.app all follow it, rather than
  leaving you tapping at a picture. A live picture is not the same thing:
  the screen can arrive from a device that refuses the HID client.
- **The fallback** is `simctl io <device> screenshot`: no Xcode frameworks
  (or an Xcode that moved them) means a BMP three or four times a second,
  cut down to the pane with ImageIO off the main thread — a picture, not a
  simulator you can use, but never a blank pane. `SimulatorMirror` chooses,
  and the pane says which it got.
- **The devices** are `simctl list devices --json`, parsed by
  `SimulatorList` (booted first, then the newest runtime, a runtime's own
  devices together). The picker boots a device that is shut down — with
  `simctl boot`, not Simulator.app, which this pane does not need. `simctl`
  runs through `Git.run`: a GCD thread, never the main one.
- **Only while it shows**: the surface and its callbacks go when the column
  is collapsed or the browser takes it back — the rule the inbox and the
  usage pane keep. The device list is re-read every 3 s while it is up, so
  a simulator booted elsewhere appears.

## Opening files in another app

A file leaves Overterm — the file tree's double-click, its menu's **Open in
<App>**, the editor header's ↗ — in the app the user picked, not the macOS
default for its type (that was Antigravity for `.md`, Xcode for
`Package.swift`, Ghostty for `.sh`). `ExternalOpener` (`Sources/Overterm/Editor/`):

- The pick is remembered as a bundle id (`openWithApp` in
  `AppEnvironment.defaults`) and opened with
  `NSWorkspace.open(_:withApplicationAt:configuration:)`. Nothing picked yet,
  or that app is gone: a sheet asks — "Open files with which app?", a pop-up
  of candidates with their icons — and remembers the answer. Never a silent
  fall-back to the default.
- **Open With ▸** (the file menu's submenu; right-click on ↗) lists the
  candidates, the one in use ticked, then Other… (an `NSOpenPanel` of
  applications). Picking one opens the file there and makes it the one.
- Candidates (`OpenWith.candidates`, pure): installed code editors first, in
  a fixed order, whether or not they claim the file (`OpenWith.editors`, bundle
  ids from the apps' Info.plist: VS Code, Cursor, Windsurf, Antigravity, Zed,
  Xcode, Sublime Text, Nova, BBEdit, JetBrains IDEs), then the system default
  marked "(default)", then by name whatever `urlsForApplications(toOpen:)`
  returns. One entry per bundle id; Overterm itself (it claims text files for
  Finder) never.
- An isolated run's `AppCatalog` is `IsolatedApps`: its scenario installs
  stand-in apps and it records what it would have opened — an E2E run never
  launches anything, as it never touches the real clipboard.

Web links from the terminal and Tab Info's ports still go to the system
opener (the browser).

## Persistence

| What | Where |
|---|---|
| Tabs (cwd, name, colour, pin, agent) + selection | `~/Library/Application Support/Overterm/session.json` (1 s debounced + on quit) |
| Shell panes' text (last 2000 lines, plain) | `…/Overterm/scrollback/<uuid>.txt`, named in session.json; written once, at quit or window close |
| Snippets | `…/Overterm/snippets.json` |
| Sidebar/changes visible, sidebar panel, changes scope | `UserDefaults` (`sidebarVisible`, `diffVisible`, `sidebarPanel`, `diffScope`) |
| The app files open in | `UserDefaults` (`openWithApp`, a bundle id) |
| Files dropped as promises (Photos, Safari) | `~/Library/Caches/io.github.overcraft-hq.overterm/Drops/<uuid>/` (`AppEnvironment.dropsDirectory`) |
| Divider positions | `UserDefaults` split autosave (`OvertermColumns.v5`) |

Bundle id `io.github.overcraft-hq.overterm`.

### Scrollback restore

libghostty can't feed output into a surface, so a restored pane runs a
launcher (`Scrollback.launcher`, in the temporary directory — Ghostty runs
the command through `bash -c`, and "Application Support" has a space) named
after the shell: Ghostty picks its shell integration by that name. The
launcher clears login(1)'s fresh "Last login", prints the saved file, deletes
it, and `exec -a -zsh`s the real shell; the integration's environment (ZDOTDIR
for zsh) passes through, so OSC 7 and prompt marks keep working. zsh and fish
only — bash's integration goes through its arguments. Agent tabs aren't
saved: their conversation resumes (`claude --continue`) instead.

The final save runs once, at whichever comes first of the window closing and
the app quitting: after the window closes its terminals are gone, and a later
save would drop the text.
