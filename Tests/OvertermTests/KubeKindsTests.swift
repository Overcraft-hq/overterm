import Foundation
import XCTest

@testable import Overterm

/// Every kind as a list: discovery read into kinds (groups, preferred
/// versions, short names), the page's sections, the names the `:` bar
/// takes and what it completes to, any kind followed as the server's
/// Table — a CRD's printer columns too — and what the cluster serves read
/// again when a CRD comes or goes: by the CRD watch, by a timer where CRDs
/// can't be listed, by a 404. Against `FakeKubeAPI` on a socket of the
/// test's own; nothing here reads ~/.kube — this Mac's current context is
/// production.
@MainActor
final class KubeKindsTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkk-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addNamespace("payments")
        api.addPod("web-1", namespace: "shop")
        api.add("deployments.apps", "web", namespace: "shop", values: ["Ready": "2/2", "Up-to-date": 2, "Available": 2, "Images": "nginx:1.27"])
        api.add("deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0])
        api.add("deployments.apps", "api", namespace: "payments", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1])
        api.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "control-plane", "Version": "v1.34.1"])
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no subresource")
            api.stop()
        }
    }

    private static func context(_ name: String, namespace: String? = nil) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: namespace, user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings())
    }

    private func model(_ contexts: [KubeContext] = [context("fake-dev", namespace: "shop"), context("fake-prod", namespace: "payments")]) -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: contexts, current: contexts.first?.name)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.rediscoveryDelay = .milliseconds(20)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return model
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func discover() async throws -> KubeDiscovery {
        try await KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")).discover()
    }

    private static let widgetColumns = [
        FakeKubeAPI.Column(name: "Color", description: "What colour it is"), FakeKubeAPI.Column(name: "Size", type: "integer"),
        FakeKubeAPI.Column(name: "Ready"), FakeKubeAPI.Column(name: "Owner", priority: 1),
    ]

    private func addWidgets() {
        api.addCRD(group: "example.com", version: "v1", plural: "widgets", kind: "Widget", shortNames: ["wd"], columns: Self.widgetColumns)
        api.add("widgets.example.com", "blue-1", namespace: "shop", values: ["Color": "blue", "Size": 3, "Ready": "True", "Owner": "team-a"])
        api.add("widgets.example.com", "red-1", namespace: "shop", values: ["Color": "red", "Size": 5, "Ready": "False", "Owner": "team-b"])
    }

    // MARK: Discovery

    /// Each group's preferred version — the first that isn't Stale in the
    /// aggregated list, `preferredVersion` in the legacy group list — with
    /// its kinds' short names, scope and verbs.
    func testDiscoveryReadsGroupsTheirPreferredVersionsAndShortNames() throws {
        let aggregated = json([
            "kind": "APIGroupDiscoveryList", "apiVersion": "apidiscovery.k8s.io/v2",
            "items": [
                [
                    "metadata": ["name": "autoscaling"],
                    "versions": [
                        [
                            "version": "v2", "freshness": "Current",
                            "resources": [
                                [
                                    "resource": "horizontalpodautoscalers", "responseKind": ["group": "autoscaling", "version": "v2", "kind": "HorizontalPodAutoscaler"],
                                    "scope": "Namespaced", "singularResource": "horizontalpodautoscaler", "verbs": ["get", "list", "watch"], "shortNames": ["hpa"],
                                    "categories": ["all"], "subresources": [["subresource": "status", "verbs": ["get"]]],
                                ]
                            ],
                        ],
                        ["version": "v1", "freshness": "Current", "resources": [["resource": "horizontalpodautoscalers", "verbs": ["list"]]]],
                    ],
                ],
                [
                    "metadata": ["name": "acme.example.com"],
                    "versions": [
                        ["version": "v2", "freshness": "Stale", "resources": [Any]()],
                        [
                            "version": "v1beta1",
                            "resources": [
                                [
                                    "resource": "gadgets", "responseKind": ["kind": "Gadget"], "scope": "Cluster", "singularResource": "",
                                    "verbs": ["get", "list", "watch"], "shortNames": ["gd", "gdg"],
                                ]
                            ],
                        ],
                    ],
                ],
            ],
        ])
        guard case .aggregated(let kinds, let stale) = try KubeDiscovery.answer(aggregated) else { return XCTFail("aggregated") }
        XCTAssertEqual(kinds.map(\.groupVersion), ["autoscaling/v2", "acme.example.com/v1beta1"], "the first version listed is the preferred one")
        XCTAssertEqual(stale, ["acme.example.com/v2": KubeDiscovery.staleMessage], "a Stale version is passed over for the next")
        XCTAssertEqual(kinds[0].shortNames, ["hpa"])
        XCTAssertEqual(kinds[0].categories, ["all"])
        XCTAssertEqual(kinds[0].subresources, ["status"])
        XCTAssertEqual(kinds[1].singular, "gadget", "an empty singular is the Kind's")
        XCTAssertFalse(kinds[1].namespaced)
        let discovery = KubeDiscovery(kinds: kinds, aggregated: true)
        XCTAssertEqual(discovery.kind("hpa")?.fullName, "horizontalpodautoscalers.autoscaling")
        XCTAssertEqual(discovery.kind("gdg")?.fullName, "gadgets.acme.example.com")
        XCTAssertEqual(discovery.kind("gadgets.acme.example.com")?.version, "v1beta1")
        XCTAssertEqual(discovery.kind("Gadget")?.resource, "gadgets")

        let groups = json([
            "kind": "APIGroupList",
            "groups": [
                [
                    "name": "acme.example.com", "versions": [["groupVersion": "acme.example.com/v2"], ["groupVersion": "acme.example.com/v1"]],
                    "preferredVersion": ["groupVersion": "acme.example.com/v1", "version": "v1"],
                ],
                ["name": "apps", "versions": [["groupVersion": "apps/v1"]]],
            ],
        ])
        XCTAssertEqual(try KubeDiscovery.answer(groups), .groups(["acme.example.com/v1", "apps/v1"]), "the preferred version, else the first")
    }

    /// The fake's discovery, both ways: its groups, a CRD's kind once added
    /// (with its short names), gone once removed.
    func testDiscoveryFindsACRDsKindAddedAndRemoved() async throws {
        var discovery = try await discover()
        XCTAssertNil(discovery.kind("widgets"))
        XCTAssertEqual(discovery.kind("crd")?.fullName, KubernetesModel.crdName)
        XCTAssertEqual(discovery.kind("ing")?.fullName, "ingresses.networking.k8s.io")
        addWidgets()
        for aggregated in [true, false] {
            api.aggregatedDiscovery = aggregated
            discovery = try await discover()
            XCTAssertEqual(discovery.aggregated, aggregated)
            let widgets = try XCTUnwrap(discovery.kind("wd"), "aggregated: \(aggregated)")
            XCTAssertEqual(widgets.fullName, "widgets.example.com")
            XCTAssertEqual(widgets.groupVersion, "example.com/v1")
            XCTAssertTrue(widgets.namespaced)
            XCTAssertEqual(discovery.kind("widget"), widgets)
            XCTAssertEqual(discovery.kind("Widget"), widgets)
        }
        api.removeCRD("widgets.example.com")
        discovery = try await discover()
        XCTAssertNil(discovery.kind("widgets"))
        XCTAssertEqual(api.names(KubernetesModel.crdName), [])
    }

    // MARK: Sections

    func testTheSectionsOfferWhatCanBeListedAndWatched() async throws {
        addWidgets()
        let catalog = KubeKindCatalog(try await discover())
        XCTAssertEqual(
            catalog.kinds(in: .workloads).map(\.fullName),
            [
                "pods", "deployments.apps", "statefulsets.apps", "daemonsets.apps", "replicasets.apps", "jobs.batch", "cronjobs.batch",
                "horizontalpodautoscalers.autoscaling",
            ])
        XCTAssertEqual(catalog.kinds(in: .network).map(\.fullName), ["services", "endpointslices.discovery.k8s.io", "ingresses.networking.k8s.io"])
        XCTAssertEqual(catalog.kinds(in: .config).map(\.fullName), ["configmaps", "secrets", "poddisruptionbudgets.policy"])
        XCTAssertEqual(catalog.kinds(in: .storage).map(\.fullName), ["persistentvolumeclaims"])
        XCTAssertEqual(catalog.kinds(in: .overview), [], "the Overview lists no kind")
        XCTAssertEqual(
            catalog.kinds(in: .cluster).map(\.fullName),
            ["nodes", "namespaces", "events.events.k8s.io", "serviceaccounts", "roles.rbac.authorization.k8s.io", KubernetesModel.crdName, "controllerrevisions.apps"],
            "events.k8s.io's events, not the core's as well; RBAC's with them")
        XCTAssertEqual(catalog.kinds(in: .custom).map(\.fullName), ["widgets.example.com"])
        let all = catalog.all.map(\.fullName)
        for left in ["componentstatuses", "bindings", "pods.metrics.k8s.io", "nodes.metrics.k8s.io", "events"] {
            XCTAssertFalse(all.contains(left), "\(left): not a list kept live")
        }
        XCTAssertEqual(catalog.section(of: try XCTUnwrap(catalog.kind(fullName: "widgets.example.com"))), .custom)
        XCTAssertNil(catalog.section(of: KubeResourceKind(group: "", version: "v1", resource: "bindings", kind: "Binding", singular: "binding", namespaced: true, verbs: ["create"])))

        // Kubernetes' own groups, and the rest.
        for group in ["", "apps", "batch", "policy", "networking.k8s.io", "gateway.networking.k8s.io", "metrics.k8s.io"] {
            XCTAssertTrue(KubeKindCatalog.isBuiltIn(group: group), group)
        }
        for group in ["example.com", "cert-manager.io", "argoproj.io", "karpenter.sh", "k8s.io.example.com"] {
            XCTAssertFalse(KubeKindCatalog.isBuiltIn(group: group), group)
        }
        XCTAssertEqual(KubeSection.allCases.map(\.key), ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "Overview is 1, Helm 8, Forwards 9")
        XCTAssertEqual(KubeSection.allCases, [.overview, .workloads, .network, .config, .storage, .cluster, .custom, .helm, .forwards], "Section 6's order")
    }

    func testAKindsTitle() {
        func title(_ kind: String, _ resource: String, group: String = "") -> String {
            KubeKindCatalog.title(of: KubeResourceKind(group: group, version: "v1", resource: resource, kind: kind, singular: "", namespaced: true, verbs: []))
        }
        XCTAssertEqual(title("Deployment", "deployments", group: "apps"), "Deployments")
        XCTAssertEqual(title("Ingress", "ingresses", group: "networking.k8s.io"), "Ingresses")
        XCTAssertEqual(title("NetworkPolicy", "networkpolicies", group: "networking.k8s.io"), "NetworkPolicies")
        XCTAssertEqual(title("Gateway", "gateways", group: "gateway.networking.k8s.io"), "Gateways")
        XCTAssertEqual(title("Endpoints", "endpoints"), "Endpoints", "already plural")
        XCTAssertEqual(title("StorageClass", "storageclasses", group: "storage.k8s.io"), "StorageClasses")
        XCTAssertEqual(title("HorizontalPodAutoscaler", "horizontalpodautoscalers", group: "autoscaling"), "HPAs")
        XCTAssertEqual(title("PersistentVolumeClaim", "persistentvolumeclaims"), "PVCs")
    }

    // MARK: Names and the `:` bar

    func testAKindByAnyNameKubectlOrK9sGivesIt() async throws {
        addWidgets()
        let discovery = try await discover()
        let cases: [(String, String?)] = [
            ("deploy", "deployments.apps"), ("dp", "deployments.apps"), ("deployment", "deployments.apps"), ("Deployment", "deployments.apps"),
            ("deployments.apps", "deployments.apps"), ("po", "pods"), ("pods", "pods"), ("svc", "services"), ("sec", "secrets"), ("cm", "configmaps"),
            ("ns", "namespaces"), ("no", "nodes"), ("crd", KubernetesModel.crdName), ("crds", KubernetesModel.crdName), ("jo", "jobs.batch"),
            ("ro", "roles.rbac.authorization.k8s.io"), ("widgets", "widgets.example.com"), ("widget", "widgets.example.com"),
            ("wd", "widgets.example.com"), ("widgets.example.com", "widgets.example.com"), ("  PO ", "pods"), ("nope", nil), ("", nil),
            ("cr", nil),  // k9s's clusterroles: not served here
            ("ev", "events.events.k8s.io"), ("events", "events.events.k8s.io"), ("event", "events.events.k8s.io"),
        ]
        let catalog = KubeKindCatalog(discovery)
        for (name, full) in cases {
            let kind = KubeKinds.resolve(name, in: discovery, catalog: catalog)
            XCTAssertEqual(kind?.fullName, full, name)
            if let kind { XCTAssertNotNil(catalog.section(of: kind), "\(name): the kind the page offers") }
        }
        XCTAssertEqual(KubeKinds.resolve("ev", in: discovery)?.fullName, "events", "kubectl's, without the page's catalog")
        XCTAssertEqual(KubeKinds.resolve("events.events.k8s.io", in: discovery, catalog: catalog)?.fullName, "events.events.k8s.io")
        let widgets = try XCTUnwrap(discovery.kind("widgets"))
        XCTAssertEqual(KubeKinds.names(of: widgets), ["widgets", "widget", "wd", "widgets.example.com"])
        let deployments = try XCTUnwrap(discovery.kind("deploy"))
        XCTAssertEqual(KubeKinds.names(of: deployments), ["deployments", "deployment", "deploy", "deployments.apps", "dp"])
    }

    func testTheCommandGrammar() {
        XCTAssertEqual(KubeCommand.parse(":deploy"), KubeCommand(target: "deploy"))
        XCTAssertEqual(KubeCommand.parse("po"), KubeCommand(target: "po"))
        XCTAssertEqual(
            KubeCommand.parse(":po globex /api app=web @globex-eu-west-1-dev"),
            KubeCommand(target: "po", namespace: "globex", labels: "app=web", context: "globex-eu-west-1-dev", filter: "api"), "the design's example")
        XCTAssertEqual(
            KubeCommand.parse(":po shop /api web app=web,tier=fe @fake-dev"),
            KubeCommand(target: "po", namespace: "shop", labels: "app=web,tier=fe", context: "fake-dev", filter: "api web"),
            "the filter ends at a label or a context")
        XCTAssertEqual(
            KubeCommand.parse(":po /web status:running label:app=web @fake-dev"),
            KubeCommand(target: "po", context: "fake-dev", filter: "web status:running label:app=web"), "the filter's own words have a colon")
        XCTAssertEqual(KubeCommand.parse(":po / api"), KubeCommand(target: "po", filter: "api"))
        XCTAssertEqual(KubeCommand.parse(":po /"), KubeCommand(target: "po"))
        XCTAssertNil(KubeCommand.parse(":po @fake-dev @fake-prod"), "two contexts")
        XCTAssertNil(KubeCommand.parse(":/api"))
        XCTAssertEqual(
            KubeCommand.parse(":PO shop app=web @fake-dev /api"),
            KubeCommand(target: "po", namespace: "shop", labels: "app=web", context: "fake-dev", filter: "api"))
        XCTAssertEqual(KubeCommand.parse(":svc -A"), KubeCommand(target: "svc", allNamespaces: true))
        XCTAssertEqual(KubeCommand.parse(":svc all a=1 b=2"), KubeCommand(target: "svc", allNamespaces: true, labels: "a=1,b=2"))
        XCTAssertNil(KubeCommand.parse(":po shop payments"), "two namespaces")
        XCTAssertNil(KubeCommand.parse(""))
        XCTAssertNil(KubeCommand.parse(":"))
        XCTAssertNil(KubeCommand.parse(":app=web"))
        XCTAssertNil(KubeCommand.parse(":po @"))
        XCTAssertEqual(KubeCommand.parse(":ctx")?.action, .context(nil))
        XCTAssertEqual(KubeCommand.parse(":ctx fake-prod")?.action, .context("fake-prod"))
        XCTAssertEqual(KubeCommand.parse(":ns")?.action, .namespace(nil))
        XCTAssertEqual(KubeCommand.parse(":ns shop")?.action, .namespace("shop"))
        XCTAssertEqual(KubeCommand.parse(":ns -A")?.action, .namespace("*"))
        XCTAssertEqual(KubeCommand.parse(":namespaces")?.action, .kind("namespaces"), "the Namespaces list itself")
    }

    func testTheBarCompletesKindsThenNamespacesAndContexts() async throws {
        addWidgets()
        let catalog = KubeKindCatalog(try await discover())
        var bar = KubeCommandBar(kinds: catalog.all, namespaces: ["payments", "shop"], contexts: ["fake-dev", "fake-prod"])
        XCTAssertEqual(bar.results.prefix(2).map(\.text), ["ctx", "ns"], "empty: everything, the switches first")
        bar.text = "dep"
        XCTAssertEqual(bar.results.first?.text, "deployments")
        XCTAssertEqual(bar.results.first?.detail, "Deployments · deploy · apps/v1")
        bar.text = "po"
        XCTAssertEqual(bar.results.first?.text, "pods", "a short name, exactly")
        bar.text = "wid"
        XCTAssertEqual(bar.results.map(\.text), ["widgets"])
        bar.complete()
        XCTAssertEqual(bar.text, "widgets", "Tab")
        bar.text = "widgets s"
        XCTAssertEqual(bar.results.map(\.text), ["shop", "payments"], "then a namespace: those it starts, then those it is in")
        bar.text = "widgets shop @prod"
        XCTAssertEqual(bar.results.map(\.text), ["@fake-prod"], "a context after @")
        bar.text = "widgets shop /blue @prod"
        XCTAssertEqual(bar.results.map(\.text), ["@fake-prod"], "after the filter too")
        bar.complete()
        XCTAssertEqual(bar.text, "widgets shop /blue @fake-prod")
        bar.text = "widgets shop /bl"
        XCTAssertEqual(bar.results, [], "the filter is typed")
        bar.text = "c"
        XCTAssertEqual(bar.results.first?.text, "ctx")
        bar.move(1)
        XCTAssertEqual(bar.index, 1)
        bar.text = "zzz"
        XCTAssertEqual(bar.results, [])

        // ↩ completes a word that isn't whole, then reads the line.
        bar.text = "deplo"
        XCTAssertEqual(bar.command(), KubeCommand(target: "deployments"))
        bar.text = "po pay"
        XCTAssertEqual(bar.command(), KubeCommand(target: "po", namespace: "payments"))
        bar.text = "ns"
        XCTAssertEqual(bar.command(), KubeCommand(target: "ns"), "a whole name stays")
        bar.text = "po staging-2"
        XCTAssertEqual(bar.command(), KubeCommand(target: "po", namespace: "staging-2"), "a namespace nobody listed, as typed")
    }

    /// Two kinds with one plural (two CRDs' `certificates`): each completes
    /// to its full name, so either can be picked.
    func testAPluralTwoKindsShareCompletesToTheirFullNames() {
        func kind(_ group: String, _ resource: String, _ kind: String) -> KubeResourceKind {
            KubeResourceKind(group: group, version: "v1", resource: resource, kind: kind, singular: kind.lowercased(), namespaced: true, verbs: ["list", "watch"])
        }
        let kinds = [
            kind("cert-manager.io", "certificates", "Certificate"), kind("networking.internal.knative.dev", "certificates", "Certificate"),
            kind("acme.example.com", "challenges", "Challenge"),
        ]
        var bar = KubeCommandBar(kinds: kinds, namespaces: [], contexts: [])
        bar.text = "cert"
        XCTAssertEqual(bar.results.map(\.text), ["certificates.cert-manager.io", "certificates.networking.internal.knative.dev"])
        bar.move(1)
        bar.complete()
        XCTAssertEqual(bar.text, "certificates.networking.internal.knative.dev")
        bar.text = "chal"
        XCTAssertEqual(bar.results.map(\.text), ["challenges"], "a plural of its own stays short")
    }

    func testTheKeysTakeTheDigitsAndTheColon() {
        XCTAssertTrue(KubernetesKey.isWellFormed)
        XCTAssertEqual(KubernetesKey.of(":"), .command)
        XCTAssertEqual(KubeSection.allCases.map { KubernetesKey.of($0.key)?.section }, KubeSection.allCases)
        XCTAssertEqual(KubernetesKey.of("8"), .helm, "8 is Helm's")
        XCTAssertEqual(KubernetesKey.of("1"), .overview, "1 is the Overview's")
    }

    // MARK: Any kind, followed

    func testAnyKindIsTheServersTableWatched() async throws {
        // Storage served nothing: the section that says so, below.
        api.unserve("persistentvolumeclaims")
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { !model.catalog.isEmpty && model.rows.count == 1 }

        // Deployments: the server's columns, rows only, watched.
        XCTAssertTrue(page.press("2"))
        XCTAssertEqual(model.kind.fullName, "pods", "Workloads' first")
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps")))
        try await until(5, "deployments") { model.rows.sorted.map(\.id.description) == ["shop/web", "shop/worker"] }
        XCTAssertEqual(page.title, "Deployments")
        XCTAssertEqual(page.section, .workloads)
        // The server's, and a Status of the page's before Age: its Table has none (KubeDeploymentHint).
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Up-to-date", "Available", "Status", "Age"])
        page.wide = true
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Up-to-date", "Available", "Status", "Age", "Containers", "Images", "Selector"])
        page.wide = false
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "None" })
        XCTAssertEqual(page.failing, [], "only pods are read for failures")
        api.add("deployments.apps", "cache", namespace: "shop", values: ["Ready": "1/1"])
        api.update("deployments.apps", "worker", namespace: "shop", values: ["Ready": "1/1", "Available": 1])
        try await until(5, "watched") {
            model.rows.count == 3 && model.rows[KubeRowID(namespace: "shop", name: "worker")]?.cell("Ready", in: model.rows.columns) == .text("1/1")
        }
        page.filter = "work"
        XCTAssertEqual(page.rows.map(\.id), ["shop/worker"])
        page.filter = ""

        // All namespaces: a Namespace column first, the metadata asked for.
        model.setScope(.all)
        try await until(5, "all") { model.rows.count == 4 }
        XCTAssertEqual(page.columns.first?.title, "Namespace")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/deployments" && $0.query["includeObject"] == "Metadata" })

        // A cluster-scoped kind: no namespace in its path or its rows, no Namespace column.
        XCTAssertTrue(page.press("6"))
        XCTAssertEqual(page.section, .cluster)
        XCTAssertEqual(model.kind.fullName, "nodes")
        try await until(5, "nodes") { model.rows.sorted.map(\.id.description) == ["fake-node-1"] }
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Status", "Roles", "CPU", "Memory", "Age", "Version"], "usage before Age")
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/nodes" && $0.query["includeObject"] == "None" })

        // Back to Workloads: the kind last shown there.
        XCTAssertTrue(page.press("2"))
        XCTAssertEqual(model.kind.fullName, "deployments.apps")
        // A section with nothing served: it says so, and lists nothing new.
        XCTAssertTrue(page.press("5"))
        XCTAssertEqual(page.section, .storage)
        XCTAssertFalse(page.showsSection)
        XCTAssertEqual(page.title, "Storage")
        XCTAssertEqual(model.kind.fullName, "deployments.apps")
    }

    /// A Secret's list is its Table: Name, Type, Data (how many keys) and
    /// Age — across all namespaces with the metadata, whose
    /// last-applied-configuration (every value, from a client-side apply)
    /// is never kept.
    func testASecretsListCarriesNoValue() async throws {
        let value = "s3cr3t-hunter2"
        let applied = #"{"apiVersion":"v1","data":{"password":"\#(Data(value.utf8).base64EncodedString())"},"kind":"Secret"}"#
        api.add(
            "secrets", "db", namespace: "shop", values: ["Type": "Opaque"], annotations: ["kubectl.kubernetes.io/last-applied-configuration": applied],
            data: ["password": value, "user": "app"])
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { !model.catalog.isEmpty }
        XCTAssertTrue(page.press("4"))
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "secrets")))
        model.setScope(.all)
        try await until(5, "secrets") { model.rows.count == 1 && model.kind.fullName == "secrets" }
        XCTAssertEqual(page.columns.map(\.title), ["Namespace", "Name", "Type", "Data", "Age"])
        let row = try XCTUnwrap(model.rows[KubeRowID(namespace: "shop", name: "db")])
        XCTAssertEqual(row.cell("Data", in: model.rows.columns), .integer(2))
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/secrets" && $0.query["includeObject"] == "Metadata" })
        for kept in [String(describing: model.rows), String(describing: page.rows)] {
            XCTAssertFalse(kept.contains(value) || kept.contains(Data(value.utf8).base64EncodedString()) || kept.contains("last-applied"), kept)
        }
    }

    // MARK: What the cluster serves, read again

    /// While the page shows, a CRD added shows as a kind without a
    /// reconnect — the CRD watch — and its custom resources list in its
    /// printer columns; removed, it goes, and the list says so.
    func testACRDAddedOrRemovedIsDiscoveredByItsWatch() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "watching CRDs") { self.api.watched.contains(KubernetesModel.crdName) && !model.catalog.isEmpty }
        XCTAssertEqual(model.catalog.kinds(in: .custom), [])
        XCTAssertTrue(page.press("7"))
        XCTAssertFalse(page.showsSection, "no custom resources yet")
        let reads = model.discoveryReads

        addWidgets()
        try await until(5, "the widgets kind") { model.catalog.kinds(in: .custom).map(\.fullName) == ["widgets.example.com"] }
        XCTAssertEqual(model.discoveryReads, reads + 1, "one read for the burst")
        try await until(5, "the section shows it") { page.showsSection && model.kind.fullName == "widgets.example.com" }
        try await until(5, "widgets") { model.rows.sorted.map(\.id.description) == ["shop/blue-1", "shop/red-1"] }
        XCTAssertEqual(page.title, "Widgets")
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Color", "Size", "Ready", "Age"], "its printer columns")
        page.wide = true
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Color", "Size", "Ready", "Owner", "Age"])
        XCTAssertEqual(model.rows[KubeRowID(namespace: "shop", name: "red-1")]?.cell("Size", in: model.rows.columns), .integer(5))
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/example.com/v1/namespaces/shop/widgets" && $0.query["includeObject"] == "None" })

        api.removeCRD("widgets.example.com")
        try await until(5, "gone") { model.catalog.kinds(in: .custom).isEmpty }
        try await until(5, "said") {
            if case .failed(let reason, _) = model.listState { return reason.contains("widgets.example.com") }
            return false
        }
        XCTAssertEqual(model.rows.count, 0)
    }

    /// Hidden and shown again with a kind picked before the kubeconfig is
    /// read back (`show` reads it off the main thread): the list starts
    /// at once, and the CRD watch with it — a CRD applied then still shows.
    func testShownAgainWithAKindPickedAtOnceTheCRDWatchComesBack() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        try await until(5, "watching CRDs") { self.api.watched.contains(KubernetesModel.crdName) && !model.catalog.isEmpty }
        let pods = try XCTUnwrap(model.catalog.kind(fullName: "pods"))
        let deployments = try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps"))
        model.hide()
        try await until(5, "the watch ends hidden") { !self.api.watched.contains(KubernetesModel.crdName) }
        model.show()
        defer { model.hide() }
        page.showKind(model.kind == pods ? deployments : pods)
        try await until(5, "the CRD watch, again") { self.api.watched.contains(KubernetesModel.crdName) }
        addWidgets()
        try await until(5, "the widgets kind, by the watch") { model.catalog.kind(fullName: "widgets.example.com") != nil }
    }

    /// Where CRDs can't be listed (RBAC), discovery is read again on a timer.
    func testWithoutTheCRDListDiscoveryIsReadOnATimer() async throws {
        api.forbidden = ["customresourcedefinitions"]
        addWidgets()
        let model = model()
        model.rediscoveryInterval = .milliseconds(300)
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.catalog.kind(fullName: "widgets.example.com") != nil }
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "widgets.example.com")))
        try await until(5, "widgets") { model.rows.count == 2 }
        XCTAssertFalse(api.watched.contains(KubernetesModel.crdName), "no CRD watch where they can't be listed")

        // The timer: a CRD added shows in a moment.
        api.addCRD(group: "tools.example.com", version: "v1", plural: "gizmos", kind: "Gizmo")
        try await until(5, "gizmos, by the timer") { model.catalog.kind(fullName: "gizmos.tools.example.com") != nil }
    }

    /// A kind the server answers 404 for is looked up again, at once — not
    /// on the timer, which is out of reach here: served at another version
    /// now, it is followed there.
    func testAKindThatAnswers404IsLookedUpAgain() async throws {
        api.forbidden = ["customresourcedefinitions"]
        addWidgets()
        let model = model()
        model.rediscoveryInterval = .seconds(300)
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.catalog.kind(fullName: "widgets.example.com") != nil }
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "widgets.example.com")))
        try await until(5, "widgets") { model.rows.count == 2 }
        let reads = model.discoveryReads

        // Widgets served at v2 now: the watch ends, the next list is a 404,
        // and discovery read again finds it there.
        api.removeCRD("widgets.example.com")
        api.addCRD(group: "example.com", version: "v2", plural: "widgets", kind: "Widget", columns: Self.widgetColumns)
        api.add("widgets.example.com", "green-2", namespace: "shop", values: ["Color": "green"])
        try await until(5, "followed at v2") { model.kind.version == "v2" && model.rows.sorted.map(\.id.name) == ["green-2"] }
        XCTAssertEqual(model.discoveryReads, reads + 1, "one read, after the 404")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/example.com/v2/namespaces/shop/widgets" })
    }

    /// Pods 404, and discovery read again has none: the list says so,
    /// rather than waiting for good.
    func testPodsThatAnswer404AndAreNotServedSaySo() async throws {
        let model = model()
        model.rediscoveryInterval = .seconds(300)
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.listState == .live && model.rows.count == 1 }
        api.removeCRD("pods")
        try await until(5, "said") {
            if case .failed(let reason, _) = model.listState { return reason.contains("404") }
            return false
        }
    }

    /// A context read again whose name now reaches another cluster: what
    /// was read for it isn't kept — discovery is read afresh.
    func testAContextThatNowReachesAnotherClusterIsDiscoveredAgain() async throws {
        let list = Locked(KubeContextList(contexts: [Self.context("fake-dev", namespace: "shop")], current: "fake-dev"))
        let model = model()
        model.load = { _ in list.value }
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { !model.catalog.isEmpty && model.listState == .live }
        XCTAssertEqual(model.discoveryReads, 1)
        model.reloadContexts()
        try await until(5, "read again") { model.listState == .live }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.discoveryReads, 1, "the same cluster: kept")

        let moved = Self.context("fake-dev", namespace: "shop")
        list.value = KubeContextList(
            contexts: [
                KubeContext(
                    name: moved.name, cluster: "fake-dev-2", server: "http://127.0.0.1:2", namespace: moved.namespace, user: moved.user, auth: moved.auth,
                    file: moved.file, contextClass: moved.contextClass, settings: moved.settings)
            ], current: "fake-dev")
        model.reloadContexts()
        try await until(5, "discovered again") { model.discoveryReads == 2 && !model.catalog.isEmpty }
    }

    /// Discovery is read once a context and kept: back on it within the
    /// interval, it isn't read again — and a kind the other context doesn't
    /// serve falls back to Pods there.
    func testDiscoveryIsKeptPerContext() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { !model.catalog.isEmpty }
        XCTAssertEqual(model.discoveryReads, 1)
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps")))
        model.select("fake-prod")
        try await until(5, "fake-prod's") { model.discoveryReads == 2 && !model.catalog.isEmpty }
        XCTAssertEqual(model.kind.fullName, "deployments.apps", "served there too")
        try await until(5, "its deployments") { model.rows.sorted.map(\.id.description) == ["payments/api"] }
        model.select("fake-dev")
        XCTAssertFalse(model.catalog.isEmpty, "kept: at once")
        try await until(5, "listed") { model.listState == .live && model.rows.count == 2 }
        XCTAssertEqual(model.discoveryReads, 2, "not read again")
    }

    // MARK: The `:` bar on the page

    func testTheCommandBarShowsAKindANamespaceAContext() async throws {
        addWidgets()
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { !model.catalog.isEmpty && !model.namespaces.isEmpty }

        XCTAssertTrue(page.press(":"))
        XCTAssertNotNil(page.command)
        page.command?.text = "deploy"
        page.runCommand()
        XCTAssertNil(page.command, "done: closed")
        XCTAssertEqual(model.kind.fullName, "deployments.apps")
        XCTAssertEqual(page.section, .workloads)

        _ = page.press(":")
        page.command?.text = "svc payments"
        page.runCommand()
        XCTAssertEqual(model.kind.fullName, "services")
        XCTAssertEqual(page.section, .network)
        XCTAssertEqual(model.scope, .namespace("payments"))

        _ = page.press(":")
        page.command?.text = "wd shop app=web /blue"
        page.runCommand()
        XCTAssertEqual(model.kind.fullName, "widgets.example.com")
        XCTAssertEqual(page.section, .custom)
        XCTAssertEqual(model.scope, .namespace("shop"))
        XCTAssertEqual(page.filter, "blue label:app=web")

        _ = page.press(":")
        page.command?.text = "nope"
        page.runCommand()
        XCTAssertEqual(page.command?.problem, "fake-dev serves no kind called nope.", "it stays, saying why")
        page.command?.text = "componentstatuses"
        page.runCommand()
        XCTAssertEqual(page.command?.problem, "componentstatuses can't be listed and watched (get, list).")
        page.closeCommand()
        XCTAssertNil(page.command)

        _ = page.press(":")
        page.command?.text = "ns -A"
        page.runCommand()
        XCTAssertEqual(model.scope, .all)
        _ = page.press(":")
        page.command?.text = "ctx"
        page.runCommand()
        XCTAssertEqual(page.picker?.kind, .context, ":ctx alone is the picker")
        page.closePicker()
        _ = page.press(":")
        page.command?.text = "po @fake-prod"
        page.runCommand()
        XCTAssertEqual(model.selectedName, "fake-prod")
        XCTAssertEqual(model.kind.fullName, "pods")
        _ = page.press(":")
        page.command?.text = "po @nowhere"
        page.runCommand()
        XCTAssertEqual(page.command?.problem, "No context called nowhere.")
        page.closeCommand()
    }

    /// A command that can't be done switches no context: `:nope @fake-prod`
    /// starts nothing for fake-prod and asks it nothing.
    func testARejectedCommandSwitchesNoContext() async throws {
        let model = model()
        let reached = Locked<[String]>([])
        let connect = model.connectOverride
        model.connectOverride = { context in
            reached.value.append(context.name)
            return connect!(context)
        }
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { !model.catalog.isEmpty && model.listState == .live }

        for (text, problem) in [
            ("nope @fake-prod", "fake-prod serves no kind called nope."), ("deploy Bad_NS @fake-prod", "Not a namespace's name: Bad_NS"),
            ("componentstatuses @fake-prod", "componentstatuses can't be listed and watched (get, list)."),
            ("ns Bad_NS @fake-prod", "Not a namespace's name: Bad_NS"),
        ] {
            _ = page.press(":")
            page.command?.text = text
            page.runCommand()
            XCTAssertEqual(page.command?.problem, problem, text)
            XCTAssertEqual(model.selectedName, "fake-dev", text)
            page.closeCommand()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(reached.value.contains("fake-prod"), "nothing asked of fake-prod")

        _ = page.press(":")
        page.command?.text = "deploy payments @fake-prod"
        page.runCommand()
        XCTAssertNil(page.command)
        XCTAssertEqual(model.selectedName, "fake-prod")
        XCTAssertEqual(model.kind.fullName, "deployments.apps")
        XCTAssertEqual(model.scope, .namespace("payments"))
        try await until(5, "its deployments") { model.rows.sorted.map(\.id.description) == ["payments/api"] }
    }
}

/// A value the fake's callbacks and the test share.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
