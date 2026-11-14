import Foundation
import XCTest

@testable import Overterm

/// A workload's change timeline (docs/design/kubernetes/analysis.md, 3.6,
/// stage 3b): template revisions read from ReplicaSets and
/// ControllerRevisions owned by the workload — images, template paths, a
/// restart, a rollback —, Helm revisions, scaling and warnings joined
/// newest first and bounded; the diffs a change opens stripped and masked
/// together (a secret env value that changed is `*** (before)` /
/// `*** (after)`, never itself); and against `FakeKubeAPI` on a socket of
/// the test's own, the History tab's reads — one bounded list by the
/// selector, the events, Helm's records by their metadata, two records
/// read only for a Helm diff — all GETs. Nothing reads ~/.kube.
@MainActor
final class KubeTimelineTests: XCTestCase {
    private static let oldPassword = "acme-timeline-pw-old-R4q"
    private static let newPassword = "acme-timeline-pw-new-Z8w"
    nonisolated(unsafe) private var api: FakeKubeAPI?
    nonisolated(unsafe) private var socket: String?

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "reads only")
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }, [], "only GETs")
            api.stop()
        }
    }

    // MARK: Fixtures

    private static let deploymentUID = "uid-deploy-web"

    private func replicaSet(
        _ name: String, revision: Int, image: String, env: [String: String] = [:], restartedAt: String? = nil, history: String? = nil,
        owner: String = deploymentUID, created: String
    ) -> [String: Any] {
        var annotations = [KubeTimeline.revisionAnnotation: String(revision)]
        if let history { annotations[KubeTimeline.historyAnnotation] = history }
        var templateMetadata: [String: Any] = ["labels": ["app": "web", "pod-template-hash": String(name.suffix(4))], "creationTimestamp": NSNull()]
        if let restartedAt { templateMetadata["annotations"] = [KubeTimeline.restartedAt: restartedAt] }
        return [
            "apiVersion": "apps/v1", "kind": "ReplicaSet",
            "metadata": [
                "name": name, "namespace": "shop", "creationTimestamp": created, "annotations": annotations,
                "ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "uid": owner, "controller": true]],
            ],
            "spec": [
                "replicas": 2,
                "template": [
                    "metadata": templateMetadata,
                    "spec": ["containers": [["name": "web", "image": image, "env": env.keys.sorted().map { ["name": $0, "value": env[$0]!] }]]],
                ],
            ],
        ]
    }

    private func list(_ items: [[String: Any]], continueToken: String? = nil) -> Data {
        var metadata: [String: Any] = ["resourceVersion": "10"]
        if let continueToken { metadata["continue"] = continueToken }
        return try! JSONSerialization.data(withJSONObject: ["kind": "List", "metadata": metadata, "items": items])
    }

    private var revisions: [KubeTemplateRevision] {
        KubeTimeline.revisions(
            list([
                replicaSet("web-bbbb", revision: 2, image: "nginx:1.27", env: ["DB_PASSWORD": Self.newPassword, "LOG_LEVEL": "info"], created: "2026-11-05T10:00:00Z"),
                replicaSet("web-aaaa", revision: 1, image: "nginx:1.25", env: ["DB_PASSWORD": Self.oldPassword, "LOG_LEVEL": "info"], created: "2026-11-04T10:00:00Z"),
                replicaSet(
                    "web-cccc", revision: 3, image: "nginx:1.27", env: ["DB_PASSWORD": Self.newPassword, "LOG_LEVEL": "info"], restartedAt: "2026-11-06T09:00:00Z",
                    created: "2026-11-06T09:00:00Z"),
                replicaSet("other-dddd", revision: 9, image: "busybox", owner: "uid-someone-else", created: "2026-11-06T11:00:00Z"),
            ]), source: .replicaSets, owner: Self.deploymentUID
        ).revisions
    }

    // MARK: Reading revisions

    func testReplicaSetsOwnedByTheWorkloadOldestFirst() {
        let read = revisions
        XCTAssertEqual(read.map(\.revision), [1, 2, 3], "its own, by revision; another owner's left out")
        XCTAssertEqual(read.map(\.name), ["web-aaaa", "web-bbbb", "web-cccc"])
        XCTAssertEqual(read[1].images, [KubeTemplateRevision.Image(container: "web", image: "nginx:1.27")])
        XCTAssertEqual(read[2].restartedAt, "2026-11-06T09:00:00Z")
        XCTAssertEqual(read[0].replicas, 2)
        let labels = (read[0].object["metadata"] as? [String: Any])?["labels"] as? [String: Any]
        XCTAssertEqual(labels as? [String: String], ["app": "web"], "the controller's hash label isn't a change")
        XCTAssertNil((read[0].object["metadata"] as? [String: Any])?["creationTimestamp"])
        XCTAssertFalse(KubeTimeline.revisions(list([]), source: .replicaSets, owner: "").more)
        XCTAssertTrue(KubeTimeline.revisions(list([], continueToken: "abc"), source: .replicaSets, owner: "").more, "a list cut short says so")
        XCTAssertEqual(KubeTimeline.revisions(Data("nope".utf8), source: .replicaSets, owner: "").revisions, [])
    }

    func testControllerRevisionsTemplateFromTheirData() {
        let item: [String: Any] = [
            "kind": "ControllerRevision", "revision": 4,
            "metadata": ["name": "db-6c8d", "creationTimestamp": "2026-11-05T08:00:00Z", "ownerReferences": [["uid": "uid-sts"]]],
            "data": [
                "spec": [
                    "template": [
                        "$patch": "replace", "metadata": ["labels": ["app": "db"]], "spec": ["containers": [["name": "postgres", "image": "postgres:16"]]],
                    ]
                ]
            ],
        ]
        let read = KubeTimeline.revisions(list([item]), source: .controllerRevisions, owner: "uid-sts").revisions
        XCTAssertEqual(read.map(\.revision), [4])
        XCTAssertNil(read.first?.object["$patch"], "the patch's directive isn't the template's")
        XCTAssertEqual(read.first?.images.first?.image, "postgres:16")
        XCTAssertEqual(KubeTimeline.revisions(list([item]), source: .controllerRevisions, owner: "uid-other").revisions, [])
    }

    func testWhichKindsHaveAHistory() {
        func ref(_ group: String, _ resource: String, namespace: String? = "shop") -> KubeObjectRef {
            KubeObjectRef(
                context: "fake-dev", kind: KubeResourceKind(group: group, version: "v1", resource: resource, kind: resource, singular: resource, namespaced: true, verbs: []),
                namespace: namespace, name: "x")
        }
        XCTAssertEqual(KubeTimeline.Source.of(ref("apps", "deployments")), .replicaSets)
        XCTAssertEqual(KubeTimeline.Source.of(ref("apps", "statefulsets")), .controllerRevisions)
        XCTAssertEqual(KubeTimeline.Source.of(ref("apps", "daemonsets")), .controllerRevisions)
        for (group, resource) in [("apps", "replicasets"), ("", "pods"), ("batch", "jobs"), ("example.com", "deployments")] {
            XCTAssertNil(KubeTimeline.Source.of(ref(group, resource)), "\(group)/\(resource)")
            XCTAssertFalse(KubeDetailTab.tabs(for: ref(group, resource)).contains(.history))
        }
        XCTAssertTrue(KubeDetailTab.tabs(for: ref("apps", "deployments")).contains(.history))
        XCTAssertEqual(KubeTimeline.Source.replicaSets.path(namespace: "shop"), "/apis/apps/v1/namespaces/shop/replicasets")
        XCTAssertEqual(KubeTimeline.Source.controllerRevisions.path(namespace: "shop"), "/apis/apps/v1/namespaces/shop/controllerrevisions")
        let object: [String: Any] = ["metadata": ["annotations": [KubeTimeline.helmRelease: "web", KubeTimeline.helmNamespace: "shop"]]]
        XCTAssertEqual(KubeTimeline.helmRelease(of: object)?.name, "web")
        XCTAssertNil(KubeTimeline.helmRelease(of: ["metadata": [:]]))
    }

    // MARK: What changed

    func testWhatChangedSaidWithoutAValue() {
        let read = revisions
        let first = KubeTimeline.summary(from: nil, to: read[0])
        XCTAssertEqual(first.kind, .revision)
        XCTAssertEqual(first.detail, "web: nginx:1.25")
        let image = KubeTimeline.summary(from: read[0], to: read[1])
        XCTAssertEqual(image.kind, .revision)
        XCTAssertEqual(image.title, "Revision 2: image changed")
        XCTAssertTrue(image.detail?.hasPrefix("web: nginx:1.25 → nginx:1.27") == true, image.detail ?? "")
        XCTAssertTrue(image.detail?.contains("env[DB_PASSWORD].value") == true, "the env entry named, \(image.detail ?? "")")
        XCTAssertFalse(image.detail?.contains(Self.newPassword) == true, "never its value")
        let restart = KubeTimeline.summary(from: read[1], to: read[2])
        XCTAssertEqual(restart.kind, .restart, "only restartedAt changed: a rollout restart")
        XCTAssertEqual(restart.title, "Restarted: revision 3")
        var rolledBack = read[0]
        rolledBack.revision = 4
        rolledBack.reused = [1]
        let rollback = KubeTimeline.summary(from: read[2], to: rolledBack)
        XCTAssertEqual(rollback.kind, .rollback)
        XCTAssertTrue(rollback.detail?.contains("revision 1") == true, rollback.detail ?? "")
        XCTAssertEqual(
            KubeTimeline.changedPaths(
                ["spec": ["containers": [["name": "web", "resources": ["limits": ["memory": "1Gi"]]]]]], ["spec": ["containers": [["name": "web", "resources": ["limits": ["memory": "2Gi"]]]]]],
                path: ""),
            ["spec.containers[web].resources.limits.memory"])
    }

    func testTheTimelineNewestFirstAndBounded() {
        let day = { (text: String) in KubeTime.date(text)! }
        var read = revisions
        // Revision 4: revision 1's template again — its ReplicaSet is the old one.
        var again = read[0]
        again.revision = 4
        again.reused = [1]
        read[0] = again
        let records = [
            KubeHelmRecord(storage: .secret, namespace: "shop", object: "sh.helm.release.v1.web.v1", release: "web", revision: 1, status: "superseded", updated: day("2026-11-04T09:59:00Z")),
            KubeHelmRecord(storage: .secret, namespace: "shop", object: "sh.helm.release.v1.web.v2", release: "web", revision: 2, status: "deployed", updated: day("2026-11-05T09:59:00Z")),
        ]
        let events = [
            KubeEvent(id: "e1", type: "Normal", reason: "ScalingReplicaSet", message: "Scaled up replica set web-cccc from 2 to 3", last: day("2026-11-06T10:00:00Z")),
            KubeEvent(id: "e2", type: "Warning", reason: "FailedCreate", message: "exceeded quota", count: 4, last: day("2026-11-06T10:05:00Z")),
            KubeEvent(id: "e3", type: "Normal", reason: "SuccessfulCreate", message: "Created pod web-cccc-x", last: day("2026-11-06T10:06:00Z")),
        ]
        let (entries, cut) = KubeTimeline.entries(revisions: read, helm: records, events: events)
        XCTAssertEqual(cut, 0)
        XCTAssertEqual(
            entries.map(\.id), ["event/e2", "event/e1", "revision/4", "revision/3", "revision/2", "helm/2", "helm/1"],
            "newest first; an event that changes nothing left out")
        XCTAssertEqual(entries.first?.kind, .warning)
        XCTAssertEqual(entries.first?.count, 4)
        XCTAssertEqual(entries[1].kind, .scale)
        let rollback = entries.first { $0.id == "revision/4" }
        XCTAssertEqual(rollback?.kind, .rollback)
        XCTAssertTrue(rollback?.approximate == true, "a rolled-back revision's object is older than the change: placed after the one before")
        XCTAssertEqual(rollback?.time, day("2026-11-06T09:00:00Z"))
        XCTAssertEqual(rollback?.change, .template(from: 3, to: 4))
        XCTAssertEqual(entries.first { $0.id == "revision/2" }?.change, .template(from: nil, to: 2), "the oldest kept, against nothing")
        XCTAssertEqual(entries.first { $0.id == "helm/2" }?.change, .helm(from: 1, to: 2))
        XCTAssertEqual(entries.first { $0.id == "helm/1" }?.change, .helm(from: nil, to: 1))
        XCTAssertNil(entries.first?.change, "a warning opens no diff")
        let capped = KubeTimeline.entries(revisions: read, helm: records, events: events, limit: 3)
        XCTAssertEqual(capped.entries.count, 3)
        XCTAssertEqual(capped.cut, 4)

        // A rollout's scaling is a rollout's step, not a change of replicas.
        let rollout = [
            KubeEvent(id: "r1", type: "Normal", reason: "ScalingReplicaSet", message: "Scaled up replica set web-cccc from 0 to 1", last: day("2026-11-06T09:00:00Z")),
            KubeEvent(id: "r2", type: "Normal", reason: "ScalingReplicaSet", message: "Scaled down replica set web-bbbb from 2 to 1", last: day("2026-11-06T09:00:30Z")),
            KubeEvent(id: "r3", type: "Normal", reason: "ScalingReplicaSet", message: "Scaled up replica set web-cccc from 2 to 5", last: day("2026-11-06T12:00:00Z")),
            KubeEvent(id: "r4", type: "Normal", reason: "SuccessfulRescale", message: "New size: 5; reason: cpu resource utilization", last: day("2026-11-06T12:00:00Z")),
        ]
        let steps = KubeTimeline.entries(revisions: revisions, helm: [], events: rollout).entries.filter { $0.kind == .scale }
        XCTAssertEqual(steps.map(\.id), ["event/r3", "event/r2", "event/r1"], "the HPA's event is the HPA's, never the workload's")
        XCTAssertEqual(steps.map(\.title), ["Scaled", "Rollout step", "Rollout step"])

        // A StatefulSet says its scaling pod by pod.
        let statefulSet = [
            KubeEvent(id: "s1", type: "Normal", reason: "SuccessfulCreate", message: "create Pod db-2 in StatefulSet db successful", last: day("2026-11-06T11:00:00Z")),
            KubeEvent(id: "s2", type: "Normal", reason: "SuccessfulDelete", message: "delete Pod db-2 in StatefulSet db successful", last: day("2026-11-06T12:00:00Z")),
            KubeEvent(id: "s3", type: "Normal", reason: "ScalingReplicaSet", message: "Scaled up replica set db-x to 1", last: day("2026-11-06T12:30:00Z")),
        ]
        let db = KubeTimeline.entries(revisions: [], helm: [], events: statefulSet, kind: "StatefulSet").entries
        XCTAssertEqual(db.map(\.kind), [.scale, .scale])
        XCTAssertEqual(db.map(\.title), ["Pod deleted: db-2", "Pod created: db-2"])
        XCTAssertEqual(
            KubeTimeline.entries(revisions: [], helm: [], events: statefulSet, kind: "Deployment").entries.map(\.id), ["event/s3"],
            "a Deployment's scaling is its ReplicaSets', not pods one by one")

        // A warning about what it owns says which.
        let owned = KubeEvent(
            id: "w1", type: "Warning", reason: "FailedCreate", message: "exceeded quota", last: day("2026-11-06T12:00:00Z"), objectKind: "ReplicaSet", object: "web-cccc")
        XCTAssertEqual(KubeTimeline.entries(revisions: [], helm: [], events: [owned]).entries.first?.detail, "replicaset/web-cccc: exceeded quota")
    }

    func testWarningsOfWhatItOwns() {
        func event(_ kind: String, _ name: String) -> KubeEvent {
            KubeEvent(id: name, type: "Warning", reason: "BackOff", message: "", objectKind: kind, object: name)
        }
        let replicaSets: Set = ["web-7d9f8c", "web-5c6b4d"]
        XCTAssertTrue(KubeTimeline.owns(event("ReplicaSet", "web-7d9f8c"), kind: "Deployment", name: "web", replicaSets: replicaSets))
        XCTAssertFalse(KubeTimeline.owns(event("ReplicaSet", "api-7d9f8c"), kind: "Deployment", name: "web", replicaSets: replicaSets))
        XCTAssertTrue(KubeTimeline.owns(event("Pod", "web-7d9f8c-x2k9p"), kind: "Deployment", name: "web", replicaSets: replicaSets))
        XCTAssertFalse(KubeTimeline.owns(event("Pod", "web-7d9f8c-extra-x2k9p"), kind: "Deployment", name: "web", replicaSets: replicaSets))
        XCTAssertFalse(KubeTimeline.owns(event("Pod", "web-x2k9p"), kind: "Deployment", name: "web", replicaSets: replicaSets), "not one of its ReplicaSets'")
        XCTAssertTrue(KubeTimeline.owns(event("Pod", "db-2"), kind: "StatefulSet", name: "db", replicaSets: []))
        XCTAssertFalse(KubeTimeline.owns(event("Pod", "db-backup-2"), kind: "StatefulSet", name: "db", replicaSets: []))
        XCTAssertTrue(KubeTimeline.owns(event("Pod", "agent-q7z4m"), kind: "DaemonSet", name: "agent", replicaSets: []))
        XCTAssertFalse(KubeTimeline.owns(event("Pod", "agent-2"), kind: "DaemonSet", name: "agent", replicaSets: []))
        XCTAssertFalse(KubeTimeline.owns(event("ReplicaSet", "agent-q7z4m"), kind: "DaemonSet", name: "agent", replicaSets: ["agent-q7z4m"]))
    }

    // MARK: The diffs

    func testATemplateDiffMasksTogether() {
        let read = revisions
        let item = KubeTimeline.templateDiff(kind: "Deployment", name: "web", namespace: "shop", from: read[0], to: read[1])
        XCTAssertEqual(item.change, .modified)
        XCTAssertTrue(item.diff.contains("-") && item.diff.contains("nginx:1.25") && item.diff.contains("nginx:1.27"), item.diff)
        XCTAssertTrue(item.diff.contains("(before)") && item.diff.contains("(after)"), "a secret env value that changed says so: \(item.diff)")
        XCTAssertFalse(item.diff.contains(Self.oldPassword) || item.diff.contains(Self.newPassword), "never itself")
        XCTAssertTrue(item.diff.contains("--- revision 1/deployment-web-template.yaml"), item.diff)
        XCTAssertFalse(item.diff.contains("pod-template-hash"), "the controller's label isn't diffed")
        let first = KubeTimeline.templateDiff(kind: "Deployment", name: "web", namespace: "shop", from: nil, to: read[0])
        XCTAssertEqual(first.change, .added)
        XCTAssertFalse(first.diff.contains(Self.oldPassword))
        let restart = KubeTimeline.templateDiff(kind: "Deployment", name: "web", namespace: "shop", from: read[1], to: read[2])
        XCTAssertTrue(restart.diff.contains("restartedAt"), restart.diff)
        XCTAssertFalse(restart.diff.contains("(before)"), "an unchanged secret is *** on both sides")
    }

    func testHelmValuesMaskedTogether() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let (before, after) = KubeTimeline.helmValues(
            before: ["auth": ["password": Self.oldPassword], "apiToken": "same-token-value", "image": ["tag": "1.25"], "port": 8080, "env": [["name": "DB_PASSWORD", "value": "x1"]]],
            after: [
                "auth": ["password": Self.newPassword], "apiToken": "same-token-value", "image": ["tag": "1.27"], "port": 8080, "note": "uses \(token)",
                "env": [["name": "DB_PASSWORD", "value": "x2"]],
            ])
        XCTAssertTrue(before.contains("password: \"*** (before)\""), before)
        XCTAssertTrue(after.contains("password: \"*** (after)\""), after)
        XCTAssertTrue(before.contains("apiToken: \"***\"") && after.contains("apiToken: \"***\""), "unchanged: the same mask")
        XCTAssertTrue(before.contains("tag: \"1.25\"") && after.contains("tag: \"1.27\""), "what isn't secret shows")
        XCTAssertTrue(after.contains("value: \"*** (after)\""), "a secret-named env entry's value: \(after)")
        for text in [before, after] {
            XCTAssertFalse(text.contains(Self.oldPassword) || text.contains(Self.newPassword) || text.contains("same-token-value") || text.contains(token), text)
        }
        XCTAssertEqual(KubeTimeline.helmValues(before: nil, after: ["a": "b"]).before, "", "the first revision: against nothing")
    }

    func testTwoHelmRevisionsDiffed() {
        func inputs(_ revision: Int, password: String, replicas: Int) -> KubeHelm.UpgradeInputs {
            let values = try! JSONSerialization.data(withJSONObject: ["auth": ["password": password], "replicaCount": replicas])
            let manifest = """
                ---
                # Source: web/templates/secret.yaml
                apiVersion: v1
                kind: Secret
                metadata:
                  name: web-auth
                data:
                  password: \(Data(password.utf8).base64EncodedString())
                ---
                # Source: web/templates/deployment.yaml
                apiVersion: apps/v1
                kind: Deployment
                metadata:
                  name: web
                spec:
                  replicas: \(replicas)
                """
            return KubeHelm.UpgradeInputs(values: values, manifest: manifest, revision: revision, chart: KubeHelmChart(chart: "web", version: "1.0.0"))
        }
        let diff = KubeTimeline.helmDiff(release: "web", namespace: "shop", from: inputs(1, password: Self.oldPassword, replicas: 1), to: inputs(2, password: Self.newPassword, replicas: 3))
        XCTAssertEqual(diff.items.map(\.id), ["values", "Secret/shop/web-auth", "Deployment/shop/web"])
        XCTAssertTrue(diff.items.allSatisfy { $0.change == .modified }, "\(diff.items.map(\.change))")
        XCTAssertTrue(diff.items[0].diff.contains("--- revision 1/values.yaml") && diff.items[0].diff.contains("+++ revision 2/values.yaml"))
        XCTAssertTrue(diff.items[2].diff.contains("-  replicas: 1") && diff.items[2].diff.contains("+  replicas: 3"), diff.items[2].diff)
        for item in diff.items {
            for secret in [Self.oldPassword, Self.newPassword, Data(Self.oldPassword.utf8).base64EncodedString(), Data(Self.newPassword.utf8).base64EncodedString()] {
                XCTAssertFalse(item.diff.contains(secret), "\(item.id): \(item.diff)")
            }
        }
        XCTAssertTrue(diff.items[1].diff.contains("(before)"), "a Secret's value that changed says so")
        XCTAssertEqual(diff.secrets, 1)
        let first = KubeTimeline.helmDiff(release: "web", namespace: "shop", from: nil, to: inputs(1, password: Self.oldPassword, replicas: 1))
        XCTAssertTrue(first.items.allSatisfy { $0.change == .added }, "\(first.items.map(\.change))")
    }

    // MARK: Against the fake

    private func startFake() throws -> (FakeKubeAPI, KubeClient) {
        let socket = "/tmp/ottl-\(UInt32.random(in: 0...UInt32.max)).sock"
        self.socket = socket
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        self.api = api
        api.addNamespace("shop")
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

    private static let deployments = KubeResourceKind(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true, verbs: ["get", "list"])

    func testTheHistoryTabReadsOnlyWhatItShows() async throws {
        let (api, client) = try startFake()
        api.add(
            "deployments.apps", "web", namespace: "shop", annotations: [KubeTimeline.helmRelease: "web", KubeTimeline.helmNamespace: "shop"],
            fields: ["spec": ["replicas": 2, "selector": ["matchLabels": ["app": "web"]]]])
        let now = Date()
        api.addRevision(
            of: "web", namespace: "shop", name: "web-aaaa", revision: 1, image: "nginx:1.25", env: ["DB_PASSWORD": Self.oldPassword], labels: ["app": "web"], created: now.addingTimeInterval(-7200))
        api.addRevision(
            of: "web", namespace: "shop", name: "web-bbbb", revision: 2, image: "nginx:1.27", env: ["DB_PASSWORD": Self.newPassword], labels: ["app": "web"], created: now.addingTimeInterval(-3600))
        api.addRevision(of: "web", namespace: "shop", name: "api-cccc", revision: 1, image: "api:1", labels: ["app": "api"])
        api.addEvent(about: "deployments.apps", "web", namespace: "shop", reason: "ScalingReplicaSet", message: "Scaled up replica set web-bbbb from 1 to 2", component: "deployment-controller")
        // What a real cluster says: the quota's refusal on the ReplicaSet,
        // a crash loop on its pod — not on the Deployment.
        api.addEvent(
            about: "replicasets.apps", "web-bbbb", namespace: "shop", type: "Warning", reason: "FailedCreate",
            message: "Error creating: pods \"web-bbbb-q2x7z\" is forbidden: exceeded quota: compute", component: "replicaset-controller")
        api.addEvent(about: "pods", "web-bbbb-k8m3p", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container")
        api.addEvent(about: "replicasets.apps", "api-cccc", namespace: "shop", type: "Warning", reason: "FailedCreate", message: "someone else's")
        api.addEvent(about: "pods", "api-cccc-k8m3p", namespace: "shop", type: "Warning", reason: "BackOff", message: "someone else's")
        api.addHelmRelease("web", namespace: "shop", revision: 1, status: "superseded", config: ["auth": ["password": Self.oldPassword]], modified: now.addingTimeInterval(-7300))
        api.addHelmRelease("web", namespace: "shop", revision: 2, config: ["auth": ["password": Self.newPassword]], modified: now.addingTimeInterval(-3700))
        api.addHelmRelease("other", namespace: "shop", revision: 1)
        let ref = KubeObjectRef(context: "fake-dev", kind: Self.deployments, namespace: "shop", name: "web")
        let detail = KubeDetailSession(ref: ref, client: client)
        XCTAssertNotNil(detail.timeline)
        api.forgetRequests()
        detail.showHistory()
        detail.load()
        guard let timeline = detail.timeline else { return }
        let read = await eventually { timeline.state == .loaded }
        XCTAssertTrue(read, "\(timeline.state)")
        XCTAssertEqual(timeline.notes, [])
        XCTAssertEqual(timeline.templates.map(\.name), ["web-aaaa", "web-bbbb"], "its own, by its selector")
        XCTAssertEqual(timeline.helmRecords.map(\.revision), [1, 2], "its release's alone")
        XCTAssertEqual(Set(timeline.entries.map(\.kind)), [.revision, .helm, .scale, .warning])
        XCTAssertEqual(
            Set(timeline.entries.filter { $0.kind == .warning }.compactMap(\.detail).map { String($0.prefix { $0 != ":" }) }),
            ["replicaset/web-bbbb", "pod/web-bbbb-k8m3p"], "its ReplicaSet's and its pod's, no one else's")
        let warnings = api.requests.filter { $0.path == "/api/v1/namespaces/shop/events" && $0.query["fieldSelector"]?.hasPrefix("type=Warning,") == true }
        XCTAssertEqual(
            Set(warnings.compactMap { $0.query["fieldSelector"] }), ["type=Warning,involvedObject.kind=ReplicaSet", "type=Warning,involvedObject.kind=Pod"])
        XCTAssertTrue(warnings.allSatisfy { $0.query["limit"] == String(KubeTimeline.warningLimit) }, "bounded")
        let list = api.requests.first { $0.path == "/apis/apps/v1/namespaces/shop/replicasets" }
        XCTAssertEqual(list?.query["labelSelector"], "app=web")
        XCTAssertEqual(list?.query["limit"], String(KubeTimeline.revisionLimit), "bounded")
        let helm = api.requests.first { $0.path == "/api/v1/namespaces/shop/secrets" }
        XCTAssertEqual(helm?.accept, KubeClient.metadataListAccept, "Helm's records by their metadata alone")
        XCTAssertEqual(helm?.query["labelSelector"], "owner=helm,name=web")
        XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "no record read for the timeline")

        // A template change's diff: from what was read, nothing asked.
        api.forgetRequests()
        let template = await timeline.diff(.template(from: 1, to: 2), production: false)
        XCTAssertEqual(api.requests, [], "from what was read")
        XCTAssertEqual(template?.title, "deployment/web: revision 1 → 2")
        let text = template?.diff.items.map(\.diff).joined() ?? ""
        XCTAssertTrue(text.contains("nginx:1.27") && text.contains("(after)"), text)
        XCTAssertFalse(text.contains(Self.oldPassword) || text.contains(Self.newPassword))

        // A Helm change's: its two records read then, masked.
        let helmDiff = await timeline.diff(.helm(from: 1, to: 2), production: false)
        XCTAssertEqual(
            Set(api.requests.map(\.path)),
            ["/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v1", "/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v2"])
        let helmText = helmDiff?.diff.items.map(\.diff).joined() ?? ""
        XCTAssertTrue(helmText.contains("*** (before)"), helmText)
        XCTAssertFalse(helmText.contains(Self.oldPassword) || helmText.contains(Self.newPassword), helmText)
        let missing = await timeline.diff(.template(from: 7, to: 2), production: false)
        XCTAssertNil(missing)
        XCTAssertNotNil(timeline.diffProblem)

        // Navigated away: what it read goes.
        detail.cancel()
        XCTAssertEqual(timeline.templates, [])
        XCTAssertEqual(timeline.helmRecords, [])
        XCTAssertEqual(timeline.entries, [])
    }

    func testAStatefulSetsControllerRevisionsAndAForbiddenHelmList() async throws {
        let (api, client) = try startFake()
        api.add(
            "statefulsets.apps", "db", namespace: "shop", annotations: [KubeTimeline.helmRelease: "db"],
            fields: ["spec": ["selector": ["matchLabels": ["app": "db"]]]])
        api.addRevision(of: "db", "statefulsets.apps", namespace: "shop", name: "db-1111", revision: 1, image: "postgres:15", labels: ["app": "db"], controllerRevision: true)
        api.addRevision(of: "db", "statefulsets.apps", namespace: "shop", name: "db-2222", revision: 2, image: "postgres:16", labels: ["app": "db"], controllerRevision: true)
        api.forbidden = ["secrets"]
        let kind = KubeResourceKind(group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", singular: "statefulset", namespaced: true, verbs: ["get"])
        let detail = KubeDetailSession(ref: KubeObjectRef(context: "fake-dev", kind: kind, namespace: "shop", name: "db"), client: client)
        detail.load()
        let object = await eventually { detail.state == .loaded }
        XCTAssertTrue(object)
        detail.showHistory()
        guard let timeline = detail.timeline else { return XCTFail("a StatefulSet has a history") }
        let read = await eventually { timeline.state == .loaded }
        XCTAssertTrue(read)
        XCTAssertEqual(timeline.templates.map(\.revision), [1, 2])
        XCTAssertEqual(timeline.entries.first?.title, "Revision 2: image changed")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/controllerrevisions" && $0.query["labelSelector"] == "app=db" })
        XCTAssertTrue(timeline.notes.contains { $0.contains("couldn't be read from its Secret records") }, "\(timeline.notes)")
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/configmaps" }, "then its ConfigMaps")
    }

    /// Navigated away while a Helm diff reads its records: the read ends —
    /// no second record asked for — and nothing is shown.
    func testLeavingMidDiffDropsIt() async throws {
        let (api, _) = try startFake()
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            annotations: [KubeTimeline.helmRelease: "web"], fields: ["spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]]]])
        api.addRevision(of: "web", namespace: "shop", name: "web-aaaa", revision: 1, image: "nginx:1.25", labels: ["app": "web"])
        api.addHelmRelease("web", namespace: "shop", revision: 1, status: "superseded", config: ["auth": ["password": Self.oldPassword]])
        api.addHelmRelease("web", namespace: "shop", revision: 2, config: ["auth": ["password": Self.newPassword]])
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: [KubeWritesTests.context("fake-dev")], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        var shown: [KubeChangeDiff] = []
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.showChange = { shown.append($0) }
        page.actions = actions
        model.show()
        defer { model.hide() }
        let served = await eventually { model.discovery?.kind("deployments") != nil }
        XCTAssertTrue(served)
        guard let deployments = model.discovery?.kind("deployments") else { return }
        page.showKind(deployments)
        let listed = await eventually { model.rows[KubeRowID(namespace: "shop", name: "web")] != nil }
        XCTAssertTrue(listed)
        page.selection = ["shop/web"]
        XCTAssertTrue(page.press("h"))
        guard let timeline = page.detail?.timeline else { return XCTFail("a Deployment's timeline") }
        let read = await eventually { timeline.state == .loaded }
        XCTAssertTrue(read, "\(timeline.state)")

        let first = "/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v2"
        api.answerSlowly(first, milliseconds: 400)
        api.forgetRequests()
        page.openChange(.helm(from: 1, to: 2))
        let asked = await eventually { api.requests.contains { $0.path == first } }
        XCTAssertTrue(asked, "the newer record asked for")
        page.closeDetail()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(api.requests.filter { $0.path.contains("/secrets/") }.map(\.path), [first], "no second record read")
        XCTAssertEqual(shown, [], "nothing shown")
        XCTAssertEqual(timeline.helmRecords, [])
    }

    // MARK: The page

    /// `h` on a Deployment of `fake-prod`: its History tab, read; a Helm
    /// change's diff reads two of the release's records, so production
    /// asks first, once a session — nothing is read before the button —,
    /// then the diff goes to the changes pane; a template change asks
    /// nothing. Reads only.
    func testHOpensTheHistoryAndProductionAsksBeforeHelm() async throws {
        let (api, _) = try startFake()
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            annotations: [KubeTimeline.helmRelease: "web"], fields: ["spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]]]])
        api.addRevision(of: "web", namespace: "shop", name: "web-aaaa", revision: 1, image: "nginx:1.25", labels: ["app": "web"], created: Date().addingTimeInterval(-600))
        api.addRevision(of: "web", namespace: "shop", name: "web-bbbb", revision: 2, image: "nginx:1.27", labels: ["app": "web"])
        api.addHelmRelease("web", namespace: "shop", revision: 1, status: "superseded", config: ["auth": ["password": Self.oldPassword]])
        api.addHelmRelease("web", namespace: "shop", revision: 2, config: ["auth": ["password": Self.newPassword]])
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod"].map { KubeWritesTests.context($0) }, current: "fake-prod")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        var confirms: [(String, () -> Void)] = []
        var shown: [KubeChangeDiff] = []
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.confirm = { _, detail, _, then in confirms.append((detail, then)) }
        actions.showChange = { shown.append($0) }
        page.actions = actions
        model.show()
        defer { model.hide() }
        let served = await eventually { model.discovery?.kind("deployments") != nil }
        XCTAssertTrue(served)
        guard let deployments = model.discovery?.kind("deployments") else { return }
        page.showKind(deployments)
        let listed = await eventually { model.rows[KubeRowID(namespace: "shop", name: "web")] != nil }
        XCTAssertTrue(listed)
        page.selection = ["shop/web"]
        XCTAssertTrue(page.press("h"), "h")
        XCTAssertEqual(page.detailTab, .history)
        guard let timeline = page.detail?.timeline else { return XCTFail("a Deployment's timeline") }
        let read = await eventually { timeline.state == .loaded }
        XCTAssertTrue(read, "\(timeline.state)")
        XCTAssertEqual(timeline.entries.filter { $0.kind == .helm }.count, 2)

        api.forgetRequests()
        page.openChange(.helm(from: 1, to: 2))
        XCTAssertEqual(confirms.count, 1, "production asks first")
        XCTAssertTrue(confirms.first?.0.contains("PRODUCTION · fake-prod") == true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "nothing read before the button")
        confirms.first?.1()
        let diffed = await eventually { shown.count == 1 }
        XCTAssertTrue(diffed)
        XCTAssertEqual(shown.first?.production, true)
        XCTAssertEqual(api.requests.filter { $0.path.contains("/secrets/") }.count, 2, "its two records")
        page.openChange(.helm(from: 1, to: 2))
        let again = await eventually { shown.count == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(confirms.count, 1, "asked once a session")
        page.openChange(.template(from: 1, to: 2))
        let template = await eventually { shown.count == 3 }
        XCTAssertTrue(template)
        XCTAssertEqual(shown.last?.title, "deployment/web: revision 1 → 2")
    }
}
