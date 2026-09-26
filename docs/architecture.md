# Architecture

One process, one window (for now), everything on the main thread except
libghostty's own threads and git calls.

## Window layout

```
┌──────────── tab strip (SwiftUI, in the title bar) ─────── ± +N −M ┐
├──────────┬──────────────────────────┬──────────────┬──────────────┤
│ sidebar  │ terminal container       │ editor pane  │ changes pane │
│ Files /  │ (every tab's TerminalView;│ (opens on a  │ (± badge,    │
│ Worktrees│  only the selected one   │  file click) │  View ▸      │
│ Snippets │  visible)                │              │  Changes or  │
│ (⌘B)     │                          │              │  ⌥⌘D; Warp-  │
│          │                          │              │  style cards)│
└──────────┴──────────────────────────┴──────────────┴──────────────┘
      + ⌘P palette: an overlay over the whole content view
      + ⌘F search: an overlay over the terminal container; a compact find
        bar in its top-right corner while a terminal search is kept
```

- One split (`split`, vertical, autosave `TerminusColumns.v2`): sidebar | terminal | editor | changes. Bump the key's version whenever the column set changes, or stale positions get applied to the new columns.
- It is a `WideDividerSplitViewController` (grabbable 1 pt dividers). The terminal column keeps ≥ 240 pt.
- Sidebar, diff panel, tab strip, palette: SwiftUI in `NSHostingView`/`NSHostingController`. Terminal, editor text, editor header: AppKit.

## Ownership

`AppDelegate` → one `TerminalWindowController`, which owns:

