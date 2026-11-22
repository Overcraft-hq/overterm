#if E2E
import Foundation

/// The surveyed production spoke at its size (docs/design/kubernetes/
/// gitops.md, 14.12; D7's leg, 14.9.3): what `kubernetesGitOpsMarksPerf`
/// reads, never a real cluster. No Argo CD Application and no Flux kind
/// served; Argo Rollouts served. Shaped as the survey counted it:
///
/// - 1,161 Deployments, 980 of them marked: 894 apps (86 with a second, a
///   worker), app names `<env>-<ns>-<name>-service` (and the shorter
///   forms) that never equal a workload's own name, every tracking id
///   naming its own object, every app in one namespace, no `ns_name`;
/// - 207 marked Deployments scaled to 0: 115 run by an Argo Rollout by
///   `workloadRef` (112 Healthy, 2 Degraded, 1 Paused; 117 Rollouts, 2 not
///   marked), the rest scaled down;
/// - 21 rollouts past their progress deadline — 16 not ready by their
///   rows, 5 single replicas whose cells read `1/1` (the old pod serving)
///   from a sync of the last hour —, 23 Deployments not every replica
///   available — ≈40 problems by their rows —, two more single replicas
///   stuck behind their old pod (cells `1/1`) and one paused (cells
///   `2/2`): what only their objects say, the most recently changed by Argo
///   CD — every other change two hours old or more;
/// - 1,006 Services (10 LoadBalancers, one `<pending>`), 893 marked HPAs
///   of 1,080 (one `<unknown>`, its metrics failing), 95 Ingresses (one
///   app holds 94 and nothing else), 44 CronJobs (one whose last run
///   failed), 8 hook Jobs, 8 claims (one Pending), 3 StatefulSets (one
///   `0/3`) and 8 DaemonSets, each of an app of its own;
/// - a few copied marks: six HPAs and six PodDisruptionBudgets carrying
///   their Deployment's; a Secret and a ConfigMap that carry marks and are
///   never to be read;
/// - 70 namespaces: `team-0…9` and `globex-00…59`.
///
/// A marked Deployment's row is about 15 KB with the fake's
/// `tableManagedFields` (the design's worst case, 14.4.4): kubectl's
/// last-applied copy (`padding` bytes, the sentinel in it) and Argo CD's
/// server-side apply and the controller's managedFields — its newest Argo
/// CD time spread over a month. No ReplicaSet or pod: the section never
/// lists them, and no app's detail is opened here. Fictional names only.
extension FakeKubeAPI {
    /// What `addSurveySpoke` made, by what the leg looks for.
    package struct SurveySpoke: Sendable {
        package typealias Workload = (namespace: String, name: String, app: String)
        /// Every app the marks make, by its instance name.
        package var apps: Set<String> = []
        /// The plain apps' primary Deployments that read ready, their
        /// desired two: the burst's and the churn's.
        package var ready: [Workload] = []
        /// Rollouts past their deadline; and not every replica available: their apps.
        package var stalled: [Workload] = []
        package var unavailable: [String] = []
        /// Only their objects say so, their cells ready, synced in the last
        /// hour: the stalled single replicas (among `stalled`), the others
        /// stuck behind the old pod, the paused one.
        package var hidden: [Workload] = []
        package var stuck: [String] = []
        package var paused = ""
        /// The Argo Rollouts' apps.
        package var rolloutApps: [String] = []
        /// Ingresses only: Unknown, no workload read.
        package var ingressOnly = ""
        /// Marked objects of each kind, by its full name.
        package var marked: [String: Int] = [:]
        /// Every object of each kind made, marked or not.
        package var made: [String: Int] = [:]
        /// What the settle reads by GET: every marked workload, CronJob and
        /// `<unknown>` HPA.
        package var fetched = 0
        /// The GET paths of those whose rows may hide a problem — not ready
        /// by their cells, what no cell says (the Rollouts' phases, the
        /// CronJobs' last runs, the `<unknown>` HPA's metrics), or synced in
        /// the last hour (`hidden`'s, `stuck`'s, `paused`'s): the settle's first.
        package var doubtful: Set<String> = []
    }

