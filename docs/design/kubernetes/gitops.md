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
- **The summaries are kept** in `KubeGitOpsStore` on the page model, keyed by context, for 5 minutes while the page is on screen. Leaving `g` for ↩ and coming back restarts R1 and R1c (rows, cheap). R2 doesn't run again; R3 fetches the rows whose cells moved since. The store is dropped when the page hides, on a context change, on a credential failure, and at quit; its window merely covered, the section is left as for another section — every read ends, the store stays its 5 minutes (D7's fix pass, §14.4.2). It is never written to disk. A scope change only filters again, because R2 reads across the cluster, except in the fallback.
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
| **A settle** (14.2.5, D5) | One GET of each bound workload of an app read from marks (`KubeMarkedWorkloadWire`) — the bound apps' Argo Rollouts first, none of a Deployment scaled to 0 where Rollouts are served (its Rollout's phase says the app's health) —, then the Rollouts of the apps B, C or D found | within P2's 8 a read, 4 MB each; the rest "from its row", a Rollout's phase said unread | on show; again on a row event when its generation moved or it wasn't Healthy, 15 s apart; none for an app the section ranked in the last 5 min |
| **A Rollouts** (14.12's consequence 2, D5) | The binding namespace's Argo Rollouts as rows with their marks (a Rollout runs a Deployment of its own namespace only, by `workloadRef`) | one paged list, 500 objects or 8 MB, no watch | once a read, where Rollouts are served and a bound Deployment of an app read from marks is scaled to 0 |
| **B marks** (14.2.5, D5) | The cluster's Argo Rollouts (where served, first), Deployments, StatefulSets and DaemonSets as rows with their marks, or the section's apps when it read them whole across the cluster in the last 5 min; the checkout's committed `*.yaml`/`*.yml` (`git ls-files`) | 500 a page, 5,000 objects and 30 MB for every kind together — the M1 bound, "rows under 30 MB together" (14.4.1), each kind read with what the ones before it left —, no watch; 2,000 files, 256 KB each, 32 MB in all | where Applications aren't read and something here carries a mark; on production only when pressed. Kept 5 minutes with the cache |

- **The 5-minute cache.** `KubeGitOpsMatchCache` is app-wide and in memory, keyed by (context, binding, the remotes' normalised set, what discovery said of Argo CD and of Flux, each apart — `argo=served|unserved|undiscovered;flux=…`, D5). Switching tabs back and forth doesn't list again. It is dropped on a binding change, on a credential failure, on Refresh and at quit, and never written to disk.
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
  - `kind`: `application|applicationset|kustomization|helmrelease|source|marks|all` (`marks`, D6: Argo CD's apps read from the marks on their objects, §14.2.6).
  - `state`: `problems|all` (D6: the Ready apps read from marks listed, with `kind: marks`).
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

An Argo CD app read from marks has a brief of its own, offered whenever it isn't Ready (§14.2.6, D6).

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

## 14. Addendum: Argo CD in another cluster — apps read from their marks

This addendum covers a spoke cluster: Argo CD runs in a hub cluster that isn't in the person's kubeconfig. The spoke has no Application objects, and usually no Argo CRDs at all. Its objects still carry Argo CD's marks. On the cluster this was written for, about 980 Deployments carry `argocd.argoproj.io/tracking-id`, which works out to about 894 distinct apps in production. Today the GitOps section shows nothing there, and the rail only says "managed by Argo CD Application X (not in <ctx>)".

The person chose one thing only: **show from marks.** The section and the rail list the apps that the marks name. Each app's health is computed from its marked objects alone, and the page says plainly that Argo CD runs in another cluster.

The following are out of scope: Argo Rollouts, the Argo CD API or server, reaching the hub, and any verb that needs the Application (sync, refresh, rollback, diff).

It builds on the code after G0–G8; line references are to that code. Argo CD's rules (resource tracking, `isSelfReferencedObj`, gitops-engine's health checks) are Argo CD 3.x's own, read from its source and docs.

**The survey has run** (§14.12): a read-only look at the spoke's production and development clusters. Its numbers replace every estimate marked **[survey]** below, and **its six consequences override anything earlier in this section** where they disagree: derive apps whenever no Application here deploys them (not only when the kind isn't served), Argo Rollouts read for health only, Argo CD's hook Jobs left out of health, the rail's name match stripping `<env>-<ns>-` and `-service`, rows-only reads, and an expired sign-in said quickly.

An adversarial review checked this section against the code and Argo CD's source before any stage was built. Its corrections are in the sections they concern: the write paths that read a member's marks (§14.2.3), where `cliLine` lives and what a derived row's keys and verbs need (§14.7), the reader's required `kind` (§14.1), presence read from R1's uncut rows rather than R2's cut summaries (§14.2.1, §14.3), `argoproj.io` alone among `failedGroups` deciding "couldn't tell" (§14.2.1), unknown never said as absent (§14.2.1, §14.2.6, §14.3), health as Argo CD's built-in rules say it — StatefulSets and DaemonSets never Degraded, HPAs read whole, a CronJob that never succeeded Healthy, an app with no workload read Unknown, Unknown's rank (§14.5, D-7) —, one GET per bound workload in the rail (§14.2.5), option B as `.describes`, never `owns` (D-8), M2's GETs only on a generation move and at most 60 a minute (§14.4.1), "no discovery, no request" as the sign-in rule (§14.4.8), the tests each of those needs (§14.8, §14.9), and D7 gating the release (D-10).

### In short

- **A derived app** (`KubeMarkedApp`) is the set of top-level objects whose tracking id passes Argo CD's own self-reference check, grouped by installation id and the app's instance name.
  - Its health is the worst of its objects' health, under gitops-engine's built-in rules, as far as what is here can say.
  - It is never Drift, Blocked or Stuck: those need the Application.
- **The section turns on from marks.** When `applications.argoproj.io` isn't served, or can't be read anywhere, `g` no longer refuses. The section follows Deployments, StatefulSets and DaemonSets across the scope as rows with their metadata, and lists them with the line "Argo CD runs in another cluster — not in your kubeconfig."
- **Rows first, then a bounded settle by GETs.** A workload's first state comes from its Table cells (Ready, Up-to-date, Available) and is said as "from its row". Cells can't show a stuck rollout whose old pods still serve, a paused Deployment, or a stale generation. Reads are rows only, never a list of whole objects (§14.12, consequence 5: kubectl prints the whole Deployment list as 16 MB of indented JSON). So a row whose generation moves, whose cells turn not ready, or that isn't healthy gets one GET (M2), and the ready-looking rows are settled by Argo CD's rule in the background, one GET each, most recently changed first (M1b), all within one budget of 60 GETs a minute, decoded by an allow-list (decision D-4).
- **Two more tiers fill in the apps:**
  - Services, Ingresses and PVCs: a paged metadata list, no watch. CronJobs and HPAs: a paged object list by allow-list, no watch (their health needs status no cell shows).
  - One app's detail: a GET of each of its objects (at most 50), and its pods by selector.
- **No new write, and no verb that needs the Application.**
  - The detail says why Sync, Refresh, Rollback and Diff are absent.
  - Each object still opens in its own list, with the verbs it has today. The verbs say that Argo CD may undo the change.
- **The rail** keeps matching by the binding's own workloads (case b), and now adds the derived app's health.
  - For a config repository, it compares the checkout's committed manifests' object identities with the tracking ids, on a press on production, and says "describes N of its objects", never that the app deploys this checkout.
  - Name and image heuristics are "probably" only. Chart names are not used.
- **Agents:** `k8s_gitops` lists derived apps when Argo CD isn't here, under `kind: "marks"` too, through `Secrets`. Ask Why on a derived app briefs its failing objects.
- **Budget:** 3 page watches on All Namespaces or one namespace. Several namespaces take 3 a namespace only while that fits in the watches the GitOps kinds and controllers leave free; past that, 3 filtered across the cluster (§14.4.1). M2's GETs are capped at 60 a minute on top of the per-flush cap (§14.4.1). Rows across the cluster are kept under 30 MB, and grouping and ranking run off the main thread once per flush. Nothing goes to disk. No Secret or ConfigMap is listed, not even its metadata.
- **Unknown is never said as absent.** "Argo CD runs in another cluster", "not in this cluster", "no workload carries marks" and "doesn't deploy this checkout" are each said only when the read behind them was whole. A refused, cut or undiscovered read says what couldn't be read (§14.3, §14.2.1).
- **Stages:** D0–D7, each one commit. The floor is D0–D3 and D5.

### 14.1 What a mark says, and what it doesn't

**A tracking id** has the form `<app>:<group>/<Kind>:<namespace>/<name>`. It is split on `:` into exactly three parts, and the second and third on `/` into exactly two.

- The app part is `Application.InstanceName`:
  - `<name>` when the Application lives in Argo CD's own namespace, which is unknown from a spoke and is said as "Argo CD's namespace";
  - `<appNamespace>_<name>` otherwise.
- Core-group objects have an empty group, as in `shop:/Service:shop/api`.
- For a cluster-scoped object, the namespace part is the Application's destination namespace. It is empty only when the destination namespace is.

**Self-reference** (`isSelfReferencedObj`, `controller/state.go`). A mark counts only when its group, Kind and name equal the object's own, and its namespace equals the object's namespace (or the object is cluster-scoped).

- The Deployment controller copies every Deployment annotation to its ReplicaSets, old ones included, and operators copy marks onto what they create. Those objects fail the check and are not members. They show only under their owner, through ownerRefs, in the detail's tree.
- Before D0, `KubeGitOpsOwner.tracking` read only up to the first `:` and did no check. D0 (§14.8) reads it through `KubeTrackingID` and checks the object everywhere it is known: a row by the kind listed, the apply's live object by its own `apiVersion` and `kind`, a GitOps object's delete and its parent by its summary. A copied mark names no Argo CD owner, nor does an instance label beside it; Flux's labels still say theirs.
- **Where the object's identity comes from.** A row read with `includeObject=Metadata` embeds a `PartialObjectMetadata`: its `kind` and `apiVersion` are `meta.k8s.io`'s, not the Deployment's. The self check takes the group and Kind from the request's `KubeResourceKind` (the `kind:` that `KubeTableReader.row` already receives, `KubeTable.swift:241`), and the name and namespace from the row. It never takes them from the embedded object. Every list path that asks `owners` or `marks` already passes `kind` (`KubeClient.swift:469, 607, 886`), so D0 makes `kind` required whenever `owners` or `marks` is asked (a precondition, not a fallback). An "unchecked, probably" tracking id would be worse than useless: `isCertain` would be false, and `KubeGitOpsMatch.found` drops an absent uncertain owner, so the rail would silently lose it. The one caller today without `kind`, `KubeGitOpsMatchTests.swift:224` (`KubeTableReader.read(table, namespace:owners:)`), is updated to pass it.

**installation-id** (`argocd.argoproj.io/installation-id`). It is set when the hub sets `installationID`. Two Argo CDs that deploy into one cluster are told apart by it, so an app's key is `(installationID ?? "", instanceName)`.

**The older label.** `argocd.argoproj.io/instance` and Argo 2.x's `app.kubernetes.io/instance` (a cluster upgraded from `label` tracking):

- an object carrying only `argocd.argoproj.io/instance` is a member, marked `labelOnly`, with no self-reference check possible;
- `app.kubernetes.io/instance` alone stays "probably". It forms a derived app only when it is the only mark in the whole scope, so on a spoke with tracking ids it is never used. It is never mixed into a tracked app of the same name.

**What a spoke can say:**

- the objects, their namespaces, and the destination namespace when a cluster-scoped mark is seen;
- images and tags (cells);
- rollout revision and time (the detail);
- generation against observedGeneration;
- when Argo CD last applied a change: the newest `managedFields[].time` whose manager is Argo CD's.
  - With server-side apply the manager is `argocd-controller` (operation Apply). The client-side manager's name, **[verify]** here at first, is confirmed by §14.9.4's run after D7: Argo CD's client-side apply writes as `argocd-controller` too (operation Update).
  - It is shown only when the manager is one of those known names. There is no fallback to "the newest Update that isn't the controller's": that would credit Argo CD with a person's `kubectl edit`, `kubectl scale` or an HPA's write. With no known manager, the Age column shows the row's own age, and its hover says "Argo CD's last change isn't readable here".
  - This is said as "last change applied by Argo CD", never "last sync": a sync that changes nothing writes nothing.

**What it can't say:** sync status, repository, path, target revision, sync policy (auto, prune, selfHeal), last sync, project, ApplicationSet, the hub's custom or Lua health checks, missing resources, or whether the Application still exists in the hub. An app deleted from the hub without a cascading delete leaves its marks behind and looks the same. So does a cluster whose own Argo CD was uninstalled, or objects restored from another cluster's backup. "Argo CD runs in another cluster" is therefore an inference from "marks here, no Application kind here", and the hover says what else leaves the same marks. The page says this (§14.2.1) rather than guessing.

### 14.2 What the person sees

#### 14.2.1 When marks mode is on

| Discovery and reads | Section | Header line |
|---|---|---|
| `applications.argoproj.io` not served, and `argoproj.io` isn't among discovery's `failedGroups` (`KubeDiscovery.swift:53`; another group failing, such as a down `metrics.k8s.io`, has no bearing); marks seen | Derived apps only | "Argo CD runs in another cluster — not in your kubeconfig. These N apps are read from the marks Argo CD leaves on their objects." |
| `argoproj.io` (or the aggregated discovery's group list) failed to answer discovery; marks seen | Derived apps only | "Couldn't tell whether Argo CD runs in <ctx>: argoproj.io didn't answer discovery. These N apps are read from the marks on their objects." Never "another cluster", as `readOwners` already treats a failed group as unreadable (`KubernetesPanelModel+GitOps.swift:537-541`). |
| Served, but Applications refused in the cluster and in every fallback namespace (§3.3) | Derived apps only | "Argo CD's Applications can't be read in <ctx> (forbidden). These N apps are read from the marks on their objects." |
| Served, and R1's Applications **row follow** has listed **across the cluster** (not namespace by namespace); some marks name an app that isn't among its rows | Applications as today, plus derived rows for the rest | A chip, "M marked apps with no Application here", pressed to show them. Each row says "its Application isn't in this cluster" only under §14.3's rule. Otherwise it says "its Application wasn't found where Applications were read". Presence is decided from R1's rows (names only, paged, never cut: `KubeGitOpsSession.follow`), **not** from R2's summaries, which are cut at 500 by design: a hub that is also a destination with 1,000 Applications (the `kubernetesGitOpsPerf` fixture) would otherwise never get derived rows. |
| Served, but Applications were read only in fallback namespaces (403 across the cluster) | As today, plus derived rows only for marks whose `<appNamespace>_` prefix names a namespace whose R1 rows were listed | The rest are counted, not listed: "N marked apps whose Application namespace couldn't be read". A fallback namespace past `spareWatches` ("not watched; Refresh reads them") counts as unread until R2's read there answered whole. |
| Served, but R1's first list hasn't come yet | As today | Nothing is derived yet, and no chip: "not here" can't be said before the names are in. |
| Served; only R2's summaries were cut (500 objects or 64 MB) | As today, plus derived rows as in the row above | R2's cut has no bearing on presence (R1 has every name); it only leaves some Applications summarised "from its row", as today. |
| Not served or refused, marks seen, but M1 was cut, refused in some namespaces, or is still reading | Derived apps from what was read | The count is a floor and says so: "At least N apps, from what could be read: Deployments refused in 3 namespaces (a, b, c)". While M1's first list is still coming, no count: "Reading the marks on Deployments, StatefulSets and DaemonSets…". |
| Flux served, Argo CD not; marks seen | Flux's rows, plus derived rows | Both lines |
| Neither served, M1 read whole across the scope, and no marks in it | Empty | "No Argo CD Application is served by <ctx>, and no Deployment, StatefulSet or DaemonSet in <scope> carries Argo CD's marks." with Show All Namespaces when the scope is narrower |
| Neither served, no marks found, but M1 was cut, refused in some namespaces, or still reading | Empty | "No Argo CD marks found in what could be read: Deployments refused in 3 namespaces (a, b, c)", or "…: the list stopped at 5,000". Never "no Deployment carries". |

The fourth row (served, read across the cluster) covers a hub that is also a destination, and argocd-agent's managed mode, which puts Applications on the workload cluster: the existing section already covers it, and the derived rows only add the apps that are missing.

**The section row** shows when `KubeGitOpsSummary.served(discovery)` is true, or when `KubeMarksSeen` says this context's rows have shown a mark. `KubeMarksSeen` lives in memory per context and costs no request of its own, but it isn't free:

- Today no list but the rail's keeps a mark. The Overview's workload part asks `KubeListOptions(metadata: true)` with no `owners` (`KubeClusterOverviewSession.swift:130-133`), and `KubeTableReader.row` keeps only `app.kubernetes.io/*` labels (`KubeTable.swift:257`).
- So D2 adds a `marksSeen` flag to the reader: when the row has metadata, it looks only for the presence of the tracking annotation or `argocd.argoproj.io/instance`, and keeps nothing.
- The flag is set on the Overview's workload follows and on Deployments, StatefulSets and DaemonSets lists read with metadata. It is a key lookup per row and costs no allocation; the D7 perf leg times it against the pods leg.
- Until such a list has run, the row stays hidden, but `g` works (below). A person who opens the page on Pods and presses `g` sees the section.

**`g`, `:gitops` and `:argo`** no longer refuse when Argo CD isn't served (`showSection`, `KubernetesPageModel.swift:619-622`; the command bar's `.gitops` case, `:1093-1095`). They open the section, which looks for marks and says the right empty sentence above if none are found. `:flux` (`.gitops(.flux)`, `KubeCommand.swift:70`) still refuses when Flux isn't served. `gitOpsRefusal` keeps only the Flux case, and takes the tool.

**The second header line,** muted and always shown in marks mode, reads: "No sync status, repository or revision: those are in the Application, in Argo CD's cluster. Health is Argo CD's built-in rules applied to what is here." Its hover adds:

- "An app deleted in Argo CD without deleting its resources leaves the same marks. So does an Argo CD uninstalled from this cluster, or objects restored from another cluster."
- "Custom health checks configured in Argo CD aren't known here."
- "Read here: Deployments, StatefulSets, DaemonSets, CronJobs, Services, Ingresses, PersistentVolumeClaims and HorizontalPodAutoscalers. Jobs, Argo Rollouts and custom resources aren't read, so their health isn't in an app's. ConfigMaps and Secrets are never listed, so an app made only of them isn't seen."
- When discovery serves `rollouts.argoproj.io`: "Argo Rollouts are served here and aren't read: an app whose workload is a Rollout shows without it."

**Several installations** are said in the header: "2 Argo CD installations mark objects here: `hub-eu` (812 apps), unnamed (82 apps)". `G` groups by installation (§14.2.4).

#### 14.2.2 A derived app's row

```
GitOps · acme-spoke-prod · All Namespaces                               Argo CD: from marks · 894 apps · read 40 s ago
Argo CD runs in another cluster — not in your kubeconfig. These 894 apps are read from the marks Argo CD leaves on their objects.
No sync status, repository or revision: those are in the Application, in Argo CD's cluster. Health is Argo CD's built-in rules applied to what is here.
[3 failing] [11 progressing] [2 paused] [878 ready]                                                    / filter
● Failed       Marks  payments/checkout-api   payments        rollout stalled (ProgressDeadlineExceeded) · Deployment checkout-api   2 Deploy · 1 Svc   …/checkout-api:4.12.0     6m
● Failed       Marks  search-indexer          search +1       last run of CronJob reindex failed · and 1 more                     1 STS · 1 CronJob  …/indexer:2.3.1 +1       21m
◐ Progressing  Marks  ledger                  ledger          0/3 ready for 2 h · StatefulSet ledger-db                           1 STS · 1 Svc      …/postgres:16.4           2h
◐ Progressing  Marks  courier/eta             courier         2/4 updated · Deployment eta                                        1 Deploy · 1 HPA   …/eta:7f3c2e1             1m
‖ Paused       Marks  ops/backfill            ops             rollout paused · Deployment backfill                                1 Deploy           …/backfill:1.0.4         3d
```

Columns, reusing `KubeGitOpsRow`:

| Column | For a derived app |
|---|---|
| State | `KubeMarkedHealth` mapped onto `KubeGitOpsState`: Degraded → Failed, Suspended → Paused, Progressing → Progressing, Healthy → Ready. The hover always gives Argo CD's own word ("Argo CD's rule: Degraded"), so a person comparing with Argo CD's UI can. Argo CD's Unknown (a PVC in an odd phase, an HPA's conditions saying neither) → Unknown. **`KubeGitOpsState.unknown` sorts last today** (`KubeGitOpsState.swift:7`, raw value 7) and the shared enum isn't reordered, because Applications' Unknown means "not read yet" there. Argo CD's aggregation makes Unknown the worst, so an app with one Degraded and one Unknown member is Unknown in Argo CD: here its word is Unknown too, but its **rank** is the worst *known* member's (it sorts with Failed), its why names the Degraded member first, and Hide Ready never hides it. Never Drift, Blocked or Stuck. A state settled only from cells (before M1b's or M2's GET reached the object) carries "from its row" in the hover. The Ready chip counts those apart: "878 ready (31 from rows only)" — only a workload's cells or a member waiting for its object count (D3's fix pass): an HPA Healthy from its row and a Job's row never settle by GET, and nearly every surveyed app has an HPA. **StatefulSets and DaemonSets are never Degraded under Argo CD's built-in rules** (no progress deadline): a `0/3` StatefulSet is Progressing indefinitely, in Argo CD as here. Its duration ("0/3 ready" for 2 h), from when the row first read not-ready, is visible as such — as built (D3's fix pass) in the Age column, which counts from the state's `since` as the page's clock moves, never baked into the why. |
| Kind | "Marks" (`Role.markedApp`) |
| Name | `appNamespace/name` for `ns_name`. A plain `name` is shown bare, and its hover says "in Argo CD's own namespace". An installation is shown as a tag when there is more than one. |
| Into | The namespaces of its members: `payments`, or `search +1`; the destination namespace from a cluster-scoped mark when one was seen. |
| Why | The worst member's sentence and its object, then "and N more" (Argo CD names up to 3 causes; the hover lists them). Ready apps say what they are: "3 objects ready". |
| Revision | Empty. The hover says "Argo CD's revision is in the Application, in another cluster". The images are under Source. |
| Source | The main image, host trimmed: the first container of the first workload, by name, then "+N". It is not a git source, and the header's hover says so. |
| Tags | Counts by kind: `2 Deploy · 1 Svc · 1 HPA`. "label only" for `argocd.argoproj.io/instance` members. `selfHeal?` never: it is unknown. |
| Age | When its state began: for a problem, the condition's `lastTransitionTime` once a GET (M1b, M2) read it, else the row's last change seen; for Ready, "last change applied by Argo CD" when a known Argo CD manager is in `managedFields` (§14.1), else the newest member's age. The hover names which. |

- Display order, chips, Hide Ready above 50 and the 30 s re-rank are the same as for every row.
- On 894 apps, Hide Ready is on, so the list opens on its 10–20 problems **[survey]**.
- Row height and `ResourceTable` are unchanged. Counts are `Text(verbatim:)`.

#### 14.2.3 A derived app's detail (↩)

↩ on a derived row opens `KubeMarkedAppDetailView` in the page's detail slot. There is no kind list to open it in. The panel shows, from top to bottom:

1. **The header:** the name, the installation, the namespaces, the state and its sentence, and "Argo CD runs in another cluster" with the same hover.
2. **"What Argo CD knows and this cluster doesn't".** One line each: Sync status, Repository and path, Target and live revision, Sync policy, Last sync, Project. Each reads "in the Application, in Argo CD's cluster". The rows are fixed: none is ever filled from a guess.
3. **The tree.** The app, then its top-level members by kind, then (by ownerRefs) the newest ReplicaSet and the pods, or a StatefulSet's or DaemonSet's pods, or a CronJob's last Jobs. Each node has Argo CD's built-in health:
   - Pods are shown with their own health, but, as in Argo CD, they don't count toward the app's.
   - Copied marks (§14.1) appear here as children, never as members.
   - A hook (`argocd.argoproj.io/hook`, `helm.sh/hook`) or an `ignore-healthcheck: "true"` member is drawn grey with "not counted, as in Argo CD".
4. **Hints** read from members' annotations:
   - `sync-wave`;
   - `sync-options`, e.g. "`Prune=false` on Deployment x" or "`ServerSideApply=true`";
   - `compare-options`;
   - `link.argocd.argoproj.io/*` as text (decision D-3).
5. **The verbs:**
   - Open each object in its own list (↩ on a node), Copy Names, Ask Why (`a`), and Copy Argo CD Command (decision D-2). As built: Tab takes the keyboard from the section's rows into the tree, ↑ ↓ walk its nodes as drawn (then the hooks), ↩ opens the one picked, and Tab, another row picked or Esc give it back; `[` from the object returns to the app's detail on that node.
   - The absent ones are listed by name: "Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there."
6. **The images line and the deployed commit.** `KubeDeployedCommit` already answers from an image (revision label, tag, appVersion), so "has this commit reached the cluster" works from the image. The manifests line (`gitopsRevision`) is absent, with the same sentence.

**Writes on members are unchanged and say more.** An object opened in its own list keeps every verb it has today: restart, scale, edit, delete. Today only one write path names a GitOps owner from a member's live marks: `KubeApply`'s warnings (`KubeFieldOwners.managedBy`, `KubeApply.swift:544-565`, used by `KubeManifestSession.swift:355`). `KubeGitOpsDelete` (`KubeGitOpsDelete.swift:115`) reads marks only when the object deleted is itself an Application, ApplicationSet, Kustomization or HelmRelease (its `Tool`), so it never sees a member Deployment. The delete, restart and scale sheets of a plain workload (`KubernetesPageModel+Writes`) name no owner, because a list row carries no marks.

In marks mode:

- `KubeApply`'s warning, when the live object carries a tracking id, adds: "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster" — as built (D4), in place of "your change will be reverted", which selfHeal unknown can't back, in the mode's words;
- delete, restart and scale add the same sentence only when started from a derived app's detail (D4), which knows the object is a member — as built, pause, resume, suspend and unsuspend too, the same kind of change, and only on one of the app's own objects (`Node.mayBeUndone`: a member, or an `ignore-healthcheck` one): a pod, a ReplicaSet or a CronJob's Job opened from the tree is its controller's (or nobody's) to set back, and Argo CD keeps no sync status of a hook or of a copied mark, so their writes say nothing of Argo CD. From a plain list they stay as today, because adding marks to every list's rows to say it is out of scope.

No new guard is added. The class and typed-name rules are `KubeWriteCheck`'s as today.

**Reads for the detail, only while it shows:**

- a GET of each member, capped at 4 MB each, 4 in flight and 50 members. Above 50, the rest show from their rows and that is said. As built (D4): each member whose rule reads its object — a workload, a CronJob, an HPA —; a Service's, an Ingress's and a claim's cells say exactly what their rule reads.
- the pods of each workload, as one list per workload by its selector, in its namespace, with rows only and up to 200. As built (D4): Table rows with their metadata (a Table or nothing, never whole objects), by the workload's own `spec.selector` (`KubeMarkedWorkloadWire` keeps it, bounded) — a Deployment's or a Rollout's ReplicaSets too, a CronJob's namespace's Jobs kept by owner.
- the events already read for a selected object, as today.

#### 14.2.4 Grouping and filters

- **`G`** groups as today: by tool, source, owner or destination. A derived app's tool is "Argo CD (from marks)". Its source groups by image repository, its destination by namespace, and owner is always "none". A new group, **installation**, is offered only when more than one installation is seen.
- **`is:marks`** keeps derived apps; `-is:marks` drops them.
- **`tool:argo`** includes derived apps.
- **`kind:app`** doesn't, so a person can tell real Applications from derived ones. `kind:marks` works too.
- `repo:` matches nothing for a derived app, and its hover says so. `image:<text>` is new and matches any member's image; it is useful on a spoke.

#### 14.2.5 The checkout rail

The rail's GitOps part (§4) keeps its structure. In marks mode its `why` cases gain health and a source of truth.

**The match options,** ranked by precision:

| # | Option | How | Precision | Cost | Taken |
|---|---|---|---|---|---|
| A | The binding's own workloads (case b, today) | The bound namespace's workloads, with owners, name derived apps | As exact as the binding: the person chose the namespace and selector | No extra read: the panel already follows them | **Yes**, always |
| B | Manifest identity | `git ls-files` for `*.yaml`/`*.yml` through `KubeGitOpsCheckouts`' isolated git, at most 2,000 files, each at most 256 KB and **32 MB in all**. Each file is opened `O_NOFOLLOW` and must resolve inside the checkout, so a committed symlink can't make it read elsewhere. It is read off the main thread (`KubeBlocking.run`), through `YAMLReader.documents` (`Sources/Overterm/API/YAMLReader.swift:19`; it resolves anchors and aliases, so only the four keys below are looked up and no value is walked further), keeping only `apiVersion`, `kind`, `metadata.name` and `metadata.namespace` of each document. Paths under `test/`, `tests/`, `testdata/`, `examples/`, `fixtures/` and `vendor/`, and documents with `{{`, are skipped and counted. The resulting `(group, Kind, ns, name)` tuples are compared with the tail of members' tracking ids. | **Exact only when the document names its namespace** and all four parts match. A document with no `metadata.namespace` gets its namespace from kustomize or Argo CD's destination, which can't be read here. Such a document matches only inside the binding's namespace, else it counts as "probably" with C and D. Without that rule, `Deployment/api` with no namespace would match every app's `api` across 894 apps. It misses templated Helm names and kustomize `namePrefix`/`nameSuffix`, which are said ("this checkout's Helm templates aren't rendered"). | A list across the cluster of three kinds' metadata rows, or the section's M1 rows when its store is fresh (no read at all). Off production it runs on show; on production only on Find What Deploys This (decision 11). Cached 5 min in `KubeGitOpsMatchCache`. | **Yes**, as "describes N of its objects" (`.describes`), **never `owns`**. An identity match isn't provenance: a fork, an old copy, a rendered dump under `docs/`, or the app repo's own `k8s/` beside a separate config repo all describe the same `(group, Kind, ns, name)` without being what Argo CD reads. Today's `.owns` comes from an Application's `repoURL` matching a remote, which is provenance; nothing on a spoke gives that. The line says the fraction: "describes 4 of `payments/checkout-api`'s 6 objects". |
| C | App name ↔ checkout name | The instance name equals the remote's repository name, or a directory segment under `apps/`, `deploy/`, `k8s/`, `charts/`, `manifests/` | Medium: with ~894 apps, short names (`api`, `worker`) collide **[survey: names shorter than 5 characters, names shared across namespaces]**. After D7 (§14.9.4): 8 apps in each cluster have a stem shorter than 5 characters; 81 apps share 27 stems in production and 76 share 27 in development, and every stem the apps with a Deployment share is shared across namespaces only | No extra read beyond B's rows | **Probably** only, when A and B found nothing, with the matched words said, never `owns`; the bound namespace's apps said alone and those elsewhere counted (as built after §14.9.4's run) |
| D | Image repository ↔ remote | A member's image path `…/<org>/<repo>` or last segment equals the remote's `org/repo` or `repo` | Medium–low: monorepos and shared base images break it | No extra read (cells) | **Probably** only, as C, with the image said |
| E | Helm chart name or `helm.sh/chart` | The checkout's `Chart.yaml` name against members' `helm.sh/chart` label | Low: a company-wide base chart would match hundreds of apps | — | **No** |

- Only A can answer `owns`: the person bound the namespace and selector, and the workloads' own marks name the app. B answers `.describes`, said above C and D but not as `owns`. A and B are "found"; C and D are not.
- C and D are a separate, muted part: "May deploy this checkout (by name): `courier/eta` — app name equals the repository's".
- When C or D match more than 3 apps, the part says "N apps by name: too many to tell" and lists none. As built after §14.9.4's run, the bound namespace comes first: the apps in it are said alone (past 3, too many to tell), and those elsewhere are only counted, on a line of their own — "2 more by name or image in other namespaces: team-1, team-2", five namespaces named at most —, never listed and never too many to tell. With none in the bound namespace, all are said as before.
- **Nothing found is never "doesn't deploy this".** When A to D find nothing, the rail says what was compared: "No marked app matched: 412 manifests compared, 37 Helm templates not rendered, 3 namespaces not readable". It doesn't say "not deployed". When B's list was cut or refused, it says that, as the rail already does for a cut list (gitops.md §13, review item 15: "searched 500 of 1,240").
- **A plain app name in coexistence.** `KubeGitOpsMatch.key(of:)` (`KubeGitOpsMatch.swift:142-145`) reads a plain-name owner in `argocd`. A 404 there is `.absent` today (`KubernetesPanelModel+GitOps.swift:571`), so it says "not in <ctx>" even when the controller's namespace is another one. D5 makes such a 404 `.absent` only when `argocd` is where this context's Applications were seen (`KubeGitOpsMatchCache`'s namespaces, or the section's store). Otherwise it is `.unreadable`, said as "its Application wasn't found in argocd; Argo CD's namespace here is unknown". On a spoke (not served) the kind isn't served, so `.absent` stays right.

**Shown per match:**

- the derived app's state and sentence;
- "Argo CD runs in another cluster";
- the image line, with its deployed-commit answer, as today;
- **Open** (the derived detail) and **Ask Why**.

There are no GitOps verbs. The `.notInCluster` sentence becomes this richer line. The `.unserved` state gets its own text: "Argo CD isn't in <ctx>; read from the marks on <ns>'s workloads". That text is said only when `applications.argoproj.io` is absent and `argoproj.io` isn't among discovery's failed groups. When it failed discovery, `readOwners` already makes the owner `.unreadable` (`KubernetesPanelModel+GitOps.swift:537-541`), and the part says "Couldn't tell whether Argo CD runs in <ctx>: argoproj.io didn't answer discovery", with the app's marks and health still shown.

**Health in the rail** is computed from the rail's own rows. Those are the bound namespace's Deployments, StatefulSets and DaemonSets **matching the binding's label selector** (`KubernetesPanelModel.swift:338`), so they may be only part of the app.

- The line says so: "health of the 2 objects bound here", never the app's health, unless the section's store for this context is fresh. In that case the store's verdict for the app is shown, with its age.
- Members in other namespaces are counted only when the section's store or B's rows saw them ("and 2 objects in `search-jobs`, not read here"). Otherwise the line says "other namespaces not read". The rail never lists across the cluster unpressed on production.
- The rail's Deployment rows are cells only, so a single-replica rollout stuck behind its old pod reads `1/1` there too. So **every bound workload gets one GET when the part first shows** (decoded by `KubeMarkedWorkloadWire`, settled by Argo CD's rule), then again only when its row's `metadata.generation` changes or it isn't Healthy, at most every `refetchEvery` (15 s). This shares the rail's budget of 8 GETs a read (`ownerReads`), which a spoke doesn't spend on owners: no GET is made for an owner whose kind isn't served. A binding with more than 8 workloads settles the first 8 by Argo CD's rule and says the rest "from its row".

