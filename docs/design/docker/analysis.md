# Docker — analysis

Nearly everything Docker Desktop does, in Overterm, with a better interface
and shortcuts:
- containers, compose projects,
- images, volumes, networks,
- builds, vulnerabilities, local models,
- the engine itself.

The real requirement is that it be developer-friendly.

This document collects:
- the code as it is today,
- what we measured with Docker on this Mac,
- Docker Desktop's feature inventory and how we would do each,
- the design of the interface and the shortcuts,
- the stages and the decisions to make.

The implementation plan comes after the decisions.

Line numbers are against `main` on 2026-10-27 (`3a5aee1`).

## In short

- **We can give nearly all of Docker Desktop.** Almost everything its
  interface does has an Engine API endpoint or a CLI equivalent:
  - **Engine API:** containers, images, volumes, networks, events, logs,
    stats; even the files inside a container.
  - **Docker Desktop's CLI plugins:** starting, stopping and updating the
    engine (`docker desktop`), build records (`docker buildx history`),
    vulnerabilities (`docker scout`), local models (`docker model`).

  What we leave out on purpose is in Section 3: the extensions marketplace
  (CLAUDE.md: no plugin slots), Docker Desktop's own resource settings (they
  have no public API), a Kubernetes interface.
- **Talk to Docker two ways.**
  - **The Engine API, over the unix socket:** reads, live streams and single
    actions. Fast (30–230 ms), structured, no polling.
  - **Commands typed into a terminal tab:** compose, `exec`, builds and
    anything that touches a registry. The developer sees what runs and can
    copy it.

  SwiftNIO is already a dependency; no new package.
- **Two layers of interface over one model.**
  - **The Docker page (⌥⌘P):** covers the body, as Settings and Notes do.
    All of Docker Desktop's dashboard is here: sections, list, detail.
  - **The Docker panel in the rail:** "this checkout's stack" beside the
    terminal. Logs show in the right slot without leaving the terminal.
- **Where it is better: the keyboard and the context.**
  - Everything can be done from the keyboard: single-letter actions while
    the list has focus, `/` to filter, ⇧⌥⌘P for a switcher that jumps to
    anything, the ⌘K palette.
  - Connections Docker Desktop can't make:
    - scope by checkout and worktree,
    - container ports in the pane header (not shown today),
    - editing a file inside a container in Overterm's editor,
    - a Database client connection from a database container,
    - marking a container that died as "needs you" on its tab,
    - MCP tools for agents.

## 1. Verified on this Mac (2026-10-27)

