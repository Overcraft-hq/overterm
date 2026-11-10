import Foundation

/// Health checks at a glance (docs/design/kubernetes/analysis.md, 3.9;
/// Popeye's lint, Argo's health): pure rules over objects already read, each
/// finding a code and a plain sentence about one object. Nothing here reads,
/// writes or installs anything.
///
/// - **One object** (`object`): its containers — no readiness or liveness
///   probe, no requests, no limits, an image on `:latest` or untagged —
///   checked where they are written (a workload's template, a CronJob's, a
///   pod whose owner's own checks don't cover it), so a Deployment's fifty
///   pods are one finding; a pod's
///   restarts in the last hour and a pod `Pending` for more than a minute; a
///   PodDisruptionBudget that allows no disruption; an HPA at its maximum; a
///   custom resource whose `Ready` condition is False (Flux, cert-manager…);
///   an Argo CD Application Degraded or Missing, or OutOfSync.
/// - **What needs another object** (`related`): a Service selecting no pod;
///   an Ingress sending to a Service that isn't there, or to a port it hasn't.
///   Said only when the list it needs was read whole.
enum KubeHealth {
    /// A check: its code, how bad, what it is called.
    enum Check: String, CaseIterable, Equatable, Hashable, Sendable {
        case noReadinessProbe = "K101"
        case noLivenessProbe = "K102"
        case noRequests = "K103"
        case noLimits = "K104"
        case latestImage = "K105"
        case serviceSelectsNone = "K201"
        case ingressMissingService = "K301"
        case ingressMissingPort = "K302"
        case pdbNoDisruption = "K401"
        case hpaAtMax = "K402"
        case recentRestarts = "K501"
        case pendingLong = "K502"
        case notReady = "K601"
        case argoDegraded = "K602"
        case argoOutOfSync = "K603"

        var code: String { rawValue }

        var severity: Severity {
            switch self {
            case .serviceSelectsNone, .ingressMissingService, .ingressMissingPort, .recentRestarts, .pendingLong, .notReady, .argoDegraded: .error
            default: .warning
            }
        }

        var title: String {
            switch self {
            case .noReadinessProbe: "No readiness probe"
            case .noLivenessProbe: "No liveness probe"
            case .noRequests: "No resource requests"
            case .noLimits: "No resource limits"
            case .latestImage: "Image on :latest"
            case .serviceSelectsNone: "Service selects no pod"
            case .ingressMissingService: "Ingress to a missing Service"
            case .ingressMissingPort: "Ingress to a missing port"
            case .pdbNoDisruption: "Budget allows no disruption"
            case .hpaAtMax: "Autoscaler at its maximum"
            case .recentRestarts: "Restarted in the last hour"
            case .pendingLong: "Pending for over a minute"
            case .notReady: "Not ready"
            case .argoDegraded: "Argo CD: unhealthy"
            case .argoOutOfSync: "Argo CD: out of sync"
            }
        }
    }

    enum Severity: Int, Comparable, Sendable {
        case warning = 1
        case error = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The object a finding is about: enough to link to it.
    struct Subject: Hashable, Sendable {
        var apiVersion: String
        var kind: String
        var namespace: String?
        var name: String

        var link: KubeLink { KubeLink(apiVersion: apiVersion, kind: kind, namespace: namespace, name: name) }
        /// `deployment/web`.
        var said: String { "\(kind.lowercased())/\(name)" }
        var group: String { apiVersion.contains("/") ? String(apiVersion.split(separator: "/").first ?? "") : "" }
    }

    struct Finding: Equatable, Hashable, Sendable, Identifiable {
        var check: Check
        var subject: Subject
        /// A plain sentence: `container web has no readiness probe`.
        var sentence: String

        var id: String { [check.code, subject.namespace ?? "", subject.kind, subject.name, sentence].joined(separator: "\u{0}") }
        var severity: Severity { check.severity }