#### 14.2.6 Ask Why and `k8s_gitops`

**Ask Why** on a derived app (`a` in the section, the detail's button, the rail's) is offered on every derived app that isn't Ready, Progressing included. `KubeGitOpsState.isProblem` (failed, blocked, stuck) isn't the test here: under Argo CD's rules a crash-looping Deployment after a finished rollout, or a `0/3` StatefulSet, is Progressing, never Failed. In the section, `a` on a derived row is handled in `gitOpsPress` before it falls through to the page, whose `askWhyRef` goes by `gitOpsSelectedRef` and is nil for a derived row. It builds `KubeAgentBrief.markedApp`:

- the app's name;
- that Argo CD runs elsewhere, and what can't be known;
- each member's state and Argo CD rule;
- the not-ready workloads' conditions (type, status, reason, message cut to 300 characters);
- their pods' waiting reasons;
- the events already read;
- the images.

Every word goes through `Secrets`, as `KubeAgentBriefing` does today. A single failing Deployment hands off to the existing Deployment Ask Why, with the app named in the brief.

**`k8s_gitops`** (`KubeMCP+GitOps.swift`):

- **Without `checkout`, when Argo CD isn't served or can't be read,** the answer starts with the line for `KubeMarkedAppsMode`'s reason, the same as the section's header: for `.notServed`, "Argo CD runs in another cluster (not in the kubeconfig); apps read from the marks on their objects; no sync status, repository or revision." For `.undiscovered`, "Couldn't tell whether Argo CD runs in <ctx> (argoproj.io didn't answer discovery); …". For `.forbidden`, "Argo CD's Applications can't be read in <ctx> (forbidden); …". Only `.notServed` says "another cluster". Then one line per derived app, problems first:
  `marks  Failed  payments/checkout-api  ns=payments  2 Deploy 1 Svc  rollout stalled (ProgressDeadlineExceeded): Deployment checkout-api  image=…/checkout-api:4.12.0`
  - At most 100 lines; the rest are counted by state.
  - **The section's store first.** When this context's derived apps are in the page's store and under 5 minutes old, they are used as they are, with their age, and nothing is read.
  - Otherwise, the agent's bounds: rows of three kinds, at most 2,000 objects or 16 MB a kind, cut and said. At 15 KB rows, 980 Deployments is ~15 MB, close to the cut, which the D7 leg records. Then at most 20 GETs of not-ready rows, within `KubeGitOpsBudget`. Every other state is said "from its row" (no background settle for an agent; the page's settled states are used when its store is fresh).
  - A cut or refused read never makes the answer "no marked apps". It says what was read.
  - Ready apps are only counted unless `kind: "marks"` with `state: "all"` is asked.
- **`kind: "marks"`** is a new filter value; `kind: "application"` doesn't include derived apps.
- **With `checkout: true`,** the matches gain the state and sentence. B is said as "describes N of its objects", never "deploys this checkout"; C and D as "probably (by name)", the bound namespace's first and those elsewhere counted (§14.2.5). B's list across a production cluster comes only from the cache of a person's press, as P3/P4 do today.

No new tool, and no write. `KubeAgentWrites` is unchanged.

### 14.3 When marks mode turns on, precisely

`KubeMarkedAppsMode` (pure) takes discovery (its kinds and `failedGroups`), what R1's Applications row follow said (listed across the cluster, listed only in fallback namespaces and which, refused everywhere, not yet listed, not served), and whether marks were seen. R2's summaries and their cut are not an input. It returns one of:

