<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-on-dark.png">
    <img alt="overterm" src="docs/assets/banner-on-light.png" width="640">
  </picture>
</p>

<p align="center">
  <b>A macOS terminal for working with agents.</b><br>
  Several worktrees at once, an agent in each, and a window that tells you which one needs you.
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-1d1d1f">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-arm64-1d1d1f">
  <img alt="Swift 6.1" src="https://img.shields.io/badge/Swift-6.1-f05138">
  <img alt="libghostty v1.3.1" src="https://img.shields.io/badge/libghostty-v1.3.1-2bb35d">
</p>

<p align="center">
  <img alt="The overterm window: sidebar, terminal, pane header" src="docs/assets/screenshot-window.png" width="900">
</p>

The terminal itself is [libghostty](https://github.com/ghostty-org/ghostty)
(`GhosttyKit`) inside a Swift/AppKit app, so your `~/.config/ghostty/config`
— font, theme, keybinds — applies as it is. Everything around it is built for
one thing: keeping five or ten agent sessions straight.

---

## What it does

### Tabs that say what is happening in them

<img alt="Tabs marked done, working, waiting and failed" src="docs/assets/screenshot-tabs.png" width="900">

Each tab carries what it is (agent, server, shell, ssh) and what it wants:
**working** (a spinner), **done**, **failed**, or **needs you** — a bell, or an
agent's permission prompt. In the background it is also a macOS notification
and a Dock badge, and ⌥⌘↓ jumps to the next one. Claude Code needs no setup
for it: it already speaks the Ghostty notification and progress sequences.

### Groups, as islands in the strip

Tabs of one checkout become an **island**: a coloured chip, its own run in the
strip, and the tabs' marks summed on it. Collapse one, **stash** it out of the
way (it keeps running), **focus** on it so the strip shows nothing else, or
**broadcast** a line into every tab in it. ⌃⌘1…9 go straight to one.

A new tab never silently joins an island — ⌘T and the strip's `+` open outside
it; the island's own `+` opens inside it.

### Agent Inbox (⌘I)

Every agent waiting on you in one list, most urgent first, with the question
and its choices read off the screen: **Approve ↩**, **Always allow**,
**Deny ⌫** — answered where you are, without walking the tabs.

### Changes, with the reason each file changed

<img alt="The changes pane beside the terminal" src="docs/assets/screenshot-changes.png" width="900">

The ± badge counts the tab's worktree; the pane shows the files, live, with
**Uncommitted** (stage, discard, commit) or **Branch** (everything since the
branch left `main`, its commits listed). Each file can say *why* it changed:
what Claude said when it edited it, read from Claude Code's own session files
on this Mac — nothing leaves it.

### Panes, and a card of every tab

<img alt="Tab Peek: every tab as a card" src="docs/assets/screenshot-peek.png" width="900">

Split a tab (⌘D, ⇧⌘D) and every pane gets a 38 pt header: what runs in it,
its island, its status, the ports it listens on, and split / zoom / close.
Drag a tab onto a pane to split with it. **Tab Peek** (⇧⌘E, or three fingers
down) scales every tab into a card.

### The things a terminal should have known

- **Command blocks** — what a command printed, how long it took and how it
  ended; a failed one is ringed in the grid, with **Copy output** (⇧⌘C) and
  **Rerun** (⌘R) pinned in the pane's header. A gutter down the pane's edge
  maps the blocks in the scrollback.
- **⌘K palette** over your actions, tabs, worktrees, snippets and **what this
  machine has actually run** — this folder's commands first, with the exit
  code and how long they took. ↩ runs, ⌥↩ pastes without running.
- **Live ports** — a pill in the pane header for whatever is listening:
  open it, copy the URL, or kill the exact pid.
- **⌘L** hands the selection to an agent, with the command it came from, the
  exit code and the diff, if you want them.
- **Search** (⌘F) — one overlay over the scrollback, the checkout's file names
  and their contents. ⌘-click a `path:line` in the output to open it in the
  editor at that line.
- **Drop files on a terminal** from Finder, Safari, Photos or the sidebar: a
  shell gets quoted paths, Claude Code gets `@`-mentions and images it can
  read. Nothing runs until you press Return.

### What the agents are costing you

<kbd>⌥⌘U</kbd>, or the gauge at the right of the strip: what is left of
Claude's five-hour and weekly windows and of Codex's, with the countdown to
each reset, and what the day's tokens would cost at list prices. Both are
read from the files the agents write on this Mac — nothing is asked over
the network, and nothing needs a key.

### An API client that is Bruno's files

<kbd>⌥⌘R</kbd>, or the rail's ⇄: the checkout's [Bruno](https://www.usebruno.com)
collection — its requests by folder, its environments — and a request opens
beside the terminal with Bruno's tabs (params, body, headers, auth, vars,
scripts, assert, tests, docs) and the response under them. Scripts and tests
run as in Bruno (`bru`, `req`, `res`, `expect`), a collection or a folder runs
top to bottom into a Runner, and the files stay Bruno's: an edit here is a
minimal edit to the `.bru` file you commit, and Bruno and `bru run` open the
same collection. No collection yet? It offers the OpenAPI document in the
checkout, or the one the tab's dev server publishes, and imports Postman,
`.http` files and a cURL command too. Agents get it over MCP: list the
requests, send one with its tests, run the collection.

### Notes that are your Obsidian vault

<kbd>⌥⌘N</kbd>, or the rail's note: a folder of Markdown — your Obsidian
vault as it is, in iCloud or anywhere — beside the terminal. Notes open in
Live Preview (headings, links, tasks as they read; the Markdown on the
line you are editing) or the reading view, with mermaid diagrams, math,
callouts, embeds and code drawn offline. Backlinks, outline, tags, tasks
and a graph; `[[` completes your notes; a rename takes its links with it;
today's note, templates and pasted images go where Obsidian's settings
put them. A terminal selection or a command's output goes into today's
note in a click, and agents can search and read the vault over MCP —
never write to it.

### A database client, DataGrip's work

<kbd>⌥⌘B</kbd>, or the rail's cylinder: PostgreSQL, MySQL, SQLite, Redshift,
ClickHouse and BigQuery — the connections with their schemas, tables and
columns, and any `.sql` file a console under the editor: ⌘↩ runs the
statement at the caret, completion knows your tables and an alias's
columns, results land in a grid you sort, copy and save as CSV, JSON,
Markdown or INSERTs. Passwords and BigQuery's service account keys stay in
your keychain; a read-only connection refuses anything that writes, and a
DROP or an UPDATE without WHERE is asked about first. A database behind a
bastion connects through an SSH tunnel, with your own `~/.ssh` setup.

S3 and Google Cloud Storage sit in the same panel — AWS, DigitalOcean
Spaces, MinIO, R2, B2, Wasabi or any S3 endpoint: browse buckets and
folders, preview a file (CSV as rows, JSON and logs as text, images, PDFs),
drop files and folders from Finder to upload them, download, delete, copy a
link that works for an hour.

Claude Code started in Overterm can use them too, through MCP: list your
connections, read a schema, run a query that reads, browse a bucket and
read a file — never seeing a password. A write is shown to you first, and
only if you allow agents to ask (Settings ▸ Database).

### Docker, Docker Desktop's work

<kbd>⌥⌘P</kbd>: the containers of the engine your terminal's `docker`
reaches — Docker Desktop, OrbStack, Colima — on a page of their own,
grouped by compose project, kept current as they start, stop and crash.
<kbd>⇧⌥⌘P</kbd> finds any container or project by name from anywhere.
Single keys while the list has the keyboard: `s` starts or stops, `r`
restarts, `e` opens a shell in a tab, `E` a debug shell beside an image
with none, `t` follows its logs, `o` opens its
port, `u` and `D` bring a project up and down — in a terminal tab, where you
see the command. Filter with `status:running project:api port:5432`;
`?` lists the keys. `n` runs an image with a window that writes the
`docker run` as you fill it in; any container copies as the `docker run`
that would make it again. A compose project's services' logs are merged as
`compose logs` merges them, each service in its colour. A container's logs are followed as they are written,
coloured by level and filtered, and picked up again after a restart; its
inspect data and its CPU, memory, network and disk sit beside it. Secrets
in a container's environment stay masked. Images (pulled with their
progress, tagged, their layers), volumes with their sizes and who mounts
them, and networks with who is on them sit in sections of their own, and
Clean Up lists what nothing uses before anything goes. Every detail has
its actions as buttons, the same ones its right-click menu has; a
network's puts a container on it or takes one off. A volume exports,
imports and clones; a container's filesystem and an image save as tars.
Builds show what buildx kept of each — how long, how much from cache, its
log, the Dockerfile a click away. Models lists Docker Model Runner's local
LLMs — which are loaded, what they take — with a chat with one in a tab
and the OpenAI base URL to give your code. An `ssh://` context reaches a
remote engine through your own ssh, its ports opening on the host. Docker
Scout looks an image over in a tab. With Docker's MCP Toolkit, the page
says whether Claude Code and Codex reach its MCP servers, and connects
them in a tab. The rail's shippingbox keeps the
selected tab's checkout's stack beside the terminal — before it runs too:
its compose file's services as Compose will make them, with Up (`u` on
the page) to start them — a container's logs a click away in the
right-hand pane, and the ports its containers publish
sit in its panes' headers beside the ones its own processes listen on. A
container that crashes, runs out of memory or turns unhealthy marks the
tab whose checkout it belongs to, as a failed command does. Two
worktrees' stacks wanting the same port: the one that couldn't start says
which stack, or which tab's process, has it — and stops that one for you. `d` on a
PostgreSQL, MySQL or ClickHouse container opens it in the Database panel,
its connection filled in from the container. A container's files are a
tab of its own: browse its folders, open a config in the editor, and the
save goes back into the container.