        /// Worst first, then by code, then by object.
        static func ordered(_ a: Finding, _ b: Finding) -> Bool {
            if a.severity != b.severity { return a.severity > b.severity }
            if a.check.code != b.check.code { return a.check.code < b.check.code }
            if (a.subject.namespace ?? "") != (b.subject.namespace ?? "") { return (a.subject.namespace ?? "") < (b.subject.namespace ?? "") }
            if a.subject.said != b.subject.said { return a.subject.said < b.subject.said }
            return a.sentence < b.sentence
        }
    }

    /// How recent a restart must be to count.
    static let restartWindow: TimeInterval = 3600
    /// How long a pod may be Pending before it is said.
    static let pendingAfter: TimeInterval = 60

    /// The groups Kubernetes itself serves: a `Ready` False there is the
    /// kind's own business (a pod's is its containers', said otherwise).
    static let builtinGroups: Set<String> = [
        "", "apps", "batch", "policy", "autoscaling", "networking.k8s.io", "rbac.authorization.k8s.io", "storage.k8s.io", "discovery.k8s.io",
        "events.k8s.io", "apiextensions.k8s.io", "admissionregistration.k8s.io", "coordination.k8s.io", "node.k8s.io", "scheduling.k8s.io",
        "certificates.k8s.io", "flowcontrol.apiserver.k8s.io", "apiregistration.k8s.io", "metrics.k8s.io", "resource.k8s.io",
    ]

    // MARK: One object

    /// A controller as an object's `ownerReferences` name it.
    struct Owner: Hashable, Sendable {
        var group: String
        var kind: String
        var namespace: String?
        var name: String

        /// Of an object's metadata: its controller, if it has one.
        static func controller(of metadata: [String: Any]) -> Owner? {
            guard let reference = (metadata["ownerReferences"] as? [[String: Any]] ?? []).first(where: { $0["controller"] as? Bool == true }) else {
                return nil
            }
            let apiVersion = reference["apiVersion"] as? String ?? ""
            return Owner(
                group: apiVersion.contains("/") ? String(apiVersion.split(separator: "/").first ?? "") : "", kind: reference["kind"] as? String ?? "",
                namespace: metadata["namespace"] as? String, name: reference["name"] as? String ?? "")
        }

        /// The object itself, as the owner its own children name.
        static func of(_ object: [String: Any]) -> Owner {
            let metadata = object["metadata"] as? [String: Any] ?? [:]
            let apiVersion = object["apiVersion"] as? String ?? ""
            return Owner(
                group: apiVersion.contains("/") ? String(apiVersion.split(separator: "/").first ?? "") : "", kind: object["kind"] as? String ?? "",
                namespace: metadata["namespace"] as? String, name: metadata["name"] as? String ?? "")
        }
    }

    /// The kinds whose own checks cover the containers of what they own:
    /// a Deployment its ReplicaSets', a ReplicaSet, StatefulSet or DaemonSet
    /// its pods', a CronJob its Jobs', a Job its pods'. A pod (or a
    /// ReplicaSet, a Job) owned by anything else — an Argo Rollout, a
    /// StrimziPodSet, an operator — has its own containers checked.
    static func covers(_ owner: Owner) -> Bool {
        switch (owner.group, owner.kind) {
        case ("apps", "Deployment"), ("apps", "ReplicaSet"), ("apps", "StatefulSet"), ("apps", "DaemonSet"), ("batch", "CronJob"), ("batch", "Job"):
            true
        default:
            false
        }
    }

