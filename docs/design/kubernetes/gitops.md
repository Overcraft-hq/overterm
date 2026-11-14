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
- **Rows first, then a bounded settle by GETs.** A workload's first state comes from its Table cells (Ready, Up-to-date, Available) and is said as "from its row". Cells can't show a stuck rollout whose old pods still serve, a paused Deployment, or a stale generation. Reads are rows only, never a list of whole objects (§14.12, consequence 5: the whole Deployment list is 16 MB of JSON). So a row whose generation moves, whose cells turn not ready, or that isn't healthy gets one GET (M2), and the ready-looking rows are settled by Argo CD's rule in the background, one GET each, most recently changed first (M1b), all within one budget of 60 GETs a minute, decoded by an allow-list (decision D-4).
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
  - With server-side apply the manager is `argocd-controller`. The client-side manager name is **[verify]** on the real cluster.
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
| State | `KubeMarkedHealth` mapped onto `KubeGitOpsState`: Degraded → Failed, Suspended → Paused, Progressing → Progressing, Healthy → Ready. The hover always gives Argo CD's own word ("Argo CD's rule: Degraded"), so a person comparing with Argo CD's UI can. Argo CD's Unknown (a PVC in an odd phase, an HPA's conditions saying neither) → Unknown. **`KubeGitOpsState.unknown` sorts last today** (`KubeGitOpsState.swift:7`, raw value 7) and the shared enum isn't reordered, because Applications' Unknown means "not read yet" there. Argo CD's aggregation makes Unknown the worst, so an app with one Degraded and one Unknown member is Unknown in Argo CD: here its word is Unknown too, but its **rank** is the worst *known* member's (it sorts with Failed), its why names the Degraded member first, and Hide Ready never hides it. Never Drift, Blocked or Stuck. A state settled only from cells (before M1b's or M2's GET reached the object) carries "from its row" in the hover. The Ready chip counts those apart: "878 ready (31 from rows only)". **StatefulSets and DaemonSets are never Degraded under Argo CD's built-in rules** (no progress deadline): a `0/3` StatefulSet is Progressing indefinitely, in Argo CD as here. Its why carries the duration ("0/3 ready for 2 h"), from when the row first read not-ready, so a long Progressing is visible as such. |
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
   - Open each object in its own list (↩ on a node), Copy Names, Ask Why (`a`), and Copy Argo CD Command (decision D-2).
   - The absent ones are listed by name: "Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there."
6. **The images line and the deployed commit.** `KubeDeployedCommit` already answers from an image (revision label, tag, appVersion), so "has this commit reached the cluster" works from the image. The manifests line (`gitopsRevision`) is absent, with the same sentence.

**Writes on members are unchanged and say more.** An object opened in its own list keeps every verb it has today: restart, scale, edit, delete. Today only one write path names a GitOps owner from a member's live marks: `KubeApply`'s warnings (`KubeFieldOwners.managedBy`, `KubeApply.swift:544-565`, used by `KubeManifestSession.swift:355`). `KubeGitOpsDelete` (`KubeGitOpsDelete.swift:115`) reads marks only when the object deleted is itself an Application, ApplicationSet, Kustomization or HelmRelease (its `Tool`), so it never sees a member Deployment. The delete, restart and scale sheets of a plain workload (`KubernetesPageModel+Writes`) name no owner, because a list row carries no marks.

In marks mode:

- `KubeApply`'s warning, when the live object carries a tracking id, adds: "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster";
- delete, restart and scale add the same sentence only when started from a derived app's detail (D4), which knows the object is a member. From a plain list they stay as today, because adding marks to every list's rows to say it is out of scope.

No new guard is added. The class and typed-name rules are `KubeWriteCheck`'s as today.

**Reads for the detail, only while it shows:**

- a GET of each member, capped at 4 MB each, 4 in flight and 50 members. Above 50, the rest show from their rows and that is said.
- the pods of each workload, as one list per workload by its selector, in its namespace, with rows only and up to 200.
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
| C | App name ↔ checkout name | The instance name equals the remote's repository name, or a directory segment under `apps/`, `deploy/`, `k8s/`, `charts/`, `manifests/` | Medium: with ~894 apps, short names (`api`, `worker`) collide **[survey: names shorter than 5 characters, names shared across namespaces]** | No extra read beyond B's rows | **Probably** only, when A and B found nothing, with the matched words said, never `owns` |
| D | Image repository ↔ remote | A member's image path `…/<org>/<repo>` or last segment equals the remote's `org/repo` or `repo` | Medium–low: monorepos and shared base images break it | No extra read (cells) | **Probably** only, as C, with the image said |
| E | Helm chart name or `helm.sh/chart` | The checkout's `Chart.yaml` name against members' `helm.sh/chart` label | Low: a company-wide base chart would match hundreds of apps | — | **No** |

- Only A can answer `owns`: the person bound the namespace and selector, and the workloads' own marks name the app. B answers `.describes`, said above C and D but not as `owns`. A and B are "found"; C and D are not.
- C and D are a separate, muted part: "May deploy this checkout (by name): `courier/eta` — app name equals the repository's".
- When C or D match more than 3 apps, the part says "N apps by name: too many to tell" and lists none.
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
- **With `checkout: true`,** the matches gain the state and sentence. B is said as "describes N of its objects", never "deploys this checkout"; C and D as "probably (by name)". B's list across a production cluster comes only from the cache of a person's press, as P3/P4 do today.

