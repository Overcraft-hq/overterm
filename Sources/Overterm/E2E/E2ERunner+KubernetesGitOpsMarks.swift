import AppKit
import Foundation
import SwiftUI

/// D3 and D4 (docs/design/kubernetes/gitops.md, 14.2, 14.9.3) against fake API
/// servers on sockets of the scenario's own, never a real cluster — the
/// run's only kubeconfig is OVERTERM_KUBECONFIG's file, and every context
/// is routed to a fake by name: `fake-dev` a spoke (no Argo CD Application
/// and no Flux served — Argo Rollouts are, as on the surveyed spokes: the
/// marks Argo CD leaves on 53 apps, two installations), `fake-prod` a
/// hub that is also a destination (Applications for most of its marked
/// apps), `kind-fake` Argo CD served with its Applications refused
/// everywhere.
///
/// 1. Discovery has no Argo CD Application or Flux; the GitOps row stays
///    hidden until the Overview's rows show a mark, then `g` opens it.
/// 2. The header's two lines verbatim, the chips' counts, the failing apps
///    first with their sentences — a Rollout's Deployment "scaled by its
///    Rollout", never a problem —, Hide Ready on; ↩ on a failing app opens
///    its detail saying why Sync, Refresh, Rollback and Diff aren't here,
///    its objects read (M4) and nothing else, Esc closes it; its menu has
///    no write.
/// 3. `is:marks`, `image:` and `G` by installation; beside Applications
///    read, the marked apps with no Application here among them, their
///    chip and the muted line unpressed; Applications refused, that header.
/// 4. ↩ on a failing app: its tree drawn — the Deployment Failed by its
///    object, under it the newest ReplicaSet and the old one still
///    serving, each carrying its mark as a copy, their pods with their
///    own health —, "What Argo CD knows" rows, its hints; a hooked app's
///    hook apart, a Rollout's app saying promote and abort aren't here and
///    its Deployment scaled by its Rollout; no Sync, Refresh, Rollback,
///    Diff or write in any menu, no Refresh in the detail but in why it
///    isn't here (↻ is Read again, this cluster's); ↩ on a node — Tab into
///    the tree, ↓ ↑ along it — opens the Deployment's detail, whose writes
///    say Argo CD may undo them, and `[` comes back to the app's detail
///    with the keyboard on that node; ↩ on a pod's node opens the pod,
///    whose writes say nothing of Argo CD.
///
/// 5. Agents (D6, `kubernetesGitOpsMarksAgents`): `a` on a Progressing
///    app's row opens the Ask Agent sheet with its brief (where Argo CD
///    runs, its pods, scrubbed), a Ready one says why not, the detail's Ask
///    Why on one failing Deployment hands off to its own brief with the app
///    named, and an agent's `k8s_gitops` answers from the section's apps
///    with nothing read.
/// 6. The checkout's rail on the spoke (D5, the checkout scenario's part
///    7, `kubernetesCheckoutGitOpsMarks`): its app read from the bound
///    workload's marks, by its object's GET, "another cluster", its Ask Why
///    with the rail's words (D6); option B on production only once Find
///    What Deploys This was pressed.
///
/// Reads only: every request a GET; never a Secret or a ConfigMap; on the
/// spoke no Application and nothing of Flux's; every part's requests —
/// the hub's and the refused context's too — only of the kinds the marks
/// are read from (rows, a GET of one object), Argo CD's own and the
/// namespaces, never a watch of Services, Ingresses, claims, Jobs,
/// CronJobs or HPAs; each detail read's — as it opens and read again — its
/// members' objects and its workloads' lists in its namespace, and beside
/// them only the section's own reads (`checkDetailReads`). The chips are
/// the fixture's own counts.
extension E2ERunner {
    func kubernetesGitOpsMarksScenario() async {
        await settledPrompt()
        guard let path = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !path.isEmpty, !path.contains(":") else {
            return check("OVERTERM_KUBECONFIG names the scenario's own file", false, "testKubernetesGitOpsMarks sets it")
        }
        let kubeconfig = URL(fileURLWithPath: path)
        guard !KubeconfigSources.isUsersOwn(kubeconfig, home: FileManager.default.homeDirectoryForCurrentUser) else {
            return check("OVERTERM_KUBECONFIG isn't under ~/.kube", false, path)
        }
        check("the run guards the user's kubeconfig", AppEnvironment.guardsKubeconfig)
        let id = UUID().uuidString.prefix(6)
        let spoke = FakeKubeAPI(socket: "/tmp/ot-e2e-kgm-s-\(id).sock")
        let hub = FakeKubeAPI(socket: "/tmp/ot-e2e-kgm-h-\(id).sock")
        let refused = FakeKubeAPI(socket: "/tmp/ot-e2e-kgm-r-\(id).sock")
        let fakes = ["fake-dev": spoke, "fake-prod": hub, "kind-fake": refused]
        let port: Int
        do {
            for fake in fakes.values { try fake.start() }
            port = try spoke.listenTCP()
        } catch {
            return check("the fake API servers start", false, "\(error)")
        }
        defer { for fake in fakes.values { fake.stop() } }
        defer { Self.accessibilityTree(false) }

        // The spoke: 40 plain apps and the named states, 8 marked by another installation.
        let made = spoke.addSpoke(FakeKubeAPI.SpokeOptions(apps: 40, rollouts: true, otherInstallation: 8))
        // The hub: Argo CD's Applications for 9 of its 12 marked apps.
        let hubApps = hub.addSpoke(FakeKubeAPI.SpokeOptions(apps: 12, states: false)).apps
        hub.serveArgoCD()
        for app in hubApps.prefix(9) {
            hub.addApplication(
                app, spec: ["project": "acme", "destination": ["namespace": "team-0"], "source": ["repoURL": "https://git.acme.example/acme/fleet.git"]],
                status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        }
        // Applications served, refused across the cluster and in argocd.
        refused.addSpoke(FakeKubeAPI.SpokeOptions(apps: 6, states: false))
        refused.serveArgoCD()
        refused.forbidden = ["applications@cluster", "applications@argocd"]

        do {
            try Self.fakeKubeconfig(port: port, kind: true).write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the scenario's kubeconfig is written", false, "\(error)")
        }
        defer { try? FileManager.default.removeItem(at: kubeconfig) }
        let model = KubernetesModel.shared
        let sockets = fakes.mapValues { $0.socket ?? "" }
        model.connectOverride = { context in KubeSocketConnection(socket: sockets[context.name] ?? "", context: context.name) }
        model.statusOverride = { _ in .open }
        defer {
            model.connectOverride = nil
            model.statusOverride = nil
        }
        let page = app.kubernetesPage
        app.toggleKubernetesPage(nil)
        defer { if app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        check(
            "the scenario's contexts are read", await eventually(10) { Set(model.contexts.contexts.map(\.name)) == ["fake-dev", "fake-prod", "kind-fake"] },
            "\(model.contexts.contexts.map(\.name))")
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.all)

        await kubernetesGitOpsMarksSpoke(model, page, spoke, made: made)
        await kubernetesGitOpsMarksSection(model, page, spoke, made: made)
        await kubernetesGitOpsMarksFilters(model, page, spoke, made: made)
        await kubernetesGitOpsMarksDetail(model, page, spoke, made: made)
        await kubernetesGitOpsMarksAgents(model, page, spoke, made: made)
        await kubernetesGitOpsMarksBeside(model, page, hub: hub, refused: refused, hubApps: hubApps)
        // The checkout's rail on the spoke (gitops.md 14.9.3: the checkout scenario's part 7).
        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        await kubernetesCheckoutGitOpsMarks(model, page, spoke, made: made)

        for (name, fake) in fakes.sorted(by: { $0.key < $1.key }) {
            check("\(name): nothing written", fake.writes.isEmpty, "\(fake.writes.map(\.description))")
            check("\(name): never a Secret or a ConfigMap", !fake.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
        }
    }

    /// Part 1: no Argo CD Application or Flux served; the GitOps row hidden
    /// until a row shows a mark (the Overview's), then `g` opens the section.
    private func kubernetesGitOpsMarksSpoke(_ model: KubernetesModel, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, made: FakeKubeAPI.Spoke) async {
        check("fake-dev's discovery read", await eventually(15) { model.selectedName == "fake-dev" && model.discovery?.kind("deploy") != nil })
        let served = Set(model.discovery?.kinds.map(\.fullName) ?? [])
        check(
            "no Argo CD Application or Flux kind served, Argo Rollouts are",
            !served.contains("applications.argoproj.io") && !served.contains { $0.hasSuffix("fluxcd.io") } && served.contains("rollouts.argoproj.io"),
            "\(served.filter { $0.contains("argoproj") || $0.contains("fluxcd") }.sorted())")
        check("so GitOps isn't served", !page.gitOpsServed)
        page.showKind(model.discovery?.kind("po") ?? .pods)
        _ = await eventually(15) { model.listState == .live }
        check("no row has shown a mark yet", !model.marksSeen.contains("fake-dev"))
        check("the GitOps row hidden", !page.gitOpsListed)
        check("not drawn among the sections", await overviewElement("kubernetes.section.gitops", timeout: 1) == nil)

        // The Overview reads the workloads with their metadata: a mark seen.
        page.showSection(.overview)
        check("the Overview's rows show a mark", await eventually(20) { model.marksSeen.contains("fake-dev") }, "\(model.marksSeen)")
        check("the GitOps row shows", page.gitOpsListed)
        check("drawn among the sections", await overviewElement("kubernetes.section.gitops", timeout: 10) != nil)

        // A Deployments list under the section: the marks' own kind, so the section's reads can be told apart.
        page.showKind(model.discovery?.kind("deploy") ?? .pods)
        _ = await eventually(15) { model.kind.resource == "deployments" && model.listState == .live }
        page.giveListTheKeyboard()
        check("the list has the keyboard", await eventually(5) { self.app.kubernetesListHasKeyboard() })
        spoke.forgetRequests()
        check("g is the list's", await pressKubernetesKey("g", keyCode: 5))
        check("and shows GitOps, refusing nothing", page.section == .gitops && page.commandProblem == nil, page.commandProblem ?? "")
        let gitOps = page.gitOps
        check("the apps read from marks", await eventually(20) { gitOps.marksMode == .only(.notServed) && gitOps.marked.state == .live }, "\(gitOps.marksMode)")
        check(
            "every app ranked, each settled by its object",
            await eventually(30) { gitOps.marked.refetchIdle && gitOps.marked.isMerged && gitOps.rows.shown.count == gitOps.marked.apps.count && !gitOps.rows.shown.isEmpty },
            "\(gitOps.rows.shown.count) rows, \(gitOps.marked.apps.count) apps")
        check("the plain apps among them", Set(gitOps.marked.apps.map(\.app.key.instance)).isSuperset(of: made.apps))
        let requests = spoke.requests
        check(
            "no Application and nothing of Flux's asked",
            !requests.contains { $0.path.contains("/applications") || $0.path.contains("/applicationsets") || $0.path.contains("fluxcd.io") })
        check("the Rollouts' rows followed for their apps' health", requests.contains { $0.isWatch && $0.path.hasSuffix("/rollouts") })
        check("GETs only", requests.allSatisfy { $0.method == "GET" })
        // The page's own namespace list beside them, for its picker.
        let read = Set(requests.filter { !$0.isDiscovery }.compactMap { Self.resource(of: $0.path) })
        check("only the marks' kinds read", read.isSubset(of: Self.marksKinds.union(["namespaces"])), "\(read.subtracting(Self.marksKinds).sorted())")
        check("never a ReplicaSet or a pod", !read.contains("replicasets") && !read.contains("pods"))
        let watched = Set(requests.filter(\.isWatch).compactMap { Self.resource(of: $0.path) })
        check(
            "Services, Ingresses, claims, Jobs, CronJobs and HPAs never watched", watched.isSubset(of: ["deployments", "statefulsets", "daemonsets", "rollouts"]),
            "\(watched.sorted())")
        check("rows only, never whole objects watched", !requests.contains { $0.isWatch && $0.query["includeObject"] == "Object" })
    }

    /// Part 2: the header's two lines, the chips, the failing apps first
    /// with their sentences, Hide Ready on; a failing app's placeholder
    /// detail.
    private func kubernetesGitOpsMarksSection(_ model: KubernetesModel, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, made: FakeKubeAPI.Spoke) async {
        let gitOps = page.gitOps
        func row(_ instance: String) -> KubeGitOpsRow? { gitOps.rows.shown.first { $0.marked?.key.instance == instance } }
        let count = gitOps.marked.apps.count
        let lead = "Argo CD runs in another cluster — not in your kubeconfig. These \(count) apps are read from the marks Argo CD leaves on their objects."
        let limits = "No sync status, repository or revision: those are in the Application, in Argo CD's cluster. Health is Argo CD's built-in rules applied to what is here."
        let leadElement = await overviewElement("kubernetes.gitops.marks.lead", timeout: 10)
        let limitsElement = await overviewElement("kubernetes.gitops.marks.limits", timeout: 10)
        check("the header's first line, verbatim", leadElement?.text.contains(lead) == true, leadElement?.text ?? "none")
        check("its second, verbatim", limitsElement?.text.contains(limits) == true, limitsElement?.text ?? "none")
        check("the first drawn", await shownText(15) { $0.contains("Argo CD runs in another cluster") } != nil)
        check("the second drawn", await shownText(15) { $0.contains("No sync status, repository or revision") } != nil)
        let header = await overviewElement("kubernetes.gitops.header", timeout: 10)
        check("the header's words", header?.text.contains("Argo CD: from marks · \(count) apps") == true, header?.text ?? "none")
        check("drawn", await shownText(15) { $0.contains("\(count) apps") && $0.contains("from marks") } != nil)
        check("two installations said", await shownText(15) { $0.contains("2 Argo CD installations mark objects here") } != nil)

        // Each named state by Argo CD's rule.
        check(
            "the stalled rollout Failed", row(made.stalled)?.state == .failed && row(made.stalled)?.why.contains("rollout stalled (ProgressDeadlineExceeded)") == true, row(made.stalled)?.why ?? "none"
        )
        check("the HPA's metrics Failed", row(made.hpa)?.state == .failed && row(made.hpa)?.why.contains("FailedGetResourceMetric") == true, row(made.hpa)?.why ?? "none")
        check("the CronJob's last run Failed", row(made.cronJob)?.why.contains("last run of CronJob acme-reindex failed") == true, row(made.cronJob)?.why ?? "none")
        check("the stuck single replica Progressing, never Ready", row(made.stuck)?.state == .progressing, row(made.stuck)?.why ?? "none")
        check("the paused one Paused", row(made.paused)?.state == .paused, row(made.paused)?.why ?? "none")
        check("a StatefulSet 0/3 Progressing, never Failed", row(made.statefulSet)?.state == .progressing, row(made.statefulSet)?.why ?? "none")
        // How long: the Age column's, from when it was first read not ready — never baked into its why.
        let ledger = row(made.statefulSet)
        check(
            "its age counted from when it was first read not ready",
            ledger?.since != nil && ledger?.marked?.sinceSaid == KubeMarkedHealth.sinceFirstRead && ledger?.why == "0/3 ready · StatefulSet acme-ledger-db",
            "\(ledger?.why ?? "none") \(ledger?.marked?.sinceSaid ?? "no age")")
        check("a Service and an Ingress alone Unknown, never Ready", row(made.serviceOnly)?.state == .unknown, row(made.serviceOnly)?.why ?? "none")
        check("a failed hook isn't its app's health", row(made.hooked)?.state == .ready, row(made.hooked)?.why ?? "none")
        check("Helm's instance label is no app", !gitOps.marked.apps.contains { $0.app.key.instance == "fake-metrics-agent" })
        // An Argo Rollout's phase is its app's; the Deployment it runs, scaled to 0, never a problem (14.12).
        let canary = row(made.rollout)
        check("a Healthy Rollout's app Ready", canary?.state == .ready, canary?.why ?? "none")
        check("its Deployment scaled by its Rollout", canary?.hover.contains("Deployment acme-canary: scaled by its Rollout") == true, canary?.hover ?? "none")
        check("never scaled to 0", canary?.hover.contains("scaled to 0") == false)
        let blue = row(made.rolloutDegraded)
        check("a Degraded Rollout's app Failed by its Rollout, not its Deployment", blue?.state == .failed && blue?.why == "rollout degraded · Rollout acme-blue", blue?.why ?? "none")
        let hover = KubeMarkedSection.lines(
            mode: gitOps.marksMode, context: "fake-dev", apps: gitOps.marked.apps.map(\.app), reading: gitOps.marked.reading, tally: gitOps.marked.tally,
            kinds: ["Rollouts"], unread: 0
        ).hover
        check("the header's hover: Rollouts read for health only", hover.contains("Promote and abort are Argo Rollouts' — not here"), hover)

        // The chips, problems first, Hide Ready on: the fixture's own counts
        // (14.9.1) — Failed the stalled rollout, the HPA's metrics, the
        // CronJob's last run and the Degraded Rollout; Progressing the stuck
        // single replica, the StatefulSet 0/3, the pending load balancer and
        // claim; Paused the one only its object shows; Unknown the Service
        // and Ingress alone; Ready the plain apps, the hooked, the label-only
        // and the Healthy Rollout's.
        let chips = KubeGitOpsSection.chips(gitOps.rows.shown)
        let counts = Dictionary(chips.map { ($0.state, $0.count) }, uniquingKeysWith: +)
        let expected: [KubeGitOpsState: Int] = [.failed: 4, .progressing: 4, .paused: 1, .ready: made.apps.count + 3, .unknown: 1]
        check("the chips count the fixture's states", counts == expected, "\(chips.map { "\($0.state.word) \($0.count)" })")
        let failingApps = Set(gitOps.rows.shown.filter { $0.state == .failed }.compactMap { $0.marked?.key.instance })
        check(
            "the failing ones the fixture's four", failingApps == [made.stalled, made.hpa, made.cronJob, made.rolloutDegraded], "\(failingApps.sorted())")
        check("drawn", await shownText(15) { $0.contains("4 failing") } != nil)
        // Every workload settled by its object: no Ready app from its rows
        // only — a third of them with an HPA Healthy from its row for good.
        let ready = counts[.ready] ?? 0
        let fromRows = gitOps.rows.shown.count { $0.state == .ready && $0.marked?.fromRows == true }
        check("no Ready app from rows only once settled, its HPA's row notwithstanding", fromRows == 0, "\(fromRows) of \(ready)")
        let readyText = KubeGitOpsSection.chipText(.ready, ready, fromRows: fromRows)
        check("the Ready chip says only its count", readyText == "\(made.apps.count + 3) ready", readyText)
        check("drawn", await shownText(15) { $0.contains(readyText) } != nil, readyText)
        check("Hide Ready on above 50", gitOps.rows.shown.count > KubeGitOpsSection.hideReadyAbove && page.gitOpsHidesReady, "\(gitOps.rows.shown.count)")
        let visible = page.gitOpsVisibleRows
        check("no Ready app shown", !visible.isEmpty && !visible.contains { $0.state == .ready })
        check("the failing first", visible.first?.state == .failed && visible.map(\.state) == visible.map(\.state).sorted(), "\(visible.map(\.state.word))")
        check("their sentences drawn", await shownText(15) { $0.contains("rollout stalled") } != nil)
        check("Unknown never hidden", visible.contains { $0.marked?.key.instance == made.serviceOnly })
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks.png"))
        }

        // ↩ on a failing app: its detail, its objects read — and nothing else; Esc closes it.
        guard let stalled = row(made.stalled) else { return check("the stalled app's row", false) }
        check("its menu has no write", page.gitOpsVerbs(for: [stalled.id]).allSatisfy { !["Sync", "Refresh", "Rollback", "Diff", "Delete…", "Restart…"].contains($0.title) && $0.place != .remove })
        page.gitOpsView.selection = [stalled.id]
        page.giveListTheKeyboard()
        // Its Deployment's object may be the section's own read of a moment ago: what was asked is checked.
        await detailRead("↩ on the failing app", page, spoke) { await self.pressKubernetesKey("\r", keyCode: 36) }
        check("its detail beside the section", await eventually(5) { page.markedDetail?.key == stalled.marked?.key } && page.section == .gitops && page.detail == nil)
        let absent = await overviewElement("kubernetes.gitops.marked.absent", timeout: 10)
        check(
            "why the Application's verbs aren't here",
            absent?.text.contains("Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there.") == true,
            absent?.text ?? "none")
        check("drawn", await shownText(15) { $0.contains("Sync, Refresh, Rollback and Diff act on the Application") } != nil)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks-detail.png"))
        }
        check("its object named", await shownText(15) { $0.contains("acme-cart") } != nil)
        check("Esc closes it", await pressKubernetesKey("\u{1B}", keyCode: 53) && page.markedDetail == nil)
        page.gitOpsView.selection = []
    }

