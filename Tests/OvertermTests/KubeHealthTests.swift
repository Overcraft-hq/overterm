import CryptoKit
import Foundation
import XCTest

@testable import Overterm

/// Health checks (docs/design/kubernetes/analysis.md, 3.9), the pinned
/// contexts' health view (decision 17) and diff across contexts (3.10):
/// the rules over fixture objects — containers on a template, not each
/// pod; restarts within the hour; Pending past a minute; budgets and
/// autoscalers; a custom resource's Ready; Argo's health; a Service
/// selecting nothing, an Ingress to a missing Service or port; then
/// against `FakeKubeAPI` on sockets of the tests' own — the Overview's
/// bounded lists, never a Secret or a ConfigMap; the pinned cards from
/// rows, read while shown and not after; "Compare with…" through each
/// context's own connection, stripped and masked, a Secret by keyed
/// hashes and on production asked first. All GETs. Nothing reads ~/.kube.
@MainActor
final class KubeHealthTests: XCTestCase {
    nonisolated(unsafe) private var fakes: [FakeKubeAPI] = []
    private static let password = "acme-health-pw-Q7v"
    private static let otherPassword = "acme-health-pw-other-J2m"

    override func tearDown() {
        for api in fakes {
            XCTAssertEqual(api.writes, [], "reads only")
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }, [], "only GETs")
            api.stop()
        }
        fakes = []
    }

    // MARK: Fixtures

    private static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func container(
        _ name: String, image: String = "nginx:1.27", probes: Bool = true, requests: Bool = true, limits: Bool = true, env: [[String: Any]] = []
    ) -> [String: Any] {
        var container: [String: Any] = ["name": name, "image": image]
        if probes {
            container["readinessProbe"] = ["httpGet": ["path": "/ready", "port": 8080]]
            container["livenessProbe"] = ["httpGet": ["path": "/live", "port": 8080]]
        }
        var resources: [String: Any] = [:]
        if requests { resources["requests"] = ["cpu": "100m", "memory": "64Mi"] }
        if limits { resources["limits"] = ["memory": "128Mi"] }
        if !resources.isEmpty { container["resources"] = resources }
        if !env.isEmpty { container["env"] = env }
        return container
    }

    private static func deployment(_ name: String, namespace: String = "shop", containers: [[String: Any]]) -> [String: Any] {
        [
            "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": name, "namespace": namespace],
            "spec": ["selector": ["matchLabels": ["app": name]], "template": ["metadata": ["labels": ["app": name]], "spec": ["containers": containers]]],
        ]
    }

    private static func pod(
        _ name: String, namespace: String = "shop", labels: [String: String] = [:], owned: Bool = false, containers: [[String: Any]] = [],
        status: [String: Any] = [:], created: Date = Date()
    ) -> [String: Any] {
        var metadata: [String: Any] = ["name": name, "namespace": namespace, "labels": labels, "creationTimestamp": time(created)]
        if owned { metadata["ownerReferences"] = [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "\(name)-rs", "controller": true]] }
        return ["apiVersion": "v1", "kind": "Pod", "metadata": metadata, "spec": ["containers": containers], "status": status]
    }

    private func codes(_ findings: [KubeHealth.Finding]) -> [String] { findings.map(\.check.code) }

    private static func read(_ resource: String) -> KubeHealth.Read { KubeHealth.reads.first { $0.resource == resource }! }

    private static func owned(_ object: [String: Any], by kind: String, _ name: String, apiVersion: String) -> [String: Any] {
        var object = object
        var metadata = object["metadata"] as? [String: Any] ?? [:]
        metadata["ownerReferences"] = [["apiVersion": apiVersion, "kind": kind, "name": name, "controller": true]]
        object["metadata"] = metadata
        return object
    }

    private static func workload(_ kind: String, _ apiVersion: String, _ name: String, containers: [[String: Any]]) -> [String: Any] {
        ["apiVersion": apiVersion, "kind": kind, "metadata": ["name": name, "namespace": "shop"], "spec": ["template": ["spec": ["containers": containers]]]]
    }

    private static func listBody(_ items: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: ["items": items]) }

    // MARK: One object

    func testAWorkloadsContainersAreCheckedOnItsTemplate() {
        let findings = KubeHealth.object(
            Self.deployment("web", containers: [Self.container("web", image: "nginx", probes: false, requests: false, limits: false)]))
        XCTAssertEqual(Set(codes(findings)), ["K101", "K102", "K103", "K104", "K105"], "\(findings.map(\.sentence))")
        XCTAssertTrue(findings.allSatisfy { $0.subject.said == "deployment/web" && $0.subject.namespace == "shop" })
        XCTAssertTrue(findings.contains { $0.sentence == "container web has no readiness probe: it gets traffic before it is ready" })
        XCTAssertEqual(KubeHealth.object(Self.deployment("ok", containers: [Self.container("ok")])), [], "a well-made one says nothing")
    }

    func testOnlyAPodNobodyOwnsHasItsContainersChecked() {
        let bare = KubeHealth.object(Self.pod("solo", containers: [Self.container("app", probes: false)]))
        XCTAssertEqual(Set(codes(bare)), ["K101", "K102"])
        let owned = KubeHealth.object(Self.pod("web-1", owned: true, containers: [Self.container("app", probes: false)]))
        XCTAssertEqual(owned, [], "its workload's template says it, once")
        var job = Self.pod("job-1", containers: [Self.container("run", probes: false)])
        job["spec"] = ["restartPolicy": "Never", "containers": [Self.container("run", probes: false)]]
        XCTAssertEqual(KubeHealth.object(job), [], "a pod that ends wants no probe")
    }

    /// A pod's containers are left to its owner only when that owner's
    /// checks cover them: a standalone Job's (kubectl create job, an
    /// operator's), a bare ReplicaSet's, a pod a Rollout's ReplicaSet or a
    /// StrimziPodSet owns are checked — never silent.
    func testAContainerIsLeftOnlyToAnOwnerThatWasChecked() {
        let bad = Self.container("run", image: "busybox", probes: false, limits: false)
        // Alone: a known owner's checks cover it; any other kind's don't.
        let strimzi = Self.owned(Self.pod("kafka-0", containers: [bad]), by: "StrimziPodSet", "kafka", apiVersion: "core.strimzi.io/v1beta2")
        XCTAssertEqual(Set(codes(KubeHealth.object(strimzi))), ["K101", "K102", "K104", "K105"], "an operator's pod is checked itself")
        let rolloutRS = Self.owned(Self.workload("ReplicaSet", "apps/v1", "api-7f", containers: [bad]), by: "Rollout", "api", apiVersion: "argoproj.io/v1alpha1")
        XCTAssertTrue(codes(KubeHealth.object(rolloutRS)).contains("K104"), "a Rollout's ReplicaSet is checked on its template")
        let deploymentRS = Self.owned(Self.workload("ReplicaSet", "apps/v1", "web-5d", containers: [bad]), by: "Deployment", "web", apiVersion: "apps/v1")
        XCTAssertEqual(KubeHealth.object(deploymentRS), [], "a Deployment's says it")

        // In a report: a standalone Job's pod — said once, on the Job.
        var lists = KubeHealth.Lists()
        let job = Self.workload("Job", "batch/v1", "migrate", containers: [bad])
        let jobPod = Self.owned(Self.pod("migrate-x1", containers: [bad]), by: "Job", "migrate", apiVersion: "batch/v1")
        // A pod whose Job wasn't read (cut, or made since): checked itself.
        let strayPod = Self.owned(Self.pod("other-x2", containers: [bad]), by: "Job", "other", apiVersion: "batch/v1")
        // A CronJob's Job and its pod: said on the CronJob alone.
        var cron = Self.workload("CronJob", "batch/v1", "nightly", containers: [])
        cron["spec"] = ["jobTemplate": ["spec": ["template": ["spec": ["containers": [bad]]]]]]
        let cronJob = Self.owned(Self.workload("Job", "batch/v1", "nightly-1", containers: [bad]), by: "CronJob", "nightly", apiVersion: "batch/v1")
        let cronPod = Self.owned(Self.pod("nightly-1-a", containers: [bad]), by: "Job", "nightly-1", apiVersion: "batch/v1")
        lists.add(Self.read("pods"), kind: "Pod", apiVersion: "v1", body: Self.listBody([jobPod, strayPod, cronPod, strimzi]), place: "namespace shop")
        lists.add(Self.read("jobs"), kind: "Job", apiVersion: "batch/v1", body: Self.listBody([job, cronJob]), place: "namespace shop")
        lists.add(Self.read("cronjobs"), kind: "CronJob", apiVersion: "batch/v1", body: Self.listBody([cron]), place: "namespace shop")
        let report = KubeHealth.report(lists)
        let limits = Set(report.findings.filter { $0.check == .noLimits }.map(\.subject.said))
        XCTAssertEqual(limits, ["job/migrate", "pod/other-x2", "cronjob/nightly", "pod/kafka-0"], "\(report.findings.map { "\($0.subject.said) \($0.check.code)" })")
    }

    /// What may carry a secret is dropped as a list is decoded: env values
    /// (names kept), Helm values, kubectl's last-applied copy.
    func testWhatIsKeptOfAListedObjectHoldsNoSecret() {
        var deployment = Self.deployment("web", containers: [Self.container("web", env: [["name": "DB_PASSWORD", "value": Self.password]])])
        deployment["metadata"] = [
            "name": "web", "namespace": "shop", "annotations": ["kubectl.kubernetes.io/last-applied-configuration": "{\"pw\":\"\(Self.password)\"}", "team": "shop"],
        ]
        let release: [String: Any] = [
            "apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease", "metadata": ["name": "web", "namespace": "shop"],
            "spec": ["chart": ["spec": ["chart": "web"]], "values": ["db": ["password": Self.password]]],
        ]
        var lists = KubeHealth.Lists()
        lists.add(Self.read("deployments"), kind: "Deployment", apiVersion: "apps/v1", body: Self.listBody([deployment]), place: "namespace shop")
        lists.add(Self.read("helmreleases"), kind: "HelmRelease", apiVersion: "helm.toolkit.fluxcd.io/v2", body: Self.listBody([release]), place: "namespace shop")
        let kept = try! JSONSerialization.data(withJSONObject: [lists.list("deployments.apps")!.items, lists.list("helmreleases.helm.toolkit.fluxcd.io")!.items])
        let text = String(decoding: kept, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.password), text)
        XCTAssertTrue(text.contains("DB_PASSWORD"), "the name stays")
        XCTAssertTrue(text.contains("team"), "other annotations stay")
        XCTAssertEqual(KubeHealth.report(lists).findings.filter { $0.subject.kind == "Deployment" }.map(\.check), [], "the checks still see the container")
    }

    func testWhatIsLatest() {
        for image in ["nginx", "nginx:latest", "registry.example:5000/app", "registry.example:5000/app:latest"] {
            XCTAssertTrue(KubeHealth.isLatest(image), image)
        }
        for image in ["nginx:1.27", "registry.example:5000/app:2", "app@sha256:abc", "nginx:1.27@sha256:abc"] {
            XCTAssertFalse(KubeHealth.isLatest(image), image)
        }
    }

    func testRestartsWithinTheHour() {
        let now = Date()
        let recent = Self.pod(
            "web-1", owned: true,
            status: [
                "phase": "Running",
                "containerStatuses": [
                    [
                        "name": "app", "restartCount": 3,
                        "lastState": ["terminated": ["reason": "OOMKilled", "finishedAt": Self.time(now.addingTimeInterval(-300))]],
                    ],
                    ["name": "old", "restartCount": 2, "lastState": ["terminated": ["reason": "Error", "finishedAt": Self.time(now.addingTimeInterval(-7200))]]],
                    ["name": "fine", "restartCount": 0],
                ],
            ])
        let findings = KubeHealth.object(recent, now: now)
        XCTAssertEqual(codes(findings), ["K501"], "only the one within the hour")
        XCTAssertEqual(findings.first?.sentence, "container app restarted 3 times, last OOMKilled, the last 5m ago")
        let started = Self.pod(
            "web-2", owned: true,
            status: ["containerStatuses": [["name": "app", "restartCount": 1, "state": ["running": ["startedAt": Self.time(now.addingTimeInterval(-60))]]]]])
        XCTAssertEqual(codes(KubeHealth.object(started, now: now)), ["K501"], "no end said: when it ran again")
    }

    func testPendingPastAMinute() {
        let now = Date()
        let stuck = Self.pod(
            "big-1", owned: true,
            status: [
                "phase": "Pending",
                "conditions": [["type": "PodScheduled", "status": "False", "reason": "Unschedulable", "message": "0/3 nodes are available: 3 Insufficient cpu."]],
            ], created: now.addingTimeInterval(-600))
        let findings = KubeHealth.object(stuck, now: now)
        XCTAssertEqual(codes(findings), ["K502"])
        XCTAssertEqual(findings.first?.sentence, "Pending for 10m: 0/3 nodes are available: 3 Insufficient cpu.")
        XCTAssertEqual(KubeHealth.object(Self.pod("new-1", owned: true, status: ["phase": "Pending"], created: now.addingTimeInterval(-20)), now: now), [])
    }

    func testBudgetsAutoscalersAndCustomResources() {
        let pdb: [String: Any] = [
            "apiVersion": "policy/v1", "kind": "PodDisruptionBudget", "metadata": ["name": "web", "namespace": "shop"],
            "status": ["disruptionsAllowed": 0, "expectedPods": 2, "currentHealthy": 2],
        ]
        XCTAssertEqual(codes(KubeHealth.object(pdb)), ["K401"])
        var empty = pdb
        empty["status"] = ["disruptionsAllowed": 0, "expectedPods": 0]
        XCTAssertEqual(KubeHealth.object(empty), [], "one that covers no pod blocks nothing")
        let hpa: [String: Any] = [
            "apiVersion": "autoscaling/v2", "kind": "HorizontalPodAutoscaler", "metadata": ["name": "web", "namespace": "shop"],
            "spec": ["minReplicas": 2, "maxReplicas": 5], "status": ["currentReplicas": 5, "desiredReplicas": 7],
        ]
        XCTAssertEqual(KubeHealth.object(hpa).first?.sentence, "at its maximum: 5 of 5 replicas, it can't scale further")
        let kustomization: [String: Any] = [
            "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization", "metadata": ["name": "apps", "namespace": "flux-system"],
            "status": ["conditions": [["type": "Ready", "status": "False", "reason": "BuildFailed", "message": "kustomization path not found"]]],
        ]
        XCTAssertEqual(KubeHealth.object(kustomization).first?.sentence, "its Ready condition is False: BuildFailed — kustomization path not found")
        let node: [String: Any] = ["apiVersion": "v1", "kind": "Node", "metadata": ["name": "n1"], "status": ["conditions": [["type": "Ready", "status": "False"]]]]
        XCTAssertEqual(KubeHealth.object(node), [], "a built-in kind's Ready is its own page's business")
        let application: [String: Any] = [
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": ["name": "shop", "namespace": "argocd"],
            "status": ["health": ["status": "Degraded", "message": "Deployment web: progress deadline exceeded"], "sync": ["status": "OutOfSync"]],
        ]
        XCTAssertEqual(codes(KubeHealth.object(application)), ["K602", "K603"], "the worst first")
    }

    // MARK: What needs another object

    func testAServiceSelectingNothingAndAnIngressToNothing() {
        let service: [String: Any] = [
            "apiVersion": "v1", "kind": "Service", "metadata": ["name": "api", "namespace": "shop"],
            "spec": ["selector": ["app": "api"], "ports": [["name": "http", "port": 80]]],
        ]
        let pods = [Self.pod("web-1", labels: ["app": "web"]), Self.pod("api-1", namespace: "other", labels: ["app": "api"])]
        XCTAssertEqual(KubeHealth.serviceSelection(service, pods: pods)?.sentence, "selects no pod (app=api): nothing answers it", "another namespace's pod isn't its")
        XCTAssertNil(KubeHealth.serviceSelection(service, pods: pods + [Self.pod("api-2", labels: ["app": "api", "tier": "x"])]))
        var external = service
        external["spec"] = ["type": "ExternalName", "externalName": "db.example"]
        XCTAssertNil(KubeHealth.serviceSelection(external, pods: []), "an ExternalName selects nothing on purpose")
        let ingress: [String: Any] = [
            "apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": ["name": "shop", "namespace": "shop"],
            "spec": [
                "rules": [
                    [
                        "host": "shop.example",
                        "http": [
                            "paths": [
                                ["path": "/", "backend": ["service": ["name": "api", "port": ["number": 80]]]],
                                ["path": "/admin", "backend": ["service": ["name": "api", "port": ["number": 9090]]]],
                                ["path": "/old", "backend": ["service": ["name": "gone", "port": ["name": "http"]]]],
                            ]
                        ],
                    ]
                ]
            ],
        ]
        let findings = KubeHealth.ingressBackends(ingress, services: [service])
        XCTAssertEqual(codes(findings), ["K302", "K301"], "\(findings.map(\.sentence))")
        XCTAssertEqual(
            findings.map(\.sentence),
            [
                "sends shop.example/admin → 9090 to Service api, which has no port 9090", "sends shop.example/old → http to Service gone, which isn't there",
            ])
    }

    func testTheReportSaysWhatItCouldNotCheck() {
        var lists = KubeHealth.Lists()
        let page: [String: Any] = ["metadata": ["continue": "next"], "items": [Self.pod("web-1", labels: ["app": "web"])]]
        lists.add(Self.read("pods"), kind: "Pod", apiVersion: "v1", body: try! JSONSerialization.data(withJSONObject: page), place: "namespace shop")
        let services: [String: Any] = [
            "items": [["metadata": ["name": "api", "namespace": "shop"], "spec": ["selector": ["app": "api"], "ports": [["port": 80]]]]]
        ]
        lists.add(Self.read("services"), kind: "Service", apiVersion: "v1", body: try! JSONSerialization.data(withJSONObject: services), place: "namespace shop")
        lists.failed(Self.read("poddisruptionbudgets"), "Forbidden", place: "namespace shop")
        let report = KubeHealth.report(lists)
        XCTAssertFalse(report.findings.contains { $0.check == .serviceSelectsNone }, "not every pod read: nothing said of a selection")
        XCTAssertTrue(report.notes.contains("More than 200 pods in namespace shop: only 200 were checked."), "\(report.notes)")
        XCTAssertTrue(report.notes.contains("Services' selections aren't checked: not every pod was read."), "\(report.notes)")
        XCTAssertTrue(report.notes.contains { $0.hasPrefix("The poddisruptionbudgets.policy in namespace shop couldn't be listed") })
        XCTAssertEqual(report.checked, 2)
        XCTAssertEqual(KubeHealth.Report(findings: [], checked: 3).said, "No finding in 3 objects")
    }

    /// Only the checks over lists read whole ran: a refused, cut or
    /// unserved list's checks never count as passing.
    func testOnlyChecksOverListsReadWholeRan() {
        var lists = KubeHealth.Lists()
        lists.add(Self.read("pods"), kind: "Pod", apiVersion: "v1", body: Self.listBody([Self.pod("web-1")]), place: "namespace shop")
        lists.add(Self.read("deployments"), kind: "Deployment", apiVersion: "apps/v1", body: Self.listBody([]), place: "namespace shop")
        lists.add(Self.read("services"), kind: "Service", apiVersion: "v1", body: Self.listBody([]), place: "namespace shop")
        lists.failed(Self.read("ingresses"), "Forbidden", place: "namespace shop")
        lists.add(Self.read("horizontalpodautoscalers"), kind: "HorizontalPodAutoscaler", apiVersion: "autoscaling/v2", body: Self.listBody([]), place: "namespace shop")
        var ran = KubeHealth.report(lists).ran
        XCTAssertTrue(ran.isSuperset(of: [.noReadinessProbe, .noLimits, .latestImage, .serviceSelectsNone, .recentRestarts, .pendingLong, .hpaAtMax]))
        XCTAssertFalse(ran.contains(.ingressMissingService), "ingresses refused")
        XCTAssertFalse(ran.contains(.ingressMissingPort))
        XCTAssertFalse(ran.contains(.pdbNoDisruption), "budgets never read")
        XCTAssertFalse(ran.contains(.argoDegraded), "no Argo CD")
        XCTAssertFalse(ran.contains(.notReady), "no custom resource read")

        // Services refused in one namespace of two: theirs never ran.
        lists.failed(Self.read("services"), "Forbidden", place: "namespace web")
        XCTAssertFalse(KubeHealth.report(lists).ran.contains(.serviceSelectsNone))

        // Pods cut at their limit: nothing over pods ran.
        var cut = KubeHealth.Lists()
        let page: [String: Any] = ["metadata": ["continue": "next"], "items": [Self.pod("web-1")]]
        cut.add(Self.read("pods"), kind: "Pod", apiVersion: "v1", body: try! JSONSerialization.data(withJSONObject: page), place: "namespace shop")
        cut.add(Self.read("services"), kind: "Service", apiVersion: "v1", body: Self.listBody([]), place: "namespace shop")
        ran = KubeHealth.report(cut).ran
        XCTAssertTrue(ran.isDisjoint(with: [.noReadinessProbe, .noRequests, .recentRestarts, .pendingLong, .serviceSelectsNone]), "\(ran)")

        // A workload list not JSON: the container checks didn't run whole.
        var broken = KubeHealth.Lists()
        broken.add(Self.read("pods"), kind: "Pod", apiVersion: "v1", body: Self.listBody([]), place: "namespace shop")
        broken.add(Self.read("replicasets"), kind: "ReplicaSet", apiVersion: "apps/v1", body: Data("<html>".utf8), place: "namespace shop")
        ran = KubeHealth.report(broken).ran
        XCTAssertFalse(ran.contains(.noLimits))
        XCTAssertTrue(ran.contains(.recentRestarts))

        // Argo CD's applications read whole: its checks and Ready ran.
        broken.add(Self.read("applications"), kind: "Application", apiVersion: "argoproj.io/v1alpha1", body: Self.listBody([]), place: "namespace shop")
        ran = KubeHealth.report(broken).ran
        XCTAssertTrue(ran.isSuperset(of: [.argoDegraded, .argoOutOfSync, .notReady]))
    }

    // MARK: The Overview's reads, against the fake

    private func startFake(_ name: String = "a") throws -> (FakeKubeAPI, String) {
        let socket = "/tmp/othl-\(name)-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        fakes.append(api)
        api.addNamespace("shop")
        return (api, socket)
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testTheNamespaceIsReadOnceBoundedAndNeverItsSecrets() async throws {
        let (api, socket) = try startFake()
        api.add("deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1"], fields: ["spec": Self.deployment("web", containers: [Self.container("web", probes: false)])["spec"]!])
        api.add("services", "orphan", namespace: "shop", fields: ["spec": ["selector": ["app": "nobody"], "ports": [["port": 80]]]])
        api.add("poddisruptionbudgets.policy", "web", namespace: "shop", fields: ["status": ["disruptionsAllowed": 0, "expectedPods": 1]])
        api.add("secrets", "web-db", namespace: "shop", data: ["password": Self.password])
        api.add("configmaps", "web-config", namespace: "shop", data: ["a": "b"])
        api.addPod("web-1", namespace: "shop", labels: ["app": "web"])
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev"))
        let discovery = try await client.discover()
        let session = KubeHealthSession()
        api.forgetRequests()
        session.show(context: "fake-dev", scope: .namespace("shop"), discovery: discovery, client: client)
        let read = await eventually { session.state == .loaded }
        XCTAssertTrue(read, "\(session.state)")
        let codes = Set(session.report.findings.map(\.check.code))
        XCTAssertTrue(codes.isSuperset(of: ["K101", "K102", "K201", "K401"]), "\(session.report.findings.map(\.sentence)) \(session.report.notes)")
        XCTAssertTrue(session.report.findings.contains { $0.subject.said == "service/orphan" })
        let paths = Set(api.requests.map(\.path))
        XCTAssertTrue(paths.isSuperset(of: ["/api/v1/namespaces/shop/pods", "/apis/apps/v1/namespaces/shop/deployments", "/api/v1/namespaces/shop/services"]), "\(paths)")
        XCTAssertFalse(paths.contains { $0.contains("secrets") || $0.contains("configmaps") }, "never a Secret or a ConfigMap: \(paths)")
        XCTAssertTrue(api.requests.allSatisfy { $0.query["limit"] != nil }, "bounded")
        XCTAssertEqual(api.requests.first { $0.path.hasSuffix("/pods") }?.query["limit"], String(KubeHealth.podLimit))
        XCTAssertFalse(api.requests.contains(where: \.isWatch), "no watch")
        XCTAssertEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods" }.count, 1, "once")

        // Shown again on the same place: nothing asked; Refresh asks again; hidden, dropped.
        api.forgetRequests()
        session.show(context: "fake-dev", scope: .namespace("shop"), discovery: discovery, client: client)
        XCTAssertEqual(api.requests, [])
        session.refresh(discovery: discovery, client: client)
        let again = await eventually { session.state == .loaded && !api.requests.isEmpty }
        XCTAssertTrue(again)
        session.hide()
        XCTAssertEqual(session.report, KubeHealth.Report())
        XCTAssertEqual(session.state, .idle)
    }

    func testADetailSaysItsOwnAndItsTreesFindings() async throws {
        let (api, socket) = try startFake()
        api.add("services", "orphan", namespace: "shop", fields: ["spec": ["selector": ["app": "nobody"], "ports": [["port": 80]]]])
        let client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev"))
        let services = KubeResourceKind(group: "", version: "v1", resource: "services", kind: "Service", singular: "service", namespaced: true, verbs: ["get", "list"])
        let detail = KubeDetailSession(ref: KubeObjectRef(context: "fake-dev", kind: services, namespace: "shop", name: "orphan"), client: client)
        detail.showTree()
        detail.load()
        let read = await eventually { detail.tree?.state == .loaded }
        XCTAssertTrue(read)
        XCTAssertEqual(detail.tree?.findings.map(\.check), [.serviceSelectsNone], "its pods listed by its selector, none")
        XCTAssertEqual(detail.health, [])
        detail.cancel()
        XCTAssertEqual(detail.tree?.findings, [])
    }

    // MARK: Pinned contexts

    func testAPinnedCardFromRows() {
        let columns = [KubeColumn(name: "Name", type: "string"), KubeColumn(name: "Ready", type: "string"), KubeColumn(name: "Status", type: "string")]
        func row(_ name: String, _ cells: [String]) -> KubeRow {
            KubeRow(id: KubeRowID(namespace: "shop", name: name), cells: ([name] + cells).map { .text($0) })
        }
        let pods = KubeTable(columns: columns, rows: [row("a", ["1/1", "Running"]), row("b", ["0/1", "CrashLoopBackOff"])], continueToken: "more")
        let deployColumns = [KubeColumn(name: "Name", type: "string"), KubeColumn(name: "Ready", type: "string")]
        let deployments = KubeTable(
            columns: deployColumns,
            rows: [
                KubeRow(id: KubeRowID(namespace: "shop", name: "web"), cells: [.text("web"), .text("0/2")]), KubeRow(id: KubeRowID(namespace: "shop", name: "ok"), cells: [.text("ok"), .text("1/1")]),
            ])
        let nodeColumns = [KubeColumn(name: "Name", type: "string"), KubeColumn(name: "Status", type: "string")]
        let nodes = KubeTable(columns: nodeColumns, rows: [KubeRow(id: KubeRowID(namespace: nil, name: "n1"), cells: [.text("n1"), .text("NotReady,SchedulingDisabled")])])
        let kinds = KubePinnedHealth.kinds(nil)
        let summary = KubePinnedHealth.summary(pods: pods, workloads: [(kinds.workloads[0], deployments)], nodes: nodes)
        XCTAssertEqual(summary.pods, 2)
        XCTAssertEqual(summary.failing, ["pod/shop/b CrashLoopBackOff"])
        XCTAssertEqual(summary.notReady, ["deployment/shop/web"])
        XCTAssertEqual(summary.notReadyNodes, ["n1"])
        XCTAssertEqual(summary.cut, ["pods"])
        XCTAssertEqual(summary.problems, 3)
    }

    func testPinnedCardsAreReadWhileShownAndNotAfter() async throws {
        let (dev, devSocket) = try startFake("dev")
        let (stage, stageSocket) = try startFake("stage")
        stage.addPod("api-1", namespace: "shop", FakeKubeAPI.Pod(status: "CrashLoopBackOff", ready: 0, restarts: 4))
        stage.add("deployments.apps", "api", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0])
        dev.addPod("web-1", namespace: "shop")
        let list = KubeContextList(contexts: ["fake-dev", "fake-stage"].map { KubeWritesTests.context($0) }, current: "fake-dev")
        let session = KubePinnedHealthSession()
        session.interval = .milliseconds(100)
        let sockets = ["fake-dev": devSocket, "fake-stage": stageSocket]
        session.show(
            pinned: ["fake-stage", "fake-dev", "acme-gone"], contexts: list, discovery: { _ in nil },
            target: { context in (KubeClient(KubeSocketConnection(socket: sockets[context.name]!, context: context.name)), .namespace("shop")) })
        XCTAssertEqual(session.cards.map(\.context), ["fake-stage", "fake-dev", "acme-gone"], "in the setting's order")
        XCTAssertEqual(session.cards.last?.state, .notRead("Not in the kubeconfig."))
        let read = await eventually {
            session.cards.prefix(2).allSatisfy { if case .read = $0.state { true } else { false } }
        }
        XCTAssertTrue(read, "\(session.cards.map(\.state))")
        guard case .read(let stageSummary, _) = session.cards[0].state, case .read(let devSummary, _) = session.cards[1].state else { return }
        XCTAssertEqual(stageSummary.failing, ["pod/shop/api-1 CrashLoopBackOff"])
        XCTAssertEqual(stageSummary.notReady, ["deployment/shop/api"])
        XCTAssertTrue(devSummary.isFine, "\(devSummary)")
        XCTAssertTrue(stage.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["limit"] == "500" && $0.query["includeObject"] == "None" })
        XCTAssertFalse(stage.requests.contains(where: \.isWatch), "rows, never a watch")
        let polled = await eventually { stage.requests.filter { $0.path == "/api/v1/namespaces/shop/pods" }.count >= 2 }
        XCTAssertTrue(polled, "read again while shown")
        // Shown again as it is: nothing made again; the kubeconfig gaining a pinned name: its card read.
        let before = session.cards
        session.show(
            pinned: ["fake-stage", "fake-dev", "acme-gone"], contexts: list, discovery: { _ in nil },
            target: { context in (KubeClient(KubeSocketConnection(socket: sockets[context.name]!, context: context.name)), .namespace("shop")) })
        XCTAssertEqual(session.cards.map(\.context), before.map(\.context))
        XCTAssertNotEqual(session.cards.first?.state, .waiting, "kept, not read from scratch")
        let wider = KubeContextList(contexts: ["fake-dev", "fake-stage", "acme-gone"].map { KubeWritesTests.context($0) }, current: "fake-dev")
        let gone = ["acme-gone": stageSocket]
        session.show(
            pinned: ["fake-stage", "fake-dev", "acme-gone"], contexts: wider, discovery: { _ in nil },
            target: { context in (KubeClient(KubeSocketConnection(socket: sockets[context.name] ?? gone[context.name]!, context: context.name)), .namespace("shop")) })
        let found = await eventually { if case .read = session.cards.last?.state { true } else { false } }
        XCTAssertTrue(found, "\(session.cards.map(\.state))")
        session.hide()
        XCTAssertEqual(session.cards, [])
        try await Task.sleep(for: .milliseconds(150))
        stage.forgetRequests()
        dev.forgetRequests()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stage.requests + dev.requests, [], "hidden, nothing is asked")
    }

    /// Kubernetes off between show and read: the card says so, not "Reading…".
    func testAPinnedCardWithNoClientSaysWhy() async {
        let list = KubeContextList(contexts: [KubeWritesTests.context("fake-stage")], current: "fake-stage")
        let session = KubePinnedHealthSession()
        session.show(pinned: ["fake-stage"], contexts: list, discovery: { _ in nil }, target: { _ in nil })
        let said = await eventually { session.cards.first?.state == .notRead(KubePinnedHealthSession.off) }
        XCTAssertTrue(said, "\(session.cards.map(\.state))")
        session.hide()
    }

    /// One session for the app: shown by two windows' pages, read while
    /// either shows it.
    func testPinnedCardsAreTheAppsWhileAnyWindowShowsThem() {
        let list = KubeContextList(contexts: [KubeWritesTests.context("fake-stage")], current: "fake-stage")
        let session = KubePinnedHealthSession()
        let one = NSObject()
        let two = NSObject()
        session.show(by: one, pinned: ["fake-stage"], contexts: list, discovery: { _ in nil }, target: { _ in nil })
        session.show(by: two, pinned: ["fake-stage"], contexts: list, discovery: { _ in nil }, target: { _ in nil })
        XCTAssertTrue(session.isReading)
        session.hide(by: one)
        XCTAssertTrue(session.isReading, "the other window still shows it")
        session.hide(by: two)
        XCTAssertFalse(session.isReading)
        XCTAssertEqual(session.cards, [])
    }

    // MARK: Compare with…

    private static func object(_ body: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: body) }

    func testTwoSidesStrippedAndMaskedTogether() {
        func side(image: String, password: String, replicas: Int, uid: String) -> Data {
            var object = Self.deployment("web", containers: [Self.container("web", image: image, env: [["name": "DB_PASSWORD", "value": password], ["name": "MODE", "value": "fast"]])])
            object["metadata"] = [
                "name": "web", "namespace": "shop", "uid": uid, "resourceVersion": "\(replicas)00", "creationTimestamp": "2026-11-0\(replicas)T00:00:00Z",
                "managedFields": [["manager": "kubectl"]], "annotations": [KubeObjectStrip.lastApplied: "{\"password\":\"\(password)\"}"],
                "ownerReferences": [["kind": "Thing", "name": "x", "uid": uid]],
            ]
            var spec = object["spec"] as! [String: Any]
            spec["replicas"] = replicas
            object["spec"] = spec
            object["status"] = ["replicas": replicas]
            return Self.object(object)
        }
        let ref = KubeObjectRef(context: "fake-dev", kind: KubeWritesTests.deployments, namespace: "shop", name: "web")
        let from = KubeCompare.Side(context: "fake-dev", namespace: "shop", production: false)
        let to = KubeCompare.Side(context: "fake-prod", namespace: "shop", production: true)
        guard
            let diff = KubeCompare.diff(
                ref: ref, kind: "Deployment", left: side(image: "nginx:1.25", password: Self.password, replicas: 1, uid: "u1"),
                right: side(image: "nginx:1.27", password: Self.otherPassword, replicas: 3, uid: "u2"), from: from, to: to)
        else { return XCTFail("a diff") }
        XCTAssertEqual(diff.title, "deployment/web: fake-dev/shop ↔ fake-prod/shop")
        XCTAssertEqual(diff.context, "fake-dev ↔ fake-prod")
        XCTAssertTrue(diff.production, "production on either side says so")
        let text = diff.diff.items.map(\.diff).joined()
        XCTAssertTrue(text.contains("--- fake-dev/shop/deployment-web.yaml") && text.contains("+++ fake-prod/shop/deployment-web.yaml"), text)
        XCTAssertTrue(text.split(separator: "\n").contains { $0.hasPrefix("-") && $0.contains("image: nginx:1.25") }, text)
        XCTAssertTrue(text.split(separator: "\n").contains { $0.hasPrefix("+") && $0.contains("replicas: 3") }, text)
        XCTAssertTrue(text.contains("(before)") && text.contains("(after)"), "a secret env value that differs says so")
        for hidden in [Self.password, Self.otherPassword, "uid", "resourceVersion", "managedFields", "creationTimestamp", "status:", KubeObjectStrip.lastApplied] {
            XCTAssertFalse(text.contains(hidden), "\(hidden) in \(text)")
        }
        XCTAssertFalse(
            text.split(separator: "\n").contains { ($0.hasPrefix("-") || $0.hasPrefix("+")) && $0.contains("value: fast") }, "an env value the same on both sides is no change")
        XCTAssertEqual(diff.diff.items.first?.change, .modified)

        let same = KubeCompare.diff(
            ref: ref, kind: "Deployment", left: side(image: "nginx:1.27", password: Self.password, replicas: 2, uid: "u1"),
            right: side(image: "nginx:1.27", password: Self.password, replicas: 2, uid: "u9"), from: from, to: to)
        XCTAssertEqual(same?.diff.items.first?.change, .unchanged, "only what names each copy differs: the same")
        let missing = KubeCompare.diff(ref: ref, kind: "Deployment", left: side(image: "a:1", password: "x", replicas: 1, uid: "u"), right: nil, from: from, to: to)
        XCTAssertEqual(missing?.diff.items.first?.change, .removed)
        XCTAssertTrue(missing?.label.contains("fake-prod/shop has no deployment/web") == true, missing?.label ?? "")
    }

    func testASecretByItsKeysAndKeyedHashes() {
        func secret(_ values: [String: String]) -> Data {
            Self.object([
                "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": ["name": "web-db", "namespace": "shop", "annotations": [KubeObjectStrip.lastApplied: "{\"data\":{\"password\":\"\(values["password"] ?? "")\"}}"]],
                "data": values.mapValues { Data($0.utf8).base64EncodedString() },
            ])
        }
        let ref = KubeObjectRef(
            context: "fake-dev", kind: KubeResourceKind(group: "", version: "v1", resource: "secrets", kind: "Secret", singular: "secret", namespaced: true, verbs: ["get"]), namespace: "shop",
            name: "web-db")
        let from = KubeCompare.Side(context: "fake-dev", namespace: "shop", production: false)
        let to = KubeCompare.Side(context: "fake-stage", namespace: "shop", production: false)
        guard
            let diff = KubeCompare.diff(
                ref: ref, kind: "Secret", left: secret(["password": Self.password, "user": "web"]),
                right: secret(["password": Self.otherPassword, "user": "web", "extra": "x"]), from: from, to: to)
        else { return XCTFail("a diff") }
        let text = diff.diff.items.map(\.diff).joined()
        for value in [Self.password, Self.otherPassword, Data(Self.password.utf8).base64EncodedString(), Data(Self.otherPassword.utf8).base64EncodedString(), "d2Vi"] {
            XCTAssertFalse(text.contains(value), "\(value) in \(text)")
        }
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("-") && $0.contains("password: hmac:") }, text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("+") && $0.contains("password: hmac:") }, "a value that differs, a hash that differs")
        XCTAssertTrue(lines.contains { $0.hasPrefix("+") && $0.contains("extra:") }, "a key only one side has")
        XCTAssertFalse(lines.contains { ($0.hasPrefix("-") || $0.hasPrefix("+")) && $0.contains("user:") }, "the same value, the same hash: no change")
        XCTAssertEqual(diff.diff.secrets, 1)
        XCTAssertTrue(diff.label.contains("hash keyed for this comparison"), diff.label)

        // A key made for each comparison: no hash outlives it.
        let a = KubeCompare.side(secret(["password": Self.password]), key: SymmetricKey(size: .bits256))
        let b = KubeCompare.side(secret(["password": Self.password]), key: SymmetricKey(size: .bits256))
        XCTAssertNotEqual((a?["data"] as? [String: String])?["password"], (b?["data"] as? [String: String])?["password"])
        XCTAssertNil((a?["metadata"] as? [String: Any])?["annotations"], "the last-applied annotation, every value again, is gone")
    }

    func testTheComparePicker() {
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod", "fake-stage"].map { KubeWritesTests.context($0) }, current: "fake-dev")
        var picker = KubePicker.compare(context: "fake-dev", namespace: "shop", contexts: list, namespaces: ["shop", "payments"])
        XCTAssertEqual(picker.items.map(\.title), ["fake-prod", "fake-stage", "payments"], "the other contexts, then the context's other namespaces")
        XCTAssertEqual(picker.items.first?.choice, .compare(context: "fake-prod", namespace: "shop"))
        XCTAssertEqual(picker.items.first?.production, true)
        picker.query = "staging@fake-prod"
        XCTAssertEqual(picker.chosen, .compare(context: "fake-prod", namespace: "staging"), "namespace@context typed")
        picker.query = "qa"
        XCTAssertEqual(picker.results.last?.choice, .compare(context: "fake-dev", namespace: "qa"), "a namespace of its own context")
        let cluster = KubePicker.compare(context: "fake-dev", namespace: nil, contexts: list, namespaces: ["shop"])
        XCTAssertEqual(cluster.items.map(\.title), ["fake-prod", "fake-stage"], "a cluster-wide object: other contexts alone")
    }

    /// The page's "Compare with…": the other side through its own context's
    /// connection, the diff to the changes pane; a Secret on production
    /// asked first, nothing read before the button, then by keyed hashes.
    func testComparingAcrossContextsOnThePage() async throws {
        let (dev, devSocket) = try startFake("dev")
        let (prod, prodSocket) = try startFake("prod")
        for (api, image) in [(dev, "nginx:1.25"), (prod, "nginx:1.27")] {
            api.add(
                "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
                fields: ["spec": Self.deployment("web", containers: [Self.container("web", image: image)])["spec"]!])
        }
        dev.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], data: ["password": Self.password])
        prod.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], data: ["password": Self.otherPassword])
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: ["fake-dev", "fake-prod"].map { KubeWritesTests.context($0) }, current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        let sockets = ["fake-dev": devSocket, "fake-prod": prodSocket]
        model.connectOverride = { context in KubeSocketConnection(socket: sockets[context.name]!, context: context.name, writable: context.isWritable) }
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
        guard let deployments = model.discovery?.kind("deployments"), let secrets = model.discovery?.kind("secrets") else { return }
        let ref = KubeObjectRef(context: "fake-dev", kind: deployments, namespace: "shop", name: "web")
        XCTAssertNil(page.compareVerb(for: ref).unavailable)
        page.openCompare(ref)
        XCTAssertEqual(page.picker?.kind, .compare(context: "fake-dev", namespace: "shop"))
        XCTAssertEqual(page.picker?.selected?.title, "fake-prod")
        dev.forgetRequests()
        prod.forgetRequests()
        page.choosePicked()
        let compared = await eventually { shown.count == 1 }
        XCTAssertTrue(compared, page.compareStatus?.text ?? "")
        XCTAssertEqual(shown.first?.title, "deployment/web: fake-dev/shop ↔ fake-prod/shop")
        XCTAssertEqual(dev.requests.map(\.path), ["/apis/apps/v1/namespaces/shop/deployments/web"], "one GET a side")
        XCTAssertEqual(prod.requests.map(\.path), ["/apis/apps/v1/namespaces/shop/deployments/web"])
        XCTAssertTrue(shown.first?.diff.items.first?.diff.contains("nginx:1.27") == true)
        XCTAssertTrue(confirms.isEmpty, "a Deployment asks nothing")

        // A Secret: production asks first, nothing read before the button.
        dev.forgetRequests()
        prod.forgetRequests()
        let secret = KubeObjectRef(context: "fake-dev", kind: secrets, namespace: "shop", name: "web-db")
        page.compare(secret, with: "fake-prod", namespace: nil)
        XCTAssertEqual(confirms.count, 1)
        XCTAssertTrue(confirms.first?.0.contains("PRODUCTION · fake-prod") == true, confirms.first?.0 ?? "")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(dev.requests + prod.requests, [], "nothing read before the button")
        confirms.first?.1()
        let secretShown = await eventually { shown.count == 2 }
        XCTAssertTrue(secretShown, page.compareStatus?.text ?? "")
        let text = shown.last?.diff.items.map(\.diff).joined() ?? ""
        XCTAssertTrue(text.contains("hmac:"), text)
        for value in [Self.password, Self.otherPassword, Data(Self.password.utf8).base64EncodedString(), Data(Self.otherPassword.utf8).base64EncodedString()] {
            XCTAssertFalse(text.contains(value))
        }
        page.compare(secret, with: "fake-prod", namespace: nil)
        let again = await eventually { shown.count == 3 }
        XCTAssertTrue(again)
        XCTAssertEqual(confirms.count, 1, "asked once a context and session")

        // Itself: said, nothing read.
        page.compare(ref, with: "fake-dev", namespace: "shop")
        XCTAssertEqual(page.compareStatus?.text, "That is the object itself: pick another context or namespace.")
        // Gone on the other side: said in the diff.
        prod.delete("deployments.apps", "web", namespace: "shop")
        page.compare(ref, with: "fake-prod", namespace: nil)
        let gone = await eventually { shown.count == 4 }
        XCTAssertTrue(gone)
        XCTAssertEqual(shown.last?.diff.items.first?.change, .removed)

        // A status is the compared object's, and goes with it: another
        // namespace, the page hidden — a comparison being read then ends,
        // and its diff never comes.
        page.compare(ref, with: "fake-dev", namespace: "shop")
        XCTAssertEqual(page.compareStatus?.ref, ref)
        model.setScope(.namespace("qa"))
        let cleared = await eventually { page.compareStatus == nil }
        XCTAssertTrue(cleared, "another namespace: \(page.compareStatus?.text ?? "")")
        page.visible = true
        prod.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1"],
            fields: ["spec": Self.deployment("web", containers: [Self.container("web")])["spec"]!])
        page.compare(ref, with: "fake-prod", namespace: "shop")
        XCTAssertNotNil(page.comparing)
        page.visible = false
        XCTAssertNil(page.compareStatus)
        XCTAssertNil(page.comparing)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(shown.count, 4, "hidden: the comparison read meanwhile is dropped")
    }
}
