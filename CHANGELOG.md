# Changelog

What changed in each version of Overterm, newest first. `VERSION` is the
version ([SemVer](https://semver.org)): a commit that changes the app bumps it
— major, minor or patch, as CLAUDE.md's Commits section sets out — with
`Scripts/bump-version.sh`, which adds the line here. The commit that brings a
version is tagged `v<version>`.

## 1.6.0 — 2026-11-13

- kubernetes: Kubernetes beside the terminal (⌥⌘J) — your kubeconfig's contexts, production marked everywhere and read-only unless you allow writes for the session; every kind and custom resource as a live list in the server's own columns (a CRD applied shows without reconnecting), sections on `1`–`9`, k9s's `:` bar, `n` and `c` for a namespace and a context, `label:` and `field:` asked of the server, ⌃⌘J finds a context, namespace or pod, `?` lists every key; Copy as kubectl, CSV, saved filters, and Context Settings… on the context card
- kubernetes: any object's detail beside its list — an Overview per kind with its rollout status, a dependency tree (`x`) down to containers and the routes to it, health checks Popeye's way (on the Overview and the pinned contexts' cards too), its YAML, its events, a workload's History (`h`) with each change diffed, and Compare with… the same object elsewhere; a Secret's values only when you press Show, masked, one at a time, dropped when you move on; Helm releases (`8`) read from the cluster's records, values and manifests masked
- kubernetes: a pod's logs (`l`) — any container, Previous, followed and picked up again without a line twice, older lines as you scroll, searched as text or a regex; a workload's or a Service's pods merged by time, stern's way; CPU and memory from metrics-server on the lists and in the detail, an Overview (`1`) of the cluster, and Prometheus charts per context, opt-in, through a proxy that reaches only its queries
- kubernetes: in your terminals — Terminal in This Context (a tab whose plain `kubectl`, `helm` and `k9s` reach that context, its pane saying which, red on production, a restored one whose context is gone marked "pin lost"), a pod's shell, attach and followed log (`e`, `A`, `t`), files copied in and out of a pod, port-forwards (`f`) from a pod, a Service or a Deployment kept on a ready pod and opened in the browser column, the Database client (`d`) or the API client — closing a tab with a running forward, or quitting, asks first, and every forward's kubectl is ended at quit; a pane's header warns when its kubectl reaches production; New Task pinned to a context, snippets with `${context}`
- kubernetes: writes on writable contexts only, each checked with the cluster's access review and asked in the window naming the context, the namespace and the kubectl it equals, the name typed where it destroys — delete, restart, scale, evict, finalizers, pause, trigger a CronJob, cordon, drain, roll back, debug containers, node shells, resize in place, namespaces, Helm rollback and uninstall, Flux's and Argo CD's verbs; edit a resource's YAML (`y`) or a checkout's manifest, Diff with Cluster by a server-side dry run naming the fields Helm, Argo CD or Flux own, then Apply; the cluster's own API docs on hover and ⌃Space in a manifest, Explain beside the editor, templates for new resources
- kubernetes: several namespaces at once — the chip beside the filter (and `n`) ticks as many as you like, `:ns a,b` too; their rows in one live list with a Namespace column, kept per context, the Overview, usage, Helm and the agents following them; a namespace you can't list is left out and named rather than failing the list
- kubernetes: a resource's YAML tab is the editor — tree-sitter YAML and the cluster's API docs, the same buffer `y` opens in the editor, Diff and Apply over it (greyed with why on a read-only context); it follows the cluster while you haven't edited it, and says "changed on the cluster" with Reload or Diff when you have; kept in memory only, never saved, closing with edits asks
- kubernetes: beside your work — a checkout bound to what it deploys: the rail's panel shows its workloads and pods and the deployed commit against the checkout (Diff Deployed…Current), its tab is marked when a pod crashes or a rollout stalls, its Helm chart diffed and upgraded from the checkout; Ask Why (`a`, ⌘L) hands an agent a brief of a failing pod or rollout, secrets taken out, shown whole before it goes; Run Locally and Scan take a pod's image to the Docker page
- kubernetes: agents read the clusters through MCP (`k8s_get`, `k8s_describe`, `k8s_logs`, `k8s_events`, `k8s_why`, `k8s_rollout`, `k8s_top`…), never a Secret's values, every answer scrubbed (Settings ▸ Kubernetes ▸ Agents can read the clusters); `k8s_restart`, `k8s_scale`, `k8s_delete_pod` and `k8s_apply` only on the contexts `kubernetes.agentWrites` names, each call asked in the window
- docker: the containers list scrolls in half the time; env names with PASS, PWD, PASSPHRASE or PIN as a word (`RABBITMQ_DEFAULT_PASS`, `MYSQL_PWD`) look secret — their values were shown, handed to agents and copied onto a command line
- security: a word with a control character (a container's or chart folder's name, an env value, a dropped path) is written as an escape, never typed raw into a tab, so ^U can't erase its quote and run the rest; a chart folder with one is refused
- build: Xcode 27 builds the app, and an app built with it takes clicks on macOS 27; double-clicking the strip's empty space zooms the window there again
- usage: an isolated run never runs your own claude for its usage
- kubernetes: Prometheus charts read the right window and count active pods — a rate over four scrapes (a 1m scrape no longer charts nothing), the prometheus chart's current Service labels found, requests and limits of running and pending pods only, a restarted container no longer counted twice, the cluster's raw lines up to 6h (past it said, with 6h offered), Prometheus's warnings shown under the chart, and a query given up after 20 s
- kubernetes: Prometheus charts with axes, a legend and a shared crosshair — hover any chart for the time and every value, the same moment marked on the charts beside it; requests, limits, allocatable and capacity as labelled dashed lines; a legend click shows one series alone
- kubernetes: a pod's detail reads its own usage, whatever the list beside it shows, and what it sampled is kept for an hour after you move on — come back to the pod and its earlier samples are there, the time away a gap; a cluster that refuses metrics.k8s.io (a 403) is told once in plain words, with Try Again, and not asked again every 15 s; of several namespaces, only those refused lose their usage
- kubernetes: a pod's Metrics tab (`m`) — CPU and memory stacked by container, then each container's against its request and limit as labelled lines, `48% of request` and `working set 93% of limit · OOM risk` beside the value; Live or the last 6 hours of what was sampled while shown (`,` and `.`); the last restart or OOMKill marked, a click opening that container's previous log, and Logs from Here (right-click) the log from a minute before the crosshair
- kubernetes: the Metrics tab on workloads, HPAs and nodes — a Deployment's, StatefulSet's, DaemonSet's or Job's pods (Per pod, or Total stacked with the rest) against its template's request and limit, its CPU by revision, its replicas and the HPA that scales it; an HPA's replicas against its bounds, flapping and ScalingLimited said, each metric against its target; a node's usage against what its pods request and its allocatable, pressure and cordon as bands, its pods against its limit, and Sample Top Pods; a namespace's by workload against its quota and its pods by phase — all sampled while shown, nothing more read
- kubernetes: the Nodes list's heat strips — beside each node's CPU and memory, its last 15 minutes as a strip of 15 s cells, taller and warmer as it nears allocatable, blank where nothing was sampled; from the list's own read, nothing more asked
- kubernetes: change markers on every chart — rollouts and Helm revisions, scaling, restarts, OOMKills and warnings where they happened, a workload's pods' OOMKills on its CPU and memory; click one for what changed and Show Diff, its previous log or its event, ⌥-click (or Show ±30 min) for the half hour either side; at most 50 a chart, the rest "+N earlier"
- kubernetes: Prometheus is probed once a context — its recording rules or node-exporter chart the cluster over 24h and 7d where raw container metrics would be too many (said with about how many samples), the rate window follows the cAdvisor job's own scrape, a kubelet scraped twice or two kube-state-metrics jobs no longer double a line, how far back it keeps data is hatched, and an agent-mode Prometheus, a refused `services/proxy` or a busy server is said in one sentence and not asked again in a loop
- kubernetes: request and limit shares in the Pods list — wide (`w`) adds `%CPU/R %CPU/L %MEM/R %MEM/L`, each pod's usage against its containers' requests and limits from Prometheus' kube-state-metrics, a limit's share orange from 80% and red from 100%, a pod with an unlimited container said so rather than guessed; without Prometheus a dash and why; `k8s_top` gives agents the same shares
- kubernetes: the Metrics tab over 1h to 7d and custom ranges, from Prometheus — a pod's, a workload's, an HPA's and a node's charts asked of it past what was sampled, `,` and `.` stepping on to Custom's two dates; drag across any chart to zoom them all (Esc steps back); a container's CPU throttling, a pod's network and restarts and earlier OOMKills, in Live too; a container's CPU peaks over 24h and 7d and its RSS beside the working set (off until clicked); a node's top pods asked only once scrolled to; only the new points asked at each refresh; Live pauses after 15 minutes without input; the pod's Prometheus chart moves from its Overview to this tab
- kubernetes: a workload's pods by revision, top five and the rest, from Prometheus — its pods found by owner (the recording rules' workloads, else kube-state-metrics' owners, a Deployment's through its ReplicaSets) rather than by name, its five largest ranked once over the range and the rest as "other", its CPU by revision a line for each ReplicaSet; a namespace's Metrics tab over 1h to 7d too — its eight largest workloads and the rest against its quota over time, what it requests but leaves idle, its pods by phase
- kubernetes: the Overview's usage by namespace and node; PVC fill forecast — the cluster's CPU and memory charted against what its nodes can give (allocatable and capacity) and, from Prometheus, what its pods request and may use, `requests 71% of allocatable` beside them and red past all of it, overcommitted; its CPU by namespace, the eight largest and the rest; its nodes as rows of two strips, the hottest 50, a click opening the node's Metrics tab; sampled while shown without Prometheus; a claim's "full in ~3 d" with the trend dotted ahead and its inodes on a toggle, an EFS volume's 8 EiB no longer read as a size (no % and no forecast); a container's ephemeral storage against its limit where the kubelet reports it, a node's own memory in use beside its pods' where node-exporter maps to it
- kubernetes: a node's disks and network from node-exporter — on a node's Metrics tab, `/` and `/local` used against their size (red from 90% full) and the node's own interfaces' received and sent, mapped to the node by `node_uname_info`; asked only once you scroll to them, in Live too, and said plainly where node-exporter doesn't map to nodes
- kubernetes: GPUs — allocation from the objects, utilisation and memory from DCGM — a GPU node's Metrics tab says how many of its GPUs are allocated and which pods hold them (a click opens one), a pod's and a workload's what they are given, without Prometheus too; where Prometheus scrapes NVIDIA's DCGM exporter, each GPU's utilisation, memory against its total, power and temperature per GPU, per container and by pod, MIG instances by profile, and a GPU held but idle over the range said plainly
- kubernetes: a context's saved queries on a workload's Metrics tab — your own Prometheus charts (request rate, latency, queue depth) written in the context's `kubernetes.contexts` entry as `charts: [{title, query, unit}]`, with `$ns`, `$name`, `$pod` (the workload's pods) and `$w` filled in escaped; a query that would read more than the workload's series — no `namespace="$ns"` and `$pod`/`$name` matcher, a subquery, a range past an hour — is refused with the reason, never sent, and one Prometheus rejects is said in its words; agents never see or write them
- kubernetes: a chart expands into the right slot — ⤢ on any Metrics tab chart (or Expand in its menu) shows it alone at full height beside your terminal, still following its tab and reading nothing more, and Show in Kubernetes takes you back; every chart's menu copies its values as CSV, and a Prometheus chart (the Overview's too) its exact PromQL to paste into Grafana; a query Prometheus refuses offers Copy PromQL beside what it says
- kubernetes: rightsizing from seven days of usage — Sizing on a pod's or a workload's Metrics tab asks Prometheus once for a week of each pod's CPU and memory (or what it keeps), per pod rather than the workload's sum, and suggests a CPU request from its p95 and a memory request and limit from its max, beside today's request and limit, an OOMKill in the week said; a workload past 50 pods without recording rules is refused with why; advice only, nothing is changed
- kubernetes: k8s_metrics for agents, and usage in Ask Why — agents get `k8s_metrics`: a pod's, container's, workload's, namespace's, node's, claim's, HPA's or the cluster's usage over 15m to 7d as short text (min, p50, p95, max and last with their times, the share of its request and limit, OOMKills, restarts and rollouts), from the Metrics tab's own Prometheus queries where the context opts in, else what was sampled while shown, else metrics-server now, and `sizing` for suggested requests; Ask Why's brief now carries the failing pod's last hour of CPU and memory, and every chart's menu has Ask Agent About This Chart…
- kubernetes: charts' performance budget — the Overview's nodes drawn as one picture (fifty nodes' strips at once, a strip's summary on hover, each still a VoiceOver element), half the time to its first draw; a large Prometheus answer read in half the time and merged into the chart cache off the main thread, so a big range never stalls the window
- kubernetes: the Overview as cards — a header with the context, its version and pills saying what needs attention and what passes; a card per kind with its count and a ready/pending/failing bar (press it for the list); what needs attention worst first, each with its reason (`CrashLoopBackOff · 14×`, `2/3 ready`), beside CPU and memory as shares of allocatable; health checks you can open by check, applications as cards, warning events with their reasons — one column when the window is narrow
- kubernetes: Argo CD 3 and multi-source Applications read right — a multi-source Application's tree shows each source's own revision instead of none; on Argo CD 3, which keeps each object's health outside the Application, the tree says so and shows its objects by sync, not as unknown; a Flux object whose latest change Flux hasn't looked at yet is flagged on the Overview even while its Ready says True; an apply warns that Argo CD probably manages an object carrying only its 2.x tracking label (`app.kubernetes.io/instance`); and the Overview's health read keeps no Helm values, patches or manifests from the copies Argo CD keeps in an Application's status
- kubernetes: deleting a GitOps object says what goes with it — deleting an Argo CD Application, a Flux Kustomization or a HelmRelease now asks for its name on every context and says what its controller deletes with it ("Argo CD deletes the 42 resources it manages with it, across 3 namespaces", a pruning Kustomization's inventory, a HelmRelease's uninstall), the worst case when it can't be read, and "it will be recreated" when a parent manages it; deleting a namespace adds what its GitOps objects take with them
- kubernetes: changing a GitOps object's source, prune or suspension says so — applying a manifest or saving the YAML of an Argo CD Application or ApplicationSet, a Flux Kustomization or HelmRelease names each change to its prune, auto-sync, source, path, destination or suspension and what it does, and asks for its name on every context; an agent's `k8s_apply` of one always has you type its name; resuming a Kustomization or HelmRelease on production says what it applies against what is applied ("applies main@c03f9aa; a77b0d1 is applied") and asks its name when it prunes
- kubernetes: a Flux source's URL without its credentials — a GitRepository, OCIRepository or HelmRepository whose URL carries a user and token (`https://user:token@…`, or a token alone) is listed with the URL alone, its Ready message too, on the page, in its live updates and in what an agent reads
- kubernetes: GitOps objects summarised — the Overview's Argo CD checks now judge an Application the way Argo CD acts on it: a failed sync of the current revision ("auto-sync failed for 77e1a02 and won't retry it"), Degraded, or Missing while Synced is a problem; OutOfSync with auto-sync off, after a sync that didn't fix it, auto-sync not starting, resources needing pruning, or a sync hung past ten minutes is drifted or stuck; an OutOfSync that auto-sync is fixing is no longer flagged; the health card says in a line what Argo CD and Flux say of what lives in the namespace ("GitOps objects living in shop: 2 failing, 1 drifted or stuck")
- kubernetes: a GitOps section (`g`) — every Argo CD Application and ApplicationSet and every Flux Kustomization, HelmRelease and source that lives in or deploys into the namespaces shown, on one screen, problems first: Failed, Blocked (naming the source or dependency), Stuck, Drift, Progressing, Paused, each with why, where it deploys, the revision applied against the one wanted and its source; chips to pick a state, Hide Ready, a banner when a controller is down; ↩ opens it in its own list with the detail, `r`, `p`, `s` and ⌫ act on it through the usual confirmations; `:gitops`, `:argo`, `:flux`; the Overview's GitOps card goes there. Read only while it shows — rows followed, each object summarised once in bounded pages, never a Secret, a ConfigMap or a Helm value
- kubernetes: a GitOps object's detail says why, where from and what's applied — an Argo CD Application or ApplicationSet, a Flux Kustomization or HelmRelease opens with its state and why ("Failed: upgrade to 1.5.0 failed; rolled back to 1.4.2"), its source, the revisions applied, attempted, wanted and fetched with when, where it deploys, auto-sync or suspension, its chain of sources and dependencies with their states (each opens), Argo CD's last operation, out-of-sync resources and history, its conditions to copy; Ask Why (`a`, in the GitOps section too) now takes one that is Failed, Blocked or Stuck, its brief naming the root cause along its chain, scrubbed and shown whole before it is sent

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