    /// Part 3, on the spoke: `is:marks`, `image:`, `G` by installation.
    private func kubernetesGitOpsMarksFilters(_ model: KubernetesModel, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, made: FakeKubeAPI.Spoke) async {
        let gitOps = page.gitOps
        page.filter = "is:marks"
        check("is:marks keeps them", !page.gitOpsVisibleRows.isEmpty && page.gitOpsVisibleRows.allSatisfy(\.isMarked))
        page.filter = "-is:marks"
        check("-is:marks drops them", page.gitOpsVisibleRows.isEmpty)
        page.filter = "image:acme-cart"
        check("image: matches a member's image", page.gitOpsVisibleRows.map { $0.marked?.key.instance } == [made.stalled], "\(page.gitOpsVisibleRows.map(\.ref.name))")
        page.filter = "repo:acme"
        check("repo: matches none of them", page.gitOpsVisibleRows.isEmpty)
        page.filter = "kind:marks is:failed"
        check("kind:marks is:failed", !page.gitOpsVisibleRows.isEmpty && page.gitOpsVisibleRows.allSatisfy { $0.isMarked && $0.state == .failed })
        page.filter = ""

        check("two installations: G offers the installation", page.gitOpsInstallations && KubeGitOpsGroupBy.offered(installations: true).contains(.installation))
        page.giveListTheKeyboard()
        var cycled: [KubeGitOpsGroupBy] = []
        for _ in 0..<6 {
            guard await pressKubernetesKey("G", keyCode: 5, shift: true) else { break }
            cycled.append(page.gitOpsView.groupBy)
        }
        check("G cycles through the installation", cycled == [.tool, .source, .owner, .destination, .installation, .none], "\(cycled)")
        page.groupGitOps(by: .installation)
        page.gitOpsView.hideReady = false
        let groups = page.gitOpsGroups()
        check("by installation", groups.map(\.title) == ["No installation id", "Installation hub-b"], "\(groups.map(\.title))")
        check("hub-b's eight", groups.last?.members.count == 8, "\(groups.last?.members.count ?? 0)")
        check("drawn", await shownText(15) { $0.contains("No installation id") } != nil)
        page.groupGitOps(by: .tool)
        check("by tool: Argo CD from marks", page.gitOpsGroups().map(\.title) == [KubeGitOpsGrouping.markedTool], "\(page.gitOpsGroups().map(\.title))")
        page.groupGitOps(by: .none)
        page.gitOpsView.hideReady = nil
        _ = gitOps
    }