    /// The survey's production spoke (gitops.md 14.12) on this fake.
    /// `padding`: kubectl's last-applied copy on each marked Deployment —
    /// 13,000 bytes give rows of about 15 KB with managedFields.
    @discardableResult
    package func addSurveySpoke(env: String = "prod", padding: Int = 13_000, now: Date = Date()) -> SurveySpoke {
        var spoke = SurveySpoke()
        let namespaces = (0..<10).map { "team-\($0)" } + (0..<60).map { String(format: "globex-%02d", $0) }
        for namespace in namespaces + ["kube-system"] { addNamespace(namespace) }
        serveRollouts()
        func counted(_ resource: String, marked: Bool = true) {
            spoke.made[resource, default: 0] += 1
            if marked { spoke.marked[resource, default: 0] += 1 }
        }
        func appName(_ index: Int, _ name: String, _ namespace: String) -> String {
            // The survey's forms: `<env>-<ns>-<name>-service` (504 of 894),
            // `<env>-<ns>-<name>` (258), `<env>-<name>` (40) and others.
            switch index % 10 {
            case 0...5: "\(env)-\(namespace)-\(name)-service"
            case 6...8: "\(env)-\(namespace)-\(name)"
            default: "\(env)-\(name)"
            }
        }
        // When Argo CD last changed each: spread over a month, two hours old
        // at the least — the hidden problems alone newer (a sync of the last
        // hour that rolled out a bad image).
        func changed(_ index: Int) -> Date { now.addingTimeInterval(-7_200 - Double((index * 7_919) % (30 * 86_400))) }

        let apps = 894
        let rollouts = Set((0..<115).map { 3 + $0 * 7 })
        let workers = Set((0..<apps).filter { $0 % 10 == 7 && $0 < 860 })
        let atZero = Set((0..<apps).filter { $0 % 150 == 13 })
        let plain = (0..<apps).filter { !rollouts.contains($0) && !atZero.contains($0) }
        func every(_ step: Int, from: Int, of indices: [Int], _ count: Int) -> [Int] {
            Array(indices.enumerated().filter { $0.offset % step == from }.prefix(count).map(\.element))
        }
        let stalled = Set(every(38, from: 5, of: plain, 21))
        // Five of them single replicas whose cells read ready: synced 20 to 40 minutes ago.
        let hiddenStalled = Array(stalled.sorted().suffix(5))
        let unavailable = Set(every(33, from: 17, of: plain.filter { !stalled.contains($0) }, 23))
        let quiet = plain.filter { !stalled.contains($0) && !unavailable.contains($0) && !workers.contains($0) }
        let stuck = Array(quiet.suffix(2))
        let paused = quiet.dropLast(2).last ?? 0
        let degradedRollouts = Set(rollouts.sorted().prefix(2))
        let pausedRollout = rollouts.sorted()[2]
        let cronJobs = every(17, from: 9, of: plain, 44)
        let hooks = every(90, from: 41, of: plain, 8)
        let unknownHPA = quiet.first { $0 % 97 == 11 } ?? quiet[0]

        for index in 0..<apps {
            let namespace = namespaces[index % namespaces.count]
            let name = String(format: "acme-svc-%03d", index)
            let app = appName(index, name, namespace)
            spoke.apps.insert(app)
            let argo = changed(index)
            let managed = { (desired: Int) in Self.surveyManagedFields(desired: desired, argoChanged: argo, now: now) }
            if rollouts.contains(index) {
                let phase = degradedRollouts.contains(index) ? "Degraded" : index == pausedRollout ? "Paused" : "Healthy"
                add(
                    "rollouts.argoproj.io", name, namespace: namespace, values: ["Desired": 3, "Current": 3, "Up-to-date": 3, "Available": phase == "Healthy" ? 3 : 2],
                    annotations: marks(app, "argoproj.io/Rollout", namespace, name), created: now.addingTimeInterval(-90 * 86_400),
                    fields: [
                        "metadata": ["generation": 9],
                        "spec": ["replicas": 3, "workloadRef": ["apiVersion": "apps/v1", "kind": "Deployment", "name": name]],
                        "status": ["observedGeneration": "9", "phase": phase, "message": phase == "Degraded" ? "RolloutAborted: metric \"error-rate\" assessed Failed" : ""],
                    ])
                setManagedFields("rollouts.argoproj.io", name, namespace: namespace, managed(3))
                counted("rollouts.argoproj.io")
                spoke.doubtful.insert("/apis/argoproj.io/v1alpha1/namespaces/\(namespace)/rollouts/\(name)")
                spoke.rolloutApps.append(app)
                // The Deployment it runs, scaled to 0 by the Rollouts controller.
                addMarkedDeployment(name, namespace: namespace, app: app, ready: 0, desired: 0, padding: padding, now: now, replicaSet: false)
                setManagedFields("deployments.apps", name, namespace: namespace, managed(0))
            } else if atZero.contains(index) {
                addMarkedDeployment(name, namespace: namespace, app: app, ready: 0, desired: 0, padding: padding, now: now, replicaSet: false)
                setManagedFields("deployments.apps", name, namespace: namespace, managed(0))
            } else if let at = hiddenStalled.firstIndex(of: index) {
                // A single replica past its deadline behind the old pod: cells `1/1`, a sync of the last hour.
                addMarkedDeployment(
                    name, namespace: namespace, app: app, ready: 1, desired: 1, padding: padding, now: now,
                    status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1, "unavailableReplicas": 1],
                    progressing: ("False", "ProgressDeadlineExceeded"), replicaSet: false)
                setManagedFields(
                    "deployments.apps", name, namespace: namespace, Self.surveyManagedFields(desired: 1, argoChanged: now.addingTimeInterval(-1_200 - Double(at) * 300), now: now))
                spoke.stalled.append((namespace, name, app))
                spoke.hidden.append((namespace, name, app))
                spoke.doubtful.insert("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)")
            } else if stalled.contains(index) {
                addMarkedDeployment(
                    name, namespace: namespace, app: app, ready: 1, desired: 2, updated: 1, available: 1, padding: padding, now: now,
                    status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1], progressing: ("False", "ProgressDeadlineExceeded"),
                    replicaSet: false)
                setManagedFields("deployments.apps", name, namespace: namespace, managed(2))
                spoke.stalled.append((namespace, name, app))
                spoke.doubtful.insert("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)")
            } else if unavailable.contains(index) {
                addMarkedDeployment(
                    name, namespace: namespace, app: app, ready: 2, desired: 3, updated: 3, available: 2, padding: padding, now: now,
                    status: ["replicas": 3, "updatedReplicas": 3, "readyReplicas": 2, "availableReplicas": 2], replicaSet: false)
                setManagedFields("deployments.apps", name, namespace: namespace, managed(3))
                spoke.unavailable.append(app)
                spoke.doubtful.insert("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)")
            } else if let at = stuck.firstIndex(of: index) {
                // Cells `1/1` (the old pod serving); the object says its rollout is stuck.
                let stalls = at == 0
                addMarkedDeployment(
                    name, namespace: namespace, app: app, ready: 1, desired: 1, padding: padding, now: now,
                    status: ["replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1, "unavailableReplicas": 1],
                    progressing: stalls ? ("False", "ProgressDeadlineExceeded") : ("True", "ReplicaSetUpdated"), replicaSet: false)
                setManagedFields(
                    "deployments.apps", name, namespace: namespace, Self.surveyManagedFields(desired: 1, argoChanged: now.addingTimeInterval(-120 - Double(at) * 60), now: now))
                spoke.stuck.append(app)
                spoke.hidden.append((namespace, name, app))
                spoke.doubtful.insert("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)")
            } else if index == paused {
                addMarkedDeployment(name, namespace: namespace, app: app, padding: padding, now: now, paused: true, replicaSet: false)
                setManagedFields("deployments.apps", name, namespace: namespace, Self.surveyManagedFields(desired: 2, argoChanged: now.addingTimeInterval(-300), now: now))
                spoke.paused = app
                spoke.hidden.append((namespace, name, app))
                spoke.doubtful.insert("/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)")
            } else {
                addMarkedDeployment(name, namespace: namespace, app: app, padding: padding, now: now, replicaSet: false)
                setManagedFields("deployments.apps", name, namespace: namespace, managed(2))
                if !workers.contains(index) { spoke.ready.append((namespace, name, app)) }
            }
            counted("deployments.apps")
            if workers.contains(index) {
                // A second Deployment of the app, scaled down: the survey's other Deployments at 0.
                addMarkedDeployment("\(name)-worker", namespace: namespace, app: app, ready: 0, desired: 0, padding: padding, now: now, replicaSet: false)
                setManagedFields("deployments.apps", "\(name)-worker", namespace: namespace, managed(0))
                counted("deployments.apps")
                addMarkedService("\(name)-worker", namespace: namespace, app: app, now: now)
                counted("services")
            }
            let loadBalancer: String? = index % 89 == 7 ? (index == 7 ? "<pending>" : "203.0.113.\(index % 250)") : nil
            addMarkedService(name, namespace: namespace, app: app, loadBalancer: loadBalancer, annotations: Self.surveyApplied(name, kind: "Service"), now: now)
            counted("services")
            if index % 40 == 0 {
                addMarkedService("\(name)-headless", namespace: namespace, app: app, now: now)
                counted("services")
            }
            if index != apps - 1 {
                addMarkedHPA(name, namespace: namespace, app: app, failing: index == unknownHPA, now: now)
                if index == unknownHPA { spoke.doubtful.insert("/apis/autoscaling/v2/namespaces/\(namespace)/horizontalpodautoscalers/\(name)") }
                if rollouts.contains(index) {
                    modify("horizontalpodautoscalers.autoscaling", name, namespace: namespace, values: ["Reference": .text("Rollout/\(name)")]) { _ in }
                }
                counted("horizontalpodautoscalers.autoscaling")
            }
            if cronJobs.contains(index) {
                let failed = index == cronJobs[0]
                add(
                    "cronjobs.batch", "\(name)-nightly", namespace: namespace, values: ["Schedule": "0 3 * * *", "Active": 0, "Last Schedule": "9h"],
                    annotations: marks(app, "batch/CronJob", namespace, "\(name)-nightly"), created: now.addingTimeInterval(-30 * 86_400),
                    fields: [
                        "spec": [
                            "schedule": "0 3 * * *", "suspend": false,
                            "jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "job", "image": "registry.acme.example/\(name):4.12.0"]]]]]],
                        ],
                        "status": [
                            "lastScheduleTime": Self.time(now.addingTimeInterval(-9 * 3_600)),
                            "lastSuccessfulTime": Self.time(now.addingTimeInterval(failed ? -33 * 3_600 : -9 * 3_600 + 120)),
                        ],
                    ])
                counted("cronjobs.batch")
                spoke.doubtful.insert("/apis/batch/v1/namespaces/\(namespace)/cronjobs/\(name)-nightly")
            }
            if hooks.contains(index) {
                var hook = marks(app, "batch/Job", namespace, "\(name)-migrate")
                hook["argocd.argoproj.io/hook"] = "PreSync"
                hook["argocd.argoproj.io/hook-delete-policy"] = "BeforeHookCreation"
                let failed = index == hooks[0]
                add(
                    "jobs.batch", "\(name)-migrate", namespace: namespace, values: ["Status": .text(failed ? "Failed" : "Complete"), "Completions": .text(failed ? "0/1" : "1/1")],
                    annotations: hook, created: now.addingTimeInterval(-86_400))
                counted("jobs.batch")
            }
            // A copy on a few HPAs and PDBs: their Deployment's own mark (14.12: "copied marks only on a few").
            if index % 150 == 70 {
                addCopiedMark("horizontalpodautoscalers.autoscaling", "\(name)-extra", namespace: namespace, app: app, of: name, now: now)
                counted("horizontalpodautoscalers.autoscaling", marked: false)
                addCopiedMark("poddisruptionbudgets.policy", name, namespace: namespace, app: app, of: name, now: now)
            }
        }

