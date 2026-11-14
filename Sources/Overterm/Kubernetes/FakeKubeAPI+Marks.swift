import Foundation

/// A spoke cluster on the fake (docs/design/kubernetes/gitops.md, 14.9.1):
/// Argo CD runs in another cluster, so no Application is served here — only
/// the marks it leaves on what it deploys, shaped as the surveyed spokes
/// carry them: app names `<env>-<ns>-<name>-service` (and the shorter
/// forms) that never equal a workload's own name, every tracking id naming
/// its own object, and a few copied ones on HPAs, PodDisruptionBudgets and
/// every ReplicaSet. Each workload's cells and object agree, except where
/// a state below says otherwise. `serveArgoCD()` and `serveFlux()` are
/// never called. Fictional names only; the sentinel sits in every place a
/// value can hide (kubectl's last-applied copy, env, annotations, Secrets
/// and ConfigMaps that carry marks and are never to be read).
extension FakeKubeAPI {
    /// What a spoke is made of.
    struct SpokeOptions: Sendable {
        /// The plain apps, beyond the named states below.
        var apps = 40
        var env = "prod"
        var namespaces = (0..<10).map { "team-\($0)" }
        /// kubectl's last-applied copy on every workload, this many bytes.
        var padding = 5_000
        /// Argo Rollouts served, with marked Rollouts that run a Deployment
        /// by `workloadRef`, its Deployment scaled to 0.
        var rollouts = false
        /// The named states (stuck, stalled, paused…).
        var states = true
        /// The first this many plain apps carry another installation's id
        /// (`argocd.argoproj.io/installation-id: hub-b`) on every member:
        /// two Argo CDs marking objects here, never merged.
        var otherInstallation = 0
    }

    /// The second installation's id `otherInstallation` puts on its apps.
    static let spokeInstallation = "hub-b"

    /// What `addSpoke` made, by what the tests look for.
    struct Spoke: Sendable {
        var apps: [String] = []
        /// A single-replica rollout stuck behind its old pod: cells `1/1`.
        var stuck = ""
        /// A rollout past its progress deadline.
        var stalled = ""
        /// Paused, its cells `2/2`: only its object says so.
        var paused = ""
        /// A StatefulSet `0/3`: Progressing, never Failed.
        var statefulSet = ""
        /// An HPA whose metrics can't be read: Degraded.
        var hpa = ""
        /// A Service and an Ingress only: Unknown, no workload read.
        var serviceOnly = ""
        /// A LoadBalancer Service `<pending>`.
        var loadBalancer = ""
        /// A CronJob whose last run failed.
        var cronJob = ""
        /// A PVC Pending.
        var claim = ""
        /// Its hook Job failed, which isn't its health.
        var hooked = ""
        /// Carried by `argocd.argoproj.io/instance` alone.
        var labelOnly = ""
        /// A Rollout's app: Healthy, its Deployment scaled by it.
        var rollout = ""
        /// A Degraded Rollout's app.
        var rolloutDegraded = ""
        /// The plain apps' Deployments: (namespace, name).
        var deployments: [(namespace: String, name: String)] = []
    }

