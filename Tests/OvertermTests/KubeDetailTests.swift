import Foundation
import XCTest

@testable import Overterm

/// A Kubernetes object's detail: the rollout read as `kubectl rollout
/// status` reads it, the YAML as kubectl writes it and stripped as the tab
/// shows it, the Overview of each tailored kind, events newest first, the
/// history's back and forward — and the page's detail against
/// `FakeKubeAPI`: one GET as it opens, events by the object's uid, links
/// followed, never a Secret read. No cluster of the user's is reached.
@MainActor
final class KubeDetailTests: XCTestCase {
    // MARK: Rollout status

    private func deployment(
        generation: Int = 2, observed: Int = 2, replicas: Int = 3, updated: Int = 3, total: Int = 3, available: Int = 3, paused: Bool = false,
        progressing: (status: String, reason: String)? = ("True", "NewReplicaSetAvailable")
    ) -> [String: Any] {
        var status: [String: Any] = [
            "observedGeneration": observed, "updatedReplicas": updated, "replicas": total, "availableReplicas": available, "readyReplicas": available,
        ]
        if let progressing { status["conditions"] = [["type": "Progressing", "status": progressing.status, "reason": progressing.reason]] }
        var spec: [String: Any] = ["replicas": replicas]
        if paused { spec["paused"] = true }
        return ["kind": "Deployment", "apiVersion": "apps/v1", "metadata": ["name": "web", "generation": generation], "spec": spec, "status": status]
    }

    func testADeploymentsRolloutIsReadAsKubectlReadsIt() {
        XCTAssertEqual(KubeRollout.of(deployment()), KubeRollout(state: .complete, message: "deployment \"web\" successfully rolled out"))
        XCTAssertEqual(
            KubeRollout.of(deployment(updated: 1, available: 1))?.message,
            "Waiting for deployment \"web\" rollout to finish: 1 out of 3 new replicas have been updated")
        XCTAssertEqual(
            KubeRollout.of(deployment(total: 5))?.message, "Waiting for deployment \"web\" rollout to finish: 2 old replicas are pending termination")
        XCTAssertEqual(
            KubeRollout.of(deployment(available: 2))?.message, "Waiting for deployment \"web\" rollout to finish: 2 of 3 updated replicas are available")
        XCTAssertEqual(KubeRollout.of(deployment(available: 2))?.state, .progressing)
        XCTAssertEqual(KubeRollout.of(deployment(generation: 3, observed: 2))?.state, .waitingForSpec, "the spec not seen yet")

        let stuck = KubeRollout.of(deployment(updated: 1, available: 0, progressing: ("False", "ProgressDeadlineExceeded")))
        XCTAssertEqual(stuck, KubeRollout(state: .stuck, message: "deployment \"web\" exceeded its progress deadline"))
        XCTAssertTrue(stuck?.isProblem == true)
        XCTAssertEqual(
            KubeRollout.of(deployment(generation: 3, observed: 2, progressing: ("False", "ProgressDeadlineExceeded")))?.state, .waitingForSpec,
            "as kubectl: the deadline counts only once the spec is observed")

        let paused = KubeRollout.of(deployment(updated: 1, paused: true, progressing: ("Unknown", "DeploymentPaused")))
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertFalse(paused?.isProblem == true)
    }

    func testStatefulSetsAndDaemonSetsRollOutTheirWay() {
        func sts(_ status: [String: Any], partition: Int? = nil, type: String = "RollingUpdate") -> [String: Any] {
            var strategy: [String: Any] = ["type": type]
            if let partition { strategy["rollingUpdate"] = ["partition": partition] }
            return [
                "kind": "StatefulSet", "metadata": ["name": "db", "generation": 1], "spec": ["replicas": 3, "updateStrategy": strategy],
                "status": status.merging(["observedGeneration": 1]) { $1 },
            ]
        }
        XCTAssertEqual(KubeRollout.of(sts(["readyReplicas": 1]))?.message, "Waiting for 2 pods to be ready")
        XCTAssertEqual(
            KubeRollout.of(sts(["readyReplicas": 3, "updatedReplicas": 1, "updateRevision": "db-2", "currentRevision": "db-1"]))?.message,
            "waiting for statefulset rolling update to complete 1 pods at revision db-2")
        XCTAssertEqual(
            KubeRollout.of(sts(["readyReplicas": 3, "currentReplicas": 3, "updateRevision": "db-2", "currentRevision": "db-2"]))?.state, .complete)
        XCTAssertEqual(
            KubeRollout.of(sts(["readyReplicas": 3, "updatedReplicas": 0], partition: 2))?.message,
            "Waiting for partitioned roll out to finish: 0 out of 1 new pods have been updated")
        XCTAssertEqual(KubeRollout.of(sts([:], type: "OnDelete"))?.state, .notTracked)

        let daemon: [String: Any] = [
            "kind": "DaemonSet", "metadata": ["name": "agent", "generation": 4],
            "status": ["observedGeneration": 4, "desiredNumberScheduled": 3, "updatedNumberScheduled": 3, "numberAvailable": 2],
        ]
        XCTAssertEqual(KubeRollout.of(daemon)?.message, "Waiting for daemon set \"agent\" rollout to finish: 2 of 3 updated pods are available")
        XCTAssertNil(KubeRollout.of(["kind": "ReplicaSet"]), "kubectl has no rollout status for a ReplicaSet")
    }

    // MARK: YAML

