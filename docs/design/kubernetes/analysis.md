# Kubernetes — analysis

This is a plan for a Kubernetes interface in Overterm. It shows clusters first and manages them later:
- contexts and namespaces,
- workloads, pods, services, configuration, storage, nodes and events,
- logs, shells and port-forwards,
- custom resources and Helm releases.

The goal is k9s's speed and keyboard with Lens's overview. On top of that comes what neither can do: the terminal, the editor, the checkouts and the agents, all joined to the cluster.

This document covers:
- what this Mac has (from the first analysis, 2026-10-28),
- the Lens and Freelens features, and what we do for each,
- what Overterm adds beyond them,
- how we talk to clusters, with the API facts checked against the sources,
- the security model for production clusters,
- the interface, the shortcuts and the integration points,
- the stages, performance, tests and risks,
- the decisions to take.

The implementation plan comes after the decisions.

**Status: built.** Every stage below is built and ships as Overterm 1.6.0. Section 15 says where the build departs from this design; `docs/architecture.md`, Kubernetes, describes what exists.

It replaces `docs/design/kubernetes/analysis.md`. That version is in Turkish, dated 2026-10-28, and was written against the `docker` branch at `910919b`. Code paths here are against `main` at `d62c5c4`, where Docker is merged.

The versions compared are Lens K8S IDE 2026.10.261408 and Freelens v2.0.0, both from 2026-10-28. Sources are in Section 14.

## In short

- **This Mac's clusters are real, and the default context is production.** kubectl's current context is `acme-prod` (EKS). So security is part of the design from day one:
  - Remote and production contexts are read-only by default. Read-only means Overterm changes no object there. Two mechanisms enforce it, and each covers different things (Section 5):
    - **The socket.** Everything Overterm sends to the API goes through the context's `kubectl proxy`, the agents' MCP tools included. On a read-only context that proxy refuses every write method. Every proxy, read-only or not, refuses the subresources that reach inside the cluster. This holds whoever uses the socket.
    - **The processes.** Shells, attach, debug, port-forwards, `logs -f`, drain, rollback, Helm and node shells are kubectl or helm processes. They run with the user's own credentials and never touch the socket. On a read-only context Overterm refuses to start the ones that change objects. That is a check in Overterm's code, locked by tests. It is not a limit on the credentials.
    - Neither covers what a person or an agent types in a terminal tab. That is the user's own kubectl.
  - Production is visible everywhere: on the page, in the pane header and in every confirmation.
  - Every write asks first and names the context and namespace. A destructive write on production also asks you to type the object's name.
  - Writes on a production context last for one session only. Apply from the editor stays off there by default.
- **We can offer nearly all of Lens's and Freelens's free features, and the useful part of Lens's paid ones.** Almost every view is one read of the Kubernetes API, and the server already formats it (`as=Table`). We leave these out on purpose:
  - cloud sign-in, because kubectl's exec plugins already do it;
  - the extensions API (CLAUDE.md: no plugin slots);
  - the built-in AI chat and "see and drive", because the user's own agents do that work;
  - Teamwork and cost;
  - installing anything into a cluster.
- **We talk to clusters through `kubectl proxy`.** Each context in use gets one long-lived `kubectl proxy --context C --unix-socket S`.
  - All authentication stays in kubectl: `aws eks get-token`, `kubectl oidc-login`, client certificates and token refresh.
  - Overterm speaks plain HTTP on the socket, using Docker's transport made generic. It must send `Host: localhost`, or the proxy answers 403.
  - **Correction to the first analysis:** by default the proxy refuses only exec, attach and `nodes/*/proxy/run`. Port-forward, the pod, service and node proxies and every write pass through. So every proxy Overterm starts gets a wider `--reject-paths`, and a read-only context's proxy adds `--reject-methods`.
  - Shells (`kubectl exec -it`) and log follows open in terminal tabs. Port-forwards are `kubectl port-forward` processes that Overterm manages.
