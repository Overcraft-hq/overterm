import XCTest

@testable import Overterm

/// The rail's Kubernetes panel (docs/design/kubernetes/analysis.md,
/// Section 6, 3.1–3.2) against `FakeKubeAPI` on a socket of the test's
/// own, a kubeconfig of two fictional contexts, a git checkout of the
/// test's own and a bindings file of its own: hidden it reads nothing — no
/// file of the checkout, no cluster —; shown unbound it guesses from the
/// checkout's files; bound it follows the namespace's workloads and pods
/// with the binding's selector sent to the server, says each workload's
/// deployed commit against the checkout, and hidden again every watch ends.
/// Only GETs, and no Secret.
@MainActor
final class KubernetesPanelModelTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var folder: URL!
    private var repo: URL!
    private var sha = ""
    /// A test that reads a release's Helm records (its Secrets, as the Helm page does).
    private var readsHelmRecords = false

    override func setUp() async throws {
        socket = "/tmp/otkp-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-panel-\(UUID().uuidString)", isDirectory: true)
        repo = folder.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("k8s"), withIntermediateDirectories: true)
        try "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\n  labels:\n    app.kubernetes.io/part-of: shop\n".write(
            to: repo.appendingPathComponent("k8s/web.yaml"), atomically: true, encoding: .utf8)
        func git(_ arguments: [String]) async throws -> String {
            try await Git.run(["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + arguments, in: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["add", "k8s/web.yaml"])
        _ = try await git(["commit", "-q", "-m", "web"])
        sha = try await git(["rev-parse", "HEAD"])

        api.addNamespace("shop")
        let part = ["app.kubernetes.io/part-of": "shop"]
        api.add(
            "deployments.apps", "web", namespace: "shop",
            values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1, "Images": .text("ghcr.io/acme/web:\(sha.prefix(7))")], labels: part)
        api.add(
            "deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0, "Images": "ghcr.io/acme/worker:1.4.2"],
            labels: part)
        api.add("deployments.apps", "other", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1])
        api.addPod("web-1", namespace: "shop", labels: part)
        api.addPod("worker-1", namespace: "shop", FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 4), labels: part)
        api.addPod("other-1", namespace: "shop")
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            if !readsHelmRecords { XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "no Secret: \(api.requests)") }
            api.stop()
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func makePanel() -> KubernetesPanelModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeMCPTests.listForPanel()
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let panel = KubernetesPanelModel(store: KubeBindingStore(file: folder.appendingPathComponent("support/bindings.json")), kubernetes: model)
        let socket = self.socket!
        panel.clientFor = { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name)) }
        return panel
    }

    private func until(_ seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testHiddenItReadsNothing() async throws {
        let panel = makePanel()
        panel.checkout = repo
        XCTAssertTrue(panel.store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop")))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(api.requests.isEmpty, "\(api.requests)")
        XCTAssertNil(panel.guess)
        XCTAssertEqual(panel.state, .idle)
        XCTAssertTrue(panel.workloads.isEmpty)
    }

    func testUnboundItGuessesFromTheCheckoutsFiles() async throws {
        let panel = makePanel()
        panel.checkout = repo
        panel.panelVisible = true
        try await until(5, "the guess") { panel.guess != nil }
        XCTAssertEqual(panel.guess?.namespace, "shop")
        XCTAssertEqual(panel.guess?.selector, "app.kubernetes.io/part-of=shop")
        XCTAssertEqual(panel.guess?.workloads, ["deploy/web"])
        XCTAssertTrue(api.requests.isEmpty, "unbound, no cluster is asked: \(api.requests)")
        panel.beginEdit()
        try await until(5, "the draft") { panel.draft != nil }
        XCTAssertEqual(panel.contextNames, ["fake-dev", "fake-prod"])
        XCTAssertEqual(panel.draft?.context, "fake-dev", "the first context that isn't production")
        XCTAssertEqual(panel.draft?.namespace, "shop")
        XCTAssertTrue(panel.saveDraft())
        XCTAssertEqual(panel.binding?.selector, "app.kubernetes.io/part-of=shop")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.path).sorted(), [".git", "k8s"], "nothing written into the checkout")
        try await until(10, "its workloads") { panel.state == .live && panel.workloads.map(\.id) == ["deploy/web"] }
        panel.panelVisible = false
    }

    func testBoundItFollowsTheNamespaceAndSaysTheDeployedCommit() async throws {
        let panel = makePanel()
        panel.checkout = repo
        XCTAssertTrue(panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=shop")))
        panel.panelVisible = true
        try await until(10, "the workloads and pods") {
            panel.state == .live && panel.workloads.map(\.id) == ["deploy/web", "deploy/worker"] && panel.pods.map(\.id.name) == ["web-1", "worker-1"]
        }
        XCTAssertEqual(panel.workloads.first?.health, "Available")
        XCTAssertEqual(panel.workloads.last?.failing, true)
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["labelSelector"] == "app.kubernetes.io/part-of=shop" },
            "the selector is the server's: \(api.requests.map(\.path))")
        // Rows only — a workload's with its metadata, in this one namespace, for who deploys it (gitops.md 4.2).
        XCTAssertTrue(
            api.requests.allSatisfy {
                $0.query["includeObject"] == nil || $0.query["includeObject"] == "None"
                    || ($0.query["includeObject"] == "Metadata" && $0.path.hasPrefix("/apis/apps/v1/namespaces/shop/"))
            }, "rows only: \(api.requests.map { "\($0.path) \($0.query)" })")
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/pods") && $0.query["includeObject"] == "Metadata" }, "the pods' rows carry nothing")
        try await until(10, "the deployed commit") { panel.deployed["deploy/web"] != nil && panel.deployed["deploy/worker"] != nil }
        XCTAssertEqual(panel.deployed["deploy/web"]?.text, "deployed \(sha.prefix(7)), up to date with main")
        XCTAssertEqual(panel.deployed["deploy/worker"], KubeDeployedAnswer.none)
        XCTAssertEqual(panel.headline?.workload.id, "deploy/web")

        // A new pod comes by the watch.
        api.addPod("web-2", namespace: "shop", labels: ["app.kubernetes.io/part-of": "shop"])
        try await until(5, "the new pod") { panel.pods.contains { $0.id.name == "web-2" } }

        // Diff deployed…current: a review tab for the range.
        var reviewed: (ReviewSource, URL)?
        panel.openReview = { reviewed = ($0, $1) }
        panel.reviewDeployed(try XCTUnwrap(panel.deployed["deploy/web"]?.found))
        XCTAssertEqual(reviewed?.0, .range(base: sha, head: "HEAD"))
        XCTAssertEqual(reviewed?.1, repo)

        // Look Up: the revision label, only when asked.
        var asked: [String] = []
        panel.inspectRevision = { image in
            asked.append(image)
            return image.hasPrefix("ghcr.io/acme/worker") ? self.sha : nil
        }
        let worker = try XCTUnwrap(panel.workloads.first { $0.id == "deploy/worker" })
        panel.lookUp(worker)
        try await until(5, "the label's commit") { panel.deployed["deploy/worker"]?.found?.source == .revisionLabel }
        XCTAssertEqual(asked, ["ghcr.io/acme/worker:1.4.2"])

        // A pod in the right slot: read only while the slot shows it.
        var slots = 0
        panel.showSlot = { slots += 1 }
        panel.pick(KubeRowID(namespace: "shop", name: "worker-1"))
        XCTAssertEqual(slots, 1)
        try await until(5, "its session") { panel.session != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods/worker-1" }, "not shown: not read")
        panel.slotVisible = true
        try await until(5, "its object") { panel.session?.state == .loaded }

        // Hidden: every watch ends, nothing more is asked, nothing stale
        // shown — but the right slot keeps its pod.
        panel.panelVisible = false
        XCTAssertTrue(panel.workloads.isEmpty && panel.pods.isEmpty)
        XCTAssertEqual(panel.picked, KubeRowID(namespace: "shop", name: "worker-1"), "the slot's pod outlives the panel hiding")
        XCTAssertEqual(panel.session?.state, .loaded)
        panel.slotVisible = false
        try await until(5, "the watches end") { api.openWatches == 0 }
        api.forgetRequests()
        api.addPod("web-3", namespace: "shop", labels: ["app.kubernetes.io/part-of": "shop"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(api.requests.isEmpty, "\(api.requests)")
        // Shown again: the same pod, not read again.
        panel.panelVisible = true
        panel.slotVisible = true
        try await until(10, "live again") { panel.state == .live }
        XCTAssertEqual(panel.session?.state, .loaded)
        // Unbound: the slot's pod goes with the binding.
        panel.unbind()
        XCTAssertNil(panel.session)
        XCTAssertNil(panel.picked)
        panel.panelVisible = false
    }

    /// 3.2's third source: the bound release's newest chart appVersion,
    /// read when asked — and kept for that binding only.
    func testLookUpReadsTheReleasesAppVersionForItsBindingOnly() async throws {
        readsHelmRecords = true
        api.addHelmRelease("shop", namespace: "shop", appVersion: sha)
        let panel = makePanel()
        panel.inspectRevision = { _ in nil }
        panel.checkout = repo
        XCTAssertTrue(
            panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", release: "shop", selector: "app.kubernetes.io/part-of=shop")))
        panel.panelVisible = true
        try await until(10, "the answers") { panel.deployed["deploy/worker"] == KubeDeployedAnswer.none }
        let worker = try XCTUnwrap(panel.workloads.first { $0.id == "deploy/worker" })
        panel.lookUp(worker)
        try await until(10, "the appVersion's commit") { panel.deployed["deploy/worker"]?.found?.source == .appVersion }
        XCTAssertTrue(panel.lookingUp.isEmpty)
        XCTAssertNil(panel.lookUpProblem)
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/secrets" && $0.query["labelSelector"]?.contains("owner=helm") == true })

        // Bound again, to another release: that appVersion is not this one's.
        XCTAssertTrue(
            panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", release: "other", selector: "app.kubernetes.io/part-of=shop")))
        try await until(10, "answered again") { panel.deployed["deploy/web"] != nil && panel.deployed["deploy/worker"] != nil }
        XCTAssertEqual(panel.deployed["deploy/worker"], KubeDeployedAnswer.none, "another binding's appVersion isn't a candidate")
        // Back to the first: its own is remembered.
        XCTAssertTrue(
            panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", release: "shop", selector: "app.kubernetes.io/part-of=shop")))
        try await until(10, "its own again") { panel.deployed["deploy/worker"]?.found?.source == .appVersion }
        panel.panelVisible = false
    }

    func testOnProductionTheReleasesAppVersionIsntRead() async throws {
        api.addNamespace("payments")
        api.add("deployments.apps", "api", namespace: "payments", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1, "Images": "ghcr.io/acme/api:2.0"])
        api.addHelmRelease("payments", namespace: "payments", appVersion: sha)
        let panel = makePanel()
        panel.inspectRevision = { _ in nil }
        panel.checkout = repo
        XCTAssertTrue(panel.bind(KubeBinding(checkout: repo.path, context: "fake-prod", namespace: "payments", release: "payments")))
        panel.panelVisible = true
        try await until(10, "its workload") { panel.state == .live && panel.production && panel.workloads.map(\.id) == ["deploy/api"] }
        panel.lookUp(try XCTUnwrap(panel.workloads.first))
        try await until(10, "the refusal") { panel.lookUpProblem != nil }
        XCTAssertTrue(panel.lookUpProblem?.contains("a production release's appVersion is read on the Helm page") == true, panel.lookUpProblem ?? "")
        XCTAssertTrue(panel.lookingUp.isEmpty)
        XCTAssertNotEqual(panel.deployed["deploy/api"]?.found?.source, .appVersion)
        panel.panelVisible = false
        // tearDown: no Secret was asked for.
    }

    /// A look-up still running when the panel hides, or the binding is
    /// edited, ends on its own: its workload's button doesn't stay "Looking Up…".
    func testALookUpOutlivedByItsPanelLeavesNothingBehind() async throws {
        let panel = makePanel()
        panel.inspectRevision = { _ in
            try? await Task.sleep(for: .milliseconds(400))
            return nil
        }
        panel.checkout = repo
        let binding = KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=shop")
        XCTAssertTrue(panel.bind(binding))
        panel.panelVisible = true
        try await until(10, "the workloads") { panel.state == .live && panel.workloads.count == 2 }
        let worker = try XCTUnwrap(panel.workloads.first { $0.id == "deploy/worker" })

        panel.lookUp(worker)
        XCTAssertEqual(panel.lookingUp, ["deploy/worker"])
        panel.panelVisible = false
        XCTAssertTrue(panel.lookingUp.isEmpty, "hidden: nothing is being looked up")
        panel.panelVisible = true
        try await until(10, "live again") { panel.state == .live && panel.workloads.count == 2 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(panel.lookingUp.isEmpty)
        XCTAssertNil(panel.lookUpProblem, "the old look-up says nothing over the new panel")

        // Edited while it runs: the same.
        panel.lookUp(worker)
        XCTAssertTrue(panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=shop", workloads: ["deploy/worker"])))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(panel.lookingUp.isEmpty)
        try await until(10, "live again") { panel.state == .live && panel.workloads.map(\.id) == ["deploy/worker"] }
        panel.lookUp(try XCTUnwrap(panel.workloads.first))
        XCTAssertEqual(panel.lookingUp, ["deploy/worker"], "it can be asked again")
        try await until(5, "it ends") { panel.lookingUp.isEmpty }
        XCTAssertNotNil(panel.lookUpProblem)
        panel.panelVisible = false
    }

    /// A kind that can't be listed (a 403 for a namespace-scoped user)
    /// says so while the others show, and is followed again after a wait;
    /// everything refused, Try Again.
    func testAFailedKindSaysSoAndRecovers() async throws {
        api.forbidden = ["statefulsets"]
        let panel = makePanel()
        panel.retryDelays = [.milliseconds(200)]
        panel.checkout = repo
        XCTAssertTrue(panel.bind(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=shop")))
        panel.panelVisible = true
        try await until(10, "the rest") { panel.state == .live && panel.workloads.count == 2 && panel.pods.count == 2 }
        XCTAssertEqual(panel.problems.count, 1)
        XCTAssertTrue(panel.problems.first?.hasPrefix("Couldn't list StatefulSets") == true, "\(panel.problems)")
        api.forbidden = []
        try await until(10, "followed again") { panel.problems.isEmpty }
        XCTAssertEqual(panel.state, .live)

        // Everything refused: failed, and Try Again recovers it.
        panel.panelVisible = false
        api.forbidden = ["deployments", "statefulsets", "pods"]
        panel.retryDelays = [.seconds(60)]
        panel.panelVisible = true
        try await until(10, "failed") { if case .failed = panel.state { true } else { false } }
        api.forbidden = []
        panel.retry()
        try await until(10, "live again") { panel.state == .live && panel.workloads.count == 2 && panel.problems.isEmpty }
        panel.panelVisible = false
    }

    func testThePodsListedAreCappedFailingOnesFirst() {
        func pod(_ name: String, _ status: String) -> KubernetesPanelModel.Pod {
            .init(summary: KubePodSummary(id: KubeRowID(namespace: "shop", name: name), ready: 1, containers: 1, status: status, restarts: 0))
        }
        let pods = (0..<10).map { pod("p\($0)", $0 == 8 ? "CrashLoopBackOff" : $0 == 9 ? "Pending" : "Running") }
        let (shown, hidden) = KubernetesPanelModel.limited(pods, limit: 4)
        XCTAssertEqual(shown.map(\.id.name), ["p0", "p1", "p8", "p9"], "the failing ones kept, in the list's order")
        XCTAssertEqual(hidden, 6)
        XCTAssertEqual(KubernetesPanelModel.limited(pods, limit: 10).hidden, 0)
    }

    func testAFolderThatIsntARepositoryIsNotGuessedFrom() async throws {
        let panel = makePanel()
        let plain = folder.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("k8s"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("k8s/web.yaml"), to: plain.appendingPathComponent("k8s/web.yaml"))
        panel.checkout = plain
        panel.panelVisible = true
        XCTAssertFalse(panel.canBind)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(panel.guess, "nothing read")
        XCTAssertFalse(panel.guessing)
        panel.beginEdit()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(panel.draft, "no Bind offered")
        panel.checkout = repo
        XCTAssertTrue(panel.canBind)
        try await until(5, "the guess") { panel.guess != nil }
        panel.panelVisible = false
    }

    func testABindingToAContextTheKubeconfigHasntSaysSo() async throws {
        let panel = makePanel()
        panel.checkout = repo
        XCTAssertTrue(panel.bind(KubeBinding(checkout: repo.path, context: "acme-gone", namespace: "shop")))
        panel.panelVisible = true
        try await until(5, "the failure") { if case .failed = panel.state { true } else { false } }
        XCTAssertEqual(panel.state, .failed("The kubeconfig has no context “acme-gone”: edit the binding."))
        XCTAssertTrue(api.requests.isEmpty)
        panel.unbind()
        XCTAssertNil(panel.binding)
        panel.panelVisible = false
    }
}

extension KubeMCPTests {
    /// The panel's kubeconfig: the same two fictional contexts.
    nonisolated static func listForPanel() -> KubeContextList { list(current: "fake-dev") }
}