        // One app of 94 Ingresses and nothing else (the survey's shared one), and one app's own.
        spoke.ingressOnly = "\(env)-globex-00-edge-routes"
        spoke.apps.insert(spoke.ingressOnly)
        for index in 0..<94 {
            let name = String(format: "edge-route-%02d", index)
            add(
                "ingresses.networking.k8s.io", name, namespace: "globex-00",
                values: ["Class": "nginx", "Hosts": .text("\(name).acme.example"), "Address": "10.0.9.1", "Ports": "80, 443"],
                annotations: marks(spoke.ingressOnly, "networking.k8s.io/Ingress", "globex-00", name), created: now.addingTimeInterval(-86_400))
            counted("ingresses.networking.k8s.io")
        }
        let first = (namespaces[1], "acme-svc-001", appName(1, "acme-svc-001", namespaces[1]))
        add(
            "ingresses.networking.k8s.io", first.1, namespace: first.0, values: ["Class": "nginx", "Hosts": "api.acme.example", "Address": "10.0.9.2", "Ports": "80"],
            annotations: marks(first.2, "networking.k8s.io/Ingress", first.0, first.1), created: now.addingTimeInterval(-86_400))
        counted("ingresses.networking.k8s.io")

        // StatefulSets and DaemonSets, each an app of its own; claims beside them.
        for index in 0..<3 {
            let namespace = namespaces[index]
            let name = "acme-db-\(index)"
            let app = "\(env)-\(namespace)-\(name)"
            spoke.apps.insert(app)
            addMarkedStatefulSet(name, namespace: namespace, app: app, ready: index == 0 ? 0 : 3, desired: 3, now: now)
            counted("statefulsets.apps")
            if index == 0 { spoke.doubtful.insert("/apis/apps/v1/namespaces/\(namespace)/statefulsets/\(name)") }
            addMarkedService(name, namespace: namespace, app: app, now: now)
            counted("services")
        }
        for index in 0..<8 {
            let namespace = index < 3 ? namespaces[index] : namespaces[10 + index]
            let claim = index < 3 ? "data-acme-db-\(index)-0" : "acme-files-\(index)"
            let app = index < 3 ? "\(env)-\(namespace)-acme-db-\(index)" : appName(10 + index, String(format: "acme-svc-%03d", 10 + index), namespace)
            add(
                "persistentvolumeclaims", claim, namespace: namespace, values: ["Status": .text(index == 4 ? "Pending" : "Bound"), "StorageClass": "gp3"],
                annotations: marks(app, "/PersistentVolumeClaim", namespace, claim), created: now.addingTimeInterval(-86_400))
            counted("persistentvolumeclaims")
        }
        for index in 0..<8 {
            let name = "fake-node-agent-\(index)"
            let app = "\(env)-kube-system-\(name)"
            spoke.apps.insert(app)
            add(
                "daemonsets.apps", name, namespace: "kube-system",
                values: [
                    "Desired": 12, "Current": 12, "Ready": 12, "Up-to-date": 12, "Available": 12, "Node Selector": "<none>", "Containers": "agent", "Images": "registry.acme.example/node-agent:3.1.0",
                ],
                annotations: marks(app, "apps/DaemonSet", "kube-system", name), created: now.addingTimeInterval(-90 * 86_400),
                fields: [
                    "metadata": ["generation": 3],
                    "spec": ["updateStrategy": ["type": "RollingUpdate"], "selector": ["matchLabels": ["app": name]]],
                    "status": ["observedGeneration": 3, "desiredNumberScheduled": 12, "updatedNumberScheduled": 12, "numberAvailable": 12, "numberReady": 12],
                ])
            counted("daemonsets.apps")
        }