    /// The spoke: no Argo CD, no Flux; marked workloads, Services, HPAs,
    /// PVCs, Ingresses, CronJobs and hook Jobs; copied marks on every
    /// ReplicaSet and some HPAs and PDBs; garbled marks; Helm's
    /// instance labels; Secrets and ConfigMaps that carry marks.
    @discardableResult
    func addSpoke(_ options: SpokeOptions = SpokeOptions(), now: Date = Date()) -> Spoke {
        for namespace in options.namespaces { addNamespace(namespace) }
        var spoke = Spoke()
        let env = options.env
        let spaces = options.namespaces
        func app(_ index: Int, _ name: String, _ namespace: String) -> String {
            // The survey's forms: mostly `<env>-<ns>-<name>-service`.
            switch index % 10 {
            case 0...5: "\(env)-\(namespace)-\(name)-service"
            case 6...8: "\(env)-\(namespace)-\(name)"
            default: "\(env)-\(name)"
            }
        }
        for index in 0..<options.apps {
            let namespace = spaces[index % spaces.count]
            let name = String(format: "acme-svc-%03d", index)
            let instance = app(index, name, namespace)
            spoke.apps.append(instance)
            spoke.deployments.append((namespace, name))
            let installation = index < options.otherInstallation ? Self.spokeInstallation : nil
            let marked = installation.map { [KubeTrackingID.installationAnnotation: $0] } ?? [:]
            addMarkedDeployment(name, namespace: namespace, app: instance, annotations: marked, padding: options.padding, now: now)
            addMarkedService(name, namespace: namespace, app: instance, installation: installation, now: now)
            if index % 3 == 0 { addMarkedHPA(name, namespace: namespace, app: instance, installation: installation, now: now) }
            // A copy on a few HPAs and PDBs: their Deployment's own mark.
            if index % 7 == 1 { addCopiedMark("horizontalpodautoscalers.autoscaling", "\(name)-extra", namespace: namespace, app: instance, of: name, now: now) }
            if index % 9 == 2 { addCopiedMark("poddisruptionbudgets.policy", name, namespace: namespace, app: instance, of: name, now: now) }
        }
        guard options.states else { return spoke }
        let ns = { (index: Int) in spaces[index % spaces.count] }

        spoke.stuck = "\(env)-\(ns(1))-acme-pay-service"
        addMarkedDeployment(
            "acme-pay", namespace: ns(1), app: spoke.stuck, ready: 1, desired: 1, padding: options.padding, now: now,
            status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1, "unavailableReplicas": 1],
            progressing: ("True", "ReplicaSetUpdated"))

