import Combine
import XCTest

@testable import Overterm

/// The rail's GitOps part (docs/design/kubernetes/gitops.md, 4, 8.2)
/// against `FakeKubeAPI` on a socket of the test's own, with Argo CD's
/// and Flux's fixtures, a kubeconfig of two fictional contexts and a git
/// checkout of the test's own whose remote names `acme/shop` (its git
/// isolated from the developer's config): the workload's owner read by one
/// GET; off production the sources listed and matched, what takes from
/// them listed only then; on production nothing listed across the cluster
/// until Find What Deploys This; the cache within five minutes; the
/// remotes read once; hidden, nothing asked. Only GETs, never a Secret or a
/// ConfigMap — save in the production test, where the page's own guard
/// path runs and one write is confirmed on purpose.
@MainActor
final class KubePanelGitOpsTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var folder: URL!
    private var repo: URL!
    private var cache: KubeGitOpsMatchCache!
    private var checkouts: KubeGitOpsCheckouts!
    /// Every git call the rail's checkouts made.
    private var gitCalls: GitLog!
    /// The production test: the page's guard path ran (its reads, one confirmed write).
    private var pageRan = false

    final class GitLog: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [[String]] = []
        var calls: [[String]] { lock.withLock { kept } }
        func add(_ arguments: [String]) { lock.withLock { kept.append(arguments) } }
    }

    override func setUp() async throws {
        socket = "/tmp/otkg-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        // Neither Argo CD nor Flux served here: the cluster Argo CD runs in
        // is another; "Bare", a cluster the test serves what it needs on.
        if name.contains("Unserved") || name.contains("Bare") { api.addNamespace("shop") } else { api.addGitOpsFixtures() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-panel-gitops-\(UUID().uuidString)", isDirectory: true)
        repo = folder.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("deploy/fake-dev"), withIntermediateDirectories: true)
        try "resources: []\n".write(to: repo.appendingPathComponent("deploy/fake-dev/kustomization.yaml"), atomically: true, encoding: .utf8)
        try await git(["init", "-q", "-b", "main"])
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "shop"])
        try await git(["remote", "add", "origin", "git@git.acme.example:acme/shop.git"])
        cache = KubeGitOpsMatchCache()
        let log = GitLog()
        gitCalls = log
        checkouts = KubeGitOpsCheckouts()
        checkouts.git = { arguments, root, success in
            log.add(arguments)
            return try await KubeGitOpsCheckouts.isolatedGit(arguments, root, success)
        }

        let labels = [
            "app.kubernetes.io/part-of": "ot-shop", "kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
        ]
        api.add("deployments.apps", "shop-api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1], labels: labels)
    }

    override func tearDown() async throws {
        if let api {
            if !pageRan {
                XCTAssertEqual(api.writes, [], "only GETs")
                XCTAssertFalse(api.requests.contains { $0.path.contains("/configmaps") }, "no ConfigMap")
            }
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "no Secret")
            api.stop()
        }
        if let gitCalls {
            XCTAssertFalse(gitCalls.calls.contains { $0.contains("fetch") || $0.contains("pull") || $0.contains("ls-remote") }, "nothing fetched: \(gitCalls.calls)")
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// git with the developer's config left out: no `insteadOf` changes a remote here.
    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        return try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
    }

    private func makePanel(model given: KubernetesModel? = nil, writable: Bool = false) -> KubernetesPanelModel {
        let model =
            given
            ?? {
                let model = KubernetesModel(proxies: KubeProxies())
                let list = KubeMCPTests.listForPanel()
                model.load = { _ in list }
                model.readConfiguration = { KubernetesModel.Configuration() }
                model.watchesSettings = false
                model.remembersSelection = false
                return model
            }()
        let panel = KubernetesPanelModel(
            store: KubeBindingStore(file: folder.appendingPathComponent("support/bindings.json")), kubernetes: model, gitOpsCache: cache,
            gitOpsCheckouts: checkouts)
        let socket = self.socket!
        // `writable`: production, writable by default — the socket doesn't refuse writes.
        panel.clientFor = { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name, writable: writable)) }
        return panel
    }

    private func until(_ seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func bound(_ context: String, show: Bool = true, model: KubernetesModel? = nil, writable: Bool = false) -> KubernetesPanelModel {
        let panel = makePanel(model: model, writable: writable)
        panel.checkout = repo
        XCTAssertTrue(panel.store.set(KubeBinding(checkout: repo.path, context: context, namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop")))
        if show { panel.panelVisible = true }
        return panel
    }

    /// A list of a GitOps kind across the cluster (no `/namespaces/` in
    /// its path: P3's GitRepository rows, P4's lists), or of whole objects
    /// anywhere (P3's OCIRepositories, P4's paged objects) — not P5's
    /// rows-only follows in one namespace, nor a GET of one object.
    private func gitOpsLists() -> [FakeKubeAPI.Request] { Self.gitOpsLists(api.requests) }

    nonisolated static func gitOpsLists(_ requests: [FakeKubeAPI.Request]) -> [FakeKubeAPI.Request] {
        requests.filter { request in
            request.method == "GET" && !request.isWatch && (request.path.contains("argoproj.io") || request.path.contains("toolkit.fluxcd.io"))
                && ["applications", "kustomizations", "helmreleases", "gitrepositories", "ocirepositories", "helmcharts"].contains {
                    request.path.hasSuffix("/\($0)")
                }
                && (!request.path.contains("/namespaces/") || !request.accept.contains("as=Table"))
        }
    }

    nonisolated static let gitRepositoriesAcross = "/apis/source.toolkit.fluxcd.io/v1/gitrepositories"


    private func match(_ panel: KubernetesPanelModel, _ kind: String, _ name: String) -> KubePanelGitOps.Match? {
        panel.gitOps.matches.first { $0.key.kind == kind && $0.key.name == name }
    }

    func testOffProductionTheOwnerAndTheSourcesMatch() async throws {
        let panel = bound("fake-dev")
        try await until(15, "acme-apps owns shop-api and takes deploy/fake-dev") {
            self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2
        }
        let apps = match(panel, "Kustomization", "acme-apps")
        XCTAssertEqual(apps?.whys, [.owns([KubeWorkloadRef(kind: .deployment, name: "shop-api")]), .repoAndPath("deploy/fake-dev", source: nil)])
        XCTAssertEqual(apps?.object?.state, .ready)
        XCTAssertEqual(apps?.tracks, "tracks main")
        XCTAssertEqual(apps?.why, "owns Deployment/shop-api · deploy/fake-dev")
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/acme-apps" },
            "the owner by one GET")
        // Its siblings from the same source: the path not on this branch, said.
        try await until(10, "acme-cron") { self.match(panel, "Kustomization", "acme-cron") != nil }
        XCTAssertEqual(match(panel, "Kustomization", "acme-cron")?.whys, [.repoOnly("path apps/cron is not on this branch", source: nil)])
        XCTAssertEqual(match(panel, "Kustomization", "acme-cron")?.object?.state, .failed)
        XCTAssertNotNil(match(panel, "Application", "acme-shop-prod"), "an Application in argocd with the repository")
        XCTAssertNil(match(panel, "Kustomization", "acme-api"), "acme-broken is another repository")
        XCTAssertTrue(panel.gitOps.shows)
        // The workloads asked with their metadata, in the binding's namespace only.
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "Metadata" },
            "\(api.requests.filter { $0.path.contains("deployments") }.map(\.query))")
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["includeObject"] == "Metadata" }, "not the pods")
        // The summaries' lists are paged whole objects; never a whole-object watch.
        XCTAssertFalse(api.requests.contains { $0.isWatch && $0.query["includeObject"] == "Object" })
        // P5: rows-only follows of what matched, at most four.
        try await until(5, "the matches followed") { panel.gitOps.openFollows > 0 }
        XCTAssertLessThanOrEqual(panel.gitOps.openFollows, KubePanelGitOps.liveFollows)
        panel.panelVisible = false
        try await until(5, "hidden, every watch ends") { self.api.openWatches == 0 }
        XCTAssertTrue(panel.gitOps.matches.isEmpty)
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(api.requests.isEmpty, "hidden, nothing asked: \(api.requests)")
    }

    func testTheCacheAndTheRemotesReadOnce() async throws {
        let panel = bound("fake-dev")
        // acme-apps matches from its owner's GETs alone; acme-cron only once the lists are in (and kept).
        try await until(15, "matched") {
            self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 && self.match(panel, "Kustomization", "acme-cron") != nil
        }
        let reads = checkouts.remoteReads[repo.standardizedFileURL.path]
        XCTAssertEqual(reads, 1)
        panel.panelVisible = false
        try await until(5, "hidden") { self.api.openWatches == 0 }
        api.forgetRequests()
        panel.panelVisible = true
        try await until(15, "shown again") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        XCTAssertEqual(gitOpsLists().map(\.path), [], "within five minutes nothing is listed again")
        XCTAssertEqual(checkouts.remoteReads[repo.standardizedFileURL.path], reads, "the remotes read once per checkout")
        // Refresh: listed again, the remotes read again (one added since is seen).
        try await git(["remote", "add", "fleet", "https://git.acme.example/acme/fleet.git"])
        panel.gitOps.refresh()
        try await until(10, "listed again") { !self.gitOpsLists().isEmpty }
        try await until(10, "matched again") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        XCTAssertEqual(checkouts.remoteReads[repo.standardizedFileURL.path], (reads ?? 0) + 1, "Refresh reads the remotes again")
        panel.panelVisible = false
    }

    func testNoFluxObjectIsListedWhenNoSourceMatched() async throws {
        try await git(["remote", "set-url", "origin", "https://git.globex.example/globex/elsewhere.git"])
        let panel = bound("fake-dev")
        try await until(15, "the owner alone") { self.match(panel, "Kustomization", "acme-apps") != nil && panel.gitOps.state == .live }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(match(panel, "Kustomization", "acme-apps")?.whys, [.owns([KubeWorkloadRef(kind: .deployment, name: "shop-api")])])
        XCTAssertFalse(gitOpsLists().contains { $0.path.hasSuffix("/kustomizations") || $0.path.hasSuffix("/helmreleases") }, "\(gitOpsLists().map(\.path))")
        panel.panelVisible = false
    }

    func testOnProductionNothingIsListedAcrossTheClusterUntilPressed() async throws {
        let panel = bound("fake-prod")
        try await until(15, "the owner by its GET") { self.match(panel, "Kustomization", "acme-apps") != nil }
        guard case .waiting(let reads) = panel.gitOps.state else { return XCTFail("\(panel.gitOps.state)") }
        XCTAssertTrue(reads.contains("Applications in argocd") && reads.contains("on fake-prod"), reads)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gitOpsLists().map(\.path), [], "no list across the cluster unpressed")
        XCTAssertFalse(api.requests.contains { $0.path == Self.gitRepositoriesAcross }, "no GitRepository rows across the cluster unpressed")
        XCTAssertTrue(panel.gitOps.shows)
        panel.gitOps.find()
        try await until(15, "found") { self.match(panel, "Kustomization", "acme-cron") != nil }
        XCTAssertFalse(gitOpsLists().isEmpty)
        XCTAssertTrue(api.requests.contains { $0.path == Self.gitRepositoriesAcross && !$0.isWatch }, "pressed: GitRepositories' rows across the cluster")
        // A press is kept with the listing: shown again, nothing asked again.
        panel.panelVisible = false
        try await until(5, "hidden") { self.api.openWatches == 0 }
        api.forgetRequests()
        panel.panelVisible = true
        try await until(15, "shown again") { self.match(panel, "Kustomization", "acme-cron") != nil }
        XCTAssertEqual(gitOpsLists().map(\.path), [])
        panel.panelVisible = false
    }

    func testUnboundAsksNothing() async throws {
        let panel = makePanel()
        panel.checkout = repo
        panel.panelVisible = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(api.requests.isEmpty, "\(api.requests)")
        XCTAssertFalse(panel.gitOps.shows)
        panel.panelVisible = false
    }

    /// The app a bound workload's own mark names (A), read from its marks.
    private func marked(_ panel: KubernetesPanelModel, _ instance: String) -> KubePanelGitOps.Match? {
        panel.gitOps.matches.first { $0.marked?.app.key.instance == instance }
    }

    /// A plain name's Application not in argocd, where the rail's own list
    /// saw Applications live (gitops.md 14.2.5): its app, read from the
    /// bound workload's marks, with its health — "not in" said of it, never
    /// an owner line.
    func testATrackingIDNamingAnApplicationNotHereIsSaid() async throws {
        api.add(
            "statefulsets.apps", "shop-db", namespace: "shop", values: ["Ready": "1/1"], labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "acme-gone:apps/StatefulSet:shop/shop-db"])
        let panel = bound("fake-dev")
        try await until(15, "said") { self.marked(panel, "acme-gone")?.marked?.place == .absent }
        let gone = try XCTUnwrap(marked(panel, "acme-gone"))
        XCTAssertEqual(gone.marked?.place.said(context: "fake-dev"), "its Application isn't in fake-dev")
        XCTAssertEqual(gone.whys, [.owns([KubeWorkloadRef(kind: .statefulSet, name: "shop-db")])])
        XCTAssertNil(gone.object)
        XCTAssertNil(match(panel, "Application", "acme-gone"), "said as its app, not as an owner")
        XCTAssertNil(panel.gitOps.marksLine, "Applications are read here")
        // Applications listed in argocd: no row asked across the cluster, and no marks' list.
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/applications" && $0.query["limit"] == "1" })
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/apps/v1/deployments" }, "\(api.requests.map(\.path))")
        panel.panelVisible = false
    }

    // MARK: Owners unread, unserved, refreshed

    /// A tracking id on a cluster that serves neither Argo CD nor Flux (Argo
    /// CD deploys here from another cluster): the owner is still said — no
    /// GET for a kind not served — and the part stays "unserved", whichever
    /// came first, the rows or discovery.
    func testUnservedATrackingIDIsStillSaid() async throws {
        api.add(
            "statefulsets.apps", "shop-db", namespace: "shop", values: ["Ready": "1/1"], labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "acme-hub:apps/StatefulSet:shop/shop-db"])
        let panel = bound("fake-dev")
        try await until(15, "said") { self.marked(panel, "acme-hub") != nil && panel.gitOps.settleGets > 0 }
        let hub = try XCTUnwrap(marked(panel, "acme-hub"))
        XCTAssertEqual(hub.said, "Argo CD app acme-hub")
        XCTAssertEqual(hub.why, "owns StatefulSet/shop-db")
        XCTAssertEqual(hub.marked?.place.said(context: "fake-dev"), "Argo CD runs in another cluster — not in your kubeconfig")
        XCTAssertEqual(panel.gitOps.marksLine, "Argo CD isn't in fake-dev; read from the marks on shop's workloads")
        XCTAssertFalse(panel.gitOps.matches.contains { $0.why.contains("Application acme-hub") }, "its owner line is its app's now")
        XCTAssertEqual(panel.gitOps.state, .unserved)
        XCTAssertTrue(panel.gitOps.shows)
        XCTAssertTrue(panel.gitOps.canRefresh, "Refresh offered")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.gitOps.state, .unserved, "not turned live by a later row")
        XCTAssertFalse(
            api.requests.contains { $0.path.contains("argoproj.io") || $0.path.contains("toolkit.fluxcd.io") }, "\(api.requests.map(\.path))")
        panel.panelVisible = false
    }

    /// A mark copied onto a workload names nobody (14.1, D0): an
    /// operator's StatefulSet carrying its custom resource's tracking id is
    /// no Application's — beside one whose own mark the rail still says,
    /// read by the same list.
    func testUnservedACopiedMarkIsNotMatched() async throws {
        api.add(
            "statefulsets.apps", "shop-db", namespace: "shop", values: ["Ready": "1/1"], labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "prod-shop-db-service:apps/StatefulSet:shop/shop-db"])
        api.add(
            "statefulsets.apps", "orders-db", namespace: "shop", values: ["Ready": "1/1"],
            labels: ["app.kubernetes.io/part-of": "ot-shop", "app.kubernetes.io/instance": "prod-shop-orders-service"],
            annotations: ["argocd.argoproj.io/tracking-id": "prod-shop-orders-service:acme.example.com/Database:shop/orders"])
        let panel = bound("fake-dev")
        try await until(15, "the self mark said") { self.marked(panel, "prod-shop-db-service") != nil }
        XCTAssertNil(marked(panel, "prod-shop-orders-service"), "\(panel.gitOps.matches.map(\.key))")
        XCTAssertNil(match(panel, "Application", "prod-shop-orders-service"))
        XCTAssertFalse(panel.gitOps.matches.contains { $0.why.contains("prod-shop-orders-service") }, "\(panel.gitOps.matches.map(\.why))")
        panel.panelVisible = false
    }

    /// An app-of-apps: the Application the rail reads carries its parent's
    /// tracking id, which names the child itself — so its parent is kept.
    func testAnAppOfAppsChildKeepsItsParent() async throws {
        api.add(
            "applications.argoproj.io", "acme-child", namespace: "argocd", values: ["Sync Status": "Synced", "Health Status": "Healthy"],
            annotations: ["argocd.argoproj.io/tracking-id": "acme-root:argoproj.io/Application:argocd/acme-child"],
            fields: ["spec": ["project": "acme", "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"]], "status": [:]])
        api.add(
            "statefulsets.apps", "shop-db", namespace: "shop", values: ["Ready": "1/1"], labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "acme-child:apps/StatefulSet:shop/shop-db"])
        let panel = bound("fake-dev")
        try await until(15, "the child read") { self.match(panel, "Application", "acme-child")?.object != nil }
        XCTAssertEqual(match(panel, "Application", "acme-child")?.object?.parentOwner?.name, "acme-root")
        panel.panelVisible = false
    }

    // MARK: Apps read from marks (gitops.md 14.2.5, 14.8 D5)

    /// A Deployment the surveyed way: its app `<env>-<ns>-<name>-service`,
    /// its tracking id naming itself, bound by the binding's selector.
    private func addMarked(_ name: String, namespace: String = "shop", app: String, bound: Bool = true, ready: Int = 2, desired: Int = 2, status: [String: Any]? = nil) {
        api.addMarkedDeployment(
            name, namespace: namespace, app: app, ready: ready, desired: desired, labels: bound ? ["app.kubernetes.io/part-of": "ot-shop"] : [:], padding: 2_000,
            now: Date(), status: status, progressing: ("True", "ReplicaSetUpdated"))
    }

    private func commit(_ text: String, _ path: String) async throws {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", path])
        try await git(["commit", "-q", "-m", path])
    }

    /// The workloads' rows across the cluster (option B): no namespace in the path.
    private func markedRowsAcross() -> [FakeKubeAPI.Request] {
        api.requests.filter { ["/apis/apps/v1/deployments", "/apis/apps/v1/statefulsets", "/apis/apps/v1/daemonsets"].contains($0.path) }
    }

    /// A single replica whose cells read 1/1 while its rollout is stuck
    /// behind the old pod: Progressing once the part's one GET of it came,
    /// never Ready from its row.
    func testUnservedAStuckSingleReplicaIsProgressingAfterItsGET() async throws {
        let app = "prod-shop-acme-pay-service"
        addMarked(
            "acme-pay", app: app, ready: 1, desired: 1, status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1, "unavailableReplicas": 1])
        let panel = bound("fake-dev")
        try await until(15, "settled by its object") { self.marked(panel, app)?.marked?.health.state == .progressing }
        let pay = try XCTUnwrap(marked(panel, app)?.marked)
        XCTAssertEqual(pay.health.why, "1 old replica pending termination · Deployment acme-pay")
        XCTAssertFalse(pay.health.fromRows, "its object said it")
        XCTAssertEqual(panel.gitOps.settleGets, 1)
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments/acme-pay" && !$0.isWatch }, "one GET of it")
        XCTAssertEqual(api.requests.filter { $0.path == "/apis/apps/v1/namespaces/shop/deployments/acme-pay" }.count, 1)
        // Its object carries the sentinel in env, args and kubectl's last-applied copy: none of it kept.
        assertNoSentinel(panel)
        panel.panelVisible = false
    }

    /// Nothing the rail keeps or says of apps read from marks holds the
    /// sentinel the fixture's objects carry (env, args, last-applied).
    private func assertNoSentinel(_ panel: KubernetesPanelModel, file: StaticString = #filePath, line: UInt = #line) {
        let kept =
            String(describing: panel.gitOps.matches) + String(describing: panel.gitOps.marksSaid) + (panel.gitOps.marksLine ?? "")
            + panel.gitOps.problems.joined() + panel.gitOps.searched.joined()
        XCTAssertFalse(kept.contains(FakeKubeAPI.gitOpsSentinel), "the sentinel kept", file: file, line: line)
    }

    /// The binding's selector covers part of the app: its health is said
    /// as the objects bound here's, its others counted where option B's
    /// list saw them — never the app's own.
    func testUnservedHealthIsTheObjectsBoundHereWhenTheSelectorCoversPart() async throws {
        let app = "prod-shop-acme-web-service"
        api.addNamespace("jobs")
        addMarked("acme-web", app: app)
        addMarked("acme-web-worker", app: app, bound: false, ready: 0, desired: 1)
        addMarked("acme-web-sync", namespace: "jobs", app: app, bound: false)
        let panel = bound("fake-dev")
        try await until(15, "its others counted") {
            if case .bound(1, 0, let others?, true)? = self.marked(panel, app)?.marked?.scope { return !others.isEmpty }
            return false
        }
        let web = try XCTUnwrap(marked(panel, app)?.marked)
        XCTAssertEqual(web.scope.said(now: Date()), "health of the 1 object bound here; 1 more in jobs and 1 in shop not counted")
        XCTAssertEqual(web.health.state, .ready, "its bound Deployment's, not its worker's 0/1")
        XCTAssertEqual(web.app.members.map(\.id.name), ["acme-web"])
        XCTAssertFalse(markedRowsAcross().isEmpty, "off production: listed on show")
        XCTAssertTrue(markedRowsAcross().allSatisfy { $0.query["includeObject"] == "Metadata" && !$0.isWatch }, "rows with their marks, no watch")
        panel.panelVisible = false
    }

    /// On production the cluster's workloads are listed for option B only
    /// once Find What Deploys This was pressed; the bound workloads' own
    /// app is said at once. A config repository's committed manifest then
    /// describes an app's object — never "owns" it.
    func testUnservedOnProductionOptionBListsOnlyWhenPressed() async throws {
        let mine = "prod-shop-acme-cart-service"
        let ledger = "prod-ledger-acme-ledger-service"
        api.addNamespace("ledger")
        addMarked("acme-cart", app: mine)
        addMarked("acme-ledger", namespace: "ledger", app: ledger, bound: false)
        try await commit("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: acme-ledger\n  namespace: ledger\n", "k8s/ledger/deployment.yaml")
        let panel = bound("fake-prod")
        try await until(15, "its own app at once") { self.marked(panel, mine) != nil }
        try await until(10, "Find offered") { if case .waiting = panel.gitOps.state { true } else { false } }
        guard case .waiting(let reads) = panel.gitOps.state else { return XCTFail("\(panel.gitOps.state)") }
        XCTAssertEqual(reads, "lists Deployments, StatefulSets and DaemonSets on fake-prod with Argo CD's marks, to compare with this checkout's manifests")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(markedRowsAcross().map(\.path), [], "nothing listed across the cluster unpressed")
        XCTAssertNil(marked(panel, ledger))
        XCTAssertFalse(gitCalls.calls.contains { $0.first == "ls-files" }, "the checkout's manifests not read unpressed")
        panel.gitOps.find()
        try await until(15, "described once pressed") { self.marked(panel, ledger) != nil }
        let described = try XCTUnwrap(marked(panel, ledger))
        XCTAssertEqual(described.whys, [.describes(1, of: 1)])
        XCTAssertFalse(described.why.contains("owns"), described.why)
        XCTAssertEqual(described.marked?.scope, .listed(1))
        XCTAssertFalse(markedRowsAcross().isEmpty)
        XCTAssertTrue(gitCalls.calls.contains(KubeCheckoutManifests.listArguments), "\(gitCalls.calls)")
        XCTAssertEqual(marked(panel, mine)?.whys, [.owns([KubeWorkloadRef(kind: .deployment, name: "acme-cart")])], "only the binding owns")
        // B's rows across the cluster carry kubectl's last-applied copy, the sentinel in it: none of it kept.
        assertNoSentinel(panel)
        panel.panelVisible = false
    }

    /// A plain name's 404 in argocd, this context's Applications seen only
    /// in `gitops`: Argo CD's namespace here is unknown — unreadable, never
    /// "not in" the cluster.
    func testBareAPlainNameNotFoundInArgocdWhereApplicationsLiveElsewhereIsUnreadable() async throws {
        api.serveArgoCD()
        api.addNamespace("gitops")
        api.addApplication(
            "acme-fleet", namespace: "gitops",
            spec: ["project": "acme", "source": ["repoURL": "https://git.globex.example/globex/fleet.git"], "destination": ["namespace": "shop"]],
            status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        cache.saw(applicationsIn: ["gitops"], context: "fake-dev")
        addMarked("acme-cart", app: "prod-shop-acme-cart-service")
        let panel = bound("fake-dev")
        try await until(15, "said") { self.marked(panel, "prod-shop-acme-cart-service") != nil && panel.gitOps.state == .live }
        try await Task.sleep(for: .milliseconds(200))
        let cart = try XCTUnwrap(marked(panel, "prod-shop-acme-cart-service")?.marked)
        XCTAssertEqual(cart.place, .notFound)
        XCTAssertEqual(cart.place.said(context: "fake-dev"), "its Application wasn't found in argocd; Argo CD's namespace here is unknown")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/prod-shop-acme-cart-service" })
        // Of the app and its Application, nothing says "not in" (the Flux labels' owner, not served here, is another line).
        let said =
            panel.gitOps.matches.filter { $0.marked != nil || $0.key.name.contains("acme-cart") }.flatMap { [$0.why, $0.marked?.place.said(context: "fake-dev") ?? ""] }
            + panel.gitOps.problems.filter { $0.contains("acme-cart") }
        XCTAssertFalse(said.contains { $0.contains("not in fake-dev") || $0.contains("isn't in fake-dev") }, "\(said)")
        XCTAssertNil(match(panel, "Application", "prod-shop-acme-cart-service"), "no owner line beside its app")
        XCTAssertNil(panel.gitOps.marksLine, "Applications are read here (in gitops)")
        // Seen in argocd too: then it isn't there.
        cache.saw(applicationsIn: ["argocd"], context: "fake-dev")
        panel.gitOps.refresh()
        try await until(15, "now absent") { self.marked(panel, "prod-shop-acme-cart-service")?.marked?.place == .absent }
        panel.panelVisible = false
    }

    /// argoproj.io not answering discovery: "couldn't tell", never that
    /// Argo CD isn't here, the app's marks and health still said.
    func testArgoprojNotAnsweringDiscoveryCantTell() async throws {
        api.failingGroups = ["argoproj.io/v1alpha1"]
        api.add(
            "statefulsets.apps", "shop-db", namespace: "shop", values: ["Ready": "1/1"], labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "prod-shop-db-service:apps/StatefulSet:shop/shop-db"])
        let panel = bound("fake-dev")
        try await until(15, "said") { self.marked(panel, "prod-shop-db-service") != nil }
        XCTAssertEqual(panel.gitOps.marksReason, .undiscovered)
        XCTAssertEqual(panel.gitOps.marksLine, "Couldn't tell whether Argo CD runs in fake-dev: argoproj.io didn't answer discovery")
        let db = try XCTUnwrap(marked(panel, "prod-shop-db-service")?.marked)
        XCTAssertEqual(db.place, .reason(.undiscovered))
        let said = [panel.gitOps.marksLine ?? "", db.place.said(context: "fake-dev")] + panel.gitOps.problems + panel.gitOps.matches.map(\.why)
        XCTAssertFalse(said.contains { $0.contains("isn't in") || $0.contains("another cluster") || $0.contains("not in fake-dev") }, "\(said)")
        panel.panelVisible = false
    }

    /// The GitOps section ranked the app in the last five minutes, across
    /// the cluster and whole: its verdict is said with its age, and nothing
    /// is read for it — no GET, no list across the cluster.
    func testUnservedTheSectionsFreshVerdictIsTakenWithNoRead() async throws {
        let app = "prod-shop-acme-cart-service"
        addMarked("acme-cart", app: app)
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeMCPTests.listForPanel()
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let id = try XCTUnwrap(KubeTrackingID.parse("\(app):apps/Deployment:shop/acme-cart"))
        let member = KubeMarkedMember(
            id: KubeMarkedMember.ID(kind: .deployment, namespace: "shop", name: "acme-cart"), marks: KubeMarkWire(tracking: .own(id)),
            health: KubeMarkedHealth.Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)"))
        let ranked = try XCTUnwrap(KubeMarkedApps.group([member]).apps.first).health
        let section = try XCTUnwrap(KubeMarkedApps.group([member]).apps.first)
        let context = try XCTUnwrap(list.context(named: "fake-dev"))
        model.keepMarkedApps(
            KubernetesModel.MarkedAppsKept(context: context, apps: [KubeMarkedRanked(app: section, health: ranked)], at: Date().addingTimeInterval(-40), scope: .all, whole: true),
            context: "fake-dev", by: self)
        let panel = bound("fake-dev", model: model)
        try await until(15, "the section's verdict") { self.marked(panel, app)?.marked?.health.state == .failed }
        // Option B reads the checkout's manifests once it has its apps: the section's, or rows listed before.
        try await until(10, "option B read") { self.gitCalls.calls.contains(KubeCheckoutManifests.listArguments) }
        let cart = try XCTUnwrap(marked(panel, app)?.marked)
        XCTAssertTrue(cart.scope.said(now: Date()).hasPrefix("as the GitOps section read it 4"), cart.scope.said(now: Date()))
        XCTAssertEqual(panel.gitOps.settleGets, 0, "its verdict is the section's")
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments/acme-cart" }, "no GET")
        XCTAssertEqual(markedRowsAcross().map(\.path), [], "no list across the cluster: the section's apps")
        model.forgetMarkedApps(by: self)
        panel.panelVisible = false
    }

    /// The cache's key holds what discovery said of each tool apart (D5): a
    /// listing made while the cluster served Argo CD — or while argoproj.io
    /// didn't answer — isn't another's, Flux served or not; option B's is
    /// kept and dropped with the rest.
    func testBareTheCacheKeyHoldsWhatDiscoverySaid() {
        let applications = KubeResourceKind(
            group: "argoproj.io", version: "v1alpha1", resource: "applications", kind: "Application", singular: "", namespaced: true, verbs: ["list"])
        let kustomizations = KubeResourceKind(
            group: "kustomize.toolkit.fluxcd.io", version: "v1", resource: "kustomizations", kind: "Kustomization", singular: "", namespaced: true, verbs: ["list"])
        let argoFailed = ["argoproj.io/v1alpha1": "503"]
        // Flux served throughout: Argo CD's three answers are three keys.
        let modes = [
            KubePanelGitOps.mode(of: KubeDiscovery(kinds: [applications, kustomizations])),
            KubePanelGitOps.mode(of: KubeDiscovery(kinds: [kustomizations])),
            KubePanelGitOps.mode(of: KubeDiscovery(kinds: [kustomizations], failedGroups: argoFailed)),
        ]
        XCTAssertEqual(modes, ["argo=served;flux=served", "argo=unserved;flux=served", "argo=undiscovered;flux=served"])
        XCTAssertEqual(KubePanelGitOps.mode(of: KubeDiscovery(kinds: [])), "argo=unserved;flux=unserved")
        XCTAssertEqual(KubePanelGitOps.mode(of: KubeDiscovery(kinds: [applications])), "argo=served;flux=unserved")
        XCTAssertEqual(
            KubePanelGitOps.mode(of: KubeDiscovery(kinds: [applications], failedGroups: ["source.toolkit.fluxcd.io/v1": "503"])), "argo=served;flux=undiscovered")
        XCTAssertEqual(
            KubePanelGitOps.mode(of: KubeDiscovery(kinds: [kustomizations], failedGroups: ["metrics.k8s.io/v1beta1": "503"])), modes[1],
            "another group failing says nothing of Argo CD")
        let keys = modes.map { KubeGitOpsMatchCache.Key(context: "fake-dev", checkout: repo.path, namespace: "shop", remotes: "r", mode: $0) }
        XCTAssertEqual(Set(keys).count, 3)
        cache.keep(KubeGitOpsMatchCache.Listing(searched: ["kept"]), for: keys[2])
        XCTAssertEqual(cache.listing(keys[2])?.searched, ["kept"])
        XCTAssertNil(cache.listing(keys[0]), "made while argoproj.io didn't answer: not the listing once it serves Applications")
        XCTAssertNil(cache.listing(keys[1]))
        cache.keep(KubeGitOpsMatch.MarkedListing(reason: .undiscovered), for: keys[2])
        XCTAssertEqual(cache.marked(keys[2])?.reason, .undiscovered)
        XCTAssertNil(cache.marked(keys[1]), "nor once it says Applications aren't served")
        cache.drop(context: "fake-dev")
        XCTAssertNil(cache.marked(keys[2]), "a credential failure drops option B's too")
        XCTAssertNil(cache.listing(keys[2]))
    }

    /// A listing of the workloads' marks that failed (the proxy's own
    /// failure: a VPN down, a credential expired) is said once among the
    /// searched lines, and goes with the next listing's outcome — never left
    /// beside one that read, as after Refresh once the VPN is back.
    func testBareAFailedMarksListingIsSaidOnceAndGoesWhenOneReads() {
        let other = "GitRepositories: forbidden across the cluster; read in flux-system and shop"
        let failed = KubePanelGitOps.searched([other], marksFailed: "the cluster didn't answer")
        XCTAssertEqual(failed, [other, "Couldn't list the workloads' marks: the cluster didn't answer"])
        XCTAssertEqual(KubePanelGitOps.searched(failed, marksFailed: "the cluster didn't answer"), failed, "said once")
        XCTAssertEqual(
            KubePanelGitOps.searched(failed, marksFailed: "signing in timed out"), [other, "Couldn't list the workloads' marks: signing in timed out"],
            "the last failure's words replaced")
        XCTAssertEqual(KubePanelGitOps.searched(failed, marksFailed: nil), [other], "gone once a listing read")
        XCTAssertEqual(KubePanelGitOps.searched([other], marksFailed: nil), [other], "another line kept")
    }

    /// The bound workload's row as the panel holds it now.
    private func row(_ panel: KubernetesPanelModel, _ name: String) -> KubeMarkedMember? {
        panel.workloads.first { $0.ref.name == name }?.member
    }

    /// A Deployment's readiness moved, its generation (and spec) as it was.
    private func setReady(_ name: String, _ ready: Int, of desired: Int = 2) {
        api.modify("deployments.apps", name, namespace: "shop", values: ["Ready": .text("\(ready)/\(desired)"), "Available": .integer(ready)]) { body in
            var status = body["status"] as? [String: Any] ?? [:]
            status["readyReplicas"] = ready
            status["availableReplicas"] = ready
            body["status"] = status
        }
    }

    /// A bound workload settled by its GET (14.2.5) is read again only when
    /// its generation moves, or when it was settled not Healthy — once 15 s
    /// since its last GET have passed, by the rail's clock —, never for its
    /// readiness alone: a Healthy one's flapping asks nothing.
    func testUnservedASettledRowIsReadAgainOnlyWhenItsGenerationMovesOrItIsntHealthy() async throws {
        let web = "prod-shop-acme-web-service"
        let pay = "prod-shop-acme-pay-service"
        addMarked("acme-web", app: web)
        addMarked(
            "acme-pay", app: pay, ready: 1, desired: 1, status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1, "unavailableReplicas": 1])
        let panel = bound("fake-dev")
        var offset: TimeInterval = 0
        panel.gitOps.clock = { Date().addingTimeInterval(offset) }
        try await until(15, "both settled by their GETs") {
            panel.gitOps.settleGets == 2 && !panel.gitOps.settleAsking && self.marked(panel, web)?.marked?.health.fromRows == false
                && self.marked(panel, pay)?.marked?.health.state == .progressing
        }
        func gets(_ name: String) -> Int { api.requests.filter { $0.path == "/apis/apps/v1/namespaces/shop/deployments/\(name)" && !$0.isWatch }.count }
        XCTAssertEqual([gets("acme-web"), gets("acme-pay")], [1, 1])

        // acme-web, settled Healthy, flaps: its generation unchanged, nothing asked — 15 s or not.
        offset = KubePanelGitOps.refetchEvery + 1
        for (ready, said) in [(1, "1/2 available"), (2, "2/2 ready")] {
            setReady("acme-web", ready)
            try await until(10, "its row at \(ready)/2") { self.row(panel, "acme-web")?.health?.sentence == said }
            // The flush that told the rail of it is done: a GET would be waiting now.
            XCTAssertFalse(panel.gitOps.settleAsking, "readiness alone asks nothing")
        }
        XCTAssertEqual(gets("acme-web"), 1)

        // acme-pay, settled Progressing: its row moving is read again.
        setReady("acme-pay", 0, of: 1)
        try await until(10, "acme-pay read again") { gets("acme-pay") == 2 && !panel.gitOps.settleAsking }

        // acme-web's generation moves (a spec change): one GET.
        api.modify("deployments.apps", "acme-web", namespace: "shop") { body in
            var metadata = body["metadata"] as? [String: Any] ?? [:]
            metadata["generation"] = 5
            body["metadata"] = metadata
            var status = body["status"] as? [String: Any] ?? [:]
            status["observedGeneration"] = 5
            body["status"] = status
        }
        try await until(10, "read again for its generation") { gets("acme-web") == 2 && !panel.gitOps.settleAsking }
        // Settled at its new generation: its readiness flapping again asks nothing.
        setReady("acme-web", 1)
        try await until(10, "its row at 1/2") { self.row(panel, "acme-web")?.health?.sentence == "1/2 available" }
        XCTAssertFalse(panel.gitOps.settleAsking)
        XCTAssertEqual([gets("acme-web"), gets("acme-pay")], [2, 2], "one GET each move that may change Argo CD's word")
        XCTAssertEqual(panel.gitOps.settleGets, 4)
        panel.panelVisible = false
    }

    /// The read's 8 GETs (14.2.5), shared with P2's (a spoke spends none on
    /// owners): a binding of ten marked workloads settles the first eight
    /// by Argo CD's rule; the other two are said from their rows.
    func testUnservedTenBoundWorkloadsSettleEightTheRestFromTheirRows() async throws {
        let names = (0..<10).map { String(format: "acme-svc-%02d", $0) }
        for name in names { addMarked(name, app: "prod-shop-\(name)-service") }
        let panel = bound("fake-dev")
        try await until(15, "eight settled, ten said") {
            panel.gitOps.settleGets == KubePanelGitOps.ownerReads && !panel.gitOps.settleAsking && panel.gitOps.matches.count { $0.marked != nil } == 10
        }
        let objects = api.requests.filter { $0.path.hasPrefix("/apis/apps/v1/namespaces/shop/deployments/") && !$0.isWatch }.map(\.path)
        XCTAssertEqual(objects.count, KubePanelGitOps.ownerReads, "\(objects)")
        XCTAssertEqual(Set(objects), Set(names.prefix(8).map { "/apis/apps/v1/namespaces/shop/deployments/\($0)" }))
        let fromRows = panel.gitOps.matches.filter { $0.marked?.health.fromRows == true }.compactMap { $0.marked?.app.key.instance }.sorted()
        XCTAssertEqual(fromRows, ["prod-shop-acme-svc-08-service", "prod-shop-acme-svc-09-service"])
        panel.panelVisible = false
    }

    /// A bound Deployment its Argo Rollout scales to 0 (14.12's second
    /// consequence): the binding namespace's Rollouts listed as rows once —
    /// no watch —, the Rollout's GET spent in place of the Deployment's, the
    /// app's health its Rollout's phase, the Deployment "scaled by its
    /// Rollout", never a scaled-down app. One scaled to 0 that no Rollout
    /// runs is read once the Rollouts were: its own 0, Healthy.
    func testUnservedABoundRolloutAppsHealthIsItsRollouts() async throws {
        api.serveRollouts()
        let app = "prod-shop-acme-blue-service"
        let idle = "prod-shop-acme-idle-service"
        api.addMarkedRollout("acme-blue", namespace: "shop", app: app, phase: "Degraded", labels: ["app.kubernetes.io/part-of": "ot-shop"], now: Date())
        addMarked("acme-idle", app: idle, ready: 0, desired: 0)
        let panel = bound("fake-dev")
        try await until(15, "its Rollout's phase, and the idle one by its own GET") {
            self.marked(panel, app)?.marked?.health.state == .failed && self.marked(panel, idle)?.marked?.health.fromRows == false && !panel.gitOps.settleAsking
        }
        let quiet = try XCTUnwrap(marked(panel, idle)?.marked)
        XCTAssertEqual(quiet.health.state, .ready, "no Rollout runs it: its 0 is its own")
        XCTAssertTrue(quiet.scope.said(now: Date()).hasPrefix("health of the 1 object bound here"), quiet.scope.said(now: Date()))
        XCTAssertFalse(quiet.scope.said(now: Date()).contains("Rollout"), "no Rollout of its app")
        XCTAssertEqual(api.requests.filter { $0.path == "/apis/apps/v1/namespaces/shop/deployments/acme-idle" }.count, 1)
        let blue = try XCTUnwrap(marked(panel, app)?.marked)
        XCTAssertEqual(blue.health.why, "rollout degraded · Rollout acme-blue")
        XCTAssertEqual(blue.app.members.map(\.said), ["Deployment acme-blue", "Rollout acme-blue"])
        let deployment = try XCTUnwrap(blue.app.members.first { $0.id.kind == .deployment })
        XCTAssertEqual(KubeMarkedHealth.member(deployment, in: blue.app)?.sentence, KubeMarkedHealth.scaledByRollout)
        XCTAssertTrue(blue.scope.said(now: Date()).hasPrefix("health of the 1 object bound here with its app's Argo Rollout"), blue.scope.said(now: Date()))
        XCTAssertEqual(marked(panel, app)?.whys, [.owns([KubeWorkloadRef(kind: .deployment, name: "acme-blue")])], "owns the bound Deployment")
        // One list of the namespace's Rollouts, never watched; the Rollout's GET, none of the Deployment it scales.
        let rollouts = "/apis/argoproj.io/v1alpha1/namespaces/shop/rollouts"
        XCTAssertEqual(api.requests.filter { $0.path == rollouts }.count, 1)
        XCTAssertTrue(api.requests.contains { $0.path == rollouts && $0.query["includeObject"] == "Metadata" && !$0.isWatch }, "rows with their marks")
        XCTAssertFalse(api.requests.contains { $0.isWatch && $0.path.contains("/rollouts") }, "no watch of Rollouts")
        XCTAssertEqual(api.requests.filter { $0.path == rollouts + "/acme-blue" }.count, 1, "its Rollout's GET")
        XCTAssertFalse(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments/acme-blue" }, "no GET of the Deployment its Rollout scales")
        XCTAssertEqual(panel.gitOps.rolloutLists, 1)
        XCTAssertEqual(panel.gitOps.settleGets, 2, "the Rollout's, and the idle Deployment's")
        assertNoSentinel(panel)
        panel.panelVisible = false
    }

    /// Option B's rows cut before the bound app's (14.2.5): its other
    /// namespaces aren't read, and its scope says so — never that every
    /// member is bound here.
    func testUnservedACutListingLeavesOtherNamespacesUnread() async throws {
        let app = "prod-shop-acme-web-service"
        api.addNamespace("aaa")
        addMarked("acme-first", namespace: "aaa", app: "prod-aaa-acme-first-service", bound: false)
        addMarked("acme-web", app: app)
        let panel = bound("fake-dev", show: false)
        panel.gitOps.markedRowsBounds.rowsObjects = 1
        panel.panelVisible = true
        try await until(15, "listed, and cut") {
            self.marked(panel, app)?.marked?.health.fromRows == false && panel.gitOps.marksSaid.caveats.contains("Deployments: the list stopped at 1")
        }
        XCTAssertEqual(marked(panel, app)?.marked?.scope.said(now: Date()), "health of the 1 object bound here; other namespaces not read")
        XCTAssertTrue(panel.gitOps.marksSaid.caveats.contains("StatefulSets not read: 1 row or 30 MB read already"), "\(panel.gitOps.marksSaid.caveats)")
        panel.panelVisible = false
    }

    /// The page's section said no Application is here, but the rail's own
    /// listing (P4) holds them now (14.3: "not in" only from a whole read):
    /// its word is no answer — nothing said "isn't in" from it, no list of
    /// the marks across the cluster, a plain name's 404 in argocd
    /// unreadable where Applications live elsewhere. Said more than five
    /// minutes ago, it isn't even taken.
    func testBareASectionsNoneHereIsNoAnswerOnceTheRailListsApplications() async throws {
        api.serveArgoCD()
        api.addNamespace("gitops")
        api.addApplication(
            "acme-fleet", namespace: "gitops",
            spec: ["project": "acme", "source": ["repoURL": "https://git.globex.example/globex/fleet.git"], "destination": ["namespace": "shop"]],
            status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"]])
        cache.saw(applicationsIn: ["gitops"], context: "fake-dev")
        let cart = "prod-shop-acme-cart-service"
        addMarked("acme-cart", app: cart)
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeMCPTests.listForPanel()
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.reloadContexts()
        try await until(10, "the contexts read") { model.contexts.context(named: "fake-dev") != nil }
        let context = try XCTUnwrap(model.contexts.context(named: "fake-dev"))
        model.noteMarksMode(.only(.noApplications), in: "fake-dev", now: Date().addingTimeInterval(-(KubernetesModel.markedAppsLife + 1)))
        XCTAssertNil(model.marksReason(of: context), "said more than five minutes ago")
        model.noteMarksMode(.only(.noApplications), in: "fake-dev")
        XCTAssertEqual(model.marksReason(of: context), .noApplications)
        let panel = bound("fake-dev", model: model)
        try await until(15, "its 404 placed by the rail's own listing") { self.marked(panel, cart)?.marked?.place == .notFound && panel.gitOps.state == .live }
        // The listing that dropped the section's word is in: nothing was started from it.
        XCTAssertNil(panel.gitOps.marksReason)
        XCTAssertNil(panel.gitOps.marksLine)
        XCTAssertFalse(panel.gitOps.readingMarks, "no list of the marks across the cluster")
        XCTAssertEqual(markedRowsAcross().map(\.path), [])
        let said = panel.gitOps.matches.flatMap { [$0.why, $0.marked?.place.said(context: "fake-dev") ?? ""] } + panel.gitOps.problems
        XCTAssertFalse(said.contains { $0.contains("isn't in fake-dev") || $0.contains("aren't in fake-dev") }, "\(said)")
        panel.panelVisible = false
    }

    /// The owner's GET refused (403): said as a problem, never as "not in
    /// this cluster" — it may well be there.
    func testARefusedOwnerIsNotSaidMissing() async throws {
        api.forbidden = ["kustomizations@flux-system"]
        let panel = bound("fake-dev")
        try await until(15, "the problem said") { !panel.gitOps.problems.isEmpty }
        XCTAssertTrue(panel.gitOps.problems[0].hasPrefix("Couldn't read"), panel.gitOps.problems[0])
        try await until(15, "listed") { panel.gitOps.state == .live && self.match(panel, "Kustomization", "acme-apps") != nil }
        let whys = match(panel, "Kustomization", "acme-apps")?.whys ?? []
        XCTAssertFalse(whys.contains { $0.said.contains("not in") }, "\(whys)")
        XCTAssertFalse(panel.gitOps.matches.contains { $0.why.contains("not in fake-dev") }, "\(panel.gitOps.matches.map(\.why))")
        panel.panelVisible = false
    }

    /// A list failing (500): said, Refresh offered, and Refresh reads again.
    func testRefreshAfterAFailure() async throws {
        api.failingResources = ["applications"]
        let panel = bound("fake-dev")
        try await until(15, "failed") { if case .failed = panel.gitOps.state { true } else { false } }
        XCTAssertTrue(panel.gitOps.shows)
        XCTAssertTrue(panel.gitOps.canRefresh)
        api.failingResources = []
        panel.gitOps.refresh()
        try await until(15, "read again") { panel.gitOps.state == .live && self.match(panel, "Application", "acme-shop-prod") != nil }
        panel.panelVisible = false
    }

    /// GitOps' groups failing discovery: the owner unreadable, never "not
    /// in" the cluster; Refresh discovers again.
    func testRefreshAfterDiscoveryFailed() async throws {
        api.failingGroups = ["kustomize.toolkit.fluxcd.io/v1", "argoproj.io/v1alpha1", "source.toolkit.fluxcd.io/v1", "helm.toolkit.fluxcd.io/v2"]
        let panel = bound("fake-dev")
        try await until(15, "the problem said") { !panel.gitOps.problems.isEmpty }
        XCTAssertTrue(panel.gitOps.problems.first?.contains("didn't answer discovery") == true, "\(panel.gitOps.problems)")
        XCTAssertFalse(panel.gitOps.matches.contains { $0.why.contains("not in fake-dev") }, "\(panel.gitOps.matches.map(\.why))")
        XCTAssertTrue(panel.gitOps.canRefresh, "\(panel.gitOps.state)")
        api.failingGroups = []
        api.forgetRequests()
        panel.gitOps.refresh()
        try await until(15, "read again") { panel.gitOps.state == .live && self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        XCTAssertTrue(api.requests.contains(where: \.isDiscovery), "discovered again")
        panel.panelVisible = false
    }

    /// P0 discovers once when nothing is known: shown, hidden and shown
    /// again, the context's discovery comes from the cache.
    func testDiscoveryReadOnce() async throws {
        let panel = bound("fake-dev")
        try await until(15, "matched") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        XCTAssertEqual(api.requests.filter { $0.path == "/apis" }.count, 1, "discovered once")
        panel.panelVisible = false
        try await until(5, "hidden") { self.api.openWatches == 0 }
        api.forgetRequests()
        panel.panelVisible = true
        try await until(15, "shown again") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        XCTAssertFalse(api.requests.contains(where: \.isDiscovery), "\(api.requests.filter(\.isDiscovery).map(\.path))")
        panel.panelVisible = false
    }

    /// The binding edited (its selector): what the rail listed for it is
    /// dropped, and listed again at once.
    func testABindingChangeDropsTheCache() async throws {
        let panel = bound("fake-dev")
        try await until(15, "matched") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        api.forgetRequests()
        XCTAssertTrue(panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop,tier=api")))
        try await until(10, "listed again") { !self.gitOpsLists().isEmpty }
        panel.panelVisible = false
    }

    /// The rail's git: remotes and symbolic-refs only — never a fetch —
    /// with the developer's config left out.
    func testTheRailsGitFetchesNothingAndIsIsolated() async throws {
        try await git(["checkout", "-q", "-b", "fix/orders"])
        let panel = bound("fake-dev")
        try await until(15, "matched") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
        XCTAssertEqual(match(panel, "Kustomization", "acme-apps")?.tracks, "tracks main; this branch is fix/orders")
        panel.gitOps.refresh()
        try await until(15, "again") { self.gitCalls.calls.filter { $0 == Refs.remoteArguments }.count == 2 }
        // The remotes, the branches, HEAD, the refs (read, hashed); and 4.3's questions, every one with literal pathspecs.
        let verbs = Set(gitCalls.calls.compactMap(\.first))
        XCTAssertTrue(verbs.isSubset(of: [Refs.remoteArguments[0], "symbolic-ref", "rev-parse", "for-each-ref", KubeGitOpsGitArgs.literal]), "\(gitCalls.calls)")
        XCTAssertTrue(gitCalls.calls.contains(KubeGitOpsCheckouts.refsArguments))
        let literal = Set(gitCalls.calls.filter { $0.first == KubeGitOpsGitArgs.literal }.map { $0.dropFirst().first ?? "" })
        XCTAssertTrue(literal.isSubset(of: ["rev-parse", "rev-list", "merge-base", "diff", "log"]), "\(literal)")
        panel.panelVisible = false
        // In a unit test the rail's own runner leaves the global and system config out.
        let origins = try await KubeGitOpsCheckouts().git(["config", "--list", "--show-origin"], repo, [0])
        let outside = origins.split(separator: "\n").filter { !$0.hasPrefix("file:.git/config") && !$0.hasPrefix("command line:") }
        XCTAssertEqual(outside, [], "only the repository's own config")
    }

    // MARK: Has this branch reached the cluster (gitops.md 4.3, 8.2)

    /// Ask Why, recorded: what the rail adds about the checkout.
    private final class RecordingHost: KubeGitOpsPanelHost {
        var extras: [String: [AskAgentModel.Part]] = [:]
        func gitOpsWrite(_ verb: KubeWriteVerb, on ref: KubeObjectRef) async {}
        func gitOpsTabWrite(_ verb: KubeProcessVerb, on ref: KubeObjectRef) async {}
        func gitOpsOpenOnPage(_ ref: KubeObjectRef) async {}
        func gitOpsOpenMarked(_ ref: KubeMarkedDetailRef, namespaces: [String]) async { opened.append((ref, namespaces)) }
        var opened: [(KubeMarkedDetailRef, [String])] = []
        func gitOpsAskWhy(_ ref: KubeObjectRef, extra: [AskAgentModel.Part]) async { extras[ref.name] = extra }
        var gitOpsWriteStatus: AnyPublisher<KubeWriteStatus?, Never> { Empty().eraseToAnyPublisher() }
    }

    private func head() async throws -> String { try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// acme-apps applied main's c1 (its source fetched the same); fix/orders
    /// one commit ahead under deploy/fake-dev; origin/main at c1 (as a fetch
    /// left it). acme-cron applied c1 and tried HEAD, which failed.
    private func flux(applied c1: String, attempted: String) {
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        api.setFluxStatus(ks, "acme-apps") { status in
            status["lastAppliedRevision"] = "main@sha1:\(c1)"
            status["lastAttemptedRevision"] = "main@sha1:\(c1)"
        }
        api.setFluxStatus("gitrepositories.source.toolkit.fluxcd.io", "acme-fleet") { status in
            status["artifact"] = ["revision": "main@sha1:\(c1)", "lastUpdateTime": FakeKubeAPI.time(Date().addingTimeInterval(-600))]
        }
        api.setFluxStatus(ks, "acme-cron") { status in
            status["lastAppliedRevision"] = "main@sha1:\(c1)"
            status["lastAttemptedRevision"] = "main@sha1:\(attempted)"
        }
    }

    func testTheManifestsLineFromFluxsAppliedRevision() async throws {
        let c1 = try await head()
        try await git(["update-ref", "refs/remotes/origin/main", c1])
        try await git(["checkout", "-q", "-b", "fix/orders"])
        try "resources:\n  - api.yaml\n".write(to: repo.appendingPathComponent("deploy/fake-dev/kustomization.yaml"), atomically: true, encoding: .utf8)
        try "kind: ConfigMap\n".write(to: repo.appendingPathComponent("deploy/fake-dev/api.yaml"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "the fix, see https://bot:ghp_fake0123456789@git.acme.example/acme/shop"])
        let c2 = try await head()
        flux(applied: c1, attempted: c2)
        let panel = bound("fake-dev")
        var reviews: [ReviewSource] = []
        panel.openReview = { source, _ in reviews.append(source) }
        let host = RecordingHost()
        panel.gitOpsHost = host
        try await until(15, "acme-apps' manifests line") { self.match(panel, "Kustomization", "acme-apps")?.reach?.found != nil }
        let apps = try XCTUnwrap(match(panel, "Kustomization", "acme-apps")?.reach)
        XCTAssertEqual(apps.deployed.text, "manifests at \(c1.prefix(7)), up to date with origin/main; this branch is 1 commit ahead")
        XCTAssertEqual(apps.source, "from Flux's applied revision (Kustomization acme-apps, Ready)")
        XCTAssertNil(apps.attempted)
        XCTAssertNil(apps.fetched)
        XCTAssertNil(apps.unchanged, "no change under the path is Argo CD's")
        XCTAssertEqual(apps.pathspecs, ["deploy/fake-dev"], "api.yaml is under the path already")
        XCTAssertEqual(apps.changed?.text, "2 files under deploy/fake-dev on this branch")
        XCTAssertEqual(apps.changed?.review, .paths(base: c1, head: c2, paths: ["deploy/fake-dev/api.yaml", "deploy/fake-dev/kustomization.yaml"]))
        // Diff Deployed…Current and the changed files open their reviews in the checkout.
        let appsMatch = try XCTUnwrap(match(panel, "Kustomization", "acme-apps"))
        panel.gitOps.reviewDeployed(appsMatch)
        panel.gitOps.reviewChanged(appsMatch)
        XCTAssertEqual(reviews, [.range(base: c1, head: "HEAD"), .paths(base: c1, head: c2, paths: ["deploy/fake-dev/api.yaml", "deploy/fake-dev/kustomization.yaml"])])

        // Attempted ≠ applied: HEAD tried, and failed.
        try await until(10, "acme-cron's attempt") { self.match(panel, "Kustomization", "acme-cron")?.reach?.attempted != nil }
        let cron = try XCTUnwrap(match(panel, "Kustomization", "acme-cron"))
        let attempted = try XCTUnwrap(cron.reach?.attempted)
        XCTAssertTrue(attempted.hasPrefix("Flux tried \(c2.prefix(7)) (this branch's HEAD) and failed: BuildFailed: "), attempted)
        XCTAssertTrue(attempted.hasSuffix("; \(c1.prefix(7)) is still applied"), attempted)
        XCTAssertFalse(attempted.contains(FakeKubeAPI.gitOpsSentinel), "the quoted Secret omitted")
        XCTAssertEqual(cron.reach?.range, KubeGitOpsReach.CommitRange(from: c1, to: c2))
        // Ask Why from the rail: the commits between, scrubbed.
        panel.gitOps.askWhy(cron)
        try await until(10, "asked") { host.extras["acme-cron"] != nil }
        let parts = host.extras["acme-cron"] ?? []
        let commits = try XCTUnwrap(parts.first { $0.title == "commits" }?.text)
        XCTAssertTrue(commits.contains("\(c2.prefix(7)) the fix"), commits)
        XCTAssertFalse(commits.contains("ghp_fake0123456789"), "scrubbed: \(commits)")
        XCTAssertTrue(parts.contains { $0.title == "checkout" && $0.text.contains("Flux tried") })

        // The HEAD key: nothing changed, no git; a new HEAD, the line again.
        let runs = panel.gitOps.reachRuns
        panel.gitOps.headMayHaveMoved()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(panel.gitOps.reachRuns, runs, "an unchanged HEAD asks nothing again")
        // A reconcile: Ready → Progressing → Ready, the revisions the same —
        // watch events that change nothing git reads: no git, the words said again.
        let ks = "kustomizations.kustomize.toolkit.fluxcd.io"
        var ready: Any?
        var offset: TimeInterval = 0
        panel.gitOps.clock = { Date().addingTimeInterval(offset) }
        api.setFluxStatus(ks, "acme-apps") { status in
            ready = status["conditions"]
            status["conditions"] = [FakeKubeAPI.condition("Ready", "Unknown", "Progressing", "Reconciliation in progress", since: Date())]
        }
        try await until(10, "the reconcile seen") {
            self.match(panel, "Kustomization", "acme-apps")?.reach?.source.hasSuffix("(Kustomization acme-apps, Ready)") == false
        }
        XCTAssertEqual(panel.gitOps.reachRuns, runs, "a state that flipped asks git nothing")
        XCTAssertEqual(match(panel, "Kustomization", "acme-apps")?.reach?.found?.sha, c1, "the answer kept")
        offset = KubePanelGitOps.refetchEvery + 1
        api.setFluxStatus(ks, "acme-apps") { status in status["conditions"] = ready }
        try await until(10, "Ready again") { self.match(panel, "Kustomization", "acme-apps")?.reach?.source.hasSuffix("(Kustomization acme-apps, Ready)") == true }
        XCTAssertEqual(panel.gitOps.reachRuns, runs, "and back: still no git")
        panel.gitOps.clock = Date.init
        try "two\n".write(to: repo.appendingPathComponent("TWO"), atomically: true, encoding: .utf8)
        try await git(["add", "TWO"])
        try await git(["commit", "-q", "-m", "two"])
        panel.gitOps.headMayHaveMoved()
        try await until(10, "a new HEAD recomputes the manifests line") {
            self.match(panel, "Kustomization", "acme-apps")?.reach?.deployed.text.hasSuffix("this branch is 2 commits ahead") == true
        }
        XCTAssertGreaterThan(panel.gitOps.reachRuns, runs)
        XCTAssertEqual(match(panel, "Kustomization", "acme-apps")?.reach?.changed?.count, 2, "TWO isn't under the path")
        panel.panelVisible = false
    }

    func testAnApplicationsLiveRevisionAndNoChangeUnderItsPath() async throws {
        let c1 = try await head()
        // main moves on outside the path; a fetch left origin/main there.
        try "readme\n".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try await git(["add", "README"])
        try await git(["commit", "-q", "-m", "readme"])
        let c2 = try await head()
        try await git(["update-ref", "refs/remotes/origin/main", c2])
        api.addApplication(
            "acme-shop-dev",
            spec: [
                "project": "acme", "source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "deploy/fake-dev", "targetRevision": "main"],
                "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
            ],
            status: [
                "sync": ["status": "Synced", "revision": c2], "health": ["status": "Healthy"],
                "history": [["revision": c1, "deployedAt": FakeKubeAPI.time(Date().addingTimeInterval(-600))]],
            ])
        let panel = bound("fake-dev")
        try await until(15, "its line") { self.match(panel, "Application", "acme-shop-dev")?.reach?.unchanged != nil }
        let reach = try XCTUnwrap(match(panel, "Application", "acme-shop-dev")?.reach)
        XCTAssertTrue(reach.source.hasPrefix("from Argo CD's synced revision (Application acme-shop-dev, "), reach.source)
        XCTAssertTrue(reach.deployed.text.hasPrefix("manifests at \(c1.prefix(7)), 1 commit behind origin/main"), reach.deployed.text)
        XCTAssertEqual(reach.fetched, "git has \(c2.prefix(7)); Argo CD synced \(c1.prefix(7)) (newer than \(c1.prefix(7)))")
        XCTAssertEqual(reach.unchanged, "no change under deploy/fake-dev since \(c1.prefix(7)) on origin/main")
        XCTAssertEqual(reach.changed?.text, "no change under deploy/fake-dev on this branch")
        XCTAssertNil(reach.changed?.review)
        panel.panelVisible = false
    }

    // MARK: Production, writable by default (gitops.md 4.4, 8.2)

    /// The window's part, as `TerminalWindowController` plays it: every
    /// verb to the page's guard path; Open on Page and Ask Why recorded and
    /// passed on.
    private final class PageHost: KubeGitOpsPanelHost {
        let page: KubernetesPageModel
        var opened: [KubeObjectRef] = []
        var asked: [KubeObjectRef] = []
        var extras: [String: [AskAgentModel.Part]] = [:]
        init(_ page: KubernetesPageModel) { self.page = page }
        func gitOpsWrite(_ verb: KubeWriteVerb, on ref: KubeObjectRef) async { page.write(verb, on: ref) }
        func gitOpsTabWrite(_ verb: KubeProcessVerb, on ref: KubeObjectRef) async { page.runTabWrite(verb, on: ref) }
        func gitOpsOpenOnPage(_ ref: KubeObjectRef) async { opened.append(ref) }
        func gitOpsOpenMarked(_ ref: KubeMarkedDetailRef, namespaces: [String]) async {}
        func gitOpsAskWhy(_ ref: KubeObjectRef, extra: [AskAgentModel.Part]) async {
            asked.append(ref)
            extras[ref.name] = extra
            page.askWhy(ref, extra: extra)
        }
        var gitOpsWriteStatus: AnyPublisher<KubeWriteStatus?, Never> { page.$writeStatus.eraseToAnyPublisher() }
    }

    private final class Sheets {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var confirms: [(String, () -> Void)] = []
        var briefs = 0
        var count: Int { confirmations.count + confirms.count }
    }

    /// On fake-prod, writable by default — its socket doesn't refuse a
    /// write — every rail action short of a confirmed verb sends
    /// nothing but GETs; a write lands only once its sheet is confirmed.
    func testOnWritableProductionNothingIsWrittenUnconfirmed() async throws {
        pageRan = true
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeMCPTests.list(current: "fake-prod")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        let sheets = Sheets()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        // Every sheet cancelled: its `then` is kept, never called — until the one confirmed below.
        actions.confirmWrite = { confirmation, then in sheets.confirmations.append((confirmation, then)) }
        actions.confirm = { title, _, _, then in sheets.confirms.append((title, then)) }
        actions.askWhy = { _ in sheets.briefs += 1 }
        page.actions = actions
        model.show()
        defer { model.hide() }
        try await until(10, "the page's contexts") { model.contextsRead && model.selectedName == "fake-prod" }
        XCTAssertEqual(model.contexts.context(named: "fake-prod")?.isWritable, true, "writable by default, no switch")

        let panel = bound("fake-prod", model: model, writable: true)
        let host = PageHost(page)
        panel.gitOpsHost = host
        try await until(15, "the owner") { self.match(panel, "Kustomization", "acme-apps")?.object != nil }
        panel.gitOps.find()
        try await until(15, "found") { self.match(panel, "Kustomization", "acme-cron") != nil && self.match(panel, "Application", "acme-shop-prod") != nil }
        panel.gitOps.refresh()
        try await until(15, "read again") { panel.gitOps.state == .live && self.match(panel, "Application", "acme-shop-prod")?.object != nil }
        XCTAssertEqual(api.writes.filter { !$0.isAccessReview }, [], "reading wrote nothing")

        // Every verb on every match, each sheet left unanswered.
        let matches = panel.gitOps.matches.filter { $0.object != nil }
        XCTAssertGreaterThanOrEqual(matches.count, 3)
        for match in matches {
            for act in [panel.gitOps.reconcile, panel.gitOps.syncInTab] {
                let before = sheets.count
                page.writeStatus = nil
                act(match)
                try await until(10, "\(match.said): asked or refused") {
                    sheets.count > before || (page.writeStatus.map { !$0.isWorking } ?? false)
                }
                // A tab write's line stays "Checking…" while its sheet asks: the check itself has ended.
                try await until(5, "the check ended") { page.writeChecking == nil }
            }
            panel.gitOps.openOnPage(match)
            panel.gitOps.askWhy(match)
            try await until(10, "\(match.said): Ask Why read") { page.askingWhy == nil && host.asked.contains { $0.name == match.key.name } }
        }
        XCTAssertEqual(host.opened.count, matches.count)
        XCTAssertGreaterThan(sheets.confirmations.count, 0, "the verbs asked in the window")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(api.writes.filter { !$0.isAccessReview }.map(\.description), [], "nothing written while every sheet is unanswered")
        XCTAssertTrue(api.requests.allSatisfy { $0.method == "GET" || $0.isAccessReview }, "\(api.requests.filter { $0.method != "GET" })")

        // One confirmed: then, and only then, its request.
        let reconcile = try XCTUnwrap(
            sheets.confirmations.first { $0.0.verb == .reconcile && $0.0.title.contains("acme-apps") }, "\(sheets.confirmations.map(\.0.title))")
        XCTAssertTrue(reconcile.0.scope.contains("fake-prod"), reconcile.0.scope)
        reconcile.1(KubeWriteAnswer(typed: reconcile.0.typedName ?? ""))
        try await until(10, "patched") {
            self.api.writes.contains { $0.method == "PATCH" && $0.path == "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/acme-apps" }
        }
        XCTAssertEqual(api.writes.filter { !$0.isAccessReview }.count, 1, "\(api.writes)")
        panel.panelVisible = false
    }
}
