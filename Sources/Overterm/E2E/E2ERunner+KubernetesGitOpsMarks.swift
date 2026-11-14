import AppKit
import Foundation
import SwiftUI

/// D3 (docs/design/kubernetes/gitops.md, 14.2, 14.9.3) against fake API
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
///    its placeholder detail saying why Sync, Refresh, Rollback and Diff
///    aren't here, Esc closes it; its menu has no write.
/// 3. `is:marks`, `image:` and `G` by installation; beside Applications
///    read, the marked apps with no Application here among them and their
///    chip; Applications refused, that header.
///
/// Reads only: every request a GET; never a Secret or a ConfigMap; on the
/// spoke no Application and nothing of Flux's, and the section's own requests
/// only of the kinds the marks are read from (rows, a GET of one object),
/// never a watch of Services, Ingresses, claims, Jobs, CronJobs or HPAs.
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
        await kubernetesGitOpsMarksBeside(model, page, hub: hub, refused: refused, hubApps: hubApps)

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

        // The chips, problems first, Hide Ready on.
        let chips = KubeGitOpsSection.chips(gitOps.rows.shown)
        let failing = chips.first { $0.state == .failed }?.count ?? 0
        check("the failing chip counts the failing apps", failing == gitOps.rows.shown.count { $0.state == .failed } && failing >= 3, "\(chips.map { "\($0.state.word) \($0.count)" })")
        check("drawn", await shownText(15) { $0.contains("\(failing) failing") } != nil)
        let ready = chips.first { $0.state == .ready }?.count ?? 0
        let fromRows = gitOps.rows.shown.count { $0.state == .ready && $0.marked?.fromRows == true }
        let readyText = KubeGitOpsSection.chipText(.ready, ready, fromRows: fromRows)
        check("the Ready chip says what is from rows only", fromRows == 0 || readyText.contains("from rows only"), readyText)
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

        // ↩ on a failing app: its placeholder detail; Esc closes it.
        guard let stalled = row(made.stalled) else { return check("the stalled app's row", false) }
        check("its menu has no write", page.gitOpsVerbs(for: [stalled.id]).allSatisfy { !["Sync", "Refresh", "Rollback", "Diff", "Delete…", "Restart…"].contains($0.title) && $0.place != .remove })
        page.gitOpsView.selection = [stalled.id]
        page.giveListTheKeyboard()
        spoke.forgetRequests()
        check("↩ is the section's", await pressKubernetesKey("\r", keyCode: 36))
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
        let detailRead = Set(spoke.requests.filter { !$0.isDiscovery }.compactMap { Self.resource(of: $0.path) })
        check("nothing new read for it: what the section holds", detailRead.isSubset(of: Self.marksKinds.union(["namespaces"])), "\(detailRead.sorted())")
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

    /// Part 3, beside Applications: a hub with most of its marked apps'
    /// Applications — the chip of those with none here; Applications
    /// refused everywhere — that header.
    private func kubernetesGitOpsMarksBeside(_ model: KubernetesModel, _ page: KubernetesPageModel, hub: FakeKubeAPI, refused: FakeKubeAPI, hubApps: [String]) async {
        let gitOps = page.gitOps
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
        page.toggleGitOpsBeside()
        let beside = page.gitOpsVisibleRows
        check("pressed, those apps alone", Set(beside.compactMap { $0.marked?.key.instance }) == Set(hubApps.suffix(3)) && beside.allSatisfy(\.isMarked), "\(beside.map(\.ref.name))")
        check("each not in this cluster", beside.allSatisfy { $0.tags.contains(.text("not in this cluster")) && $0.hover.contains("Its Application isn't in this cluster.") })
        check("said on its row", await shownText(15) { $0.contains("not in this cluster") } != nil)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-kube-gitops-marks-beside.png"))
        }
        page.toggleGitOpsBeside()

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
        page.showKind(model.discovery?.kind("po") ?? .pods)
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