- `.off`: R1 listed Applications, and no mark names an app outside them. This is today's section. Also `.off` while R1's first list hasn't come, and with no discovery (a sign-in still waiting: nothing is said).
- `.beside(Coexistence)` (D1's name for the earlier `.missingFromApplications`): R1 listed Applications, and some marks name apps outside them. `Coexistence` holds the `missing` ones (said "its Application isn't in this cluster", only from a whole read), the `maybe` ones (an Application of the same name lives elsewhere: listed, never said missing), `otherInstallation` (listed, can't tell) and `unknown` (counted, not listed: their Application's namespace wasn't read). The chip from §14.2.1.
- `.only(reason)`: `reason` is `.notServed`, `.noApplications` (served, R1's whole list across the cluster has none — §14.12's development cluster, said "Argo CD's Applications for these aren't in this cluster.", never "isn't installed"; whatever the marks found so far — while they are read, refused, or read whole with none —, amended in D3's fix pass: D1 kept `.off` until a mark was found, so the dev cluster said "No GitOps object lives in or deploys into the cluster" for seconds and a refused read never), `.undiscovered` (argoproj.io failed discovery) or `.forbidden`. Derived apps are the whole Argo CD side of the section. Only `.notServed` says "Argo CD runs in another cluster".

Rules:

- Presence comes from R1's rows, which are never cut (rows only, paged at 500). R2's 500-object cut leaves some Applications unsummarised, not unseen, so it doesn't turn marks off. Unserved Flux has no bearing on it.
- **"Not in this cluster" needs a whole read.** A derived app is said "its Application isn't in this cluster" only when R1 listed Applications across the cluster and its name can't be any Application listed (below). When Applications were read namespace by namespace after a 403 (`fallbackNamespaces`, `KubeGitOpsSession.swift:353-366`), only an `<appNamespace>_<name>` mark whose namespace was read whole can be said missing. A plain name can't, because Argo CD's own namespace is unknown. The rest are counted as unknown (§14.2.1).
- **Matching an Application to marks** uses the instance name only. An Application object carries no installation id, and the local Argo CD's `installationID` is in `argocd-cm`, which is never read (gitops.md §5.2). So a mark's installation id can't be matched to a local Application: a derived app with an installation id is never said missing in coexistence. It is listed with "installation `<id>`: can't tell whether it is this cluster's Argo CD".
  - An Application's instance name is `name` when it lives in the namespace the controller's Applications mostly live in, read as the most common namespace among Applications (normally `argocd`), and `namespace_name` otherwise.
  - If that guess is wrong for an app, the app could show twice: once real and once derived. So a derived app whose name equals an Application's `name` in any namespace is not said as missing, only listed with "may be <ns>/<name>". This is false negatives over false alarms.
- **Installation id between marks:** Argo CD ignores a tracking id whose installation id doesn't match its own, so marks with different ids belong to different installations and are never merged.
- **Apps grouped by `app.kubernetes.io/instance` alone** (D-5, no Argo CD mark in the scope) are never said missing beside Applications, nor listed there: on a hub still on label tracking, one with no Application here is likelier an operator's, a chart's or kustomize's than an Application gone (D3's fix pass). Wherever they show, every sentence says "probably" and nothing of where Argo CD runs.

### 14.4 Reads and budget

#### 14.4.1 What is read

All reads happen only while the section, a derived detail, or the rail's part is on screen. They go through the page's client and proxy slot, never a new proxy.

| Tier | What | How | Bounds |
|---|---|---|---|
| M1 | Deployments, StatefulSets, DaemonSets | Rows with metadata (`KubeListOptions(metadata: true, marks: true)`), followed. All Namespaces or one namespace: one follow a kind. Several namespaces: one follow a kind per namespace only while `3 × namespaces ≤` the watches left free. Past that, across the cluster filtered to the scope (`KubeScope.reads(for:cap:)` called with `cap: free / 3`, not the default `watchCap`). A 403 across the cluster: the context's `accessibleNamespaces`, else the scope's names, each read as a **paged list with no watch** (on show, on Refresh and every 5 min), because 3 kinds × N namespaces of watches doesn't fit. That is said: "Deployments refused across the cluster; read in a, b, c every 5 min". With no namespace to read, it says it can't list. | 3 watches on All Namespaces, one namespace, or several filtered across the cluster; 3 a namespace only while they fit in what is free (10 on a pure spoke, since Argo's 5 kinds and 3 controllers aren't followed when not served). With Flux served, 4 kinds + 1 controller + 2 spare + 3 = 10, at the cap: the marks follows take their 3 first and Flux's refused-kind fallback gets what is left, said as today. First list streamed, else paged at 500. Rows under 30 MB together. |
| M1b | The settle: the same three kinds' ready-looking rows not yet settled by Argo CD's rule | **A GET each, never a list of whole objects** (§14.12, consequence 5), decoded off the main thread by `KubeMarkedWorkloadWire`, **once every first list it orders across is in** (the workloads', the CronJobs', the HPAs' — D7's fix pass: taken at the first flush, the kinds listed first went first), **what may be a problem first** (D7: a row not Healthy by its cells, or what no cell says — a Rollout's phase, a CronJob's last run, an `<unknown>` HPA —, as an agent's read picks them; and, from D7's fix pass, a workload Argo CD changed, else made, in the last hour: a sync's single replica stuck behind its old pod reads `1/1`, a paused rollout its last counts — first only by cells, it waited behind every not-ready row, ~3.5 min on the survey's spoke, while Hide Ready hid it), then the rest, each most recently changed first (the newest `managedFields` time the row's metadata carries), **within M2's budget**: M2's moves go first, the settle takes what is left of the 60 a minute. A settled state is kept in the store with the row's `resourceVersion`, so a re-show within the store's life doesn't settle it again; a row that moves after it goes to M2. | ~1,120 workloads at ~10–20 KB, at most 60 a minute: ~20 min of the section showing to settle all, ~1.2 MB a minute at worst. The header shows "checking rollouts 400 of 1,120" until done, and every row not yet settled stays "from its row", counted on the Ready chip. Decision D-4: the owner may prefer cells only. |
| M2 | Workloads whose `metadata.generation` changed since they were last settled (a spec change: a rollout, a pause, a scale), or new while the section shows. **Never readiness alone** (amended in D2's fix pass, to agree with §14.9.3's "2,000 readiness-only row events, which cause none"): a row whose cells turn not ready with its generation unchanged is said from its cells; what was last settled not Healthy is re-read by the 60 s tick (Progressing, Unknown), a Degraded one every 5 min | A GET each, decoded by `KubeMarkedWorkloadWire` (§14.4.3) | At most 20 a flush, 4 in flight, 4 MB each, **and at most 60 a minute for the context** — at the server: each GET's place held from its take until a minute after its answer (D7), never freed while unanswered and given back if never sent (D7's fix pass: freed a minute after the take, a server slower than four in flight let the queue grow past 60 and sent it at once when it sped up) —, never two GETs of one object at once, the context's (`KubeMarkedLedger`, the app's): kept across a hide, a drop (the page hidden or closed), another context and back, and shared by every window's section; past that, rows wait their turn and say "from its row". Each object at most once every 15 s; Progressing ones re-read every 60 s at most. This is narrower than `KubeGitOpsRefetch.reason`'s "cells moved": at 980 Deployments, readiness churn alone (a pod restarting, a node drained) moves cells all day, and with `inFlight` 4 the existing rule alone allows tens of GETs a second against a production API server. A move with the generation unchanged and the cells still all equal needs no GET: a stuck or paused rollout starts with a spec change, which moves the generation. A Ready row that didn't move is fetched only once, by M1b's settle. |
| M3 | Services, Ingresses, PVCs (and `ingresses.networking.k8s.io` only when served) | One paged rows-with-metadata list a kind, **no watch**. On show and on Refresh; again after 5 min while shown. | 500 a page, cut at 5,000 objects or 16 MB a kind, said. Cells only: LoadBalancer Service External-IP, Ingress Address, PVC Status. |
| M3b | CronJobs and HorizontalPodAutoscalers | Rows with metadata, M3's way (one paged list a kind, no watch, M3's timing), then **GETs through M2's budget**, decoded by `KubeMarkedWorkloadWire`: every marked CronJob, and each HPA whose Targets cell reads `<unknown>` | ~44 CronJobs and ~890 HPAs **[survey]**; GETs for the CronJobs and the `<unknown>` HPAs only. A CronJob's health needs `status.lastSuccessfulTime`, which no cell shows. An HPA's needs its conditions: Argo CD's HPA check (`FailedGetResourceMetric` and the like) turns Degraded often, and that failure shows in the cells as an `<unknown>` target, so those are read; an HPA whose targets all read is Healthy "from its row". |
| M4 | One app's detail | GETs of its members whose rule reads the object (≤ 50), a workload's ReplicaSets and pods by its own selector (Table rows with metadata, ≤ 200 pods), a CronJob's namespace's Jobs | Only while that detail shows; no watch, no timer — read as it shows, when its members change, shown again past 30 s, on Refresh; a member the section settled in the last 15 s stands |

- **Never listed,** not even as metadata: Secrets and ConfigMaps (the section's rule since G0, `KubeGitOpsSession`'s doc: "Never a Secret, never a ConfigMap"). Also never: ReplicaSets across the cluster (they carry copied marks, which is noise), Pods across the cluster, and any custom resource.
  - A marked CR is seen only if a person's own CR list carries metadata. A derived app made only of CRs or ConfigMaps is not seen, and the header's hover says so.
- **Health of M3 kinds** comes from cells where Argo CD's rule reads a field that the cells show:
  - A LoadBalancer Service whose External-IP cell is `<pending>` (kubectl's word for no `status.loadBalancer.ingress`) or empty is Progressing. Every other Service is Healthy, as in Argo CD.
  - An Ingress with an empty Address is Progressing, else Healthy. Many ingress controllers never fill it, and Argo CD then shows Progressing forever too. The hover says "as Argo CD shows it".
  - A PVC that is Pending is Progressing; one that is Lost is Degraded; Bound is Healthy; anything else is Unknown.
  - CronJobs are settled by M3b's GET: suspended is Healthy (Argo CD's Lua), `lastSuccessfulTime < lastScheduleTime` with no active job is Degraded, scheduled but never succeeded (`lastSuccessfulTime` absent) is Healthy, as Argo CD's Lua says.
  - HPAs with an `<unknown>` target are settled by M3b's GET, by Argo CD's rule from their conditions (§14.5); the others are Healthy "from its row". An HPA whose GET hasn't come yet has no health and the app's hover says "an HPA's state wasn't read".