    /// Part 4, on the spoke: a failing app's detail — its tree, per-object
    /// health, a copied ReplicaSet as a child, what only the Application
    /// knows, its hints; a hook apart; a Rollout's verbs not here; no
    /// Sync, Refresh, Rollback, Diff or write in any menu, no Refresh in the
    /// detail but why it isn't here; ↩ on a node from the keyboard opening
    /// the Deployment's detail, `[` back to the app's on that node; a pod's
    /// node, its writes saying nothing of Argo CD. Each read checked.
    private func kubernetesGitOpsMarksDetail(_ model: KubernetesModel, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, made: FakeKubeAPI.Spoke) async {
        let gitOps = page.gitOps
        func row(_ instance: String) -> KubeGitOpsRow? { gitOps.rows.shown.first { $0.marked?.key.instance == instance } }
        guard let stalled = row(made.stalled), let key = stalled.marked?.key else { return check("the stalled app's row", false) }
        page.gitOpsView.selection = [stalled.id]
        page.giveListTheKeyboard()
        await detailRead("↩ on the stalled app", page, spoke) { await self.pressKubernetesKey("\r", keyCode: 36) && page.markedDetail?.key == key }
        // Read again on purpose — what part 2 read may be younger than 30 s —: the detail's own, every member.
        await detailRead("Read again", page, spoke, everyMember: true) { await self.pressOnce("kubernetes.gitops.marked.readAgain") }
        let absentSentence = "Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there."
        let whole = await overviewElement("kubernetes.gitops.marked.detail", timeout: 10)?.text ?? ""
        check(
            "no Refresh in the detail but why Argo CD's isn't here", whole.contains(absentSentence) && !whole.replacingOccurrences(of: absentSentence, with: "").contains("Refresh"),
            whole)
        guard let detail = page.markedDetailShown else { return check("its detail", false) }
        // The tree: each object with Argo CD's word; under the Deployment its ReplicaSets, then their pods.
        guard let deployment = detail.tree.first(where: { $0.kind == "Deployment" && $0.name == "acme-cart" }) else { return check("its Deployment's node", false) }
        check("the Deployment Failed by its object", deployment.status == .degraded && deployment.sentence == "rollout stalled (ProgressDeadlineExceeded)", deployment.sentence)
        check(
            "under it the newest ReplicaSet and the old one still serving", deployment.children.map(\.name) == ["acme-cart-5f8d7c", "acme-cart-7d4b9c"],
            "\(deployment.children.map(\.name))")
        check(
            "each a copy of its mark, never a member",
            deployment.children.allSatisfy { $0.role == .owned && $0.note == "a copy of Deployment acme-cart's mark: not a member" })
        check("their health from their rows", deployment.children.map(\.status) == [.progressing, .healthy])
        let pod = deployment.children.first?.children.first
        check("the new one's pod crash-looping, its own health", pod?.name == "acme-cart-5f8d7c-x2k9p" && pod?.status == .degraded && pod?.sentence == "CrashLoopBackOff")
        check("its app Failed by its members, not its pods", detail.word == "Failed")
        let service = detail.tree.first { $0.kind == "Service" }
        check("its Service's ignore-healthcheck: not counted", service?.role == .ignored && service?.note == "ignore-healthcheck: not counted, as in Argo CD")
        let tree = await overviewElement("kubernetes.gitops.marked.tree", timeout: 10)
        for name in ["acme-cart-5f8d7c", "acme-cart-7d4b9c", "acme-cart-5f8d7c-x2k9p", "rollout stalled (ProgressDeadlineExceeded)", "CrashLoopBackOff", "a copy of Deployment acme-cart's mark"] {
            check("the tree says \(name)", tree?.text.contains(name) == true, tree?.text ?? "none")
        }
        check("drawn", await shownText(15) { $0.contains("acme-cart-5f8d7c-x2k9p") } != nil)
        // What Argo CD alone knows: fixed rows, never filled.
        let knows = await overviewElement("kubernetes.gitops.marked.knows", timeout: 10)
        for field in KubeMarkedAppDetail.applicationFields { check("“\(field)” said", knows?.text.contains(field) == true, knows?.text ?? "none") }
        check("each in the Application, in Argo CD's cluster", knows?.text.contains("in the Application, in Argo CD's cluster") == true)
        // A card's caption is drawn in capitals.
        check("drawn", await shownText(15) { $0.lowercased().contains("what argo cd knows and this cluster") } != nil)
        check(
            "its hints, as text",
            detail.hints.contains("sync-options Prune=false — Deployment acme-cart") && detail.hints.contains { $0.hasPrefix("link external-link: https://grafana.acme.example/") })
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks-tree.png"))
        }
        // No Sync, Refresh, Rollback, Diff or write in any menu.
        let absent: Set<String> = ["Sync", "Refresh", "Rollback", "Diff"]
        let writes = Set(KubernetesPageModel.writeVerbOrder.map(\.title))
        let menus = (detail.tree.flatMap(\.all) + detail.hooks).map { page.markedNodeVerbs($0).map(\.title) } + [page.gitOpsVerbs(for: [stalled.id]).map(\.title)]
        check("no Sync, Refresh, Rollback or Diff in any menu", menus.allSatisfy { absent.isDisjoint(with: $0) }, "\(menus)")
        check("no write in any menu", menus.allSatisfy { writes.isDisjoint(with: $0) })

