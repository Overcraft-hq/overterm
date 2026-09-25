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
| `DiffModel` | that checkout's changes — uncommitted, or everything on its branch (see Changes pane) — counts (always live — the ± badge), per-file diffs (only while the pane is open), stage/discard/commit; works before the first commit (empty-tree base) |
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
| Divider positions | `UserDefaults` split autosave (`TerminusColumns.v2`) |

Bundle id `ai.promptrails.terminus`.

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
