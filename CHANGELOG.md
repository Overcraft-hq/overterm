# Changelog

What changed in each version of Overterm, newest first. `VERSION` is the
version ([SemVer](https://semver.org)): a commit that changes the app bumps it
— major, minor or patch, as CLAUDE.md's Commits section sets out — with
`Scripts/bump-version.sh`, which adds the line here. The commit that brings a
version is tagged `v<version>`.

## 1.5.0 — 2026-10-30

- docker: Docker's work on a page of its own (⌥⌘P) — the containers of the engine your terminal's `docker` reaches, grouped by compose project and kept current as they start, stop and crash; a container's logs followed and coloured by level, its inspect data with secrets masked, its CPU, memory and network; single keys while the list has the keyboard, `?` lists them
- docker: the rail's shippingbox keeps the selected tab's checkout's stack beside the terminal, a container's logs a click away in the right-hand pane
- docker: ⇧⌥⌘P finds any container or compose project by name, from anywhere
- docker: images (pulled with their progress, tagged, their layers), volumes with their sizes and who mounts them, networks with who is on them; Clean Up lists what nothing uses before anything goes
- docker: a container that crashes, runs out of memory or turns unhealthy marks its checkout's tab, as a failed command does
- docker: `d` on a PostgreSQL, MySQL or ClickHouse container opens it in the Database panel, its connection filled in from the container
- docker: a container's files — browse its folders, open a config in the editor, and the save goes back into the container
- docker: agents started in Overterm read Docker through MCP — containers, projects, logs, why one failed — with secrets kept out; starting, stopping, compose and exec are asked about in the window each time
- docker: a compose project's logs merged as `compose logs` merges them, each service in its colour
- docker: two stacks wanting the same port — the one that couldn't start says which stack, or which tab's process, has it, and stops that one for you
- docker: any context the `docker` CLI knows, picked for Overterm alone; Docker Desktop, OrbStack and Colima started, stopped and restarted from the page
- docker: `n` runs an image from a window that writes the `docker run` as you fill it in; any container copies as the `docker run` that would make it again
- docker: a container's processes, and the files it changed since it started
- docker: a compose project's file and its resolved config, and the engine's own settings, open in the editor
- docker: `E` opens a debug shell beside a container whose image has no tools of its own
- docker: the ports a checkout's containers publish sit in its panes' headers, in Tab Info and in the API client's discovery
- docker: a volume exports, imports and clones; a container's filesystem and an image save as tars
- tasks: New Task can start the new worktree's compose stack with it
- docker: Builds shows what buildx kept of each — how long, how much from cache, its log, the Dockerfile a click away
- docker: Docker Hub is searched as you type the image to pull
- docker: Docker Desktop's update check, diagnose and Kubernetes status in the engine menu, in a terminal tab
- docker: an `ssh://` context reaches a remote engine through your own ssh, its ports opening on the host
- docker: Docker Model Runner's models — which are loaded, what they take — with a chat in a tab and the OpenAI base URL to give your code
- docker: with Docker's MCP Toolkit, the page says whether your agents reach its MCP servers, and connects them in a tab
- docker: Rancher Desktop started, stopped and asked about through `rdctl`
- docker: Docker Scout looks an image over in a tab
- docker: every detail has its actions as buttons — the same ones its right-click menu has; a network's puts a container on it or takes one off
- docker: a checkout's compose project shows before it has run, ready to bring up
- docker: a compose service rebuilt, restarted or pulled on its own; Watch, and Up with profiles
- docker: a worktree's stack comes up on free ports when another worktree's holds them — the repository stays untouched
- docker: a database container's own client in a tab — psql, mysql, redis-cli, mongosh… — its password never on the command line
- docker: ask an agent why a container failed — its state, last logs and compose service, secrets left out; selected log lines with ⌘L
- docker: a container running under emulation on Apple silicon says so, with what to do
- docker: CPU and memory columns in the container list
- docker: Testcontainers' containers apart, by test run, removed together
- docker: a container's memory, CPUs and restart policy changed in place; renamed; saved as an image
- docker: a volume's files browsed, opened and saved back, as a container's are
- docker: files dragged from Finder into a container, and out of it
- docker: Check for Updates asks the registries whether your images have newer builds, and pulls them
- docker: a build shown as it runs, step by step with its time and cache

## 1.4.6 — 2026-10-29

- sidebar: the rail's panels in your order, a compact rail, and the panel a new window opens on

## 1.4.5 — 2026-10-27

- tabs: dragging tabs and islands to reorder works by hand — the strip is the title bar now, the dragged tab follows the pointer into and out of islands; in full screen the strip comes down with the traffic lights
- api: an import goes into the collection you picked, My Requests too; the collection menu makes more collections — in the checkout, or your own on this Mac
- api: New Request opens at once and sends before it is saved, as in Postman — ⌘S names it and puts it in the collection; closed unsaved, it is gone
- api: a request in a narrow pane keeps its left edge — Params, the status and Body were cut off

## 1.4.2 — 2026-10-26

- groups: tabs inside an island and the island's chip can be dragged — a press there no longer moves the window
- window: full screen shows the tab strip — no black band over it; the toolbar is put away while full screen lasts
- usage: Opus 4.5–4.8 priced at their own list price — they were counted at Opus 4's, three times over
- usage: 30 days counts all of a big transcript — anything past its last 64 MB was left out; a transcript being written is read only where it grew
- usage: every Claude Code config folder on this Mac counts — sessions run under CLAUDE_CONFIG_DIR (`~/.claude-work`…) were missing, and the limits come from the newest of them

## 1.4.1 — 2026-10-26

- session: both islands come back — restoring one no longer drops the other's tabs
- window: full screen keeps the tab strip — the toolbar it lives in no longer hides
- groups: an island dragged by its chip moves right as well as left, its tabs in their order
- terminal: ⌘V pastes a screenshot into Claude Code and Codex — with only an image on the clipboard, the agent gets the ⌃V it reads images on
- sidebar: Sessions and Snippets can be switched off in Settings ▸ General — the panel, its icon and the palette's snippets with it
- notes: a task being edited shows its `- [ ]` without a box drawn over it, as a list item shows its `-`

## 1.4.0 — 2026-10-25

- database: a database client in the sidebar — PostgreSQL, MySQL, SQLite, Redshift, ClickHouse and BigQuery; any .sql file a console with ⌘↩, completion from your schema, results in a grid to sort, copy and export, history; passwords and keys in your keychain (⌥⌘B)
- database: S3 and Google Cloud Storage in the Database panel — AWS, DigitalOcean Spaces, MinIO, R2 and any S3 endpoint; browse buckets, preview files (CSV as rows, JSON, logs, images, PDFs), upload from Finder, download, delete, share a link
- database: connections through an SSH tunnel — a database behind a bastion, with your ~/.ssh config, keys and agent; the password or passphrase in your keychain
- database: agents can use your databases and buckets — Claude Code reads a schema, runs a query that reads, lists and reads files in S3/GCS over MCP; a write is shown to you first, off unless you allow it
- tabs: Suspend Tab and Suspend Other Tabs in a tab's menu — everything running in it stopped where it is, no CPU, until Resume carries on; the strip counts what is suspended

## 1.3.0 — 2026-10-25

- notes: a notes vault in the sidebar that is your Obsidian vault — Live Preview and a reading view with mermaid and math, backlinks, tags, tasks and a graph, [[ completion, renames that keep links, daily notes and templates, terminal output to a note, and MCP tools for agents to read it (⌥⌘N)
- overgit: Pull Requests shows the repository's list — an error from a tab outside a repository, or a worktree git can't follow, no longer hides it
- overgit: a pull request clicked in Overgit opens in the right-hand pane, any branch's — ↗ still opens GitHub
- groups: Rename Group… and a double-click on an island's chip rename it — the field took no keys before
- overgit: stage and commit from Overgit — a Changes section with each file's box, Stage All, the message, Amend, and Push or Publish Branch
- overgit: search the history — words in the message, a hash, and author:, path:, code:, since:, branch: filters
- overgit: compare two branches, tags or commits in the right-hand pane — the commits on each side and every file's diff since they parted
- browser: the browser and the simulator each have their own switch in Settings ▸ Browser — off, its button leaves the title bar

## 1.2.0 — 2026-10-21

- api: an API client in the sidebar that is Bruno's files — requests, environments, scripts and tests, a runner, imports from OpenAPI, Postman, .http and cURL, My Requests, and MCP tools for agents (⌥⌘R)

## 1.1.0 — 2026-10-21

- sidebar: the panels move to a rail down the left edge, with Settings and Hide Sidebar at its foot
- tabs: a group's island is the height of the tab beside it, and the strip keeps its distance from the traffic lights

## 1.0.0 — 2026-10-21

The first public release: a macOS terminal for working with agents —
libghostty inside a Swift/AppKit app, built for several worktrees at once,
each with an agent in it.

- Tabs that say what is happening in them: working, done, failed, needs you — with notifications, a Dock badge and ⌥⌘↓ to the next one
- Tab groups as islands in the strip: collapse, stash, focus, broadcast
- Agent Inbox (⌘I): every agent waiting on you, answered from one list
- Changes pane with stage, discard and commit, and why each file changed
- Splits with a header per pane (status, ports, island), and Tab Peek
- Command blocks, the ⌘K palette over what this machine has run, live ports, ⌘L to hand a selection to an agent, ⌘F search over scrollback and files
- Usage: what is left of Claude's and Codex's windows, read from their own files
- New Task (worktree + branch + agent), merged-worktree cleanup, pull requests and CI through `gh`, Claude sessions
- Overgit: the git panel in the sidebar, and a commit's detail
- An editor beside the terminal: tree-sitter highlighting, language servers, Markdown preview, file actions
- A browser column per tab, with its own pages and an MCP server agents can drive, and the iOS simulator beside it
- Themes, settings.json and keybindings.json, and session restore
