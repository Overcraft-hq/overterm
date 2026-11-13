# Kubernetes — Argo CD and Flux on one screen, and in the checkout's rail

This design covers two things:

- **A GitOps section on the Kubernetes page.** Every Argo CD Application and ApplicationSet, and every Flux Kustomization, HelmRelease and Source, that lives in the scope or deploys into it, on one screen.
- **A GitOps part in the checkout's Kubernetes rail panel.** Which objects deploy this repository, and whether this branch's commit has reached the cluster.

It also covers what is read and when, the verbs and their guards, the agents' tool, the tests and the stages. It extends `docs/design/kubernetes/analysis.md` (§2.23, §3.9, §4, §5, §10, decision 24) and the code on `kubernetes` at `1261668`. It ships on this branch in 1.6.0, after the metrics work (M0–M12).

No kubectl, helm, flux or argocd was run against a cluster to write this. Object shapes come from the Argo CD and Flux docs and CRDs. Fields marked **[verify]** must be checked against the pinned CRD schemas (§8.5) before code relies on them. Every name here is fictional.

## In short

- **The section summarises; it is not a new kind list.** `KubeSection.gitops` ("GitOps", key `g`) shows one row per object, problems first, with its state, why, revision, source and destination. ↩ opens the object in its own kind's list with the detail open, so the tree (`x`), the YAML and every verb are the ones that already exist. Argo's and Flux's kinds stay in Custom Resources, and `:app` and `:ks` keep working. This takes decision 24's "dedicated dashboards" option as a summary only.
- **One state ladder for both tools** (`KubeGitOpsState`), decided from the object, never from how long the app has been watching:
  - It is evaluated in this order: Paused, Blocked, Failed, Stuck, Drift, Progressing, Ready, Unknown.
  - It is shown problems first: Failed, Blocked, Stuck, Drift, Progressing, Paused, Ready, Unknown.
  - A suspended object is Paused before anything else. A failing Source makes its users Blocked, naming the cause, not Failed.
  - Auto-sync's OutOfSync is Progressing only while Argo is actually on it.
  - K602 and K603 use the same functions as the section.
- **Scope means where an object lives or what it deploys into.** An object is kept when one of these is in scope:
  - its own namespace;
  - a namespace it manages, read from its inventory or `status.resources`;
  - when it has applied nothing yet, its in-cluster destination namespace.
  
  A Source is kept when a kept object uses it. An object deploying to another cluster is kept only by its own namespace.
- **Three reads, all only while the page shows:**
  - **R1:** rows-only Table follows of five kinds across the cluster, plus Argo's and Flux's controllers.
  - **R2:** one byte-bounded, paged list of whole objects per kind, decoded straight into allow-listed `Decodable` structs. No `[String: Any]` tree is ever built.
  - **R3:** GETs of single objects, when a row's cells change, or every 15 s for a row that isn't healthy.
  
  Summaries are kept in memory for 5 minutes while the page shows, so ↩ and back reads nothing again. Follows end when the section changes. Everything is dropped when the page hides.
- **The rail answers two shapes of repository, owners first:**
  - **(b) The checkout is the app repo.** The bound workloads' owner labels and tracking id name their Argo or Flux object, which is read by one GET. No list across the cluster.
  - **(a) The checkout is the config repo.** A source's URL matches one of the checkout's remotes, and its path is in the checkout.
  
  On a production binding, (a)'s lists across the cluster run only when a person presses Find What Deploys This.
