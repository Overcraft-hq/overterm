# Changelog

What changed in each version of Overterm, newest first. `VERSION` is the
version ([SemVer](https://semver.org)): a commit that changes the app bumps it
— major, minor or patch, as CLAUDE.md's Commits section sets out — with
`Scripts/bump-version.sh`, which adds the line here. The commit that brings a
version is tagged `v<version>`.

## 1.6.0 — 2026-11-13

- kubernetes: Kubernetes beside the terminal (⌥⌘J) — your kubeconfig's contexts, production marked everywhere and read-only unless you allow writes for the session; every kind and custom resource as a live list in the server's own columns, several namespaces at once, k9s's keys and `:` bar, ⌃⌘J for a context, namespace or pod, and an Overview of the cluster as cards
- kubernetes: any object's detail — its overview, dependency tree and health checks, its YAML edited in the editor and diffed with the cluster before Apply, its events, a workload's history with each change diffed, Compare with…; a Secret's values only on Show, masked; Helm releases read from the cluster's records
- kubernetes: in your terminals — a pod's or a workload's logs followed and merged, Terminal in This Context (a tab whose plain `kubectl`, `helm` and `k9s` reach that context, red on production), a pod's shell and attach, files copied in and out, port-forwards opened in the browser column, the Database or the API client
- kubernetes: writes on writable contexts only — delete, restart, scale, drain, roll back, debug, resize, Helm, Argo CD's and Flux's verbs — each checked with the cluster's access review and confirmed naming the context and the kubectl it equals, the name typed where it destroys; deleting or changing a GitOps object says what goes with it
- kubernetes: metrics — CPU and memory from metrics-server, and per context from Prometheus, on the lists and in a Metrics tab on pods, workloads, HPAs, nodes and namespaces from Live to 7 days: change markers, nodes' heat strips, request and limit shares, GPUs, your own saved queries, rightsizing from a week of usage, a chart expanded beside your terminal
- kubernetes: GitOps (`g`) — Argo CD and Flux on one screen, problems first, grouped by source, owner or destination; each object's detail says why, where from and what is applied
- kubernetes: beside your work — a checkout bound to what it deploys: its workloads and pods, the deployed commit against yours, the Argo CD and Flux objects that deploy it and whether this branch has reached the cluster; its tab marked when a pod crashes or a rollout stalls, and Ask Why hands an agent a scrubbed brief
- kubernetes: agents read the clusters through MCP (`k8s_get`, `k8s_logs`, `k8s_why`, `k8s_metrics`, `k8s_gitops`…), never a Secret's values, every answer scrubbed; they write only on the contexts `kubernetes.agentWrites` names, each call asked in the window
- docker: the containers list scrolls in half the time; env names with PASS, PWD, PASSPHRASE or PIN as a word (`RABBITMQ_DEFAULT_PASS`, `MYSQL_PWD`) look secret — their values were shown, handed to agents and copied onto a command line
- security: a word with a control character (a container's or chart folder's name, an env value, a dropped path) is written as an escape, never typed raw into a tab
- build: Xcode 27 builds the app, and an app built with it takes clicks on macOS 27; double-clicking the strip's empty space zooms the window there again
- window: built with macOS 26's SDK or later, the tab strip no longer sits on a grey glass band across the title bar
- usage: an isolated run never runs your own claude for its usage
- settings: security settings — a Kubernetes context's class or writes, the contexts agents may change — edited in settings.json outside the Settings page (an agent can write the file) take effect only after a banner in the window is answered: Keep or Revert
- editor: language servers hear of files changed outside the editor — an agent's, a checkout's, an `init`'s — so gopls and sourcekit-lsp no longer go stale, and rust-analyzer leaves the watching to Overterm
- terraform: HCL in the editor — Terraform, OpenTofu and Terragrunt files coloured; terraform-ls when it is installed; Validate (with no credential in its environment) puts terraform's problems on their lines; Format runs terraform fmt as one undoable edit, and on save where the checkout is already formatted; F12 and ⇧⌘O on variables, locals, modules and resources without a language server
- browser: each pane's MCP token opens only its own tools — the browser, API client, notes, database, Docker and Kubernetes tools of one agent's pane are no longer reachable with another pane's config, and every write an agent asks for names its tab and agent, "asked through MCP"

## 1.5.6 — 2026-11-13

- database: Prometheus, Loki and Tempo — PromQL graphed (and as a table), Targets, Alerts and Rules; LogQL's lines with their levels, filtered and followed Live; TraceQL's traces and a trace's waterfall, opened from a log line's trace id; metrics, labels and tags in the panel, a value a click from its query; a time window per connection; Basic or token auth, a tenant, a path behind a proxy, TLS and SSH tunnels
- database: queries saved by name under their connection (the console's bookmark), a click runs one

## 1.5.5 — 2026-11-13

- database: Redis, as Redis Insight has it — keys as folders (SCAN by pattern and type), each type's value read and edited in the right-hand pane with its TTL, new keys; the server's page (INFO, slow log, clients, Pub/Sub, Profiler); a console with command and key completion; TLS (rediss://), a redis:// URL pasted fills the form, a Redis or Valkey container opens as a connection, agents query it too
- database: a key's or a file's page opens beside a zoomed editor instead of behind it

## 1.5.4 — 2026-11-09

- database: a connection whose password can't be had says why — none saved, or the keychain refused — and saving one no longer fails silently
- notes: notes, files and folders drag in the panel — onto a folder, or beside a note — their links following
- notes: a character typed in Live Preview no longer shows as another for a moment ("." as "e")
- overgit: the branches have a filter, as the commits have a search
- search: ⌘F has tabs — All, Files, Notes, Terminal (⇥ steps through) — so the notes aren't under every file's lines
- palette: ⌘K redone — one size whatever is selected, its tabs under the field with their counts (⇥ steps through), the list in its groups, every item explained beside it
- tabs: a tab is as wide as its name, within the Tab width setting's bounds — a short name no longer sits in a half-empty tab
- api: a request's Bruno docs read rendered (Edit for the Markdown), what has docs is marked in the panel, and a folder's or the collection's open from it

## 1.5.3 — 2026-11-04

- appearance: the terminal's look tuned in Settings — translucency, ligatures, line height, contrast, cursor and selection colours, a background image
- appearance: the interface too — an accent colour, compact or comfortable density, a larger or smaller interface text, the space between the cards and their corners, pane headers only on a split tab, narrow or wide tabs, every tab's close button, tabs without icons
- themes: make your own — duplicate any theme and change its colours, or import one from iTerm2 (.itermcolors) or VS Code (Import…, or drop it on the themes)
- editor: the code can take the terminal theme's colours (Settings ▸ Editor ▸ Colours)
- themes: a theme of a group's own (its menu ▸ Terminal Theme), or by folder (`~/Projects/prod-* = Red Alert`) — a checkout told apart at a glance
- window: Presentation Mode (⌃⌘P) — the terminal alone and larger for a screen share, and back as it was

## 1.5.2 — 2026-11-02

- build: one weekly check for every pinned dependency — the Swift packages too, which Dependabot can't resolve here
- notes: typing at the end of a long note no longer jumps the page, and prose isn't offered the file's words as you type
- tabs: "N need you" goes when the tabs are seen, instead of staying with an empty list behind it
- terminal: a pane's header shows only the ports its own processes listen on — not a neighbouring pane's, nor the checkout's Docker stack
- settings: View the Full Changelog opens over a full-screen window, on the desktop you are on
- settings: About ▸ Acknowledgements lists the software Overterm is built on — Ghostty and what it links, tree-sitter, the Swift packages, the notes' libraries, Excalidraw and its fonts — each with its licence
- build: swift-nio-ssl 2.37.6
- review: side by side, the line between the old and the new drags to resize them (double-click for half and half)
- overgit: Pull and Push at the top; branches merged, rebased, renamed, deleted and pushed, commits cherry-picked, reverted and reset to, tags and stashes made — and a merge or rebase stopped on a conflict continued or aborted
- e2e: a test run's first tab starts in an empty folder of its own, never the home folder of whoever runs it

## 1.5.1 — 2026-11-02

- terminal: Ghostty 1.4.0 underneath (Zig 0.17.0, still Xcode 16.4) — its clipboard API, and a ⌘-clicked path that froze the app
- notes: the reading view's libraries up to date — DOMPurify 3.4 (every note's HTML goes through it), markdown-it 15, KaTeX 0.19, mermaid 12, highlight.js 11.12; Excalidraw's bundle built with esbuild 0.28
- build: weekly checks for what is pinned — an issue when a bundled web library has a newer release, Dependabot PRs for the Swift packages

## 1.5.0 — 2026-11-01

- docker: Docker beside the terminal (⌥⌘P) — the containers your `docker` reaches, grouped by compose project and kept live; logs followed and coloured by level, inspect with secrets masked, CPU, memory, network, processes and changed files; ⇧⌥⌘P finds any container or project
- docker: images, volumes, networks and builds — pulls with progress and Docker Hub search, layers, Check for Updates, Scout's vulnerabilities, buildx history and builds followed step by step; volumes exported, imported and cloned; Clean Up lists what nothing uses before anything goes
- docker: compose — a checkout's project shown before it runs, Up with profiles, Watch, one service rebuilt, restarted or pulled, logs merged by service; a worktree's stack on free ports when another holds them, and a port clash says who holds it; New Task can start the stack
- docker: inside a container — its files browsed, edited and dragged in and out (a volume's too), a database container in the Database panel or its own client in a tab, a debug shell for images without tools, its memory, CPUs and restart policy changed, renamed or saved as an image; `n` runs an image as its `docker run` is written
- docker: beside your work — the rail's shippingbox shows the selected checkout's stack; published ports in pane headers, Tab Info and the API client; a container that crashes, runs out of memory or turns unhealthy marks its tab, and an agent can be asked why
- docker: agents read Docker through MCP with secrets kept out, and every write is asked about first; Docker's MCP Toolkit and Model Runner (models, a chat, the base URL) from the page
- docker: any engine — every `docker` context, `ssh://` through your own ssh; Docker Desktop, OrbStack, Colima and Rancher Desktop started and stopped from the page; Testcontainers' runs kept apart

## 1.4.8 — 2026-11-01

- review: a big review scrolls smoothly — the file list is an AppKit table, the diff draws only what changed
- review: uncommitted changes in a review tab — on main too, where ⇧⌘R said there was nothing to review
- terminal: an oh-my-zsh prompt (user@host:path) is no longer taken for a command — blocks, ⇧⌘C and ⌘L's exit code follow the right command again

## 1.4.7 — 2026-10-31

- notes: drawings — New Drawing opens an Excalidraw canvas, saved as Obsidian Excalidraw's own file; embedded drawings show as pictures, and agents can draw diagrams (notes_draw)
- review: a branch, commits or a pull request in a tab of their own — the files on the left, each diff side by side or unified, viewed marks, j/k n/p v keys (⇧⌘R, Overgit, the changes and pull request panes)

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
