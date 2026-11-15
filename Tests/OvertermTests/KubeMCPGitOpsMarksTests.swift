import XCTest

@testable import Overterm

/// `k8s_gitops` where no Argo CD Application here deploys the apps (docs/
/// design/kubernetes/gitops.md, 14.2.6, D6) against `FakeKubeAPI`'s spoke on
/// a socket of the test's own (`addSpoke`: the survey's shape, fictional
/// names) and a kubeconfig of fictional contexts — never a real cluster,
/// never ~/.kube: the apps read from the marks Argo CD leaves on their
/// objects, problems first, one line each, scrubbed — never "serves
/// neither"; the opening line in the mode's words, "another cluster" only
/// where Applications aren't served and argoproj.io answered discovery;
/// `kind: "application"` never derived apps, `kind: "marks"` only them,
/// Ready ones listed only with `state: "all"`; the agent's bounds — rows of
/// the workloads' kinds, a GET of at most 20 that may be problems, 4 in
/// flight —; a cut or refused read said, never "no marked apps"; the
/// page's section's fresh store answering with no request at all; the
/// checkout's own app with its health, option B's "describes", never
/// "owns". Every test ends with only GETs, never a Secret, a ConfigMap or
/// a list of the marks' kinds' whole objects; an agent's read is once,
/// never a watch (a test showing the page's section has its follows).
@MainActor
final class KubeMCPGitOpsMarksTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var spoke = FakeKubeAPI.Spoke()
    private var kept: (rows: KubeMarkedAppsSession.Bounds, cache: KubeGitOpsMatchCache, checkouts: KubeGitOpsCheckouts, bindings: KubeBindingStore, pane: ((String) -> URL?)?)!
    private var folder: URL?
    private var pages: [KubernetesPageModel] = []

    override func setUp() async throws {
        socket = "/tmp/otkmm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        spoke = api.addSpoke(FakeKubeAPI.SpokeOptions(apps: 12))
        kept = (KubeMCP.marksRows, KubeMCP.gitOpsCache, KubeMCP.gitOpsCheckouts, KubeMCP.bindings, KubeMCP.paneCheckout)
        KubeMCP.gitOpsCache = KubeGitOpsMatchCache()
        let checkouts = KubeGitOpsCheckouts()
        checkouts.git = KubeGitOpsCheckouts.isolatedGit
        KubeMCP.gitOpsCheckouts = checkouts
        KubeMCP.forgetDiscoveries()
    }

    override func tearDown() async throws {
        for page in pages { page.model.hide() }
        pages = []
        if let kept {
            KubeMCP.marksRows = kept.rows
            KubeMCP.gitOpsCache = kept.cache
            KubeMCP.gitOpsCheckouts = kept.checkouts
            KubeMCP.bindings = kept.bindings
            KubeMCP.paneCheckout = kept.pane
        }
        if let api {
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }.map(\.description), [], "only GETs: no write, not even a review")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") }, "never a Secret or a ConfigMap")
            let marksKinds = ["/deployments", "/statefulsets", "/daemonsets", "/rollouts"]
            let whole = api.requests.filter { request in
                !request.isDiscovery && !request.accept.contains("as=Table") && marksKinds.contains { request.path.hasSuffix($0) }
            }
            XCTAssertEqual(whole.map(\.description), [], "rows, and a GET of one: never a list of whole objects")
            api.stop()
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeModel(_ contexts: KubeContextList = KubeMCPTests.list(current: "fake-dev")) -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        model.load = { _ in contexts }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return model
    }

    private lazy var model: KubernetesModel = makeModel()

    private func call(_ arguments: [String: Any], model given: KubernetesModel? = nil, pane: String? = nil) async -> (text: String, error: Bool) {
        let model = given ?? self.model
        if model.selectedName == nil {
            model.reloadContexts()
            var waited = 0
            while model.selectedName == nil && waited < 500 {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
        }
        do {
            let result = try await KubeMCP.call("k8s_gitops", arguments, kubernetes: model, pane: pane)
            return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool == true)
        } catch let error as BrowserMCP.ToolError {
            return (error.message, true)
        } catch {
            return ("\(error)", true)
        }
    }

    private func text(_ arguments: [String: Any] = [:], model: KubernetesModel? = nil, pane: String? = nil, file: StaticString = #filePath, line: UInt = #line) async -> String {
        let answer = await call(arguments, model: model, pane: pane)
        XCTAssertFalse(answer.error, answer.text, file: file, line: line)
        XCTAssertFalse(answer.text.contains(FakeKubeAPI.gitOpsSentinel), "the sentinel in:\n\(answer.text)", file: file, line: line)
        return answer.text
    }

    private func apps(_ text: String) -> [String] { text.components(separatedBy: "\n").filter { $0.hasPrefix("marks  ") } }

    private static let notServed =
        "Argo CD runs in another cluster (not in the kubeconfig); apps read from the marks on their objects; no sync status, repository or revision."

    // MARK: A spoke

    /// Argo CD runs in another cluster: its apps read from their marks,
    /// problems first — the stalled rollout Failed by its object's GET,
    /// the StatefulSet `0/3` Progressing, never Failed — one line each, the
    /// Ready ones counted ("from rows only": no settle for an agent), the
    /// reads said; never "serves neither", nothing of Argo CD's or Flux's
    /// asked.
    func testOnASpokeAnAgentGetsAppsProblemsFirstNotServesNeither() async throws {
        let said = await text(["namespace": "all"])
        let lines = said.components(separatedBy: "\n")
        XCTAssertEqual(lines.dropFirst().first, Self.notServed, said)
        XCTAssertFalse(said.contains("serves neither"), said)
        XCTAssertTrue(said.contains("fake-dev serves no Flux kind."), said)
        let shown = apps(said)
        XCTAssertEqual(shown.count, 2, "the stalled rollout and the StatefulSet, the rest Ready:\n\(said)")
        let stalled = try XCTUnwrap(shown.first)
        XCTAssertTrue(stalled.hasPrefix("marks  Failed  \(spoke.stalled)  ns=team-2  1 Deploy  rollout stalled (ProgressDeadlineExceeded): Deployment acme-cart"), stalled)
        XCTAssertTrue(stalled.contains("image=…/acme-cart:4.12.0"), stalled)
        let ledger = shown[1]
        XCTAssertTrue(ledger.hasPrefix("marks  Progressing  \(spoke.statefulSet)  ns=team-4  1 STS  0/3 ready: StatefulSet acme-ledger-db"), ledger)
        let ready = spoke.apps.count + 7
        XCTAssertTrue(
            said.contains("apps read from marks in any namespace, problems first: 1 Failed, 1 Progressing, \(ready) Ready ("), said)
        XCTAssertTrue(said.contains("\(ready) Ready apps counted, not listed: kind marks with state all lists them."), said)
        XCTAssertTrue(said.contains("then 2 objects settled by Argo CD's rule"), said)
        XCTAssertTrue(said.contains("2 marks Argo CD wouldn't write: counted, never shown."), said)
        XCTAssertTrue(said.contains("1 workload with Helm's instance label alone: not Argo CD's apps."), said)
        // The two that may be problems read by a GET of one each; the rest from their rows.
        let gets = api.requests.filter { !$0.isWatch && !$0.isDiscovery && !$0.accept.contains("as=Table") }.map(\.path)
        XCTAssertEqual(
            Set(gets), ["/apis/apps/v1/namespaces/team-2/deployments/acme-cart", "/apis/apps/v1/namespaces/team-4/statefulsets/acme-ledger-db"], "\(gets)")
        XCTAssertTrue(api.requests.filter { $0.accept.contains("as=Table") }.allSatisfy { $0.query["includeObject"] == "Metadata" }, "rows with their marks")
        XCTAssertFalse(api.requests.contains { $0.path.contains("argoproj.io") || $0.path.contains("fluxcd.io") }, "nothing of Argo CD's or Flux's where neither is served")
        XCTAssertFalse(api.requests.contains { ["/services", "/horizontalpodautoscalers", "/cronjobs", "/jobs", "/ingresses", "/persistentvolumeclaims"].contains(where: $0.path.hasSuffix) })
        XCTAssertFalse(api.requests.contains { $0.isWatch }, "read once, never followed")
    }

    /// The opening line follows the mode's reason: "another cluster" only
    /// where Applications aren't served and argoproj.io answered discovery
    /// (a down metrics.k8s.io says nothing of Argo CD); argoproj.io not
    /// answering, "couldn't tell"; served with none listed, "aren't in this
    /// cluster"; refused everywhere, "can't be read".
    func testTheOpeningLineFollowsTheModesReason() async throws {
        api.failingGroups = ["metrics.k8s.io/v1beta1"]
        var said = await text(["namespace": "all"])
        XCTAssertTrue(said.contains(Self.notServed), said)

        // Argo Workflows' group served, and failing: whether Applications are there can't be told.
        api.addCRD(group: "argoproj.io", version: "v1alpha1", plural: "workflows", kind: "Workflow")
        api.failingGroups = ["argoproj.io/v1alpha1"]
        KubeMCP.forgetDiscoveries()
        said = await text(["namespace": "all"])
        XCTAssertTrue(
            said.contains("Couldn't tell whether Argo CD runs in fake-dev (argoproj.io didn't answer discovery); apps read from the marks on their objects"), said)
        XCTAssertFalse(said.contains("another cluster"), said)
        XCTAssertFalse(apps(said).isEmpty, said)

        api.failingGroups = []
        api.serveArgoCD()
        KubeMCP.forgetDiscoveries()
        api.forgetRequests()
        said = await text(["namespace": "all"])
        XCTAssertTrue(said.contains("Argo CD's Applications for these aren't in this cluster (none is listed here); apps read from the marks"), said)
        XCTAssertFalse(said.contains("another cluster"), said)
        XCTAssertFalse(said.contains("No GitOps objects"), "the apps from marks are its Argo CD side: \(said)")
        XCTAssertFalse(apps(said).isEmpty, said)
        XCTAssertEqual(api.requests.filter { $0.path == "/apis/argoproj.io/v1alpha1/applications" }.count, 1, "Applications listed once across the cluster")

        api.forbidden = ["applications@cluster", "applications@argocd"]
        KubeMCP.forgetDiscoveries()
        said = await text(["namespace": "all"])
        XCTAssertTrue(said.contains("Argo CD's Applications can't be read in fake-dev (forbidden); apps read from the marks"), said)
        XCTAssertFalse(said.contains("another cluster"), said)
        XCTAssertTrue(said.contains("Applications: forbidden across the cluster"), said)
    }

    /// `kind: "application"` is Argo CD's own Applications, never an app
    /// read from marks; `kind: "marks"` only those, its Ready ones listed
    /// with `state: "all"` — never with `kind: "all"`.
    func testKindApplicationExcludesDerivedAppsAndKindMarksListsThem() async throws {
        let applications = await text(["kind": "application", "namespace": "all"])
        XCTAssertTrue(apps(applications).isEmpty, applications)
        XCTAssertTrue(applications.contains("fake-dev serves neither Argo CD's Applications nor any Flux kind."), applications)
        XCTAssertTrue(applications.contains(KubeMCP.marksHint), applications)

        let marks = await text(["kind": "marks", "namespace": "all"])
        XCTAssertEqual(apps(marks).count, 2, marks)
        let every = await text(["kind": "marks", "namespace": "all", "state": "all"])
        let all = apps(every)
        XCTAssertEqual(all.count, spoke.apps.count + 9, every)
        XCTAssertTrue(all.first?.hasPrefix("marks  Failed") == true && all.last?.hasPrefix("marks  Ready") == true, every)
        XCTAssertTrue(all.contains { $0.contains(spoke.labelOnly) && $0.contains("(label only)") }, every)
        XCTAssertFalse(every.contains("counted, not listed"), every)
        let allKinds = await text(["namespace": "all", "state": "all"])
        XCTAssertEqual(apps(allKinds).count, 2, "kind all lists the problems alone: \(allKinds)")
        let failing = await text(["kind": "marks", "namespace": "all", "failing_only": true])
        XCTAssertEqual(apps(failing).map { $0.contains(spoke.stalled) }, [true], failing)
        let wrong = await call(["state": "some"])
        XCTAssertTrue(wrong.error && wrong.text.contains("“state” is problems or all"), wrong.text)
        let kind = await call(["kind": "pods"])
        XCTAssertTrue(kind.error && kind.text.contains("marks"), kind.text)
    }

    /// One namespace: only its apps, read in it.
    func testANamespacesAppsReadInIt() async throws {
        let said = await text(["namespace": "team-2"])
        XCTAssertEqual(apps(said).count, 1, said)
        XCTAssertTrue(said.contains("apps read from marks in or deploying into namespace team-2"), said)
        let rows = api.requests.filter { $0.accept.contains("as=Table") }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.path.contains("/namespaces/team-2/") }, "\(rows.map(\.path))")
    }

    // MARK: Bounds

    /// At most 20 GETs, of those that may be problems, the most recently
    /// changed by Argo CD first, 4 in flight; the rest said "not settled",
    /// never as if they had been.
    func testAtMostTwentyGetsFourInFlightTheRestSaid() async throws {
        // 30 plain apps not ready by their rows: 32 that may be problems.
        let extra = api.addSpoke(FakeKubeAPI.SpokeOptions(apps: 30, namespaces: ["team-x"], padding: 0, states: false))
        for (namespace, name) in extra.deployments {
            api.modify("deployments.apps", name, namespace: namespace, values: ["Ready": "1/2", "Available": 1]) { _ in }
            api.answerSlowly("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)", milliseconds: 150)
        }
        api.forgetRequests()
        let said = await text(["namespace": "all"])
        let gets = api.requests.filter { !$0.isWatch && !$0.isDiscovery && !$0.accept.contains("as=Table") }
        XCTAssertEqual(gets.count, KubeMCP.marksGets, "\(gets.map(\.path))")
        XCTAssertLessThanOrEqual(api.mostHeldAnswers, KubeMarkedDetailSession.inFlight, "4 in flight at most")
        XCTAssertTrue(said.contains("12 workloads not ready by their rows not settled by Argo CD's rule (an agent reads 20 objects at most)."), said)
        XCTAssertTrue(said.contains("then 20 objects settled by Argo CD's rule"), said)
        // At most 100 lines; the rest counted by state.
        XCTAssertLessThanOrEqual(apps(said).count, KubeMCP.marksLines)
    }

    /// A read cut short or refused says what was read — "At least N apps",
    /// "No Argo CD marks found in what could be read" — never that nothing
    /// carries marks, never "no marked apps".
    func testACutOrRefusedReadNeverAnswersNoMarkedApps() async throws {
        KubeMCP.marksRows.rowsObjects = 5
        var said = await text(["namespace": "all"])
        XCTAssertTrue(said.contains("At least"), said)
        XCTAssertTrue(said.contains("Deployments: the list stopped at 5; the rest not read"), said)
        XCTAssertFalse(said.contains("carries Argo CD's marks"), said)

        KubeMCP.marksRows = kept.rows
        api.forbidden = ["deployments@cluster", "statefulsets@cluster", "daemonsets@cluster"]
        said = await text(["namespace": "all"])
        XCTAssertTrue(apps(said).isEmpty, said)
        XCTAssertTrue(said.contains("No Argo CD marks found in what could be read: Deployments refused across the cluster"), said)
        XCTAssertFalse(said.contains("carries Argo CD's marks"), said)
        XCTAssertFalse(said.lowercased().contains("no marked app"), said)
        XCTAssertFalse(said.contains("another cluster"), "no app read: nothing said of where Argo CD runs")

        // Refused across the cluster, read where the context says it may be — once, no "every 5 min".
        let accessible = makeModel(KubeMCPTests.list(current: "fake-dev", devSettings: KubeContextSettings(accessibleNamespaces: ["team-2", "team-4"])))
        said = await text(["namespace": "all"], model: accessible)
        XCTAssertTrue(said.contains("Deployments refused across the cluster; read in team-2, team-4"), said)
        XCTAssertFalse(said.contains("every 5 min"), said)
        XCTAssertTrue(said.contains("At least"), said)
        XCTAssertTrue(apps(said).contains { $0.contains(spoke.stalled) }, "team-2's stalled app read where it may be: \(said)")
    }

    /// A whole read with no mark says so — only then.
    func testAWholeReadWithNoMarkSaysNoneCarriesThem() async throws {
        api.stop()
        socket = "/tmp/otkmm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.add("deployments.apps", "shop-api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1])
        model = makeModel()
        let said = await text(["namespace": "all"])
        XCTAssertTrue(
            said.contains("No Argo CD Application is served by fake-dev, and no Deployment, StatefulSet or DaemonSet in all namespaces carries Argo CD's marks."), said)
        XCTAssertFalse(said.contains("another cluster"), said)
        XCTAssertTrue(apps(said).isEmpty)
    }

    /// Beside Applications listed whole, apps grouped by
    /// `app.kubernetes.io/instance` alone (no tracking id or instance label
    /// anywhere: Helm's, kustomize's, a hub's label-tracked apps) are only
    /// probably Argo CD's — never compared with the Applications, never
    /// listed, never said to have one or to lack one (14.3).
    func testBesideApplicationsAppsByTheInstanceLabelAloneAreOnlyProbable() async throws {
        api.stop()
        socket = "/tmp/otkmm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.serveArgoCD()
        api.addNamespace("shop")
        api.addApplication(
            "acme-shop",
            spec: [
                "project": "acme", "source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "deploy", "targetRevision": "main"],
                "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
            ],
            status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        for name in ["acme-web", "acme-worker"] {
            api.addMarkedDeployment(name, namespace: "shop", app: nil, labels: ["app.kubernetes.io/instance": "fake-\(name)"], padding: 0, now: Date())
        }
        model = makeModel()
        let said = await text(["kind": "marks", "namespace": "all"])
        XCTAssertTrue(said.contains("the 2 apps grouped by app.kubernetes.io/instance are only probably Argo CD's"), said)
        XCTAssertTrue(said.contains("none is listed, nor said to lack one"), said)
        XCTAssertFalse(said.contains("has an Application of its name here"), "nothing compared them: \(said)")
        XCTAssertTrue(apps(said).isEmpty, said)
    }

    /// Kind marks beside Applications served whose read can't say which
    /// marked apps have none here: said by its cause — couldn't be read, or
    /// cut at the agent's bound —, never one for the other.
    func testKindMarksSaysWhyTheApplicationsReadCantTell() async throws {
        api.serveArgoCD()
        let spec: [String: Any] = [
            "project": "acme", "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps", "targetRevision": "main"],
            "destination": ["server": "https://kubernetes.default.svc", "namespace": "team-0"],
        ]
        let status: [String: Any] = ["sync": ["status": "Synced"], "health": ["status": "Healthy"]]
        api.addApplication("acme-fleet", spec: spec, status: status)
        api.failingResources = ["applications"]
        var said = await text(["kind": "marks", "namespace": "all"])
        XCTAssertTrue(said.contains("Argo CD's Applications are served here and couldn't be read — "), said)
        XCTAssertFalse(said.contains("cut at") || said.contains("200"), "nothing was cut: \(said)")
        XCTAssertTrue(apps(said).isEmpty, said)

        api.failingResources = []
        for index in 0..<KubeMCP.gitOpsObjects { api.addApplication(String(format: "acme-app-%03d", index), spec: spec, status: status) }
        said = await text(["kind": "marks", "namespace": "all"])
        XCTAssertTrue(said.contains("Argo CD's Applications are served here and were cut at an agent's bound (200 objects or 16 MB a kind)"), said)
        XCTAssertFalse(said.contains("couldn't be read"), said)
    }

    /// Argo Rollouts served but refused across the cluster, nowhere else to
    /// read them: an app a Rollout runs — its Deployment scaled to 0 by it —
    /// is Unknown, never counted Ready from its Deployment's 0.
    func testRolloutsRefusedTheirAppsAreUnknownNeverReady() async throws {
        api.stop()
        socket = "/tmp/otkmm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        spoke = api.addSpoke(FakeKubeAPI.SpokeOptions(apps: 6, rollouts: true))
        api.forbidden = ["rollouts@cluster"]
        model = makeModel()
        let said = await text(["namespace": "all"])
        let canary = try XCTUnwrap(apps(said).first { $0.contains(spoke.rollout) }, "its Rollout unread, its app isn't Ready: \(said)")
        XCTAssertTrue(canary.hasPrefix("marks  Unknown  \(spoke.rollout)  ns=team-0  1 Deploy"), canary)
        XCTAssertTrue(canary.contains("scaled to 0; an Argo Rollout may run it (Argo Rollouts can't be read here (forbidden))"), canary)
        XCTAssertTrue(apps(said).contains { $0.hasPrefix("marks  Unknown  \(spoke.rolloutDegraded)") }, said)
        XCTAssertTrue(said.contains("Rollouts refused across the cluster"), said)
    }

    /// Argo Rollouts served: read for their apps' health only — a Rollout's
    /// phase by a GET of it, its Deployment scaled by it; never an
    /// Application.
    func testRolloutsAreReadForTheirAppsHealthOnly() async throws {
        api.stop()
        socket = "/tmp/otkmm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        spoke = api.addSpoke(FakeKubeAPI.SpokeOptions(apps: 6, rollouts: true))
        model = makeModel()
        let said = await text(["namespace": "all"])
        let blue = try XCTUnwrap(apps(said).first { $0.contains(spoke.rolloutDegraded) }, said)
        XCTAssertTrue(blue.hasPrefix("marks  Failed  \(spoke.rolloutDegraded)  ns=team-1  1 Deploy 1 Rollout  rollout degraded: Rollout acme-blue"), blue)
        XCTAssertFalse(apps(said).contains { $0.contains(spoke.rollout) }, "the Healthy Rollout's app is Ready: \(said)")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/namespaces/team-1/rollouts/acme-blue" }, "its phase by a GET")
        XCTAssertFalse(api.requests.contains { $0.path.contains("/applications") }, "never an Application")
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/team-1/deployments/acme-blue" }, "its Deployment, scaled by it, isn't asked")
    }

    // MARK: The section's store

    /// The page's GitOps section ranked the apps in the last five minutes,
    /// in a scope covering the call's: they are answered as they are, with
    /// their age, and nothing is asked of the cluster — the stuck single
    /// replica Progressing as the section settled it, the HPA's metrics
    /// Failed as the section read them. A narrower scope's section isn't an
    /// answer for all namespaces: read again.
    func testThePagesFreshStoreIsUsedWithNoRequest() async throws {
        let model = makeModel(KubeContextList(contexts: ["fake-dev", "fake-prod", "kind-fake"].map { KubeWritesTests.context($0) }, current: "kind-fake"))
        let page = KubernetesPageModel(model: model)
        pages.append(page)
        page.gitOps.flushInterval = .milliseconds(20)
        page.gitOps.marked.flushInterval = .milliseconds(20)
        // The section's own GETs again only on a row's move: none comes, so any read of the marks' kinds below is the agent's.
        page.gitOps.marked.tickInterval = .seconds(3600)
        page.actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        page.visible = true
        model.flushInterval = .milliseconds(20)
        model.show()
        try await until("listed") { model.selectedName == "kind-fake" && model.discovery?.kind("deploy") != nil }
        model.setScope(.all)
        XCTAssertTrue(page.press("g"))
        try await until("the section's apps settled and kept", 30) {
            let marked = page.gitOps.marked
            return marked.state == .live && marked.refetchIdle && marked.isMerged && !marked.reading.isReading
                && model.markedApps(of: model.contexts.context(named: "kind-fake")!)?.apps.count == marked.apps.count
                && marked.apps.first { $0.app.key.instance == self.spoke.stuck }?.health.state == .progressing
        }
        api.forgetRequests()
        let said = await text(["context": "kind-fake", "namespace": "all"], model: model)
        XCTAssertEqual(marksReads(), [], "nothing asked: the section's store answered")
        XCTAssertTrue(said.contains("As the GitOps section on the Kubernetes page read them"), said)
        XCTAssertTrue(said.contains("nothing read for this answer"), said)
        XCTAssertTrue(apps(said).contains { $0.hasPrefix("marks  Progressing  \(spoke.stuck)") }, "settled by the section: \(said)")
        XCTAssertTrue(apps(said).contains { $0.hasPrefix("marks  Failed  \(spoke.hpa)") && $0.contains("1 HPA") }, said)
        // One namespace of it: from the store too.
        let one = await text(["context": "kind-fake", "namespace": "team-2"], model: model)
        XCTAssertEqual(marksReads(), [])
        XCTAssertTrue(apps(one).allSatisfy { $0.contains("ns=team-2") } && !apps(one).isEmpty, one)

        // The section on one namespace: no answer for all of them.
        model.setScope(.namespace("team-2"))
        try await until("the section read team-2", 30) {
            page.gitOps.marked.scope == .namespace("team-2") && page.gitOps.marked.state == .live && !page.gitOps.marked.reading.isReading
                && model.markedApps(of: model.contexts.context(named: "kind-fake")!)?.scope == .namespace("team-2")
        }
        api.forgetRequests()
        let all = await text(["context": "kind-fake", "namespace": "all"], model: model)
        XCTAssertTrue(all.contains("Read for this answer"), all)
        XCTAssertFalse(marksReads().isEmpty, "read again")
    }

    /// What reads the marks' kinds — a list that isn't a watch, a GET of one
    /// — and discovery: an agent's reads, the section's follows aside.
    private func marksReads() -> [String] {
        let kinds = ["/deployments", "/statefulsets", "/daemonsets", "/rollouts"]
        return api.requests.filter { request in
            guard !request.isWatch else { return false }
            return request.isDiscovery || kinds.contains { request.path.hasSuffix($0) || request.path.contains("\($0)/") }
        }.map(\.description)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: checkout: true

    /// The checkout bound to team-3: its app read from the bound
    /// Deployment's marks, Paused by its one GET though its cells read
    /// 2/2, "health of the 1 object bound here", "Argo CD runs in another
    /// cluster" — in place of the owner's "not in" line; on production the
    /// cluster's workloads aren't listed for option B.
    func testCheckoutSaysItsAppAndHealth() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-mcp-marks-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        let repo = folder.appendingPathComponent("acme-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# acme-batch\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "batch"], ["remote", "add", "origin", "git@git.acme.example:acme/acme-batch.git"]] {
            _ = try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
        }
        let store = KubeBindingStore(file: folder.appendingPathComponent("bindings.json"))
        KubeMCP.bindings = store
        KubeMCP.paneCheckout = { $0 == "pane-bound" ? repo : nil }
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-prod", namespace: "team-3", selector: "app=acme-batch")))
        let said = await text(["checkout": true], pane: "pane-bound")
        let shown = apps(said)
        let paused = try XCTUnwrap(shown.first { $0.contains(spoke.paused) }, said)
        XCTAssertTrue(paused.hasPrefix("marks  Paused  \(spoke.paused)  ns=team-3  1 Deploy  rollout paused: Deployment acme-batch"), paused)
        XCTAssertTrue(said.contains("  matched: owns Deployment/acme-batch"), said)
        XCTAssertTrue(said.contains("  health of the 1 object bound here; other namespaces not read"), said)
        XCTAssertTrue(said.contains("  Argo CD runs in another cluster — not in your kubeconfig"), said)
        XCTAssertTrue(said.contains("Argo CD isn't in fake-prod; read from the marks on team-3's workloads."), said)
        XCTAssertFalse(said.contains("(not in fake-prod)"), "its owner's \"not in\" line is its app's now: \(said)")
        XCTAssertTrue(said.contains("only once Find What Deploys This is pressed in the rail"), "production: no list across the cluster: \(said)")
        XCTAssertFalse(api.requests.contains { ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets"].contains($0.path) })
        XCTAssertEqual(api.requests.filter { $0.path == "/apis/apps/v1/namespaces/team-3/deployments/acme-batch" }.count, 1, "one GET of it")
        let checkoutOnly = await text(["checkout": true, "kind": "application"], pane: "pane-bound")
        XCTAssertTrue(apps(checkoutOnly).isEmpty, "kind application: never an app read from marks")
        // Its owner's own line stays — kind application says no app read from marks in its place, so never "nothing found".
        XCTAssertTrue(checkoutOnly.contains("managed by Argo CD Application \(spoke.paused) (not in fake-prod)"), checkoutOnly)
        XCTAssertFalse(checkoutOnly.contains("Nothing found"), checkoutOnly)
    }

    /// The checkout of a config repository on a cluster serving Argo CD's
    /// Applications with none here (the survey's development cluster): one
    /// row of them asked, as the rail asks it, says none is here — its apps
    /// read from marks "aren't in fake-dev", never "couldn't be read"; the
    /// rail's own comparison of the last five minutes says the same with its
    /// reason, nothing listed again for it.
    func testCheckoutWhereApplicationsAreServedWithNoneSaysTheyArentHere() async throws {
        api.serveArgoCD()
        KubeMCP.forgetDiscoveries()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-mcp-marks-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        let repo = folder.appendingPathComponent("fleet", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("apps/acme-search"), withIntermediateDirectories: true)
        try "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: acme-search\n  namespace: team-5\n".write(
            to: repo.appendingPathComponent("apps/acme-search/deployment.yaml"), atomically: true, encoding: .utf8)
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "fleet"], ["remote", "add", "origin", "git@git.acme.example:acme/fleet.git"]] {
            _ = try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
        }
        let store = KubeBindingStore(file: folder.appendingPathComponent("bindings.json"))
        KubeMCP.bindings = store
        KubeMCP.paneCheckout = { $0 == "pane-fleet" ? repo : nil }
        let binding = KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "team-0", selector: "app=fake-metrics-agent")
        XCTAssertTrue(store.set(binding))
        model.sawMarks(in: "fake-dev")
        let line = "Argo CD's Applications aren't in fake-dev; read from the marks on the cluster's workloads."

        // The agent's own: one row of Applications asked, none there.
        var said = await text(["checkout": true], pane: "pane-fleet")
        XCTAssertTrue(said.contains(line), said)
        XCTAssertTrue(apps(said).contains { $0.contains(spoke.hpa) }, said)
        XCTAssertTrue(said.contains("  matched: this checkout's manifests describe 1 of its 1 object read here"), said)
        XCTAssertTrue(said.contains("  its Application isn't in fake-dev"), said)
        XCTAssertFalse(said.contains("couldn't be read in fake-dev"), said)
        XCTAssertFalse(said.contains("Nothing found"), said)
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/applications" && $0.query["limit"] == "1" && $0.query["includeObject"] == "None" },
            "one row of Applications across the cluster, as the rail asks it")

        // The rail's comparison of the last five minutes: its reason with it, nothing listed again.
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev"))
        let discovery = try await client.discover()
        // The checkout as the binding keeps it (its real path), what the rail keys its listing by.
        let checkout = KubeBindingStore.key(repo)
        let facts = await KubeMCP.gitOpsCheckouts.facts(URL(fileURLWithPath: checkout))
        let read = await KubePanelGitOps.markedListing(
            client: client, discovery: discovery, checkout: facts, namespace: "team-0", reason: nil, accessible: [], section: nil, git: KubeMCP.gitOpsCheckouts.git)
        let listing = try XCTUnwrap(try read.get())
        XCTAssertEqual(listing.reason, .noApplications)
        KubeMCP.gitOpsCache.keep(
            listing,
            for: KubeGitOpsMatchCache.Key(
                context: "fake-dev", checkout: checkout, namespace: "team-0", remotes: facts.remotesKey, mode: KubePanelGitOps.mode(of: discovery)))
        api.forgetRequests()
        said = await text(["checkout": true], pane: "pane-fleet")
        XCTAssertTrue(said.contains("as the rail compared them in the last five minutes"), said)
        XCTAssertTrue(said.contains(line), said)
        XCTAssertTrue(said.contains("  its Application isn't in fake-dev"), "the rail's reason, never \"couldn't be read\": \(said)")
        XCTAssertFalse(said.contains("couldn't be read in fake-dev"), said)
        XCTAssertFalse(api.requests.contains { ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets"].contains($0.path) }, "nothing listed again")
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/applications" && $0.query["limit"] == "1" })
    }

    /// Off production, a config repository's committed manifest naming an
    /// app's object is option B: the app "describes 1 of its objects",
    /// never that it deploys the checkout, never "owns"; the cluster's
    /// marked workloads listed as rows for it, the checkout's YAML read.
    func testCheckoutOptionBDescribesNeverOwns() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-mcp-marks-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        let repo = folder.appendingPathComponent("fleet", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("apps/acme-search"), withIntermediateDirectories: true)
        try "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: acme-search\n  namespace: team-5\n".write(
            to: repo.appendingPathComponent("apps/acme-search/deployment.yaml"), atomically: true, encoding: .utf8)
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "fleet"], ["remote", "add", "origin", "git@git.acme.example:acme/fleet.git"]] {
            _ = try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
        }
        let store = KubeBindingStore(file: folder.appendingPathComponent("bindings.json"))
        KubeMCP.bindings = store
        KubeMCP.paneCheckout = { $0 == "pane-fleet" ? repo : nil }
        // Bound to Helm's own agent: no Argo CD mark of its own, so A finds nothing.
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "team-0", selector: "app=fake-metrics-agent")))
        // Something here carries a mark (a list's rows showed one): B lists.
        model.sawMarks(in: "fake-dev")
        let said = await text(["checkout": true], pane: "pane-fleet")
        let search = try XCTUnwrap(apps(said).first { $0.contains(spoke.hpa) }, said)
        XCTAssertTrue(search.hasPrefix("marks  Ready (from rows)  \(spoke.hpa)  ns=team-5  1 Deploy"), "its workload from its row: B reads rows: \(search)")
        XCTAssertTrue(said.contains("  matched: this checkout's manifests describe 1 of its 1 object read here"), said)
        XCTAssertTrue(said.contains("  health of its 1 workload, from their rows"), said)
        XCTAssertFalse(said.contains("matched: owns"), "identity isn't provenance: \(said)")
        XCTAssertFalse(said.lowercased().contains("deploys this checkout:"), said)
        XCTAssertTrue(said.contains("Argo CD isn't in fake-dev; read from the marks on the cluster's workloads."), said)
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/deployments" && $0.query["includeObject"] == "Metadata" && !$0.isWatch }, "the marks listed across the cluster")
    }

    /// The checkout of a service deployed into three namespaces, bound in
    /// one of them (gitops.md 14.9.4: on the surveyed spokes, apps with a
    /// Deployment that share a name were never in one namespace): its app
    /// said "probably" by its name and image, the two elsewhere counted on
    /// a line of their own — never listed, never "too many to tell" —, as
    /// the rail says it; with failing_only, the healthy ones neither.
    func testCheckoutByNameSaysTheBoundNamespacesAppAndCountsTheRest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-mcp-marks-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        let repo = folder.appendingPathComponent("acme-relay", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# acme-relay\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "relay"], ["remote", "add", "origin", "git@git.acme.example:acme/acme-relay.git"]] {
            _ = try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
        }
        for namespace in ["team-0", "team-1", "team-2"] {
            api.addMarkedDeployment("acme-relay", namespace: namespace, app: "prod-\(namespace)-acme-relay-service", padding: 0, now: Date(), replicaSet: false)
        }
        let store = KubeBindingStore(file: folder.appendingPathComponent("bindings.json"))
        KubeMCP.bindings = store
        KubeMCP.paneCheckout = { $0 == "pane-relay" ? repo : nil }
        // Bound to Helm's own agent: no Argo CD mark of its own, so A finds nothing.
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "team-0", selector: "app=fake-metrics-agent")))
        // Something here carries a mark (a list's rows showed one): B lists.
        model.sawMarks(in: "fake-dev")
        let said = await text(["checkout": true], pane: "pane-relay")
        let lines = said.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("May deploy this checkout, probably (by name or image) — never said found:"), said)
        XCTAssertEqual(apps(said).filter { $0.contains("acme-relay-service") }.count, 1, said)
        XCTAssertTrue(apps(said).contains { $0.contains("prod-team-0-acme-relay-service") }, said)
        XCTAssertTrue(said.contains("  matched: probably: its name, read as acme-relay, is the repository's"), said)
        XCTAssertTrue(lines.contains("2 more by name or image in other namespaces: team-1, team-2."), said)
        XCTAssertFalse(said.contains("prod-team-1-acme-relay-service") || said.contains("prod-team-2-acme-relay-service"), "counted, never listed: \(said)")
        XCTAssertFalse(said.contains("too many to tell"), said)
        XCTAssertTrue(said.contains("Argo CD isn't in fake-dev; read from the marks on the cluster's workloads."), said)

        // Problems only: the three are Ready by their rows, so none is listed and none counted —
        // never "2 more" after nothing, never the namespaces of apps the filter left out.
        let failing = await text(["checkout": true, "failing_only": true], pane: "pane-relay")
        XCTAssertFalse(failing.contains("May deploy this checkout"), failing)
        XCTAssertTrue(apps(failing).isEmpty, failing)
        XCTAssertFalse(failing.contains("by name or image"), "nothing healthy counted: \(failing)")
        XCTAssertFalse(failing.contains("team-1") || failing.contains("team-2"), failing)
        XCTAssertTrue(failing.contains("Argo CD isn't in fake-dev; read from the marks on the cluster's workloads."), failing)
    }

    /// A GET of several objects keeps to its bytes in all, whatever comes:
    /// each one in flight counts the most it may read, so no more start
    /// than the bound holds; once it is spent, the rest are skipped.
    func testAFetchKeepsToItsBytesInAll() async throws {
        let wanted = spoke.deployments.prefix(8).map { entry in
            (
                id: KubeMarkedMember.ID(kind: .deployment, namespace: entry.namespace, name: entry.name),
                path: KubeResourceKind.deployments.path(namespace: entry.namespace, name: entry.name)
            )
        }
        for entry in wanted { api.answerSlowly(entry.path, milliseconds: 50) }
        api.forgetRequests()
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev"))
        let each = 16 << 10
        let total = 40 << 10
        let fetched = await KubeMarkedFetch.objects(Array(wanted), client: client, maxBytes: each, totalBytes: total, timeout: .seconds(10))
        XCTAssertLessThanOrEqual(fetched.answers.map(\.bytes).reduce(0, +), total, "within its bound")
        XCTAssertLessThanOrEqual(api.mostHeldAnswers, total / each, "no more in flight than the bound holds whole")
        XCTAssertFalse(fetched.answers.isEmpty)
        XCTAssertFalse(fetched.skipped.isEmpty, "the rest skipped once it was spent")
        XCTAssertEqual(fetched.answers.count + fetched.skipped.count, wanted.count)
        XCTAssertTrue(fetched.answers.allSatisfy { if case .success = $0.result { true } else { false } })
    }

    // MARK: Pure

    /// An agent reads counts plain: `2.000` is two thousand in the owner's
    /// Turkish and two to an agent reading English. What the section's and
    /// the rail's reads keep holds its counts as numbers — the page groups
    /// them as the person's locale writes them, an agent's answer never.
    func testAnAgentsCountsArePlainWhateverThePersonsLocaleWrites() {
        let cut: KubeCountedText = "Deployments: the list stopped at \(count: 5000); the rest not read"
        XCTAssertEqual(cut.said(plain: true), "Deployments: the list stopped at 5000; the rest not read")
        XCTAssertEqual(cut.said(), "Deployments: the list stopped at \(5000.formatted()); the rest not read", "the page's, as the locale writes it")
        XCTAssertEqual(KubeCountedText("Services: refused across the cluster"), "Services: \("refused") across the cluster", "the same words, the same value")
        XCTAssertEqual(KubeCountedText.joined(["a \(count: 1)", "b"], separator: "; ").said(plain: true), "a 1; b")
        var reading = KubeMarkedReading()
        reading.kinds = ["Deployments"]
        reading.listed = ["Deployments"]
        reading.rowCuts["Deployments"] = cut
        reading.notes["rows:services"] = "Services: the list stopped at \(count: 5000); the rest not read"
        reading.checking = 1412
        reading.checked = 1024
        let notes = KubeMCPMarksText.notes(KubeMCP.MarkedAppsRead(reading: reading), counted: false).joined(separator: "\n")
        for plain in ["Deployments: the list stopped at 5000", "Services: the list stopped at 5000", "checking rollouts 1024 of 1412"] {
            XCTAssertTrue(notes.contains(plain), notes)
        }
        XCTAssertFalse(notes.contains("5.000") || notes.contains("5,000") || notes.contains("1.412") || notes.contains("1,412"), notes)
        XCTAssertEqual(
            reading.empty(context: "fake-dev", scope: .all, served: false, plain: true),
            "No Argo CD marks found in what could be read: Deployments: the list stopped at 5000; the rest not read")

        // The rail's comparison, as an agent is told it.
        var manifests = KubeCheckoutManifests.Read()
        manifests.files = 2480
        manifests.documents = 1412
        manifests.templates = 1024
        manifests.cut = "\(count: 2000) of \(count: 2480) manifest files read"
        let checkout = KubeGitOpsMatch.Checkout(
            root: URL(fileURLWithPath: "/tmp/fleet"), remotes: [KubeGitOpsMatch.Remote(name: "origin", repo: GitRemoteURL("git@git.acme.example:acme/fleet.git")!)])
        let listing = KubeGitOpsMatch.markedListing(
            [], manifests: manifests, checkout: checkout, namespace: "shop", reason: .notServed, notes: ["StatefulSets not read: \(count: 5000) rows or 30 MB read already"])
        XCTAssertEqual(
            KubeGitOpsMatch.marked(bound: [], listing: listing, plain: true).nothing,
            "No marked app matched: 1412 manifests compared, 1024 Helm templates not rendered, 2000 of 2480 manifest files read, StatefulSets not read: 5000 rows or 30 MB read already"
        )
        XCTAssertEqual(
            KubeGitOpsMatch.marked(bound: [], listing: listing).nothing,
            "No marked app matched: \(1412.formatted()) manifests compared, \(1024.formatted()) Helm templates not rendered, \(2000.formatted()) of \(2480.formatted()) manifest files read, StatefulSets not read: \(5000.formatted()) rows or 30 MB read already",
            "the rail's, as the locale writes it")
    }

    /// The apps by name outside the bound namespace, as an agent is told
    /// them: a plain count — 1001 beside the bound one's app, which `1.001`
    /// would make one to an agent reading English —, the rail's grouped as
    /// the person's locale writes it; the line as it is in the agent's text.
    func testTheAppsByNameElsewhereAreCountedPlainForAnAgent() throws {
        func member(_ namespace: String) throws -> KubeMarkedMember {
            let id = try XCTUnwrap(KubeTrackingID.parse("prod-\(namespace)-acme-relay-service:apps/Deployment:\(namespace)/acme-relay"))
            return KubeMarkedMember(
                id: .init(kind: .deployment, namespace: namespace, name: "acme-relay"), marks: KubeMarkWire(tracking: .own(id)),
                health: KubeMarkedHealth.Verdict(status: .healthy, sentence: "2/2 ready", fromRow: true), images: ["registry.acme.example/acme/relay:4.12.0"])
        }
        let namespaces = (0...1001).map { String(format: "acme-team-%04d", $0) }
        let apps = KubeMarkedApps.group(try namespaces.map(member)).apps
        let checkout = KubeGitOpsMatch.Checkout(
            root: URL(fileURLWithPath: "/tmp/acme-relay"), remotes: [KubeGitOpsMatch.Remote(name: "origin", repo: GitRemoteURL("git@git.acme.example:acme/acme-relay.git")!)])
        let listing = KubeGitOpsMatch.markedListing(apps, manifests: KubeCheckoutManifests.Read(), checkout: checkout, namespace: "acme-team-0000", reason: .notServed)
        let plain = KubeGitOpsMatch.marked(bound: [], listing: listing, plain: true)
        let named = "in other namespaces: acme-team-0001, acme-team-0002, acme-team-0003, acme-team-0004, acme-team-0005, …"
        XCTAssertEqual(plain.elsewhere, "1001 more by name or image \(named)")
        XCTAssertEqual(plain.probably.map(\.app.key.instance), ["prod-acme-team-0000-acme-relay-service"])
        XCTAssertNil(plain.tooMany, "those elsewhere are counted, never too many")
        XCTAssertEqual(
            KubeGitOpsMatch.marked(bound: [], listing: listing).elsewhere, "\(1001.formatted()) more by name or image \(named)", "the rail's, as the locale writes it")

        XCTAssertEqual(plain.others.count, 1001, "the apps elsewhere kept, for an agent's answer to count")

        var marks = KubeMCP.CheckoutMarks()
        marks.probably = plain.probably.map { KubeMCP.CheckoutMarks.Match(entry: $0, health: $0.app.health, scope: .listed(1), place: .reason(.notServed)) }
        marks.elsewhere = plain.others.map { KubeMCP.CheckoutMarks.Match(entry: $0, health: $0.app.health, scope: .listed(1), place: .reason(.notServed)) }
        let lines = KubeMCPMarksText.checkout(marks, failing: false, limit: 100, context: "fake-dev", now: Date())
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("May deploy this checkout, probably (by name or image) — never said found:"), text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("marks  Ready (from rows)  prod-acme-team-0000-acme-relay-service") }, text)
        XCTAssertTrue(lines.contains("1001 more by name or image \(named)"), text)
        XCTAssertFalse(text.contains("1,001") || text.contains("1.001"), text)
    }

    /// With failing_only the apps by name elsewhere are filtered as the
    /// rest are: only the failing ones counted and their namespaces named —
    /// on a line of their own where the bound namespace's app is healthy,
    /// never "more" after nothing —, nothing at all where none fails.
    func testWithFailingOnlyOnlyTheFailingAppsElsewhereAreCounted() throws {
        func member(_ namespace: String, failing: Bool) throws -> KubeMarkedMember {
            let id = try XCTUnwrap(KubeTrackingID.parse("prod-\(namespace)-acme-relay-service:apps/Deployment:\(namespace)/acme-relay"))
            let health =
                failing
                ? KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)")
                : KubeMarkedHealth.Verdict(status: .healthy, sentence: "2/2 ready", fromRow: true)
            return KubeMarkedMember(
                id: .init(kind: .deployment, namespace: namespace, name: "acme-relay"), marks: KubeMarkWire(tracking: .own(id)), health: health,
                images: ["registry.acme.example/acme/relay:4.12.0"])
        }
        let checkout = KubeGitOpsMatch.Checkout(
            root: URL(fileURLWithPath: "/tmp/acme-relay"), remotes: [KubeGitOpsMatch.Remote(name: "origin", repo: GitRemoteURL("git@git.acme.example:acme/acme-relay.git")!)])
        // acme-relay in three namespaces, bound in team-0; `failing`: whose app is Degraded.
        func said(failing: Set<String>, only: Bool) throws -> [String] {
            let members = try ["team-0", "team-1", "team-2"].map { try member($0, failing: failing.contains($0)) }
            let listing = KubeGitOpsMatch.markedListing(
                KubeMarkedApps.group(members).apps, manifests: KubeCheckoutManifests.Read(), checkout: checkout, namespace: "team-0", reason: .notServed)
            let answer = KubeGitOpsMatch.marked(bound: [], listing: listing, plain: true)
            XCTAssertEqual(answer.probably.map(\.app.key.instance), ["prod-team-0-acme-relay-service"])
            XCTAssertEqual(answer.others.map(\.app.key.instance), ["prod-team-1-acme-relay-service", "prod-team-2-acme-relay-service"])
            func match(_ entry: KubeGitOpsMatch.MarkedFound) -> KubeMCP.CheckoutMarks.Match {
                KubeMCP.CheckoutMarks.Match(entry: entry, health: entry.app.health, scope: .listed(1), place: .reason(.notServed))
            }
            var marks = KubeMCP.CheckoutMarks()
            marks.probably = answer.probably.map(match)
            marks.elsewhere = answer.others.map(match)
            return KubeMCPMarksText.checkout(marks, failing: only, limit: 100, context: "fake-dev", now: Date())
        }
        let header = "May deploy this checkout, probably (by name or image) — never said found:"

        // The bound namespace's app healthy, team-1's failing: team-1's counted on its own, team-2 never named.
        let alone = try said(failing: ["team-1"], only: true)
        XCTAssertEqual(alone, ["1 failing app by name or image in another namespace: team-1."], alone.joined(separator: "\n"))
        XCTAssertEqual(
            try said(failing: ["team-1", "team-2"], only: true), ["2 failing apps by name or image in other namespaces: team-1, team-2."])

        // The bound namespace's failing too: listed, then the failing one elsewhere counted after it.
        let both = try said(failing: ["team-0", "team-1"], only: true)
        let text = both.joined(separator: "\n")
        XCTAssertTrue(both.contains(header), text)
        XCTAssertTrue(both.contains { $0.hasPrefix("marks  Failed  prod-team-0-acme-relay-service") }, text)
        XCTAssertEqual(both.last, "1 more failing app by name or image in another namespace: team-1.", text)
        XCTAssertFalse(text.contains("team-2"), text)

        // None failing: nothing listed, nothing counted, no namespace named.
        XCTAssertEqual(try said(failing: [], only: true), [])
        // Only the bound namespace's failing: it alone, the healthy two elsewhere not counted.
        let bound = try said(failing: ["team-0"], only: true)
        let boundText = bound.joined(separator: "\n")
        XCTAssertTrue(bound.contains(header), boundText)
        XCTAssertTrue(bound.contains { $0.hasPrefix("marks  Failed  prod-team-0-acme-relay-service") }, boundText)
        XCTAssertFalse(boundText.contains("by name or image in") || boundText.contains("team-1") || boundText.contains("team-2"), boundText)

        // Every state asked: the rail's count, whatever their health.
        let every = try said(failing: ["team-1"], only: false)
        XCTAssertTrue(every.contains(header), every.joined(separator: "\n"))
        XCTAssertEqual(every.last, "2 more by name or image in other namespaces: team-1, team-2.", every.joined(separator: "\n"))
    }

    func testALinesWordsAndTheCountsLine() {
        var deployment = KubeMarkWire()
        deployment.tracking = .own(KubeTrackingID.parse("prod-team-2-acme-cart-service:apps/Deployment:team-2/acme-cart")!)
        deployment.installation = "hub-b"
        let member = KubeMarkedMember(
            id: .init(kind: .deployment, namespace: "team-2", name: "acme-cart"), marks: deployment,
            health: KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)"), images: ["registry.acme.example/acme/cart:4.1"])
        let app = try! XCTUnwrap(KubeMarkedApp.make(key: .init(installation: "hub-b", instance: "prod-team-2-acme-cart-service"), [member]))
        let ranked = KubeMarkedRanked(app: app, health: app.health)
        let line = KubeMCPMarksText.line(ranked, now: Date())
        XCTAssertEqual(
            line,
            "marks  Failed  prod-team-2-acme-cart-service  ns=team-2  1 Deploy  rollout stalled (ProgressDeadlineExceeded): Deployment acme-cart  image=…/cart:4.1  (installation hub-b)")
        let beside = KubeMCPMarksText.line(ranked, beside: .otherInstallation("hub-b"), now: Date())
        XCTAssertTrue(beside.hasSuffix("(installation hub-b)") && !beside.contains("installation hub-b, installation"), beside)
        XCTAssertEqual(
            KubeMCPMarksText.counts([ranked], whole: false, unread: ["Deployments refused in 1 namespace (team-9)"], scope: .all, failing: false),
            "At least 1 app read from marks in any namespace, from what could be read (Deployments refused in 1 namespace (team-9)), problems first: 1 Failed.")
        XCTAssertEqual(KubeMCPMarksText.counts([], whole: true, unread: [], scope: .namespace("team-2"), failing: true), "No failing app read from marks in or deploying into namespace team-2.")
        for (mode, words) in [
            (KubeMarkedAppsMode.only(.notServed), "another cluster"), (.only(.noApplications), "aren't in this cluster"), (.only(.undiscovered), "Couldn't tell"),
            (.only(.forbidden), "can't be read"),
        ] {
            let opening = KubeMCPMarksText.opening(mode, context: "fake-dev", probable: false)
            XCTAssertTrue(opening.contains(words), opening)
            XCTAssertEqual(opening.contains("another cluster"), mode == .only(.notServed), opening)
        }
        XCTAssertFalse(KubeMCPMarksText.opening(.only(.notServed), context: "fake-dev", probable: true).contains("another cluster"))
    }
}