    /// What one object, as its GET answers it, says of itself. `covered`:
    /// whether its controller's checks cover its containers — alone (a
    /// detail), any kind that has them (`covers`); in a report, only one
    /// that was read and checked.
    static func object(_ object: [String: Any], now: Date = Date(), covered: (Owner) -> Bool = covers) -> [Finding] {
        let kind = object["kind"] as? String ?? ""
        let apiVersion = object["apiVersion"] as? String ?? ""
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let subject = Subject(apiVersion: apiVersion, kind: kind, namespace: metadata["namespace"] as? String, name: metadata["name"] as? String ?? "")
        let group = subject.group
        let spec = object["spec"] as? [String: Any] ?? [:]
        var found: [Finding] = []
        switch (group, kind) {
        case ("", "Pod"):
            if !isCovered(metadata, covered) {
                found += containers(spec, subject: subject, probes: (spec["restartPolicy"] as? String ?? "Always") == "Always")
            }
            found += restarts(object, subject: subject, now: now)
            if let pending = pending(object, subject: subject, now: now) { found.append(pending) }
        case ("apps", "Deployment"), ("apps", "StatefulSet"), ("apps", "DaemonSet"):
            found += containers((spec["template"] as? [String: Any])?["spec"] as? [String: Any] ?? [:], subject: subject, probes: true)
        case ("apps", "ReplicaSet"):
            if !isCovered(metadata, covered) {
                found += containers((spec["template"] as? [String: Any])?["spec"] as? [String: Any] ?? [:], subject: subject, probes: true)
            }
        case ("batch", "Job"):
            if !isCovered(metadata, covered) {
                found += containers((spec["template"] as? [String: Any])?["spec"] as? [String: Any] ?? [:], subject: subject, probes: false)
            }
        case ("batch", "CronJob"):
            let template = ((spec["jobTemplate"] as? [String: Any])?["spec"] as? [String: Any])?["template"] as? [String: Any]
            found += containers(template?["spec"] as? [String: Any] ?? [:], subject: subject, probes: false)
        case ("policy", "PodDisruptionBudget"):
            let status = object["status"] as? [String: Any] ?? [:]
            if let allowed = KubeRollout.int(status["disruptionsAllowed"]), allowed == 0, let expected = KubeRollout.int(status["expectedPods"]), expected > 0 {
                let healthy = KubeRollout.int(status["currentHealthy"]).map { ", \($0) of \(expected) pods healthy" } ?? ""
                found.append(Finding(check: .pdbNoDisruption, subject: subject, sentence: "allows no disruption\(healthy): a node can't be drained"))
            }
        case ("autoscaling", "HorizontalPodAutoscaler"):
            let status = object["status"] as? [String: Any] ?? [:]
            if let max = KubeRollout.int(spec["maxReplicas"]), max > 0, let current = KubeRollout.int(status["currentReplicas"]), current >= max {
                found.append(Finding(check: .hpaAtMax, subject: subject, sentence: "at its maximum: \(current) of \(max) replicas, it can't scale further"))
            }
        case ("argoproj.io", "Application"):
            let status = object["status"] as? [String: Any] ?? [:]
            let health = (status["health"] as? [String: Any])?["status"] as? String
            if let health, ["Degraded", "Missing"].contains(health) {
                let message = ((status["health"] as? [String: Any])?["message"] as? String).map { ": \($0)" } ?? ""
                found.append(Finding(check: .argoDegraded, subject: subject, sentence: "Argo CD says it is \(health)\(message)"))
            }
            if (status["sync"] as? [String: Any])?["status"] as? String == "OutOfSync" {
                found.append(Finding(check: .argoOutOfSync, subject: subject, sentence: "Argo CD says it is OutOfSync with its source"))
            }
        default:
            break
        }
        if !builtinGroups.contains(group), let ready = readyFalse(object) {
            found.append(Finding(check: .notReady, subject: subject, sentence: "its Ready condition is False" + (ready.isEmpty ? "" : ": \(ready)")))
        }
        return found.sorted(by: Finding.ordered)
    }

    /// Owned by a controller whose checks cover its containers.
    private static func isCovered(_ metadata: [String: Any], _ covered: (Owner) -> Bool) -> Bool {
        Owner.controller(of: metadata).map(covered) ?? false
    }

