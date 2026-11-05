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
an unknown key is listed and left alone. A `list` setting is the user's own
names or paths; an `entries` one (`kubernetes.contexts`) is named entries
with fields of their own, each field checked on its own (Kubernetes,
below). `changes` names the keys that
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

Other places open the same sheet with what they know: a note, a browser
page, an API response, a Docker container. What they bring is the text,
a question already typed, and parts (`AskAgentModel.Part`), each a chip
you can switch off. A container's last log lines are one part, its
compose service another. The prompt is still one string, built in one
place. Send hides a page over the tabs (Docker's) first, or the agent's
tab would be chosen under it and the prompt typed out of sight; Cancel
gives the keyboard back to that page's list, not to the hidden terminal.

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

- **What it does to the repository** goes through one place:
  `OvergitCommand` (`Git/GitState.swift`) names it, the window runs it
  (`TerminalWindowController.overgit(_:)`) — Pull and Push in the overview;
  a branch made, merged, rebased onto, renamed, pushed or deleted; a commit
  cherry-picked, reverted, reset to, branched or tagged from; tags pushed and
  deleted; stashes made and popped. A name is asked in a sheet; what loses
  work (a hard reset, an unmerged branch, a remote branch, a tag) is asked
  about first. The overview reads the branch's upstream and ahead/behind
  itself (`BranchTracking`) — the Branches section is often shut — and a
  merge, rebase, cherry-pick or revert stopped on a conflict
  (`GitInProgress`, from the files git leaves in the git dir) puts Continue
  and Abort above everything. The `overgitGit` scenario runs every command
  against a real remote.

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

## Review tabs (⇧⌘R)

A branch, some commits or a pull request read as a reviewer reads them, in a
tab of its own (`Sources/Overterm/Review/`) — the whole window under the
strip, so full screen is the whole screen. Not the right-hand pane: that is
one slot and a card wide, and a review side by side needs the width.

- **A page, as Settings is.** `TabStore.reviews` are the open ones, after the
  terminal tabs and before Settings; `reviewShowing` is the one covering the
  body (`ReviewHostingView`, over it as Settings' page is). The terminal tab
  under it stays `selectedID`, so nothing that assumes "a tab has terminals"
  changes: choosing a terminal tab uncovers it, ⌘W while it shows closes
  only it, Settings and a review never show at once. Reviews are not saved
  with the session — they are cheap to open again.
- **What is reviewed** (`ReviewSource`): `branch` — the checkout's branch
  since its merge base with the changes pane's base, uncommitted and
  untracked files included (what the changes pane's Branch lists);
  `range` — `base...head`, against their merge base, as a pull request
  reads (Overgit's Compare, a branch's Review Branch against that base);
  `commits` — `from` through `to` against `from`'s first parent (the empty
  tree for a root commit), picked in either order and put oldest first;
  `pullRequest` — `gh pr diff N`, so the branch need not be here, with
  `gh pr view` for the header. Opening the same thing again shows its tab.
- **Read lazily.** `ReviewModel` lists the files at once (`--name-status`
  with `--numstat`; for a pull request, `ReviewPatch.split` cuts the one
  patch into files and reads each header: added, deleted, renamed, binary,
  C-quoted names) and reads a file's diff only when it is picked, and the
  next one ahead. Up to `ReviewModel.maxLines` lines a file (20,000), more
  than the changes pane's: a review is for reading.
- **Side by side** (`SplitDiff.rows`, pure): context on both sides; a run of
  removed lines pairs in order with the added run right after it — as
  `DiffHighlight.pairs` pairs them for what changed inside a line — and the
  longer run's rest faces an empty side. Laid out once per file. The lines
  are `FileDiff`'s, so colours and changed parts are the changes pane's.
  Split or Unified is remembered (`reviewLayout` in `AppEnvironment.defaults`).
- **Keys** (`ReviewHostingView.keyDown`, only what nothing on the page took):
  j/k next and previous file, n/p next and previous change (past the last,
  the next file), v viewed — which moves on to the next file not viewed.
  Viewed marks belong to the review tab, not to the repository.
- **Opened from** View ▸ Review Branch (⇧⌘R) and the palette (Review Branch,
  Review Pull Request), the changes pane's Review (Branch scope), Overgit
  (a commit's Review Commit / Select as Start of Review, a branch's Review
  Branch, a pull request's Review Changes), and the Compare, Commit and Pull
  Request panes' headers. Comments on lines are for later.

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

`CHANGELOG.md` is the history; the commit a version is released from carries
the tag `v<version>`, made when releasing (CLAUDE.md, Commits) — the
pre-commit hook (`.githooks`, `make hooks`) reads the newest one to know
what is released.

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
- **Drawings** (`DrawingFile`, `DrawingView`, `EditorViewController+Drawing`):
  Excalidraw, in Obsidian Excalidraw's own file, so a drawing made in either
  opens in the other. A `.excalidraw.md` is markdown: the frontmatter and
  anything written above `# Excalidraw Data`, the text elements under
  `## Text Elements` (search and links see them), the plugin's other
  sections, then the scene under `## Drawing` — JSON, or lz-string's base64
  in lines of 256 (`compressed-json`) when the plugin's "compress" is on.
  Only the text elements and the scene are ever written again; every other
  byte is kept (`DrawingFileTests` round-trips the plugin's file). New
  Drawing reads the plugin's `data.json` for its folder, name, template and
  compression, and never writes `.obsidian/`.

  The canvas is a WKWebView (`Resources/notes/draw.html`) running
  Excalidraw 0.18 offline: Excalidraw is ESM that imports bare packages, so
  `Scripts/fetch-excalidraw.sh` bundles it with React and lz-string into one
  script (esbuild; every package pinned with its hash in
  `Scripts/excalidraw/package-lock.json`, mermaid and the other locales left
  out, the 12 MB Chinese font left out) into `Resources/notes/excalidraw`.
  A change on the canvas goes back as the scene's text, the editor writes it
  into the buffer (`replaceText`, as a `.bru` request does) and saves a
  second later: a drawing has no Save to forget. A change on disk (Obsidian,
  an agent) is redrawn. ⇧⌘V shows the text.

  A note embedding a drawing (`![[Board.excalidraw]]`) shows its picture:
  Swift hands the reading view the scene (`NoteRenderPayload.drawings`), and
  the page loads Excalidraw the first time it needs it and draws it with
  `exportToSvg`.
- **Agents** (`NotesMCP`): `notes_search` and `notes_read` beside the
  browser's and the API client's tools on the same MCP server, read-only,
  naming only the index's notes. Settings ▸ Notes ▸ "Agents can read the
  notes". `notes_draw` (Settings ▸ Notes ▸ "Agents can add drawings") is the
  one tool that writes: a new drawing, never over a file, from Excalidraw's
  element skeletons, converted by Excalidraw itself on a page no window shows
  (`DrawingConverter`) and opened in the front window's editor.
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

### SSH tunnels (SSHTunnel)

A server connection can go through a bastion: `/usr/bin/ssh -N -L`
forwarding a free local port to host:port as the bastion sees them, so
the user's `~/.ssh/config`, keys and agent work unchanged. The driver
connects to `127.0.0.1:<port>`; `serverName` keeps TLS on the database's
own name (PostgresNIO's `tlsServerName`, MySQL's `serverHostname`,
ClickHouse's trust policy). A password or key passphrase is a keychain
secret (`.ssh`) handed to ssh by SSH_ASKPASS — a script that prints an
environment variable set for that one process; with none, BatchMode, so a
prompt never hangs. A new host key is accepted and remembered
(`accept-new`), a changed one refused. Ready when the local end answers;
if ssh exits first, its last line is the error (lines end `\r\n` — one
Character in Swift). The session closes its tunnel; the app closes every
one on quit. Tested against an Alpine sshd beside PostgreSQL
(`SSHTunnelTests`, the `databaseTunnel` scenario).

### Agents (DatabaseMCP)

On the MCP server the browser's tools are on (BrowserBridge), with
`database.agentAccess`: `db_connections`, `db_schema`, `db_query`,
`storage_connections`, `storage_list`, `storage_read`. Connections are
named, never their secrets. `db_query` takes one statement and reads only:
`SQLText.agentReads` is stricter than a person's check — a WITH hiding a
write, `SELECT … INTO` and `EXPLAIN ANALYZE` of a write all count as
writes. Text can't see what a function does; a read-only connection is the
database's own guarantee. With `database.agentWrites`, a write is put to
the user in the window (`DatabaseMCP.allow`) and runs only on yes; a
read-only connection refuses it anyway. What an agent runs goes into the
history like anything else. Storage is read-only for agents. The
`databaseAgent` scenario drives it through `BrowserMCP.handle`.

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

## Docker (⌥⌘P, a page; the rail's shippingbox)

Docker Desktop's work on a page of its own, over the body like Settings
(`WorkspaceOverlay.docker`, made the first time it opens; the window wires
it from its declaration, `dockerWorkspacePage` — a `WorkspacePage`): the engine the
user's `docker` reaches — Docker Desktop, OrbStack, Colima — and its
containers, grouped by compose project. Settings ▸ Docker turns it off
(nothing is read then) or points it at another engine.

- **Where the engine is** (`DockerEndpoint`, pure once the files are read):
  as the CLI finds it — `DOCKER_HOST`, `DOCKER_CONTEXT` or `config.json`'s
  `currentContext`, that context's record (`contexts/meta/<sha256>/meta.json`),
  the default socket. `docker.endpoint` overrides it with a host, and
  `docker.context` (the engine menu's list) with a context — for Overterm
  alone: the CLI's current context is never changed, and the commands
  Overterm types carry `DOCKER_CONTEXT=`; an isolated run
  reaches none unless `OVERTERM_DOCKER_HOST` names one (a scenario's fake).
  `DockerRuntime` says which engine it is from the socket's path, the
  context and `/info`, how to start, stop and restart it, and the rest its
  own CLI does for it (`extras`: Docker Desktop's update check, update,
  Kubernetes status, diagnose, logs; OrbStack's and Colima's status) —
  the engine menu runs them in a terminal tab. Rancher Desktop is
  `rdctl`'s: `start` (which opens the app), `shutdown`, and its app's
  `/v1/backend_state` for whether the VM is up (`DISABLED` is up, with
  Kubernetes off). Podman answers the same API (podman-compose writes
  Compose's labels too, but never `oneoff`).
- **A remote engine** (`ssh://user@host`, a context's or `DOCKER_HOST`;
  `DockerSSH`): the system's ssh forwards a socket here to the engine's on
  the host (`-L local.sock:/var/run/docker.sock`, the local end the user's
  alone), so the transport talks to a unix socket as it does for a local
  engine and one ssh carries every call and stream — the CLI's own way,
  `docker system dial-stdio`, is an ssh per connection. The engine's socket
  there is the URL's path, else what the host's `docker context inspect`
  says, else `/var/run/docker.sock`. BatchMode, its own connection
  (ControlMaster off), the user's ~/.ssh/config, keys and agent: whatever
  `docker -H ssh://` does works; nothing is asked. A forward whose ssh has
  gone is opened again by the next call, one per host, closed when it is
  no longer the engine and when the app quits. What ssh says is the
  engine bar's reason — a refused key, or the host's socket refused
  (`connect failed: Permission denied`: the user isn't in its docker
  group). A remote engine is `.engine` whatever `/info` calls it (Docker
  Desktop's commands would start this Mac's); its ports open on the host
  (`publishedHost`, the name `ssh -G` resolves; one bound to the host's
  loopback has no link), aren't a checkout's servers or a port conflict
  here, and a database in it is reached through the Database client's
  own SSH tunnel to the host. The engine menu adds a shell on the host and
  its `daemon.json` and log there, in a terminal tab.
- **Talking to it** (`DockerEngine`, `DockerAPI`): the Engine API over the
  unix socket with SwiftNIO's HTTP/1.1 (one connection a call, ~30 ms),
  the API version settled with `/_ping`. Streams — events, followed logs,
  stats, a pull — are `AsyncThrowingStream`s that close their connection
  when the reader leaves. A request's body can be written as it is read,
  its length said first: each piece is flushed before the next is read,
  so the socket sets the pace (a folder copied in). A response's body can
  be read the same way (`receive`, NIO's async channel): the socket is
  read further only as the reader takes the pieces, so a folder copied
  out to a slow disk slows the engine down rather than piling up in
  memory, as a stream's unbounded buffer would. Pure helpers beside
  it: log frames demuxed across any cut and lines read for their level
  (`DockerFrames`), a plain ustar writer and an incremental reader for
  `archive` (macOS's `tar` adds xattrs the engine fails on), stats as
  `docker stats` works them out, ports once rather than once per
  address family, secret-looking env values masked (`DockerStats`). A `;`
  in a query is encoded: Go refuses one there, and a commit's comment may
  hold one.
- **`docker` itself** (`DockerCLI`): for what the API doesn't answer — a
  runtime's own status while its socket is silent (`docker desktop
  status`, `orb status`, `colima status`), and a checkout's compose file as
  Compose resolves it (`compose config`, run in the checkout:
  `DockerCLI.run(in:)`). Found where installers put it (an app from the
  Dock has none of it on its PATH), run through `Git.run`, told the context
  or host Overterm uses. Its stderr can be followed as it comes, while its
  stdout is kept whole (Scout's progress, then its report).
- **The model** (`DockerModel`, one for the app): whether the engine
  answers, its containers, the compose projects among them
  (`ComposeProjects` — Compose's only record is its labels; a checkout's
  stack is the projects run in it or from a compose file in it, compared by
  real path). Events keep it current, a burst read as one list 120 ms after
  it starts, filtered to what changes a list (healthchecks' `exec_*` are
  most of the traffic). It starts when the page first shows; a page on
  screen adds a 15 s poll for "Up 2 minutes". An engine that goes away
  empties the lists and is tried again at growing intervals.
- **A checkout's project before it runs** (`ComposeConfig`, pure;
  `ComposeFileModel`, one per window): Compose keeps no record of a project
  until its containers exist. So the selected tab's checkout's compose file
  is read the way `up` will read it: `docker compose config --format json
  --no-env-resolution`, in the checkout, without `-f` (Compose before 2.35
  doesn't know the flag, and is asked again without it). That is the only way
  to get what `up` gets: the name as Compose settles it
  (`COMPOSE_PROJECT_NAME` in `.env`, then `name:`, then the folder's,
  lowercased), the override merged, `include` and `extends` resolved, `.env`
  filled in, only the active profiles' services. It reaches no engine; that
  was checked against a socket that counts connections. Only names, images,
  build folders, published ports, dependencies, replicas and whether a
  service has a `develop.watch` are kept, never `environment`: it holds the
  variables' values. It is read while the
  rail's panel or the page shows Docker: when one comes up, when the
  checkout changes and its files did, and when a `.yaml`, `.yml` or `.env`
  at the checkout's top changes (FSEvents, filtered to the top folder and
  stamped by size and mtime). An isolated run asks only a scenario's stub.
  When Compose can't read it, its own words are shown, warnings left out,
  and the services read last are kept. An answer with no service (each
  under a profile that isn't on) is no project: its Up could only fail.
  The project is stopped, its services "Not created"; Up (`u`) is `docker
  compose up -d` in a tab in the checkout. It names no project: Compose
  takes the name from the files as they are then, so a name read earlier
  never pins it. Once one of its containers exists, the project from
  labels takes its place: one of its name, or one made from its compose
  file under another (`-p`, the shell's `COMPOSE_PROJECT_NAME`), since its
  Up would make the same services again, their ports taken
  (`ComposeProjects.replaces`). On the page, one of that name from another
  folder does too, and Up from here asks first: Compose would make that
  stack again from this checkout's files (with Docker Compose 2.24.4 or
  later, the question offers a name of its own — below). A checkout with
  ports of its own is read with its override, under its name, so its plan
  is the stack Overterm's Up makes; read again when an override comes or
  goes (`readAgain`). Show Resolved Config is `docker
  compose config` as YAML, in the editor: a copy, removed when its tab
  closes. A copy is a file, so env files' contents aren't asked for, and
  what Compose filled in from the variables is masked first
  (`ComposeConfig.masked`): secret-looking values in `environment` and a
  build's `args`, a URL's password, and `.env`'s secrets wherever they
  landed.
- **The page** (`DockerPageModel` per window, `DockerPageView`): sections
  and the engine on the left, the list in the middle, the selected
  container's detail (`ContainerDetailView`, `ContainerSession`) at the
  right — the list keeps its place in the view tree whether or not the
  detail is beside it, or SwiftUI makes its table again and the keyboard
  and the scroll position go with it. The filter is `DockerFilter`
  (`status:running project:api image:postgres port:5432 is:test`, `-`
  negates).
- **The containers list** is a `ResourceTable` (shared in `ResourcePage/`;
  `DockerTableRow`, the rows): an AppKit table whose rows are the page's
  SwiftUI rows, a view only while on screen and reused as they scroll (as
  a SwiftUI `List`, 160 containers took 39 ms a scroll step). A press goes
  to the row's view whole — a project's chevron is its button — and
  selects the row on release (⌘ adds or takes away, ⇧ extends); the
  right-click menu is the clicked rows' verbs. Docker's has one column
  under its own SwiftUI header (CPU and memory sort there); given several
  `ResourceColumn`s the table draws their header and sets a
  `ResourceSort`, a group's row laid across them — Kubernetes' lists, with
  the server's columns.
- **Verbs** (`ResourceVerb`, shared in `ResourcePage/`;
  `DockerPageModel+Verbs`): what can be done to a container, a project,
  an image, a volume, a network, a build or a model is one list, drawn twice — as the buttons under its detail's title
  (`ResourceActionBar`: the used ones labelled, the rest behind ⋯, removal
  last as a red bin) and as its right-click menu (`ResourceVerbMenu`) — so
  nothing is only in the menu and the two never disagree. A verb that
  can't be done now (a mounted volume's removal, the shell of a stopped
  container) is greyed with the reason in its help. Too narrow for the
  words, the bar keeps them on its first two buttons, then on none
  (`ViewThatFits`; the right-hand pane). The panel's menus and pane use
  the page's verbs acting through the panel (`DockerPanelModel.verbs`),
  whose errors are its own. A network's detail puts a container on it and
  takes one off (`/networks/{id}/connect`, `…/disconnect`): the engine
  sends no event a list reads for that (it sends one at every start), so
  both lists are read again after it.
- **A container's detail**: Overview (ports, command, health, mounts,
  networks, env with secrets masked), Logs, Inspect, Stats. A session
  (`ContainerSession`) reads logs only while Logs shows and stats only
  while Stats does — nothing while the page is hidden. The log is the last
  500 lines, then followed; Docker ends a followed log when the container
  stops, and the session follows it again on the container's own `start`
  event (a list read after a quick restart can look as before), from the
  last line's second, dropping what it already has (timestamps compared
  padded to nine digits: Docker trims a fraction's zeros). Lines go into an
  NSTextView (`LogTextView`), only the new ones drawn; 5000 kept.
  Inspect is the engine's JSON with the env's secret values taken out.
- **CPU and memory in the list** (`DockerUsageMonitor`, one for the app;
  `DockerUsageReadings`, pure): each running or paused container's use,
  a compose project's added up, sorted by either at a click on its
  column — read only while a page's Containers section is on screen, and
  stopped when the last such page goes (another section, the page hidden,
  the window closed: `DockerPageModel.close`, or the window under another
  app's, minimized or hidden: its occlusion, `windowVisible`; an isolated
  run's window, often under the user's own, counts as shown). Every 3 s
  each container is read once, four at a time, with
  `/containers/{id}/stats?stream=false&one-shot=true` (API 1.41): it
  answers at once but carries no `precpu_stats`, so the CPU is the read
  set against the one before it, over the seconds between; `stream=false`
  alone has the engine wait for two of its own samples, a second or two a
  call. A container read for the first time is read again a second later,
  so its columns fill quickly. A read has 5 s: one that hangs (moby's
  stats have, for a container whose shim stopped answering) is cancelled,
  which closes its connection, and the round ends — else nothing is read
  again and every cell keeps its last number. A failed read keeps what it
  showed one round, then a dash, never an old number as if current; it
  doesn't hurry the next round as a first read does. `docker stats
  --no-stream` was the other way, and lost: a process every interval, the
  same calls without one-shot (all at once, each waiting), numbers
  printed for people (`2.352MiB / 982.5MiB`) and read back, and over
  `ssh://` an ssh a call.
  A page takes the values only while it wants them (`DockerPageModel.usage`):
  a hidden page in another window draws nothing again for them. The
  detail's Stats tab keeps its own stream, a sample a second.
- **Images, volumes, networks** (the page's sections 2–4,
  `DockerResourceViews`): read only while their section shows
  (`DockerModel.want`) and then kept current by their own events (the
  event filter takes images, volumes and networks too, but not a volume's
  mount or a network's connect at every start). Volumes come from
  `/system/df`, the only place that says each one's size and users. An
  image pulls with its layers' progress summed (`DockerPull`); one a
  registry won't give without credentials says to pull it in a terminal
  tab, where the credential helper signs in — Overterm never handles a
  registry password. Typing in the pull field asks Docker Hub through
  the engine's own `/images/search` (as `docker search` does) and suggests
  images with their stars and the official mark. Tag, remove (asked first; never what a running
  container uses), a shell on a volume in a tab (a throwaway container);
  its files in the detail's Files tab. Overterm's own helpers are never
  listed: one mounting a volume would make it look in use.
- **Emulation** (`DockerPlatform`, `DockerEmulation`, pure): an image built
  for another architecture than the engine's — amd64 on Apple silicon —
  runs translated (Rosetta or QEMU), often several times slower. The
  engine's architecture is `/info`'s (`uname -m`: `aarch64`, `x86_64`),
  read once a connection; an image's is its inspect data's `Architecture`
  and `Variant`. `/images/json` doesn't say it. It is read only for what
  is on screen: the badge (`DockerEmulationBadge`) on a container's row,
  an image's row and a detail asks as it appears, eight images at a time,
  once an id (`DockerModel.platforms`). The page's overlay is hidden, not
  removed, and the sidebar's panel stays while it is collapsed, so their
  views live on: each host says whether it is on screen
  (`\.dockerShown`), and a badge off screen asks nothing.
- **What a container runs** is not what its image says now. In the
  containerd image store (Docker Desktop's default) an id is the image's
  index, a pull can add the engine's own platform to it, and inspect then
  describes that one — while the container made before still runs amd64.
  From API 1.48 a container says its own (`ImageManifestDescriptor` in
  `/containers/json` and inspect): the list and inspect are asked at 1.48
  when the engine speaks it, every other call at 1.47. Before that, a
  container is kept to what its image said when first read for it
  (`containerPlatforms`) — read since the last image event, never after
  one, which may have changed the index. After an image event an image's
  row asks again (`platformEpoch`); a container's, once known, never does.
  An agent asking waits for the read, a view's on its way too.
- **Running it natively**: a container marked says `amd64` on its row; its
  detail says why, and its verb runs it natively in a terminal tab. A
  service its compose files build (`ComposeFacts.built`, from `docker
  compose config`) is built again with DOCKER_DEFAULT_PLATFORM and never
  pulled: `image:` may name what `build:` makes, and a pull would put a
  registry's image in place of the checkout's. Its image's name can't
  tell: a tag moves on. Any other service's image is pulled for the
  engine's platform, then the service recreated alone (Compose applies
  DOCKER_DEFAULT_PLATFORM only to the services it builds). The verb waits
  for the files' answer; files that can't be read get `--build` and no
  pull. A lone container's image is only pulled: making it again is Run
  Another Like It's. An image's own verb pulls its variant through the
  engine (`/images/create?platform=`), and one with no such variant says
  so.
- **Builds** (section 5; `DockerBuildRecord`/`DockerBuildDetail` and
  `DockerBuildProgress`, pure; `DockerBuildSession`): what `docker buildx
  history` keeps — Docker Desktop's Builds view reads the same records —
  through the CLI. The list is read every 3 s while the section shows and
  its window can be seen (10 s over ssh, where each read is a
  connection). So a build started anywhere — a tab, an agent, compose —
  is there while it runs, and selected when nothing is, once.
  A build's steps are BuildKit's own account: `buildx history logs
  --progress rawjson <ref>` replays a finished record's stored progress
  and follows a running one to its end. BuildKit answers from the record
  once it is written and from the running job before, replayed from its
  start either way. The JSON is on stderr, a SolveStatus a line, read by
  `DockerCLI.lines` (no thread blocked) and decoded off the main thread.
  It is folded as the plain printer folds it: a step numbered when it
  first starts; its time its intervals merged; cached, failed or
  canceled as BuildKit says; its output in lines (a half line waits for
  the rest, colour and `\r` redraws out, 2 MB a step); Dockerfile
  warnings with their line. The detail redraws at most five times a
  second and reads only while it shows; hidden, the follow's process is
  terminated, and shown again it reads from the start.
  Overterm never starts a build to watch it: compose has no rawjson (its
  `--progress json` is its own), and BuildKit records every build anyway.
  Build args are masked as env is, and a secret one's value is taken out
  of step names, output and Copy Log too — BuildKit expands an ARG into a
  RUN step's name. So nothing of the steps is drawn or copied until
  `buildx history inspect` has said the build args (`secretsKnown`); it is
  asked again until it answers. buildx 0.20 has no `inspect --format`,
  and its plain table is read instead (`parsePlain`). BuildKit ends the
  stream before it writes the record's end, so the inspect is asked again
  after the end until it says how the build ended, and once more when the
  list says the record is over. Whether a build runs is the record's say
  (the list) or the inspect's, never a guess. A follow that breaks off
  keeps the steps it read and says why over them; a step still open then
  is drawn as not known, not running. A list read that fails stands in
  for the list and the detail, and the follow stops with them; Read Again
  brings both back, and the poll. The steps are a table, but not the
  list: the page's keys act only on its first table, and ⌫ asks before a
  record goes. Log in a Tab (`t`) is the plain alternative. A
  scenario points `DockerCLI.override` at a stub `docker`; a test process
  or an isolated run reads builds from nothing else (`buildsCLI`).
- **Image updates** (`DockerImageUpdates`; `DockerImageReference`, pure):
  Check for Updates — the Images header, an image's menu, a project's, `C`
  — asks each tag's registry what the tag names now. It goes through
  `docker buildx imagetools inspect <ref>`, so the CLI's own credential
  helpers sign in and Overterm never sees a password. The answer is
  compared with the tag's repo digest (`RepoDigests`), an index's children
  too, for an image pulled by its platform's digest. It reads the default
  output, not `--format`: a template makes buildx fetch every platform's
  config. It runs only when asked, since every answer is a GET of the
  registry's manifest, which Docker Hub counts as a pull; four at a time,
  a tag once however many names it has. A registry that doesn't answer
  isn't asked about its other tags: behind a firewall each would wait out
  its 30 s. Stop ends the check, and what it asked stays. In the classic
  store a tag with no repo digest for its own name was built or tagged
  here, and isn't asked. The containerd store records one for every named
  image, a build's too (its own ID; `/info` says which store), so there it
  proves nothing. Such a tag is asked, and "no such image", or a 401 to a
  question asked without credentials, makes it "not in its registry"
  rather than a failure. Another image in the registry is an update only
  once an answer has named the one here, or a project's files pull it (an
  `image:` they don't build); else it "differs", and nothing pulls over
  it. A service its project's files build is never asked, from the project
  or the Images section: a project's check reads its files first, and a
  plan's say it themselves. Answers are kept in memory with their time,
  for the app's run. The local side is read again when an image changes
  (an image event, once something has been checked, unless the Images
  section reads them anyway), so a pull — the page's, or `compose pull` in
  a tab — makes an update current with no second question. The header
  counts what wasn't asked: "Up to date" only when every image there was
  to ask is current. Pull Updates pulls Docker Hub's through the engine,
  with its progress. The engine pulls without credentials, so another
  registry's goes to a terminal tab (`docker pull`), where the CLI signs
  in as it did for the check; a project's runs `docker compose pull
  <services>` in a tab. Each project's services' images are kept as the
  engine lists its projects, for the services they have now: once a tag
  moves, the engine lists a container by its image's ID (moby's
  `refreshImage`, which the fake imitates when `refreshesImages` is on).
  Its detail says "Up recreates web" when a container runs another image
  than its tag names now. No buildx stops the check with how to get it.
  Agents read the last answers (`docker_image_updates`) and never ask a
  registry. A scenario's stub `docker` answers as buildx would, and the
  fake engine's `setRegistryDigest` makes a pull bring a new image.
- **Models** (section 6, `ModelRunner`, pure but for `read`): Docker
  Model Runner's models — pulled, loaded, on disk — read from the
  runner's own API and never `docker model`: on Docker Engine (OrbStack,
  Colima) every one of its commands, `list` and `status` too, installs a
  runner first — pulls its image, makes a container and a volume.
  Docker Desktop's runner answers over the engine's socket under
  `/exp/vDD4.40` (503 while it is off); an engine's is a
  `docker/model-runner` container already there, at its published port;
  a remote engine's isn't read. Enabling, installing, a pull and a chat
  (`n`, `docker model run`) go to a terminal tab; a removal is asked
  first and is the runner's `DELETE /models/…`. The header copies the
  OpenAI-compatible base URL for a container and, for a runner
  container, for this Mac; agents get the same in `docker_models`.
- **Vulnerabilities** (`DockerScout`, pure; `DockerScoutScans`;
  `DockerScoutView`): an image's detail has two tabs, Overview and
  Vulnerabilities. A scan is `docker scout cves --format sarif
  local://<name>` through `DockerCLI`, and it runs only when Scan is
  pressed (or the image's Scan for Vulnerabilities): Scout sends the
  image's packages to Docker's service, signed in as the user. `v` and
  the tab itself run nothing, and Scan is no default button: Return is
  the page's ↩, pressed out of habit. `local://` scans the engine's own copy and
  never asks a registry; `--platform` is the image's own, when its
  inspect says one. A scan may take ten minutes at most. The last line
  Scout writes on stderr is its progress (`Git.run` hands stderr over as
  it comes, while stdout is kept whole), and Cancel stops the process.
  SARIF, because its rules carry the fixed version, the affected range,
  the package URLs, the severity, a score and the advisory's link;
  GitLab's format gives the fix only as prose, and `cves` has no json.
  One rule covers every package a CVE is in, but its properties describe
  only the first package, so each result's message wins
  (CVE-2023-44487 is fixed in nghttp2 but not in nginx). Older Scouts
  write no package URLs (`name version`), and text after the JSON is
  tolerated (scout-cli#78). Every field is read on its own, and a wrong
  type is ignored, never fatal. `security-severity` is the advisory's CVSS
  where it has one, but Scout puts 3.1 where there is none: the page calls
  it Scout's score, never CVSS, and hides it for Unspecified. Scans are
  kept in memory for the app, by image ID: a rebuilt image starts
  unscanned, two windows show the same scan, and the Images list's row
  says `1C 2H 5M`. Signed out is said so, with `docker login` in a tab;
  a missing plugin, an image the engine doesn't have and the timeout are
  said in words too, and anything else is Scout's own last lines, with
  Run in a Tab. An isolated run or a test process never runs the real
  Scout (`DockerScout.mayRunReal`); a scenario's stub runs through
  `DockerCLI.override`. Quitting cancels every scan. The three "in a
  Tab" verbs stay in the image's Docker Scout menu (`quickview`, `cves`,
  `recommendations`), when the plugin is there (`DockerCLI.hasPlugin`).
- **MCP Toolkit** (`DockerMCPToolkit`, pure but for `read`): whether
  Claude Code and Codex reach Docker's MCP gateway — `docker mcp client
  ls --global --json`, which reads their config files and nothing else,
  each time the page shows (an isolated run asks only a scenario's stub).
  Connect and Disconnect are `docker mcp client connect|disconnect
  --global <agent>` in a terminal tab: they rewrite that agent's config,
  so the user sees them do it. Without Docker Desktop's plugin the block
  isn't there.
- **Export and import**: a container's filesystem (`/export`, `docker
  export`) and an image (`/images/…/get`, `docker save`) stream to a file
  as they come. A volume goes through a helper: a container created with
  the volume at `/volume` and never started — the archive endpoint mounts
  it anyway (the live test checks that against the real engine) — so any
  image on the Mac will do and nothing runs; it is named
  `overterm-helper-…`, labelled, recorded in `DockerHelpers` and removed
  before the call returns — one left by a quit mid-export is removed at
  quit too. Export reads `/volume`, import makes the volume and writes the
  tar back at `/`, a clone is both.
- **Clean Up** (`c`, `DockerPrunePlan`, pure): what the engine's prunes
  would remove, listed before anything goes — the prunes say what they
  removed only afterwards. It follows their rules: stopped containers
  first, so an image or a network only they kept counts as unused; images
  untagged only unless asked; volumes only when asked, anonymous ones only
  unless named ones are asked for; a network stays while any container,
  stopped too, is on it (`/containers/json`'s `NetworkSettings`, since a
  network's own record lists only running members).
- **Ports in the panes** (`ComposeProjects.ports`, `Tab.containerPorts`):
  Docker's own process (`com.docker.backend`) holds a container's
  published ports, so lsof never finds them under a tab. What the compose
  projects of a tab's checkout publish is shown beside its own ports, with
  a shippingbox; Stop goes through the engine, Docker shows it on the page.
  Kept apart from `ports`: a stack running doesn't make the shell a server.
  Tab Info lists them too, and the API client's discovery asks them for
  an OpenAPI document as it asks the tab's own ports.
- **Files of the Mac in the editor**: a project's compose file (its
  `config_files` label), what Compose makes of it — `docker compose
  config`, variables filled in and overrides merged, written to a copy
  under Overterm's folder — and the engine's own settings
  (`DockerRuntime.configFile`: Docker Desktop's `daemon.json`, which is
  its Settings ▸ Docker Engine; OrbStack's `docker.json`; Colima's
  profile), applied when the engine restarts.
- **Run** (`n`, `DockerRunSpec`, pure; `DockerRunSheet`): an image in a
  new container — name, ports, env, volumes, command, restart policy,
  in the background or in the tab — the `docker run` written out as it is
  filled in, run in a terminal tab where it pulls and starts. Copy as
  `docker run` and Run Another Like It read a container's own settings
  back: its env less what its image sets (the image's inspect data), its
  published ports, mounts (`:ro` kept), restart policy, network, and its
  command when it isn't the image's.
- **A container's settings** (`,`, `DockerContainerSettings`, pure;
  `DockerSettingsSheet`): its memory limit, CPUs and restart policy, read
  from inspect and changed in place with `POST /containers/{id}/update`,
  running or stopped — what `docker update` does, written out in the sheet
  as it is edited. The engine reads every zero as "unchanged", so a limit
  can be changed but never taken away; the sheet says so rather than send
  an empty one. A new memory limit always goes with its swap: the engine
  refuses a limit above the swap it has when none is given, and a
  container with no limit has a swap of 0 — so the swap keeps what it was
  (none, unlimited, the same on top), or is twice the limit, as
  `docker run -m` makes it. A container made with `--cpu-quota` (Compose's
  `cpu_quota`) is changed by its quota: the engine won't put NanoCpus over
  one. What the engine would refuse — under 6m, more CPUs than it has, a
  restart policy for a `--rm` container — is said before it is sent; a
  number of CPUs is held inside an Int before it is converted, since a
  byte count pasted there would trap as nano-CPUs. The `,` key goes
  through the verb, so a container Docker is removing has none. A
  running container's memory in use is one sample (`one-shot`), read when
  the sheet opens. The detail reads itself again at the `update` event, so
  a change from the CLI shows too. A compose service's container keeps
  these until Compose makes it again from its file, and the sheet says to
  write them there.
- **Rename and Save as Image** (`DockerCommit`, pure): Rename is
  `/containers/{id}/rename`; a name Docker would refuse, or one that is
  taken, is asked again with the reason. Compose finds its containers by
  their labels, so a service's container renamed still runs as the
  service, but the next up that makes it again gives it its old name back:
  that is asked about first. Save as Image is `/commit` — the running
  container paused while it is copied, its volumes not in it. Its env and
  labels can only be overridden there, not removed, so the image gets
  `ENV KEY=""` for each value that looks like a secret (by its name, or a
  URL's password) and that its own image didn't set, and `LABEL key=""`
  for Compose's and Testcontainers' labels: kept, a container run from the
  image would be counted as one of the service's replicas by the next
  `compose up`, or reaped by Ryuk. An emptied label reads as none
  (`composeProject` is nil for `""`), so such a container is no service of
  a project called "". The classic image store also writes the committed
  container's own config into the image (`container_config`, the secrets
  in it), and `docker save` and `docker push` carry it; no parameter
  changes that. There (`EngineInfo.containerdStore` is false, or unknown)
  the commit is made twice (`commitAnew`): untagged with the changes, then
  from a container of that one, never started and removed after — whose
  own config is the changed one. The first image stays as the second's
  parent, which the engine lists no more than a layer. The containerd
  store keeps nothing of the container, and one commit does. What a
  commit can't change is said instead: a password in the command or the
  health check (Compose puts `.env`'s values there) stays in the image,
  and the question says so before, the note after. The inspect is read
  before the question for that. Both verbs bring the page up first from
  the panel's menu and the right-hand pane, where their progress and
  failures are shown.
- **New Task's stack**: with Docker on and a compose file at the
  repository's top (`ComposeProjects.composeFile`), New Task offers to
  start the new worktree's own stack — through the same Up as everywhere,
  which looks at its ports and its name first (below).
- **Port conflicts** (`PortConflicts`, pure; `ContainerSession.conflict`):
  worktrees of one repository run the same compose file, and its fixed
  host ports (`5432:5432`) leave the second stack's container `created`,
  Docker saying only "port is already allocated" (or, for a process,
  "address already in use"). The detail says who holds the port — another
  container (its project and folder, usually another worktree's), a
  process in one of the windows' tabs, or one outside them (lsof) — and
  offers the way out: stop that one and start this one, or show the tab.
  A compose container's detail also offers Up on Free Ports for its stack.
- **A worktree's stack on its own ports** (`ComposePorts`, pure;
  `ComposePortStore`; `DockerPageModel+Ports`): worktrees of one repository
  run one compose file, so their stacks want the same host ports — and,
  with a `name:` in the file or `COMPOSE_PROJECT_NAME` in `.env`, the same
  project, which an Up would take over. Before any Up of a checkout's stack
  (the project's `u`, its row's play button, the panel's, View ▸ Compose
  Up, the palette's, New Task's, a rebuild, Up With Profiles…) Overterm
  asks Compose what it would publish: `docker compose -f … --profile '*'
  config --no-env-resolution --format json` — variables filled in, the
  overrides merged, ranges spread, no env file read. The files are the
  checkout's as Compose finds them (`ComposeProjects.composeFiles`):
  `COMPOSE_FILE` in `.env`, else `compose.yaml` and its
  `compose.override.yaml`. Given `-f`, Compose discovers nothing itself.
  Each port is looked for among the other stacks' containers (their own
  containers' ports are theirs: Docker binds them), then on this Mac: a
  bind with SO_REUSEADDR on 0.0.0.0, 127.0.0.1, :: and ::1
  (`ListeningPorts.isBound`) meets what Docker's own bind would, TIME_WAIT
  aside, and never listens, so no firewall asks; lsof names the holder for
  the question. A remote engine's are its containers only. A taken port of
  a service that starts, or a name another checkout's stack has, asks
  first: Up on Free Ports, Up as Written, Cancel. Free Ports writes an
  override into Overterm's folder (`Compose/Ports`, never the repository),
  passed with `-f` after the checkout's files. It holds the moved services'
  ports under `!override`, because an override's `ports` are added to the
  file's and the taken one would stay (Compose 2.24.4 and later; an older
  one goes up as written), and a project name of its own when the files'
  is another checkout's (the worktree's folder, `shop-wt-feat-x`). A
  moved port goes 10 000 up while that stays below the system's ephemeral
  range (8080 → 18080), else to the next free one; no two overrides give
  out the same port, and an answer given long after the question looks at
  the ports again before it writes anything (another window may have given
  one out meanwhile). A project run from the checkout's folder is its
  stack only when it was made from these files, or takes the plan's
  place: a test stack started there from others (`-f compose.test.yaml
  -p shop-test`) is another stack, whose ports are taken. A compose file
  is passed as named, its folder a real path (`composePath`): Compose
  resolves no link, so a linked `compose.yaml` keeps the checkout as its
  project folder. The override is remembered per Compose folder (a plan
  finds it by that folder too, which `COMPOSE_FILE` can put in a
  subfolder) and written again from the files before each Up, which asks
  nothing more; a moved port stays where it was put while it is free, so
  its URL doesn't change, and one taken since moves again or goes back to
  the file's (the page says so). With nothing left to move and the files'
  name its own, it is forgotten rather than kept empty. When the files
  change, it is written again before whatever reads them next — Pull,
  Watch, Run, the plan's read, Compose's facts, Show Resolved Config, an
  agent's up (`ComposePortStore.refresh`, by the files' sizes and dates):
  Compose refuses an override naming a service the files no longer have,
  and `!override` would pin a service's old ports. That reads the base
  files and keeps each move whose port they still ask for; only an Up
  moves ports. Every compose command that reads files is made by
  `ComposePortStore.command`, which leaves out a forgotten override that
  the containers' `config_files` label still names; Down, Stop and Restart
  go by name. The project's detail, the pane headers' pills
  (`:8080→18080`) and `docker_projects` say what moved, and an agent's
  `docker_compose up` uses the override. ⋯ ▸ Back to the File's Ports
  forgets it; `U` moves ports without asking. Settings ▸ Docker ▸ Compose
  turns the check off. A Compose that doesn't say its version, or one too
  old, leaves a kept override as it was — its name, its ports — rather
  than let the files' name take another checkout's stack over, and says
  so. Up on Free Ports where the files aren't on this Mac (a remote
  engine's project) moves nothing and says why; its verb and a conflict's
  button are greyed with the reason. What an Up says shows on the page,
  and in an alert when the page isn't on screen (an Up from the panel,
  the right slot, a menu or New Task). An Up with nothing to look at (no
  files on this Mac, the check off) is typed at once; the rest about
  0.3 s later, the project's row busy meanwhile. Unit tests never look
  (`mayCheckPorts`) unless one asks with a stub `docker` of its own.
- **A project's detail** (`ProjectDetailView`, `ProjectSession`): a
  compose project's row selected shows its verbs, its services, and their
  logs merged by time — `docker compose logs -f`, in the app. Logs go
  through a feed (`LogFeed`: the lines, a revision when they must be
  drawn again) filled by one follower a container (`LogFollower` over a
  `DockerLogSource`: the tail, then the stream, again after a restart from
  where it stopped, nothing twice); a project's lines are merged in time
  order, at the end when they are the newest, else merged and drawn again.
  Each service's name has a colour of its own. The feed, the follower, the
  pane and the text view are shared (Logs, below).
- **Testcontainers** (`Testcontainers`, pure; `DockerPageModel+Testcontainers`):
  a test run's containers say so in their labels — `org.testcontainers=true`
  and the run's session, which Java and Go write as
  `org.testcontainers.sessionId` and Node, Python and .NET as
  `org.testcontainers.session-id`. Reading only one key would miss three
  libraries. Ryuk, the reaper (`testcontainers/ryuk`), carries no session
  where Java and Python start it, so its name says it instead
  (`testcontainers-ryuk-<session>`; Go's `reaper_<session>`). They are
  taken out before the compose projects are grouped (`DockerModel.reload`):
  Go's compose module labels a stack both ways, and a test's stack is not
  a checkout's — not its panel, its pane headers' ports, nor
  `docker_projects`. The list keeps them last, a block a run, newest first,
  folded the first time a run shows: `DockerPageModel.folding` seeds
  `collapsed` once a session, from the runs the model emits (a turn later,
  a new run would show unfolded for a frame). A filter doesn't unfold one;
  revealing one of its containers does. A run's row stands for its
  containers less Ryuk, so `s` and Stop All leave Ryuk to remove them when
  the run ends. Its age is `UsageFormat.age` in a `TimelineView` — once a
  minute, only while it shows. Remove All (⌫ on the row, asked first) does
  what Ryuk does at a run's end, in its order: the containers forced out
  with their anonymous volumes (`?force=1&v=1`), then the networks, the
  volumes and the images labelled with the session — each list read once,
  at the yes — and Ryuk last, only when everything else went. Ryuk prunes
  all four kinds once the run is over; killed before the rest goes, it
  would leave a built image or a named volume on the engine for good, and
  kept, it still removes what couldn't go. A 404, or Ryuk's own removal
  racing ours ("already in progress"), counts as gone. Containers kept for reuse carry no session and are a
  block of their own. `is:test` and `session:` filter them; in the rail's
  panel, "Running elsewhere" sums the runs up in one row; an agent's
  `docker_containers` says which run a container is for.
- **A project's services** (the Services tab, `DockerPageModel+Compose`):
  each service has its verbs on its header and in its right-click menu.
  Rebuild and Start (`up -d --build <service>`), Pull, Run a One-Off
  (`run --rm`) and its logs followed go to a terminal tab in the project's
  folder. Restart goes through the engine, on that service's containers, as
  the project's does. Show Its Logs narrows the merged log to that service
  (`LogFilter.source`); every service is still followed, so All
  services comes back at once. The feed keeps its last 5,000 lines and each
  service's last 1,000 before them (`LogFeed.trimmed`): a service that
  logs every request would otherwise push a quiet one's lines out, and the
  picker would show it blank. A service with nothing to show says so. The
  choice is kept on the `ProjectSession`,
  so another project starts with all of them, and the pane's "Follow in a
  Terminal Tab" follows the same one. `b` rebuilds the selected
  containers' services, or all of a project's row: one command a project,
  four at most. A one-off is no service's.
- **What the files say** (`ComposeFacts`): the labels don't say what a
  service watches or which profiles there are. So Compose is asked, with
  `docker compose -p … -f … config --format json` (the services `up`
  starts, read by `ComposeConfig`, and which of them have `develop.watch`)
  and `config --profiles`, both with `--no-env-resolution` where Compose
  knows it. Both read the files and never the engine. They are asked when
  something on screen draws a project's verbs (the page, the panel's menu,
  the palette), once a change of its files or its `.env` (their sizes and
  dates; a link's target's, since that is what is edited), and kept by the
  page. A failure that is the files' (Compose ran and said no) is kept the
  same way, so a fixed file is read again, and the Services tab says what
  Compose said in one dim line. One that isn't (no answer in 15 s, no
  `docker`, a `docker` that didn't start) is asked again: by a view after
  30 s, by a key or a menu item at once. A key or a menu item asks on demand. A view's body only starts
  a read: the answer is published later, never during the update. Nothing
  is asked for a project none of whose files are on this Mac (a remote
  engine's), nor in an isolated run without a stub `docker`. A project
  before it runs is its plan's: `ComposeConfig` already read its JSON.
  Watch (`w`, `compose watch` in a tab) is offered only when a service has
  `develop.watch`, because Compose refuses a project with none; it is
  typed plainly, with no profiles, so it watches exactly the services in
  that JSON. Up With Profiles… lists the profiles in a sheet, ticked as last
  time in this run (never on disk), and types `--profile a --profile b up
  -d`.
- **A container's files** (the detail's Files tab, `DockerFiles`, pure):
  a folder at a time, listed by a plain `sh` script run with `exec` —
  `archive` hands a folder over as its whole tree. `exec start` hijacks
  the connection and the output comes framed until it closes; the live
  test checks that against the real engine. An image without a shell
  can't be listed, but a file in it can be opened by its path. A file
  opens in the editor as a copy under Overterm's folder
  (`Containers/<name>/<path>`, `.` and `..` left out) and is written back
  through `archive` when the editor saves it — asked first when it
  changed in the container since it was opened (its stat's size and
  mtime), and kept with its mode and owner. Its Changes view is the engine's
  `/changes`: what was added, modified and deleted since it started, a
  file a click from the editor. Stats shows its processes (`top`, every
  other sample while the tab shows).
- **Files dragged in and out** (`DockerFileTransfers`, `DockerFileDrag`;
  a container's Files tab and a volume's): files and folders dropped from
  Finder, or picked with Copy Here…, go into the folder shown, or a folder
  row they are dropped on, as one plain ustar archive made as it is sent
  (`DockerTar.Plan`, `DockerTarWriter`). Its length is said first, so
  nothing is held in memory and a bar follows it. A file that changes size
  while it goes fails the copy: the length was said. The archive is sent
  with `noOverwriteDirNonDir`, as `docker cp` sends it: a file never
  replaces a folder, nor a folder a file. Names already there are asked
  about first: from the list when it is the folder shown and listed, else
  a stat each, at most 20 — while a folder is being listed, the list is
  another folder's, or this one's before the last copy (a folder's
  entries go as soon as another is opened, so no row names a file that
  isn't there). Files of the same name are replaced. A folder there is
  merged into without the dropped folder's own entry: the engine gives a
  folder it merges into the entry's owner and mode, so node's
  `/home/node/app` would become root's. The folder is looked at before
  anything is sent, so a path that isn't
  there or isn't a folder is said at once — and the engine, refusing
  partway (a read-only rootfs), may close before reading it all: the
  write's failure then waits for its answer, which is what is said.
  Links stay links, but one that points above the drop is left out: the
  engine refuses the whole archive for it. Owners are root's, as with
  `docker cp` without `-a`; `copyUIDGID` fails on engines before moby 29
  for a numeric `USER`. GNU's long names and links are used past ustar's
  name and prefix. A file over ustar's 8 GB is refused, with `docker cp`
  in a tab as the way. A stopped or distroless container still takes a
  drop: the archive endpoint needs no shell and nothing running.
  A row dragged out is a file promise. SwiftUI's drags can't promise a
  file, so the row's drag is AppKit's (`DockerFileDragSourceView`): it
  takes only a left press, opening the row on a click, so the menu, the
  pointer and the scroll wheel still reach SwiftUI. The list is a lazy
  stack in a scroll view, as a bucket's folders are, rather than a
  `List`, whose table has row drags of its own. Finder names the place,
  and the archive's GET is read into it as it comes, the next piece only
  once this one is written (`DockerTar.Reader`, `DockerTarExtractor`), a
  folder's tree kept inside it: `..`, absolute names and anything under a
  link it wrote are left out, a folder entry of a link's name replaces the
  link, and what is there is looked at without following one — a folder's
  mode set through a link would change the folder outside. Modes and
  times are kept, owners never, a folder's mode set last so one that
  can't be written still gets what is in it. Save to the Mac… streams the
  same way, folders too; over something the user said to replace, it is
  written beside it first and swapped in once whole, with its own mode
  and times (the swap keeps the old item's by default). The promise's
  delegate isn't the main actor's: AppKit asks it to write on its own
  queue. The copies are the app's (`DockerFileTransfers`), not a
  detail's: one outlives its container being deselected. Each is a row in
  its pane's strip, a container's matched by its id so a rename keeps it
  — a finished one goes after 3 s, a failed one keeps the engine's words
  until OK. A volume's go through a helper made for the copy and removed
  after (`DockerEngine.reaching`), so the tab's own helper coming and
  going can't take it away under one.
- **A volume's files** (the volume detail's Files tab, `VolumeFilesSession`,
  `DockerVolumeFiles` pure; the list is `DockerFolderList`, a container's
  too): its folders are listed as a container's are, by the same `sh`
  script through `exec`, so they need a container that runs. `archive` on
  a folder hands over its whole tree, written as it is walked in name
  order: a folder's entries are spread through its subfolders' until the
  end, so a database's volume would be gigabytes a click. The helper is a
  container of an image already here that has a shell (busybox, alpine,
  debian, ubuntu, the debug shell's image, what mounts the volume, then the
  rest by size; at most three tried, each checked with `sh -c true`). It
  has the volume at `/volume`, runs `exec sleep 1800` as root with no
  network, and is labelled `overterm.helper=1`. It is made when the tab
  first lists, and removed when the tab stops showing: another tab,
  another volume, the page hidden, the window closed. A helper gone under
  the tab (its sleep ended) is made again at the next listing. At quit,
  what is left is removed (`DockerHelpers`), before a remote engine's
  forward closes. After a crash, its sleep ends and AutoRemove takes it.
  A file opens, saves and downloads through a helper made for the call and
  never started, as export's is (`DockerEngine.reaching`): any image will
  do, and the editor's copy (`Volumes/<name>/<path>`) still saves after the
  tab has gone. A save keeps the file's owner: the engine gives what
  `archive` writes the tar's uid and gid, and a database won't read a
  config that root now owns. The copy saves only to the engine it was
  read from: a volume's name is on every engine, and the context may have
  changed since. With no image with a shell here, the tab offers to pull
  busybox, and only when asked; a failure of another kind (a volume that
  won't mount, a full disk) is said as the engine said it, since busybox
  would fail the same way.
- **Helpers** (`DockerHelpers`): a helper is made only for a volume the
  engine has (`GET /volumes/<name>`). Bound by its name, one would make
  the volume again, empty: a volume pruned or removed in a terminal would
  come back, and a save would land in it. The tab makes none for a volume
  the list no longer has, as its detail isn't drawn then. A helper is
  removed once however many ask, and the removal returns only when the
  engine no longer has it: the engine refuses a second at once (409,
  already in progress) while the first still kills the container, which
  still holds its volume. Its anonymous volumes go with it (`v=1`): an
  image's `VOLUME` (postgres', redis') makes one at create, and the volume
  it was given by name is never one of them. A running helper holds its
  volume, so Remove and Clean Up remove the helpers holding one first and
  wait for them, and the Files tab makes none meanwhile. They ask the
  engine too, by the mount: one a crash left, or a version before
  `overterm.volume`, is in no list and in no record. Each helper carries
  its run (`overterm.run`); when an engine connects, the helpers of
  another run that don't run and were made over ten minutes ago are
  removed — a never-started one would hold its volume for good, and
  another Overterm may still be reading through a newer one.
- **Open in Database** (`d`, `DockerDatabaseGuess`, pure): a PostgreSQL,
  MySQL, MariaDB or ClickHouse container as a connection — the kind from
  its image, user, password and database from the variables its image's
  documentation asks for, the host port it publishes — in the Database
  panel's form, filled in. Nothing is saved until the form is, and then
  the password goes to the keychain as any connection's does. A port not
  published can't be reached from the Mac (the containers live in a VM),
  and says so.
- **A database's own client** (`q`, `DockerClient`, pure): a running
  PostgreSQL, MySQL, MariaDB, Redis, Valkey, MongoDB, ClickHouse,
  Cassandra or Scylla, Neo4j or SQL Server container opens its own
  client — psql, mysql, redis-cli, mongosh… — in a terminal tab,
  `docker exec -it` into it. The image says which, by the words of its
  name; one named for a tool beside a database (an exporter, a UI,
  PostgREST, a keeper) is not one, and `DockerDatabaseGuess` reads the
  same table. A compose project's name leading an image's is dropped
  first: Compose names a built image `<project>-<service>`, and New
  Task's worktree carries its branch into the project — a branch about
  Redis gave every built service a redis-cli. Docker lists an image by
  its ID once its tag names a newer one (a pull); then the name inspect
  keeps (`Config.Image`) says, when a detail has read it or `q` reads
  it. The env says who to sign in as, and only by name: Overterm
  reads which variables the container has, and the command says
  `"$POSTGRES_PASSWORD"` inside `sh -c '…'`, which the container's own
  shell expands — so no secret is on the tab's command line, in the
  shell's history or in Overterm. A client is given it the way it takes
  it off argv where there is one (PGPASSWORD, REDISCLI_AUTH,
  SQLCMDPASSWORD, clickhouse-client's own variables); mysql and mongosh
  take it on argv inside the container, as the images' documentation
  does, and blank it there. A `_FILE` variable — a Docker secret — is
  read inside too. The users are the ones the image made: MySQL's app
  user only with its password (else root), Bitnami's PostgreSQL database
  `postgres` whoever the user. With no password in the env, mysql,
  mariadb, sqlcmd, cypher-shell — and mongosh and cqlsh given a user —
  ask for one; psql asks if the server wants one (the official image
  trusts its socket); redis-cli and clickhouse-client connect without,
  as a server with no password expects. A client renamed between
  versions (mariadb, mongosh) falls back to the old name, decided in the
  container. Nothing to expand, no shell: an image without one still
  gets its client. Inspect is read when the button is pressed, never to
  draw it; a failure off the page (the panel's menu, the right-hand
  pane) is an alert, as the page isn't there to say it.
- **A failing container marks its tab** (`DockerAttention`, pure;
  `TabActivity.containerFailed`): a container of a tab's checkout that
  exits non-zero, runs out of memory or turns unhealthy marks the tab
  failed — the strip, the Dock badge, a notification while you are
  elsewhere, as a long command failing does. A stop someone asked for
  isn't news: Docker sends `kill` before such a `die`, and a crash gets
  `die` alone. Whose checkout is the compose project's working folder
  against each tab's (`DockerAttention.belongs`), the selected tab first.
  Settings ▸ Docker ▸ Attention turns it off.
- **Why did it fail? Ask an agent** (`DockerAgentBrief`,
  `DockerAttention.trouble`, pure but for the reads). A container that
  exited non-zero, ran out of memory, is dead or is unhealthy — what the
  list paints red — and one that keeps restarting, or was created and
  couldn't start (the engine's error), has Ask Why among its buttons
  (`a`; ⌘L while the list has the keyboard). It reads the container
  once, when asked; nothing polls for it. Its inspect data says how it
  ended: the exit code and what 137 or 127 means, OOMKilled with its
  memory limit, restarts and the policy, the health check and its last
  output, ports, mounts, the other services, and the env masked. A
  stopped container's health is said only as a failing streak: the
  engine calls every stopped container with a check unhealthy. Its ports
  are its bindings while it is stopped, since the list's exist only while
  it runs — a port conflict is exactly a container that never ran. Its
  last 80 log lines are one chip, the newest cut rather than dropped when
  it alone is over the budget. Its compose service is another, as `docker
  compose config --no-interpolate --no-env-resolution --format json` has
  it: variables as written, env files unread, so a .env password never
  comes in. With --no-interpolate Compose ignores a service name and
  renders the whole model, so the service is picked here. Lines picked
  out of a log go the same way with ⌘L, as whole lines, the container (or
  the project) as context. The log's text view answers ⌘L itself
  (`LogLinesTextView`), so the menu's action reaches it before the
  terminal hidden under the page; without a selection it passes the
  action on. Every word that can carry a secret goes through
  `DockerSecrets.scrub` (`Secrets`, shared with Kubernetes): the env's
  secret values and every URL's password come out, since the prompt is typed into an agent and lands
  in its transcript. A command and a health check are masked by their
  flags too (`maskArguments`: `--requirepass`, redis-cli's `-a`): Compose
  has put `.env`'s values into them, and the container's env needn't
  hold those. The names, paths and states come from the engine and
  Compose's labels and are said as they are, and a secret value that is
  one of those names (`POSTGRES_PASSWORD=postgres`) is left alone: taking
  it out would blank the container's name and its log, not a secret. A
  brief that can't be scrubbed — no engine, no inspect, so no env to
  take out — isn't made.
  The agents of the container's checkout come first, the closest first
  (`DockerAttention.closeness`): a folder above it that is no repository,
  such as `~`, holds every project, so its agent isn't this one's. A new
  one opens in its compose folder.
- **Agents** (`DockerMCP`, on BrowserBridge's server beside the
  browser's, the API client's, the notes' and the databases' tools):
  `docker_containers`, `docker_projects`, `docker_logs` (levels read,
  filtered), `docker_inspect` (state, error, health, its limits and
  restart policy, platform — emulated or not, and what runs it natively —
  ports, mounts, env) and `docker_stats` read; `docker_containers` marks
  what runs emulated, reading the platforms it needs first;
  `docker_action`, `docker_update` (a container's limits or restart
  policy, checked as the sheet checks them), `docker_compose` and
  `docker_exec` act, each asked about in the window first (`allow`; a
  test answers through `askOverride`), compose up, rebuild (`up --build`)
  and down in a terminal tab the user sees. `docker_compose` takes a
  `service` too, for all but down. `docker_vulnerabilities` reads a scan
  the user ran (from memory, without the engine) and never starts one,
  even with agents allowed to act. A name means the image that holds it
  now: after a rebuild the old image's report is not the image's. A long
  list is cut at its end, never its head — the worst come first. Settings ▸ Docker ▸ Agents: reading, and asking to
  act — on by default, as decided. No secret leaves in an answer: env
  values that look like secrets are masked, and their values taken out of
  logs and exec output.
- **Watched in the background**: the model starts when Docker is shown,
  or when the selected tab's checkout has a compose file at its top. While
  nothing shows Docker, a retry asks Docker Desktop's own CLI first (the
  host's side) and doesn't ping a VM that Resource Saver has paused, or
  one that is stopped — the ping would wake it; showing Docker tries at
  once.
- **The rail's panel** (`DockerPanelView`, `DockerPanelModel` per window):
  the selected tab's checkout's stack — its compose projects
  (`DockerModel.projects(in:)`) — then what else runs. A container picked
  opens in the right-hand pane (`RightPane.Mode.container`,
  `DockerSlotView`), the same detail as the page's, which reads its logs
  and stats only while that pane shows it — the models that own a session
  start and stop its streams (`ContainerSession.follow`), not the view's
  appearing: SwiftUI swaps a view's instances, and the one leaving
  stopped what the next had started. Until a project of its name (or one
  made from its files) runs here, the checkout's compose file is also
  listed as its stack before it runs (above); when Compose can't be asked,
  the file still offers `up`. The panel, like the page,
  starts the model and holds its poll only while it is on screen.
- **Keys** (`DockerKey`, a pure table, `?` shows it): single letters while
  the list's table has the keyboard — `s` start/stop, `r` restart, `p`
  pause, `e` a shell, `t` logs followed, `o` its port, `u`/`D` compose
  up/down, `b` rebuild, `w` watch, `v` an image's vulnerabilities (on a
  container, its image's; nothing is scanned for a key), `⌫` remove, `/`
  the filter. The window's key monitor
  (`handlePageKey`, the page's declared `press`) hands them over: SwiftUI's `onKeyPress` is macOS 14,
  and an AppKit table would eat letters for type-select.
- **The switcher** (⇧⌥⌘P): the palette scoped to its Docker group —
  every container and compose project (`dockerPaletteItems`), restocked as
  they come and go. ↩ shows one on the page, selected and unfolded; ⌥↩ is
  a shell in a running container, a start for a stopped one, `up` for a
  project. Compose Up, Down…, Restart and Watch act on the selected tab's
  checkout's stack (View menu, palette; no keys); the palette offers Watch
  only for a stack with something to watch, and is restocked when Compose
  answers. With no stack, Compose
  Up is the plan's Up — asked first when that name runs from another
  folder — if the plan was read from the files as they are
  (`ComposeFileModel.isCurrent`: nothing reads them while Docker is
  hidden); else `docker compose up -d` in the checkout. Compose Watch
  with no stack is the plan's, the same way. A tab running
  `docker exec -it …` (or attach, debug, an interactive run, Compose's
  exec and run, past Compose's own `-p`/`-f`/`--profile`) is a
  `TabKind.container`, its icon the shippingbox. The title is read in the
  shell's words (`TabKind.shellWords`): a path with a space is quoted, and
  split on spaces its second half would pass for the command.
- **A debug shell** (`E`, `DockerCommands.debugShell`): for an image
  with no shell of its own (distroless, scratch), a toolbox container
  beside it in a tab — `--pid` and `--network` its own, its volumes
  mounted, its files at `/proc/1/root`; Docker Debug's work without its
  subscription. The toolbox is `docker.debugImage` (netshoot), pulled in
  the tab where the user sees it.
- **What runs in a terminal** (`DockerCommands`, pure): compose up, down,
  pull and logs, watch, up with profiles, a service rebuilt, pulled, run
  once or its logs followed, a shell in a container, its logs followed —
  typed into a new tab in the project's folder, where the user sees them
  and can run them again. `-f` goes with up, pull, build, run and watch,
  and with every command that has profiles: those read the files; the
  rest find the project by name. A command is told the engine (`DOCKER_HOST=`) only when the
  shell wouldn't find the same one by itself.
- **Tests**: `FakeDockerEngine` plays the API on a socket of its own
  (containers, events, logs framed, files as tar; `/info`'s Architecture
  and each image's platform, a platform pull of `amd64only/…` refused;
  `containerdStore` for the containerd store's indexes and, at
  `apiVersion` 1.48, each container's own platform; one-shot stats from a
  use a test sets, `setUsage`, and a stopped container's empty, as the
  engine answers them — or a 500, or no answer at all, `setStatsAnswer`);
  `DockerTransportTests`,
  `DockerModelTests` and the `docker` scenario run against it, which records
  rather than types what would reach a real `docker`; a stub `docker`
  answers `compose config` for the scenario (a checkout's plan, a
  project's watch and profiles), and plays Compose before 2.35 too.
  Scout's SARIF is a fixture written after real 1.17 reports
  (`Fixtures/scout-cves.sarif.json`) and the fake's `scoutReport`, which
  a stub `docker` prints with its progress, for the store's tests and the
  scenario; a stub signed out, a slow one and a timeout are tested too.

## Logs (shared: Docker's and a pod's)

A log tab's pieces, whoever writes the log (`Sources/Overterm/Logs/`):

- `LogLine` (pure): a line read — its timestamp, its level (a JSON
  line's `level`, Pino's numbers, `level=`, `[ERROR]`…), its message (a
  JSON line's `msg` pulled out, its other fields kept as `key=value`),
  colour codes out, and whose it is in merged logs (`source`).
- `LogFeed`: the lines, and a revision when they must be drawn again;
  added at the end, or merged by time with other sources'; older ones put
  in front (`prepend`, as many as there is room for, `prepended` bumped
  so the view keeps its place); the last 5,000 kept, and each source's
  last 1,000 before them (`trimmed`).
- `LogFollower` over a `LogSource`: the source opens the stream (its last
  lines, or from the newest line's time) and parses its lines off the main
  actor, and says whether one that ended is followed again. Followed again
  from a time, what comes before that time is dropped, and of that time
  only the lines already shown — the same time and text, once each: two
  lines can share a time, and the second may have been written while the
  stream was down. Past that time nothing is dropped. Docker's source is
  `DockerLogSource` (the engine's frames, `since` in whole seconds, a
  restart followed again), a pod's `KubePodLogSource` (Kubernetes,
  below); what a source may do is read.
- `LogsPane` (filter, level, the source picker, Following/Stopped, wrap,
  timestamps, newest first, Save As when the page gives it a place,
  Follow in a Terminal Tab), `LogFilter` (pure: the text plain or a
  regular expression — case aside; one that isn't is said and picks
  nothing out — and picking the lines it matches or marking them,
  `highlight`; `matcher()` makes the expression once for the thousands of
  lines), `LogViewOptions` (what a page keeps for its window — Kubernetes'
  does — else the pane's own), `LogStyle` (the time dim, a level's
  colour, a source's colour, a search's matches marked), and
  `LogTextView`: an NSTextView that draws only the lines added — on top,
  newest first, where it keeps to the top as it keeps to the bottom
  otherwise; older lines put in front are drawn again with the line read
  kept where it was; scrolled to the oldest line it says so (`onOldest`,
  only where something older can be asked for). Its `LogLinesTextView`
  answers ⌘L with the whole lines picked, to a closure the page gives —
  which scrubs them (Docker's: `DockerSecrets.scrub`; a pod's:
  `KubeLogScrub`) before an agent sees them.

## Kubernetes

The design is `docs/design/kubernetes/analysis.md`; this is what exists of
it (`Sources/Overterm/Kubernetes/`). So far: the kubeconfigs, the contexts
and their classes, the settings, the proxies a request goes through, the
client that reads through them (and the fake API server it is tested
against), and the page (⌥⌘J) with its pickers and the ⌃⌘J switcher —
stage 1a of the design — and, of stage 1b, every kind and CRD as a list
kept live, in the page's sections and behind the `:` bar, any
object's detail beside its list, a Secret's values shown only when
asked, `label:` and `field:` sent to the server, the palette's page
commands, Copy as kubectl and a list as CSV — stage 1c, a pod's
logs, and of stage 1d, Terminal in this context, a pod's shell,
attach and followed log in a tab, and port-forwards — and, of stage 1e,
Ask Why and agents' read tools — and of stage 2a, writable contexts,
production's switch for the session and the page's first writes (Writes,
below): delete, force delete, finalizers, evict, rollout restart, scale.

**Which files.** `AppEnvironment.kubeconfigs(extra:)` is the one place the
list is built (`KubeconfigSources.paths`): the shell's `KUBECONFIG`
(`ShellEnvironment`; a Dock-launched app has none of its own),
colon-separated, empty entries and repeats passed over — else
`~/.kube/config` — then `kubernetes.kubeconfigs`' files, a folder giving
every file in it. Missing files are passed over, as kubectl does.

**The guard.** This Mac's current context is production, so an isolated run
(`OVERTERM_E2E`, `OVERTERM_DUMP_LAYOUT`) and a unit test
(`AppEnvironment.isUnitTest`: XCTest is loaded) read only
`OVERTERM_KUBECONFIG`'s files — a scenario's fake clusters — and without it
none: no contexts, so nothing can start a proxy. The shell isn't asked
there, so an inherited `KUBECONFIG` never comes through, and the setting's
extras are ignored. A file under `~/.kube` (a symlink followed) is refused
twice: when the list is built and when `KubeContextList.load` reads it.
`KubeconfigTests` and the `settings` scenario check it.

**Reading.** `Kubeconfig.parse` reads YAML (or JSON) through `YAMLReader`,
the API client's tree-sitter reader. Overterm only has to tell contexts
apart — kubectl signs in — so the credential keys (`client-key-data`,
`token`, `password`, an auth provider's tokens and secret) are blanked in
the text first (`Kubeconfig.redacted`), and only names, servers,
namespaces and the kind of auth leave the parser (`KubeAuth`: an `exec`
plugin, an auth provider, a token, a client certificate, basic, none). An
exec plugin keeps its command, arguments, the names (not values) of its
env, `apiVersion`, `interactiveMode` and `installHint`: the arguments are
for showing (an `aws sso login --profile` to offer), and `description`
names the plugin alone (`exec: aws`, `exec: kubectl oidc-login`) so none
reaches a log. `Kubeconfig.merged` is kubectl's merge: the first file to
name a context, cluster or user wins, and the current context is the first
file's that sets one. `KubeContextList` holds the resolved contexts (the
cluster's server, the user's auth, the file), kubectl's current context,
the files read and what couldn't be — by path, never a value.

**Classes** (`KubeClassifier`, decision 31), first match wins: a class set
by hand in `kubernetes.contexts`; production by name — the context's or
the cluster's, `prod`, `prd`, `production` or `live` as a word split on
`-_/.:@`, case aside (decision 25), so `…:cluster/acme-prod`,
kubeadm's `kubernetes-admin@prod` and `kind-prod-copy` are production; local by name (`docker-desktop`,
`orbstack`, `minikube`, `rancher-desktop`, `colima`, `kind-…`, `k3d-…`);
else remote. A loopback server never makes a context local: a tunnel to a
remote cluster is on 127.0.0.1 too. `isWritable`: production never by a
setting — only while its writes are on for the session
(`KubeContext.sessionWrites`, Writes below) —, remote only by its
`writable` flag, local unless the flag says no.

**Settings** (Settings ▸ Kubernetes): `kubernetes.enabled` (on; nothing runs
until the page or the panel opens, or an agent calls a `k8s_` tool — which
reads the kubeconfig and starts that context's proxy), `kubernetes.kubeconfigs` and
`kubernetes.pinnedContexts` (lists), `kubernetes.maxProxies` (4), and
`kubernetes.contexts` — one entry per context name, the only place a
context's own settings live (`KubeContextSettings`: `class`, `writable`,
`displayName`, `defaultNamespace`, `accessibleNamespaces`,
`favouriteNamespaces`, `terminalDirectory`, `shells`, `debugImage`, `nodeShellImage`, `nodeShell`; more fields join with the stages that read them).
It is the first `entries` setting: `SettingValue.entries`, written on one
line and edited in place there, its fields checked one by one
(`SettingSpec.fitted`) — a field that doesn't fit is reported and left
out, the rest of the entry kept, so a typo never takes a hand-set
production class with it. The page lists the entries and sends you to
settings.json to edit them. `kubernetes.proxyIdleMinutes` (10) and
`kubernetes.kubectlPath` (empty: found) are the proxies'
(`Settings.kubernetesProxyConfiguration`). `kubernetes.agentAccess` (on)
gives agents the `k8s_` tools (Agents' tools, below);
`kubernetes.agentWrites` (a list, empty: agents only read) names the
contexts whose agents get the write tools while Overterm may write there;
`kubernetes.debugImage` (`busybox:1.36`) is what `E` runs unless the
context names its own (Writes in a tab, below).

**The proxies** (`KubeProxies`, one for the app). Everything Overterm asks a
cluster goes through the context's own long-lived `kubectl proxy --context
C --unix-socket S`, started by its first request (`KubeProxy.open`, a
`ManagedProcess`: ready on kubectl's `Starting to serve on` line, its
socket removed before and after, closed by its pid and at quit) and kept
in a `ManagedProcessPool` keyed by the whole `KubeProxySpec`, so a dead
one is opened again on the next use. kubectl keeps the credentials — exec
plugins, certificates, token refresh — and Overterm speaks plain HTTP on
the socket (`UnixHTTPTransport.kubernetes`: `Host: localhost`, readiness
`/version`).

- **The flags** (`KubeProxyFlags`, decision 12): every proxy refuses
  exec, attach, port-forward and the pod, service and node proxy
  subresources (and KubeVirt's console) with `--reject-paths` — which
  replaces kubectl's defaults, so the list repeats them — and answers only
  `Host: localhost` (`--accept-hosts=^localhost$`); a read-only context's
  (`!KubeContext.isWritable`: production and remote by default) also
  `--reject-methods` every write method, POST included, since a path
  can't tell a permission review from a create. A context that becomes
  writable, or stops being, gets a new proxy with the other flags. No
  kuberc can switch the filters off: kubectl (1.33+) reads `~/.kube/kuberc`,
  whose `defaults` set any flag the command line leaves out, so every
  proxy gets `--disable-filter=false` and runs with `KUBERC=off` (and
  `KUBECTL_KUBERC=false`), whatever the login shell exported. kubectl
  redirects `//api/…` and `/./` before it proxies anything, and decodes
  `%2F` before the filter: `KubeProxyTests` runs the real kubectl (when
  installed) against a server of its own on 127.0.0.1 through a
  kubeconfig of its own and checks that GET passes, every write and every
  listed subresource is 403 on a read-only context, writes pass on a
  writable one while exec stays 403, a wrong Host is 403, and nothing else
  reached the server.
- **The socket** (`KubeSocketFolder`): `/tmp/ot-kube-<uid>-<pid>/`, 0700,
  checked to be a folder (not a link) of this user's; not the support
  folder, where the spike's path was 132 bytes and the bind failed. The
  socket is named by the first 12 hex digits of the context's SHA-256, its
  path checked against the 103 bytes a unix socket has. The folder is
  removed at quit, and a dead run's swept when the next one makes its own.
- **The environment** (`KubeProxyEnvironment`): the login shell's
  (`ShellEnvironment`; `aws` and `kubectl-oidc_login` must be found), with
  `KUBECONFIG` set to exactly `AppEnvironment.kubeconfigs`' files. Guarded
  (an isolated run, a unit test) it is the process's own environment, no
  `AWS_*`, `KUBECONFIG` only `OVERTERM_KUBECONFIG`'s files — never one under
  `~/.kube` — and a cache folder and a `HOME` of the run's own (in the
  socket folder), so nothing under the user's home is read; without those files the
  planner throws `noKubeconfig` before it looks for kubectl or asks any
  shell (`KubeProxyTests`, and the `settings` scenario).
- **Which kubectl** (`KubectlLocator`, decision 22): `kubernetes.kubectlPath`
  if set (it overrides), else `/usr/local/bin`, `/opt/homebrew/bin`, Docker
  Desktop's bundle, `~/.rd/bin`, then the login shell's PATH, one each with
  symlinks followed; once a `/version` answer gave the server's minor, the
  next proxy gets the copy closest to it (`Kubectls` asks each `version
  --client` once). An isolated run uses only the setting.
- **Before it starts** (`KubeProxyPlanner`): a plugin with
  `interactiveMode: Always` needs a terminal the proxy hasn't
  (`needsTerminal`: run `kubectl --context C version` in a tab), and a
  plugin that isn't on the PATH says so with its `installHint`.
- **Slots**: at most `maxProxies`, one always the page's (`setPage`, or a
  `.page` request): background requests use `maxProxies − 1` at most and
  are refused (`noSlot`) when none is idle; the page takes the least
  recently used idle one's slot, else a busy background one's. A proxy no
  request has used for `idleTime` is closed (a sweep every minute while any
  is open); a request or stream in flight keeps it. A request counts
  itself in its context's entry by the entry's id: two first requests
  that wait for a slot share one entry, and one whose entry was closed
  while it waited (another's slot, `retry`, `close`) ends with
  `closedWhileOpening` — a retry may go — and the kubectl that finished
  opening for it is ended, not left uncounted.
- **oidc one at a time**: kubelogin opens a browser and listens on
  127.0.0.1:8000, so a context whose user signs in with it holds a gate
  until its first answer; others wait (`status`: `signingIn` — "Waiting
  for the browser sign-in" — and `waitingForSignIn(behind:)`).
- **Errors** (`KubeProxyProblem.classify`): the server's own errors pass
  through as Status JSON and stay responses; the proxy's own failures are
  a 500 with plain text. "getting credentials: exec: …" stops the
  context's requests — each would run the plugin again (the spike: 1.3–4.6 s
  of `aws` apiece) — until `retry`: for `aws`, "Sign in again: aws sso
  login [--profile p]" (`command`, to run in a tab later); for kubelogin a
  sign-in that timed out or failed; a missing plugin. A dial error is "the
  cluster can't be reached (VPN?)" and doesn't stop anything.

**The client** (`KubeClient`) reads a cluster over a `KubeConnection`: a
context's proxy (`KubeProxyConnection`, through `KubeProxies`) or any
transport (`KubeSocketConnection`: a socket spoken to directly, the
tests'). A read has no method to pass — it is a GET; a write is a path
of its own (`KubeConnection.write`, `KubeClient.write`), refused unless
the connection's context is writable (Writes, below).

- **Discovery** (`discover`, `KubeDiscovery`): aggregated discovery when
  the server has it (always since 1.33) — `/api` and `/apis` asked for
  `APIGroupDiscoveryList`, two requests — else the legacy walk: the core
  version's resource list, then each group's preferred version's, eight
  at a time. A group that is down is noted in `failedGroups` rather than
  thrown: the aggregated list marks an aggregated API that is down
  (metrics.k8s.io's, often) with `freshness: Stale` — that version is
  skipped, the group's next one used, as client-go does — and the legacy
  walk's list answers 503. A kind (`KubeResourceKind`)
  says its group, version, plural, Kind, scope, verbs, short names and
  subresources (legacy's `pods/log` folded into `pods`); `kind(_:)` finds
  one by any of kubectl's names (`po`, `pod`, `Pod`, `deploy`,
  `deployments.apps`), the core group first, as kubectl resolves `events`.
- **Lists are Table rows only** (`list`): `Accept: application/json;as=Table;
  v=v1;g=meta.k8s.io, application/json` and `includeObject=None` — the
  spike's 2886 pods were 885 KB that way, 35 MB with the default metadata —
  paged with `limit=500` and `continue`; an expired `continue` (410) lists
  again from the start. Selectors go to the server. Across all namespaces
  a namespaced kind's rows carry their metadata (`includeObject=Metadata`,
  `KubeClient.includeObject`): no core kind's Table has a Namespace column
  — `kubectl get -A` adds it from the metadata — and with rows only, two
  pods called `postgres-0` in two namespaces would be one row, a DELETED
  for one removing the other. In one namespace the request's is the
  row's, and rows stay cells only. `KubeTableReader` reads
  a Table (columns with their `priority`: 0 is the default view, the rest
  `-o wide`'s; `format: name` the identifier) or, from an API without
  Table support, a plain List as Name and Created At. A row
  (`KubeRow`) is known by its namespace and name (`KubeRowID`): a
  Namespace column (a CRD's printer column may have one), else the
  embedded metadata's, else the request's.
  `KubePodSummary` reads a pod's Ready, Status and Restarts cells
  (`7 (2m ago)` since 1.22) into whether it is ready, failing and why
  (`CrashLoopBackOff`, `OOMKilled`, `Init:…` said as the init container's).
- **One object** (`object`) is one plain GET, whole, when its detail opens.
  **Its events** (`events`) are the core Events `kubectl describe` lists,
  picked by the server: `fieldSelector=involvedObject.name=…,namespace=…,
  kind=…,uid=…` in its namespace, across all of them for a cluster-scoped
  object (a node's are in `default`), plain JSON (`KubeEvent.list`:
  newest first — last seen, a series' last, `eventTime` —, warnings
  marked).
- **Following a list** (`follow`) is the informer's loop, as
  `KubeFollowUpdate`s a `KubeRows` applies: `.listed` (the whole list),
  then the watch from the list's resourceVersion (`watch=1`,
  `allowWatchBookmarks`, `includeObject=None`, `timeoutSeconds` 5–10
  minutes at random) — `.changed` rows, `.bookmark` where it has got. A
  watch on a Table sends `columnDefinitions` in its first event only, so
  `KubeWatchDecoder` keeps the list's headers for the rest. A watch the
  server ends is watched again from the last resourceVersion, not listed;
  a 410 — an in-stream `ERROR` event or the watch's answer — lists again.
  With `streamingLists` (1.32, 1.34+: `servesStreamingLists`) the first
  list is a watch with `sendInitialEvents`, its ADDED events the list until
  the bookmark annotated `k8s.io/initial-events-end` (another bookmark
  before it only moves the version on); one cut before that end is listed
  and watched instead, as is a server that refuses it (422, the gate off).
  A list without a resourceVersion (metrics.k8s.io's, which has no watch)
  is listed again every `unversionedPoll` (30 s), never watched from "".
  A 429 or the server's 5xx — on the list, as the watch's answer or in
  the stream — is `.retrying` and tried again from where it got: after
  the `Retry-After` (10 s at most), else backing off. A watch that ends at
  once, again and again, waits longer each time (to `maxBackoff`).
- **Errors**: a proxy's own 500 in plain text is `KubeProxyProblem`
  (`classify`, with the connection's `KubeSignIn`: an expired AWS session
  is "aws sso login --profile p"), and a follow ends at it — no retry runs
  the plugin again; the server's own Status is `KubeAPIError` (status,
  reason, message); a 429 is retried after its `Retry-After`, three times.
  A stream's error keeps its answer whole (`HTTPError.response`: the
  `Content-Type`, the Status, the `Retry-After`), so a watch's JSON 500 is
  the server's `KubeAPIError`, not the proxy's plain text.

**The fake** (`FakeKubeAPI`, `Sources/`, for the tests and the scenario):
an API server on a unix socket of its own and on 127.0.0.1
(`listenTCP`, for a real `kubectl proxy` in front of it), holding objects
of any kind it serves as values versioned as the server versions them —
pods (`addPod`), and with `add`/`update`/`delete` deployments, services,
configmaps, secrets (a Table row of Type and how many keys; only a plain
GET carries `data`), nodes, events — and with `fields` (or `setFields`)
the rest of an object as a GET answers it (`spec`, `status`,
`metadata.ownerReferences`, merged over a pod's own), and `addEvent`, a
core Event about an object by its Kind and uid — each in the columns `kubectl get`
shows (`columns(for:)`, priority 1 for `-o wide`'s; an event's Name is a
wide column, `format: name`). `addCRD` serves a new kind from then on, in
both discoveries and in paths, with its `additionalPrinterColumns`, and
adds the CRD itself (ADDED to CRD watches); `removeCRD` takes the kind away
(a 404 after), ends its watches and DELETEs the CRD. One version a group:
a group's kinds are served at its first kind's. It also serves kinds that
can't be listed and watched (`componentstatuses`, `bindings`,
metrics.k8s.io's), for the page to leave out. It answers
`/version`, both discoveries (`aggregatedDiscovery`; `failingGroups`
`Stale` in the aggregated list, 503 in the walk),
lists as Tables (`includeObject` None, Metadata or Object) or plain JSON,
paged (`expireContinueTokens`), with a field selector on any dotted path
of the object (`involvedObject.uid=…`), one object, and watches: replayed from a
version, sent as `addPod`/`updatePod`/`deletePod` change things,
`bookmark()`, a 410 for a version before `compact()` (in the stream, or
as the answer with `goneAsAnswer`), `expireWatches` (an in-stream 410),
`endWatches` (the server's timeout), `sendInitialEvents` (refused with a
422 without `streamingLists`; `interimBookmarks` puts a plain bookmark
among the initial events). `unversionedLists` answers lists without a
resourceVersion. A pod's log (`appendLog`, `setLog`; `previous` for the
last terminated instance's) is served at `pods/{p}/log` as the API serves
it — `container` (a 400 without one when the pod has several, or for one
it hasn't), `previous` (a 400 when it never restarted), `timestamps` (nine
digits of fraction), `sinceSeconds` or `sinceTime` (whole seconds),
`tailLines` — and with `follow` kept open, a line appended written to it;
`dropLogStreams` closes the follows mid-stream (a network blip),
`endLogStreams` ends them as the server does, and a pod deleted ends its
own. It serves EndpointSlices too (`discovery.k8s.io`, a forward's). A pod can have init and ephemeral containers, declared ports (`ports`), its first container
ended (`terminatedReason`), env. `failCredentials` makes every answer the proxy's 500 in
plain text, `throttle` 429s, `failWatches` answers the next watches with a
429 or a 5xx. What a test sets is behind the fake's lock, as its state
is. It records every request
(method, path, query, Accept), so a test shows that no write method and
no subresource reached it, and which kinds are watched (`watched`)
(`writes`, `subresourceRequests` — a
Namespace's own `finalize` and `status` included; a pod's `log`, the one
Overterm reads, is `isLog`); it has no
exec, attach or port-forward. `KubeClientTests` checks all of the client
against it — every test ends by asserting only GETs arrived — and runs
the real kubectl (when installed) as a read-only context's proxy in
front of it through a kubeconfig of its own: discovery, a list, a followed
change and a 410 pass through. A unit test also shows the app's own
proxies reach nothing from a unit test: no kubeconfig, so no kubectl.

**The model** (`KubernetesModel`, one for the app, as `DockerModel` is):
the contexts, the one the page shows and its namespace, that context's
pods, how its proxy stands. Each window's page holds it while it shows in
a window on screen (`show`/`hide`, counted, through
`updateKubernetesPageHold` — the emitted visibility, since
`showingOverlay` isn't set yet); nothing is read until then — not the
kubeconfig, not a cluster — and the last `hide` ends the watch and the
status poll (a proxy is left to its idle close, so coming back needs no
new sign-in). The kubeconfig is read on a GCD thread
(`KubeContextList.fromEnvironment`, so `AppEnvironment`'s guard holds)
each time a page first shows, and again when `kubernetes.kubeconfigs` or
`kubernetes.contexts` change while one does; the model follows
`kubernetes.*` itself, and `kubernetes.enabled` off stops everything and
closes every proxy. The context shown is the one it showed, else the
one last picked (remembered in `AppEnvironment.defaults`), else the first
pinned, else kubectl's current, else the first (`choose`); its namespace
is the one last picked for it, else `defaultNamespace`, else the
context's own, else `default`, as kubectl has it (`defaultScope`); `0`
is all of them. The list is `KubeClient.follow(kind)` of the kind shown
(`kind`, Pods until another is picked — `setKind`; the app's, as the
scope is) over the context's `KubeProxyConnection` (a test's or the
scenario's stand-in connection through `connectOverride`): the first list is applied at
once, the watch's changes in batches every `flushInterval` (120 ms), one
published change each; a `.retrying` says so while the rows stand, and
a failure (a `KubeProxyProblem`, a 403) is the list's state with its
reason and, for a sign-in, the command to run. The server's version,
what it serves and the namespaces (the context's `accessibleNamespaces`,
else the server's list; a 403 means one is typed, `namespacesRefused`)
are read once a context is picked.

- **What a context serves** (`discovery`, and `catalog`, below) is kept
  per context (`discoveries`) for `rediscoveryInterval` (5 minutes): back
  on a context within it, nothing is read again, and the kind shown is
  taken as that context serves it — at its version there — else Pods.
  Discovery read again moves the kind with it: another version (or scope)
  is followed there; one no longer served stops the list, saying so. What
  was read for a context is kept only while its name reaches the same
  cluster (`sameCluster`: server, cluster, user, sign-in): the kubeconfig
  read again with a name pointing elsewhere drops it.
- **CRDs without a reconnect** (decision 28). While a page shows, the
  context's CustomResourceDefinitions are followed (rows only, cluster
  scope) where discovery says they can be listed and watched: their first
  list naming one discovery hadn't, a later change, or a list again after
  a 410 that differs, reads discovery again — once a burst
  (`rediscoveryDelay`), and the kind shown listed again when its own CRD
  changed (its printer columns). Where the watch is refused (RBAC) or the
  CRD kind isn't served, discovery is read again every
  `rediscoveryInterval` instead. And a 404 for the kind followed reads it
  again once (`lookedUpAfter404`, cleared by the next list): gone, the
  list says so (Pods too, when discovery has none); at another version, it
  is followed there. Hidden, the CRD
  watch ends with the rest. `selectors` (`KubeListSelectors`: a
`labelSelector` and a `fieldSelector`) are what the list is asked for with
(a page's `label:` and `field:` words), the list and its watch: set to
something else, the list is asked for again with them. They belong to the page that asked last
(`selectorOwner`): the list is the app's, and two windows can show the
page at once, so the one that asked last has it and the other says so
(`listIsOurs`, a line over its list), and a window becoming key asks
with its page's filter. A page that hides gives it back
(`releaseSelectors`) and a hidden one asks for nothing, so the ⌃⌘J
switcher, or another page, never gets a list narrowed by a filter not on
screen; the last `hide` drops it, and a page held again asks anew. The
proxy's state (`KubeProxies.status`: open, signing in, waiting behind
another context's browser sign-in, stopped with its reason) is asked
once a second while a page shows. The model reads only; it holds
production's switch for the session (`productionWrites`) and the writes'
access reviews (`writeAccess`), and the page's guard path writes.

**Ages** (`KubeAge`, pure). The server renders Age when it answers, so a
cell is stale once it arrives. A row across all namespaces carries its
metadata (`KubeRow.created`, from the embedded `creationTimestamp`) and
its age is that one's; with rows only (one namespace) the cell is all
there is, so the age is what it said (`seconds` reads kubectl's
`2d3h`) plus the time since the row came (`Anchor`, kept per row as
rows arrive and change). `format` is apimachinery's `HumanDuration`.
Each visible Age cell is a `TimelineView` a second apart — a cell
scrolled away isn't drawn, so only the visible ones are recomputed.

**The page** (⌥⌘J, `kubernetes.page`; `WorkspaceOverlay.kubernetes`,
declared as a `WorkspacePage` in `TerminalWindowController+Kubernetes`):
`KubernetesPageModel` (a window's: section, filter, selection, sort,
`wide`, the pickers, the `:` bar, the keys) and `KubernetesPageView`. Left: the contexts, each
with its class's colour and kubectl's current marked, the namespace
menu (all, the favourites, the server's list, Other… for the `n` picker), the sections
(each with its digit and how many kinds it has; the one showing open on
its kinds, custom resources under their API group) and the context's card (class, writable or
read-only, how it signs in, its server). Middle: the kind's list as a
`ResourceTable` of the server's columns — those `kubectl get` shows for
it (a CRD's printer columns), `-o wide`'s too with `w`, a namespaced
kind's Namespace first across all of them as `kubectl get -A` adds it
(a cluster-scoped kind has none, its count "cluster-wide"); on Deployments,
whose Table has no Status, a Status of the page's before Age
(`KubeDeploymentHint`, pure, off the row's Ready, Up-to-date and Available:
Available, Rolling out 1/3, Unavailable 0/1 in red, Not ready, Scaled to 0
— the conditions aren't in a row; the detail's Rollout says why) — sorted by any column (numbers as numbers, ages
— `Age`, or a CRD's `Created At` — by age) or by namespace and name, filtered by text (the name, the
namespace, the Status — or that hint, or Type — cell), `status:`, `ns:`,
`label:`, `field:` and `-` (`KubeFilterKey`, through `ResourceFilter`). A row is
only cells — no labels, no fields — so `label:` and `field:` words are the server's:
`KubeLabelSelector` reads them as typed (labels are case-sensitive) into
the list's `labelSelector` — `label:app=web`, `app!=web`, `-label:app`
(`!app`), `label:a=1,b=2` — refusing what the server wouldn't take (a
negated pair, a bad key) and saying so; `KubeFieldSelector` reads `field:`
words into its `fieldSelector` as `kubectl get --field-selector` takes
one — `field:status.phase=Running`, `field:spec.nodeName==fake-node-1`,
`-field:status.phase=Running` (`!=`), several with commas — refusing what
has no operator (a field has no "exists"), a negated pair, a bad path or
a value with the grammar's own characters; which fields a kind takes is
the server's to say, its 400 said over the list (every kind
`metadata.name` and `metadata.namespace`, pods `spec.nodeName`,
`status.phase`…). The list is asked for again once
the typing stops (`selectorDelay`, 350 ms) or on ↩, and the page says what
went to the server (`label app=web, field status.phase=Running`). The rest of the filter matches the rows that came. On the Pods list a failing pod's
Status is its reason in red (`KubePodSummary.exitReason`:
`CrashLoopBackOff`, `OOMKilled`, `… (init container)`), and the header
counts the failing ones. Bottom: the context bar — the proxy's state,
the server's version, a stopped context's reason with Try Again and the
command that signs in again (in a terminal tab), the class. On a
production context a red band runs across the top of the whole page,
above the sidebar and the list, with the context's name, and its card is
edged in red. The empty states: Kubernetes off (Settings ▸ Kubernetes),
no kubeconfig (an isolated run says only OVERTERM_KUBECONFIG's file is
read; what couldn't be read is listed), loading. The list keeps its
place in the view tree through all of them — loading, empty, failed lie
over it — so a keyboard given to it finds it; a table with no columns
refuses the keyboard, so when the server's columns come the list takes it
if nothing else has it (`offerListTheKeyboard`). The keys
(`KubernetesKey`, through `ResourceKey`, while the list has the
keyboard): `1`–`7` the sections, ↩ the detail, `[` `]` back and forward,
Esc closes it, `:`, `n`, `c`, `w`, `0`, `k`, `/`, `?`, `l` a pod's logs (↩ on a pod is them too), `f` and `o` a forward,
`9` the Forwards section. The right-click menu
only copies — names, Copy as kubectl, Copy List as kubectl, Copy Rows as
TSV or CSV — and exports the list, and has the object's writes, each
greyed with why where it can't be done (Writes, below).

**Copy as kubectl** (`k`, the right-click menu, the header's and the
detail's buttons; `KubectlLine`, pure, docs/design/kubernetes/analysis.md
3.14): the command that shows what the page shows, always with
`--context`, offered on every class — a copied command is the user's to
run. `k` copies the selected rows' (a line each, in the list's order),
else the list's: `kubectl --context fake-dev get deploy -n shop -l app=web
--field-selector status.phase=Running` (`-A` across all namespaces,
nothing for a cluster-wide kind, `-o wide` with `w`; the filter's text
words have no kubectl twin and are left out). An object's is `kubectl
--context C -n NS get deploy NAME -o yaml`; on the detail's Events tab,
`kubectl --context C -n NS events --for deploy/NAME` (`events -A` for a
cluster-wide object's: `-A` is the command's own flag, after it, where
`--context` and `-n` are global). The kind is said as kubectl resolves it
(`resource`): a core kind by its short name (`po`, `svc`), a built-in
group's by its short name or plural where no other kind served claims it
(`deploy`), else `plural.group` (`events.events.k8s.io`, every CRD's).
Every word not ours is quoted for zsh: bare only for letters, digits and
`_ . / : @ + , - =` (no `=` or `-` in front), else single-quoted, where zsh
expands nothing — `'app!=web'`. A command never holds a Secret's value: a
Secret's is `kubectl describe secrets NAME`, which prints its keys' sizes
as the masked detail does, never `-o yaml`.

**CSV** (View ▸ Export Kubernetes List as CSV…, `kubernetes.exportCSV`,
no key by default — ⇧⌘E is Tab Peek's; the header's button, the
right-click menu, the palette; `KubeListExport`, pure): the columns the
list shows, the rows its filter lets through in its order, each cell as
drawn (an age as it reads now, a failing pod's reason), to a save panel
named `<context>-<namespace|all>-<plural>.csv`. RFC 4180 through
`ResultExport`, and a cell a spreadsheet would run as a formula (`=`, `+`,
`@`, a tab or a carriage return in front; `-` unless a number) prefixed
with `'`. An isolated run shows no panel: it writes into its own support
folder's `Exports` (`kubernetesExportFolder`). A write that fails is
said — an alert on the window, and the page's `exportProblem`, which the
scenario checks. **Copy Rows as TSV or CSV** (the right-click menu, the
palette; `copyRows`): the same columns and cells on the pasteboard, TSV
for a spreadsheet's paste — the right-clicked rows, else the selected
ones the filter shows, else every row it shows.

**The sections** (`KubeSection`, `KubeKindCatalog`, pure): Workloads,
Network, Config, Storage, Access Control, Cluster, Custom Resources — the
digits `1`–`7` (Overview, Helm and Forwards join with their stages). Each
names the built-in kinds it shows, in order (`named`, by full name); of
two that are one Kind the first served shows (`events.events.k8s.io`
rather than the core `events`). Cluster also takes Kubernetes' own kinds
no section names, by title; every kind of a group that isn't Kubernetes'
own (`isBuiltIn`: the core, `*.k8s.io`, `apps`, `batch`, `autoscaling`,
`policy`, `extensions`) is a custom resource, by group. Only a kind that
can be listed **and** watched is offered (`isOffered`): a list here is
kept live, so metrics.k8s.io's, `componentstatuses` and `bindings` aren't.
A kind's title is its plural Kind (`NetworkPolicies`, `Ingresses`;
`HPAs`, `PVCs`, `CRDs`). A digit shows the section's kind last shown,
else its first; a section with none to show (discovery not read yet, no
CRDs) says so over the list (`waitingForSection`) and takes its first
kind once it has one — a CRD added while it shows. The section follows
the kind, whoever picked it (another window, the switcher).

**The `:` bar** (k9s's; `KubeCommand`, `KubeKinds`, `KubeCommandBar`, pure,
and `KubeCommandBarView`): `:<kind>[ <namespace>|all|-A][ /<filter>][ <label=value,…>][ @<context>]`
— `:deploy`, `:po shop`, `:svc @fake-dev`, `:widgets /blue`,
`:po globex /api app=web @globex-eu-west-1-dev`; `:ctx` and `:ns` open
their pickers, or switch with a name. The filter runs from its `/` word to
the next `label=value` or `@context` word (its own words, `status:…`,
`label:…`, have a colon). A kind is any of kubectl's names
(`KubeDiscovery.kind`: plural, singular, short names, Kind,
`plural.group`; the core group first) or k9s's aliases discovery lacks
(`dp`, `sec`, `jo`, `np`, `cr`, `crb`, `rb`, `ro`) — and, of two built-in
kinds that are one Kind, the one the catalog offers (`ev` is
events.k8s.io's, as Cluster shows it). The completions follow the word
being typed: a kind (exact names first, then prefixes, then the rest that
contain it; `ctx` and `ns`; a plural two kinds share completes to each
one's `plural.group`), a namespace after it, a context after `@` (after
the filter too). ↑↓ move, Tab completes (`PaletteField.onTab`), ↩
completes a word that isn't whole and runs. All of the command is checked
first — the context named, the kind (as that context is known to serve
it, else as the one shown does), the namespace — and only then is it
done: the context, the kind, the namespace, the filter (`label=value`
words become `label:`). A typo switches no context, so nothing is asked of
one named with it. What can't be done is said in the bar, which stays;
Esc closes it and the list has the keyboard again.

**The pickers** (`n`, `c`; `KubePicker`, pure, and `KubePickerView`): a
field over the page and the namespaces or contexts it lets through,
ranked by `FuzzyMatch` as the palette is (the field is the palette's
`PaletteField`: ↑↓, ↩, Esc). Namespaces: all of them first, the
context's favourites, its own (or `defaultNamespace`) and the one showing,
then the server's list (or `accessibleNamespaces`); a name typed in full
(RFC 1123, lowercased) is one more item when nothing listed is it — first
where listing is refused (a context that carries a namespace often
means its user is held to it), with the reason shown. An open
picker follows the namespaces listed after it opened, what is typed kept.
Contexts: each with its class, read-only or not, kubectl's current,
production in red; none is typed. ↩ is `setScope` or `select`, and the
list has the keyboard again.

**The detail** (`KubeDetailSession`, `KubeDetailView`; Docker's container
detail is its pattern): beside the list, opened by ↩ on the selected row
or a plain click on one (`ResourceTable.pressed`), and once open it
follows the list's one selected row. A `KubeObjectRef` (context, kind,
namespace, name) is what it shows; it reads that object with one GET as
it opens — nothing is watched — and drops the session, and all it read,
when it moves on. A Secret is never asked for by the detail (`isSecret`,
and an answer that is one is dropped): its object is every value at
once, so only its Show reads it (**Secrets**, below); its events are read
as any object's. Its tabs (and a pod's Logs, below):
- **Overview** (`KubeOverview.of`, pure, from the object's JSON alone):
  facts at the top and sections, tailored for Pods (phase, the reason,
  the node as a link, IPs, QoS, each container — init and ephemeral too —
  with its image, state, restarts and how it last ended: `OOMKilled (exit
  137)`), Deployments, StatefulSets, DaemonSets and ReplicaSets
  (desired/ready/updated/available, strategy, selector, images, and the
  rollout), Services (type, cluster IP, external addresses, ports,
  selector), Nodes (ready, roles, version, instance type and node group,
  system, capacity · allocatable, taints), Jobs and CronJobs (active jobs
  as links), Ingresses (each rule to its Service, as a link; TLS),
  ConfigMaps (keys and values — they are not secret), PVCs, PVs and
  Namespaces; and for every kind the object (namespace, created, deleting,
  finalizers, uid), its owners as links, its status conditions where it
  has them (a node's pressure conditions are bad when True), labels and
  annotations — the last-applied one left out. A selector (a workload's,
  a Service's, a Job's; `KubeSelector`: `matchLabels`, `matchExpressions`
  as `in`/`notin`/`!key`) lists the pods it picks once the Overview
  shows: one list, rows only, each a link.
- **Rollout status** (`KubeRollout`, pure) is `kubectl rollout status`'s
  own reading: the spec observed (`generation` ≤ `observedGeneration`),
  then for a Deployment its Progressing condition —
  `ProgressDeadlineExceeded` is stuck, said in red — and updated, old
  and available replicas against those wanted; a paused one says so; a
  StatefulSet's ready replicas, its partition and revisions; a
  DaemonSet's scheduled and available pods; `OnDelete` isn't tracked.
- **YAML** (`KubeYAML`, `KubeObjectStrip`, pure): written as `kubectl get
  -o yaml` writes it — keys sorted, as kubectl's go through a map,
  sequences under their key unindented, a string quoted only where YAML
  1.1 would read it as something else (`"true"`, `"0123"`, `"1.0"`,
  `": "` inside), several lines as a `|` block. Without
  `metadata.managedFields` and the last-applied annotation by default; a
  toggle shows them. A container's env value whose name looks secret
  (`DB_PASSWORD`), or a URL's password, is masked on any kind, as
  Docker's inspect masks them (`DockerSecrets`); a `secretKeyRef` is only
  a name. A Secret's — after Show — has its `data` and `stringData`
  masked and its last-applied never shown, whatever the toggle; before
  Show its YAML says it comes with the values, with the Show button. Read-only, in
  Docker's text view, keys brighter than values; Copy.
- **Events**, asked for once the tab shows (Refresh again), newest first,
  a warning marked with how often it came.

**A pod's logs** (stage 1c; `KubePodLogSession`, `KubePodLogSource`,
`KubePodLog`, `KubePodLogsView`): a pod's detail has a Logs tab, opened
by `l` on a selected pod or ↩ on one (the design's Section 7: a pod's ↩ is
its logs; a click keeps the tab shown; another kind's detail has no Logs
and opens on its Overview). Through the shared pieces (Logs, above): a
`LogFollower` over the pod's `KubePodLogSource` into the session's
`LogFeed`, in the shared `LogsPane`.

- **Which container** (`KubePodContainers`, pure): the one the
  `kubectl.kubernetes.io/default-container` annotation names if the pod
  has it, else its first container, as kubectl picks; the picker lists
  the containers, then the init and the ephemeral ones, marked. Previous
  (the last terminated instance, `previous=true`) is offered once the
  container restarted — read whole, not followed. Since (5m, 1h, 6h, 24h,
  all) is `sinceSeconds`.
- **The request** (`KubeLogQuery`, pure) is a GET of `pods/{p}/log` like
  any other, through the context's proxy: `container`, `follow=true`,
  `tailLines` (500) and always `timestamps=true` — the resume and the
  ordering need them; shown or not is the view's. Its bytes are lines
  (`KubeLogText.Splitter`) parsed on the cooperative pool
  (`KubeClient.logs`; once, `logLines`).
- **Resume**: a follow ends — the server's timeout, a dropped connection,
  the proxy restarting. The source then decides (`followsAgain`): the
  server refused the log (a 400 but "waiting to start", a 403) or a
  credential failure stops it, said; else the pod is read again (300 ms,
  backing off to 5 s, a blip asked again): running, it is followed again
  with `sinceTime` = the last line's second (`metav1.Time` is whole
  seconds there), and the follower drops what it showed (same time and
  text); waiting (a back-off, a restart) it waits, saying so; gone (404),
  or the container ended for good (`KubeLogResume`, pure: the pod
  Succeeded or Failed, `Never`, `OnFailure` after a success, an init or
  ephemeral container), it stops and says why.
- **Older lines on scroll-up**: the API has no offset, so scrolled to
  the top the log is asked for again with twice the tail (up to 5,000,
  the feed's cap) and what that answer has before the first line shown
  (`KubeLogText.older`: where the shown lines start in it, their first
  lines matched) is put in front; fewer lines than asked is the log's
  start, and nothing more is asked.
- **Options kept per window** (`KubernetesPageModel.logOptions`,
  `logSince`): wrap, timestamps, newest first, the search as a regular
  expression or marking matches, how far back. Save As writes the lines
  shown under `<pod>-<container>[-previous]-<yyyyMMdd-HHmmss>.log`
  (`KubeLogText.fileName`) — a save panel; an isolated run writes into
  its own `Exports` folder. Copy as kubectl on the tab is `kubectl
  --context C -n NS logs POD -c CONTAINER [--previous] [--since=1h]
  [--timestamps]` (`KubectlLine.logs`).
- **⌘L** on picked lines (`askAboutLogLines`): whole lines, scrubbed
  (`KubeLogScrub`, pure) of the pod's own env values whose names look
  secret, a URL's password (`Secrets.scrub`), bearer tokens, JWTs,
  PEM blocks' bodies, AWS keys, a kubeconfig's `token:` and
  `client-key-data:`, `password=`-style pairs, base64 blobs
  (`Secrets.scrubCredentials`) — then the Ask Agent sheet
  with the pod they come from and the command that reads them.
- **Reading only while it shows** (`updateLogsReading`): the tab shown,
  the page on screen, its window on screen. Another tab, the page
  hidden, the window off screen close the stream; shown again it is
  resumed from its last line. The detail closing or moving on (the
  arrows), and another context, end it (`KubeDetailSession.cancel`).

**Secrets** (rule 9; `KubeSecretSession`, `KubeSecretView`, `KubeSecret`,
`KubeCertificate`). The list is the server's Table — Name, Type, Data (how
many keys), Age — rows only, and across all namespaces the embedded
metadata, of which a row keeps only the namespace and creation time, so
the last-applied annotation (which can hold every value) never stays.
The detail reads nothing until Show: its Overview says what the row said
(type, how many keys) and offers Show, as its YAML does. On a production
context — or one the kubeconfig no longer names — the first Show of
each context asks first, inline, naming it (`KubeSecretConsent`, the
app's, in memory until quit; Cancel asks again next time). Show is
the one GET (`KubeClient.secret`), taken apart at once (`KubeSecret.read`):
the object with every `data`/`stringData` value `***` and the
last-applied annotation gone is what the Overview and the YAML show; the
keys come with their decoded lengths; the decoded values stay in the
session alone; an answer that isn't a Secret is said without what it
said. A TLS Secret's `tls.key` is counted from its base64, never decoded,
revealed or copied ("private key · never shown"). Each value is masked
— `•••••••• · 17 bytes` — and revealed one at a time (another revealed
masks it; binary as base64), not selectable; Copy copies one, on the
pasteboard with nspasteboard.org's concealed and transient markers. Its
values are dropped — released, not zeroed (the response and the strings
made of it are Foundation's copies), the keys, the certificate and
the request in flight with them, the detail back to Show with why — when
the detail moves on or closes (`KubeDetailSession.cancel`), the page hides
or its window goes off screen, the context changes (the detail goes), on
Hide, and `timeout` (2 minutes) after Show, a reveal or a copy. A TLS
Secret's `tls.crt` is read (`KubeCertificate`, pure: PEM's `CERTIFICATE`
blocks only, a DER reader of its own, bounded by its bytes): subject,
issuer (self-signed said), SANs (DNS, IP, email, URI), not before and
after, CA, how many more are in the chain, and valid, expiring within 30
days, expired or not yet valid. Nothing logs a value, nothing printable
holds one (`KubeSecretRead`'s description is its keys), and nothing of it
is written, saved with the session or given to an agent.
`KubeSecretTests` pins it; the fake's TLS Secret uses
`FakeKubeAPI.testCertificatePEM`, a public self-signed certificate (no
key in the repository).

A link (`KubeLink`: `apiVersion`, Kind, namespace, name — as references
are written) is resolved by the context's discovery (`kind(apiVersion:
kind:)`: the reference's version where served, else the group's); a kind
it doesn't serve is said over the detail. **History** (`KubeHistory`,
pure, the page's): back and forward across resources and kinds, as a
browser keeps it — a link followed is a visit of its own, while walking
the list replaces a visit that came from the list, so the arrows don't
pile up history; closing the detail keeps the way back (`[` shows it
again); another context clears it, its objects not being this one's. `[`
`]` while the list has the keyboard, ⌘[ ⌘] while the page shows and no
text is being typed (`WorkspacePage.commandPress`, before the menus,
whose ⌘[ is Previous Pane — theirs again with nothing behind), and the
detail's chevrons.

**Terminal in this context** (stage 1d; `KubeTerminal.swift`,
docs/design/kubernetes/analysis.md 3.11): a terminal tab whose plain
`kubectl` (`helm`, `k9s`) goes to a context, the user's current context —
every other tab's — never changed. It is the user's own kubectl with the
user's rights, so read-only doesn't reach into it; the pin and the
production band are its guard.

- **The pin** (`KubeTerminalPin`: the context, its cluster and user by
  name, the namespace — the one asked for, else `defaultNamespace`, else
  the context's own —, production or not, the files after it) is the
  pane's (`TerminalView.kubePin`, with the `environment` its shell was
  given over the app's own, through libghostty's `env_vars`); a split of
  the pane gets both. A pane moved into another tab keeps its own, so a
  tab's panes may differ: `Tab.kubePin` is the focused pane's, and the
  strip says `KubeTabBadge` (pure) — one context, `⎈ mixed` (red when any
  pane is production or unpinned: that one reaches the current context),
  or `⎈ pin lost`. Each pane is saved with its own (`TabState.kubeContext`
  for a one-pane tab, `paneKubeContexts` in reading order for a split;
  names and paths only; an older file's one pin goes to every pane).
- **Restored** (`KubeTerminalRestore`, pure but for the file it writes):
  each saved pin is looked up again by name in Overterm's kubeconfigs as
  they are at launch (`kubernetesRestoreList`: `AppEnvironment.kubeconfigs`
  with `kubernetes.kubeconfigs` and the current `kubernetes.contexts` —
  guarded, only `OVERTERM_KUBECONFIG`'s; read only when a pane was pinned,
  blocking, since the shell can't start before its `KUBECONFIG` is known)
  and pinned again from that: today's files, cluster, user and class (a
  context made production since comes back with the band), the saved
  namespace. A context gone, no kubeconfig, a file that can't be written:
  the pane comes back **lost** (`KubeTerminalLost`) — `KUBECONFIG=/dev/null`,
  which reaches no cluster, its header `⎈ <context> — pin lost` in red
  (`KubePinLostLabel`), the page's `terminalProblem` saying why — never a
  plain shell to the current context; saved again as it was, tried again
  on the next launch. A production pin restored isn't asked again: it was
  confirmed when opened, and it comes back with its band.
- **Followed** (`KubeTerminalFollow`, pure over the list;
  `followKubernetesPins`, the window's): a `use-context` or `set-context
  --current --namespace` typed in the tab rewrites the pin's file, so the
  pins' folder is watched (`DirectoryWatcher`, from the first pinned pane)
  and each pinned pane's `KUBECONFIG` is read again as kubectl merges it
  (`KubeContextList.load`: the first `current-context`, the first entry
  naming it) when a file changes and when the contexts do (a class set in
  Settings): its label, band and the strip follow, and the session saves
  what it reaches now. An unset `current-context` falls to the user's own
  — production here — and says so.
- **The file** (`KubeTerminalConfig`, pure; `KubeTerminalFiles`): in
  `AppEnvironment.supportDirectory`/Kubernetes/Contexts (0700), one a tab
  — `<the context's SHA-256, 12 hex digits>-<the tab's id>-<Overterm's pid>.yaml`,
  opened 0600 with `O_NOFOLLOW` — holding `current-context` and the
  context's own entry naming the user's cluster and user (empty when the
  user's entry names none — the entry is always written: without it the
  namespace is lost and a `set-context` writes the user's file) with the
  namespace: kubectl
  takes the first `current-context`, and a context entry whole from the
  first file naming it, so the entry repeats the user's names; the server
  and the credentials stay in the user's files. A `use-context` or a
  `set-context --namespace` typed in the tab writes this file, never the
  user's. Names are YAML double-quoted (an ARN's `:` and `/`). None is
  removed while its Overterm runs (a moved pane keeps its `KUBECONFIG`; a
  missing first file would send kubectl to the current context): before a
  run writes its first, only the files whose pid no longer runs go —
  another Overterm on the same folder (a dev build beside the installed
  one) keeps its own. In a unit test's process the default folder is a
  temporary one (`KubeTerminalFiles.defaultFolder`): `supportDirectory`
  is the user's real one there.
- **The environment** (`KubeTerminalEnvironment`, pure; `KubeTerminalLaunch.prepare`):
  only `KUBECONFIG` — the pin's file, then exactly
  `AppEnvironment.kubeconfigs`' files (the proxies' list), in order, a
  repeat dropped. Guarded (an isolated run, a unit test) a file under
  `~/.kube`, or none at all, is refused before anything is written.
- **Where** (`KubeTerminalDirectory`, pure): the context's
  `terminalDirectory` (`kubernetes.contexts`' field, `~` allowed) when it
  is a folder, else the checkout bound to the context (stage 3a), else
  home.
- **Opened from** (`openKubernetesTerminal`, the window's; the page's
  `KubernetesActions.openTerminal`): the context card's "Terminal in This
  Context" and a context's right-click (the namespace shown), a row's verb
  menu (`terminalVerb`: the row's namespace; a Namespace row, that one),
  the palette (`Terminal in <context>` for every context, and the page's
  command), View ▸ Terminal in Kubernetes Context… (`kubernetes.terminal`,
  no key: the switcher with its query). On production it is asked first,
  naming the context and namespace. The page steps aside for the tab.
- **What it shows**: the tab is a Kubernetes one (`TabKind.kubernetes`,
  the helm glyph, unless an agent, a container, a pod or ssh), with `⎈ <context>`
  after its title on every tab; the pane header's label is `⎈ <context> ·
  <namespace>` (`KubePinLabel`), and on production "PRODUCTION …" white on
  the page's red with a red band under the header; the tooltip says what a
  plain kubectl there reaches.
- **Checked** (`KubeTerminalTests`): the file's content (no credential, no
  server), quoting, its name, 0600 and 0700, never through a link, the
  sweep, `KUBECONFIG`'s order, the guard, the namespace's precedence,
  the folder, the tab's kind, the session; a restore whose kubeconfig or
  context is gone (lost, `/dev/null`, never a plain shell), one whose
  class or files changed since (today's), the pin following a rewritten
  file, a moved pane (`mixed`) and each pane saved with its own. The
  `kubernetes` scenario checks the band and the strip's label by their
  accessibility identifiers (and no band off production), the label and
  band following a rewritten pin file, View ▸ Terminal in Kubernetes
  Context… (the switcher on `k.t.*` items only), the card's menu, and a
  restored session's lost and reclassified pins. `KubeTerminalMergeTests` runs
  the real kubectl and helm when installed — temporary kubeconfigs, every
  server a closed port on 127.0.0.1, a HOME of its own, kuberc off —
  against a user's file whose current context is production: the pin's
  context, namespace, server and user win, a change typed in the tab
  writes the pin's file, helm reads its namespace and dials its server.

**A pod's commands in a tab** (stage 1d; `KubeCommands.swift`,
`KubeCanI.swift`; analysis Sections 2.6, 2.14 and 5): `e` a shell, `A`
attach, `t` the log followed — kubectl processes with the user's own
credentials, never the proxy's socket (which refuses exec and attach on
every context), typed into a new tab pinned to the pod's context and
namespace as Terminal in this context pins one.

- **The process class check** (`KubeProcessVerb`, `KubeProcessCheck`,
  pure — rule 1's second half): every process Section 5 names, those
  not built yet too (port-forward, debug, drain, rollout undo, Helm's,
  node shells, `auth can-i`/`whoami`/`version`/`kustomize`, `helm
  template`, Terminal in this context), against the context's class,
  writable flag and settings: what writes is refused on a read-only
  context with why; a log followed and a port-forward start after `can-i`;
  a shell and attach after `can-i`, confirmed on production, off where
  the context's `shells` setting (`kubernetes.contexts`) is false (a log
  followed is confirmed on production too: its tab is a pinned shell once
  the follow ends); a
  typed name where rule 4 says. `KubeCommands.command` builds nothing it
  refuses.
- **The lines** (`KubeCommands`, pure): `kubectl exec -it POD -c C
  --context CTX -n NS -- sh -c 'command -v bash >/dev/null && exec bash
  || exec sh'`, `kubectl attach -it POD -c C --context CTX -n NS`,
  `kubectl logs -f --tail=200 POD -c C --context CTX -n NS` — `--context`
  and `-n` always (rule 7), whatever the tab's pin says; every word that
  isn't ours quoted for zsh as `KubectlLine.quoted` quotes it. The word is
  `kubectl`, the tab's shell's own.
- **The container** (`KubeContainerPick`, pure): read with one GET of
  the pod as the verb runs (`KubeClient.object`, through the proxy);
  one container is it; several are a picker (`KubernetesActions.choose`,
  an alert's buttons), the Logs tab's default first — kubectl's
  `default-container` annotation, else the first; a log offers init and
  ephemeral containers too, a shell and attach only the pod's own.
- **`kubectl auth can-i`** (`KubeCanI`, pure: its arguments — `--context`,
  `-n`, guarded the run's `--cache-dir` — and its answer read: `yes`
  exit 0, `no` with the server's reason after ` - `, anything else a
  failure with kubectl's last stderr line): a short-lived process
  (`KubeCanIRunner`, `KubeProcessRun`, on a GCD thread, 20 s — spawned in
  a process group of its own, so an exec plugin it runs ends with it: the
  group is ended after it, timed out or not, and every one still running
  at quit, `KubeProcessRun.stopAll`, by the group's id) with the
  kubectl and environment the context's proxy gets
  (`KubeProxyPlanner.tool`, which `plan` now builds on: Overterm's
  kubeconfig files as `KUBECONFIG`, kuberc off, guarded only
  `OVERTERM_KUBECONFIG`'s and the run's own HOME), and under the proxies'
  credential rules (`KubeProxies.beginShortLived`/`endShortLived`): a
  context the proxies stopped starts no kubectl (its problem is the
  answer), an oidc context's run waits for any other browser sign-in, a
  proxy's included, and a credential failure (`KubeCanI.credentialProblem`,
  read as the proxy's error is) stops the context as a proxy's does. The app's answers are
  `KubernetesModel.access` (`KubeAccessChecks`, over `KubeAccessCache`,
  pure: a minute each per context, namespace and verb, a failure ten
  seconds; one process per question however many ask; a context's
  questions one after another, never three plugins at once; what has run
  out pruned as another is kept; a context's answers forgotten when the
  kubeconfig read again no longer has it or names another cluster, user,
  credential or class, `KubernetesModel.sameAccess`). Asked when a pod
  is picked in the list, so the menu is ready; `check` publishes nothing
  until the answer comes, so a view's update may call it.
- **Greyed with why** (`KubeAccessState.unavailable`; the page's
  `podVerbs`, `unavailable`): the three verbs are `ResourceVerb`s — the
  pod's right-click menu (one pod picked) and its detail's buttons
  (`ResourceActionBar`, `kubernetes.detail.actions`) — disabled with the
  process check's refusal, "Checking kubectl auth can-i …" while it is
  asked, or "kubectl auth can-i create pods/attach says no in shop[: the
  reason]". A key pressed waits for the answer; refused, the page's
  `commandProblem` says it (over the list, or under the detail's buttons)
  until another pod, namespace or context is picked. With the detail
  open the keys mean the pod it shows (a link followed, back and forward
  leave the list's selection where it was); on another kind, nothing.
- **Production** (rule 5): a shell or attach is asked first —
  `KubernetesActions.confirm`, naming the context, namespace, pod and
  container, and that the tab is pinned there — once per pod, context
  and verb a session (`KubeShellConsent`, in memory). A log followed is
  asked once per context a session, in Terminal in this context's words:
  once the follow ends (or Ctrl-C) its tab is a plain shell whose kubectl,
  helm and k9s go to production; it carries the red band.
- **The tab** (`runKubernetesCommand`, the window's): the pin written and
  the environment made as `startKubernetesTerminal` makes them, then
  `newTab(in:environment:kubePin:running:)` through `addTab` — the
  command typed as the shell starts. A shell or attach tab is a pod's
  (`TabKind.pod`, `shippingbox.circle`: `kubectl exec`/`attach`/`debug`
  with stdin, read off the title ahead of the pin). A scenario sets
  `kubernetesCommandRecorder`: the tab opens pinned and the command is
  handed to it, never typed.
- **Checked** (`KubeCommandsTests`, `KubePodCommandsPageTests`): the
  lines and their quoting, every verb against every class (this Mac's
  context names among them), `shells: false`, the container picked,
  can-i's arguments and answers, the cache's minute, one process per
  question, the greyed reasons, the real runner against a stand-in
  kubectl that records its `KUBECONFIG` and HOME, and on the page `e`,
  `t` and `A` against the fake (a refused verb greyed and opening
  nothing, a picker for two containers, production asked once per pod,
  a log on production once per context, the detail's pod, the problem
  gone with another pod or namespace, answers forgotten for a changed
  user); `KubeCanIProcessTests`: on two oidc contexts no two sign-ins and
  no two of a context's questions at once (a stand-in that logs each
  run's start and end), a stopped context starting nothing and a
  plugin's failure stopping one, a timed-out run and `stopAll` ending a
  stand-in and the child it forked.

**Port-forwards** (stage 1d; `KubePortForward.swift` (pure),
`KubeForwards.swift`, `KubernetesPageModel+Forwards.swift`,
`KubeForwardsView.swift`; analysis 2.7 and 3.8): `f` on a pod, a Service
or a Deployment — kubectl processes with the user's own credentials,
never the proxy's socket, which refuses port-forward on every context.

- **Allowed on read-only contexts** (a forward changes no object) once
  `kubectl auth can-i create pods/portforward` says yes in the namespace
  (`KubeProcessCheck`, the page's minute-long `KubeAccessChecks`): Port-
  forward… and Quick Forward are greyed with why until then, and a forward
  whose answer is no stops saying so.
- **The target, resolved by Overterm** (`KubeForwardResolve`, pure over
  the API's JSON; `KubeForwards.resolve`, GETs only through the
  context's proxy in the background's slots): a pod is itself while it
  runs; a Service is one of its **ready** endpoints' pods —
  EndpointSlices by `kubernetes.io/service-name` (an endpoint whose
  `ready` isn't false and that isn't terminating, a Pod's `targetRef`),
  else the legacy Endpoints' `addresses` — and the pod's port is the
  Service port's `targetPort` (a number, a name looked up in the pod's
  containers, or the port itself), as kubectl does; a Deployment is one of
  its selector's ready pods (`matchLabels` and `matchExpressions` as the
  server's `labelSelector`), oldest first. The pod pinned before is kept
  while it is still one of them: a forward that works isn't moved.
  kubectl is only ever given `pod/<name>`, so the pill names it.
- **The process** (`KubePortForwardCommand`, pure; `KubeForwards.start`):
  `kubectl port-forward pod/P L:R --context C --namespace NS --address A`
  (guarded, `--cache-dir` the run's), with the kubectl and environment the
  context's proxy gets (`KubeProxyPlanner.tool`: Overterm's kubeconfig
  files as `KUBECONFIG`, kuberc off; guarded only `OVERTERM_KUBECONFIG`'s
  and the run's own HOME), under the proxies' credential rules
  (`beginShortLived`/`endShortLived`: a stopped context starts nothing,
  an oidc sign-in waits for any other, a credential failure stops the
  context) — a `ManagedProcess`, ready on its `Forwarding from` line, its
  stderr kept, closed by its pid.
- **Started again** (`KubeForwards.run`): when kubectl exits, or its pod
  goes — the pod read every `podCheckInterval` (5 s) while it forwards:
  gone, terminating or no longer running, and for a Service or a
  Deployment (`KubeForwardTarget.followsEndpoints`) no longer ready, as
  a pod failing readiness leaves the Service's endpoints — the target is resolved again
  and a new kubectl started on the same local port, after
  `KubeForwardBackoff` (1, 2, 4, 8, 15, 30 s; the count starts over after
  a forward that ran 30 s; stopped after 8 in a row, saying so). It stops,
  saying why, when the target itself is gone (`svc/web is gone`), on a
  credential failure or a missing kubectl (no retry runs the exec plugin
  again), and when its context leaves the kubeconfig or names another
  cluster (`contextsChanged`) — a stopped forward's too: its context is
  forgotten, so Start Again can't take it to a cluster it never went to;
  Start Again and Edit read the context's class (production's red) and
  the process check again. A Service's resolve takes the first ready
  endpoint that has the port, not the first ready one. A run that was
  cancelled (stopped, edited, started again) and whose launch or read
  ends late changes nothing (`finish` checks `Task.isCancelled`): the
  task, kubectl and state are the new run's. `ManagedProcess.start`
  closes its process when the waiting task is cancelled, so a kubectl
  stopped before it says it listens ends then, not at the 30 s timeout.
  Stopped, edited, at quit
  (`KubeForwards.stopAll`, before `ManagedProcess.closeAll`) and with
  Kubernetes off, every kubectl is closed by its pid — never a pattern.
- **The local port** (`KubeForwardPortChoice`, pure): the remote port where
  it is free, else one at random in 30000–39999 (Quick Forward: always at
  random) — never one another forward has, or one something on this Mac
  holds (`ListeningPorts.isBound`), nor under 1024. The sheet
  (`KubeForwardDraft`, pure, and `KubeForwardSheetView`): the target's TCP
  ports (`KubeForwardPortOption`: a pod's containers', a template's, a
  Service's own) or one typed, the local port with Random, the address
  (127.0.0.1 unless changed; anything else is said to be reachable from
  other machines), https (what Open and Copy URL say); Edit changes the
  local end and starts kubectl again.
- **Where it shows**: the page's **Forwards** section (`KubeSection.forwards`,
  `9`: every forward of the app, its pod, state and restarts; Open, Edit,
  Stop; Start Again and Remove for one that stopped), the pod's,
  Service's or Deployment's verbs and detail buttons (Port-forward… `f`,
  Quick Forward, Open Forward `o`), a pill in the pane header of the tab
  under the page when it started (`Tab.forwardPorts`, a `ListeningPort`
  with a `forward` origin — `:L → <pod>`, its popover's Kubernetes and
  Stop), Tab Info's Listening, the browser column's empty page, and the
  palette (each forward, ↩ as `o`; Kubernetes Forwards). A pod's Overview
  gives each container its TCP ports (`KubeOverview.Item.ports`), each a
  button that opens Port-forward… on the pod with that port picked. Open
  is the browser column, as Docker's links open (`openDockerLink`). One
  for the app: a forward outlives its window and tab, not the app — so
  closing a tab with a running forward asks, whatever Settings ▸ General
  says (`TerminalWindowController.needsCloseConfirmation`,
  `runningForwards`), and says it keeps running on the page; quitting
  (and the last window's close) asks for any running forward and says it
  stops them.
- **Checked** (`KubePortForwardTests`, `KubeForwardsTests`,
  `KubeForwardPageTests`): the targets and their ports, the command line
  and its quoting, ready endpoints only, a named `targetPort`, a
  Deployment's selector and oldest ready pod, the backoff, the port
  choice, the sheet's checks; against the fake, a Service forwarded to
  its ready pod and started again on the new one after the old is
  deleted (the old process closed), kubectl exiting keeping the pod,
  the Service gone stopping it, can-i's no starting nothing, failures
  backing off then stopping, a credential failure not retried, a context
  gone or pointing elsewhere stopping its forwards, `stopAll`; the real
  launch through a stand-in that listens (ready on its line, the test's
  kubeconfig alone, closed by its pid, a port it can't listen on said);
  the page's `f`, the sheet, `o` and `9`.

**What opens through a forward** (stage 1d; `KubeOpen.swift` (pure),
`KubernetesPageModel+Open.swift`; analysis 3.8):

- **`o`** on a forward is the browser column of the tab under the page
  (`openDockerLink`): the page steps aside and the column takes the right
  slot (`RightSlot`) — the changes pane gives way and comes back when it
  closes; never a column of its own. That, and the terminal tabs `t`, `e`
  and `A` open, is Section 2's dock under the list. A forward's URL is the
  address kubectl listens on (`KubeForwardAddress.host`: 127.0.0.1 for
  loopback, `localhost` and 0.0.0.0, `[::1]` for IPv6) — never
  `localhost`, which a browser may try as ::1 first. **`o` on an Ingress**
  (`KubeIngressLinks`, pure; `ingressRef`, Open in Browser) is where it is
  reached: each rule's host — https when a TLS entry names it, a wildcard
  skipped, a regex path the root — else its load balancer's address; the
  first in the default browser, several asked. An isolated run records it
  (`kubernetesOpenedExternally`) instead of opening anything.
- **`d`** on a database pod (`databaseRef`, Open in Database Client on a
  pod whose detail read it): the image says which (`KubeDatabase.detect`,
  `DockerClient`'s table — postgres, mysql and mariadb, clickhouse; an
  exporter beside it is a tool; Redis and Mongo are said, with their
  client in a shell), the container's port (the image's, or the one it
  declares — unless that is a port the image speaks another protocol on:
  ClickHouse's native 9000/9440/9009, MySQL's X Protocol 33060,
  `KubeDatabase.port`), and where its user, database and password come
  from: each field an ordered list of sources (`KubeEnvValue`: written in
  the spec, a Secret's key by `secretKeyRef`, an `envFrom` `secretRef`'s
  key under its prefix *only if the Secret holds it* — `secretIfHeld` —,
  or elsewhere, never read), resolved against what was read
  (`KubeDatabase.resolve`, `KubeSecretValues`): a key a Secret read
  doesn't hold gives way to the image's next name (Bitnami's
  `POSTGRESQL_PASSWORD`), and MySQL's app user is taken only with its
  password, else root with root's — decided after the read. What the env
  takes from a Secret is asked about first — every time, naming the
  Secret and its keys (`KubeSecretWant`: `envFrom`'s as "whichever of …
  it holds"), production in its band's words — and Cancel starts nothing.
  Then a forward to that port — one running reused, else one started on
  the database's own port where it is free, after `kubectl auth can-i`,
  marked `forDatabase` — and once it forwards, the Secret read if the
  user said so (one GET, only the keys named kept, `KubeDatabase.take`,
  the rest of the answer dropped) and the Database client's form
  (`newDatabaseConnection`) filled in with 127.0.0.1 and its local port
  (`KubeDatabase.connection`); a password written in the spec is left to
  type. Nothing is saved or connected: the form does that, its password
  to the keychain only (`DatabaseStore`). The window's `databaseDraft`,
  which the scenarios read, holds the password only in an isolated run
  and only while the form shows (`presentSheet`'s `ended`).
- **A forward's API**: the first time a forward forwards on its local port,
  its server is asked for an OpenAPI document (`KubeForwards.probe`,
  `APIDiscovery.probe`: every usual path at once, 1.5 s each, 3 s in all) —
  not a production forward's, not `d`'s (`forDatabase`) nor one to a port
  where a server speaks no HTTP (`KubeForwards.nonHTTPPorts`: databases,
  caches, queues — ten requests there are ten bad handshakes, and MySQL
  counts them toward blocking the host), and only while the API client
  and its server discovery are on; turned on while forwards run, those
  are asked then (`probeForwarding`, on Settings' `changes`). One found (`KubeForwards.openAPI`, gone with
  the forward or its port) is offered, never imported unasked: the API
  panel lists it with what the checkout has (`APIWorkspace.forwardSources`,
  `importable`), and the Forwards row and the palette import it on a
  press (`importForwardAPI`: into the checkout's collection, its first
  request opened).
- **The palette** (`forwardPaletteItems`): Kubernetes: New Port-forward…
  (the sheet on the selected object, else the Services list saying what
  to pick), each forward (↩ as `o`), its Stop, and its API's import —
  each named by the address `o` opens (`KubeForwardSpec.hostPort`,
  127.0.0.1:<port>, as the Forwards list, the pill and the close warning
  say it); an open palette is restocked as forwards and their APIs
  change.
- **Checked** (`KubeOpenTests`, `KubeOpenForwardsTests`): an Ingress's
  links; the database detection (images, env names, `secretKeyRef` and
  `envFrom`, ports — a lone other-protocol port not taken —, what isn't
  spoken); an `envFrom` Secret holding only MySQL's root key or
  Bitnami's names resolved to those; the connection filled in, a
  password only from a Secret read on the user's word, never from the
  spec; only the keys named taken; a pod's connection saved keeps its
  password out of connections.json; the probe against a local server and
  bounded against a closed port; a forward probed once, not again on its
  next pod, forgotten with it, never on production or with discovery
  off, probed when discovery is turned on while it runs; a database
  forward never probed (the echo server sees no connection); `d` against
  the fake (one GET of the Secret when asked, none when not, the forward
  reused, Redis said, Cancel at the Secret's question starting no
  forward); the palette's items and what they do. The `kubernetes` scenario opens a forward in the browser column at
  http://127.0.0.1:<port> in the right slot, `d` on a postgres pod to the
  filled-in form (the Secret's one GET, nothing saved), a Redis pod said,
  an Ingress's host recorded, and the palette's Stop.

**Ask Why** (stage 1e; `KubeAgentBrief.swift`, `KubeAgentBriefing.swift`,
`KubernetesPageModel+AskWhy.swift`; analysis 3.4): a failing pod or a stuck
rollout handed to an agent with what it needs to say why — Docker's Ask Why
(`DockerAgentBrief`), for Kubernetes.

- **What is wrong** (`KubeTrouble`, pure): off a pod's object, its
  containers (init first) — `CrashLoopBackOff` (`OOMKilled` when its last
  end was the OOM killer), `ImagePullBackOff`/`ErrImagePull`/…,
  `CreateContainerConfigError`/`CreateContainerError`, one that ended with
  an error — then its phase (`Failed`, `Pending`); off a Deployment's, a
  rollout past its progress deadline (`KubeRollout`'s stuck) or fewer
  available replicas than wanted. The question an agent is started with
  is the trouble's ("Why does pod shop/worker-1 keep crashing
  (CrashLoopBackOff)?"). A list row says enough to offer it — a pod's
  Status failing or Pending, a Deployment not Available — and the
  detail's object, once read, says it exactly; else the verb is greyed
  with why ("pod/web-1 isn't failing: Running, 1/1 ready.").
- **The brief** (`KubeAgentText`, pure, every part bounded): always sent,
  the pod — where (the context, production said as such, read-only), its
  phase and reason, QoS, node, owners (`ReplicaSet … ← Deployment …`), its
  conditions that aren't True, each container's state, restarts and last
  terminated state with what its exit code means (`exitMeaning`: 1, 2,
  126, 127, 137 the OOM killer when `OOMKilled` else a kill — a liveness
  probe, a stop past its grace period —, 139, 143, 128 + a signal),
  resources, probes, its command (`maskArguments`) and env: a value whose
  name looks secret masked, a `secretKeyRef` or an `envFrom` Secret named
  — `DB_PASSWORD from Secret web-db, key password (not read)` — never
  valued; and how kubectl reads it. Then a chip each: its events (newest
  first, 15, each message bounded); the last 60 lines of the troubled
  container, and of one more that restarted or ended (`logTargets`) — its
  previous instance's (`previous=true`) when it restarted, 8 KB, the newest
  kept and a crash's one long line cut, not dropped — read with
  `limitBytes` (256 KB, `KubeClient.logTail`), of which the last 64 KB are
  taken apart (`KubeLogText.tail`: no part of a line kept where a cut went
  through it) and each line bounded before it is scrubbed
  (`KubeAgentText.bounded`), the brief saying when the server stopped at
  the limit; its owner's pod template — the last owner read that has
  `spec.template` (a CronJob's Job's) — as `kubectl get -o yaml` writes
  it (`pod-template-hash` out, `KubeAgentText.masked`: env through
  `KubeObjectStrip.maskingEnv`, every container's command and args, its
  probes' and hooks' `exec`, through `Secrets.maskArguments`), and, under
  a Deployment, its diff with the previous ReplicaSet's
  (`currentAndPrevious`: the revision the Deployment names, else the
  highest, and the one before; `lineDiff`, two lines of context; whether
  they differ asked of the templates, not their masked YAML — a masked
  value that changed, a rotated password, is marked "(changed)" and named,
  `markingChanged`); for Pending, the scheduler's `PodScheduled` message,
  what it requests (`requests`: the containers' summed, or the largest init
  container's; `KubeQuantity`), its node selector and tolerations, against
  each node's allocatable, readiness, cordon and taints (20 nodes, and
  what other pods request isn't counted, said). A Deployment's brief is
  its rollout as `kubectl rollout status` says it, its replicas, strategy,
  deadline, conditions and ReplicaSets, then its events, its newest
  ReplicaSet's (a FailedCreate — a quota — is there), that ReplicaSet's
  pods (by its `pod-template-hash`), the first failing one's containers and
  log, the template and the diff. `KubeAgentBrief.deployedCommit` is the
  seam for the bound checkout's deployed commit (3.2): nil until stage 3a's
  binding exists.
- **The reads** (`KubeAgentBriefing`): once, when asked — the object, its
  events, the logs, its owners (by discovery's kinds, else Kubernetes'
  own; an ownerReference naming a Secret never followed), a Deployment's ReplicaSets (one page of 50), the nodes (one page of
  50), its pods as rows only — every one a GET through the context's proxy
  (`KubernetesModel.client`), each given `readTimeout` (10 s,
  `KubeBriefRace`); one that fails or times out leaves its part out and
  the brief says what couldn't be read. **No Secret is read**: none is
  asked for, and a Secret asked about is refused before anything is.
- **Scrubbed**: every word through `Secrets` — the pod's and its
  template's env values that look secret and every URL's password
  (`Secrets.scrub`, the names the brief says anyway kept:
  `KubeAgentText.names`), then credentials in text
  (`Secrets.scrubCredentials`: PEM bodies, bearer and basic
  authorization, JWTs, AWS keys, a kubeconfig's `token`,
  `client-key-data`, `client-certificate-data`, `password`, an auth
  provider's `id-token`, `refresh-token`, `client-secret`…, env-style
  names with a prefix (`DB_PASSWORD=`, `GITHUB_TOKEN:`) — only spaces and
  tabs around the `:`, so a YAML block under `secret:` stays —, vendor
  tokens by their prefix (`ghp_`, `xoxb-`, `glpat-`, `sk_live_`…), and
  base64 or base64url blobs — 32 characters or more with upper- and
  lowercase and a digit, so a digest, a SHA, a uid or a path stays).
- **Asked from** `a` (on the list's one selected pod or Deployment, or the
  detail's), ⌘L over the page (`WorkspacePage.askAboutSelection`; lines
  picked in a log answer it themselves), a failing pod's Why in its row
  (Docker's Ask Why, a button), and Ask an Agent Why… on the menu and the
  detail's buttons (a `ResourceVerb`). Production too: it only reads.
- **The sheet** (`presentKubernetesBrief`): the Ask Agent sheet with the
  question typed, the subject the fixed chip, the parts their chips, and
  the whole prompt shown before it is sent (`AskAgentModel.showsBrief`,
  updated as chips go off; no git diff chip, which the preview wouldn't
  show). No checkout is bound to a context yet, so the
  selected tab's agent is offered first, then the window's others, then a
  new one in the selected tab's folder; Send types it, as every Ask Agent
  does, the page stepping aside.
- **Checked** (`KubeAgentBriefTests`): each failure kind off fixture
  objects, the exit codes, a container's env (a Secret named, a secret
  value masked), the template diff, Pending's requests and nodes, the
  bounds, the log targets; every scrubbing pattern and what isn't a blob,
  Docker's scrubbing unchanged; against the fake, a crash loop's brief
  with every section and its planted secrets out (the previous log read
  once, never followed), production said, Pending's nodes, a stuck
  rollout's ReplicaSet events, pods and diff, a pod that is fine and a
  Secret refused with nothing asked, a read that hangs left out in time —
  every test ending with only GETs and no `/secrets`; on the page, `a`,
  the greyed verb, the detail's button, a Deployment's from its object,
  production. The `kubernetes` scenario: on fake-dev's crash-looping pod,
  its row's Why drawn, `a` opening the sheet with the brief shown whole
  (its sections, the exit code's meaning, events, the previous log), the
  planted secrets out and a Secret's env named, the selected tab's agent
  first, read with GETs alone and no Secret — then Cancel, nothing sent; a
  pod that is fine saying why; ⌘L over the page; the detail's button; and
  on fake-prod the same, said production, reads only.

**Agents' tools** (stage 1e; `KubeMCP.swift`; analysis 3.5): the `k8s_`
group of the MCP server Claude Code gets from Overterm (`BrowserMCP`, as
Docker's `docker_` are), offered and answered only while
`kubernetes.agentAccess` is on (`Settings.kubernetesAgentAccess`, which
`kubernetes.enabled` off turns off too; the bridge serves while any group
is on, and follows `kubernetes.*` changes). Seven tools read; three write
where a context is writable for agents (Agents' writes, below):

- `k8s_contexts`: each context's name, class (production said as such),
  whether Overterm may write there and whether agents may, its namespace, kubectl's current one,
  the one the tools use unless told another, and a stopped proxy's
  reason — never a server, a user or a credential; scrubbed and bounded
  like every answer. Read from the
  kubeconfig files (`KubernetesModel.contextsForAgents`: the page's list
  while one shows, else the files read again, locally) — no cluster asked.
- `k8s_get`: a kind (any name `KubeKinds.resolve` takes: `po`, `deploy`,
  a CRD's plural) as the server's Table, one page of `limit` rows (100, at
  most 500) — rows only, `includeObject` as the page's lists ask, but
  Secrets across namespaces one namespace at a time with
  `includeObject=None` (`secretsAcrossNamespaces`, 100 namespaces at
  most): a row's metadata would carry a Secret's last-applied data —, with
  `label_selector` and `field_selector` sent to the server, `name` as
  `metadata.name=`, `filter` on the rows' text once each cell is
  scrubbed (else a row's being there would test a guess), `wide` for the
  `priority > 0` columns; printed as kubectl prints it, a NAMESPACE column
  across namespaces, cells cut at 200 characters, a cut list said
  (`KubeMCPText.table`).
- `k8s_describe`: one object's GET, as the YAML tab strips it
  (`KubeObjectStrip.shown`: managed fields and last-applied out, env that
  looks secret masked), said by its `KubeOverview` — facts, sections,
  rollout — then the pods its selector picks (rows, 30) and its events.
- `k8s_logs`: a pod's container (kubectl's default, else named; checked
  against the pod's), `tail` (200, at most 2000), `since` (`30s`…`1d`, as
  `sinceTime`), `previous`, read once — `limitBytes` 1 MB, the last 512 KB
  taken apart (`KubeClient.logTail`) — every line scrubbed with the pod's
  env, then `grep`: matched after scrubbing, so a secret can't be found a
  character at a time.
- `k8s_events`: a namespace's (or every namespace's) core Events, newest
  first — every page read (500 a page, 4 pages at most) before the newest
  are picked, since the server lists them in key order, and a list cut
  there says so —, `warnings_only` as `type=Warning`, or one object's by `name` (and
  `kind`, a pod's by default), at most 200.
- `k8s_why`: Ask Why's brief (`KubeAgentBriefing`) on a pod or a
  Deployment, as one text — the question, the brief, each part; one that
  isn't failing says why.
- `k8s_rollout`: a Deployment's, StatefulSet's or DaemonSet's rollout as
  `KubeRollout` says it, its replicas, and its history — a Deployment's
  ReplicaSets, the others' ControllerRevisions (where served), the ones it
  owns, newest first: revision, images, ready, age, change-cause.
- `k8s_top` isn't there: it waits for metrics (stage 2d); `k8s_apply` is
  2b's. A name that isn't one of these is an unknown tool.

**Where**: the context the call names — one the kubeconfig doesn't have
is an error, never a fallback — else the page's selected one
(`KubernetesModel.agentDefaultContext`), and with none selected the call
names one: never the one the page would open on, which falls back to
kubectl's current context, often production; the namespace
named (`all` for every one) else the page's on that context, else the
context's own (`agentDefaultScope`); a tool that needs one namespace and
gets all says so. `KubeMCP.defaultContext` takes the calling pane's tag
(`BrowserMCP.handle`'s `pane`, from the bridge's path): the seam for stage
3a's binding, whose checkout's context comes first. Kinds are resolved
against the page's discovery only while the page's reading of the name is
the same cluster and user as the tool's (`knownDiscovery(of:)` with
`sameCluster` — the kubeconfig may change while the page is hidden), else
against the tools' own, kept five minutes per cluster and user. Every answer starts
with the context, production in capitals (`KubeBriefContext.said`).

**Reads, no Secret**: every read a GET through
`KubernetesModel.agentClient` — the context's proxy in a background slot
(never the page's), under the proxies' rules: a stopped context answers
its problem and starts nothing, an oidc sign-in waits its turn — each read
given `readTimeout` (30 s). A read-only context's socket refuses writes
anyway. A Secret (`sec`, `secret`, `secrets`) is listed and described from
its Table row alone — type, how many keys, age, with `includeObject=None`
for one — never GET, since that one GET is every value; Ask Why's brief
names a Secret's env, never values it. **Scrubbed and bounded**: every
answer through `Secrets` — the object's env (`KubeLogScrub.env`, its
template's too, the names said kept), every URL's password, credentials
and base64 blobs (`KubeMCPText.scrubbed`) — and cut at 60,000 characters
(a log keeps its end). A failure — a proxy's credential problem, the
server's — is said scrubbed.

**Checked** (`KubeMCPTests`, against `FakeKubeAPI` and a model of two
fictional contexts): each tool's answer; the default context and
namespace, another named, an unknown one refused with nothing asked; a
read on fake-prod; no selection with fake-prod current refused unnamed,
nothing asked; a Secret listed and described with no key and no value,
its alias, none asked for but as a Table, across namespaces each with
`includeObject=None` and its planted last-applied never seen; a token in
a cell not found by `filter`; events past a page read before the newest
are picked, a list cut said; logs scrubbed before `grep`;
the tool list exactly the seven reads with no writable context, a write
tool on a read-only context refused asking nothing, `k8s_apply` unknown; a credential
failure through the real `KubeProxies` answered scrubbed, the context then
stopped — the next call asks nothing and plans no proxy, `k8s_contexts`
says why; Kubernetes off; the setting taking the
group from `tools/list`, the instructions and the calls (a `Settings` of
the test's own) — every test ending with only GETs, no subresource but a
log, no Secret's object. `KubeMCPTextTests`: durations, names, the table,
the bounds and the scrubbing. The `kubernetes` scenario calls them through
the bridge's real HTTP endpoint at a pane's path, with its token: the list
without a write tool, `k8s_get` on fake-prod, the page's context when none
is named, an unknown context refused, a Secret without its value,
`k8s_why`, a write on read-only production refused, only GETs; `kubernetes.agentAccess` off
taking the group from the endpoint's list and refusing a call (or, with no
other group on, the endpoint gone), and on again back in its `tools/list`.

**Writes** (stage 2a; `KubeWrites.swift` (pure, and
`KubeClient`'s writes), `KubernetesPageModel+Writes`,
`KubeScaleSheetView`, `KubeNamespaceSheetView`; analysis Sections 2.2,
2.3, 2.4, 2.9, 2.15, 4 and 5):

- **Where** (rule 2): a writable context only — a remote or local
  context's `writable` flag in `kubernetes.contexts` (local unless it
  says no), and production only while its switch is on for the session
  (`KubeContext.sessionWrites`; nothing else decides). The switch is the
  context card's Allow Writes Until Quit…, asked first naming the
  context, kept in memory by `KubernetesModel.productionWrites`
  (`KubeProductionWrites`: off at launch, dropped when the kubeconfig
  read again points the name at another cluster or user), and said in the
  band ("writes on until quit"). `KubeProxies.allowSessionWrites` closes
  the context's proxy so the next request opens it without the method
  filter — only then — and `endSessionWrites` back with it; the proxies
  plan from their own knowledge of the switch, kept with the context as
  it was turned on for (`KubernetesModel.sameAccess`), so a stale copy of
  the context never flips the flags, and a kubeconfig read again that
  points the name at another cluster, user or class is planned with the
  filter before the model has told them.
- **Two locks before the socket**: `KubeClient.write` refuses unless the
  connection's context is writable, and `KubeProxies.sendWrite` refuses
  unless the proxies know it so (`KubeWriteRefused`); a read-only
  context's socket refuses writes anyway (`KubeProxyFlags`).
- **The verbs** (`KubeWriteVerb`, each offered where discovery says the
  kind takes it, `KubeWriteCheck.offered`): delete (`DELETE` with
  DeleteOptions, `propagationPolicy: Background`, the pod's own grace
  period), delete to recreate (`r` on a pod; its controller named from
  its metadata), force delete (grace 0, warned), remove finalizers (a JSON
  patch that tests the finalizers confirmed before removing them, warned),
  evict (`POST pods/{p}/eviction`; a PodDisruptionBudget's 429 said with
  its cause, never retried), rollout restart (kubectl's strategic merge
  of the template's `kubectl.kubernetes.io/restartedAt`), scale (a merge
  patch of the `scale` subresource), rollout pause and resume (a
  Deployment's `spec.paused`, as kubectl's strategic merge sets it —
  resume takes the field away), a CronJob triggered (`POST jobs`: the
  Job `kubectl create job --from=cronjob/…` makes — the jobTemplate's
  spec and labels, its annotations over
  `cronjob.kubernetes.io/instantiate: manual`, the CronJob as its
  controller with `blockOwnerDeletion`, as `metav1.NewControllerRef` sets it, named `<cronjob>-manual-<5>` within 63), suspended and
  resumed (a merge patch of `spec.suspend`, said as `kubectl patch
  --type=merge`), a node cordoned and
  uncordoned (`spec.unschedulable`), and a namespace made (`POST
  namespaces`, nothing but its name — a DNS label, `KubeNamespaceName`,
  checked in its sheet as the server would). Pause, suspend and cordon
  are states (`KubeWriteToggle`): what a row says of one — a CronJob's
  Suspend, a node's Status, which follow the watch (a Deployment's rows
  don't say paused; the detail's object is read only as it opens) —
  greys the verb that is so already with why; the key toggles, and the
  object read decides — the row may be behind it (the watch's
  coalescing, a watch stale after sleep). Patches and creates
  carry `fieldManager=overterm`. Keys: ⌫ delete, `r` restart (a pod:
  recreate), `+`/`-` by one, `=` the scale sheet (its field takes the
  keyboard as it appears, Return goes on to the confirmation), `p` pause
  or resume (a CronJob: suspend or resume), `s` trigger, `u` cordon or
  uncordon, `N` the new namespace's sheet; the rest are in the right-click
  menu and the detail's buttons (`ResourceActionBar`, delete as its red
  bin). ⌘K has New Namespace… and the selected object's writes that can
  be done now, each by the same path.
- **The guard path** (`KubernetesPageModel.write`), in this order: the
  class check (`KubeWriteCheck.rule`: refused with why on a read-only
  context or production without its switch); the access review — a
  SelfSubjectAccessReview through the writable socket
  (`KubeAccessReview`, `KubernetesModel.writeAccess`: a minute per
  context, namespace and verb, asked as a row is picked so the menu is
  greyed with the cluster's own reason); a metadata-only read where the
  confirmation needs it (`PartialObjectMetadata` — a Secret's values are
  never read —, the scale subresource's replicas, the object whole for a
  state's field or a CronJob's template — `KubeClient.spec`, never a
  Secret —, or a namespace's contents counted from Tables of rows alone,
  `KubeNamespaceContents`: a row a kind with the server's
  `remainingItemCount`, a page of 500 only without one; its twelve
  kinds said as a lower bound, a 403 said as not allowed apart from a
  kind that couldn't be counted, and nothing said as none while
  discovery isn't known; a
  toggle read as so already is turned round, its review being the
  same; carried on as `KubeWriteFacts` — meanwhile the page says
  Checking…, and no other write starts (`writeChecking`): two triggers
  confirmed would make two Jobs); the confirmation in
  the window (`KubeWriteConfirmation`, `confirmKubernetesWrite`: the
  verb and object, the context and namespace on a line of their own —
  production's red on production —, the kubectl it equals, the
  warning; the sheet is `WriteConfirmation`, the one every write is
  asked with: DockerMCP's `allow` and the page's other asks too) with the object's name typed where rule 4
  asks — on production a delete, recreate or scale to 0; force delete,
  finalizers and a namespace's delete on every class — which the page
  checks (`accepts`), a wrong name sending nothing; the context checked
  once more as the button is pressed; then the request, its outcome said
  over the list or under the detail's buttons (`KubeWriteStatus`), the
  API's 403, 404, 409, 422 and an eviction's 429 in plain words
  (`KubeWriteOutcome`), the answer's body never kept. The list follows
  by its watch.
- **Checked**: `KubeWritesTests` (each verb against each class, the
  typed name, each request exactly, the review's attributes and answer,
  the confirmation's words, the outcomes, the switch kept only for the
  same cluster), `KubeWriteClientTests` (each write landing on
  `FakeKubeAPI` — which applies deletes, finalizers, merge and JSON
  patches, scale and evictions to its objects and its watches, answers
  access reviews from `deniedAccess` and a metadata-only GET, and records
  each write's body and content type — a read-only connection sending
  nothing), `KubeWritesPageTests` (no write before the review and the
  confirmation, Cancel, a refused review, a read-only context sending not
  even a review, production's switch and the typed name, writes turned
  off while asked, every verb through the page), `KubeProxiesTests`
  (the switch restarting the proxy without the method filter and back;
  another cluster under the name read-only at once), `KubeWriteVerbsTests`
  (the other verbs' requests exactly, the trigger's Job, the kubectl each
  equals, their reviews and no typed name, states from an object or a
  row, a namespace's name, what its delete warns of) and
  `KubeWriteVerbsPageTests` (each through the page against the fake: the
  review before the CronJob is read, the Job made and owned, suspend and
  resume by the row, pause turned round by the read, cordon's
  SchedulingDisabled, the sheet's name checked, a name taken, a
  namespace's counts and typed name, fake-dev refusing each with nothing
  sent, production's switch checked again at the button). The scenario's
  `kubernetesVerbs` (`E2ERunner+KubernetesVerbs`) triggers, cordons and
  makes then deletes a namespace on `kind-fake` by the window's keys and
  sheets, and sees `fake-dev` refuse each.

**Writes in a tab** (stage 2a; `KubeTabWrites.swift` (pure),
`KubernetesPageModel+TabWrites`; analysis 2.4, 2.9, 2.15 and Section 5's
process table): a drain, a rollback and a debug container are kubectl in
a terminal tab — where evictions and what a PodDisruptionBudget blocks
show as they go, and `rollout undo`'s logic stays kubectl's — not
requests. `KubeTabWrite` is each one's words: `kubectl drain NODE
--ignore-daemonsets` (Drain in a Tab…, a node's), `kubectl rollout undo
deployment/D --to-revision=N` (Roll Back in a Tab…, a Deployment's: the
revision picked from the ReplicaSets it owns, newest first, each with its
images and age — `KubeRevision`, the current one never offered),
`kubectl debug -it POD --image=I --target=C` (`E` on a pod where the
server serves ephemeral containers; C picked when there are several) and
`kubectl debug node/N -it --image=I` (`E` on a node), `--context` and `-n`
always (a drain's `-n` is its tab's, harmless for a node), every word not
ours quoted for zsh. A pod's image is the context's `debugImage`, else
`kubernetes.debugImage`; a node's the context's `nodeShellImage` first
(`KubernetesModel.nodeShellImage`).
One path (`runTabWrite`), as the page's writes: the process class check
(`KubeProcessCheck`: refused on every read-only context — each is
`KubeProcessVerb.writes` —, a node's debug also needs the context's
`nodeShell`; a debug container and a node's debug are shells, refused
where the context's `shells` is off); the access review of what the command does
(`KubeTabWrite.accesses` through `writeAccess`: patch nodes and create
pods/eviction cluster-wide; patch deployments.apps; patch
pods/ephemeralcontainers and create pods/attach; create pods); what it
needs read; the confirmation (`KubeTabWrite.confirmation`, a
`KubeWriteConfirmation` without a request verb: the context and
namespace, what happens, the command the tab runs) with the name typed
where rule 4 says — a drain, rollback or debug container on production,
a node's debug on every class (decision 20) —; the class check once more
against the context as it is at the button, which must still be the
cluster, user and class reviewed (`KubernetesModel.sameAccess`: the tab's
kubectl reaches it by name); then `KubeCommands.command(_:in:)` —
which builds nothing the check refuses — typed into a new tab pinned to
the context (`runKubernetesCommand`), recorded instead in a scenario.
Checked: `KubeTabWritesTests` (each line, quoting, every read-only
context refusing each, typed names, the confirmation's words, the
reviews, which kinds, the revisions) and `KubeTabWritesPageTests`
(reviewed then asked then typed, a read-only context sending not even a
review, a refused review, a revision picked, `E`'s container, a wrong
name, writes turned off and the kubeconfig pointing the name elsewhere
at the button running nothing). ⌘K lists them beside the page's writes
(`Kubernetes: Drain node N in a Tab…`).

**Agents' writes** (stage 2a; `KubeMCP.write`, `KubeAgentWrites`; 3.5,
rule 10): `k8s_restart`, `k8s_scale` and `k8s_delete_pod` work only on
a context `kubernetes.agentWrites` names (empty by default: agents only
read) and writable for Overterm — a local or remote one by its
`writable`, a production one only with its switch on for the session
(`KubeAgentWrites.refused`); `tools/list` offers them while the setting
names any context — by the setting, not the contexts' state at the
list, which MCP isn't told of again (an agent started before a name was
added needs a restart) — and `k8s_contexts` says where they work. A call goes the page's way: the class check
(`KubeWriteCheck.rule`), the access review through the context's
socket, the replicas read for a scale, the confirmation
(`KubeWriteConfirmation.make`) asked in the calling pane's window — "An
agent asks, in <context · namespace>: …", the sheet `WriteConfirmation`
with Allow and Don't, all of it shown, the name typed where rule 4 says
—, the contexts read again and every check repeated (writes turned off,
`agentWrites` changed or the kubeconfig pointing the name elsewhere
while it asked stop it), then one request (`KubeWrites`) through
`agentClient`. Declined, a wrong name, refused: an error to the agent
and nothing sent. An isolated run with no window answers no.
`KubeMCP.askOverride` answers in tests. Checked: `KubeMCPWritesTests`
(where agents may write, the tool list by `agentWrites`, a writable
context it doesn't name refused, every tool asking first and a refusal sending nothing, a
scale reviewed then landing, production's typed name, a refused review,
a change while asked); the scenario's `kubernetesTabWrites` and
`kubernetesAgentWrites` (`E2ERunner+KubernetesTabWrites`): a drain
refused on fake-dev and recorded on kind-fake after its review and its
sheet, a rollback's revision picked, `E`'s debug container; through the
bridge's endpoint no write tool and `k8s_scale` on kind-fake refused
until `agentWrites` names it, then asked in the window (the runner
answers) and landing on the fake, a declined delete sending nothing, and
fake-prod's writes refused until its switch is on and `agentWrites`
names it, then its name asked.

**The switcher** (⌃⌘J, `kubernetes.switch`; ⇧⌥⌘J, Docker's pattern, is
Ghostty's `write_screen_file:open`, and its ⌃⌘ defaults are only `[` and
`]`): the palette scoped to `PaletteItem.Group.kubernetes` — every
context, the context's namespaces, the kinds it serves ("Go to
Deployments", with its section and `:` names) and the rows of the kind
showing, each a palette item the page's `paletteItems` gives (so ⌘K
finds them too; rows only while something looks at them, never a list
left from before). ⌘K also has, while the page shows in its window, the
page's commands (`kubernetesPageCommands`, actions: Switch Context…,
Switch Namespace…, Go to Kind…, All Namespaces, Wide Columns, Copy as
kubectl with the line it copies, Copy Rows as TSV and as CSV, Export
List as CSV…, New Namespace…, the selected object's writes). It looks
as the page does: it holds the model while the palette shows it
(`kubernetesSwitcherHeld`), so the kubeconfig is read and the pods
followed with the page hidden, and lets go after the palette closes — once
what was picked has opened the page, so the watch runs on. ↩ on a context
or a namespace switches to it on the page; on a kind, the page on its
list; on a row, the page on its kind's list with it selected and in view
(`revealOnKubernetesPage`).

**The scenario** (`kubernetes`, `E2ERunner+Kubernetes`): testKubernetes
names a temporary OVERTERM_KUBECONFIG; the scenario opens the page before
the file exists (no kubeconfig), then starts `FakeKubeAPI` on a socket
and 127.0.0.1 and writes there two contexts on it, `fake-dev` (remote,
so read-only although its server is loopback) and `fake-prod`
(production by name). `kubernetes.kubectlPath` names a stand-in script
of the run's own (`writeStandInKubectl`): it answers `auth can-i` itself
— no for `pods/attach` — recording its KUBECONFIG and arguments, and
`exec`s the real kubectl for the rest. With kubectl installed the real
`kubectl proxy` runs through it in front of the fake (that file as its
only KUBECONFIG, `--context`, a HOME of the run's own); else a stand-in
connection goes to the fake's socket. It checks the pods
listed as rows only in the server's columns, a crashing pod's reason
(and drawn, read off the window), the watch's changes, the keys, all
namespaces (two same-named pods apart, metadata asked for there),
`label:` sent to the server through the proxy (and said); `field:` too —
a finished pod left out by `status.phase=Running`, the fake recording the
fieldSelector on the list and its watch, said, and `k` by the key as the
window takes it copying the list's command with it (the user's pasteboard
put back after); every kind —
what fake-dev serves read and drawn in its sections, `:` by the key as the
window takes it (the field given the keyboard, its completions drawn),
`:deploy`'s deployments in their own columns as rows only, with the Status
read off them (drawn), `k` on one copying its `-o yaml` command, ⌘K finding
a deployment, "Go to Deployments" and the page's Copy as kubectl, the list
exported as CSV by the menu's action into the run's folder in the visible
columns (no write problem), Copy Rows as TSV (the visible rows) and as CSV
(the selected one) on the pasteboard, put back after, Tab completing
and Esc closing by the field's own commands, `:widgets`' custom resources
in the CRD's printer columns (the wide one behind `w`), a kind nobody
serves said, `2` and `6` (Network's services, the cluster-wide nodes), a
secret's row with no value, a CRD applied while the page shows appearing
by the CRD watch and listed, `:po` back; the detail — a pod by ↩ as the
window takes it, read with one GET, its phase, node, image and owner
(drawn), its YAML without managedFields or the last-applied annotation
(drawn; the toggle shows them), its events by uid, the warning first
(drawn); the ReplicaSet and the Deployment followed as links, the
deployment's replicas, strategy, rollout and selected pod; ⌘[ ⌘] by the
key as the window takes them (⌘[ the menus' with nothing behind), `[`
`]`; a stuck deployment opened by a click, its progress deadline said
(drawn), the detail following the list; a pod's logs — `l` by the key
as the window takes it, its default container's last 500 lines followed
with timestamps (in the text view, its end in view, drawn), older lines
by a larger tail when scrolled to the top, a line written coming by the
follow, the fake dropping the stream and the view resuming by
`sinceTime` with what was written meanwhile (one of the very time of the
last line shown) and nothing twice, newest first, Save As into the run's
folder, ⌘L on picked lines scrubbed with the pod as context, the detail
following to the crashing pod and Previous showing its crashed
container's lines (drawn), the stream closed with the detail, only GETs
of `log`; a Secret's detail that reads
nothing (drawn) until Show is pressed where a person presses it, then
one GET, its keys with the values masked (drawn, the length shown), one
revealed and another masking it (drawn, then not), its YAML masked, the
next row dropping every value, a TLS Secret's certificate (drawn) and its
key never revealable, Esc and the page hidden dropping them, and no value
in the app's unified log — testKubernetes checks the app's output and
errors hold none either; Esc; `n` by the key
as the window takes it, a namespace picked by typing, one typed that
nobody listed, Esc; `c` to `fake-prod` and back;
`fake-prod`'s band, drawn; that `fake-dev`'s proxy refuses a POST, a
DELETE, an exec and a port-forward; that the fake recorded no write and
no subresource but a pod's log; that hidden the page's watch ends and nothing is asked;
⌃⌘J from the terminal — the model held, a pod (with its reason), a
context and a namespace found, ↩ showing the pod selected on the page,
the hold let go; Terminal in this context — opened from the context
card on `fake-dev`, its tab pinned to `fake-dev` in `shop` and a
Kubernetes tab, its `KUBECONFIG` the pin's file (in the run's support
folder, 0600, the context and namespace, no credential) then the run's
kubeconfig alone and nothing else given the shell, the shell having it
(a `printf`, never kubectl), its header's label drawn, a split pinned
too, a row's verb recorded with the row's namespace, `fake-prod` from
the palette asked first naming it (Cancel opens nothing), confirmed,
its band drawn, and the kubeconfig never written; a pod's commands —
can-i asked of the stand-in as a pod is picked (the run's kubeconfig
alone, `--context`, `-n`, once a minute), attach greyed with its reason,
`e` and `t` recorded with their tabs (pinned to `fake-dev` in `shop`,
their KUBECONFIG the pin's file and the run's), `A` opening nothing and
saying why (drawn), two containers asking which (the default first),
and on `fake-prod` a shell asked first naming the context and pod
(Cancel opens nothing), its tab's band, and not asked again for the pod;
port-forwards — `f` on `fake-dev`'s Service `web` (read-only, after the
stand-in's `can-i create pods/portforward`), the sheet with the Service's
port and a free local one (drawn), resolved to its ready endpoint's pod
and run through the stand-in kubectl (`port-forward pod/web-7d9 L:8080
--context fake-dev --namespace shop --address 127.0.0.1`, the run's
kubeconfig alone), which listens and answers with its pod's name; the
fake then replaces the pod and the stand-in is ended by its pid, as
kubectl ends when its pod goes, and a second stand-in starts for the new
pod on the same port — answering, the pill and Tab Info naming it, `9`
listing it (drawn), `o` opening it; Edit moving its local port, kubectl
exiting starting it again on the same pod, the Service gone stopping it
and saying so (drawn); a Quick Forward of a pod opened once it forwards;
nothing but GETs reaching the API; writes
(`E2ERunner+KubernetesWrites`) — `kind-fake` (local by name) added to
the run's kubeconfig and read, a pod deleted by ⌫ as the window takes
it once its access review reached the fake, the sheet naming the verb,
object, context and namespace and the kubectl it equals, nothing
written while it asks, ended by the runner's own `endSheet` and landing
as one DELETE, the list following by its watch and the outcome drawn; a
deployment scaled from the `=` sheet (drawn) 1 → 3, the scale
subresource patched and its row 3/3 by the watch; on `fake-prod` Delete…
greyed until the switch (⌫ only saying so, drawn, nothing sent), the
switch asked naming it, the band saying writes are on (drawn), then ⌫
asking for the name — a wrong one sending nothing, the right one
landing — and writes off again, fake-prod's proxy refusing a POST once
more; on `fake-dev` every write greyed with why and nothing reaching the
fake, not even a review; and Kubernetes off stopping every
forward, its kubectl ended;
the page with Kubernetes off; and that every kubectl it started ends —
the scenario's `exit` isn't the app's quit.

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