- **Has my commit reached the cluster?** This reuses `KubeDeployedCommit`. A new `KubeCommitSource.gitopsRevision` answers from Argo's live revision, or from Flux's applied revision (a HelmRelease's history). It shows as its own "manifests" line beside the image line, with Diff Deployed…Current. Every cluster-supplied revision, ref and path goes into git only after it has been checked (§5.4).
- **No new verb, but the gaps are closed first.** Several existing writes are unguarded today:
  - Deleting an Application, Kustomization or HelmRelease, or the `argocd` or `flux-system` namespace, deletes what they manage.
  - An apply can change an object's source or turn on prune.
  - Resuming on production applies whatever git holds now.
  
  G0b and G0d make each of these say so and type the name.
- **Agents get `k8s_gitops`.** It is read-only and bounded, with one scrubbed line per object. `checkout: true` answers only for the pane's bound context. There is no GitOps write tool, and `k8s_apply` on GitOps kinds always has the person type the name.
- **Budgets.** At most 8 page watches. No new proxy, no setting, no background watch, nothing written to disk. Never a Secret, a Helm value, Argo's ConfigMaps or Argo CD's API server. The repository is never fetched.
- **The floor is G0a–G0d, G1, G2, G5 and G6.**

## 1. What exists

| Piece | Where | What it gives |
|---|---|---|
| Verbs | `KubeGitOps.swift` (pure) | `fluxKinds` (7 Flux kinds and what `flux` calls each), `isArgoApplication`, the merge patches for suspend, resume, reconcile and refresh, `fluxLine`, `refreshLine`, `argoSyncLine` (with `--app-namespace`, `--core`, `--kube-context`, `ARGOCD_*` unset), `argoNamespace(installs:application:)`, `argoDefaultNamespace`, `FluxSource`, `sources(of:resource:)`, `sourceResources` |
| Verb wiring | `KubernetesPageModel+Writes.swift` (`KubeWriteVerb.reconcile/.fluxSuspend/.fluxResume/.refresh`, `writeVerbs(for:)`, `writeTarget`, `KubeWriteFacts`), `+TabWrites.swift` (`tabWriteVerbs(for:)`: `argoSync`, `fluxReconcile`; the `argocd-cm` name lookup at `:118–125`), `+Forwards.swift` (`detailVerbs(for:)`, which includes `writeVerbs`, `.delete` among them) | Every GitOps verb already works on a `KubeObjectRef`. A new list only has to build refs. |
| Trees | `KubeGitOpsTree.swift` (pure) | `argoHealth(_:)`, `argoInCluster(destination)`, `fluxRemote`, sources from `spec.source(s)`, inventory ids, a HelmRelease's namespace as `targetNamespace ?? metadata.namespace` (`:198`) |
| Health | `KubeHealth.swift` | K601 `notReady` (`readyFalse(_:)`, for any group outside `builtinGroups`), K602 `argoDegraded`, K603 `argoOutOfSync`. `reads` lists applications, kustomizations, helmreleases and gitrepositories as whole objects (limit 500), through `scope.reads(for:)` (their own namespaces), while the Overview shows. `kept` / `scrubbed` (`:418`) drop `spec`'s `values`, `valuesObject`, `valuesFrom`, `parameters`, `data`, `stringData`, env values, last-applied and managedFields. They don't touch `status`. |
| Patterns | `KubeHealthSession` (`getAll(width: 4)`, `KubeBlocking.run`; the objects decoded and dropped inside, only `report` kept, `:61–70`); `KubeClusterOverviewSession` (`Part`s, `client.follow(kind, in:options:cap:)`, `watchCap(kinds)` = 10 / namespaced kinds, 250 ms flush, `problems`, `hide()`); `updateOverviewReading()` hides `health` whenever the section isn't `.overview` (`+Metrics.swift:197`) | The section copies the live follows. The paged object read is new (§3.1). |
| Client | `KubeClient.get(_:accept:maxBytes:)` (`:294`; throws `KubeBodyTooLarge`), `getAll(_:width:)` (`:264`; independent GETs, no `maxBytes`), `listOne`'s `continue` / 410 restart (`:446–465`), `includeObject` (`:323`: `Metadata` for a namespaced read across the cluster) | `get(maxBytes:)` and `listOne`'s loop are reused. |
| Scope | `KubeScope` (`reads(for:cap:)`, `isFilteredAcross`, `includes`, `KubeScopeMerge`, `KubeScopeRefused`, `watchCap = 10`) | Several namespaces become one watch each up to the cap, then one watch across the cluster, filtered |
| Rows | `KubeRow` (`cells`, `created`, `labels`: only `app.kubernetes.io/…`, `conditions` with `objects: true`), `KubeListOptions(labelSelector:fieldSelector:metadata:objects:)`, `KubeColumn.type` | The CRDs' printer columns. Argo Application: Sync Status, Health Status, Revision (priority 10), Project (priority 10). ApplicationSet: none (Name and Age only). Flux Kustomization and HelmRelease: Age (`date`), Ready, Status (the Ready message). GitRepository and OCIRepository add URL. HelmChart: Chart, Version, Source Kind, Source Name. Bucket: Endpoint. |
| Writes' rules | `KubeWriteCheck.rule` / `warning(_:kind:)` (`KubeWrites.swift:269`, static, no object) | `.delete` is offered on any kind that serves delete. Its name is typed only on production or for a namespace. `warning` has no GitOps case. The delete path reads nothing before it confirms (`facts.meta` is only for recreate and removeFinalizers). |
| Apply | `KubeApply` (`owners` at `:543`: `argocd.argoproj.io/instance`, `tracking-id`, `kustomize.toolkit.fluxcd.io/name`, `helm.toolkit.fluxcd.io/name`), `KubeResourceBuffer`, `KubeAgentWrites.tools` (`k8s_apply` among them) | Owner parsing to extract. No warning for an apply to a GitOps object itself. |
| Ask Why | `+AskWhy.swift` (`asksWhy`, `:7`: pods and Deployments only; `askWhyRef`, `askWhyUnavailable` via `KubeTrouble`), `KubeAgentBriefing`, `k8s_why` (`KubeMCP.swift:608`, throws for other kinds) | Extended in G3 and G7. |
| Deployed commit | `KubeDeployedCommit` (`candidates`, `answer(_:in:)`, `compare` via `Git.run`, `rev-parse --verify` at `:186`, `review(found)`), `KubeDeployedAnswer` (`.text`, `.sourceSaid`, `.none`'s "no commit found in the image"), `KubeCommitSource` (revisionLabel 1, tag 2, appVersion 3) | Reused, with one new source case and a source-aware text. |
| Rail | `KubernetesPanelModel` (~640 lines) | Follows Deployments, StatefulSets, DaemonSets and Pods as Table rows, through the binding's label selector, on `panelClient(for:)` (`.background`), in the binding's one namespace. Also `stop()` on hide, `generation`, `retryDelays`, `deployed[workload.id]`, and `answered`, keyed by the candidates only (`:461`). It never discovers. `kubernetes.knownDiscovery(of:)` is non-nil only when the page or an agent read that context recently. |
| Rail view | `KubernetesPanelView.bound(_:)`; `SidebarView.swift:234` gives it only an `openPage` closure | Shows the scope, `helmLine`, `deployedLine`, then Workloads, Pods and Forwards. It has no write host and no Ask Why. `KubeHelmUpgradeHost` (`helmHost`) is the pattern for a host. |
| Git remotes | `Git/Refs.swift` (`Refs.remoteArguments`, `Refs.parse(remotes:)`) | The checkout's remotes. Nothing normalises a git URL yet. |
| YAML | `API/YAMLReader.swift` | Reads a `kustomization.yaml` (§4.3) |
| Fake | `FakeKubeAPI.addCRD(columns:)`, `add(values:labels:fields:)`, `setFields`, `update(values:)`, `FieldSelector`, `forbidden` (for example `"applications.argoproj.io@cluster"`, which refuses only the list across the cluster), and a log of every request | Cells come from `values` keyed by column name, because the fake evaluates no JSONPath. Today's GitOps E2E fixtures (`E2ERunner+KubernetesTree.swift:175-218`, `+KubernetesGitOps.swift:29`) add the CRDs with no columns. `kubernetesCheckout`'s repository and `c1` are local to that function. |

### 1.1 Gaps in what exists (fixed in G0a–G0d)

| Today | Problem | Change | Stage |
|---|---|---|---|
| `KubeGitOpsTree.swift:92` reads `status.resources[].health` | Argo CD 3.0 doesn't persist each resource's health in the Application unless `controller.resource.health.persist` is set (`status.resourceHealthSource: appTree`). Every child comes back with no health. | When `resourceHealthSource == "appTree"`, the tree says once that "Argo CD 3 keeps each resource's health outside the Application", and draws the children as sync-only, never as Unknown or unhealthy. | G0a |
| `KubeGitOpsTree.swift:76` reads only `status.sync.revision` | A multi-source Application leaves it empty and writes `status.sync.revisions[]`. The same singular/plural pair is in `operationState.syncResult`, `history[]` and `sourceType(s)`. | One reader, `KubeGitOpsSource.revisions(_:)`, for both forms everywhere | G0a |
| Owner parsing lives inside `KubeApply.owners` | It is needed by the rail and the delete warning too. Argo 2.x's default tracking label `app.kubernetes.io/instance` (`application.instanceLabelKey`) isn't accepted. | `KubeGitOpsOwner.parse(labels:annotations:)` is extracted from `KubeApply.owners` and accepts `tracking-id` (`<app>:<group>/<Kind>:<ns>/<name>`, with `<appNs>_<app>` for apps in any namespace), `argocd.argoproj.io/instance`, and `app.kubernetes.io/instance` as "probably Argo CD", because Helm sets it too (§4.2). `KubeApply` calls it. | G0a |
| K601 is `Ready=False` alone | A Flux object is healthy only when `Ready=True` **and** `status.observedGeneration == metadata.generation`. | For `*.toolkit.fluxcd.io` kinds only, K601 treats a lower `observedGeneration` as "not yet looked at". cert-manager and other groups keep today's rule, because they keep `observedGeneration` per condition. K601 is a one-shot read and can't time the lag, so it has no "after a minute" rule. | G0a |
| `KubeHealth.kept` scrubs `spec` only | Argo copies the whole source, `helm.values`, `valuesObject` and `parameters` included, into `status.sync.comparedTo.source(s)`, `status.history[].source(s)`, `status.operationState.operation.sync.source(s)` and `status.operationState.syncResult.source(s)`. `operation.sync.manifests` can hold raw manifests, Secrets among them. jsonnet `extVars` and `tlas`, `kustomize.patches`, Flux `spec.patches`, `postBuild.substitute` and generator `elements` aren't dropped anywhere. So the Overview's health report holds values in memory today. | `kept` runs `scrubbed` over `status` too, drops `operation.sync.manifests`, and adds those keys. Every string loses a URL's userinfo, and every `message` is cut at its first manifest line (§5.3, step 1). The sentinel test (§8.1) runs against `kept`, both carriers included. | G0a |
| Deleting an Application, Kustomization or HelmRelease | An Application carrying `resources-finalizer.argocd.argoproj.io` (or its `/background` or `/foreground` variant) deletes everything it manages. A Kustomization with `spec.prune: true` deletes its inventory. Deleting a HelmRelease uninstalls the release. Today it is asked like any custom resource. | `KubeWriteFacts.gitOps` holds whether the finalizer is there (matched by prefix), `spec.prune`, the managed count, and a parent owner if any. The guard reads it with `client.object` for `.delete` on the three kinds and passes it to `KubeWriteConfirmation.make`. `rule` types the name on every class for these kinds. `warning` takes the facts and says "Argo CD deletes the 42 resources it manages with it". When the read fails or is refused, it gives the worst-case sentence ("may delete everything it manages"), never no sentence. When a parent manages the object (a `kustomize.toolkit.fluxcd.io/name` label, an ApplicationSet owner, an app-of-apps tracking id), it adds "managed by Kustomization flux-system/flux-system: it will be recreated". | G0b |
| Deleting the `argocd` or `flux-system` namespace | It deletes every Application with the finalizer and every pruning Kustomization in it, and so everything they manage. The warning says only "Everything in the namespace is deleted with it." | When the namespace holds GitOps objects (counted from the review's reads kind by kind), the warning adds "and the 31 Applications in it delete the resources they manage: 1,204 objects across 9 namespaces". | G0b |
| The generic GitRepository, OCIRepository and HelmRepository lists show the URL column raw | A URL can carry `user:token@` | `KubeTableReader.row` drops the userinfo from the URL column of the Flux source kinds (`GitRemoteURL.withoutUserinfo`) | G0c |
| An apply or a YAML edit to a GitOps object | A Kustomization's `prune: true` with a new `path`, an Application's new `repoURL` or `destination`, or `suspend: false` is a mass delete or a redeploy. Neither `KubeApply` nor `KubeResourceBuffer`'s save says so. `k8s_apply` lets an agent do it with an ordinary confirmation. | `KubeApply` compares against the live object for the four main kinds. When `prune`, `destination`, `targetNamespace`, `repoURL`/`url`, `path`, `sourceRef` or `suspend` changes, the sheet names each change and types the name on every class. `k8s_apply` on these kinds always has the person type the name in their confirmation. | G0d |
| Resume (Flux) | Resuming applies whatever git holds now, prune included, possibly many commits later | On production, Resume's confirmation names what it will apply: "applies main@c03f9aa; a77b0d1 is applied". It types the name when `spec.prune` is true. The object read after the review (which already decides Suspend or Resume) carries this. | G0d |

## 2. The GitOps section

### 2.1 Place and key

- `KubeSection.gitops` sits between `.helm` and `.forwards`. Its title is "GitOps" and its symbol `arrow.triangle.branch`. `listsKinds`, a deny-list at `KubeKindCatalog.swift:90`, gains `.gitops`.
- **The key is `g`.**
  - `KubeSection.key` becomes an explicit switch: 1–8 as today, `.gitops` is `g`, and `.forwards` stays `9`.
  - `0` is All Namespaces. Renumbering Helm or Forwards would break people's habits.
  - `KubernetesKey` gains `case gitops`; `KubeKeyGroup` gains entries for `.gitops` and `.groupBy`; `isWellFormed` catches duplicates.
  - `KubeKindsTests:215` changes. `KubeHelmTests:355` (Forwards on 9) stays.
- **When it shows.** The section row shows only when discovery serves `applications.argoproj.io` or any `*.toolkit.fluxcd.io` kind (`KubeGitOpsSummary.served(discovery)`). Pressed on a context that serves neither, `g` says "Neither Argo CD nor Flux is served by fake-dev" in the status line.
- **No count on the section row.** A count like `KubeHelmCount` exists only while its own session is live, which is only while the section shows, so it would tell nothing.
- **The Overview gets one line**, built from the K601–K603 findings its health report already has, so it costs no read. It counts what *lives* in the scope, and says so: "GitOps in these namespaces: 2 failing, 3 out of sync — press g for what deploys here". The section counts what lives in or deploys into the scope, so the two numbers can differ, and the line says what it counts.
- **Palette:** "Kubernetes: GitOps" in `kubernetesPageCommands()`, and the shown objects as `PaletteItem`s (`k.g.<kind>.<ns>.<name>`) while the section shows (`TerminalWindowController+Kubernetes.swift`).
- **Command bar:** `:gitops`, `:argo` and `:flux` in `KubeCommandBar`. The last two also set the tool filter.
- **Reading.** `updateGitOpsReading()` is called at the three places Helm's and the Overview's are (`KubernetesPageModel.swift:224, 270, 284`).

### 2.2 Layout

```
GitOps · kind-fake · shop                       Argo CD 2 kinds · Flux 6 kinds · summarised 3 min ago
⚠ kustomize-controller 0/1 ready in flux-system — Flux's states below may be stale
[2 failing] [1 blocked] [1 stuck] [1 drift] [1 paused] [41 ready]  3 not placed      / filter
● Failed   HR   flux-system/acme-payments  → shop   upgrade to 1.5.0 failed; rolled back to 1.4.2   1.4.2          acme-charts/payments    4m
● Failed   App  argocd/acme-web            → shop   auto-sync failed for 77e1a02 and won't retry it  5d0c1e2 → 77e1a02 acme/fleet apps/web @main  12m
● Failed   Ks   flux-system/acme-cron      shop     c03f9aa failed (BuildFailed); a77b0d1 still applied  a77b0d1     acme/fleet ./apps/cron   8m
● Blocked  Ks   flux-system/acme-api       shop     dependency acme-infra: HealthCheckFailed        a77b0d1        acme/fleet ./apps/api    2m
◐ Stuck    App  argocd/globex-batch        → shop   syncing 26m: waiting for hook Job/migrate                      globex/ops batch @v1.4   26m
◇ Drift    App  argocd/acme-admin          → shop   OutOfSync, auto-sync off · manual               5d0c1e2 → 77e1a02 acme/fleet apps/admin  1h
‖ Paused   Ks   flux-system/acme-jobs      shop     suspended 12 days ago by overterm · last: Ready 51e8ad0       acme/fleet ./apps/jobs
```

- **Header:**
  - the context and the scope;
  - which tools are served, and how many of their kinds;
  - when the summaries were read;
  - each kind that refused or was cut, by name: "Applications: forbidden across the cluster; read in argocd", or "500 of 1,240 Applications summarised; the rest show their state only".
- **The controller banner** (§3.1) shows when a controller in Argo's or Flux's namespace isn't ready.
- **Chips** come in display order, with counts from the live rows. A chip filters, and pressing it again clears the filter. "N not placed" counts the rows R2 didn't summarise, which can't be placed in a scope (§2.5). It is pressed to show them, and appears only when the scope isn't All Namespaces.
- **A `ResourceTable<KubeGitOpsRow>`**, identifier `kubernetes.gitops`. Its columns:

| # | Column | From | Notes |
|---|---|---|---|
| 1 | State | `KubeGitOpsState` | A glyph and a word, coloured through `ChromeTheme` via `KubeTreeHealth` |
| 2 | Kind | `role` | App, AppSet, Ks, HR, Git, OCI, HelmRepo, Chart, Bucket |
| 3 | Name | `ref` | `namespace/name` |
| 4 | Into | Argo `spec.destination.namespace`; Flux `spec.targetNamespace`, else for a HelmRelease its own namespace (`KubeGitOpsTree.swift:198`); else the managed namespaces | `→ shop` for a destination field. `shop` or `shop +2` for managed namespaces. `⇢ <server>` for a remote cluster (`argoInCluster` false, or `fluxRemote`), which is said, never followed, and never used for scope. |
| 5 | Why | §2.4's sentence | One line. The hover shows at most 4 KB, scrubbed (§5.3). |
| 6 | Revision | §2.6 | 7 characters, `Text(verbatim:)`. Argo shows `live → target` while OutOfSync; Flux shows `applied` and names the attempted revision in Why. |
| 7 | Source | `sources`, or the Flux source followed through `sourceRef` | `host-less org/repo path @ref`, `chart@version`, or "3 sources" |
| 8 | Age | the time the current state started, read from the object (§2.3) | Else the row's `created` |

- **Order:** State in display order, then Age, oldest problem first. The columns sort like any `ResourceTable`.
- **Hide Ready** is on by default once the scope holds more than 50 rows. The Ready chip still counts them, and pressing it shows them.
- **A row that isn't summarised yet** shows its state from the cells alone, and "…" in Why.
- **The empty scope** says where the objects are: "No GitOps object lives in or deploys into `default`. Argo CD's Applications are in argocd: Show argocd". The button adds the namespace to the scope, as the chip would. The scope is never widened silently.

### 2.3 The state ladder (pure, `KubeGitOpsState`)

The rules are evaluated in order, and the first that holds wins. Every time comes from the object (`lastTransitionTime`, `operationState.startedAt`/`finishedAt`, an artifact's `lastUpdateTime`, `managedFields` times), never from when the app first saw it.

A 30 s tick re-runs the ladder over the summaries already held, on the main thread, with no read. Without it, a time-based rule would only change on the next event. K602 and K603 call the same functions; G1 changes their findings, and its CHANGELOG line says so.

1. **Paused** (Flux)
   - `spec.suspend: true`.
   - The state the conditions show is kept as a tag ("last: UpgradeFailed").
   - Argo's manual sync is a tag ("manual"), not a state.
2. **Blocked**
   - Flux: the object's Source (through `sourceRef`), or for a HelmRelease its HelmChart (or `chartRef`), is not Ready. This holds whatever reason the object gives itself, including `ArtifactFailed` ("Source artifact not found"). The row names the cause: "source acme-fleet: AuthenticationFailed".
   - Flux: `Ready=False` with reason `DependencyNotReady`. The row names the first dependency that isn't ready, and follows the chain while each link is among the summarised objects, at most 5 hops: "acme-infra ← cert-manager: HealthCheckFailed". It never makes an extra GET.
3. **Failed**
   - **Flux:**
     - `Ready=False` with any other reason. An unknown reason counts too; the known ones (`BuildFailed`, `HealthCheckFailed`, `ReconciliationFailed`, `PruneFailed`, `InstallFailed`, `UpgradeFailed`, `TestFailed`, `RollbackFailed`, `GitOperationFailed`, `AuthenticationFailed`, `FetchFailed`, `URLInvalid`…) only choose the wording.
     - `Stalled=True` (`RetriesExceeded`, `InvalidPath`, `InvalidChartReference`…).
     - `Reconciling=True` with reason `ProgressingWithRetry` ("retrying after: …").
     - A HelmRelease whose `Ready=False` reason is `RollbackSucceeded` or `UninstallSucceeded`, or whose `history[0].status` is `failed`: "upgrade to 1.5.0 failed; rolled back to 1.4.2". Remediation hides this failure otherwise.
     - For a Kustomization, `lastAttemptedRevision ≠ lastAppliedRevision` with `Ready=False` is worded "c03f9aa failed; a77b0d1 still applied". It is the same failure, not a separate rule.
   - **Argo:**
     - a condition whose type ends in `Error` (`ComparisonError`, `InvalidSpecError`, `SyncError`, `UnknownError`, `OperationError`);
     - health Degraded;
     - health Missing while Synced (Missing with OutOfSync goes through the OutOfSync rules below, so a new Application before its first sync isn't Failed);
     - `operationState.phase` Failed or Error, when the operation's revision(s) (`syncResult.revision(s)`) equal the current `sync.revision(s)`. With auto-sync on, Argo won't try that commit again unless `syncPolicy.retry` is set: "auto-sync failed for 77e1a02 and won't retry it". A failed operation for an older revision is a tag only ("last sync failed 2d ago").
     - phase Running with `operationState.retryCount > 0` [verify]: "retrying (attempt 3): <message>".
   - **ApplicationSet:** `ErrorOccurred=True`.
4. **Stuck**
   - Flux: `Reconciling=True` for longer than `max(2 × spec.interval, 5 min)` since its `lastTransitionTime`.
   - Argo: `operationState.phase == Running` with no retries, for longer than 10 minutes since `startedAt`. Argo has no interval in the object.
   - Argo: phase `Terminating` for longer than 10 minutes.
5. **Drift**
   - **Argo, OutOfSync (Missing included):**
     - auto-sync off (`syncPolicy.automated` absent, or `enabled: false` [verify]); or
     - auto-sync on, and the last operation already ran for `sync.revision` and succeeded. Auto-sync won't fix this: `selfHeal` is off and the live state changed, or `ignoreDifferences` is missing. Or
     - auto-sync on, and nothing has started for the new revision, more than 3 minutes (Argo's default reconcile period) after the last operation finished: "auto-sync on, not started for 77e1a02".
   - **Argo, needs pruning:** `status.resources[]` entries with `requiresPruning: true` while `syncPolicy.automated.prune` is off: "3 resources need pruning; prune is off". Under auto-sync this OutOfSync never ends.
   - **A Flux Source's artifact differs from what its Kustomization or HelmRelease last attempted**, the user isn't Blocked, and the artifact's `lastUpdateTime` is older than the user's `interval` plus `retryInterval`: "fetched, not applied". Revisions can't be ordered without git, so it says "differs", never "newer".
6. **Progressing**
   - Argo: health Progressing; an operation Running within its 10 minutes; OutOfSync with auto-sync on while an operation is Running; or OutOfSync with auto-sync on, the last operation for an older revision, and it finished less than 3 minutes ago.
   - Flux: `Reconciling=True` within its window; `Ready=Unknown`; a Source artifact that differs, within its window; `observedGeneration < generation` for less than a minute.
7. **Ready**
   - Flux: `Ready=True` with `observedGeneration == generation`.
   - Argo: Synced and Healthy, or Suspended health, said as such.
8. **Unknown**
   - Argo: sync Unknown with no Error condition.
   - Flux: `observedGeneration < generation` for more than a minute, timed from the newest `managedFields` entry that owns `f:spec`: "not yet looked at".
   - Anything else.

**A controller that is down** (§3.1's controller follows) doesn't change a row's state. It tags every row of that tool "may be stale" and shows the banner. An Application whose `status.reconciledAt` is more than 9 minutes (3 × 180 s) older than its summary's read time is tagged "not reconciled for 40 min".

`mark: KubeTreeHealth`: Failed and Blocked are bad; Stuck, Drift and Progressing are waiting; Paused is dim; Ready is good; Unknown is grey.

### 2.4 What a row knows (`KubeGitOpsObject`, pure, Sendable)

`KubeGitOpsObject` is decoded straight from the response bytes by `Decodable` structs (`KubeGitOpsWire`) that declare only the fields below. That is the allow-list itself: no `[String: Any]` tree is built, and no field outside it is ever parsed into memory. `KubeHealth.kept` isn't in this path. It stays the Overview's net, fixed in G0a.

```
KubeGitOpsObject
  ref: KubeRowID, kindFullName, role (.application .applicationSet .kustomization .helmRelease .source(kind)), tool (.argo .flux)
  resourceVersion, generation, observedGeneration, generationChangedAt: Date?
  cells: [String]             // the cells the summary was taken with, date columns left out (§3.1)
  state: KubeGitOpsState, stateSince: Date?, tags: [manual, remote, multiSource, valuesFromThisRepo, lastSyncFailed(Date), mayBeStale…]
  sync, health, ready: KubeRowCondition?, reconciling, stalled, suspended, suspendedAt: (Date, manager)?
  autoSync: (enabled, prune, selfHeal)?, retryCount: Int?, reconciledAt: Date?
  sources: [KubeGitOpsSource{repo: GitRemoteURL?, rawRepoHost, path?, chart?, targetRevision?, isValuesRef}]
  sourceRef: KubeGitOps.FluxSource?, chartRef: KubeRowID?, dependsOn: [KubeRowID], ownerAppSet: KubeRowID?, parentOwner: KubeGitOpsOwner?
  destination: (server|name, namespace?, inCluster), remote: Bool
  managedNamespaces: Set<String>   // from inventory ids / status.resources[].namespace, at most 64
  revisions: (applied: [String], attempted: String?, wanted: [String], helmHistory: (chartVersion, status)?)
  artifact: (revision, lastUpdateTime)?                     // a Source
  operation: (phase, startedAt, finishedAt, revisions, message?)?
  lastError: String?            // scrubbed (§5.3), at most 300 characters
  managedCount: Int?, pruneNeeded: Int?
  managed: Set<KubeManagedID>?  // only for objects the rail matched, at most 2,000
  images: [String]              // Argo status.summary.images, at most 20
  manifestPaths: [String]       // argocd.argoproj.io/manifest-generate-paths, split on ';'
  artifactOrigin: (repo: GitRemoteURL, revision: String)?   // OCIRepository's org.opencontainers.image.source/.revision
```

- **`managedFields`** are decoded as their entries' `time`, `manager`, and whether `fieldsV1` holds `f:spec` and `f:spec.f:suspend`. That is a small `Decodable` that looks at keys only. From them come `suspendedAt` ("suspended 12 days ago by overterm") and `generationChangedAt`. Nothing else of `managedFields` is kept.
- **Last error.** The first message that says something:
  - **Argo:**
    1. an `*Error` condition's message;
    2. `operationState.message` when the phase is Failed or Error, with the first `syncResult.resources[]` whose status is `SyncFailed` ("Deployment/acme-web: …");
    3. `health.message`;
    4. `OrphanedResourceWarning` or `SharedResourceWarning`, as a warning.
  - **Flux:**
    1. the `Ready=False` message;
    2. `Stalled`;
    3. `Reconciling` with reason `ProgressingWithRetry`;
    4. a HelmRelease's `Released` or `Remediated` False.
  - **ApplicationSet:** `ErrorOccurred`.
  - A Blocked row's Why is its cause's message, not its own.
- **Revisions** (§2.6) come from:
  - Argo: `status.history[]`'s last entry, `sync.revision(s)` and `operationState.syncResult.revision(s)`;
  - a Kustomization's `lastAppliedRevision` and `lastAttemptedRevision`;
  - a HelmRelease's `lastAttemptedRevision` and `history[0].chartVersion`/`status`. HelmRelease v2's `lastAppliedRevision` is deprecated and empty on new releases, and is never compared.
  - a Source's `artifact.revision`.
- **Never decoded:**
  - Helm values (`values`, `valuesFrom`'s content, `helm.values`, `valuesObject`, `parameters`, `fileParameters`);
  - `plugin.env`, jsonnet `extVars` and `tlas`, every `patches`, `postBuild`, generator `elements`;
  - `status.*.source(s)` copies, `operation.sync.manifests`;
  - `status.resources` and inventory entries beyond the count, the managed namespaces, the prune count and the rail's capped `managed` set;
  - `history` beyond its last entry, and a URL's userinfo.
  
  A Secret's name is kept as a name only ("values from Secret acme-web-values").

### 2.5 Scope rule

`KubeGitOpsSummary.inScope(object, scope, referenced:)` keeps an object when one of these holds:

- its own namespace is in scope;
- one of its `managedNamespaces` is in scope;
- it has applied nothing yet (`managedNamespaces` empty) and its destination namespace is in scope. That is Argo `spec.destination.namespace`, or Flux `spec.targetNamespace`, or a HelmRelease's own namespace. The destination counts only when it is in this cluster (`argoInCluster` true and `fluxRemote` nil);
- it is an ApplicationSet whose generated Applications are kept (by ownerReference);
- it is a Source that a kept object references (`KubeGitOps.sources`, the `chartRef`'s HelmChart).

An object that deploys to another cluster is kept only by its own namespace, with its `⇢ server` tag. All Namespaces keeps everything.

Rows that R2 didn't summarise carry no spec and no status beyond their cells, so they can't be placed. Off All Namespaces they are counted under "N not placed (not summarised)", and never implied to be in or out.

### 2.6 Revisions (`KubeGitOpsRevision`, pure)

| As the cluster writes it | Shown | Commit (for the rail) |
|---|---|---|
| Flux `main@sha1:<40 hex>`, `refs/heads/main@sha1:…`, `v1.2.3@sha1:…` | `main@a77b0d1` | the SHA; the ref says what it tracks |
| Flux legacy `main/<40 hex>` | `main@a77b0d1` | the SHA |
| `sha1:<40>` alone | `a77b0d1` | the SHA |
| `…@sha256:<64>`, `sha256:…` (OCI, Bucket, or a SHA-256 git repository) | `sha256:1f2e3d4` | none, except a SHA-256 GitRepository [verify] or an OCI artifact's `org.opencontainers.image.revision` |
| HelmRelease chart version `1.2.3`, `1.2.3+<sha12>` (Revision strategy) | `1.2.3` | the 12 characters after `+`, when SHA-shaped, and only once `rev-parse --verify <prefix>^{commit}` resolves them to one commit. "Ambiguous" when it doesn't. |
| Argo `sync.revision`, `history[-1].revision` | `a77b0d1`; a chart version stays as it is | the SHA, when SHA-shaped |
| Argo `revisions[i]` | one per source; the matched source's index for the rail | as above |

- **Argo's live revision** is the last `history` entry's revision(s), else `operationState.syncResult.revision(s)`. `sync.revision` is what Git has now. The two can differ while the app is Synced, when the new commit changed no manifests.
- **The Revision column:** Argo shows `live → target` while OutOfSync; Flux shows the applied revision; a Source shows its artifact.

### 2.7 Keys inside the section

| Key | Does | Through |
|---|---|---|
| ↑ ↓ | move | `ResourceTable` |
| ↩ | the object in its kind's list, with the detail open | `openFromOverview(kind:_:)` (`KubernetesPageModel+Metrics.swift`) |
| `x` | its tree, in that detail | existing |
| `r` | Reconcile (Flux, a Source too) / Refresh (Argo) | `writeVerbs(for: ref)`, asked |
| `p` | Suspend / Resume (Flux) | the same; Resume as G0d says |
| `s` | Sync in a Tab… (Argo) / Reconcile with Source in a Tab… (Flux) | `tabWriteVerbs(for: ref)` |
| `k` | copy `flux get kustomization acme-api -n flux-system --context kind-fake` or `argocd app get acme-web --app-namespace argocd --core --kube-context kind-fake`; ⇧ copies the kubectl `get` | `KubeGitOps` lines |
| `a` | Ask Why (Failed, Blocked, Stuck), **from G3** | `askWhyVerb(for:)`, once `asksWhy` takes GitOps kinds |
| `G` | cycle the grouping (§2.8), **from G4** | new `KubernetesKey.groupBy`, active in this section only |
| `/` | filter (§2.8) | `KubeFilter`; the tokens from G4 |
| `?` | the keys | `KubeKeySheet`, from `KubernetesKey.allCases` and `KubeKeyGroup` |

- **The target.** `writeTarget` (`+Writes.swift:63`) gains `if section == .gitops { return gitOps.selectedRef }`. The ref is built through `model.knownDiscovery(of:)`.
- **The press.** It is routed by a `gitOpsPress`, modelled on `helmPress`, next to the other section presses (`KubernetesPageModel.swift:~620`). `ResourceTable` has no double click, so there is none here.
- **Right-click** gives `gitOpsVerbs`: Open, then `detailVerbs(for: ref)`, which includes Delete (G0b's guard), then Copy as kubectl. It has the same shape as `treeVerbs` (`+Tree.swift:32`) and is built only when it opens (`ResourceVerbMenuArea`). Access reviews are asked then, never while rows draw.
- **Multi-select** offers Open and Copy only. There is no write on several rows.

### 2.8 Grouping and filters (G4)

- **Group (`G`):**
  - None (the default).
  - Tool: Argo CD, then Flux.
  - Source: a Flux Source heads its group and carries its own state; Argo groups by repo. A Source nothing uses gets its own group.
  - Owner: an ApplicationSet with its Applications; an app-of-apps parent with the Applications it manages (by tracking id); else a Kustomization's `dependsOn` root.
  - Destination.
  
  The grouping is remembered per page, in memory.
- **Filter (`/`):** `KubeGitOpsFilter` takes its tokens off the front, then hands the rest to `KubeFilter`'s text match over name, why and source. The tokens:
  - `is:failed|blocked|stuck|drift|progressing|paused|ready`
  - `kind:app|appset|ks|hr|source`
  - `tool:argo|flux`
  - `repo:<text>`

### 2.9 The detail's Overview for GitOps kinds (G3)

↩ opens the existing detail, whose GET already brings the whole object. G3 adds a GitOps header to its Overview tab for the four main kinds. It is built by the same `KubeGitOpsWire` decode of that body:

- **The state sentence:** "Failed: upgrade to 1.5.0 failed; rolled back to 1.4.2 (4m)".
- **Source:** the repo, the path, the ref or the chart and its version, with "values from this repo" for a `ref:` source.
- **Revisions,** each with when it was fetched or applied: applied, attempted and wanted.
- **Destination, interval, auto-sync (prune, selfHeal) or suspension.**
- **Chain:** each `dependsOn` and the Source, with its state. ↩ opens one. Nothing is read for it beyond what the section's summaries or the detail already hold.
- **Argo:**
  - the operation (phase, who started it, its age, its retries);
  - the out-of-sync and needs-pruning resources from `status.resources`, at most 50, each opening its object;
  - `history`'s last 10 entries (revision, deployedAt). When a window has a checkout of that repo open (the §4.2 match), each entry opens a review of `git diff a..b -- <path>` in it, through §5.4's checks (G5: it needs the match; G3 shows the entries without it).
- **Conditions,** through §5.3, and copyable.

Flux and Argo diffs (`flux diff`, `argocd app diff --local`), and a native render-and-dry-run of the branch's path, are later work (§11).

## 3. Reads and budgets: the section

### 3.1 What is read

| Read | What | Bound | When |
|---|---|---|---|
| **R1 live rows** | One rows-only Table follow across the cluster per kind in `{applications, kustomizations, helmreleases, gitrepositories, ocirepositories}` that discovery serves and `KubeKindCatalog.isOffered`. `KubeListOptions()`, which across the cluster gets `includeObject=Metadata` (`KubeClient.includeObject`): the row decoder keeps only the namespace, `created` and the allowed labels, and drops the rest. ApplicationSets have no printer columns, so they come from R2 and R3 only. | The first list a streaming list where the server serves one (`KubeStreamingLists`), else paged at 500 with `continue` (an expired one lists again), as every follow. 250 ms flush. | while the section shows |
| **R1c controllers** | Rows-only follows, each in one namespace (`includeObject=None`): Deployments and StatefulSets in Argo's namespace (the namespace most Applications live in, else `argoDefaultNamespace`); Deployments in `flux-system` | 3 follows | while the section shows |
| **R2 summary list** | Whole objects of every served GitOps kind, ApplicationSets and the five Source kinds included. `KubeGitOpsSession.pagedObjects(kind, in:, pageLimit:, maxBytes:, stopAfter:)` is a new loop modelled on `listOne`'s `continue`/410 restart, on `KubeClient.get(_:maxBytes:)`. Each page is decoded off the main thread (`KubeBlocking.run`) by `KubeGitOpsWire`, then its bytes are dropped. | `limit=20` and 16 MB a page. On `KubeBodyTooLarge`, halve the limit and ask the same `continue` again, down to 1. If one object alone is over 16 MB, the kind stops there, because no `continue` gets past it: "stopped at an object over 16 MB; 212 summarised". Per kind, stop at 500 objects or 64 MB read, and say so. Two kinds at a time. | on show (when the store is cold), on Refresh (`⌘R`), on a context change; in the fallback (§3.3) also on a scope change |
| **R3 object GETs** | One GET of one object, `KubeClient.get(_:maxBytes: 4 MB)` | At most 4 in flight. Each object at most once every 15 s. At most 20 queued per flush, Failed, Blocked and Stuck first; the rest wait for the next flush. A 403 or an oversized body says "couldn't read why" once per object. | (a) a row ADDED that R2 didn't summarise; (b) a row whose cells, date columns left out, differ from its summary's; (c) any MODIFIED of a row whose cells aren't Synced+Healthy or Ready=True; (d) every 60 s, at the lowest priority, an object last summarised Running, Progressing, Reconciling or Stuck |
| HelmRepositories, HelmCharts, Buckets | not followed | R2 only | refreshed by R2 and Refresh |

- **The cells, not `resourceVersion`.** Argo writes `status.reconciledAt` every few minutes for every Application. On 1,000 Applications, refetching on every `resourceVersion` would be 5–10 GETs a second. That noise comes mostly from healthy apps.
  - Healthy rows are refetched only when a cell changes. Date-formatted columns (`KubeColumn.type == "date"`, Flux's Age) are left out of the comparison, because the server renders them relative and they change on every event.
  - Rows that aren't healthy are refetched on any event, at most once every 15 s. That way an operation that fails, or starts and hangs, while the cells still say OutOfSync/Healthy is seen live.
  - A spec change on a healthy row that changes no cell waits for Refresh, and the header says how old the summaries are.
- **The summaries are kept** in `KubeGitOpsStore` on the page model, keyed by context, for 5 minutes while the page is on screen. Leaving `g` for ↩ and coming back restarts R1 and R1c (rows, cheap). R2 doesn't run again; R3 fetches the rows whose cells moved since. The store is dropped when the page or its window hides, on a context change, on a credential failure, and at quit. It is never written to disk. A scope change only filters again, because R2 reads across the cluster, except in the fallback.
- **Hidden.** When the section changes, `KubeGitOpsSession.hide()` ends every follow and cancels every GET, and keeps only the store. When the page hides, the store goes too.
- **The Overview's objects can't be shared.** `KubeHealthSession` keeps only its report, and `updateOverviewReading()` hides it whenever the section isn't the Overview, so the two never read at the same time.
- **Never:**
  - a Secret, or a ConfigMap. The `argoSync` review's field-selector lookup of `argocd-cm` stays the only exception, as today, and the section doesn't use it.
  - a Helm release Secret, or Argo CD's API server;
  - a whole-object watch.

**The watch budget.** The section's follows are allotted explicitly within the page's 10:

1. the five R1 kinds, one each;
2. then R1c's three;
3. then, in the fallback only, at most 2 more namespaces, Applications first.

Anything beyond that is cut and said ("Kustomizations in team-b: not watched; Refresh reads them").

### 3.2 Expected cost (written into architecture.md and analysis.md §10)

| Cluster | R1 + R1c | R2 | Steady state |
|---|---|---|---|
| Argo, 40 Applications | 1 + 2 watches. Rows with metadata, managedFields included: about 0.2–1 MB once. | 2–4 pages, about 2–8 MB, decoded and dropped | a GET when a row changes or isn't healthy |
| Flux, 60 objects across 6 kinds | 4 + 1 watches, under 1 MB | 6–9 small pages, under 2 MB | the same |
| Argo, 1,000 Applications | 1 + 2 watches. The first list carries each object's metadata: 3–6 KB of managedFields, plus a `last-applied-configuration` up to the whole spec where client-side apply was used. That is about 5–30 MB once, and 5–10 events a second at 5–50 KB each. | cut at 500 objects or 64 MB, said | at most 4 GETs in flight, 20 a flush |

The metadata across the cluster is the largest cost, and it is the one G8 measures. If G8 finds it too high, the fix is a `KubeListOptions` that asks for `includeObject=None` with the namespace taken from the row's name column, but that is not part of this design. **G8 measured it** (`kubernetesPerf`, 1,000 Applications of ~7 KB with that metadata): the rows' first list ~5 MB, ~5 KB a row, inside the bound, so R1 keeps `includeObject=Metadata`; R2 ~4 MB in 25 pages. What it found was elsewhere: each R3 answer ranked every summary and drew the table on its own, so a burst of 500 events took 7–8 s; the answers are now ranked together at the next flush (~2 s). The section uses the page's proxy slot (`model.client(for:)`, role `.page`). It opens no proxy, and nothing counts against `kubernetes.backgroundWatches`.

### 3.3 When a list across the cluster is refused

A 403 is common for Argo. Each kind is handled on its own, and namespaces are chosen without reading any ConfigMap:

1. the context's `KubeContextSettings.accessibleNamespaces`, when set;
2. else, for Argo kinds, `argoDefaultNamespace` (`argocd`) plus the namespaces Applications were already seen in this session; for Flux kinds, `KubeGitOps.fluxDefaultNamespace = "flux-system"` (new); plus the scope's namespaces, within the 2 spare watches.

These go through `KubeScope.namespaces`, so `KubeScopeMerge` names any namespace that refuses too. The header says it once per kind: "Applications: forbidden across the cluster; read in argocd and shop".

## 4. The rail's GitOps part

### 4.1 Where it lives

- **`KubePanelGitOps`** (`KubernetesPanelModel+GitOps.swift`) is an object owned by `KubernetesPanelModel`. It starts from `follow(_:context:checkout:generation:)` and stops in `stop()`, so the panel's visibility rule comes free.
- **It reads only the binding's context,** through the panel's `client(for:)` (`.background`), and holds a client it uses for GETs only. An unbound checkout reads no cluster. The panel never looks across contexts for where a repository is deployed.
- **Published:**
  - `matches: [KubePanelGitOpsMatch]`, each with its object, `why`, `deployed: KubeDeployedAnswer?`, `attemptFailed: String?`, `tracks: String?`, `changed: KubeGitOpsChanges?`;
  - `state`;
  - `searched: (read, total)?`, when a list was cut;
  - `problems` by kind.
- **`why`** is one of:
  - `.owns([KubeWorkloadRef])` (case b);
  - `.repoAndPath(path)`;
  - `.repoOnly` (a values source, an OCI artifact, or a path not on this branch);
  - `.notInCluster(name)`: the tracking id names an Application this cluster doesn't have.

### 4.2 Matching the repository (`KubeGitOpsMatch`, pure)

**The checkout's side.** The remotes are read once per checkout through `Git.run` (`Refs.remoteArguments`). `Refs.parse(remotes:)` hands each URL straight to `GitRemoteURL` (`Git/GitRemoteURL.swift`, pure), so only normalised values ever leave the parser. The raw output, which may carry a token added by the user's `url.*.insteadOf`, is never kept, logged or briefed. The normalisation steps:

1. Trim whitespace, a trailing `/` and `.git`.
2. The scp form `git@host:org/repo` becomes `host` + `org/repo`.
3. `ssh://[user@]host[:port]/…`, `git+ssh://`, `ssh+git://` and `git://` lose the user and the port. `ssh.github.com:443` becomes `github.com`, and `altssh.gitlab.com:443` becomes `gitlab.com`.
4. `http(s)://[userinfo@]host[:port]/…` **always loses the whole userinfo** (a token may have no `:`, which `Secrets.maskURLs` misses) and its default ports. `http` counts as `https`.
5. Azure DevOps: `https://dev.azure.com/o/p/_git/r`, `git@ssh.dev.azure.com:v3/o/p/r` and `https://o.visualstudio.com/p/_git/r` all become `dev.azure.com/o/p/r`.
6. The host is lowercased. The path is compared case-insensitively on `github.com`, `gitlab.com` and `bitbucket.org`, and exactly elsewhere. GitLab subgroups are kept whole. Self-hosted hosts are compared literally after these steps.
7. ssh config aliases are compared as written; there is no `ssh -G` (decision 8).
8. `oci://`, an Argo source with `chart:` set, and a Flux HelmRepository never match a checkout by URL.

**Case (b), asked first: the checkout is the app repo** (images built here, manifests elsewhere).

- The rail's workload follows ask `metadata: true` and a new `KubeListOptions.owners: true`. They are in one namespace, the binding's, so `includeObject=Metadata` is allowed there.
- Only with `owners`, `KubeTableReader.row` keeps a parsed `KubeRow.owner: KubeGitOpsOwner?` (§1.1) beside the `app.kubernetes.io/…` labels: from `kustomize.toolkit.fluxcd.io/name|namespace`, `helm.toolkit.fluxcd.io/name|namespace`, `argocd.argoproj.io/instance`, `app.kubernetes.io/instance` and the `argocd.argoproj.io/tracking-id` annotation. No other annotation is kept. Every other list's `row()` is unchanged.
- Pods are not asked for metadata; the workloads are enough.
- **Each named owner is read by one GET** (P2), at most 8: the Application, Kustomization or HelmRelease. `app.kubernetes.io/instance` names "probably Argo CD `x`" until that Application exists and its `status.resources` names the workload, because Helm sets the same label.
- A tracking id naming an Application the cluster doesn't have says "managed by Argo CD Application acme-shop (not in kind-fake)". **It never looks in another context.** The cluster that runs Argo is often production.
- **The answer** sits beside the existing image line: "deployed by Kustomization flux-system/acme-api (Ready, 3m) from git.acme.example/acme/fleet". The config repo's commit isn't this checkout's, so it isn't compared. When that owner's source also matches this checkout's remote, it is case (a) as well, and is compared.
- **Workloads with no owner labels:** an Application already read in P4 whose `images` include a bound workload's image is shown as "probably deploys shop-api (same image)".

**Case (a): the checkout is a source of the object.**

| Object | Matches when | Path |
|---|---|---|
| Application | some `source(s)[i].repoURL` equals a remote; also `sourceHydrator.drySource` [verify] | `source.path`, else root; a `ref:` source is `.repoOnly` ("values from this repo") |
| Kustomization | its `sourceRef` GitRepository's `spec.url` equals a remote. The Source may be in another namespace: `sourceRef.namespace ?? own`. | `spec.path` |
| HelmRelease | `chart.spec.sourceRef` is a GitRepository that matches, or `chartRef` is a HelmChart whose source matches | `chart.spec.chart` |
| OCIRepository-sourced Kustomization or HelmRelease | the OCIRepository's `status.artifact.metadata["org.opencontainers.image.source"]` equals a remote | not checked; `.repoOnly`, with the revision from `…image.revision` |
| ApplicationSet | only through its generated Applications. Git generators' globs are later work (§11). | — |

- **The path** is checked by `KubeGitOpsPath.resolve(_:in:)`:
  - It strips a leading `./` and a trailing `/`; `""` and `.` are the root.
  - It **refuses** a path that is absolute or contains a NUL byte. In `manifest-generate-paths`, a leading `/` means the repository root, as Argo reads it, and is taken as root-relative.
  - It resolves the path against the repository root with `resolvingSymlinksInPath().standardized`, and compares that with the root resolved the same way, **by path components, never by a string prefix**. So `..` or a symlink out of the checkout is refused.
  - It is one `FileManager.fileExists(isDirectory:)` per candidate. It never walks up the tree (CLAUDE.md's `/` rule).
  - A path that isn't there is `.repoOnly` with "path apps/web is not on this branch".
- **The branch it tracks:**
  - Argo's `targetRevision`. `HEAD` means the remote's default branch, read locally from `refs/remotes/<remote>/HEAD`.
  - Flux's `spec.ref`, in precedence commit > name > semver > tag > branch; the default is `master`.
  
  The row says "tracks main", or "tracks main; this branch is fix/orders" when they differ. Every ref goes through §5.4 before git sees it.
- **A cut list.** When P4's list was cut, a checkout with no match says "searched 500 of 1,240 Applications", never "nothing deploys this repository".

### 4.3 Has this branch's commit reached the cluster? (reuses `KubeDeployedCommit`)

- **The new source.** `KubeCommitSource.gitopsRevision = 4` says "Argo CD's synced revision" or "Flux's applied revision", by tool. It is asked in its own call, never ranked against the image's candidates. It answers a different question (the manifests, not the code), so the rail shows two lines when both exist:
  - **manifests** `a77b0d1` (Kustomization acme-api, Ready): this branch is 1 commit ahead
  - **image** `9f8e7d6`, from the image's tag: in this branch
- **Only case (a) is compared:**
  - `KubeGitOpsRevision.commit(…)` takes the commit (§2.6); for multi-source, the matched source's index.
  - `KubeDeployedCommit.answer([KubeCommitCandidate(sha:, source: .gitopsRevision, image: nil)], in: checkout)` gives the existing sentence, `.missing(sha:)` included ("not in this checkout — fetch to compare").
  - Diff Deployed…Current is unchanged.
  - `KubeDeployedAnswer.none` gains a text by source: "Argo CD's synced revision isn't a commit (chart 1.4.2)".
  - The gitops line's answers are keyed by (sha, source, HEAD). The panel's existing `answered` keys by candidates only, so this key is new; an event that changes nothing runs no git, and a new HEAD recomputes.
- **Attempted ≠ applied.** For a Kustomization: "Flux tried c03f9aa (this branch's HEAD) and failed: BuildFailed — …; a77b0d1 is still applied". For a HelmRelease: from `history[0]` against `lastAttemptedRevision`, worded "rolled back". The message is scrubbed (§5.3). This answers "is my fix out?" even when Flux refused it.
- **Fetched, not applied.** A Source's `artifact.revision` differs from the user's `lastAttemptedRevision`, or Argo's `sync.revision` differs from its live revision. When the checkout has both commits, `git merge-base --is-ancestor` says which is newer.
- **No change under the path** (Argo with a path, G6): `git rev-list --count <live>..<remote>/<tracked> -- <pathspecs>` through `Git.run`. When it is 0, it says exactly what was checked: "no change under apps/web since a77b0d1", never "nothing".
- **Files this branch changes** (G6): `git diff --name-only <merge-base with remote/tracked>...HEAD -- <pathspecs>`. It shows "3 files under apps/web", which opens a review tab of those files (a `ReviewSource` range), or "no change under apps/web on this branch". It is computed only when HEAD or the revision changes.
- **The pathspecs**, for both:
  - the path;
  - plus the entries of `argocd.argoproj.io/manifest-generate-paths`, Argo's own answer to "what does this app depend on";
  - plus, for Kustomize, the relative directory entries of the path's own `kustomization.yaml` `resources:` and `components:`, one level deep. That file is read with `YAMLReader`, at most 256 KB; URL entries are ignored, and that is said. Each entry goes through `KubeGitOpsPath.resolve`.
  
  `$values/…` files of another source and charts vendored elsewhere aren't followed, so the line names the paths it checked.
- **Nothing is ever fetched.** All git is as of the last fetch, and the line says so.

### 4.4 Reads and budget: the rail

| Read | What | Bound | When |
|---|---|---|---|
| **P0 discovery** | `kubernetes.knownDiscovery(of: context)`, else one `client.discover()` through `panelClient`, as `KubeMCP.swift:262` does | one, cached with the match cache | on show, when the cache is cold |
| **P1 owners** | the existing workload follows, with `metadata: true, owners: true` | unchanged count (3) | as today |
| **P2 owners by name** | One GET per owner P1 named: an Application, Kustomization or HelmRelease, plus its Flux Source and HelmChart | at most 8 objects, 4 MB each | on show, on an owner change |
| **P3 sources** | GitRepository rows (the URL column) across the cluster, else Flux's fallback (§3.3); OCIRepositories as whole objects through `pagedObjects` (they are small; the match needs `status.artifact.metadata`) | rows: one list; OCI: 200 objects or 8 MB | on show, when Flux is served. **On production, only when pressed.** |
| **P4 objects** | Whole objects through `pagedObjects`: Applications in Argo's namespace (and the namespaces seen), always when served; Kustomizations and HelmReleases **only when P3 matched a remote**; and the HelmCharts a matched `chartRef` names, by GET | R2's bounds (500 objects or 64 MB a kind), the cut said | on show, Refresh, a binding change. **On production, only when pressed.** Kept 5 minutes. |
| **P5 live** | One rows-only follow per (kind, namespace) holding a matched or owning object, filtered here by name | at most 4 | while matched |
| **P6 GET** | One GET of a matched object, by R3's rules (b)–(d) | 4 MB, once per object every 15 s | as R3 |

- **The 5-minute cache.** `KubeGitOpsMatchCache` is app-wide and in memory, keyed by (context, binding, the remotes' normalised set). Switching tabs back and forth doesn't list again. It is dropped on a binding change, on a credential failure, on Refresh and at quit, and never written to disk.
- **Unbound:** zero requests. **Hidden:** `stop()` cancels P0–P6 and keeps only the cache.
- **Production.** A production binding reads P0, P1, P2, P5 and P6 on its own: one namespace, plus GETs of objects that were named. The lists across the cluster (P3, P4) wait for **Find What Deploys This**, a button in the rail that says what it will read ("lists Applications in argocd and GitRepositories on fake-prod"). The binding's background socket is read-only only while the context isn't writable. Production is writable by default (no session switch, the owner's decision), so it usually isn't, so the guarantee rests on `KubePanelGitOps` holding a GET-only client and routing every verb through the page's guard (§4.5). A test asserts it (§8.2).
- **The count of follows.** The rail's follows go from 3–4 to at most 7, all on the background slot. The page takes that slot first when it needs one, and the rail then says "not watched". They are on-screen reads, like the rail's existing follows, not attention watches, and don't count against `kubernetes.backgroundWatches`. This is written in `KubernetesPanelModel`'s header and in architecture.md.

### 4.5 `KubernetesPanelView`: the "GitOps" part

- **Place.** It sits after `deployedLine` and before Workloads, and shows only when there is a match, an owner, a problem, or the production button.
- **A row:**
  - the dot;
  - `Application argocd/acme-shop-prod`;
  - the state and its sentence, the revision and its age;
  - in grey, why it matched ("apps/web @ main", "owns Deployment/shop-api").
  
  Under it: the manifests line (§4.3), the attempted line, "tracks main; this branch is fix/orders", and the changed files.
- **The host.** The panel gets a `KubeGitOpsPanelHost`, a protocol in the shape of `KubeHelmUpgradeHost` (`helmHost`), set in `TerminalWindowController+KubernetesPanel.swift`. Before it acts, it makes sure the page's contexts are loaded (`contextsForAgents`), because `write` and `writeVerbs` need `model.contexts.context(named:)` and `model.client(for:)`. It puts the outcome in the rail (`gitOpsStatus`), not only in the page's `writeStatus`.
- **Buttons:**
  - **Open on Page:** selects the binding's context on the page, then `openFromOverview`.
  - **Refresh or Reconcile, and Sync in a Tab…:** through the host, so through the page's guard path (`writeVerbs(for: ref)`, `tabWriteVerbs(for: ref)`).
  - **Diff Deployed…Current.**
  - **Ask Why** (from G3), on a Failed, Blocked or Stuck row, through the host to the window's `askAgent`. The rail has no Ask Why wiring today, so it is added here.
  - **Find What Deploys This,** on a production binding.
- **Identifiers:** `kubernetes.panel.gitops`, `kubernetes.panel.gitops.<namespace>.<name>`, `kubernetes.panel.gitops.deployed`, `kubernetes.panel.gitops.changed`, `kubernetes.panel.gitops.find`.

## 5. Verbs, guards and secrets

### 5.1 Verbs

| Row | Verbs (key) | Name typed |
|---|---|---|
| Application | Refresh (`r`), Sync in a Tab… (`s`, `argoSync`), Delete (right-click and `⌫`, through `detailVerbs`) | Refresh: never. Sync: on production, as today. Delete: on every class (G0b). |
| Kustomization, HelmRelease | Reconcile (`r`), Suspend/Resume (`p`; the object read after the review decides which), Reconcile with Source in a Tab… (`s`, `fluxReconcile`), Delete | Reconcile, Suspend: never. Resume: on production when `spec.prune` is true (G0d). Delete: every class (G0b). |
| Source kinds | Reconcile (`r`), Suspend/Resume (`p`) | Never |
| ApplicationSet | Open, Copy as kubectl, Delete | Delete: as any custom resource; the warning says its generated Applications go with it, through their finalizers |
| Any of the four, by apply or YAML | `KubeApply`, `KubeResourceBuffer`'s save, `k8s_apply` | When prune, destination, source or suspend changes: every class (G0d). `k8s_apply` on these kinds: always, by the person. |

Each verb goes through the one guard path (`KubernetesPageModel+Writes`):

- its access review (`patch <kind>`, or `delete`);
- `WriteConfirmation`, naming the context, the namespace, the object, the CLI line it equals, and G0b's and G0d's facts;
- the production band (no session switch since the owner's decision: writable unless `writable: false`);
- refused on a read-only context, both by the check and by the socket.

`argoSync` already passes `--app-namespace`, so apps in any namespace work.

**Left out of 1.6.0:** Hard Refresh, Terminate Operation, auto-sync on/off, rollback, `argocd app delete`, `flux suspend --all`, and any write on several rows.

### 5.2 What is never read, shown, logged or briefed

- **Credentials:**
  - anything a `secretRef` names (sources, `decryption`, `kubeConfig`, verification, Providers, Receivers): the name only;
  - Argo's `argocd.argoproj.io/secret-type` Secrets and `argocd-secret`;
  - `helm.sh/release.v1` Secrets.
- **Values:**
  - inline Helm values in both tools, and their copies in Argo's `status`;
  - `valuesFrom` and `postBuild.substituteFrom` of kind Secret (named only);
  - jsonnet `extVars` and `tlas`, `plugin.env`, inline patches, generator elements;
  - `operation.sync.manifests`;
  - SOPS-encrypted content.
- **Argo's config:** `argocd-cm`, `argocd-rbac-cm`, `argocd-cmd-params-cm`. The `argoSync` review's existing name lookup is the one exception, and the section and the rail never use it.
- **Strings:**
  - a URL's userinfo, anywhere, the checkout's own remotes included;
  - a Provider's `address`, a Receiver's `webhookPath`.

### 5.3 Messages

Every message (conditions, `operationState.message`, `syncResult.resources[].message`, `health.message`) goes through these steps, in order:

1. **Cut at the first line that starts a manifest.** A line whose trimmed text begins `apiVersion:`, `kind:`, `data:`, `stringData:` or `metadata:`, or a `---` document marker, ends the message with "… manifest omitted". BuildFailed, UpgradeFailed and kustomize errors quote whole YAML, and short base64 values or a value under a key like `DB_URL:` pass the scrubs below.
2. `Secrets.maskURLs`.
3. `GitRemoteURL.stripUserinfo(inText:)`, for every `scheme://…@` in the text.
4. `Secrets.scrubCredentials`.
5. 300 characters in the row. The hover, the detail's conditions and the Ask Why brief get at most 4 KB, after the same steps.

### 5.4 Cluster-supplied strings in git

The rail and the detail pass strings the cluster wrote into `git`. These are paths (`spec.path`, `source.path`, `manifest-generate-paths`, kustomization entries), refs (`targetRevision`, `spec.ref.branch`/`tag`) and revisions (`history[].revision`, `lastAppliedRevision`). `KubeGitOpsGitArgs` checks every one of them before use:

- **Revisions:** only SHA-shaped strings (`isSHAShaped`), then `git rev-parse --verify --end-of-options <sha>^{commit}`, as `KubeDeployedCommit.swift:186` does. A 12-character prefix must resolve to exactly one commit.
- **Refs:** refused when they start with `-`, contain `..`, `@{`, NUL or whitespace, or fail `git check-ref-format --branch`. They are used as `refs/remotes/<remote>/<ref>`, after `--end-of-options`.
- **Pathspecs:** every call runs with `GIT_LITERAL_PATHSPECS=1` (or `--literal-pathspecs`), so `:(top)`, `:!`, `:(attr:…)` and `:/` are plain names. They are passed after `--`, and each has been through `KubeGitOpsPath.resolve`.

## 6. Agents

### 6.1 `k8s_gitops` (`KubeMCP+GitOps.swift`, G7)

- **Wiring.** It joins `KubeMCP.reads`, the dispatch, the `tools` schema and `instructions`.
- **Arguments:**
  - `context`: else the pane's binding's.
  - `namespace`: own or deploying into; else the binding's.
  - `kind`: `application|applicationset|kustomization|helmrelease|source|all`.
  - `failing_only`.
  - `limit`: default 100, max 500.
  - `checkout`: a bool; only what deploys the calling pane's checkout, through `KubeMCP.binding(for:)`, with the deployed sentence and the attempted line.
- **`checkout: true` is fenced:**
  - It is refused when the checkout is unbound, and when `context` names any context but the binding's.
  - With a fresh `KubeGitOpsMatchCache`, it answers from that.
  - With a cold cache, it runs P0–P2 and, off production, P3–P4 at the agent's bounds (200 objects or 16 MB a kind). On production it never lists across the cluster: the answer says "on fake-prod only the owners of the bound workloads were read; press Find What Deploys This in the rail for more".
- **The answer** is one line per object, for example:
  `Kustomization flux-system/acme-cron  Failed  c03f9aa failed; applied main@a77b0d1  source acme/fleet ./apps/cron @main  into shop  last error: BuildFailed: …`
  - Never `status.resources` (a count only), history, values, patches, or a URL's userinfo.
  - Every message goes through §5.3, and the whole text through `Secrets.scrubCredentials` once more.
- **Reads:** R2's `pagedObjects` through `agentClient` (`.background`), bounded tighter, at 200 objects or 16 MB a kind, within `readTimeout`. It is an on-demand read like `k8s_get`, not a watch, so analysis.md §10's watch rule doesn't apply to it. §4 lists it with the other reads.
- **`k8s_why`** on a GitOps object returns the Ask Why text (§6.2). Today it throws for those kinds (`KubeMCP.swift:608`).
- **No write tool.** `k8s_apply` on the four GitOps kinds goes through G0d's rule: the person types the name.
- **The changelog line** says that agents started earlier need a restart to see the new tool, because the tool list is announced once.

### 6.2 Ask Why (G3)

`asksWhy` and `askWhyUnavailable` (`+AskWhy.swift`) take the four main GitOps kinds. `KubeAgentBriefing.gitOps(object:)` is offered on Failed, Blocked and Stuck rows, on the page and in the rail (through the host). It carries:

- the summary's fields;
- the conditions with their messages (§5.3);
- Argo's operation (phase, message, retries, up to 50 failed or out-of-sync resources);
- Flux's attempted against applied revision, and a HelmRelease's history head;
- the chain's root cause;
- with a matched checkout: the commits between applied and attempted (`git log --oneline`, at most 20, through §5.4), and the changed files under the pathspecs.

Every word goes through `Secrets`, and the brief is shown whole before it is sent, as today.

## 7. Settings

None. The bounds are constants, as `KubeHealth.listLimit` is:

- 20 objects and 16 MB a page; 500 objects and 64 MB a kind;
- 4 GETs in flight; 15 s per object; 20 a flush; 60 s for objects in progress;
- the 30 s ladder tick; the 10-minute Argo operation threshold; the 3-minute reconcile period;
- the 5-minute store and rail cache;
- the 10-watch allotment.

There is no `kubernetes.gitopsAttention` in 1.6.0 (decision 7). Per-context `argoNamespace` and `fluxNamespace` in Context Settings are later work. `argocd`, the namespaces Applications were seen in, `flux-system` and `accessibleNamespaces` cover the installs.

## 8. Tests

Every test runs against `FakeKubeAPI` (127.0.0.1, its own kubeconfig, contexts `kind-fake`, `fake-dev`, `fake-prod`), never a real cluster. Every fixture repository's git calls run with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, as `VersioningTests.swift:97` does, so that the developer's `insteadOf` rules can't change a match.

### 8.1 Unit (pure)

- **`KubeGitOpsSummaryTests`:**
  - the ladder: one fixture per rule and reason, in evaluation order. That includes Paused over Failed; Blocked over ArtifactFailed; auto-sync failed and won't retry; an old failed operation as a tag; `retryCount`; Missing with OutOfSync as Progressing; Terminating; Drift after an operation already ran for the revision; needs pruning; the HelmRelease rollback; and source drift timed by `lastUpdateTime`;
  - the 3-minute, 10-minute and `2 × interval` edges, re-ranked by the tick with no new input;
  - the last-error order;
  - `observedGeneration` lag timed from managedFields;
  - `suspendedAt`;
  - Argo 3's `appTree` health;
  - multi-source revisions;
  - the scope rule: own namespace, managed namespaces (a `flux-system` Kustomization with no `targetNamespace` and an inventory in `shop`), destination only before anything is applied, a remote destination not kept, a referenced Source, an ApplicationSet by owner, and unsummarised rows "not placed".
- **The sentinel test.** `s3cr3t-sentinel` is placed in:
  - `values`, `valuesObject`, `parameters`, `extVars`, `tlas`, `plugin.env`, `patches`, `postBuild.substitute`, generator `elements`;
  - `status.sync.comparedTo.source`, `status.history[].source`, `operationState.operation.sync.source`, `operationState.syncResult.source`, `operation.sync.manifests`;
  - `last-applied-configuration`, a URL's userinfo;
  - a message quoting a `kind: Secret` block.
  
  It must never appear in any `KubeGitOpsObject` field (reflected and stringified), in `KubeHealth.kept`'s output, in any row's text, in the hover, in the brief, or in the MCP answer.
- **`KubeGitOpsWireTests`:** no field outside the allow-list is decoded. A struct that declares `values` fails a compile-time list check against a reviewed constant.
- **`KubeGitOpsRevisionTests`:** the §2.6 table: `@sha1:`, `refs/heads/`, legacy `/`, `sha256:` (no commit), `+sha12` (resolved, ambiguous), the multi-source index, an OCI artifact's metadata.
- **`GitRemoteURLTests`:**
  - every form in §4.2;
  - `https://ghp_x@github.com/acme/shop.git` and `https://oauth2:tok@…` become `github.com/acme/shop`;
  - Azure's three forms, GitLab subgroups, `oci://` never matching, and `stripUserinfo(inText:)`;
  - `Refs.parse(remotes:)` never returns a raw URL.
- **`KubeGitOpsMatchTests`:**
  - repo and path; a path not on this branch; `..`, an absolute path, a NUL byte and a symlink out of the checkout refused; `/` in `manifest-generate-paths` taken as the root;
  - a Flux `sourceRef` across namespaces;
  - a HelmRelease's chart path, and its `chartRef` to a HelmChart;
  - an OCI artifact's source;
  - a `ref:` values source;
  - the tracking branch (`HEAD` becomes the remote's default branch);
  - the owner from each of the three labels and from the tracking id (`ns_app` too);
  - "not in this cluster"; "searched 500 of 1,240";
  - `.gitopsRevision` answered beside an image tag; its `.none` text;
  - the attempted ≠ applied wording;
  - one level of `kustomization.yaml` entries.
- **`KubeGitOpsGitArgsTests`:** a `:(top)x` path and a `:!` path are literal; a `-x` branch, a `--output=f` ref and `a..b` are refused; a non-commit SHA is refused.
- **`KubeWritesTests`:**
  - **Delete** on an Application with the finalizer (and its `/background` variant), on a pruning Kustomization and on a HelmRelease is name-typed on `fake-dev`, with its count.
  - **A delete whose read fails** gives the worst-case sentence.
  - **A child object's delete** says it will be recreated.
  - **Deleting `argocd`** counts what goes.
  - **Resume** on `fake-prod` names the revision and is name-typed with prune.
  - **Applying a changed `prune`, `path` or `repoURL`** is name-typed on every class.
  - **Refresh and reconcile** are never name-typed.
- **`KubeHealthTests`:** K601's generation rule on a Flux kind, and not on a cert-manager Certificate.
- **`KubeKindsTests`:** the keys (`g`, Forwards on `9`), the order, `listsKinds`, `KubeKeyGroup`.

### 8.2 Against the fake (`KubeGitOpsSessionTests`, `KubePanelGitOpsTests`, `KubeMCPTests`)

Assertions read the fake's request log.

- **Section shown:**
  - only GETs;
  - every watch is `as=Table`, with `includeObject` in {None, Metadata} and never Object (None for reads in one namespace);
  - one paged whole-object list per served kind, within its bounds;
  - no Secret path and no ConfigMap path;
  - kinds not served are not asked;
  - at most 8 watches open.
- **Paging:** a page over 16 MB halves the limit and asks the same `continue` again; one object over 16 MB stops the kind and says so; a 410 lists again.
- **Section left and page kept:** ↩ and back within 5 minutes makes no whole-object list again. **Page hidden:** no request after two flushes, `openWatches == 0`, and the store is dropped.
- **R3:**
  - 30 Failed Applications whose cells change give exactly 20 GETs in the first flush;
  - an unchanged healthy row with a new resourceVersion, and a new Age cell, give none;
  - an OutOfSync row whose operation fails with no cell change is refetched within 15 s and shows Failed;
  - a second change within 15 s waits.
- **Scope:**
  - a 403 across the cluster (`FakeKubeAPI.forbidden = ["applications.argoproj.io@cluster"]`) falls back to `argocd`, and that is said;
  - no ConfigMap is read in the fallback;
  - a namespace that refuses is named;
  - a scope change outside the fallback makes no request.
- **Controllers:** a `kustomize-controller` Deployment at 0/1 shows the banner.
- **Scale:** 1,000 Applications' rows come in one streaming list where the server serves one (1.32, 1.34+; the fake does), and in two row pages of 500 where it refuses one (the WatchList gate off); a summary list cut at 500 and said; and a burst of 500 events applied in batches.
- **Rail:**
  - unbound gives zero requests; hidden gives none;
  - labelled Deployments give the owner by one GET each, with no list across the cluster;
  - no Kustomization or HelmRelease list when no GitRepository or OCIRepository matched;
  - the cache: a second show within 5 minutes lists nothing;
  - P0 discovers once when nothing is known;
  - on `fake-prod`, nothing is listed across the cluster until Find What Deploys This is pressed;
  - on `fake-prod`, writable by default (no switch), the log holds no non-GET after every rail action short of a confirmed verb;
  - no `git fetch` among the `Git.run` arguments (a temporary repository with `c1` and `fix/orders`);
  - a new HEAD recomputes the manifests line.
- **MCP:**
  - bounded output;
  - the sentinel and userinfo absent;
  - `checkout` uses the pane's binding, refuses another context and an unbound checkout, and on `fake-prod` with a cold cache makes no list across the cluster;
  - no GitOps write tool listed;
  - `k8s_apply` on a Kustomization asks with the name typed;
  - `k8s_why` on an Application answers;
  - no non-GET recorded by `k8s_gitops`.

### 8.3 Fixtures (`FakeKubeAPI+GitOps.swift`, beside `FakeKubeAPI+PromQL.swift`)

The fake evaluates no printer-column JSONPath, so each helper sets the body and the cells together, as `addHelmRelease` does. `setArgoState(…)` and `setFluxReady(…)` call `setFields` and `update(values:)` in one step, so a watch sees one MODIFIED.

- **`serveArgoCD()`:** `applications.argoproj.io` v1alpha1 (short names `app`, `apps`; columns Sync Status, Health Status, Revision p10, Project p10); `applicationsets` (no columns); Deployments `argocd-server`, `argocd-repo-server` and the StatefulSet `argocd-application-controller` in `argocd`. No ConfigMap.
- **`serveFlux()`:**
  - `kustomizations` v1 (`ks`; Age as `date`, Ready, Status);
  - `helmreleases` v2 (`hr`);
  - `gitrepositories` v1 (URL, Ready, Status);
  - `ocirepositories` v1, `helmrepositories`, `helmcharts` (Chart, Version, Source Kind, Source Name), `buckets`;
  - Deployments `source-controller`, `kustomize-controller` and `helm-controller` in `flux-system`, with `setControllerReady(_:)`.
- **Argo objects:**
  - `acme-shop-prod` in `argocd`: repo `https://git.acme.example/acme/shop.git`, path `deploy/fake-prod`, destination `shop`; Synced, Healthy; `history` at `c1`; `helm.values` holding the sentinel, also in `status.sync.comparedTo`.
  - `acme-api` in `team-a`: multi-source, a chart from `oci://ghcr.io/acme/charts` plus `ref: values` from `git@git.acme.example:acme/shop`; OutOfSync, Degraded; `operationState` Failed for the current revision, with a message holding `https://bot:ghp_fake@git.acme.example/…` and a quoted `kind: Secret`; `resourceHealthSource: appTree`.
  - `acme-web`: auto-sync on, the operation Failed for `sync.revision`.
  - `acme-new`: Missing and OutOfSync, auto-sync on, an operation Running.
  - `globex-batch`: an operation Running for 26 minutes.
  - `acme-admin`: OutOfSync, auto-sync off.
  - `acme-old-fail`: Synced and Healthy, with a failed operation for an older revision.
  - `acme-remote`: destination `https://fake-prod.example:6443`, namespace `shop`.
  - An ApplicationSet `acme-envs` with two generated Applications, and one with `ErrorOccurred`.
- **Flux objects:**
  - A GitRepository `acme-fleet` (`https://user:ghp_fake@git.acme.example/acme/shop.git`, branch main) and `acme-broken` (AuthenticationFailed).
  - Kustomizations:
    - `acme-apps` (`./deploy/fake-dev`, no `targetNamespace`, an inventory holding `shop_shop-api_apps_Deployment`, Ready, applied == the artifact);
    - `acme-cron` (attempted ≠ applied, Ready=False BuildFailed);
    - `acme-web` (DependencyNotReady on `acme-infra`, which is HealthCheckFailed);
    - `acme-api` (sourced from `acme-broken`, its own reason ArtifactFailed);
    - `acme-jobs` (suspended, with a managedFields time, Ready=False from before);
    - `globex-remote` (`spec.kubeConfig`).
  - HelmReleases: `globex-redis` (`chartRef` to an OCIRepository, Stalled RetriesExceeded) and `acme-payments` (Ready=False RollbackSucceeded, `lastAttemptedRevision` 1.5.0; `history[0]` the rollback's release, deployed at 1.4.2, the failed 1.5.0 after it — helm-controller records a rollback as a release of its own, so "rolled back to" is `history[0]`'s chart version).
  - An OCIRepository whose artifact metadata names `git.acme.example/acme/shop` at `c1`.
- **Refusals:** the fake's existing `forbidden` set.

### 8.4 E2E

**Shared fixture first.** G5 moves `kubernetesCheckout`'s `ot-kube-shop` repository and its `c1` into a shared helper (`E2EKubeCheckoutFixture`), with its git isolated as in §8.

**`kubernetesGitOpsSection`** (`E2ERunner+KubernetesGitOpsSection.swift`, run after `kubernetesGitOpsVerbs` in `E2ERunner+Kubernetes.swift:342`) checks:

- `g` shows the section; the chips and the order are drawn; `acme-cron` is Failed and `acme-api` Blocked by `acme-broken`;
- the `shop` scope keeps `argocd/acme-shop-prod` by its destination, and `flux-system/acme-apps` by its inventory; `acme-remote` isn't kept;
- `acme-web`'s chain names `acme-infra`;
- Hide Ready;
- the controller banner, after `setControllerReady(false)`;
- ↩ opens the detail, and back to `g` makes no whole-object list (from the log);
- `r` asks the same sheet `kubernetesGitOpsVerbs` checks;
- `s` records the tab line and doesn't type it (`KubeCommands`);
- the Overview's GitOps line goes to `g`;
- the empty-scope hint's "Show argocd";
- with the page hidden, nothing is asked for 1.5 s;
- a layout dump.

G3 adds: the detail's GitOps header, and `a` opening the brief.

**`kubernetesCheckoutGitOps`** (`E2ERunner+KubernetesCheckoutGitOps.swift`, on the shared fixture with `c1` and `fix/orders`). Its setup adds a remote in the scp form (`git@git.acme.example:acme/shop.git`) and a `deploy/fake-dev` folder with a `kustomization.yaml`. It checks:

- the rail's row, and the owner "owns Deployment/shop-api" found by one GET;
- `kubernetes.panel.gitops.deployed` says "manifests at <c1>…, this branch is 1 commit ahead";
- Diff Deployed…Current opens a review tab;
- the changed-files line names the paths it checked;
- `acme-cron`'s "c03f9aa failed; a77b0d1 still applied";
- Reconcile from the rail asks the page's sheet, and its outcome shows in the rail;
- bound to `fake-prod`: the Find What Deploys This button, and no list across the cluster before it is pressed;
- unbound and hidden ask nothing.

**`kubernetesPerf`** gains a GitOps leg in G8: 1,000 Applications with metadata, and a 500-event burst, timed and counted, with bytes received recorded.

### 8.5 Real CRDs (opt-in)

`Scripts/fetch-gitops-crds.sh` pins an Argo CD release and a Flux release, downloads their CRD YAMLs, checks them against SHA-256s written in the script (as `fetch-notes-web.sh` does), and commits them under `Tests/OvertermTests/Fixtures/gitops-crds/`. Nothing is downloaded at test time.

One `KubeRealClusterTests` case (`OVERTERM_KUBE_TESTS=1`):

- applies those files to `kind-fake`, only with `--kubeconfig` set to `Scripts/kube-test-cluster.sh`'s file;
- refuses to run when the kubeconfig path resolves to `~/.kube/config`, or when its current context isn't `kind-fake`;
- checks the real printer columns' names and types against `FakeKubeAPI+GitOps`'s;
- resolves the [verify] fields against the schemas.

## 9. Stages

Each stage is one commit.

**Before each:**

- `swift format --in-place --recursive Sources Tests`, `make test`, `make e2e`.
- Docs change in the commit that changes the behaviour:
  - architecture.md: the Kubernetes part's GitOps paragraph next to "Flux and Argo CD", the rail panel paragraph, the MCP list;
  - analysis.md: §2.23, §3.2's fourth commit source, §4's reads, decision 24, §10's watch counts;
  - CLAUDE.md: the Kubernetes Layout row.

**Versioning.** VERSION stays **1.6.0**: it is unreleased, and the last tag is `v1.5.0`. Each stage a person sees adds its line to 1.6.0's CHANGELOG entry, as the metrics stages did. The Size column gives the change's size, for the commit message. If `make hooks` is on in the clone that commits, a stage that leaves VERSION at 1.6.0 needs `SKIP_VERSION_CHECK=1`. Hooks are off in this clone today, which is how the M stages went through.

| Stage | Commit subject | What | Size |
|---|---|---|---|
| **G0a** | `kubernetes: Argo CD 3 and multi-source Applications read right` | §1.1 rows 1–5: `appTree` health said; `revisions[]` everywhere; `KubeGitOpsOwner` extracted from `KubeApply.owners`, with the instance label; K601's `observedGeneration` for Flux kinds; `kept` scrubbing `status` and the new keys. `KubeGitOpsTests`, `KubeHealthTests`, and the sentinel against `kept`. | PATCH, line |
| **G0b** | `kubernetes: deleting a GitOps object says what goes with it` | §1.1 rows 6–7: `KubeWriteFacts.gitOps` read for `.delete`; the name typed on every class for the three kinds; the count, the worst case, "will be recreated"; the finalizer by prefix; the namespace warning. `KubeWritesTests`, and a `kubernetesGitOpsVerbs` check. | PATCH, line |
| **G0c** | `kubernetes: a Flux source's URL without its credentials` | §1.1 row 8: `GitRemoteURL.withoutUserinfo` (the first piece of `GitRemoteURL`) in `KubeTableReader.row` for the source kinds | PATCH, line |
| **G0d** | `kubernetes: changing a GitOps object's source, prune or suspension says so` | §1.1 rows 9–10: `KubeApply`'s and the YAML save's comparison for the four kinds; `k8s_apply` name-typed by the person; Resume on production naming what it applies. `KubeWritesTests`, `KubeMCPTests`. | PATCH, line |
| **G1** | `kubernetes: GitOps objects summarised` | `KubeGitOpsWire`, `KubeGitOpsObject`, `KubeGitOpsState` (with the tick), `KubeGitOpsRevision`, `KubeGitOpsSummary`, `KubeGitOpsPath`, `KubeGitOpsGitArgs` and the rest of `GitRemoteURL` (pure); the shared source parsing out of `KubeGitOpsTree`; K602 and K603 through the ladder; `FakeKubeAPI+GitOps`; §8.1's tests; `Scripts/fetch-gitops-crds.sh` and §8.5. The Overview's GitOps findings change, so it gets a line. | PATCH, line |
| **G2** | `kubernetes: a GitOps section (g) — Argo CD and Flux on one screen` | `KubeSection.gitops`, the explicit `key`, `KubernetesKey.gitops`, `KubeKeyGroup`, `listsKinds`; `KubeGitOpsSession` (R1, R1c, R2's `pagedObjects`, R3, the allotment, the fallback, hide) and `KubeGitOpsStore`; `KubeGitOpsView`; `KubernetesPageModel+GitOps` (`updateGitOpsReading()` at its three call sites, `gitOpsPress`, `writeTarget`, `gitOpsVerbs`); the chips, order, Hide Ready, "not placed", the banner, the empty hint; the Overview line; the palette and `:gitops`/`:argo`/`:flux`; `kubernetesGitOpsSection` | MINOR |
| **G3** | `kubernetes: a GitOps object's detail says why, where from and what's applied` | §2.9's header; the chain; Argo's operation, out-of-sync resources and history; `asksWhy`/`askWhyUnavailable` for GitOps kinds, `KubeAgentBriefing.gitOps`, `a` in the section; `kubernetesGitOpsSection`'s G3 checks | MINOR |
| **G4** | `kubernetes: GitOps grouped by source, owner or destination` | `G` (`KubernetesKey.groupBy`), `KubeGitOpsFilter`'s tokens | MINOR |
| **G5** | `kubernetes: the rail says which Argo CD and Flux objects deploy the checkout` | `E2EKubeCheckoutFixture`; `KubePanelGitOps`, `KubeGitOpsMatch`, the remotes once per checkout, `KubeListOptions.owners` and `KubeRow.owner`, P0–P6, Find What Deploys This on production, `KubeGitOpsMatchCache`; `KubeGitOpsPanelHost`; the panel's part and its buttons; the detail's history entries each opening a review of `git diff a..b -- <path>` in the matched checkout (§2.9, through §5.4's checks — waits on the match, left by G3); `kubernetesCheckoutGitOps` parts 1–3 | MINOR |
| **G6** | `kubernetes: has this branch reached the cluster, from Argo CD's and Flux's revisions` | `KubeCommitSource.gitopsRevision` and its `.none` text, the HEAD key, the manifests line beside the image line, attempted ≠ applied, fetched-not-applied, the tracking branch, the pathspecs, "no change under", the changed files and their review tab; the rail's Ask Why with the commits; `kubernetesCheckoutGitOps` parts 4–6 | MINOR |
| **G7** | `kubernetes: k8s_gitops for agents` | §6.1, the `checkout` fence, `k8s_why` for GitOps kinds; analysis.md §4; `KubeMCPTests` | MINOR |
| **G8** | `kubernetes: GitOps' performance budget` | `kubernetesPerf`'s GitOps leg (1,000 Applications), and whatever it finds | PATCH; no line if tests only |

**The floor is G0a–G0d, G1, G2, G5 and G6.** G3, G4 and G7 add depth. G8 proves the bounds at scale. The G0 stages stand on their own and can ship even if the rest slips.

**Each stage names its scenario parts.** A stage is never done with a part merely written and skipped.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Argo at scale: 1,000 Applications, each up to 1 MB with `status.resources` | Rows for everything live. Summaries are paged by count and by bytes (20, halved on overflow), capped at 500 objects or 64 MB a kind, and decoded straight into allow-listed structs, two kinds at a time. GETs come at most 4 in flight and 20 a flush. G8 measures it. |
| R1's metadata across the cluster (managedFields, last-applied) | It is counted in §3.2 and decoded to nothing but namespace and labels. G8 measures the bytes; a fix (§3.2) is ready if needed. |
| CRD versions move (OCIRepository `v1beta2` → `v1`, HelmRelease `v2beta*` removed) | The version always comes from discovery. The decoders read fields, never a version, and ignore unknown fields. |
| Fields marked [verify] (`automated.enabled`, `sourceHydrator`, `retryCount`, a SHA-256 GitRepository's revision) | Each is read optionally, and its absence falls back to the documented older field. Each is checked against the pinned CRDs (§8.5) before the stage that uses it. |
| The fake doesn't evaluate JSONPath, so cells and bodies could disagree in tests and hide a bug | The helpers set both in one call. §8.5 checks the real columns' names and types, Age's `date` included. |
| A state that depends on time | Every time is read from the object. The 30 s tick re-ranks with no read, so opening the section late shows the same state as watching it all along. |
| A false match (a fork with the same path) or a missed one (an ssh alias, a mirror, a cut list) | The match is `host/org/repo`. Aliases are compared as written (decision 8). `.repoOnly` and the path check say what matched. A cut list says what it searched. Nothing writes on a match. |
| The rail reading a production cluster | Only a bound checkout, only the binding's context, only on screen, through a GET-only client. Lists across the cluster run only when pressed. Cached 5 minutes. Never another context. |
| The OutOfSync noise (`ignoreDifferences`, HPA replicas) | Auto-sync's OutOfSync is Progressing only while Argo is acting. A lasting one is Drift with its reason, and manual sync is a tag. |
| Secrets leak through a field nobody listed | The decode is the allow-list (§2.4). `kept` is fixed for the Overview. The sentinel test covers every known carrier, the status copies included. Messages are cut at manifests (§5.3). |
| Cluster strings reaching git | §5.4: literal pathspecs, verified commits, checked refs, `--end-of-options`. |
| A write that cascades through a GitOps object | Delete, a namespace delete, an apply that changes the source or prune, and Resume on production all say what goes with them and type the name (G0b, G0d). |
| Keys: `g` and `G` collide with a future binding | `isWellFormed` and `KubeKindsTests` catch duplicates. `G` is active only in the section. |

## 11. Later (not 1.6.0)

- **Hard Refresh** (`KubeWriteVerb.hardRefresh`, with a warning about the repo-server's load and no typed name).
- **Terminate Operation** (`KubeTabWrite.argoTerminate`, the name typed on production).
  
  Each is one commit through the guard path.
- **Diffs:**
  - `flux diff kustomization --path` in a tab, classed as a reading process and asked once on production;
  - `argocd app diff --local --core` in a tab;
  - a native render of the branch's path with a server-side dry run (decision 30's diff), with SOPS files skipped and said.
- **ApplicationSet git generators' `directories`/`files` globs** (`fnmatch`; matrix and merge to depth 3), for a checkout no generated Application matched.
- **Find What Deploys This for an unbound checkout:** a pressed, bounded read of the page's context, never production, which turns a match into a binding draft.
- **GitOps attention marks:** a third budgeted watch per bound scope through `KubeAttentionBudget`; `kubernetes.gitopsAttention`, off by default.
- **R1 without metadata**, if G8 asks for it (§3.2).
- **Smaller additions:**
  - a commit-per-environment matrix (Kargo's idea), once a checkout can bind to several contexts;
  - Flux image automation's `lastPushCommit` in the rail;
  - Argo sync windows evaluated (today auto-sync "not started" may be a window);
  - Flux Operator's kinds;
  - per-context `argoNamespace`/`fluxNamespace`;
  - `$values` files of another source followed in "no change under".

## 12. Decisions (taken, with the recommended option)

| # | Question | Decided | Why |
|---|---|---|---|
| 1 | The section's key | **`g`**, with an explicit `KubeSection.key`; the digits unchanged | 1–9 are taken and `0` is All Namespaces. Renumbering Helm or Forwards breaks habits and `KubeHelmTests`. |
| 2 | A new kind list or a summary | **A summary** (`listsKinds` false); ↩ to the kind's list and detail | The verbs, the trees and the YAML already exist on the kinds' lists. A second list would duplicate them. |
| 3 | Scope | **Own namespace or a managed namespace**; the in-cluster destination before anything is applied; Sources by reference; a remote cluster's objects by their own namespace only | Argo's and Flux's objects live in their controllers' namespaces, and a typical Kustomization has no `targetNamespace`. What it manages is where it deploys. |
| 4 | Live state | **Rows-only Table follows**; whole objects by one byte-bounded paged list, then GETs when cells change or a row isn't healthy | Whole-object watches cost 50 KB–1 MB an event on large Argo installs. Refetching every `resourceVersion` would be 5–10 GETs a second at 1,000 Applications. Refetching on cell changes alone would miss failed operations. |
| 5 | Which kinds are followed live | **Applications, Kustomizations, HelmReleases, GitRepositories, OCIRepositories, plus the controllers (3)**. ApplicationSets, HelmRepositories, HelmCharts and Buckets come by the list and GETs only. | Eight watches within the page's 10, allotted explicitly. ApplicationSets have no columns to follow. |
| 6 | Argo's manual sync | **A tag, not a state**, unless OutOfSync | Many teams sync by hand on purpose. Making it a state would colour healthy apps. |
| 7 | GitOps attention marks in 1.6.0 | **None** | `KubeAttentionWatches`' stated budget (two watches per bound namespace) stays. Marks can come later, off by default. |
| 8 | ssh host aliases | **Compared as written; no `ssh -G`** | It would run a process per remote and read the user's ssh config. A mismatch is visible and can be fixed by a remote URL. |
| 9 | Time-based thresholds | **From the object's own times:** `max(2 × interval, 5 min)` for Flux, 10 min for an Argo operation, 3 min for auto-sync to start; a 30 s re-rank; no setting | The section reads only while shown, so a "seen for N minutes" rule would restart on every show. |
| 10 | Hide Ready | **On above 50 rows**, counted on its chip | Problems first is the point. A small scope shows everything. |
| 11 | The rail's reads | **Owners first, by GET; lists across the cluster on show off production, on a press on production; cached 5 minutes in memory**; Kustomizations and HelmReleases listed only when a Flux Source matched | The common case answers with no list. Production gets no automatic read across the cluster. Unbound reads nothing. |
| 12 | The deployed commit's source | **`KubeCommitSource.gitopsRevision`, asked separately, shown as a "manifests" line beside the image's** | It is the manifests' commit, not the build's. Ranking them in one list would hide one of the answers. |
| 13 | Delete on GitOps objects | **Kept, the name typed on every class, with what goes with it said**, fixed in the existing path first (G0b), namespaces included | It is a gap today, in the generic list too. Leaving it out of the menu would leave the list's ⌫ unguarded. |
| 14 | New verbs | **None in 1.6.0** (Hard Refresh and Terminate later); the existing apply and Resume made to say what they do (G0d) | Every needed verb exists. The gaps are in what the existing ones say. |
| 15 | What is kept of an object | **An allow-list that is the decoder (`KubeGitOpsWire`)**; `kept` fixed for the Overview | A deny-list missed `extVars`, `tlas`, patches, `substitute`, generator elements and Argo's status copies. A decoder that never parses them can't leak them. |
| 16 | Agents | **`k8s_gitops`, read-only and bounded; `checkout` fenced to the binding; no list across a production cluster unpressed**; Ask Why and `k8s_why` gain GitOps objects; `k8s_apply` on these kinds has the person type the name | An agent's "is it deployed yet?" after a push is the common question. Writes stay with `KubeAgentWrites`. |
| 17 | Version | **1.6.0, a line per stage a person sees**, VERSION unchanged | The user asked for it in 1.6.0, which is unreleased. The metrics stages did the same. |
| 18 | The section's memory | **Summaries kept 5 minutes while the page shows; follows only while the section shows** | ↩ to a detail and back is the common path. Re-reading up to 64 MB a kind each time would defeat the bounds. |

## 13. What the review changed

### Feasibility against the code

| # | Finding | What was done |
|---|---|---|
| 1 | A 16 MB page of 100 large objects gives zero summaries | Applied. `limit=20`, halved on `KubeBodyTooLarge`, same `continue`. One object over 16 MB stops the kind, said; no `continue` can skip it (§3.1 R2). |
| 2 | `getAll` can't page | Applied. New `pagedObjects` loop modelled on `listOne`, on `get(maxBytes:)`, two kinds at a time (§3.1). |
| 3 | The Overview's objects can't be reused | Applied. The claim and its risk row are gone, and §3.1 says why they never coexist. |
| 4 | ↩ throws away the R2 read | Applied. `KubeGitOpsStore` keeps the summaries 5 minutes while the page shows (§3.1, decision 18). |
| 5a | Age cells change on every event | Applied. Date columns are left out of the comparison (§3.1). |
| 5b | Failed and Stuck invisible live | Applied, merged with value 12: unhealthy rows are refetched on any event every 15 s, and in-progress ones every 60 s (§3.1 R3 c–d). |
| 6 | The watch budget breaks in the fallback | Applied. Five kinds across the cluster, the Argo/Flux namespace fallback, explicit allotment within 10, ApplicationSets out of R1 (§3.1, §3.3). |
| 7 | `kept` drops managedFields before `suspendedAt`; memory | Applied. A `Decodable` allow-list decodes managedFields' keys only and builds no tree; `kept` isn't in this path (§2.4). |
| 8 | The rail needs discovery | Applied. P0 (§4.4). |
| 9 | Kustomizations with no `targetNamespace` are dropped; unsummarised rows | Applied, with value 1. `managedNamespaces` and "not placed" (§2.5). |
| 10 | ApplicationSets have no columns | Applied. Out of R1 and out of decision 5. |
| 11 | Time rules need re-running; the generation lag needs a time | Applied. The 30 s tick and `generationChangedAt` from managedFields; K601 has no minute rule (§2.3, §1.1). |
| 12 | K601's generation rule would hit cert-manager | Applied. Flux kinds only, with a test. |
| 13 | The Overview line can't agree; the count lives only in the section | Applied. The line says it counts what lives in the scope; `KubeGitOpsCount` is dropped (§2.1). |
| 14 | The fallback would read `argocd-cm` | Applied, with safety 6. `argoDefaultNamespace` plus the namespaces seen, no ConfigMap (§3.3). |
| 15 | OCI matching can't work from rows | Applied. OCIRepositories are read as whole objects in P3 (§4.4). |
| 16 | G0a row 3 names code that isn't there | Applied. `KubeGitOpsOwner` extracted from `KubeApply.owners`; KubeOpen and KubePaneWarning removed. |
| 17 | The delete warning can't carry a count | Applied. `KubeWriteFacts.gitOps`, read for `.delete`, passed to the confirmation (§1.1). |
| 18 | Ask Why is used in G2 but built in G3 | Applied. `a` is in G3 with `asksWhy`/`askWhyUnavailable`; `k8s_why` is in G7. |
| 19 | The rail can't reach the page's guard | Applied. `KubeGitOpsPanelHost` loads the contexts and reports in the rail; Ask Why is wired through it (§4.5). |
| 20 | The test assertions on `includeObject`, the HEAD key and `.none` are wrong | Applied. {None, Metadata}; HEAD added to the gitops key; a source-aware `.none` (§8.2, §4.3). |
| 21 | Double click, `refuseList`, `listsKinds`, call sites, `KubeKeyGroup`, the shared fixture, Delete via `detailVerbs` | All applied. Double click dropped; the fake's `forbidden` used; the rest named in §2.1, §2.7, §8.4 and the stages. |
| 22 | `k8s_metrics` wording; G1 is visible; the hooks | Applied. §6.1 reworded as an on-demand read; G1 gets a CHANGELOG line; `SKIP_VERSION_CHECK=1` noted (§9). |

### Safety and security

| # | Finding | What was done |
|---|---|---|
| 1 | R1 across the cluster carries metadata; G5's `row()` change affects every list | Applied. Said in §3.1–3.2 with costs redone; owner extraction opt-in via `KubeListOptions.owners`; assertions fixed. A risk row and a later fix are noted. |
| 2 | `kept` misses Argo's status copies and `operation.sync.manifests` | Applied. G0a fixes `kept`, and the sentinel covers these carriers and `kept` (§1.1, §8.1). The section's decode never parses them. |
| 3 | The production socket isn't read-only once writes are allowed | Applied. Reworded; the guarantee is a GET-only client plus a `fake-prod` test with it writable (§4.4, §8.2). |
| 4 | The rail lists every Application on production | Applied, with value 15. Owners by GET first; Applications listed in Argo's namespace; on production only when Find What Deploys This is pressed; tested (§4.2, §4.4). |
| 5 | Cluster strings in git arguments | Applied. §5.4 `KubeGitOpsGitArgs` and its tests. |
| 6 | The fallback reads ConfigMaps | Applied. No ConfigMap in the fallback (§3.3). |
| 7 | Namespace deletes, finalizer variants, a failed read | Applied in G0b (§1.1). |
| 8 | `k8s_apply` and `KubeApply` can rewrite GitOps objects | Applied. G0d: the changed fields named and the name typed; `k8s_apply` always name-typed by the person. |
| 9 | Resume on production | Applied in G0d. |
| 10 | Manifests quoted in messages | Applied. Cut at the first manifest line; 4 KB hover bound; a sentinel case (§5.3). |
| 11 | Remote URLs with tokens; developer git config in tests | Applied. Normalised inside the parser; fixtures with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` (§4.2, §8). |
| 12 | Path check holes | Applied. Absolute and NUL refused; components compared after resolving symlinks; tests (§4.2). |
| 13 | `k8s_gitops checkout` isn't fenced | Applied. Another context and an unbound checkout refused; a cold cache bounded; production unpressed lists nothing (§6.1). |
| 14 | Real-cluster CRDs | Applied. Pinned and SHA-checked by a script, committed; a guarded kubeconfig check (§8.5). |

### Argo CD and Flux correctness, and user value

| # | Finding | What was done |
|---|---|---|
| 1 | Scope drops Kustomizations with no target and app-of-apps children | Applied. `managedNamespaces` (§2.5). |
| 2 | A remote destination counts as in scope | Applied. In-cluster only (§2.5). |
| 3 | `storageNamespace` isn't a destination | Applied. Removed; `targetNamespace ?? metadata.namespace`. |
| 4 | "OutOfSync for 10 minutes" has no start time | Applied. Rules from the operation's revision and times, the 3-minute reconcile period, generation time from managedFields, the 30 s tick (§2.3). |
| 5 | Auto-sync doesn't retry a failed revision; `retryCount` | Applied. Failed with "won't retry it"; retries counted as Failed. `retryCount` is marked [verify]. |
| 6 | An old failed operation turns a healthy app red | Applied. It counts only for the current revision; otherwise a tag. I used "the operation's revision equals the current one" rather than also "or not Synced", because an older revision's failure on an OutOfSync app is a new commit Argo will try (Progressing or Drift). |
| 7 | `acme-cron` contradicts the ladder | Applied. It is Failed; attempted ≠ applied is wording, not a rule. The mock-up and E2E are fixed. |
| 8 | HelmRelease v2's `lastAppliedRevision`; rollbacks | Applied. `history[0]` compared; RollbackSucceeded/UninstallSucceeded are Failed with "rolled back". |
| 9 | Blocked loses to Failed | Applied. Blocked is evaluated before Failed, whatever the object's own reason. |
| 10 | Paused after Failed | Applied. Paused first, the old state as a tag. |
| 11 | Missing as Failed; Terminating | Applied. |
| 12 | Live cells can't show Stuck | Applied. The 60 s refetch, merged with feasibility 5b. |
| 13 | A controller that is down | Applied. R1c's three follows, the banner, "not reconciled for 40 min". |
| 14 | Argo's default instance label; finalizer variants | Applied in G0a and G0b. |
| 15 | "Nothing deploys this" on a cut list | Applied. Owners first; "searched 500 of 1,240". |
| 16 | "This branch changes nothing" can be wrong | Applied. Said as "no change under <paths>"; `manifest-generate-paths` and one level of `kustomization.yaml` added; never "nothing". |
| 17 | "Newer" can't be known; drift timing | Applied. "Differs"; timed by `lastUpdateTime` plus interval and retryInterval; compared with attempted; `merge-base --is-ancestor` in the rail. |
| 18 | Needs pruning, `summary.images`, "will be recreated", short SHAs | All applied: §2.3 Drift; §2.4 and §4.2's image fallback; G0b's warning; §2.6 and §5.4's prefix check with "ambiguous". |