    func testYAMLIsWrittenAsKubectlWritesIt() {
        let object: [String: Any] = [
            "kind": "Pod", "apiVersion": "v1",
            "metadata": ["name": "web", "labels": ["app": "web", "version": "1.0"], "annotations": [:] as [String: Any]],
            "spec": [
                "containers": [["name": "app", "image": "nginx:1.27", "args": ["-c", "echo: hi", ""], "ports": [["containerPort": 80]]]],
                "hostNetwork": false, "nodeSelector": NSNull(),
            ],
            "data": ["script": "line one\nline two\n", "flag": "true", "number": "0123", "plain": "hello world"],
        ]
        XCTAssertEqual(
            KubeYAML.text(object),
            """
            apiVersion: v1
            data:
              flag: "true"
              number: "0123"
              plain: hello world
              script: |
                line one
                line two
            kind: Pod
            metadata:
              annotations: {}
              labels:
                app: web
                version: "1.0"
              name: web
            spec:
              containers:
              - args:
                - -c
                - "echo: hi"
                - ""
                image: nginx:1.27
                name: app
                ports:
                - containerPort: 80
              hostNetwork: false
              nodeSelector: null

            """)
        for (text, quoted) in [
            ("yes", true), ("~", true), ("1e3", true), ("0x1F", true), ("- item", true), ("#tag", true), ("a #b", true), (" lead", true), ("key:", true),
            ("v1.27", false), ("nginx:1.27", false), ("-c", false), ("10.0.0.1", false), ("a-b_c", false), ("3m", false),
        ] {
            XCTAssertEqual(KubeYAML.needsQuotes(text), quoted, text)
        }
        XCTAssertEqual(KubeYAML.text(["s": "no newline\nat end"]), "s: |-\n  no newline\n  at end\n")
    }

    func testTheYAMLTabLeavesOutManagedFieldsAndLastApplied() {
        let object: [String: Any] = [
            "kind": "ConfigMap", "apiVersion": "v1",
            "metadata": [
                "name": "web-config", "managedFields": [["manager": "kubectl"]],
                "annotations": [KubeObjectStrip.lastApplied: "{\"data\":{}}", "team": "shop"],
            ],
            "data": ["a": "1"],
        ]
        XCTAssertTrue(KubeObjectStrip.hasHidden(object))
        let stripped = KubeYAML.text(KubeObjectStrip.shown(object, full: false))
        XCTAssertFalse(stripped.contains("managedFields"))
        XCTAssertFalse(stripped.contains("last-applied"))
        XCTAssertTrue(stripped.contains("team: shop"), "the other annotations stay")
        let full = KubeYAML.text(KubeObjectStrip.shown(object, full: true))
        XCTAssertTrue(full.contains("managedFields:") && full.contains("manager: kubectl"))
        XCTAssertTrue(full.contains(KubeObjectStrip.lastApplied))

        let lone: [String: Any] = ["kind": "Service", "metadata": ["name": "s", "annotations": [KubeObjectStrip.lastApplied: "{}"]]]
        XCTAssertNil((KubeObjectStrip.shown(lone, full: false)["metadata"] as? [String: Any])?["annotations"], "an empty map goes with it")

        // A Secret, were one ever shown: masked whatever the toggle, its last-applied never.
        let secret: [String: Any] = [
            "kind": "Secret", "apiVersion": "v1", "metadata": ["name": "s", "annotations": [KubeObjectStrip.lastApplied: "{\"data\":{\"k\":\"c2VjcmV0\"}}"]],
            "data": ["k": "c2VjcmV0"], "stringData": ["p": "hunter2"],
        ]
        let shown = KubeYAML.text(KubeObjectStrip.shown(secret, full: true))
        XCTAssertFalse(shown.contains("c2VjcmV0") || shown.contains("hunter2") || shown.contains("last-applied"), shown)
        XCTAssertFalse(KubeObjectStrip.hasHidden(secret))

        // A container's env: a value whose name looks secret is masked, at any depth.
        let deployment: [String: Any] = [
            "kind": "Deployment", "apiVersion": "apps/v1", "metadata": ["name": "web"],
            "spec": [
                "template": [
                    "spec": [
                        "containers": [
                            [
                                "name": "app",
                                "env": [
                                    ["name": "DB_PASSWORD", "value": "hunter2"], ["name": "LOG_LEVEL", "value": "debug"],
                                    ["name": "DATABASE_URL", "value": "postgres://app:s3cret@db:5432/app"],
                                    ["name": "API_TOKEN", "valueFrom": ["secretKeyRef": ["name": "api", "key": "token"]]],
                                ],
                            ]
                        ]
                    ]
                ]
            ],
        ]
        let env = KubeYAML.text(KubeObjectStrip.shown(deployment, full: true))
        XCTAssertFalse(env.contains("hunter2") || env.contains("s3cret"), env)
        XCTAssertTrue(env.contains("value: debug"))
        XCTAssertTrue(env.contains("postgres://app:••••••@db:5432/app"))
        XCTAssertTrue(env.contains("key: token"), "a secretKeyRef is only a name")

        // The last-applied annotation is the manifest as applied: its env masked too.
        let manifest =
            "{\"apiVersion\":\"apps/v1\",\"kind\":\"Deployment\",\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"app\",\"env\":[{\"name\":\"DB_PASSWORD\",\"value\":\"hunter2\"},{\"name\":\"LOG_LEVEL\",\"value\":\"debug\"}]}]}}}}"
        let applied: [String: Any] = [
            "kind": "Deployment", "apiVersion": "apps/v1",
            "metadata": ["name": "worker", "annotations": [KubeObjectStrip.lastApplied: manifest]],
        ]
        let appliedYAML = KubeYAML.text(KubeObjectStrip.shown(applied, full: true))
        XCTAssertTrue(appliedYAML.contains(KubeObjectStrip.lastApplied))
        XCTAssertFalse(appliedYAML.contains("hunter2"), appliedYAML)
        XCTAssertTrue(appliedYAML.contains("LOG_LEVEL") && appliedYAML.contains("debug"))
        let unchanged = KubeObjectStrip.shown(object, full: true)
        XCTAssertEqual(
            ((unchanged["metadata"] as? [String: Any])?["annotations"] as? [String: Any])?[KubeObjectStrip.lastApplied] as? String, "{\"data\":{}}", "nothing to mask: as the server sent it")
        let broken: [String: Any] = ["kind": "Pod", "metadata": ["name": "p", "annotations": [KubeObjectStrip.lastApplied: "{\"env\":[{\"name\":\"DB_PASSWORD\",\"value\":\"hunter2\""]]]
        let brokenYAML = KubeYAML.text(KubeObjectStrip.shown(broken, full: true))
        XCTAssertFalse(brokenYAML.contains("hunter2"), "not JSON: masked whole")
        XCTAssertTrue(brokenYAML.contains(KubeObjectStrip.mask))
    }

