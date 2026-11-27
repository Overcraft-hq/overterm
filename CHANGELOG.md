# Changelog

What changed in each version of Overterm, newest first. `VERSION` is the
version ([SemVer](https://semver.org)): a commit that changes the app bumps it
— major, minor or patch, as CLAUDE.md's Commits section sets out — with
`Scripts/bump-version.sh`, which adds the line here. The commit that brings a
version is tagged `v<version>`.

## 1.6.8 — 2026-11-26

- The Docker page lists Apple's container tool's containers, images and volumes — a section of its own, when the tool is installed
- Next and previous tab, ⌘1–9 and Close or Suspend Other Tabs go by the tabs the strip shows; a stashed, collapsed or unfocused island's are left alone, or named and asked about
- No secret reaches an agent or a file of Overterm's: a password field in the browser's snapshot, the API report Ask an Agent sends, a command with a secret in ⌘K's history (Forget, Clear Command History…), a password in the database console's history
- A note's remote image loads only when you press Load (Settings ▸ Notes can load them all)
- Every feature's agent switch is held when settings.json changes outside Settings, as Kubernetes' already were
- The Inbox offers answers only to a real question; Broadcast leaves out production, an agent that asks and a suspended pane, by name; Suspend Tab doesn't stop a terraform write; the console's destroying question names its connection; the JSON settings view never saves a stale draft over the file
- The changes pane stages, unstages and discards one hunk at a time; a card's diff is read when it opens, however many files changed
- The Inbox reads and answers the pane that asked, not the one with the keyboard, and types nothing once its question has left the screen
- Every pane of a restored tab comes back with its own agent, and each Claude with its own conversation — two in one folder were both the newest
- Sheets that delete leave Return on Cancel: the button that deletes takes a click, and where a name is typed, Return deletes once it matches
- Docker's, Redis', the SQL console's, Files' and Overgit's questions that delete use the same sheet and say what they reach: the engine, the connection, the folder, the repository and branch. Docker's Clean Up leaves Return on Cancel too
- New Task asks what the agent is to do and types it in once the agent is up; a repository's setup copies its untracked files (.env) into the new worktree and types a command before the agent
- Create Pull Request… from the pane, Overgit and ⌘K; Mark Ready, Approve, Request Changes and Merge on a pull request, each asked first
- A failed CI check's log opens in the Pull Request pane, with Re-run Failed Jobs; CI going red on a branch with a tab open marks the tab and puts a "CI failed" card in the Inbox, with Ask Agent to Fix
- A pull request can be checked out in a new worktree from its pane: on its own branch (fetched from origin if need be), a fork's detached
- A review's lines are picked by their numbers (⇧-click for a run) and copied with ⌘C; notes on them go to the checkout's agent as one message with Send, and a pull request's thread with Address This Thread — typed in, Return left to you
- A pull request's review threads show at their lines in its review; comments on picked lines are kept and posted to GitHub as one review with Comment, Approve or Request Changes, asked first
- An agent's write (Docker, a database, Kubernetes, Terraform's plan) is asked as a card in the Inbox when you're not looking at its window — the tab marked, a notification, Allow and Don't, the name typed on production — and as the sheet only when its window is in front; Overterm no longer jumps to the front, and a question nobody answers fails after ten minutes
- Tab Info lists the tab's agent's last calls on Overterm's tools, secrets masked, kept in memory only; Settings ▸ Agents shows every feature's agent switch in one place

## 1.6.7 — 2026-11-23

- Kubernetes lists sort a little faster: 5,000 rows by CPU in 25 ms, from 28–30
- The Kubernetes rail is drawn again after the page was opened over it; it stayed blank
- The rail's GitOps buttons go one under another when they don't fit, instead of breaking every title

## 1.6.6 — 2026-11-22

- build: the API client, the git panel, the notes, the simulator, the agents' usage, the settings page, the agents' overview, the Activity page and the end-to-end scenarios are modules of their own

## 1.6.5 — 2026-11-22

- activity: an agent's folder already read since its call is not read again
- build: the shipped app no longer carries the end-to-end scenarios and the tests' fake servers (`#if E2E`; `make e2e` builds them in with the E2E trait) — a smaller binary and a shorter release build
- build: the app is built as seven modules — the core, the shell, the database client, Docker, Kubernetes, Terraform and the window — so a release build optimises them side by side and a change rebuilds only what sits above it

## 1.6.4 — 2026-11-22

- make test-changed runs under macOS's bash 3.2 and picks every test a change can reach
- A read from Docker (a file copied out, a list) no longer fails with "ChannelError" on a busy Mac: the request goes out in one write
- make app CONFIG=debug bundles the debug build, for the nightly end-to-end run in CI

## 1.6.3 — 2026-11-22

- build: Overterm opens again on macOS 13–15 — 1.6.2 was killed at launch there, built by Xcode 27 without the Swift library (libswiftCompatibilitySpan) macOS before 26 lacks; the app now carries it, and a bundle without it fails to build

## 1.6.2 — 2026-11-19

- Activity (⌥⌘A, its switcher ⌃⌘A — the listening ports and the busiest processes, `:5000` found with no page showing): every process and every open port on this Mac, by checkout, tab and agent — filtered (`name:node|bun cpu:>50 mem:>1g`), sorted with htop's keys, followed and paused, its columns picked, moved and kept, its order held while you point at it, the selected process's detail beside
- Activity has a button at the foot of the sidebar's rail, beside Settings: it opens the page
- Activity's Listening: who holds each port — a container (by its published address), a port-forward, a database tunnel, a tab, a brew service or AirPlay Receiver — with its URL by the addresses it is bound to; two holders on one port said on both rows (split across IPv4 and IPv6, beside a wildcard, `SO_REUSEPORT`); your connections paired end to end (`c`)
- Activity's Listening: every user's listening ports too — root's, macOS's and other users', read by nettop every 10 s while it shows and believed only when its answer holds your own (else "unknown", never "nothing listens") — launchd's socket jobs named from their plists ("launchd — com.apple.ftp-proxy"), macOS's daemons and tools like ngrok's inspector named, never a kill; agents' `port_holder` answers with them too (Settings ▸ Activity ▸ Every user's listening ports); your unix-socket listeners — who holds a socket file — behind Settings ▸ Activity ▸ Unix-socket listeners
- Activity's Listening: a `kubectl port-forward` or an `ssh -L` typed in a tab says where it goes ("port-forward → svc/web:80", "ssh -L → db:5432 via bastion"), and a server an `ssh -R` reaches says where it is published
- Show in Activity: from Tab Info (its header, a process's or a port's menu), a pane's port pill, the tab's menu, an Agents card and Docker's port-conflict box — the page opens at that tab, process or port; ⌘K's Activity: This Tab; an Agents card also says its agent's CPU and memory, its servers as pills that open
- Activity's row verbs: Terminal in Its Folder (`e`) and Reveal Its Folder (⌥r), Open Files (`lsof`) and Sample in a new tab, the detail's Files (`l`) — what it holds open, files and sockets, read when asked, Copy PID and Copy Command — the command masked as everywhere
- Activity's Free (`f` on a port, or View ▸ Free a Port… — ⌘K's, the port typed): through what holds it — Stop Container, Stop Forward, Disconnect a database's tunnel, a brew or launchd service's own stop typed in a new tab, AirPlay Receiver's switch opened in System Settings, for your own process what its kind asks (⌃C typed into its pane, Stop, Stop Agent, an app's Quit), every other holder of the port named and the supervisor that may start it again, and for another user's port `sudo lsof` typed for you to run — each asked first, then the port watched until it is free, came back or is still held
- Activity's Stop (`k`), Force Quit (`K`) and Send a Signal (`x`), with Stop Its Tree, Group and Parent: each asked, by the process listed and never another that took its pid — a pane's foreground job interrupted with ⌃C typed (a full-screen program reads it as a key), an agent's turn interrupted or the agent stopped in a critical sheet, a terraform write only interrupted, an app asked to quit as its menu does (Force Quit as the Force Quit window does), Force Quit asking "Stop it first?" unless a Stop didn't end it; after a Stop the header says stopped, still running, or came back as pid N
- Activity's Suspend and Resume (`p`): a pane's job with its pane, anything else with its tree — the processes Activity stopped listed in the header with Resume All, and quitting asks to resume them first — after a crash, the next launch offers to; the header also counts every other stopped process of your tabs (`state:stopped`) and your zombies, and near the per-user process limit says "9,100 of 10,666 processes" with Sample and Terminal in Its Folder waiting; Run in Background (`b`) and back; Lower Priority (`n`), asked, since only an administrator raises it again
- Activity's Ask an Agent (`a`, ⌘L on a process): an agent of its tab, or a new one, handed where it runs and why, its usage now, its ports and its children by name, and its command masked as data from that program — never its environment
- Activity's Left Behind: what outlived its tab, its agent or an earlier Overterm, each with its reason — "left by Claude in “web”, which exited at 13:10", a closed tab's, an earlier run's, a test run's — in a section of its own (3) by checkout, a group in Processes and an owner in Listening, with Keep and Stop All Certain in This Checkout… (asked, listing each); when an agent finishes and leaves something running, its tab says so ("Claude finished — left node :3001 running"), in the Inbox too with Show, and its Agents card says "left 2 behind"; at launch, what an earlier Overterm left is listed once, with a Stop All that asks first; nothing there is ever stopped on its own
- Activity's history: a strip of the last 15 minutes' CPU on every row, the selected process's CPU, memory, energy, wake-ups and disk as charts and the Mac's CPU and memory under the meters; Energy, Idle Wake-ups, Disk Read and Write and Preventing Sleep columns; a new process tinted, an ended one shown once more; chips for a process that held a core for 5 minutes, an agent burning one while its tab waits for you, and a server that asked for a port and got the next
- agents: an agent started here (Claude Code, Codex, opencode, Gemini CLI) can ask who holds a port before assuming 3000 (`port_holder`), list their pane's processes and servers (`proc_mine`), the ports and what was left running in their checkout (`port_list`, `proc_left_behind`) and the busiest processes (`proc_list`) — read only, masked, outside their own checkout only names, pids, owners and ports; Settings ▸ Activity ▸ Agents can read processes and ports
- tabs: closing a tab or a pane names what will keep running after it (a nohup'd or disowned job, a daemon it started) and what its shell decides (background jobs), each with a checkbox to stop it too — unticked ones are kept — and under "only when something is running" those count
- sidebar: removing a worktree lists what still runs in it outside every tab — by its folder or a file it holds open — with Stop Them and Remove, Remove Anyway or Cancel; Clean Up Merged keeps such a worktree and says why
- docker: a container that couldn't start names the tab whose server holds its port — any tab, not only one you had looked at since it started; Up on Free Ports also counts a port held on one of this Mac's own addresses (a LAN or VPN one) as taken
- tabs: every visible tab's port pills stay current — a server started in a tab you aren't looking at shows on its pill — and a pill opens where its server listens: 127.0.0.1, [::1] or the one address it is bound to, localhost only where both IPv4 and IPv6 do
- info: Tab Info shows a split tab as a group a pane, what left a pane's terminal under it, and its memory as Activity Monitor's, real memory in the tooltip; its ports say their protocol, IPv4 or IPv6 and This Mac or Network, with Copy URL under ⋯
- tabs: a port pill's Stop… is Free…, decided by what holds the port — a pane's foreground job interrupted with ⌃C, an agent stopped only in a critical sheet, a terraform write only interrupted — containers' and forwards' Stop included, and says when the port is free; its Open follows Settings ▸ Browser, as a link in the terminal does
- database: a tunnel's ssh opens its own connection and no longer rides a ControlMaster from your ssh config — a bastion behind a second factor needs a key or agent the tunnel can use on its own
- tabs: Suspend Tab stops only the tab's own processes — never a tmux server and its sessions, an ssh-agent, an app started with `code .`, a nohup'd job or anything on another terminal that carries its tag — and Resume continues only what it stopped, never a pid another process holds since

## 1.6.1 — 2026-11-16

- api: GraphQL — New GraphQL Request; the server's schema read by introspection (with the request's URL, headers and auth) into a Schema tab to browse and filter; the query completed from it as it is typed — fields, arguments, types
- api: MCP servers — the checkout's .mcp.json, Claude Code's and Codex's servers listed in the API panel (read, never written), and your own added there (secrets in the keychain); one inspected beside the editor: its tools called with JSON arguments started from their schema, its resources read, its prompts got, every message logged — over stdio, Streamable HTTP or SSE
- api: gRPC — Bruno's gRPC requests: New gRPC Request, its methods from the server's reflection or the collection's .proto files (with protoc), messages typed as JSON, metadata and auth; unary, server, client and bidi streams called over HTTP/2 (TLS or plain), every reply and the status shown
- terraform: a root is compared with main alone — not every worktree's branch ("feat/x has no lock file", a dozen branches "sharing its state" are gone); Needs init said only when a required provider really isn't locked (by its source, so better-uptime is better-uptime), naming it and what to do; the branch and version said once above the cards, "no state yet" where a local state isn't there; a monorepo past 2,000 Terraform folders read in a moment, not seconds
- kubernetes: the rail's warnings — the last hour's Warning events of the bound namespace, or unbound of the page's context in the namespace the checkout's files name — with the nodes' readiness; the forwards running shown unbound too; a workload's image tag when no commit is known
- database: new kinds — MongoDB and Amazon DocumentDB (the mongo shell's statements, a connection string pasted, replica sets and mongodb+srv), MariaDB, Elasticsearch and OpenSearch (Kibana Dev Tools' console, indices and their mappings, SQL and ES|QL), DynamoDB (PartiQL; an AWS profile or a key; DynamoDB Local), InfluxDB (1.x InfluxQL, 2.x Flux, 3.x SQL), Neo4j (Cypher), RabbitMQ (its management API: peek, publish, purge), Oracle (SQL and PL/SQL as SQL*Plus splits them) — each with its tree, read-only and what to ask before, agents' tools and Docker containers opened as connections
- database: a connection's Server page — sessions (stopped the engine's way, asked), slow queries, locks and who waits, sizes, the server's numbers — rows edited in the grid (cells, added, deleted, duplicated; held until Save, never lost unasked, the statements shown, one transaction where the engine has them), and its users and roles (grants, create, password, grant/revoke, drop — a password never stored, sent hashed where the engine takes it) — on PostgreSQL, MySQL, MariaDB, SQLite, Oracle, ClickHouse, BigQuery, MongoDB, DocumentDB, Elasticsearch, OpenSearch, DynamoDB, Neo4j, InfluxDB, RabbitMQ and Redis, as far as each has them; agents read it (db_server, db_activity, db_slow_queries, db_locks)
- agents: opencode, pi and Gemini CLI join Claude Code and Codex — New Tab menus, ⌘K, New Task, their own arguments in Settings, resumed at launch, recognised by their processes; Overterm's MCP tools (browser, API, notes, databases, Docker, Kubernetes, Terraform) for Codex, opencode and Gemini too, each for that launch only, nothing written to their configs; Terraform's write guard for opencode and Gemini; a background agent that says nothing when it waits (opencode) still marks its tab and reaches the Inbox, its question read off the screen — Gemini's and Codex's choices answered from there