| What | Result |
|---|---|
| Runtime | Docker Desktop 4.95, Engine 29.8.2, API 1.56 (the server's minimum 1.40), `arm64`; `docker desktop status` → running |
| Context | `desktop-linux` → `unix:///Users/…/.docker/run/docker.sock`; `/var/run/docker.sock` is a symlink to it; `currentContext` in `~/.docker/config.json`; its record in `~/.docker/contexts/meta/<sha256("desktop-linux")>/meta.json` (verified) |
| Speed (socket, `curl`) | `containers/json?all=1` 54 ms; `inspect`, one-shot `stats`, `logs?tail=5` ~30 ms; `/volumes` 34 ms, `/networks` 35 ms, `/images/json` 228 ms (43 KB), image history 47 ms |
| Logs | 8-byte multiplexing frames for a container without a TTY (`02` = stderr, then the length); we have to demultiplex them |
| Events | `/events?filters={"type":["container"]}` is a stream that stays open; it sends nothing while nothing happens |
| Files | `HEAD /containers/<id>/archive?path=/etc/hostname` → 200 and `X-Docker-Container-Path-Stat` (base64 JSON: name, size, mode, mtime). Files can be browsed without a shell in the container |
| Disk | `system/df`: 69 images, 70 volumes, 387 build cache entries |
| **Ports** | The container's published 55432 is listened on by `com.docker.backend` (`lsof`). It is in no tab's process tree, so Overterm's port indicator **can't see today** the ports of a tab running `docker compose up` |
| CLI plugins | `~/.docker/cli-plugins`: agent, ai, buildx (0.37.2), compose (5.6.0), debug, desktop (4.95.0), dhi, extension, init, mcp (0.44.1), model, offload, pass, sandbox, scout |
| Machine-readable output | `docker buildx history ls --format json` (verified, with step and cache counts); `docker model list --json`; `docker scout cves --format sarif\|spdx`; `docker desktop status --format` |
| Instability | `docker mcp server ls` says "obsolete, see `docker mcp profile server ls`": the MCP Toolkit's CLI changes fast |
| Caution | `docker debug version` started pulling an image (stopped halfway, left nothing). Some plugins have side effects; Overterm should run them only for an action the user asked for |
| Editor | A `Dockerfile`/`Containerfile` and YAML grammar are already there (`Syntax/EditorLanguage.swift:103`, `:161`, `:177`) |
| Compose | No compose project runs on this Mac right now (two single containers: `cg-test-pg`, `cg-moto`). Grouping by labels is known from the documentation, not tried here |

## 2. The code today

Nothing touches Docker. Where it would connect:

| Piece | Where | What it means for Docker |
|---|---|---|
| Pages over the body | `WorkspaceOverlay` (Settings, Notes) | The Docker page is a third page |
| Rail panels | `SidebarPanel` (`Sidebar/SidebarView.swift:66`): files, git, sessions, snippets, api, notes, database | A new `docker` panel, turned on and off by a setting |
| The right slot | `RightPaneView`'s modes (`Diff/RightPaneView.swift:7`) | A mode for a container's logs and detail; it reads only while shown |
| Database client | `Database/`; `DatabaseMCP.allow` (`:113`) asks the user before writes | The same pattern (model, panel, right slot, MCP); a way from a database container to a connection |
| Ports | `Info/ListeningPorts.swift:17` (`lsof`, the tab's processes) | Docker's ports should be added here |
| Tab kind | `TabKind` (`Tabs/TabKind.swift:13`) | A `container` kind for a `docker exec` tab |
| Browser | `openInBrowser(_:for:)` (`Window/TerminalWindowController+Browser.swift:165`) | A web port in the tab's browser |
| A command in a new tab | `newTab(in:running:)` (`Window/TerminalWindowController.swift:1048`) | compose, `exec`, `logs -f`, build, pull/push from here |
| Editor | `EditorViewController`; `ExternalOpener` | Opening a file in a container and writing it back; `daemon.json` |
| Pickers | `EditorPicker`, the ⌘K palette (`PaletteModel`), `FuzzyMatch` | The Docker switcher and palette entries |
| Shortcuts | `KeyCommands` (rebindable, Settings ▸ Keyboard Shortcuts) | Docker's global shortcuts go here; the in-list single letters don't |
| MCP | `BrowserMCP.handle`'s prefix branches (`Browser/BrowserMCP.swift:60`, `:72`) | A group prefixed `docker_` |
| Attention | `AttentionNotifier`, `TabActivity` | A container that exits or turns unhealthy → a tab mark, a notification |
| SSH tunnel | `Database/SSHTunnel` | Forwarding a remote Docker context's socket |
| Test servers | `Scripts/database-test-servers.sh` | The Database tests already run on Docker; Docker is a development tool in this project |
| Dependencies | `Package.swift:18` swift-nio | `NIOHTTP1` for HTTP over a unix socket; no new package |

## 3. Docker Desktop's inventory and what we do for each

Docker Desktop 4.x's dashboard and settings, section by section. The "How"
column: **API** the Engine API (socket), **CLI** a command (in the
background, its JSON read), **Tab** a command typed into a terminal tab,
**Helper** a short-lived helper container.

### Containers

| Docker Desktop | Ours | How | Stage |
|---|---|---|---|
| List, grouped by compose; search, "only running" | The same; the checkout's first; CPU and memory in columns | API (`containers/json`, `events`) | 1 |
| Start, stop, restart, pause, resume, kill, delete; bulk selection | The same, with single letters and in bulk | API | 1 |
| Port links, open in browser | In the tab's browser column; in the pane header | API | 1 |
| Logs (search, copy) | Follow, search and regex, level colours, JSON logs made readable, a stderr mark, a time range, a compose project's merged logs; selected lines to an agent with ⌘L | API (`logs`, frames) | 1 |
| Inspect | A JSON tree and a readable summary; secrets in the env masked | API | 1 |
| Bind mounts | A list; the host path opened in Finder or Overterm's Files panel | API | 1 |
| Exec (embedded terminal) | A new Overterm tab: `docker exec -it <c> sh` (bash if there is bash), tab kind `container` | Tab | 1 |
| Files (browse, edit, import/export, delete) | Browse; open a file in Overterm's editor and write it back; import and export by drag and drop | API (`archive` GET/PUT/HEAD) | 1 |
| Stats (CPU, memory, disk, network graphs) | The same; streamed only while shown | API (`stats?stream=1`) | 1 |
| Run (with settings) | A "Run" window on the page: name, ports, volumes, env, network, restart; "Copy as `docker run`" | API (`create`, `start`) | 2 |
| `top`, changed files, export | Processes, `diff`; export the filesystem as a tar | API (`top`, `changes`, `export`) | 2 |
| Docker Debug (a shell in a container without one; a Pro subscription) | A shell from a busybox sharing the container's namespaces; no subscription needed | Tab (`docker run --pid/--network container:<c>`) | 2 |

### Compose

| Docker Desktop | Ours | How | Stage |
|---|---|---|---|
| A project group; start, stop, delete at the project level | up -d, down (`-v` asked), restart, pull, build, per service; by checkout | Tab | 1 |
| — | The project's resolved model: services, ports, the `depends_on` graph, env | CLI (`docker compose config --format json`) | 2 |
| — | The compose file in the editor: ▶ (up) on a service's line, `config` errors as diagnostics | CLI and editor | 2 |
| — | Worktree conflicts: two stacks asking for the same host port, and a way out | API and `lsof` | 2 |

### Images

| Docker Desktop | Ours | How | Stage |
|---|---|---|---|
| List (size, created, in use); filter | The same; unused and dangling marked | API (`images/json`) | 2 |
| Inspect, layers | Layers with size bars, the command that made each | API (`history`, `json`) | 2 |
| Pull, push, tag, delete, prune | Pull (public images, with a progress bar), tag, delete, prune (with a preview); push and private images in the terminal | API and Tab | 2 |
| Run | The containers' "Run" window, filled in from the image's `EXPOSE` and `VOLUME`s | API | 2 |
| Search Hub, repositories | Search Hub, and tags | API (`images/search`), Hub's public API | 3 |
| Docker Scout (CVEs, recommendations) | An image's CVE summary and list, base image recommendations | CLI (`scout quickview`, `cves --format sarif`, `recommendations`) | 3 |

### Volumes and networks

| Docker Desktop | Ours | How | Stage |
|---|---|---|---|
| Volume list (size, in use), create, delete | The same; the containers using it; prune (with a preview) | API (`volumes`, `system/df`) | 2 |
| Browsing a volume's data | Browse, and open a file in the editor (read-only) | Helper (a small container mounting the volume read-only) and `archive` | 2 |
| Export/import, clone, empty | Export/import as a tar, clone | Helper | 3 |
| Networks (not a prominent view in Docker Desktop) | List, inspect, connected containers, create, delete, prune | API (`networks`) | 2 |

### Builds

| Docker Desktop | Ours | How | Stage |
|---|---|---|---|
| Build history (status, duration, cache) | The same; filtered by checkout | CLI (`buildx history ls --format json`) | 3 |
| A build's detail: timing, logs, errors, Dockerfile | Logs; from an error line to the Dockerfile's line | CLI (`history inspect`, `logs`) and editor | 3 |
| Builders, build cache | List; clear the cache | CLI (`buildx ls`), API (`build/prune`) | 3 |
| Starting a build | `docker build`/`compose build` in the terminal | Tab | 1 |

### Engine and settings

| Docker Desktop | Ours | How | Stage |
|---|---|---|---|
| The engine's status; start, stop, restart | A status bar; start, stop, restart Docker Desktop | CLI (`docker desktop status/start/stop/restart`); OrbStack's and Colima's own commands | 1 |
| Contexts | A picker; choose one for Overterm alone, or make it the default with `docker context use` | Files and CLI | 1 |
| Disk usage, clean-up | `system df`; prune with a preview for images, volumes, cache | API | 2 |
| Docker Engine setting (the `daemon.json` editor) | `~/.docker/daemon.json` in Overterm's editor; JSON validation; "Restart" after saving | Editor and CLI | 2 |
| Updates, diagnostics | Is there an update, update; a diagnostics bundle | CLI (`docker desktop update`, `diagnose`) | 3 |
| Resources (CPU, memory, disk limit), file sharing, proxy | **None**: Docker Desktop's own settings, with no public API; an "Open in Docker Desktop" link | — | — |
| Kubernetes | Status and on/off; **no** Kubernetes interface | CLI (`docker desktop kubernetes`) | 3 |

### The rest of Docker Desktop

| Docker Desktop | Ours | Why |
|---|---|---|
| Model Runner (local LLMs) | List, pull, run (chat in the terminal), logs, disk | CLI (`docker model … --json`); stage 3 |
| MCP Toolkit (a catalog of MCP servers) | List and on/off; stage 3 | Its CLI is unstable (Section 1); Overterm's agents already get their own MCP |
| Extensions marketplace | **None** | CLAUDE.md: no plugin slots |
| Ask Gordon (Docker AI) | **None** | Overterm's agents do the same work with their own MCP tools |
| Account, Docker Hub sign-in | `docker login` in the terminal | Credentials stay in Docker's credential helper |
| Offload, Hardened Images, Sandboxes | **None** (for now) | Fast-changing products that need a subscription or an account |

## 4. How we talk to Docker

### Options

| | The `docker` CLI (`--format json`) | The Engine API (unix socket) | An SDK |
|---|---|---|---|
| Setup | The `docker` binary on the PATH; a GUI app's PATH is narrow (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.docker/bin`, `~/.orbstack/bin` must be searched) | Only the socket's path | No official SDK for Swift |
| Speed | A process per call (~100 ms+) | 30–230 ms, no process | — |
| Liveness | `docker events` is a long-lived process | The `/events` stream; no polling | — |
| Compose and plugins | Yes | **No**: compose is client-side; Scout, Model, Desktop are each a plugin | — |
| Format | Text/JSON that changes with the CLI's version | Versioned, documented JSON | — |

**My recommendation is a mix.**
- **The API:** containers, images, volumes and networks, events, logs,
  stats, files.
- **The CLI in the background:** only the plugins that give JSON (build
  history, Scout, Model, `docker desktop status`), on a GCD thread (as
  `Git.run` does).
- **A terminal tab:** anything the user should see, anything long, anything
  that needs credentials: compose, `exec`, build, push, pulling a private
  image, `docker login`. The developer sees what runs and can copy it.
  Ghostty draws the progress bars and colours, ⌘F and command blocks come
  for free, and ⌃C stops it.

### Finding the socket

The Docker CLI's order, exactly:
1. `DOCKER_HOST`.
2. `DOCKER_CONTEXT`.
3. `currentContext` in `~/.docker/config.json`.
4. That context's record (`meta.json`, `Endpoints.docker.Host`).
5. The default, `unix:///var/run/docker.sock`.

A pure function, unit-tested.

| Runtime | Socket | Context | Plugins |
|---|---|---|---|
| Docker Desktop | `~/.docker/run/docker.sock` | `desktop-linux` | All |
| OrbStack | `~/.orbstack/run/docker.sock` | `orbstack` | buildx, compose; no `desktop`, the rest as installed |
| Colima | `~/.colima/<profile>/docker.sock` | `colima` | Whatever Homebrew installed |
| Rancher Desktop | `~/.rd/docker.sock` | `rancher-desktop` | What it bundles |
| Podman | `podman machine`'s socket (a Docker-compatible API) | — | — |

The ones other than Docker Desktop weren't tried on this Mac; the paths are
from their documentation. Features turn on by the plugin being there and by
`/info`: the Model Runner section, for one, shows only when `docker model`
is there. `ssh://` and `tcp://` contexts (remote machines) are stage 3:
Database's `SSHTunnel` can forward the remote socket
(`ssh -L local.sock:/var/run/docker.sock`).

### Details

- **Version:** `/_ping`'s `API-Version` header; requests use the lower of
  the server's and ours.
- **Streams:** `events`, `logs?follow=1`, `stats?stream=1` and a pull's
  progress are chunked JSON. NIOHTTP1 decodes them; we split the log frames
  ourselves (pure, tested).
- **While Docker is off:** the panel and the page say so and offer "Start"
  (`docker desktop start`, or the runtime's command). They reconnect at
  measured intervals when it is back, and spend no CPU while it is off.
- **Compose labels:**
  - `com.docker.compose.project`
  - `com.docker.compose.project.working_dir`
  - `com.docker.compose.project.config_files`
  - `com.docker.compose.service`
  - `com.docker.compose.container-number`
  - `com.docker.compose.oneoff`
  - `com.docker.compose.depends_on`

  The project and service tree is built from these, without asking the CLI.
- **Files in a container:** the `archive` endpoint speaks tar; opening a
  file is reading a one-entry tar, writing it back is PUTting a one-entry
  tar (a pure tar reader/writer, tested). It works on a stopped container
  too.
- **Helper containers** (browsing, exporting a volume): a small image
  already on the machine, or `busybox` pulled once. The user is told before
  it is pulled. They are marked with a label and removed when done.
- **Credentials:** Overterm never sees a registry password. Whatever needs
  credentials runs in the terminal, with Docker's credential helper.

## 5. Interface

### Two layers

| Layer | When | What |
|---|---|---|
| **The Docker page** (⌥⌘P) | Managing: clean-up, images, volumes, builds, the engine | A page over the body (`WorkspaceOverlay`), as Settings and Notes are. Sections on the left (Containers, Images, Volumes, Networks, Builds, Models, Engine), the list in the middle, the detail on the right (Logs, Inspect, Files, Stats, Mounts). The engine bar along the bottom: context, status, total CPU and memory, disk, updates |
| **The Docker panel** (rail) | While working: "is this branch's database up, what does its log say" | The selected tab's checkout's stack at the top, the others below. A container picked shows its logs in the right slot, beside the terminal. The same single-letter actions |

Both share one model (`DockerModel`: the connection, the event stream, the
container and project tree). With neither the page nor the panel showing,
the list and the events still flow (one connection, for the port indicator
and the attention marks). Stats, logs and the image list are read only while
shown (CLAUDE.md: a panel not on screen reads nothing).

Terminal tabs are the third place: `exec`, `logs -f`, compose's and builds'
output. Overterm's own tabs in place of Docker Desktop's embedded terminal,
with splits, search, command blocks and asking an agent.

### Where it will be better than Docker Desktop

1. **Keyboard first.** No mouse needed (Section 6). A container's log is
   three clicks in Docker Desktop; here it is ⇧⌥⌘P and a few letters of
   its name, then ↩.
2. **Context.**
   - The list starts with the stack of the checkout you work in.
   - Ports are in the terminal's pane header.
   - A container that dies marks the tab that started it.
3. **Transparent.** Every action says the command it runs ("Copy as
   Command"); long work goes to the terminal.
4. **Readable logs.** JSON log lines unfolded, levels coloured. A compose
   project's services in one stream, coloured by service name. Jump to an
   error line. Selected lines to an agent with ⌘L.
5. **The editor one click away.**
   - A file in a container, the compose file, the Dockerfile and
     `daemon.json` in Overterm's editor, with syntax colours.
   - A container's file, saved, is written back into the container.
6. **Safe clean-up.** Prune lists what it will delete, with the total size;
   what is in use is never touched. `down -v` asks with the volumes' names.
7. **Help on errors.**
   - On "port is already allocated", it says who holds the port: which
     worktree's stack, which tab, which process.
   - An exited container's last lines and exit code are in the list.
8. **Fast.** Live from events; the list in 50 ms. AppKit and SwiftUI, not
   Docker Desktop's Electron interface.

## 6. Shortcuts

Two kinds:
- **Global ones:** in `KeyCommands` (rebindable, shown in Settings ▸
  Keyboard Shortcuts).
- **Single letters in the list:** only while the Docker list has focus.
  Never in the terminal or the editor; no key leaks there.

### Global (proposed)

| Shortcut | Command | Status |
|---|---|---|
| ⌥⌘P | The Docker page, open/close | Free (not in KeyCommands, nor among Ghostty's `super+alt` keys) |
| ⇧⌥⌘P | Go to Docker: by container, service, image or volume name | Free (no shortcut uses ⇧⌥⌘) |
| — | Compose Up / Down / Restart (this checkout) | Palette and menu; the binding is the user's |
| ⌘K | Docker entries in the palette: "Restart api", "Logs db", "Shell into web" | The existing palette |

In the switcher (⇧⌥⌘P), ↩ opens the logs, ⌘↩ a shell, ⌥↩ restarts, ⌘O
opens the port in the browser.

### While the list has focus

| Key | Action |
|---|---|
| ↑ ↓, ← → | Move; open/close a project |
| ↩ | Detail (logs) |
| Space | Quick look (as Finder's Quick Look): status, ports, the last log lines |
| `s` | Start / stop |
| `r` | Restart |
| `p` | Pause / resume |
| `l` | Logs |
| `t` | Logs in the terminal (`docker logs -f`) |
| `e` | Shell (`exec` in a new tab) |
| `f` | Files |
| `i` | Inspect |
| `o` | Open the port in the browser |
| `d` | Connect in the Database client (database containers) |
| `u` / `D` | Compose up / down (on a project or a service) |
| ⌫ | Delete (asked; a bulk selection lists them all) |
| ⌘A, ⇧↑/↓ | Bulk selection |
| `/` | Filter: text, or `status:running`, `project:api`, `image:postgres`, `port:5432` |
| `?` | This table itself, as a cheat sheet |
| ⌘C | Copy the name; ⌥⌘C the ID |

The keys stay close to lazydocker's and VS Code's habits. The page and the
panel use the same keys. ⌃1…⌃7 between the page's sections (only while the
page shows; ⌘1–9 are the tabs').

## 7. What only Overterm has

### Worktrees and compose

Compose's project name is, by default, the name of the compose file's
folder. Overterm's worktrees (`repo-wt-feat-x`) are different folders, so
they are different projects; so far, so good. But fixed host ports in the
compose file (`5432:5432`) fail the second worktree's stack with "port is
already allocated".

The page and the panel say which project, which worktree and which tab hold
the port. At first they offer to stop the other stack; in stage 2, a port
shift per worktree, or `COMPOSE_PROJECT_NAME`. New Task can, as an option,
start the worktree's stack too (stage 2).

### Ports

Container ports are listened on in `com.docker.backend`'s name, so the pane
header of a tab running `docker compose up` is empty today. The model gives
a project's ports to the tab whose checkout is its `working_dir`. The pane
header's port indicator, "Open" and the browser column then work for Docker
too, with a container icon so their source is clear.

### Database client

Images such as `postgres`, `pgvector`, `mysql`, `mariadb`, `clickhouse` and
`redis` are recognised. The container's env (`POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`, `MYSQL_ROOT_PASSWORD`…) and its
published port fill in a Database connection; the password goes to the
keychain. `cg-test-pg` on this Mac (pgvector, 55432) is exactly this case.

### Agents

The agent already has a shell and can run the `docker` CLI. What MCP adds
should therefore be three things:
1. **Scope:** the stack of the tab's checkout comes to the tools by itself.
2. **Structure:** logs come grepped, shortened, secrets masked.
3. **Confirmation:** restart, up/down and rm are asked of the user in the
   window (as `DatabaseMCP.allow` does).

Tools:
- `docker_ps`
- `docker_logs` (tail, since, grep)
- `docker_inspect`
- `docker_stats`
- `docker_files` (read)
- `docker_restart`, `docker_compose_up`, `docker_compose_down` (confirmed)

### Attention

A container that exits with a non-zero code or turns `unhealthy` marks the
tab that started it, and (if set) sends a notification.

## 8. Stages

Nearly all of Docker Desktop is the goal, but not all in one release. Each
stage is usable on its own.

| Stage | Scope | Size |
|---|---|---|
| **1. Containers and compose** (daily work) | Connection, context, the engine's status and starting it. Containers: list, actions, logs, inspect, mounts, files (editing in the editor included), stats, the `exec` tab, ports (pane header, browser). Compose: the project tree, actions in the terminal, merged logs. The page and the panel, the switcher, single-letter keys, the palette. Attention marks, the way to Database, MCP (reads and confirmed actions). Builds in the terminal | Large; as large as the Database client |
| **2. Management** | Images (list, layers, pull, tag, delete, prune, the Run window), volumes (list, browse, prune), networks, disk and clean-up with a preview, the `daemon.json` editor, compose's resolved model and compose in the editor, worktree conflicts, a Docker Debug equivalent, `top`/`changes`/`export`, Tab Info, the API client's OpenAPI discovery | Medium |
| **3. Docker Desktop's plugins** | Build history and detail, builders; Scout (CVEs, recommendations); searching Hub; volume export/import and cloning; Model Runner; MCP Toolkit; updates and diagnostics; Kubernetes status; remote contexts (SSH tunnel); Podman's and Rancher's differences | Medium, small per plugin |

## 9. Performance and reliability

CLAUDE.md's rules hold here too:

- **What isn't shown reads nothing.**
  - The event stream and the container list are one connection. It stays
    open while Docker runs and the setting is on; it spends no CPU while
    nothing happens.
  - Stats, logs, images, volumes and plugin calls are read only while
    shown.
  - The `performance` scenario measures idle CPU; it must pass with Docker
    on too.
- **Nothing waits on the main thread.** Network work on NIO's event loop,
  CLIs on a GCD thread, results to the main thread.
- **Large lists:** the image list, and a noisy container's log (thousands
  of lines a second). Logs keep the last N lines; the terminal for all of
  them. Tables in NSTableView (as Database's result grid: a SwiftUI list of
  thousands of rows doesn't scroll).
- **Secrets:** env values whose names contain `PASSWORD`, `SECRET`,
  `TOKEN`, `KEY` are masked in Inspect and in MCP's output. Registry
  passwords are never touched.
- **Side effects:** running a plugin can have side effects (`docker debug`
  started pulling an image). Overterm calls plugins only for a user's
  action, and only their documented JSON commands.
- **Isolated runs:** in E2E the socket's path comes through
  `AppEnvironment`. Tests never touch the user's Docker: either a fake
  engine, or labelled containers made for the test.

## 10. Tests

- **Pure parts, unit-tested:**
  - resolving the context and the socket,
  - the project tree from compose labels,
  - splitting log frames, JSON log lines,
  - reading and writing tar,
  - the stats arithmetic (the difference between two samples for CPU%),
  - merging ports (IPv4/IPv6 duplicates),
  - masking the env,
  - guessing a connection from a database image,
  - the filter syntax (`status:running …`),
  - "Copy as `docker run`",
  - the prune preview,
  - detecting worktree conflicts.
- **A fake engine:** a small server playing the Engine API on a unix socket
  in tests (like BridgeServer's HTTP). List, inspect, events, framed logs
  and `archive`, deterministic. The `docker` E2E scenario runs on it.
- **Plugins:** JSON samples taken from real output (`buildx history ls`,
  `model list --json`, Scout's SARIF).
- **Real Docker:** behind an environment variable, as the Database tests
  are (`OVERTERM_DOCKER_TESTS=1`): a small `alpine` container and a
  two-service compose project, made and removed. The containers are marked
  with a label, and only they are cleaned up.

## 11. Risks and unknowns

- **The plugins' stability.** The MCP Toolkit's CLI has changed already.
  The Scout, Model and Desktop plugins also change with Docker Desktop's
  version. Hence stage 3, each one checking that its plugin is there, and
  its version.
- **Podman and Rancher.** API compatibility is the same for most endpoints,
  but events, compose labels and plugins may differ. Only Docker Desktop is
  on this Mac.
- **Subscriptions.** Docker Debug wants Pro (we do it with busybox); some
  of Scout's work wants a sign-in.
- **Containers without compose.** Those started with `docker run` (as
  `cg-test-pg`) have no checkout; they sit under "other containers". They
  could be tied to a checkout by hand if wanted (stage 2).
- **Clashing project names.** Two folders of the same name in different
  repositories are the same compose project; `working_dir` tells them
  apart, compose itself mixes them up.
- **The helper container.** Browsing a volume needs an image; if the
  machine has none, the user is asked before it is pulled.
- **The size of the scope.** All of Docker Desktop is several times the
  Database client's work. That is what the stages are for.

## 12. Decisions (2026-10-27)

1. **Interface:** two layers: the Docker page (⌥⌘P) and the rail panel.
2. **Talking to Docker:** the Engine API; the CLI in the background for
   the plugins that give JSON; the terminal for what must be seen or needs
   credentials.
3. **Stages:** stage 1 takes in images, volumes and networks too (list,
   detail, actions, prune with a preview). Section 8's table is read with
   that change.
4. **Left out:** the extensions marketplace, Ask Gordon, Docker Desktop's
   resource settings, a Kubernetes interface, Offload and Hardened Images.
5. **Shortcuts:** ⌥⌘P, ⇧⌥⌘P, single-letter actions while the list has
   focus, `/` to filter, `?` for a cheat sheet.
6. **Agents:** every tool: reads and confirmed actions (restart, up, down
   and rm included).
7. **Runtimes:** Docker Desktop, OrbStack and Colima in stage 1.