        // Deployments, Rollouts and HPAs Argo CD doesn't deploy: the cluster's own, Helm's.
        for index in 0..<181 {
            let namespace = index < 40 ? "kube-system" : namespaces[index % namespaces.count]
            let name = String(format: "globex-tool-%03d", index)
            var labels: [String: String] = [:]
            var annotations: [String: String] = ["deployment.kubernetes.io/revision": "3"]
            if index % 3 == 0 {
                labels["app.kubernetes.io/instance"] = name
                annotations["meta.helm.sh/release-name"] = name
                annotations["meta.helm.sh/release-namespace"] = namespace
            }
            addMarkedDeployment(name, namespace: namespace, app: nil, labels: labels, annotations: annotations, padding: 1_500, now: now, replicaSet: false)
            counted("deployments.apps", marked: false)
            add(
                "horizontalpodautoscalers.autoscaling", name, namespace: namespace,
                values: ["Reference": .text("Deployment/\(name)"), "Targets": "cpu: 30%/80%", "MinPods": 1, "MaxPods": 3, "Replicas": 1],
                created: now.addingTimeInterval(-86_400))
            counted("horizontalpodautoscalers.autoscaling", marked: false)
        }
        for index in 0..<2 {
            add(
                "rollouts.argoproj.io", "globex-canary-\(index)", namespace: "globex-59", values: ["Desired": 1, "Current": 1, "Up-to-date": 1, "Available": 1],
                created: now.addingTimeInterval(-86_400), fields: ["status": ["phase": "Healthy"]])
            counted("rollouts.argoproj.io", marked: false)
        }

