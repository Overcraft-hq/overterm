# Kubernetes — metrics as charts

This is a design for showing the Kubernetes page's metrics in more detail, as charts. It covers each object kind's charts, where the numbers come from, how the charts behave and how they are drawn, the budgets, the agents' tools, the tests and the stages.

It extends `docs/design/kubernetes/analysis.md` (§2.11, §4's Prometheus proxy, §10, §11) and the code on `kubernetes` at `dd5f8ee`. Nothing in the repository was changed to write it, and no kubectl or helm was run. The survey behind it read the source of Freelens, Headlamp's Prometheus plugin, k9s, kubernetes-mixin and Rancher, plus the documentation of Datadog, GKE, EKS, New Relic and Komodor.

## In short

- **metrics-server comes first, Prometheus second.** Most of the user's EKS clusters run the metrics-server add-on and have no Prometheus inside the cluster. So every chart that can be drawn from metrics.k8s.io and the objects Overterm already reads is drawn from them. Prometheus is the deeper layer: ranges, history, and the charts metrics-server can't give (throttling, network, PVCs, replicas over time, rightsizing). It stays opt-in per context, exactly as today.
- **Every object that uses resources gets a Metrics tab in its detail** (`KubeDetailTab.metrics`, key `m`). That covers pods and their containers, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, HPAs, Namespaces, Nodes and PVCs. The Overview section's usage block uses the same chart. The design adds no new section and no new page.
- **Usage is drawn against request and limit.** Request, limit, allocatable, capacity and quota are reference lines: dashed and stepped, never more series. The header shows k9s's numbers as chips: `% of request`, `% of limit`.
- **Changes are marked on every time chart.** The markers are rollouts, Helm revisions, scaling, restarts, OOMKilled and Warning events. They come from what Overterm already reads (`KubeTimeline`, the pod's `lastState`, the detail's events), through a pure join that costs no read. No desktop tool does this; Datadog, GKE and Grafana do.
- **A Deployment's usage by revision.** One line per ReplicaSet, labelled with its revision and image, so old and new pods sit side by side during and after a rollout. None of the surveyed tools does this.
- **One chart component, drawn with a SwiftUI `Canvas`, not Swift Charts.** macOS 13's Charts has no selection API. A pure plot (`KubePlot`) builds cached paths off the main thread. Only a thin overlay redraws while the mouse moves. The plot's geometry can be unit-tested and dumped by `OVERTERM_DUMP_LAYOUT`.
- **A shared crosshair, drag to zoom, a range picker (`,` and `.`), legend isolation, and drill-down from a series to its object.**
- **The budgets don't move.**
  - Nothing is read unless a chart is on screen.
  - metrics.k8s.io stays one GET per target every 15 s.
  - Prometheus goes through the existing metrics proxy, whose `--accept-paths` are unchanged: one Service's `query` and `query_range`.
  - At most 4 queries are in flight per context, and each answer is bounded.
  - No new process, no `nodes/proxy`, nothing installed in the cluster, nothing written to disk.
- **Today's Prometheus path has defects, and they are fixed first (M0).** The rate window comes back empty on a 1m scrape. The current prometheus chart's Service is never detected. Requests and limits count finished pods. Cluster CPU over 7d reads raw cAdvisor.
- **Agents get `k8s_metrics`**, which returns bounded text summaries rather than matrices, and works without Prometheus too. `k8s_top` gains `%CPU/R %CPU/L %MEM/R %MEM/L` where the pod's spec is in hand (§2.1).
- **List rows carry no spec.** The Pods list is a Table with `includeObject=None` (885 KB for 2,886 pods, against 35 MB as objects), so nothing that needs a pod's requests or limits may assume the list has them. Requests and limits come from the one object a detail GETs, a workload's pod template, kube-state-metrics when Prometheus is on, or a bounded read named where it is used (§2.1, §2.8, §4.1).
- **A chart that needs Prometheus uses it in Live too** when Prometheus is found (15 minutes at 30 s); only the charts that have a sampled form are sampled in Live.
- **The floor is M0–M4.** If the work stops there, every EKS cluster with metrics-server gets per-container usage against request and limit, OOM and rollout markers, and node and HPA charts, with no Prometheus.

The review of this design (2026-11-07) changed it in the places marked "(review)"; §11 lists what changed and why.

## 1. What exists today

| Piece | What it does | Limits |
|---|---|---|
| `KubeMetrics` / `KubeMetricsMonitor` | metrics.k8s.io lists polled every 15 s per `KubeMetricsTarget`, only while a usage column or the Overview shows. `KubeQuantity`, `KubeUsageCell`. | Lists only; no single-pod or single-node target. |
| `KubeUsageHistory` | The samples taken while shown, in memory, for `KubeSparkline` | `capacity = 40` (10 min at 15 s); keyed by arrival time, no gaps |
| `KubeClusterOverview*` | The Overview section: counts, usage against allocatable, applications | Usage is one number plus a sparkline |
| `KubePrometheus` | `KubePrometheusService`, `KubePrometheusFlags` (the metrics proxy's `--accept-paths`: one Service's `/api/v1/query` and `/api/v1/query_range`, escaped and anchored, GETs only), `KubePrometheusProvider` (`lens`, `helm`, `operatorManaged`), `KubeChartRange` (1h/6h/24h/7d at 30/180/720/3600 s), `KubePromQL`, `KubePrometheusReader` (2,000 series, 2,000 points, 8 MB), `KubeChart` (`.cluster`, `.pod`, `.volume`) | See §1.1 |
| `KubePrometheusMonitor` | One per context, found once; reads only while a chart or the PVC column shows; closes the metrics proxy when readings stop; its own slot within `maxProxies` (`KubeProxies.sendPrometheus`/`closePrometheus`); `metricsProblem` | Each chart issues its queries one after another; no queue |
| `KubePrometheusViews` | `KubeRangeChart`: one `Path` with one dashed reference line; the range picker | No hover, no axis, no legend, no markers |
| `KubeMCP+Top` | `k8s_top`: metrics-server's current usage | No shares of request or limit |
| `FakeKubeAPI.servePrometheus` / `setPrometheusSeries` | A small evaluator ramping a value | Can't script gaps, errors or agent mode |

### 1.1 Defects in today's Prometheus path (fixed in M0)

| Today (`KubePrometheus.swift`) | Problem | Change |
|---|---|---|
| `rateWindow = max(60, step)` (line 262) | The prometheus chart scrapes every 1m by default. `rate(x[1m])` then holds 0 or 1 samples and returns nothing, and Prometheus 3's left-open range selectors make it worse. | `KubeRateWindow.of(step:scrape:) = max(step + scrape, 4 × scrape)`, rounded up to a whole minute (Grafana's `$__rate_interval`). `scrape` comes from the probe (§4.4); 60 s until it is known. |
| `helmSelector = app=prometheus,component=server,heritage=Helm` (line 168) | That is the prometheus chart before v15. Since 2022 the chart labels its Service `app.kubernetes.io/*`, so detection never finds a current install. | Add `.helm` with `app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server,app.kubernetes.io/managed-by=Helm`. Rename the old one `.helm14` (same title). Order: `lens`, `operatorManaged`, `helm`, `helm14`. |
| `requests()` / `limits()` sum every pod | kube-state-metrics (KSM) keeps Succeeded and Failed pods (completed Jobs, Evicted) until they are deleted, so the sums are too high. | Multiply by `ACTIVE` (§4.2), or use `cluster:namespace:pod_{cpu,memory}:active:kube_pod_container_resource_{requests,limits}` when the probe finds them. |
| Cluster CPU and memory are raw cAdvisor at every range | About 10k series on a 2–5k-pod cluster. At 24h or 7d that is tens of millions of samples, against `query.max-samples` (50M) and the 2-minute timeout. | M0: raw cAdvisor across the cluster only up to 6h; beyond, the chart says why and offers 6h. M5 adds the tiers (§4.3): recording rules, then node-exporter, then raw. (review: the tiers need the probe, which is M5) |
| A container's series doubled across its restart | cAdvisor labels each series with the container's ID. After a restart the old series lingers until it goes stale (up to 5 min), so `sum(container_memory_working_set_bytes{…})` counts the container twice and shows a false spike right before or after an OOM, which is exactly where a developer looks. | Gauges are `max by (namespace, pod, container)` before any sum across containers or pods; counters are `sum by (namespace, pod, container)(rate(…))`, since a dead counter's rate falls to 0. (review) |
| The reader | It accepts only `matrix`, drops `warnings` and `infos`, and doesn't say it skips native histograms. | `KubePrometheusReader.Answer { series, notes, resultType }`. `scalar` and `vector` are accepted. Native-histogram series are skipped and counted. Warnings (Thanos' partial responses) become the chart's footnote. A line breaks where two points are more than 2 × step apart. |
| No `timeout` | A slow query holds the slot until the HTTP timeout. | `timeout=20s` on every `query` and `query_range`, with a 25 s client deadline. |
| Doubled series | kube-prometheus-stack can scrape kubelet's `/metrics/cadvisor` and `/metrics/resource` at once, and both carry `container_cpu_usage_seconds_total`. Two KSM jobs double every `kube_*` sum, and so do two KSM replicas in one job (HA, distinct `instance`). | M5: the probe pins `metrics_path="/metrics/cadvisor"` and the KSM `job` when it sees more than one (§4.4). Every `kube_*` series is taken `max by` its identifying labels before it is summed, which removes the HA replicas the job pin can't. (review) |

## 2. What the user gets

### 2.1 Where the charts are