    // MARK: History

    private func ref(_ name: String, _ kind: KubeResourceKind = .pods, context: String = "fake-dev") -> KubeObjectRef {
        KubeObjectRef(context: context, kind: kind, namespace: kind.namespaced ? "shop" : nil, name: name)
    }

    func testTheHistoryGoesBackAndForwardAcrossKinds() {
        var history = KubeHistory()
        XCTAssertFalse(history.canGoBack || history.canGoForward)
        history.visit(ref("web-1"), from: .list)
        history.visit(ref("web-2"), from: .list)
        XCTAssertEqual(history.current, ref("web-2"))
        XCTAssertFalse(history.canGoBack, "walking the list replaces, it doesn't pile up")
        history.visit(ref("web-rs", KubeResourceKind(group: "apps", version: "v1", resource: "replicasets", kind: "ReplicaSet", singular: "replicaset", namespaced: true, verbs: [])), from: .link)
        history.visit(ref("fake-node-1", KubeResourceKind(group: "", version: "v1", resource: "nodes", kind: "Node", singular: "node", namespaced: false, verbs: [])), from: .link)
        XCTAssertEqual(history.back.map(\.name), ["web-2", "web-rs"])
        XCTAssertNil(history.current?.namespace, "a node is cluster-wide")

        XCTAssertEqual(history.goBack()?.name, "web-rs")
        XCTAssertEqual(history.goBack()?.name, "web-2")
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.current?.name, "web-2")
        XCTAssertEqual(history.forward.map(\.name), ["fake-node-1", "web-rs"])
        XCTAssertEqual(history.goForward()?.name, "web-rs")

        // A new visit drops what was ahead; the same one again is no visit.
        history.visit(ref("api-0"), from: .link)
        XCTAssertFalse(history.canGoForward)
        history.visit(ref("api-0"), from: .link)
        XCTAssertEqual(history.back.map(\.name), ["web-2", "web-rs"])

        // A list visit after a link is a visit of its own.
        history.visit(ref("web-3"), from: .list)
        XCTAssertEqual(history.back.last?.name, "api-0")

        // Closed, back shows it again.
        history.leave()
        XCTAssertNil(history.current)
        XCTAssertEqual(history.goBack()?.name, "web-3")

        // Closed and opened again from the list: back doesn't step to itself.
        history.leave()
        history.visit(ref("web-3"), from: .list)
        XCTAssertNotEqual(history.back.last, ref("web-3"))
        XCTAssertEqual(history.back.last?.name, "api-0")

        // A row of another kind's list (or context's) is a visit of its own.
        let secrets = KubeResourceKind(group: "", version: "v1", resource: "secrets", kind: "Secret", singular: "secret", namespaced: true, verbs: [])
        let deployments = KubeResourceKind(group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true, verbs: [])
        var lists = KubeHistory()
        lists.visit(ref("worker", deployments), from: .list)
        lists.visit(ref("web-tls", secrets), from: .list)
        XCTAssertEqual(lists.back, [ref("worker", deployments)])
        lists.visit(ref("api-tls", secrets), from: .list)
        XCTAssertEqual(lists.back, [ref("worker", deployments)], "the same list walked replaces")
        lists.visit(ref("api-tls", secrets, context: "fake-prod"), from: .list)
        XCTAssertEqual(lists.back.last, ref("api-tls", secrets))