    /// A pod spec's containers, each check once a container. `probes`: only
    /// for what runs on (a Job's pods end — no probe is wanted there).
    static func containers(_ spec: [String: Any], subject: Subject, probes: Bool) -> [Finding] {
        var found: [Finding] = []
        for container in spec["containers"] as? [[String: Any]] ?? [] {
            let name = container["name"] as? String ?? "?"
            let says = "container \(name)"
            if probes {
                if container["readinessProbe"] == nil {
                    found.append(Finding(check: .noReadinessProbe, subject: subject, sentence: "\(says) has no readiness probe: it gets traffic before it is ready"))
                }
                if container["livenessProbe"] == nil {
                    found.append(Finding(check: .noLivenessProbe, subject: subject, sentence: "\(says) has no liveness probe: a hung process isn't restarted"))
                }
            }
            let resources = container["resources"] as? [String: Any] ?? [:]
            if (resources["requests"] as? [String: Any] ?? [:]).isEmpty {
                found.append(Finding(check: .noRequests, subject: subject, sentence: "\(says) requests no CPU or memory: the scheduler can't place it well"))
            }
            if (resources["limits"] as? [String: Any] ?? [:]).isEmpty {
                found.append(Finding(check: .noLimits, subject: subject, sentence: "\(says) has no limits: it can take its node's memory"))
            }
            if let image = container["image"] as? String, isLatest(image) {
                found.append(Finding(check: .latestImage, subject: subject, sentence: "\(says) runs \(image): not a version, so a restart may run another"))
            }
        }
        return found
    }

    /// `nginx`, `nginx:latest`, `registry:5000/app:latest` — not `app@sha256:…`
    /// or `registry:5000/app` with a tag.
    static func isLatest(_ image: String) -> Bool {
        if image.contains("@") { return false }
        let last = image.split(separator: "/").last.map(String.init) ?? image
        guard let colon = last.lastIndex(of: ":") else { return true }
        return last[last.index(after: colon)...] == "latest"
    }

    /// Each container restarted in the last hour: its last termination's
    /// end, else — no end said — when it started running again.
    static func restarts(_ pod: [String: Any], subject: Subject, now: Date) -> [Finding] {
        let status = pod["status"] as? [String: Any] ?? [:]
        var found: [Finding] = []
        for item in (status["initContainerStatuses"] as? [[String: Any]] ?? []) + (status["containerStatuses"] as? [[String: Any]] ?? []) {
            guard let count = KubeRollout.int(item["restartCount"]), count > 0 else { continue }
            let terminated = (item["lastState"] as? [String: Any])?["terminated"] as? [String: Any]
            let running = (item["state"] as? [String: Any])?["running"] as? [String: Any]
            let when = (terminated?["finishedAt"] as? String).flatMap(KubeTime.date) ?? (running?["startedAt"] as? String).flatMap(KubeTime.date)
            guard let when, now.timeIntervalSince(when) <= restartWindow else { continue }
            let reason = (terminated?["reason"] as? String).map { ", last \($0)" } ?? ""
            found.append(
                Finding(
                    check: .recentRestarts, subject: subject,
                    sentence:
                        "container \(item["name"] as? String ?? "?") restarted \(count) time\(count == 1 ? "" : "s")\(reason), the last \(KubeAge.format(max(0, now.timeIntervalSince(when)))) ago"))
        }
        return found
    }

