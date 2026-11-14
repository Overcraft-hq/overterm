import XCTest

@testable import Overterm

/// `k8s_gitops` and `k8s_why` on Argo CD's and Flux's objects (docs/design/
/// kubernetes/gitops.md, 6.1, 8.2; G7) against `FakeKubeAPI` with §8.3's
/// fixtures on a socket of the test's own, a kubeconfig of two fictional
/// contexts (never ~/.kube), and a git checkout of the test's own whose
/// remote names `acme/shop` (its git isolated from the developer's
/// config): the scope's objects, problems first, one line each, bounded;
/// the sentinel and every URL's userinfo absent; `checkout` on the pane's
/// binding only, refused unbound or naming another context, on production
/// with a cold cache no list across the cluster, with a warm one the
/// rail's; no GitOps write tool. Every test ends with only GETs, never a
/// Secret or a ConfigMap. (`k8s_apply` on a Kustomization having the
/// person type its name is `KubeApplySessionTests`'.)
@MainActor
final class KubeMCPGitOpsTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var folder: URL!
    private var repo: URL!
    private var store: KubeBindingStore!
    private lazy var model: KubernetesModel = makeModel()
    private var kept: (cache: KubeGitOpsMatchCache, checkouts: KubeGitOpsCheckouts, bindings: KubeBindingStore, pane: ((String) -> URL?)?)!

    override func setUp() async throws {
        socket = "/tmp/otkmg-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addGitOpsFixtures()
        let labels = [
            "app.kubernetes.io/part-of": "ot-shop", "kustomize.toolkit.fluxcd.io/name": "acme-apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
        ]
        api.add("deployments.apps", "shop-api", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1], labels: labels)

        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-mcp-gitops-\(UUID().uuidString)", isDirectory: true)
        repo = folder.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("deploy/fake-dev"), withIntermediateDirectories: true)
        try "resources: []\n".write(to: repo.appendingPathComponent("deploy/fake-dev/kustomization.yaml"), atomically: true, encoding: .utf8)
        try await git(["init", "-q", "-b", "main"])
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "shop"])
        try await git(["remote", "add", "origin", "git@git.acme.example:acme/shop.git"])

        store = KubeBindingStore(file: folder.appendingPathComponent("bindings.json"))
        kept = (KubeMCP.gitOpsCache, KubeMCP.gitOpsCheckouts, KubeMCP.bindings, KubeMCP.paneCheckout)
        KubeMCP.gitOpsCache = KubeGitOpsMatchCache()
        let checkouts = KubeGitOpsCheckouts()
        checkouts.git = KubeGitOpsCheckouts.isolatedGit
        KubeMCP.gitOpsCheckouts = checkouts
        KubeMCP.bindings = store
        let repo = self.repo!
        KubeMCP.paneCheckout = { $0 == "pane-bound" ? repo : nil }
        KubeMCP.forgetDiscoveries()
    }

    override func tearDown() async throws {
        if let kept {
            KubeMCP.gitOpsCache = kept.cache
            KubeMCP.gitOpsCheckouts = kept.checkouts
            KubeMCP.bindings = kept.bindings
            KubeMCP.paneCheckout = kept.pane
        }
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "no Secret")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/configmaps") }, "no ConfigMap")
            XCTAssertFalse(api.requests.contains { $0.isWatch }, "read once, never followed")
            api.stop()
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeModel() -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeMCPTests.list(current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return model
    }

    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        return try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
    }

    private func pageSelected() async {
        guard model.selectedName == nil else { return }
        model.reloadContexts()
        var waited = 0
        while model.selectedName == nil && waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
    }

    private func call(_ name: String, _ arguments: [String: Any], pane: String? = nil) async -> (text: String, error: Bool) {
        await pageSelected()
        do {
            let result = try await KubeMCP.call(name, arguments, kubernetes: model, pane: pane)
            return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool == true)
        } catch let error as BrowserMCP.ToolError {
            return (error.message, true)
        } catch {
            return ("\(error)", true)
        }
    }

    private func text(_ name: String, _ arguments: [String: Any] = [:], pane: String? = nil) async -> String {
        let answer = await call(name, arguments, pane: pane)
        XCTAssertFalse(answer.error, "\(name): \(answer.text)")
        return answer.text
    }

    /// No value, patch, manifest or credential an agent is given.
    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for needle in [FakeKubeAPI.gitOpsSentinel, "ghp_fake", "bot:", "user:"] {
            XCTAssertFalse(text.contains(needle), "\(needle) in:\n\(text)", file: file, line: line)
        }
    }

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    // MARK: The tool

    func testItIsAReadAndNoGitOpsWriteToolExists() {
        let names = KubeMCP.tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("k8s_gitops") && KubeMCP.reads.contains("k8s_gitops"))
        let writes = KubeMCP.writeTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(writes), Set(KubeMCP.writes))
        for name in names + writes {
            for word in ["gitops", "sync", "reconcile", "suspend", "resume", "refresh", "argo", "flux"] where name != "k8s_gitops" {
                XCTAssertFalse(name.contains(word), "no GitOps write tool: \(name)")
            }
        }
        XCTAssertFalse(KubeMCP.writes.contains("k8s_gitops"))
        XCTAssertTrue(KubeMCP.instructions.contains("k8s_gitops"))
    }

    func testTheScopesObjectsProblemsFirstOneLineEachScrubbed() async throws {
        let said = await text("k8s_gitops")
        let all = lines(said)
        XCTAssertTrue(all[0].hasPrefix("Context fake-dev"), said)
        XCTAssertTrue(all[1].contains("GitOps objects in or deploying into") && all[1].contains("Failed"), said)
        // acme-cron: Flux tried c03f9aa and failed; a77b0d1 stays applied.
        let cron = all.first { $0.hasPrefix("Kustomization flux-system/acme-cron  Failed") }
        XCTAssertNotNil(cron, said)
        XCTAssertTrue(cron?.contains("c03f9aa failed; applied main@a77b0d1") == true, cron ?? said)
        XCTAssertTrue(cron?.contains("source acme/shop ./apps/cron @main") == true, cron ?? said)
        XCTAssertTrue(cron?.contains("into shop") == true && cron?.contains("BuildFailed") == true, cron ?? said)
        XCTAssertTrue(cron?.contains("manifest omitted") == true || cron?.contains("Secret") == false, "cut at its manifest: \(cron ?? "")")
        // Problems first: no Ready line before a Failed one.
        let states = all.dropFirst(2).compactMap { line in KubeGitOpsState.allCases.first { line.contains("  \($0.word)") } }
        XCTAssertEqual(states, states.sorted(), said)
        // Scope: an object deploying into shop, from argocd; not envs-dev's.
        XCTAssertTrue(said.contains("Application argocd/acme-web"), said)
        XCTAssertFalse(said.contains("acme-envs-dev"), "deploys into envs-dev: \(said)")
        assertClean(said)
        // One paged list of whole objects a kind, never past 20 a page, never a Table follow.
        let lists = api.requests.filter { $0.path.hasSuffix("/kustomizations") }
        XCTAssertFalse(lists.isEmpty)
        XCTAssertTrue(lists.allSatisfy { Int($0.query["limit"] ?? "") ?? 99 <= KubeGitOpsSession.pageLimit && !$0.accept.contains("as=Table") }, "\(lists)")
    }

    func testKindFailingOnlyAndLimit() async throws {
        let failing = await text("k8s_gitops", ["kind": "kustomization", "failing_only": true])
        let rows = lines(failing).filter { $0.hasPrefix("Kustomization ") }
        XCTAssertFalse(rows.isEmpty, failing)
        XCTAssertTrue(rows.allSatisfy { $0.contains("  Failed") || $0.contains("  Blocked") || $0.contains("  Stuck") }, failing)
        XCTAssertFalse(failing.contains("acme-apps"), "Ready: \(failing)")
        XCTAssertFalse(failing.contains("Application "), failing)
        // Only the kinds a Kustomization rests on are read: never Applications.
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/applications") }, "\(api.requests.map(\.path))")
        let one = await text("k8s_gitops", ["kind": "kustomization", "limit": 1])
        XCTAssertEqual(lines(one).filter { $0.hasPrefix("Kustomization ") }.count, 1, one)
        XCTAssertTrue(one.contains("more not listed"), one)
        let wrong = await call("k8s_gitops", ["kind": "pods"])
        XCTAssertTrue(wrong.error && wrong.text.contains("“kind” is application"), wrong.text)
        let sources = await text("k8s_gitops", ["kind": "source", "namespace": "all"])
        XCTAssertTrue(sources.contains("GitRepository flux-system/acme-fleet") && !sources.contains("Kustomization "), sources)
        assertClean(sources)
    }

    func testAKindIsCutAtTheAgentsBoundAndSaysSo() async throws {
        api.addNamespace("bulk")
        for index in 0..<(KubeMCP.gitOpsObjects + 5) {
            api.addApplication(
                "bulk-\(index)", namespace: "bulk",
                spec: [
                    "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "bulk", "targetRevision": "main"],
                    "destination": ["server": "https://kubernetes.default.svc", "namespace": "bulk"],
                ],
                status: ["sync": ["status": "Synced", "revision": FakeKubeAPI.GitOpsCommit.applied], "health": ["status": "Healthy"]])
        }
        let said = await text("k8s_gitops", ["kind": "application", "namespace": "all", "limit": 500])
        XCTAssertTrue(said.contains("Applications: 200 of"), said)
        XCTAssertTrue(said.contains("narrow it with a namespace or kind"), said)
        XCTAssertLessThanOrEqual(lines(said).filter { $0.hasPrefix("Application ") }.count, KubeMCP.gitOpsObjects)
        XCTAssertLessThanOrEqual(said.count, KubeMCPText.maxCharacters)
    }

    func testANamespaceRefusedAcrossTheClusterIsReadWhereItLives() async throws {
        api.forbidden.insert("kustomizations.kustomize.toolkit.fluxcd.io@cluster")
        let said = await text("k8s_gitops", ["kind": "kustomization"])
        XCTAssertTrue(said.contains("Kustomizations: forbidden across the cluster; read in shop, flux-system"), said)
        XCTAssertTrue(said.contains("acme-cron"), said)
    }

    func testARefusedKindHoldsItsBoundAcrossTheNamespacesItIsReadIn() async throws {
        api.forbidden.insert("applications.argoproj.io@cluster")
        seedApplications(KubeMCP.gitOpsObjects + 5, in: "shop")
        api.forgetRequests()
        let said = await text("k8s_gitops", ["kind": "application", "limit": 500])
        XCTAssertTrue(said.contains("Applications: forbidden across the cluster; read in shop."), said)
        XCTAssertTrue(said.contains("Applications in shop: 200 of"), said)
        XCTAssertTrue(said.contains("Applications: 200 objects or 16 MB a kind read; not read in argocd"), "the bound spent in shop: \(said)")
        XCTAssertFalse(api.requests.contains { $0.path == Self.applications(in: "argocd") }, "argocd not read past the bound")
        XCTAssertLessThanOrEqual(asked(Self.applications(in: "shop")), KubeMCP.gitOpsObjects)
    }

    func testABudgetHoldsObjectsAndBytesAcrossPlaces() {
        var budget = KubeGitOpsBudget(objects: 200, bytes: 16 << 20)
        var first = KubeGitOpsPaged()
        first.objects = Array(repeating: KubeGitOpsObject.testKustomization(), count: 3)
        first.bytes = 12 << 20
        XCTAssertTrue(budget.allows("argocd"))
        budget.spend(first)
        XCTAssertEqual(budget.left.objects, 197)
        XCTAssertEqual(budget.left.bytes, 4 << 20, "the bytes left, not 16 MB again")
        var second = KubeGitOpsPaged()
        second.bytes = 4 << 20
        XCTAssertTrue(budget.allows("shop"))
        budget.spend(second)
        XCTAssertFalse(budget.allows("team-a"))
        XCTAssertFalse(budget.allows("team-b"))
        XCTAssertEqual(budget.said("Applications"), "Applications: 200 objects or 16 MB a kind read; not read in team-a, team-b")
        // The rail's: each place its own bound.
        var rail = KubeGitOpsBudget(objects: 500, bytes: 64 << 20, shared: false)
        rail.spend(first)
        XCTAssertEqual(rail.left.bytes, 64 << 20)
        XCTAssertTrue(rail.allows("shop"))
        XCTAssertNil(rail.said("Applications"))
    }

    // MARK: Why

    func testWhyOnAnApplicationAnswersAndASourceIsRefused() async throws {
        let said = await text("k8s_why", ["kind": "application", "name": "acme-web", "namespace": "argocd"])
        XCTAssertTrue(said.contains("acme-web"), said)
        XCTAssertTrue(said.contains("admission webhook denied the request"), said)
        assertClean(said)
        let ks = await text("k8s_why", ["kind": "ks", "name": "acme-cron", "namespace": "flux-system"])
        XCTAssertTrue(ks.contains("acme-cron") && ks.contains("BuildFailed"), ks)
        assertClean(ks)
        let ready = await text("k8s_why", ["kind": "kustomization", "name": "acme-apps", "namespace": "flux-system"])
        XCTAssertTrue(ready.contains("Ready"), "not failing, said: \(ready)")
        let source = await call("k8s_why", ["kind": "source", "name": "acme-fleet", "namespace": "flux-system"])
        XCTAssertTrue(source.error && source.text.contains("“kind” is pod, deployment, application"), source.text)
        let repository = await call("k8s_why", ["kind": "gitrepositories", "name": "acme-fleet", "namespace": "flux-system"])
        XCTAssertTrue(repository.error, repository.text)
    }

    func testWhyTakesArgoCDsApplicationWhereAnotherApplicationsKindComesFirst() async throws {
        // kubernetes-sigs' Application (GKE installs it), its group listed before argoproj.io.
        api.addCRD(group: "app.k8s.io", version: "v1beta1", plural: "applications", kind: "Application", first: true)
        let said = await text("k8s_why", ["kind": "application", "name": "acme-web", "namespace": "argocd"])
        XCTAssertTrue(said.contains("acme-web") && said.contains("admission webhook denied the request"), said)
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/acme-web" }, "Argo CD's")
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/apis/app.k8s.io/") }, "never the other kind")
        let full = await text("k8s_why", ["kind": "applications.argoproj.io", "name": "acme-web", "namespace": "argocd"])
        XCTAssertTrue(full.contains("acme-web"), full)
        let other = await call("k8s_why", ["kind": "applications.app.k8s.io", "name": "acme-web", "namespace": "argocd"])
        XCTAssertTrue(other.error && other.text.contains("“kind” is pod, deployment, application"), other.text)
    }

    // MARK: checkout

    func testCheckoutIsThePanesBindingWithTheDeployedSentence() async throws {
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=ot-shop")))
        let said = await text("k8s_gitops", ["checkout": true], pane: "pane-bound")
        XCTAssertTrue(said.contains("What deploys this checkout (shop), bound to fake-dev/shop"), said)
        XCTAssertTrue(said.contains("Kustomization flux-system/acme-apps  Ready"), said)
        XCTAssertTrue(said.contains("matched: owns Deployment/shop-api · deploy/fake-dev; tracks main"), said)
        XCTAssertTrue(said.contains("manifests at a77b0d1"), "the deployed sentence: \(said)")
        XCTAssertTrue(said.contains("Kustomization flux-system/acme-cron  Failed"), said)
        XCTAssertTrue(said.contains("Flux tried c03f9aa"), "the attempted line: \(said)")
        XCTAssertFalse(said.contains("acme-api"), "another repository: \(said)")
        assertClean(said)
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/acme-apps" },
            "the owner by one GET")
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "Metadata" },
            "the workloads with their marks, in the binding's namespace")
        // Not kept: the rail's listing is the rail's.
        let facts = await KubeMCP.gitOpsCheckouts.facts(repo)
        let key = KubeGitOpsMatchCache.Key(
            context: "fake-dev", checkout: try XCTUnwrap(store.binding(for: repo)?.checkout), namespace: "shop", remotes: facts.remotesKey)
        XCTAssertNil(KubeMCP.gitOpsCache.listing(key))
    }

    func testCheckoutHoldsTheAgentsBoundAcrossArgoCDsNamespaces() async throws {
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop")))
        seedApplications(KubeMCP.gitOpsObjects + 5, in: "argocd")
        seedApplications(3, in: "shop")
        api.forgetRequests()
        let said = await text("k8s_gitops", ["checkout": true], pane: "pane-bound")
        XCTAssertTrue(said.contains("searched 200 of"), said)
        XCTAssertTrue(said.contains("Applications summarised; the rest show their state only in argocd"), said)
        XCTAssertTrue(said.contains("Applications: 200 objects or 16 MB a kind read; not read in shop"), "the bound spent in argocd: \(said)")
        XCTAssertLessThanOrEqual(asked(Self.applications(in: "argocd")), KubeMCP.gitOpsObjects, "never past 200 objects asked of argocd")
        XCTAssertFalse(api.requests.contains { $0.path == Self.applications(in: "shop") }, "shop not read past the kind's bound")
    }

    func testCheckoutRefusesUnboundAndAnotherContext() async throws {
        let unbound = await call("k8s_gitops", ["checkout": true], pane: "pane-other")
        XCTAssertTrue(unbound.error && unbound.text.contains("isn't bound to a context"), unbound.text)
        let noPane = await call("k8s_gitops", ["checkout": true])
        XCTAssertTrue(noPane.error && noPane.text.contains("isn't bound"), noPane.text)
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop")))
        let other = await call("k8s_gitops", ["checkout": true, "context": "fake-prod"], pane: "pane-bound")
        XCTAssertTrue(other.error && other.text.contains("only on the checkout's own context, fake-dev"), other.text)
        XCTAssertTrue(api.requests.isEmpty, "refused, nothing asked: \(api.requests)")
    }

    func testOnProductionAColdCacheListsNothingAcrossTheCluster() async throws {
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-prod", namespace: "shop")))
        let said = await text("k8s_gitops", ["checkout": true], pane: "pane-bound")
        XCTAssertTrue(said.hasPrefix("PRODUCTION context fake-prod"), said)
        XCTAssertTrue(
            said.contains("On fake-prod only the owners of the bound workloads were read; press Find What Deploys This in the rail for more"), said)
        XCTAssertTrue(said.contains("Kustomization flux-system/acme-apps"), "the owner, by its GET: \(said)")
        XCTAssertFalse(said.contains("acme-cron"), "found only by a list: \(said)")
        XCTAssertEqual(KubePanelGitOpsTests.gitOpsLists(api.requests).map(\.path), [], "no list across the cluster")
        XCTAssertFalse(api.requests.contains { $0.path == KubePanelGitOpsTests.gitRepositoriesAcross })
        assertClean(said)
    }

    func testWithTheRailsListingKeptItAnswersFromIt() async throws {
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-prod", namespace: "shop")))
        // What the rail would have kept after Find What Deploys This.
        let facts = await KubeMCP.gitOpsCheckouts.facts(repo)
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-prod"))
        let discovery = try await client.discover()
        guard case .success(let listing) = await KubePanelGitOps.listing(client: client, discovery: discovery, checkout: facts, namespace: "shop", argo: ["argocd"])
        else { return XCTFail("listed") }
        // The binding's checkout is its real path (/private/var/…): the key the tool asks by.
        let checkout = try XCTUnwrap(store.binding(for: repo)?.checkout)
        let key = KubeGitOpsMatchCache.Key(context: "fake-prod", checkout: checkout, namespace: "shop", remotes: facts.remotesKey)
        KubeMCP.gitOpsCache.keep(listing, for: key)
        api.forgetRequests()
        let said = await text("k8s_gitops", ["checkout": true], pane: "pane-bound")
        XCTAssertTrue(said.contains("as the rail read them in the last five minutes"), said)
        XCTAssertTrue(said.contains("Kustomization flux-system/acme-cron  Failed"), said)
        XCTAssertEqual(KubePanelGitOpsTests.gitOpsLists(api.requests).map(\.path), [], "nothing listed again")
        assertClean(said)
    }

    // MARK: Helpers

    private static func applications(in namespace: String) -> String { "/apis/argoproj.io/v1alpha1/namespaces/\(namespace)/applications" }

    /// How many objects were asked of `path`: its pages' limits, summed.
    private func asked(_ path: String) -> Int {
        api.requests.filter { $0.path == path }.reduce(0) { $0 + (Int($1.query["limit"] ?? "") ?? Int.max / 1024) }
    }

    private func seedApplications(_ count: Int, in namespace: String) {
        if !api.names("namespaces").contains(namespace) { api.addNamespace(namespace) }
        for index in 0..<count {
            api.addApplication(
                "\(namespace)-bulk-\(index)", namespace: namespace,
                spec: [
                    "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "bulk", "targetRevision": "main"],
                    "destination": ["server": "https://kubernetes.default.svc", "namespace": "bulk"],
                ],
                status: ["sync": ["status": "Synced", "revision": FakeKubeAPI.GitOpsCommit.applied], "health": ["status": "Healthy"]])
        }
    }

    // MARK: Pure

    func testALineSaysAnAttemptBesideWhatIsApplied() {
        var object = KubeGitOpsObject.testKustomization()
        object.revisions.applied = ["main@sha1:\(FakeKubeAPI.GitOpsCommit.applied)"]
        object.revisions.attempted = "main@sha1:\(FakeKubeAPI.GitOpsCommit.attempted)"
        object.state = .failed
        XCTAssertEqual(KubeMCPGitOpsText.revision(object), "main@c03f9aa failed; applied main@a77b0d1")
        object.state = .ready
        XCTAssertEqual(KubeMCPGitOpsText.revision(object), "main@a77b0d1")
    }
}

extension KubeGitOpsObject {
    /// A bare Kustomization, for the pure tests.
    static func testKustomization() -> KubeGitOpsObject {
        let data = try! JSONSerialization.data(withJSONObject: [
            "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization",
            "metadata": ["name": "acme-cron", "namespace": "flux-system"],
            "spec": ["path": "./apps/cron", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]],
        ])
        return try! KubeGitOpsSummary.object(data, readAt: Date())!
    }
}