        // A hooked app: its hook apart, never its health.
        if let hooked = row(made.hooked)?.marked?.key {
            await detailRead("the hooked app", page, spoke) {
                page.openMarkedApp(KubeMarkedDetailRef(context: "fake-dev", key: hooked))
                return page.markedDetail?.key == hooked
            }
            await detailRead("the hooked app read again", page, spoke, everyMember: true) { await self.pressOnce("kubernetes.gitops.marked.readAgain") }
            let hooks = await overviewElement("kubernetes.gitops.marked.hooks", timeout: 10)
            check("its hook apart, not counted", hooks?.text.contains("acme-orders-migrate") == true && hooks?.text.contains("not counted, as in Argo CD") == true, hooks?.text ?? "none")
            check("its app Ready all the same", page.markedDetailShown?.word == "Ready")
        } else {
            check("the hooked app's row", false)
        }
        // A Rollout's app: promote and abort aren't here; its Deployment scaled by it.
        if let blue = row(made.rolloutDegraded)?.marked?.key {
            await detailRead("the Rollout's app", page, spoke) {
                page.openMarkedApp(KubeMarkedDetailRef(context: "fake-dev", key: blue))
                return page.markedDetail?.key == blue
            }
            // Its Rollout's own GET among them, its lists by its Deployment's selector.
            await detailRead("the Rollout's app read again", page, spoke, everyMember: true) { await self.pressOnce("kubernetes.gitops.marked.readAgain") }
            check(
                "the Rollout read by a GET of its own", page.markedRead.asked.contains("/apis/argoproj.io/v1alpha1/namespaces/team-1/rollouts/acme-blue"),
                "\(page.markedRead.asked)")
            let rollouts = await overviewElement("kubernetes.gitops.marked.rollouts", timeout: 10)
            check("promote and abort are Argo Rollouts'", rollouts?.text.contains("promote and abort are Argo Rollouts' — not here") == true, rollouts?.text ?? "none")
            let shown = page.markedDetailShown
            check(
                "its Deployment scaled by its Rollout",
                shown?.tree.contains { $0.kind == "Deployment" && $0.sentence == KubeMarkedHealth.scaledByRollout } == true)
            check(
                "the Rollout's own ReplicaSet under it, a pod crash-looping",
                shown?.tree.first { $0.kind == "Rollout" }?.children.first?.children.contains { $0.status == .degraded } == true)
        } else {
            check("the Rollout's app row", false)
        }

