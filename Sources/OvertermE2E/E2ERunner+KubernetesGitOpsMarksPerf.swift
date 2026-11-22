#if E2E
import AppKit
import Foundation

/// D7 (docs/design/kubernetes/gitops.md, 14.9.3, 14.12): `kubernetesPerf`'s
/// leg of Argo CD's apps read from their marks, on a spoke at the surveyed
/// production cluster's size (`FakeKubeAPI.addSurveySpoke`: 980 marked
/// Deployments of 1,161 — 207 scaled to 0, 115 of them run by an Argo
/// Rollout by `workloadRef` —, 906 apps, 1,006 Services, 893 marked HPAs,
/// a few copied marks, rows of about 15 KB) on a fake of its own that
/// `fake-prod` — production by name — reaches, never a real cluster:
///
/// - the Overview reads its workloads and sees a mark: what `marksSeen`
///   adds to it timed against the pods leg's Overview (at most 5%); what
///   the switch and the Overview read a closed set;
/// - `g`: first drawn with every app's row in under 5 s, the main thread
///   never held 500 ms; M1 the four workload kinds' rows followed, one
///   streaming list each, their first lists under 30 MB, recorded; M3
///   paged rows, never watched, the Services' bytes recorded against the
///   16 MB cut; the six copied marks on HPAs counted, nobody's member;
/// - the settle (M1b): GETs of one object only, the minute's 60 at most,
///   20 a flush and 4 in flight, decoded off the main thread, once every
///   first list is in — what may be a problem first: what was just synced
///   under cells that read ready (single replicas stuck or past their
///   deadline behind the old pod, a paused rollout) said by Argo CD's rule
///   in that minute; its count, bytes and time to settle recorded; the
///   sentinel in nothing the section keeps or draws, before and after;
/// - a burst of 500 Deployment events (450 status writes that move
///   nothing kept, 50 rollouts begun) ranked within 3 s, the main thread
///   never held 500 ms; the 50 waiting as M2's moves;
/// - 2,000 readiness-only row events, on what the first minute settled
///   and on ready rows not yet settled: none asked as a move;
/// - the table scrolled with Hide Ready off, under 35 ms a step (p95);
/// - the next minute: M2's 50 read first, the only moves taken;
/// - the page closed and opened again within the minute: what the section
///   read goes, the context's minute doesn't — only the places freed since
///   taken, never a fresh 60;
/// - another section ends every follow, back to `g` lists no Service,
///   Ingress, claim, Job, CronJob or HPA again — on a server refusing a
///   streaming list, the Deployments' rows in pages of 500; never more
///   than 60 object GETs in any minute from `g` on (the fake's own times);
/// - an agent's `k8s_gitops` with no section's apps kept: its own read at
///   its bounds, the Deployments' rows against its 16 MB cut, recorded,
///   its count exact only from a whole read, at most 20 GETs;
/// - throughout, nothing forgotten from the fake's log: GETs only, nothing
///   of Argo CD's own kinds or Flux's, no Secret or ConfigMap, never a
///   ReplicaSet, a whole-object watch or a list of whole objects, every
///   list of a marks kind rows with their metadata; nothing written.
extension E2ERunner {
    package func kubernetesGitOpsMarksPerf(_ model: KubernetesModel, _ page: KubernetesPageModel, spoke fake: FakeKubeAPI, podsOverview: Double) async {
        // Its holds are measured over a minute and more, much of it idle
        // while the settle waits its minute: awake, never napped (an
        // isolated run's window is behind the person's, and a napped app's
        // timers wake seconds late).
        let fullSpeed = Self.measuredAtFullSpeed()
        defer { ProcessInfo.processInfo.endActivity(fullSpeed) }
        let footprint = Self.footprintMB()
        fake.tableManagedFields = true
        let building = CACurrentMediaTime()
        let made = fake.addSurveySpoke()
        let deployments = made.made["deployments.apps"] ?? 0
        note(
            "kubernetes marks: the surveyed spoke made in \(Int((CACurrentMediaTime() - building) * 1000)) ms — \(made.apps.count) apps, "
                + made.marked.sorted { $0.key < $1.key }.map { "\($0.value) of \(made.made[$0.key] ?? 0) \($0.key)" }.joined(separator: ", ") + " marked")
        check(
            "the survey's size: 980 marked Deployments of 1,161, 115 Rollouts, ~1,000 Services, 893 marked HPAs, ~900 apps",
            made.marked["deployments.apps"] == 980 && deployments == 1161 && made.marked["rollouts.argoproj.io"] == 115 && (made.made["services"] ?? 0) >= 1000
                && made.marked["horizontalpodautoscalers.autoscaling"] == 893 && (900...910).contains(made.apps.count),
            "\(made.marked) of \(made.made), \(made.apps.count) apps")
        let before = (context: model.selectedName, scope: model.scope)
        model.select("fake-prod")
        model.setScope(.all)
        func served() -> Set<String> { Set(model.discovery?.kinds.map(\.fullName) ?? []) }
        let spoke = await eventually(15) { model.selectedName == "fake-prod" && served().contains("rollouts.argoproj.io") && !served().contains("applications.argoproj.io") }
        check(
            "fake-prod is the spoke: no Argo CD Application or Flux kind served, Argo Rollouts are", spoke && !served().contains { $0.hasSuffix("fluxcd.io") },
            "\(served().filter { $0.contains("argoproj") || $0.contains("fluxcd") }.sorted())")
        guard spoke, let discovery = model.discovery, let deployment = discovery.kinds.first(where: { $0.fullName == "deployments.apps" }) else {
            return restore(model, before)
        }
        page.showKind(.pods)
        _ = await eventually(15) { model.listState == .live }

        // The Overview: its workloads read with their metadata, a mark seen.
        let overview = page.clusterOverview
        let opened = CACurrentMediaTime()
        check("1 is the spoke's Overview", page.press("1") && page.section == .overview)
        let read = await eventually(30) { overview.state == .live && overview.overview.workloads.first { $0.resource == "deployments.apps" }?.total == deployments }
        let overviewTime = (CACurrentMediaTime() - opened) * 1000
        check("its Overview reads every Deployment", read, "\(overview.state) \(overview.overview.workloads.map { "\($0.resource) \($0.total)" })")
        check("and sees Argo CD's marks", model.marksSeen.contains("fake-prod"), "\(model.marksSeen)")
        check("the GitOps row shows", page.gitOpsListed)
        page.showKind(.pods)
        check("the Overview's follows end", await eventually(10) { overview.state == .idle }, "\(overview.state)")
        if let client = model.client(for: "fake-prod"), let cost = await marksSeenCost(client, deployment) {
            let share = cost.marks / max(podsOverview, 1) * 100
            note(
                String(
                    format:
                        "kubernetes marks: the spoke's Overview read in %d ms; marksSeen's look-ups over its %d Deployments' rows %.3f ms — %.4f%% of reading them (%.1f ms), %.4f%% of the pods leg's Overview (%d ms)",
                    Int(overviewTime), cost.rows, cost.marks, cost.marks / max(cost.read, 0.001) * 100, cost.read, share, Int(podsOverview)))
            check(
                "the Overview's marksSeen costs at most 5% over the pods leg's Overview time", cost.rows == deployments && share <= 5, String(format: "%.3f ms of %d ms", cost.marks, Int(podsOverview))
            )
            check("and at most 5% of reading the rows it looks in", cost.marks <= cost.read * 0.05, String(format: "%.3f of %.1f ms", cost.marks, cost.read))
        } else {
            check("the Deployments' rows read for marksSeen's cost", false)
        }
        // Everything before `g`: the switch, the pods, the Overview, marksSeen's list — a closed set.
        checkMarksPerfOpening(fake.requests, discovery: discovery)

        await marksPerfSection(model, page, fake, made: made, discovery: discovery)

        page.showKind(.pods)
        check("closed, the marks' follows end", await eventually(10) { page.gitOps.marked.openFollows == 0 && fake.watched.allSatisfy { !Self.marksWorkloads.contains($0) } }, "\(fake.watched)")
        // The fake's whole log, nothing forgotten since the spoke was made.
        let requests = fake.requests
        check("every request a GET", requests.allSatisfy { $0.method == "GET" }, "\(requests.filter { $0.method != "GET" }.map(\.description).prefix(5))")
        check("nothing written", fake.writes.isEmpty)
        check("nothing of Argo CD's own or Flux's asked", !requests.contains(where: Self.isArgoCDOrFlux))
        check("never a Secret or a ConfigMap", !requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
        note(String(format: "kubernetes marks: the app's footprint %.0f MB before the spoke, %.0f MB after its leg", footprint, Self.footprintMB()))
        restore(model, before)
    }

    /// The context and scope the perf scenario had before the leg; the
    /// spoke's refused streaming list (learned by `marksPerfBack`) forgotten.
    private func restore(_ model: KubernetesModel, _ before: (context: String?, scope: KubeScope)) {
        model.streamingLists.forget("fake-prod")
        if let context = before.context { model.select(context) }
        model.setScope(before.scope)
    }

    /// Argo CD's own kinds or Flux's: never asked where they aren't served
    /// (`argoproj.io` serves Argo Rollouts here, read for health only).
    package static func isArgoCDOrFlux(_ request: FakeKubeAPI.Request) -> Bool {
        request.path.contains("/applications") || request.path.contains("/applicationsets") || request.path.contains("/appprojects") || request.path.contains("fluxcd.io")
    }

    /// What the switch to the spoke, its pods, its Overview and marksSeen's
    /// look read (14.9.3: every part's paths a closed set): discovery, the
    /// Overview's parts and its health checks' lists (`KubeHealth.reads`
    /// the spoke serves — whole objects, kept by their own allow-list), the
    /// page's own — pods, usage, namespaces, CRDs, nodes —, Deployments'
    /// rows for marksSeen; GETs only, nothing of Argo CD's or Flux's, never
    /// a Secret or a ConfigMap; the Overview's workload follows, where
    /// `marksSeen` looks, rows with their metadata.
    private func checkMarksPerfOpening(_ requests: [FakeKubeAPI.Request], discovery: KubeDiscovery) {
        let parts = Set(KubeClusterOverviewSession.parts(discovery).map { $0.1.path(namespace: nil) })
        let health = Set(
            KubeHealth.reads.compactMap { read in discovery.kinds.first { $0.group == read.group && $0.resource == read.resource }?.path(namespace: nil) })
        let page: Set<String> = [
            "/api/v1/pods", "/api/v1/namespaces", "/api/v1/nodes", "/apis/apiextensions.k8s.io/v1/customresourcedefinitions",
        ]
        let strays = requests.filter { request in
            !request.isDiscovery && !parts.contains(request.path) && !health.contains(request.path) && !page.contains(request.path)
                && !request.path.hasPrefix("/apis/metrics.k8s.io/") && !(request.path.hasPrefix("/api/v1/namespaces/") && request.path.hasSuffix("/pods"))
        }
        note("kubernetes marks: before g \(requests.count) requests, \(Set(requests.filter { !$0.isDiscovery }.map(\.path)).count) paths")
        check("before g: nothing read but the Overview's parts and health checks and the page's own", strays.isEmpty, "\(Set(strays.map(\.path)).sorted().prefix(8))")
        check("before g: GETs only, nothing written", requests.allSatisfy { $0.method == "GET" }, "\(requests.filter { $0.method != "GET" }.map(\.description).prefix(5))")
        check("before g: nothing of Argo CD's own or Flux's", !requests.contains(where: Self.isArgoCDOrFlux))
        check("before g: never a Secret or a ConfigMap", !requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
        let workloads = Set(
            KubeClusterOverviewSession.workloadKinds.compactMap { name in discovery.kinds.first { $0.fullName == name }?.path(namespace: nil) })
        let follows = requests.filter { $0.isWatch && workloads.contains($0.path) }
        check(
            "before g: the Overview's workload follows, where marksSeen looks, rows with their metadata",
            !follows.isEmpty && follows.allSatisfy { $0.accept.contains("as=Table") && $0.query["includeObject"] == "Metadata" },
            "\(follows.map { "\($0.path)?\($0.query)" }.prefix(5))")
    }

    /// `g` on the spoke, the settle's first minute, the burst, the churn,
    /// the scroll, the next minute, the page closed and opened again, the
    /// section left and shown again; an agent's read.
    private func marksPerfSection(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, discovery: KubeDiscovery) async {
        let gitOps = page.gitOps
        let marked = gitOps.marked
        let kinds = KubeMarkedAppsSession.kinds(discovery)
        let rowLists = Set(kinds.rows.map { "rows:\($0.fullName)" })
        // From here on: the fake's log is never forgotten, each part's reads its slice.
        let start = fake.requests.count
        fake.forgetBytes()

        // The first draw: `g` until every app's row is there, M3's lists in, the table drawn.
        let stall = MainThreadStall()
        stall.start()
        let opened = CACurrentMediaTime()
        check("g shows GitOps", page.press("g") && page.section == .gitops)
        let live = await eventually(30) {
            gitOps.marksMode == .only(.notServed) && marked.state == .live && marked.isMerged && rowLists.isSubset(of: marked.store?.done ?? [])
                && gitOps.rows.shown.count == made.apps.count
        }
        var table: NSTableView?
        let drawn = await eventually(15) {
            table = self.gitOpsTable()
            return (table?.numberOfRows ?? 0) == page.gitOpsVisibleRows.count && (table?.numberOfRows ?? 0) > 0
        }
        app.kubernetesView?.displayIfNeeded()
        let firstDraw = (CACurrentMediaTime() - opened) * 1000
        let openStall = stall.stop()
        check("every app's row, M3's lists in", live, "\(gitOps.marksMode) \(marked.state) \(gitOps.rows.shown.count) of \(made.apps.count) rows, \(marked.store?.done.sorted() ?? [])")
        check("the apps the marks make", Set(gitOps.rows.shown.compactMap { $0.marked?.key.instance }) == made.apps)
        check("the table drawn", drawn, "\(table?.numberOfRows ?? -1) of \(page.gitOpsVisibleRows.count)")
        note("kubernetes marks: first draw of \(made.apps.count) apps from \(made.marked.values.reduce(0, +)) marked objects: \(Int(firstDraw)) ms, the main thread held at most \(Int(openStall)) ms")
        check("first drawn in under 5 s", firstDraw < 5000, "\(Int(firstDraw)) ms")
        check("the main thread never held 500 ms", openStall < 500, "\(Int(openStall)) ms")
        check("Hide Ready, past 50 rows", page.gitOpsHidesReady && page.gitOpsVisibleRows.count < made.apps.count, "\(page.gitOpsVisibleRows.count) shown")
        // As §14.12 says them, at the survey's size: what is scaled to 0 is
        // no problem — a Rollout's Deployment scaled by its Rollout —; not
        // ready by their rows, never Ready; the Ingresses alone Unknown.
        func row(_ app: String) -> KubeGitOpsRow? { gitOps.rows.shown.first { $0.marked?.key.instance == app } }
        check("no app said scaled to 0", !gitOps.rows.shown.contains { $0.why.contains("scaled to 0") })
        check("each Rollout's Deployment scaled by its Rollout", made.rolloutApps.allSatisfy { row($0)?.hover.contains("scaled by its Rollout") == true })
        let hidden = Set(made.hidden.map(\.app))
        let visible = made.stalled.map(\.app).filter { !hidden.contains($0) } + made.unavailable
        check("past their deadline or not every replica available by their rows: never Ready", visible.allSatisfy { [.progressing, .failed].contains(row($0)?.state) })
        check("the Ingresses alone Unknown", row(made.ingressOnly)?.state == .unknown, row(made.ingressOnly)?.why ?? "none")
        // The copies on six HPAs (14.12: "copied marks only on a few") name their Deployment's app: nobody's member, counted.
        let extras = marked.apps.flatMap { $0.app.members.filter { $0.id.kind == .horizontalPodAutoscaler && $0.id.name.hasSuffix("-extra") } }
        let copies = marked.apps.flatMap { $0.app.copies.filter { $0.id.name.hasSuffix("-extra") } }
        check(
            "the six copied marks on HPAs counted, nobody's member, shown under their Deployment's app", marked.tally.copied == 6 && extras.isEmpty && copies.count == 6,
            "\(marked.tally.copied) copied, \(extras.count) members, \(copies.count) under apps")
        await marksPerfNoSentinel("first drawn", page)

        // M1's first lists: the four workload kinds' rows, a streaming list each across the cluster.
        let workloadPaths = ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets", "/apis/argoproj.io/v1alpha1/rollouts"]
        let opening = Array(fake.requests.dropFirst(start))
        for path in workloadPaths {
            let asked = opening.filter { $0.path == path }
            check(
                "\(path): followed once, its first list streamed, rows with their metadata",
                asked.filter(\.isWatch).count == 1 && asked.contains { $0.query["sendInitialEvents"] == "true" } && !asked.contains { !$0.isWatch }
                    && asked.allSatisfy { $0.query["includeObject"] == "Metadata" && $0.accept.contains("as=Table") }, "\(asked.map(\.query))")
        }
        let m1 = Self.marksWorkloads.map { fake.bytesSent($0) - fake.bytesSent($0, table: false) }.reduce(0, +)
        let m1Deployments = fake.bytesSent("deployments.apps") - fake.bytesSent("deployments.apps", table: false)
        note("kubernetes marks M1: first lists \(m1 / 1024) KB, the Deployments' \(m1Deployments / 1024) KB (\(m1Deployments / max(made.made["deployments.apps"] ?? 1, 1)) bytes a row)")
        check("M1's first lists under 30 MB (D-6)", m1 < 30 << 20, "\(m1) bytes")
        // M3: paged rows with their metadata, never watched.
        for kind in kinds.rows {
            let path = kind.path(namespace: nil)
            let asked = opening.filter { $0.path == path }
            check(
                "\(path): listed by pages of rows with their metadata, never watched",
                !asked.isEmpty && asked.allSatisfy { !$0.isWatch && $0.query["includeObject"] == "Metadata" && $0.accept.contains("as=Table") && $0.query["limit"] == "500" },
                "\(asked.map(\.query))")
        }
        let services = fake.bytesSent("services", table: true)
        let m3 = kinds.rows.map { fake.bytesSent($0.fullName, table: true) }.reduce(0, +)
        note("kubernetes marks M3: \(m3 / 1024) KB of rows, the Services' \(services / 1024) KB for \(made.made["services"] ?? 0) (the cut is 16 MB a kind)")
        check("the Services' rows within the 16 MB cut, none cut", services < marked.bounds.rowsBytes && marked.store?.notes.isEmpty == true, "\(services) bytes, \(marked.store?.notes ?? [:])")
        check(
            "never a ReplicaSet, nor a whole object watched or listed",
            !opening.contains { request in
                request.path.contains("/replicasets") || (request.isWatch && request.query["includeObject"] == "Object")
                    || (!request.isDiscovery && !request.accept.contains("as=Table") && !Self.isObjectRead(request) && Self.marksKinds.contains(Self.resource(of: request.path) ?? ""))
            })

        await marksPerfSettle(page, fake, made: made, start: start)
        let moves = marked.taken(as: .moved)
        let rolling = await marksPerfBurst(page, fake, made: made, start: start)
        await marksPerfChurn(page, fake, made: made, rolling: rolling)
        await gitOpsScroll(rows: made.apps.count, label: "kubernetes marks")
        await marksPerfNextMinute(page, fake, rolling: rolling, start: start, moves: moves)
        checkMarksPerfReads("the section shown", Array(fake.requests.dropFirst(start)), kinds: kinds)
        await marksPerfReopen(page, fake, made: made, kinds: kinds)
        await marksPerfBack(model, page, fake, made: made, kinds: kinds)
        // The section's GETs from `g` on, its every part — closed and opened
        // again, left and shown again — never more than 60 in any minute.
        let gets = fake.timedRequests.dropFirst(start).filter { Self.isObjectRead($0.request) }
        let most = Self.mostInAMinute(gets.map(\.at))
        note("kubernetes marks: \(gets.count) object GETs from g on, at most \(most) in any minute at the fake")
        check("from g on, never more than 60 object GETs in any minute", most <= KubeMarkedRefetch.perMinute, "\(most)")
        await marksPerfAgent(model, page, fake, made: made, discovery: discovery)
    }

    /// The most of `times` within any minute.
    package static func mostInAMinute(_ times: [Date]) -> Int {
        let sorted = times.sorted()
        var most = 0
        var start = 0
        for end in sorted.indices {
            while sorted[end].timeIntervalSince(sorted[start]) >= 60 { start += 1 }
            most = max(most, end - start + 1)
        }
        return most
    }

    /// What a part read (14.9.3: "for each part, the set of paths the part
    /// read"): M1's four workload kinds' rows, M3's lists, GETs of one
    /// object of a kind settled by it, and the page's own — its list under
    /// the section (pods) and their usage, the namespaces for its picker,
    /// the CRDs whose changes read discovery again —; nothing else. Every
    /// list or watch of a marks kind rows with their metadata, none of M3's
    /// kinds watched.
    private func checkMarksPerfReads(_ part: String, _ requests: [FakeKubeAPI.Request], kinds: (workloads: [KubeResourceKind], rows: [KubeResourceKind])) {
        let lists = Set((kinds.workloads + kinds.rows).map { $0.path(namespace: nil) })
        let page: Set<String> = [
            "/api/v1/pods", "/apis/metrics.k8s.io/v1beta1/pods", "/api/v1/namespaces", "/apis/apiextensions.k8s.io/v1/customresourcedefinitions",
        ]
        let strays = requests.filter { request in
            !request.isDiscovery && !lists.contains(request.path) && !page.contains(request.path)
                && !(Self.isObjectRead(request) && Self.settledKinds.contains(Self.resource(of: request.path) ?? ""))
        }
        check("\(part): nothing read but the marks' rows, their objects one by one and the page's own", strays.isEmpty, "\(Set(strays.map(\.path)).sorted().prefix(8))")
        let marksLists = requests.filter { !$0.isDiscovery && !Self.isObjectRead($0) && Self.marksKinds.contains(Self.resource(of: $0.path) ?? "") }
        let whole = marksLists.filter { !$0.accept.contains("as=Table") || $0.query["includeObject"] != "Metadata" }
        check("\(part): every list or watch of a marks kind rows with their metadata", whole.isEmpty, "\(whole.map { "\($0.path)?\($0.query)" }.prefix(5))")
        let m3 = Set(kinds.rows.map(\.resource))
        let watched = requests.filter { request in request.isWatch && m3.contains(Self.resource(of: request.path) ?? "") }
        check("\(part): no Service, Ingress, claim, Job, CronJob or HPA watched", watched.isEmpty, "\(watched.map(\.path).prefix(5))")
    }

    /// Nothing the section keeps or draws carries what the allow-lists drop
    /// (the sentinel in kubectl's last-applied copy on every marked
    /// Deployment's row, in their objects' env and args, in the Secret's and
    /// the ConfigMap's data): its apps, what was settled, its rows' why and
    /// hover, its header — looked through off the main thread.
    private func marksPerfNoSentinel(_ when: String, _ page: KubernetesPageModel) async {
        let gitOps = page.gitOps
        let marked = gitOps.marked
        let lines = KubeMarkedSection.lines(
            mode: gitOps.marksMode, context: "fake-prod", apps: marked.apps.map(\.app), reading: marked.reading, tally: marked.tally, kinds: [],
            unread: gitOps.rows.besideUnread)
        let said = KubeMarkedSection.header(apps: marked.apps.count, reading: marked.reading, readAt: marked.readAt, now: Date(), probable: marked.probable)
        let header = [lines.lead, lines.limits, lines.hover, lines.installations, lines.unread, said].compactMap { $0 } + marked.reading.said
        let rows = gitOps.rows.shown.flatMap { [$0.why, $0.hover] }
        let apps = marked.apps
        let settled = Array((marked.store?.settled ?? [:]).values)
        let sentinel = FakeKubeAPI.gitOpsSentinel
        let found = await Task.detached(priority: .userInitiated) { () -> [String] in
            var found: [String] = []
            if header.contains(where: { $0.contains(sentinel) }) { found.append("the header") }
            if rows.contains(where: { $0.contains(sentinel) }) { found.append("a row's why or hover") }
            if String(describing: settled).contains(sentinel) { found.append("what was settled") }
            if String(describing: apps).contains(sentinel) { found.append("the apps") }
            return found
        }.value
        check("\(when): the sentinel in nothing the section keeps or draws (\(settled.count) objects settled)", found.isEmpty, "\(found)")
    }

    /// The settle's first minute: GETs of one object, 60 at most, what may be a problem first.
    private func marksPerfSettle(_ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, start: Int) async {
        let marked = page.gitOps.marked
        let stall = MainThreadStall()
        stall.start()
        let minute = await eventually(30) { marked.takenLastMinute == KubeMarkedRefetch.perMinute && marked.getsQueued == 0 }
        let held = stall.stop()
        let gets = fake.timedRequests.dropFirst(start).filter { Self.isObjectRead($0.request) }
        check("the settle took the minute's 60, each answered", minute && gets.count == KubeMarkedRefetch.perMinute, "\(marked.takenLastMinute) taken, \(gets.count) GETs")
        check("each a GET of one object of a kind settled by it", gets.allSatisfy { Self.settledKinds.contains(Self.resource(of: $0.request.path) ?? "") }, "\(gets.map(\.request.path).prefix(5))")
        check("each object once", Set(gets.map(\.request.path)).count == gets.count)
        check(
            "at most 20 a flush, 4 in flight", marked.mostTaken <= KubeMarkedRefetch.perFlush && marked.mostInFlight <= KubeMarkedAppsSession.inFlight,
            "\(marked.mostTaken) a flush, \(marked.mostInFlight) in flight")
        check("decoded off the main thread: never held 500 ms", held < 500, "\(Int(held)) ms")
        // What may be a problem first: the ≈210 whose rows can't say Healthy or that were just synced, before any other.
        let first = Set(gets.map(\.request.path))
        check(
            "what may be a problem first: all 60 not Healthy by their rows, what no cell says, or just synced (of \(made.doubtful.count))", first.isSubset(of: made.doubtful),
            "\(first.subtracting(made.doubtful).sorted().prefix(5))")
        let bytes = Self.settledResources.map { fake.bytesSent($0, table: false) }.reduce(0, +)
        let span = (gets.last?.at.timeIntervalSince(gets.first?.at ?? Date()) ?? 0) * 1000
        let checking = marked.reading.checking ?? 0
        note(
            "kubernetes marks M1b: the settle's first minute \(gets.count) GETs, \(bytes / 1024) KB (\(bytes / max(gets.count, 1) / 1024) KB each) in \(Int(span)) ms; "
                + "\(checking) to settle (\(made.fetched) the fixture's), at 60 a minute all in about \(Int((Double(checking) / 60).rounded(.up))) min of the section showing")
        check("the settle's progress said", marked.reading.said.contains { $0.hasPrefix("checking rollouts \(gets.count.formatted()) of ") }, "\(marked.reading.said)")
        check("each of the settle's objects to read", checking == made.fetched, "\(checking) of \(made.fetched)")
        // Read in that minute, each said by Argo CD's rule: past the deadline Failed, the just synced under cells that read ready too.
        let gitOps = page.gitOps
        func row(_ app: String) -> KubeGitOpsRow? { gitOps.rows.shown.first { $0.marked?.key.instance == app } }
        let read = made.stalled.filter { first.contains("/apis/apps/v1/namespaces/\($0.namespace)/deployments/\($0.name)") }.map(\.app)
        let failed = await eventually(10) { marked.isMerged && read.allSatisfy { row($0)?.state == .failed } }
        check("each rollout past its deadline read in the first minute Failed by Argo CD's rule (\(read.count) of \(made.stalled.count))", !read.isEmpty && failed)
        // Just synced under cells that read ready: each Deployment read by its
        // object in that minute, its app said by Argo CD's rule (another
        // member not read yet — a CronJob's last run — leaves the app "from
        // rows", never its Deployment's state).
        let hiddenApps = Set(made.hidden.map(\.app))
        let stalledHidden = made.stalled.map(\.app).filter { hiddenApps.contains($0) }
        let expected: [String: KubeGitOpsState] = Dictionary(
            uniqueKeysWithValues: stalledHidden.map { ($0, .failed) } + [(made.stuck[0], .failed), (made.stuck[1], .progressing), (made.paused, .paused)])
        let ids = made.hidden.map { KubeMarkedMember.ID(kind: .deployment, namespace: $0.namespace, name: $0.name) }
        let said = await eventually(10) { marked.isMerged && ids.allSatisfy { marked.store?.settled[$0] != nil } && expected.allSatisfy { row($0.key)?.state == $0.value } }
        check(
            "just synced under cells that read ready — single replicas past their deadline or stuck behind the old pod, a paused rollout —: each read in the first minute, said by Argo CD's rule",
            said && expected.count == made.hidden.count,
            "\(made.hidden.map { "\($0.name) \(marked.store?.settled[KubeMarkedMember.ID(kind: .deployment, namespace: $0.namespace, name: $0.name)] == nil ? "unread" : "read") \(row($0.app)?.state.word ?? "none")" })"
        )
        await marksPerfNoSentinel("the first minute settled", page)
    }

    /// 500 Deployment events: 450 status writes that move nothing kept, 50
    /// rollouts begun (their generation moved). Ranked within 3 s; the 50
    /// wait as M2's moves (the minute's 60 are the settle's).
    private func marksPerfBurst(_ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, start: Int) async -> [(namespace: String, name: String, app: String)] {
        let gitOps = page.gitOps
        let marked = gitOps.marked
        let ready = Set(gitOps.rows.shown.filter { $0.state == .ready }.compactMap { $0.marked?.key.instance })
        let picked = made.ready.filter { ready.contains($0.app) }
        let rolling = Array(picked.prefix(50))
        let touched = Array(picked.dropFirst(50).prefix(450))
        check("the burst's 500 picked", rolling.count == 50 && touched.count == 450, "\(rolling.count) + \(touched.count)")
        let rowsBefore = marked.rowsChanged
        let stall = MainThreadStall()
        stall.start()
        let started = CACurrentMediaTime()
        let sending = Task.detached {
            for (namespace, name, _) in touched {
                fake.modify("deployments.apps", name, namespace: namespace) { body in
                    var status = body["status"] as? [String: Any] ?? [:]
                    status["collisionCount"] = 1
                    body["status"] = status
                }
            }
            for (namespace, name, _) in rolling {
                fake.modify("deployments.apps", name, namespace: namespace, values: ["Up-to-date": 1]) { body in
                    var metadata = body["metadata"] as? [String: Any] ?? [:]
                    metadata["generation"] = 5
                    body["metadata"] = metadata
                    var status = body["status"] as? [String: Any] ?? [:]
                    status["observedGeneration"] = 5
                    status["updatedReplicas"] = 1
                    status["replicas"] = 3
                    body["status"] = status
                }
            }
        }
        _ = await sending.value
        let apps = Set(rolling.map(\.app))
        let applied = await eventually(20) {
            marked.rowsChanged - rowsBefore >= 500 && gitOps.rows.shown.count { apps.contains($0.marked?.key.instance ?? "") && $0.state == .progressing } == apps.count
        }
        let burstTime = (CACurrentMediaTime() - started) * 1000
        let held = stall.stop()
        check(
            "the burst's 50 rollouts Progressing, every event in", applied,
            "\(marked.rowsChanged - rowsBefore) events, \(gitOps.rows.shown.count { apps.contains($0.marked?.key.instance ?? "") && $0.state == .progressing }) of 50")
        note("kubernetes marks: a burst of \(touched.count + rolling.count) Deployment events ranked in \(Int(burstTime)) ms, the main thread held at most \(Int(held)) ms")
        check("ranked in under 3 s", burstTime < 3000, "\(Int(burstTime)) ms")
        check("the main thread never held 500 ms", held < 500, "\(Int(held)) ms")
        check("shown, Hide Ready on", apps.isSubset(of: Set(page.gitOpsVisibleRows.compactMap { $0.marked?.key.instance })))
        let waits = rolling.map { marked.waiting(KubeMarkedMember.ID(kind: .deployment, namespace: $0.namespace, name: $0.name)) }
        let read = Set(fake.timedRequests.dropFirst(start).filter { Self.isObjectRead($0.request) }.map(\.request.path))
        check(
            "each waits as M2's move, or was read",
            zip(rolling, waits).allSatisfy { entry, waiting in waiting == .moved || read.contains("/apis/apps/v1/namespaces/\(entry.namespace)/deployments/\(entry.name)") },
            "\(waits.map { $0.map { "\($0)" } ?? "none" }.prefix(5))")
        return rolling
    }

    /// 2,000 readiness-only row events on 100 Deployments — every one the
    /// first minute settled, the rest ready and not yet settled —, their
    /// generation never moving: none asked as a move. A settled row whose
    /// cells move is where a "cells moved" rule (D2 took it out) would ask.
    private func marksPerfChurn(_ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, rolling: [(namespace: String, name: String, app: String)]) async {
        let gitOps = page.gitOps
        let marked = gitOps.marked
        let moving = Set(rolling.map(\.name))
        let settledIDs = (marked.store?.settled.keys.map { $0 } ?? []).filter { $0.kind == .deployment && !moving.contains($0.name) }.sorted()
        let settled = settledIDs.compactMap { id in id.namespace.map { (namespace: $0, name: id.name) } }
        let names = Set(settled.map(\.name))
        let ready = Set(gitOps.rows.shown.filter { $0.state == .ready }.compactMap { $0.marked?.key.instance })
        let unsettled = made.ready.filter { !moving.contains($0.name) && !names.contains($0.name) && ready.contains($0.app) }.prefix(100 - settled.count)
        let churned = settled + unsettled.map { (namespace: $0.namespace, name: $0.name) }
        check("100 Deployments to churn, the first minute's settled ones among them", churned.count == 100 && settled.count >= 8, "\(settled.count) settled, \(churned.count) in all")
        let rowsBefore = marked.rowsChanged
        let stall = MainThreadStall()
        stall.start()
        let started = CACurrentMediaTime()
        let pairs = churned
        let churning = Task.detached { fake.churnReadiness(pairs, rounds: 10) }
        _ = await churning.value
        let all = await eventually(60) { marked.rowsChanged - rowsBefore >= 2000 && marked.isMerged }
        let took = (CACurrentMediaTime() - started) * 1000
        let held = stall.stop()
        check("2,000 readiness-only row events, every one in", all, "\(marked.rowsChanged - rowsBefore)")
        note("kubernetes marks: 2,000 readiness-only row events (\(settled.count) of the 100 settled) merged in \(Int(took)) ms, the main thread held at most \(Int(held)) ms")
        check("the main thread never held 500 ms", held < 500, "\(Int(held)) ms")
        let moves = churned.filter { marked.waiting(KubeMarkedMember.ID(kind: .deployment, namespace: $0.namespace, name: $0.name)) == .moved }
        check("none asked as a move — the settled ones above all: readiness alone isn't M2's", moves.isEmpty, "\(moves.map(\.name).prefix(5))")
        check("the settled still at the generation they were read at", settledIDs.allSatisfy { marked.store?.settled[$0]?.generation == 4 })
        let apps = Set(unsettled.map(\.app))
        check("the rest ready again by their rows", gitOps.rows.shown.filter { apps.contains($0.marked?.key.instance ?? "") }.allSatisfy { $0.state == .ready })
    }

    /// The minute after the settle's: M2's moves read first, the only moves
    /// taken since the burst (`moves`: the count before it) — none of the
    /// churned; never more than 60 object GETs in any minute, by the fake's
    /// own times.
    private func marksPerfNextMinute(_ page: KubernetesPageModel, _ fake: FakeKubeAPI, rolling: [(namespace: String, name: String, app: String)], start: Int, moves: Int) async {
        let marked = page.gitOps.marked
        let moved = Set(rolling.map { "/apis/apps/v1/namespaces/\($0.namespace)/deployments/\($0.name)" })
        note("kubernetes marks: waiting for the next minute")
        let ids = rolling.map { KubeMarkedMember.ID(kind: .deployment, namespace: $0.namespace, name: $0.name) }
        let stall = MainThreadStall()
        stall.start()
        // Waited out by what the session read, not the fake's log: its lock
        // is held while it makes a list, and the main thread waiting on it
        // would be the scenario's hold, not the app's.
        let read = await eventually(90) { ids.allSatisfy { marked.store?.settled[$0]?.generation == 5 } && marked.getsQueued == 0 }
        let held = stall.stop()
        let gets = fake.timedRequests.dropFirst(start).filter { Self.isObjectRead($0.request) }
        let roll = gets.dropFirst(KubeMarkedRefetch.perMinute).first?.at
        let ended = Date().addingTimeInterval(stall.longestEnded - CACurrentMediaTime())
        note(
            String(
                format: "kubernetes marks: the next minute's wait held the main thread at most %d ms (%d ms of it its own work), ending %.1f s from the minute's first GET",
                Int(held), Int(stall.longestBusy), roll.map { ended.timeIntervalSince($0) } ?? -1))
        check("the next minute: M2's 50 read", read, "\(moved.subtracting(Set(gets.map(\.request.path))).count) of 50 not read")
        // The minute's 60 were the settle's; past them, M2's moves are
        // taken first — 4 in flight, so no other GET before the 47th.
        let next = gets.dropFirst(KubeMarkedRefetch.perMinute).map(\.request.path)
        let firstOther = next.firstIndex { !moved.contains($0) } ?? next.count
        check("first, before the settle's", firstOther >= moved.count - (KubeMarkedAppsSession.inFlight - 1), "another GET at \(firstOther): \(next.prefix(55).filter { !moved.contains($0) })")
        check(
            "the burst's 50 the only moves taken: none of the churned rows read as a move", marked.taken(as: .moved) - moves == rolling.count,
            "\(marked.taken(as: .moved) - moves) taken as moves")
        let most = Self.mostInAMinute(gets.map(\.at))
        note("kubernetes marks M2: \(gets.count) object GETs since g, at most \(most) in any minute, \(marked.mostTaken) a flush, \(marked.mostInFlight) in flight")
        check("never more than 60 in any minute", most <= KubeMarkedRefetch.perMinute, "\(most)")
        check("20 a flush, 4 in flight", marked.mostTaken <= KubeMarkedRefetch.perFlush && marked.mostInFlight <= KubeMarkedAppsSession.inFlight)
        check("the main thread never held 500 ms meanwhile", held < 500, "\(Int(held)) ms")
    }

    /// The page closed and opened again within the minute (14.4.1): what
    /// the section read goes with it, the context's minute doesn't
    /// (`KubernetesModel.markedMinutes`) — its apps again from their rows,
    /// its settle taking only the places freed since the close, never a
    /// fresh 60 (before D7's fix pass, a drop gave the minute again: every
    /// return to the page another minute's GETs at the API server).
    private func marksPerfReopen(_ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, kinds: (workloads: [KubeResourceKind], rows: [KubeResourceKind])) async {
        let gitOps = page.gitOps
        let marked = gitOps.marked
        let rowLists = Set(kinds.rows.map { "rows:\($0.fullName)" })
        // Nothing in flight: what the session sent and what the fake saw are counted from the same moment.
        check("nothing in flight before the page closes", await eventually(10) { marked.getsQueued == 0 }, "\(marked.getsQueued)")
        let held = marked.takenLastMinute
        let sent = marked.getsAsked
        let mark = fake.requests.count
        let closed = Date()
        app.closeOverlay(.kubernetes)
        check(
            "the page closed: the section's reads end, what it read dropped", await eventually(10) { marked.state == .idle && marked.store == nil && !marked.isReading && marked.openFollows == 0 },
            "\(marked.state) \(marked.store == nil ? "" : "a store kept")")
        app.toggleKubernetesPage(nil)
        if page.section != .gitops { _ = page.press("g") }
        let again = await eventually(30) {
            marked.state == .live && marked.isMerged && rowLists.isSubset(of: marked.store?.done ?? []) && gitOps.rows.shown.count == made.apps.count && !marked.refetchIdle
                && marked.getsQueued == 0
        }
        let took = Date().timeIntervalSince(closed)
        let since = marked.getsAsked - sent
        let asked = Array(fake.requests.dropFirst(mark))
        let objects = asked.filter(Self.isObjectRead)
        note("kubernetes marks: the page closed and opened again in \(Int(took * 1000)) ms — \(since) object GETs since, the minute holding \(held) at the close")
        check("opened again: every app's row again, from its rows, its settle waiting its turn", again, "\(marked.state) \(gitOps.rows.shown.count) of \(made.apps.count)")
        check(
            "opened again within the minute: only the places freed since the close taken, never a fresh 60 — the minute is the context's, not the page's",
            took < 60 && since < KubeMarkedRefetch.perMinute && objects.count == since, String(format: "%d taken, %d at the fake, in %.1f s", since, objects.count, took))
        checkMarksPerfReads("opened again", asked, kinds: kinds)
    }

    /// Another section ends every follow; back to `g` on a server refusing
    /// a streaming list: the rows in pages of 500, M3 not listed again.
    private func marksPerfBack(
        _ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, kinds: (workloads: [KubeResourceKind], rows: [KubeResourceKind])
    ) async {
        let gitOps = page.gitOps
        let marked = gitOps.marked
        page.showKind(.pods)
        check("another section: its follows end", await eventually(10) { marked.openFollows == 0 && gitOps.openFollows == 0 && !marked.isReading }, "\(marked.openFollows)")
        check("and their watches", await eventually(10) { fake.watched.allSatisfy { !Self.marksWorkloads.contains($0) } }, "\(fake.watched)")
        let mark = fake.requests.count
        fake.streamingLists = false
        defer { fake.streamingLists = true }
        let back = CACurrentMediaTime()
        check("back to g", page.press("g") && page.section == .gitops)
        let again = await eventually(30) { marked.state == .live && marked.isMerged && gitOps.rows.shown.count == made.apps.count }
        check("its apps again", again, "\(gitOps.rows.shown.count) of \(made.apps.count)")
        note("kubernetes marks: back to g in \(Int((CACurrentMediaTime() - back) * 1000)) ms")
        let asked = fake.requests.dropFirst(mark)
        let pages = asked.filter { !$0.isWatch && $0.path == "/apis/apps/v1/deployments" }
        check(
            "streaming refused: the Deployments' rows in pages of 500",
            pages.count == 3 && pages.allSatisfy { $0.query["limit"] == "500" && $0.query["includeObject"] == "Metadata" } && pages.first?.query["continue"] == nil
                && pages.dropFirst().allSatisfy { $0.query["continue"] != nil }, "\(pages.map(\.query))")
        let lists = Set(kinds.rows.map { $0.path(namespace: nil) })
        check(
            "within five minutes no Service, Ingress, claim, Job, CronJob or HPA listed again", !asked.contains { lists.contains($0.path) }, "\(asked.filter { lists.contains($0.path) }.map(\.path))")
        checkMarksPerfReads("back to g", Array(asked), kinds: kinds)
        page.showKind(.pods)
        check("left, nothing follows", await eventually(10) { marked.openFollows == 0 && !marked.isReading })
    }

    /// An agent's `k8s_gitops` on the spoke with no section's apps kept —
    /// the page closed (14.2.6): its own read at its bounds, once — the
    /// four workload kinds' rows, 2,000 objects or 16 MB a kind, the
    /// Deployments' bytes recorded against that cut ("close to the cut,
    /// which the D7 leg records") —, then a GET of at most 20; whole, its
    /// count exact, cut, "At least"; its reads a closed set. The page opened
    /// again after, on its pods.
    private func marksPerfAgent(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, made: FakeKubeAPI.SurveySpoke, discovery: KubeDiscovery) async {
        page.showKind(.pods)
        app.closeOverlay(.kubernetes)
        let forgotten = await eventually(10) { page.gitOps.marked.store == nil && model.contexts.context(named: "fake-prod").map { model.markedApps(of: $0) == nil } == true }
        check("the page closed: no section's apps kept for an agent", forgotten)
        let mark = fake.requests.count
        fake.forgetBytes()
        let started = CACurrentMediaTime()
        var answer = ""
        do {
            let result = try await KubeMCP.call("k8s_gitops", ["context": "fake-prod", "namespace": "all"], kubernetes: model)
            answer = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        } catch {
            answer = "\(error)"
        }
        let took = (CACurrentMediaTime() - started) * 1000
        let asked = Array(fake.requests.dropFirst(mark))
        let bytes = fake.bytesSent("deployments.apps", table: true)
        let cut = KubeMCP.marksRows.rowsBytes
        let lines = answer.components(separatedBy: "\n")
        note(
            String(
                format: "kubernetes marks: an agent's k8s_gitops read for itself in %d ms — the Deployments' rows %d KB, %.1f%% of its %d MB cut",
                Int(took), bytes / 1024, Double(bytes) / Double(cut) * 100, cut >> 20))
        check("read for this answer, not the section's", answer.contains("Read for this answer"), String(answer.prefix(400)))
        check(
            "the opening line: Argo CD in another cluster",
            lines.contains("Argo CD runs in another cluster (not in the kubeconfig); apps read from the marks on their objects; no sync status, repository or revision."),
            String(answer.prefix(400)))
        // Every app but the Ingresses' (no workload: an agent reads none of its kinds).
        let workloadApps = made.apps.count - 1
        if bytes < cut {
            check(
                "its Deployments' rows within its cut: whole, every app with a workload counted", lines.contains { $0.hasPrefix("\(workloadApps) apps read from marks in any namespace") },
                lines.first { $0.contains("read from marks in") } ?? String(answer.prefix(400)))
        } else {
            check("its Deployments' rows past its cut: a floor, said", lines.contains { $0.hasPrefix("At least ") }, lines.first { $0.contains("read from marks in") } ?? "")
        }
        let gets = asked.filter(Self.isObjectRead)
        let workloads = Set(["deployments", "statefulsets", "daemonsets", "rollouts"])
        check(
            "at most 20 GETs, each of one workload", gets.count <= KubeMCP.marksGets && gets.allSatisfy { workloads.contains(Self.resource(of: $0.path) ?? "") },
            "\(gets.count): \(gets.map(\.path).prefix(5))")
        let lists = Set(KubeMarkedAppsSession.kinds(discovery).workloads.map { $0.path(namespace: nil) })
        let strays = asked.filter { !$0.isDiscovery && !lists.contains($0.path) && !Self.isObjectRead($0) }
        check("its reads: the workloads' rows and their GETs alone", strays.isEmpty, "\(Set(strays.map(\.path)).sorted().prefix(8))")
        let rows = asked.filter { lists.contains($0.path) }
        check(
            "each kind's rows paged, with their metadata, never watched",
            Set(rows.map(\.path)) == lists && rows.allSatisfy { !$0.isWatch && $0.query["includeObject"] == "Metadata" && $0.accept.contains("as=Table") && $0.query["limit"] == "500" },
            "\(rows.map { "\($0.path)?\($0.query)" }.prefix(6))")
        check(
            "GETs only, nothing of Argo CD's own or Flux's, no Secret or ConfigMap",
            asked.allSatisfy { $0.method == "GET" && !Self.isArgoCDOrFlux($0) && !$0.path.contains("/secrets") && !$0.path.contains("/configmaps") })
        check("scrubbed", !answer.contains(FakeKubeAPI.gitOpsSentinel))
        app.toggleKubernetesPage(nil)
    }

    /// What `marksSeen` adds to reading a list of workloads (gitops.md
    /// 14.2.1): two key look-ups on each row's metadata as decoded, and the
    /// scan of a list for one marked row — timed over the spoke's
    /// Deployments' rows as the Overview reads them (with their metadata),
    /// beside the reader's own time over them. Off the main thread; the
    /// fastest of three of each.
    private func marksSeenCost(_ client: KubeClient, _ kind: KubeResourceKind) async -> (rows: Int, read: Double, marks: Double)? {
        let path = KubePath.query(kind.path(namespace: nil), [("includeObject", "Metadata")])
        guard let data = try? await client.get(path, accept: KubeClient.tableAccept).body else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> (rows: Int, read: Double, marks: Double)? in
            var read = Double.infinity
            var table: KubeTable?
            for _ in 0..<3 {
                let start = CACurrentMediaTime()
                table = try? KubeTableReader.read(data, namespace: nil, kind: kind)
                read = min(read, CACurrentMediaTime() - start)
            }
            guard let table, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["rows"] as? [[String: Any]] else { return nil }
            let metadatas = rows.compactMap { ($0["object"] as? [String: Any])?["metadata"] as? [String: Any] }
            let update = KubeFollowUpdate.listed(table)
            var marks = Double.infinity
            var seen = 0
            for _ in 0..<3 {
                let start = CACurrentMediaTime()
                for _ in 0..<100 {
                    for metadata in metadatas where KubeTableReader.argoMarked(metadata) { seen += 1 }
                    if KubeClusterOverviewSession.marked(update) { seen += 1 }
                }
                marks = min(marks, (CACurrentMediaTime() - start) / 100)
            }
            return seen > 0 ? (metadatas.count, read * 1000, marks * 1000) : nil
        }.value
    }

    /// M1's kinds, by their full names.
    package static let marksWorkloads: Set<String> = ["deployments.apps", "statefulsets.apps", "daemonsets.apps", "rollouts.argoproj.io"]
    /// The kinds the settle reads an object of: the workloads, CronJobs, HPAs.
    package static let settledKinds: Set<String> = ["deployments", "statefulsets", "daemonsets", "rollouts", "cronjobs", "horizontalpodautoscalers"]
    package static let settledResources = [
        "deployments.apps", "statefulsets.apps", "daemonsets.apps", "rollouts.argoproj.io", "cronjobs.batch", "horizontalpodautoscalers.autoscaling",
    ]
}
#endif