No new tool, and no write. `KubeAgentWrites` is unchanged.

### 14.3 When marks mode turns on, precisely

`KubeMarkedAppsMode` (pure) takes discovery (its kinds and `failedGroups`), what R1's Applications row follow said (listed across the cluster, listed only in fallback namespaces and which, refused everywhere, not yet listed, not served), and whether marks were seen. R2's summaries and their cut are not an input. It returns one of:

- `.off`: R1 listed Applications, and no mark names an app outside them. This is today's section. Also `.off` while R1's first list hasn't come, and with no discovery (a sign-in still waiting: nothing is said).
- `.beside(Coexistence)` (D1's name for the earlier `.missingFromApplications`): R1 listed Applications, and some marks name apps outside them. `Coexistence` holds the `missing` ones (said "its Application isn't in this cluster", only from a whole read), the `maybe` ones (an Application of the same name lives elsewhere: listed, never said missing), `otherInstallation` (listed, can't tell) and `unknown` (counted, not listed: their Application's namespace wasn't read). The chip from §14.2.1.
- `.only(reason)`: `reason` is `.notServed`, `.noApplications` (served, R1's whole list across the cluster has none — §14.12's development cluster, said "Argo CD's Applications for these aren't in this cluster.", never "isn't installed"), `.undiscovered` (argoproj.io failed discovery) or `.forbidden`. Derived apps are the whole Argo CD side of the section. Only `.notServed` says "Argo CD runs in another cluster".

Rules:

- Presence comes from R1's rows, which are never cut (rows only, paged at 500). R2's 500-object cut leaves some Applications unsummarised, not unseen, so it doesn't turn marks off. Unserved Flux has no bearing on it.
- **"Not in this cluster" needs a whole read.** A derived app is said "its Application isn't in this cluster" only when R1 listed Applications across the cluster and its name can't be any Application listed (below). When Applications were read namespace by namespace after a 403 (`fallbackNamespaces`, `KubeGitOpsSession.swift:353-366`), only an `<appNamespace>_<name>` mark whose namespace was read whole can be said missing. A plain name can't, because Argo CD's own namespace is unknown. The rest are counted as unknown (§14.2.1).
- **Matching an Application to marks** uses the instance name only. An Application object carries no installation id, and the local Argo CD's `installationID` is in `argocd-cm`, which is never read (gitops.md §5.2). So a mark's installation id can't be matched to a local Application: a derived app with an installation id is never said missing in coexistence. It is listed with "installation `<id>`: can't tell whether it is this cluster's Argo CD".
  - An Application's instance name is `name` when it lives in the namespace the controller's Applications mostly live in, read as the most common namespace among Applications (normally `argocd`), and `namespace_name` otherwise.
  - If that guess is wrong for an app, the app could show twice: once real and once derived. So a derived app whose name equals an Application's `name` in any namespace is not said as missing, only listed with "may be <ns>/<name>". This is false negatives over false alarms.
- **Installation id between marks:** Argo CD ignores a tracking id whose installation id doesn't match its own, so marks with different ids belong to different installations and are never merged.

### 14.4 Reads and budget

#### 14.4.1 What is read

All reads happen only while the section, a derived detail, or the rail's part is on screen. They go through the page's client and proxy slot, never a new proxy.

| Tier | What | How | Bounds |
|---|---|---|---|
| M1 | Deployments, StatefulSets, DaemonSets | Rows with metadata (`KubeListOptions(metadata: true, marks: true)`), followed. All Namespaces or one namespace: one follow a kind. Several namespaces: one follow a kind per namespace only while `3 × namespaces ≤` the watches left free. Past that, across the cluster filtered to the scope (`KubeScope.reads(for:cap:)` called with `cap: free / 3`, not the default `watchCap`). A 403 across the cluster: the context's `accessibleNamespaces`, else the scope's names, each read as a **paged list with no watch** (on show, on Refresh and every 5 min), because 3 kinds × N namespaces of watches doesn't fit. That is said: "Deployments refused across the cluster; read in a, b, c every 5 min". With no namespace to read, it says it can't list. | 3 watches on All Namespaces, one namespace, or several filtered across the cluster; 3 a namespace only while they fit in what is free (10 on a pure spoke, since Argo's 5 kinds and 3 controllers aren't followed when not served). With Flux served, 4 kinds + 1 controller + 2 spare + 3 = 10, at the cap: the marks follows take their 3 first and Flux's refused-kind fallback gets what is left, said as today. First list streamed, else paged at 500. Rows under 30 MB together. |
| M1b | The settle: the same three kinds' ready-looking rows not yet settled by Argo CD's rule | **A GET each, never a list of whole objects** (§14.12, consequence 5), decoded off the main thread by `KubeMarkedWorkloadWire`, most recently changed first (the newest `managedFields` time the row's metadata carries), **within M2's budget**: M2's moves go first, the settle takes what is left of the 60 a minute. A settled state is kept in the store with the row's `resourceVersion`, so a re-show within the store's life doesn't settle it again; a row that moves after it goes to M2. | ~1,120 workloads at ~10–20 KB, at most 60 a minute: ~20 min of the section showing to settle all, ~1.2 MB a minute at worst. The header shows "checking rollouts 400 of 1,120" until done, and every row not yet settled stays "from its row", counted on the Ready chip. Decision D-4: the owner may prefer cells only. |
| M2 | Workloads whose `metadata.generation` changed since they were last settled (a spec change: a rollout, a pause, a scale), whose cells now read not ready, or that were last settled not Healthy | A GET each, decoded by `KubeMarkedWorkloadWire` (§14.4.3) | At most 20 a flush, 4 in flight, 4 MB each, **and at most 60 a minute for the section**; past that, rows wait their turn and say "from its row". Each object at most once every 15 s; Progressing ones re-read every 60 s at most. This is narrower than `KubeGitOpsRefetch.reason`'s "cells moved": at 980 Deployments, readiness churn alone (a pod restarting, a node drained) moves cells all day, and with `inFlight` 4 the existing rule alone allows tens of GETs a second against a production API server. A move with the generation unchanged and the cells still all equal needs no GET: a stuck or paused rollout starts with a spec change, which moves the generation. A Ready row that didn't move is fetched only once, by M1b's settle. |
| M3 | Services, Ingresses, PVCs (and `ingresses.networking.k8s.io` only when served) | One paged rows-with-metadata list a kind, **no watch**. On show and on Refresh; again after 5 min while shown. | 500 a page, cut at 5,000 objects or 16 MB a kind, said. Cells only: LoadBalancer Service External-IP, Ingress Address, PVC Status. |
| M3b | CronJobs and HorizontalPodAutoscalers | Rows with metadata, M3's way (one paged list a kind, no watch, M3's timing), then **GETs through M2's budget**, decoded by `KubeMarkedWorkloadWire`: every marked CronJob, and each HPA whose Targets cell reads `<unknown>` | ~44 CronJobs and ~890 HPAs **[survey]**; GETs for the CronJobs and the `<unknown>` HPAs only. A CronJob's health needs `status.lastSuccessfulTime`, which no cell shows. An HPA's needs its conditions: Argo CD's HPA check (`FailedGetResourceMetric` and the like) turns Degraded often, and that failure shows in the cells as an `<unknown>` target, so those are read; an HPA whose targets all read is Healthy "from its row". |
| M4 | One app's detail | GETs of its members (≤ 50), its pods by selector (rows, ≤ 200 a workload) | Only while that detail shows |

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

Until a GET reaches an object, the state is "from its row" (§14.2.2). A rollout that starts while the section shows moves the generation, so M2 follows it by Argo CD's rule at once; one that started before the show is found by the settle, most recently changed first. Decision D-4 is about whether the settle ships in the floor.

#### 14.4.2 The 5-minute store and hiding

- `KubeGitOpsSession.Store` (`KubeGitOpsSession.swift:147-159`; there is no type named `KubeGitOpsStore`) gains the derived apps and the settled states (M1b, M2, M3b), each with the `resourceVersion` it was read at. It keeps them per context for 5 min while the page shows, as it keeps summaries. ↩ into a detail and back settles nothing again and reads no M3 again: M1's follows end when the section is left and start again with a list. Rows-only, they are cheap.
- `drop` clears it when the page hides, the context changes, or a credential fails.

#### 14.4.3 What a row keeps (allow-list)

**`KubeMarkWire`** is read from a row's embedded metadata in `KubeTableReader.row` when `marks` is asked. It keeps only:

- `argocd.argoproj.io/tracking-id`, `argocd.argoproj.io/installation-id`, `argocd.argoproj.io/instance`, and `app.kubernetes.io/instance`;
- `argocd.argoproj.io/hook`, `helm.sh/hook` (read as gitops-engine's `hook.IsHook`: Argo CD's annotation present, even empty, is a hook unless its only type is `Skip`, and then Helm's isn't read; Helm's is one but `crd-install`), `argocd.argoproj.io/ignore-healthcheck`, `argocd.argoproj.io/sync-wave`, `argocd.argoproj.io/sync-options` and `argocd.argoproj.io/compare-options`;
- `link.argocd.argoproj.io/*`: at most 5, detail only, each URL's userinfo dropped and credentials scrubbed at decode;
- `metadata.generation` and `deletionTimestamp`;
- from `managedFields`, only the newest `time` of Argo CD's manager — `argocd-controller` alone until §14.9.4 names the client-side one (`argocd-server` writes on a person's action in Argo CD's UI or API).

`kubectl.kubernetes.io/last-applied-configuration`, every other annotation and label (beyond today's `app.kubernetes.io/…`), `resourceVersion`, every other manager's time and `managedFields`' field sets are dropped while decoding and never kept: `KubeRow` is compared whole, so a status write (kube-controller-manager's managedFields time, a new resourceVersion) changes no row's marks and gives D2's flush nothing to filter. Every kept string is capped and loses control, format (bidi, zero-width), line/paragraph separator and private-use characters.

**`KubeMarkedWorkloadWire`** is M2's and M4's `Decodable`. It keeps:

- `spec.paused`, `spec.replicas`, `spec.updateStrategy`/`strategy.type` and `rollingUpdate.partition`;
- `metadata.generation`;
- `status.observedGeneration`, `replicas`, `updatedReplicas`, `readyReplicas` and `availableReplicas`; a DaemonSet's `desiredNumberScheduled`, `updatedNumberScheduled` and `numberAvailable`; `currentRevision` and `updateRevision`;
- `status.conditions[]` (type, status, reason, `lastTransitionTime`, and message cut to 300 characters and scrubbed);
- a CronJob's `spec.suspend`, `status.lastScheduleTime`, `lastSuccessfulTime` and the count of `status.active`;
- an HPA's `status.conditions[]` only, read at `autoscaling/v2` (so the v1 conditions annotation is never needed);
- each container's `name` and `image`.

It never keeps env, args, command, volumes, or `spec.template` beyond the images.

#### 14.4.4 Expected cost at the spoke's size

| | Estimate | Note |
|---|---|---|
| M1 rows | ~980 Deployments + ~100 StatefulSets + ~40 DaemonSets **[survey]** at ~5 KB a row with metadata (gitops.md §3.2), **~5.6 MB** | Client-side apply puts `last-applied-configuration` (the whole manifest) in the metadata, which could make a row 10–20 KB, so **up to ~20 MB**. It stays under 30 MB, and the perf leg uses 15 KB rows (§14.9.3). Per-namespace follows are no fix: on ~70 namespaces they would take 3 watches each, far past the page's 10, and the bytes are the same. If the real check finds more than 30 MB, decision D-6 applies. |
| M1 events | A rollout touches 1 Deployment (one event per status change). A shared base change can roll 500 at once. | The burst budget (500 events ranked in 3 s) already covers it |
| M1b | ~1,120 GETs at ~10–20 KB **[survey]**, at most 60 a minute (shared with M2), only while shown: ~20 min to settle all | Decoded and dropped one by one. Never a list of whole objects (§14.12, consequence 5). The list shows from rows meanwhile, problems first. |
| M2 GETs | Generation moved, not ready, or unhealthy: ~10–30 apps **[survey]** × ≤ 4 MB, usually ~10–20 KB | At most 20 a flush and 60 a minute: worst case ~1.2 MB a minute at 20 KB, while shown |
| M3 | ~1,000 Services, ~300 Ingresses, ~100 PVCs **[survey]** at ~3–15 KB, **~5–20 MB** once per 5 min while shown | No watch. Cut and said at 16 MB a kind; 1,000 Services at 15 KB would reach it, so the D7 leg records it. A cut Services list loses only LoadBalancer health (every other Service is Healthy), and says so. |
| M3b | ~44 CronJobs and ~890 HPAs **[survey]** as rows, **~1–5 MB**; GETs for the CronJobs and the `<unknown>` HPAs | No watch; the GETs within M2's budget |
| Memory kept | ~1 KB a member after the allow-list, so **~2 MB** for 2,000 members | No raw JSON kept |
| Watches | 3 of the page's 10 | Coexistence: §14.4.5 |

#### 14.4.5 Coexistence (Applications served and read)

Then the section already holds 8 watches. Derived rows are only extras for apps whose Application isn't read here, and M1 doesn't watch: it is one paged rows-with-metadata list per kind on show, on Refresh, and **every 5 min** while shown. Every 60 s would re-read ~15–20 MB a minute at the spoke's size, for rows that are the minority there. M1b settles only the derived apps' members, by GET (M2's bounds), as everywhere. The rows are ranked like M3's. The header says "marked apps read 2 min ago".

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
- The check: `KubeProxies`' oidc one-at-a-time and start timeout already apply. The section is started from `updateGitOpsReading` (`KubernetesPageModel+GitOps.swift:41-54`) with `model.discovery`, and marks mode is decided from discovery (§14.3). Discovery needs the sign-in, so with no discovery the session makes no M1, M1b, M2 or M3 request at all and the section shows the proxy's own words ("Waiting for the browser sign-in", or "Waiting for <ctx>'s sign-in in the browser to finish", `KubeProxies.swift:79-80`). There is no separate proxy-ready seam: the testable rule is "no discovery, no request", which the session test checks by calling `show` with `discovery: nil`. A sign-in that expires later stops the proxy (`KubeProxyProblem`), which `drop()`s the store as today (`KubeGitOpsSession.swift:546`), and the reads start once, not once per kind's retry, when discovery comes back.
- A section still waiting for sign-in never shows an empty sentence: no read has answered, so nothing is said about marks.

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
- requires the app part and the name to be at most 253 characters each, with only `[a-z0-9._-]` and at most one `_` in the app part;
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
| `KubeMarkedAppDetail` (pure) + `KubeMarkedAppDetailView` | new | §14.2.3; M4 |
| `openGitOps`, `gitOpsPress`, `gitOpsVerbs` | `KubernetesPageModel+GitOps.swift` (:173, :191-235, :243-276) | A derived row opens the detail (today `openGitOps` refuses a row whose `resource` isn't in the catalog). In `gitOpsPress`, a derived row's `a` (Ask Why) and `x` (its tree: the detail's) are handled before the fall-through to the page; `r`, `p`, ⌫, `s` and ⇧K stay refused because `gitOpsSelectedRef` is nil (a derived row's `resource` is empty, so `gitOpsRef` can't resolve it to a kind). `gitOpsVerbs` today returns only Open and Copy Names when the ref is nil (`:262`), so Copy Argo CD Command and Ask Why are added there for a derived row. |
| `cliLine` | `KubeGitOpsSection.swift:371-379` | For a derived row, `argocd app get <name> [--app-namespace <ns>]` without `--core` or `--kube-context` (D-2); `--app-namespace` only for an `ns_name` mark. |
| `KubeGitOpsMatch` | existing (pure) | `.markedApp(key, state)`, option A as `owns`, option B as the new `.describes(n, of:)` (never `owns`), C and D as "probably", "too many to tell" |
| `KubePanelGitOps` | existing | Marks-mode health from the rail's rows, each bound workload settled by one GET on show (said as "the N objects bound here"), or the section's store when fresh; B on Find on production; the `.unserved` text only when `argoproj.io` didn't fail discovery; a plain name's 404 in `argocd` made `.unreadable` unless Applications were seen there (§14.2.5) |
| `KubeAgentBrief.markedApp`, `KubeMCP+GitOps` | existing | §14.2.6 |
| `FakeKubeAPI+Marks` | `FakeKubeAPI+Marks.swift` | §14.9.1 |

### 14.8 Stages

**Each stage** is one commit with the main design's routine: `swift format`, `make test` and `make e2e`, and docs in the same commit (architecture.md's GitOps paragraph, analysis.md §2.23 and §10, CLAUDE.md's Kubernetes row, and this section once merged into gitops.md as §14). A stage a person sees adds a line to the unreleased version's CHANGELOG entry. Which version that is, is the owner's call.

| Stage | Commit subject | What | Tests | Done when |
|---|---|---|---|---|
| **D0** | `kubernetes: a copied Argo CD mark names nobody` | `KubeTrackingID` (parse, caps, `isSelf`); `KubeGitOpsOwner.tracking` through it; the self check where the object is known (row reader by its `kind:` argument, apply, delete warning, `KubeGitOpsWire`) | `KubeTrackingIDTests`: forms, core group, cluster-scoped, `ns_name`, malformed and over-long, control characters, installation id. `KubeGitOpsTests`: a ReplicaSet with its Deployment's mark has no owner; the existing tracking-id cases (`KubeGitOpsTests.swift:324-383`) updated where a two-part value such as `shop:anything` parsed before and is now refused. `KubeTableTests`: a Metadata row (embedded `kind: PartialObjectMetadata`) is checked against the request's kind, not the embedded one. `KubePanelGitOpsTests`: a copied mark isn't matched; an app-of-apps child Application keeps its parent. `KubeWritesTests.swift:613` and `KubeGitOpsWireTests` keep passing (their marks name the object itself). `KubeGitOpsMatchTests.swift:224` passes `kind:` to `KubeTableReader.read`, which now requires it with `owners`. | A ReplicaSet's or operator child's copied mark is never an owner anywhere. A CHANGELOG line (a person sees the rail stop naming an owner for a copied mark). |
| **D1** | `kubernetes: apps and their health from Argo CD's marks (pure)` | `KubeMarkWire`, `KubeMarkedWorkloadWire`, `KubeMarkedApps`, `KubeMarkedHealth`, `KubeMarkedAppsMode`; `KubeListOptions.marks` and the reader keeping the allow-list, unused by any list yet | Unit tests (§14.9.2), including the sentinel: a row whose last-applied, env and other annotations carry `SENTINEL` keeps none of it | Pure types done; no UI and no behaviour change. It touches `Sources/`, so the pre-commit hook needs the unreleased version's entry to exist; no line of its own. |
| **D2** | `kubernetes: GitOps reads apps from marks where Argo CD isn't` | `KubeMarkedAppsSession` (M1, M1b, M2, M3, M3b, the flush off the main thread, store, hide, the fallback, wait for sign-in); `KubeMarkedSettle`; `KubeMarksSeen` and the reader's `marksSeen` on the Overview's workload part; `FakeKubeAPI+Marks` | `KubeMarkedAppsSessionTests` against the fake: no Argo or Flux request; 3 watches, and with 6 namespaces still ≤ 3 (filtered across the cluster); no list of whole objects (every M1b request a GET of one object), never a watch; a single-replica stuck rollout whose cells read `1/1` is Progressing after its settle GET; the settle waits behind M2's moves and stays within the shared 60 a minute; a settled row isn't fetched again on a re-show; M2 only for a moved generation, not-ready cells or a last unhealthy state, never for a readiness-only move with the generation unchanged, and never more than 60 a minute under a churn of 2,000 row events; M3 and M3b have no watch; 403 falls back to paged lists in `accessibleNamespaces` and is said, with no "carries no marks" sentence; `argoproj.io` failing discovery gives `.undiscovered`, not "another cluster"; hide drops; no write; no Secret or ConfigMap request; `show` with `discovery: nil` makes no request at all; a failing `metrics.k8s.io` in `failedGroups` still gives `.notServed`; HPAs and CronJobs as rows, no watch, a GET only for CronJobs and `<unknown>`-target HPAs | The session yields ranked derived apps from the fake spoke. No UI yet: `g` still refuses, so a person sees nothing new. |
| **D3** | `kubernetes: the GitOps section shows Argo CD apps from their marks` | The section row and `g`/`:gitops`/`:argo` in marks mode; header lines and hover; rows; chips; Hide Ready; empty sentences; coexistence's chip; `is:marks`, `kind:marks`, `image:`, `G` installation; ↩ on a derived row opening a placeholder detail with the absent-verbs sentence | `KubeGitOpsSectionTests` (every row of §14.2.1's table, the unknown ones above all: `.undiscovered`'s header, Applications read only in fallback namespaces, a cut or refused M1's empty sentence, "from rows only" counted on the Ready chip; R2 cut at 500 with R1 complete still deriving the missing apps; M1 partial giving "At least N apps"; an app with only a Service read giving Unknown, not Ready; a Degraded-plus-Unknown app sorting with Failed). `KubernetesPageModel` tests: on a derived row `r`, `p`, ⌫, `s` and ⇧K do nothing and send nothing (`fake.writes` empty), `k` copies the `argocd` line without `--core`, and the verbs menu has no write. E2E `kubernetesGitOpsMarks` parts 1–3 (§14.9.3). `a` on a derived row arrives with D6. | A spoke shows its apps, problems first, with the sentence. CHANGELOG line. |
| **D4** | `kubernetes: a marked app's detail — its objects, their health, what Argo CD alone knows` | `KubeMarkedAppDetail(View)`, M4, the tree with copied marks as children, hints, the absent verbs, Copy Argo CD Command, the selfHeal sentence on members' writes | `KubeMarkedAppDetailTests`; E2E part 4 | ↩ shows the tree and per-object health; no Sync or Refresh anywhere |
| **D5** | `kubernetes: the rail says which marked app deploys the checkout, and its health` | `KubeGitOpsMatch` A+B+C+D, `KubePanelGitOps`' marks mode, Find on production, the cache key gains the mode, the plain-name 404 rule. Open goes to D3's detail (D4's once it lands); it needs D2 and D3, not D4. | `KubeGitOpsMatchTests` (B said as `.describes`, never `owns`; B exact only with a namespace; a namespace-less `Deployment/api` matching 40 apps' `api` gives "probably" in the binding's namespace only; kustomize prefix missed and said; a symlinked YAML outside the checkout not read; the 32 MB bound; C and D probably; too many to tell; nothing found says what was compared, never "not deployed"); `KubePanelGitOpsTests` (production lists only pressed; health said as "the N objects bound here" when the selector covers part of the app; a plain-name 404 in `argocd` with Applications seen only in `gitops` is unreadable, not "not in"; a bound single-replica Deployment whose cells read `1/1` but whose object is stuck is Progressing after the show's GET; `argoproj.io` in `failedGroups` gives the "couldn't tell" text, not "isn't in"); E2E `kubernetesCheckoutGitOps` part 7 | The bound checkout says its app and health on a spoke |
| **D6** | `kubernetes: agents read marked apps (k8s_gitops, Ask Why)` | `k8s_gitops` marks mode, `kind: "marks"`, `KubeAgentBrief.markedApp`, `a` | `KubeMCPGitOpsTests` (lines, bounds, scrubbing sentinel, no write; the page's fresh store used with no request; a cut read never answers "no marked apps"; `kind: "application"` excludes derived apps; no request to `argoproj.io` when not served; the opening line follows the mode's reason, "another cluster" only for `.notServed`), `KubeAgentBriefTests`; `a` on a derived row in the section, Progressing included | An agent on a spoke gets apps, not "serves neither" |
| **D7** | `kubernetes: GitOps from marks at a spoke's size` | `kubernetesGitOpsMarksPerf` beside `kubernetesGitOpsPerf`, plus whatever it finds | The perf leg (§14.9.3) | The budgets hold at 1,000 Deployments and ~900 apps. PATCH; no line if tests only. |

**D1 as built** (`kubernetes: apps and their health from Argo CD's marks (pure)`): `KubeMarkWire` and `KubeMarkedWorkloadWire` (`KubeMarkWire.swift`), `KubeMarkedKind` and `KubeMarkedHealth` (`KubeMarkedHealth.swift`), `KubeMarkedMember`, `KubeMarkedApp`, `KubeMarkedApps` and `KubeMarkedAppsMode` (`KubeMarkedApps.swift`), `KubeTrackingID.instanceLabel` (an instance label checked as the app part is), and `KubeListOptions.marks` threaded through the list, the watch decoder and the streaming list (`includeObject=Metadata` when asked) — no list asks it yet, so nothing a person sees changes. §14.12's consequences that are pure are in it: `.noApplications` (consequence 1); an Argo Rollout as a member kind, its phase its health by Argo CD's bundled check, the Deployment its `workloadRef` names — or, before the Rollout's object is read, a Deployment scaled to 0 beside a Rollout — "scaled by its Rollout", Healthy and never a cause (consequence 2); a hook (`argocd.argoproj.io/hook`, else `helm.sh/hook`) kept apart as `KubeMarkedApp.hooks`, out of health (consequence 3). Choices made where the design left room: a condition's message is bounded to 4,096, scrubbed whole as a summary's is (`KubeGitOpsMessage.scrubbed`), then cut to 300 (a credential cut in half could slip past the patterns); Argo CD's manager is `argocd-controller` alone (gitops-engine's `ArgoCDSSAManager`), never `argocd-server` (a person's action in its UI) or `kubectl-client-side-apply`, until §14.9.4 confirms the client-side name; a Rollout's row is never a verdict (its columns are counts, never its phase), only its object; an app is Unknown until a workload of its own has a health — never Ready from a Service beside a CronJob not yet read, or from the Deployment its Rollout scales; `.noApplications` only when marks were seen (a hub with no Application and no mark keeps today's section); Service, Ingress and claim verdicts are exact from their cells (the field Argo CD reads is the cell), so only workloads and HPAs say "from its row"; an app none of whose members has a rule is Ready only when no member waits to be read (a CronJob's or an `<unknown>` HPA's object), else "not read yet"; a Job (not a hook) has Argo CD's rule from its Status cell or its conditions. Consequences 4 (the rail's name match) and 6 (an expired sign-in said quickly) belong to D5 and D2.

**The floor is D0–D3 and D5:** the person's two asks, the section and the rail. D4 and D6 add depth. D7 proves the bounds. D0 stands alone and fixes a bug that exists today.

**D7 gates the release.** D3 turns marks mode on for every context with marks, the person's 980-Deployment production spoke among them, so a version holding D3 isn't released (tagged) before D7's leg passes, whatever stages ship in it. D7 can land right after D2, since it drives the session, with the parts that need D3's view added then.

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

**`kubernetesGitOpsMarksPerf`,** in `kubernetesPerf`, at 980 Deployments, 894 apps and 15 KB rows. It keeps the existing budgets:

- first draw in under 5 s;
- the main thread never held 500 ms on open or during a burst of 500 Deployment updates, which is ranked within 3 s;
- scrolling under 35 ms a step at p95 with Hide Ready off;
- M1's first list under 30 MB, recorded;
- M1b only GETs of one object (no list of whole objects), never a watch, decoded off the main thread (no 500 ms hold while it runs), within the 60 a minute shared with M2, its count, bytes and time to settle recorded;
- M2 GETs ≤ 20 a flush and ≤ 60 a minute under 2,000 readiness-only row events, which cause none;
- no watch of M3's or M3b's kinds; M3's Services' bytes recorded against the 16 MB cut; no 500 ms hold while M3 and M3b decode;
- the Overview's `marksSeen` costing no more than 5% over the pods leg's Overview time;
- no request to `argoproj.io` or `fluxcd.io`, no Secret or ConfigMap request, and no write.

**Every request is checked** against the fake's log: for each part, the set of paths the part read, so a new list can't sneak in.

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

### 14.10 Risks

| Risk | Mitigation |
|---|---|
| Rows much larger than 5 KB (client-side apply's last-applied) | The perf leg runs at 15 KB. The real check measures it. Above 30 MB, decision D-6 (per-namespace follows don't fit the watch cap and save no bytes). |
| A marked app is mistaken for a live one (deleted in the hub, marks left) | The hover says it plainly. Nothing writes on a derived app. |
| Optimism: cells show Ready for a paused Deployment, a stale generation, or a stuck single-replica rollout whose old pod serves | M1b settles every workload by Argo CD's rule in the background, one GET each within the budget; until then "from its row" is said on the state and counted on the Ready chip. M2 follows rows that move. Decision D-4. |
| A sign-in wait or a refusal shown as an answer ("no marks", "another cluster", "not in") | §14.3's rule: only a whole read says absent; `.undiscovered`, fallback-only and cut reads say what wasn't read |
| A namespace-less manifest matching many apps in the rail | B is exact only with the namespace; otherwise "probably", and only in the binding's namespace |
| The hub's custom health checks disagree with built-in rules | The second header line says "Argo CD's built-in rules applied to what is here" |
| Coexistence's instance-name guess shows an app twice | False negatives over false alarms (§14.3). A name match is never said as missing. |
| Several installations merged by mistake | Keyed by installation id, never merged |
| Name and image heuristics claim a checkout wrongly | Shown apart as "probably", with the matched words. "Too many to tell" above 3. Never `owns`, never a verb. |
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
| D-6 | The real spoke's M1 rows are past 30 MB (client-side apply's `last-applied-configuration` on large Deployments) | **Settled by the survey: keep the 30 MB bound**; the D7 leg records the real size | The survey (§14.12) measured the whole Deployment list as JSON at ~16 MB; rows-only is smaller. Per-namespace follows don't fit the 10-watch cap at ~70 namespaces and read the same bytes. |
| D-7 | How an Unknown app with a Degraded member ranks | **Word Unknown (Argo CD's), rank with Failed, why names the Degraded member** | `KubeGitOpsState.unknown` sorts last and is shared with Applications, where it means "not read yet"; reordering it would move every Application. Showing Failed instead would differ from Argo CD's UI. |
| D-8 | Whether manifest identity (option B) may say `owns` | **No: `.describes N of its objects`**, above C and D | Identity isn't provenance (forks, copies, app repo beside a config repo). Only the binding (A) owns. |
| D-9 | The Overview's GitOps line on a spoke | **Unchanged in this addendum**: it stays K601–K603, so a spoke's Overview says nothing about derived apps | The Overview already reads workloads with metadata (`KubeClusterOverviewSession.swift:130-133`) and could count failing derived apps, but that is a new Overview read path and a new finding. It is a later stage if the owner wants it. |
| D-10 | When D7's perf leg must pass | **Before the version holding D3 is released**, landing right after D2 if possible | D3 turns marks mode on for the person's 980-Deployment production spoke. |

### 14.12 Survey facts (2026-11-14)

A read-only look at the spoke's production and development clusters (prod and dev below). These replace every [survey] estimate above, and the consequences at the end override anything earlier in §14.

Read with get, api-resources and auth can-i only, an explicit `--context`, no Secret or ConfigMap.

| | prod | dev |
|---|---|---|
| Kubernetes | 1.33 (EKS) | 1.36 (EKS) |
| applications.argoproj.io served | **no** | **yes, but 0 Applications** (Argo Workflows/Rollouts CRDs present; Argo CD's apps live elsewhere) |
| Rollouts CRD | served; 117 Rollouts, 115 marked, **all 115 with spec.workloadRef**; phases Healthy 112, Degraded 2, Paused 1 | served; 31, 29 marked, all workloadRef; Healthy 27, Degraded 1, Progressing 1 |
| Deployments | 1161, 980 marked, **207 scaled to 0** (the Rollouts' referenced Deployments), 23 unavailable, 21 progress-stalled | 1208, 997 marked, 111 scaled to 0, 28 unavailable, 17 stalled |
| distinct apps (from Deployments) | 894 | 905 |
| tracking-id format | always `app:group/kind:ns/name`; no `_` (no apps-in-any-namespace); every app in one namespace | same |
| self-reference | 99.9% self; copied marks only on a few HPAs, PDBs, Roles/RoleBindings | same |
| other marked kinds | Services 1004, HPAs 893 (of 1137), SAs 336, Ingresses 95 (one shared app holds 94), CronJobs 44, Jobs 8 (hooks), PVCs 8, StatefulSets 3, DaemonSets 8 | similar; Jobs 45 (41 Argo hooks) |
| app name vs objects | app name **never** equals the Deployment's name or its `app` label: `<env>-<ns>-<name>-service` (504), `<env>-<ns>-<name>` (258), `<env>-<name>` (40)… | |
| full Deployment list, JSON | 16.3 MB in 2.5 s | 16.9 MB in 2.6 s |
| sign-in | kubectl oidc-login exec plugin; an expired session blocks for minutes waiting for a browser | same |

Consequences for the design (taken as decisions, within the scope the person chose):
1. **Derived mode's trigger is "no Application deploys these", not "CRD not served".** dev serves the CRD with zero Applications and 0 of its 905 marked app names exist as Applications. Rule: derive when Applications are not served, or are served but none is listed (R1's row follow, complete, says 0), or the marked app names are absent from a complete Application list. Wording: prod → "Argo CD runs in another cluster — not in your kubeconfig."; dev → "Argo CD's Applications for these aren't in this cluster." (never "Argo CD isn't installed").
2. **Rollouts are read for health only — no Rollout feature.** A marked Rollout with `workloadRef` is the app's workload: its row (metadata + status.phase, via the Table/rows path, same budget as Deployments) gives the app's health (Healthy/Degraded/Paused/Progressing map onto ours as Argo CD's own Rollout health check does). The Deployment it references, scaled to 0 by the Rollouts controller, is shown as "scaled by its Rollout", never as a problem or "scaled to zero". Without this, 115 prod apps would read as scaled down. No Rollout verbs, no Rollout page — said in the detail ("promote/abort are Argo Rollouts' — not here").
3. **Argo hook Jobs** (annotation `argocd.argoproj.io/hook`) are not members for health (Argo CD leaves hooks out of app health); shown under the app as hooks.
4. **Rail matching**: since names never match workloads directly, option C (app name) must strip `<env>-<ns>-` and an optional `-service` before comparing with the checkout's name or its manifests' names — still "probably". Option B (the checkout's committed YAML identities vs the tracking-id tail `ns/name`) stays the exact one.
5. **Budget**: ~2,000 marked workloads + Rollouts per cluster; rows-only reads, never full JSON (16 MB). Problems-first is non-empty in practice (≈45 Deployments + 3 Rollouts).
6. **Expired OIDC session**: a context whose exec plugin waits for a browser must say "Sign-in needed — run `kubectl --context X get ns` once in a terminal" after a short wait, not "unreachable" after minutes. Check KubeProxies' oidc handling; add a test with a stand-in exec plugin that sleeps.