- **Lists come as Tables.** The API server sends `kubectl get`'s own columns, CRDs' `additionalPrinterColumns` included. One generic table shows every kind, as k9s does.
- **We only watch what is on screen.** Watches open for the visible section and namespaces and close when hidden. That keeps a cluster with thousands of pods cheap. One stated exception has a fixed budget: the pod and Deployment watches behind attention marks (3.13).
- **The interface has two layers, as Docker's does.**
  - The Kubernetes page opens with ⌥⌘J (⌥⌘K is Notes' Graph View). It has sections, a list and a detail pane.
  - The rail panel shows the selected tab's checkout's namespace or Helm release. It reads only while it is the panel on screen.
  - Both offer k9s's `:` command mode, the `/` filter and single-letter verbs.
- **Beyond Lens and Freelens (Section 3):**
  - a checkout tied to its namespace or Helm release,
  - what is deployed, compared with the checkout's commit,
  - Ask Why: a failing pod's brief handed to the agent working in that checkout,
  - typed MCP tools that are read-only on production,
  - port-forwards in the pane header, the browser column, the API client and the Database client,
  - YAML edited in Overterm's editor and applied after a server-side diff,
  - a "Terminal in this context" tab (stage 1d), and a production warning in the pane header when `kubectl` runs there (stage 3b).
- **The first release is small.** Stage 1 is cut into five pieces (1a–1e), each shippable on its own. The first is contexts and the Pods list, with the proxy flags already in place (Section 9).
- **No new package is needed.** NIO, NIOHTTP1 and NIOSSL are already dependencies, and WebSocket support is in swift-nio if we ever need it.

## 1. What this Mac has (2026-10-28)

These findings come from the first analysis. No cluster was contacted: only local files and the tools' help texts were read, and no secrets or server addresses were printed. Nothing was run again for this document.

**Tools**

| Tool | Where | Note |
|---|---|---|
| `kubectl` v1.36.1 | `/usr/local/bin` | Docker Desktop has its own copy at `/Applications/Docker.app/Contents/Resources/bin/kubectl` |
| `helm` v4.2.3 | installed | Helm 4 writes the same release format as Helm 3 (Section 4) |
| `k9s`, `kubectx` | installed | The user knows k9s's keys |
| `kind`, `k3d`, `minikube`, `stern` | not installed | No local cluster: Docker Desktop's Kubernetes is off |
| `aws` | `/opt/homebrew/bin` | Not on the PATH of an app launched from the Dock |
| `kubectl oidc-login` (kubelogin) | installed | Opens a browser and listens on 127.0.0.1:8000 |

**`~/.kube/config` has five contexts**

| Context | Cluster | Authentication | Namespace |
|---|---|---|---|
| `…:cluster/acme-dev` | EKS | exec: `aws eks get-token` | — |
| `…:cluster/acme-prod` (current) | EKS | exec: `aws eks get-token` | — |
| `globex-eu-west-1-dev` | EKS | exec: `kubectl oidc-login get-token` | `globex` |
| `globex-eu-west-1-prod` | EKS | exec: `kubectl oidc-login get-token` | `globex` |
| `kubernetes-admin@k8s-cluster` | self-hosted (an IP) | client certificate | — |

What follows from this:
- **The default context is production.** A `kubectl` typed in any terminal today goes to `acme-prod`. A test that read `~/.kube/config` would go there too.
- **One kubeconfig file is not read.** `~/.kube/acme-extra.kubeconfig` is a separate file, and `KUBECONFIG` is empty, so kubectl ignores it. (A context with that name also exists in the main file.) Overterm must be able to read extra kubeconfig files from a setting.
- **Exec plugins need the shell's environment.** `aws` lives in `/opt/homebrew/bin`, which is not on a Dock-launched app's PATH.
- **The `globex-*` contexts carry a namespace.** That suggests RBAC limited to that namespace. Listing namespaces may be refused, so the namespace picker must accept a typed name.
- **The self-hosted cluster uses a client certificate**, and its key is in the kubeconfig. Overterm never reads it; kubectl does.
- **Context names are long.** The EKS ones are ARNs. A socket path must stay under 104 bytes, so sockets are named by a short hash of the context, not by its name.
- **`kubectl proxy`** supports `--unix-socket`, refuses `exec` and `attach` by default (`--reject-paths`), and accepts only localhost Host headers (`--accept-hosts`). Section 4 corrects what this means in practice.

### The spike (2026-11-03), read-only, on the two dev clusters

The proxy ran with the read-only flags of decision 12. Production was never contacted, and no Secret was read.

| | `acme-dev` (aws) | `globex-eu-west-1-dev` (oidc) |
|---|---|---|
| Proxy socket ready | 0.13 s; credentials come on the first request | 0.13 s |
| First request (token) | 1.9 s | 3.9 s |
| Later requests | 75–200 ms | ~100 ms |
| API groups | 36 | 78 |
| Pods | 56 in all | 260 in `globex`, 2886 in all |
| metrics.k8s.io | 404, no metrics-server | present |
| POST, exec, a wrong Host | 403 | 403 |

A cluster-wide pod list on `globex-eu-west-1-dev`, 2886 pods:

| Form | Size | Time |
|---|---|---|
| Table, `includeObject=Metadata` (the default) | 35 MB | 1.9 s |
| **Table, `includeObject=None`** | **885 KB** | **0.15 s** |
| Plain JSON, the full objects | 81 MB | 4.0 s |
| `PartialObjectMetadataList` | 33 MB | 0.9 s |
| Protobuf | 28 MB | 1.1 s |

What it decided:
- **Lists and watches ask for rows only** (`includeObject=None`). A row is known by its namespace and name. The full object is one GET when its detail opens.
  - Across all namespaces a namespaced kind asks for `includeObject=Metadata`: no core kind's Table has a Namespace column (`kubectl get -A` adds it from the metadata), so with rows only a row's namespace is unknown and same-named pods in two namespaces are one row. In one namespace the request's namespace is the row's.
  - Ages: the metadata's `creationTimestamp` where a row has it; a namespace's rows-only list has only the Age cell as the server rendered it. Which the page recomputes from is the page step's to decide. `managedFields` alone averaged 4.4–5.4 KB a pod.
- **A watch answers as a Table too**, and the streaming list (`sendInitialEvents`) works and ends with a bookmark.
- **The socket folder must be short.** In the support folder the path was 132 bytes and the bind failed; the limit is 104. Sockets go in a private folder under `/tmp` (mode 0700), named by a short hash.
- **A credential failure is not retried.** With an expired AWS SSO token every request was an HTTP 500 with a short text body ("getting credentials: exec: executable aws failed with exit code 255"), and the proxy ran `aws` again for each one, 1.3–4.6 s apiece. The first such answer stops the context's requests and says what to run (`aws sso login`).
- **An oidc sign-in waits in the browser.** With nobody signing in, the first request waited 181 s and then failed. The page says a sign-in is waiting rather than looking stuck.

## 2. Feature inventory

The tables go through Lens and Freelens area by area. Columns:
- **Lens**:
  - Yes;
  - **Plus**, which needs a paid plan (Plus at $25–30 a month, Pro or Enterprise);
  - —.
- **Freelens**:
  - Yes;
  - **ext**, an extension rather than part of the app;
  - —.
- **How**:
  - **API**: a read or write through the context's proxy.
  - **Watch**: a list plus a watch, open only while shown.
  - **Tab**: a command typed into a terminal tab, always with explicit `--context` and `-n` (`KubeCommands`).
  - **Proc**: a process Overterm manages, such as `kubectl port-forward`.
  - **Local**: pure code over data already read.
  - **Editor**: Overterm's editor or the changes pane.
- **Stage**: see Section 9 (0, 1a–1e, 2a–2f, 3a–3b, 4). "Out" means left out, with the reason given.

Tab and Proc rows run with the user's own credentials, not through the socket. Section 5 says which of them start on a read-only context.

Every kind gets the generic view: the server's Table, and a detail with metadata, conditions, owner, events and YAML. These get a tailored Overview on top: Pods, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, HPAs, Services, Ingresses, Nodes, Namespaces, PVCs, ConfigMaps, Secrets and Helm releases. Everything else stays generic.

### 2.1 Clusters and contexts

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Read `~/.kube/config` and `KUBECONFIG` | Yes | Yes | The same, merged in kubectl's order (first file wins per key); never written | Local (pure parser) | 1a |
| Extra kubeconfig files and folders | Yes | Yes (applied at once) | `kubernetes.kubeconfigs`: files and folders watched with `DirectoryWatcher`, passed to kubectl as a `KUBECONFIG` list | Local | 1a |
| Add a cluster by pasting a kubeconfig | — | Yes | **Out**: Overterm writes no kubeconfig. The empty state says where to put the file and offers to add its path to the setting | — | Out |
| Navigator or catalog tree | Yes | Yes (catalog) | The page's left column: context card, namespace picker and sections. Jumps go through the switcher and the palette | Local | 1a |
| Preview and fixed tabs, history per tab | Yes | — | One detail pane with back and forward (`[` and `]`, as in k9s; ⌘[ and ⌘] are the panes'). Logs, YAML and shells open as Overterm tabs when asked | Local | 1b |
| Several clusters connected at once | Yes | Yes | One proxy per context in use, at most `kubernetes.maxProxies` alive, one always kept for the page's context. The page shows one context at a time; a health view across contexts comes later | Proc | 1a / 3b |
| Hotbar: icons, F1–F12, banks | **Plus** (free in OpenLens) | Yes | Pinned contexts (`kubernetes.pinnedContexts`, a list setting) at the top of the context picker (`c`) and in the palette. No F-keys: they belong to the terminal | Local | 1a |
| Cluster settings: name, icon, proxy, terminal folder, default and accessible namespaces, metrics source, node-shell image | Yes | Yes (plus skipping the namespace and metrics checks, and an OpenShift Prometheus token) | One entry per context in `kubernetes.contexts` (Section 8): display name, colour, class, writable, default, accessible and favourite namespaces, which kubectl, terminal folder, metrics source, debug and node-shell images. When accessible namespaces are set, the namespace list is never asked for (Freelens's skip). Metrics `none` skips the metrics check. The proxy is the kubeconfig's `proxy-url`. **Out:** an icon (the class colour and display name stand in), and the OpenShift Prometheus token (a secret Overterm would have to keep; Prometheus is reached through the apiserver with kubectl's credentials). No secrets | Local | 1a (metrics source 2d / 4) |
| Highlight production clusters | **Plus** (an extension how-to) | — | Built in: a class from the name or the setting, a red band, the pane-header warning | Local | 1a |
| EKS, AKS and GKE sign-in and discovery | **Plus** | — | **Out**: kubectl's exec plugins (`aws`, kubelogin, `gke-gcloud-auth-plugin`) already sign in. When a session expires, "aws sso login" runs in a tab | Tab | Out (help in 1a) |
| OpenShift and local clusters | Yes (docs) | Yes (plus an OpenShift Prometheus token) | Through the kubeconfig; local contexts recognised by name (Section 5). The OpenShift token is out (row above) | Local | 1a |
| Bastions, SOCKS5, custom User-Agent | proxy setting | Yes | kubectl itself honours the kubeconfig's `proxy-url`; we add no setting | Proc | 1a |
| Cluster overview: CPU and memory charts, requests, limits, capacity, issues | Yes | Yes | Version, nodes, live usage against allocatable (metrics.k8s.io) with a sparkline of the samples taken while shown, warnings first. Requests and limits against allocatable in stage 4: summing them needs every pod's spec, a whole-object list the Overview's rows avoid (5,000 pods are tens of MB a read), and Prometheus has them as series (`kube_pod_container_resource_requests`), counted only for Pending and Running pods (joined on `kube_pod_status_phase`; kube-state-metrics keeps finished pods, metrics.md M0). Longer history only with Prometheus: the cluster's CPU and memory lines up to 6 h — at 24 h and 7 d the chart says why and offers 6 h, its requests and limits still read | API | 2d (requests and limits 4) |
| Welcome page | — | Yes | The page's empty state: the contexts with their class | Local | 1a |
| Lens ID sign-in and activation | required | none | None | — | — |

### 2.2 Namespaces

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Namespace multi-select filter | Yes | Yes (shared across lists) | Picker (`n`): several at once, favourites (per context, in `kubernetes.contexts`), "all". Defaults to the context's namespace; a typed name works when listing is refused | Watch | 1a |
| Namespace list, labels, status | Yes | Yes | Generic table | Watch | 1b |
| Create and delete | Yes | Yes | Create on writable contexts. Delete always asks for the typed name | API | 2a |
| Quotas and limit ranges in the detail | Yes | Yes | The namespace's detail lists them | API | 1b |
| Hierarchical namespaces (HNC) tree | — | removed in v2 | **Out** | — | Out |
| Namespaces grouped as a project (Headlamp's idea) | — | — | A checkout's binding plays this part (3.1) | Local | 3a |

### 2.3 Workloads

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Workloads overview: rings and counts per kind | Yes | Yes | Counts per kind, with failing objects listed first | Watch | 2d |
| Table basics: sort, resize, reorder and hide columns; keyboard rows; scroll kept; resume after sleep | Yes | Yes (plus a right-click menu and search kept per namespace) | `ResourceTable` (NSTableView): the server's columns, with `priority > 0` columns behind `w` (wide). Sort, resize, reorder and hide; right-click opens the verb menu; watches resume after wake | Watch | 1a |
| CSV export | Yes | — | Copy the visible rows as TSV or CSV; Save As | Local | 1b |
| Deployments: pods, replicas, conditions, owned ReplicaSets | Yes | Yes (N/N column) | The same, plus each ReplicaSet revision with its images | Watch | 1b |
| DaemonSets, StatefulSets, ReplicaSets, ReplicationControllers | Yes | Yes | The same, with owned pods | Watch | 1b |
| Jobs and CronJobs | Yes | Yes (plus Job suspend and the schedule in words) | Lists with the schedule in words and the next run. Trigger, suspend and resume come with the writes | Watch / API | 1b / 2a |
| Applications, grouped by `app.kubernetes.io/instance` | Yes | — | Group the pod and workload lists by instance label or Helm release | Local | 2d |
| Flux reconciliation column | **Plus** | ext | A custom resource's `Ready` condition, read generically | Local | 3b |
| HPAs, VPAs, PDBs | Yes | Yes | Generic tables. An HPA shows current against target; a PDB shows allowed disruptions | Watch | 1b |

### 2.4 Pods

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Pods list: containers, CPU and memory, restarts, owner, node, QoS, age, status | Yes | Yes (plus warnings, IP and a logs link) | The server's columns plus ours: the last exit reason (`OOMKilled`, exit 137…), a warning mark, how recent the last restart was. CPU and memory columns come with metrics | Watch | 1a / 2d |
| Pod detail: status, node, IPs, service account, priority, QoS, conditions, tolerations, affinity, labels, owner, volumes; for each container its image, state, ports, env, mounts, probes, command | Yes | Yes (plus ephemeral containers, pod-level resources, scheduler, image volumes) | An Overview tab, ephemeral containers listed. Env from a ConfigMap is resolved and shown. Env from a Secret is named only: the pod spec holds the key's name, and no value is fetched. A "why it isn't running" block sits at the top (3.4). A container port is a button that starts a forward | API | 1b |
| Attach | Yes | Yes | `kubectl attach -it` in a tab, after `kubectl auth can-i`. On production it is confirmed (rule 5) | Tab | 1d |
| Shell, with container choice | Yes | Yes | `kubectl exec -it … -- sh -c 'command -v bash >/dev/null && exec bash \|\| exec sh'` in a tab, after `kubectl auth can-i`. On production it is confirmed (rule 5) | Tab | 1d |
| Default-container annotation | Yes | Yes | Yes: `kubectl.kubernetes.io/default-container`, else the first container. Logs, shells and attach all use it | Local | 1c |
| Delete | Yes | Yes | Writable contexts only; on production the name is typed | API | 2a |
| Force delete, remove finalizers | — | Yes | Writable contexts only, always with the name typed | API | 2a |
| Evict | Yes | — | The `eviction` subresource, which respects PDBs | API | 2a |
| In-place resize | — | Yes | The `resize` subresource, where discovery lists it | API | 3b |
| Ephemeral debug container | — (shows existing ones only) | — (#962) | `kubectl debug -it --image=<debugImage> --target=<c>` in a tab, the image per context, else `kubernetes.debugImage`. It adds an ephemeral container, which is a write, so it is refused on read-only contexts | Tab | 2a |
| Share a deep link | Yes | — | "Copy as kubectl" (`kubectl --context … -n … get pod/x`) | Local | 1b |
| Metric charts | Yes (Prometheus) | Yes (Prometheus) | Live from metrics.k8s.io, with a sparkline of samples taken while shown. Prometheus later | API | 2d / 4 |
| DRA resource claims, claim templates, slices, device classes | Yes (2026.9) | — | Generic tables of `resource.k8s.io`, no special view | Watch | 1b |

### 2.5 Logs

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Pod log viewer with pod and container pickers, follow | Yes | Yes | `DockerLogView` made generic: levels coloured, JSON lines unfolded, follow, 5000 lines kept | API (`pods/{p}/log`) | 1c |
| Older lines on scroll-up | Yes | — | The API has no offset, so we ask again with a larger `tailLines`, up to a cap | API | 1c |
| Search that highlights or filters | Yes | Yes (⌘F takes the selection) | The same, regex included | Local | 1c |
| Timestamps, previous container, wrap, since | Yes | Yes (options kept) | Yes; options kept per window | API | 1c |
| Newest first | Yes | — | Yes | Local | 1c |
| Download | Yes | Yes (timestamped name) | Save As, with a timestamped name | Local | 1c |
| Merged logs of a workload's pods (Deployment Logs) | Yes | — (#687, ext) | stern's way: one stream per pod, merged on timestamps, a colour per pod, new pods joined from the pod watch. Capped at `kubernetes.logStreams` (default 10) | API, one stream per pod | 2e |
| Follow in a terminal | — | — | `t`: `kubectl logs -f` in a tab, with ⌘F and command blocks for free | Tab | 1d |
| Selected lines to an agent | **Plus** (AI) | — | ⌘L (Ask Agent), secrets scrubbed | Local | 1c |

### 2.6 Shell, attach and terminal

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| A terminal set to the cluster's context | Yes | Yes | **Terminal in this context**: an Overterm tab whose `KUBECONFIG` starts with a small file naming the context and the tab's namespace (3.11), so a plain `kubectl` there goes to it. It opens in the context's `terminalDirectory`, else the bound checkout. The user's current context is never changed, and Overterm's own commands still carry `--context` and `-n`. It is the user's own kubectl, so read-only does not reach into it (Section 5) | Tab | 1d |
| Standalone terminal | — | Yes (v2) | Overterm is a terminal | — | — |
| A kubectl matching the server version, downloaded | Yes | Yes (signed checksums, mirror) | The installed kubectl closest to the server's minor version (two copies on this Mac), or the context's `kubectl`. Never downloaded; if no copy is within the ±1 version skew, the page says so | Local | 1a |
| Helm bundled | Yes (3.x) | Yes (4.3.1) | The installed `helm` | Local | 2c |
| Node shell (a privileged nsenter pod) | Yes | Yes (fails on nodes without bash) | `kubectl debug node/<n> -it --image=<nodeShellImage>` in a tab, the image per context, else `debugImage`. Writable contexts only, off until the context's `nodeShell` is on, name typed | Tab | 3b |
| Shell environment synced | Yes | Yes (pollutes shell history, #1696) | `$SHELL -lic 'env -0'` once, with `HISTFILE=/dev/null` so nothing goes into history | Local | 1a |
| Splits, dragging into splits | **Plus** (Studio) | — | Overterm's splits | — | — |

### 2.7 Port-forward

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| From a container port or a service port | Yes | Yes | Yes, and from a Deployment. Allowed on read-only contexts after `kubectl auth can-i create pods/portforward`: it changes no object | Proc | 1d |
| Quick forward to a random port, opened in the browser | Yes | Yes | A free port checked with `ListeningPorts.isBound`, opened in the tab's browser column | Proc | 1d |
| Choose the local port, https, the listen address | Yes | Yes (plus the address) | The same; `127.0.0.1` unless changed | Proc | 1d |
| A page of forwards: open, edit, stop | Yes | Yes | A Forwards section, pills in the pane header, and Tab Info | Local | 1d |
| Forwards in the palette | — | Yes | Yes | Local | 1d |
| Reopened when the pod dies, following a service's new pod | — | — | Yes. Overterm resolves the target itself (a Service or Deployment → a ready endpoint's pod) and runs `kubectl port-forward pod/<name>`. When kubectl exits, it resolves again and starts a new one. The pill names the pod it is pinned to | Proc | 1d |
| Open in the Database client or the API client | — | — | `d` for a database pod; an HTTP forward is probed for an OpenAPI document (3.8) | Local | 1d |
| HTTP benchmark over a forward (k9s) | — | — | **Out** for now: `hey` or `oha` in a tab does it | — | Out |

### 2.8 Editing and apply

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| YAML editor; saving applies | Yes (Monaco) | Yes | The detail's YAML tab *is* Overterm's editor (tree-sitter YAML, the cluster's API docs on hover and completion), and `y` opens the same buffer in the window's editor — one buffer per resource, so both show the same edits. It lives in memory only: no file, no autosave, nothing restored; ⌘S is refused and closing with edits asks — the tab, the window, the quit, wherever the edits were typed (the detail leaving them says they are kept). Over it a bar: Diff with Cluster (a server-side dry run, client-side where refused), then Apply with `resourceVersion` — the access review, the confirmation naming context and namespace, the name typed on production. Writable contexts only: on a read-only one the buffer is edited and diffed, Apply greyed with why (and the socket refuses anyway). Not offered on production, even with writes on, unless the context sets `applyOnProduction` (decision 30). Secrets stay masked in it (values only on Show; values typed in clear masked again once applied); a masked value is never sent | API (server-side apply) and Editor | 2b |
| Show or hide managedFields, sort keys | — | Yes | managedFields and status stripped by default, with a toggle ("neat" copy, as kubectl-neat does) | Local | 1b |
| Diff against the original, revert | **Plus** | — | Diff with Cluster: on the page the diff shows in the YAML tab, in place of the text (the right-hand pane is under the page); from `y`'s tab in the changes pane. The bar's Revert puts the text back to what the cluster has (its newer object, when one came) | Editor | 2b |
| Editing an object that was deleted or changed | a notice | — | While the YAML shows, the object is watched by name. Without edits the buffer follows the cluster quietly (managedFields and status trimmed); with edits a banner says "changed on the cluster" — Reload, or Diff against it — and never overwrites them; deleted, it says so. A 409 at Apply brings up the "changed since you opened it — Replace?" prompt | API | 2b |
| Create from a template | Yes | Yes (plus user templates) | Templates are files in `Resources/kubernetes/templates`, as themes are, opened as a new buffer and applied as above | Editor | 3b |
| Dialogs for Secret, quota, namespace, service account, roles, bindings | Yes | Yes (bulk) | **Out**, except for a namespace; templates cover the rest | — | Out |
| Manual-edit annotation | — | Yes | The `overterm` field manager in managedFields records it | API | 2b |

### 2.9 Scaling and rollouts

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Scale Deployments, StatefulSets, ReplicaSets | Yes | Yes | `+` / `-` and a number, as a PATCH on `/scale`. Scaling to 0 on production asks for the typed name | API | 2a |
| Rolling restart (Deployments, StatefulSets, DaemonSets) | Yes | Yes | `r`: sets the `restartedAt` annotation | API | 2a |
| Rollout status | — | — | Updated, ready and available counts, plus the condition's reason. A stuck rollout is marked | Local | 1b |
| Pause and resume a rollout | — | — | Sets `spec.paused` | API | 2a |
| Rollback | — | — | `kubectl rollout undo --to-revision=N` in a tab. The logic is client-side in kubectl, so we don't copy it. Refused on read-only contexts; typed name on production | Tab | 2a |
| Revision history with what changed | — | — | Each ReplicaSet's pod template against the previous one, in the changes pane (3.6) | Local | 3b |

### 2.10 Events

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Events list: type, message, object link, source, count, last seen | Yes | Yes (sorted; source and count from events.k8s.io) | `events.k8s.io/v1`, warnings first, the object as a link | Watch | 1b |
| Search, CSV | Yes | Yes | `/` and copy | Local | 1b |
| Edit and delete events | Yes | — | **Out**: events expire on their own | — | Out |
| A resource's warnings in its detail | Yes | Yes | Yes, with a `fieldSelector` on the object | API | 1b |
| Cluster-wide warnings | Yes | Yes | In the Overview | Watch | 2d |

### 2.11 Metrics

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Usage columns from metrics-server | Yes | Nodes only | Pods and nodes: the list shows raw usage (a node's with its share of allocatable), since Table rows carry no spec; a pod's detail shows each container against its requests and limits, from its one GET. Polled every 15–30 s, only while the column shows. A dash when a read fails or metrics-server is absent (EKS has none by default); the sample's age when it is old. Never a stale number shown as current | API | 2d |
| Charts with history | Yes (Prometheus) | Yes (Prometheus) | Without Prometheus: samples taken while shown, kept in memory (metrics.md 4.1): a list's rows while they are sampled; what a detail polls in two tiers (15 minutes raw, 6 hours of minutes) for an hour after it hides, at most 3 detail targets a context; under 6 MB, dropped on a context switch and a credential failure. A 403 on metrics.k8s.io is said once and not asked again until the credentials change. With Prometheus: see Section 4 | API | 2d / 4 |
| Chart time range | — | Yes | With Prometheus only: a range picker (1 h, 6 h, 24 h, 7 d), sent as `query_range`'s start, end and step — except the Overview's cluster-wide CPU and memory, asked up to 6 h only (raw cAdvisor across a cluster at 24 h or 7 d is tens of millions of samples): past it the chart says so with a Show 6 h button, its totals still instant queries (metrics.md M0). Without it there is no range to pick: the chart covers the time it has been shown, and says so | API | 4 |
| Volume usage (PVC metrics) | — | Yes | With Prometheus only: `kubelet_volume_stats_used_bytes` against `_capacity_bytes`, as a column on PVCs and in the detail. metrics.k8s.io has no volume data, and kubelet's `/stats/summary` needs `nodes/proxy`, which every proxy refuses (Section 4) | API | 4 |
| Prometheus, with providers detected automatically | Yes | Yes (more providers) | Opt-in per context (`metrics` in `kubernetes.contexts`), with Freelens's selectors and queries. Only the detected or configured Prometheus service's query paths are reachable, through a second proxy that accepts nothing else (Section 4) | API | 4 |
| Install a metrics stack into the cluster | Yes | — | **Out**: Overterm installs nothing into a cluster | — | Out |

### 2.12 Helm

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Releases: chart, revision, versions, status, updated | Yes | Yes | Name, revision, status and updated read from the labels on Helm's storage Secrets, metadata only. ConfigMap storage too; Helm 2's (Tiller's) across all namespaces only, in Tiller's namespace. Helm's labels carry no chart or app version: those show once a release is opened (rule 9 forbids reading every record for the list) | API | 2c |
| Release detail: values, resources, notes, history | Yes | Yes | One Secret decoded on demand. The user's `config` values and any Secrets in the manifest are masked | API | 2c |
| Rollback to a chosen revision, uninstall | Yes | Yes | `helm rollback <r> <rev>` / `helm uninstall`, with `--kube-context X -n Y`, in a tab. The revision is picked from the history. Refused on read-only contexts. Rollback on production asks for the release's name; uninstall asks for it on every class | Tab | 2f |
| Upgrade with values and a version pick | Yes | Yes | `helm upgrade --version V` in a tab, with the values file in the editor. Refused on read-only contexts | Tab | 3a |
| Diff between two revisions (values, manifest) | — | — | In the changes pane, masked | Local | 3b |
| Upgrade from a local chart folder or `.tgz` | Yes (2026.10) | — | From the checkout's chart (3.1) | Tab | 3a |
| Chart browser, repositories (OCI, CA, basic auth), install | Yes | Yes | **Out** of the page: `helm repo` and `helm install` run in a tab, and repos stay in the user's `helm` config | — | Out |
| `HELM_DRIVER`: secret, configmap or sql | Yes | — | Secret and ConfigMap storage read; SQL **out** | API | 2c |

### 2.13 Custom resources

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| CRDs grouped by API group | Yes | Yes (plus short names) | From discovery, grouped by group | API | 1b |
| Custom resources with printer columns | Yes | Yes | The server's Table | Watch | 1b |
| Works without permission to list CRDs | — | Yes (v2) | Yes, through discovery rather than the CRD list | API | 1b |
| New CRDs appear without reconnecting | — (needs a reconnect) | — | A watch on CRDs while the page shows, where listing them is allowed; otherwise discovery is read again on a 404 and every 5 minutes while the page shows (decision 28) | Watch / API | 1b |
| Argo CD, Flux, cert-manager, Karpenter | **Plus** (Argo, Flux) | ext | Generic tables from printer columns. Argo's sync and health and Flux's Ready condition are read generically (3.9) | Watch | 1b / 3b |

### 2.14 Access control

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| ServiceAccounts, Roles, ClusterRoles, bindings, PodSecurityPolicies | Yes | Yes (plus links) | Generic tables; a binding's subjects and role are linked | Watch | 1b |
| Create dialogs | Yes | Yes (bulk) | **Out** (templates instead) | — | Out |
| Who am I | — | — | The context card shows the user and groups from `SelfSubjectReview` (the IAM role ARN on EKS) | Proc (`kubectl auth whoami`) | 1a |
| Shells and forwards enabled by permission | — | — | `kubectl auth can-i create pods/exec` (and `pods/attach`, `pods/portforward`) as a short-lived process, cached for a minute. A refused verb is greyed with the reason | Proc | 1d |
| Writes enabled by permission | — | — | A `SelfSubjectAccessReview` per verb through the writable proxy, cached. Each write ships with its check | API | 2a |
| "What can I do here" | — | — | `SelfSubjectRulesReview` as a hint to pre-grey verbs, marked incomplete when the server says so. Never the last word | API | 2a |

### 2.15 Nodes

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Nodes list: CPU, memory, disk, taints, roles, version, conditions | Yes | Yes (plus pods, instance type, node group, capacity) | The server's columns, plus instance type and node group from well-known labels (EKS node group, Karpenter NodePool) | Watch | 1b |
| Detail: addresses, OS, runtime, capacity against allocatable, taints, conditions, pods, DRA devices | Yes | Yes (plus provider ID) | Yes, with each pod's requests and the node's ResourceSlices | API | 1b |
| Cordon, uncordon | Yes | Yes | Sets `spec.unschedulable`; writable contexts only | API | 2a |
| Drain | Yes | Yes | `kubectl drain` in a tab, where evictions and PDB blocks are visible. Refused on read-only contexts; typed name on production | Tab | 2a |
| Node shell | Yes | Yes | See 2.6 | Tab | 3b |

### 2.16 Network

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Services with endpoints; forward from a port | Yes | Yes | Yes; a selector that matches no pod is marked | Watch | 1b |
| Endpoints, EndpointSlices | Yes | Yes | Generic | Watch | 1b |
| Ingresses, with rules as links | Yes | Yes (first rule only) | Every rule, opened in the default browser (a remote host, so not the browser column) | Watch | 1b |
| IngressClasses, NetworkPolicies | Yes | Yes | Generic; a policy's selected pods shown later | Watch | 1b / 3b |
| Gateway API: Gateways, HTTPRoutes | Yes (native) | ext | Generic custom resources with their printer columns; a route's parent Gateway and backends linked in the tree (3.7) | Watch | 1b / 3b |

### 2.17 Storage

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| PVCs (Lost shown in red, pods linked), PVs, StorageClasses | Yes | Yes | Yes; a PVC's pods are linked | Watch | 1b |
| PVC usage columns | — | Yes | With Prometheus only (2.11) | API | 4 |

### 2.18 Configuration and secrets

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| ConfigMaps | Yes | Yes | Yes; a key opens as a read-only copy in the editor | Watch | 1b |
| Secrets, with values revealed on click | Yes | Yes (hidden again on navigation) | The list is the server's Table: Name, Type, Data (a count of keys) and Age. It carries no keys and no values. The keys exist only in the object itself, and a GET returns every value at once. So "Show" makes one GET, and only when the user asks. The keys are listed with every value masked; each is revealed one by one. The whole response is dropped on navigation. On production the first Show per context and session asks. Values are never logged, written to disk or given to an agent (rule 9) | API | 1b |
| A TLS Secret's certificate: subject, issuer, expiry | — | ext (certificate-info) | Parsed from `tls.crt` in the response that Show fetched; the private key is never shown | Local | 1b |
| Create a Secret | Yes | — | A template. The value is typed into the editor's copy, which is removed after apply | Editor | 3b |
| ResourceQuotas, LimitRanges, PriorityClasses, RuntimeClasses, Leases, Mutating and Validating webhooks, ValidatingAdmissionPolicies and their bindings | Yes | Yes | Generic tables | Watch | 1b |

### 2.19 Search, palette and navigation

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Command palette ("Switch to <resource>", forwards) | Yes | Yes (plus forwards, every page, the terminal) | ⌘K: contexts, namespaces, kinds, resources, forwards, verbs | Local | 1b |
| Cluster quick search (⌘P) | Yes | Yes | The context picker (`c`) and the ⌃⌘J switcher, over what the stage has: contexts, namespaces and pods in 1a, every kind from 1b | Local | 1a |
| Find in a tab (⌘F) | Yes | Yes | `/` in lists (text in 1a, selectors in 1b); ⌘F in logs | Local | 1a / 1c |
| k9s's `:` command mode (`:po ns /filter @ctx`) | — | — | Yes (Section 7) | Local | 1b |
| Search kept and linked across views | — | Yes | Kept per section and context for as long as the window is open | Local | 1b |
| Search that ignores dashes and underscores | — | Yes (v2) | `FuzzyMatch` | Local | 1a |
| Label and field selectors sent to the server | — | — | `label:` and `field:` terms become `labelSelector` and `fieldSelector` | API | 1b |
| Saved searches | — | — (#939) | Saved filters as palette items, kept in `Kubernetes/filters.json` under `AppEnvironment.supportDirectory` | Local | 3b |

### 2.20 Shortcuts

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Palette, cluster search, find, settings, terminal, Ask AI, tabs, splits, F-keys | Yes | Yes (not rebindable) | Global shortcuts in `KeyCommands` (rebindable). Single letters only while a Kubernetes list has the keyboard. The dispatch path, `?`, `n`, `c`, `/`, `w` and the section digits come in 1a; each verb's letter lands with its verb (Section 7) | Local | 1a |

### 2.21 Layout

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Dock with terminal and logs under the list | Yes | Yes | The right slot and terminal tabs | Local | 1d |
| Split screen (Lens Studio) | **Plus** | — | Overterm's splits for tabs; one page per window | — | — |
| Tabs torn off into windows | **Plus** | — | Overterm's windows, each with its own page | — | — |

### 2.22 AI and agents

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Built-in chat (Prism, bring your own key) | **Plus** | ext | **Out**: the user's Claude Code and Codex run in tabs | — | Out |
| Launch a CLI agent with the resource as context (Ask AI) | **Plus** | ext (AgentBridge) | Ask Why (`a`, ⌘L): a brief to the agent in the checkout's tab (3.4) | Local | 1e |
| AI that sees and drives the UI | **Plus** | — | **Out**: it sends screenshots, secrets included, and CLAUDE.md forbids synthetic input | — | Out |
| MCP server (read-only, only while the app runs) | **Plus** | — | `k8s_` tools through the existing bridge: typed reads first, then confirmed writes on writable contexts (3.5) | API | 1e / 2a |
| Self-hosted agent product | paid | — | **Out** | — | Out |

### 2.23 GitOps, cost, security, teamwork

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Flux dashboard, Sources, Kustomizations, HelmReleases | **Plus** | ext | Generic tables, health from conditions. Suspend, resume and reconcile as annotation patches | Watch / API | 1b / 4 |
| Argo CD applications, sync, refresh, resource tree | **Plus** | community ext | Generic tables (sync and health are printer columns). The managed tree from `status.resources`. Sync is left to `argocd` in a tab | Watch / Tab | 1b / 3b |
| Cost per namespace (OpenCost, Kubecost or an estimate) | **Plus** | — | **Out**: it needs cloud prices. Requests against usage is shown instead | — | Out |
| Security Center (Trivy Operator) | **Plus** | requested | **Out** of the cluster. A pod's image can be scanned on the Docker page (`DockerScout`) | Local | 4 |
| Teamwork, Cluster Connect | **Plus** | — | **Out**: SaaS, and an agent in the cluster | — | Out |
| `lens` CLI | **Plus** | — | **Out**: MCP and the palette cover it | — | Out |

### 2.24 Extensions

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Extensions API: views, columns, menus, detail sections | **Plus** (to install and run) | Yes (v2 API; v1 extensions no longer load) | **Out**: CLAUDE.md, no plugin slots | — | Out |
| Marketplace, AI-built extensions | **Plus** | — (#730) | **Out** | — | Out |
| Popular extensions: node-pod-menu, resource map, multi-pod logs, certificate info, pod file browser | — | ext | Built in: shells and logs (1d), merged logs (2e), certificate info (1b), the dependency tree (3b), pod files (4, `kubectl cp` in a tab) | — | 1b–4 |
| k9s's plugins.yaml: a command bound to a key for some kinds | — | — | Snippets with placeholders (`${context}`, `${namespace}`, `${pod}`, `${container}`) offered in the verb menu. These are the user's own commands, typed into a tab, not a plugin API (decision 18) | Tab | 3b |

### 2.25 Settings, platform, support

| Feature | Lens | Freelens | Ours | How | Stage |
|---|---|---|---|---|---|
| Preferences: theme, proxy, kubectl path and download, extra kubeconfigs, editor, terminal | Yes | Yes | `SettingsSchema` entries in a Kubernetes section (Section 8) | Local | 1a |
| Telemetry | on unless turned off | no policy stated | None | — | — |
| Update channel, auto-update | Yes | — (#552) | Overterm's own | — | — |
| Export support logs | Yes | — | Overterm's diagnostics | — | — |
| Watch-based updates at scale | Yes (tested at 20k namespaces) | Yes (HTTP/2, bounded restarts) | Section 10 | Watch | 1a |
| Signed bundled binaries | — | Yes | We download nothing | — | — |
| Windows, Linux | Yes | Yes | macOS only | — | — |

### 2.26 Other tools' ideas

| Idea | From | Ours | Stage |
|---|---|---|---|
| xray: a resource's tree with health | k9s | The dependency tree in Overview (3.7) | 3b |
| Pulses: live counts per kind | k9s | The Overview section's counts | 2d |
| Read-only mode | k9s | Built in: classes, enforced in the proxy for what Overterm sends, and by refusing to start writing processes (Section 5) | 1a |
| Benchmarks over a forward | k9s | **Out** (2.7) | Out |
| Lint (Popeye) | Popeye | Health checks over what a detail reads, and bounded reads for the Overview (3.9, decision 33) | 3b |
| Map | Headlamp | The dependency tree (3.7); no free-form graph | 3b |
| Projects | Headlamp | Checkout bindings (3.1) | 3a |
| Diff of one resource across clusters | Aptakube | "Compare with…" (3.10) | 3b |
| Lists merged across contexts | Aptakube | **Later**: one context per page (decision 17) | — |
| neat | kubectl-neat | The stripped YAML copy (2.8) | 1b |
| view-secret | kubectl plugin | Show, then reveal one value at a time (2.18) | 1b |
| Include and exclude regexes, container filter | stern | Options of merged logs | 2e |
| Change timeline | Komodor | 3.6 | 3b |
| Manifest diff in the editor | Monokle | 3.3 | 2b / 3a |

## 3. Beyond Lens and Freelens

Lens and Freelens stop at the cluster. Each of the other tools has one good idea worth taking (2.26).

None of them ties a cluster resource to the worktree and branch that produced it. None hands a failing pod to the coding agent working in the matching checkout.

Overterm already has the pieces to do both:
- the terminal and the editor,
- checkouts, and agents with MCP,
- the Docker page, the Database client and the browser column,
- Ask Agent, attention marks and Tab Info.

### 3.1 A checkout tied to what it deploys

- **How it works.**
  - Overterm recognises the checkout's Kubernetes files: `Chart.yaml`, `kustomization.yaml`, plain manifests, `skaffold.yaml`, `Tiltfile` and `helmfile.yaml`.
  - It offers a guess: the chart's name as the release name, the kustomization's `namespace:`, the manifests' `metadata.namespace`, or labels such as `app.kubernetes.io/part-of`.
  - The user confirms or picks the context, the namespace, and optionally a release or a label selector.
  - The binding is stored in `AppEnvironment.supportDirectory` (`Kubernetes/bindings.json`), keyed by the repository's root. It is never written into the repository. An isolated run gets its own folder, as every piece of state does.
  - The walk up from a file to its chart stops at `pathComponents.count <= 1` and is bounded (CLAUDE.md).
- **Why it matters.** This binding is the scope everything else uses: the rail panel, the attention marks, the MCP tools' default and the switcher's first results. Headlamp's projects need a label on the namespace; ours needs nothing in the cluster.

### 3.2 What is deployed, compared with the checkout

- **How it works.**
  - It needs a binding (3.1). Without one there is nothing to compare with.
  - Overterm reads the bound workload's images from its pod template. The commit comes from these sources, in order of trust:
    1. the image's `org.opencontainers.image.revision` label or annotation, read through the Docker page's existing `buildx imagetools` path (`DockerImageUpdates`), only when asked;
    2. a tag shaped like a commit SHA, full or short (7–40 hex characters), shown at once;
    3. for a Helm release, the chart's `appVersion` when it is SHA-shaped.
  - `Git.run` looks the commit up in the checkout. Nothing is fetched. The answer is like "deployed `abc123`, 4 commits behind `main`; this branch is 2 commits ahead", or "commit `abc123` is not in this checkout" when it is missing, or "no commit found in the image" when no source gives one.
  - "Diff deployed…current" opens a review tab (⇧⌘R) for that range.
- **Why it matters.** "Is my fix out yet?" is the most common question a developer asks a cluster. No Kubernetes UI can answer it, because none of them knows the checkout.

### 3.3 The manifest in the editor, diffed against the cluster

- **How it works.**
  - A manifest open in the editor gets "Diff with cluster". This runs a server-side apply with `dryRun=All`, then compares the live object with the result in the changes pane. managedFields and status are stripped and Secrets are masked; `kubectl diff --server-side` does the same.
  - A dry run is a PATCH and needs the same RBAC as the write. A read-only context's proxy refuses it, and so may the user's RBAC. Then the diff is client-side, the file against the live object, both stripped, and labelled "client-side: defaults and admission not applied".
  - A kustomization is rendered with `kubectl kustomize` (stage 2b). A chart is rendered with `helm template` and the bound release's values, in the background (stage 3a, since it needs the binding). Both render locally and reach no cluster.
  - Fields owned by another manager (`helm`, `argocd-controller`, Flux) are named before anything is applied, for example "Argo CD manages this; your change will be reverted".
  - Applying is a separate, confirmed step (Section 5), on writable contexts only. On production it is not offered by default (decision 30). This is the same path as editing a resource's YAML (2.8): one implementation.
  - A resource's own YAML is this, in its detail's YAML tab: the tab is the editor, one in-memory buffer per resource shared with the window's editor (`y`), the Diff/Apply bar over it, followed from the cluster while it shows — quietly without edits, a banner with them (2.8).
- **Why it matters.** Monokle had this idea and is no longer maintained. Argo and Flux only diff what they manage. A developer edits manifests in the checkout, so the diff belongs next to the file.

### 3.4 Ask Why: a failing pod handed to the agent

- **How it works.**
  - Overterm assembles a brief, as `DockerAgentBrief` does, for these failures:
    - `CrashLoopBackOff`
    - `OOMKilled`
    - `ImagePullBackOff`
    - `CreateContainerConfigError`
    - `Pending`
    - a stuck rollout
  - The brief holds:
    - the pod's status and last terminated state, with what the exit code means;
    - its events;
    - the previous container's last log lines;
    - the owner's pod template, and its diff with the previous ReplicaSet;
    - the bound checkout's deployed commit (3.2), when there is a binding;
    - for `Pending`, the scheduler's message and the nodes' allocatable resources against the requests.
  - Secrets are scrubbed with `DockerSecrets` made generic, plus base64 and kubeconfig patterns. Env from Secrets is named, never valued: the brief fetches no Secret. The user sees the whole brief before it is sent.
  - It goes through the existing Ask Agent sheet to the agent running in the bound checkout's tab, so the agent can read the code that failed. Without a binding, the sheet offers the selected tab's agent or a new one.
  - `DockerAttention`'s "Ask Why" button is reused on failing rows and on attention marks (3.13).
- **Why it matters.** Lens's Ask AI starts an agent next to the cluster; ours goes to the agent that already has the code. Komodor's root-cause analysis is SaaS and covers only pods; this is local and free.

### 3.5 Typed MCP tools, read-only on production

- **How it works.**
  - A `k8s_` group in `BrowserMCP`, turned on by `kubernetes.agentAccess`.
  - Read tools (stage 1e):
    - `k8s_contexts`
    - `k8s_get`: Table text, filtered
    - `k8s_describe`: a summary and events
    - `k8s_logs`: tail, since and grep, scrubbed
    - `k8s_events`
    - `k8s_why`: the brief from 3.4
    - `k8s_rollout`: status and history
    - `k8s_top` (once metrics exist, 2d)
  - Write tools (stage 2a, each with its verb):
    - `k8s_restart`
    - `k8s_scale`
    - `k8s_delete_pod`
    - `k8s_apply`, with the dry-run diff shown in the confirmation (2b)
  - By default a tool works on the calling pane's bound checkout; any other context or namespace must be named.
  - Every tool goes through the context's proxy and starts no process. On a read-only context nothing a tool sends can write, because the socket refuses it.
  - Write tools exist only on writable contexts, and each call is asked in the window with the context and namespace in the title. On production there are none unless writes are on for the session **and** `kubernetes.agentWrites` names that context. `k8s_apply` is never offered on production unless the context also sets `applyOnProduction`.
  - There is no tool for reading Secrets.
- **Why it matters.**
  - Generic Kubernetes MCP servers expose "run any kubectl". Azure's mcp-kubernetes has access levels; kubectl-ai's HTTP mode has no authentication by default.
  - Lens's MCP server is read-only and paid.
  - Ours is typed, scoped and confirmed, as `DockerMCP` is.
  - What it cannot do: stop an agent's own `kubectl` in a terminal. Section 5, rule 10.

### 3.6 A change timeline per workload

- **How it works.** One timeline, newest first, joins:
  - ReplicaSet revisions (image and template changes),
  - Helm revisions,
  - `restartedAt` restarts,
  - scale changes from events,
  - warning events.

  Each change opens its diff in the changes pane.
- **Why it matters.** This is Komodor's selling point, built from data the API already keeps. "It broke at 14:02; what changed at 14:00?" becomes one look.

### 3.7 Dependency tree (k9s xray, kubectl tree)

- **How it works.**
  - The tree sits in a detail's Overview.
  - It goes down the owner chain: Deployment → ReplicaSet → Pod → containers.
  - It goes across references: ConfigMaps, Secrets, PVCs, the ServiceAccount, the Services that select the pod, and the Ingresses and HTTPRoutes that route to those Services.
  - A referenced Secret is shown by name from the Secret list's Table; its data is not fetched.
  - Each node has a health mark; a missing ConfigMap or a Service that selects nothing shows in red.
  - It reads only objects in the same namespace, once, when the tab opens; it does not open watches.
  - Verbs work on the tree's nodes.
- **Why it matters.** Most "why is this broken" answers come down to one broken link. k9s and Freelens's Resource Map extension show this; Lens doesn't.

### 3.8 Port-forwards wherever Overterm shows ports

- **How it works.**
  - A forward is a `ListeningPort` with a `forward` origin. It shows as a pill in the pane header of the tab that asked for it (or the bound checkout's tab), in Tab Info and in the palette. The pill names the pod it is pinned to.
  - A forward is a `kubectl port-forward` process with the user's credentials, not a request on the socket. It changes no object, so it is allowed on read-only contexts after `kubectl auth can-i create pods/portforward`.
  - `o` opens it in the tab's browser column.
  - The API client: a new forward's local port is passed to `APIDiscovery.probeServers`, which asks the usual OpenAPI paths (`/openapi.json`, `/v3/api-docs`, `/swagger.json`…) for a second each. One that answers is offered in the API panel as an import, as a tab's own server is today. Nothing is imported without a press.
  - `d` on a Postgres, MySQL, Redis or ClickHouse pod starts a forward, then creates a Database connection to `localhost:<port>`. The image is recognised by `DockerDatabaseGuess`.
  - The password comes from the Secret that the pod's env refers to, only when the user asks. That is one GET of the Secret, which returns every value (rule 9); on production the session's first one asks. Only the referenced key's value is kept, and it goes straight to the keychain. The rest of the response is dropped.
  - Forwards are reopened when kubectl exits, with the target resolved again (2.7). They survive closing a window, but not quitting the app.
- **Why it matters.** In Lens a forward is a row on a page. Here it sits where the developer already looks for ports, and leads straight to the tools that use it.

### 3.9 Health at a glance (Popeye, Argo's health)

- **How it works.** Pure checks run over what is already read. Each finding has a code and a plain sentence, for example:
  - containers without probes, without requests or limits, or on `:latest`;
  - a Service that selects no pod, or an Ingress pointing at a missing Service or port;
  - a PDB that allows no disruption, or an HPA stuck at its maximum;
  - restarts in the last hour, or pods `Pending` for more than a minute;
  - a custom resource whose `Ready` condition is false (Argo, Flux, cert-manager).

  The section shows a count, and each row links to its object. Nothing is written and nothing is installed. A detail's findings come from its own GET and its tree's lists, so nothing extra is read there. The Overview's count is the one stated addition (decision 33): while it shows, one bounded GET of whole objects for each list the checks need.
- **Why it matters.** Popeye's findings live in a separate tool. Here they sit where the developer already looks: the Overview and each object's detail.

### 3.10 Diff across contexts

- **How it works.** "Compare with…" on any object fetches the same kind and name from another context or namespace (for example staging against production). Both sides are stripped and masked and shown in the changes pane. It is one GET per side, through each context's proxy. On Secrets it compares keys and value hashes only, and on production it asks as Show does.
- **Why it matters.** Drift between environments is a common cause of "it works on staging". Aptakube has this, but it is paid.

### 3.11 A tab's own context, and a warning where it matters

- **How it works.**
  - **Terminal in this context** (stage 1d). A tab opened from the context card, the palette or a resource's verb menu is pinned to that context.
    - Overterm writes a small kubeconfig in `AppEnvironment.supportDirectory` (`Kubernetes/Contexts/<hash>-<tab>-<pid>.yaml`, the folder 0700, the file 0600): `current-context: <name>`, and the context's own entry naming the user's cluster and user (names only) with the tab's namespace.
    - It starts the shell with `KUBECONFIG=<that file>:<Overterm's list>` (exactly the proxies' files), in the context's `terminalDirectory`, else the bound checkout's root (stage 3a), else the home folder.
    - kubectl's merge takes the first `current-context` it finds, so a plain `kubectl` in that tab goes to the pinned context. The user's current context is untouched.
    - The file holds no secret: the server and the credentials stay in the user's entries, which the pin's entry names. A `kubectl config use-context` typed in that tab writes only to it, because kubectl changes the file that sets the key.
    - **The namespace (changed from the first plan, which set none).** A context entry is taken whole from the first file that names it, so the pin's entry hides the user's — which is why it repeats the user's cluster and user by name. With it the tab has its own namespace, and a `kubectl config set-context --current --namespace=…` typed in the tab writes the pin's file. Without it that command wrote the user's own file (checked). Overterm's own commands still carry `-n`.
    - Each tab has its own file, so a `use-context` typed in one tab changes no other. A split of the tab shares it. Files stay while the app runs (a pane moved to another tab keeps its `KUBECONFIG`; a missing first file would send kubectl to the current context). The file's name carries the pid of the Overterm that wrote it, and only the files of an Overterm that no longer runs are swept — a second Overterm on the same folder keeps its tabs' files. The entry is always written, even for a context naming no cluster or no user (copied empty, as the user's entry has it).
    - The tab's label and band follow its file: a `use-context` or `set-context` typed there rewrites it, Overterm reads the pane's `KUBECONFIG` again as kubectl merges it, and the label, band and saved pin say what a plain kubectl reaches now.
    - A restored session writes a new file, the context looked up again by name in Overterm's kubeconfigs as they are then (their files, the context's class now). A context gone, or a file that can't be written, brings the pane back marked "pin lost" with `KUBECONFIG=/dev/null`, which reaches no cluster — never a plain shell to the current context. Each pane of a split is saved with its own pin.
    - It is the user's own kubectl, with the user's rights: a read-only context is not read-only in this tab. On production the tab's header carries the red band from the start, and opening one is confirmed with the context's name.
    - A `KUBECONFIG` exported by the shell's own startup files replaces the tab's. Overterm cannot see that from outside the shell.
    - **The merge order, checked (2026-11-04)** with temporary kubeconfigs only (servers on closed ports on 127.0.0.1, a HOME of the check's own, kuberc off), the user's `current-context` set to a production context:
      - kubectl v1.36.1: `config current-context` and `config view --minify` give the pin's context, its namespace, and the user's cluster's server and user. A `set-context --current --namespace` and a `use-context` write the pin's file; the user's file is unchanged.
      - helm v4.3.1: `helm env` gives the pin's namespace (`HELM_NAMESPACE`), and `helm list` dials the pin's cluster's server.
      - k9s v0.51.0 (headless, read-only, its own config folder): its log names the pin's context and dials its server.
      - `KubeTerminalMergeTests` repeats the kubectl and helm checks whenever they are installed. k9s is a TUI, so it was checked by hand only.
    - **Opened from**: the context card's "Terminal in This Context", a context's right-click on the page, a row's verb menu (in the row's namespace; on a Namespace, that namespace), the palette (`Terminal in <context>`, and the page's command), and View ▸ Terminal in Kubernetes Context… (`kubernetes.terminal`, no key by default).
    - A New Task (worktree plus agent, stage 3b) can open the agent's tab this way, pinned to the bound context, a dev one, so the agent's own kubectl doesn't reach production by default.
  - **The warning** (stage 3b) is limited to what Overterm can know.
    - `CommandLedger` knows which command runs in a pane. Only `kubectl`, `helm`, `k9s` and `stern` are looked at.
    - The context comes from, in order: the command's `--context` (`--kube-context` for helm) and `--kubeconfig` flags; else the tab's pinned context; else the `current-context` of the files that the captured `KUBECONFIG`, or `~/.kube/config`, resolve to.
    - Those files are watched with `DirectoryWatcher` and read again only when they change, never per command. They are never written. A `kubectx` changes the file, so it is seen.
    - Overterm cannot see a pane's own environment: a `KUBECONFIG` exported in that shell is unknown. Unless a flag or the pinned context settles it, the warning says "probably".
    - If the context is production, the pane header shows "⎈ acme-prod" in red.
- **Why it matters.** The real risk on this Mac is not Overterm's buttons. It is a `kubectl delete` that a person or an agent runs while the current context is production. kube-ps1 and kubie solve half of this; Overterm can solve it per tab.

### 3.12 The Docker page and local clusters

- **How it works.**
  - "Scan" on a pod's image opens it on the Docker page's Vulnerabilities tab (Scout).
  - "Run locally" fills in the Docker page's Run window with the pod's image, its non-secret env and its ports. Secret values are asked for, not copied.
  - Local contexts (`docker-desktop`, `kind-*`, `k3d-*`, and the other names in Section 5) are recognised by name as local and writable by default. Overterm never turns a local cluster on or changes another app's settings.
- **Why it matters.** Reproducing a production crash locally is a common next step, and Overterm already runs containers.

### 3.13 Attention marks

- **How it works.**
  - Some failures in a bound namespace mark the checkout's tab:
    - a pod going into `CrashLoopBackOff`, `OOMKilled` or `ImagePullBackOff`, from the pod watch;
    - a Deployment's rollout past its `progressDeadlineSeconds` (its `Progressing` condition false with `ProgressDeadlineExceeded`), from the Deployment watch.
  - If set, it also sends a notification (`AttentionNotifier`, as `DockerAttention` does), with Ask Why (3.4).
  - **This is a stated exception to "only what is on screen"**, as `DockerModel`'s event stream is. Its budget:
    - two watches per bound namespace, on that context's proxy: Pods and Deployments, both narrowed by the binding's label selector when there is one;
    - open only while that checkout has a tab open and `kubernetes.notifyOnFailure` is on;
    - at most `kubernetes.backgroundWatches` bound namespaces (default 4, so at most 8 watches) across the app, the most recently used checkouts first;
    - the watches are the only thing it reads: no logs, no metrics, no discovery beyond the Pods and Deployments kinds;
    - **proxies:** background watches never take the page's slot. They use at most `maxProxies − 1` proxies. When the page needs a proxy and every slot is held, the least recently used background proxy is closed. Its checkout's tab then shows "not watched" until a slot is free again.
  - The rail panel does not depend on it. It reads only while it is the panel on screen.
- **Why it matters.** The developer learns that the deploy failed in the tab where they pushed it, not ten minutes later.

### 3.14 Copy as kubectl

- **How it works.** Every verb shows the command it is equivalent to, for example `kubectl --context X -n Y rollout restart deploy/api`. Every menu has "Copy as kubectl", and verbs that run in a tab anyway have "Run in a tab". Copying is offered on every class: a copied command is the user's to run.
- **Why it matters.** It is transparent and teaches the commands, and the user can repeat them in a script.

### 3.15 The cluster's own API docs in the editor

- **How it works.**
  - For a resource buffer, field descriptions come from the cluster's `/openapi/v3`, CRDs included.
  - Hovering over a field shows its description, and an unknown field is marked.
  - The data is read once per context and group, and cached in memory.
- **Why it matters.** It is `kubectl explain` without leaving the file. Seabird and the OpenShift console show this reference beside the editor.

## 4. How we talk to clusters

### Options

| | Our own client (NIOSSL, kubeconfig auth in Swift) | Everything with kubectl (`get -o json`, `--watch`) | **`kubectl proxy` plus the API (recommended)** |
|---|---|---|---|
| Authentication | We re-implement it: exec plugins and their cache, client certs, `proxy-url`, `tls-server-name`, impersonation | Free | Free, in one long-lived kubectl |
| Speed | Direct | A process per call. An exec plugin per process (`aws eks get-token` takes about 1 s) | One process per context. Tokens cached until `expirationTimestamp` or a 401 |
| Live updates | Ours | `--watch` prints JSON objects one after another | Watch streams over the socket |
| Errors | Typed | Parsed from text | The server's Status JSON. Transport failures come back as 500 with plain text |
| Risk | Every auth bug hits production | Low, but slow | Low; kubectl is what users debug with |
| Socket exposure | None | None | A socket other processes running as the same user can reach (Section 5) |

What sharpens the comparison:
- **The cost of the legacy auth-providers is mostly gone.** The in-tree gcp and azure providers were removed from client-go and kubectl in 1.26. Only the rare `oidc` provider remains. EKS, GKE and AKS all use exec plugins now.
- **The real cost of our own client is the exec-plugin contract and its edge cases:**
  - ExecCredential v1 and v1beta1, `KUBERNETES_EXEC_INFO`, `interactiveMode`;
  - caching until `expirationTimestamp`, invalidating on 401 and retrying;
  - closing connections when the returned certificate changes;
  - the plugin's environment (PATH, `AWS_PROFILE`).
- **SwiftkubeClient (0.26) does not remove the hard part.** It documents only basic, bearer and x509 auth, with no exec plugins.
- **The choice stays open.** A transport protocol separates the HTTP layer from how it reaches the server, so a later switch to in-process auth, or a hybrid, needs no change above it. The fake API server (Section 11) tests that layer either way.

**Recommended:** a hybrid.
- `kubectl proxy` handles REST, watches, logs and the permission reviews.
- `kubectl port-forward` processes handle forwards. Port-forward over WebSocket is still SPDY frames inside WebSocket messages, so an in-process client would have to implement SPDY/3.1 with zlib header compression.
- Shells, attach, debug, drain, rollback and Helm are commands in terminal tabs.
- Only the first goes through the socket. The rest run with the user's own credentials, and Section 5 says which of them start on a read-only context.

### The proxy, as verified

From `kubectl/pkg/proxy/proxy_server.go` and `cmd/proxy/proxy.go`. Corrections to the first analysis are marked.

| Fact | Detail |
|---|---|
| Default filters | `DefaultHostAcceptRE = ^localhost$,^127\.0\.0\.1$,^\[::1\]$`. `DefaultPathRejectRE = ^/api/.*/pods/.*/exec,^/api/.*/pods/.*/attach,^/api/.*/nodes/.*/proxy/run`. `DefaultMethodRejectRE = ^$`, so no method is rejected |
| **New:** how the filter matches | `accept(method, path, host)` checks the reject paths first, then the reject methods, then requires both an accepted path and an accepted host. The path is `req.URL.Path` (decoded). The patterns are unanchored `MatchString`, so each one starts with `^`. Passing `--reject-paths` replaces the defaults, so our list repeats them |
| **Corrected:** what is refused | Only exec, attach and `nodes/*/proxy/run`. `pods/*/portforward`, `pods/*/proxy`, `services/*/proxy`, the rest of `nodes/*/proxy`, and every POST, PUT, PATCH and DELETE pass |
| **New:** the Host header | The filter also applies on a unix socket and checks the Host header with the port stripped. `UnixHTTPTransport` takes the Host as a parameter; Kubernetes's sends `Host: localhost`. Any other value gets 403 |
| `--disable-filter` | Removes all filtering; its help text calls it dangerous. Not used: we widen `--reject-paths` instead |
| Upgrades | Proxied by `UpgradeAwareHandler`, forced to HTTP/1.1, with kubectl's credentials. Exec, attach and port-forward pass through once the reject paths stop blocking them. A WebSocket upgrade is a GET (SPDY's is a POST), so the method filter alone does not stop it: the paths must |
| **New:** errors | Transport errors, including a failed exec plugin, come back as HTTP 500 with `err.Error()` as plain text (`text/plain`). They are not Status JSON and not 502. Real API errors (401, 403, 404, 409, 410, 429) pass through as the server's Status JSON. The exec plugin's stderr goes to kubectl's stderr, for example "Token has expired" from `aws` |
| Socket | `umask 0077` around `net.Listen`, so only the user can open it. A stale socket file at the path is removed. Readiness is `Starting to serve on <addr>` on stdout. The path must stay under 104 bytes |
| Other flags | `--keepalive` defaults to 0. `--api-prefix` defaults to `/`. `--accept-paths` and `--reject-methods` are configurable |

**What the read-only list must cover.** A read-only socket must refuse anything that changes an object or acts inside the cluster:

| Subresource | Method | Covered by |
|---|---|---|
| Every create, update, patch and delete, dry runs included | POST, PUT, PATCH, DELETE | the method filter |
| `pods/eviction`, `serviceaccounts/token` (TokenRequest), `pods/binding` | POST | the method filter |
| `pods/ephemeralcontainers`, `pods/resize`, `*/scale`, `*/status` | PATCH, PUT | the method filter |
| `pods/exec`, `pods/attach`, `pods/portforward` | GET (WebSocket) or POST (SPDY) | the paths |
| `pods/*/proxy`, `services/*/proxy`, `nodes/*/proxy` | any method, GET included: a GET reaches a process in the cluster, which may act on it | the paths |
| An aggregated API's own connect subresources (KubeVirt's `subresources.kubevirt.io` `console` and `vnc`) | GET (WebSocket) | the paths, for the known groups; the rest is a spike item and a risk (Section 12) |

None of the path-covered subresources is used by Overterm through the socket: shells and forwards are kubectl processes, and Prometheus has its own proxy (below). So every proxy refuses them, writable or not. A read-only one also refuses the write methods.

**How Overterm starts it.** The binary is the chosen kubectl, and the environment is the shell's, captured once (below). The socket is named by a short hash of the context.

```
# every context: no exec, attach, port-forward or proxy subresources on the socket
PATHS='^/api/.*/pods/.*/(exec|attach|portforward|proxy),^/api/.*/services/.*/proxy,^/api/.*/nodes/.*/proxy,^/apis/subresources\.kubevirt\.io/'

# read-only context (remote and production by default): every method but GET
kubectl proxy --context C --unix-socket <0700 dir>/<hash>.sock \
  --reject-methods='^(?:[^G]|G$|G[^E]|GE$|GE[^T]|GET.)' \
  --reject-paths="$PATHS"

# writable context: the same paths, no method filter
kubectl proxy --context C --unix-socket <0700 dir>/<hash>.sock \
  --reject-paths="$PATHS"

# Prometheus (stage 4, opt-in): a second proxy that reaches only the query paths
kubectl proxy --context C --unix-socket <0700 dir>/<hash>-metrics.sock \
  --reject-methods='^(?:[^G]|G$|G[^E]|GE$|GE[^T]|GET.)' \
  --accept-paths='^/api/v1/namespaces/<ns>/services/<svc>:<port>/proxy/api/v1/(query|query_range)$'
```

How this works:
- **POST cannot be rejected selectively.** The permission reviews (SelfSubjectAccessReview and SelfSubjectRulesReview) are POSTs, and they go to collection paths that a create would use too. A path filter cannot let one through and stop the other.
- **So a read-only context's proxy refuses every write method, POST included.** That context then asks its few permission questions through short-lived kubectl processes instead of the socket:
  - every write verb is off by policy;
  - reads that are refused come back as 403 and grey out what they cover;
  - shells, attach and forwards are checked with `kubectl auth can-i create pods/exec` (and the others) before the verb is enabled (stage 1d);
  - who-am-I (`SelfSubjectReview`, also a POST) is asked once through `kubectl auth whoami -o json`.
- **When a context becomes writable, its proxy restarts without the method filter.** Reviews then go through the socket. When it stops being writable (a production session ends, a setting changes), the proxy restarts with the filter again.
- **No socket reaches the proxy subresources.** A GET on a service, pod or node proxy reaches a process inside the cluster, which may act on it. Prometheus (stage 4) gets its own proxy whose `--accept-paths` names only the detected or configured service's `query` and `query_range` paths (namespace, service and port regex-escaped). Every other path, other services' proxies included, gets 403 there. It counts towards `maxProxies` and runs only while a chart shows.
- **The guarantee is the socket's.** Overterm's own requests and the MCP tools cannot write on a read-only context, whoever sends them. The kubectl and helm processes Overterm starts do not use the socket. For them, read-only is Overterm refusing to start the writing ones (Section 5).

Checked against a real cluster (kind, Kubernetes v1.37.0, kubectl v1.36.1; 2026-11-07; `KubeRealClusterTests`, Section 11 and Section 12):
- **The method filter matches the method as sent, case and all.** `post`, `Delete`, `OPTIONS`, `PROPFIND` and `TRACE` passed `^(POST|PUT|PATCH|DELETE|CONNECT)$` and reached the apiserver, which answered 405 and changed nothing — an aggregated API server needn't. So the read-only pattern now names the one method let through: everything but `GET` is refused (`KubeProxyFlags.rejectedMethods`). An upgrade is a GET, so the paths stop it (a WebSocket exec gets 403).
- **The filter's answer** is kubectl's own: `403`, `Content-Type: text/plain; charset=utf-8`, body `Forbidden\n`, the server never asked. The server's 403 is Status JSON, so the two can be told apart.
- **Path variants don't slip past.** `%2F` anywhere (`pods%2Fp%2Fexec`, `api%2Fv1…%2Fproxy%2F`), `%65xec` and `exec%3F…` are decoded before the match and refused; `//`, `/./`, `..` get kubectl's mux's `307` to the clean path, which is refused in turn; a changed case (`EXEC`, `/API`, `Proxy`) is a 404 from the server, which serves no such path; trailing segments (`exec/`, `exec/extra`, `exec;x`, `exec.json`) and a query are still refused, `pods/p?/exec` is the pod.
- **Connect subresources:** kind's discovery lists exactly `pods/attach`, `pods/exec`, `pods/portforward`, `pods/proxy`, `nodes/proxy` and `services/proxy` with `get` (besides the reads: status, scale, log, ephemeralcontainers, resize, approval), all six refused on either socket, and no API is aggregated. The suite fails naming any new one. The dev clusters' aggregated APIs (metrics-server's on EKS) are still to be listed there.
- **Failed exec calls are not cached:** a plugin that fails ran once per request (four requests, four runs; `/version` too), each a 500 `text/plain` "getting credentials: exec: executable … failed with exit code 1", its own words ("Token has expired") on kubectl's stderr. A token the server refuses (401) is thrown away and asked for again: five runs for four requests. A token it takes is kept until its expiry: one run for many. So a credential failure stops the context (as before), and **a 401 on a context whose user signs in with a plugin now does too** (`KubeProxyProblem.classify`).

### Environment and credentials

- **The environment comes from the shell.** A Dock-launched app's environment is not the shell's, so Overterm asks the shell once: `$SHELL -lic 'env -0'` with `HISTFILE=/dev/null`.
  - It must be interactive (`-i`) so `.zshrc` is read. That is the lesson from `AgentUsageCommand`.
  - That function returns a path today; it is generalised to return the environment.
  - kubectl processes (the proxy, forwards, `auth can-i`) start with this environment, so `aws`, kubelogin and `gke-gcloud-auth-plugin` are found and `AWS_PROFILE`, `AWS_REGION` and `KUBECONFIG` come through.
  - In an isolated run, `KUBECONFIG` is replaced, never inherited (Section 11).
- **Credential lifetimes.** Exec-plugin credentials are cached until `expirationTimestamp`, a 401, or the process exiting. EKS tokens last about 15 minutes and refresh inside the long-lived proxy without anyone noticing. A rotated client certificate is picked up when the proxy restarts.
- **`interactiveMode: Always` fails without a terminal**, and a proxy started by Overterm has none. Overterm reads this, and the plugin's `installHint`, from the kubeconfig. Before starting the proxy for such a context, it offers a terminal tab running `kubectl --context C version` so the user can sign in there. A missing plugin shows its `installHint`.
- **kubelogin (oidc-login)** opens a browser and listens on 127.0.0.1:8000, then 18000. A second login at the same time takes the second port; a third fails to bind. So proxies whose exec plugin is `oidc-login` start one at a time. The ones waiting say "Waiting for sign-in in the browser". Its token cache is `~/.kube/cache/oidc-login`.
- **Errors in plain words:**
  - "Token has expired" / "SSO session": an "aws sso login" button that runs in a tab, with `--profile` taken from the plugin's env or args.
  - An expired client certificate: said plainly, with the file and the date.
  - A 500 whose text is a dial error: "the cluster can't be reached (VPN?)", with the text available.
  - The error mapper treats 500 with `text/plain` as a transport or auth failure and reads the proxy's stderr for the reason.
- **Which kubectl.**
  - The candidates are those found where installers put them (`/usr/local/bin`, `/opt/homebrew/bin`, Docker Desktop's bundle), as `DockerCLI` finds `docker`, plus `kubernetes.kubectlPath` and the context's own `kubectl`.
  - The one closest to the server's minor version is chosen, within kubectl's ±1 skew policy.

### The API features we use

**Discovery**
- Aggregated discovery (beta in 1.27, GA in 1.30, always on since 1.33) gives kinds, short names, verbs, scope and subresources.
- We fall back to the legacy `/api` and `/apis` only for very old servers.
- Discovery is cached per context and read again on a CRD event, a 404, or every 5 minutes while the page shows (decision 28).

**Tables**
- The request sends `Accept: application/json;as=Table;g=meta.k8s.io;v=v1, application/json`. The fallback matters: an aggregated API without Table support answers 406 to Table alone. So the reader handles a Table or a plain List.
- `includeObject=Metadata` is the default, set explicitly anyway. It embeds each row's labels, annotations, ownerReferences, creationTimestamp, resourceVersion and uid.
- A column with `priority` 0 is in the default view; a column with `priority > 0` is what `-o wide` adds, behind `w`. `format: name` marks the identifier column.
- A CRD without printer columns gets Name plus Created At.
- **New:** a Secret's Table has Name, Type, Data and Age, and Data is the number of keys (`len(obj.Data)`). Neither the cells nor the embedded metadata carry a key or a value. One exception: an annotation can. `kubectl.kubernetes.io/last-applied-configuration` holds the whole object, values included, on a Secret made with client-side `kubectl apply`. So Secret rows drop that annotation as they are decoded. It is never kept, shown or logged, and the YAML of any Secret masks it as it masks `data`.
- **New:** Age is a string rendered when the server answers, so it goes stale. Ages are computed again on the client from `creationTimestamp`.
- **New:** a watch on a Table sends `columnDefinitions` in the first event only. Later events are single-row Tables without headers, so the header kept from the list is reused.

**List and watch** (the informer's states)
- A list is paged with `limit=500` and `continue`, and the collection's resourceVersion stays the same across pages.
  - A `continue` token expires after about 5 minutes and returns 410; the list then starts again.
  - `remainingItemCount` is absent when selectors are used.
- `resourceVersion` on a list:
  - unset means consistent and most recent, served from the watch cache since 1.31;
  - `0` means any, possibly stale.
  - A `resourceVersion` is always paired with `resourceVersionMatch`.
- A watch uses `allowWatchBookmarks=true`, and the last bookmark's resourceVersion is kept as the point to resume from.
- **New:** a 410 usually arrives as an in-stream event, `{"type":"ERROR","object":{"kind":"Status","code":410}}`, though it can also come as an HTTP 410 when the watch starts. Both are handled the same way: drop the cache, list again, watch again from the list's resourceVersion.
- **New:** the server ends a watch after its timeout, a random 30–60 minutes by default. That is normal: we watch again from the last resourceVersion without listing again.
- Streaming lists (`sendInitialEvents=true&resourceVersionMatch=NotOlderThan`) are only an optimisation, depending on the version:
  - beta and on in 1.32, off by default in 1.33, on again from 1.34;
  - client-go's own gate is on by default only from 1.35.

  They sit behind detecting the version, with list plus watch as the baseline. **They combine with `as=Table`** (kind's 1.37): every object ADDED as a one-row Table, the columns on the first, then a `BOOKMARK` that is a Table too — its own metadata only the resourceVersion, its one row's object (whatever `includeObject` asked) carrying `k8s.io/initial-events-end: "true"`, its cells empty. An empty list's end is the stream's first Table, so it carries the columns. Overterm read the annotation only from the Table's own metadata, so on a real server every streaming list went quiet for 5 s and the context fell back to list plus watch for the run; `KubeWatchDecoder` now reads it from the row, and the columns from the bookmark. A streaming list whose events go quiet for 5 s without its end is still given up for list plus watch, for a server that doesn't combine them.

**Single objects**
- Fetched as JSON and shown as YAML, with managedFields and status folded away.
- A Secret is fetched only by Show (rule 9). Its GET returns every value at once, base64-encoded. There is no API for one key, and metadata-only fetches carry no keys.
- Helm-style metadata-only listings use `Accept: application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1`.

**Logs** (`pods/{p}/log`)
- Parameters:
  - `container`, `follow`, `previous`, `timestamps`, `tailLines`;
  - `sinceSeconds` or `sinceTime` (RFC3339), never both;
  - `limitBytes`, which may cut a line.
- **New:** with several containers, `container` is required, or the server answers 400. We choose the `kubectl.kubernetes.io/default-container` annotation, else the first container, as kubectl does.
- `timestamps=true` is always on internally. It is needed to merge streams and to resume a follow after a reconnect with `sinceTime` = the last timestamp, removing duplicate lines, as `DockerLogFollower` does.
- Follow streams end on kubelet or apiserver timeouts. That is reconnected the same way.
- There is no API for logs of several pods. kubectl opens one request per pod (`--max-log-requests` defaults to 5), and a selector does not pick up pods created later. Overterm fans out with its own cap (`kubernetes.logStreams`) and adds streams from the pod watch.
- `stream=Stdout|Stderr` is alpha and off by default since 1.32, so it is not used.

**Events**
- `events.k8s.io/v1`, filtered to one object with `fieldSelector=regarding.name=…`.

**Permissions**
- On read-only contexts: `kubectl auth can-i` and `kubectl auth whoami` processes, as above.
- On writable contexts, `SelfSubjectAccessReview` is authoritative per verb. It asks the full chain of authorizers, RBAC and webhooks.
  - Examples: `delete pods`, `patch deployments/scale`, `create pods/exec`, `get secrets`.
  - Results are cached per context, namespace and attributes for about a minute.
- `SelfSubjectRulesReview` is only a hint to pre-grey verbs. It is flagged `incomplete` with webhook authorizers. EKS access entries are evaluated outside RBAC, so the rules may miss them (to verify in the spike). A verb is enabled only after its access review says yes.
- **New:** since 1.35, `AuthorizePodWebsocketUpgradeCreatePermission` is on by default, so a WebSocket exec, attach or port-forward also needs `create` on `pods/exec`, `pods/attach` or `pods/portforward`. The check for the `e`, `A` and `f` verbs asks `create`.

**Writes** (writable contexts only)
- Delete is a `DELETE` with `propagationPolicy=Background`.
- Scale is a `PATCH` on the `/scale` subresource; RBAC needs `patch` on `deployments/scale`.
- Restart is a merge patch of `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` to an RFC3339 time.
- Cordon is a patch of `spec.unschedulable`.
- Apply from the editor is server-side apply:
  - `PATCH` with `Content-Type: application/apply-patch+yaml` and `fieldManager=overterm`, which apply requires.
  - The object carries the `resourceVersion` it was opened at, so a change since then is a 409, not a silent overwrite.
  - It is preceded by a `dryRun=All` diff.
  - A dry run runs admission and needs the same RBAC as the real request, so a read-only user cannot dry-run (3.3 says what happens then).
  - A 409 Conflict lists the managers that own the fields. The fields' owners are shown from managedFields before anything is applied.
  - `force=true` is never the default, and never offered on production.
  - On production, apply is not offered at all unless the context sets `applyOnProduction` (decision 30).
  - Objects created with client-side apply carry `last-applied-configuration`; a new manager does not remove fields it doesn't own.
  - Helm 4 uses server-side apply by default (`install --server-side`; upgrade "auto"), so its fields belong to `helm`.
- Our diff copies `kubectl diff`:
  - the dry-run result against the live object;
  - managedFields and status stripped;
  - a Secret's `data` masked as `***` / `*** (before)` / `*** (after)`.

**Metrics**
- `/apis/metrics.k8s.io/v1beta1`: `{timestamp, window, usage{cpu,memory}}` per container and node. This is a snapshot with no history and no watch.
- metrics-server scrapes every 15 s and says it is for autoscaling, not monitoring. We poll every 15–30 s, only while a metrics column or tab shows. Any history is Overterm's own ring buffer in memory.
- It is not deployed by default on EKS. RBAC needs `get` and `list` on `pods.metrics.k8s.io` and `nodes.metrics.k8s.io`.
- kubelet's `/stats/summary` needs `nodes/proxy`, a highly privileged permission, and every proxy refuses that path. It is not used, so volume usage needs Prometheus.

**Prometheus** (stage 4, opt-in per context)
- Freelens's way: find the service by known selectors with a list through the main socket, then query through the apiserver's service proxy (`/api/v1/namespaces/{ns}/services/{svc}:{port}/proxy/api/v1/query_range`, which needs `get services/proxy`). The query goes through the metrics proxy, which accepts that one service's query paths and nothing else.
- Known selectors:
  - `lens-metrics/prometheus`;
  - `operated-prometheus=true`;
  - the prometheus chart's `app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server,app.kubernetes.io/managed-by=Helm` (v15 on);
  - its older `app=prometheus,component=server,heritage=Helm`.

  The context's `prometheus` entry can name the namespace, service and port instead.
- Freelens's queries need cAdvisor, kube-state-metrics and node-exporter. For a pod's CPU, for example: `sum(rate(container_cpu_usage_seconds_total{container!="",image!="",pod=~…,namespace=…}[1m]))`, plus `container_memory_working_set_bytes` and `kube_pod_container_resource_requests` and `_limits`. Volume usage is `kubelet_volume_stats_used_bytes` and `_capacity_bytes`.
- (metrics.md, M0) Overterm's take on them: every sum goes over one series a container (`max by` a gauge, `sum by` a counter's rate), kube-state-metrics' series `max by` what identifies them, and requests and limits only of Pending and Running pods (`kube_pod_status_phase`). A `rate()`'s window is four scrapes at least (a step and a scrape, whole minutes; a minute's scrape assumed until probed); `rate(x[1m])` on a 1m scrape answers nothing. Raw cAdvisor across the cluster is read up to 6h; past it the chart says why and offers 6h. Every query carries `timeout=20s`.
- The chart's time range sets `query_range`'s `start`, `end` and `step`.
- OpenShift's Prometheus sits behind a token-checking proxy. Its token is out (2.1).

**Helm releases** (Helm main, `pkg/storage/driver`)
- Storage:
  - Secret type `helm.sh/release.v1`, named `sh.helm.release.v1.<release>.v<revision>`, with one data key, `release`.
  - Labels: `owner=helm`, `name`, `status`, `version`, `createdAt`, `modifiedAt`.
- **Answered:** Helm 4 (v4.3.1) writes the same format as Helm 3.
- Encoding: JSON → gzip → base64, then the API's own base64.
  - We decode base64 twice.
  - We decompress only if the bytes start `1f 8b 08`; otherwise the payload is plain JSON (old releases).
  - The decompressed size is capped (32 MB), and parsing runs on a background queue.
- Listing uses `labelSelector=owner=helm` and `fieldSelector=type=helm.sh/release.v1`, metadata only. Status and revision come from the labels, and one Secret is fetched only for a detail.
- ConfigMap storage uses the same format and the same `owner=helm` label. Overterm looks for both.
- Helm keeps 10 revisions by default.
- What needs masking:
  - `config` (the user's values: secrets live here);
  - every Secret in `manifest`, which Helm does **not** mask.

  Neither is written to disk or given to agents.
- Reading releases needs `get` and `list` on Secrets in the namespace, the same privilege as reading every Secret there. Read-only production users may not have it. The section says so when it is refused, and the rest of the page works.

**Shells and forwards**
- `kubectl exec -it`, `attach`, `debug`, `logs -f`, `port-forward` and `drain` run as processes, with the captured environment and the user's credentials. None of them uses the socket. Which start on a read-only context is in Section 5.
- kubectl uses WebSocket for exec by default since 1.30 and for port-forward since 1.31.
- `kubectl port-forward` to a Service or Deployment picks one pod at start and does not follow it. So Overterm resolves the pod itself and forwards to `pod/<name>`. It does not exit when its pod is deleted while nothing connects: kubectl 1.36 against 1.37 kept listening for a minute and more, then exited (1, "error: lost connection to pod") at the next connection, which failed. So Overterm's pod check (every 5 s while the page shows) is what notices a pod gone; kubectl exiting says so only once the forward was used. Hidden, nothing is read, and a forward to a deleted pod stays up until it is used or the page shows again.
- In-process exec over WebSocket (`v5.channel.k8s.io`, a one-byte channel prefix, resize on channel 4) is feasible. It is not needed: Overterm's terminal tabs give a TTY, resize and auth for free.

### Connections

- The transport is `UnixHTTPTransport`, extracted from `NIODockerTransport`:
  - the Host header is a parameter (`docker` for Docker, `localhost` for Kubernetes);
  - Docker's `/_ping` version negotiation stays in `DockerEngine`;
  - streams are an `AsyncThrowingStream` that closes when the reader leaves.
- **New:** HTTP/1.1 on the socket means one connection per open watch or log stream, with no multiplexing on the local side. kubectl multiplexes over HTTP/2 to the server.
  - Streams get dedicated connections. Each context caps concurrent streams (default 24) and queues the rest.
  - Request and response calls use a separate bounded pool (default 6 per context), so watches and logs never block the request that opens a detail.
- On a 429, the client honours `Retry-After` (API Priority and Fairness).
- At most `kubernetes.maxProxies` (default 4) proxies are alive, metrics proxies included.
  - One slot is always kept for the page's context. Background watches use at most `maxProxies − 1`, and theirs are the first closed when the page needs a slot (3.13).
  - Otherwise opening another closes the least recently used idle one.

## 5. Security for production clusters

This section is the centre of the design: the default context on this Mac is production.

**Classes**

| Class | Recognised by | Default |
|---|---|---|
| Production | The context or cluster name matches `kubernetes.productionPattern` (default `(^\|[-_/.:])(prod\|prd\|production\|live)([-_/.:]\|$)`) | Read-only, red everywhere. Writes only for a session (rule 2) |
| Local | The context name is `docker-desktop`, `orbstack`, `minikube`, `rancher-desktop` or `colima`, or starts with `kind-` or `k3d-` | Writable |
| Remote | Everything else | Read-only |

**Precedence**, first match wins:
1. a `class` set by hand in the context's `kubernetes.contexts` entry;
2. production by name, which beats a local name, so `kind-prod-copy` is production;
3. local by name;
4. remote.

A server on 127.0.0.1 or `::1` does not make a context local: an SSH tunnel or a bastion's forward looks the same. The address is used only by the live tests, which need a local name **and** a loopback server (Section 11). A unit test pins this order, with the fake server's contexts on 127.0.0.1 among the cases.

On this Mac the default pattern marks `…:cluster/acme-prod` and `globex-eu-west-1-prod` as production. The two `-dev` contexts and `kubernetes-admin@k8s-cluster` are remote, so they are read-only too. A unit test pins these five names.

Each context's class, writable flag and colour can be set in its `kubernetes.contexts` entry. A name the pattern misses can be marked production by hand. A context can be made less strict only by an explicit setting; it never happens implicitly.

**What read-only guarantees, and what it doesn't**

Read-only means Overterm changes no object in that cluster. Two mechanisms enforce it, and each covers different things:

| What | Path | Enforced by | Strength |
|---|---|---|---|
| Lists, watches, details, logs, metrics, reviews; every `k8s_` MCP tool | The context's proxy socket | The proxy's flags (Section 4) | Holds for any process that uses the socket |
| `kubectl` and `helm` processes Overterm starts: shells, attach, debug, port-forwards, `logs -f`, drain, `rollout undo`, Helm, node shells | The user's kubeconfig and credentials, never the socket | Overterm refusing to start the writing ones on a read-only context (table below) | A check in Overterm's code, locked by tests. The credentials could write |
| What a person or an agent types in any terminal tab, a "Terminal in this context" tab included | The user's own kubectl | Nothing Overterm can enforce. The pinned context and the warnings (3.11) are the guard | None |

**Processes on a read-only context**

| Process | Read-only context | Writable context |
|---|---|---|
| `kubectl logs -f` | Started | Started |
| `kubectl port-forward` | Started, after `can-i create pods/portforward` | Started, after `can-i` |
| `kubectl exec -it`, `attach -it` | Started after `can-i`. On production each is confirmed once per pod and session (rule 5). A context can turn them off (`shells: false`) | Started after `can-i` |
| `kubectl debug` (an ephemeral container), `drain`, `rollout undo`; `helm rollback`, `upgrade`, `uninstall` | **Refused** | Started after the confirmation, with a typed name where rule 4 says |
| `kubectl debug node/…` (node shell) | **Refused** | Only with the context's `nodeShell` on, name typed |
| `kubectl auth can-i`, `auth whoami`, `version`, `kustomize`; `helm template` | Started: they change nothing | Started |
| Terminal in this context | Opened, on production with a confirmation and the red band. Nothing is enforced inside it | Opened |

A shell or attach changes no object, but inside the container it can do anything the container can. On production it is allowed only after `can-i` and a confirmation (decision 27).

**Rules enforced in code and locked by tests**
1. **Read-only is enforced on the socket and at process start, not only in the interface.**
   - A read-only context's socket refuses POST, PUT, PATCH, DELETE and CONNECT. Every socket refuses exec, attach, port-forward, and the pod, service and node proxy subresources (Section 4). This is in stage 1a, before any verb exists.
   - `KubeCommands` and `ManagedProcess` refuse to build a writing command for a read-only context (the table above). This lands with the first such command.
   - The interface also hides or greys out write verbs, with the reason.
   - A unit test checks the flags built for each class. Another checks every process verb against every class.
   - A test runs a real kubectl proxy against the fake API server. It checks that no write method and no listed subresource reaches the fake, path variants included.
2. **Writes are turned on per context, in one place.**
   - A non-production context's `writable` flag in `kubernetes.contexts` decides. Local contexts default to writable, remote ones to read-only. The flag persists.
   - A production context ignores that flag. Its writes are turned on from the context card for this session only, and end when the app quits, so they must be turned on again on purpose each day (decision 4).
   - No other setting says whether a context is writable. `kubernetes.agentWrites` only says whether agents' write tools exist on a context that is writable: they exist only on a context it names, whatever its class (empty by default, so agents only read, even on a writable local context).
3. **Every write is confirmed.** One shared confirmation sheet (extracted from `DockerMCP.allow`) shows:
   - the context and namespace, in red on production;
   - the object;
   - the exact command it equals (Copy as kubectl);
   - for apply, the dry-run diff and the fields' other owners.

   Each write ships with its access review and its confirmation in the same commit, never before them.
4. **Destructive actions on production ask for the object's name to be typed**, GitHub's pattern for deleting a repository. These are: delete, scale to 0, force delete, removing finalizers, drain, `rollout undo`, a debug container (it stays in the pod's spec until the pod goes), deleting a namespace, node shell, Helm rollback, Helm uninstall, and apply where `applyOnProduction` allows it. Deleting a namespace and uninstalling a Helm release ask for the name on every class.
5. **A shell or attach on production is confirmed** with the context, namespace and pod, once per pod and session. It runs in a tab whose header carries the red band. The verb is enabled only after `kubectl auth can-i` says yes. A context's `shells` turned off refuses every shell Overterm would open there: exec, attach, a debug container (it is attached to) and a node shell.
6. **The context is visible all the time.** On production the page carries a red band with the context's name. A "Terminal in this context" tab on production carries it in its header. From stage 3b, the pane header shows "⎈ <context>" when a kubectl-family command runs against production in any tab (3.11).
7. **Overterm never writes a kubeconfig and never changes the current context.** Every command carries `--context` (`--kube-context` for helm) and `-n`, built by `KubeCommands`. A tab's pinned context is a separate small file of Overterm's that holds no secret (3.11).
8. **Overterm installs nothing into a cluster.** That means no metrics stack, no operator and no agent. Node shells and debug containers are the user's explicit commands, run in a tab, on writable contexts only.
9. **Secrets:**
   - Lists never carry Secret values. The Table gives Name, Type, Data (a count of keys) and Age. The embedded metadata has no keys, and the `last-applied-configuration` annotation, which can hold every value, is dropped as rows are decoded.
   - A Secret's keys and values come together: one GET returns every value at once. It is made only when the user asks to see that Secret (Show). On production, the first Show per context and session asks once, naming the context.
   - The response lives only in that detail's memory. The keys are listed with every value masked, and each value is revealed one by one. Everything is dropped on navigation.
   - Values are never written to disk, a log or the history, never put in a brief, never given to an agent, and never cached across details or windows.
   - Copying a value is an explicit action.
   - A database password taken for a forward (3.8) keeps only that key's value, and it goes straight to the keychain.
   - Helm's `config` and the Secrets in a release's manifest are masked the same way.
   - Env values whose names look secret are masked. Values that come from `secretKeyRef` are named and never fetched.
   - Logs and shell output handed to agents are scrubbed with the shared Secrets helper, which also covers bearer tokens, PEM blocks, AWS keys and kubeconfig `token:` and `client-key-data:` fields.
10. **Agents:**
    - The default is read-only.
    - Write tools exist only on writable contexts that `kubernetes.agentWrites` names, and every call is confirmed. They are listed while it names any context (MCP's tool list isn't announced again, so an agent started before needs a restart); each call is refused where the context isn't writable for agents.
    - On production there are no write tools unless writes are on for the session and `kubernetes.agentWrites` names that context. `k8s_apply` also needs `applyOnProduction`.
    - There is no tool for Secrets.
    - An agent in a terminal still has its own kubectl and the user's credentials, and Overterm cannot take those away. The pinned tab context (3.11) and the warnings are the guard there. Overterm's tools claim only what the proxy enforces.
11. **The socket:**
    - It lives in a 0700 folder under `AppEnvironment.supportDirectory` (`Kubernetes/Sockets`), named by a short hash of the context, with a path under 104 bytes.
    - It is a credential for the cluster for any process running as the same user. That is why a read-only context's socket cannot write, and why no socket reaches exec, attach, port-forward or the proxy subresources (rule 1).
    - It is removed at quit.
    - A proxy that is idle for `kubernetes.proxyIdleMinutes` (default 10) is closed.
12. **Isolated runs never see the user's kubeconfig.** Under `OVERTERM_E2E` or `OVERTERM_DUMP_LAYOUT`, `AppEnvironment.kubeconfigs` returns only `OVERTERM_KUBECONFIG`'s file. Without it there are no contexts. The loader refuses `~/.kube/config` and an inherited `KUBECONFIG` in an isolated run, and kubectl processes get `KUBECONFIG` set to that file explicitly (Section 11).
13. **No telemetry.** Nothing about a cluster leaves the machine, except what an agent the user started receives through the tools.

## 6. Interface

### Two layers (as Docker has)

| Layer | When | What |
|---|---|---|
| **The Kubernetes page** (⌥⌘J) | Exploring and managing | A page over the body (`WorkspaceOverlay.kubernetes`). Left: the context card (class, authentication, who-am-I, the production band, "Allow writes until quit" on production, "Terminal in this context"), the sections. Middle: the `ResourceTable`, the namespace chip beside its filter field. Right: the detail. Bottom: the context bar (server version, proxy state, errors with their buttons) |
| **The rail panel** (`SidebarPanel.kubernetes`) | While working on a checkout (stage 3a, with the binding) | The bound namespace or release: its workloads and pods with status, forwards, the last deploy against the checkout's commit. A pod picked shows its logs or detail in the right slot, beside the terminal. It reads only while it is the panel on screen (`SidebarModel`), as Overgit does |

**Sections on the page** (`1`–`9` while a Kubernetes list has the keyboard, as Docker's `1`–`6`):
1. Overview: health, warnings, the lint count.
2. Workloads: Pods, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, HPAs.
3. Network: Services, Endpoints/Slices, Ingresses, Gateway API, NetworkPolicies.
4. Config: ConfigMaps, Secrets, Quotas, LimitRanges, PDBs, PriorityClasses, webhooks.
5. Storage: PVCs, PVs, StorageClasses.
6. Cluster: Nodes, Namespaces, Events, RBAC, API resources.
7. Custom resources, grouped by API group.
8. Helm.
9. Forwards.

`:` reaches any kind directly. In stage 1a only Workloads' Pods exists; the others appear as their stage lands (every kind in 1b, Forwards in 1d, Helm in 2c, Overview in 2d).

**Detail tabs:**
- **Overview:**
  - status and conditions;
  - for pods, "why it isn't running" first;
  - the dependency tree (3.7);
  - containers with state, ports (a press forwards), env, mounts, probes;
  - for workloads, rollout status and revisions;
  - for a Secret, its type and key count, and Show (rule 9).
  - Kinds without a tailored Overview (Section 2) get metadata, conditions, owner and events.
- **Logs**: per container, previous, merged for workloads.
- **Events.**
- **YAML**: read-only here, stripped by default, a Secret's values and `last-applied-configuration` masked; `y`, or "Edit", opens it in the editor.
- **Metrics**: when available.
- **History**: the timeline from 3.6.
- **Helm**: for a release; values masked.

All read only while shown, as `ContainerSession` does.

**The right slot.** A pod, its logs or a forward shown from the rail panel joins `RightSlot` as `DockerSlotView` does. It never adds a column.

**Terminal tabs** are the third place: "Terminal in this context", shells, `logs -f`, `debug`, `drain`, `helm`, `rollout undo`. A new tab goes through `addTab` and `NewTabGroup.placement`, and the tab is placed by the checkout's binding when there is one. A shell tab gets a `TabKind` of its own (a pod). Closing a tab with a running forward asks, through `needsCloseConfirmation`.

### Following the Docker page, and what gets generalised

Each of these is a separate PATCH commit before Kubernetes uses it: stage 0, decision 13.

| Docker today | Generalised as | Used by Kubernetes for |
|---|---|---|
| `NIODockerTransport` (Host `docker`, `/_ping`) | `UnixHTTPTransport` (Host a parameter) | The proxy's socket |
| `DockerSSHForward`, `SSHTunnel` | `ManagedProcess` / `SocketForward` (spawn, readiness, the reason from stderr, reopened on next use, `closeAll`, tracked by pid) | `kubectl proxy`, `kubectl port-forward` |
| `AgentUsageCommand.askTheShell` (a path) | `ShellEnvironment` (the whole environment, once) | kubectl's exec plugins |
| `DockerContainerTable` | `ResourceTable<Row>`: columns, grouping, sort, selection, verb menu | Every list, with the server's columns |
| `DockerVerb`, `DockerActionBar`, `DockerVerbMenu` | `ResourceVerb` (unchanged, moved) | Buttons, menus, the reason a verb is unavailable |
| `DockerKey`, `handleDockerKey` | `ResourceKey` tables plus one dispatch path for "a page's list has the keyboard" | Single-letter keys and the section digits |
| `DockerFilter` | A filter parser generic over a key enum plus aliases; matching per model | `ns:`, `status:`, `label:`, `node:`, `owner:`, `restarts:>3`; selectors sent to the server |
| `DockerLogFeed`, `DockerLogFollower`, `DockerTextView`, `DockerLogStyle` | `LogFeed`, `LogFollower`, `LogTextView` | Pod and merged logs |
| `DockerSecrets` | `Secrets` (plus base64, kubeconfig, AWS patterns) | Masking and scrubbing |
| `DockerFileCopy`, `hookDockerSaves` | `RemoteFileCopy` (fetch, conflict check, write back, refusal) | Edit YAML, then apply |
| `DockerMCP.allow`, `DatabaseMCP.allow` | `MCPConfirmation` (context and namespace in the title, production flagged) | Confirmed writes |
| `BrowserMCP`'s prefix branches | A table of tool groups and their gates | `k8s_` |
| `makeOverlay`, page visibility, palette scope in `+Docker` | A protocol for workspace pages | The second page |
| `DockerAgentBrief`, `DockerAttention` | `AgentBrief`, `Attention` (the brief's shape, the mark, Ask Why) | Ask Why, attention marks |
| `FakeDockerEngine` | — (a pattern) | `FakeKubeAPI` |

### Keyboard first

- Everything can be done from the keyboard: `:` for the kind, `/` to filter, `n` and `c` for namespace and context, the digits for sections, single-letter verbs, ⌃⌘J for the switcher.
- The mouse works too: right-click is the verb menu, and a double-click opens the detail.
- The list keeps its place in the view tree, so selection, scroll and the keyboard survive updates and section switches (the Docker page's lesson).

## 7. Shortcuts

Shortcuts follow Docker's letters: the same letter means the same thing. k9s's `:`, `/`, `[` and `]` are kept.

### Global (proposed)

Checked against `KeyCommands.all` (`Sources/Overterm/Settings/Keybindings.swift`) and Ghostty v1.3.1's defaults (`vendor/ghostty/src/config/Config.zig`). Both land in stage 1a.

| Shortcut | Command | Status |
|---|---|---|
| ⌥⌘J | The Kubernetes page, open or close (`kubernetes.page`) | **Free**: not in `KeyCommands` or `MainMenu`, not a Ghostty default. Ghostty binds ⌘J (`scroll_to_selection`), ⇧⌘J, ⌥⇧⌘J and ⌃⇧⌘J (`write_screen_file`) |
| ⌃⌘J | Go to Kubernetes: a pod, workload, service or context by name (`kubernetes.switch`) | **Free**: `KeyCommands`' ⌃⌘ keys are B, F, G, I, N, S, 1–9 and =; Ghostty's ⌃⌘ defaults are only [ and ] (and ⌃⇧⌘J); macOS reserves none for J |
| — | Switch context, switch namespace, Terminal in this context, restart this checkout's workload | Palette and menu; the user can bind them |
| ⌘K | Kubernetes entries in the palette | The existing palette |

**⇧⌥⌘J is not available**: it is Ghostty's `write_screen_file:open`, which Ghostty takes before the menu does. Docker's pattern (⌥⌘P page, ⇧⌥⌘P switcher) therefore cannot be copied.

Both new shortcuts are `KeyCommands` entries, with `MainMenu.command(…, id)` for their menu items.

⌥⌘K is taken (Notes' Graph View). The other ⌥⌘ letters in use are B, C, D, G, H, N, O, P, R, T, U and X, plus ⇧⌥⌘P. ⌥⌘I is Ghostty's inspector. ⌥⌘C is New Claude Tab, so Copy as kubectl is a letter (`k`), not ⌥⌘C.

**Sections are plain digits, not ⌃1–⌃9.** ⌃1–⌃9 are in neither `KeyCommands` nor Ghostty's macOS defaults (Ghostty's `goto_tab` is on ⌘). But `Keybindings.swift` already moved the group shortcuts off ⌃1–⌃9 because ⌃2 and ⌃6 are control characters a terminal must pass through. macOS's Mission Control can also claim ⌃1–⌃9 for desktops. So the page follows Docker: `1`–`9` while a Kubernetes list has the keyboard, never as menu shortcuts. k9s's digits pick favourite namespaces; ours are in the `n` picker.

In the switcher, ↩ shows the object on the page, ⌥↩ opens a shell or logs, ⌘↩ follows logs in a tab, and ⌘O opens its forward. Each works once its verb's stage has landed.

### While a Kubernetes list has the keyboard

Each key lands with its verb's stage; the last column says which.

| Key | Action | Docker's meaning | Stage |
|---|---|---|---|
| ↑ ↓, ← → | Move; open or close a group | same | 1a |
| ↩ | Detail (logs for a pod, from 1c) | same | 1a |
| Space | Quick look: status, the reason, last log lines | same | 1a |
| `1`–`9` | Sections (Section 6) | same (`1`–`6`) | 1a |
| `[` / `]` | Back / forward in the detail's history (k9s's) | — | 1b |
| `l` | Logs | same | 1c |
| `t` | Follow logs in a tab (`kubectl logs -f`) | same | 1d |
| `e` | Shell in a tab (`kubectl exec -it`) | same | 1d |
| `E` | Debug container in a tab (`kubectl debug`) | — | 2a |
| `A` | Attach in a tab | — | 1d |
| `i` | YAML (inspect) | same | 1b |
| `y` | Edit the YAML in the editor | — | 2b |
| `f` | Port-forward | Docker: files (decision 10) | 1d |
| `o` | Open: a forward in the browser column, an Ingress in the default browser | same | 1b / 1d |
| `d` | Database client (via a forward) | same | 1d |
| `a` | Ask Agent (Ask Why) | same | 1e |
| `r` | Rollout restart; on a pod, delete it to recreate (asked) | same idea | 2a |
| `+` / `-` | Scale by one; `=` for a number | — | 2a |
| `p` | Pause or resume a Deployment's rollout; suspend or resume a CronJob (the object read decides which) | same (pause or unpause) | 2a |
| `s` | Trigger a CronJob now (`kubectl create job --from`) | same idea (start) | 2a |
| `u` | Cordon or uncordon a node | Docker: compose Up — the exception, below | 2a |
| `N` | New namespace (a sheet for its name) | — | 2a |
| `x` | Dependency tree | — | 3b |
| `h` | History (change timeline) | — | 3b |
| `w` | Wide columns (`priority > 0`) | — | 1a |
| `k` | Copy as kubectl | — | 1b |
| ⌫ | Delete (asked; typed name on production) | same | 2a |
| `:` | Command mode | — | 1b |
| `/` | Filter: text (1a); `ns:`, `status:`, `label:app=web`, `field:spec.nodeName=…`, `node:`, `owner:deploy/api`, `restarts:>3`, `-status:Running` (1b) | same | 1a / 1b |
| `n` / `c` | Namespace picker / context picker | — | 1a |
| `0` | All namespaces (paged) | — | 1a |
| ⌘A, ⇧↑/↓ | Bulk selection | same | 1b |
| ⌘C | Copy the name | same | 1a |
| `?` | This table | same | 1a |

**`u` is the one letter that means something else.** Docker's `u` is a Compose project's Up, which has no Kubernetes counterpart, while cordon has no Docker one; `u` is k9s's uncordon (k9s's cordon, `c`, is our context picker), and here it toggles. The other free letters say nothing of a node.

**Command mode grammar** (k9s's):
- `:<kind>[ <namespace>][ /<filter>][ <label=value,…>][ @<context>]`
- Examples: `:po globex /api app=web @globex-eu-west-1-dev`, `:deploy`, `:svc`, `:certificates`.
- `:ctx` and `:ns` switch context and namespace.
- Kinds and short names come from discovery, aliases from k9s's set. A completion list follows the typing.

## 8. Integration points in Overterm

From the read-only survey of `main` at `d62c5c4`.

| Where | File | What Kubernetes adds |
|---|---|---|
| Transport | `Sources/Overterm/Docker/DockerEngine.swift` (`NIODockerTransport`, Host hard-coded at ~104) | Extract `UnixHTTPTransport` |
| Processes | `Sources/Overterm/Docker/DockerSSH.swift`, `Sources/Overterm/Database/SSHTunnel.swift` (+ `Tests/OvertermTests/SSHTunnelTests.swift`) | `ManagedProcess`; `KubeProxy` (main and metrics), `KubePortForward` with arguments built by pure functions; the class check that refuses writing processes |
| Shell environment | `Sources/Overterm/Usage/AgentUsageCommand.swift`; `Sources/Overterm/Docker/DockerCLI.swift` (finding a CLI, `lines()`) | `ShellEnvironment`; `KubectlCLI`, `HelmCLI` |
| Page | `Sources/Overterm/Docker/DockerPageModel.swift` (+Verbs, +Resources), `DockerPageView.swift` | `KubernetesPageModel` (sections, context, namespaces), `KubernetesPageView` |
| Table | `Sources/Overterm/Docker/DockerContainerTable.swift`, `DockerRows.swift` | `ResourceTable` over Table rows |
| Verbs | `Sources/Overterm/Docker/DockerVerbs.swift` | `ResourceVerb`; `KubernetesPageModel+Verbs` |
| Keys | `Sources/Overterm/Docker/DockerKeys.swift`; `TerminalWindowController+Docker.swift` (`installDockerKeys`, `handleDockerKey`, `dockerListHasKeyboard`, ~574–605) | `ResourceKey`; one dispatch path |
| Filter | `Sources/Overterm/Docker/DockerFilter.swift` | Generic parser; `KubeFilter` keys and server-side selectors |
| Model | `Sources/Overterm/Docker/DockerModel.swift`, `DockerModels.swift`, `DockerUsageMonitor` | `KubernetesModel` (app-wide), a `KubeContextSession` per context (proxy, discovery, watches, reviews), `KubeMetricsMonitor` |
| Detail | `Sources/Overterm/Docker/ContainerSession.swift`, `ContainerDetailView.swift`, `ContainerPanes.swift` | `PodSession`, `ResourceDetailView`, `SecretSession` (Show, masked values, dropped on navigation) |
| Logs | `Sources/Overterm/Docker/DockerLogFeed.swift`, `DockerLogFollower`, `DockerLogView.swift`, `DockerTextView` | `LogFeed`, `LogTextView`; `KubeLogFollower` (sinceTime resume), `MergedLogs` |
| Secrets | `Sources/Overterm/Docker/DockerStats.swift:157` (`DockerSecrets`) | `Secrets` |
| Editor round trip | `TerminalWindowController+Docker.swift` (`openDockerFile`, `hookDockerSaves`, `saveDockerFile`, `showDockerReadCopy`); `Sources/Overterm/Docker/DockerFiles.swift:132` (`DockerFileCopy`); `Sources/Overterm/Editor/EditorViewController.swift`, `EditorBuffer.swift` | `RemoteFileCopy`; `KubeResourceCopy` (fetch, dry-run, diff, apply); possibly `EditorViewController+Kubernetes` for an Apply bar |
| Diff | `Sources/Overterm/Diff/` (the changes pane) | Dry-run, revision and cross-context diffs |
| Review tabs | `Sources/Overterm/Review/ReviewSource.swift` | "Deployed…current" range |
| MCP | `Sources/Overterm/Docker/DockerMCP.swift`, `Sources/Overterm/Database/DatabaseMCP.swift`, `Sources/Overterm/Browser/BrowserMCP.swift` (`handle`), `BrowserBridge.swift` | `MCPConfirmation`; `KubernetesMCP` (`k8s_`) |
| Agents | `Sources/Overterm/Docker/DockerAgentBrief.swift`, `DockerAttention.swift`; `Sources/Overterm/AskAgent/AskAgentModel.swift` | `KubeAgentBrief`, `KubeAttention` |
| Rail and right slot | `Sources/Overterm/Docker/DockerPanelView.swift` (`DockerPanelModel`, `DockerSlotView`); `Sources/Overterm/Sidebar/SidebarView.swift:65` (`SidebarPanel`); `Sources/Overterm/Window/TerminalWindowController+Browser.swift:15` (`RightSlot`) | `SidebarPanel.kubernetes`, `KubernetesPanelView`, `KubeSlotView` |
| Page over the body | `Sources/Overterm/Tabs/WorkspaceOverlay.swift`; `toggleDockerPage`, `makeOverlay` (`+Docker` ~494–521) | `WorkspaceOverlay.kubernetes`; `TerminalWindowController+Kubernetes.swift` |
| Commands in tabs | `Sources/Overterm/Docker/DockerCommands.swift`; `runDockerCommand(_:in:)` | `KubeCommands`: `--context` and `-n` always, quoted; refuses writing commands on read-only contexts; in scenarios, a command typed into a tab is recorded, not typed. "Terminal in this context" sets the tab's `KUBECONFIG` and folder |
| Ports | `Sources/Overterm/Info/ListeningPorts.swift`; `Sources/Overterm/Splits/PaneHeaderView.swift:74`; `Info/TabInfoModel.swift` | A `forward` origin; pills; Tab Info's forwards and kubectl children |
| Browser | `Sources/Overterm/Browser/BrowserLinks.swift`; `openDockerLink` | Forwards in the browser column |
| API client | `Sources/Overterm/API/APIDiscovery.swift` (`probeServers`) | A forward's port probed for an OpenAPI document |
| Database | `Sources/Overterm/Database/DatabaseConnection.swift` (`KeychainDatabaseSecrets`), `Sources/Overterm/Docker/DockerDatabaseGuess.swift` | A connection from a forwarded database pod |
| Palette | `Sources/Overterm/Palette/PaletteModel.swift`; `dockerPaletteItems`, `showDockerSwitcher` | A `.kubernetes` scope; the ⌃⌘J switcher |
| Settings | `Sources/Overterm/Settings/SettingsSchema.swift` (Docker's block ~474–516) | A `.kubernetes` section (below), and an object value kind for `contexts` |
| Shortcuts | `Sources/Overterm/Settings/Keybindings.swift:238` (`KeyCommands.all`); `MainMenu.command(…, id)` | `kubernetes.page`, `kubernetes.switch` |
| Command awareness | `Sources/Overterm/Blocks/CommandLedger.swift`; `Sources/Overterm/Sidebar/DirectoryWatcher.swift` | The production warning in the pane header; the watched kubeconfig files |
| New Task | `Sources/Overterm/Tasks/` | Pinning the agent's tab to the bound context |
| Environment | `Sources/Overterm/AppEnvironment.swift` (~136–143, `OVERTERM_DOCKER_HOST`) | `OVERTERM_KUBECONFIG` and `kubeconfigs`; the socket folder; the bindings, pinned-context and saved-filter files, all under `supportDirectory` |
| Tests | `Sources/Overterm/Docker/FakeDockerEngine.swift`; `Sources/Overterm/E2E/E2ERunner+Docker.swift` (~3161); `E2ERunner.swift` scenario table | `FakeKubeAPI`; a stand-in kubectl for port-forwards; `E2ERunner+Kubernetes.swift` |

**Settings** (`kubernetes.*`, matching `docker.*`, each a `SettingsSchema` entry):
- `enabled` (default on; nothing runs until the page or the rail panel opens)
- `kubeconfigs` (files and folders)
- `kubectlPath`
- `helmPath`
- `productionPattern`
- `contexts`: one entry per context name, the only place a context's own settings live. `SettingsSchema`'s values are bool, int, double, string and list today, so this adds an object kind, keyed by context name, with its validation (stage 1a). Fields:
  - `class` (`production`, `remote` or `local`; unset means by name), `writable` (ignored on production, rule 2), `colour`, `displayName`;
  - `defaultNamespace`, `accessibleNamespaces` (when set, the namespace list is never asked for), `favouriteNamespaces`;
  - `kubectl` (a path for this context), `terminalDirectory`;
  - `metrics` (`auto`, `metricsServer`, `prometheus` or `none`; `none` skips the metrics check), `prometheus` (namespace, service, port; stage 4);
  - `debugImage`, `nodeShellImage`, `nodeShell` (default off), `shells` (default on);
  - `applyOnProduction` (default off; production only, and only while writes are on for the session).
- `pinnedContexts` (a list)
- `agentAccess` (default on, reads)
- `agentWrites` (default empty: the contexts where agents get write tools, when the context is writable)
- `debugImage` (default `busybox:1.36`; also the node shell's image when a context names none)
- `logStreams` (default 10)
- `proxyIdleMinutes` (default 10)
- `maxProxies` (default 4, one kept for the page)
- `backgroundWatches` (default 4 bound namespaces)
- `notifyOnFailure`

Out on purpose: a per-context icon and an OpenShift Prometheus token (2.1). A production context's writes are not a setting: they are turned on for the session from the context card.

Never read from UserDefaults. State that is not a setting lives under `AppEnvironment.supportDirectory`: bindings (`Kubernetes/bindings.json`), pinned-context files (`Kubernetes/Contexts`), saved filters (`Kubernetes/filters.json`) and sockets (`Kubernetes/Sockets`).

**The CLAUDE.md rules that bind this work:**
- A panel reads nothing while it is not on screen. The attention watches are the one stated exception, with a budget (3.13).
- Long-running subprocesses use GCD threads in the style of `Git.run`, never a blocked Swift-concurrency thread.
- NIO callbacks are built in a `nonisolated` context, and a block for a queue is spelled `@Sendable () -> Void`.
- `@Published` emits before the property changes; use `dropFirst()` when only a change should act.
- `Text(verbatim:)` for restarts, ports and pids.
- No `lazy.compactMap(…).first` over live pod state.
- `tab.terminals` for whole-tab work.
- Never `pkill -f` in tests.
- `pressReturn()` after `insertText`.
- Closing a tab with a running forward asks, through `needsCloseConfirmation`.
- `clipsToBounds`, and fill `dirtyRect ∩ bounds`.
- `ChromeTheme` is per window.
- Isolated runs go through `AppEnvironment` for every piece of persistent state.
- A new setting is a `SettingsSchema` entry; a new shortcut is a `KeyCommands` entry.
- Never walk up directories comparing paths with "/".
- Built in, no plugin slots.
- Never synthetic input.
- Tests are part of the change.
- Each commit is `area: subject` with a VERSION bump.

## 9. Stages

All of them are built; Section 15 says where the build departs from this plan. Each stage is usable on its own and has its own E2E check. Security comes first: the proxy flags are in 1a, before any verb exists. Every write ships with its permission check and confirmation, and every writing process with its class check.

| Stage | Scope | Useful alone because | Check | Bump |
|---|---|---|---|---|
| **0. Groundwork** | The extractions in Section 6's table, each its own commit with no change in behaviour. `FakeKubeAPI` and the real-proxy test harness | Docker is unchanged | Docker's tests and scenario pass, `make test && make e2e` | PATCH each |
| **1a. Contexts and pods** | Kubeconfigs (merged, extra files, isolated-run guard). Classes with their precedence, the production pattern. The `contexts` object setting, `pinnedContexts`. The proxy's lifecycle with its flags, the socket folder, `maxProxies` with the page's slot, idle close, oidc one at a time. The shell environment, `interactiveMode` handling, errors with buttons. Who-am-I, which kubectl. Discovery. The namespace and context pickers (`n`, `c`). The Pods list (Table plus watch, exit reasons). The production band. ⌥⌘J, the ⌃⌘J switcher (contexts, namespaces, pods), the key dispatch path with the section digits, `/` (text), `w`, `0` and `?` | "Which pods are failing on dev?" without a terminal, and nothing can write | `kubernetes`: the page opens, pods list, a crashing pod's reason, the `fake-prod` band, `fake-dev` read-only although its server is 127.0.0.1; `n`, `c` and `/` work; no write method or listed subresource reaches the fake | MINOR |
| **1b. Every kind** | Generic Tables for every kind and CRD, CRD re-discovery. Detail: tailored Overviews, YAML (stripped), Events, back and forward. Secrets: Show, masked values, one revealed at a time; TLS certificate info. `:`, `/` with server selectors, the palette, Copy as kubectl (`k`), CSV, rollout status | The whole cluster is browsable | `:deploy`, a CRD; a Secret shown with its values masked, one revealed, all dropped on navigation, and no value in any log | MINOR |
| **1c. Logs** | Container and default container, previous, timestamps, since, follow with resume, search, newest first, save, ⌘L, `l` | The most-used view after the list | Logs follow, resume without duplicates | MINOR |
| **1d. Tabs and forwards** | First, the `KUBECONFIG` merge-order check (3.11). Terminal in this context. Shell, attach and `logs -f` in tabs through `KubeCommands`, checked with `kubectl auth can-i`; the production shell confirmation; the process class check. Port-forwards: managed, re-resolved, pills, Tab Info, the Forwards section, the browser column, the API-client probe, the Database link. `t`, `e`, `A`, `f`, `o`, `d` | Replaces most daily `kubectl` typing | `e` and `t` recorded, not typed. A forward through the stand-in kubectl restarts on the new pod after the old one goes (Section 11). A Terminal in this context tab's `KUBECONFIG` checked | MINOR |
| **1e. Agents, reading** | `k8s_` read tools. Ask Why (the brief, to the selected tab's agent), `a` | Agents can diagnose without "run any kubectl" | The brief is scrubbed; a read tool on `fake-prod` works and a write is impossible | MINOR |
| **2a. Writes** | Writable contexts: the `writable` flag, production's session switch, the proxy restarted without the method filter. Each verb with its access review, confirmation and typed name: delete, force delete, finalizers, evict, rollout restart, scale, pause and resume, CronJob trigger, suspend and resume, cordon, namespace create and delete. Drain, rollback and debug in a tab, refused on read-only contexts. `k8s_` write tools | The first time Overterm changes a cluster, with every guard in place | A write on `kind-fake` is confirmed and lands; on `fake-prod` it is unavailable until the session switch, then asks for the typed name; drain is refused on `fake-dev` | MINOR, then PATCH per further verb |
| **2b. Editor apply and manifest diff** | YAML edited in the editor; dry-run diff (or client-side, labelled); owners shown; apply; 409 handling; apply off on production unless `applyOnProduction`. "Diff with cluster" for a manifest or kustomization in the checkout | One path for both | A diff with masked Secret data; a 409 conflict shown; no Apply on `fake-prod` with writes on | MINOR |
| **2c. Helm, reading** | Releases (Secret and ConfigMap storage), history, values and manifest masked, notes | Releases without `helm` in a terminal | A release's values masked; a forbidden Secret list degrades | MINOR |
| **2d. Metrics and overview** | metrics.k8s.io columns, polled while shown, with ages. The Overview section, workload counts, Applications grouping, cluster warnings. The context's `metrics` setting (`none` skips the check) | Load and health at a glance | Columns with a dash when metrics-server is absent | MINOR |
| **2e. Merged logs** | stern's merge, the cap, new pods joined, include and exclude regexes | A Deployment's logs as one | Two pods merged on timestamps | MINOR |
| **2f. Helm writes** | Rollback to a chosen revision and uninstall, in a tab with `--kube-context` and `-n`. Refused on read-only contexts; typed name on production for rollback, on every class for uninstall | Fixing a bad release without leaving the page | Both recorded, not typed, on `kind-fake`; refused on `fake-dev`; typed name asked on `fake-prod` with writes on | MINOR |
| **3a. The checkout** | Bindings (3.1). The rail panel and the right slot. Attention marks within their budget, pods and Deployments (3.13). The deployed commit (3.2). Helm upgrade and `helm template` diff from the checkout's chart | The cluster joined to the work | A bound checkout's tab marked on a crash and on a stuck rollout; the rail reads nothing while hidden; a background proxy closed when the page needs its slot | MINOR |
| **3b. Depth** | The change timeline (3.6), the dependency tree (3.7), health checks (3.9), diff across contexts (3.10), revision diffs. The pane-header warning and New Task pinning (3.11). Templates, Argo and Flux trees, Kubernetes snippets, saved filters, a health view across pinned contexts, node shell, in-place resize | Each item ships alone | One scenario check per item | MINOR each |
| **4. Optional** | Prometheus per context, through its own proxy: charts with a time range, PVC usage, the Overview's requests and limits against allocatable (2.1). Flux and Argo verbs. The cluster's API docs in the editor (3.15). Pod files (`kubectl cp` in a tab). Scan and Run locally on the Docker page (3.12). Streaming lists where the server supports them | — | — | MINOR each |

## 10. Performance and reliability at scale

- **Only the visible is read.**
  - One watch per visible section and namespace set, closed when hidden.
  - The page closed and the rail panel hidden means no watches, except the attention watches within their budget (3.13).
  - Metrics are polled only while their column shows.
  - Discovery is read once per context, then again on a CRD event, a 404, or every 5 minutes while the page shows.
  - The `performance` scenario's idle-CPU budget must hold with the page open on a quiet fake cluster.
- **Large clusters** (globex has thousands of pods):
  - The default is the context's namespace; "all" is paged with `limit=500` and Table plus Metadata.
  - Selectors from the filter are sent to the server.
  - Rows are kept only for the visible section; a detail fetches one object.
  - Many CRDs cost nothing until their kind is opened, because discovery does not open watches.
- **Coalescing:**
  - Watch events are decoded on a background queue and applied in batches every 120 ms (Docker's burst coalescing).
  - The table updates rows by uid, not by reloading.
  - Ages are recomputed once a second for visible rows only.
- **Tables:** NSTableView of hosted rows (the container table's lesson: a SwiftUI list of thousands of rows doesn't scroll).
  - The `kubernetesPerf` scenario measures 5,000 pods: first draw, a burst of 500 events, scroll.
- **Logs:**
  - Keep 5,000 lines. A noisy pod is throttled on drawing, not on reading.
  - Merged logs are capped at `logStreams` and say so.
  - Follow streams reconnect with `sinceTime` and remove duplicate lines.
- **Failures:**
  - **Proxy died:** reopened on the next use, with backoff (Docker's SSH forward pattern).
  - **Auth failure:** stop requesting and show the button. No retry storm, because every request may run `aws` again.
  - **410 (in-stream or HTTP), or an expired `continue`:** list again.
  - **Watch timeout:** watch again from the last resourceVersion.
  - **429:** `Retry-After`.
  - **VPN down or sleep:** watches marked stale with their age, resumed on wake or when the network comes back. Never show a stale count as current.
- **Connections:** streams on dedicated connections with a cap per context; requests on their own bounded pool (Section 4).
- **Processes:**
  - The proxy is closed after `proxyIdleMinutes`. At most `maxProxies` are alive, one kept for the page's context; background proxies are evicted first.
  - The metrics proxy runs only while a chart shows.
  - Forwards are closed at quit (`closeAll`) and tracked by pid, never by pattern.
  - oidc proxies start one at a time.
- **The main thread does nothing slow:** NIO on its event loop, kubectl through GCD threads, Helm decoding on a background queue with a size cap.

## 11. Tests

**Tests never reach the user's clusters.** The Docker rule applies, and matters more here, since the default context is production.

- An isolated run (`OVERTERM_E2E`, `OVERTERM_DUMP_LAYOUT`) sees no kubeconfig unless `OVERTERM_KUBECONFIG` names one. `AppEnvironment.kubeconfigs` is the only place the list is built.
- The kubeconfig loader refuses `~/.kube/config`, the user's `kubernetes.kubeconfigs` and an inherited `KUBECONFIG` when `AppEnvironment.isIsolated`. Without `OVERTERM_KUBECONFIG` there are no contexts, so no proxy can start.
- Every kubectl a test starts gets `KUBECONFIG` set explicitly to a temporary file, `--cache-dir` set to a temporary folder, and no inherited `AWS_*`.
- A unit test asserts that the environment builder never passes `~/.kube/config` in isolated runs, and that the loader returns nothing there without `OVERTERM_KUBECONFIG`.
- Every command a scenario would type into a tab that reaches `kubectl` or `helm` is recorded, not typed (`KubeCommands`), as Docker's are. Managed processes (the proxy, port-forwards) are not typed into anything. The proxy is the real kubectl against the fake; port-forwards use the stand-in below.
- Proxy and kubectl processes are killed by the exact pids Overterm started, never by pattern (CLAUDE.md).

**Pure parts, unit-tested:**
- merging kubeconfigs (first file wins); classes, their precedence and the production pattern (this Mac's five names; `fake-prod`, `kind-fake` and `fake-dev` on 127.0.0.1; `kind-prod-copy`); the proxy's flags per class; socket names under 104 bytes;
- the process class check: every process verb against every class (Section 5's table);
- the Table reader (headers kept from the first watch event, priorities, the Metadata embedding, the List fallback, a Secret row's `last-applied-configuration` dropped);
- watch event handling: in-stream 410, bookmarks, timeouts, an expired `continue`;
- the background budget: two watches per bound namespace, `backgroundWatches`, the page's proxy slot kept, the least recently used background proxy evicted;
- the log merge on timestamps, removing duplicates on resume, the default container;
- the filter grammar and the selectors it sends; the `:` grammar;
- Helm decoding (double base64, the gzip and plain-JSON variants, the size cap, masking);
- masking in Secret, Helm and diff output (`***` before and after); a Secret session's values dropped on navigation;
- dry-run diff stripping; port-forward target resolution and arguments; drain arguments; Copy as kubectl;
- the forward restart logic: resolve, start, exit, resolve again to the new pod, with backoff, and a stop after repeated failures;
- binding guesses from checkout files; the deployed-commit sources in order; lint checks; the pinned context file and the tab's `KUBECONFIG`;
- the context resolution behind the pane-header warning (flags, pinned, files, "probably");
- the exec-plugin error mapping ("Token has expired" → SSO button; 500 `text/plain` → transport);
- the metrics proxy's `--accept-paths`, with a namespace and service name that need escaping.

**`FakeKubeAPI`**, written with NIO on a unix socket and TCP:
- it serves:
  - aggregated and legacy discovery;
  - Table and JSON lists with `limit` and `continue` (and an expired `continue`);
  - watches with bookmarks, in-stream 410 and timeouts;
  - logs with follow, previous, timestamps and sinceTime, and a 400 without `container`;
  - events;
  - who-am-I, permission reviews and 403s;
  - writes (delete, scale, patch, apply with a 409 conflict, dry-run);
  - metrics;
  - Helm release Secrets and ConfigMaps;
  - Secrets whose Table has only the key count, one with a `last-applied-configuration` annotation;
  - an object without Table support (406);
- it records every request it receives, so a test can assert that one never arrived;
- it has no exec, attach or port-forward upgrade;
- it uses values, not mocks, and sends events when its state changes, as `FakeDockerEngine` does.

**A real kubectl proxy against the fake.** A temporary kubeconfig points at `http://127.0.0.1:<port>` and the proxy runs on a temporary socket. This checks, with real kubectl and without touching the user's file:
- the Host header (a wrong one gets 403);
- the default reject paths;
- our flags: no write method reaches the fake on a read-only context, and no exec, attach, port-forward, pod, service or node proxy path reaches it on either kind, sent with path variants (`//api/…`, `/./`, `%2F`);
- the metrics proxy: one service's query path passes, another service's gets 403;
- the 500 text from a failing exec plugin, using a fake plugin script that prints an ExecCredential, expires, then fails;
- stream pass-through.

These tests skip if no kubectl is found.

**A stand-in kubectl for forwards.** The fake cannot serve a port-forward, so a real `kubectl port-forward` cannot run against it. The isolated run's `kubernetes.kubectlPath` points at a stand-in script:
- it hands `proxy`, `auth` and `version` to the real kubectl;
- it answers `port-forward pod/<p> L:R` itself: it records its arguments, listens on L, and stays up until it is ended.

The scenario starts a forward to a Service, deletes the pod in the fake, and ends the stand-in by its pid, as kubectl ends when its stream is lost. It then checks that Overterm resolved the Service again, started a second stand-in for the new pod, and that the pill names it. This tests Overterm's restart logic, not kubectl. Whether real kubectl exits when its pod goes is a spike item (Section 12).

**E2E scenarios:**
- `kubernetes`: the fake server through `OVERTERM_KUBECONFIG`, with three contexts on 127.0.0.1: `fake-prod` (production by name), `fake-dev` (remote) and `kind-fake` (local by name). One check per stage (Section 9).
  - ⌥⌘J opens the page; the digits switch sections; `n`, `c`, `/`; `:po` from 1b.
  - A crashing pod shows its reason.
  - Logs follow; a Secret is shown with its values masked, one is revealed, and all are dropped on navigation.
  - The production band shows on `fake-prod`, and its write verbs are greyed. `fake-dev` is read-only although its server is on 127.0.0.1. `kind-fake` is writable.
  - `e` and `t` are **recorded, not typed**: the command built is checked, never run against a cluster.
  - `f` runs through the stand-in kubectl, as above.
- `kubernetesPerf`: 5,000 pods.
- Layout checks through `OVERTERM_DUMP_LAYOUT`.

**Optional live tests** (`OVERTERM_KUBE_TESTS=1`, `KubeRealClusterTests`; docs/testing.md, Kubernetes):
- The fixture is a kind cluster started only for them: `Scripts/kube-test-cluster.sh create|delete|kubeconfig` (decision 8) — cluster `fake`, context `kind-fake`, its kubeconfig a file of its own (`--kubeconfig` on every kind command: kind writes into `~/.kube/config` otherwise), its node container labelled `overterm.test`.
- Only that file: a kubeconfig under `~/.kube`, or one whose one context isn't `kind-fake` on 127.0.0.1 or `::1`, is refused. A second file of the suite's own adds `fake-dev` (read-only) and plugin users over the same cluster; their tokens (ServiceAccounts', ten minutes) are in the plugin's environment, never on disk.
- They work in their own namespace (`overterm-test-<random>`, labelled `overterm.test`), which is deleted afterwards.
- What they check is Section 12's list: the method filter's answer, path variants, connect subresources, exec plugins' caching, a real `kubectl port-forward` whose pod is deleted, streaming lists with Tables, the metrics proxy against a real Service proxy path, a write on a writable socket, `can-i`, `KubeTree` and `KubeHealth` on real objects.

## 12. Risks

- **The socket is a credential.** Any process running as the user can reach it. The flags limit what it can do: no socket reaches exec, attach, port-forward or the proxy subresources, and a read-only one cannot write. A writable context's socket can still write whatever the user's RBAC allows. An agent's own kubectl is stronger still, which 3.11 only mitigates.
- **Process enforcement is Overterm's code, not the cluster's.** A writing kubectl or helm command on a read-only context is refused by `KubeCommands` and `ManagedProcess`. A bug there would run it with the user's full rights. The class-by-verb unit test is the lock.
- **"Terminal in this context" is the user's own kubectl.** It goes to the pinned context, but read-only does not apply inside it. The red band and the confirmation on production say so.
- **The proxy's unknowns, answered** against a real cluster — kind, Kubernetes **v1.37.0**, kubectl v1.36.1, 2026-11-07 (`KubeRealClusterTests`, `OVERTERM_KUBE_TESTS=1`; Section 4 has the detail):
  - *The method filter's answer:* kubectl's own 403, `text/plain; charset=utf-8`, `Forbidden\n`. It matches the method as sent: a lowercase or unknown method (`post`, `Delete`, `PROPFIND`) passed it to the apiserver, which said 405. **Fixed:** the read-only and metrics proxies now refuse every method but `GET`.
  - *Path variants:* none slips past. Encoded slashes and letters are decoded before the match; `//`, `/./` and `..` are redirected (307) to a path that is refused; a changed case is a path the server doesn't serve (404); trailing segments and queries are still the subresource.
  - *Connect subresources:* kind serves exactly the six the list names, and no aggregated API. The dev clusters' aggregated APIs are still to be listed; the suite fails on any new one where it runs.
  - *Failed exec calls:* not cached — the plugin runs again for every request, and a refused token (401) is asked for again too. A credential failure already stopped the context; **fixed:** a 401 on a plugin's context stops it as well.
  - *A forward whose pod goes:* kubectl doesn't exit while nothing connects; it exits (1, "lost connection to pod") at the next connection, which fails. Overterm's pod check while the page shows is what notices; hidden, the forward waits for a connection or the page.
  - *Streaming lists with Tables:* they combine, and end with the `k8s.io/initial-events-end` bookmark — on the Table's one row's object, which Overterm didn't read, so every streaming list fell back after 5 s. **Fixed** (`KubeWatchDecoder`); an empty list's end carries the columns. Not yet run on EKS 1.32/1.34+.
  - Also checked: the metrics proxy's `--accept-paths` against a real Service proxy path (only its query and query_range reach the Service), a write on a writable socket, `can-i` (yes for the admin, no with the server's reason for a ServiceAccount with no role; a short-lived kubectl runs the credential plugin for every question), and `KubeTree`/`KubeHealth` on a Deployment, its ReplicaSet and pod, a ConfigMap, a PVC (kind's `standard` class) and Services.
- **oidc-login's browser flow** from a background process. Logins are serialized, so a second context waits for the first.
- **EKS access entries** may make the rules review incomplete. Verbs are enabled only after an access review, and a 403 at write time is reported plainly.
- **Version spread:** EKS 1.2x–1.3x. Version-dependent features (streaming lists, the WebSocket permission change) sit behind detection.
- **Field ownership:** applying to objects managed by Helm, Argo or Flux either conflicts or, if forced, takes their fields away. The owners are shown first, forcing is never offered on production, and apply is off on production by default.
- **The production pattern can miss a name.** Classes can be set by hand, and remote contexts are read-only anyway. A loopback server never makes a context local, so a tunnel to a remote cluster stays read-only.
- **The pane-header warning can be wrong** when a shell has its own `KUBECONFIG`. It says "probably" then, and the pinned tab context is the real guard.
- **Background watches compete with the page for proxies.** One slot is kept for the page, and background proxies are evicted first. A checkout's marks can then go quiet, and its tab says "not watched".
- **Scope:** Kubernetes is wider than Docker. Small stages (1a–1e) keep each release safe and reviewable, and stage 0's refactors touch Docker code that has just shipped.
- **Extracting Docker's pieces** risks regressions in the Docker page. Each extraction is its own commit, with Docker's tests and scenario passing.
- **kubectl skew:** only two copies on this Mac; a cluster outside ±1 gets a warning, not a download.
- **The pinned tab context** depends on kubectl's merge order and on tools other than kubectl (`helm`, `k9s`) reading `KUBECONFIG` the same way. Checked at the start of stage 1d: all three do (3.11). A `KUBECONFIG` exported by the shell's own startup files still replaces the tab's.

## 13. Decisions to take

The first analysis's 11, updated, then new ones. Each has a recommended option.

1. **Talking to clusters:** `kubectl proxy` plus the API, port-forwards and shells as kubectl processes, with the transport kept abstract for a later hybrid (**recommended**) / our own client / everything through kubectl.
2. **Shortcuts:** ⌥⌘J for the page and ⌃⌘J for the switcher, both checked free against `KeyCommands` and Ghostty v1.3.1 and both in stage 1a; ⇧⌥⌘J is Ghostty's `write_screen_file:open`. Sections are plain `1`–`9` while a list has the keyboard, as Docker's are, not ⌃1–⌃9 (**recommended**) / the switcher only in the palette.
3. **Interface:** a page plus the rail panel, as Docker has (**recommended**) / the page only.
4. **Security defaults:** read-only on remote and production contexts. It is enforced by the proxy's flags for what Overterm sends, and by refusing writing processes for what it starts. Whether a context is writable lives in one place: a non-production context's `writable` flag in `kubernetes.contexts`. A production context's writes last for the session only and are never a setting. Typed names for destructive actions on production (**recommended**) / make production writes persistent once turned on.
5. **Agents:** typed `k8s_` tools, reads in stage 1e, writes only on writable contexts and confirmed each time. None on production unless writes are on for the session and `agentWrites` names the context. No Secrets tool (**recommended**) / reads only.
6. **Stage 1 scope:** five small stages that change no object (1a contexts and pods, 1b every kind, 1c logs, 1d tabs, forwards and Terminal in this context, 1e agent reads), each released alone (**recommended**) / one stage 1 release.
7. **Spike:** read-only measurements on `acme-dev` and `globex-eu-west-1-dev` only, never a production context, and only with the user's explicit yes (**recommended**) / the fake API server only.
8. **A local cluster for live tests:** kind or k3d, started only for the tests and removed after (**recommended**) / none, the fake only. Overterm never turns on Docker Desktop's Kubernetes.
9. **Background watches for attention marks:** a stated exception with a budget. Pod and Deployment watches per bound namespace, only while that checkout has a tab, at most `backgroundWatches` namespaces. They use at most `maxProxies − 1` proxies and are evicted first when the page needs one (**recommended**) / no background marks; marks only while the page or rail shows.
10. **Letters:** Docker's letters, with `f` meaning port-forward on Kubernetes (pod files are rare and go to stage 4), plus k9s's `:`, `/`, `[` and `]` (**recommended**) / `⇧F` for forwards, keeping `f` for files / k9s's letters throughout.
11. **Applying from the editor:** server-side apply with `fieldManager=overterm`, carrying the opened `resourceVersion`, after a dry-run diff. Conflicts are shown with their owners, never forced by default and never forced on production (**recommended**) / `kubectl apply` in a tab / PUT with `resourceVersion`.
12. **The proxy's flags:** read-only contexts reject every write method, POST included. Every context rejects exec, attach, port-forward and the pod, service and node proxy subresources, since Overterm never uses them through the socket. Who-am-I and the shell and forward checks on read-only contexts come from short-lived `kubectl auth` processes; access reviews go through the socket only on writable contexts (**recommended**) / allow POST so the reviews work everywhere / enforce read-only only in the app. *Built differently: Section 15, Where the build departs.*
13. **Stage 0 refactors first**, each a PATCH commit (**recommended**) / copy Docker's pieces and unify later.
14. **Where checkout bindings live:** `AppEnvironment.supportDirectory`, keyed by repository root (**recommended**) / a file in the repository. *Built differently: Section 15, Where the build departs.*
15. **Helm writes:** reading in stage 2c. Rollback and uninstall in a tab in stage 2f, refused on read-only contexts, with typed names (rollback on production, uninstall everywhere). Upgrade from the checkout's chart in stage 3a. No chart browser or repo management (**recommended**) / a full Helm UI.
16. **Metrics:** metrics.k8s.io in stage 2d, polled only while shown. Prometheus opt-in per context in stage 4, through its own proxy that reaches only the detected service's query paths; charts get a time range and PVCs a usage column there. Nothing installed (**recommended**) / leave Prometheus out for good.
17. **Several contexts at once:** one context on the page, several proxies alive, a health view across pinned contexts in stage 3b (**recommended**) / Aptakube-style merged lists (later at the earliest).
18. **k9s-style custom verbs:** Kubernetes placeholders in Snippets, offered in the verb menu (**recommended**) / none. A plugin API stays out either way.
19. **The tab's own context:** "Terminal in this context" in stage 1d, after the merge order is checked at the start of that stage; the pane-header warning and New Task pinning in stage 3b (**recommended**) / the warning only.
20. **Node shell:** stage 3b, a tab running `kubectl debug node/…` with the context's image. Writable contexts only, off until the context's `nodeShell` is on, typed name (**recommended**) / left out.
21. **Secret values:** one GET when the user asks to see a Secret, which returns every value at once. Values masked until revealed one by one, dropped on navigation, never cached, logged or written. On production the first Show per context and session asks once. Copy is explicit (**recommended**) / no Show on production at all.
22. **Which kubectl:** the installed copy closest to the server's minor, within ±1, with a setting (global and per context) to override; never downloaded (**recommended**) / always the first on PATH. *Built differently: Section 15, Where the build departs.*
23. **Cloud sign-in and discovery (EKS, AKS, GKE without a kubeconfig):** left out, kubectl's job; help on errors only (**recommended**) / built-in sign-in.
24. **GitOps:** generic tables of Argo and Flux resources in stage 1b, trees in stage 3b, verbs in stage 4; sync left to their own CLIs in a tab (**recommended**) / dedicated dashboards.
25. **New: the production classifier:** the default pattern matches `prod`, `prd`, `production` and `live` as a separated word, which covers `…/acme-prod` and `globex-eu-west-1-prod`; overrides in `kubernetes.contexts` (**recommended**) / any substring `prod` / every remote context treated as production.
26. **New: live proxies:** at most `maxProxies` (4), one kept for the page's context, background proxies evicted first, then the least recently used idle one; oidc logins serialized (**recommended**) / no cap.
27. **New: shells on production:** allowed after `kubectl auth can-i` and a confirmation once per pod and session; a context can turn shells off (**recommended**) / only on writable contexts.
28. **New: CRD re-discovery:** a CRD watch while the page shows where listing is allowed, else discovery on a 404 and every 5 minutes (**recommended**) / only on reconnect, as Lens does.
29. **New: `kubernetes.enabled` and the rail:** on by default, with nothing running until the page or the panel opens; the rail panel placed after Docker's (**recommended**) / off until turned on in Settings.
30. **New: apply on production:** server-side apply from the editor (and `k8s_apply`) is not offered on a production context, even with writes on for the session. The context's `applyOnProduction` opts in; even then each apply asks for the typed name and is never forced. The diff with the cluster works everywhere (**recommended**) / apply on production whenever writes are on.
31. **New: class precedence:** a class set by hand, then production by name, then local by name, then remote. A loopback server never makes a context local (**recommended**) / a loopback server counts as local.
32. **New: per-context settings:** one `kubernetes.contexts` object per context, with Lens's and Freelens's cluster settings except the icon and the OpenShift Prometheus token, which stay out (**recommended**) / separate top-level settings per field. *Built differently: Section 15, Where the build departs.*
33. **New: what the Overview's health checks read (3.9):** the Overview's count reads more than the lists already hold, because list rows are Table rows with no object, and the template checks need specs. While the Overview shows on screen it makes one GET a list of whole objects, with no watch, in the context and namespace shown (all namespaces too). Each list is bounded: pods 200, and 500 each for Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, Services, Ingresses, PDBs, HPAs, and the Argo CD, Flux and cert-manager kinds the context serves. A cut list is said. Production is read the same way, since the page already reads it when shown. Never a Secret or a ConfigMap. What may carry a secret is dropped as each list is decoded: env values (names kept), Helm values, the last-applied annotation, managedFields. Nothing is kept once the Overview hides. The findings show on the Overview and in each object's detail, not as a list column, because a column would need the same reads on every list (**recommended**) / Table rows only, with only the status checks (restarts, Pending, PDB, HPA, Ready) and no template checks / a findings column on every list, read with each list.

## 14. Sources

Lens:
- https://lenshq.io/pricing
- https://docs.lenshq.io/release-notes/lens-k8s-ide/lens-2026-10-261408/
- https://docs.lenshq.io/k8slens/using-lens/shortcuts/
- https://docs.lenshq.io/k8slens/using-lens/navigator/
- https://docs.lenshq.io/k8slens/using-lens/hotbar/
- https://docs.lenshq.io/k8slens/using-lens/workloads/pods/
- https://docs.lenshq.io/k8slens/using-lens/log-options/
- https://docs.lenshq.io/k8slens/using-lens/terminal/
- https://docs.lenshq.io/k8slens/using-lens/advanced-editor/
- https://docs.lenshq.io/k8slens/using-lens/helm/releases/
- https://docs.lenshq.io/k8slens/cluster/cluster-metrics/
- https://docs.lenshq.io/k8slens/cluster/cluster-settings/
- https://docs.lenshq.io/k8slens/cluster/cluster-performance/
- https://docs.lenshq.io/k8slens/cluster/use-port-forwarding/
- https://docs.lenshq.io/k8slens/mcp-server/
- https://docs.lenshq.io/k8slens/ask-ai/
- https://docs.lenshq.io/k8slens/ask-ai/see-and-drive-lens/
- https://docs.lenshq.io/k8slens/lens-studio/
- https://docs.lenshq.io/k8slens/flux-cd/
- https://docs.lenshq.io/k8slens/argo-cd/
- https://docs.lenshq.io/k8slens/cost-monitoring/
- https://docs.lenshq.io/k8slens/security-center/
- https://docs.lenshq.io/k8slens/extensions/
- https://github.com/lensapp/lens

Freelens:
- https://github.com/freelensapp/freelens
- https://github.com/freelensapp/freelens/releases/tag/v2.0.0
- https://github.com/freelensapp/freelens/issues/2376
- https://github.com/freelensapp/freelens/tree/main/packages/technical-features/prometheus/src

Other tools:
- https://k9scli.io/topics/commands/
- https://k9scli.io/topics/plugins/
- https://github.com/derailed/popeye
- https://headlamp.dev/blog/2025/11/11/headlamp-projects
- https://aptakube.com/
- https://github.com/kubeshop/monokle
- https://github.com/ahmetb/kubectl-tree
- https://github.com/itaysk/kubectl-neat
- https://github.com/stern/stern
- https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- https://github.com/gimlet-io/capacitor
- https://github.com/robusta-dev/holmesgpt
- https://github.com/GoogleCloudPlatform/kubectl-ai

Kubernetes API:
- https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/kubectl/pkg/proxy/proxy_server.go (the default filters; `accept`'s order; `req.URL.Path`; unanchored `MatchString`)
- https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/kubectl/pkg/cmd/proxy/proxy.go
- https://raw.githubusercontent.com/kubernetes/kubernetes/master/pkg/printers/internalversion/printers.go (a Secret's Table: Name, Type, Data as `len(obj.Data)`, Age)
- https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins
- https://github.com/int128/kubelogin/blob/master/docs/usage.md
- https://kubernetes.io/docs/reference/using-api/api-concepts/ (Tables, watch bookmarks, streaming lists, chunking, resource versions, dry-run, metadata-only fetches)
- https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/watch.go
- https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#additional-printer-columns
- https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery/4006-transition-spdy-to-websockets
- https://raw.githubusercontent.com/kubernetes/api/master/core/v1/types.go
- https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/kubectl/pkg/cmd/logs/logs.go
- https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html
- https://github.com/kubernetes-sigs/metrics-server/blob/master/README.md
- https://kubernetes.io/docs/reference/using-api/server-side-apply/
- https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/kubectl/pkg/cmd/diff/diff.go
- https://raw.githubusercontent.com/kubernetes/api/master/authorization/v1/types.go
- https://kubernetes.io/docs/reference/access-authn-authz/authentication/#self-subject-review
- https://kubernetes.io/blog/2022/12/09/kubernetes-v1-26-release/
- https://github.com/swiftkube/client
- https://kubernetes.io/releases/version-skew-policy/#kubectl
- https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/

Helm:
- https://raw.githubusercontent.com/helm/helm/main/pkg/storage/driver/util.go
- https://raw.githubusercontent.com/helm/helm/main/pkg/storage/driver/secrets.go
- https://raw.githubusercontent.com/helm/helm/main/pkg/cmd/install.go

Overterm:
- `CLAUDE.md`
- `docs/architecture.md`
- `docs/design/kubernetes/analysis.md`
- `docs/design/docker/analysis.md`
- `Sources/Overterm/Settings/Keybindings.swift` (`KeyCommands.all`, and the note that moved groups off ⌃1–⌃9; checked for Section 7)
- `Sources/Overterm/Settings/SettingsSchema.swift` (its value kinds: bool, int, double, string, list)
- `Sources/Overterm/Docker/DockerKeys.swift` (Docker's sections on `1`–`6`)
- `vendor/ghostty/src/config/Config.zig` (Ghostty's default keybinds, `goto_tab` on ⌘ on macOS; checked for Section 7)
- `Sources/Overterm/API/APIDiscovery.swift`
- `Sources/Overterm/AppEnvironment.swift`
- the source files listed in Section 8

## 15. What was built

Every stage in Section 9 is built, 0 to 4, and ships as Overterm 1.6.0. Each decision in Section 13 was taken as recommended, except where the list below says otherwise (decisions 12, 14, 22 and 32). `docs/architecture.md`, Kubernetes, describes what exists and names every type; this section says where the build departs from the design above, and what the design left open that the build settled.

### Where the build departs

- **The read-only filter (Section 4, decision 12).** The design rejects every write method. The build names the one method it lets through, `--reject-methods` for everything but `GET`. kubectl matches the method as it is sent: against kind's 1.37, `post`, `Delete` and `PROPFIND` passed a list of write methods and reached the API server. The API server refused them with 405, but an aggregated API server need not.
- **Bindings (3.1, decision 14).** A binding is keyed by the checkout's own root, its real path, not by the repository's root. Each worktree of a repository has a binding of its own. The brief and the agents' tools prefer the selected tab's checkout when several are bound to one namespace.
- **Which kubectl (decision 22).** The installed copy closest to the server's minor is used, and `kubernetes.kubectlPath` overrides it for every context. There is no per-context kubectl setting.
- **Per-context settings (decision 32).** `kubernetes.contexts` is a list of entries, one per context name, edited in settings.json or with Context Settings… on the context card. It holds the fields Overterm reads: `class`, `writable`, `displayName`, `defaultNamespace`, `accessibleNamespaces`, `favouriteNamespaces`, `terminalDirectory`, `shells`, `debugImage`, `nodeShellImage`, `nodeShell`, `applyOnProduction`, `metrics` and `prometheus`. A field this build doesn't know is kept when the sheet saves.
- **Namespaces (2.2).** A list shows one namespace, several, or all of them (`0`). The chip beside the filter field and `n` open one picker: the favourites first, a box each to tick several, a name typed, `a,b` typed (or `:ns a,b`). Several are a watch each, merged into one list with a Namespace column, at most 10; past 10, the watch across the cluster filtered in the app — refused, with why, where the user can't list cluster-wide. Every namespace the server listed ticked is the all-namespaces watch. The selection is kept per context. The Overview, health, usage, Helm and the agents' default follow it; a tab's command still carries one `-n`.
- **The filter (Section 7).** Text, `ns:`, `status:`, `label:` and `field:` (the last two sent to the server as selectors) and `-` are built. `node:`, `owner:` and `restarts:>3` are not: a row is Table cells only, and `field:spec.nodeName=…` covers the node.
- **Keys (Section 7).** Space's quick look and `i` for YAML are not built: ↩ opens the detail, whose YAML is a tab. Several rows can be selected and copied as names, TSV or CSV, but every verb acts on one object. The switcher's ⌥↩, ⌘↩ and ⌘O are not built: ↩ shows the object on the page, where its verbs are.
- **Streaming lists (Section 4, stage 4).** A context lists with `sendInitialEvents` only where its `/version` is 1.32 or 1.34 and later, and falls back to a list and a watch on any failure of one. A Table's end bookmark carries its annotation on its one row's object, as kind's 1.37 sends it, not in the list's metadata.
- **Credential plugins (Section 12).** A 401 on a context whose user signs in with an exec plugin stops that context until Retry, as a failing plugin does. kubectl throws a refused token away and runs the plugin again for the next request, so retrying ran `aws` or kubelogin for every request.

### What the design left open

- **The real-cluster suite (decision 8, Section 11).** `KubeRealClusterTests`, opt-in with `OVERTERM_KUBE_TESTS=1`, runs the app's own proxies, client, `kubectl auth can-i`, the dependency tree and the health checks against a kind cluster made for it (`Scripts/kube-test-cluster.sh`, a kubeconfig of its own, the node container labelled `overterm.test`) and removed after. It answered Section 12's questions about the proxy on Kubernetes v1.37.0, and three of the departures above came of it: the read-only filter's methods, the streaming list's end and the credential plugins' 401.
- **Commands typed into a pinned tab** carry the pin's `KUBECONFIG` on their own line, so a shell's startup files that export another one can't send `--context` to a different cluster than the one reviewed. A word with a control character is written as an escape, never typed raw.
- **Helm upgrade from the checkout** runs only on the chart that was diffed: a template, `values.yaml` or a dependency changed since, or the release upgraded meanwhile, and nothing runs until it is diffed again.
- **Scale.** `kubernetesPerf` and `kubernetesScale` time the page against the fake API server at a large cluster's size; the Overview's health checks and a tree ask for their lists four at a time.