        // Marks on what is never read here.
        let sentinel = Self.gitOpsSentinel
        let carrier = (namespaces[1], appName(1, "acme-svc-001", namespaces[1]))
        add("secrets", "acme-svc-001-db", namespace: carrier.0, annotations: marks(carrier.1, "/Secret", carrier.0, "acme-svc-001-db"), data: ["password": sentinel], created: now)
        add("configmaps", "acme-svc-001-config", namespace: carrier.0, annotations: marks(carrier.1, "/ConfigMap", carrier.0, "acme-svc-001-config"), data: ["token": sentinel], created: now)

        spoke.fetched =
            (spoke.marked["deployments.apps"] ?? 0) + (spoke.marked["statefulsets.apps"] ?? 0) + (spoke.marked["daemonsets.apps"] ?? 0)
            + (spoke.marked["rollouts.argoproj.io"] ?? 0) + (spoke.marked["cronjobs.batch"] ?? 0) + 1
        return spoke
    }

    /// kubectl's last-applied copy of a small object (a Service's): its manifest again, a kilobyte or so.
    package static func surveyApplied(_ name: String, kind: String) -> [String: String] {
        let manifest =
            "{\"apiVersion\":\"v1\",\"kind\":\"\(kind)\",\"metadata\":{\"name\":\"\(name)\",\"labels\":{\"app\":\"\(name)\"}},\"spec\":{\"ports\":[{\"name\":\"http\",\"port\":80,\"protocol\":\"TCP\",\"targetPort\":8080}],\"selector\":{\"app\":\"\(name)\"},\"type\":\"ClusterIP\"},\"pad\":\""
        return ["kubectl.kubernetes.io/last-applied-configuration": manifest + String(repeating: "x", count: 900) + "\"}"]
    }

    /// A marked workload's managedFields as the survey's spoke carries
    /// them: Argo CD's server-side apply (`argocd-controller`, the spec it
    /// owns field by field) at `argoChanged`, the controller's status
    /// writes since.
    package static func surveyManagedFields(desired: Int, argoChanged: Date, now: Date) -> [[String: Any]] {
        let empty = [String: Any]()
        let container: [String: Any] = [
            ".": empty, "f:env": [".": empty, "k:{\"name\":\"DB_PASSWORD\"}": [".": empty, "f:name": empty, "f:value": empty]], "f:image": empty,
            "f:imagePullPolicy": empty, "f:name": empty,
            "f:ports": [".": empty, "k:{\"containerPort\":8080,\"protocol\":\"TCP\"}": [".": empty, "f:containerPort": empty, "f:name": empty, "f:protocol": empty]],
            "f:readinessProbe": [".": empty, "f:httpGet": [".": empty, "f:path": empty, "f:port": empty], "f:periodSeconds": empty],
            "f:resources": [".": empty, "f:limits": [".": empty, "f:memory": empty], "f:requests": [".": empty, "f:cpu": empty, "f:memory": empty]],
        ]
        return [
            [
                "manager": "argocd-controller", "operation": "Apply", "apiVersion": "apps/v1", "time": time(argoChanged), "fieldsType": "FieldsV1",
                "fieldsV1": [
                    "f:metadata": [
                        "f:annotations": ["f:argocd.argoproj.io/tracking-id": empty], "f:labels": ["f:app": empty, "f:acme.example/team": empty],
                    ],
                    "f:spec": [
                        "f:replicas": empty, "f:revisionHistoryLimit": empty, "f:selector": empty,
                        "f:strategy": ["f:rollingUpdate": ["f:maxSurge": empty, "f:maxUnavailable": empty], "f:type": empty],
                        "f:template": [
                            "f:metadata": ["f:annotations": ["f:prometheus.io/scrape": empty], "f:labels": ["f:app": empty]],
                            "f:spec": ["f:containers": ["k:{\"name\":\"app\"}": container], "f:serviceAccountName": empty, "f:terminationGracePeriodSeconds": empty],
                        ],
                    ],
                ],
            ],
            [
                "manager": "kube-controller-manager", "operation": "Update", "subresource": "status", "apiVersion": "apps/v1",
                "time": time(now.addingTimeInterval(-Double(600 + desired * 60))), "fieldsType": "FieldsV1",
                "fieldsV1": [
                    "f:metadata": ["f:annotations": [".": empty, "f:deployment.kubernetes.io/revision": empty]],
                    "f:status": [
                        "f:availableReplicas": empty, "f:conditions": [".": empty, "k:{\"type\":\"Available\"}": empty, "k:{\"type\":\"Progressing\"}": empty],
                        "f:observedGeneration": empty, "f:readyReplicas": empty, "f:replicas": empty, "f:updatedReplicas": empty,
                    ],
                ],
            ],
        ]
    }
}
#endif