        var short = KubeHistory(limit: 2)
        for name in ["a", "b", "c", "d"] { short.visit(ref(name), from: .link) }
        XCTAssertEqual(short.back.map(\.name), ["b", "c"], "the oldest go first")
        short.clear()
        XCTAssertNil(short.current)
        XCTAssertFalse(short.canGoBack)
        XCTAssertEqual(short.limit, 2)
    }

    // MARK: Events, selectors, links

    func testEventsAreReadNewestFirst() throws {
        let list: [String: Any] = [
            "kind": "EventList",
            "items": [
                [
                    "metadata": ["name": "a", "uid": "1"], "type": "Normal", "reason": "Scheduled", "message": "Assigned shop/web to fake-node-1",
                    "lastTimestamp": "2026-11-04T10:00:00Z", "source": ["component": "default-scheduler"],
                ],
                [
                    "metadata": ["name": "b", "uid": "2"], "type": "Warning", "reason": "BackOff", "message": "Back-off restarting failed container\n",
                    "count": 7, "firstTimestamp": "2026-11-04T10:01:00Z", "lastTimestamp": "2026-11-04T10:09:00Z",
                    "source": ["component": "kubelet", "host": "fake-node-1"],
                ],
                [
                    "metadata": ["name": "c", "uid": "3"], "type": "Normal", "reason": "Pulled", "message": "pulled",
                    "eventTime": "2026-11-04T10:05:00.123456Z", "reportingComponent": "kubelet", "series": ["count": 2, "lastObservedTime": "2026-11-04T10:06:00.000001Z"],
                ],
            ],
        ]
        let events = try KubeEvent.list(JSONSerialization.data(withJSONObject: list))
        XCTAssertEqual(events.map(\.reason), ["BackOff", "Pulled", "Scheduled"])
        XCTAssertTrue(events[0].isWarning)
        XCTAssertEqual(events[0].count, 7)
        XCTAssertEqual(events[0].message, "Back-off restarting failed container")
        XCTAssertEqual(events[0].source, "kubelet, fake-node-1")
        XCTAssertEqual(events[1].count, 2, "a series' count")
        let observed = try XCTUnwrap(events[1].last)
        XCTAssertEqual(observed.timeIntervalSince(try XCTUnwrap(KubeTime.date("2026-11-04T10:06:00Z"))), 0, accuracy: 0.01, "MicroTime read")
        XCTAssertEqual(
            KubeEvent.fieldSelector(kind: "Pod", name: "web", namespace: "shop", uid: "u-1"),
            "involvedObject.name=web,involvedObject.namespace=shop,involvedObject.kind=Pod,involvedObject.uid=u-1")
        XCTAssertEqual(KubeEvent.fieldSelector(kind: "Node", name: "n", namespace: nil, uid: nil), "involvedObject.name=n,involvedObject.kind=Node")
    }

    func testSelectorsAreSaidAsAListAsksForThem() {
        XCTAssertEqual(
            KubeSelector.text([
                "matchLabels": ["app": "web", "tier": "front"],
                "matchExpressions": [
                    ["key": "env", "operator": "In", "values": ["prod", "dev"]], ["key": "legacy", "operator": "DoesNotExist"],
                    ["key": "track", "operator": "Exists"], ["key": "zone", "operator": "NotIn", "values": ["b"]],
                ],
            ]), "app=web,tier=front,env in (dev,prod),!legacy,track,zone notin (b)")
        XCTAssertEqual(KubeSelector.text(["app": "web"]), "app=web", "a Service's plain map")
        XCTAssertNil(KubeSelector.text([:] as [String: Any]))
        XCTAssertNil(KubeSelector.text(nil))
    }

    func testALinkIsResolvedAsTheContextServesItsKind() {
        let discovery = KubeDiscovery(kinds: [
            .pods,
            KubeResourceKind(group: "apps", version: "v1", resource: "replicasets", kind: "ReplicaSet", singular: "replicaset", namespaced: true, verbs: ["get"]),
            KubeResourceKind(group: "", version: "v1", resource: "nodes", kind: "Node", singular: "node", namespaced: false, verbs: ["get"]),
        ])
        let owner = KubeLink(apiVersion: "apps/v1", kind: "ReplicaSet", namespace: "shop", name: "web-7d9f").resolve(in: discovery, context: "fake-dev")
        XCTAssertEqual(owner?.kind.fullName, "replicasets.apps")
        XCTAssertEqual(owner?.namespace, "shop")
        let node = KubeLink(apiVersion: "v1", kind: "Node", namespace: "shop", name: "fake-node-1").resolve(in: discovery, context: "fake-dev")
        XCTAssertNil(node?.namespace, "a cluster-scoped kind has none")
        XCTAssertEqual(
            KubeLink(apiVersion: "apps/v1beta2", kind: "ReplicaSet", namespace: "shop", name: "x").resolve(in: discovery, context: "c")?.kind.version, "v1",
            "another version of the group: the one served")
        XCTAssertNil(KubeLink(apiVersion: "example.com/v1", kind: "Widget", namespace: nil, name: "w").resolve(in: discovery, context: "c"))
    }

    // MARK: Overviews

    func testAPodsOverview() {
        let pod: [String: Any] = [
            "kind": "Pod", "apiVersion": "v1",
            "metadata": [
                "name": "web-7d9", "namespace": "shop", "uid": "u-pod", "creationTimestamp": "2026-11-04T10:00:00Z", "labels": ["app": "web"],
                "annotations": [KubeObjectStrip.lastApplied: "{}"],
                "ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-7d9f", "controller": true]],
            ],
            "spec": [
                "nodeName": "fake-node-1", "serviceAccountName": "web",
                "containers": [["name": "app", "image": "nginx:1.27"], ["name": "sidecar", "image": "envoy:1.30"]],
            ],
            "status": [
                "phase": "Running", "podIP": "10.0.0.10", "qosClass": "Burstable",
                "conditions": [["type": "Ready", "status": "False", "reason": "ContainersNotReady"]],
                "containerStatuses": [
                    ["name": "app", "ready": true, "restartCount": 0, "state": ["running": ["startedAt": "2026-11-04T10:00:05Z"]]],
                    [
                        "name": "sidecar", "ready": false, "restartCount": 4, "state": ["waiting": ["reason": "CrashLoopBackOff"]],
                        "lastState": ["terminated": ["reason": "OOMKilled", "exitCode": 137]],
                    ],
                ],
            ],
        ]
        let overview = KubeOverview.of(pod, now: KubeTime.date("2026-11-04T10:30:00Z")!)
        XCTAssertEqual(overview.item("Phase")?.value, "Running")
        XCTAssertEqual(overview.item("Phase")?.tone, .good)
        XCTAssertEqual(overview.item("Node")?.link, KubeLink(apiVersion: "v1", kind: "Node", namespace: nil, name: "fake-node-1"))
        XCTAssertEqual(overview.item("Pod IP")?.value, "10.0.0.10")
        XCTAssertEqual(overview.item("QoS")?.value, "Burstable")
        let containers = overview.section("Containers")?.items ?? []
        XCTAssertEqual(containers.map(\.label), ["app", "sidecar"])
        XCTAssertEqual(containers[0].value, "Running, ready")
        XCTAssertEqual(containers[0].detail, "nginx:1.27")
        XCTAssertEqual(containers[1].value, "CrashLoopBackOff · 4 restarts · last: OOMKilled (exit 137)")
        XCTAssertEqual(containers[1].tone, .bad)
        XCTAssertEqual(
            overview.section("Owned by")?.items.first?.link, KubeLink(apiVersion: "apps/v1", kind: "ReplicaSet", namespace: "shop", name: "web-7d9f"))
        XCTAssertEqual(overview.section("Conditions")?.items.first?.tone, .waiting)
        XCTAssertEqual(overview.item("Created")?.value, "30m ago")
        XCTAssertEqual(overview.section("Labels")?.items.map(\.label), ["app"])
        XCTAssertNil(overview.section("Annotations"), "last-applied left out; nothing else")
        XCTAssertNil(overview.pods)
    }

    func testAWorkloadsServicesNodesAndConfigMapsOverview() {
        var object = deployment(updated: 2, available: 2)
        object["metadata"] = ["name": "web", "namespace": "shop", "generation": 2]
        object["spec"] = [
            "replicas": 3, "strategy": ["type": "RollingUpdate", "rollingUpdate": ["maxSurge": "25%", "maxUnavailable": 0]],
            "selector": ["matchLabels": ["app": "web"]], "template": ["spec": ["containers": [["name": "app", "image": "nginx:1.27"]]]],
        ]
        let workload = KubeOverview.of(object)
        XCTAssertEqual(workload.item("Replicas")?.value, "2/3 ready")
        XCTAssertEqual(workload.rollout?.state, .progressing)
        XCTAssertEqual(workload.item("Rollout")?.tone, .waiting)
        XCTAssertEqual(workload.item("Strategy")?.value, "RollingUpdate · maxSurge 25% · maxUnavailable 0")
        XCTAssertEqual(workload.item("Selector")?.value, "app=web")
        XCTAssertEqual(workload.pods?.namespace, "shop")
        XCTAssertEqual(workload.pods?.selector, "app=web")
        XCTAssertEqual(workload.section("Replicas")?.items.map(\.label), ["Desired", "Ready", "Updated", "Available"])

        let service = KubeOverview.of([
            "kind": "Service", "apiVersion": "v1", "metadata": ["name": "web", "namespace": "shop"],
            "spec": [
                "type": "NodePort", "clusterIP": "10.96.0.12", "selector": ["app": "web"],
                "ports": [["name": "http", "port": 80, "protocol": "TCP", "targetPort": 8080, "nodePort": 30080]],
            ],
        ])
        XCTAssertEqual(service.item("Type")?.value, "NodePort")
        XCTAssertEqual(service.item("Cluster IP")?.value, "10.96.0.12")
        XCTAssertEqual(service.section("Ports")?.items.first?.value, "80/TCP → 8080 · node port 30080")
        XCTAssertEqual(service.pods?.selector, "app=web")

        let node = KubeOverview.of([
            "kind": "Node", "apiVersion": "v1",
            "metadata": ["name": "fake-node-1", "labels": ["node-role.kubernetes.io/control-plane": "", "node.kubernetes.io/instance-type": "m7g.large"]],
            "spec": ["taints": [["key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule"]]],
            "status": [
                "conditions": [["type": "Ready", "status": "True"], ["type": "MemoryPressure", "status": "False"]],
                "nodeInfo": ["kubeletVersion": "v1.34.1", "osImage": "Bottlerocket"], "capacity": ["cpu": "2", "memory": "8Gi", "pods": "110"],
                "allocatable": ["cpu": "1930m", "memory": "7Gi", "pods": "110"],
            ],
        ])
        XCTAssertEqual(node.item("Ready")?.tone, .good)
        XCTAssertEqual(node.item("Roles")?.value, "control-plane")
        XCTAssertEqual(node.item("Version")?.value, "v1.34.1")
        XCTAssertEqual(node.item("Instance type")?.value, "m7g.large")
        XCTAssertEqual(node.section("Capacity · allocatable")?.items.map(\.label), ["cpu", "memory", "pods"])
        XCTAssertEqual(node.section("Capacity · allocatable")?.items.first?.value, "2 · 1930m")
        XCTAssertEqual(node.section("Taints")?.items.first?.value, "NoSchedule")
        XCTAssertEqual(node.section("Conditions")?.items.map(\.tone), [.good, .good], "a pressure condition that is False is good")

        let config = KubeOverview.of(["kind": "ConfigMap", "apiVersion": "v1", "metadata": ["name": "c"], "data": ["nginx.conf": "worker_processes 1;"]])
        XCTAssertEqual(config.section("Data")?.items.first?.value, "worker_processes 1;", "a ConfigMap's values are shown")

        let job = KubeOverview.of([
            "kind": "Job", "apiVersion": "batch/v1", "metadata": ["name": "j", "namespace": "shop"],
            "spec": ["completions": 2, "selector": ["matchLabels": ["batch.kubernetes.io/controller-uid": "u"]]],
            "status": ["succeeded": 2, "conditions": [["type": "Complete", "status": "True"]]],
        ])
        XCTAssertEqual(job.item("Status")?.value, "Complete")
        XCTAssertEqual(job.item("Completions")?.value, "2/2")
        XCTAssertEqual(job.pods?.selector, "batch.kubernetes.io/controller-uid=u")

        let generic = KubeOverview.of([
            "kind": "Widget", "apiVersion": "example.com/v1",
            "metadata": ["name": "blue-1", "namespace": "shop", "annotations": ["note": "hi"]],
            "status": ["conditions": [["type": "Ready", "status": "True", "message": "all good"]]],
        ])
        XCTAssertTrue(generic.facts.isEmpty)
        XCTAssertEqual(generic.section("Conditions")?.items.first?.detail, "all good")
        XCTAssertEqual(generic.section("Annotations")?.items.first?.value, "hi")
    }

    // MARK: The page's detail, against the fake

    private var api: FakeKubeAPI!
    private var socket: String!

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests.filter { !$0.isLog }, [], "no subresource but a pod's log")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "no Secret read")
            api.stop()
        }
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pageOverFake() throws -> (KubernetesModel, KubernetesPageModel) {
        socket = "/tmp/otkd-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1"],
            fields: [
                "metadata": ["generation": 1],
                "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]], "strategy": ["type": "RollingUpdate"]],
                "status": ["observedGeneration": 1, "replicas": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1],
            ])
        api.add(
            "replicasets.apps", "web-7d9f", namespace: "shop",
            fields: [
                "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "controller": true]]],
                "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]]], "status": ["replicas": 1, "readyReplicas": 1],
            ])
        api.addPod("web-7d9", namespace: "shop", labels: ["app": "web"])
        api.addPod("other", namespace: "shop", labels: ["app": "other"])
        api.setFields(
            "pods", "web-7d9", namespace: "shop",
            ["metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-7d9f", "controller": true]]]])
        api.add("secrets", "web-tls", namespace: "shop", values: ["Type": "kubernetes.io/tls"], data: ["tls.key": "fake-key"])
        api.addEvent(about: "pods", "web-7d9", namespace: "shop", reason: "Scheduled", message: "Assigned", last: Date().addingTimeInterval(-600))
        api.addEvent(about: "pods", "web-7d9", namespace: "shop", type: "Warning", reason: "Unhealthy", message: "Readiness probe failed", count: 3)
        api.addEvent(about: "pods", "other", namespace: "shop", reason: "Pulled", message: "not this one's")

        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        let other = KubeContext(
            name: "fake-prod", cluster: "fake-prod", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .production, settings: KubeContextSettings())
        let list = KubeContextList(contexts: [context, other], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return (model, KubernetesPageModel(model: model))
    }

    func testTheDetailReadsOneObjectAndFollowsItsLinks() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        try await until(5, "pods listed") { model.rows.count == 2 && model.discovery != nil }

        // ↩ on the selected row: one GET of the object.
        XCTAssertFalse(page.press("\r"), "nothing selected: ↩ is the list's")
        page.selection = ["shop/web-7d9"]
        XCTAssertNil(page.detail, "a selection alone doesn't open it")
        api.forgetRequests()
        XCTAssertTrue(page.press("\r"))
        let pod = try XCTUnwrap(page.detail)
        XCTAssertEqual(pod.ref, KubeObjectRef(context: "fake-dev", kind: model.kind, namespace: "shop", name: "web-7d9"))
        try await until(5, "loaded") { pod.state == .loaded }
        XCTAssertEqual(api.requests.map(\.path), ["/api/v1/namespaces/shop/pods/web-7d9"], "one GET")
        XCTAssertEqual(pod.overview?.item("Phase")?.value, "Running")
        XCTAssertEqual(pod.overview?.item("Node")?.value, "fake-node-1")
        XCTAssertEqual(pod.overview?.section("Containers")?.items.first?.detail, "nginx:1.27")
        XCTAssertFalse(pod.yaml.contains("managedFields"), "stripped")
        XCTAssertTrue(pod.yaml.contains("image: nginx:1.27"))
        pod.showsHidden = true
        XCTAssertTrue(pod.yaml.contains("managedFields:"))
        pod.showsHidden = false

        // Events: asked once the tab shows, by the object's uid; newest first.
        XCTAssertEqual(pod.events, .idle)
        page.showTab(.events)
        try await until(5, "events") { pod.events.value != nil }
        XCTAssertEqual(pod.events.value?.map(\.reason), ["Unhealthy", "Scheduled"], "its own, newest first")
        XCTAssertEqual(pod.events.value?.first?.isWarning, true)
        let uid = try XCTUnwrap(api.uid("pods", "web-7d9", namespace: "shop"))
        let asked = try XCTUnwrap(api.requests.last { $0.path == "/api/v1/namespaces/shop/events" })
        XCTAssertEqual(
            asked.query["fieldSelector"],
            "involvedObject.name=web-7d9,involvedObject.namespace=shop,involvedObject.kind=Pod,involvedObject.uid=\(uid)")
        page.showTab(.overview)

        // Its owner, then the owner's owner: links across kinds.
        let owner = try XCTUnwrap(pod.overview?.section("Owned by")?.items.first?.link)
        XCTAssertTrue(page.follow(owner))
        let replicaSet = try XCTUnwrap(page.detail)
        XCTAssertEqual(replicaSet.ref.kind.fullName, "replicasets.apps")
        try await until(5, "rs") { replicaSet.state == .loaded }
        let deploymentLink = try XCTUnwrap(replicaSet.overview?.section("Owned by")?.items.first?.link)
        page.follow(deploymentLink)
        let deployment = try XCTUnwrap(page.detail)
        try await until(5, "deployment") { deployment.state == .loaded }
        XCTAssertEqual(deployment.overview?.rollout?.state, .complete)
        XCTAssertEqual(deployment.overview?.item("Replicas")?.value, "1/1 ready")

        // The pods its selector picks: one list, rows only, its own.
        deployment.loadPods()
        try await until(5, "selected pods") { deployment.pods.value != nil }
        XCTAssertEqual(deployment.pods.value?.map(\.row.id.name), ["web-7d9"])
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=web" && !$0.isWatch })

        // Back and forward: [ ], ⌘[ ⌘].
        XCTAssertEqual(page.history.back.map(\.name), ["web-7d9", "web-7d9f"])
        XCTAssertTrue(page.press("["))
        XCTAssertEqual(page.detail?.ref.name, "web-7d9f")
        XCTAssertTrue(page.commandPress("["))
        XCTAssertEqual(page.detail?.ref.name, "web-7d9")
        XCTAssertFalse(page.commandPress("["), "nothing behind: the menus' ⌘[")
        XCTAssertTrue(page.commandPress("]"))
        XCTAssertEqual(page.detail?.ref.kind.fullName, "replicasets.apps")
        _ = page.press("]")
        XCTAssertEqual(page.detail?.ref.kind.fullName, "deployments.apps")

        // A selected pod opens; the list's arrows then move the detail.
        page.openPod(try XCTUnwrap(deployment.pods.value?.first))
        XCTAssertEqual(page.detail?.ref.name, "web-7d9")
        page.selection = ["shop/other"]
        XCTAssertEqual(page.detail?.ref.name, "other", "an open detail follows the list")

        // Esc closes it; [ brings it back.
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertNil(page.detail)
        XCTAssertFalse(page.press("\u{1B}"), "nothing open: Esc goes on")
        _ = page.press("[")
        XCTAssertEqual(page.detail?.ref.name, "other")

        // A click on a row opens its detail.
        page.closeDetail()
        page.pressed("shop/web-7d9")
        XCTAssertEqual(page.detail?.ref.name, "web-7d9")

        // A link to a kind nobody serves says so.
        XCTAssertFalse(page.follow(KubeLink(apiVersion: "example.com/v1", kind: "Widget", namespace: "shop", name: "w")))
        XCTAssertEqual(page.linkProblem, "fake-dev serves no Widget (example.com/v1).")

        // Another context: the detail and its history go.
        model.select("fake-prod")
        XCTAssertNil(page.detail)
        XCTAssertFalse(page.history.canGoBack)
    }

    func testEventsShownWhileNavigatingAreAskedByTheNewObjectsUid() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        try await until(5, "pods listed") { model.rows.count == 2 && model.discovery != nil }
        page.selection = ["shop/web-7d9"]
        XCTAssertTrue(page.openSelected())
        page.showTab(.events)
        let pod = try XCTUnwrap(page.detail)
        try await until(5, "pod's events") { pod.events.value != nil }
        let owner = try XCTUnwrap(pod.overview?.section("Owned by")?.items.first?.link)

        // The Events tab still showing: a link followed asks once the GET answers, by the uid.
        api.forgetRequests()
        XCTAssertTrue(page.follow(owner))
        let replicaSet = try XCTUnwrap(page.detail)
        try await until(5, "rs events") { replicaSet.events.value != nil }
        let uid = try XCTUnwrap(api.uid("replicasets.apps", "web-7d9f", namespace: "shop"))
        let asked = api.requests.filter { $0.path == "/api/v1/namespaces/shop/events" }
        XCTAssertEqual(asked.count, 1, "\(asked)")
        XCTAssertEqual(
            asked.first?.query["fieldSelector"],
            "involvedObject.name=web-7d9f,involvedObject.namespace=shop,involvedObject.kind=ReplicaSet,involvedObject.uid=\(uid)")

        // Back, too.
        api.forgetRequests()
        XCTAssertTrue(page.press("["))
        let again = try XCTUnwrap(page.detail)
        try await until(5, "pod's events again") { again.events.value != nil }
        let podUID = try XCTUnwrap(api.uid("pods", "web-7d9", namespace: "shop"))
        XCTAssertEqual(
            api.requests.last { $0.path == "/api/v1/namespaces/shop/events" }?.query["fieldSelector"]?.hasSuffix("involvedObject.uid=\(podUID)"), true)
    }

    func testASecretsDetailNeverReadsIt() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil }
        let secrets = try XCTUnwrap(model.discovery?.kind("secrets"))
        page.showKind(secrets)
        try await until(5, "secrets listed") { model.rows.count == 1 && model.kind.fullName == "secrets" }
        api.forgetRequests()
        page.selection = ["shop/web-tls"]
        XCTAssertTrue(page.openSelected())
        let detail = try XCTUnwrap(page.detail)
        XCTAssertEqual(detail.state, .withheld)
        detail.load()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(detail.object)
        XCTAssertEqual(detail.yaml, "")
        XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "\(api.requests)")
        // Its events are no secret.
        page.showTab(.events)
        try await until(5, "events") { detail.events.value != nil }
        XCTAssertEqual(detail.events.value, [])
    }

    /// A pod's logs: `l` (and ↩ on a pod) open its Logs tab, read only
    /// while the tab shows on a page on screen — the stream closed with
    /// another tab, the page hidden, the detail closed — and resumed from
    /// its last line when shown again; another kind has no Logs. ⌘L's lines
    /// go to the agent scrubbed, with the pod they come from.
    func testAPodsLogsAreReadOnlyWhileTheyShow() async throws {
        let (model, page) = try pageOverFake()
        api.updatePod("web-7d9", namespace: "shop") { $0.env = ["API_TOKEN": "tok-fake-123"] }
        api.setLog("web-7d9", namespace: "shop", ["ready", "using tok-fake-123 Authorization: Bearer abc.def"])
        var asked: (String, AskAgentModel.Part)?
        var saved: (String, String)?
        page.actions = KubernetesActions(
            run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in }, save: { saved = ($0, $1) }, askAgent: { asked = ($0, $1) })
        model.show()
        defer { model.hide() }
        try await until(5, "pods listed") { model.rows.count == 2 }
        func logs() -> [FakeKubeAPI.Request] { api.requests.filter(\.isLog) }

        page.selection = ["shop/web-7d9"]
        XCTAssertTrue(page.press("l"), "l: the pod's logs")
        let pod = try XCTUnwrap(page.detail)
        XCTAssertEqual(page.detailTab, .logs)
        XCTAssertEqual(KubeDetailTab.tabs(for: pod.ref), [.overview, .logs, .yaml, .events, .metrics])
        let session = try XCTUnwrap(pod.logs)
        try await until(5, "the pod read") { pod.state == .loaded && session.container == "app" }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(logs(), [], "the page isn't on screen: nothing read")

        page.visible = true
        try await until(5, "its lines") { session.feed.lines.count == 2 && self.api.openLogStreams == 1 }
        XCTAssertEqual(logs().count, 1)
        XCTAssertEqual(page.detailKubectl, "kubectl --context fake-dev -n shop logs web-7d9 -c app --timestamps")
        page.showTab(.overview)
        try await until(5, "closed with another tab") { self.api.openLogStreams == 0 }
        api.appendLog("web-7d9", namespace: "shop", "while away")
        page.showTab(.logs)
        try await until(5, "resumed") { session.feed.lines.map(\.message).last == "while away" && self.api.openLogStreams == 1 }
        XCTAssertNotNil(logs().last?.query["sinceTime"], "from its last line, not its tail again")
        XCTAssertEqual(session.feed.lines.count, 3, "nothing twice")
        page.visible = false
        try await until(5, "closed with the page hidden") { self.api.openLogStreams == 0 }
        page.visible = true
        try await until(5, "open again") { self.api.openLogStreams == 1 }
        // The window off screen (occluded, minimised): closed too, nothing asked meanwhile.
        page.windowVisible = false
        try await until(5, "closed with the window hidden") { self.api.openLogStreams == 0 }
        let whileHidden = logs().count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(logs().count, whileHidden, "nothing read while the window is hidden")
        page.windowVisible = true
        try await until(5, "open with the window shown") { self.api.openLogStreams == 1 }

        // ⌘F with the Logs tab showing: its filter; on another tab, not the page's.
        let focus = page.focusLogFilter
        XCTAssertTrue(page.commandPress("f"))
        XCTAssertEqual(page.focusLogFilter, focus + 1)
        page.showTab(.yaml)
        XCTAssertFalse(page.commandPress("f"), "no log filter on another tab")
        page.showTab(.logs)
        try await until(5, "open on its tab again") { self.api.openLogStreams == 1 }

        // ⌘L: scrubbed — the pod's own env value, the bearer token — with the pod it comes from.
        page.askAboutLogLines("using tok-fake-123 Authorization: Bearer abc.def")
        let (text, about) = try XCTUnwrap(asked)
        XCTAssertFalse(text.contains("tok-fake-123") || text.contains("abc.def"), text)
        XCTAssertEqual(about.title, "pod/web-7d9")
        XCTAssertTrue(about.text.contains("kubectl --context fake-dev -n shop logs web-7d9 -c app"), about.text)
        page.saveLogs("ready\n")
        XCTAssertEqual(saved?.0.hasPrefix("web-7d9-app-"), true)
        XCTAssertEqual(saved?.0.hasSuffix(".log"), true)

        // ↩ on a pod: its logs; another kind's detail has none.
        page.closeDetail()
        try await until(5, "closed with the detail") { self.api.openLogStreams == 0 }
        page.showTab(.overview)
        page.selection = ["shop/other"]
        XCTAssertTrue(page.press("\r"))
        XCTAssertEqual(page.detailTab, .logs, "↩ on a pod opens its logs")
        let other = try XCTUnwrap(page.detail?.logs)
        try await until(5, "the other pod's log follows") { other.feed.following && self.api.openLogStreams == 1 }
        // `m`: its Metrics tab, its own usage polled; `,` and `.` its range — Live and 6h without Prometheus.
        XCTAssertFalse(page.press("."), "no range to step off the Metrics tab")
        XCTAssertTrue(page.press("m"), "m: the pod's Metrics tab")
        XCTAssertEqual(page.detailTab, .metrics)
        try await until(5, "its log closed with the tab") { self.api.openLogStreams == 0 }
        XCTAssertEqual(page.metricsDetailsOnScreen, [.pod(namespace: "shop", name: "other")], "the pod's own sample, while the tab shows")
        XCTAssertTrue(page.press("."))
        XCTAssertEqual(page.metricsRange, .sixHours, "1h needs Prometheus: stepped over")
        XCTAssertTrue(page.press("."))
        XCTAssertEqual(page.metricsRange, .sixHours, "the last one that can be picked")
        XCTAssertTrue(page.press(","))
        XCTAssertEqual(page.metricsRange, .live)
        XCTAssertEqual(page.detailKubectl, "kubectl --context fake-dev -n shop top pod other --containers")
        page.showTab(.logs)
        XCTAssertTrue(page.metricsDetailsOnScreen.isEmpty, "the Logs tab reads no usage")
        try await until(5, "followed again on its tab") { other.feed.following && self.api.openLogStreams == 1 }
        // Another context: the detail goes, and its stream with it.
        let beforeSwitch = logs().count
        model.select("fake-prod")
        try await until(5, "closed with the context") { page.detail == nil && self.api.openLogStreams == 0 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(logs().count, beforeSwitch, "nothing read after the context changed")
        XCTAssertFalse(other.feed.following)
        model.select("fake-dev")
        try await until(5, "fake-dev again") { model.selectedName == "fake-dev" && model.rows.count == 2 && model.discovery != nil }
        let deployments = try XCTUnwrap(model.discovery?.kind("deployments"))
        page.showKind(deployments)
        try await until(5, "deployments") { model.kind.fullName == "deployments.apps" && model.rows.count == 1 }
        page.selection = ["shop/web"]
        XCTAssertTrue(page.press("\r"))
        XCTAssertEqual(page.detailTab, .overview, "a deployment's ↩ opens its Overview")
        XCTAssertNil(page.detail?.logs, "no pod's log")
        XCTAssertEqual(KubeDetailTab.tabs(for: try XCTUnwrap(page.detail?.ref)), [.overview, .logs, .yaml, .events, .history, .metrics])
        try await until(5, "nothing open") { self.api.openLogStreams == 0 }
        // `l` on a deployment: its pods' logs, merged.
        XCTAssertTrue(page.press("l"), "l: a deployment's pods' logs")
        XCTAssertEqual(page.detailTab, .logs)
        try await until(5, "merged") { page.detail?.merged != nil }
        let merged = try XCTUnwrap(page.detail?.merged)
        XCTAssertEqual(merged.title, "deployment/web")
        XCTAssertEqual(page.detailKubectl?.hasPrefix("kubectl --context fake-dev -n shop logs -l app=web --all-containers --prefix"), true, page.detailKubectl ?? "")
        page.showTab(.overview)
        try await until(5, "hidden with another tab") { !merged.watching && self.api.openLogStreams == 0 }
        page.visible = false
    }
}