        spoke.stalled = "\(env)-\(ns(2))-acme-cart-service"
        addMarkedDeployment(
            "acme-cart", namespace: ns(2), app: spoke.stalled, ready: 1, desired: 2, updated: 1, available: 1, padding: options.padding, now: now,
            status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1], progressing: ("False", "ProgressDeadlineExceeded"))
        addMarkedService("acme-cart", namespace: ns(2), app: spoke.stalled, now: now)

        spoke.paused = "\(env)-\(ns(3))-acme-batch-service"
        addMarkedDeployment("acme-batch", namespace: ns(3), app: spoke.paused, padding: options.padding, now: now, paused: true)

        spoke.statefulSet = "\(env)-\(ns(4))-acme-ledger-service"
        addMarkedStatefulSet("acme-ledger-db", namespace: ns(4), app: spoke.statefulSet, ready: 0, desired: 3, now: now)
        addMarkedService("acme-ledger-db", namespace: ns(4), app: spoke.statefulSet, now: now)

        spoke.hpa = "\(env)-\(ns(5))-acme-search-service"
        addMarkedDeployment("acme-search", namespace: ns(5), app: spoke.hpa, padding: options.padding, now: now)
        addMarkedHPA("acme-search", namespace: ns(5), app: spoke.hpa, failing: true, now: now)

        spoke.serviceOnly = "\(env)-\(ns(6))-acme-edge-service"
        addMarkedService("acme-edge", namespace: ns(6), app: spoke.serviceOnly, now: now)
        add(
            "ingresses.networking.k8s.io", "acme-edge", namespace: ns(6), values: ["Class": "nginx", "Hosts": "edge.acme.example", "Address": "10.0.9.1", "Ports": "80"],
            annotations: marks(spoke.serviceOnly, "networking.k8s.io/Ingress", ns(6), "acme-edge"), created: now.addingTimeInterval(-86_400))

        spoke.loadBalancer = "\(env)-\(ns(7))-acme-gateway-service"
        addMarkedDeployment("acme-gateway", namespace: ns(7), app: spoke.loadBalancer, padding: options.padding, now: now)
        addMarkedService("acme-gateway", namespace: ns(7), app: spoke.loadBalancer, loadBalancer: "<pending>", now: now)

        spoke.cronJob = "\(env)-\(ns(8))-acme-reindex-service"
        add(
            "cronjobs.batch", "acme-reindex", namespace: ns(8), values: ["Schedule": "0 * * * *", "Active": 0, "Last Schedule": "20m"],
            annotations: marks(spoke.cronJob, "batch/CronJob", ns(8), "acme-reindex"), created: now.addingTimeInterval(-86_400),
            fields: [
                "spec": [
                    "schedule": "0 * * * *", "suspend": false,
                    "jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "reindex", "image": "registry.acme.example/reindex:2.3.1"]]]]]],
                ],
                "status": ["lastScheduleTime": Self.time(now.addingTimeInterval(-1200)), "lastSuccessfulTime": Self.time(now.addingTimeInterval(-4800))],
            ])

        spoke.claim = "\(env)-\(ns(9))-acme-store-service"
        addMarkedDeployment("acme-store", namespace: ns(9), app: spoke.claim, padding: options.padding, now: now)
        add(
            "persistentvolumeclaims", "acme-store-data", namespace: ns(9), values: ["Status": "Pending", "StorageClass": "gp3"],
            annotations: marks(spoke.claim, "/PersistentVolumeClaim", ns(9), "acme-store-data"), created: now.addingTimeInterval(-3600))

        spoke.hooked = "\(env)-\(ns(2))-acme-orders-service"
        addMarkedDeployment("acme-orders", namespace: ns(2), app: spoke.hooked, padding: options.padding, now: now)
        var hook = marks(spoke.hooked, "batch/Job", ns(2), "acme-orders-migrate")
        hook["argocd.argoproj.io/hook"] = "PreSync"
        hook["argocd.argoproj.io/hook-delete-policy"] = "BeforeHookCreation"
        add(
            "jobs.batch", "acme-orders-migrate", namespace: ns(2), values: ["Status": "Failed", "Completions": "0/1"], annotations: hook,
            created: now.addingTimeInterval(-600), fields: ["status": ["conditions": [["type": "Failed", "status": "True", "reason": "BackoffLimitExceeded"]]]])

        spoke.labelOnly = "\(env)-\(ns(3))-acme-legacy"
        addMarkedDeployment("acme-legacy", namespace: ns(3), app: nil, labels: ["argocd.argoproj.io/instance": spoke.labelOnly], padding: options.padding, now: now)

        // Helm's own: an instance label beside its release annotation — never an app.
        addMarkedDeployment(
            "fake-metrics-agent", namespace: ns(0), app: nil, labels: ["app.kubernetes.io/instance": "fake-metrics-agent"],
            annotations: ["meta.helm.sh/release-name": "fake-metrics-agent", "meta.helm.sh/release-namespace": ns(0)], padding: options.padding, now: now)
        // Garbled marks: counted, never shown.
        addMarkedDeployment("acme-garbled", namespace: ns(4), app: nil, annotations: ["argocd.argoproj.io/tracking-id": "acme-garbled"], padding: 0, now: now)
        addMarkedDeployment(
            "acme-newline", namespace: ns(4), app: nil, annotations: ["argocd.argoproj.io/tracking-id": "acme-x:apps/Deployment:\(ns(4))/acme-newline\nother"],
            padding: 0, now: now)
        // Marks on what is never read here.
        let sentinel = Self.gitOpsSentinel
        add(
            "secrets", "acme-pay-db", namespace: ns(1), annotations: marks(spoke.stuck, "/Secret", ns(1), "acme-pay-db"), data: ["password": sentinel],
            created: now)
        add(
            "configmaps", "acme-pay-config", namespace: ns(1), annotations: marks(spoke.stuck, "/ConfigMap", ns(1), "acme-pay-config"),
            data: ["token": sentinel], created: now)

        if options.rollouts {
            addCRD(
                group: "argoproj.io", version: "v1alpha1", plural: "rollouts", kind: "Rollout", shortNames: ["ro"],
                columns: [
                    Column(name: "Desired", type: "integer"), Column(name: "Current", type: "integer"), Column(name: "Up-to-date", type: "integer"),
                    Column(name: "Available", type: "integer"),
                ])
            spoke.rollout = "\(env)-\(ns(0))-acme-canary-service"
            addMarkedRollout("acme-canary", namespace: ns(0), app: spoke.rollout, phase: "Healthy", now: now)
            spoke.rolloutDegraded = "\(env)-\(ns(1))-acme-blue-service"
            addMarkedRollout("acme-blue", namespace: ns(1), app: spoke.rolloutDegraded, phase: "Degraded", now: now)
        }
        return spoke
    }

    /// Argo CD's annotation-based tracking id for an object it deploys.
    func marks(_ app: String, _ groupKind: String, _ namespace: String, _ name: String) -> [String: String] {
        ["argocd.argoproj.io/tracking-id": "\(app):\(groupKind):\(namespace)/\(name)"]
    }

    /// A Deployment, its cells and its object agreeing unless `status`,
    /// `progressing` or `paused` say otherwise; `app` its tracking id's
    /// (nil: only the labels and annotations given). Its ReplicaSet carries
    /// its mark, copied.
    func addMarkedDeployment(
        _ name: String, namespace: String, app: String?, ready: Int = 2, desired: Int = 2, updated: Int? = nil, available: Int? = nil,
        labels: [String: String] = [:], annotations extra: [String: String] = [:], padding: Int, now: Date, status: [String: Any]? = nil,
        progressing: (status: String, reason: String) = ("True", "NewReplicaSetAvailable"), paused: Bool = false, generation: Int = 4,
        image: String? = nil
    ) {
        let image = image ?? "registry.acme.example/\(name):4.12.0"
        var annotations = extra
        if let app { annotations.merge(marks(app, "apps/Deployment", namespace, name)) { $1 } }
        if padding > 0 { annotations["kubectl.kubernetes.io/last-applied-configuration"] = Self.lastApplied(name, padding: padding) }
        var state: [String: Any] =
            status ?? ["replicas": desired, "updatedReplicas": updated ?? desired, "readyReplicas": ready, "availableReplicas": available ?? ready]
        state["observedGeneration"] = generation
        state["conditions"] = [
            ["type": "Available", "status": (available ?? ready) >= desired ? "True" : "False", "reason": "MinimumReplicasAvailable"],
            [
                "type": "Progressing", "status": progressing.status, "reason": progressing.reason, "lastUpdateTime": Self.time(now.addingTimeInterval(-600)),
                "lastTransitionTime": Self.time(now.addingTimeInterval(-600)), "message": "ReplicaSet \"\(name)-7d4b9c\" has timed out progressing.",
            ],
        ]
        add(
            "deployments.apps", name, namespace: namespace,
            values: [
                "Ready": .text("\(ready)/\(desired)"), "Up-to-date": .integer(updated ?? desired), "Available": .integer(available ?? ready),
                "Containers": "app", "Images": .text(image), "Selector": .text("app=\(name)"),
            ],
            labels: labels.merging(["app": name]) { a, _ in a }, annotations: annotations, created: now.addingTimeInterval(-86_400),
            fields: [
                "metadata": ["generation": generation],
                "spec": [
                    "replicas": desired, "paused": paused, "strategy": ["type": "RollingUpdate"],
                    "template": [
                        "spec": ["containers": [["name": "app", "image": image, "env": [["name": "DB_PASSWORD", "value": Self.gitOpsSentinel]], "args": ["--token=\(Self.gitOpsSentinel)"]]]]
                    ],
                ],
                "status": state,
            ])
        if app != nil {
            // The Deployment controller copies every annotation onto its ReplicaSets.
            add(
                "replicasets.apps", "\(name)-7d4b9c", namespace: namespace, values: ["Desired": .integer(desired), "Current": .integer(desired), "Ready": .integer(ready)], annotations: annotations,
                created: now.addingTimeInterval(-86_400))
        }
    }

    func addMarkedStatefulSet(_ name: String, namespace: String, app: String, ready: Int, desired: Int, now: Date) {
        add(
            "statefulsets.apps", name, namespace: namespace,
            values: ["Ready": .text("\(ready)/\(desired)"), "Containers": "db", "Images": "registry.acme.example/postgres:16.4"],
            annotations: marks(app, "apps/StatefulSet", namespace, name), created: now.addingTimeInterval(-7200),
            fields: [
                "metadata": ["generation": 2],
                "spec": [
                    "replicas": desired, "updateStrategy": ["type": "RollingUpdate"],
                    "template": ["spec": ["containers": [["name": "db", "image": "registry.acme.example/postgres:16.4"]]]],
                ],
                "status": [
                    "observedGeneration": 2, "replicas": desired, "readyReplicas": ready, "currentRevision": "\(name)-5f6", "updateRevision": "\(name)-5f6",
                ],
            ])
    }

    func addMarkedService(_ name: String, namespace: String, app: String, loadBalancer: String? = nil, installation: String? = nil, now: Date) {
        var annotations = marks(app, "/Service", namespace, name)
        if let installation { annotations[KubeTrackingID.installationAnnotation] = installation }
        add(
            "services", name, namespace: namespace,
            values: ["Type": .text(loadBalancer == nil ? "ClusterIP" : "LoadBalancer"), "Cluster-IP": "10.96.0.12", "External-IP": .text(loadBalancer ?? "<none>"), "Port(s)": "80/TCP"],
            annotations: annotations, created: now.addingTimeInterval(-86_400))
    }

    func addMarkedHPA(_ name: String, namespace: String, app: String, failing: Bool = false, installation: String? = nil, now: Date) {
        let conditions: [[String: Any]] =
            failing
            ? [
                ["type": "AbleToScale", "status": "True", "reason": "SucceededGetScale"],
                [
                    "type": "ScalingActive", "status": "False", "reason": "FailedGetResourceMetric", "lastTransitionTime": Self.time(now.addingTimeInterval(-900)),
                    "message": "the HPA was unable to compute the replica count: failed to get cpu utilization",
                ],
            ]
            : [
                ["type": "AbleToScale", "status": "True", "reason": "ReadyForNewScale"],
                ["type": "ScalingActive", "status": "True", "reason": "ValidMetricFound"],
            ]
        add(
            "horizontalpodautoscalers.autoscaling", name, namespace: namespace,
            values: ["Reference": .text("Deployment/\(name)"), "Targets": .text(failing ? "cpu: <unknown>/70%" : "cpu: 40%/70%"), "MinPods": 2, "MaxPods": 6, "Replicas": 2],
            annotations: marks(app, "autoscaling/HorizontalPodAutoscaler", namespace, name).merging(installation.map { [KubeTrackingID.installationAnnotation: $0] } ?? [:]) { $1 },
            created: now.addingTimeInterval(-86_400),
            fields: ["spec": ["minReplicas": 2, "maxReplicas": 6], "status": ["currentReplicas": 2, "desiredReplicas": 2, "conditions": conditions]])
    }

    /// An object carrying another's tracking id, as an operator or a
    /// controller copies it: nobody's member.
    func addCopiedMark(_ resource: String, _ name: String, namespace: String, app: String, of deployment: String, now: Date) {
        add(resource, name, namespace: namespace, annotations: marks(app, "apps/Deployment", namespace, deployment), created: now.addingTimeInterval(-86_400))
    }

    /// An Argo Rollout running its Deployment by `workloadRef`, the
    /// Deployment scaled to 0 by the Rollouts controller.
    func addMarkedRollout(_ name: String, namespace: String, app: String, phase: String, now: Date) {
        add(
            "rollouts.argoproj.io", name, namespace: namespace, values: ["Desired": 3, "Current": 3, "Up-to-date": 3, "Available": phase == "Healthy" ? 3 : 1],
            annotations: marks(app, "argoproj.io/Rollout", namespace, name), created: now.addingTimeInterval(-86_400),
            fields: [
                "metadata": ["generation": 6],
                "spec": ["replicas": 3, "workloadRef": ["apiVersion": "apps/v1", "kind": "Deployment", "name": name]],
                "status": ["observedGeneration": "6", "phase": phase, "message": phase == "Healthy" ? "" : "RolloutAborted: metric \"error-rate\" assessed Failed"],
            ])
        addMarkedDeployment(name, namespace: namespace, app: app, ready: 0, desired: 0, padding: 0, now: now)
    }

    /// Readiness churn on Deployments, their generation unchanged: each
    /// round turns every one not ready, then ready again (`rounds` × 2 ×
    /// the Deployments' events).
    func churnReadiness(_ deployments: [(namespace: String, name: String)], rounds: Int) {
        for round in 0..<(rounds * 2) {
            let ready = round % 2 == 1
            for (namespace, name) in deployments {
                modify("deployments.apps", name, namespace: namespace, values: ["Ready": .text(ready ? "2/2" : "1/2"), "Available": .integer(ready ? 2 : 1)]) { body in
                    var status = body["status"] as? [String: Any] ?? [:]
                    status["readyReplicas"] = ready ? 2 : 1
                    status["availableReplicas"] = ready ? 2 : 1
                    body["status"] = status
                }
            }
        }
    }

    /// kubectl's client-side apply: the manifest again as a string, the sentinel in it.
    static func lastApplied(_ name: String, padding: Int) -> String {
        let head = "{\"apiVersion\":\"apps/v1\",\"kind\":\"Deployment\",\"metadata\":{\"name\":\"\(name)\"},\"env\":\"\(gitOpsSentinel)\",\"pad\":\""
        return head + String(repeating: "x", count: max(0, padding - head.count - 3)) + "\"}"
    }
}
