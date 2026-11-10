import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Overterm

/// The dependency tree in a detail's Overview (docs/design/kubernetes/
/// analysis.md, 3.7, stage 3b) and Argo CD's and Flux's trees: which kinds
/// have one and what each reads — only what it uses, in its namespace,
/// bounded, Secrets as their Table's names —; the owner chain down to
/// containers, references across (a missing ConfigMap red, an optional one
/// grey), the Services selecting its pods (none red) and the routes to
/// them (a missing port red); an Application's, a Kustomization's and a
/// HelmRelease's trees; and against `FakeKubeAPI` on a socket of the
/// test's own, the reads made once the Overview shows — GETs only, no
/// Secret read, no watch — and `x` and the nodes' verbs on the page.
/// Nothing reads ~/.kube.
@MainActor
final class KubeTreeTests: XCTestCase {
    private static let secretValue = "acme-tree-pw-Qm4Vx"
    nonisolated(unsafe) private var api: FakeKubeAPI?
    nonisolated(unsafe) private var socket: String?
    /// The page test's list watches the kind shown: only the tree's reads are checked for none.
    nonisolated(unsafe) private var pageWatches = false

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "reads only")
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "no Secret read")
            // The page's own list watches; the tree opens none.
            XCTAssertFalse(api.requests.contains { $0.query["watch"] != nil && !pageWatches }, "no watch")
            api.stop()
        }
    }

    // MARK: Fixtures

    private static func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private static func list(_ items: [[String: Any]], more: Bool = false) -> Data {
        var metadata: [String: Any] = ["resourceVersion": "10"]
        if more { metadata["continue"] = "next" }
        return data(["kind": "List", "metadata": metadata, "items": items])
    }

    /// A Table of names, with one more column (a Secret's Type, a PVC's Status).
    private static func table(_ rows: [(String, String)], column: String? = nil, more: Bool = false) -> Data {
        var columns: [[String: Any]] = [["name": "Name", "type": "string", "format": "name", "priority": 0]]
        if let column { columns.append(["name": column, "type": "string", "format": "", "priority": 0]) }
        var metadata: [String: Any] = ["resourceVersion": "10"]
        if more { metadata["continue"] = "next" }
        return data([
            "kind": "Table", "apiVersion": "meta.k8s.io/v1", "metadata": metadata, "columnDefinitions": columns,
            "rows": rows.map { ["cells": column == nil ? [$0.0] : [$0.0, $0.1]] },
        ])
    }

    private static func meta(_ name: String, uid: String? = nil, labels: [String: String] = [:], owner: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var metadata: [String: Any] = ["name": name, "namespace": "shop", "uid": uid ?? "uid-\(name)"]
        if !labels.isEmpty { metadata["labels"] = labels }
        if let owner { metadata["ownerReferences"] = [["uid": owner, "name": "x", "kind": "x", "apiVersion": "v1", "controller": true]] }
        return metadata.merging(extra) { $1 }
    }

    private static let podSpec: [String: Any] = [
        "serviceAccountName": "web",
        "imagePullSecrets": [["name": "regcred"]],
        "volumes": [
            ["name": "config", "configMap": ["name": "web-config"]],
            ["name": "extra", "configMap": ["name": "web-extra", "optional": true]],
            ["name": "data", "persistentVolumeClaim": ["claimName": "web-data"]],
            ["name": "certs", "projected": ["sources": [["secret": ["name": "web-tls"]], ["configMap": ["name": "web-config"]]]]],
        ],
        "containers": [
            [
                "name": "app", "image": "web:1",
                "envFrom": [["configMapRef": ["name": "web-env"]]],
                "env": [["name": "DB_PASSWORD", "valueFrom": ["secretKeyRef": ["name": "web-db", "key": "password"]]], ["name": "LOG", "value": "info"]],
            ]
        ],
    ]

    private static func deployment() -> [String: Any] {
        [
            "apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta("web", uid: "uid-deploy"),
            "spec": [
                "replicas": 2, "selector": ["matchLabels": ["app": "web"]],
                "template": ["metadata": ["labels": ["app": "web", "tier": "front"]], "spec": podSpec],
            ],
            "status": ["observedGeneration": 1, "replicas": 2, "updatedReplicas": 2, "readyReplicas": 1, "availableReplicas": 1],
        ]
    }

    private static func replicaSet(_ name: String, revision: Int, replicas: Int) -> [String: Any] {
        [
            "metadata": meta(name, owner: "uid-deploy", extra: ["annotations": ["deployment.kubernetes.io/revision": String(revision)]]),
            "spec": ["replicas": replicas], "status": ["replicas": replicas, "readyReplicas": max(0, replicas - 1)],
        ]
    }

    private static func pod(_ name: String, owner: String, labels: [String: String] = ["app": "web", "tier": "front"], waiting: String? = nil) -> [String: Any] {
        let state: [String: Any] = waiting.map { ["waiting": ["reason": $0]] } ?? ["running": ["startedAt": "2026-11-06T09:00:00Z"]]
        return [
            "metadata": meta(name, labels: labels, owner: owner),
            "spec": ["containers": [["name": "app", "image": "web:1"]]],
            "status": [
                "phase": "Running",
                "containerStatuses": [["name": "app", "ready": waiting == nil, "restartCount": waiting == nil ? 0 : 4, "state": state]],
            ],
        ]
    }

    private static func service(_ name: String, selector: [String: String], ports: [(Int, String?)] = [(80, "http")]) -> [String: Any] {
        [
            "metadata": meta(name),
            "spec": [
                "selector": selector,
                "ports": ports.map { port, name -> [String: Any] in
                    var item: [String: Any] = ["port": port, "protocol": "TCP"]
                    if let name { item["name"] = name }
                    return item
                },
            ],
        ]
    }

    private static func ingress(_ name: String, service: String, port: Int, tls: String? = nil) -> [String: Any] {
        var spec: [String: Any] = [
            "rules": [
                [
                    "host": "shop.acme.example",
                    "http": ["paths": [["path": "/", "pathType": "Prefix", "backend": ["service": ["name": service, "port": ["number": port]]]]]],
                ]
            ]
        ]
        if let tls { spec["tls"] = [["hosts": ["shop.acme.example"], "secretName": tls]] }
        return ["apiVersion": "networking.k8s.io/v1", "metadata": meta(name), "spec": spec]
    }

    private func read(_ root: [String: Any], _ lists: [(KubeTree.Read.What, Data)]) -> KubeTreeRead {
        var read = KubeTreeRead(root: Self.data(root))
        for (what, body) in lists { read.add(KubeTree.Read(what: what, namespace: "shop"), body: body) }
        return read
    }

    private func node(_ tree: KubeTree, _ kind: String, _ name: String) -> KubeTreeNode? {
        tree.root.all.first { $0.kind == kind && $0.name == name }
    }

    // MARK: Which kinds, what they read

    func testWhichKindsHaveATree() {
        func kind(_ group: String, _ resource: String) -> KubeResourceKind {
            KubeResourceKind(group: group, version: "v1", resource: resource, kind: "", singular: "", namespaced: true, verbs: ["get", "list"])
        }
        XCTAssertEqual(KubeTree.Root.of(kind("", "pods")), .pod)
        XCTAssertEqual(KubeTree.Root.of(kind("apps", "deployments")), .deployment)
        XCTAssertEqual(KubeTree.Root.of(kind("batch", "cronjobs")), .cronJob)
        XCTAssertEqual(KubeTree.Root.of(kind("", "services")), .service)
        XCTAssertEqual(KubeTree.Root.of(kind("networking.k8s.io", "ingresses")), .ingress)
        XCTAssertEqual(KubeTree.Root.of(kind("gateway.networking.k8s.io", "httproutes")), .httpRoute)
        XCTAssertEqual(KubeTree.Root.of(kind("argoproj.io", "applications")), .argoApplication)
        XCTAssertEqual(KubeTree.Root.of(kind("kustomize.toolkit.fluxcd.io", "kustomizations")), .fluxKustomization)
        XCTAssertEqual(KubeTree.Root.of(kind("helm.toolkit.fluxcd.io", "helmreleases")), .fluxHelmRelease)
        XCTAssertNil(KubeTree.Root.of(kind("", "secrets")), "a Secret has no tree")
        XCTAssertNil(KubeTree.Root.of(kind("", "configmaps")))
        let secret = KubeObjectRef(context: "fake-dev", kind: kind("", "secrets"), namespace: "shop", name: "web-db")
        XCTAssertNil(KubeDetailSession(ref: secret, client: nil).tree)
    }

    func testADeploymentReadsOnlyWhatItUsesInItsNamespace() {
        let reads = KubeTree.reads(.deployment, object: Self.deployment())
        XCTAssertEqual(
            reads.map(\.what), [.replicaSets, .pods, .configMaps, .secrets, .claims, .accounts, .services, .ingresses, .routes])
        XCTAssertTrue(reads.allSatisfy { $0.namespace == "shop" }, "its own namespace")
        XCTAssertEqual(reads.first { $0.what == .pods }?.labelSelector, "app=web")
        XCTAssertEqual(reads.first { $0.what == .pods }?.limit, KubeTree.podLimit)
        XCTAssertTrue(reads.filter(\.table).map(\.what) == [.configMaps, .secrets, .claims, .accounts], "names only, from Tables")

        // A pod that uses nothing by name lists no ConfigMaps, Secrets or claims.
        let bare: [String: Any] = [
            "kind": "Pod", "metadata": Self.meta("bare"), "spec": ["containers": [["name": "app", "image": "busybox"]]],
        ]
        XCTAssertEqual(KubeTree.reads(.pod, object: bare).map(\.what), [.accounts, .services, .ingresses, .routes])
        // Argo's and a Kustomization's say what they manage: nothing read.
        XCTAssertEqual(KubeTree.reads(.argoApplication, object: ["metadata": Self.meta("shop")]), [])
        XCTAssertEqual(KubeTree.reads(.fluxKustomization, object: ["metadata": Self.meta("shop")]), [])
    }

    func testThePathsAskForNamesOnlyAndAreBounded() {
        let secrets = KubeTree.Read(what: .secrets, namespace: "shop")
        let kind = KubeTreeSession.kind(secrets, in: nil)!
        let path = KubeTreeSession.path(secrets, kind: kind)
        XCTAssertEqual(path, "/api/v1/namespaces/shop/secrets?limit=500&includeObject=None")
        let pods = KubeTree.Read(what: .pods, namespace: "shop", labelSelector: "app=web")
        XCTAssertEqual(KubeTreeSession.path(pods, kind: KubeTreeSession.kind(pods, in: nil)!), "/api/v1/namespaces/shop/pods?labelSelector=app%3Dweb&limit=200")
        XCTAssertNil(KubeTreeSession.kind(KubeTree.Read(what: .routes, namespace: "shop"), in: nil), "Gateway API only where discovery serves it")
        XCTAssertNil(KubeTreeSession.kind(KubeTree.Read(what: .routes, namespace: "shop"), in: KubeDiscovery(kinds: [.pods])))
    }

    func testReferencesFromEveryPlaceAPodNamesThem() {
        let found = KubeTree.references(Self.podSpec)
        XCTAssertEqual(
            found.map { "\($0.kind) \($0.name)" },
            [
                "ConfigMap web-config", "ConfigMap web-extra", "ConfigMap web-env", "Secret web-tls", "Secret web-db", "Secret regcred",
                "PersistentVolumeClaim web-data", "ServiceAccount web",
            ])
        XCTAssertEqual(found.first { $0.name == "web-config" }?.how, ["volume config", "volume certs"], "every way it is used")
        XCTAssertEqual(found.first { $0.name == "web-db" }?.how, ["env DB_PASSWORD"])
        XCTAssertEqual(found.first { $0.name == "web-extra" }?.optional, true)
        XCTAssertEqual(found.first { $0.name == "web-config" }?.optional, false)
        XCTAssertEqual(KubeTree.references(["containers": [[String: Any]]()]).map(\.name), ["default"], "the default ServiceAccount")
    }

    // MARK: A workload's tree

    func testADeploymentDownToContainersAndAcross() {
        let read = read(
            Self.deployment(),
            [
                (.replicaSets, Self.list([Self.replicaSet("web-old", revision: 1, replicas: 0), Self.replicaSet("web-new", revision: 2, replicas: 2)])),
                (
                    .pods,
                    Self.list([
                        Self.pod("web-new-a", owner: "uid-web-new"), Self.pod("web-new-b", owner: "uid-web-new", waiting: "CrashLoopBackOff"),
                        Self.pod("api-x", owner: "uid-someone", labels: ["app": "web"]),
                    ])
                ),
                (.configMaps, Self.table([("web-config", ""), ("unrelated", "")])),
                (.secrets, Self.table([("web-db", "Opaque"), ("web-tls", "kubernetes.io/tls")], column: "Type")),
                (.claims, Self.table([("web-data", "Bound")], column: "Status")),
                (.accounts, Self.table([("default", "")])),
                (
                    .services,
                    Self.list([
                        Self.service("web", selector: ["app": "web"]), Self.service("api", selector: ["app": "api"]),
                        Self.service("web-front", selector: ["tier": "front", "app": "web"]),
                    ])
                ),
                (.ingresses, Self.list([Self.ingress("web", service: "web", port: 80), Self.ingress("web-bad", service: "web", port: 8080)])),
                (.routes, Self.list([])),
            ])
        let tree = KubeTree.build(.deployment, read: read)
        XCTAssertEqual(tree.root.kind, "Deployment")
        XCTAssertEqual(tree.root.health, .waiting, "1/2 ready")
        XCTAssertEqual(tree.root.status, "1/2 ready")

        // Down: the ReplicaSet with pods, its pods, their containers; the old one counted.
        let owned = tree.root.children.filter { $0.relation == .owns }
        XCTAssertEqual(owned.map(\.name), ["web-new"])
        XCTAssertEqual(owned.first?.how, "revision 2")
        XCTAssertEqual(owned.first?.children.map(\.name), ["web-new-a", "web-new-b"], "its own pods, not another owner's")
        XCTAssertEqual(node(tree, "Pod", "web-new-b")?.health, .bad)
        XCTAssertEqual(node(tree, "Pod", "web-new-b")?.status, "CrashLoopBackOff · 4 restarts")
        XCTAssertEqual(node(tree, "Pod", "web-new-a")?.health, .good)
        XCTAssertEqual(node(tree, "Pod", "web-new-a")?.children.map(\.kind), ["Container"])
        XCTAssertNil(node(tree, "Pod", "web-new-a")?.children.first?.link, "a container opens nothing")
        XCTAssertTrue(tree.notes.contains("1 older ReplicaSet, scaled to 0, left out."), "\(tree.notes)")

        // Across: a missing ConfigMap red, an optional one grey, the rest found.
        XCTAssertEqual(node(tree, "ConfigMap", "web-config")?.health, .good)
        XCTAssertEqual(node(tree, "ConfigMap", "web-env")?.health, .missing)
        XCTAssertEqual(node(tree, "ConfigMap", "web-env")?.status, "not found")
        XCTAssertEqual(node(tree, "ConfigMap", "web-extra")?.health, .dim)
        XCTAssertEqual(node(tree, "Secret", "web-db")?.status, "Opaque", "by name and type, from the Table")
        XCTAssertEqual(node(tree, "Secret", "regcred")?.health, .missing)
        XCTAssertEqual(node(tree, "PersistentVolumeClaim", "web-data")?.status, "Bound")
        XCTAssertEqual(node(tree, "ServiceAccount", "web")?.health, .missing, "its own account isn't there")

        // The Services that select its pods, and what routes to them.
        let services = tree.root.children.filter { $0.relation == .selects }
        XCTAssertEqual(services.map(\.name), ["web", "web-front"], "not api's")
        XCTAssertEqual(services.first?.status, "selects 2 of its pods")
        let routes = services.first?.children ?? []
        XCTAssertEqual(routes.map(\.name), ["web", "web-bad"])
        XCTAssertEqual(routes.first?.how, "shop.acme.example/ → 80")
        XCTAssertEqual(routes.first?.health, .good)
        XCTAssertEqual(routes.last?.health, .bad, "a port the Service hasn't")
        XCTAssertEqual(Set(tree.problems.map(\.name)), ["web-new-b", "app", "web-env", "regcred", "web", "web-bad"], "the crashing pod's container too")
    }

    func testAListCutOrRefusedChecksNothing() {
        var read = read(Self.deployment(), [(.configMaps, Self.table([("other", "")], more: true))])
        read.failed(KubeTree.Read(what: .secrets, namespace: "shop"), "secrets is forbidden")
        let tree = KubeTree.build(.deployment, read: read)
        XCTAssertEqual(node(tree, "ConfigMap", "web-config")?.health, .unknown, "the list was cut: not known missing")
        XCTAssertEqual(node(tree, "ConfigMap", "web-config")?.status, "not checked: the list was cut")
        XCTAssertEqual(node(tree, "Secret", "web-db")?.health, .unknown)
        XCTAssertTrue(tree.notes.contains { $0.hasPrefix("More than 500 ConfigMaps in shop") }, "\(tree.notes)")
        XCTAssertTrue(tree.notes.contains { $0.contains("secrets is forbidden") })
    }

    /// No pod to select is red only when it should have some: pods not
    /// listed (refused) aren't checked, and a workload scaled to 0 wants none.
    func testAServiceOfAWorkloadWithNoPodsReadOrWantedIsntRed() {
        let service = Self.service("web", selector: ["app": "web"])
        var refused = read(Self.deployment(), [(.services, Self.list([service]))])
        refused.failed(KubeTree.Read(what: .pods, namespace: "shop"), "pods is forbidden")
        let unread = KubeTree.build(.deployment, read: refused)
        XCTAssertEqual(node(unread, "Service", "web")?.health, .unknown, "\(String(describing: node(unread, "Service", "web")))")
        XCTAssertEqual(node(unread, "Service", "web")?.status, "not checked: its pods weren't listed")
        XCTAssertFalse(unread.problems.contains { $0.kind == "Service" })

        var idle = Self.deployment()
        idle["spec"] = (idle["spec"] as! [String: Any]).merging(["replicas": 0]) { $1 }
        let scaled = KubeTree.build(.deployment, read: read(idle, [(.pods, Self.list([])), (.services, Self.list([service]))]))
        XCTAssertEqual(node(scaled, "Service", "web")?.health, .dim)
        XCTAssertEqual(node(scaled, "Service", "web")?.status, "scaled to 0: no pod to select")

        let wanted = KubeTree.build(.deployment, read: read(Self.deployment(), [(.pods, Self.list([])), (.services, Self.list([service]))]))
        XCTAssertEqual(node(wanted, "Service", "web")?.health, .bad, "two wanted, none there: red")
    }

    /// A Secret list answered whole (a proxy that ignored the Accept): asked
    /// as a Table and nothing else, dropped unread, said — not missing.
    func testASecretListNotATableIsSaidNotMissing() {
        XCTAssertEqual(KubeTreeSession.accept(KubeTree.Read(what: .secrets, namespace: "shop")), "application/json;as=Table;v=v1;g=meta.k8s.io")
        XCTAssertFalse(KubeTreeSession.accept(KubeTree.Read(what: .configMaps, namespace: "shop")).contains(", application/json"))
        let whole = Self.list([["metadata": Self.meta("web-db"), "type": "Opaque", "data": ["password": Self.secretValue]]])
        let read = read(Self.deployment(), [(.secrets, whole)])
        XCTAssertNil(read.names(.secrets))
        let tree = KubeTree.build(.deployment, read: read)
        XCTAssertEqual(node(tree, "Secret", "web-db")?.health, .unknown)
        XCTAssertTrue(tree.notes.contains("The Secret list in shop couldn't be read as a Table: its names aren't checked."), "\(tree.notes)")
        XCTAssertFalse(String(describing: tree).contains(Self.secretValue))
    }

    /// A list's answer is decoded off the main actor: `add` isn't bound to it.
    func testAListIsDecodedOffTheMainActor() async {
        let root = Self.data(Self.deployment())
        let body = Self.list([Self.pod("web-1", owner: "rs")])
        let (offMain, count) = await Task.detached { () -> (Bool, Int) in
            var read = KubeTreeRead(root: root)
            read.add(KubeTree.Read(what: .pods, namespace: "shop"), body: body)
            return (pthread_main_np() == 0, read.items(.pods).count)
        }.value
        XCTAssertTrue(offMain)
        XCTAssertEqual(count, 1)
    }

    func testAServiceSelectingNothingIsRed() {
        let service = Self.service("web", selector: ["app": "web"]).merging(["kind": "Service", "apiVersion": "v1"]) { $1 }
        let empty = KubeTree.build(.service, read: read(service, [(.pods, Self.list([])), (.ingresses, Self.list([Self.ingress("web", service: "web", port: 80)]))]))
        XCTAssertEqual(empty.root.health, .bad)
        XCTAssertEqual(empty.root.status, "selects no pod")
        XCTAssertEqual(empty.root.children.map(\.kind), ["Ingress"])
        let some = KubeTree.build(.service, read: read(service, [(.pods, Self.list([Self.pod("web-1", owner: "rs")]))]))
        XCTAssertEqual(some.root.health, .good)
        XCTAssertEqual(some.root.children.map(\.name), ["web-1"])
        XCTAssertEqual(some.root.children.first?.relation, .selects)
        let manual = KubeTree.build(.service, read: read(Self.service("ext", selector: [:]).merging(["kind": "Service"]) { $1 }, []))
        XCTAssertEqual(manual.root.health, .dim, "no selector: not broken")
    }

    func testAnIngressToAMissingServiceAndOneSelectingNothing() {
        var ingress = Self.ingress("shop", service: "web", port: 80, tls: "shop-tls").merging(["kind": "Ingress"]) { $1 }
        var spec = ingress["spec"] as! [String: Any]
        spec["defaultBackend"] = ["service": ["name": "gone", "port": ["number": 80]]]
        var rules = spec["rules"] as! [[String: Any]]
        rules.append(["host": "api.acme.example", "http": ["paths": [["path": "/", "backend": ["service": ["name": "idle", "port": ["name": "http"]]]]]]])
        spec["rules"] = rules
        ingress["spec"] = spec
        let reads = KubeTree.reads(.ingress, object: ingress)
        XCTAssertEqual(reads.map(\.what), [.services, .secrets])
        var read = read(
            ingress,
            [
                (.services, Self.list([Self.service("web", selector: ["app": "web"]), Self.service("idle", selector: ["app": "idle"])])),
                (.secrets, Self.table([("shop-tls", "kubernetes.io/tls")], column: "Type")),
            ])
        let followUps = KubeTree.followUps(.ingress, object: ingress, read: read)
        XCTAssertEqual(followUps.map(\.labelSelector), ["app=web", "app=idle"], "each backend's pods, by its selector")
        read.add(followUps[0], body: Self.list([Self.pod("web-1", owner: "rs", labels: ["app": "web"])]))
        read.add(followUps[1], body: Self.list([]))
        let tree = KubeTree.build(.ingress, read: read)
        XCTAssertEqual(node(tree, "Service", "gone")?.health, .missing)
        XCTAssertEqual(node(tree, "Service", "idle")?.status, "selects no pod")
        XCTAssertEqual(node(tree, "Service", "idle")?.health, .bad)
        XCTAssertEqual(node(tree, "Service", "web")?.children.map(\.name), ["web-1"])
        XCTAssertEqual(node(tree, "Secret", "shop-tls")?.how, "tls")
        XCTAssertEqual(node(tree, "Secret", "shop-tls")?.status, "kubernetes.io/tls")
    }

    func testAStatefulSetsClaimsAndACronJobsJobs() {
        let set: [String: Any] = [
            "kind": "StatefulSet", "apiVersion": "apps/v1", "metadata": Self.meta("db", uid: "uid-db"),
            "spec": [
                "replicas": 2, "selector": ["matchLabels": ["app": "db"]],
                "template": ["metadata": ["labels": ["app": "db"]], "spec": ["containers": [["name": "db", "image": "postgres:16"]]]],
                "volumeClaimTemplates": [["metadata": ["name": "data"]]],
            ],
        ]
        XCTAssertTrue(KubeTree.reads(.statefulSet, object: set).contains { $0.what == .claims })
        let tree = KubeTree.build(
            .statefulSet,
            read: read(set, [(.claims, Self.table([("data-db-1", "Bound"), ("data-db-0", "Pending"), ("data-dbx-0", "Bound")], column: "Status"))]))
        let claims = tree.root.children.filter { $0.kind == "PersistentVolumeClaim" }
        XCTAssertEqual(claims.map(\.name), ["data-db-0", "data-db-1"], "its template's, by ordinal")
        XCTAssertEqual(claims.first?.health, .waiting)

        let cron: [String: Any] = [
            "kind": "CronJob", "apiVersion": "batch/v1", "metadata": Self.meta("report", uid: "uid-cron"),
            "spec": ["schedule": "0 * * * *", "jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "r", "image": "r:1"]]]]]]],
        ]
        XCTAssertEqual(KubeTree.reads(.cronJob, object: cron).first?.what, .jobs)
        func job(_ name: String, created: String, failed: Bool = false) -> [String: Any] {
            [
                "metadata": Self.meta(name, owner: "uid-cron", extra: ["creationTimestamp": created]),
                "spec": ["selector": ["matchLabels": ["controller-uid": "uid-\(name)"]]],
                "status": ["conditions": [["type": failed ? "Failed" : "Complete", "status": "True", "reason": failed ? "BackoffLimitExceeded" : ""]]],
            ]
        }
        var read = read(
            cron,
            [(.jobs, Self.list([job("report-1", created: "2026-11-06T08:00:00Z"), job("report-2", created: "2026-11-06T09:00:00Z", failed: true)]))])
        let followUps = KubeTree.followUps(.cronJob, object: cron, read: read)
        XCTAssertEqual(followUps.map(\.labelSelector), ["controller-uid=uid-report-2", "controller-uid=uid-report-1"], "newest first")
        read.add(followUps[0], body: Self.list([Self.pod("report-2-x", owner: "uid-report-2")]))
        let jobs = KubeTree.build(.cronJob, read: read)
        XCTAssertEqual(jobs.root.children.filter { $0.kind == "Job" }.map(\.name), ["report-2", "report-1"])
        XCTAssertEqual(node(jobs, "Job", "report-2")?.health, .bad)
        XCTAssertEqual(node(jobs, "Job", "report-2")?.children.map(\.name), ["report-2-x"])
    }

    func testAnHTTPRoutesGatewayAndBackends() {
        let route: [String: Any] = [
            "kind": "HTTPRoute", "apiVersion": "gateway.networking.k8s.io/v1", "metadata": Self.meta("web"),
            "spec": [
                "parentRefs": [["name": "public", "namespace": "infra", "sectionName": "https"]],
                "rules": [["matches": [["path": ["type": "PathPrefix", "value": "/api"]]], "backendRefs": [["name": "web", "port": 80], ["name": "gone", "port": 80]]]],
            ],
            "status": [
                "parents": [["parentRef": ["name": "public"], "conditions": [["type": "Accepted", "status": "True"], ["type": "ResolvedRefs", "status": "False", "reason": "BackendNotFound"]]]]
            ],
        ]
        let tree = KubeTree.build(.httpRoute, read: read(route, [(.services, Self.list([Self.service("web", selector: ["app": "web"])]))]))
        let gateway = node(tree, "Gateway", "public")
        XCTAssertEqual(gateway?.namespace, "infra")
        XCTAssertEqual(gateway?.how, "parent, listener https")
        XCTAssertEqual(gateway?.health, .bad)
        XCTAssertEqual(gateway?.status, "ResolvedRefs: BackendNotFound")
        XCTAssertEqual(node(tree, "Service", "gone")?.health, .missing)
        XCTAssertEqual(node(tree, "Service", "web")?.how, "/api → 80")
    }

    // MARK: Argo CD and Flux

    func testAnArgoApplicationsTreeFromItsStatus() {
        let app: [String: Any] = [
            "kind": "Application", "apiVersion": "argoproj.io/v1alpha1", "metadata": ["name": "shop", "namespace": "argocd"],
            "spec": [
                "source": ["repoURL": "https://git.acme.example/shop.git", "path": "deploy", "targetRevision": "main"],
                "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
            ],
            "status": [
                "sync": ["status": "OutOfSync", "revision": "abc1234def567890"], "health": ["status": "Degraded"],
                "resources": [
                    ["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "web", "status": "Synced", "health": ["status": "Healthy"]],
                    ["version": "v1", "kind": "Service", "namespace": "shop", "name": "web", "status": "OutOfSync", "health": ["status": "Healthy"]],
                    ["version": "v1", "kind": "ConfigMap", "namespace": "shop", "name": "web-config", "status": "Synced"],
                    ["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "worker", "status": "Synced", "health": ["status": "Missing"]],
                    ["version": "v1", "kind": "Namespace", "name": "shop", "status": "Synced"],
                ],
            ],
        ]
        let tree = KubeTree.build(.argoApplication, read: KubeTreeRead(root: Self.data(app)))
        XCTAssertEqual(tree.root.health, .bad)
        XCTAssertEqual(tree.root.status, "OutOfSync · Degraded")
        XCTAssertEqual(tree.root.children.first?.relation, .source)
        XCTAssertEqual(tree.root.children.first?.name, "https://git.acme.example/shop.git")
        XCTAssertEqual(tree.root.children.first?.how, "deploy @ main")
        XCTAssertNil(tree.root.children.first?.link, "a repository isn't an object")
        let managed = tree.root.children.filter { $0.relation == .manages }
        XCTAssertEqual(managed.map(\.name), ["web", "web", "web-config", "worker", "shop"])
        XCTAssertEqual(managed[0].link, KubeLink(apiVersion: "apps/v1", kind: "Deployment", namespace: "shop", name: "web"))
        XCTAssertEqual(managed[1].health, .waiting, "out of sync")
        XCTAssertEqual(managed[2].health, .dim, "no health check")
        XCTAssertEqual(managed[3].health, .missing)
        XCTAssertNil(managed[4].namespace)
        XCTAssertEqual(managed[4].link?.apiVersion, "v1")

        var elsewhere = app
        elsewhere["spec"] = ["destination": ["server": "https://globex-eu.example:6443", "namespace": "shop"]]
        let remote = KubeTree.build(.argoApplication, read: KubeTreeRead(root: Self.data(elsewhere)))
        XCTAssertTrue(remote.root.children.allSatisfy { $0.link == nil }, "another cluster's objects aren't opened here")
        XCTAssertTrue(remote.notes.contains { $0.contains("another cluster") })
    }

    func testAFluxKustomizationsInventory() {
        XCTAssertEqual(KubeGitOpsSource.inventoryEntry("shop_web_apps_Deployment", version: "v1")?.apiVersion, "apps/v1")
        XCTAssertNil(KubeGitOpsSource.inventoryEntry("_shop__Namespace", version: "v1")?.namespace)
        XCTAssertEqual(KubeGitOpsSource.inventoryEntry("_shop__Namespace", version: "v1")?.apiVersion, "v1")
        XCTAssertNil(KubeGitOpsSource.inventoryEntry("garbage", version: "v1"))
        let kustomization: [String: Any] = [
            "kind": "Kustomization", "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "metadata": ["name": "shop", "namespace": "flux-system"],
            "spec": ["path": "./deploy", "sourceRef": ["kind": "GitRepository", "name": "shop"], "dependsOn": [["name": "infra"]]],
            "status": [
                "lastAppliedRevision": "main@sha1:abc1234",
                "conditions": [["type": "Ready", "status": "False", "reason": "HealthCheckFailed"]],
                "inventory": ["entries": [["id": "shop_web_apps_Deployment", "v": "v1"], ["id": "shop_web__Service", "v": "v1"], ["id": "_shop__Namespace", "v": "v1"]]],
            ],
        ]
        XCTAssertEqual(KubeTree.reads(.fluxKustomization, object: kustomization), [])
        let tree = KubeTree.build(.fluxKustomization, read: KubeTreeRead(root: Self.data(kustomization)))
        XCTAssertEqual(tree.root.health, .bad)
        XCTAssertEqual(tree.root.status, "Not ready: HealthCheckFailed")
        XCTAssertEqual(tree.root.how, "applied main@sha1:abc1234")
        let source = tree.root.children.first { $0.relation == .source }
        XCTAssertEqual(source?.link, KubeLink(apiVersion: "source.toolkit.fluxcd.io/v1", kind: "GitRepository", namespace: "flux-system", name: "shop"))
        XCTAssertEqual(tree.root.children.first { $0.how == "dependsOn" }?.name, "infra")
        XCTAssertEqual(tree.root.children.filter { $0.relation == .manages }.map { "\($0.kind) \($0.name)" }, ["Deployment web", "Service web", "Namespace shop"])
    }

    func testAFluxHelmReleasesObjectsByHelmsLabels() {
        let release: [String: Any] = [
            "kind": "HelmRelease", "apiVersion": "helm.toolkit.fluxcd.io/v2", "metadata": ["name": "shop", "namespace": "flux-system"],
            "spec": [
                "targetNamespace": "shop",
                "chart": ["spec": ["chart": "shop", "version": "1.2.x", "sourceRef": ["kind": "HelmRepository", "name": "acme"]]],
            ],
            "status": ["conditions": [["type": "Ready", "status": "True"]], "history": [["chartName": "shop", "chartVersion": "1.2.3"]]],
        ]
        let reads = KubeTree.reads(.fluxHelmRelease, object: release)
        XCTAssertEqual(reads.map(\.what), [.deployments, .statefulSets, .daemonSets, .services])
        XCTAssertTrue(reads.allSatisfy { $0.namespace == "shop" && $0.labelSelector == "helm.toolkit.fluxcd.io/name=shop,helm.toolkit.fluxcd.io/namespace=flux-system" })
        var read = KubeTreeRead(root: Self.data(release))
        read.add(
            reads[0],
            body: Self.list([
                ["metadata": Self.meta("web"), "spec": ["replicas": 2], "status": ["observedGeneration": 0, "readyReplicas": 2, "updatedReplicas": 2, "availableReplicas": 2, "replicas": 2]]
            ]))
        read.add(reads[3], body: Self.list([Self.service("web", selector: ["app": "web"])]))
        let tree = KubeTree.build(.fluxHelmRelease, read: read)
        XCTAssertEqual(tree.root.health, .good)
        XCTAssertEqual(tree.root.how, "shop 1.2.3")
        XCTAssertEqual(tree.root.children.first?.kind, "HelmRepository")
        XCTAssertEqual(tree.root.children.first?.namespace, "flux-system")
        XCTAssertEqual(tree.root.children.filter { $0.relation == .manages }.map { "\($0.kind) \($0.name)" }, ["Deployment web", "Service web"])
        XCTAssertEqual(node(tree, "Deployment", "web")?.health, .good)
        let empty = KubeTree.build(.fluxHelmRelease, read: KubeTreeRead(root: Self.data(release)))
        XCTAssertTrue(empty.notes.contains { $0.contains("carries its Helm labels") })
    }

    /// A Kustomization or a HelmRelease applying to another cluster
    /// (`spec.kubeConfig`): said, its objects listed but not opened — a
    /// verb would reach this cluster's same-named one —, a HelmRelease's
    /// labels not read here.
    func testFluxDeployingToAnotherClusterOpensNothingThere() {
        let remote: [String: Any] = ["secretRef": ["name": "acme-prod-kubeconfig"]]
        let kustomization: [String: Any] = [
            "kind": "Kustomization", "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "metadata": ["name": "shop", "namespace": "flux-system"],
            "spec": ["path": "./deploy", "kubeConfig": remote, "sourceRef": ["kind": "GitRepository", "name": "shop"]],
            "status": ["inventory": ["entries": [["id": "shop_web_apps_Deployment", "v": "v1"]]]],
        ]
        let tree = KubeTree.build(.fluxKustomization, read: KubeTreeRead(root: Self.data(kustomization)))
        let managed = tree.root.children.filter { $0.relation == .manages }
        XCTAssertEqual(managed.map(\.name), ["web"], "listed as Flux says")
        XCTAssertTrue(managed.allSatisfy { $0.link == nil }, "not opened here")
        XCTAssertNotNil(tree.root.children.first { $0.relation == .source }?.link, "its source is here")
        XCTAssertTrue(tree.notes.contains { $0.contains("another cluster through spec.kubeConfig.secretRef acme-prod-kubeconfig") }, "\(tree.notes)")

        let release: [String: Any] = [
            "kind": "HelmRelease", "apiVersion": "helm.toolkit.fluxcd.io/v2", "metadata": ["name": "shop", "namespace": "flux-system"],
            "spec": ["kubeConfig": remote, "chart": ["spec": ["chart": "shop", "sourceRef": ["kind": "HelmRepository", "name": "acme"]]]],
        ]
        XCTAssertEqual(KubeTree.reads(.fluxHelmRelease, object: release), [], "its objects aren't in this cluster")
        let helm = KubeTree.build(.fluxHelmRelease, read: KubeTreeRead(root: Self.data(release)))
        XCTAssertFalse(helm.root.children.contains { $0.relation == .manages })
        XCTAssertTrue(helm.notes.contains { $0.contains("another cluster through spec.kubeConfig.secretRef acme-prod-kubeconfig") }, "\(helm.notes)")
        XCTAssertFalse(helm.notes.contains { $0.contains("carries its Helm labels") })
    }

    // MARK: Against the fake

    private func startFake() throws -> (FakeKubeAPI, KubeClient) {
        let socket = "/tmp/ottr-\(UInt32.random(in: 0...UInt32.max)).sock"
        self.socket = socket
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        self.api = api
        api.addNamespace("shop")
        api.addNamespace("other")
        return (api, KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")))
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The fake's shop: a Deployment `web` using a ConfigMap that isn't
    /// there and a Secret that is (its value never read), its ReplicaSet
    /// and pods, a Service selecting them and one selecting nothing, an
    /// Ingress to the first; another namespace's look-alikes.
    private func seed(_ api: FakeKubeAPI) {
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "2/2", "Up-to-date": 2, "Available": 2],
            fields: [
                "spec": [
                    "replicas": 2, "selector": ["matchLabels": ["app": "web"]],
                    "template": [
                        "metadata": ["labels": ["app": "web"]],
                        "spec": [
                            "containers": [
                                [
                                    "name": "app", "image": "nginx:1.27", "envFrom": [["configMapRef": ["name": "web-env"]]],
                                    "env": [["name": "DB_PASSWORD", "valueFrom": ["secretKeyRef": ["name": "web-db", "key": "password"]]]],
                                ]
                            ]
                        ],
                    ],
                ],
                "status": ["observedGeneration": 0, "replicas": 2, "readyReplicas": 2, "updatedReplicas": 2, "availableReplicas": 2],
            ])
        let deployUID = api.uid("deployments.apps", "web", namespace: "shop")!
        api.add(
            "replicasets.apps", "web-7d9", namespace: "shop", labels: ["app": "web"],
            annotations: ["deployment.kubernetes.io/revision": "1"],
            fields: [
                "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "uid": deployUID, "controller": true]]],
                "spec": ["replicas": 2], "status": ["replicas": 2, "readyReplicas": 2],
            ])
        let setUID = api.uid("replicasets.apps", "web-7d9", namespace: "shop")!
        for (name, status) in [("web-7d9-a", "Running"), ("web-7d9-b", "CrashLoopBackOff")] {
            var pod = FakeKubeAPI.Pod(status: status)
            if status != "Running" { pod.ready = 0 }
            api.addPod(name, namespace: "shop", pod, labels: ["app": "web"])
            api.setFields(
                "pods", name, namespace: "shop",
                ["metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-7d9", "uid": setUID, "controller": true]]]])
        }
        api.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], data: ["password": Self.secretValue])
        api.add("services", "web", namespace: "shop", fields: ["spec": ["selector": ["app": "web"], "ports": [["port": 80, "protocol": "TCP"]]]])
        api.add("services", "idle", namespace: "shop", fields: ["spec": ["selector": ["app": "nobody"], "ports": [["port": 80, "protocol": "TCP"]]]])
        api.add(
            "ingresses.networking.k8s.io", "web", namespace: "shop",
            fields: ["spec": ["rules": [["host": "shop.acme.example", "http": ["paths": [["path": "/", "backend": ["service": ["name": "web", "port": ["number": 80]]]]]]]]]])
        api.add("configmaps", "web-env", namespace: "other")
    }

    private static let deployments = KubeResourceKind(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true, verbs: ["get", "list"])
    private static let services = KubeResourceKind(
        group: "", version: "v1", resource: "services", kind: "Service", singular: "service", namespaced: true, verbs: ["get", "list"])

    func testTheOverviewReadsItsTreeOnceNamesOnlyNoWatch() async throws {
        let (api, client) = try startFake()
        seed(api)
        let ref = KubeObjectRef(context: "fake-dev", kind: Self.deployments, namespace: "shop", name: "web")
        let detail = KubeDetailSession(ref: ref, client: client)
        guard let session = detail.tree else { return XCTFail("a Deployment's tree") }
        api.forgetRequests()
        detail.showTree()
        detail.load()
        let read = await eventually { session.state == .loaded }
        XCTAssertTrue(read, "\(session.state)")
        guard let tree = session.tree else { return XCTFail("built") }
        XCTAssertEqual(tree.notes, [])
        XCTAssertEqual(node(tree, "ReplicaSet", "web-7d9")?.children.map(\.name), ["web-7d9-a", "web-7d9-b"])
        XCTAssertEqual(node(tree, "Pod", "web-7d9-b")?.health, .bad)
        XCTAssertEqual(node(tree, "ConfigMap", "web-env")?.health, .missing, "another namespace's doesn't count")
        XCTAssertEqual(node(tree, "Secret", "web-db")?.health, .good)
        XCTAssertEqual(node(tree, "Secret", "web-db")?.status, "Opaque")
        XCTAssertEqual(node(tree, "Service", "web")?.children.map(\.kind), ["Ingress"])
        XCTAssertNil(node(tree, "Service", "idle"), "it doesn't select its pods")
        XCTAssertFalse(String(describing: tree).contains(Self.secretValue))

        let paths = api.requests.map(\.path)
        XCTAssertTrue(
            paths.allSatisfy { $0.hasPrefix("/apis/apps/v1/namespaces/shop/") || $0.hasPrefix("/api/v1/namespaces/shop/") || $0.hasPrefix("/apis/networking.k8s.io/v1/namespaces/shop/") }, "\(paths)")
        let secrets = api.requests.filter { $0.path == "/api/v1/namespaces/shop/secrets" }
        XCTAssertEqual(secrets.count, 1)
        XCTAssertTrue(secrets.first?.accept.contains("as=Table") == true, "the Secret list's Table")
        XCTAssertEqual(secrets.first?.query["includeObject"], "None", "names only")
        XCTAssertEqual(api.requests.first { $0.path == "/api/v1/namespaces/shop/pods" }?.query["labelSelector"], "app=web")
        XCTAssertTrue(api.requests.filter { $0.path.hasSuffix("/pods") || $0.path.hasSuffix("/services") }.allSatisfy { $0.query["limit"] != nil }, "bounded")
        XCTAssertFalse(paths.contains { $0.contains("httproutes") }, "not served: not asked")

        // Once: the Overview shown again reads nothing.
        api.forgetRequests()
        detail.showTree()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.requests.count, 0)
        // Refresh reads again.
        detail.showTree(again: true)
        let again = await eventually { session.state == .loaded && !api.requests.isEmpty }
        XCTAssertTrue(again)

        detail.cancel()
        XCTAssertNil(session.tree, "dropped with the detail")
    }

    /// A proxy that answers a Secret list whole, ignoring the Accept: the
    /// tree asked for a Table and nothing else, says it couldn't read one,
    /// and no value reaches it.
    func testASecretListAnsweredWholeReachesNothing() async throws {
        let (api, client) = try startFake()
        seed(api)
        api.ignoresTables = ["secrets"]
        let detail = KubeDetailSession(ref: KubeObjectRef(context: "fake-dev", kind: Self.deployments, namespace: "shop", name: "web"), client: client)
        guard let session = detail.tree else { return XCTFail("a Deployment's tree") }
        detail.showTree()
        detail.load()
        let read = await eventually { session.state == .loaded }
        XCTAssertTrue(read, "\(session.state)")
        guard let tree = session.tree else { return XCTFail("built") }
        let secrets = api.requests.filter { $0.path == "/api/v1/namespaces/shop/secrets" }
        XCTAssertEqual(secrets.map(\.accept), ["application/json;as=Table;v=v1;g=meta.k8s.io"], "a Table and nothing else")
        XCTAssertEqual(node(tree, "Secret", "web-db")?.health, .unknown, "not checked, not missing")
        XCTAssertTrue(tree.notes.contains { $0.contains("couldn't be read as a Table") }, "\(tree.notes)")
        XCTAssertFalse(String(describing: tree).contains(Self.secretValue))
        XCTAssertFalse(String(describing: tree).contains(Data(Self.secretValue.utf8).base64EncodedString()))
    }

    func testAServicesTreeAgainstTheFake() async throws {
        let (api, client) = try startFake()
        seed(api)
        let detail = KubeDetailSession(ref: KubeObjectRef(context: "fake-dev", kind: Self.services, namespace: "shop", name: "idle"), client: client)
        detail.load()
        detail.showTree()
        guard let session = detail.tree else { return XCTFail("a Service's tree") }
        let read = await eventually { session.state == .loaded }
        XCTAssertTrue(read, "\(session.state)")
        XCTAssertEqual(session.tree?.root.health, .bad)
        XCTAssertEqual(session.tree?.root.status, "selects no pod")
    }

    func testArgoAndFluxTreesFromTheirCRDs() async throws {
        let (api, client) = try startFake()
        api.addCRD(group: "argoproj.io", version: "v1alpha1", plural: "applications", kind: "Application", shortNames: ["app"])
        api.addCRD(group: "helm.toolkit.fluxcd.io", version: "v2", plural: "helmreleases", kind: "HelmRelease", shortNames: ["hr"])
        api.add(
            "applications.argoproj.io", "shop", namespace: "shop",
            fields: [
                "spec": ["destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"]],
                "status": [
                    "sync": ["status": "Synced"], "health": ["status": "Healthy"],
                    "resources": [["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "web", "status": "Synced", "health": ["status": "Healthy"]]],
                ],
            ])
        api.add(
            "helmreleases.helm.toolkit.fluxcd.io", "shop", namespace: "shop",
            fields: ["spec": ["chart": ["spec": ["chart": "shop", "sourceRef": ["kind": "HelmRepository", "name": "acme"]]]], "status": ["conditions": [["type": "Ready", "status": "True"]]]])
        api.add(
            "deployments.apps", "web", namespace: "shop", labels: [KubeTree.fluxHelmName: "shop", KubeTree.fluxHelmNamespace: "shop"],
            fields: ["spec": ["replicas": 1], "status": ["observedGeneration": 0, "replicas": 1, "readyReplicas": 1, "updatedReplicas": 1, "availableReplicas": 1]])
        api.add("deployments.apps", "unlabelled", namespace: "shop")
        let discovery = try await client.discover()
        guard let applications = discovery.kind("applications"), let releases = discovery.kind("helmreleases") else { return XCTFail("served") }

        api.forgetRequests()
        let argo = KubeDetailSession(ref: KubeObjectRef(context: "fake-dev", kind: applications, namespace: "shop", name: "shop"), client: client, discovery: discovery)
        argo.load()
        argo.showTree()
        let argoRead = await eventually { argo.tree?.state == .loaded }
        XCTAssertTrue(argoRead)
        XCTAssertEqual(api.requests.map(\.path), ["/apis/argoproj.io/v1alpha1/namespaces/shop/applications/shop"], "its own object, nothing else")
        XCTAssertEqual(argo.tree?.tree?.root.children.map(\.name), ["web"])

        api.forgetRequests()
        let flux = KubeDetailSession(ref: KubeObjectRef(context: "fake-dev", kind: releases, namespace: "shop", name: "shop"), client: client, discovery: discovery)
        flux.load()
        flux.showTree()
        let fluxRead = await eventually { flux.tree?.state == .loaded }
        XCTAssertTrue(fluxRead)
        XCTAssertEqual(flux.tree?.tree?.root.children.filter { $0.relation == .manages }.map(\.name), ["web"], "only what carries Helm's labels")
        XCTAssertTrue(
            api.requests.filter { $0.path.hasSuffix("/deployments") }.allSatisfy {
                $0.query["labelSelector"] == "\(KubeTree.fluxHelmName)=shop,\(KubeTree.fluxHelmNamespace)=shop"
            })
    }

    // MARK: The page

    /// `x` on a Deployment: its Overview, the tree read; a node's verbs are
    /// its object's — Open first, a pod's Port-forward… among them — and
    /// Open shows its detail.
    func testXOpensTheTreeAndNodesHaveVerbs() async throws {
        let (api, _) = try startFake()
        seed(api)
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: ["fake-dev"].map { KubeWritesTests.context($0) }, current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        var copied: [String] = []
        page.actions = KubernetesActions(run: { _ in }, settings: {}, copy: { copied.append($0) }, copySecret: { _ in })
        model.show()
        defer { model.hide() }
        let served = await eventually { model.discovery?.kind("deployments") != nil }
        XCTAssertTrue(served)
        guard let deployments = model.discovery?.kind("deployments") else { return }
        model.setScope(.namespace("shop"))
        page.showKind(deployments)
        let listed = await eventually { model.rows[KubeRowID(namespace: "shop", name: "web")] != nil }
        XCTAssertTrue(listed)
        pageWatches = true
        api.forgetRequests()
        page.selection = ["shop/web"]
        page.detailTab = .events
        let revealed = page.revealTree
        XCTAssertTrue(page.press("x"), "x")
        XCTAssertEqual(page.detailTab, .overview)
        XCTAssertEqual(page.revealTree, revealed + 1)
        guard let session = page.detail?.tree else { return XCTFail("its tree") }
        let read = await eventually { session.state == .loaded }
        XCTAssertTrue(read, "\(session.state)")
        guard let tree = session.tree, let pod = node(tree, "Pod", "web-7d9-a"), let container = pod.children.first else { return XCTFail("its pods") }
        let verbs = page.treeVerbs(for: pod)
        XCTAssertEqual(verbs.first?.title, "Open")
        XCTAssertTrue(verbs.contains { $0.title == "Port-forward…" }, "\(verbs.map(\.title))")
        XCTAssertEqual(verbs.last?.title, "Copy as kubectl")
        verbs.last?.perform()
        XCTAssertEqual(copied.last, "kubectl --context fake-dev -n shop get po web-7d9-a -o yaml")
        XCTAssertEqual(page.treeVerbs(for: container).count, 0, "a container has none")

        // Drawn, the tree asks nothing: a node's verbs (and their can-i and
        // access reviews) are made only as its menu opens.
        let asked = (model.access.asked, model.writeAccess.asked)
        let theme = ChromeTheme(background: .black, foreground: .white)
        let host = NSHostingView(rootView: KubeTreeView(page: page, tree: session, theme: theme).frame(width: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        model.objectWillChange.send()
        page.objectWillChange.send()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.access.asked, asked.0, "drawing the tree runs no kubectl auth can-i")
        XCTAssertEqual(model.writeAccess.asked, asked.1, "nor any access review")
        func menus(in view: NSView) -> [ResourceVerbMenuView] { view.subviews.flatMap { ($0 as? ResourceVerbMenuView).map { [$0] } ?? menus(in: $0) } }
        let areas = menus(in: host)
        XCTAssertFalse(areas.isEmpty, "a node's menu is there to open")
        if let area = areas.first,
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)
        {
            XCTAssertEqual(area.menu(for: event)?.items.first?.title, "Open", "made as it opens")
        }
        XCTAssertTrue(ResourceVerbMenuView.opensMenu(.rightMouseDown, []))
        XCTAssertTrue(ResourceVerbMenuView.opensMenu(.leftMouseDown, .control))
        XCTAssertFalse(ResourceVerbMenuView.opensMenu(.leftMouseDown, []), "a press goes to the name's link")
        window.contentView = nil
        verbs.first?.perform()
        XCTAssertEqual(page.detail?.ref.name, "web-7d9-a")
        XCTAssertEqual(page.detail?.ref.kind.resource, "pods")
        XCTAssertTrue(page.history.canGoBack, "back to the Deployment")
        XCTAssertFalse(page.press("x") && page.detail?.tree == nil)
        XCTAssertTrue(
            api.requests.filter { $0.query["watch"] != nil }.allSatisfy { $0.path == "/apis/apps/v1/namespaces/shop/deployments" },
            "the tree opens no watch: \(api.requests.filter { $0.query["watch"] != nil }.map(\.path))")
    }
}
