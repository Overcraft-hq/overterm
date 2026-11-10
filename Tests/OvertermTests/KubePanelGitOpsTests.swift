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
        // Neither Argo CD nor Flux served here: the cluster Argo CD runs in is another.
        if name.contains("Unserved") { api.addNamespace("shop") } else { api.addGitOpsFixtures() }
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
        // `writable`: production with its writes on — the socket no longer refuses them.
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
        try await until(15, "matched") { self.match(panel, "Kustomization", "acme-apps")?.whys.count == 2 }
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

    func testATrackingIDNamingAnApplicationNotHereIsSaid() async throws {
        api.add(
            "statefulsets.apps", "shop-db", namespace: "shop", values: ["Ready": "1/1"], labels: ["app.kubernetes.io/part-of": "ot-shop"],
            annotations: ["argocd.argoproj.io/tracking-id": "acme-gone:apps/StatefulSet:shop/shop-db"])
        let panel = bound("fake-dev")
        try await until(15, "said") { self.match(panel, "Application", "acme-gone") != nil }
        XCTAssertEqual(match(panel, "Application", "acme-gone")?.why, "managed by Argo CD Application acme-gone (not in fake-dev)")
        XCTAssertNil(match(panel, "Application", "acme-gone")?.object)
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
        try await until(15, "said") { self.match(panel, "Application", "acme-hub") != nil }
        XCTAssertEqual(match(panel, "Application", "acme-hub")?.why, "managed by Argo CD Application acme-hub (not in fake-dev)")
        XCTAssertEqual(panel.gitOps.state, .unserved)
        XCTAssertTrue(panel.gitOps.shows)
        XCTAssertTrue(panel.gitOps.canRefresh, "Refresh offered")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.gitOps.state, .unserved, "not turned live by a later row")
        XCTAssertFalse(
            api.requests.contains { $0.path.contains("argoproj.io") || $0.path.contains("toolkit.fluxcd.io") }, "\(api.requests.map(\.path))")
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
        let verbs = Set(gitCalls.calls.compactMap(\.first))
        XCTAssertEqual(verbs, Set([Refs.remoteArguments[0], "symbolic-ref"]), "\(gitCalls.calls)")
        panel.panelVisible = false
        // In a unit test the rail's own runner leaves the global and system config out.
        let origins = try await KubeGitOpsCheckouts().git(["config", "--list", "--show-origin"], repo, [0])
        let outside = origins.split(separator: "\n").filter { !$0.hasPrefix("file:.git/config") && !$0.hasPrefix("command line:") }
        XCTAssertEqual(outside, [], "only the repository's own config")
    }

    // MARK: Production with its writes on (gitops.md 4.4, 8.2)

    /// The window's part, as `TerminalWindowController` plays it: every
    /// verb to the page's guard path; Open on Page and Ask Why recorded and
    /// passed on.
    private final class PageHost: KubeGitOpsPanelHost {
        let page: KubernetesPageModel
        var opened: [KubeObjectRef] = []
        var asked: [KubeObjectRef] = []
        init(_ page: KubernetesPageModel) { self.page = page }
        func gitOpsWrite(_ verb: KubeWriteVerb, on ref: KubeObjectRef) async { page.write(verb, on: ref) }
        func gitOpsTabWrite(_ verb: KubeProcessVerb, on ref: KubeObjectRef) async { page.runTabWrite(verb, on: ref) }
        func gitOpsOpenOnPage(_ ref: KubeObjectRef) async { opened.append(ref) }
        func gitOpsAskWhy(_ ref: KubeObjectRef) async {
            asked.append(ref)
            page.askWhy(ref)
        }
        var gitOpsWriteStatus: AnyPublisher<KubeWriteStatus?, Never> { page.$writeStatus.eraseToAnyPublisher() }
    }

    private final class Sheets {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var confirms: [(String, () -> Void)] = []
        var briefs = 0
        var count: Int { confirmations.count + confirms.count }
    }

    /// On fake-prod with "Allow writes until quit" on — its socket no longer
    /// refuses a write — every rail action short of a confirmed verb sends
    /// nothing but GETs; a write lands only once its sheet is confirmed.
    func testOnProductionWithWritesOnNothingIsWrittenUnconfirmed() async throws {
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
        await model.setProductionWrites(true, for: "fake-prod")
        XCTAssertEqual(model.contexts.context(named: "fake-prod")?.sessionWrites, true, "writes on until quit")
        XCTAssertEqual(model.contexts.context(named: "fake-prod")?.isWritable, true)

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