Claude Code started in Overterm can read Docker too, through MCP: the
containers and compose projects, a container's logs, why it failed, what
it uses — secrets kept out. Starting, stopping, compose and exec are asked
about in the window each time, and Settings ▸ Docker can take them away.

### And the work around the work

**New Task** (⇧⌘N) makes a worktree, a branch and a tab with an agent started
in it — and, with a compose file in the repository, can start the worktree's
own stack. **Merged worktrees** are marked and cleaned up in one click, keeping
anything with changes, a tab or unpushed commits. **Pull requests** and CI
(through your `gh`) sit on the worktree, in the strip, and in a pane of their
own. **Claude sessions** lists every conversation ever run in the repository,
and resumes one where it ran. The **editor** opens a file beside the terminal;
a double-click opens it in the app you chose.

Tabs, their names, colours, pins, directories, splits and islands come back on
relaunch — shell panes with their last 2000 lines, agent tabs resuming their
conversation.

---

## Install

**Homebrew.**

```sh
brew install --cask overcraft-hq/tap/overterm
```

**Without Xcode — the release DMG.** Download `Overterm-<version>.dmg` from
[Releases](https://github.com/Overcraft-hq/overterm/releases), open it and drag
**Overterm** to **Applications** (Apple silicon, macOS 13+). It is signed ad hoc
and not notarized, so macOS stops the first open: right-click → **Open** (macOS
15 and later: System Settings → Privacy & Security → **Open Anyway**), or

```sh
xattr -dr com.apple.quarantine /Applications/Overterm.app
```

**With Xcode — from source.** The Command Line Tools alone can't build
GhosttyKit; it needs `xcodebuild` and the Metal compiler.

```sh
mise trust && mise install   # the pinned Zig
make ghosttykit              # GhosttyKit from the pinned Ghostty (once, ~2 min)
make install                 # build Overterm.app and copy it to /Applications
```

## Keys

The defaults; every one of them is rebindable in Settings ▸ Keyboard Shortcuts
(or `keybindings.json`), menu items and the terminal's keys alike.

| | |
|---|---|
| ⌘T / ⌘W | New tab / close the pane, else the tab |
| ⌥⌘C / ⌥⌘X | New Claude / Codex tab here |
| ⇧⌘N | New Task — worktree, branch, agent |
| ⌘K | Command palette: actions, tabs, worktrees, snippets, history |
| ⌘I | Agent Inbox · ⌃⌘I Tab Info · ⇧⌘A agent overview |
| ⌥⌘↓ | Jump to the next failure or tab that needs you |
| ⌘D / ⇧⌘D | Split right / down · ⌘[ ⌘] between panes · ⇧⌘↩ zoom |
| ⌃⌘N / ⌃⌘G | Group the selected tabs / the group switcher |
| ⌃⌘1…9 | Go to a group · ⌃⌘F focus · ⌃⌘S stash · ⌃⌘B broadcast |
| ⌘R / ⇧⌘C | Run the last command again / copy its output |
| ⌘↑ / ⌘↓ | Previous / next prompt |
| ⌘L | Ask an agent about the selection |
| ⌘F | Search the terminal and the files |
| ⌘B / ⌥⌘D | Sidebar / changes |
| ⇧⌘E | Tab Peek (or three fingers down) |
| ⌘, / ⌥⌘O | Settings / what's new |
| ⌘-click | Open a printed `path:line` in the editor |
| ⌥ while dropping | Plain quoted paths, even where Claude Code runs |

## Settings

⌘, opens a tab, not a window. Every section switches between controls and the
JSON behind it — `settings.json` and `keybindings.json` in
`~/Library/Application Support/Overterm/`, VS Code's two files, editable by
hand (only what you changed is in them, comments are fine, and a hand edit
applies at once). General, Appearance, **Themes**, Terminal (over your Ghostty
config, applied to open terminals immediately), Agents, Editor, Notifications,
Keyboard Shortcuts, and About — the version, what's new, and updates from
GitHub releases.

**Themes** is a gallery, not a menu of names: each one drawn as a little
window in its own colours. It opens on ten — the ones people name — and
**All** is the whole catalogue of 473: Ghostty's own, ten more bundled beside
them, and anything in your `~/.config/ghostty/themes`, marked *Yours*. Pick
one and the terminals you have open change as you do — the strip, the
sidebar and the panes with them. "Follow macOS between a
light and a dark theme" keeps one of each and switches with the system.

## Build

Requirements: macOS 13+, Xcode 16 or 26.2, [mise](https://mise.jdx.dev).
Newer SDKs don't work yet: the pinned Zig 0.15.2 can't link against the macOS
26.5 and 27 SDKs (their libSystem lists only arm64e), and Xcode 27's SwiftPM
builds an app macOS runs in 13.0 compatibility mode. With such an Xcode
selected, point the shell at a supported one; the system's choice stays:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.app/Contents/Developer
```

Xcode 26 downloads the Metal compiler separately — if `make ghosttykit` can't
find `metal`: `xcodebuild -downloadComponent MetalToolchain`.

```sh
mise trust && mise install   # the pinned Zig
make ghosttykit              # GhosttyKit from the pinned Ghostty (once, ~2 min)
make hooks                   # git hooks: version bump check, release tags (once)
make test                    # unit + integration tests (~30 s)
make e2e                     # end-to-end scenarios in the real app (~2 min)
make run                     # build Overterm.app and open it
make install                 # …and copy it to /Applications
```

Builds are signed ad hoc, which makes every one of them a new app to macOS: a
permission such as the microphone would be asked for again after each update.
Set `SIGN_IDENTITY` — in the environment, or an untracked `local.mk` next to
the Makefile — and `make install` re-signs the installed copy with it, so the
grants stay (`make app`, `test` and `e2e` stay ad hoc and never touch the
keychain):

```make
# local.mk (gitignored); list yours with: security find-identity -v -p codesigning
SIGN_IDENTITY ?= Apple Development: Your Name (TEAMID1234)
```

## Releasing

Push the commit and its `v<VERSION>` tag (`git push origin main --tags`), then
GitHub → Actions → **Release** → Run workflow: a macOS runner tests, builds the
app and a DMG, and publishes `v<VERSION>` with that version's `CHANGELOG.md`
entry as the notes. It refuses a version already released — bump first.
Nothing triggers it on push. Locally, the same pieces are `make app dmg` and
`Scripts/release-notes.sh`.

## Versioning

`VERSION` holds the version ([SemVer](https://semver.org)), `CHANGELOG.md` what
each version changed, and the commit that brings a version is tagged
`v<version>`. **Overterm ▸ About Overterm** shows it — "Version 1.30.0 (147)",
the brackets counting commits — with the commit it was built from and the day.

```sh
make hooks                                          # once per clone
Scripts/bump-version.sh minor "tabs: what changed"  # or patch, major
git add VERSION CHANGELOG.md                        # commit them with the change
```

The pre-commit hook refuses a change to the app without a new VERSION; the
post-commit hook adds the tag. Tags stay local until you push them.

## Under the hood

Ghostty is pinned to v1.3.1 (`Scripts/build-ghosttykit.sh`); state lives in
`~/Library/Application Support/Overterm/` — `session.json`, `snippets.json`,
`history.json`, the saved scrollback.

More in `docs/`: [architecture](docs/architecture.md),
[the Ghostty embedding](docs/ghostty.md), [testing](docs/testing.md),
[debugging](docs/debugging.md). The house rules are in
[CLAUDE.md](CLAUDE.md).