| Object | Role |
|---|---|
| `TabStore` | ordered `Tab`s, selection, pinned-first invariant, drag reorder |
| `Tab` | a `TerminalView` + title, custom name, colour, pin, agent, cwd, `TabActivity` |
| `FileTreeModel` | tree of the selected tab's checkout; lazy listings, FSEvents invalidation, gitignore dimming |
| `WorktreeModel` | `git worktree list` of that repository |
| `DiffModel` | that checkout's changes — uncommitted, or everything on its branch (see Changes pane) — counts (always live — the ± badge), per-file diffs and why each file changed (only while the pane is open), stage/discard/commit; works before the first commit (empty-tree base) |
| `SnippetStore` | `~/Library/Application Support/Terminus/snippets.json` |
| `PaletteModel` | ⌘P query and ranking |
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
| `NEW_TAB`, `CLOSE_TAB`, `GOTO_TAB`, `MOVE_TAB` | the window's tab operations (the user's Ghostty keybinds drive Terminus tabs) |
| `CLOSE_WINDOW`, `CLOSE_ALL_WINDOWS` | window close (with confirmation) |
| `TOGGLE_COMMAND_PALETTE` | Terminus palette |
| `START_SEARCH` | the ⌘F overlay (with Ghostty's needle, if any) |
| `END_SEARCH`, `SEARCH_TOTAL`, `SEARCH_SELECTED` | `TerminalSearch` → the overlay's terminal row and the compact bar's `3/12` |
| `RING_BELL`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `COMMAND_FINISHED` | `TabActivity`: `isWorking` + a ranked mark (waiting > failed > done) → tab strip (breathing glyph + sliding bar / ringing yellow dot / green check / red mark), notification, Dock badge |
| `OPEN_URL` | ⌘-click on a link libghostty matched: `FileLink` (shell dir, then checkout; `:line[:col]`, `(line,col)`) → the editor at that line; URLs, directories, binaries → system opener |
| `MOUSE_SHAPE`, `QUIT` | handled directly |
| `NEW_SPLIT`, `GOTO_SPLIT`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM` | the tab's splits (Ghostty's defaults: ⌘D, ⇧⌘D, ⌘[ ⌘], ⌥⌘arrows, ⌃⌘arrows, ⌃⌘=, ⇧⌘↩) |
| anything else (new window, …) | returns false: unhandled |

`close_surface_cb` (shell exited, or Ghostty's ⌘W) → `closeTab` (pinned tabs
ignore it unless the process actually exited).

## Splits

A tab is a `SplitTree<TerminalView>` (`Sources/Terminus/Splits/`): a
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

`MergedWorktrees` (`Sources/Terminus/Git/`) decides which linked worktrees
are done with; `WorktreeModel.merged` holds it, refreshed with the list.
A branch is merged when

- its upstream is `[gone]` — pushed, then deleted on the remote: GitHub's
  delete-on-merge, and the only trace a squash merge leaves; or
- it has an upstream and its tip is reachable from the default branch
  (`origin/HEAD`, else the main worktree's branch).

Never pushed never counts: a New Task branch with no commits is reachable
from main too. A worktree whose folder was deleted by hand (`prunable`) is
cleanable as well. Rows get a purple merge mark; the Worktrees header gets a
count that runs **Clean Up Merged Worktrees…** (also File menu, ⌘P, a row's
menu): `git fetch --prune` (ssh in BatchMode), then one sheet listing what
goes and what stays — kept: a tab in it, uncommitted changes, locked. It runs
`git worktree remove` without `--force` and, if ticked, `git branch -D`
(`-d` refuses a squash-merged branch). The Worktrees reload button fetches too.

## Changes pane

The fourth column (`Sources/Terminus/Diff/`): `DiffModel` for the selected
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

- **Which transcripts** (`ClaudeEditsReader`, `Sources/Terminus/Info/ClaudeEdits.swift`):
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

## Agent overview (⇧⌘A)

Every tab as a card over the window (`Sources/Terminus/Agents/`), refreshed
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

Everything GitHub goes through the user's own `gh` (`Sources/Terminus/GitHub/`;
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

`SpotlightModel` (`Sources/Terminus/Search/`), rows in this order:

| Row | Source | Return |
|---|---|---|
| Terminal | libghostty's own search (`search:<needle>` binding action; totals come back as `SEARCH_TOTAL`) — highlights live behind the overlay | keeps the search, shows `TerminalSearchBar` (Return / ⇧Return / Esc) |
| File | `git ls-files --cached --others --exclude-standard` of the checkout (`diff.root ?? tree.root`), loaded once per open, fuzzy-ranked with the name weighted over the path | opens it in the editor |
| In file | `git grep -F -i -I --untracked`, ≥ 2 characters, 150 ms debounce, capped per file and in total | opens it at that line (`EditorViewController.go(toLine:)`) |

Without a checkout only the terminal row is shown. Esc (or a click outside)
ends the terminal search too; only choosing the terminal row keeps it.

## Tab Info (⌘I, or Show Info… on a tab)

A popover per tab, live while open (`TabInfoModel`, `Sources/Terminus/Info/`):

| Section | Source |
|---|---|
| Location | tab cwd → checkout, branch, worktree-of, changed files (git) |
| Running | `ProcessInspector`: everything under the tab's `login` (paired to its surface by `SurfaceProcesses`, since libghostty doesn't expose the pid), plus anything tagged `TERMINUS_TAB_ID` that left the tree. CPU% from task-time deltas (Mach ticks → ns), resident memory. Links via sysctl KERN_PROC — proc_pidinfo refuses root's `login`. |
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

## Opening from Finder

`Info.plist` (`Scripts/make-app.sh`) declares folders and text/source/any
files at `LSHandlerRank` Alternate — listed under Open With, never the default
— and an `NSServices` entry, "New Terminus Tab Here" (`NSRequiredContext`
makes it on by default). `AppDelegate.application(_:open:)` and
`AppDelegate.newTabHere` (the service; `NSApp.servicesProvider = self`) both
call `TerminalWindowController.open(_:)`. `make install` runs `lsregister -f`
and `pbs -update` so Finder sees a change at once. `public.data` alone did not
get files listed; the explicit text types did.

## Microphone and other privacy prompts

macOS charges what a program in the terminal asks for to Terminus, the app
it runs in. `Info.plist` therefore carries `NSMicrophoneUsageDescription`,
`NSSpeechRecognitionUsageDescription` and `NSAudioCaptureUsageDescription`
(Ghostty's wording): without them macOS refused the microphone without asking
— Claude Code's `/voice` got silence, and Terminus never appeared in System
Settings ▸ Privacy & Security ▸ Microphone. Now the first request asks; the
setting is there to change it. The `terminal` scenario checks the keys.
An ad-hoc signed build is a new app to macOS each time, so the answer would
not survive a reinstall; `make install` re-signs the installed copy with
`SIGN_IDENTITY` (environment or the untracked `local.mk`) when it is set, and
one identity keeps the grant (README, Build).

## Build metadata

`Scripts/make-app.sh` writes what About Terminus shows into `Info.plist`:

| Key | From |
|---|---|
| `CFBundleShortVersionString` | `VERSION` — SemVer, bumped by each commit that changes the app (CLAUDE.md, Commits) |
| `CFBundleVersion` | `git rev-list --count HEAD`: the build number, growing with every commit on main |
| `TerminusCommit` | `git rev-parse --short HEAD`, plus `-dirty` when `git status --porcelain` lists anything |
| `TerminusBuildDate` | the day it was built, `YYYY-MM-DD` |

`VERSION` and `BUILD` in the environment override the first two. Without git
(a copy of the tree, no repository) the build is 1 and the commit `unknown`.

About Terminus (`AppDelegate.showAbout` → `AboutPanel.show`) is the standard
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
promises and text (`Sources/Terminus/Ghostty/TerminalDrop.swift`). A drop is
a paste (`insertText`), never Return: the references separated by spaces,
with a trailing space; the pane gets the keyboard.

- **What a drag carries** (`TerminalDrop.payload`), in order: file URLs
  (Finder, the Desktop, the sidebar — reference URLs resolved to paths);
  else file promises (Photos, Safari, the screenshot thumbnail), received
  into a folder of their own under `AppEnvironment.dropsDirectory`
  (~/Library/Caches/io.github.terminus-app.terminus/Drops; an isolated run's own);
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

## Opening files in another app

A file leaves Terminus — the file tree's double-click, its menu's **Open in
<App>**, the editor header's ↗ — in the app the user picked, not the macOS
default for its type (that was Antigravity for `.md`, Xcode for
`Package.swift`, Ghostty for `.sh`). `ExternalOpener` (`Sources/Terminus/Editor/`):

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
  returns. One entry per bundle id; Terminus itself (it claims text files for
  Finder) never.
- An isolated run's `AppCatalog` is `IsolatedApps`: its scenario installs
  stand-in apps and it records what it would have opened — an E2E run never
  launches anything, as it never touches the real clipboard.

Web links from the terminal and Tab Info's ports still go to the system
opener (the browser).

## Persistence

| What | Where |
|---|---|
| Tabs (cwd, name, colour, pin, agent) + selection | `~/Library/Application Support/Terminus/session.json` (1 s debounced + on quit) |
| Shell panes' text (last 2000 lines, plain) | `…/Terminus/scrollback/<uuid>.txt`, named in session.json; written once, at quit or window close |
| Snippets | `…/Terminus/snippets.json` |
| Sidebar/changes visible, sidebar panel, changes scope | `UserDefaults` (`sidebarVisible`, `diffVisible`, `sidebarPanel`, `diffScope`) |
| The app files open in | `UserDefaults` (`openWithApp`, a bundle id) |
| Files dropped as promises (Photos, Safari) | `~/Library/Caches/io.github.terminus-app.terminus/Drops/<uuid>/` (`AppEnvironment.dropsDirectory`) |
| Divider positions | `UserDefaults` split autosave (`TerminusColumns.v2`) |

Bundle id `io.github.terminus-app.terminus`.

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
