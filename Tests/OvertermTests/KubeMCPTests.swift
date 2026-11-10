import XCTest

@testable import Overterm

/// Agents' `k8s_` tools (stage 1e; docs/design/kubernetes/analysis.md,
/// 3.5) against `FakeKubeAPI` on a socket of the test's own, through a
/// `KubernetesModel` whose kubeconfig is two fictional contexts — never
/// ~/.kube: each tool's answer, scrubbed and bounded; the default context
/// and namespace, another named, an unknown one refused; production read;
/// a Secret said from its row, never read; the setting taking the group
/// away; and no write tool at all. Every test ends with only GETs, no
/// subresource but a pod's log, and no Secret's object asked for.
@MainActor
final class KubeMCPTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private lazy var model: KubernetesModel = makeModel()
    /// Whether a call is made as after the page selected a context (fake-dev).
    private var pageSelects = true

    nonisolated static let password = "hunter2-fake-pw"
    nonisolated static let token = "fake-token-value-123"
    nonisolated static let secretValue = "never-read-secret-value"

    override func setUpWithError() throws {
        socket = "/tmp/otkm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addNamespace("payments")
        var web = FakeKubeAPI.Pod()
        web.env = ["DB_PASSWORD": Self.password, "MODE": "dev"]
        api.addPod("web-1", namespace: "shop", web, labels: ["app": "web"])
        var crashing = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 3)
        crashing.env = ["API_TOKEN": Self.token]
        api.addPod("worker-1", namespace: "shop", crashing, labels: ["app": "worker"])
        api.setLog("web-1", namespace: "shop", ["GET /healthz 200", "using \(Self.password) to connect", "GET /orders 500"])
        api.setLog("worker-1", namespace: "shop", ["using \(Self.token)", "panic: boom"], previous: true)
        api.addEvent(about: "pods", "worker-1", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container app", count: 7)
        api.addEvent(about: "pods", "web-1", namespace: "shop", reason: "Scheduled", message: "Assigned shop/web-1 to fake-node-1")
        api.add(
            "secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"],
            annotations: [KubeObjectStrip.lastApplied: "{\"data\":{\"password\":\"\(Data(Self.secretValue.utf8).base64EncodedString())\"}}"],
            data: ["password": Self.secretValue])
        api.addPod("api-0", namespace: "payments")
        deployment()
        MainActor.assumeIsolated { KubeMCP.forgetDiscoveries() }
    }

    /// The kubeconfig: fake-dev (remote) and fake-prod (production), both
    /// on the fake's socket; nothing read from ~/.kube.
    private func makeModel(current: String = "fake-dev", proxies: KubeProxies = KubeProxies(), direct: Bool = true) -> KubernetesModel {
        let model = KubernetesModel(proxies: proxies)
        let list = Self.list(current: current)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        guard direct else { return model }
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return model
    }

    /// fake-dev and fake-prod; `cluster` renames fake-dev's cluster (the
    /// kubeconfig changed: the same name, another cluster).
    nonisolated static func list(current: String, cluster: String? = nil, devSettings: KubeContextSettings = KubeContextSettings()) -> KubeContextList {
        let contexts = ["fake-dev", "fake-prod"].map { name in
            let clusterName = name == "fake-dev" ? cluster ?? name : name
            return KubeContext(
                name: name, cluster: clusterName, server: "http://127.0.0.1:1", namespace: name == "fake-dev" ? "shop" : "payments",
                user: "fake-user-\(name)", auth: KubeAuth.none, file: nil,
                contextClass: KubeClassifier.classify(context: name, cluster: clusterName, set: nil),
                settings: name == "fake-dev" ? devSettings : KubeContextSettings())
        }
        return KubeContextList(contexts: contexts, current: current)
    }

    /// The page has selected a context (kubectl's current, the page's
    /// first pick): the kubeconfig read, nothing asked of a cluster.
    private func pageSelected() async {
        guard model.selectedName == nil else { return }
        model.reloadContexts()
        var waited = 0
        while model.selectedName == nil && waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        XCTAssertNotNil(model.selectedName, "the page selected a context")
    }

    private func until(_ seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests.filter { !$0.isLog }, [], "no subresource but a pod's log")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "no Secret's object is asked for: \(api.requests)")
            XCTAssertTrue(
                api.requests.filter { $0.path.hasSuffix("/secrets") }.allSatisfy { $0.accept.contains("as=Table") },
                "a Secret only as a Table's row")
            api.stop()
        }
    }

    /// Deployment web (revision 2) and its ReplicaSets web-7d9f (2,
    /// nginx:1.27) and web-5c4a (1, nginx:1.26, a change-cause).
    nonisolated private func deployment() {
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            annotations: ["deployment.kubernetes.io/revision": "2"],
            fields: [
                "metadata": ["generation": 2],
                "spec": [
                    "replicas": 1, "selector": ["matchLabels": ["app": "web"]],
                    "template": [
                        "metadata": ["labels": ["app": "web"]],
                        "spec": ["containers": [["name": "app", "image": "nginx:1.27", "env": [["name": "DB_PASSWORD", "value": Self.password]]]]],
                    ],
                ],
                "status": [
                    "observedGeneration": 2, "replicas": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1,
                    "conditions": [["type": "Available", "status": "True", "reason": "MinimumReplicasAvailable"]],
                ],
            ])
        let uid = api.uid("deployments.apps", "web", namespace: "shop") ?? ""
        for (name, revision, image) in [("web-7d9f", "2", "nginx:1.27"), ("web-5c4a", "1", "nginx:1.26")] {
            api.add(
                "replicasets.apps", name, namespace: "shop", labels: ["app": "web"],
                annotations: ["deployment.kubernetes.io/revision": revision, "kubernetes.io/change-cause": "kubectl set image deploy/web app=\(image)"],
                fields: [
                    "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "uid": uid, "controller": true]]],
                    "spec": [
                        "replicas": revision == "2" ? 1 : 0, "selector": ["matchLabels": ["app": "web"]],
                        "template": ["spec": ["containers": [["name": "app", "image": image]]]],
                    ],
                    "status": ["replicas": revision == "2" ? 1 : 0, "readyReplicas": revision == "2" ? 1 : 0],
                ])
        }
    }

    private func text(_ name: String, _ arguments: [String: Any] = [:]) async throws -> String {
        if pageSelects { await pageSelected() }
        let result = try await KubeMCP.call(name, arguments, kubernetes: model)
        XCTAssertNil(result["isError"], "\(name): \(result)")
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func refused(_ name: String, _ arguments: [String: Any] = [:]) async -> String? {
        if pageSelects { await pageSelected() }
        do {
            _ = try await KubeMCP.call(name, arguments, kubernetes: model)
            return nil
        } catch let error as BrowserMCP.ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// Nothing an agent is given carries a planted secret.
    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for needle in [Self.password, Self.token, Self.secretValue, Data(Self.secretValue.utf8).base64EncodedString()] {
            XCTAssertFalse(text.contains(needle), "\(needle) in:\n\(text)", file: file, line: line)
        }
    }

    // MARK: The tools

    func testEveryToolReadsAndNoneWrites() {
        let names = KubeMCP.tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, KubeMCP.reads)
        XCTAssertEqual(
            Set(names), ["k8s_contexts", "k8s_get", "k8s_describe", "k8s_logs", "k8s_events", "k8s_why", "k8s_rollout", "k8s_top", "k8s_metrics", "k8s_gitops"],
            "k8s_top since metrics (2d), k8s_metrics since M11, k8s_gitops since G7")
        for verb in ["restart", "scale", "delete", "apply", "patch", "exec", "edit", "secret"] {
            XCTAssertFalse(names.contains { $0.contains(verb) }, "no \(verb) tool")
        }
        XCTAssertTrue(KubeMCP.tools.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
    }

    func testAWriteOnAReadOnlyContextIsRefusedAndSecretIsUnknown() async {
        XCTAssertTrue(KubeMCP.writes.contains("k8s_apply"), "k8s_apply is a write tool (2b): refused where agents may not write")
        for name in ["k8s_secret"] {
            let said = await refused(name, ["name": "web-1", "namespace": "shop"])
            XCTAssertTrue(said?.contains("Unknown tool") == true, "\(name): \(said ?? "answered")")
        }
        for name in KubeMCP.writes {
            let said = await refused(name, ["name": "web-1", "namespace": "shop", "replicas": 2])
            XCTAssertTrue(said?.contains("isn't offered on fake-dev") == true, "\(name): \(said ?? "answered")")
            let prod = await refused(name, ["name": "api-0", "namespace": "payments", "context": "fake-prod", "replicas": 0])
            XCTAssertTrue(prod?.contains("isn't offered on fake-prod") == true, "\(name): \(prod ?? "answered")")
        }
        XCTAssertTrue(api.requests.isEmpty, "nothing asked: \(api.requests)")
    }

    func testContextsSayClassAndNamespaceButNoServerOrUser() async throws {
        let said = try await text("k8s_contexts")
        XCTAssertTrue(said.contains("* fake-dev — remote, read-only for Overterm; namespace shop; kubectl's current context"), said)
        XCTAssertTrue(said.contains("  fake-prod — PRODUCTION, read-only for Overterm; namespace payments"), said)
        XCTAssertFalse(said.contains("127.0.0.1") || said.contains("fake-user"), "no server, no user: \(said)")
        XCTAssertTrue(api.requests.isEmpty, "listing contexts asks no cluster: \(api.requests)")
    }

    func testGetIsTheServersTableInThePagesNamespace() async throws {
        let said = try await text("k8s_get", ["kind": "po"])
        XCTAssertTrue(said.hasPrefix("Context fake-dev (read-only for Overterm), namespace shop."), said)
        let lines = said.components(separatedBy: "\n")
        XCTAssertTrue(lines[1].hasPrefix("NAME") && lines[1].contains("STATUS") && lines[1].contains("RESTARTS"), said)
        XCTAssertTrue(lines.contains { $0.hasPrefix("worker-1") && $0.contains("CrashLoopBackOff") }, said)
        XCTAssertFalse(said.contains("api-0"), "another namespace's pod")
        XCTAssertTrue(
            api.requests.contains {
                $0.path == "/api/v1/namespaces/shop/pods" && $0.accept.contains("as=Table") && $0.query["includeObject"] == "None"
                    && $0.query["limit"] == "100"
            }, "\(api.requests)")

        let picked = try await text("k8s_get", ["kind": "pods", "label_selector": "app=web"])
        XCTAssertTrue(picked.contains("web-1") && !picked.contains("worker-1"), picked)
        XCTAssertTrue(api.requests.contains { $0.query["labelSelector"] == "app=web" })
        let one = try await text("k8s_get", ["kind": "pods", "name": "worker-1"])
        XCTAssertTrue(one.contains("worker-1") && !one.contains("web-1"), one)
        XCTAssertTrue(api.requests.contains { $0.query["fieldSelector"] == "metadata.name=worker-1" })
        let filtered = try await text("k8s_get", ["kind": "pods", "filter": "crashloop"])
        XCTAssertTrue(filtered.contains("worker-1") && !filtered.contains("web-1"), filtered)
        let cut = try await text("k8s_get", ["kind": "pods", "limit": 1])
        XCTAssertTrue(cut.contains("1 more not listed"), cut)
        let all = try await text("k8s_get", ["kind": "pods", "namespace": "all"])
        XCTAssertTrue(all.contains(", all namespaces.") && all.contains("NAMESPACE") && all.contains("payments") && all.contains("api-0"), all)
        let deployments = try await text("k8s_get", ["kind": "deploy"])
        XCTAssertTrue(deployments.contains("web") && deployments.contains("1/1"), deployments)
        let none = try await text("k8s_get", ["kind": "pods", "label_selector": "app=nothing"])
        XCTAssertTrue(none.hasSuffix("No pods matching app=nothing."), none)
    }

    func testAFluxSourcesURLReachesAnAgentWithoutItsCredentials() async throws {
        api.addCRD(
            group: "source.toolkit.fluxcd.io", version: "v1", plural: "gitrepositories", kind: "GitRepository", shortNames: ["gitrepo"],
            columns: [FakeKubeAPI.Column(name: "URL"), FakeKubeAPI.Column(name: "Ready"), FakeKubeAPI.Column(name: "Status")])
        api.add(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-fleet", namespace: "shop",
            values: ["URL": "https://ghp_fake@git.acme.example/acme/shop.git", "Ready": "False", "Status": "unable to clone 'https://bot:ghp_fake@git.acme.example/acme/shop.git'"])
        api.add("gitrepositories.source.toolkit.fluxcd.io", "acme-other", namespace: "payments", values: ["URL": "https://u:ghp_fake@git.acme.example/acme/pay.git"])
        for namespace in ["shop", "all"] {
            let said = try await text("k8s_get", ["kind": "gitrepositories", "namespace": namespace])
            XCTAssertTrue(said.contains("acme-fleet") && said.contains("https://git.acme.example/acme/shop.git"), said)
            XCTAssertFalse(said.contains("ghp_fake"), said)
        }
    }

    /// A source's Ready message and its events quote the URL it failed
    /// to clone: describe and events give them without its userinfo, a
    /// token with no `:` and one too short to look like a credential too.
    func testAFluxSourcesDescribeAndEventsGiveNoUserinfo() async throws {
        api.addCRD(
            group: "source.toolkit.fluxcd.io", version: "v1", plural: "gitrepositories", kind: "GitRepository", shortNames: ["gitrepo"],
            columns: [FakeKubeAPI.Column(name: "URL"), FakeKubeAPI.Column(name: "Ready")])
        let failed = "unable to clone 'https://tok9z@git.acme.example/acme/x.git': authentication required"
        api.add(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-fleet", namespace: "shop", values: ["URL": "https://tok9z@git.acme.example/acme/x.git"],
            fields: [
                "spec": ["url": "https://tok9z@git.acme.example/acme/x.git", "interval": "1m"],
                "status": ["conditions": [["type": "Ready", "status": "False", "reason": "GitOperationFailed", "message": failed]]],
            ])
        api.addEvent(
            about: "gitrepositories.source.toolkit.fluxcd.io", "acme-fleet", namespace: "shop", type: "Warning", reason: "GitOperationFailed",
            message: "failed to checkout and determine revision: unable to clone 'https://deploy:tok9z@git.acme.example/acme/x.git'",
            component: "source-controller")
        let described = try await text("k8s_describe", ["kind": "gitrepositories", "name": "acme-fleet"])
        XCTAssertTrue(described.contains("GitRepository shop/acme-fleet") && described.contains("https://git.acme.example/acme/x.git"), described)
        XCTAssertTrue(described.contains("GitOperationFailed"), "its events and Ready said: \(described)")
        XCTAssertFalse(described.contains("tok9z"), described)
        let events = try await text("k8s_events", ["kind": "gitrepositories", "name": "acme-fleet"])
        XCTAssertTrue(events.contains("GitOperationFailed") && events.contains("https://git.acme.example/acme/x.git"), events)
        XCTAssertFalse(events.contains("tok9z"), events)
        let namespace = try await text("k8s_events")
        XCTAssertTrue(namespace.contains("GitOperationFailed"), namespace)
        XCTAssertFalse(namespace.contains("tok9z"), namespace)
    }

    func testAReadOnProductionWorks() async throws {
        let said = try await text("k8s_get", ["kind": "pods", "context": "fake-prod"])
        XCTAssertTrue(said.hasPrefix("PRODUCTION context fake-prod (read-only: Overterm changes nothing there), namespace payments."), said)
        XCTAssertTrue(said.contains("api-0"), said)
        let described = try await text("k8s_describe", ["kind": "pod", "name": "api-0", "context": "fake-prod"])
        XCTAssertTrue(described.hasPrefix("PRODUCTION context fake-prod") && described.contains("Pod payments/api-0"), described)
    }

    func testAnUnknownContextIsAnErrorNeverAFallback() async {
        let said = await refused("k8s_get", ["kind": "pods", "context": "acme-prod"])
        XCTAssertEqual(said, "No context “acme-prod” in the kubeconfig. It has: fake-dev, fake-prod.")
        let path = await refused("k8s_describe", ["kind": "pods", "name": "../secrets/web-db"])
        XCTAssertEqual(path, "“../secrets/web-db” isn't an object's name.")
        let kind = await refused("k8s_get", ["kind": "gizmos"])
        XCTAssertEqual(kind, "fake-dev serves no kind “gizmos”.")
        XCTAssertFalse(api.requests.contains { $0.path.contains("pods") }, "nothing listed for them: \(api.requests)")
    }

    func testANamedContextUsesItsOwnNamespace() async throws {
        let said = try await text("k8s_get", ["kind": "pods", "context": "fake-prod", "namespace": "shop"])
        XCTAssertTrue(said.contains("namespace shop") && said.contains("worker-1"), said)
    }

    // MARK: Secrets

    func testASecretIsListedAndDescribedFromItsRowNeverRead() async throws {
        let listed = try await text("k8s_get", ["kind": "secrets"])
        XCTAssertTrue(listed.contains("web-db") && listed.contains("Opaque"), listed)
        XCTAssertTrue(listed.contains("never read for an agent"), listed)
        assertClean(listed)
        let described = try await text("k8s_describe", ["kind": "secret", "name": "web-db"])
        XCTAssertTrue(described.contains("Secret shop/web-db: type Opaque, 1 key"), described)
        XCTAssertFalse(described.contains("password"), "not even its keys: \(described)")
        assertClean(described)
        let alias = try await text("k8s_describe", ["kind": "sec", "name": "web-db"])
        XCTAssertTrue(alias.contains("Secret shop/web-db"), alias)
        let missing = await refused("k8s_describe", ["kind": "secrets", "name": "nope"])
        XCTAssertEqual(missing, "No secret shop/nope.")
        let why = await refused("k8s_why", ["kind": "secret", "name": "web-db"])
        XCTAssertNotNil(why, "Ask Why is a pod's or a Deployment's")
    }

    /// Across namespaces a list's rows carry their metadata — a Secret's
    /// last-applied data: Secrets are listed one namespace at a time, rows only.
    func testSecretsAcrossNamespacesAreListedANamespaceAtATimeRowsOnly() async throws {
        api.add(
            "secrets", "api-key", namespace: "payments", values: ["Type": "Opaque"],
            annotations: [KubeObjectStrip.lastApplied: "{\"data\":{\"key\":\"\(Data(Self.secretValue.utf8).base64EncodedString())\"}}"],
            data: ["key": Self.secretValue])
        let all = try await text("k8s_get", ["kind": "secrets", "namespace": "all"])
        XCTAssertTrue(all.contains(", all namespaces.") && all.contains("NAMESPACE"), all)
        XCTAssertTrue(all.components(separatedBy: "\n").contains { $0.hasPrefix("shop") && $0.contains("web-db") && $0.contains("Opaque") }, all)
        XCTAssertTrue(all.components(separatedBy: "\n").contains { $0.hasPrefix("payments") && $0.contains("api-key") }, all)
        assertClean(all)
        let lists = api.requests.filter { $0.path.hasSuffix("/secrets") }
        XCTAssertFalse(lists.isEmpty)
        XCTAssertTrue(lists.allSatisfy { $0.query["includeObject"] == "None" && $0.path.hasPrefix("/api/v1/namespaces/") }, "\(lists)")
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/secrets" }, "never across namespaces at once")
        XCTAssertFalse(api.requests.contains { $0.query["includeObject"] == "Metadata" }, "\(api.requests)")

        let bound = KubeMCP.secretNamespaces
        defer { KubeMCP.secretNamespaces = bound }
        KubeMCP.secretNamespaces = 1
        let cut = try await text("k8s_get", ["kind": "secrets", "namespace": "all"])
        XCTAssertTrue(cut.contains("More not listed"), cut)
    }

    // MARK: Describe, logs, events

    func testDescribeSumsUpAPodWithItsEventsScrubbed() async throws {
        let said = try await text("k8s_describe", ["kind": "pod", "name": "worker-1"])
        XCTAssertTrue(said.contains("Pod shop/worker-1"), said)
        XCTAssertTrue(said.contains("CrashLoopBackOff"), said)
        XCTAssertTrue(said.contains("Events of pod/worker-1") && said.contains("Warning BackOff ×7"), said)
        assertClean(said)
        let deployment = try await text("k8s_describe", ["kind": "deployments.apps", "name": "web"])
        XCTAssertTrue(deployment.contains("Deployment shop/web") && deployment.contains("Pods it selects (app=web)") && deployment.contains("web-1"), deployment)
        XCTAssertEqual(deployment.components(separatedBy: "successfully rolled out").count, 2, "its rollout said once: \(deployment)")
        assertClean(deployment)
    }

    func testLogsAreScrubbedBeforeGrepLooks() async throws {
        let said = try await text("k8s_logs", ["pod": "web-1"])
        XCTAssertTrue(said.contains("Log of pod shop/web-1, container app: the last 200 lines:"), said)
        XCTAssertTrue(said.contains("GET /orders 500"), said)
        assertClean(said)
        let grep = try await text("k8s_logs", ["pod": "web-1", "grep": "hunter2"])
        XCTAssertTrue(grep.hasSuffix("(no lines)"), "a secret can't be found by grep: \(grep)")
        let errors = try await text("k8s_logs", ["pod": "web-1", "grep": "500", "tail": 50])
        XCTAssertTrue(errors.contains("GET /orders 500") && !errors.contains("healthz"), errors)
        XCTAssertTrue(api.requests.contains { $0.isLog && $0.query["tailLines"] == "50" && $0.query["follow"] == nil && $0.query["limitBytes"] != nil })
        let previous = try await text("k8s_logs", ["pod": "worker-1", "previous": true])
        XCTAssertTrue(previous.contains("its previous instance") && previous.contains("panic: boom"), previous)
        assertClean(previous)
        _ = try await text("k8s_logs", ["pod": "web-1", "since": "10m"])
        XCTAssertTrue(api.requests.contains { $0.isLog && $0.query["sinceTime"] != nil })
        let container = await refused("k8s_logs", ["pod": "web-1", "container": "nope"])
        XCTAssertEqual(container, "pod/web-1 has no container “nope”. It has: app.")
        let since = await refused("k8s_logs", ["pod": "web-1", "since": "soon"])
        XCTAssertNotNil(since)
    }

    func testEventsOfANamespaceAndOfAnObject() async throws {
        let namespace = try await text("k8s_events")
        XCTAssertTrue(namespace.contains("Warning BackOff pod/worker-1 ×7") && namespace.contains("Normal Scheduled pod/web-1"), namespace)
        let warnings = try await text("k8s_events", ["warnings_only": true])
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/events" && $0.query["fieldSelector"] == "type=Warning" }, warnings)
        let object = try await text("k8s_events", ["name": "web-1"])
        XCTAssertTrue(object.contains("Scheduled") && !object.contains("BackOff"), object)
        XCTAssertTrue(api.requests.contains { $0.query["fieldSelector"]?.contains("involvedObject.name=web-1") == true })
    }

    /// The server lists events in key order, not by time: past a page,
    /// every page is read before the newest are picked, and a list cut at
    /// the bound says so.
    func testEventsPastAPageAreReadBeforeTheNewestArePicked() async throws {
        let (page, pages) = (KubeMCP.eventsPage, KubeMCP.eventPages)
        defer { (KubeMCP.eventsPage, KubeMCP.eventPages) = (page, pages) }
        KubeMCP.eventsPage = 3
        KubeMCP.eventPages = 20
        for index in 0..<8 {
            api.addEvent(about: "pods", "aa-old-\(index)", namespace: "shop", reason: "Old\(index)", message: "old", last: Date().addingTimeInterval(-3600 - Double(index)))
        }
        api.addEvent(about: "pods", "zz-newest", namespace: "shop", type: "Warning", reason: "Newest", message: "the newest", last: Date().addingTimeInterval(120))
        let said = try await text("k8s_events", ["limit": 1])
        XCTAssertTrue(said.contains("Warning Newest pod/zz-newest"), said)
        XCTAssertFalse(said.contains("only the first"), said)
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/events" && $0.query["continue"] != nil && $0.query["limit"] == "3" })

        KubeMCP.eventPages = 1
        let cut = try await text("k8s_events")
        XCTAssertTrue(cut.contains("… only the first 3 events in namespace shop were read"), cut)
        XCTAssertTrue(cut.contains("name (one object's events), warnings_only"), cut)
        XCTAssertFalse(cut.contains("zz-newest"), "past the bound: \(cut)")
    }

    // MARK: Why, rollout

    func testWhyIsAskWhysBriefScrubbed() async throws {
        let said = try await text("k8s_why", ["name": "worker-1"])
        XCTAssertTrue(said.hasPrefix("Question: Why does pod shop/worker-1 keep crashing (CrashLoopBackOff)?"), said)
        XCTAssertTrue(said.contains("## previous log of app") && said.contains("panic: boom"), said)
        assertClean(said)
        let fine = try await text("k8s_why", ["name": "web-1"])
        XCTAssertTrue(fine.contains("pod/web-1 isn't failing"), fine)
    }

    func testRolloutHasItsStatusAndHistory() async throws {
        let said = try await text("k8s_rollout", ["name": "web"])
        XCTAssertTrue(said.contains("Rollout of deployment/web: deployment \"web\" successfully rolled out"), said)
        XCTAssertTrue(said.contains("Replicas: 1 wanted, 1 updated, 1 ready, 1 available."), said)
        let revisions = said.components(separatedBy: "\n").filter { $0.contains("revision ") }
        XCTAssertEqual(revisions.count, 2, said)
        XCTAssertTrue(revisions.first?.contains("revision 2 web-7d9f (current): nginx:1.27") == true, said)
        XCTAssertTrue(revisions.last?.contains("revision 1 web-5c4a: nginx:1.26") == true && revisions.last?.contains("change-cause: kubectl set image") == true, said)
        assertClean(said)
        let pod = await refused("k8s_rollout", ["name": "web-1", "kind": "pods"])
        XCTAssertEqual(pod, "k8s_rollout is a Deployment's, a StatefulSet's or a DaemonSet's.")
    }

    func testTopSaysWhatPodsAndNodesUse() async throws {
        api.setPodMetrics("web-1", namespace: "shop", [("app", "250m", "64Mi")], at: Date().addingTimeInterval(-20))
        api.setPodMetrics("worker-1", namespace: "shop", [("app", "1500m", "32Mi")])
        api.setPodMetrics("api-0", namespace: "payments", [("app", "5m", "16Mi")])
        api.add("nodes", "fake-node-1", values: ["Status": "Ready"], fields: ["status": ["allocatable": ["cpu": "4", "memory": "8Gi"]]])
        api.setNodeMetrics("fake-node-1", cpu: "2", memory: "1Gi")
        let pods = try await text("k8s_top")
        let lines = pods.components(separatedBy: "\n")
        XCTAssertTrue(lines.first?.hasPrefix("Context fake-dev") == true && lines.first?.contains("namespace shop") == true, pods)
        XCTAssertEqual(lines[1], "NAME       CPU(cores)   MEMORY(bytes)", pods)
        XCTAssertTrue(lines[2].hasPrefix("worker-1") && lines[2].contains("1500m") && lines[3].hasPrefix("web-1"), "by cpu, the most first:\n\(pods)")
        XCTAssertTrue(pods.contains("Sampled by metrics-server 20s ago over 15s."), pods)
        XCTAssertFalse(pods.contains("api-0"), "the page's namespace only")
        XCTAssertTrue(pods.contains(KubeChartEmpty.topSharesNeedSpecs.sentence), "a namespace's shares need the specs:\n\(pods)")
        XCTAssertFalse(pods.contains("%CPU/R"), pods)
        let byMemory = try await text("k8s_top", ["sort_by": "memory", "limit": 1])
        XCTAssertTrue(byMemory.contains("web-1") && !byMemory.contains("worker-1 ") && byMemory.contains("… 1 more pods"), byMemory)
        let all = try await text("k8s_top", ["namespace": "all", "containers": true])
        XCTAssertTrue(all.contains("NAMESPACE") && all.contains("CONTAINER") && all.contains("payments") && all.contains("api-0"), all)
        let nodes = try await text("k8s_top", ["kind": "nodes"])
        XCTAssertTrue(nodes.contains("fake-node-1   2000m        50%      1024Mi          13%"), nodes)
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods" })
        let wrong = await refused("k8s_top", ["kind": "deployments"])
        XCTAssertTrue(wrong?.contains("pods or nodes") == true, wrong ?? "answered")
        // A named pod: its own object read once, its containers' shares.
        api.addPod(
            "sized-1", namespace: "shop",
            FakeKubeAPI.Pod(resources: ["app": ["requests": ["cpu": "500m", "memory": "64Mi"], "limits": ["cpu": "1", "memory": "128Mi"]]]))
        api.setPodMetrics("sized-1", namespace: "shop", [("app", "250m", "96Mi")])
        api.forgetRequests()
        let named = try await text("k8s_top", ["name": "sized-1"])
        XCTAssertTrue(named.contains("%CPU/R   %CPU/L   %MEM/R   %MEM/L"), named)
        XCTAssertTrue(named.contains("50%      25%      150%     75%"), named)
        XCTAssertEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods/sized-1" }.count, 1, "\(api.requests)")

        // No metrics-server: said, and nothing asked of metrics.k8s.io.
        api.metricsServer = false
        KubeMCP.forgetDiscoveries()
        api.forgetRequests()
        let absent = try await text("k8s_top", ["context": "fake-prod"])
        XCTAssertTrue(absent.contains("No metrics-server"), absent)
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/apis/metrics.k8s.io") }, "\(api.requests)")
    }

    /// `k8s_top` across a namespace where the context opts in to
    /// Prometheus, the page not showing its Pods list: kube-state-metrics
    /// asked for the call (its raw series, evaluated by the fake), once
    /// for the namespace, as an agent — the pods' shares, a two-container
    /// pod's on its own line; across every namespace none asked, said. A
    /// named pod whose object can't be read says why rather than "name a pod".
    func testTopAsksKubeStateMetricsForANamespaceWhereThePageDoesnt() async throws {
        api.addNamespace("monitoring")
        api.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        let mi = 1_048_576.0
        func ksm(_ pod: String, _ containers: [(String, cpu: Double, memory: Double)]) {
            for (container, cpu, memory) in containers {
                let labels = ["namespace": "shop", "pod": pod, "container": container]
                api.setPrometheusSeries("kube_pod_container_info", labels: labels, value: 1)
                api.setPrometheusSeries("kube_pod_container_resource_requests", labels: labels.merging(["resource": "cpu"]) { $1 }, value: cpu)
                api.setPrometheusSeries("kube_pod_container_resource_requests", labels: labels.merging(["resource": "memory"]) { $1 }, value: memory)
                api.setPrometheusSeries("kube_pod_container_resource_limits", labels: labels.merging(["resource": "cpu"]) { $1 }, value: cpu * 2)
            }
        }
        ksm("web-1", [("app", 0.5, 128 * mi)])
        ksm("worker-1", [("app", 0.25, 64 * mi), ("log", 0.05, 16 * mi)])
        api.setPodMetrics("web-1", namespace: "shop", [("app", "250m", "64Mi")])
        api.setPodMetrics("worker-1", namespace: "shop", [("app", "150m", "32Mi"), ("log", "30m", "8Mi")])
        let socket = self.socket!
        model = makeModel()
        model.load = { _ in Self.list(current: "fake-dev", devSettings: KubeContextSettings(prometheus: "monitoring/prometheus-server:80")) }
        model.prometheusOverride = { context, service in
            KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: context.name), service: service)
        }
        func ksmAsked() -> [FakeKubeAPI.Request] {
            api.requests.filter { $0.isPrometheusQuery && $0.query["query"]?.contains("kube_pod_container_info") == true }
        }

        let pods = try await text("k8s_top")
        XCTAssertTrue(pods.contains("%CPU/R   %CPU/L   %MEM/R   %MEM/L"), pods)
        XCTAssertTrue(pods.contains("web-1      250m         64Mi            50%      25%      50%      -"), pods)
        XCTAssertTrue(pods.contains("Shares from kube-state-metrics (Prometheus), read now."), pods)
        XCTAssertFalse(pods.contains(KubeChartEmpty.topSharesNeedSpecs.sentence), pods)
        XCTAssertEqual(ksmAsked().count, 1, "one query for shop: \(ksmAsked().map(\.query))")
        XCTAssertTrue(ksmAsked().allSatisfy { $0.query["query"]?.contains(#"namespace="shop""#) == true })
        XCTAssertNil(model.prometheus.shares, "nothing kept as the page's")
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/api/v1/namespaces/shop/pods/") }, "no pod object read for a namespace's shares")

        let withContainers = try await text("k8s_top", ["containers": true])
        let lines = withContainers.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("worker-1   (pod)") && $0.hasSuffix("60%      30%      50%      -") }, "the pod's line:\n\(withContainers)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("worker-1   log") && $0.hasSuffix("-        -        -        -") }, withContainers)
        XCTAssertTrue(lines.contains { $0.hasPrefix("web-1      app") && $0.hasSuffix("50%      25%      50%      -") }, "a lone container's, the pod's:\n\(withContainers)")

        api.forgetRequests()
        let across = try await text("k8s_top", ["namespace": "all"])
        XCTAssertTrue(across.contains(KubeChartEmpty.topSharesNeedNamespaces.sentence), across)
        XCTAssertFalse(across.contains("%CPU/R"), across)
        XCTAssertTrue(ksmAsked().isEmpty, "none across every namespace")

        // A named pod sampled but its object gone: why, not "name a pod".
        api.setPodMetrics("ghost-1", namespace: "shop", [("app", "10m", "8Mi")])
        let ghost = try await text("k8s_top", ["name": "ghost-1"])
        XCTAssertTrue(ghost.contains("Shares of request and limit need the pod's own object, which couldn't be read for ghost-1 ("), ghost)
        XCTAssertFalse(ghost.contains(KubeChartEmpty.topSharesNeedSpecs.sentence), ghost)
        XCTAssertFalse(ghost.contains("%CPU/R"), ghost)
    }

    // MARK: Failures

    /// Through the real proxies (a stand-in kubectl that serves the fake's
    /// socket): the sign-in fails, the answer says so scrubbed, and the
    /// context stops — the next call asks nothing and starts no proxy, and
    /// k8s_contexts says why.
    func testAContextWhoseCredentialsFailIsStoppedAndAsksNothingMore() async throws {
        final class Opened: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int { lock.withLock { value } }
            func add() { lock.withLock { value += 1 } }
        }
        let opened = Opened()
        let socket = self.socket!
        let proxies = KubeProxies(
            plan: { context, _, _ in
                KubeProxySpec(
                    context: context.name, readOnly: !context.isWritable, kubectl: URL(fileURLWithPath: "/nonexistent/kubectl"), socket: socket,
                    environment: [:], cacheDirectory: nil, signIn: .none)
            },
            open: { spec in
                opened.add()
                return KubeProxy(
                    context: spec.context, readOnly: spec.readOnly, signIn: .none, transport: UnixHTTPTransport.kubernetes(socket: spec.socket, context: spec.context),
                    isRunning: { true }, close: {})
            })
        defer { proxies.closeAll() }
        model = makeModel(proxies: proxies, direct: false)
        await pageSelected()
        let settings = try settings()
        func call(_ name: String) async -> (text: String, isError: Bool) {
            let answer = await BrowserMCP.handle(
                ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": ["kind": "pods"]]], browser: { nil },
                settings: settings, kubernetes: model)
            if let error = answer?["error"] as? [String: Any] { return (error["message"] as? String ?? "", true) }
            let result = answer?["result"] as? [String: Any]
            return (((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result?["isError"] as? Bool == true)
        }

        api.failCredentials("getting credentials: exec: executable fake-plugin failed: token: \(Self.token)")
        let failed = await call("k8s_get")
        XCTAssertTrue(failed.isError, failed.text)
        XCTAssertTrue(failed.text.hasPrefix("kubectl couldn't get credentials: getting credentials: exec: executable fake-plugin failed"), failed.text)
        assertClean(failed.text)
        XCTAssertFalse(api.requests.isEmpty, "it was asked once")
        XCTAssertEqual(opened.count, 1)
        guard case .stopped = await proxies.status(of: "fake-dev") else { return XCTFail("a credential failure stops the context") }

        api.failCredentials(nil)
        api.forgetRequests()
        let again = await call("k8s_get")
        XCTAssertTrue(again.isError && again.text.hasPrefix("kubectl couldn't get credentials"), again.text)
        assertClean(again.text)
        XCTAssertEqual(api.requests, [], "a stopped context asks nothing")
        XCTAssertEqual(opened.count, 1, "and starts no proxy")
        let contexts = try await text("k8s_contexts")
        XCTAssertTrue(contexts.contains("* fake-dev — remote, read-only for Overterm; namespace shop; kubectl's current context; not answering now: kubectl couldn't get credentials"), contexts)
        assertClean(contexts)
        XCTAssertEqual(api.requests, [])
    }

    func testWithNothingSelectedAnUnnamedCallIsRefusedNeverProduction() async throws {
        pageSelects = false
        model = makeModel(current: "fake-prod")
        XCTAssertNil(model.selectedName)
        for (tool, arguments) in [("k8s_get", ["kind": "pods"]), ("k8s_logs", ["pod": "api-0"]), ("k8s_why", ["name": "api-0"])] as [(String, [String: Any])] {
            let said = await refused(tool, arguments)
            XCTAssertEqual(said, "Name a “context”: fake-dev, fake-prod.", tool)
        }
        let contexts = try await text("k8s_contexts")
        XCTAssertTrue(contexts.contains("None is selected on the Kubernetes page"), contexts)
        XCTAssertFalse(contexts.contains("* "), "no default: \(contexts)")
        XCTAssertTrue(contexts.contains("  fake-prod — PRODUCTION, read-only for Overterm; namespace payments; kubectl's current context"), contexts)
        XCTAssertEqual(api.requests, [], "nothing asked of production, nor any cluster")
        let named = try await text("k8s_get", ["kind": "pods", "context": "fake-prod"])
        XCTAssertTrue(named.hasPrefix("PRODUCTION context fake-prod"), "named, it reads: \(named)")
    }

    /// The kubeconfig changed while the page was hidden: fake-dev now names
    /// another cluster, and the page's discovery of the old one isn't used.
    func testThePagesDiscoveryIsUsedOnlyForTheSameCluster() async throws {
        model.show()
        try await until(5, "the page's discovery") { self.model.selectedName == "fake-dev" && self.model.discovery != nil }
        model.hide()
        try await until(5, "watches closed") { self.api.openWatches == 0 }
        try await Task.sleep(for: .milliseconds(100))
        api.forgetRequests()
        _ = try await text("k8s_get", ["kind": "pods"])
        XCTAssertFalse(api.requests.contains { $0.path == "/api" || $0.path == "/apis" }, "the same cluster: the page's discovery: \(api.requests)")

        model.load = { _ in Self.list(current: "fake-dev", cluster: "fake-other") }
        api.forgetRequests()
        _ = try await text("k8s_get", ["kind": "pods"])
        XCTAssertTrue(api.requests.contains { $0.path == "/api" } && api.requests.contains { $0.path == "/apis" }, "another cluster: read afresh: \(api.requests)")
        api.forgetRequests()
        _ = try await text("k8s_why", ["name": "worker-1"])
        XCTAssertTrue(api.requests.allSatisfy { $0.path != "/api" && $0.path != "/apis" }, "then the tools' own, for that cluster: \(api.requests)")
    }

    func testKubernetesOffAnswersSo() async throws {
        model.readConfiguration = {
            var configuration = KubernetesModel.Configuration()
            configuration.enabled = false
            return configuration
        }
        let result = try await KubeMCP.call("k8s_get", ["kind": "pods"], kubernetes: model)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(api.requests.isEmpty)
    }

    // MARK: The setting

    private func settings() throws -> Settings {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otkm-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Settings(url: dir.appendingPathComponent("settings.json"), watch: false)
    }

    func testTheSettingTurnsTheGroupOnAndOff() async throws {
        await pageSelected()
        let settings = try settings()
        XCTAssertTrue(settings.kubernetesAgentAccess, "on by default: reads")
        func listed() async -> [String] {
            let answer = await BrowserMCP.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], browser: { nil }, settings: settings, kubernetes: model)
            return ((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }
        func call() async -> [String: Any]? {
            let answer = await BrowserMCP.handle(
                ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "k8s_get", "arguments": ["kind": "pods"]]], browser: { nil },
                settings: settings, kubernetes: model)
            return answer?["result"] as? [String: Any]
        }
        let on = await listed()
        XCTAssertEqual(on.filter { $0.hasPrefix("k8s_") }, KubeMCP.reads)
        XCTAssertTrue(BrowserMCP.instructions(in: settings).contains("k8s_get"))
        let answered = await call()
        XCTAssertNil(answered?["isError"])
        XCTAssertTrue(((answered?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("worker-1") == true)

        settings.set("kubernetes.agentAccess", .bool(false))
        XCTAssertFalse(settings.kubernetesAgentAccess)
        let off = await listed()
        XCTAssertFalse(off.contains { $0.hasPrefix("k8s_") }, "\(off)")
        XCTAssertFalse(BrowserMCP.instructions(in: settings).contains("k8s_"))
        api.forgetRequests()
        let refused = await call()
        XCTAssertEqual(refused?["isError"] as? Bool, true)
        XCTAssertTrue(((refused?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("Settings ▸ Kubernetes") == true)
        XCTAssertTrue(api.requests.isEmpty, "nothing asked with the group off")

        settings.set("kubernetes.agentAccess", nil)
        settings.set("kubernetes.enabled", .bool(false))
        XCTAssertFalse(settings.kubernetesAgentAccess, "Kubernetes off takes the tools too")
    }
}

/// The tools' words, pure.
final class KubeMCPTextTests: XCTestCase {
    /// A number past Int's range, as an agent's JSON arrives through
    /// JSONSerialization: clamped to the tool's range, never a trap
    /// (`Int(1e300)` took the whole app down).
    func testAHugeNumberIsClampedNeverATrap() throws {
        let json = #"{"limit": 1e300, "tail": -1e300, "most": 1.7976931348623157e308, "half": 2.9}"#
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let call = KubeMCP.Call(name: "k8s_events", arguments: arguments)
        XCTAssertEqual(call.int("limit", default: 50, in: 1...500), 500)
        XCTAssertEqual(call.int("tail", default: 200, in: 1...5000), 1)
        XCTAssertEqual(call.int("most", default: 50, in: 1...500), 500)
        XCTAssertEqual(call.int("half", default: 50, in: 1...500), 2)
        XCTAssertNil(KubeMCP.Call.clamped(.nan, to: 1...5))
        XCTAssertNil(KubeMCP.Call.clamped(.infinity, to: 1...5))
    }

    func testDurationsAndNames() {
        XCTAssertEqual(KubeMCPText.seconds("30s"), 30)
        XCTAssertEqual(KubeMCPText.seconds("10m"), 600)
        XCTAssertEqual(KubeMCPText.seconds("2h"), 7200)
        XCTAssertEqual(KubeMCPText.seconds("1d"), 86400)
        XCTAssertEqual(KubeMCPText.seconds("90"), 90)
        XCTAssertNil(KubeMCPText.seconds("soon"))
        XCTAssertNil(KubeMCPText.seconds("-5m"))
        XCTAssertNil(KubeMCPText.seconds("0"))
        XCTAssertEqual(KubeMCPText.rfc3339(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertTrue(KubeMCPText.isName("web-7d9f.v2"))
        XCTAssertTrue(KubeMCPText.isName("system:controller"))
        for bad in ["", ".", "..", "a/b", "../secrets", "a\nb"] { XCTAssertFalse(KubeMCPText.isName(bad), bad) }
    }

    func testATableAsKubectlPrintsIt() {
        let columns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Status"), KubeColumn(name: "IP", priority: 1)]
        let rows = [
            KubeRow(id: KubeRowID(namespace: "shop", name: "web-1"), cells: [.text("web-1"), .text("Running"), .text("10.0.0.1")]),
            KubeRow(id: KubeRowID(namespace: "payments", name: "api-0"), cells: [.text("api-0"), .text("Pending"), .text("")]),
        ]
        let table = KubeTable(columns: columns, rows: rows, continueToken: "t", remainingItemCount: 3)
        let text = KubeMCPText.table(table, kind: .pods, allNamespaces: true, wide: false, filter: nil)
        XCTAssertEqual(
            text,
            """
            NAMESPACE   NAME    STATUS
            shop        web-1   Running
            payments    api-0   Pending
            … 3 more not listed: narrow it (label_selector, field_selector, a namespace) or raise limit.
            """)
        XCTAssertTrue(KubeMCPText.table(table, kind: .pods, allNamespaces: false, wide: true, filter: nil).contains("IP"))
        XCTAssertEqual(KubeMCPText.table(table, kind: .pods, allNamespaces: false, wide: false, filter: "nothing"), "No pods with “nothing”.")
        XCTAssertEqual(KubeMCPText.cut(String(repeating: "x", count: 300)).count, KubeMCPText.maxCell + 1)
    }

    func testEveryAnswerIsBoundedAndScrubbed() {
        let long = String(repeating: "a", count: KubeMCPText.maxCharacters + 10)
        XCTAssertTrue(KubeMCPText.bounded(long).hasSuffix("… (10 more characters left out)"))
        XCTAssertTrue(KubeMCPText.bounded(long, keepEnd: true).hasPrefix("… (the first 10 characters left out)"))
        let scrubbed = KubeMCPText.finished(
            "token: abcDEF.fake-bearer\nclient-key-data: QWxhZGRpbjpvcGVuIHNlc2FtZTEyMzQ1Njc4OTBhYmNkZWZn\nAuthorization: Bearer abc.def.ghi\npostgres://u:pw-fake@db/x")
        for needle in ["abcDEF.fake-bearer", "QWxhZGRpbjpvcGVuIHNlc2FtZTEyMzQ1Njc4OTBhYmNkZWZn", "abc.def.ghi", "pw-fake"] {
            XCTAssertFalse(scrubbed.contains(needle), "\(needle): \(scrubbed)")
        }
    }

    func testContextsLines() {
        let text = KubeMCPText.contexts([
            .init(
                name: "acme-prod", displayName: nil, contextClass: .production, writable: false, namespace: "default", isDefault: true, isCurrent: true,
                problem: "Signing in failed"),
            .init(name: "kind-fake", displayName: "Kind", contextClass: .local, writable: true, namespace: "all namespaces", isDefault: false, isCurrent: false),
        ])
        XCTAssertTrue(
            text.contains("* acme-prod — PRODUCTION, read-only for Overterm; namespace default; kubectl's current context; not answering now: Signing in failed"),
            text)
        XCTAssertTrue(text.contains("  kind-fake (“Kind”) — local, writable for Overterm (not for agents); namespace all namespaces"), text)
        let many = (0..<5000).map {
            KubeMCPText.ContextRow(
                name: "acme-\($0)", displayName: nil, contextClass: .remote, writable: false, namespace: "default", isDefault: false, isCurrent: false,
                problem: String(repeating: "x", count: 100))
        }
        XCTAssertLessThanOrEqual(KubeMCPText.contexts(many).count, KubeMCPText.maxCharacters + 100, "bounded")
    }

    /// `filter` looks at the cells once scrubbed: a token in a cell (a
    /// CRD's printer column) can't be found by guessing at it.
    func testAFilterLooksAtScrubbedCells() {
        let columns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Endpoint")]
        let rows = [
            KubeRow(id: KubeRowID(namespace: "shop", name: "hook"), cells: [.text("hook"), .text("Authorization: Bearer fake-token-value-123")])
        ]
        let table = KubeTable(columns: columns, rows: rows)
        for guess in ["fake-token", "value-123", "fake-token-value-123"] {
            XCTAssertEqual(KubeMCPText.table(table, kind: .pods, allNamespaces: false, wide: false, filter: guess), "No pods with “\(guess)”.", guess)
        }
        let shown = KubeMCPText.table(table, kind: .pods, allNamespaces: true, wide: false, filter: "hook")
        XCTAssertTrue(shown.contains("hook") && !shown.contains("fake-token-value-123"), shown)
    }

}

// MARK: A bound checkout (3.1, 3.2)

extension KubeMCPTests {

    /// A git checkout of the test's own, one commit; its sha.
    private func boundRepo() async throws -> (URL, String) {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("kube-mcp-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: [String]) async throws -> String {
            try await Git.run(["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + arguments, in: repo)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        try "worker".write(to: repo.appendingPathComponent("worker.go"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "worker.go"])
        _ = try await git(["commit", "-q", "-m", "worker"])
        return (repo, try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testTheCallingPanesBoundCheckoutIsTheDefault() async throws {
        let (repo, sha) = try await boundRepo()
        let store = KubeBindingStore(file: repo.deletingLastPathComponent().appendingPathComponent("bindings-\(UUID().uuidString).json"))
        let (kept, keptPane) = (KubeMCP.bindings, KubeMCP.paneCheckout)
        KubeMCP.bindings = store
        KubeMCP.paneCheckout = { $0 == "pane-bound" ? repo : nil }
        defer {
            KubeMCP.bindings = kept
            KubeMCP.paneCheckout = keptPane
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: store.file)
        }
        func said(_ name: String, _ arguments: [String: Any] = [:], pane: String?) async throws -> String {
            let result = try await KubeMCP.call(name, arguments, kubernetes: model, pane: pane)
            XCTAssertNil(result["isError"], "\(name): \(result)")
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        await pageSelected()
        XCTAssertEqual(model.selectedName, "fake-dev")
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-prod", namespace: "payments")))

        // The bound pane's call goes to its binding, the page's selection aside.
        let bound = try await said("k8s_get", ["kind": "pods"], pane: "pane-bound")
        XCTAssertTrue(bound.hasPrefix("PRODUCTION context fake-prod") && bound.contains("namespace payments"), bound)
        XCTAssertTrue(bound.contains("api-0") && !bound.contains("worker-1"), bound)
        // Another pane, unbound: the page's.
        let other = try await said("k8s_get", ["kind": "pods"], pane: "pane-other")
        XCTAssertTrue(other.contains("fake-dev") && other.contains("worker-1"), other)
        // Named, the call's own.
        let named = try await said("k8s_get", ["kind": "pods", "context": "fake-dev"], pane: "pane-bound")
        XCTAssertTrue(named.contains("worker-1"), named)
        let contexts = try await said("k8s_contexts", pane: "pane-bound")
        XCTAssertTrue(contexts.contains("* fake-prod"), contexts)
        XCTAssertTrue(contexts.components(separatedBy: "\n").contains { $0.contains("fake-prod") && $0.contains("payments") }, contexts)

        // A binding to a context the kubeconfig hasn't: the page's again.
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "gone", namespace: "shop")))
        let gone = try await said("k8s_get", ["kind": "pods"], pane: "pane-bound")
        XCTAssertTrue(gone.contains("fake-dev"), gone)

        // Bound to fake-dev/shop, its failing pod's image tagged with the
        // checkout's commit: the brief says what is deployed.
        XCTAssertTrue(store.set(KubeBinding(checkout: repo.path, context: "fake-dev", namespace: "shop")))
        api.updatePod("worker-1", namespace: "shop") { $0.image = "ghcr.io/acme/worker:\(sha.prefix(7))" }
        let why = try await said("k8s_why", ["name": "worker-1"], pane: "pane-bound")
        XCTAssertTrue(why.contains("## deployed commit"), why)
        XCTAssertTrue(why.contains("deployed \(sha.prefix(7)), up to date with main") && why.contains("(from the image's tag)"), why)
        assertClean(why)
        // Unbound, none.
        store.remove(repo)
        let unbound = try await said("k8s_why", ["name": "worker-1"], pane: "pane-bound")
        XCTAssertFalse(unbound.contains("## deployed commit"), unbound)
    }
}