    /// Pending for more than `pendingAfter`: since it was made, with the
    /// scheduler's word when it has one.
    static func pending(_ pod: [String: Any], subject: Subject, now: Date) -> Finding? {
        let status = pod["status"] as? [String: Any] ?? [:]
        guard status["phase"] as? String == "Pending",
            let created = ((pod["metadata"] as? [String: Any])?["creationTimestamp"] as? String).flatMap(KubeTime.date),
            now.timeIntervalSince(created) > pendingAfter
        else { return nil }
        let scheduled = (status["conditions"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "PodScheduled" && $0["status"] as? String == "False" }
        let why = (scheduled?["message"] as? String ?? scheduled?["reason"] as? String).map { ": \($0)" } ?? ""
        return Finding(check: .pendingLong, subject: subject, sentence: "Pending for \(KubeAge.format(now.timeIntervalSince(created)))\(why)")
    }

    /// A `Ready` condition False: its reason and message; nil when there is
    /// none, or it isn't False.
    static func readyFalse(_ object: [String: Any]) -> String? {
        let conditions = (object["status"] as? [String: Any])?["conditions"] as? [[String: Any]] ?? []
        guard let ready = conditions.first(where: { $0["type"] as? String == "Ready" }), ready["status"] as? String == "False" else { return nil }
        return [ready["reason"] as? String, ready["message"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: What needs another object

    /// A Service's selector against the pods read: one that picks none.
    /// `pods` must be the namespace's every pod (or every one its selector
    /// picks) — a cut list says nothing.
    static func serviceSelection(_ service: [String: Any], pods: [[String: Any]]) -> Finding? {
        let spec = service["spec"] as? [String: Any] ?? [:]
        guard spec["type"] as? String != "ExternalName", let selector = spec["selector"] as? [String: String], !selector.isEmpty else { return nil }
        let metadata = service["metadata"] as? [String: Any] ?? [:]
        let namespace = metadata["namespace"] as? String
        let inNamespace = pods.filter { (($0["metadata"] as? [String: Any])?["namespace"] as? String) == namespace || namespace == nil }
        guard !inNamespace.contains(where: { KubeTree.matches(selector, $0) }) else { return nil }
        let words = selector.keys.sorted().map { "\($0)=\(selector[$0]!)" }.joined(separator: ",")
        return Finding(
            check: .serviceSelectsNone, subject: Subject(apiVersion: "v1", kind: "Service", namespace: namespace, name: metadata["name"] as? String ?? ""),
            sentence: "selects no pod (\(words)): nothing answers it")
    }

    /// An Ingress's backends against the Services read: one missing, or
    /// without the port it is sent to. `services` must be the namespace's every one.
    static func ingressBackends(_ ingress: [String: Any], services: [[String: Any]]) -> [Finding] {
        let metadata = ingress["metadata"] as? [String: Any] ?? [:]
        let namespace = metadata["namespace"] as? String
        let subject = Subject(
            apiVersion: ingress["apiVersion"] as? String ?? "networking.k8s.io/v1", kind: "Ingress", namespace: namespace, name: metadata["name"] as? String ?? "")
        var byName: [String: [String: Any]] = [:]
        for service in services {
            let meta = service["metadata"] as? [String: Any] ?? [:]
            guard namespace == nil || meta["namespace"] as? String == namespace || meta["namespace"] == nil else { continue }
            byName[meta["name"] as? String ?? ""] = service
        }
        var found: [Finding] = []
        var said: Set<String> = []
        for backend in KubeTree.ingressBackends(ingress) {
            guard let service = byName[backend.service] else {
                if said.insert("svc:\(backend.service)").inserted {
                    found.append(Finding(check: .ingressMissingService, subject: subject, sentence: "sends \(backend.said) to Service \(backend.service), which isn't there"))
                }
                continue
            }
            if let port = backend.port, !KubeTree.hasPort(service, port), said.insert("port:\(backend.service):\(port)").inserted {
                found.append(Finding(check: .ingressMissingPort, subject: subject, sentence: "sends \(backend.said) to Service \(backend.service), which has no port \(port)"))
            }
        }
        return found
    }

    /// A detail's tree read what its root's relations need: a Service's
    /// pods (by its selector), an Ingress's Services. Said only from a list
    /// read whole.
    static func related(_ root: KubeTree.Root, read: KubeTreeRead) -> [Finding] {
        let object = read.rootObject
        switch root {
        case .service:
            guard let pods = read.list(.pods), pods.complete else { return [] }
            return serviceSelection(object, pods: pods.items).map { [$0] } ?? []
        case .ingress:
            guard let services = read.list(.services), services.complete else { return [] }
            return ingressBackends(object, services: services.items)
        default:
            return []
        }
    }

    // MARK: A namespace

    /// A list the namespace's checks read: where, how many at most.
    struct Read: Equatable, Hashable, Sendable {
        var group: String
        var resource: String
        var limit: Int

        var fullName: String { group.isEmpty ? resource : "\(resource).\(group)" }
    }

    static let podLimit = 200
    static let listLimit = 500

    /// Every list the checks use, in the order read — pods, the workloads
    /// (ReplicaSets and Jobs too: what owns a pod must be read for its
    /// containers to be left to it), what routes to them, the budgets and
    /// autoscalers, then the GitOps and certificate resources a context may
    /// serve. Never a Secret or a ConfigMap.
    static let reads: [Read] = [
        Read(group: "", resource: "pods", limit: podLimit),
        Read(group: "apps", resource: "deployments", limit: listLimit),
        Read(group: "apps", resource: "statefulsets", limit: listLimit),
        Read(group: "apps", resource: "daemonsets", limit: listLimit),
        Read(group: "batch", resource: "cronjobs", limit: listLimit),
        Read(group: "apps", resource: "replicasets", limit: listLimit),
        Read(group: "batch", resource: "jobs", limit: listLimit),
        Read(group: "", resource: "services", limit: listLimit),
        Read(group: "networking.k8s.io", resource: "ingresses", limit: listLimit),
        Read(group: "policy", resource: "poddisruptionbudgets", limit: listLimit),
        Read(group: "autoscaling", resource: "horizontalpodautoscalers", limit: listLimit),
        Read(group: "argoproj.io", resource: "applications", limit: listLimit),
        Read(group: "kustomize.toolkit.fluxcd.io", resource: "kustomizations", limit: listLimit),
        Read(group: "helm.toolkit.fluxcd.io", resource: "helmreleases", limit: listLimit),
        Read(group: "source.toolkit.fluxcd.io", resource: "gitrepositories", limit: listLimit),
        Read(group: "cert-manager.io", resource: "certificates", limit: listLimit),
    ]

    /// What of a listed object is kept for the checks: never what may
    /// carry a secret — env values (their names stay), Helm values (a Flux
    /// HelmRelease's, an Argo Application's), kubectl's last-applied copy
    /// of the whole object, managedFields. Dropped as each list is decoded.
    static func kept(_ object: [String: Any]) -> [String: Any] {
        var object = object
        if var metadata = object["metadata"] as? [String: Any] {
            metadata["managedFields"] = nil
            if var annotations = metadata["annotations"] as? [String: Any] {
                annotations["kubectl.kubernetes.io/last-applied-configuration"] = nil
                metadata["annotations"] = annotations
            }
            object["metadata"] = metadata
        }
        if let spec = object["spec"] as? [String: Any] { object["spec"] = scrubbed(spec) }
        return object
    }

    private static let secretKeys: Set<String> = ["values", "valuesObject", "valuesFrom", "parameters", "data", "stringData"]

    private static func scrubbed(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in dict where !secretKeys.contains(key) {
                if key == "env", let entries = inner as? [[String: Any]] {
                    out[key] = entries.map { entry in
                        var entry = entry
                        if entry["value"] != nil { entry["value"] = "" }
                        return entry
                    }
                } else {
                    out[key] = scrubbed(inner)
                }
            }
            return out
        }
        if let array = value as? [Any] { return array.map(scrubbed) }
        return value
    }

    /// What the checks read: each list's objects (in its kind: a list's
    /// items carry none), whether it was all of them, and what couldn't be read.
    struct Lists: @unchecked Sendable {
        struct List {
            var items: [[String: Any]]
            var complete: Bool
        }

        private(set) var lists: [String: List] = [:]
        var notes: [String] = []
        /// The lists that a namespace (or more) couldn't give: refused, or not JSON.
        private(set) var failed: Set<String> = []

        init() {}

        /// One list's answer: its objects, each given its kind and version —
        /// those of `scope`'s namespaces (a list across the cluster for
        /// more than the cap), added to the kind's others (one a namespace).
        mutating func add(_ read: Read, kind: String, apiVersion: String, body: Data, place: String, scope: KubeScope = .all) {
            guard let list = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                notes.append("The \(read.fullName) list couldn't be read: the answer isn't JSON.")
                failed.insert(read.fullName)
                return
            }
            let more = ((list["metadata"] as? [String: Any])?["continue"] as? String).map { !$0.isEmpty } ?? false
            if more { notes.append("More than \(read.limit) \(read.fullName) in \(place): only \(read.limit) were checked.") }
            let items = (list["items"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
                guard scope.includes((item["metadata"] as? [String: Any])?["namespace"] as? String) else { return nil }
                var item = KubeHealth.kept(item)
                if item["kind"] == nil { item["kind"] = kind }
                if item["apiVersion"] == nil { item["apiVersion"] = apiVersion }
                return item
            }
            if let old = lists[read.fullName] {
                lists[read.fullName] = List(items: old.items + items, complete: old.complete && !more)
            } else {
                lists[read.fullName] = List(items: items, complete: !more)
            }
        }

        mutating func failed(_ read: Read, _ reason: String, place: String) {
            notes.append("The \(read.fullName) in \(place) couldn't be listed: \(reason)")
            failed.insert(read.fullName)
        }

        func list(_ fullName: String) -> List? { lists[fullName] }
        /// Read, and read whole: every namespace answered, none cut at its limit.
        func whole(_ fullName: String) -> Bool { lists[fullName]?.complete == true && !failed.contains(fullName) }
        /// Not read at all: not served (a CRD not installed), not asked.
        func absent(_ fullName: String) -> Bool { lists[fullName] == nil && !failed.contains(fullName) }
        var read: Int { lists.count }
        var objects: Int { lists.values.reduce(0) { $0 + $1.items.count } }
    }

    /// What a namespace's (or every namespace's) checks found.
    struct Report: Equatable, Sendable {
        var findings: [Finding] = []
        /// How many objects were checked, and what wasn't read.
        var checked = 0
        var notes: [String] = []
        /// The checks that ran over lists read whole — what found nothing
        /// among them passes; one over a list refused, cut short or never
        /// read says nothing (`KubeHealth.ran`).
        var ran: Set<Check> = []

        var errors: Int { findings.count { $0.severity == .error } }
        var warnings: Int { findings.count { $0.severity == .warning } }
        /// `3 problems, 12 warnings`, or that nothing was found.
        var said: String {
            guard !findings.isEmpty else { return "No finding in \(checked) object\(checked == 1 ? "" : "s")" }
            let parts = [errors > 0 ? "\(errors) problem\(errors == 1 ? "" : "s")" : nil, warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
            return parts.compactMap { $0 }.joined(separator: ", ")
        }

        /// The findings of each check, the worst first.
        var byCheck: [(check: Check, findings: [Finding])] {
            let grouped = Dictionary(grouping: findings, by: \.check)
            return grouped.keys.sorted { a, b in a.severity != b.severity ? a.severity > b.severity : a.code < b.code }.map { ($0, grouped[$0]!) }
        }
    }

    /// Every check over what was read: each object's own, a Service's pods
    /// and an Ingress's Services where those lists were read whole.
    static func report(_ lists: Lists, now: Date = Date()) -> Report {
        var report = Report(checked: lists.objects, notes: lists.notes)
        var found: [Finding] = []
        // What owns a pod is checked first, top down: a container left to
        // its owner only when that owner was read and checked here — a
        // ReplicaSet to its Deployment, a Job to its CronJob, a pod to its
        // ReplicaSet, StatefulSet, DaemonSet or Job. One owned by what
        // wasn't read (a Rollout, an operator's, a list cut short) is checked itself.
        var checked: Set<Owner> = []
        let tiers: [[String]] = [
            ["deployments.apps", "statefulsets.apps", "daemonsets.apps", "cronjobs.batch"], ["replicasets.apps", "jobs.batch"], ["pods"],
        ]
        for tier in tiers {
            var next: Set<Owner> = []
            for name in tier {
                for item in lists.list(name)?.items ?? [] {
                    found += object(item, now: now) { checked.contains($0) }
                    next.insert(Owner.of(item))
                }
            }
            checked.formUnion(next)
        }
        let ordered = Set(tiers.joined())
        for read in reads where !ordered.contains(read.fullName) {
            for item in lists.list(read.fullName)?.items ?? [] { found += object(item, now: now) }
        }
        if let pods = lists.list("pods"), lists.whole("pods") {
            for service in lists.list("services")?.items ?? [] {
                if let finding = serviceSelection(service, pods: pods.items) { found.append(finding) }
            }
        } else if lists.list("pods") != nil, !(lists.list("services")?.items.isEmpty ?? true) {
            report.notes.append("Services' selections aren't checked: not every pod was read.")
        }
        if let services = lists.list("services"), lists.whole("services") {
            for ingress in lists.list("ingresses.networking.k8s.io")?.items ?? [] { found += ingressBackends(ingress, services: services) }
        }
        report.findings = Array(Set(found)).sorted(by: Finding.ordered)
        report.ran = ran(lists)
        return report
    }

    /// The lists a check reads: `whole`, each read whole; `optional`, each
    /// read whole or not served at all (none refused or cut short);
    /// `served`, at least one of the optional ones was read.
    private struct Needs {
        var whole: [String] = []
        var optional: [String] = []
        var served = false
    }

    private static func needs(_ check: Check) -> Needs {
        let workloads = ["deployments.apps", "statefulsets.apps", "daemonsets.apps", "cronjobs.batch", "replicasets.apps", "jobs.batch"]
        let gitOps = [
            "argoproj.io", "kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io", "source.toolkit.fluxcd.io", "cert-manager.io",
        ]
        .flatMap { group in reads.filter { $0.group == group }.map(\.fullName) }
        switch check {
        case .noReadinessProbe, .noLivenessProbe, .noRequests, .noLimits, .latestImage:
            return Needs(whole: ["pods"], optional: workloads)
        case .serviceSelectsNone: return Needs(whole: ["pods", "services"])
        case .ingressMissingService, .ingressMissingPort: return Needs(whole: ["services", "ingresses.networking.k8s.io"])
        case .pdbNoDisruption: return Needs(whole: ["poddisruptionbudgets.policy"])
        case .hpaAtMax: return Needs(whole: ["horizontalpodautoscalers.autoscaling"])
        case .recentRestarts, .pendingLong: return Needs(whole: ["pods"])
        case .notReady: return Needs(optional: gitOps, served: true)
        case .argoDegraded, .argoOutOfSync: return Needs(whole: ["applications.argoproj.io"])
        }
    }

    /// The checks whose lists were all read whole.
    static func ran(_ lists: Lists) -> Set<Check> {
        Set(
            Check.allCases.filter { check in
                let needs = needs(check)
                guard needs.whole.allSatisfy(lists.whole) else { return false }
                guard needs.optional.allSatisfy({ lists.whole($0) || lists.absent($0) }) else { return false }
                return !needs.served || needs.optional.contains(where: lists.whole)
            })
    }

    /// `ingressBackends` over a list.
    private static func ingressBackends(_ ingress: [String: Any], services: Lists.List) -> [Finding] {
        ingressBackends(ingress, services: services.items)
    }
}