| Where | What | Source |
|---|---|---|
| A detail's **Metrics** tab (`m`) | Every chart for that object (§2.2–§2.9) | sampled, or Prometheus |
| A detail's **Overview** | A compact row: CPU and memory, 90 pt, the page's range, "More in Metrics (m)". Keeps `kubernetes.detail.prometheus`. | as the Metrics tab |
| The **Overview** section | X1–X4 (§2.9), in place of today's `KubePrometheusChartView(.cluster)` and its requests block | as the Metrics tab |
| **Pods** list | Optional `%CPU/R %CPU/L %MEM/R %MEM/L` columns, part of the wide view (`w`, which already toggles wide) or the column menu. Coloured at 80% and 100% of limit. **(review)** The rows have no spec, so the shares' denominators come from: (1) with Prometheus, one instant query per namespace shown, `max by (namespace,pod,resource)(kube_pod_container_resource_{requests,limits}{namespace="$ns"})` summed by pod, read with the column and every 5 min; (2) without it, open decision 10. Until one of them answers, the cells are a dash saying why, never a guess. | the sample already read, plus (1) |
| **Nodes** list | A 14 pt heat strip in the CPU and memory cells: the last 15 min as 60 cells, coloured by % of allocatable | the ring |
| The right slot | **Expand** (a chart's ⤢, or ⌥↩ on a focused chart): one chart at full height, as `KubeManifestPane.Shown.chart`, under the `RightSlot` rule | the same data, no new read |
| The rail panel's pod (`KubeSlotView`) | The compact CPU and memory row, sampled only | sampled |

`KubeObjectRef.hasMetrics` decides which kinds show the tab. Other kinds have no Metrics tab, so `m` does nothing on them.

### 2.2 The Metrics tab's layout

```
┌ Pod api-7f9c6d-x2k4q · prod-eu ──────────────────────────────────────────────┐
│ Overview  Logs  YAML  Events  History  [Metrics]                             │
│ ‹ Live  1h  6h  24h  7d  Custom › Zoomed 14:02–14:20 [Reset]  Sizing         │
│ Prometheus monitoring/prometheus-operated:9090 · 1h at 30s · recording rules │
├──────────────────────────────────────────────────────────────────────────────┤
│ CPU  120m now · 48% of request · 12% of limit      ■app ■sidecar  ┄req ┄lim  │
│ 1 ┤┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ limit       │
│   │            ╭╮             │                                              │
│250┤┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┼┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ request     │
│   │▁▂▃▃▄▅▆▇███▇▆▅╯╰▄▃▂▂▂▃▃▃▄▄▄│▃▃▂▂▃▃▃▃▄▄▃▃▂▂▃▃▃▃                            │
│ 0 ┼─────────────┬─────────────┼───────────┬───────────────────────────────── │
│   13:30        ▲13:58         14:10       ▼14:11                     14:30   │
│                rev 14 nginx:1.27.2        OOMKilled                          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Memory  412Mi · 81% of limit  OOM risk            (same frame, shared │)     │
├──────────────────────────────────────────────────────────────────────────────┤
│ Network  rx 1.2 MB/s tx 340 kB/s · drops ▁▁▁▁▃▁                              │
│ Restarts  ▌    ▌▌                                                            │
├─ container app ──────────────────────────────────────────────────────────────┤
│ CPU · Memory · Throttling 31% (> 25% guide) · Ephemeral storage              │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **The top bar** holds the range picker, the zoom state with Reset, the source caption and "Sizing" where it is offered.
- **The body** is a `LazyVStack` of charts, each 140 pt high (the Overview's are 180 pt). Each chart's header line gives the title, the latest value, the % chips and the legend.
- **Width.** Charts fill the detail's width. Below 560 pt the legend wraps under the plot.
- **Containers.** A pod lists its own charts first, then a section per container. The Logs tab's default container comes first. Beyond 4 containers a picker replaces the sections.

### 2.3 Container (inside a pod's tab)

| # | Chart | Series | References | Sampled (S) / Prometheus (P) |
|---|---|---|---|---|
| C1 | CPU | usage; a peak band at ranges of 24h and more (P, one pod only) | request, limit | S, P |
| C2 | Memory | working set; RSS as a legend toggle, off by default (P) | request, limit (red) | S, P |
| C3 | Throttling % | throttled periods ÷ periods | 25% guide (the mixin's `CPUThrottlingHigh`) | P |
| C4 | Ephemeral storage | `container_fs_usage_bytes` | ephemeral-storage limit | P |

- **C2's markers:**
  - OOMKilled and Error at `lastState.terminated.finishedAt`, which is exact, but only for the last termination;
  - restarts, from `changes(…restarts_total)` (P) or from a restartCount increase between two reads (S);
  - (review) earlier OOMs over Prometheus: a step where the restart count rose and the last terminated reason is OOMKilled (§4.6). KSM's reason carries no time, so the marker sits on the step, not the second.
- **(review) A restart or OOM marker's click** opens the Logs tab on that container with Previous on, since kubelet keeps exactly the one previous instance. Past the first restart it says "Only the last previous instance's log is kept".
- **C2's chip** reads `working set 81% of limit`. Above 90% it turns red and reads "OOM risk".
- **C3 without a CPU limit** asks nothing. It reads "No CPU limit: never throttled".
- **C4 is drawn only when the probe found `container_fs_usage_bytes` with a value for this pod's node** (review: on EKS's containerd it is usually absent, and a chart that is always empty is noise). Otherwise one line under the container's charts says why: "This cluster's kubelet doesn't report per-container filesystem use (containerd). A pod's ephemeral use is in kubelet's stats, which Overterm never reaches (nodes/proxy)."

### 2.4 Pod

| # | Chart | Notes | S / P |
|---|---|---|---|
| P1 | CPU, stacked by container | C1's series | S, P |
| P2 | Memory, stacked by container | C2's series, with its markers | S, P |
| P3 | Network rx/tx in B/s, with drops as a 20 pt strip under it | A hostNetwork pod reads "This pod uses the node's network; its traffic is the node's" and asks nothing | P |
| P4 | Restarts, as bars per step, plus markers | integers, rounded | P (S: markers only) |

### 2.5 Workload: Deployment, StatefulSet, DaemonSet, ReplicaSet, Job

```
CPU  total 1.8 cores · requests 3 cores (60%)        ■total ■api-…x2k4q ■… ■other ┄req
  ███████████████▇▇▇▇▇▇▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▇▇▇  stacked: top 5 pods + other
By revision                                              ■rev 13 nginx:1.27.1 ■rev 14 nginx:1.27.2
  ▇▇▇▇▇▇▇▇▇▇▆▅▄▃▂▁        ← rev 13 draining
               ▁▂▃▄▅▆▇▇▇▇▇▇▇▇▇▇▇  ← rev 14 taking over
             ▲ rollout rev 14 (13:58)
Replicas  desired ┄ available ━ unavailable ▒           HPA: min ┄ max ┄  "flapping: 6 scales in 1h"
```

| # | Chart | Notes | S / P |
|---|---|---|---|
| W1 | CPU: the total, the top 5 pods, "other" | other = total − top 5, computed in the client; reference: the sum of active pods' requests. **(review) Two views, Total and Per pod**, a legend toggle. Total is stacked against the summed request. Per pod draws the top 5 as lines against the template's per-pod request and limit, which is where a hot or imbalanced pod shows; stacking hides it. Per pod is the default when the workload has ≤ 5 pods. | S, P |
| W2 | Memory, the same shape | OOM and restart markers for every pod; the same two views | S, P |
| W3 | By revision: Deployment (ReplicaSets); StatefulSet and DaemonSet (ControllerRevisions) | One line per revision, coloured and labelled from `KubeTimeline`: "rev 14 (nginx:1.27.2)" | Deployment: S (`pod-template-hash` from the pod name), P. StatefulSet, DaemonSet: S only, from each PodMetrics' `controller-revision-hash` label; P only when `kube_pod_labels` carries that label, which KSM 2.x doesn't by default (review: their pod names hold no hash) |
| W4 | Replicas: desired, available, unavailable | stepped; scaling markers; for a Job, completions and failures | S (the object's status), P |
| W5 | Restarts, as bars per step | all pods | P |

Pods are chosen by owner, not by today's names, so a 7d chart keeps the earlier ReplicaSets' pods (§4.5). The sampled forms are summed per sample from the selector's metrics list, and the top 5 are ranked by the ring's last 15-minute average.

**(review) The sampled request and limit references** come from the workload's own object, which the detail already holds: the pod template's requests and limits per container, times `status.replicas` for Total (a Job: `status.active`). The legend says "from the template", since a resized pod (`pods/resize`) can differ. No pod spec is read for them.

### 2.6 HPA (its own tab; also on its target workload's tab when one exists)

| # | Chart | Notes | S / P |
|---|---|---|---|
| H1 | Replicas: current, desired | references: min and max; a "ScalingLimited" band from `status.conditions`; the header says "flapping: N scales in 1h" past 4 | S, P |
| H2 | Each `spec.metrics[]`: current against target | target as a reference | S (`status.currentMetrics`), P (KSM ≥ 2.10) |

This is the most useful sampled view for an EKS cluster without Prometheus.

(review) A workload's tab finds its HPA with one HPA Table read in the namespace, made when the tab opens, matched on `scaleTargetRef`, and never repeated while the tab shows. With no HPA it asks nothing more.

### 2.7 Namespace

| # | Chart | Notes | S / P |
|---|---|---|---|
| N1 | CPU, stacked by workload: the top 8 plus "other" | reference: ResourceQuota `requests.cpu` hard and used, where a quota exists | S, P |
| N2 | Memory, the same | the same, for `requests.memory` | S, P |
| N3 | Idle requested CPU and memory | (review) **Not a chart.** It is one chip on N1 and N2's header, "requested but idle: 2.1 cores (avg, range)", from one instant query per range. A band chart of it repeated N1's lines. | P |
| N4 | Pods by phase, stacked | | S (the pods Table, `includeObject=Metadata`, paged `limit=500`, read every minute while shown), P |

(review) **A pod's workload, sampled**, comes from the same Metadata rows' `ownerReferences`: a ReplicaSet owner becomes its Deployment by its `pod-template-hash` label, which is exact. The pure `KubeWorkloadName.of(pod)` (strip `-<hash>-<5>`, `-<5>`, `-<ordinal>`) is only the fallback when no rows are in hand, and the legend says "grouped by name". With Prometheus, the workload rule or the owner join (§4.5) is used.

### 2.8 Node

| # | Chart | Notes | S / P |
|---|---|---|---|
| K1 | CPU: usage | references: requested (active pods), allocatable, capacity | S, P |
| K2 | Memory: usage | the same; plus "node total" (MemTotal − MemAvailable) where node-exporter maps to the node (§4.6) | S, P |
| K3 | Top pods on this node, stacked: top 8 | sampled only when the user presses "Sample top pods" (§4.1) | P; S on request |
| K4 | Pods against `allocatable.pods` | on EKS that is the VPC CNI's limit, the one that matters; only active pods are counted, as the scheduler does | S, P |
| K5 | Pressure and cordon bands on K1 and K2 | MemoryPressure, DiskPressure, PIDPressure, `spec.unschedulable` | S (conditions), P |
| K6 | Disk per mount: used against size | `/` and Bottlerocket's `/local`; tmpfs, overlay and squashfs left out. (review) Moved to M8b, the last chart stage: a developer rarely debugs a node's disk here, and DiskPressure (K5) already says when it matters | P, node-exporter mapped |
| K7 | Network rx/tx | lo, veth, eni, cali, docker and cni interfaces left out. (review) M8b, as K6 | P, node-exporter mapped |

**(review) K1 and K2's sampled "requested" line** needs the node's pods' specs, which a Table row doesn't carry. When the node's tab opens, one list of the node's pods as objects (`fieldSelector=spec.nodeName=$node`, `limit=250`, a node holds at most 110 on EKS's largest default) is decoded on a background queue into each pod's requests, limits and phase. Everything else is dropped as it is decoded, env values first, by `KubeHealthSession`'s rule that secret-bearing fields are dropped on decode. No object is kept. The list is read again every 5 minutes while the tab shows, and is the same read K4 counts from, so K4 needs no Table of its own. Above 250 pods the line is left out and the chart says so.

### 2.9 PVC and cluster

| # | Chart | Notes | S / P |
|---|---|---|---|
| V1 | PVC used against capacity, with time-to-full | A dotted projection to the right edge and a chip, "full in ~3 d" or "not filling". Capacity over 2^60 (EFS reports 8 EiB) shows used only: no %, no projection. | P |
| V2 | Inodes used % (toggle) | | P |
| X1 | Cluster CPU over time | references: requested and limits (active pods), allocatable, capacity; chips `requests 71% of allocatable`, `limits 143%`, red above 100% with "overcommitted" | S, P |
| X2 | Cluster memory, the same | | S, P |
| X3 | CPU by namespace, stacked: top 8 plus other | rules, or raw up to 6h | P |
| X4 | Nodes as small multiples | One row per node (the top 50 by %, above 50 nodes), each with a 60-cell strip for CPU % and one for memory %. A click opens the node's Metrics tab. | S, P |

A PVC with no series reads "No volume stats: the volume isn't mounted, or its CSI driver doesn't report them". The probe tells which.

**X1 and X2 when sampled.** Their reference lines are the nodes' allocatable and capacity, from the `/nodes` read the Overview already makes. (review) The Pods section's rows carry no spec, so a sampled X1 or X2 has no requests or limits line. The chips say "requests need Prometheus (kube-state-metrics)". A cluster-wide list of pod objects (35 MB on globex) is never read for them.

### 2.10 Rightsizing (on demand)

```
CPU sizing · app · 7 days · per pod
        p50 ▕██████▏ 110m
        p95 ▕██████████████▏ 210m        suggested request ≈ p95 × 1.15 = 240m
        max ▕███████████████████████▏ 480m
 request ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ 1000m
Memory sizing · app · 7 days · per pod
        max ▕███████████████████▏ 509Mi   suggested request and limit ≈ max × 1.15 = 586Mi
```

- **Where:** a "Sizing" button on a workload's or a container's tab.
- **Per pod, not per workload.** (review) A request is per pod, so every quantile is taken over each pod's own series (`by (pod, container)`) and then the highest pod's figure is shown. A quantile of the workload's sum would suggest N times too much.
- **CPU and memory are sized differently.** (review) CPU is compressible: the suggested request is p95 × 1.15. Memory is not: an over-limit container is OOMKilled, so memory is sized from the max, and an OOM in the window adds "OOMKilled at 14:11; the max understates the need". This follows VPA's practice.
- **What it reads:** one instant query per measure and quantile (CPU p50, p95, max; memory p95 and max), over 7d or the retention, whichever is shorter.
- **What it shows:** bands against the request and limit.
- **When:** once, on the press. It never refreshes and never runs in Live.
- **It is advice.** The suggestion is never applied and never typed anywhere.
- **Cost:** without recording rules it is offered only for one workload of at most 50 pods.

## 3. Interactions

1. **A shared crosshair.**
   - `KubeChartCursor` holds the hovered time. There is one per Metrics tab, Overview or expanded chart.
   - Every chart in that scope draws the vertical line at that time.
   - The chart under the mouse shows the tooltip:
     - the time ("Nov 7, 14:32:15");
     - each series sorted by value, with a colour dot, name, value and unit;
     - then the reference lines' values with %.
   - Hover uses `onContinuousHover` (macOS 13). The nearest point is found by binary search in the plot.
   - Every number goes through `Text(verbatim:)`.
2. **Markers.**
   - Each is a tick on the plot's bottom edge with a faint full-height line:
     - rollout (rev N, image) and Helm revision: blue;
     - scale: grey;
     - restart: orange;
     - OOMKilled: red;
     - Warning event: yellow.
   - Hover says what it is.
   - A click opens it: the History item with its diff, or the event in Events.
   - ⌥-click, or "Show ±30 min" in the popover, sets Custom to the marker's time ± 30 min.
   - At most 50 markers per chart; older ones fold into "+N earlier" at the left edge.
   - Events last about an hour (`--event-ttl`), so the legend says "events: last hour". Older warnings come only from `KubeTimeline`.
3. **Drag to zoom.**
   - Drag across any chart. A translucent band follows, and on release every chart in the tab moves to that absolute window.
   - The charts are asked again at the window's own step, never stretched.
   - Reset, or Esc, pops one level off the zoom stack.
   - A zoomed window doesn't refresh.
   - With sampled data a zoom only narrows the axis; nothing is asked.
4. **Ranges.**
   - `,` and `.` step through Live, 1h, 6h, 24h, 7d and Custom. These keys are free on the page; the section digits keep their meaning.
   - **Custom** is a popover with two date pickers, validated: start before end, end not in the future, the span within the probed retention or 30 d.
   - The range is one choice per page, in memory (`KubernetesPageModel.chartRange`), never saved.
   - **The default** is Live when metrics-server answers, otherwise 1h.
   - (review) **Without Prometheus**, the picker offers only Live and 6h, which is the folded tier of what was sampled while shown, captioned "since 14:02". 1h, 24h, 7d and Custom are greyed out with "needs Prometheus". analysis.md §2.11 currently says there is "no range to pick" without Prometheus, and it changes in M3a to say this.
5. **Live.**
   - Sampled every 15 s when metrics-server answers, for the charts that have a sampled form.
   - A chart with no sampled form (C3, P3, P4, W5, V1…), and every chart when only Prometheus answers, uses 15m at a 30 s step (60 s on a 1m scrape), refreshed at that step. (review: before this, a Prometheus-only chart in Live said "needs Prometheus" while Prometheus was on.)
   - Live **pauses** after 15 minutes without input in the window, showing "Paused, Resume". It stops on any hide.
6. **Legend.**
   - A click isolates a series; ⌘-click adds or removes one.
   - Hover highlights a series and dims the others to 25%.
   - "other" is a series like the rest.
   - The reference lines toggle together as "Lines".
7. **Drill-down.**
   - A pod's series in W1, W2, K3 or N1 opens that pod.
   - An X4 row opens its node.
   - An N1 workload opens that workload.
   - All of these go through `KubeHistory`, so `[` returns.
   - (review) A series' pod or node can be gone, since Prometheus remembers deleted pods for 7d. The click then opens nothing and says "api-7f9c6d-x2k4q no longer exists (last seen 13:58)". The one GET's 404 decides this, and nothing is retried.
8. **Keyboard on a focused chart.**
   - ←/→ move the crosshair by one step.
   - ⇧←/⇧→ grow a zoom selection; ↩ applies it.
   - ⌥↩ expands the chart into the right slot.
   - Esc resets the zoom, then behaves as built.
9. **A chart's context menu** has five items:
   - (review) "Logs from here" (a pod's or a container's chart only): the Logs tab with `sinceTime` set to the crosshair's time minus one minute. A spike's first question is "what did it log then", and `KubePodLog` already takes `sinceTime`. It says so when kubelet has rotated past that time;
   - "Copy PromQL": the exact query, to paste into Grafana (Prometheus charts only);
   - "Copy values as CSV": the visible window, to the clipboard only, with `KubeListExport`'s inert-cell rule;
   - "Ask agent about this chart": the `k8s_metrics` text for this chart, through the Ask Agent sheet with `showsBrief`;
   - "Expand".
10. **Honest emptiness.** Every empty or partial chart says why in one sentence (§4.7). Old-range data is hidden while a new range loads. Gaps are drawn as gaps, never interpolated and never drawn as zero. A missing trailing point means "not yet scraped".

## 4. Data sources and the exact queries

### 4.1 Sampled: metrics.k8s.io plus the objects

`KubeUsageHistory` becomes **`KubeUsageRing`**. It is pure and kept in memory only. Each series key has two tiers:

| Tier | Resolution | Span | Points |
|---|---|---|---|
| raw | the sample's own `timestamp` (15 s with EKS's add-on) | 15 min | ≤ 60 |
| folded | 1-minute buckets holding min, avg and max | 6 h | ≤ 360 |

- **Keys.** `KubeUsageKey` is one of:
  - `.cluster`
  - `.node(name)`
  - `.pod(ns, name)`
  - `.container(ns, pod, container)`
  - `.workload(ns, kind, name)`, summed per sample when it is recorded
  - `.namespace(ns)`
- **Time.** Samples are keyed by metrics-server's `timestamp`, not by when they arrived. A sample whose timestamp didn't move is dropped, so polling faster than `window` adds nothing.
- **Sums across pods** (review). Pods on different nodes carry different timestamps, up to one resolution apart. A `.workload` or `.namespace` sum is therefore keyed by the poll and stamped with the newest timestamp in it. It is recorded only when at least one pod's timestamp moved, and a pod that is missing from a poll ends its contribution rather than counting as zero.
- **Gaps.** A stretch longer than 2.5 × the interval is stored as a break and drawn hatched: "not shown".
- **Two populations** (review). The Pods list's sparklines feed up to 5,000 rows every 15 s. Sharing one LRU with the details' keys would push out the pod the user is looking at. So:
  - list-fed keys (`.pod` from a list, `.node`, `.cluster`) keep the raw tier only, and are forgotten as soon as their row is no longer sampled, as `KubeUsageHistory` does now. A pod's row and the cluster's keep 40 points, as today (the Overview's sparkline its 10 minutes); a node's row keeps the whole 15 minutes, 60 points, since the Nodes list's heat strip (2.1, M3c) draws all 60 cells;
  - detail-fed keys (what a Metrics tab or a compact row polls) get both tiers, at most 200 keys, the least recently fed dropped first.
- **Bounds.**
  - A detail key is forgotten 1 h after it was last fed (open decision 1).
  - The whole ring is dropped on a context switch, on a credential failure, and at quit.
  - (review) A point is stored as an `Int32` second offset plus `Float32` values: a raw point is 8 B, and a folded point (min, avg, max) is 16 B. A detail key is 2 measures × (60 × 8 + 360 × 16) B ≈ 12.5 KB, so 200 keys is about 2.5 MB. The list's 5,000 × 40 × 8 B × 2 is about 3.2 MB; its nodes' rows at 60 points are 60 × 8 B × 2 ≈ 1 KB a node, about 0.1 MB for 100 nodes (past the cap, list rows are given up first). The hard cap is 6 MB. (The earlier figure of "13 MB at 16 B a point" undercounted the folded tier's three values.)
- **Keeping what was already read is not reading.** The time the page was hidden shows as a gap.
- **The caption** reads "Sampled from metrics-server while shown since 14:02, every 15 s".

**What is polled**, each only while a chart that needs it is on screen:

| Shown | Target | Path | Rate |
|---|---|---|---|
| a pod's Metrics tab | `.pod(ns, name)` (new) | `/apis/metrics.k8s.io/v1beta1/namespaces/$ns/pods/$name` | 15 s |
| a workload's tab | `.pods(ns, labelSelector)` | `…/namespaces/$ns/pods?labelSelector=…` | 15 s |
| a namespace's tab | `.pods(ns, nil)` | `…/namespaces/$ns/pods` | 15 s |
| a node's tab | `.node(name)` (new) | `…/nodes/$name` | 15 s |
| a node's tab, after "Sample top pods" | (review) reuses the page's all-namespaces pods list when the Pods column already polls it; otherwise `.pods(ns, nil)` for the namespaces holding the node's 8 largest-request pods (≤ 4) | as above | 30 s, and stopped after 15 min with "Sample again" |
| an HPA's tab, or its workload's | `.hpa(ns, name)` (new; an apiserver GET) | `/apis/autoscaling/v2/namespaces/$ns/horizontalpodautoscalers/$name` | 15 s (the HPA controller's own sync period; faster adds nothing) |
| a workload's W4 | the workload object, one GET | as built | 60 s |
| a node's K1, K2, K4 | the node's pods as objects, decoded to requests and phase (§2.8) | `/api/v1/pods?fieldSelector=spec.nodeName=$node&limit=250` | 5 min |
| a namespace's N1, N4 | the namespace's pods Table, `includeObject=Metadata`, paged | as built | 60 s |
| a workload's tab, once | the namespace's HPAs Table, to find one targeting it | as built | on open |
| Overview, Nodes list | `.nodes` (as built) | `/nodes` | 15 s |

(review) **metrics.k8s.io and RBAC.** A 403 on `pods.metrics.k8s.io` or `nodes.metrics.k8s.io` is said once per context as a sentence (§4.7) and stops that target until the context's credentials change. It is not retried every 15 s.

**Request, limit, restarts and OOM come from objects the detail already holds.** That means the pod spec, `status.containerStatuses[].restartCount`, and `lastState.terminated{reason, exitCode, finishedAt}`. A restartCount that rose between two reads becomes a marker spanning them: "restarted between 14:02 and 14:03".

### 4.2 Shared PromQL fragments

These are placeholders: `$ns $pod $ctr $node $pvc $hpa $name $w $s`. Every literal goes through `KubePromQL.literal`. Every regex value goes through a new `KubePromQL.regexLiteral`, which escapes RE2's `\.+*?()|[]{}^$`; Prometheus anchors it. (review) The order is fixed and tested: `regexLiteral` first, then `literal`, so a `.` in a name becomes `\\.` inside the PromQL string. Done the other way round, the backslash is lost.

```
CAD    = container!="",image!="",container!="POD" [,metrics_path="/metrics/cadvisor"] [,job="<pinned>"]
ACTIVE = max by (namespace,pod)(kube_pod_status_phase{phase=~"Pending|Running"} == 1)
KSM    = [job="<pinned ksm job>"]
NODE   = the profile's node label: node="$node" (kube-prometheus-stack relabels it), else instance="$node" (the prometheus chart's cadvisor job sets instance to the node's name)
w      = KubeRateWindow.of(step: s, scrape: profile.scrape)      # max(s + scrape, 4 × scrape), whole minutes
```

- (review) **cAdvisor has no `node` label of its own.** The scrape config adds it. kube-prometheus-stack's kubelet ServiceMonitor does; the prometheus chart's `kubernetes-nodes-cadvisor` job instead sets `instance` to the node name and maps node labels to `kubernetes_io_hostname`. The probe decides `NODE` (§4.4), and with neither, the node charts' C tier is left out with a sentence.
- (review) **De-duplication before sums.** `CTR_GAUGE(m) = max by (namespace,pod,container)(m{CAD,…})`, `CTR_RATE(m) = sum by (namespace,pod,container)(rate(m{CAD,…}[$w]))`, and `KSM_REQ(r) = max by (namespace,pod,container,node)(kube_pod_container_resource_requests{KSM,resource="r"})`. Every chart sums these, never the raw series (§1.1).

- **Network has no container filter.** Its stats belong to the pod sandbox, which containerd labels `container=""`.
- **Usage, request and limit come back in one round trip.** They are unioned, since their label sets differ, and the reader splits the answer on `overterm_s`:
  ```
  label_replace(U,"overterm_s","usage","","") or label_replace(R,"overterm_s","request","","") or label_replace(L,"overterm_s","limit","","")
  ```
  (review) The label was `__s`. Names beginning with `__` are reserved for Prometheus' internal use, and some front ends (Thanos, VictoriaMetrics, remote-read proxies) are free to drop them from answers. Each of U, R and L is already summed `by (container)` (or the chart's grouping), so the three sides never share a label set.
- **Gauges keep their peaks.** Memory and fs usage are wrapped in `max_over_time(<gauge>[$s])` once the step is 5m or more, so the spike before an OOM survives.

### 4.3 Tiers per series

Each series has up to three forms, and the probe (§4.4) decides which one is used:
- **R**: the kubernetes-mixin recording rules (kube-prometheus-stack ships them);
- **N**: node-exporter;
- **C**: raw cAdvisor and KSM.

The legend and the caption name the form in use: "recording rules · scrape 30s", or "raw cAdvisor (≤ 6h)".

| Series | R | N | C |
|---|---|---|---|
| container CPU | `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{…}` (older mixins `…:sum_irate`; the probe picks) | — | `rate(container_cpu_usage_seconds_total{CAD,…}[$w])` |
| container memory | `node_namespace_pod_container:container_memory_working_set_bytes{…}` | — | `container_memory_working_set_bytes{CAD,…}` |
| active requests and limits | `cluster:namespace:pod_{cpu,memory}:active:kube_pod_container_resource_{requests,limits}` | — | `kube_pod_container_resource_{requests,limits}{KSM,resource=…} * on(namespace,pod) group_left() ACTIVE` |
| cluster or node CPU | `instance:node_cpu_utilisation:rate5m * on(instance) instance:node_num_cpu:sum` | `sum(rate(node_cpu_seconds_total{mode!~"idle\|iowait\|steal"}[$w]))` | `sum by (<NODE label>)(CTR_RATE(container_cpu_usage_seconds_total))`, ≤ 6h cluster-wide |
| cluster or node memory | `instance:node_memory_utilisation:ratio * …MemTotal` | `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` | `sum by (<NODE label>)(CTR_GAUGE(container_memory_working_set_bytes))`, ≤ 6h cluster-wide |
| workload pods | `namespace_workload_pod:kube_pod_owner:relabel{namespace="$ns",workload="$name",workload_type="$kind"}`, where `$kind` is lower case (`deployment`, `statefulset`, `daemonset`), as the mixin writes it (review) | — | the owner join of §4.5 |

(review) The R tier's CPU is a 5-minute rate whatever the step. At 1h and 30 s it is smoother than the C tier's, and the caption says "5 min averages (recording rules)", so that a short spike's absence isn't read as no spike. On a pod's or a container's tab at 1h or less, the C tier is used even when rules exist, because one pod's raw series are cheap.

### 4.4 The probe: `KubePromProfile`, once per context, in memory

It runs when Prometheus is first found for a context, and only when a chart that needs it is shown (or an agent asks); finding Prometheus does not run it. It runs again after an hour while charts show, on a 404 or 422, or when the provider changes. It is four instant queries (review: it said three, and the third did two reads), sent one after another, each with `timeout=20s`:

1. **What exists.** The selector touches every series of these metrics once, about 50k on a 2–5k-pod cluster. That is one instant read, well within the limits, but it is why the probe runs at most once an hour.
   ```
   group by (__name__) ({__name__=~"container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_cpu_cfs_throttled_periods_total|container_cpu_cfs_periods_total|container_fs_usage_bytes|container_network_receive_bytes_total|container_oom_events_total|kube_pod_status_phase|kube_pod_container_resource_requests|kube_pod_container_resource_requests_cpu_cores|kube_pod_container_status_last_terminated_reason|kube_pod_owner|kube_replicaset_owner|kube_node_status_allocatable|kube_horizontalpodautoscaler_status_current_replicas|kube_hpa_status_current_replicas|kube_horizontalpodautoscaler_status_target_metric|kube_resourcequota|node_cpu_seconds_total|node_memory_MemAvailable_bytes|node_uname_info|kubelet_volume_stats_used_bytes|kubelet_volume_stats_inodes_used|node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m|node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate|node_namespace_pod_container:container_memory_working_set_bytes|namespace_workload_pod:kube_pod_owner:relabel|cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests|instance:node_cpu_utilisation:rate5m|prometheus_tsdb_lowest_timestamp_seconds"})
   ```
   (review) The list gained the metrics the charts read but the probe didn't ask about: working set, CFS periods (C3's denominator), OOM events, phase (`ACTIVE`), last terminated reason, allocatable, MemAvailable, and inodes.
2. **Duplicates.**
   ```
   count by (job, metrics_path)(container_cpu_usage_seconds_total{container!=""}) or count by (job)(kube_node_info)
   ```
   More than one `metrics_path` pins `/metrics/cadvisor`. More than one KSM `job` pins the first one, in name order. The prometheus chart sets no `metrics_path` label, and then nothing is pinned by it. (review) The same answer names the cAdvisor job, which query 3 uses. A third arm of the union, `label_replace(count(container_cpu_usage_seconds_total{container!="",node!=""}),"overterm_s","node","","")`, decides `NODE`: `node` if it answers, else `instance`.
3. **Scrape interval.** (review) This is the cAdvisor job's own interval. Every target's `up` would give the slowest job in the server, often a 2-minute blackbox probe.
   ```
   600 / max(count_over_time(up{job="<cadvisor job>"}[10m]))
   ```
   The result is rounded to 15, 30 or 60 s.
4. **Retention.** `min(prometheus_tsdb_lowest_timestamp_seconds)`, and the chart hatches before that time: "Prometheus keeps data from Oct 28". (review) The metric exists only where Prometheus scrapes itself, and Thanos and VictoriaMetrics don't have it. Without it the retention is unknown: Custom allows 30 d, and an empty start is drawn as a gap, not hatched.

**One more query, only when a namespace's tab or X3 opens** without rules:
```
count(container_cpu_usage_seconds_total{namespace="$ns",container!=""})
```
It is kept with the profile. Below 2,000 series the raw tier is allowed for that namespace.

**What it derives:**
- `ksmMajor`: 1 if only `…_requests_cpu_cores` exists. The HPA label is then `hpa`, not `horizontalpodautoscaler`.
- `nodeExporterMapped`: true when `node_uname_info` exists (§4.6).
- `agentOnly`: true when the server answers that queries are unsupported, or 404s on `/api/v1/query` while the Service answers. The chart then reads "Prometheus at monitoring/prometheus-agent only forwards metrics to a remote store (agent mode); it can't be asked". It is never retried within the hour.

### 4.5 Workload selection and top-N

**By owner, in tier order:**
1. **The rule.** `* on(namespace,pod) group_left(workload) namespace_workload_pod:kube_pod_owner:relabel{…}`.
2. **A raw owner join, for a Deployment through its ReplicaSets.**
   ```
   * on(namespace,pod) group_left(replicaset) max by (namespace,pod,replicaset)(
       label_replace(kube_pod_owner{KSM,namespace="$ns",owner_kind="ReplicaSet"},"replicaset","$1","owner_name","(.*)")
       * on(namespace,replicaset) group_left() max by (namespace,replicaset)(kube_replicaset_owner{KSM,namespace="$ns",owner_kind="Deployment",owner_name="$name"}))
   ```
   StatefulSets, DaemonSets and Jobs use `kube_pod_owner{owner_kind="<Kind>",owner_name="$name"}` directly.
3. **A name regex**, labelled "pods matched by name". The alphabet below is Kubernetes' safe one.

   | Kind | Pattern |
   |---|---|
   | Deployment | `pod=~"$name-[bcdfghjklmnpqrstvwxz2456789]{1,10}-[bcdfghjklmnpqrstvwxz2456789]{5}"` |
   | StatefulSet | `pod=~"$name-[0-9]+"` |
   | DaemonSet, Job | `pod=~"$name-[bcdfghjklmnpqrstvwxz2456789]{5}"` |

**W3, by revision:**
- From the raw owner join: `sum by (replicaset)`.
- With rules or names: `sum by (rs)(label_replace(<by pod>,"rs","$1","pod","(.+)-[bcdfghjklmnpqrstvwxz2456789]{5}"))`.
- `KubeTimeline`'s ReplicaSets map each `rs` to its revision and image.

**Top-N in two reads**, because `topk` inside a range query wanders from step to step:
1. **An instant ranking, with no subquery.** (review) The ranking was `avg_over_time(<rate>[<range>:<$s>])`, a subquery that evaluates the rate once per step. The average rate over the range is the counter's increase over the range, read in one pass of the raw samples:
   ```
   CPU:    topk(5, sum by (pod)(rate(container_cpu_usage_seconds_total{CAD,<scope>}[<range>])))
   memory: topk(5, sum by (pod)(avg_over_time(CTR_GAUGE(container_memory_working_set_bytes)[<range>:<$s>])))   # rules: avg_over_time(<rule>[<range>]), no subquery
   ```
   Raw memory still needs a subquery to de-duplicate first, so it runs only at 24h or less. Raw CPU still reads every sample in the range: 2,000 series × 7d at 30 s is 40M samples, close to `query.max-samples`. So `KubeQueryCost` estimates the samples as series (from the profile's count) × range ÷ scrape. It ranks raw CPU at any range only under 10M, and otherwise ranks over the last 24h and says "ranked by the last 24h".
2. **One `query_range`** for the total, plus one for those names: `{pod=~"^(p1|p2|…)$"}` with at most 5, or 8 for namespaces and nodes.

The ranking is cached with the range. It is redone on a range change and every 10 refreshes.

### 4.6 The remaining queries

All are scoped by `namespace="$ns"` and, where it applies, `pod="$pod"`.

| Chart | Query |
|---|---|
| C1 peak (≥ 24h, one pod) | `max_over_time(sum by (container)(rate(container_cpu_usage_seconds_total{CAD,…}[$w0]))[$s:$r])`, where `$w0 = 4 × scrape` and `$r = max(scrape, 1m)`. (review: a fixed `[2m]` holds one or two samples on a 1m scrape, which is M0's own defect again) |
| C2 RSS | `max by (container)(container_memory_rss{CAD,…})` (a gauge: one series a container, as every gauge is; `max_over_time` past 5m steps) |
| C3 | `sum by (container)(increase(container_cpu_cfs_throttled_periods_total{container!="",…}[$w'])) / sum by (container)(increase(container_cpu_cfs_periods_total{…}[$w']))`, where `$w' = max($w, 5m)` |
| C4 | `sum(container_fs_usage_bytes{CAD,…})`; limit `kube_pod_container_resource_limits{resource="ephemeral_storage"}` |
| P3 | `sum(rate(container_network_{receive,transmit}_bytes_total{…}[$w]))`; drops `…_packets_dropped_total` |
| P4, W5 restarts | `sum(clamp_min(RST - RST offset $s, 0))`, where `RST = max by (namespace,pod,container)(kube_pod_container_status_restarts_total{KSM,…})`. (review) Restart bars need the step to be at least the scrape interval, so a counting chart's step is `max($s, scrape)`, and Live's 30 s step becomes 60 s on a 1m scrape. (M6 review) Not `changes(…[$s:])`: since Prometheus 3.0 a range and a subquery's range are left-open, so a window one step wide holds one sample at a scrape-sized step (Live, 1h) and counts nothing, misses the rise across each window's boundary at longer steps, and a subquery evaluates at the server's global interval (1m by default). The count against its own a step back has neither problem, and it is no subquery, so a workload's restarts need no cap on its pods |
| C2 OOM (P, older than the pod's `lastState`) | (review) `(clamp_min(RST - RST offset $s, 0) > 0) and on(namespace,pod,container) (kube_pod_container_status_last_terminated_reason{KSM,reason="OOMKilled",…} == 1)`, a marker per step it answers; `increase(container_oom_events_total{…}[$s + scrape]) > 0` (a window that always holds two samples; one marker a run of steps, so the overlap marks nothing twice) where it exists (cAdvisor ≥ 0.39), which also catches an OOM-killed child process that didn't restart the container. The bare `last_terminated_reason` gauge only says the last reason, not when |
| W4 | `kube_deployment_spec_replicas`, `kube_deployment_status_replicas_available`, `…_unavailable`; `kube_statefulset_status_replicas_ready`; `kube_daemonset_status_number_available` against `…desired_number_scheduled`; `kube_job_status_succeeded`, `…_failed` |
| H1 | `kube_horizontalpodautoscaler_status_{current,desired}_replicas`, `…_spec_{min,max}_replicas` (`kube_hpa_*` with label `hpa` on KSM 1.x) |
| H2 | `kube_horizontalpodautoscaler_status_target_metric` against `…_spec_target_metric`, by `metric_name` |
| N1 / N2 quota | `kube_resourcequota{namespace="$ns",resource=~"requests.cpu\|requests.memory",type=~"hard\|used"}` |
| N3 chip | one instant query: `avg_over_time((sum(KSM_REQ(cpu) * on(namespace,pod) group_left() ACTIVE) - sum(CTR_RATE(container_cpu_usage_seconds_total)))[<range>:<$s>])`, with `namespace="$ns"` inside every selector the fragments expand to (a matcher can't be put on an expression). Without rules it is offered only at 24h or less |
| N4 | `sum by (phase)(kube_pod_status_phase{namespace="$ns"} == 1)` |
| K1 / K2 | C-tier: `sum(CTR_RATE(container_cpu_usage_seconds_total{NODE}))`, with the probe's node label (§4.2; review: cAdvisor has no `node` label of its own). Requested: `sum(KSM_REQ(cpu) * on(namespace,pod) group_left() ACTIVE)` with `node="$node"` inside `KSM_REQ`'s selector, since KSM 2.x labels each request with its pod's node. (review: the earlier form joined an undefined `ACTIVE_ON_NODE`.) `kube_node_status_{allocatable,capacity}{node="$node",resource=~"cpu\|memory\|pods"}`, where KSM's `node` is the node's name in every profile |
| K4 | `count(max by (namespace,pod)(kube_pod_info{KSM,node="$node"}) * on(namespace,pod) group_left() ACTIVE)` against `kube_node_status_allocatable{node="$node",resource="pods"}`. (review) `kube_pod_info` alone counts Succeeded and Failed pods, which the limit doesn't |
| K5 | `kube_node_status_condition{node="$node",condition=~"MemoryPressure\|DiskPressure\|PIDPressure",status="true"} == 1`; `kube_node_spec_unschedulable{node="$node"}` |
| K2 node total, K6, K7 (node-exporter) | Mapped by `* on(instance) group_left(nodename) node_uname_info{nodename="$node"}`. On EKS the instance is usually `IP:9100`, and `nodename` is the node's hostname, which EKS uses as the node name. K6: `node_filesystem_{avail,size}_bytes{fstype!~"tmpfs\|overlay\|squashfs",mountpoint=~"/\|/local"}`. K7: `rate(node_network_{receive,transmit}_bytes_total{device!~"lo\|veth.*\|eni.*\|cali.*\|docker.*\|cni.*"}[$w])`. Without `node_uname_info` these charts are left out, and the tab says so. |
| V1 | `sum(kubelet_volume_stats_{used,capacity}_bytes{namespace="$ns",persistentvolumeclaim="$pvc"})`; projection (instant) `predict_linear(kubelet_volume_stats_available_bytes{…}[6h], 4*86400)` and ETA `available / -deriv(available[6h])` |
| V2 | `kubelet_volume_stats_inodes_used / kubelet_volume_stats_inodes` |
| PVC column | one instant query per namespace: `sum by (persistentvolumeclaim)(…{namespace="$ns"})`, as built |
| X3 | `topk` ranking `by (namespace)`, then the top 8 |
| R1 sizing | (review: per pod) `max by (container)(quantile_over_time(0.95, (sum by (pod,container)(rate(container_cpu_usage_seconds_total{CAD,<owner>}[$w5])))[7d:5m]))`, where `$w5 = max(5m, 4 × scrape)`, plus 0.5 and `max_over_time`. Memory: `max by (container)(max_over_time(CTR_GAUGE(container_memory_working_set_bytes{<owner>})[7d:5m]))` and its p95. Rules: `quantile_over_time(0.95, <rule>{<owner>}[7d])`, with no subquery. Without rules, at most 50 pods, which is about 2M samples |

### 4.7 Which source a chart uses, and what it says when it can't

`KubeChartSource.pick` is pure and runs per chart:
1. **Live, or no Prometheus:** the sampled form, if the chart has one. (review) Otherwise, in Live with Prometheus found, the Prometheus form over 15 minutes. Otherwise the chart says why, for example: "Throttling needs Prometheus; metrics-server reports only CPU and memory".
2. **1h or more, with Prometheus found:** Prometheus. The tier is the best one the profile allows. If no tier fits within the cost caps (§6.3), the chart says why and what to pick instead.
3. **Prometheus fails during a read:** the chart keeps its last answer, marked with its age. It says what failed in plain words, and offers "Show sampled" when a sampled form exists. The tab never switches source silently.

**The sentences are table-driven** (`KubeChartEmpty`, pure). Each has a test.

| Cause | Sentence |
|---|---|
| no metrics-server | "No metrics-server in this cluster: there are no usage numbers without it or Prometheus." EKS has none by default. |
| KSM missing | "kube-state-metrics isn't scraped: no requests or limits over time." |
| KSM 1.x | "kube-state-metrics is older than 2.0; requests and limits use its old names." This one is a footnote, and the chart still draws. |
| no throttling metrics | "This cluster's kubelet doesn't report CPU throttling." |
| cost refused | "Raw container metrics over 24h would read about 30M samples, and this Prometheus has no recording rules. Pick 6h or less." |
| timeout | "Prometheus took longer than 20 s. Pick a shorter range." |
| `bad_data` | "Prometheus refused the query: <its error>." This is a bug report: "Copy PromQL" is offered. |
| Thanos or partial | a footnote: "Partial answer: <warning>" |
| young pod | "Pod started 14:02", with the earlier time hatched |
| agent mode | see §4.4 |
| (review) 403 on the service proxy | "You can't reach monitoring/prometheus-operated here: `get services/proxy` is refused in monitoring." Said once a context; the queue stops for that context until its credentials change |
| (review) 403 on metrics.k8s.io | "metrics-server answered 403: you can't list pods.metrics.k8s.io in api." No retry every 15 s |
| (review) credential failure | The context's own sentence and button (§10, "stop requesting"). Every chart of that context stops, and the queue drops what it holds |
| (review) the filter's 403 (`Forbidden\n`, text/plain) | "Overterm's metrics proxy refused this path." This can only be a bug, since every query is one of the two accepted paths; it is reported as one, with Copy PromQL |
| (review) sampled, the requests line left out | "Requests need the pods' specs; pick one node or turn Prometheus on" (X1, X2, the Pods list's shares) |

### 4.8 Out of reach, decided

- **Amazon Managed Prometheus** is out. It needs SigV4 to `aps-workspaces` and isn't reached through the apiserver with kubectl's credentials.
- **Prometheus behind a path prefix** (Mimir, VictoriaMetrics' vmselect) is a later stage (§11, open decision 4).
- **kubelet's Summary API**, and with it a pod's real ephemeral use, is never used: it needs `nodes/proxy`.
- **Ingress charts** are out. The usual EKS ALB keeps its metrics in CloudWatch.
- **API server latency** is out.

## 5. Rendering

### 5.1 Decision: our own `Canvas`, not Swift Charts

| | Swift Charts | `Canvas` over a pure plot |
|---|---|---|
| Hover on macOS 13 | `chartXSelection` is macOS 14+; a hand-rolled `chartOverlay` reader works but re-evaluates every mark | `onContinuousHover`, binary search in the cached plot |
| A crosshair over six charts | each chart's body is re-run on every move | only the overlay layer redraws |
| 13 series × 300 points | each mark is a view | one path per series, built once |
| Geometry tests, `OVERTERM_DUMP_LAYOUT` | opaque | `KubePlot` is a value |
| Gaps, hatches, bands, stepped references | possible, but awkward | direct |

Swift Charts' axes and accessibility come free, but nothing else in its column outweighs the macOS 13 floor and the hover cost. **Decision: Canvas.**

### 5.2 Structure

- **`KubeChartData`** holds, per series, `[KubeSeriesPoint]`, with breaks as separators, plus its role (usage, request, limit, allocatable, capacity, quota, guide, peak, projection, band), unit, tier, notes and version.
- **`KubePlot`** is pure and built off the main thread. Given the data and a size, it produces:
  - the x and y scales. The y axis is rounded to nice values, starts at 0 for usage, and its top includes every visible reference line;
  - 3–5 ticks on y, and time ticks chosen by span;
  - one `CGPath` per series segment and per stacked band (cumulative, in legend order);
  - reference steps, marker positions, hatches and the points used for hit-testing.
  It is cached by `(data.version, size, hidden series)`.
- **`KubeChartView`** draws `KubePlot`'s paths in one `Canvas` pass. The header, legend and axis labels are SwiftUI `Text(verbatim:)`. It doesn't observe the cursor.
- **`KubeChartOverlay`** is a second `Canvas` stacked on the first. It alone observes `KubeChartCursor`, and draws the crosshair, the hovered points, the zoom band and the tooltip.
- **Decimation** keeps each pixel column's min and max (2 points a column). It runs when a series has more points than the plot has columns. Peaks always survive.
- **Style.**
  - Strokes are 1.25 pt; area fills are 0.15 alpha; references are dashed [3,3].
  - Series take a 10-colour categorical palette from `ChromeTheme`, checked in both appearances.
  - Request (green), limit (red), capacity and allocatable (grey) and quota (purple) are fixed by meaning. (review) Colour is never the only cue, since red and green are the pair most often confused. Each reference also has its own dash (request [3,3], limit [6,2], allocatable [1,2], quota [6,2,1,2]) and is labelled at its right end ("request", "limit").
  - There is no `drawingGroup()`.
- **Accessibility.**
  - Each chart's `accessibilityLabel` comes from `KubeChartSummary`, for example "CPU, last 1h: 120m now, peak 480m at 14:10, request 250m, limit 1".
  - Each chart's identifier is `kubernetes.chart.<subject>.<id>`.
  - (review) Each chart also gives an `AXChartDescriptor` (`accessibilityChartDescriptor`, macOS 12+) built from the same `KubePlot`. VoiceOver's Audio Graph then reads the series, which a `Canvas` otherwise hides behind its one label.
- **Dump layout.** For each chart, `OVERTERM_DUMP_LAYOUT` reports the series and point counts, the y maximum, the references, the markers, the source and the tier.

### 5.3 Performance targets (added to `kubernetesPerf`)

| What | Target |
|---|---|
| Metrics tab first draw, sampled, 9 charts | ≤ 50 ms on the main thread |
| Hover move, 13 series × 300 points | ≤ 2 ms per frame, over 200 moves; **a draw counter proves the series layers are not redrawn** |
| `KubePlot` build, same data | ≤ 5 ms off the main thread |
| Decoding an 8 MB answer | off the main thread, ≤ 150 ms |
| Steady state, Live, quiet fake cluster | idle CPU within the `performance` budget; one GET per target per 15 s |
| Steady state, 24h | ≤ 1 incremental `query_range` per chart per 5 min |
| Page hidden | no metrics reads; the metrics proxy closed within 60 s |
| Rings | ≤ 6 MB hard cap: 200 detail keys at about 2.5 MB, plus the list's raw points at about 3.2 MB for 5,000 pods (§4.1) |
| Chart cache | ≤ 96 entries and 12 MB |

Data is merged off the main thread and published in one assignment. `@Published` emits before the property changes, so sinks use the value they are given.

## 6. Ranges, budgets and safety

### 6.1 Ranges and steps

| Range | Source | Step | Points | Rate window (scrape 30 s / 60 s) | Refresh while shown |
|---|---|---|---|---|---|
| **Live** (15m) | sampled; Prometheus for a chart with no sampled form, or when there is no metrics-server | the sample's own (15 s); P: 30 s (60 s on a 1m scrape) | ≤ 60 / 30 | P: 2m / 4m | 15 s (P: the step), paused after 15 min idle |
| 1h | P | 30 s (60 s on a 1m scrape) | 120 / 60 | 2m / 4m | 60 s, incremental |
| 6h | P (sampled up to its folded 6h when there is no P) | 2m | 180 | 3m / 4m | 2 min, incremental |
| 24h | P | 5m | 288 | 6m (5m with rules) | 5 min, incremental |
| 7d | P | 30m | 336 | 31m, plus the peak band for one pod | 15 min, incremental |
| Custom, zoom | P | `max(scrape, nice(span/250))`, `nice` ∈ {15s, 30s, 1m, 2m, 5m, 10m, 15m, 30m, 1h, 3h} | ≤ 300 | the rule | none |

- **Alignment.** The end is aligned to the step, as `KubeChartRange.window` does now.
- **The hard check** is 11,000 points per series, Prometheus' own limit. The budget is 300.
- **Incremental refresh.**
  - `KubeChartCache` is per context, an LRU of 96 entries and 12 MB, keyed by `(query, range, step)`.
  - A refresh asks for `[lastEnd − k × step, alignedNow]`, where `k = max(2, ⌈(scrape + 30 s) ÷ step⌉)`. It replaces the points it got back, then drops points before the start. (review) Asking again from `lastEnd − step` kept a last point computed before its final scrape arrived: rates there are short and a gauge can be missing, so the line's end was wrong until the range changed.
  - A range change discards the old range's data at once, so it is never drawn on the new axis (Freelens' `lastResolvedRangeKey` lesson).
  - A cancelled answer is never cached as complete.
  - The cache is dropped on a context change, on a kubeconfig change, and 10 minutes after the page hides.

### 6.2 Read only while shown

- **The views register what they show.** Each chart registers a `KubeChartRequest` on appear and removes it on disappear, through `KubePrometheusMonitor.want` (as built) and `KubeMetricsMonitor`'s targets.
  - The charts sit in a `LazyVStack`, so a chart scrolled off removes its own want. A 9-chart pod tab with 3 on screen reads 3.
  - (M6, as built) A tab's Prometheus queries are one want (`KubeTabRequest`), its families asked together, except a node's top pods (K3: a series per pod on the node, about 110 a query), which their group's view asks only while it is on screen. A pod's, a workload's and an HPA's families are each one object's few series, every container's in one query; with `KubeChartCache` a refresh asks only each query's last steps. Asking them per chart would make every scroll a new request for a few series each; §6.5 counts what this costs.
  - Hiding the page, changing section or detail tab, or closing the detail removes every want at once.
- **The metrics proxy closes** 60 s after the last want, as built.
- **Nothing is prefetched.** Neither a neighbouring range nor a scrolled-off chart is read ahead of time.

### 6.3 The query queue and the cost caps

- **`KubePromQueue`** is an actor, one per context.
  - At most 4 queries are in flight.
  - Identical requests in flight are de-duplicated on `(query, start, end, step)`.
  - A request for a range or chart no longer wanted is cancelled.
  - Priority, highest first:
    1. visible charts, top first;
    2. the top-N ranking;
    3. peak and projection series;
    4. sizing.
  - (review) The page's charts and an agent's `k8s_metrics` share the one queue per context. An agent's queries rank below every visible chart and hold at most 2 of the 4 places, so an agent in a loop can't starve the page.
  - (review) A 429, or a 503 with a `Retry-After`, from the apiserver's proxy honours `Retry-After`, and the queue pauses for that context rather than per query. The pause is capped at 5 minutes (`KubePromQueue.maxPause`): a longer one is read as 5 minutes, and the chart's sentence says the pause taken, never the raw header. Only a whole, non-negative number of seconds is read; an HTTP-date or anything else is no `Retry-After` (asked again at the next refresh). A 503 without one is a Prometheus down or not ready (the apiserver's "no endpoints available"), said in its own words, not as busy. A credential failure or a 403 on `services/proxy` empties the queue and stops it (§4.7). Nothing is retried in a loop.
- **`KubeQueryCost`** is pure. It decides before sending, from the profile:
  - Raw cAdvisor across the cluster: spans of 6h or less only.
  - Raw across a namespace: only below 2,000 series (§4.4).
  - Subqueries (the peak band, sizing): one pod or container, or one workload of at most 50 pods, or with rules.
  - A regex of names holds at most 50; beyond that, pods are selected by owner.
  - A refused query is never sent. Its sentence says why and what to pick instead.
- **Every answer:**
  - carries `timeout=20s`;
  - is capped at 8 MB;
  - is capped at 12 series per chart plus "other". For a stacked top-N the cap is the N plus "other".

### 6.4 The proxies and paths: unchanged

- **No new process.** Prometheus reads use the existing metrics proxy (`KubeProxies.sendPrometheus`). It has its own slot within `maxProxies` and never takes the page's slot. Background watches give way first, as built.
- **`--accept-paths` is not changed.** It stays one Service's `^/api/v1/namespaces/<ns>/services/<svc>:<port>/proxy/api/v1/(query|query_range)$`, with GETs only. Every query in this design is one of those two paths, including the probe, the ranking, the projection and sizing. Nothing in it needs the labels or series APIs.
- **metrics.k8s.io and the HPA, node and pod GETs** go through the page's proxy, as today's usage reads do.
- **`nodes/proxy` and the kubelet are never reached.** Every socket refuses them already.
- (review) **The one exception to "only while a chart shows"** is an agent's explicit read, like every `k8s_` tool: `k8s_metrics` (M11), and since M5b `k8s_top`'s shares across a namespace (§7). It may open the metrics proxy of a context whose page isn't shown, in a background slot (`KubeProxies.Role`, as `k8s_` reads use), for that call, through the context's queue as an agent. The proxy closes when idle. analysis.md §4 and §10 ("runs only while a chart shows") say so since M5b. Such a call never runs on a context whose Prometheus isn't opted in.
- **Nothing is installed, and nothing about a cluster is written to disk.** The rings, the profile and the cache live in memory and end with the context.

### 6.5 What a tab costs (counted against §10)

| Shown | apiserver GETs per minute | Prometheus queries |
|---|---|---|
| a pod's Metrics tab, Live | 4 (the pod's metrics) + 1 (the pod's object, for its markers, M4) | 0 without Prometheus; with it, the on-screen Prometheus-only charts (C3, P3, P4), each 1 per step (30–60 s) |
| a pod's tab, 1h, 3 charts on screen | 1 (the pod's object, for its markers, M4; with metrics-server) | (M6, as built: the tab's families together, §6.2) 7 on open (CPU, memory, RSS, throttling where a container has a CPU limit, network, restarts, OOMs), 7 per minute, each its last 2 steps (incremental); 24h and 7d add the peak band |
| a workload's tab, Live | 4 (its pods' metrics) + 1 (status) + 1 once (the HPA Table) + 1 (its pods by selector as objects, ≤ 250 and ≤ 16 MB, restarts and last terminations kept, for its markers, M4; stopped on a 403 or a failed sign-in) | 0 |
| an HPA's tab | 4 (the HPA) + 4 (its target's pods) | 0 Live |
| a node's tab, Live | 4 (the node's metrics) + 0.2 (its pods as objects, every 5 min); after "Sample top pods", + 8 at most (4 namespaces × 2), or 0 when the page's all-namespaces list is already polled, for at most 15 min | 0 |
| a namespace's tab, Live | 4 (its pods' metrics) + 1 (the Metadata Table, paged) | 0 |
| Overview, 24h | 4 (`/nodes`, as built) | (review) about 6 on open (X1 and X2 one union each, X3 ranking and range, X4 CPU and memory by node), then 6 per 5 min |
| page hidden | 0 | 0 |

Per context there are at most 3 metrics targets for a detail, plus the page's own (the Nodes and Pods columns, the Overview). A fourth detail target replaces the oldest. The markers' read of a pod's or a workload's pods' states (M4) is not one of them: a workload's tab already takes the three (its pods, its replicas, its HPA), so it is read by the tab itself, a minute apart, by the same rules — only while shown, bounded, stopped on a 403 or a failed sign-in.

## 7. Agents

**`k8s_top`** (exists) gains `%CPU/R %CPU/L %MEM/R %MEM/L` for pods and containers, from the same sample and the pod's spec. It also gains `range`, which reads from the ring when the object was shown. Otherwise it is unchanged and bounded.

**`k8s_metrics`** is new, in `KubeMCP+Metrics`, and is listed in `KubeMCP.reads`.

- **Arguments:**
  - `kind`: `pod`, `container`, `workload`, `namespace`, `node`, `pvc`, `hpa` or `cluster`;
  - `sizing`: a boolean, for `container` and `workload` only (review: sizing is a question about an object, not a kind of object);
  - `name`, `namespace`, `container`, `context`, which default as the other `k8s_` tools do (the page's, or the bound checkout's);
  - `range`: `15m`, `1h`, `6h`, `24h` or `7d`; the default is `1h`;
  - `measures`: any of `cpu`, `memory`, `throttling`, `network`, `restarts`, `replicas`, `volume`, `fs`.
- **The answer** is text, bounded to about 4 KB through `KubeMCPText`. Per measure it gives:
  - min, p50, p95, max and last, with their times;
  - the reference lines and the % of each;
  - restart and OOMKilled times;
  - the markers in range (rollout revision and image, scaling), through `KubeChartMarkers`;
  - the source, tier, step and window;
  - any missing parts of the profile, as sentences.

  For example:
  `memory api/api-7f9…/app 1h @30s rules: last 412Mi (81% of limit 512Mi), p95 498Mi, max 509Mi at 14:10; OOMKilled 14:11; rollout rev 14 nginx:1.27.2 at 13:58`.
- **Where the numbers come from:**
  - **With Prometheus:** the charts' own queries, through `KubernetesModel.agentClient` and the metrics proxy, under the same caps and queue. The proxy is opened for the call and closes after its 60 s idle. It never takes the page's slot.
  - **Without Prometheus:** the ring, if the object was shown ("sampled while shown since 14:02"). Otherwise one metrics.k8s.io read now ("now only; no history without Prometheus"). Agents always get an answer.
- **`sizing`** runs R1's queries once, under R1's bounds.
- **No free-form PromQL tool.** An agent can't send its own query; the queries are the design's, and they are capped.
- (review) **Label values are text from the cluster.** Pod, container and workload names, and Prometheus warnings, go through `KubeMCPText`'s scrub (`Secrets`) like every other `k8s_` answer, and are cut to 253 characters. A Prometheus `bad_data` message is quoted as data, never as instructions.
- (review) **`k8s_top`'s shares** need the pod's spec: for named pods, one GET each (at most 10). For a namespace, Prometheus' KSM query (§2.1) when it is on, else the raw usage only, saying "shares need the pods' specs". (M5b, built) The KSM query is asked for the call (`KubePrometheusMonitor.agentShares`: where Prometheus is and its profile as the page found them, else looked for and probed now), for at most 10 namespaces and none across all; where it fails, what the Pods list last read whole for those namespaces, said as such. With containers listed, a pod's shares are on its own `(pod)` line. A named pod whose object can't be read says why. A native sidecar (an init container with `restart_policy="Always"`, KSM 2.10) is counted in the list's denominators as in the pod's own spec; a pod whose sample has more containers than KSM lists (a sidecar KSM before 2.10 can't tell) has no share.
- **Ask Why.** `KubeAgentText` gains a bounded "Usage" part: C1 and C2's summary for the failing container over the last hour (or what was sampled), with its OOM markers. It is included when it is cheap: rules exist, or it is one pod. Its words go through `Secrets` like the rest of the brief.

## 8. Tests and scenario checks

### Unit (pure)

| Test | What it checks |
|---|---|
| `KubeRateWindowTests` | the window for each scrape and step, never under 4 × scrape |
| `KubeChartRangeTests` | steps, ≤ 300 points, end alignment, Custom validation, zoom steps, Live's source |
| `KubePromQLTests` (extended) | every chart's query as a golden string per tier; literal and regex escaping (`"`, `\`, metacharacters, a namespace with `.`); the `label_replace` union; owner joins; the alphabet regexes; the `metrics_path` and `job` pins; the `node_uname_info` mapping |
| `KubePromProfileTests` | capability answers into `requires`; sentences per missing metric; agent mode; duplicate pins; the node label (`node` against `instance`); the cAdvisor job's scrape, not the slowest job's; scrape rounding; retention, and no retention metric |
| `KubeQueryCostTests` | refused spans and namespaces; subquery gating; a name regex over 50 refused |
| `KubePrometheusReaderTests` | scalar, vector, matrix; warnings and infos kept; histograms skipped and counted; NaN and Inf as gaps; the per-chart cap with "other"; segments broken at 2 × step |
| `KubeUsageRingTests` | timestamp de-duplication; gaps at 2.5 × interval; folding into min/avg/max; trimming at 6h; the two populations (5,000 list rows never evict a detail key; LRU at 200 detail keys); forgetting after 1 h; dropped on a context switch and on a credential failure; workload and namespace sums across pods with different timestamps, with a pod missing from a poll; the 6 MB cap |
| (review) `KubePromDedupTests` | golden strings showing every chart sums `CTR_GAUGE`, `CTR_RATE` or `KSM_REQ`, never a raw series; a fixture with a restarted container (two IDs overlapping for 5 min) draws no spike; one with two KSM replicas doesn't double requests |
| (review) `KubeNodeSpecsTests` | the node's pods as objects decoded to requests, limits and phase with env dropped; above 250 pods the line is left out with its sentence; Succeeded pods not counted in K4 |
| (review) `KubeSizingTests` | a 10-pod workload's suggestion is per pod, not ten times it; memory from the max; an OOM in the window adds its note |
| `KubeChartMarkersTests` | timeline, events, OOM `finishedAt` and restart deltas into markers within the range; the 50 cap and "+N earlier"; the "events: last hour" note |
| `KubePlotTests` | scales including references; stacking order; min/max decimation keeping peaks; gap segments; hatches; the nearest point for an x; the cache key |
| `KubeChartSourceTests`, `KubeChartEmptyTests` | the ladder per chart, including a Prometheus-only chart in Live with and without Prometheus; every sentence, the 403s and the credential failure included |
| `KubeWorkloadNameTests` | Deployment, StatefulSet, DaemonSet and Job pod names |
| `KubeChartCacheTests` | an incremental merge drops points before the start; a range change discards; a cancelled answer isn't cached |
| `KubePromQueueTests` | 4 in flight; de-duplication; cancellation; priority order; an agent holds at most 2 places; `Retry-After` pauses the context; a credential failure empties it |
| `KubeMCPMetricsTests` | the text for each kind, bounded; the sampled and Prometheus captions; sizing numbers |

### The fake (tests only)

- **`FakeKubeAPI.setPrometheusMatrix`.** A fixture is matched by a fragment the query contains, or by a normalised string. It is not matched by parsing PromQL.
  - Built with M0's fix pass, beside `FakePromQL`: the fake also evaluates M0's own queries (selectors, `rate`, `sum`/`max`/`min`/`count` by, `== n`, `* on(…) group_left()`) over `setPrometheusSeries`' values, so the de-duplication and the active-pod join are shown on data. That evaluator is not extended: anything past it (`label_replace`, `max_over_time`, subqueries, `or`, offsets) is a fragment fixture. A fixture is matched first; one without lines adds its warnings to what `FakePromQL` evaluates.
  - Range fixtures are functions of t, so gaps, ramps and steps can be scripted.
  - A fixture can also script an error (`bad_data`, a timeout, 404), a delay, a Thanos warning or agent mode.
  - A query that matches no fixture is answered 400 `bad_data` and recorded, so a test fails loudly.
- **Profiles** in `Tests/OvertermTests/Fixtures/prometheus/`:
  - `kube-prometheus-stack`: rules, 30 s scrape, duplicate `metrics_path`, `node` label, two KSM replicas;
  - `prometheus-chart`: no rules, 1 m scrape, `app.kubernetes.io` labels, `instance` as the node, no `metrics_path`;
  - `agent-mode`;
  - `containerd-no-fs`;
  - `efs-pvc`;
  - `ksm-1x`;
  - `no-node-exporter`.
- **metrics.k8s.io.** `setPodMetrics(ns, pod, containers, timestamp)` with an advancing timestamp, plus the single-pod and single-node paths, and the HPA object.
- **Asserted on the recorded requests:**
  - only `query` and `query_range` reach the metrics proxy;
  - `timeout=20s` on every query;
  - at most 4 in flight;
  - nothing while hidden, and nothing after the wants are gone;
  - no `nodes/proxy` path anywhere.

### E2E (`E2ERunner+Kubernetes`, a new `kubernetesCharts` scenario)

The fake cluster serves sampled metrics, and Prometheus with the `kube-prometheus-stack` fixture.

1. **A pod's detail, then `m`.** The range is Live and the data sampled, with two charts per container. The dump shows a request and a limit reference, a restart marker from the fixture's `lastState`, and the caption "Sampled from metrics-server".
2. **Prometheus on, then `.` to 1h.** The throttling chart appears, its tier is "recording rules", and only `query_range` and `query` against the one Service are recorded.
3. **Hover at a fixed point.** The tooltip text matches, through `kubernetes.chart.tooltip`, and the draw counter shows no series layer redrawn.
4. **A zoom, driven through the dump hook.** A request goes out at the zoom's step, and Reset restores the range.
5. **A Deployment's tab.** W3 has two ReplicaSet lines labelled with their revisions.
6. **A PVC on `efs-pvc`.** No %, no projection.
7. **The `agent-mode` fixture.** The plain sentence shows, and nothing is retried within the scenario.
8. **Hide the page.** No metrics request within 20 s; the metrics proxy's pid is gone within the scenario's shortened idle.
9. **`k8s_metrics` through the MCP.** The text is bounded and contains "81% of limit".
10. **Expand.** The chart opens in the right slot and takes the slot by the `RightSlot` rule.
11. (review) **A Live pod tab with Prometheus on.** The throttling chart draws from a 15-minute `query_range` and doesn't say "needs Prometheus".
12. (review) **An OOM marker's click** opens Logs with Previous on, and "Logs from here" sets `sinceTime` in the recorded request.
13. (review) **The Pods list's shares with `prometheus-chart`.** One instant KSM query per namespace shown; without Prometheus, dashes with their sentence and no pod object read.

`kubernetesPerf` adds §5.3's targets, with 13 series × 300 points. No test reaches a real cluster. An isolated run has no kubeconfig unless `OVERTERM_KUBECONFIG` names one.

## 9. Stages

Each stage is one commit. Before each: `swift format`, `make test`, `make e2e`, and `Scripts/bump-version.sh`. Docs (architecture.md's Kubernetes paragraph, analysis.md §2.11 and §10) change in the commit that changes the behaviour.

| Stage | Commit subject | What | Bump |
|---|---|---|---|
| **M0** | `kubernetes: Prometheus charts read the right window and count active pods` | §1.1, only what needs no probe: the rate window (scrape taken as 60 s), `helm` and `helm14` providers, active-pod requests, KSM and container de-duplication (`max by` / `sum by` container), raw cluster charts ≤ 6h with a sentence beyond, the reader (scalar, warnings, segments), `timeout=20s`. The `metrics_path` and job pins and the tiers wait for M5 (review) | PATCH |
| **M1** | `kubernetes: a chart drawn in one Canvas, with a shared crosshair` | `KubePlot`, `KubeChartView`, `KubeChartOverlay`, `KubeChartCursor`, legend, reference lines with their dashes, min/max decimation, `AXChartDescriptor`, dump output; `KubeRangeChart` replaced. (review) The hover and draw-counter perf checks of §5.3 land here, not in M12; the stage that makes the overlay proves it | MINOR (review: the existing charts gain hover, axes and a legend, which a person sees) |
| **M2** | `kubernetes: usage kept while shown in two tiers` | `KubeUsageRing` replaces `KubeUsageHistory`, with the two populations and the 6 MB cap; the single-pod, node and HPA targets; the per-detail target cap; the 403 rule for metrics.k8s.io | PATCH |
| **M3a** | `kubernetes: a Metrics tab on pods, from metrics-server` | `KubeDetailTab.metrics`, `m`, `,`/`.` over Live and 6h (sampled); C1, C2, P1, P2 sampled with spec references and chips; restart and OOM markers from `lastState` only, opening Logs with Previous; "Logs from here"; `kubernetesCharts` parts 1, 3 and 12. (review) Today's Prometheus pod chart (`KubePrometheusChartView(.pod)` in the Overview tab) stays as it is until M6 replaces it, so no context loses its 1h–7d chart between stages. analysis.md §2.11's range row changes here | MINOR |
| **M3b** | `kubernetes: the Metrics tab on workloads, HPAs and nodes` | W1, W2 (Total and Per pod, template references), W3 (sampled: Deployments by hash, StatefulSets and DaemonSets by `controller-revision-hash`), W4, H1, H2 and the workload's HPA lookup, K1, K2, K4 (the node's pods as objects), K5; "Sample top pods"; the namespace tab sampled (N1, N2, N4 from Metadata rows) | MINOR |
| **M3c** | `kubernetes: the Nodes list's heat strips` | the Nodes strip. (review) The Pods list's shares and `k8s_top`'s move to M5b, since without Prometheus they have no denominator in a list (open decision 10) | MINOR |
| **M4** | `kubernetes: change markers on every chart` | `KubeChartMarkers`, popovers, ±30 min, the 50 cap; (M3b review) W2's OOM and restart markers for every pod, from a bounded read of the workload's pods' `lastState` | MINOR |
| **M5** | `kubernetes: Prometheus is probed once a context` | `KubePromProfile` (four queries, the node label, the cAdvisor job's scrape), tiers, `KubeChartEmpty` (the 403s and the credential failure included), agent mode, pins, retention; `KubeQueryCost` (the samples estimate); `KubePromQueue` (`Retry-After`, the agent's two places) | PATCH |
| **M5b** | `kubernetes: request and limit shares in the Pods list` (review) | `%CPU/R %CPU/L %MEM/R %MEM/L` in the wide view from one KSM instant query per namespace shown; dashes with their sentence without Prometheus (or open decision 10's choice); `k8s_top`'s shares; `kubernetesCharts` part 13 | MINOR |
| **M6** | `kubernetes: the Metrics tab over 1h to 7d and custom ranges, from Prometheus` | §6.1's ranges, Live's pause, Live's Prometheus form for the charts without a sampled one, Custom, drag zoom, incremental refresh (`k` steps again), `KubeChartCache`; the Prometheus forms of the M3 charts plus C3, P3, P4, W5, and the Prometheus OOM markers; today's `KubePrometheusChartView(.pod)` removed; `kubernetesCharts` parts 2, 4 and 11 | MINOR |
| **M7** | `kubernetes: a workload's pods by revision, top five and the rest` | owner joins, the two-read top-N without subqueries and its re-rank, W3 over Prometheus (Deployments), the namespace tab's Prometheus forms (N1, N2, N4, the N3 chip), quota references; `kubernetesCharts` part 5 | MINOR |
| **M8** | `kubernetes: the Overview's usage by namespace and node; PVC fill forecast` | X1–X4 replacing the cluster chart; V1's projection, V2, the EFS rule; C4 behind the probe and its sentence; K2's node total behind `node_uname_info`; `kubernetesCharts` part 6 | MINOR |
| **M8b** | `kubernetes: a node's disks and network from node-exporter` (review) | K6, K7. The lowest priority, and the first stage to drop if the work is cut | MINOR |
| **M8c** | `kubernetes: GPUs — allocation from the objects, utilisation and memory from DCGM` | decision 12: the GPU resources on nodes and pods without Prometheus; the probe's DCGM check; G1 utilisation, G2 framebuffer memory, G3 power and temperature on node, pod, container and workload tabs; idle-but-allocated; MIG; the fake's DCGM fixtures; a `kubernetesCharts` part | MINOR |
| **M8d** | `kubernetes: a context's saved queries on a workload's Metrics tab` | decision 11: `charts` in `kubernetes.contexts` (SettingsSchema), `$ns`/`$pod`/`$name` filled in escaped, scope matchers required, the cost caps; user-written only | MINOR |
| **M9** | `kubernetes: a chart expands into the right slot` | `KubeManifestPane.Shown.chart`; Copy PromQL and CSV | MINOR |
| **M10** | `kubernetes: rightsizing from seven days of usage` | R1, per pod, CPU from p95 and memory from the max; the Sizing button, its bounds | MINOR |
| **M11** | `kubernetes: k8s_metrics for agents, and usage in Ask Why` | `KubeMCP+Metrics` (`sizing` a flag, label values scrubbed, the background-slot exception written into analysis.md §4 and §10), `KubeAgentText`'s Usage part, "Ask agent about this chart"; `kubernetesCharts` part 9 | MINOR |
| **M12** | `kubernetes: charts' performance budget` | the rest of §5.3 at scale (13 series × 300 points, 50 nodes in X4, the 6 MB ring), and whatever they find | PATCH; no bump if tests only |

**The floor is M0–M4.** Every EKS cluster with metrics-server then gets the charts that matter for "why did this pod die": per-container usage against request and limit, OOM and rollout markers with the previous container's log one click away, and HPA and node charts. M5–M8 are the depth, and M10–M11 are the payoff for agents. M8b is optional.

(review) **Each stage names its scenario parts** above. A stage whose part can't run yet (Prometheus before M5) adds the unit tests and leaves the part for the stage that makes it runnable. A stage is never done with a scenario part merely written and skipped.

## 10. Open decisions

| # | Question | Options | Recommended |
|---|---|---|---|
| 1 | How long the ring keeps a detail key after it stops being fed | 0 (today's rule: hidden means gone) · 10 min · 1 h · 6 h | **1 h, 200 detail keys, list keys as today.** Coming back to a pod after lunch shows what was sampled before, with the hidden time drawn as a gap; the bound is 6 MB. (review) This changes today's contract in `KubeUsageHistory` ("nothing here outlives the reading"), which is why it is the user's call. It is memory only and is still dropped on a context switch, a credential failure and at quit. **Decided (2026-11-07): 1 h.** |
| 2 | Live with Prometheus | always sampled when metrics-server answers · always Prometheus at 30 s | **Sampled when metrics-server answers**, and Prometheus at 30 s only without it. Live costs no queries in the common case. |
| 3 | Compare with yesterday (`offset 1d`) | out · a legend toggle that queries only while it is on | **A toggle, after M8** (its own MINOR). It costs one query per chart, only while on. |
| 4 | Prometheus behind a path prefix (Mimir, VictoriaMetrics) | out · `prometheusPathPrefix` in `kubernetes.contexts` | **A later stage.** The prefix goes into `KubePrometheusFlags.acceptedPaths`, still anchored and escaped, and still only `query` and `query_range`. The accept-paths never get wider than that. |
| 5 | Amazon Managed Prometheus | out · SigV4 through `S3Signer` with the kubeconfig's AWS profile | **Out.** It leaves "through the apiserver with kubectl's credentials". It would need its own design. |
| 6 | Node-exporter charts on a node | joined through `node_uname_info` · through `kube_pod_info`'s host IP · left out | **`node_uname_info`.** Without it, K6 and K7 are left out and the tab says so. The host-IP join is what breaks Lens. |
| 7 | The range's default | a setting (`kubernetes.chartRange`) · Live/1h, remembered per session | **No setting.** Live when metrics-server answers, else 1h, remembered for the session. |
| 8 | "Top pods on this node" without Prometheus | polled by default · on request | **On request** ("Sample top pods"). (review) It costs at most 8 GETs a minute (4 namespaces at 30 s), or none when the page already polls every namespace, and it stops after 15 minutes. |
| 9 | A chart with more than 12 lines | spaghetti · stacked top-N plus other | **Stacked top-N plus other**, with legend isolation; a workload's Per pod view draws its top 5 as lines (§2.5). |
| 10 | (review) The Pods list's `%CPU/R…` without Prometheus, where rows carry no spec | dashes and "needs Prometheus" · one paged list of the selected namespace's pods as objects (≤ 500 pods, about 6 MB, decoded to requests and dropped, read once and again on the watch's ADDED events, by GET for each new pod) · out | **Dashes and the sentence for now.** The second option is real work, roughly 6 MB a namespace to read, and it breaks §10's "rows only" for the list. Decide after M5b, from whether the user misses it on EKS. **Decided (2026-11-07): dashes and the sentence.** |
| 11 | (review) The user's own application metrics: request rate, latency, queue depth, which Prometheus already has for many apps | out · saved queries per context in `kubernetes.contexts` (`charts: [{title, query, unit}]`), shown on the workload's Metrics tab with `$ns`/`$pod`/`$name` filled in and escaped, user-written and never an agent's · a PromQL box on the tab | **Saved queries per context, after M8**, as their own MINOR. A developer's real question after "is it CPU?" is usually "is it my endpoint?", and the paths stay `query` and `query_range`. They are typed by the user into settings, so §7's "no free-form PromQL for agents" holds. The cost caps apply: a query without the scope's matchers is refused. **Decided (2026-11-07): saved queries per context, stage M8d.** |
| 12 | GPU charts on GPU nodes (LLM workloads) | out · probed and shown when present | **Decided (2026-11-07): probed and shown when present, stage M8c.** Without Prometheus: a node's and a pod's `nvidia.com/gpu` (and `amd.com/gpu`) capacity, allocatable and requests from the objects already read — which pods hold which GPUs, none idle-but-allocated hidden. With Prometheus, when the probe finds DCGM exporter (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`/`_FREE`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_PROF_GR_ENGINE_ACTIVE` where profiling metrics are on; its `pod`/`namespace`/`container` labels, or `exported_*` when honor_labels is off): GPU utilisation, framebuffer memory against total, power and temperature per GPU on a node's tab, per container on a pod's, a workload's GPUs by pod; an allocated GPU idle over the range said plainly (the costly case); MIG instances by `GPU_I_PROFILE`. Same budgets and caps; the probe adds one query. |
| 13 | (review) A workload's W1/W2 default view | Total (stacked) · Per pod (lines) · Per pod when ≤ 5 pods | **Per pod when ≤ 5 pods, else Total**, remembered per page in memory. |
| 14 | (review) The times on the axes and in the tooltip | local time · UTC · a toggle | **Local, with the zone in the tooltip ("14:32:15 GMT+3")**, since Grafana and CloudWatch links the user pastes from are often UTC. No setting unless asked. |

## 11. What the review changed (2026-11-07)

Each change is marked "(review)" where it was made.

**It broke a rule, or contradicted what is built**
- The Pods list's `%CPU/R…`, X1/X2's sampled requests, K1's requested line and `k8s_top`'s shares assumed pod specs that a Table row (`includeObject=None`) doesn't carry. The list's shares now come from KSM, and wait for M5b. A sampled X1/X2 has no requests line. A node's tab reads its own pods as objects, bounded at 250 and decoded with env dropped. W1's references come from the template.
- The ring shared one 1,000-key LRU with the Pods list's 5,000 rows, so the list would push out the pod being looked at. Its 13 MB bound also undercounted the folded tier. There are now two populations, `Float32` points and a 6 MB cap.
- The agent's `k8s_metrics` opening the metrics proxy with no chart shown is now named as the one exception to analysis.md §10, in a background slot, written into §4 and §10 in M11.
- "Sample top pods" could cost 32 GETs a minute. It is now ≤ 8, reuses the page's list when there is one, and stops after 15 minutes.
- 403s (metrics.k8s.io, `services/proxy`) and credential failures had no sentence and no stop rule, which risked a retry loop against §10.

**A query was wrong or too costly**
- cAdvisor has no `node` label of its own, so the probe now picks `node` or `instance`. `ACTIVE_ON_NODE` was undefined.
- A container's restart doubled its series, and two KSM replicas doubled requests. Every sum now goes over `max by` or `sum by` container first.
- `__s` is a reserved label prefix and is now `overterm_s`.
- The top-N ranking used a subquery where `rate(…[range])` is the same average at a fraction of the cost, now gated by a samples estimate.
- C1's peak used a fixed `[2m]`, which is M0's own bug.
- Sizing took quantiles of the workload's sum, about N times too high. It is now per pod, with memory sized from the max.
- K4 counted finished pods. Restart bars could miss restarts at steps below the scrape interval. Incremental refresh kept a half-scraped last point.
- The probe's scrape interval came from every job's `up`, which gives the slowest job. It missed metrics the charts read, and assumed `prometheus_tsdb_lowest_timestamp_seconds` exists.
- W3 for StatefulSets and DaemonSets had no hash in the pod name.

**A chart nobody needs**
- N3's band is now a chip. C4 is drawn only where the cluster reports it. K6 and K7 moved to an optional last stage (M8b).

**What a developer would miss**
- A restart or OOM marker opens the previous container's log.
- "Logs from here" at the crosshair.
- A Per pod view for imbalanced pods.
- Prometheus-only charts work in Live.
- A gone pod's drill-down says so.
- Reference lines aren't told apart by colour alone.
- VoiceOver's Audio Graph.
- Earlier OOMs over Prometheus.

**The fake (M0's fix pass)**
- `FakePromQL` evaluates M0's queries so its de-duplication is tested on data; it stays that small. `setPrometheusMatrix`'s fragment fixtures, matched before it, answer every later query (§8).

**Vague stages**
- M0 no longer depends on M5's probe.
- M1 owns its perf check and is a MINOR.
- M3a keeps today's Prometheus pod chart until M6.
- Each stage names its scenario parts.
- The Overview's query count is corrected.

**Open for the user:** decisions 1 (keeping a detail's samples an hour after it hides), 10 (the list's shares without Prometheus), 11 (saved queries for the user's own app metrics), 12 (GPU), 13 and 14. Also: do the user's EKS clusters run metrics-server, and which Prometheus, if any (kube-prometheus-stack, the prometheus chart, AMP only)? The design's floor assumes metrics-server, and decision 5 leaves AMP out.