## 1.6.0 — 2026-11-13

- kubernetes: Kubernetes beside the terminal (⌥⌘J) — your kubeconfig's contexts, production marked in red everywhere and writable like any other context, each change asked — a context's `writable: false` makes it read-only; every kind and custom resource as a live list in the server's own columns, several namespaces at once, k9s's keys and `:` bar, ⌃⌘J for a context, namespace or pod, and an Overview of the cluster as cards
- kubernetes: any object's detail — its overview, dependency tree and health checks, its YAML edited in the editor and diffed with the cluster before Apply, its events, a workload's history with each change diffed, Compare with…; a Secret's values only on Show, masked; Helm releases read from the cluster's records
- kubernetes: in your terminals — a pod's or a workload's logs followed and merged, Terminal in This Context (a tab whose plain `kubectl`, `helm` and `k9s` reach that context, red on production), a pod's shell and attach, files copied in and out, port-forwards opened in the browser column, the Database or the API client
- kubernetes: writes on any context not set read-only, production included — delete, restart, scale, drain, roll back, debug, resize, Helm, Argo CD's and Flux's verbs — each checked with the cluster's access review and confirmed naming the context and the kubectl it equals, the name typed where it destroys; deleting or changing a GitOps object says what goes with it
- kubernetes: metrics — CPU and memory from metrics-server, and per context from Prometheus, on the lists and in a Metrics tab on pods, workloads, HPAs, nodes and namespaces from Live to 7 days: change markers, nodes' heat strips, request and limit shares, GPUs, your own saved queries, rightsizing from a week of usage, a chart expanded beside your terminal
- kubernetes: GitOps (`g`) — Argo CD and Flux on one screen, problems first, grouped by source, owner or destination; each object's detail says why, where from and what is applied
- kubernetes: GitOps where Argo CD runs in another cluster, or none of its Applications is here — its apps read from the marks it leaves on their objects, their health by Argo CD's built-in rules (what may be a problem checked by them first), problems first, saying what can't be known here; never a sync or a write on them
- kubernetes: a marked app's detail (↩) — its objects as Argo CD would draw them, each with its health by Argo CD's rules, its ReplicaSets and pods (a copied mark shown as a child), its hooks apart, its hints, what only the Application knows; each object opens in its own list (↩ on it, Tab into the tree), where a write on one of the app's own says Argo CD may undo it
- kubernetes: on such a cluster the checkout's rail says the marked app its bound workloads belong to and its health (each workload read once by Argo CD's rule — the Argo Rollout's phase for a Deployment it runs), the apps its committed manifests describe (on production after Find What Deploys This), and apart those only probably named after it (the bound namespace's, those elsewhere counted); Open shows the app's detail
- kubernetes: agents read those marked apps too — `k8s_gitops` lists them problems first where no Application here deploys them (`kind: marks`), from the section's last read when there is one — and Ask Why (`a`) on one that isn't Ready, Progressing included, hands an agent its objects' states, conditions and pods (an Argo Rollout's too, and from the checkout's rail on any context), scrubbed
- kubernetes: a copy of Argo CD's mark — on a Deployment's ReplicaSets, on what an operator makes — no longer names an Application as what deploys it, and a malformed one names nobody
- kubernetes: a context whose browser sign-in hasn't answered in a few seconds — the first, or one expired while connected — says to run `kubectl --context … get ns` once in a terminal, instead of waiting for minutes; Try Again then picks the sign-in up
- kubernetes: beside your work — a checkout bound to what it deploys: its workloads and pods, the deployed commit against yours, the Argo CD and Flux objects that deploy it and whether this branch has reached the cluster; its tab marked when a pod crashes or a rollout stalls, and Ask Why hands an agent a scrubbed brief
- kubernetes: agents read the clusters through MCP (`k8s_get`, `k8s_logs`, `k8s_why`, `k8s_metrics`, `k8s_gitops`…), never a Secret's values, every answer scrubbed; they write only on the contexts `kubernetes.agentWrites` names — a remote or production one only where its entry also sets `writable: true` —, each call asked in the window
- docker: the containers list scrolls in half the time; env names with PASS, PWD, PASSPHRASE or PIN as a word (`RABBITMQ_DEFAULT_PASS`, `MYSQL_PWD`) look secret — their values were shown, handed to agents and copied onto a command line
- security: a word with a control character (a container's or chart folder's name, an env value, a dropped path) is written as an escape, never typed raw into a tab
- security: passwords on a command line are masked in more forms — `docker login -p` (podman's, nerdctl's, `helm registry login`'s too), the registry clients' `--creds user:pass`, `sshpass -p`, the LDAP tools' `-w`, `smbclient -U user%pass`, `htpasswd -b`, `//user:pass@server` (`mount -t smbfs`, `mount_smbfs`), `openssl -passin pass:` and `enc -k`; a password with a space in it whole, and one starting with `/` no longer kept as a path
- git: started from a git hook or `git bisect run`, Overterm's git works in the folder it names, never in the GIT_DIR it inherited
- sidebar: the Files tree no longer asks git again and redraws when a folder is rescanned unchanged — behind other windows, a tab in ~ could keep the app busy
- build: Xcode 27 builds the app, and an app built with it takes clicks on macOS 27; double-clicking the strip's empty space zooms the window there again
- window: built with macOS 26's SDK or later, the tab strip no longer sits on a grey glass band across the title bar
- window: a port pill's Kill is now Stop… and asks first; it stops only the process still holding the port, never another that took an ended server's pid
- terminal: in a folder four or more deep, the prompt is no longer taken for a command — a command's rows went to it, so ⇧⌘C copied the wrong output and ⌥⌘↓ missed failures
- tabs: Tab Info's CPU is measured in a split tab, where every pane's processes read 0%, and in a tab that isn't selected, where they kept dropping to 0%
- tabs: Tab Info's tooltip masks the passwords and tokens in a command line
- usage: an isolated run never runs your own claude for its usage
- terraform: Terraform beside the terminal (⌥⌘E) — the checkout's roots in the sidebar with their workspace, backend, version and class, production in red by its names and once seen always; HCL in the editor (colours, terraform-ls, Validate with no credential, Format, F12); a header over any pane where terraform runs
- terraform: a plan in the right slot, read as data — Overterm's own plan, asked first on production and when the code isn't yours; destroys and replaces first and why, drift, moves and imports, never a sensitive value; a held lock named, a stale plan said; Init with what it fetches shown first
- terraform: apply with every guard — only the plan on screen, in the environment and with the terraform that made it, after checking nothing changed; a root's `writable: false` making it plan only; the root's name typed for production, a destroy or a plan that creates everything; it outlives a quit or a crash, and Stop interrupts it gracefully; destroy, targeted and replace plans; Force Unlock… for a stale lock, re-checked and named
- terraform: state and outputs, a sensitive one never shown; outputs into the browser, the API client, a database connection or the Kubernetes page; Check Drift and Accept into State; terraform test in the right slot, its failures at their lines
- terraform: in your worktrees and reviews — a New Task worktree's roots warned (state in another checkout, the workspace not copied) and initialised without a backend so validate works; lock files compared across worktrees; a review tab lists the roots its diff touches with their plans, and Post to Pull Request comments the masked plans
- terraform: agents — apply, destroy and state commands marked on their tab and denied where a root is production; `tf_roots`, `tf_validate`, `tf_plan` (asked, not on production), `tf_state_list`, `tf_outputs`, `tf_test`, never a sensitive value
- security: an agent pane's MCP token opens only that pane's tools; security settings (a context's class or writes, what agents may change) edited in settings.json outside Settings wait for a banner's Keep or Revert
- editor: language servers hear of files changed outside the editor, so gopls and sourcekit-lsp no longer go stale

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