        // ↩ on a node, from the keyboard: Tab into the tree, ↓ ↑ along it, ↩ — the Deployment in its own list.
        page.openMarkedApp(KubeMarkedDetailRef(context: "fake-dev", key: key))
        check("the stalled app's detail again", await eventually(15) { page.markedDetailShown?.tree.first?.children.first?.children.isEmpty == false })
        guard let shown = page.markedDetailShown else { return check("its detail", false) }
        let walk = KubeMarkedAppDetail.walk(shown)
        guard walk.count > 2, walk[0].name == "acme-cart", let podAt = walk.firstIndex(where: { $0.kind == "Pod" }) else {
            return check("its tree walked", false, "\(walk.map(\.name))")
        }
        check("Tab: the keyboard into its tree, on its first node", await pressKubernetesKey("\t", keyCode: 48) && page.markedNode == walk[0].id, page.markedNode ?? "none")
        check("its keys said", await shownText(10) { $0.contains("back to the list") } != nil)
        check("↓ along it", await pressKubernetesKey("\u{F701}", keyCode: 125) && page.markedNode == walk[1].id, page.markedNode ?? "none")
        check("↑ back", await pressKubernetesKey("\u{F700}", keyCode: 126) && page.markedNode == walk[0].id, page.markedNode ?? "none")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks-node.png"))
        }
        check("↩ on the node", await pressKubernetesKey("\r", keyCode: 36))
        check(
            "its detail in its own list",
            await eventually(10) { page.detail?.ref.name == "acme-cart" && page.detail?.ref.kind.fullName == "deployments.apps" && page.section != .gitops },
            "\(page.detail?.ref.description ?? "none")")
        if let ref = page.detail?.ref {
            check(
                "its writes say Argo CD may undo them",
                page.markedUndone(.restart, on: ref) == "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster.")
            check("a trigger's doesn't", page.markedUndone(.trigger, on: ref) == nil)
        }
        check("[ goes back", await pressKubernetesKey("[", keyCode: 33))
        check(
            "to the app's detail, the keyboard on its node again",
            await eventually(15) { page.section == .gitops && page.markedDetail?.key == key && page.markedDetailShown != nil && page.markedNode == walk[0].id },
            page.markedNode ?? "none")
        // A pod's node: opened all the same, its writes saying nothing of Argo CD.
        for _ in 0..<podAt { _ = await pressKubernetesKey("\u{F701}", keyCode: 125) }
        check("↓ to the crash-looping pod's node", page.markedNode == walk[podAt].id, page.markedNode ?? "none")
        check("↩ on it", await pressKubernetesKey("\r", keyCode: 36))
        check("the pod in its own list", await eventually(10) { page.detail?.ref.name == walk[podAt].name && page.detail?.ref.isPod == true }, "\(page.detail?.ref.description ?? "none")")
        if let ref = page.detail?.ref {
            check("a pod's writes say nothing of Argo CD", page.markedUndone(.delete, on: ref) == nil && page.markedUndone(.restart, on: ref) == nil)
            check("yet [ comes back to its app", page.markedOrigin?.app.key == key)
        }
        check("[ goes back", await pressKubernetesKey("[", keyCode: 33))
        check("to the app's detail", await eventually(15) { page.section == .gitops && page.markedDetail?.key == key && page.markedDetailShown != nil })
        check("Esc closes it", await pressKubernetesKey("\u{1B}", keyCode: 53) && page.markedDetail == nil && page.markedNode == nil)
        page.gitOpsView.selection = []
        check("nothing written", spoke.writes.isEmpty, "\(spoke.writes.map(\.description))")
        // The pod opened Pods under the section: the marks' own kind there again, so the next part's reads are told apart.
        page.showKind(model.discovery?.kind("deploy") ?? .pods)
        _ = await eventually(15) { model.kind.resource == "deployments" && model.listState == .live }
    }

    /// The element `identifier` names under the page, found (SwiftUI builds
    /// its accessibility tree a moment later), then pressed once.
    func pressOnce(_ identifier: String) async -> Bool {
        Self.accessibilityTree(true)
        guard await eventually(10, { self.app.kubernetesView.map { Self.accessibilityPress(identifier, in: $0, press: false) } ?? false }),
            let root = app.kubernetesView
        else { return false }
        return Self.accessibilityPress(identifier, in: root)
    }

    /// A detail read that `open` makes — the fake's log forgotten just
    /// before —, then what it read checked (`checkDetailReads`). Read
    /// Again (`everyMember`) reads every member whatever the section
    /// holds; an app opened again within 30 s asks nothing, what was read
    /// standing — then nothing of the detail's may be in the log.
    private func detailRead(_ what: String, _ page: KubernetesPageModel, _ spoke: FakeKubeAPI, everyMember: Bool = false, _ open: () async -> Bool) async {
        let marked = page.gitOps.marked
        let read = page.markedRead
        // The section's GETs while the detail reads: asked from here, and those waiting or in flight now.
        let sectionAsked = marked.getsAsked
        let sectionQueued = marked.getsQueued
        let detailAsked = read.getsAsked + read.listsAsked
        let at = read.read.at
        spoke.forgetRequests()
        check("\(what): opened", await open())
        check(
            "\(what): read",
            await eventually(15) { page.markedDetail != nil && read.ref == page.markedDetail && read.state == .loaded && (!everyMember || read.read.at != at) })
        let asked = read.getsAsked + read.listsAsked > detailAsked ? read.asked : []
        checkDetailReads(
            what, spoke.requests, page: page, asked: asked, sectionGets: marked.getsAsked - sectionAsked + sectionQueued, everyMember: everyMember)
    }

    /// What an app's detail read (M4, gitops.md 14.2.3; 14.9.3: "for each
    /// part, the set of paths the part read"), from the fake's log of the
    /// read and the detail's own account of it (`asked`, its last read's
    /// paths): GETs only; every object it read one of the app's members
    /// whose rule reads its object — each of them after Read Again —;
    /// every list a workload's ReplicaSets or pods by the workload's own
    /// selector, or a CronJob's Jobs, in the app's namespaces, as Table rows
    /// with metadata (a Table or nothing), never a watch; each path one the
    /// fake was asked. Beside them only what the section shown reads — the
    /// marks' kinds and the page's own (namespaces, CRDs) —: never a new
    /// kind of read, a ReplicaSet, pod or Job across the cluster, a Secret
    /// or a ConfigMap, and no more objects read that aren't the app's than
    /// the section's own GETs meanwhile (`sectionGets`).
    private func checkDetailReads(_ what: String, _ requests: [FakeKubeAPI.Request], page: KubernetesPageModel, asked: [String], sectionGets: Int, everyMember: Bool) {
        guard let app = page.markedDetailApp?.app, let discovery = page.model.discovery else { return check("\(what): its app", false) }
        let kinds = KubeMarkedAppsSession.kinds(discovery)
        let objectKinds = kinds.workloads + kinds.rows
        let members = Set(
            KubeMarkedAppDetail.fetched(app, limit: page.markedRead.bounds.members).read.compactMap { id in
                objectKinds.first { KubeMarkedKind($0) == id.kind }?.path(namespace: id.namespace, name: id.name)
            })
        let namespaces = app.namespaces
        func base(_ path: String) -> String { String(path.split(separator: "?", maxSplits: 1).first ?? "") }
        func inItsNamespaces(_ path: String) -> Bool { namespaces.contains { path.contains("/namespaces/\($0)/") } }
        let objects = Set(asked.filter { !$0.contains("?") })
        let lists = asked.filter { $0.contains("?") }.map(base)
        if everyMember { check("\(what): a GET of each member whose rule reads its object", !members.isEmpty && objects == members, "\(objects.symmetricDifference(members).sorted())") }
        check("\(what): no object but its members'", objects.isSubset(of: members), "\(objects.subtracting(members).sorted())")
        check(
            "\(what): its lists in its namespaces, of what is under its workloads",
            lists.allSatisfy { inItsNamespaces($0) && ["replicasets", "pods", "jobs"].contains(Self.resource(of: $0) ?? "") }, "\(lists)")
        check("\(what): each the fake was asked", Set(asked.map(base)).isSubset(of: Set(requests.map(\.path))), "\(asked)")
        // The fake's whole log: the detail's reads, and the section's own beside them.
        let read = Set(requests.filter { !$0.isDiscovery }.compactMap { Self.resource(of: $0.path) })
        let allowed = Self.marksKinds.union(["replicasets", "pods", "namespaces", "customresourcedefinitions"])
        check("\(what): nothing read but the marks' kinds and what is under them", read.isSubset(of: allowed), "\(read.subtracting(allowed).sorted())")
        // The section never lists ReplicaSets or pods, nor Jobs in a namespace on All Namespaces: the detail's.
        let children = requests.filter {
            let resource = Self.resource(of: $0.path)
            return resource == "replicasets" || resource == "pods" || (resource == "jobs" && $0.path.contains("/namespaces/"))
        }
        if asked.isEmpty { check("\(what): nothing asked — what was read within 30 s stands", children.isEmpty, "\(children.map(\.path))") }
        check(
            "\(what): ReplicaSets and pods by a selector, a CronJob's Jobs, in its namespaces only, as Table rows",
            children.allSatisfy { request in
                inItsNamespaces(request.path) && request.query["includeObject"] == "Metadata" && request.accept == KubeClient.tableOnlyAccept && !request.isWatch
                    && (Self.resource(of: request.path) == "jobs" || request.query["labelSelector"]?.isEmpty == false)
            }, "\(children.map { "\($0.path)?\($0.query)" })")
        let strays = requests.filter { Self.isObjectRead($0) && !members.contains($0.path) }
        check("\(what): no object read but its members' and the section's own", strays.count <= sectionGets, "\(strays.map(\.path)) beside \(sectionGets) of the section's")
        check("\(what): GETs only", requests.allSatisfy { $0.method == "GET" })
        check("\(what): never a Secret or a ConfigMap", !requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") })
    }

    /// A GET of one object in a namespace: `…/namespaces/<ns>/<kind>/<name>`.
    static func isObjectRead(_ request: FakeKubeAPI.Request) -> Bool {
        guard request.method == "GET", !request.isWatch else { return false }
        let parts = request.path.split(separator: "/")
        guard let at = parts.firstIndex(of: "namespaces") else { return false }
        return parts.count > at + 3
    }

    /// Part 3, beside Applications: a hub with most of its marked apps'
    /// Applications — the chip of those with none here; Applications
    /// refused everywhere — that header.
    private func kubernetesGitOpsMarksBeside(_ model: KubernetesModel, _ page: KubernetesPageModel, hub: FakeKubeAPI, refused: FakeKubeAPI, hubApps: [String]) async {
        let gitOps = page.gitOps
        hub.forgetRequests()
        model.select("fake-prod")
        check("fake-prod serves Argo CD", await eventually(15) { model.selectedName == "fake-prod" && page.gitOpsServed })
        model.setScope(.all)
        if page.section != .gitops { page.showSection(.gitops) }
        check(
            "its Applications read, the marked apps with none here beside them",
            await eventually(30) {
                guard case .beside = gitOps.marksMode else { return false }
                return gitOps.rows.beside.count == 3 && !gitOps.summarising
            }, "\(gitOps.marksMode) \(gitOps.rows.beside.count)")
        check(
            "the Applications as today, the marked apps with none here among them",
            gitOps.rows.shown.contains { $0.role == .application } && gitOps.rows.shown.filter(\.isMarked).count == 3)
        check("the chip drawn", await shownText(15) { $0.contains("3 marked apps with no Application here") } != nil)
        // The muted line, its chip not pressed: always while they are among the rows (14.2.1).
        let besideLimits = await overviewElement("kubernetes.gitops.marks.limits", timeout: 10)
        check(
            "what only the Application knows, said beside them unpressed", besideLimits?.text.contains("No sync status, repository or revision") == true,
            besideLimits?.text ?? "none")
        page.toggleGitOpsBeside()
        let beside = page.gitOpsVisibleRows
        check("pressed, those apps alone", Set(beside.compactMap { $0.marked?.key.instance }) == Set(hubApps.suffix(3)) && beside.allSatisfy(\.isMarked), "\(beside.map(\.ref.name))")
        check("each not in this cluster", beside.allSatisfy { $0.tags.contains(.text("not in this cluster")) && $0.hover.contains("Its Application isn't in this cluster.") })
        check("said on its row", await shownText(15) { $0.contains("not in this cluster") } != nil)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks-beside.png"))
        }
        page.toggleGitOpsBeside()
        checkMarksReads("fake-prod", hub.requests)

        refused.forgetRequests()
        model.select("kind-fake")
        check("kind-fake serves Argo CD", await eventually(15) { model.selectedName == "kind-fake" && page.gitOpsServed })
        model.setScope(.all)
        if page.section != .gitops { page.showSection(.gitops) }
        check(
            "Applications refused: the apps from marks", await eventually(30) { gitOps.marksMode == .only(.forbidden) && gitOps.marked.state == .live && !gitOps.rows.shown.isEmpty },
            "\(gitOps.marksMode)")
        let lead = await overviewElement("kubernetes.gitops.marks.lead", timeout: 10)
        check(
            "that header",
            lead?.text.contains("Argo CD's Applications can't be read in kind-fake (forbidden). These \(gitOps.marked.apps.count) apps are read from the marks on their objects.") == true,
            lead?.text ?? "none")
        check("never another cluster", lead?.text.contains("another cluster") == false)
        check("drawn", await shownText(15) { $0.contains("can't be read in kind-fake (forbidden)") } != nil)
        checkMarksReads("kind-fake", refused.requests)
        page.showKind(model.discovery?.kind("po") ?? .pods)
    }

    /// What one part read of a context, from its selection on (14.9.3:
    /// "for each part, the set of paths the part read"): the marks' kinds,
    /// Argo CD's own, and the page's own reads of a context it shows — the
    /// namespaces for its picker, the CRDs whose changes read discovery
    /// again (`KubernetesModel.crdName`); GETs; rows, never whole objects,
    /// watched; never a ReplicaSet or a pod; only the workloads,
    /// Applications and the page's CRDs watched.
    private func checkMarksReads(_ context: String, _ requests: [FakeKubeAPI.Request]) {
        let page: Set<String> = ["namespaces", "customresourcedefinitions"]
        let read = Set(requests.filter { !$0.isDiscovery }.compactMap { Self.resource(of: $0.path) })
        let allowed = Self.marksKinds.union(["applications", "applicationsets"]).union(page)
        check("\(context): only the marks' kinds and Argo CD's own read", !read.isEmpty && read.isSubset(of: allowed), "\(read.subtracting(allowed).sorted())")
        check("\(context): never a ReplicaSet or a pod", !read.contains("replicasets") && !read.contains("pods"))
        check("\(context): GETs only", requests.allSatisfy { $0.method == "GET" })
        let watched = Set(requests.filter(\.isWatch).compactMap { Self.resource(of: $0.path) })
        check(
            "\(context): Services, Ingresses, claims, Jobs, CronJobs and HPAs never watched",
            watched.isSubset(of: ["applications", "deployments", "statefulsets", "daemonsets", "rollouts", "customresourcedefinitions"]), "\(watched.sorted())")
        check("\(context): rows only, never whole objects watched", !requests.contains { $0.isWatch && $0.query["includeObject"] == "Object" })
    }

    /// The kinds the marks are read from (14.4.1): rows, and a GET of one object.
    static let marksKinds: Set<String> = [
        "deployments", "statefulsets", "daemonsets", "rollouts", "services", "ingresses", "persistentvolumeclaims", "jobs", "cronjobs", "horizontalpodautoscalers",
    ]

    /// A request's resource: what follows a namespace, else the API's version.
    static func resource(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let at = parts.firstIndex(of: "namespaces"), parts.count > at + 2 { return parts[at + 2] }
        guard let first = parts.first else { return nil }
        let start = first == "api" ? 2 : 3
        return parts.count > start ? parts[start] : nil
    }
}
