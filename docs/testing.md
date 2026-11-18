# Testing

Two layers. Run both before calling a change done.

```sh
make test   # unit + integration: pure logic, real git in temp repos (~3 s)
make e2e    # end-to-end: every scenario in the real, built app (~15 s, opens windows)
```

Both must run **outside the Bash tool's sandbox** (they spawn git, FSEvents,
and for E2E the app itself).

## Unit / integration — `Tests/OvertermTests`

Pure logic and anything that can run without a window: parsers (worktree,
status, numstat, name-status, branch log, unified diff), `FileTreeModel`,
`DirectoryWatcher` (real FSEvents), `WorktreeModel`, `TaskCreator`,
`DiffModel` (real repos, incl. no HEAD yet, a commit in a linked worktree,
the branch scope, its base without origin/HEAD, when it has nothing to
compare with, and which cards start folded and stay so), `DiffHighlight`
(colours per hunk side, a line's changed part, which lines pair; one capped
file's cost), `EditorDocument`,
`SyntaxHighlighter`, snippets, palette ranking, session file, `TabActivity`,
`GhosttyInput`, `TabStore`/`Tab`, and `ClaudeEdits` — Claude Code's edits
and why it made them, from transcript lines in its shape (one content part
per line, results on later lines, a subagent's without `toolUseResult`),
written by `TranscriptFixture` into a scratch projects directory: never the
real `~/.claude`.

The version (`VersioningTests`, `AboutPanelTests`): `VERSION` is SemVer and
`CHANGELOG.md`'s top entry, the changelog newest first; About's credits;
`Scripts/bump-version.sh` run for real on a scratch copy (with `/bin/bash`,
macOS's 3.2 — each part's arithmetic, the entry on top, a second run adding
to the same version, bad input changing nothing); and the hooks in a scratch
repository whose `core.hooksPath` is this checkout's `.githooks` (an app change
without VERSION refused, with it or docs-only committed, the escape hatch,
`v<VERSION>` tagged once). Those runs get no global git config and no
`SKIP_VERSION_CHECK` from the caller.

Tabs are real: the unit-test process never calls `ghostty_init`, so
`GhosttyRuntime` has no app and every `TerminalView` is surfaceless — no
pty, same object. Don't initialize the runtime in unit tests.

Async models supersede older refreshes by design; wait for them to settle
(`eventually { … }`) rather than asserting right after one call.

### Database drivers

`DatabaseDriverTests` talks to real servers. SQLite runs always; PostgreSQL,
MySQL and ClickHouse need Docker:

```
Scripts/database-test-servers.sh            # PostgreSQL :55432, MySQL :53306, ClickHouse :58123
OVERTERM_DB_TESTS=1 swift test --filter DatabaseDriverTests
Scripts/database-test-servers.sh stop
```

Without `OVERTERM_DB_TESTS=1` those three are skipped, so `make test` and
CI need no Docker. BigQuery's signing and its answers are tested offline.

It also starts an SSH bastion (:52222, on a Docker network with
PostgreSQL) for `SSHTunnelTests` and the `databaseTunnel` scenario; both
keep the host key out of your `~/.ssh/known_hosts`.

The same script starts an S3 server (RustFS, :59000) for
`StorageClientTests` (`OVERTERM_DB_TESTS=1`) and the `storage` scenario,
which skips itself when nothing answers there.

### Docker

`DockerTransportTests`, `DockerModelTests` and the `docker` scenario talk to `FakeDockerEngine`
(`Sources/Overterm/Docker/`): Docker's Engine API on a unix socket of its
own in `/tmp` (a socket's path must stay under 104 bytes), with containers,
images, volumes and networks held as values, events sent as the engine
sends them, logs framed, files as tar. Nothing touches your Docker.
`DockerSSHTests` and the scenario reach it as a remote engine too, through
`FakeSSHHost`: a throwaway sshd on 127.0.0.1 with its own host key, the one
client key it lets in and its own known_hosts — ssh told `-F /dev/null` and
no agent, so nothing of your ~/.ssh is read or written (skipped where
`/usr/sbin/sshd` won't start).

```
OVERTERM_DOCKER_TESTS=1 swift test --filter DockerTransportTests
```

adds calls to the engine your terminal's `docker` reaches, to check that
the models still read what it answers: reads (`_ping`, `info`, the lists),
then exec, files, a volume's export and import, and a container's limits
and name changed, on a container and a volume of their own — labelled
`overterm.test`, made from `debian:bookworm-slim` only if it is already
there (nothing is pulled), and removed after.

`OVERTERM_DOCKER_TESTS=1 swift test --filter ComposeConfigTests` runs your
`docker compose config` on a project of its own, to check that Compose
still answers what the plan reads. It reaches no engine: `DOCKER_HOST`
names a socket that isn't there.

An Up looks at a stack's ports first (`DockerPageModel+Ports`), which
asks `docker compose` and probes ports: never in a unit test unless the
test sets `DockerPageModel.checksPortsInTests` and a stub `docker` of its
own (`ComposeUpTests`), never in a scenario without a stub. The `docker`
scenario's one real `docker` call there is `compose … config` on the
override it wrote, with `DOCKER_HOST` at the fake engine's socket: config
reads files, not the engine.

Builds come from recorded shapes: `Fixtures/buildkit-rawjson-*.jsonl`
are BuildKit's `--progress rawjson` lines — SolveStatus as
client/graph.go's json tags and Go's encoder write them — and
`DockerBuildProgressTests` folds them as the plain printer does. The
scenario's and `DockerBuildSessionTests`' `buildx history` is a stub
`docker` (`DockerCLI.override`, `DockerCLI(executable:)`); a page in a
test process reads builds from nothing else (`buildsCLI`). No test runs
buildx.

What SwiftUI draws itself has no AppKit view to find: a bordered
`Button`, a plain `Text`. A `Text` with `.textSelection(.enabled)` is an
`NSTextField`, which `find` reads. In-process accessibility stays empty
without an assistive app, so the `docker` scenario reads a button's label
off the window's pixels (Vision, `readWindow`) and clicks there with
events queued for its own window (`click(at:)`) — queued, not sent: a
mouse-down that tracks the mouse would wait forever for a mouse-up sent
after it.

Vision's accurate reading can come back empty — no results, no error —
for a large, mostly dark capture (a sparse Kubernetes page at 4112×2466),
so `recognized` reads an empty window again in overlapping 1400-pixel
tiles. A line is what Vision calls one: a table's cells, a sidebar's rows
and a field are each their own, so a check for two texts asks for both
anywhere (`drawn([…])`), never on one line. A check that something is
*not* drawn passes only on a read that found the text it was anchored
to (`notDrawn(_:besides:)`) — an empty read proves nothing. Look for a
part of a value Vision reads as written: it read `acme` as Cyrillic.

`shownText`'s tiles overlap by half across, so a line up to 350 points
wide is whole in one of them (a detail's caption that straddled two
tiles was read in halves); a tile's edge can still cut a longer line, so
a check that picks the first match names everything it needs in the
match itself. Text below the fold isn't drawn, and a `LazyVStack`
builds nothing there: scroll to it first (`revealChart`,
`revealElement`), never wait longer. A failing read says where the read was asked
(file:line — a scenario has several checks called "drawn"; a helper
that reads passes its caller's `#fileID`/`#line` on), how many lines
were read and the window's size (`sawInstead`). With
`OVERTERM_E2E_READ_DIR` set, the check that fails after it also saves a
picture of the window there (its path in the failure, 20 a run) — only a
failing check, never a read expected to find nothing, and nothing outside
a folder the person named. The text itself only with
`OVERTERM_E2E_READ=1`: a scenario reveals a Secret's value. While a part
may draw one (`withholdPictures` — the Secret's detail, Apply's diff of a
Secret, the database form a pod's Secret fills) neither the text nor a
picture is ever kept. Vision reads `l` as
`1` and puts a space after a comma (`Ready, SchedulingDisabled`): match
what it may read, not only what is drawn. It also reads Latin letters as
their Cyrillic look-alikes (`сpu 250m`, `64Mі`); every read is given back
with those put back to Latin (`latin`), so match the Latin text.

A value that needs time to be true is waited for as long as it takes: a
sampled chart's caption needs two samples, 15 s apart — a 15 s read of
it raced the second sample in a full run.

Each scenario's parts start from a settled window: a part that closes its
tabs leaves the new selection's keyboard queued for a turn later
(`kubernetesPart` pauses after each), and a part that opened the editor in
that same turn saw the terminal take the keyboard back.

### Kubernetes

`FakeKubeAPI`'s Metadata rows carry an object's owners only when a test
says so (`setRowOwners`), as a server's `PartialObjectMetadata` always
does: without them a namespace's chart grouped its pods by their names
until the rows came and by pod after — the check passed or not by timing.

The unit tests and the `kubernetes` scenarios talk to `FakeKubeAPI`
(`Sources/Overterm/Kubernetes/`), with the real kubectl as its proxy where
one is installed, through kubeconfigs of their own. This Mac's
`~/.kube/config` has real clusters and its current context is production:
no test reads it, and an isolated run sees no kubeconfig but
`OVERTERM_KUBECONFIG`'s.

`KubeRealClusterTests` runs Overterm's own proxies, client, `can-i`, tree
and health checks against a real cluster — a kind cluster made only for
it:

```
Scripts/kube-test-cluster.sh create       # kind cluster "fake", context kind-fake (~1 min; pulls kindest/node once)
OVERTERM_KUBE_TESTS=1 OVERTERM_KUBE_TEST_KUBECONFIG="$(Scripts/kube-test-cluster.sh kubeconfig)" \
  swift test --filter KubeRealClusterTests
Scripts/kube-test-cluster.sh delete       # the cluster, its node container, the file
```

Without `OVERTERM_KUBE_TESTS=1` it is skipped, so `make test` and CI need
no cluster. The script's kubeconfig is a file of its own (a folder given
as its second argument, else `$TMPDIR/overterm-kind`; never under
`~/.kube`, never one `KUBECONFIG` names): kind writes into `~/.kube/config`
unless told otherwise, so every kind command gets `--kubeconfig`. The node
container is kind's node image with one label added (`overterm.test`).
The suite refuses a kubeconfig under `~/.kube` or one whose one context
isn't `kind-fake` on 127.0.0.1; every kubectl it starts gets that file as
`KUBECONFIG`, `--context` and a HOME of its own; a second file of its own
adds `fake-dev` (remote: read-only) and credential plugins over the same
cluster, whose tokens (two ServiceAccounts', ten minutes) are in the
plugin's environment, never on disk. It works in a namespace of its own
(`overterm-test-…`, labelled `overterm.test`), deleted when it ends. It
needs `registry.k8s.io/e2e-test-images/agnhost`, pulled by the node.

What it checks — analysis.md Section 12's questions about the proxy, as
kind's Kubernetes v1.37.0 answers them (2026-11-07, kubectl v1.36.1):

- a read-only socket answers every method but GET — a lowercase or unknown
  one too — with kubectl's own `403 text/plain` "Forbidden", and nothing is
  made;
- no path variant reaches exec, attach, port-forward or a pod's, Service's
  or node's proxy on either socket: encoded slashes and letters, `//`,
  `/./` and `..` (a 307 to a path refused in turn), a changed case (the
  server's 404), trailing segments, a query, a WebSocket upgrade;
- every subresource the server lists with `get` that isn't a read is
  refused — exactly the six the list names on kind, and no API is
  aggregated (a new one fails, named);
- a failing credential plugin runs again for every request kubectl gets,
  and a refused token (401) is asked for again: Overterm stops the context
  at the first of either and runs the plugin again only on Retry; a token
  the server takes is run for once;
- a real `kubectl port-forward` whose pod is deleted goes on listening
  until a connection, which fails, then exits 1 ("lost connection to pod");
- a streaming list with Tables ends at its `k8s.io/initial-events-end`
  bookmark (on the Table's row), well before the 5 s that would give it up,
  an empty one with its columns, and the context goes on streaming;
- the metrics proxy reaches the Service's query and query_range paths and
  nothing else;
- a write on a writable socket, none on a read-only one;
- `kubectl auth can-i`: yes for kind's admin, no for a ServiceAccount with
  no role;
- a Deployment's tree (ReplicaSet, pod, ConfigMap, PVC, Service) and the
  namespace's health findings on real objects.

The Kubernetes scenarios each get a kubeconfig of their own from the
test — a temporary file the scenario writes once `FakeKubeAPI` listens
(`OVERTERM_KUBECONFIG`), never `~/.kube`:

- `kubernetes` — the page end to end, its parts one after another
  (`kubernetesPart`): lists, details, logs, Terminal in This Context,
  Secrets, writes and their confirmations, Helm, GitOps, the bound
  checkout, the agents' `k8s_` tools (about 260 s);
- `kubernetesCharts` — the Metrics tabs: a pod's, a workload's, a node's,
  a namespace's, sampled and over `FakePromQL`'s Prometheus;
- `kubernetesOverview` — the Overview's cards, dark, light and narrow
  (`OVERTERM_DUMP_PNG` captures each);
- `kubernetesPerf` — 5,000 pods: the first draw, a burst of 500 events,
  the scroll;
- `kubernetesScale` — 5,000 pods across 50 namespaces with their
  workloads: lists, the Overview's health checks, a 200-pod tree, the
  footprint after;
- `showcase` photographs the page on `fake-prod` with a pod's Metrics
  tab (below, Looking at the UI).

### Terraform

Terraform changes real infrastructure: no test runs it against anything
of the user's. Unit tests are guarded (`AppEnvironment.guardsTerraform`):
no terraform but `OVERTERM_TERRAFORM`'s, nothing of the shell in a run's
environment, a HOME and CLI config of the run's own, proxies at a dead
port. A unit test that needs a terraform process uses a stand-in
(`TerraformRecorder.writeStandIn`) behind the recording wrapper
(`TerraformRecorder`), which records each call's argv, folder and
environment names — never a value but the few Overterm sets.

`TerraformRealBackendTests` runs the real terraform, offline, against
`FakeTerraformBackend` (an `http` state backend on 127.0.0.1):

```
OVERTERM_TF_TESTS=1 swift test --filter TerraformRealBackendTests
```

The binary is `OVERTERM_TF_TEST_TERRAFORM`, else Homebrew's. Every run is
in a temporary folder the test makes, through the wrapper, with the
guarded environment — its CLI config fetches no provider
(`direct { exclude = ["*/*/*"] }`) — and only `terraform_data`, which is
built in. It refuses to start when its own environment sets any
credential variable (`AWS_*`, `GOOGLE_*`, `ARM_*`, `TF_TOKEN_*`,
`TF_VAR_*`, `KUBECONFIG`…) rather than unsetting it. Without
`OVERTERM_TF_TESTS=1` it is skipped, so `make test` and CI need no
terraform.

The `terraform` scenario (`E2ERunner+Terraform.swift`) runs the installed
terraform — `OVERTERM_TF_TEST_TERRAFORM`, else Homebrew's, passed to the
app as `OVERTERM_TERRAFORM` — behind the recording wrapper, in the guarded
environment, over checkouts it writes (`terraform_data` only, no init):
colours, validate's diagnostic on its line, Format undone, format on save
only in a checkout that passes `fmt -check`, F12 and ⇧⌘O, and the checkout
byte for byte the same after validate. Without a terraform the test is
skipped, saying so.

The `terraformRoots` scenario (`E2ERunner+TerraformRoots.swift`, stage 1b)
writes a checkout of two `terraform_data` roots, a module and an `http`
backend nobody reaches: the rail panel reads nothing while hidden (no read,
and the wrapper records no call), lists the roots and the module with its
caller, `envs/prod` production; `version -json` is the one terraform it
runs. A pane types the real `terraform -chdir=envs/prod console` through the
wrapper in `env -i` (a scratch HOME and CLI config, proxies at a dead port)
and gets the header; the console is ended by its pid. Provider-sized
writes under `.terraform/providers` don't refresh the changes pane; a
second worktree says "no state here" and "shares its state". The process
walk is unit-tested with a stand-in script (`TerraformPaneWarningTests`).

The `terraformAgents` scenario (`E2ERunner+TerraformAgents.swift`, stage 1c)
checks agents' guards without starting an agent: Claude Code's launch
command in a checkout with a production root carries the deny rules
(`agentCommand`, recorded — the tab is made with `startAgent: false`),
Codex's is "not guarded", a checkout with no Terraform gets nothing. A
script in the agent tab prints a Claude Code permission prompt for
`cd envs/prod && terraform apply -auto-approve`: the tab is marked with
envs/prod, production; the Inbox's card has no answer and `answer` types
nothing; the mark goes when the screen is cleared. With the window off
screen (`lightTickVisibility = false`, so no light tick), an agent tab whose
shell is in a checkout with no Terraform runs a stand-in agent that works
in the one with production roots: its folder is followed there all the same
(`OffScreenAgents`), a stand-in `terraform output` it runs marks the pane
as having printed secrets, and its ask is read and said as production —
each step waiting for a file the scenario writes. The scenario runs the
real terraform itself (init and `plan -out`, `terraform_data` only, in the
guarded scratch environment) and reads the plan through `tf_plan_summary`:
the sensitive variable's sentinel absent, `show -json /dev/fd/3` the only
call through the wrapper, with no credential; `tf_validate` runs where the
lock file is committed and refuses where there is none; Ask Why on a failed
validate lands in `terraformBriefRecorder`. The decoder's sentinel test
(`TerraformPlanTests`) reads `Fixtures/terraform-plan-sentinels.json`,
Terraform 1.17.1's `show -json` of a sandbox plan with a moved, imported
and forgotten resource, drift, an action and an unknown key planted, a
sentinel in each path the decoder drops or masks.

The `terraformPlan` scenario (`E2ERunner+TerraformPlan.swift`, stage 1d)
plans through the app as a person does, the questions answered by
`terraformPlanQuestionRecorder` and the plugin cache's offer by
`terraformCacheOfferRecorder` (no sheet). Its checkout has a local root
whose state the scenario makes with the CLI (guarded scratch environment)
before changing a tfvars line, a root on `FakeTerraformBackend` (in the
app's process, 127.0.0.1), one whose `.terraform/environment` names a
workspace that doesn't exist, a production root and a sandbox root:
the first plan fails on a variable with no value and offers the var file;
with it, the replace is first, its cause chain ends at the changed line,
the plan file was 0600 in a 0700 folder left empty, the wrapper saw
`plan … -lock=true -lock-timeout=10s … -var-file=dev.tfvars` and `show
-json /dev/fd/3`, and three sentinels (a sensitive variable's value — also
copied, unmarked, into `terraform_data`'s `output` —, an unmarked password,
a token) are in neither the model, the log, Copy Summary nor the
accessibility text; the missing workspace is refused with no terraform run
there; Init asks with its fetch list; a lock `holdLock` holds is named
with Wait for It and Ask Why; a second worktree's plan of the shared state
turns stale once the first worktree's pane runs `terraform apply` typed
(a cleared environment, the fake backend, a `sleep 5` provisioner so the
header sees it); an agent's `tf_plan` is asked once, runs with
`-lock-timeout=0s` and no var file, and what `tf_run_status`,
`tf_plan_resource` and `tf_plan_summary` say has no sentinel; production
is refused. The stage's pure parts — the plan line and what it can never
be, the run's environment, 5.3's verbs by class, the workspace check,
locks in Terraform's words, the UI stream, the plan zip, the run folder,
the stream run against stand-ins (the umask launcher, the file held and
unlinked, exit 1 keeping nothing), rows, attributes, the cause chain, the
risk list and the questions, init's fetch list, the queue — are
`TerraformPlanTests.swift`, with a planted plan whose every sentinel path
is checked against everything said from it.

The `terraformApply` scenario (`E2ERunner+TerraformApply.swift`, stage
2a) applies a local root's plan in the plan's environment — a hostile
`TF_CLI_ARGS_apply` never reaching it —, asks for the root's name on a
destroy and on production, asks before a pane, the window or a tab
closes while the real terraform applies (Interrupt leaving the resource
tainted and the lock free), and finds an apply whose record was lost by
its pid. `terraformPerf` decodes a generated 2,000-resource plan and
shows and filters its rows in the slot within Section 10's budgets; no
terraform runs. The later stages' checks run inside these scenarios:
`terraform` holds 2b's worktrees (`E2ERunner+TerraformA2b.swift`), 2c's
state and outputs and 2d's drift and tests (`+TerraformB2c`,
`+TerraformB2d`) and 2f's review section (`+TerraformC2f`);
`terraformPlan` holds 2e's Force Unlock (`+TerraformA2e`). Every one but
`terraformPerf` needs an installed terraform (`OVERTERM_TF_TEST_TERRAFORM`,
else Homebrew's) and is skipped without one.

### Activity

The census (`Sources/Overterm/Activity/`, docs/design/activity/analysis.md
Section 10) reads the real process table, and a test may only ever touch
processes it started. The kernel is a protocol, `ActivityKernel`:
`FakeActivityKernel` is a whole Mac a test makes — other users'
processes, 20,000 sockets, a clock it moves — for the classification,
the bounds and the rates. Real processes are the test's own children
only (`TestChild`, `Tests/OvertermTests/ActivityTestChildren.swift`):
spawned into a group of their own, never the runner's, their identity
(pid and start time) read at spawn and read again before the one SIGKILL
their cleanup sends, then reaped. Never a name, a pattern, `kill(-1)` or
a group the test didn't make. A child that wouldn't end on its own ends
itself (a busy loop's `ulimit -t 20`): a runner stopped by ⌃C, whose
SIGINT never reaches a child's own group, or a crash leaves nothing
burning a core. What the tests plant is invented (`acme-*`,
`SENTINEL-*`); no assertion message carries an argv, an environment
value, a path or an address of a process that isn't the test's.

- `ProcessTableTests`: the headroom retry, every field, parents by
  start time; a child's start and parent, a zombie child, a `nohup`'d one.
- `ProcessUsageTests`: rates by the interval measured, 250 ms at least and
  15 s at most, the first sample "—", baselines that survive readers asking for others
  (Tab Info's split-tab 0%); a busy child's rate.
- `ProcessArgumentsTests`: argv masked at the read and cut at 64 KB, the
  environment scanned in place for four names only — a sentinel planted
  in a python child's environment never in any string the read makes —,
  a reader's own names alone (Terraform's three, a closed set no
  secret's name is in), argv's words handed to it inside the read,
  the region cleared, a `CS_RESTRICT` child's environment hidden; a full
  region never parsed (an area an `exec` grew read again, one past
  `kern.argmax` refused); a title written over argv read alone, a
  python child's that writes one too.
- `ProcessCommandTests`: a command line as Tab Info's tooltip shows it,
  read as the census reads argv — a fake password, made at run time,
  masked in every form (a flag's, mysql's `-p`, a URL's, a bearer's, with
  a space in it, starting with `/`, inside Claude Code's `eval`) —, while
  which agent runs (argv[0] a long relative path that masking hides) and
  the session a Claude resumed (`--fork-session -r <id>`) are taken off
  the raw words inside the read.
- `SocketScanTests`: the classification from fixtures; a child handed
  listeners on 127.0.0.1 and ::1 and a bound UDP socket; a child holding
  3,000 sockets read 2,000 a tick, rotating.
- `ActivityTextTests`: masking for display, for titles (as commands) and
  for agents, `Secrets`' per-program passwords (9.3), interpreters'
  labels, masked before they are cut.
- `ActivitySamplerTests`: a tick over a fake Mac — two panes read in turn
  both reading their CPU (Tab Info's split-tab 0%), the first sample "—"
  and a reused pid's again, rates only over 250 ms and never over a gap,
  what each level reads, a tagged process joining its pane (a tree's
  members' environments never read), the pane's agent and its folder, an
  `exec` read again; the churn budget (200 a tick, the level's own first —
  what carries a pane's tag among them once it is known —, then the
  oldest, and the time the reads may take), a read still to come told
  from a failed one, the cache's bound (ended identities first), the
  in-flight guard, the stretched cadence, a folder on a mount that
  doesn't answer, one waited for bounded by its deadline, one read since
  a moment (an MCP call's) never the one known while a read goes on, at most 200
  folders asked a tick, the app's children
  for the pairing and the logins no pane has, listed on its queue (a
  zombie `login` left out); a lookup answered from the
  latest snapshot while it is a tick old at most, else a tick, a cold one
  reading what the budget left in the same call, one waiting for the tick
  in flight; then a busy child of the test's through the real
  kernel. The fake's clock moves only when told — a call made to cost
  time or held (`FakeActivityKernel.onCall`, `CallGate`) — so nothing
  waits on a moment.
- `ProcessInspectorTests`: a tab's tree a lookup in the census — a split
  tab's two panes asked for in turn both reading their CPU, no new scan
  while a snapshot is a tick old, a tag alone or a root no pane has, a
  setuid child, one running as the user only for now and a zombie left
  out of a tree (Tab Info's own nodes name them), an agent's folder at
  once, a reused pid inheriting nothing, a command and
  its tooltip masked as it is read —, then the test's own children: a
  tree, a nohup'd python found by its tag among every process's markers,
  two busy roots read in turn.
- `SurfaceProcessesTests`: which `login` is whose, stand-in surfaces over
  a fake Mac — a list a tick old never pairs a new pane with a closed
  pane's `login` (ended, a zombie, its pid another's since), a surface
  made after a list takes nothing from it, the oldest surface the oldest
  `login`, a pairing over only with its `login`, waiting surfaces paired
  from a list read off the main thread (Tab Info's, as it opens), and
  from a census that landed — a zombie `login` never paired, one taken
  since never offered twice; the app's children from one read of the
  table, a zombie `login` left out.
- `TabSuspensionTests`: the sends through `ProcessSignals` over a fake
  Mac, the shell stopped first and continued last; what Suspend Tab stops
  read at the press — a lookup that always ticks, where the census's
  other readers answer from a snapshot a tick old; the pane's set
  (`ActivityPaneSet`) — a tagged daemon whose child sits on a pty of its
  own, a tmux by name, an app and its helper, a nohup'd job and a tree
  member on another terminal left out, what left the terminal and a dev
  build's `.app` inside a checkout kept; the pane's own jobs on its
  terminal kept whatever their path — Xcode's toolchain, a framework's
  `Python.app`, a CLI in an app's `Contents/Resources`; a reused pid
  never resumed.
- `TabInfoModelTests`: Tab Info over its tab's slice — a split tab a group
  a pane, each labelled (masked), the shell its dimmed root, what left a
  terminal under its pane, both panes' busy children's CPU, the
  footprint, the ports from the census's sockets (no lsof), a snapshot of
  another tab left alone.
- `ListeningPortsTests`: where a listener is opened — its URL from its
  sockets' bound addresses and families (6.8's table, on documentation
  addresses: a dual-stack wildcard or both families on loopback
  `localhost`, IPv4 alone `127.0.0.1`, IPv6 alone `[::1]`, one address
  that address, a loopback alias such as 127.0.0.2 too, a link-local one
  nothing to open) —, a process's v4 and v6 sockets on one port one entry
  with the widest scope and its holder's identity, a published port
  reached where it is published; who holds a
  port, the census's (the oldest of the user's listeners, a UDP socket
  or a connection from the number none, another user's never named) and
  a real child's listener named by the walk; the bind probe on a real
  listener, and on a socket bound to one of this Mac's own addresses —
  bound, never listening, so no firewall asks — which the wildcard and
  loopback probes alone never met. A port is watched with the census
  (`KubePortForwardTests`' and the `kubernetes` scenario's forward gone),
  never by binding it. A forward's scope is where kubectl listens, and
  Tab Info says the address of one that isn't this Mac's alone
  (`KubePortForwardTests`).
- `TabLightReadTests`: the light tick's consumers from a fake census —
  each pane's own ports (what carries its tag outside its tree under it),
  a holder's v4 and v6 sockets one pill, none for a setuid program the
  pane runs (only what runs as the user alone), the tab's ports sorted, a pane
  the snapshot has for another tab not this tab's; an agent's folder read
  since a moment over the one the tick knew (the `follow` scenario's: off
  screen, an agent's `tf_` and `k8s_` calls scoped at their first ask to
  the worktree it just entered); the focused pane's
  agent first, its folder followed once read, kept while it isn't, nothing
  to follow where it can't be read; Docker's "a tab holds the port" from
  a census of every pane, a process outside every pane no tab's. Setting
  them on the tabs is the `info` scenario's — a server started in a tab
  that isn't selected shows on its pill, and a window off screen wants no
  light tick until it shows — and the `docker` scenario's: a container
  whose port a server holds in a tab that isn't selected names that tab.
- `ActivityMonitorTests`: one tick for every reader at the fastest
  cadence, the ticks stopped at the last `unwant` and when a reader goes
  away, an early tick only for a wider want and once for a burst, one-off
  censuses coalesced and nil when the table can't be read, agents served
  from a snapshot at most one interval old (at 1 s too), a tick in flight
  never doubled, the context rebuilt once for a burst of changes, at its
  limit for one that never quiets, and by the early tick a tab opened and
  wanted in the same turn makes; a pairing a snapshot brought bringing
  the next tick early; a busy Mac's 5 s.
- `ProcessSignalsTests`: the one signal path over a fake Mac — the refusals
  made before any call that touches a process (pid ≤ 1, this process, what
  doesn't run as the user alone: a setuid program's, root's, another
  user's, and what runs as the user only for now, its real or saved uid
  another's), a pid taken again before the token or after it (the token
  then reaches nothing), or, with no token, after the path was read and
  before the kill, an exec since it was listed or between the token and the
  send told apart from an end (its own binary again too), a deleted
  executable, a stopped target continued after TERM and INT but never a
  traced one, no token or no token call (only a single TERM or INT falls
  back),
  Overterm's helpers by where they sit and by their group (an apply found
  again, a plugin reparented), the gate and the real kernel's own check of
  it; then the test's own children through the real kernel: a setuid `top`,
  refused by its effective uid though `kill(child, 0)` passes, kept alive by
  an output pipe the test never reads and ended by its own SIGPIPE; a bash
  that execs sleep after it was listed, and between the token and the send
  (the old token's ESRCH); a token across an exec and an end (a zombie's
  ESRCH the kernel's, a reaped pid's the gate's); a dead child, a zombie and
  then reaped; an unregistered child the real kernel's sends refuse, though
  a `ProcessSignals` was handed a gate that registered it; a
  `ManagedProcess`'s member let go to launchd, a helper's by its group; an
  apply's group while a run has it; a sleep
  stopped, continued and ended by its token; its priority — Run in
  Background and back, a nice raised a step then to 20, never lowered — and
  the real kernel's `setpriority` refused for what isn't the run's own. A
  priority over the fake Mac is checked as a signal is (refusals, the
  gate, a reused pid, an exec, no token, a nice no higher). A group's send (6.10 step 9)
  over the fake Mac: one `killpg` once the leader is pinned and every
  member checked; refused for a member that started before the leader, is
  in another session, isn't the user's alone or is a helper's, for a
  leader that doesn't lead its group, and for a member not the run's own
  in an isolated run; an ended leader's pid another's says so. In
  `TerraformApplyTests`, the close guard's Interrupt over the fake Mac: its
  targets kept (terraform's own group, terraform alone in an agent's); a
  group refused — a member older than the leader, a helper's in it — sends
  nothing and is said, never terraform alone instead; no start read by
  `find` reaches nobody; with no token call terraform alone still goes by
  its pid and its own group is refused and said.
- `ActivityHeldTests`: a Suspend's tree stopped only once its root was, a Resume planned again at its button; what Activity stopped and put in the background,
  kept by identity — resumed as kept, a Suspension whole from its root;
  let go only by a census read after the change; the quit question's
  count read now and its Resume and Quit, children first by token, a pid
  another process holds since never sent anything, one it couldn't
  continue still held and asked about again.
- `ActivitySignalCheckTests`: the pane pill's Free… over every class a pill
  can name — the owners' own verbs, the never-list (what runs as the user
  only for now among it), a terraform write interrupted wherever it runs,
  the agent's critical Stop, a helm or pulumi write's critical sheet and
  its reading from a masked argv, what outlives its terminal and apps
  refused — and every Free asked, the owners' own verbs too.
- `SystemMetersTests`: the meters' arithmetic — CPU a core between two
  reads, none for a first one, the counters' wrap at 2³², a changed core
  count, a core whose counters didn't move or a gap over 15 s without a
  rate; memory in Activity Monitor's terms; the pressure
  and thermal words; the full tick carrying them and the light one never
  asking; the real kernel's counters, counts only.
- `ActivityRowsTests`: the page's rows over a fake Mac — everyone's
  processes, other users' without numbers, a first sample "—", CPU first
  once rated, the busiest five, only yours without `activity.everyone`, a
  test run's own tabs' alone with the Mac counted, the user's listeners
  by number with their tab and reach, what each row says to VoiceOver,
  numbers written the same in every locale, a tab's title masked as a
  command in the rows and their labels, the Started column's words, when
  the header says "Reading…" and what an empty section says; the page's
  want — the full level only while it is shown in a window on screen with
  Activity on, its rows dropped when hidden and none made while hidden;
  the ⌃⌘A switcher's rows (ports by number, then the ten busiest with a
  rate) and its hold, every second while open, its rows kept once rated,
  a masked title's secret in none of them; ⌘K's Activity tab only while
  Activity is on.
- `ActivityPortsTests`: Listening over a fake Mac — a holder's v4 and v6
  one row and UDP without a URL, the URL by the bound families, the
  owners in order (a container by its published address, port and
  protocol, never the number alone, and its own row "via the engine"
  only at the Mac's or its checkout's scope; a forward keeping its https,
  a database tunnel, the bridge, a pane, AirPlay Receiver, a brew service
  by `XPC_SERVICE_NAME`, a job by a LaunchAgent plist's program — plists
  read from a temporary folder, none under test; a link and a FIFO never
  read, a program behind a link resolved), an engine's listener on no
  published port its host network, one number on two host addresses two
  containers, a container's own row bound and given its URL as published
  (and its collision with a checkout's server), one socket's holders one
  row, connections paired by the 4-tuple — a socket two processes hold
  paired once, a remote address never in a row's id, those past the cap
  counted —, a tunnel client's "forwarded by" past the cap too, apps'
  ephemeral listeners folded (never a server of the user's elsewhere) and
  a filter finding them, the switcher and the count reading them,
  Listening's filter keys, Open as https.
- `PortCollisionsTests`: a port split across IPv4 and IPv6, a specific
  address beside a wildcard (a dual-stack `::` counting, a v6-only one
  not), `SO_REUSEPORT`, AirPlay Receiver beside a server — each said on
  both rows from its side —, none for one holder, one shared socket,
  another protocol or port, or a connection; the note on a built row and
  in its VoiceOver label, `is:collision`.
- `NettopListenersTests` (D-25): a pinned, hand-written fixture
  (`Fixtures/nettop-listeners.txt`, every name invented) — a name with
  spaces or dots, the pid after its last dot, `:` before an IPv4 port and
  `.` before an IPv6 one, a zone left out, UDP without a state, a
  connected UDP, an established TCP and QUIC no listeners, one listener
  twice once —; anything else failing the whole parse; the blind check
  (checked, unchecked, blind; 0 rows blind, a listener that closed while
  it ran no proof); and a read through a stand-in the test writes — its
  own child, nettop's arguments checked — while the real nettop is never
  run under test (`Reader.unavailable`).
- `LaunchdSocketsTests`: fixture plists in folders the test hands over
  (`Fixtures/launchd-sockets/`: a number and a name, a dict and an array
  of them, dgram as UDP, a unix socket's, none, a broken plist), names
  through the fixture's services file; the user's own job only alone on
  a number — beside another's, both named; `/Library/LaunchAgents`'
  stopped in the gui domain; a unit test reads no launchd folder of the Mac's
  (`AppEnvironment.launchdSocketFolders`).
- `ActivityListenerSourcesTests`: over a fake Mac, a nettop reading's
  rows — launchd's named and refused, the user's own LaunchAgent's its
  service's stop, Bonjour by name, another user's the read route, the
  user's own left to libproc, a pid the table lacks or one started after
  the read left out, their Since, their ephemeral ones folded apart —; a
  blind, narrow or mine-only read shows none; a typed `kubectl
  port-forward`'s and `ssh -L`'s targets, clustered flags too (`-fNL`,
  `-NR`), an `ssh -R`'s "forwarded by"; unix-socket listeners only
  behind their setting, a co-holder, no Free; more known holders, a
  user's own non-platform `sshd` theirs, and a brew service of a known
  tool its service.
- `ActivityMCPTests.testAPortNoneOfYoursHoldsIsReadThroughNettop`: an
  agent's `port_holder` through a stand-in nettop — a believed read names
  launchd's job, a blind one is unknown, a port the user holds starts no
  nettop. `ActivityBriefTests`: a unix socket never in the brief.
- `ProcessOpenFilesTests`: the Files block's read over a fake Mac —
  files by path, sockets in words, pipes and kqueues named, an unreadable
  path said —, another user's and a reused pid nothing; a path read
  that never returns (the fake's call held) left behind, later reads
  saying so at once.
- `RunMarkersTests` (stage 3's groundwork, 6.9 and D-15): the run's
  marker, its kind from the bundle's place, set over an inherited one
  and taken off a login shell's answer; every argv sign spelt and read
  back, through the masking too, and nothing that only looks like one;
  the leftover check's rules — never the pid alone, a start before the
  run's another's, a record younger than its process the pid taken again
  — over a fake Mac, only the run's said and nothing of an environment
  but the marker; lineage first — a person's `tail` or `grep` naming the
  scratch folder under a shell older than the run never found, an
  orphan's child found, a registry's pid and what is still under the app
  only inside it —; and a real child of the test's (perl, its argv a
  ControlPath) found by the live kernel; every spawn path's markers —
  where each builds its child's environment, and printed by a real child
  of the test's at the spawn through `ManagedProcess`, `KubeProcessRun`,
  `TerraformRun`, `TerraformStreamRun` (both ways it starts), a detached
  apply's launcher, `Git.run`, `env` as Docker's CLI runs it,
  `DockerCLI.lines`, `SSHTunnel.open` (a stand-in ssh) and the login
  shell's run; a pane's tag and run, never a helper; the tunnel's
  ControlPath (short, under `_CS_DARWIN_USER_TEMP_DIR`, never made,
  `none` when too long or expandable, or when its folder is a link or
  another user could write in it); the kubectl socket folder named by pid and start, a
  folder whose pid runs another process swept. `SSHTunnelTests`' spike:
  the tunnel's own ssh through `FakeSSHHost` to a listener of the test's,
  forwarded, its stderr silent about the path, nothing made there.

**The isolated-run gate.** A unit test or an isolated run is guarded
(`AppEnvironment.guardsSignals`), over every change Overterm makes to a
process it didn't spawn — every signal, a priority (`setpriority`) and an
app's Quit and Force Quit (`terminate`/`forceTerminate`, which the live
kernel's `quitApp` checks the gate for itself), each through the same gate: Activity changes
only what the run registered as its own (`ActivitySignalGate.register`, a child's pid and
start read at spawn) and what runs under a `login` its own panes spawned.
`ProcessSignals` refuses anything else before a token is taken, and the
real kernel's sends refuse it again before their call, by the app's gate
(`ActivitySignalGate.shared`) and this process, whatever gate or app a
`ProcessSignals` was handed. A test that signals its own children
registers them in `.shared` for the test's length. A real process that
isn't the test's — the runner's parent — is only ever asked about through
`RecordingKernel`, whose signals reach nothing but the test's own
children, so not even a broken gate could signal it. The E2E scenario
quits only applets it made and launched itself (`createsNewApplicationInstance`),
registered with the gate, and takes each out of LaunchServices' database
(`lsregister -u`) before its scratch folder goes.

`ActivityProbeTests` is opt-in, run on each new macOS and on the oldest
supported one (the support matrix of docs/design/activity/analysis.md,
12): the structures' sizes, who answers each call and what it costs —
`csops` against Security.framework's fallback among them — and the
sampler's whole light and full ticks, cold and steady, and the light
tick's cost a member over 8, 100 and 300 of its own children holding
sockets; whether `proc_signal_with_audittoken` is there, and what a token
and a whole send cost, a CONT to its own running child
(`testTheSignalPath`, which answers the macOS 13 spike when run there);
`testTheSupportMatrix` — `rusage_info_v6` and its energy for the user's
processes, `csops`, the token call and the responsibility call (stage 1's
grouping, D-31) present or not, and netstat's rows run by the probe and
by an ad hoc-signed copy of `sh` against libproc's count of listeners,
blind when the second is 0 (3.5); `testTheTicksEnergyAtEachQoS` — this
process's `ri_energy_nj` a light and a full tick costs at `.userInitiated`
and at `.utility` (D-8); `testThePagesRowsAndTheMeters` — the Activity
page's rows made of a steady full tick, everyone's, and the meters' read.
It reads the whole table, read only, and prints
counts, errnos and timings, never a name or an argv:

```
OVERTERM_ACTIVITY_PROBES=1 swift test --filter ActivityProbeTests
```

Without `OVERTERM_ACTIVITY_PROBES=1` it is skipped, so `make test` and CI
print nothing of this Mac's. Its timings are a debug build's — masking
runs several times slower there — unless it runs in release, as the app
does:

```
swift build -c release --build-tests -Xswiftc -enable-testing
OVERTERM_ACTIVITY_PROBES=1 swift test -c release --skip-build --filter ActivityProbeTests
```

A tick's cost includes reading the processes that started since the last
one: a build running beside it shows in the numbers, and the sampler's
probe prints how many identities each tick read.

**A build signed as a release would be** (3.11, D-4): `make signed-spike`
signs a copy of `Overterm.app` in `dist/signed-spike` with hardened
runtime and `SIGN_IDENTITY` (environment or `local.mk`; it refuses
without one), the line a release would use — `make install`'s re-sign has
no hardened runtime and `make app` signs ad hoc, so neither tests it.
Then the copy's own scenarios check it, run as the harness runs them
(credential variables and `GIT_*` left out of the environment):
`OVERTERM_E2E=suspend dist/signed-spike/Overterm.app/Contents/MacOS/Overterm`
— Suspend Tab stops and resumes through `ProcessSignals`, so audit tokens
and `task_name_for_pid` answer under that signing — and `OVERTERM_E2E=
splits`, whose `E2E INFO` line counts netstat's rows in a pane, 0 under ad
hoc signing.

## End-to-end — `Sources/Overterm/E2E/E2ERunner.swift` + `Tests/OvertermE2ETests`

`OVERTERM_E2E=<scenario> ./Overterm.app/Contents/MacOS/Overterm` runs one
scenario inside the app and prints `E2E PASS|FAIL <check>` lines, then
`E2E DONE <failures>`, exiting with the failure count. The XCTest target
launches one process per scenario (skipped unless `OVERTERM_E2E_TESTS=1`,
which `make e2e` sets) and turns FAIL lines into test failures.

What makes it end-to-end without being dangerous:

- **Input goes only to its own window**: key events are built with
  `NSEvent.keyEvent` and delivered with `window.sendEvent` (→ `TerminalView.keyDown`
  → `interpretKeyEvents` → libghostty → pty); drags are posted to the app's
  own queue. Never CGEvent/osascript — those reach whatever has focus.
- **Isolated state** (`AppEnvironment`): its own defaults suite (wiped at
  launch), a temp support dir (or `OVERTERM_SUPPORT_DIR` for a prepared
  session), notifications counted not posted, no split autosave, no window
  frame autosave — its window opens at 1400×880 (or the screen's visible
  area) every time: macOS keeps the autosaved frame in the standard
  defaults, the user's, and a scenario that resized the window
  (`fullScreen`'s 1000×640) opened every scenario after it that small, until
  text read off the window no longer fit — never
  activated (it stays behind your windows), and Claude Code's transcripts an
  empty projects directory of its own until a scenario points
  `ClaudeUsageReader.projectsDirectory` at the ones it wrote — never the
  real `~/.claude`. The first tab starts in an empty folder of the run's
  (`start` in the support dir; `OVERTERM_E2E_CWD` names another), never
  your home folder: the window follows that tab, and its panels read what
  they find there — the API panel once found a real Bruno collection.
- **Scratch files** in a temp dir removed at the end; repos are created with
  a throwaway git identity.
- **Nothing of a run is left running** (docs/design/activity/analysis.md,
  10.5). Every scenario's app prints `E2E RUN <OVERTERM_RUN> <scratch>`
  first, and at its end — once what quitting ends was ended — looks for
  its own processes still there (`RunLeftovers`, `E2ERunner+Leftovers`):
  the run's `OVERTERM_RUN` in their environment, a stand-in's record of
  its own pid in the scratch folder's `spawned/` (written before it
  `exec`s; `RunLeftovers.recordLine`), or an argv sign naming the run's
  pid **and start** — the kubectl socket folder, Docker's ssh socket, the
  tunnel's `ControlPath` — or its scratch folder (`ArgvSign`; Apple's perl
  and ssh hide their environment), a helper registry's pid, or anything
  still under the app — and only when its parents, each started since the
  run, lead to the run or launchd (`RunLeftovers.lineage`): what the
  person runs meanwhile, a `grep` naming the scratch folder, is never
  found, said or signalled. Each is a failure (`at the end,
  nothing of the run's is left running`, by pid and name), then is
  stopped by its identity through `ProcessSignals`, the gate admitting it
  as the run's own. Once the app has quit the harness looks again from
  outside by the same rules, lineage too (`Tests/OvertermE2ETests/E2ELeftovers.swift`:
  its own `KERN_PROC_ALL` and `KERN_PROCARGS2`, the marker matched as
  bytes at an entry's start, the region cleared), against the start it
  read of the app it launched — never a pid alone: a relaunched Overterm
  can get the same pid — and ends what it finds, TERM then KILL, each
  read again just before. Only this user's processes started since the
  run are read, and nothing of one that isn't the run's is said. The
  harness also drops an inherited `OVERTERM_RUN`/`OVERTERM_HELPER` from
  the app's environment.
- **Left Behind's checks** (`E2ERunner+ActivityLeftBehind`, in the
  `activity` scenario) make every survivor a detached python of the run's
  own that writes its pid and ends itself at the part's stop file (written
  in a `defer`), so the leftover check finds none; a survivor ticked in a
  close sheet, and the stand-in stopped for D-29's Resume offer, are
  registered with the gate by pid and start before anything is sent. D-29
  is checked through Activity's own Suspend and the writer: the file's bytes
  (pid and start only, 0600), then the app forgetting while the file stays,
  for the next launch's Resume offer. The
  launch check (D-14) lists the Mac's processes and never runs in an
  isolated run: `LeftBehindTests` checks it over a fake Mac instead.

Scenarios: `terminal`, `tabs`, `rename`, `pin`, `close`, `editor`, `diff`,
`branchDiff`, `why`, `diffStyle`, `layout`, `session`, `task`, `snippets`, `attention`,
`marks`, `palette`, `reorder`, `info`, `activity`, `claude`, `disk`, `clipboard`,
`openWith`, `dropFiles`, `peek`, `groups`, `blocks`, `inbox`, `askAgent`,
`dropSplit`, `settings`, `themes`, `browser` (the browser column, its tabs, a page's console,
and the MCP server over real HTTP as an agent would use it), `fileActions` (the file tree's New File…, Rename…,
Move to Trash…, through their sheets), `editorZed` (the editor as Zed's: zoom, tabs,
tree-sitter, editing commands, pickers, vim, and a language server —
`Tests/OvertermTests/Fixtures/fake-lsp.py`, through `LanguageServers.discoveryOverride`).
`terminal` also checks the bundle: its version is the `VERSION` next to
`Overterm.app` (the run's app is the checkout's), the build a positive
integer, the commit named — and that About Overterm shows them, opened
through its menu item, without bringing the app forward.
`splits` also reads Tab Info's CPU in a split tab: a busy loop of its own in
each pane (stopped by a file it writes, 60 s at most), each above 0% — a
pane's read once forgot the other's baselines, and every pane read 0%.
`info` reads it in a tab that isn't selected: Tab Info on its second tab,
a busy loop of its own there, while the first is selected and the window's
agent poll reads that one with the same inspector — above 10% at every
refresh for 4.5 s, over two of the poll's ticks; the poll's reads once
dropped the other tab's baselines, and every reading after one was 0%.
`info` also runs a sleeping perl of its own (60 s at most) whose argv
carries a fake password, made at run time and never typed — a script it
writes execs it —, once after a token's flag with a `/` in front, once with
a space in it as one word, and reads its row's tooltip from the popover's
accessibility tree: masked, the password and every part of it nowhere.
`activity` opens the Activity page from View ▸ Activity: before its
first rows the list and the header say "Reading…" (read from the
accessibility tree); it lists the run's own sleep and python server in
their tab and nothing outside the run's tabs, the meters a core each, the
server's port in Listening with the note below the list, each row's
VoiceOver label; hidden, before and after, the census's full level
doesn't tick for 3 s while the light tick goes on, and its rows are gone;
⌃⌘A with no page showing holds the full level, offers the server's port
first, and its ↩ shows it on the page in Listening, the hold going with
the palette; ⇥ onto Activity's tab in ⌘K holds it too, and ⇥ off lets
go; with Activity off, ⌥⌘A opens Settings ▸ Activity and ⌘K has no
Activity tab. Stage 4's checks (`E2ERunner+ActivityListenerSources`)
type a stand-in `kubectl port-forward` and `ssh -L` (scripts named as the
tools, listening on their own ports — never the real ones) and check
each row's target; turn unix-socket listeners on and off over a socket
of the run's own; point the page's nettop at a stand-in whose answer the
scenario writes from the run's own listeners and launchd (pid 1) on a
port nobody holds, with a fixture plist naming it
(`LaunchdSockets.standIn`) — the row named, its Free refused, the note
"checked" —, then an answer without the run's own (blind: unknown, no
rows) and the setting off; and read the server's open files with `l`.
The real nettop and this Mac's launchd folders are never read in a run.
Its checks print counts, its own pids and port numbers only.
`marks` leaves one tab in each activity state; with `OVERTERM_DUMP_PNG=<png>`
it captures the window, for judging the look. Run one by hand while working
on it:

```sh
make app && OVERTERM_E2E=diff ./Overterm.app/Contents/MacOS/Overterm 2>/dev/null | grep ^E2E
```

### Typing into a shell

- **Wait for the shell.** `waitForPrompt()` waits for its first OSC 7 (shell
  integration, from the first prompt) — "no running command" is also true
  while it still reads its rc files. `settledPrompt()` adds 400 ms, and
  1.2 s after that first report: the first prompt keeps working (the theme's
  git status, deferred integration init) and keys typed then were lost.
- **Run commands with `run(_:until:)`** (or `runAndExpect`): it types, presses
  Return, and if the condition doesn't hold, sends Ctrl-C and types it once
  more. A prompt redraw can flush keys *mid-command* — once, 40 characters
  vanished from the middle and left zsh at `for>`; a plain retry then typed
  into the continuation prompt. Only for commands that are fine to run twice.
- **Keep typed lines short**: put code in a script and run the script.
- **`clipboard` is the scenario this hits most.** Ten runs at load 6 on
  2026-09-28: 7 clean; 2 lost the `python3 …` line entirely, retry
  included (the terminal showed only "Last login"), and every later check
  failed in a chain; 1 answered Deny in the sheet — the app completed the
  request — yet the reader had no reply after 35 s. With logging on
  (`confirmClipboard` → complete, each time) that one did not recur, so it
  is open: a lost reply, or the reader stuck restoring the tty. Rerun
  before suspecting the app; if it recurs, log what the reader receives.
- **Output on disk isn't output on screen.** A file the command wrote can
  exist before libghostty's IO thread has drawn the output; wait on
  `TerminalView.visibleText` before clicking at a screen position.
- Typing goes to the *selected* tab.

### GitHub without the network

The `pullRequest` scenario writes a stand-in `gh` (a Python script answering
`pr list`, `pr view` and the comments API from fixtures, logging what it is
asked to post) and points `GitHub.executableOverride` at it: the app's real
calls and parsing run, nothing reaches GitHub. New gh calls need a branch in
that script, or the scenario fails with "fake gh: unexpected".

### Other apps without launching them

Opening a file in another app goes through `ExternalOpener`, whose catalog in
an isolated run is `IsolatedApps`: the `openWith` scenario installs two
stand-in apps (bundle ids and names only) and checks what it *would* have
opened; `SystemApps.launched` stays 0. A new way of opening a file
elsewhere goes through the opener too, or a scenario driving it would launch
a real app.

### Drags without the system's drag

`dropFiles` calls a pane's own `NSDraggingDestination` methods (entered,
updated, exited; prepare, perform, conclude, ended) with `E2EDraggingInfo`,
whose pasteboard is a private, named one — never the drag pasteboard or the
clipboard. What runs in a pane is found by its processes, so Claude Code is a
stand-in: `exec -a claude cat > file`, argv[0] `claude` in the foreground,
which also records what the drop typed (Ctrl-D hands cat the line, no
newline). ⌥ comes from `TerminalView.dropModifierFlags`. A file promise is
kept only at the end of a real drag, which a run can't start:
`TerminalDrop.keepPromise` stands in for the source and writes the file
where asked. The sidebar's rows get in-process clicks at their position, and
their menu comes from `menu(for:)` without being shown.

### Clicks in the changes pane

In-process mouse events that land in the pane's SwiftUI `ScrollView` don't
reach its gestures (the run's window is never key): a card header's fold and
its why strip ignore them, and a mouseDown on a diff line (selectable text)
starts a tracking loop that waits for a real mouseUp — the run hangs. Its
accessibility tree is empty in-process too. Scenarios there call the model
action the gesture or button calls (`toggleWhy`, `toggleFold`, `expandAll`)
and check what a card is given (`DiffModel.why(for:)`, `isFolded`) and what a
line is given (`FileDiff.style(of:)`, in `diffStyle`), which the view renders
as it is.

### Adding a scenario

1. Add a method on `E2ERunner` and register it in `scenarios`.
2. Drive it through the same entry points the UI uses (menu `@objc`
   actions, `menu(for:)` items, `openInEditor`, `type`/`pressReturn`, sheet
   buttons via `clickSheetButton`) — not by setting model state directly,
   or the test skips the wiring it exists to cover.
3. Check outcomes a person would see: files written by the shell, tab
   order, first responder, sheet text, git log.
4. Add `func testX() throws { try run("x") }` to `E2ETests`.

Every user-visible feature gets a scenario; every bug found by hand gets a
check that would have caught it (the rename focus loss, the 0-wide editor,
closing without asking, the no-HEAD diff all have one).

## Looking at the UI

`OVERTERM_DUMP_LAYOUT` / `OVERTERM_DUMP_PNG` (docs/debugging.md) print the
view tree and capture the real window — use them when a check isn't enough
to see what's wrong.

README's pictures come from the `showcase` scenario (`E2ERunner.swift`,
`E2ERunner+Showcase.swift`) and a few others (api, review, notes,
drawing, database, overgit, docker), photographed in a fixed 1400×880
frame. The showcase's Kubernetes picture needs `OVERTERM_KUBECONFIG` —
`testShowcase` passes a temporary path; without one it is left out, and
a path to a file already there is refused (the run writes it and
removes it) —
and is taken against `FakeKubeAPI` and its Prometheus with no kubectl;
its Terraform picture is the panel over a checkout it writes and a plan
of `envs/prod` decoded from `show -json`'s shape, with no terraform, in
a tab running a plain `bash` whose prompt names nobody's user or host.
The captures are 2800 pixels wide; `docs/assets` keeps them at 1600
(`sips -Z 1600`).

### The title bar and full screen

A scenario must not depend on the window being key: a person using the
Mac during `make e2e` keeps another app there, and under macOS 14's
cooperative activation the run's window is then never key — a hover gated
on the key window showed nothing. Ask such a thing directly
(`showHover(…, inKeyWindowOnly: false)`). What is the window's own is
still checked in every run: its first responder (the editor's keyboard)
belongs to it whether or not the app is in front. A click goes through the
window (`window.sendEvent`), so its hit-testing is checked; only
`OVERTERM_E2E_BACKGROUND=1` — a scenario stepped back behind the
frontmost app, to try this — gives `link`'s ⌘-click to the terminal
itself, after checking the window would hand it there.

The display is kept awake while `E2ETests` runs (`beginActivity` with
`idleDisplaySleepDisabled`, released at the end): a full run takes about
14 minutes, and a display that slept at 10 would leave every later
scenario reading a black window.

Known to fail on a Mac whose idle app alone passes the 3% CPU budget (the
same machine-dependent cause as `performance`'s idle CPU): `kubernetesCharts`'
"steady, within the idle budget" — the Live tab's absolute budget, held
over 9 s; the same window with the page hidden is said beside it as a
guide, never in its place.

A scenario ends as quitting would (`E2ERunner.endRun`, the same
`AppDelegate.endRun` as `applicationWillTerminate`): every kubectl proxy,
port-forward and ssh forward it started is closed and checked gone by pid,
and its temporary support folder removed — it exits rather than quits, and
85 proxies of earlier runs were found alive, reparented to launchd. A
scenario that times out is terminated, and what it started is killed by
the pids found under it first, never by a pattern.

`OVERTERM_E2E_ACTIVATE=1` brings an isolated run to the front for the
`fullScreen` scenario — full screen's title bar window only shows for the
app in front — and takes the keyboard for a few seconds, so ask first.
`OVERTERM_E2E_FULLSCREEN=1` runs `reorder` with the window full screen.
What macOS does itself with a real pointer — moving a window by its title
bar, the title bar coming down in full screen — no in-process event
reaches; the scenarios check what a press would hit from the frame view
down, and the rest is tried by hand (an Overterm Dev build, with its own
bundle id and `OVERTERM_SUPPORT_DIR`).