**What cells can't show,** and M1b's settle (or M2's GET) finds:

- a paused Deployment (Suspended in Argo CD);
- `generation > observedGeneration`;
- **a stuck rollout whose old pods still serve.** With `replicas: 1`, the default 25% surge and 0 unavailable, a new pod that crash-loops leaves Ready `1/1`, Up-to-date `1`, Available `1` (the old pod). Argo CD says Progressing (`status.replicas > updatedReplicas`), then Degraded at `ProgressDeadlineExceeded`. Cells alone would say Ready. Single-replica Deployments with a bad image are common, so this can't be left to the hover.

Until a GET reaches an object, the state is "from its row" (§14.2.2). A rollout that starts while the section shows moves the generation, so M2 follows it by Argo CD's rule at once; one that started before the show is found by the settle — what may be a problem first, then the rest, each most recently changed first. Decision D-4 is about whether the settle ships in the floor.

#### 14.4.2 The 5-minute store and hiding

- `KubeGitOpsSession.Store` (`KubeGitOpsSession.swift:147-159`; there is no type named `KubeGitOpsStore`) gains the derived apps and the settled states (M1b, M2, M3b), each with the `resourceVersion` it was read at. It keeps them per context for 5 min while the page shows, as it keeps summaries. ↩ into a detail and back settles nothing again and reads no M3 again: M1's follows end when the section is left and start again with a list. Rows-only, they are cheap.
- `drop` clears it when the page hides, the context changes, or a credential fails. Its window covered, the section is only hidden — every read ends, what was read and settled stays its 5 minutes, so a window covered and uncovered doesn't start the settle again (D7's fix pass: dropped, each return re-read the same newest ~60 and the ~1,150-object settle never got past them).
- **The minute of GETs is the context's, not the store's** (D7's fix pass): `KubeMarkedMinute` (pure) holds each GET's place from its take until a minute after its answer and when each object was last asked, and `KubeMarkedLedger` — the app's, `KubernetesModel.markedMinutes`, every window's section sharing it — keeps it across a hide, a drop, another context and back. Before, a drop or another context started a fresh 60: each return to a covered window, the page closed and opened, or prod → dev → prod within a minute was another minute's GETs at the production API server.

#### 14.4.3 What a row keeps (allow-list)

**`KubeMarkWire`** is read from a row's embedded metadata in `KubeTableReader.row` when `marks` is asked. It keeps only:

- `argocd.argoproj.io/tracking-id`, `argocd.argoproj.io/installation-id`, `argocd.argoproj.io/instance`, and `app.kubernetes.io/instance`;
- `argocd.argoproj.io/hook`, `helm.sh/hook` (read as gitops-engine's `hook.IsHook`: Argo CD's annotation present, even empty, is a hook unless its only type is `Skip`, and then Helm's isn't read; Helm's is one but `crd-install`), `argocd.argoproj.io/ignore-healthcheck`, `argocd.argoproj.io/sync-wave`, `argocd.argoproj.io/sync-options` and `argocd.argoproj.io/compare-options`;
- `link.argocd.argoproj.io/*`: at most 5, detail only, each URL's userinfo dropped and credentials scrubbed at decode;
- `metadata.generation` and `deletionTimestamp`;
- from `managedFields`, only the newest `time` of Argo CD's manager — `argocd-controller` alone, which §14.9.4's run after D7 confirmed is the client-side apply's name too (`argocd-server` writes on a person's action in Argo CD's UI or API, and `kubectl-client-side-apply` on a person's `kubectl apply` or an older Argo CD's).

`kubectl.kubernetes.io/last-applied-configuration`, every other annotation and label (beyond today's `app.kubernetes.io/…`), `resourceVersion`, every other manager's time and `managedFields`' field sets are dropped while decoding and never kept: `KubeRow` is compared whole, so a status write (kube-controller-manager's managedFields time, a new resourceVersion) changes no row's marks and gives D2's flush nothing to filter. Every kept string is capped and loses control, format (bidi, zero-width), line/paragraph separator and private-use characters.

**`KubeMarkedWorkloadWire`** is M2's and M4's `Decodable`. It keeps:

- `metadata.name`, `namespace`, `resourceVersion` and `generation`, and whether `deletionTimestamp` is set;
- `spec.paused`, `spec.replicas`, `spec.updateStrategy`/`strategy.type` and `rollingUpdate.partition`;
- `spec.selector` (D4: what a detail lists the workload's ReplicaSets and pods by), bounded as it is decoded and never cut: at most 32 `matchLabels` and 16 `matchExpressions` of 16 values, each key at most a label key's 317 bytes and each value 63, and **1 KB in all** (keys, operators and values) — a Rollout's selector is a custom resource's field no API server bounds, and the store's ~1 KB a member (§14.4.4) holds. Past any bound, or not a selector at all, it is kept only as `unusable`: no list is made of it, and the object's health is read all the same. Only `KubeMarkedAppDetail.selector` makes a query of it, after Kubernetes' label syntax;
- an Argo Rollout's `spec.workloadRef` (the Deployment it runs instead of), `status.phase` and `status.message` (scrubbed, cut to 300 characters);
- `status.observedGeneration`, `replicas`, `updatedReplicas`, `readyReplicas` and `availableReplicas`; a DaemonSet's `desiredNumberScheduled`, `updatedNumberScheduled` and `numberAvailable`; `currentRevision` and `updateRevision`;
- `status.conditions[]` (type, status, reason, `lastTransitionTime`, and message cut to 300 characters and scrubbed);
- a CronJob's `spec.suspend`, `status.lastScheduleTime`, `lastSuccessfulTime` and the count of `status.active` (a Job's active pods, likewise);
- an HPA's `status.conditions[]` only, read at `autoscaling/v2` (so the v1 conditions annotation is never needed);
- each container's `name` and `image` (a CronJob's through its job template), at most 20.

It never keeps env, args, command, volumes, annotations, labels, the template's own metadata, or `spec.template` beyond the images. `KubeMarkWireTests`' sentinel checks this list.

#### 14.4.4 Expected cost at the spoke's size

| | Estimate | Note |
|---|---|---|
| M1 rows | ~980 Deployments + ~100 StatefulSets + ~40 DaemonSets **[survey]** at ~5 KB a row with metadata (gitops.md §3.2), **~5.6 MB**; measured after D7 (§14.9.4), the objects' metadata alone, managedFields included: **~9.5 MB** of metadata in production for 1,161 Deployments, 7 StatefulSets, 18 DaemonSets and 117 Rollouts, and ~9.5 MB in development for 1,208, 17, 20 and 31 | Client-side apply puts `last-applied-configuration` (the whole manifest) in the metadata, which could make a row 10–20 KB, so **up to ~20 MB**. It stays under 30 MB, and the perf leg uses 15 KB rows (§14.9.3). Per-namespace follows are no fix: on ~70 namespaces they would take 3 watches each, far past the page's 10, and the bytes are the same. If the real check finds more than 30 MB, decision D-6 applies. It found ~9.5 MB of metadata (a row is that plus its cells): the 1,161 production Deployments' metadata is 8.88 MB, about 7.6 KB a Deployment, so the leg's rows (13.3 KB on average, cells included) are about 1.7 times that. |
| M1 events | A rollout touches 1 Deployment (one event per status change). A shared base change can roll 500 at once. | The burst budget (500 events ranked in 3 s) already covers it |
| M1b | ~1,120 GETs at ~10–20 KB **[survey]**, at most 60 a minute (shared with M2), only while shown: ~20 min to settle all | Decoded and dropped one by one. Never a list of whole objects (§14.12, consequence 5). The list shows from rows meanwhile, problems first. |
| M2 GETs | Generation moved, not ready, or unhealthy: ~10–30 apps **[survey]** × ≤ 4 MB, usually ~10–20 KB | At most 20 a flush and 60 a minute: worst case ~1.2 MB a minute at 20 KB, while shown |
| M3 | ~1,000 Services, ~300 Ingresses, ~100 PVCs **[survey]** at ~3–15 KB, **~5–20 MB** once per 5 min while shown; measured after D7 (§14.9.4), their metadata with the Jobs' and M3b's kinds': **~6.3 MB** in production, **~7 MB** in development | No watch. Cut and said at 16 MB a kind; 1,000 Services at 15 KB would reach it, so the D7 leg records it. A cut Services list loses only LoadBalancer health (every other Service is Healthy), and says so. Measured after D7: the Services' metadata is 2.37 MB for 1,271 in production and 2.53 MB for 1,337 in development, about 1.9 KB a marked one; the largest kind's metadata is 2.95 MB (production's HPAs) and 3.19 MB (development's 1,224 Jobs), far under the cut. |
| M3b | ~44 CronJobs and ~890 HPAs **[survey]** as rows, **~1–5 MB**; GETs for the CronJobs and the `<unknown>` HPAs. Measured after D7 (§14.9.4): the CronJobs' metadata 0.32 MB and the HPAs' 2.95 MB for 1,137 in production, 0.35 MB and 0.60 MB in development | No watch; the GETs within M2's budget |
| Memory kept | ~1 KB a member after the allow-list, so **~2 MB** for 2,000 members | No raw JSON kept |
| Watches | 3 of the page's 10 | Coexistence: §14.4.5 |

#### 14.4.5 Coexistence (Applications served and read)

Then the section already holds 8 watches. Derived rows are only extras for apps whose Application isn't read here, and M1 doesn't watch: it is one paged rows-with-metadata list per kind on show, on Refresh, and **every 5 min** while shown. Every 60 s would re-read ~15–20 MB a minute at the spoke's size, for rows that are the minority there. M1b settles only the derived apps' members, by GET (M2's bounds), as everywhere, and M2 and M3b read only theirs. The rows are ranked like M3's. The header says "marked apps read 2 min ago".

When they aren't the minority — more than 100 derived apps, or most of the marked apps (a few local Applications beside a hub's ~900 apps: §14.12's first consequence, "the marked app names are absent from a complete Application list") — M1 is followed as on a spoke, in the watches the section's own leave, and still only the derived apps' objects are read (`KubeGitOpsSession.followsBeside`, kept until the section is left).

#### 14.4.6 Off the main thread

The follows already decode off the main thread. Grouping (`KubeMarkedApps.group`, pure) and health (`KubeMarkedHealth`, pure) run in one detached task per 250 ms flush, over a snapshot of the changed rows, and are merged into the kept apps by key (only the apps whose members changed are re-grouped).

Ranking is batched per flush, as the section does today. The main thread only swaps the ranked array. `MainThreadStall` checks it (§14.9.3).

#### 14.4.7 Production

- The section's reads are the person's: the page is open and the section shows. That matches today's rule for the section on production, where R2 already reads whole Applications on show. The marks reads are lighter: rows, and single GETs within a budget of 60 a minute.
- The rail lists across the cluster (option B) only on Find What Deploys This (decision 11).
- `k8s_gitops` without `checkout` reads a production cluster's rows only within the agent's bounds, as today. With `checkout`, it never lists across a production cluster unpressed.

#### 14.4.8 Sign-in

The spoke's contexts use an `oidc-login` exec plugin that waits minutes for a browser when the token has expired.

- This addendum doesn't change sign-in.
- §14.10 names it as a risk: marks mode starts more reads on show, so it must not turn a sign-in wait into "cluster slow".
- The check: `KubeProxies`' oidc one-at-a-time and start timeout already apply. The section is started from `updateGitOpsReading` (`KubernetesPageModel+GitOps.swift:41-54`) with `model.discovery`, and marks mode is decided from discovery (§14.3). Discovery needs the sign-in, so with no discovery the session makes no M1, M1b, M2 or M3 request at all and the section shows the proxy's own words ("Waiting for the browser sign-in", or "Waiting for <ctx>'s sign-in in the browser to finish", `KubeProxies.swift:79-80`). There is no separate proxy-ready seam: the testable rule is "no discovery, no request", which the session test checks by calling `show` with `discovery: nil`. A sign-in that expires later stops the proxy (`KubeProxyProblem`), which `drop()`s the store as today (`KubeGitOpsSession.swift:546`), and the reads start once, not once per kind's retry, when discovery comes back — as built from D7's fix pass: before, a section shown before its context's discovery was read (another context picked with the section open) never started them where Argo CD and Flux aren't served, the kinds it reads the same none either way (`KubeGitOpsSession.show`).
- A section still waiting for sign-in never shows an empty sentence: no read has answered, so nothing is said about marks.
- §14.12's sixth consequence, as built: a first oidc request unanswered past `KubeProxies.signInPatience` (8 s) says "Sign-in needed — run `kubectl --context X get ns` once in a terminal", and so does a signed-in context with a request waiting that long and no answer since (a session that expired while the proxy was open; a stream isn't counted, as a quiet watch sends nothing for minutes). The context bar's Run types it and closes the proxy with its waiting plugin (`signInAtTerminal`); the context then waits for Try Again, whose fresh plugin finds the token kubelogin kept.

### 14.5 Health (`KubeMarkedHealth`, pure)

gitops-engine's built-in checks, ported for the kinds read:

| Kind | From rows (M1/M3), said "from its row" | From the object (M1b/M2/M3b/M4), Argo CD's rule |
|---|---|---|
| Deployment | Ready `a/b`, Up-to-date `u`, Available `v`: all equal to `b` gives "ready by its row" (not Argo CD's Healthy: see §14.4.1's stuck single-replica case); otherwise Progressing; `deletionTimestamp` gives Progressing, "pending deletion" | `paused` gives Suspended. `generation > observedGeneration` gives Progressing. `Progressing` with reason `ProgressDeadlineExceeded` gives Degraded. `updated < spec.replicas`, `status.replicas > updated` or `available < updated` give Progressing. Otherwise Healthy. |
| StatefulSet | Ready `a/b`: equal gives "ready by its row", else Progressing | Argo CD's rule: observedGeneration, `readyReplicas < replicas`, partition, OnDelete gives Healthy, `updateRevision ≠ currentRevision` |
| DaemonSet | Ready, Up-to-date and Available against Desired | Argo CD's rule, OnDelete gives Healthy |
| Service | LoadBalancer with External-IP `<pending>` or empty gives Progressing; every other Service is Healthy | — |
| Ingress | An empty Address gives Progressing, else Healthy | — |
| PVC | Bound gives Healthy, Pending Progressing, Lost Degraded, else Unknown | — |
| CronJob | — (settled by M3b's GET) | Suspended gives Healthy. Active jobs give Healthy. Scheduled but never succeeded (`lastSuccessfulTime` absent) gives Healthy, as Argo CD's Lua does. The last run not succeeded (`lastSuccessfulTime < lastScheduleTime`, none active) gives Degraded. No status gives Progressing. Else Healthy. |
| HPA | Every target read gives Healthy "from its row"; an `<unknown>` target goes to M3b's GET | Argo CD's v2 rule, from conditions: `AbleToScale` FailedGetScale/FailedUpdateScale, or `ScalingActive` FailedGet…Metric/FailedComputeMetricsReplicas/InvalidSelector, gives Degraded; else `AbleToScale` or `ScalingLimited` True gives Healthy; else Progressing |
| Pod (detail only) | — | `Err*`, `*Error`, `*BackOff` waiting reasons give Degraded. Shown, not counted. |

- **The app** is the worst member by Argo CD's order: Healthy < Suspended < Progressing < Missing < Degraded < Unknown. "Missing" never occurs here. A "ready by its row" member counts as Healthy for the order but makes the app's Ready "from rows". Its rank in the list is the worst *known* member's (§14.2.2): Unknown is the word, but a Degraded member still sorts it with Failed.
- **StatefulSets and DaemonSets have no Degraded** under Argo CD's built-in rules. A StatefulSet that never becomes ready is Progressing for as long as it lasts, here as in Argo CD; the sentence carries the duration.
- **An app with no workload member read** (its members are only Services, Ingresses, PVCs or HPAs, so its workload is a Job, a Rollout or a custom resource, which aren't read, or its workload rows were cut) isn't shown Ready from its Service alone. It is Unknown, with the why "no Deployment, StatefulSet, DaemonSet or CronJob of it was read: its workload may be a kind not read here (a Job, an Argo Rollout, a custom resource)". This departs from Argo CD on purpose, because Argo CD does see that workload. Otherwise a Rollout-based app would read "Ready: 1 Svc".
- Hooks and `ignore-healthcheck` members are skipped. Kinds with no rule (nil health in Argo CD) are counted and left out: they neither help nor hurt.
- **An app none of whose members has a health rule** is Healthy in Argo CD, because `setApplicationHealth` starts from Healthy. The pure type returns Ready, with the hover "no member here has a health check; Argo CD shows such an app Healthy". The section can't produce such an app (every kind it lists has a rule), and the "no workload member read" rule above comes first.
- **Sentences** are fixed English built from the facts: "2/4 updated", "rollout stalled (ProgressDeadlineExceeded)", "rollout paused", "load balancer not assigned", "volume claim Pending", "last run of CronJob x failed", "pending deletion".
  - A condition's message is used only in the hover and the brief, cut and scrubbed.
- **Pods aren't counted, as in Argo CD.** A Deployment whose pods crash-loop after a finished rollout is Progressing (`available < updated`), not Failed. The list reads no pods, so it can't know they fail: the hover says "not every updated replica is available: its pods may be failing, which the detail shows". Pods are read only in the detail (M4).

### 14.6 Security

**Marks are cluster-supplied strings.** `KubeTrackingID.parse`:

- caps the value at 1,024 UTF-8 bytes, else nil;
- rejects control characters and newlines;
- requires exactly 3 `:` parts and 2 `/` parts each;
- requires the app part and the name to be at most 253 characters each, the app part an Application's name (a DNS subdomain) or a DNS label, one `_` and that name — each side starting and ending with `[a-z0-9]`, so no part of `k`'s argocd line is ever an option (`--core`; D3's fix pass);
- requires the group to be a DNS name or empty, and the Kind to be `[A-Za-z0-9]` and at most 63 characters;
- requires the namespace part to be empty or a DNS label of at most 63 characters, and the name to be a DNS subdomain.

Anything else gives nil, and the object counts as "unparsed mark", tallied in the header's hover and never shown raw. Installation ids are capped at 63 characters with the same character rules.

**Further rules on what a mark may do:**

- **Never a path, URL, argument or selector.** A mark's text is never handed to git, a shell, `kubectl`, the browser or a label selector.
  - The rail's B compares tuples as strings in memory.
  - Copy Argo CD Command quotes the app name for zsh through `KubeCommands`' quoting, and copies it only.
  - A `link.argocd.argoproj.io/*` value is text (decision D-3).
- **Shown escaped.** Names go through `Text(verbatim:)`. Hovers are capped at 4 KB.
- **Agents:** `k8s_gitops`' lines and `KubeAgentBrief.markedApp` go through `Secrets`. Condition messages are cut at 300 characters and scrubbed. `last-applied-configuration` is never decoded, so it can't leak.
- **No writes are added.** Members' existing write paths keep `KubeWriteCheck`. The new sentence about selfHeal is said, not guarded.
- **Nothing reaches the hub.** No request goes anywhere but the context's own proxy. Copy Argo CD Command only copies. A `link.argocd.argoproj.io/*` value is never opened. The image's revision label still goes through `docker buildx imagetools` to the image's registry only when the person asks for it (`KubeDeployedCommit.swift:247-251`), as today. That is a registry, not Argo CD.
- **Nothing is persisted.** Derived apps, `KubeMarksSeen` and the match cache are memory only, and isolated runs touch no `AppEnvironment` state.

### 14.7 New and changed types

| Type | File | What |
|---|---|---|
| `KubeTrackingID` | `KubeTrackingID.swift` (pure) | Parse with caps; `isSelf(group:kind:namespace:name:clusterScoped:)`; `appKey` (installation, instance); `said` |
| `KubeGitOpsOwner.tracking` | `KubeGitOpsOwner.swift` | Calls `KubeTrackingID`. `parse(labels:annotations:self:)` takes the object's identity when the caller knows it, and drops a copied mark. Callers: the row reader (identity from its `kind:` argument and the row, never the embedded `PartialObjectMetadata`), `KubeApply`, the delete warning, `KubeGitOpsWire`'s parent owner (an app-of-apps child Application names itself, so it passes). `KubeFieldOwners.managedBy`'s presence check (`KubeApply.swift:551`) stays as it is: a copied mark still warns "Argo CD", which errs toward caution. |
| `KubeMarkWire`, `KubeMarkedWorkloadWire` | `KubeMarkWire.swift` (pure) | The allow-lists (§14.4.3) |
| `KubeListOptions.marks`, `KubeRow.marks` | `KubeClient.swift`, `KubeTable.swift` | Only when asked: the section's M1/M3 and the rail |
| `KubeMarkedApp`, `KubeMarkedApps` | `KubeMarkedApps.swift` (pure) | Key, members, namespaces, counts by kind, images, last change; `group(_:)`; `merge(changed:into:)` |
| `KubeMarkedHealth` | `KubeMarkedHealth.swift` (pure) | §14.5 from rows and from wires; the app's verdict and up to 3 causes; sentences |
| `KubeMarkedAppsMode` | `KubeMarkedApps.swift` (pure) | §14.3 |
| `KubeMarksSeen` | `KubernetesModel` | Per context, in memory, set from the reader's `marksSeen` flag on the Overview's workload follows and on workload lists with metadata (§14.2.1) |
| `KubeMarkedSettle` (pure) | `KubeMarkedSettle.swift` | Which rows get a GET next: M2's moves first, then M3b's, then the settle, most recently changed first; the 60-a-minute budget, 20 a flush, 4 in flight, once every 15 s an object |
| `KubeMarkedAppsSession` | `KubeMarkedAppsSession.swift` | M1–M3b (M1b, M2 and M3b's GETs through `KubeMarkedSettle`), the flush, the store; owned by `KubeGitOpsSession` and started by it in marks mode |
| `KubeGitOpsObject.Role.markedApp`, `KubeGitOpsRow.marked` | existing files | A row with no `resource`, so `gitOpsRef` is nil and only Open and Copy Names remain |
| `KubeGitOpsSection` | existing | Header lines, the chip, the empty sentences, `is:marks`, `kind:marks`, `image:`, `G` installation |
| `KubeMarkedAppDetail` (pure) + `KubeMarkedAppDetailView` | new | §14.2.3: the tree, the Application's fixed rows, hints, images, the selfHeal sentence (`undone`) |
| `KubeMarkedDetailSession` | `KubeMarkedDetailSession.swift` | M4: the members' GETs, the children's lists; each read told back to the section |
| `openGitOps`, `gitOpsPress`, `gitOpsVerbs` | `KubernetesPageModel+GitOps.swift` (:173, :191-235, :243-276) | A derived row opens the detail (today `openGitOps` refuses a row whose `resource` isn't in the catalog). In `gitOpsPress`, a derived row's `a` (Ask Why) and `x` (its tree: the detail's) are handled before the fall-through to the page; `r`, `p`, ⌫, `s` and ⇧K stay refused because `gitOpsSelectedRef` is nil (a derived row's `resource` is empty, so `gitOpsRef` can't resolve it to a kind). `gitOpsVerbs` today returns only Open and Copy Names when the ref is nil (`:262`), so Copy Argo CD Command and Ask Why are added there for a derived row. |
| `cliLine` | `KubeGitOpsSection.swift:371-379` | For a derived row, `argocd app get <name> [--app-namespace <ns>]` without `--core` or `--kube-context` (D-2); `--app-namespace` only for an `ns_name` mark. |
| `KubeGitOpsMatch` | existing (pure); `KubeGitOpsMatch+Marks.swift` | option A as `owns`, option B as the new `.describes(n, of:)` (never `owns`), C and D as `.probably` — the bound namespace's said alone, those elsewhere counted (`MarkedListing.namespace`, `MarkedAnswer.elsewhere`) —, "too many to tell" (`MarkedListing`, `marked(bound:listing:)`, `MarkedAnswer`, `MarkedPlace`, `MarkedScope`, `stem`, `health(_:rollouts:)`, `RolloutsRead`) |
| `KubeCheckoutManifests` | `KubeCheckoutManifests.swift` | Option B's side: the checkout's committed YAML's four keys, bounded, `O_NOFOLLOW` |
| `KubePanelGitOps` | existing | Marks-mode health from the rail's rows, each bound workload settled by one GET on show (said as "the N objects bound here"), or the section's store when fresh; B on Find on production; the `.unserved` text only when `argoproj.io` didn't fail discovery; a plain name's 404 in `argocd` made `.unreadable` unless Applications were seen there (§14.2.5) |
| `KubeAgentBrief.markedApp`, `KubeMCP+GitOps` | `KubeAgentBrief+Marks.swift` (`KubeMarkedBriefFacts`, `KubeAgentBriefing.markedApp`, `withMarkedApp`, `markedNotAsked`), `KubeMCP+Marks.swift` (`keptMarks`, `readMarks`, `gitOpsMarks`, `gitOpsCheckoutMarks`, `KubeMCPMarksText`) | §14.2.6; D6 as built below |
| `KubeMarkedFetch` | `KubeMarkedDetailSession.swift` | A GET of each of several marked objects, 4 in flight, bounded in time, bytes each and in all: Ask Why's and an agent's |
| `FakeKubeAPI+Marks` | `FakeKubeAPI+Marks.swift` | §14.9.1 |

### 14.8 Stages

**Each stage** is one commit with the main design's routine: `swift format`, `make test` and `make e2e`, and docs in the same commit (architecture.md's GitOps paragraph, analysis.md §2.23 and §10, CLAUDE.md's Kubernetes row, and this section once merged into gitops.md as §14). A stage a person sees adds a line to the unreleased version's CHANGELOG entry. Which version that is, is the owner's call.

| Stage | Commit subject | What | Tests | Done when |
|---|---|---|---|---|
| **D0** | `kubernetes: a copied Argo CD mark names nobody` | `KubeTrackingID` (parse, caps, `isSelf`); `KubeGitOpsOwner.tracking` through it; the self check where the object is known (row reader by its `kind:` argument, apply, delete warning, `KubeGitOpsWire`) | `KubeTrackingIDTests`: forms, core group, cluster-scoped, `ns_name`, malformed and over-long, control characters, installation id. `KubeGitOpsTests`: a ReplicaSet with its Deployment's mark has no owner; the existing tracking-id cases (`KubeGitOpsTests.swift:324-383`) updated where a two-part value such as `shop:anything` parsed before and is now refused. `KubeTableTests`: a Metadata row (embedded `kind: PartialObjectMetadata`) is checked against the request's kind, not the embedded one. `KubePanelGitOpsTests`: a copied mark isn't matched; an app-of-apps child Application keeps its parent. `KubeWritesTests.swift:613` and `KubeGitOpsWireTests` keep passing (their marks name the object itself). `KubeGitOpsMatchTests.swift:224` passes `kind:` to `KubeTableReader.read`, which now requires it with `owners`. | A ReplicaSet's or operator child's copied mark is never an owner anywhere. A CHANGELOG line (a person sees the rail stop naming an owner for a copied mark). |
| **D1** | `kubernetes: apps and their health from Argo CD's marks (pure)` | `KubeMarkWire`, `KubeMarkedWorkloadWire`, `KubeMarkedApps`, `KubeMarkedHealth`, `KubeMarkedAppsMode`; `KubeListOptions.marks` and the reader keeping the allow-list, unused by any list yet | Unit tests (§14.9.2), including the sentinel: a row whose last-applied, env and other annotations carry `SENTINEL` keeps none of it | Pure types done; no UI and no behaviour change. It touches `Sources/`, so the pre-commit hook needs the unreleased version's entry to exist; no line of its own. |
| **D2** | `kubernetes: GitOps reads apps from marks where Argo CD isn't` | `KubeMarkedAppsSession` (M1, M1b, M2, M3, M3b, the flush off the main thread, store, hide, the fallback, wait for sign-in); `KubeMarkedSettle`; `KubeMarksSeen` and the reader's `marksSeen` on the Overview's workload part; `FakeKubeAPI+Marks` | `KubeMarkedAppsSessionTests` against the fake: no Argo or Flux request; 3 watches, and with 6 namespaces still ≤ 3 (filtered across the cluster); no list of whole objects (every M1b request a GET of one object), never a watch; a single-replica stuck rollout whose cells read `1/1` is Progressing after its settle GET; the settle waits behind M2's moves and stays within the shared 60 a minute; a settled row isn't fetched again on a re-show; M2 only for a moved generation (a last unhealthy state is the tick's), never for a readiness-only move with the generation unchanged, so a churn of 2,000 readiness-only row events makes no GET; M3 and M3b have no watch; 403 falls back to paged lists in `accessibleNamespaces` and is said, with no "carries no marks" sentence; `argoproj.io` failing discovery gives `.undiscovered`, not "another cluster"; hide drops; no write; no Secret or ConfigMap request; `show` with `discovery: nil` makes no request at all; a failing `metrics.k8s.io` in `failedGroups` still gives `.notServed`; HPAs and CronJobs as rows, no watch, a GET only for CronJobs and `<unknown>`-target HPAs | The session yields ranked derived apps from the fake spoke. No UI yet: `g` still refuses, so a person sees nothing new. |
| **D3** | `kubernetes: the GitOps section shows Argo CD apps from their marks` | The section row and `g`/`:gitops`/`:argo` in marks mode; header lines and hover; rows; chips; Hide Ready; empty sentences; coexistence's chip; `is:marks`, `kind:marks`, `image:`, `G` installation; ↩ on a derived row opening a placeholder detail with the absent-verbs sentence | `KubeGitOpsSectionTests` (every row of §14.2.1's table, the unknown ones above all: `.undiscovered`'s header, Applications read only in fallback namespaces, a cut or refused M1's empty sentence, "from rows only" counted on the Ready chip; R2 cut at 500 with R1 complete still deriving the missing apps; M1 partial giving "At least N apps"; an app with only a Service read giving Unknown, not Ready; a Degraded-plus-Unknown app sorting with Failed). `KubernetesPageModel` tests: on a derived row `r`, `p`, ⌫, `s` and ⇧K do nothing and send nothing (`fake.writes` empty), `k` copies the `argocd` line without `--core`, and the verbs menu has no write. E2E `kubernetesGitOpsMarks` parts 1–3 (§14.9.3). `a` on a derived row arrives with D6. | A spoke shows its apps, problems first, with the sentence. CHANGELOG line. |
| **D4** | `kubernetes: a marked app's detail — its objects, their health, what Argo CD alone knows` | `KubeMarkedAppDetail(View)`, M4, the tree with copied marks as children, hints, the absent verbs, Copy Argo CD Command, the selfHeal sentence on members' writes | `KubeMarkedAppDetailTests`; E2E part 4 | ↩ shows the tree and per-object health; no Sync or Refresh anywhere |
| **D5** | `kubernetes: the rail says which marked app deploys the checkout, and its health` | `KubeGitOpsMatch` A+B+C+D, `KubePanelGitOps`' marks mode, Find on production, the cache key gains the mode, the plain-name 404 rule. Open goes to D3's detail (D4's once it lands); it needs D2 and D3, not D4. | `KubeGitOpsMatchTests` (B said as `.describes`, never `owns`; B exact only with a namespace; a namespace-less `Deployment/api` matching 40 apps' `api` gives "probably" in the binding's namespace only; kustomize prefix missed and said; a symlinked YAML outside the checkout not read; the 32 MB bound; C and D probably; too many to tell; nothing found says what was compared, never "not deployed"); `KubePanelGitOpsTests` (production lists only pressed; health said as "the N objects bound here" when the selector covers part of the app; a plain-name 404 in `argocd` with Applications seen only in `gitops` is unreadable, not "not in"; a bound single-replica Deployment whose cells read `1/1` but whose object is stuck is Progressing after the show's GET; `argoproj.io` in `failedGroups` gives the "couldn't tell" text, not "isn't in"); E2E `kubernetesCheckoutGitOps` part 7 | The bound checkout says its app and health on a spoke |
| **D6** | `kubernetes: agents read marked apps (k8s_gitops, Ask Why)` | `k8s_gitops` marks mode, `kind: "marks"`, `KubeAgentBrief.markedApp`, `a` | `KubeMCPGitOpsTests` (lines, bounds, scrubbing sentinel, no write; the page's fresh store used with no request; a cut read never answers "no marked apps"; `kind: "application"` excludes derived apps; no request to `argoproj.io` when not served; the opening line follows the mode's reason, "another cluster" only for `.notServed`), `KubeAgentBriefTests`; `a` on a derived row in the section, Progressing included | An agent on a spoke gets apps, not "serves neither" |
| **D7** | `kubernetes: GitOps from marks at a spoke's size` | `kubernetesGitOpsMarksPerf` beside `kubernetesGitOpsPerf`, plus whatever it finds | The perf leg (§14.9.3) | The budgets hold at 1,000 Deployments and ~900 apps. PATCH; no line if tests only. |

**D1 as built** (`kubernetes: apps and their health from Argo CD's marks (pure)`): `KubeMarkWire` and `KubeMarkedWorkloadWire` (`KubeMarkWire.swift`), `KubeMarkedKind` and `KubeMarkedHealth` (`KubeMarkedHealth.swift`), `KubeMarkedMember`, `KubeMarkedApp`, `KubeMarkedApps` and `KubeMarkedAppsMode` (`KubeMarkedApps.swift`), `KubeTrackingID.instanceLabel` (an instance label checked as the app part is), and `KubeListOptions.marks` threaded through the list, the watch decoder and the streaming list (`includeObject=Metadata` when asked) — no list asks it yet, so nothing a person sees changes. §14.12's consequences that are pure are in it: `.noApplications` (consequence 1); an Argo Rollout as a member kind, its phase its health by Argo CD's bundled check, the Deployment its `workloadRef` names — or, before the Rollout's object is read, a Deployment scaled to 0 beside a Rollout — "scaled by its Rollout", Healthy and never a cause (consequence 2); a hook (`argocd.argoproj.io/hook`, else `helm.sh/hook`) kept apart as `KubeMarkedApp.hooks`, out of health (consequence 3). Choices made where the design left room: a condition's message is bounded to 4,096, scrubbed whole as a summary's is (`KubeGitOpsMessage.scrubbed`), then cut to 300 (a credential cut in half could slip past the patterns); Argo CD's manager is `argocd-controller` alone (gitops-engine's `ArgoCDSSAManager`), never `argocd-server` (a person's action in its UI) or `kubectl-client-side-apply`, until §14.9.4 confirms the client-side name — which its run after D7 did: Argo CD's client-side apply writes as `argocd-controller` too; a Rollout's row is never a verdict (its columns are counts, never its phase), only its object; an app is Unknown until a workload of its own has a health — never Ready from a Service beside a CronJob not yet read, or from the Deployment its Rollout scales; `.noApplications` only when marks were seen (a hub with no Application and no mark keeps today's section); Service, Ingress and claim verdicts are exact from their cells (the field Argo CD reads is the cell), so only workloads and HPAs say "from its row"; an app none of whose members has a rule is Ready only when no member waits to be read (a CronJob's or an `<unknown>` HPA's object), else "not read yet"; a Job (not a hook) has Argo CD's rule from its Status cell or its conditions. Consequences 4 (the rail's name match) and 6 (an expired sign-in said quickly) belong to D5 and D2.

**D2 as built** (`kubernetes: GitOps reads apps from marks where Argo CD isn't`, and its fix pass): `KubeMarkedAppsSession` (`KubeMarkedAppsSession.swift`), owned by `KubeGitOpsSession` as `marked` and started by `updateMarks` from discovery and `applicationsRead` (R1's rows: `notYetListed`, `acrossCluster`, `namespaces`, `refused` — never R2's summaries); `marksMode` published for D3, made again once a flush re-ranked the apps (`changed`), never on a row event. Followed (`Reads.follow`) when Applications aren't served, are refused (also when no namespace is left to follow them in), are listed whole with none, or are missing for more than 100 or most of the marked apps (`followsBeside`, §14.4.5) — §14.12's first consequence; listed every 5 min (`Reads.periodic`, D-1) beside read Applications otherwise. `settling` names the derived apps beside Applications: only their objects are read by GET there. M1's watches are what the section's kinds, controllers and the spare in use leave (`marksWatches`: ten on a pure spoke), a kind each in order (`allot`: Deployments, StatefulSets, DaemonSets, Rollouts); with Flux served the marks take theirs before a refused Flux kind's namespaces (`spareLeft`), the Applications' own fallback still first. A kind left without a watch, refused, failed or listed is listed again every 5 min and on Refresh (`reread`: every kind with no follow). M1 includes `rollouts.argoproj.io` where served (§14.12's second consequence: rows for membership, the phase from the object). M3 is rows with metadata — Services, Ingresses, PVCs, Jobs (a hook Job under its app, never in its health: the third), CronJobs and HPAs at `autoscaling/v2` —, none watched. **Rows only, never a list of whole objects (the fifth consequence, §14.4.1, D-4):** every object is a GET of one through `KubeMarkedRefetch` (pure) — M2 first (a moved generation or a workload new while shown, never readiness alone), then the tick's (Progressing and Unknown every 60 s, Degraded every 5 min), then the settle (M1b: each marked workload not yet settled, the newest change by Argo CD first, "checking rollouts N of M", "from its row" until then) and M3b (a marked CronJob, an HPA whose Targets read `<unknown>`; again when its row moves) — 15 s an object, 20 a flush, 4 in flight, 60 a minute kept across a hide and a show of the same context (`forgetPending`; a new budget only on `drop` or another context). `KubeMarkedSettled` stands for its row only while the generation agrees and the row hasn't turned not ready since; an HPA's only while a target still reads `<unknown>`. `KubeMarkedBook` (members made, merged, verdicts made only for dirty apps, ranked — run in `KubeBlocking` once a flush, handed over whole so the main thread keeps no copy) and `KubeMarkedReading` (the kinds listed, refused, read in fallback namespaces, cut or failed; `count` and `empty` say "At least N" and never "carries no marks" unless the read was whole, naming every kind read, Rollouts too). `KubeMarkedHealth.member` says a Deployment its Rollout scales to 0 "scaled by its Rollout" (the app Unknown, never Ready, until the Rollout's object is read). `KubeClient.pagedList` is R2's paging made generic over its reader (`pagedObjects` is it now, its words unchanged); M3 reads rows through it. `KubeRow.argoMarked` and `KubernetesModel.marksSeen` (D2's `KubeMarksSeen`): the Overview's workload follows (`KubeClusterOverviewSession.sawMarks`) and the page's Deployments, StatefulSets and DaemonSets lists set it; no request of its own. Consequence 6: `KubeProxies.Status.signInNeeded(context:)` after `signInPatience` (8 s) of a first request waiting for kubelogin, or of a signed-in context's request (not a stream) with no answer since; Run types the command and `signInAtTerminal` closes the proxy, the context waiting for Try Again (`KubeProxyProblem.signingInAtTerminal`) — §14.4.8. `FakeKubeAPI+Marks` (`addSpoke`, §14.9.1's states at 40 apps by default; rows' `metadata.generation` from their fields; Ingress's columns). Bounds are `KubeMarkedAppsSession.Bounds` (constants but for the tests). D-6's 30 MB isn't enforced here: D7 records M1's real bytes. Nothing a person sees changes but the sign-in sentences: `g` still refuses on a spoke until D3.

**D3 as built** (`kubernetes: the GitOps section shows Argo CD apps from their marks`): `KubeMarkedSection` (`KubeMarkedSection.swift`, pure) makes `KubeGitOpsSession.marked`'s ranked apps into the section's rows — `KubeGitOpsSession.derived`, made again only when the marks' flush ranked them again or the mode changed, never on a row event, laid among the rest by `publish` (`KubeGitOpsSection.rows(… derived:)`) —: a `KubeGitOpsRow` with `role` `.markedApp` ("Marks", a new `KubeGitOpsObject.Role` case no summary ever has) and `marked` (`KubeGitOpsRow.Marked`: the key, Argo CD's word — D-7's Unknown ranked with its Degraded member —, "from rows", the images, the installation, what its age is); `resource` empty, so `gitOpsRef` is nil and `r`, `p`, ⌫, `s`, ⇧K, `+`, `-` and `a` do nothing (`a` comes with D6), its menu only Open, Copy as argocd and Copy Name. Its tags are `KubeGitOpsTag.text`: the members counted by kind, "label only", "probably: app.kubernetes.io/instance", and — where the design put a tag on every row of several installations — another installation's id only on the rows that carry one (the header counts those without: "2 Argo CD installations mark objects here: unnamed (43 apps), hub-b (8 apps)"). Beside Applications read, a row's tag is short ("not in this cluster" — R1's whole list only —, "not where Applications were read", "may be ns/name", "installation hub-b") and the design's whole sentence is its hover's; the rows are among the Applications ("Applications as today, plus derived rows for the rest") and in `Rows.beside`, which the chip "N marked apps with no Application here" shows alone (`KubeGitOpsViewState.beside`, `toggleGitOpsBeside`), the unread ones counted (`besideUnread`). The header (`sectionHeader`) is "Argo CD: from marks · N apps · read …" (Flux's after it where served; beside Applications, today's with "marked apps read …"), `Lines.lead` the mode's own sentence (§14.12's two wordings: only `notServed` "another cluster", `noApplications` "aren't in this cluster"; apps grouped by `app.kubernetes.io/instance` alone, D-5, only "probably Argo CD's", never where Argo CD runs — `probableSentence`) then `countSentence` — "These N apps are read from the marks Argo CD leaves on their objects.", "At least N apps, from what could be read: …", none while reading —, `limits` the muted second line in the mode's words (forbidden: "which can't be read here"; undiscovered: "which couldn't be looked for here"), shown in marks mode and beside Applications while their chip is pressed, its hover naming the kinds actually read (Rollouts and Jobs among them, §14.12's second and third consequences) and the marks counted, not shown. `KubeMarkedReading.unread` now names a kind read only where it may be ("Deployments refused across the cluster; read in a, b every 5 min"), so the count's floor and the empty sentence say it too. Empty (`KubeMarkedSection.empty`): reading, not whole, or whole in the mode's words — `undiscovered` and `forbidden` never "isn't served" —, with Show All Namespaces off All Namespaces; with no discovery (a sign-in waiting) the proxy's own words, never an empty sentence. `is:marks`/`kind:marks` (`KubeGitOpsFilter`; `kind:app` stays Applications', `is:marks` asks no state, so Hide Ready still hides), `image:`, `repo:` never a derived app; `G` "Argo CD (from marks)", the image repository, the namespace, no owner, and `.installation` (`KubeGitOpsGroupBy.next(installations:)`, offered only while several installations mark objects here). `k`: `cliLine` → `argocd app get <name> [--app-namespace <ns>]` (D-2). ↩ and `x` open `KubeMarkedAppDetailView` in the detail's slot (`KubernetesPageModel.markedDetail`, Esc closes it, another section or context too): the placeholder — the state and why, the mode's line, each member as its app counts it (a Rollout's Deployment "scaled by its Rollout"), the hooks, the absent verbs' sentence in the mode's words (`absentVerbs`), Argo Rollouts' promote and abort "not here", Copy as argocd — reading nothing of its own. `g`, `:gitops` and `:argo` open the section everywhere; `gitOpsRefusal(tool:)` refuses only `:flux` where Flux isn't served (a Flux filter left from another context is dropped by `g`); the row shows by `gitOpsListed` (served, a mark seen, or showing). `FakeKubeAPI+Marks` gains `otherInstallation` (apps marked `installation-id: hub-b` on every member). `KubeMarkedSectionTests` (pure: §14.2.1's table row by row, the two wordings, "At least N apps", the cut, refused and fallback reads' empty sentences, "from rows only" on the Ready chip, a Service-only app Unknown, Degraded plus Unknown with Failed, a Rollout's Deployment "scaled by its Rollout", a hook out of health, R1's 1,000 listed still deriving the missing, fallback namespaces, R1 not yet listed, Flux beside, the filters, the groupings, `k`), `KubeGitOpsMarksPageTests` (on the fake spoke: `g` opens, `:flux` refused, the row once a list's rows showed a mark, no key writes or asks on `kind-fake` and on `fake-prod`, `k`, the menu, ↩ and Esc; R2 cut at 500 beside R1's 1,000 still deriving the missing) and the `kubernetesGitOpsMarks` scenario (`testKubernetesGitOpsMarks`: §14.9.3's parts 1–3 on three fakes — a spoke of 53 apps with Argo Rollouts served (a Rollout's Deployment "scaled by its Rollout", a Degraded Rollout its app's cause), a hub with Applications for 9 of its 12 marked apps, Applications refused —, each part's requests checked against the marks' kinds) check it.

**D3's fix pass**: the review found unknown said as absent and claims the marks can't back. `KubeMarkedAppsMode.of` makes Applications served with none listed `.only(.noApplications)` whatever the marks found so far (D1 kept `.off` until a mark was seen, so the dev cluster said "No GitOps object lives in or deploys into the cluster" for seconds before its 905 apps, and a refused M1 was never said); a whole read with none says the marks' empty sentence. The header's marks part (`KubeMarkedSection.header`, optional now) is there only with apps, while reading, or from a read that wasn't whole ("none found in what could be read", never "at least 0 apps"); a whole read with none gives the tools' own words back (Flux's "Flux 6 kinds · summarised …" as before D3). What wasn't read is said once — by the lead or the marks' empty sentence when drawn, else a note (`KubeMarkedSection.notes`, `Lines.saysUnread`). The muted line shows whenever apps read from marks are among the rows, beside Applications unpressed too. Apps grouped by `app.kubernetes.io/instance` alone (`KubeGitOpsRow.Marked.probable`, `KubeMarkedAppsSession.probable`) are "probably" in every word — the detail's label, lead, facts and absent verbs, the Revision hover, the limits and their hover, the row's hover — and never listed beside Applications (`KubeMarkedAppsMode.of(…probable:)`, §14.3). The Ready chip's "from rows only" counts only a workload said from its cells or a member waiting for its object (`KubeMarkedKind.cellsMayHide`), the note naming them. A state's duration is its `since` (`KubeMarkedHealth.Verdict.since`/`sinceSaid`: a condition's time, a CronJob's last run, else when its row was first read not ready — kept once a GET settles it — or last changed), the Age column's, never "for 0s" in a why. The rows are made off the main thread with the apps (`KubeMarkedBook.rows`/`shownRows`/`keys`, `KubeMarkedSection.base`, only the changed apps'), the main thread tagging them for the mode (`decorated`). R1 seeing an Application added or deleted makes the mode again once a flush, so the placeholder detail of an app whose Application comes is gone (`markedDetailApp` resolves through the section's rows). `KubeTrackingID`'s app part is a DNS subdomain, or a label `_` subdomain — never a leading `-` — and `cliLine` refuses any other. A row's images are capped and stripped where its member is made (`KubeMarkedMember.images(inCell:)`), the Source hover and the detail's images line capped at 4 KB. Tests: the mode's served-with-none and probable cases, the header's and notes' cases, the probable words, the muted line beside, the capped images, `--core`, the duration kept once settled, only a workload's row "from rows", the book making only the changed rows, the R2 cut with a marked app past it never derived, the detail gone when its Application comes; the scenario's chips are the fixture's counts and every part's reads — the hub's and the refused context's — are checked.

**D4 as built** (`kubernetes: a marked app's detail — its objects, their health, what Argo CD alone knows`): `KubeMarkedAppDetail` (`KubeMarkedAppDetail.swift`, pure) replaces D3's placeholder model (`KubeMarkedSection.detail` is gone; `cliLine(key:)` is the detail's Copy as argocd). `make` settles the ranked app's members by what the detail read (`Read.objects`, or the section's newer reads: `markedDetailShown`) and gives the header — its state by Argo CD's rules over those objects, the mode's line with the limits' hover, Copy as argocd, Copy Name, Copy Names (each object a line), and the absent verbs' sentence beside them (drawn in the header, so it never scrolls away) —, the facts (installation, its Application and where, namespaces, a cluster-scoped mark's destination), "What Argo CD knows and this cluster doesn't" (`applicationFields`, six rows each `whereTheApplicationIs` in the mode's words — Argo CD's cluster only for `notServed`; for an app only probably Argo CD's, "if Argo CD deploys it"), the tree (`Node`: member, ignored, owned, copy, hook), the hooks apart (each with its row's health and "not counted, as in Argo CD"), the hints (`sync-wave`, `sync-options`, `compare-options`, links — text, never opened, D-3; 50 at most), the images with the members running them and the commit an image's tag names (`KubeDeployedCommit.candidates`; the comparison with a checkout is the rail's), the manifests' revision "the Application's", and what wasn't read (past 50, a GET refused, a list refused or cut). Under a member, by its children's `ownerReferences` (the controller, `Owner`): a Deployment's or a Rollout's newest ReplicaSet and every other still asking for pods (an old one serving during a stuck rollout), the rest "N older ReplicaSets, scaled to 0"; each with its pods (50 drawn, "N more pods"); a StatefulSet's, DaemonSet's or Job's pods; a CronJob's 5 newest Jobs. A pod's health is gitops-engine's `getPodHealth` from its row (`KubeMarkedHealth.pod`: a waiting reason `Err*`, `*Error`, `*BackOff` Degraded — an init container's `Init:…` Progressing, as its pod is Pending —; Running ready Healthy, not ready Degraded once restarted, else Progressing; Succeeded Healthy; Failed, Evicted, OOMKilled Degraded), a ReplicaSet's from Desired and Ready (`replicaSet`); neither counted. A ReplicaSet carrying its Deployment's mark says "a copy of Deployment x's mark: not a member"; the copies the section reads (an HPA's, kept by `KubeMarkedApps.merge` as `KubeMarkedApp.copies`, by the app their mark names — copies alone make no app) hang under the member they name, else at the end. `KubeMarkedDetailSession` (`KubeMarkedDetailSession.swift`, the page's `markedRead`) is M4: `fetched` — members whose rule reads the object, ≤ 50 —, a GET each (4 in flight, 4 MB, decoded off the main thread), one the section settled in the last 15 s standing unless Read Again (the header's ↻ — this cluster's objects, never Argo CD's Refresh — or ⌘R); each read told back (`settled`) to `KubeMarkedAppsSession.settled(byDetail:)`, which keeps it as its settle's and forgets the GET it had pending (14.4.2: back from the detail, nothing is settled again); then `lists` — each workload's own `selector` (`KubeMarkedWorkloadWire.Spec.selector`: ≤ 32 labels and 16 expressions, never cut — past its bounds, or not a selector, it is `unusable` and the object's health is read all the same —, each key and value by Kubernetes' label syntax, as a Rollout's, a custom resource's, isn't checked by the API server; none for a workload with no selector or one selecting everything; a Rollout with `workloadRef` by its Deployment's), the same list once — as Table rows with metadata and `tableOnlyAccept`, 8 MB each, `children` keeping only name, cells' health, controller, creation and a copied tracking id. No watch and no timer (`showing`): read as it shows, when its members change, shown again past 30 s (`keptFor`), Read Again; `hide` on close, `drop` with the page or the context. A node's name opens its object in its own list (`openMarkedNode`, through `openFromOverview(from: .gitops)`), its right-click menu Open, Copy as kubectl, Copy Name (`markedNodeVerbs`) — no write, no Application verb anywhere in the detail. The object opened records `markedOrigin` (cleared by another object or a close; `sameObject` by kind name, any version), so its delete, restart, scale, pause, resume, suspend or unsuspend confirmation (`undoneVerbs`) adds `undone` in the mode's words through `KubeWriteConfirmation.make(note:)` — the guard, typed name and access review as they were; `[` back from it reopens the app's detail. An apply's warning (`KubeFieldOwners.warnings(argoMarks:)`): on a live object Argo CD tracks (`tracks`: its own tracking id, or its instance label alone — never a copy) where the context's section said the marks' mode (`KubeGitOpsSession.marksModeSaid` → `KubernetesModel.marksReasons`, memory only), else where discovery says Applications aren't served or argoproj.io didn't answer, `applyWarning` says "Argo CD may undo this: …" in place of "your change will be reverted". The fixture gains each Deployment's selector, its ReplicaSets labelled and owned in their rows (the fake's ReplicaSets now have kubectl's Desired, Current and Ready columns), the stalled app's new ReplicaSet with a crash-looping pod beside the old one serving, the stuck one's `ImagePullBackOff`, the StatefulSet's Pending pods, the CronJob's last Jobs, the Rollout's own ReplicaSet and pods, and hints and `ignore-healthcheck` on the stalled app. Tests: `KubeMarkedAppDetailTests` (the tree by owners, the newest and the serving ReplicaSet, pods capped and never counted, members settled by the detail, hooks and ignored and copies, a Rollout's, the fixed rows in every mode, hints and commits, the 50, the lists by selector, the children reader's sentinel, pod and ReplicaSet rules, copies in `KubeMarkedApps`, the apply's and a write's "may undo"; against the fake: only GETs, the Deployment's object and never the Service's, ReplicaSets and pods by selector as Table rows, told back, no timer while shown, 30 s, Read Again, 50 GETs 4 at a time, no discovery no request), `KubeGitOpsMarksPageTests` (↩'s tree, every menu without a write or Sync/Refresh/Rollback/Diff, the section keeping the detail's read, a node opening the Deployment whose `r` says "may undo", `[` back, the same Deployment from its own list saying nothing), `KubeApplySessionTests` (a tracked object's diff "may undo" where Applications aren't served or the section said none is here, served as before) and the scenario's part 4 (§14.9.3: the tree drawn, per-object health, a copied ReplicaSet as a child, the six rows, the hooked app's hook apart, the Rollout's verbs not here, no Sync, Refresh, Rollback, Diff or write in any menu, the node's button pressed opening the Deployment's detail, `[` back; part 2's ↩ reads checked too).

**D4's fix pass**: the review found "may undo" said of objects Argo CD doesn't track, ↩ on a node missing, and checks that couldn't fail. `openMarkedNode` records `markedOrigin` for any node (`[` comes back from it) but its `undone` only for `Node.mayBeUndone` — a member, or an `ignore-healthcheck` one —, never a pod, a ReplicaSet or a CronJob's Job (their controller's to set back, or nobody's), a hook or a copied mark (Argo CD keeps no sync status of either: `controller/state.go`). ↩ on a node: Tab takes the keyboard from the section's rows into the tree (`markedTreePress`; the page's `markedNode`, drawn picked and scrolled to), ↑ ↓ walk `KubeMarkedAppDetail.walk` (the tree depth first, then the hooks; `step` held at either end; kept while the tree is made again), ↩ opens the node (`KubeMarkedOrigin.node`: `[` comes back on it); Tab, another row picked or Esc give the rows the keyboard back. Overlapping selectors (`app=web`, `app=web,track=canary`) found an object in two lists: `KubeMarkedAppDetail.unique` keeps each once (the session's merge, and `ChildIndex`), so no node is drawn twice under one id or counted twice; hints, images and notes name each object's namespace where the app spans several (`KubeMarkedMember.ID.said(namespaced:)`), and the view draws lines by their place. The selector is 1 KB at most in all (`Selector.totalBytes`), and §14.4.3 lists it with the rest of the wire's allow-list. `settled(byDetail:)` also drops a GET the section had taken and not yet sent. ↻ is "Read again" (`kubernetes.gitops.marked.readAgain`): this cluster's objects, never Argo CD's Refresh. An apply's reason (`KubeManifestRun.marksReason`): discovery first (not served, argoproj.io not answering, unread); served, a section's word only of the same cluster and user (`KubernetesModel.marksReason(of:)`, by `sameCluster`) and only `.noApplications` or `.forbidden`; else one row of Applications asked across the cluster (`applicationsHere`: `limit=1`, a Table with no object, only counted — none, `.noApplications`, so the survey's development cluster says "may undo … isn't in this cluster" before any section was opened; 403, `.forbidden`; one or more, Argo CD's own words; no answer, `.undiscovered`, "may" all the same). Tests: `KubeGitOpsMarksPageTests` (the keyboard's walk, ↩, `[` back on the node; a pod — by ↩ —, a ReplicaSet, a copy, a CronJob's Job and a hook saying nothing of Argo CD, a member and an ignored Service saying it; the section keeping the detail's Read again — its time and generation — with its own waiting GET forgotten and no second GET), `KubeMarkedAppDetailTests` (overlapping selectors, pure and against the fake; namespaced hints, images and notes; the walk; `mayBeUndone`; the 1 KB selector), `KubeApplySessionTests` (the row asked, refused, listed; a section's word of another cluster or user, or one discovery contradicts) and the scenario's parts 2 and 4 (each detail read — opened and read again, the stalled, hooked and Rollout apps — checked against the fake's log and the detail's own `asked`: only its members' objects, its lists in its namespace, nothing beside but the section's own reads; ↩ on a node by Tab, ↓ ↑; a pod's node; no "Refresh" in the detail but why Argo CD's isn't here).

**D5 as built** (`kubernetes: the rail says which marked app deploys the checkout, and its health`): the pure half is `KubeGitOpsMatch+Marks.swift` — `markedListing` makes B, C and D once, as the cluster's marked apps were listed (`MarkedListing`: each app's members listed, the matched apps, B's `described`, the probable words, what was compared and what listing couldn't read), and `marked(bound:listing:)` sets A beside it as the bound workloads come (`MarkedAnswer`: found, probably, `tooMany` past `maxProbable` 3, `nothing`, `caveats`; after §14.9.4's run, `elsewhere` — of the probable apps, those with the listing's namespace, the binding's, are said alone where there are any, and the others counted, five namespaces named at most, `maxNamespacesNamed`); `Why` gains `.describes(n, of:)` ("this checkout's manifests describe 1 of its 2 objects read here") and `.probably(words)`; `MarkedPlace` and `MarkedScope` say where an app's Application stands and whose health is said; `marksLine` is the part's line ("read from the marks on <ns>'s workloads" where A found the app, else "on the cluster's workloads": B read across the cluster); `stem` reads an app's name as the checkout would call it (§14.12's fourth consequence); `health(_:rollouts:)` says an app's health as the rail reads it, a Deployment scaled to 0 where Argo Rollouts are served (§14.12's second consequence) as D5's fix pass says below. `KubeCheckoutManifests` reads B's side: `git ls-files -z -- *.yaml *.yml` through `KubeGitOpsCheckouts.git` (isolated in tests), then each file off the main thread — at most 2,000, 256 KB each, 32 MB in all (`Bounds`), `O_NOFOLLOW` (a link, `links`), inside the checkout once open (`F_GETPATH`; a folder linked out, `links` too), a plain file (a FIFO isn't opened blocking), a template as D5's fix pass says, the six folders skipped — and each document's four keys off the YAML grammar's tree, its top level and `metadata`'s alone: never walked deeper, so no nesting or alias costs more than the parse (an alias where one of the four is leaves the document out, where `YAMLReader` would build the whole tree). Choices made where the design left room: a manifest's name counts for C only in the namespace it names, one naming none only in the binding's — else C undid B's namespace rule (`Deployment/api` with no namespace matched 40 apps' `api` by name: "too many to tell" where the binding's app was meant); apps grouped by `app.kubernetes.io/instance` alone are never in B, C or D (D-5: never said where Argo CD runs); B lists only where something here carries a mark (a bound workload's own, `KubernetesModel.marksSeen`, the section's apps) — a checkout bound on a cluster with no Argo CD at all reads nothing more; where Applications are served with no word of the section's, B waits for P4's listing and runs only where it found none in its places, after one row of Applications asked across the cluster (`KubeManifestRun.applicationsHere`) answers none or refused — no request when P4 found any; "the section's store" is the section's ranked apps kept by its page (`KubernetesModel.keepMarkedApps`, `markedApps(of:)`, five minutes, the same cluster and user, forgotten when the page drops its reads): an app's verdict from there is said with its age and its workloads get no GET, and B takes the section's apps instead of listing when it read them whole across the cluster. `KubePanelGitOps`: the panel's workload follows keep the marks (`KubeListOptions.marks`, `Workload.member`, `Bound`); `isDerived` — a bound workload whose own Argo CD mark names an app whose Application isn't read present here, once its owner's read is known; `settle` — one GET each as the part first shows, within `ownerReads` less what P2 spent (`OwnersRead.spent`), none for an app the section ranked; `rowsMoved` — the panel tells each flush's workload events, and one settled before is read again when its generation moved or it wasn't Healthy, 15 s apart; `settledMember` — a GET's state stands while the generation agrees and the row hasn't turned not ready since; `listMarks` — B, cached with the listing (`KubeGitOpsMatchCache.marked`), the cache's `Key.mode` from discovery (`mode(of:)`, each tool apart since the fix pass); the Argo CD owner lines a derived app replaces are dropped from `found` (Flux's "not in" stays), and their problem lines where the app's place says the same (refused, not answering, not found in `argocd`). `readOwners` leaves a plain certain name's 404 to `resolved` (`OwnersRead.unplaced`), which `k8s_gitops checkout` calls too. `KubeGitOpsPanelHost.gitOpsOpenMarked` opens the page on the binding's context, its GitOps section and the app's detail, the app's namespaces added to the scope (the section reads only its scope). A row (`KubePanelGitOpsView.markedRow`) is the app's name whole — two lines in the narrow rail, never cut in the middle (the part's line says it is Argo CD's) —, its state and why, whose health, where its Application stands, why it matched, Open; the "probably" ones apart and muted under "May deploy this checkout (by name)". Ask Why on a derived rail row comes with D6 (`KubeAgentBrief.markedApp`). Tests: `KubeGitOpsMatchTests` (B described never owns, exact only with its namespace and group, a namespaceless `Deployment/api` beside 40 apps' `api` probably in the binding's namespace only, the stem and image parts, C by the repository, a folder and a manifest's name in its namespace, D by an image, A found hiding C and D, A beside B, too many, nothing found's words, whose health and where, the scaled-to-0 Deployment beside Rollouts; the reader's four keys over several documents, a List and an alias left out, a kustomization's prefix, a Helm template, a test folder, YAML the grammar can't read, a link and a folder linked out, the sentinel, and the 256 KB and 32 MB bounds with real files) and `KubePanelGitOpsTests` (a stuck single replica Progressing after its one GET; "the 1 object bound here" with its others counted by B's rows; production's B only once pressed, its label, then `describes`, never `owns`, no `ls-files` before; a plain name's 404 in `argocd` with Applications seen only in `gitops` unreadable, then — seen in `argocd` — absent; `argoproj.io` not answering, "couldn't tell"; the section's fresh verdict taken with no GET and no list; the cache's key by what discovery said, option B's listing kept and dropped with it; a failed listing of the marks said once among the searched lines and gone when one reads, `searched`; the earlier tracking-id, unserved and copied-mark cases said as apps). The design's E2E "`kubernetesCheckoutGitOps` part 7" needs the spoke, which only `kubernetesGitOpsMarks` serves: it is `kubernetesCheckoutGitOpsMarks`, in the checkout scenario's file, run as that scenario's part 5 (team-3's paused Deployment Paused by its GET with "another cluster" and Open showing its detail; then fake-dev classed production by `kubernetes.contexts`, a config repository's committed manifest matched by B only once pressed; each part's reads checked).

**D5's fix pass**: the review found a Degraded sibling hidden behind a scaled-to-0 Deployment, every Rollout-run app on a cluster serving Argo Rollouts (115 on the surveyed production spoke) read as Unknown, a stale "none here" said as "not in", and bounds and checks short of the design's. `KubeGitOpsMatch.health(_:rollouts:)` replaces `boundHealth`: it never overrides `KubeMarkedHealth.app` — where Rollouts are served and weren't read whole (`RolloutsRead.unread`, said), a Deployment scaled to 0 with no Rollout of its app read is an Unknown member, ranked with the rest (a Degraded sibling still ranks the app with Failed and is named first, D-7). The rail reads the binding namespace's Rollouts as rows with their marks (one paged list, 500 or 8 MB, no watch; a Rollout runs a Deployment of its own namespace only) once a bound Deployment of an app read from marks is scaled to 0, adds the app's Rollout to its bound app (`MarkedScope.bound`'s `rollouts`: "health of the 1 object bound here with its app's Argo Rollout") and spends the settle's GET on the Rollout's phase instead of the Deployment, whose answer can't change; the settle (now in `compute`, `settle(_:)`) asks the bound apps' Rollouts first, then the bound workloads, then the Rollouts of the apps B, C or D found, and a Rollout past the 8 or whose GET failed says so (`settleSkipped`, `settleFailed`) — never "not read yet" for good. B's rows are one bound for every kind together, 5,000 objects and 30 MB (the M1 bound), Rollouts first, each kind read with what the ones before left (`RowsRead.read` carries its bytes); its listing says whether it was `whole` and what it read of Rollouts, and an app B didn't list (cut, refused before it, listed before it came) says "other namespaces not read", one it listed from a listing not whole "other namespaces not all read" (`elsewhere`). A section's word is time-bounded (`KubernetesModel.marksReason(of:now:)`, five minutes, as its apps are kept) and, where Applications are served, never stands once the rail's own reads hold an Application (P4's listing, P2's owners: `updateMarksReason`, `applicationsHeld`): B then waits for P4's listing and runs only where it holds none, and a plain name's 404 in `argocd` is "not in" only from a whole read (`k8s_gitops checkout` too). `mode(of:)` says each tool apart (`argo=served|unserved|undiscovered;flux=…`), so a listing made while argoproj.io didn't answer isn't reused once it does, Flux served or not; `k8s_gitops` says "serves neither" only where both answered (`KubeMCP.unservedNote`). `KubeCheckoutManifests` parses first: a file holding `{{` is a template only when the grammar can't read it; one it reads leaves out only a document whose four keys hold `{{` (a PrometheusRule's quoted `{{ $labels.pod }}` beside a Deployment leaves both compared). The "nothing matched" hover is capped like every other; Open on a context the page's list hasn't reads the kubeconfig once more, else says so and leaves the page's scope alone. Tests: `KubeGitOpsMatchTests` (the scaled-to-0 member beside a Degraded sibling, a Rollout's app, the scope's Rollouts and floor, the `{{` rule), `KubePanelGitOpsTests` (a settled row read again only for a moved generation or an unhealthy state, by the rail's clock; ten bound workloads, eight GETs; a bound Rollout-run app; a cut listing; a section's "none here" beside Applications the rail listed; the cache key with Flux served; the sentinel kept out of the settle's and B's reads), `KubeApplySessionTests` (a stale word), `KubeMCPGitOpsTests` (the unserved note) and `kubernetesCheckoutGitOpsMarks` (team-1's Rollout-run app Failed by its Rollout, its reads; the sentinel in nothing the rail keeps or draws).

**D6 as built** (`kubernetes: agents read marked apps (k8s_gitops, Ask Why)`): `k8s_gitops` (`KubeMCP+Marks.swift`; `KubeMCP+GitOps.swift` restructured around it) reads Argo CD's apps from marks where no Application here deploys them — `KubeMarkedAppsMode.of` over discovery and what the call's own read of Applications said (`GitOpsKindRead.presence`: whole across the cluster, some namespaces, refused everywhere; `.notYetListed` when cut or failed, so a cut never derives) — for `kind: all` only in `.only` (not served, argoproj.io not answering, refused everywhere, served with none listed: §14.12's first consequence), with `kind: "marks"` beside Applications too (coexistence's listed apps, tagged as the section tags them — "not in this cluster" only from a whole read —, the unread counted; a cut read of Applications "can't be told"). `kind: "application"` never lists one (where its Applications aren't here it says `kind marks` lists them); `state: "all"` lists the Ready ones, only with `kind: "marks"`; `failing_only` keeps Failed. **The section's store first** (`keptMarks`): `KubernetesModel.MarkedAppsKept` now holds the mode, the reading, the tally and `probable` (`keepMarkedApps` keeps them as `$reading` and `marksMode` change too, `markedKeepWatch`); used as it is — same cluster and user, under five minutes, its reads done, its mode deriving, its scope covering the call's, the apps in the call's scope — with its age, nothing read. **Else the agent's own read** (`readMarks`): `KubeMarkedAppsSession.kinds`' workloads (Rollouts where served: §14.12's second consequence) as rows with their marks, `readRows` at `marksRows` (2,000 objects or 16 MB a kind), refused across the cluster read in `accessibleNamespaces` else the scope's (`KubeMarkedReading.rereads` off: no "every 5 min"); then a GET of at most 20 that may be problems — not ready by their rows, a Rollout's unread phase —, the most recently changed by Argo CD first, 4 in flight, 4 MB each, 16 MB in all (`KubeMarkedFetch`, beside the detail session's readers, which it shares with Ask Why); what wasn't settled said ("12 workloads not ready by their rows not settled… (an agent reads 20 objects at most)", "N Argo Rollouts' phases not read: their apps say Unknown"); Services, Ingresses, claims, CronJobs, Jobs and HPAs not read for an agent, said in the answer — the section's store has them. The answer (`KubeMCPMarksText`, pure): the mode's line first (`.notServed` "Argo CD runs in another cluster (not in the kubeconfig); apps read from the marks on their objects; no sync status, repository or revision."; `.noApplications` "Argo CD's Applications for these aren't in this cluster (none is listed here); …"; `.undiscovered`, `.forbidden` theirs; apps by `app.kubernetes.io/instance` alone only "probably"), what health is and how the section's states map onto Argo CD's words, where they were read, the count (`At least N apps … from what could be read (…)` unless whole), one line an app — `marks  Failed  <app>  ns=<ns>  2 Deploy 1 Svc  <sentence>: <object>; …  for 10m  image=…/x:1.2  (tags)` —, at most 100, the rest counted by state, the Ready counted, the notes (cuts, refusals, the settle, copies and garbled marks counted), installations; no app: the mode's empty sentence (`KubeMarkedSection.empty`: "carries no marks" only from a whole read, never "no marked apps"), Flux's word where neither tool is served. Numbers are plain (`counted`: never the person's locale's `2.000`). **`checkout: true`** (`gitOpsCheckoutMarks`): P1's rows carry the marks; A — the bound workloads whose own mark names an app whose Application isn't read present here, each settled by one GET within what P2 left of the 8, the bound apps' Rollouts first (the binding namespace's Rollouts listed once where a bound Deployment is scaled to 0) —; B as the rail compared it in the last five minutes (`KubeGitOpsMatchCache.marked`), else off production `KubePanelGitOps.markedListing` at the agent's bound, on production only from a person's press (said); C and D "probably"; each match its line, `matched:` (B "describes N of its objects", never "deploys this checkout"), whose health and where its Application stands; the owners' "not in" lines and their problems it replaces dropped, as the rail does. **Ask Why** (`KubeAgentBrief+Marks.swift`): offered on every derived app that isn't Ready, Progressing included (`KubeAgentBriefing.markedNotAsked`) — `a` and ⌘L in the section (the page's `askWhy()` takes a derived row picked, or the detail's app with none), the row's menu (`askWhyMarkedVerb`, greyed with why), the detail's Ask Why button, the rail's (`KubePanelGitOps.Match.asksWhy`, through `KubeGitOpsPanelHost.gitOpsAskWhyMarked` with the rail's own words: its place, where the Application is — `MarkedPlace.whereApplication` —, whose health). `KubeAgentBriefing.markedApp` reads: one failing Deployment (the app's only cause) hands off to the Deployment's own brief, the app named in what is always sent and a chip of its objects (`withMarkedApp`); else a GET of its causes and its other objects whose rule reads the object and that aren't Healthy (6 at most; one the section or the detail read in the last 15 s stands), its health made again from them (unless the asker's verdict wasn't Argo CD's rules' alone; Ready now: not asked), the not-ready workloads' pods by their own selector as Table rows (3 lists, 50 rows), the causes' events. `KubeAgentBrief.markedApp` (pure, `KubeMarkedBriefFacts`): the question in Argo CD's word ("Why is Argo CD app X still Progressing — 0/3 ready, StatefulSet x?"), the app, the mode's line (or the rail's place), what only its Application knows and where, its health and whose, each object as its app counts it, its hooks, images, `kubectl … describe` of each cause and `argocd app get` (never for a probable app), what couldn't be read; chips for the conditions, the pods and the events; every word through `KubeAgentBriefing.scrubber`, the app's and its objects' names kept out of what it takes out; the bound checkout's deployed commit added as for any brief. No new tool and no write. Tests: `KubeMCPGitOpsMarksTests` (a spoke's apps problems first, never "serves neither", nothing of Argo CD's or Flux's asked; the opening line by the mode's reason — metrics.k8s.io down still "another cluster"; argoproj.io down, served with none, refused —; `kind: "application"` and `kind: "marks"`, `state: "all"`, `failing_only`; a namespace; 20 GETs and 4 in flight under 32 that may be problems; a cut and a refused read; a whole read with no mark; Rollouts by their phase; the page's store answering with no request, a narrower one not; the checkout's app, and option B's "describes", never "owns"; the lines and counts, pure), `KubeMarkedBriefTests` (the words, every mode, a probable app, Unknown ranked with Failed, Ready not asked; against the fake: a StatefulSet's brief by GETs only, one failing Deployment's hand-off, the sentinel nowhere), `KubeGitOpsMarksPageTests` (`a` on a Progressing app, the stalled one's hand-off, a Ready one refused, the menu, the detail's app), `KubePanelGitOpsTests` (the rail's Ask Why with its words) and the `kubernetesGitOpsMarks` scenario's part 5 (`kubernetesGitOpsMarksAgents`: the sheet's brief, a Ready app, the detail's button, `k8s_gitops` from the store) and its rail part's Ask Why.

**D6's fix pass**: the review found what an agent is told short of what the rail and the detail say, and claims nothing had checked. Ask Why on an Argo Rollout's app reads the Deployment its `workloadRef` names where the Rollout has no selector of its own (all 115 marked Rollouts of the surveyed production spoke), within the brief's 6, so its pods — the crash-looping one too — are listed under the Rollout: the not-ready workloads' lists alone are made (`lists` of them), so the Deployment it scales to 0 never takes them, and that Deployment's own conditions stay out of the chip. What the context serves is the page's, else the rail's (`KubeGitOpsMatchCache.shared.discovery`), else read for the brief, else the built-in workloads' kinds (`markedBuiltInKinds`) — never "StatefulSets aren't served here" for want of a discovery (the rail's Ask Why on a context the page never showed). `checkout: true` finds `.noApplications` as the rail does: B first — the rail's cached listing with its reason, where no section said one (on production only that: a person's press's, as before); else, Applications served and none held, off production, `markedListing(reason: nil)`, one row of them asked —, then A; `kind: application` reads nothing from marks and keeps its owners' "not in" lines and problems (D6 dropped them for every kind). `kind: marks` beside Applications: apps grouped by `app.kubernetes.io/instance` alone are said only probably Argo CD's, never compared with the Applications, never "has an Application of its name"; a read of Applications that can't tell says its cause (`GitOpsKindRead.unlisted`: "couldn't be read — <why>", "were cut at an agent's bound"), and otherwise its notes (refused, read where) follow the apps. The agent's read makes members, apps and candidates and ranks them off the main thread (`marksMade`, `marksRanked`, nonisolated, through `KubeBlocking`); where Argo Rollouts are served and weren't read whole (`marksRollouts`: refused, failed, cut, or read only where the context says), a Rollout-run app is Unknown by `KubeGitOpsMatch.health`, never Ready from its Deployment's 0. What the section and the rail keep holds its counts as numbers (`KubeCountedText`, a sentence written with `\(count: n)`, equal by its plain words: `KubeMarkedReading.rowCuts`/`notes` with `unread(plain:)`, `said(plain:)`, `empty(…plain:)`; `MarkedListing.notes`, `KubeCheckoutManifests.Read.cut`, `KubeGitOpsMatch.marked(…plain:)`): the page groups them as the person's locale does, an agent reads `2000`, never Turkish's `2.000`. `KubeMarkedFetch` counts each GET in flight as the most it may read, so "16 MB in all" holds whatever comes. Tests: `KubeMarkedBriefTests` (a Rollout's pods by its Deployment's selector and a closed set of what was read; no discovery — read for the brief, and unanswered, the built-in kinds — never "not served"), `KubeMCPGitOpsMarksTests` (the checkout where Applications are served with none — the agent's own B and the rail's kept listing —; kind application's owner line; probable apps beside Applications; the Applications read's cause; Rollouts refused; plain counts; the fetch's bytes in all), `KubePanelGitOpsTests` (the rail's Ask Why through the page on a context it never showed) and the `kubernetesGitOpsMarks` scenario's part 5, each sub-part's reads a closed set (the brief's kinds in its app's namespace, events about its causes alone, beside the section's own).

**D7 as built** (`kubernetes: GitOps from marks at a spoke's size`): `kubernetesGitOpsMarksPerf` (`E2ERunner+KubernetesGitOpsMarksPerf.swift`) is `kubernetesPerf`'s leg after `kubernetesGitOpsPerf`, on a fake of its own that `fake-prod` (production by name) reaches. `FakeKubeAPI.addSurveySpoke` (`FakeKubeAPI+MarksSurvey.swift`) is §14.12's production spoke: 1,161 Deployments, 980 marked, 207 of them at 0 (115 run by Argo Rollouts by `workloadRef`: 112 Healthy, 2 Degraded, 1 Paused), 894 apps from them and 12 of other kinds (906), `<env>-<ns>-<name>-service` names that never equal a workload's, no `ns_name`; 1,006 Services, 893 marked HPAs of 1,080, 95 Ingresses (one app of 94 and nothing else, Unknown), 44 CronJobs, 8 hook Jobs, 8 claims, 3 StatefulSets, 8 DaemonSets, copies on six HPAs and six PDBs, 70 namespaces; 21 rollouts past their deadline and 23 with not every replica available, two single replicas stuck behind their old pod and one paused that only their objects say; marked rows of about 15 KB with managedFields (`tableManagedFields`, Argo CD's server-side apply time spread over a month). Measured on the release build (Apple silicon): the spoke's Overview in ~0.4 s; the first draw of the 906 apps ~1.5 s, the main thread held at most ~0.2 s throughout; M1's first lists 15.3 MB (the Deployments' 15.1 MB, 13.3 KB a row on average) — D-6's 30 MB kept; M3 2.6 MB, the Services' 1.8 MB (cut at 16 MB); the settle's first minute 60 GETs, ~320 KB in ~1 s, of 1,151 to settle — 20 minutes of the section showing at 60 a minute, more while the tick re-reads what is in progress; a burst of 500 Deployment events ranked in ~0.4–0.5 s; 2,000 readiness-only row events, none asked as a move, merged in ~2 s; the 906 rows scrolled at p95 ~12 ms; `marksSeen`'s look-ups 0.25 ms over 1,161 rows (0.3% of reading them, 0.04% of the pods leg's Overview, ~0.6 s); the footprint ~45–70 MB more after the leg. What it found, fixed here: (1) newest change first, the settle left the 115 Rollouts' apps "Unknown, not read yet" (never hidden) and the 21 rollouts past their deadline Progressing from their rows behind ~900 ready-looking workloads, up to twenty minutes before Argo CD's rule said them: `KubeMarkedRefetch.doubtful` — a row not Healthy by its cells, or what no cell says (a Rollout's phase, a CronJob's last run, an `<unknown>` HPA), as an agent's read picks them (D6) — is taken first within the settle, each group the most recently changed first: the first minute's 60 are all such, and the stalled ones among them say Failed; (2) the minute's 60 were counted from the take, so a GET queued behind four in flight reached the server later than it was taken and the next minute's came less than a minute after it — 66 in a minute at the fake once: a GET's place now counts from its answer (`answered`; one given up in flight at a hide, from then), and the leg counts the most in any minute by the fake's own times (`FakeKubeAPI.timedRequests`); (3) `marksSeen`'s look-up bridged each row's annotations and labels whole into Swift dictionaries — kubectl's last-applied copy among them —, 6.5% of reading the rows it looked in: `KubeTableReader.argoMarked` asks JSONSerialization's dictionaries as they are, 0.3%. `MainThreadStall` says how much of its longest gap was the main thread's own work and when it ended, and the leg's waits look at the session, never at the fake's log, whose lock is held while it makes a list. Tests: `KubeMarkedReadsTests` (what may be a problem first; doubtful by its row; a place counted from its answer), `KubeMarkedAppsSessionTests` (more to settle than a minute's: what may be a problem in the first flush, a Rollout's app Failed by its phase) and the leg, each part's reads a closed set.

**D7's fix pass** (`fixup! kubernetes: GitOps from marks at a spoke's size`): the review found the bound claimed "at the server" short of what held, and the leg short of what it claimed. (1) A GET's place lapsed a minute after its take, answered or not, and every flush queued what it took: a server slower than four in flight can keep up with (GETs past ~7.5 s) grew the queue past 60 and got all of it once it sped up — modelled, 356 GETs in one minute. `KubeMarkedMinute` (pure) holds a place from its take until a minute after its answer, never frees one unanswered, gives back one taken and never sent (hidden while it waited), and an object being read is never taken again (`busy`). (2) The minute lived in one `KubeMarkedRefetch`, replaced by `drop()` and by another context: each return to a covered window, the page closed and opened, or prod → dev → prod within a minute was another minute's 60 — uncovering the window every 20 s, ~180 GETs a minute at the production API server. `KubeMarkedLedger` keeps each context's minute — the app's, `KubernetesModel.markedMinutes`, every window's section sharing it, memory only, spent minutes forgotten —, and a covered window only hides the section (§3.1, §14.4.2), its settle going on where it was. (3) Doubtful first took every row not ready by its cells before any ready-looking one, so a just-synced single replica stuck behind its old pod, or a paused rollout — the case D-4 exists for — waited behind all ≈205 on the survey's spoke, ~3.5 min, Hide Ready hiding it as Ready: a workload Argo CD changed (else made) in the last hour is doubtful too (`recentlyChanged`), the newest first. (4) The settle took at the first flush after show, so whichever kinds' lists came first went first: it waits until every first list it orders across is in (`firstListsIn`), and the session test asserts the session's own order (`firstTaken`) with the HPAs' list held back, never the server's arrivals. (5) Found with (2)'s page test: the section shown before its context's discovery was read — another context picked with the section open — never started the marks where Argo CD and Flux aren't served, the kinds it reads the same none either way; `KubeGitOpsSession.show` updates them when discovery comes. The leg now checks, beside D7's: the switch and the Overview's reads before `g` a closed set (its parts, its health checks' lists, the page's own), the fake's log never forgotten; every list or watch of a marks kind rows with their metadata, no M3 kind watched; the six copied marks on HPAs counted (`tally.copied`), nobody's member, under their Deployment's app; the sentinel in nothing the section keeps or draws, after the first draw and after the settle; five of the 21 rollouts past their deadline single replicas whose cells read `1/1`, synced in the last hour, read with the two stuck and the paused one in the first minute and said by Argo CD's rule; the churn on the 20 Deployments the first minute settled beside 80 not yet settled, the burst's 50 the only moves taken (`taken(as:)`); the page closed and opened again within the minute — 0.9 s, 1 GET, the one place freed since —; never more than 60 object GETs in any minute from `g` on (120 in all); `k8s_gitops` with no section's apps kept, its Deployments' rows 14.6 MB of its 16 MB cut (91%), whole, 905 apps (the Ingresses' has no workload), at most 20 GETs, in ~0.35 s. Tests: `KubeMarkedReadsTests` (a place never freed unanswered, given back unsent; what is being read and the settle before its lists wait; just synced is doubtful), `KubeMarkedAppsSessionTests` (a slow server — `FakeKubeAPI.answerObjectsSlowly` — never sees more than 60 a minute; the minute across a drop, another context and back; just synced under ready cells settled in the first minute; the first take across every kind; discovery coming after the section shows), `KubeGitOpsMarksPageTests` (a covered window keeps what was read; hidden and shown, another context and back, within the minute: none again).

**The floor is D0–D3 and D5:** the person's two asks, the section and the rail. D4 and D6 add depth. D7 proves the bounds. D0 stands alone and fixes a bug that exists today.

**D7 gates the release.** D3 turns marks mode on for every context with marks, the person's 980-Deployment production spoke among them, so a version holding D3 isn't released (tagged) before D7's leg passes, whatever stages ship in it. D7 can land right after D2, since it drives the session, with the parts that need D3's view added then. It landed last, and passes. §14.9.4's survey ran after it, on 2026-11-15, and found M1's rows well within D-6's 30 MB; the look in Overterm on the real spoke is still the person's.

### 14.9 Tests

#### 14.9.1 The fake spoke (`FakeKubeAPI+Marks.swift`)

`addSpoke(apps:deploymentsPerApp:…)` builds the spoke and never calls `serveArgoCD()` or `serveFlux()`. Its defaults are 894 apps and 980 Deployments, across `team-0…team-9` namespaces and ~60 more. Each row's metadata is padded to 5 KB by default, or 15 KB for the perf leg, through a `last-applied-configuration`-like annotation that must not survive.

It adds:

- **Workloads:** 100 StatefulSets, 40 DaemonSets, 900 Services (10 LoadBalancer, 2 without External-IP), 300 Ingresses (1 without Address), 200 CronJobs (1 last run failed), 150 HPAs, 100 PVCs (1 Pending).
- **Apps in any namespace:** 20% of names in `ns_name` form.
- **Two installation ids:** 82 apps with `hub-b`.
- **Copied marks:** ReplicaSets carrying their Deployment's mark, plus 5 operator-made objects with their CR's mark.
- **Malformed marks:** missing parts, 2 KB long, a newline, a `../` in the name.
- **An app spanning two namespaces,** and a cluster-scoped `ClusterRole` mark carrying a destination namespace.
- **Other marks:** 5 objects with only `argocd.argoproj.io/instance`, 3 hooks, 2 `ignore-healthcheck`, and 30 Helm-installed workloads with only `app.kubernetes.io/instance` plus `meta.helm.sh/release-name`, which must not be apps.
- **States:** 3 Deployments with `ProgressDeadlineExceeded`, 2 paused (one of them with cells `2/2`, so only the settle finds it), 11 rolling; 2 single-replica Deployments stuck with the old pod serving (cells `1/1`, `1`, `1`; object `status.replicas: 2`, `updatedReplicas: 1`, one with `ProgressDeadlineExceeded`); 1 StatefulSet `0/3` (expected Progressing, never Failed); 1 HPA with `ScalingActive=False/FailedGetResourceMetric` and its Targets cell `<unknown>` (Degraded); 1 app made of a Service and an Ingress only (expected Unknown, "no workload read"); 1 LoadBalancer Service whose External-IP cell is `<pending>`.
- **Objects as well as rows:** every workload and CronJob is served whole by its object list and GET with a `status` consistent with its cells, except where a state above says otherwise.
- **`forbidden` variants:** Deployments refused across the cluster; Applications CRD served but refused (`addCRD` for Applications only, `forbidden "applications.argoproj.io@cluster"` and in `argocd`); Applications refused across the cluster but readable in `argocd` only.
- **Discovery failing** for `argoproj.io` (the group answers 503), and separately for `metrics.k8s.io` alone (must stay `.notServed`).
- **Rollouts served:** a variant serving `rollouts.argoproj.io` (no Applications), so the header's Rollouts sentence shows and no Rollout is requested.
- **Churn:** a generator of 2,000 Deployment row events where only readiness moves (generation unchanged), for M2's rate bound.
- **Coexistence:** `serveArgoCD()` with 100 Applications, and marks naming 112 apps: 6 `team-x_name` marks, 4 plain names, 2 with an installation id. A second variant over `addGitOpsPerfApplications(1000)`, so R2 is cut at 500 while R1 lists all 1,000.

#### 14.9.2 Unit tests (pure)

- `KubeTrackingIDTests`: §14.6's rules, each rejection, and `isSelf` with the core group and cluster scope.
- `KubeMarkedAppsTests`:
  - grouping by (installation, instance);
  - an `ns_name` app versus a same-named plain app;
  - copied marks excluded;
  - instance-label members tagged;
  - a Helm `app.kubernetes.io/instance` excluded;
  - multi-namespace;
  - destination namespace from the cluster-scoped mark;
  - the merge only re-grouping changed keys;
  - a bound against accidental quadratic work that holds in a debug build on CI: 10,000 rows take at most 3× the time of 5,000, and 5,000 take under 500 ms. A 50 ms bound would be flaky in debug.
- `KubeMarkedHealthTests`: each row in §14.5 from cells and from wires; the stuck single-replica rollout (cells ready, object Progressing then Degraded); a `<pending>` LoadBalancer; a ClusterIP Service Healthy; worst-first, with Unknown worst for the word and the worst known member for the rank; StatefulSet and DaemonSet never Degraded; an app with no workload member Unknown; HPA conditions; a CronJob never succeeded Healthy; hooks and ignore skipped; an app with no member rule Ready, not Unknown; "from its row" carried to the app; the three-causes cut; sentences; pods not counted.
- `KubeMarkedAppsModeTests`: §14.3's table, including R2's cut having no bearing and R1's first list not yet come giving `.off`; `metrics.k8s.io` alone in `failedGroups` still `.notServed`; `.undiscovered` never saying "another cluster"; a fallback-only Applications read saying missing only for `ns_name` marks in a read namespace; an installation-id mark never said missing in coexistence.
- The "last change applied" rule: a `kubectl-edit` or HPA `managedFields` entry newer than Argo CD's is never shown as Argo CD's; an unknown manager shows no time.
- The sentinel: `KubeMarkWire` and `KubeMarkedWorkloadWire` drop `SENTINEL` from last-applied, env, args, other annotations, and a condition message past 300 characters.
- `KubeGitOpsMatchTests`: B's tuples giving `.describes`, never `owns`, from YAML with several documents, a kustomization without names and a Helm template skipped; C's and D's "probably" and "too many".

#### 14.9.3 E2E

**`kubernetesGitOpsMarks`,** a new part in `E2ERunner+KubernetesGitOps`, on the fake spoke at 50 apps:

1. Discovery has no Argo or Flux. The GitOps row shows once the Overview has seen a mark, and `g` opens it.
2. The header's two lines verbatim. The chips' counts. Failed rows first with their sentences, and Hide Ready on.
3. `is:marks`, `image:` and `G` installation. Coexistence, with the "not in this cluster" chip. Forbidden Applications, with that header.
4. ↩ on a failing app: the tree, per-object health, a copied ReplicaSet as a child, "What Argo CD knows" rows, no Sync, Refresh, Rollback or Diff in any menu, and ↩ on a node opening the Deployment's detail.

**`kubernetesCheckoutGitOps` part 7:** a checkout bound to `team-3` shows its app's state and the "another cluster" sentence. A config-repo checkout with matching YAML is matched by B after Find on a production-classed context, and not before.

**`kubernetesGitOpsMarksPerf`,** in `kubernetesPerf`, at the surveyed production spoke's size and shape (§14.12: 980 marked Deployments of 1,161, 115 Argo Rollouts, 906 apps) and 15 KB rows. It keeps the existing budgets:

- first draw in under 5 s;
- the main thread never held 500 ms on open or during a burst of 500 Deployment updates, which is ranked within 3 s;
- scrolling under 35 ms a step at p95 with Hide Ready off;
- M1's first list under 30 MB, recorded;
- M1b only GETs of one object (no list of whole objects), never a watch, decoded off the main thread (no 500 ms hold while it runs), within the 60 a minute shared with M2 — what may be a problem first, so the first minute's 60 go to it, what was just synced under cells that read ready said by Argo CD's rule in it —, its count, bytes and time to settle recorded;
- M2 GETs ≤ 20 a flush and ≤ 60 a minute at the server (the fake's own times) under 2,000 readiness-only row events, which cause none — on rows the first minute settled too, where a "cells moved" rule would ask;
- the page closed and opened again within the minute: only the places freed since taken, never a fresh 60 (the context's minute); never more than 60 object GETs in any minute from `g` on;
- the copied marks counted and nobody's member; the sentinel in nothing the section keeps or draws, after the first draw and after the settle;
- `k8s_gitops` with no section's store: its Deployments' rows recorded against its 16 MB cut, its count exact only from a whole read, at most 20 GETs, its paths a closed set;
- no watch of M3's or M3b's kinds; M3's Services' bytes recorded against the 16 MB cut; no 500 ms hold while M3 and M3b decode;
- the Overview's `marksSeen` costing no more than 5% over the pods leg's Overview time;
- no request for Argo CD's own kinds (Applications, ApplicationSets, AppProjects) or Flux's — on the surveyed spoke `argoproj.io` serves Argo Rollouts, read for health only (§14.12) —, no Secret or ConfigMap request, and no write.

**Every request is checked** against the fake's log: for each part, the set of paths the part read, so a new list can't sneak in — the switch to the spoke and its Overview too, and the whole log at the end, nothing forgotten (D7's fix pass); every list or watch of a marks kind rows with their metadata, no M3 kind ever watched.

#### 14.9.4 The read-only real-cluster check (after D3, and again after D7)

Run by the person after signing in. The survey script uses only get, api-resources, auth can-i and version, with `--context` and a 20 s timeout each, sequentially, and never touches Secrets or ConfigMaps. It confirms:

- the counts **[survey]** above;
- the tracking-id form, and how many names are `ns_name`;
- installation ids;
- the share of rows with `last-applied-configuration`, and the Deployment list's bytes and time;
- the Argo CD client-side apply manager's name in `managedFields`;
- how many app names are shorter than 5 characters or shared, which decides C's worth.

Then, in Overterm on the real spoke, read-only:

- the section opens and shows the problems first, with the sentence;
- the numbers match the survey's;
- a known failing app's detail agrees with Argo CD's UI in the hub (asked of the person, since the hub isn't reachable from here);
- Activity Monitor shows no growth after 10 minutes on the section.

No write is attempted.

**Run after D7 (2026-11-15).** The survey part ran on the spoke's production and development clusters, with get, api-resources, auth can-i and version only, and printed counts only. Production comes first below, development second. It found:

- **The counts.** Production's match §14.12's: 1,161 Deployments, 980 marked, 207 of them at 0; 115 of 117 Argo Rollouts marked, all by `workloadRef` (112 Healthy, 2 Degraded, 1 Paused); 21 Deployments past their deadline; and marked, 1,004 Services, 893 of 1,137 HPAs, 95 Ingresses, 44 CronJobs, 8 Jobs, 8 claims, 3 StatefulSets and 8 DaemonSets. Development's Deployments (1,208, 997 marked, 111 at 0) and Rollouts (29 of 31 marked, all by `workloadRef`) match too. What moved are live numbers, each counted a little differently from §14.12's: the marked Deployments with not every replica available, 27 and 26 (23 and 28 "unavailable"), and development's past their deadline, 14 (17 "stalled").
- **The marks.** Every tracking id is in Argo CD's form: none unparsed and none `ns_name`, in either cluster. No own mark carries an installation id (3,155 own marks in production, 2,479 in development): one unnamed installation in each.
- **Copied marks:** 1 Deployment, 1 Service, 7 HPAs and 1 PDB in production; 3 HPAs in development. The leg's fixture copies onto six HPAs and six PDBs only; a copy on a Deployment and on a Service is `KubeMarkedAppsSessionTests`' — never read by GET, never a member.
- **The apps.** By own marks, 950 in production: 934 with a workload of their own and 16 without (10 of HPAs and Services, 4 of HPAs, 1 of a Service, 1 of an Ingress), which §14.5's rule for an app with no workload read says Unknown. 957 in development: 946 and 11. 893 and 905 have a Deployment of their own (§14.12's 894 counted every marked Deployment, the copy too). One app in each cluster spans more than one namespace.
- **Applications** aren't served in production, and a list of them fails; development serves them and lists none. Those are `.notServed` and `.noApplications`.
- **The rows.** kubectl's last-applied is on 1,138 of 1,161 Deployments, 1,232 of 1,271 Services and 1,134 of 1,137 HPAs in production, and on 1,165 of 1,208, 1,282 of 1,337 and 234 of 235 in development. kubectl prints the whole Deployment list, managedFields included, as 33.17 MB (2.6 s) and 34.38 MB (2.6 s): `-o json`'s indented JSON, four spaces a level, so neither the bytes the API sends, which are compact, nor comparable with the metadata, measured compact. Its objects' metadata, managedFields included (about what a row with its metadata carries, less the cells), is 8.88 MB and 9.17 MB: about 7.6 KB a Deployment, a marked one's about 8.0 KB and 7.9 KB. M1's four kinds, Rollouts among them, come to ~9.5 MB of metadata in each cluster, well within D-6's 30 MB. M3's six kinds, M3b's CronJobs and HPAs among them, come to ~6.3 MB and ~7 MB of metadata every 5 minutes while shown; the largest kind's is 2.95 MB (production's HPAs) and 3.19 MB (development's 1,224 Jobs), far under the 16 MB cut. The leg's rows, 13.3 KB on average with their cells, are about 1.7 times the real ones' metadata.
- **The managers.** Argo CD's client-side apply writes as `argocd-controller` with operation Update (2,995 entries on production's own-marked objects, 2,315 on development's), and its server-side apply as `argocd-controller` Apply (105 and 108). The manager is on 962 of production's 979 own-marked Deployments, 975 of development's 997, and every own-marked Rollout. An older version's `argocd-application-controller` is never the newer entry, and it is alone on 1 production Deployment: taking it too would date that one, last changed under a year ago, and no other. `kubectl-client-side-apply` (1,207 and 645 entries) and `argocd-server` (478 and 385) stay out. `KubeMarkWire.argoManagers` stays `argocd-controller` alone, confirmed.
- **Argo CD's recent changes**, the newest `argocd-controller` time on an own-marked Deployment: none in the last hour and 7 in the last day in production; 5 in the last hour and 10 more in the day in development; no own-marked Rollout in the last day in either. So what D7's fix pass puts first in the settle for Argo CD's change in the last hour was 0 Deployments in production and 5 in development.
- **C's worth.** 8 apps in each cluster have a stem shorter than 5 characters (the name with `<env>-<ns>-` and `-service` left out). 81 production apps share 27 stems: 9 shared by two apps, 10 by three, 7 by four and 1 by five, so 33 apps are in stems of more than 3. 76 development apps share 27 (16 in stems of more than 3). Of the apps with a Deployment (the only ones this part counted), 73 share 23 stems in production and 70 share 24 in development, and each is alone with its stem in its namespace: no two of them sharing a stem are in one namespace. That they are one service deployed into several namespaces is an inference; the other 8 production apps in shared stems and 6 in development (without a Deployment, or sharing their stem only with apps without one) weren't checked. So the rail now looks in the bound namespace first (§14.2.5, as built after this run): its apps are said alone, those elsewhere counted.

The look in Overterm on the real spoke (the four points under "Then, in Overterm on the real spoke") hasn't been done: it is still the person's.

### 14.10 Risks

| Risk | Mitigation |
|---|---|
| Rows much larger than 5 KB (client-side apply's last-applied) | The perf leg runs at 15 KB. The real check measures it: after D7, about 7.6 KB of metadata a Deployment (a row is that plus its cells) and ~9.5 MB of metadata for M1 in each cluster, managedFields included (§14.9.4). Above 30 MB, decision D-6 (per-namespace follows don't fit the watch cap and save no bytes). |
| A marked app is mistaken for a live one (deleted in the hub, marks left) | The hover says it plainly. Nothing writes on a derived app. |
| Optimism: cells show Ready for a paused Deployment, a stale generation, or a stuck single-replica rollout whose old pod serves | M1b settles every workload by Argo CD's rule in the background, one GET each within the budget; until then "from its row" is said on the state and counted on the Ready chip. M2 follows rows that move. Decision D-4. |
| A sign-in wait or a refusal shown as an answer ("no marks", "another cluster", "not in") | §14.3's rule: only a whole read says absent; `.undiscovered`, fallback-only and cut reads say what wasn't read |
| A namespace-less manifest matching many apps in the rail | B is exact only with the namespace; otherwise "probably", and only in the binding's namespace |
| The hub's custom health checks disagree with built-in rules | The second header line says "Argo CD's built-in rules applied to what is here" |
| Coexistence's instance-name guess shows an app twice | False negatives over false alarms (§14.3). A name match is never said as missing. |
| Several installations merged by mistake | Keyed by installation id, never merged |
| Name and image heuristics claim a checkout wrongly | Shown apart as "probably", with the matched words. The bound namespace's first, those elsewhere only counted: on the surveyed spokes no two apps with a Deployment that share a name are in one namespace (§14.9.4; that they are one service is an inference, and apps without a Deployment weren't counted). "Too many to tell" above 3. Never `owns`, never a verb. |
| Marks mode starting reads behind an expired OIDC sign-in | No discovery, no request: the mode is decided from discovery, which needs the sign-in; the proxy's "waiting for sign-in" is shown (§14.4.8) |
| M2's GETs following readiness churn across ~1,000 Deployments on a production API server | GETs only on a generation move, not-ready cells or an unhealthy last state; 60 a minute for the section; the D2 test and the D7 leg drive 2,000 readiness-only events |
| An app whose workload is a Rollout, a Job or a custom resource read as Ready from its Service | Such an app is Unknown, "no workload read" (§14.5); the header's hover lists the kinds read, and says so when Rollouts are served |
| A checkout whose YAML names the same objects as the deployed app but isn't what Argo CD reads (a fork, an old copy, an app repo beside its config repo) | B says "describes N of its objects", never `owns`; only A (the binding's own workloads) owns |
| A 1,000-Application hub-and-destination losing derived rows to R2's cut | Presence is read from R1's uncut rows, not R2's summaries (§14.3) |
| A copied mark inflating apps (ReplicaSets, operators) | D0's self check; ReplicaSets never listed across the cluster |
| A malicious or garbled mark | §14.6's parser; nothing reaches git, a shell or a URL |

### 14.11 Open decisions (with the recommendation)

The stages are built on the recommendation until the owner decides otherwise. Only what the survey settled (§14.12) is marked settled.

| # | Question | Recommendation | Why |
|---|---|---|---|
| D-1 | In coexistence, follow M1 (11 watches) or read it periodically | **Periodic: on show, Refresh, and every 5 min**, no watch | Keeps the page's 10-watch cap. Derived rows are the minority there, and every 60 s would re-list ~15–20 MB a minute at the spoke's size. |
| D-2 | Offer Copy Argo CD Command on a derived app | **Yes**: `argocd app get <name> [--app-namespace <ns>]`, without `--core`, labelled "against your Argo CD server", copied, never run | It's the next step a person takes, and it needs the hub, which is theirs to reach. `--core` would read this kubeconfig and fail. |
| D-3 | `link.argocd.argoproj.io/*` annotations | **Text in the detail, copyable; not opened**, in this addendum | A cluster-supplied URL opened by a press is a new trust edge. Opening (https only, userinfo stripped, the browser column) can come later. |
| D-4 | Settle ready-looking rows by Argo CD's rule (paused, stale generation, a stuck rollout whose old pod serves) | **Yes, by M1b's settle in D2**: rows plus one GET each, most recently changed first, within M2's 60 a minute, never a list of whole objects | Cells alone show a common failure, a single-replica Deployment with a bad image, as Ready, and a hover can't fix a wrong state. **Settled by the survey (§14.12, consequence 5: rows-only, never full JSON):** the earlier recommendation, one paged list of whole objects on show (~16–20 MB), is out. What remains is replacing it by GETs: ~1,120 at 60 a minute is ~20 min of the section showing to settle all, ~1.2 MB a minute at worst, said "from its row" meanwhile. **Open: the owner may prefer cells only in the floor** (no settle, "from its row" on every Ready) and the settle in D7. |
| D-5 | Use `app.kubernetes.io/instance` alone to form apps | **Only when no tracking id or `argocd.argoproj.io/instance` is in the scope**, said "probably", Helm's annotated ones excluded | On a spoke with tracking ids, it would add hundreds of Helm and kustomize apps that Argo CD doesn't own |
| D-6 | The real spoke's M1 rows are past 30 MB (client-side apply's `last-applied-configuration` on large Deployments) | **Settled by the survey: keep the 30 MB bound**; the D7 leg records the real size — 15.3 MB for M1's first lists at the survey's size with 15 KB rows. Measured after D7 (§14.9.4): M1's metadata, managedFields included, ~9.5 MB in each cluster, the 1,161 production Deployments' 8.88 MB, about 7.6 KB a Deployment (a row is that plus its cells), so the leg's rows (13.3 KB on average, cells included) are about 1.7 times that | The survey (§14.12) measured kubectl's printout of the whole Deployment list at ~16 MB (indented JSON, not the bytes the API sends); rows-only is smaller. Per-namespace follows don't fit the 10-watch cap at ~70 namespaces and read the same bytes. |
| D-7 | How an Unknown app with a Degraded member ranks | **Word Unknown (Argo CD's), rank with Failed, why names the Degraded member** | `KubeGitOpsState.unknown` sorts last and is shared with Applications, where it means "not read yet"; reordering it would move every Application. Showing Failed instead would differ from Argo CD's UI. |
| D-8 | Whether manifest identity (option B) may say `owns` | **No: `.describes N of its objects`**, above C and D | Identity isn't provenance (forks, copies, app repo beside a config repo). Only the binding (A) owns. |
| D-9 | The Overview's GitOps line on a spoke | **Unchanged in this addendum**: it stays K601–K603, so a spoke's Overview says nothing about derived apps | The Overview already reads workloads with metadata (`KubeClusterOverviewSession.swift:130-133`) and could count failing derived apps, but that is a new Overview read path and a new finding. It is a later stage if the owner wants it. |
| D-10 | When D7's perf leg must pass | **Before the version holding D3 is released**, landing right after D2 if possible | D3 turns marks mode on for the person's 980-Deployment production spoke. |

### 14.12 Survey facts (2026-11-14)

A read-only look at the spoke's production and development clusters (prod and dev below). These replace every [survey] estimate above, and the consequences at the end override anything earlier in §14. A figure marked "after D7" is the second run's (2026-11-15, §14.9.4), beside the first's.

Read with get, api-resources and auth can-i only, an explicit `--context`, no Secret or ConfigMap.

| | prod | dev |
|---|---|---|
| Kubernetes | 1.33 (EKS) | 1.36 (EKS) |
| applications.argoproj.io served | **no** | **yes, but 0 Applications** (Argo Workflows/Rollouts CRDs present; Argo CD's apps live elsewhere) |
| Rollouts CRD | served; 117 Rollouts, 115 marked, **all 115 with spec.workloadRef**; phases Healthy 112, Degraded 2, Paused 1 | served; 31, 29 marked, all workloadRef; Healthy 27, Degraded 1, Progressing 1 |
| Deployments | 1161, 980 marked (after D7: 979 own, 1 copied), **207 scaled to 0** (the Rollouts' referenced Deployments), 23 unavailable (after D7: 27 with not every replica available, counted another way), 21 progress-stalled | 1208, 997 marked, 111 scaled to 0, 28 unavailable (after D7: 26 with not every replica available), 17 stalled (after D7: 14 past their deadline) |
| distinct apps (from Deployments) | 894 (after D7: 893 by own marks; 950 by own marks of every kind read, 16 without a workload) | 905 (after D7: 905; 957 of every kind read, 11 without a workload) |
| tracking-id format | always `app:group/kind:ns/name` (after D7: none unparsed); no `_` (no apps-in-any-namespace); every app in one namespace (after D7, counted across every kind read: all but 1) | same (after D7: none unparsed; all but 1 app in one namespace) |
| self-reference | 99.9% self; copied marks only on a few HPAs, PDBs, Roles/RoleBindings (after D7, of the kinds read: 1 Deployment, 1 Service, 7 HPAs, 1 PDB; Roles and RoleBindings not read) | same (after D7: 3 HPAs) |
| other marked kinds | Services 1004, HPAs 893 (of 1137), SAs 336, Ingresses 95 (one shared app holds 94), CronJobs 44, Jobs 8 (hooks), PVCs 8, StatefulSets 3, DaemonSets 8 (after D7: the same; PDBs 7 of 18; SAs not read) | similar; Jobs 45 (41 Argo hooks); after D7: Services 1,010, HPAs 211 (of 235), Ingresses 98, CronJobs 54, Jobs 45 (of 1,224), PVCs 12, StatefulSets 6, DaemonSets 9, PDBs 11 |
| app name vs objects | app name **never** equals the Deployment's name or its `app` label: `<env>-<ns>-<name>-service` (504), `<env>-<ns>-<name>` (258), `<env>-<name>` (40)… | |
| full Deployment list, as `kubectl get -o json` prints it (indented, four spaces a level: not the bytes the API sends) | 16.3 MB in 2.5 s (after D7, managedFields included: 33.17 MB in 2.6 s; the objects' metadata alone, as compact JSON, 8.88 MB — not comparable with the printout) | 16.9 MB in 2.6 s (after D7: 34.38 MB in 2.6 s; metadata 9.17 MB) |
| sign-in | kubectl oidc-login exec plugin; an expired session blocks for minutes waiting for a browser | same |

Consequences for the design (taken as decisions, within the scope the person chose):
1. **Derived mode's trigger is "no Application deploys these", not "CRD not served".** dev serves the CRD with zero Applications and 0 of its 905 marked app names exist as Applications. Rule: derive when Applications are not served, or are served but none is listed (R1's row follow, complete, says 0), or the marked app names are absent from a complete Application list. Wording: prod → "Argo CD runs in another cluster — not in your kubeconfig."; dev → "Argo CD's Applications for these aren't in this cluster." (never "Argo CD isn't installed").
2. **Rollouts are read for health only — no Rollout feature.** A marked Rollout with `workloadRef` is the app's workload: its row (metadata + status.phase, via the Table/rows path, same budget as Deployments) gives the app's health (Healthy/Degraded/Paused/Progressing map onto ours as Argo CD's own Rollout health check does). The Deployment it references, scaled to 0 by the Rollouts controller, is shown as "scaled by its Rollout", never as a problem or "scaled to zero". Without this, 115 prod apps would read as scaled down. No Rollout verbs, no Rollout page — said in the detail ("promote/abort are Argo Rollouts' — not here").
3. **Argo hook Jobs** (annotation `argocd.argoproj.io/hook`) are not members for health (Argo CD leaves hooks out of app health); shown under the app as hooks.
4. **Rail matching**: since names never match workloads directly, option C (app name) must strip `<env>-<ns>-` and an optional `-service` before comparing with the checkout's name or its manifests' names — still "probably". Option B (the checkout's committed YAML identities vs the tracking-id tail `ns/name`) stays the exact one. After D7's run (§14.9.4), the rail says the bound namespace's apps first and only counts those elsewhere: every stem the apps with a Deployment share is shared across namespaces only.
5. **Budget**: ~2,000 marked workloads + Rollouts per cluster; rows-only reads, never full JSON (kubectl prints the Deployment list as 16 MB of indented JSON). Problems-first is non-empty in practice (≈45 Deployments + 3 Rollouts).
6. **Expired OIDC session**: a context whose exec plugin waits for a browser must say "Sign-in needed — run `kubectl --context X get ns` once in a terminal" after a short wait, not "unreachable" after minutes. Check KubeProxies' oidc handling; add a test with a stand-in exec plugin that sleeps.
