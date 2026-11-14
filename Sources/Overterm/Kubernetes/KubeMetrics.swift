import Foundation

/// Kubernetes' quantities (`500m`, `1.5`, `128Mi`, `1G`, `1e3`,
/// `1234567n`) as numbers: cores for cpu, bytes for memory. A suffix is
/// one of the binary (`Ki`…`Ei`) or decimal (`n`, `u`, `m`, `k`, `M`…`E`)
/// ones; a decimal exponent (`e3`, `E-2`) is the number's own. Pure.
enum KubeQuantity {
    static let suffixes: [(String, Double)] = [
        ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824), ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624),
        ("Ei", 1_152_921_504_606_846_976), ("n", 1e-9), ("u", 1e-6), ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15),
        ("E", 1e18),
    ]

    static func value(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for (suffix, scale) in suffixes where text.hasSuffix(suffix) {
            guard let number = number(text.dropLast(suffix.count)) else { return nil }
            return number * scale
        }
        return number(Substring(text))
    }

    /// A plain or exponent number: digits, a point, a sign, `e` — never
    /// `nan`, `inf` or hex, which `Double` would take.
    private static func number(_ text: Substring) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }), let value = Double(text), value.isFinite
        else { return nil }
        return value
    }
}

/// What something uses or has: cpu in cores, memory in bytes.
struct KubeUsage: Equatable, Sendable {
    var cpu: Double
    var memory: Double

    static let zero = KubeUsage(cpu: 0, memory: 0)

    static func + (lhs: KubeUsage, rhs: KubeUsage) -> KubeUsage { KubeUsage(cpu: lhs.cpu + rhs.cpu, memory: lhs.memory + rhs.memory) }

    /// `{cpu, memory}` as the API writes them; nil when neither reads.
    init?(_ value: Any?) {
        guard let map = value as? [String: Any] else { return nil }
        let cpu = (map["cpu"] as? String).flatMap(KubeQuantity.value)
        let memory = (map["memory"] as? String).flatMap(KubeQuantity.value)
        guard cpu != nil || memory != nil else { return nil }
        self.init(cpu: cpu ?? 0, memory: memory ?? 0)
    }

    init(cpu: Double, memory: Double) {
        self.cpu = cpu
        self.memory = memory
    }
}

/// One pod's sample (metrics.k8s.io's PodMetrics): when metrics-server
/// took it, over how long, and each container's usage.
struct KubePodMetrics: Equatable, Sendable {
    var id: KubeRowID
    var timestamp: Date?
    var window: String?
    var containers: [String: KubeUsage]
    /// Its revision, as its labels say it (metrics-server copies the pod's):
    /// `pod-template-hash` (a Deployment's), else `controller-revision-hash`
    /// (a StatefulSet's, a DaemonSet's). No other label is kept.
    var revision: String? = nil

    var total: KubeUsage { containers.values.reduce(.zero, +) }
}

/// One node's sample (NodeMetrics).
struct KubeNodeMetrics: Equatable, Sendable {
    var name: String
    var timestamp: Date?
    var window: String?
    var usage: KubeUsage
}

/// metrics.k8s.io's answers, and the nodes' allocatable, read. Pure.
enum KubeMetricsReader {
    struct Malformed: Error, LocalizedError {
        var detail: String
        var errorDescription: String? { "metrics.k8s.io's answer isn't a metrics list: \(detail)" }
    }

    private static func items(_ data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object["items"] as? [[String: Any]] else {
            throw Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        return items
    }

    static func time(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return try? Date(text, strategy: .iso8601)
    }

    /// A Go duration as the API writes one (a sample's `window`: `15.012s`,
    /// `1m0.5s`, `500ms`), in seconds; nil for anything else.
    static func seconds(_ value: Any?) -> TimeInterval? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let units: [(String, Double)] = [("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("μs", 1e-6), ("ms", 1e-3), ("h", 3600), ("m", 60), ("s", 1)]
        var rest = Substring(text)
        var total = 0.0
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            guard let (unit, scale) = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            rest = rest.dropFirst(unit.count)
            total += value * scale
        }
        return total
    }

    /// A PodMetricsList.
    static func pods(_ data: Data) throws -> [KubePodMetrics] { try items(data).compactMap(pod(item:)) }

    /// A NodeMetricsList.
    static func nodes(_ data: Data) throws -> [KubeNodeMetrics] { try items(data).compactMap(node(item:)) }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        return object
    }

    /// One PodMetrics (a pod's own GET).
    static func pod(_ data: Data) throws -> KubePodMetrics {
        guard let pod = pod(item: try object(data)) else { throw Malformed(detail: "no pod's sample") }
        return pod
    }

    /// One NodeMetrics (a node's own GET).
    static func node(_ data: Data) throws -> KubeNodeMetrics {
        guard let node = node(item: try object(data)) else { throw Malformed(detail: "no node's sample") }
        return node
    }

    private static func pod(item: [String: Any]) -> KubePodMetrics? {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        guard let name = metadata["name"] as? String else { return nil }
        var containers: [String: KubeUsage] = [:]
        for container in item["containers"] as? [[String: Any]] ?? [] {
            guard let name = container["name"] as? String, let usage = KubeUsage(container["usage"]) else { continue }
            containers[name] = usage
        }
        let labels = metadata["labels"] as? [String: Any] ?? [:]
        return KubePodMetrics(
            id: KubeRowID(namespace: metadata["namespace"] as? String, name: name), timestamp: time(item["timestamp"]), window: item["window"] as? String,
            containers: containers, revision: (labels["pod-template-hash"] as? String) ?? (labels["controller-revision-hash"] as? String))
    }

    private static func node(item: [String: Any]) -> KubeNodeMetrics? {
        guard let name = (item["metadata"] as? [String: Any])?["name"] as? String, let usage = KubeUsage(item["usage"]) else { return nil }
        return KubeNodeMetrics(name: name, timestamp: time(item["timestamp"]), window: item["window"] as? String, usage: usage)
    }

    /// A HorizontalPodAutoscaler (autoscaling/v2), as its status says it.
    static func hpa(_ data: Data) throws -> KubeHPAStatus {
        let object = try object(data)
        guard let name = (object["metadata"] as? [String: Any])?["name"] as? String else { throw Malformed(detail: "no HorizontalPodAutoscaler") }
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        func metric(_ entry: [String: Any], _ side: String) -> (name: String, value: String?)? {
            guard let type = entry["type"] as? String else { return nil }
            let key = type.prefix(1).lowercased() + type.dropFirst()
            guard let body = entry[key] as? [String: Any] else { return nil }
            let named = (body["name"] as? String) ?? ((body["metric"] as? [String: Any])?["name"] as? String) ?? type
            guard let values = body[side] as? [String: Any] else { return (named, nil) }
            if let percent = int(values["averageUtilization"]) { return (named, "\(percent)%") }
            return (named, (values["averageValue"] as? String) ?? (values["value"] as? String))
        }
        let targets = (spec["metrics"] as? [[String: Any]] ?? []).compactMap { metric($0, "target") }
        let currents = (status["currentMetrics"] as? [[String: Any]] ?? []).compactMap { metric($0, "current") }
        let metrics = targets.map { target in
            KubeHPAStatus.Metric(name: target.name, current: currents.first { $0.name == target.name }?.value ?? nil, target: target.value)
        }
        let limited = (status["conditions"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "ScalingLimited" && $0["status"] as? String == "True" }
        return KubeHPAStatus(
            name: name, current: int(status["currentReplicas"]) ?? 0, desired: int(status["desiredReplicas"]) ?? 0, min: int(spec["minReplicas"]) ?? 1,
            max: int(spec["maxReplicas"]) ?? 0, scalingLimited: limited, metrics: metrics)
    }

    /// A NodeList's `status.allocatable`, by node, and where the next page starts.
    static func allocatable(_ data: Data) throws -> (nodes: [String: KubeUsage], continueToken: String?) {
        let read = try nodeResources(data)
        return (read.allocatable, read.continueToken)
    }

    /// A NodeList's `status.allocatable` and `status.capacity`, by node (the
    /// Overview's lines, X1 and X2), and where the next page starts.
    static func nodeResources(_ data: Data) throws -> (allocatable: [String: KubeUsage], capacity: [String: KubeUsage], continueToken: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        var nodes: [String: KubeUsage] = [:]
        var capacity: [String: KubeUsage] = [:]
        for item in object["items"] as? [[String: Any]] ?? [] {
            guard let name = (item["metadata"] as? [String: Any])?["name"] as? String else { continue }
            let status = item["status"] as? [String: Any]
            if let usage = KubeUsage(status?["allocatable"]) { nodes[name] = usage }
            if let usage = KubeUsage(status?["capacity"]) { capacity[name] = usage }
        }
        let token = ((object["metadata"] as? [String: Any])?["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (nodes, capacity, token)
    }
}

/// Usage as `kubectl top` says it: cpu in millicores, memory in Mi (Ki
/// below one). Pure.
enum KubeMetricsFormat {
    static func cpu(_ cores: Double) -> String { "\(Int((cores * 1000).rounded()))m" }

    static func memory(_ bytes: Double) -> String {
        if bytes > 0, bytes < 1_048_576 { return "\(Int((bytes / 1024).rounded()))Ki" }
        return "\(Int((bytes / 1_048_576).rounded()))Mi"
    }

    /// `used` of `total`, a whole percent; nil without a total.
    static func percent(_ used: Double, of total: Double?) -> Int? {
        guard let total, total > 0 else { return nil }
        return Int((used / total * 100).rounded())
    }

    /// `12s`, `3m`, `2h`: how old a sample is.
    static func age(_ seconds: TimeInterval) -> String { KubeAge.format(max(0, seconds)) }
}

/// Where a context's usage comes from (`metrics` in its
/// `kubernetes.contexts` entry): metrics-server when the cluster serves
/// it (unset, the default), metrics-server only, or none — `none` skips
/// the check entirely: no column, nothing asked. Prometheus is opt-in
/// (stage 4): `prometheus`, or `auto` set in the entry, looks for one
/// besides metrics-server (`KubePrometheusUse`).
enum KubeMetricsSource: String, CaseIterable, Sendable {
    case auto, metricsServer, prometheus, none

    var title: String {
        switch self {
        case .auto: "Auto: metrics-server when served, and Prometheus when found"
        case .metricsServer: "metrics-server only"
        case .prometheus: "Prometheus, with metrics-server's columns when served"
        case .none: "None: no usage columns, nothing asked"
        }
    }
}

/// Whether usage can be read, as discovery says it — no request is made to
/// find out. Pure.
enum KubeMetricsAvailability: Equatable, Sendable {
    /// The context's `metrics` is `none`: nothing shown or asked.
    case off
    /// Discovery not read yet.
    case unknown
    /// metrics.k8s.io serves pods and nodes.
    case served
    /// The cluster has no metrics-server (EKS has none by default).
    case absent
    /// metrics.k8s.io is registered but not answering (discovery marks it).
    case down(String)

    static let group = "metrics.k8s.io"

    static func of(_ discovery: KubeDiscovery?, source: KubeMetricsSource) -> KubeMetricsAvailability {
        if source == .none { return .off }
        guard let discovery else { return .unknown }
        if discovery.kinds.contains(where: { $0.group == group && $0.resource == "pods" && $0.canList }) { return .served }
        if let failed = discovery.failedGroups.first(where: { $0.key.hasPrefix(group + "/") }) { return .down(failed.value) }
        return .absent
    }

    /// What a dash says instead of a number.
    var reason: String? {
        switch self {
        case .off: "Metrics are off for this context (its metrics setting is none)."
        case .unknown: "Reading what the cluster serves…"
        case .served: nil
        case .absent: "No metrics-server: this cluster doesn't serve metrics.k8s.io (EKS has none by default). Overterm installs nothing."
        case .down(let why): "metrics-server isn't answering: \(why)"
        }
    }
}

/// What usage is read for: a scope's pods (with the list's label
/// selector), the nodes — and then their allocatable too — or, for a
/// detail, one pod, one node, one HorizontalPodAutoscaler.
enum KubeMetricsTarget: Hashable, Sendable {
    case pods(KubeScope, labels: String?)
    case nodes
    case pod(namespace: String, name: String)
    case node(String)
    case hpa(namespace: String, name: String)
    /// A workload's own object, for its replicas (W4): an apiserver GET.
    case replicas(namespace: String, kind: String, name: String, path: String)
    /// A node's pods as objects (`fieldSelector=spec.nodeName`, at most
    /// `KubeNodePods.limit`), decoded to their requests, limits and phase
    /// and dropped (K1, K2, K4).
    case nodePods(String)
    /// A namespace's pods as Metadata rows, paged: their owners and
    /// statuses (N1, N2, N4).
    case namespacePods(String)
    /// Some namespaces' PodMetrics, for one node's pods ("Sample top pods", K3).
    case podsOn(node: String, namespaces: [String])

    static let base = "/apis/metrics.k8s.io/v1beta1"

    /// How many polls' intervals apart it is read: a workload's replicas
    /// and a namespace's rows a minute (at 15 s), a node's pods five, a
    /// node's top pods 30 s; the rest each poll.
    var every: Int {
        switch self {
        case .replicas, .namespacePods: 4
        case .nodePods: 20
        case .podsOn: 2
        case .pods, .nodes, .pod, .node, .hpa: 1
        }
    }

    /// Its metrics.k8s.io list, or its one object.
    var path: String { paths[0] }

    /// Its reads: several namespaces' pods a list each (past the cap,
    /// across the cluster — `scope` keeps the samples to them).
    var paths: [String] {
        switch self {
        case .pods(let scope, _):
            return scope.reads(for: .pods).map(podsPath)
        case .nodes: return [Self.base + "/nodes"]
        case .pod(let namespace, let name): return [Self.base + "/namespaces/\(KubePath.segment(namespace))/pods/\(KubePath.segment(name))"]
        case .node(let name): return [Self.base + "/nodes/\(KubePath.segment(name))"]
        case .hpa(let namespace, let name):
            return ["/apis/autoscaling/v2/namespaces/\(KubePath.segment(namespace))/horizontalpodautoscalers/\(KubePath.segment(name))"]
        case .replicas(_, _, _, let path): return [path]
        case .nodePods(let node):
            return [KubePath.query("/api/v1/pods", [("fieldSelector", "spec.nodeName=" + node), ("limit", String(KubeNodePods.limit))])]
        case .namespacePods(let namespace):
            return [
                KubePath.query(
                    "/api/v1/namespaces/\(KubePath.segment(namespace))/pods", [("includeObject", "Metadata"), ("limit", String(KubeNamespacePods.pageSize))])
            ]
        case .podsOn(_, let namespaces): return namespaces.map(podsPath)
        }
    }

    /// Whether it is metrics-server's: an HPA, a workload, a node's or a
    /// namespace's pods are the apiserver's own, read with or without one.
    var needsMetricsServer: Bool {
        switch self {
        case .hpa, .replicas, .nodePods, .namespacePods: false
        case .pods, .nodes, .pod, .node, .podsOn: true
        }
    }

    /// A pods target's read of one namespace (nil: across the cluster).
    func podsPath(_ namespace: String?) -> String {
        let labels: String? = if case .pods(_, let labels) = self { labels } else { nil }
        let base = Self.base + (namespace.map { "/namespaces/\(KubePath.segment($0))" } ?? "") + "/pods"
        return KubePath.query(base, [("labelSelector", labels)])
    }

    /// A pods target's reads: a namespace each, or one across the cluster (nil).
    var podsReads: [String?] {
        guard case .pods(let scope, _) = self else { return [] }
        return scope.reads(for: .pods)
    }

    /// What a 403 on it says, once (metrics.md 4.7): who refused what, where.
    var refusal: String {
        switch self {
        case .pods: return Self.podsRefusal(podsReads)
        case .nodes: return KubeChartEmpty.metricsServerForbidden(verb: "list", resource: "nodes.metrics.k8s.io", place: "").sentence
        case .pod(let namespace, _): return KubeChartEmpty.metricsServerForbidden(verb: "get", resource: "pods.metrics.k8s.io", place: " in \(namespace)").sentence
        case .node: return KubeChartEmpty.metricsServerForbidden(verb: "get", resource: "nodes.metrics.k8s.io", place: "").sentence
        case .hpa(let namespace, _): return "The apiserver answered 403: you can't get horizontalpodautoscalers.autoscaling in \(namespace)."
        case .replicas(let namespace, let kind, _, _): return "The apiserver answered 403: you can't get this \(kind) in \(namespace)."
        case .nodePods: return "The apiserver answered 403: you can't list pods across the cluster, so the node's requests aren't known."
        case .namespacePods(let namespace): return "The apiserver answered 403: you can't list pods in \(namespace)."
        case .podsOn(_, let namespaces): return Self.podsRefusal(namespaces)
        }
    }

    /// What a 403 on some of a pods target's reads says: only those
    /// (nil, the read across the cluster).
    static func podsRefusal(_ reads: [String?]) -> String {
        let names = reads.compactMap { $0 }.sorted()
        let place = reads.contains(nil) || names.isEmpty ? " across the cluster" : " in " + names.joined(separator: ", ")
        return KubeChartEmpty.metricsServerForbidden(verb: "list", resource: "pods.metrics.k8s.io", place: place).sentence
    }

    /// The pods' samples, read over its reads but `skipping`, kept to the
    /// scope. A read refused (a 403) is left out and named in `refused`, as
    /// a list's namespace is (`KubeScopeMerge`): the others' samples stand.
    /// Every read refused: the 403 is thrown.
    func pods(_ client: KubeClient, skipping: Set<String?> = []) async throws -> KubePodsRead {
        if case .podsOn(_, let namespaces) = self {
            var read = KubePodsRead()
            var forbidden: KubeAPIError?
            let reads = namespaces.filter { !skipping.contains($0) }
            for namespace in reads {
                do {
                    read.pods += try KubeMetricsReader.pods(try await client.get(podsPath(namespace)).body)
                } catch let error as KubeAPIError where error.isForbidden {
                    forbidden = error
                    read.refused.append(namespace)
                }
            }
            if let forbidden, read.refused.count == reads.count { throw forbidden }
            return read
        }
        guard case .pods(let scope, _) = self else { return KubePodsRead() }
        var read = KubePodsRead()
        var forbidden: KubeAPIError?
        let reads = podsReads.filter { !skipping.contains($0) }
        for namespace in reads {
            do {
                read.pods += try KubeMetricsReader.pods(try await client.get(podsPath(namespace)).body)
            } catch let error as KubeAPIError where error.isForbidden {
                forbidden = error
                read.refused.append(namespace)
            }
        }
        if let forbidden, read.refused.count == reads.count { throw forbidden }
        read.pods = read.pods.filter { scope.includes($0.id.namespace) }
        return read
    }
}

/// A pods target's samples, and the reads refused (nil: the read across
/// the cluster), left out.
struct KubePodsRead: Sendable {
    var pods: [KubePodMetrics] = []
    var refused: [String?] = []
}

/// What a detail reads usage for (metrics.md 4.1): the target polled, and
/// the ring's sum its samples also go to — a workload's pods, a
/// namespace's.
enum KubeMetricsDetail: Hashable, Sendable {
    case pod(namespace: String, name: String)
    case node(String)
    case hpa(namespace: String, name: String)
    /// A workload's pods, by its selector.
    case workload(namespace: String, kind: String, name: String, labels: String)
    case namespace(String)
    /// A workload's object, for its replicas.
    case replicas(namespace: String, kind: String, name: String, path: String)
    /// A node's pods as objects.
    case nodePods(String)
    /// A namespace's pods as Metadata rows.
    case namespacePods(String)
    /// A node's largest pods' samples, from their namespaces' lists.
    case nodeTopPods(node: String, namespaces: [String], pods: [String])

    var target: KubeMetricsTarget {
        switch self {
        case .pod(let namespace, let name): .pod(namespace: namespace, name: name)
        case .node(let name): .node(name)
        case .hpa(let namespace, let name): .hpa(namespace: namespace, name: name)
        case .workload(let namespace, _, _, let labels): .pods(.namespace(namespace), labels: labels)
        case .namespace(let namespace): .pods(.namespace(namespace), labels: nil)
        case .replicas(let namespace, let kind, let name, let path): .replicas(namespace: namespace, kind: kind, name: name, path: path)
        case .nodePods(let node): .nodePods(node)
        case .namespacePods(let namespace): .namespacePods(namespace)
        case .nodeTopPods(let node, let namespaces, _): .podsOn(node: node, namespaces: namespaces)
        }
    }

    /// The ring's sum for it, if it is one.
    var sum: KubeUsageKey? {
        switch self {
        case .workload(let namespace, let kind, let name, _): .workload(namespace: namespace, kind: kind, name: name)
        case .namespace(let namespace): .namespace(namespace)
        case .pod, .node, .hpa, .replicas, .nodePods, .namespacePods, .nodeTopPods: nil
        }
    }

    /// What its samples are broken into beside the sum.
    var parts: [KubeUsageParts] {
        switch self {
        case .workload(_, let kind, let name, _):
            let revisions: [KubeUsageParts] = ["Deployment", "StatefulSet", "DaemonSet"].contains(kind) ? [.revisions(whole: kind + "/" + name)] : []
            return [.pods(only: nil)] + revisions
        case .namespace: return [.workloads]
        case .nodeTopPods(_, _, let pods): return [.pods(only: pods)]
        case .pod, .node, .hpa, .replicas, .nodePods, .namespacePods: return []
        }
    }

    /// The namespace whose Metadata rows say its pods' owners (`.workloads`).
    var ownersFrom: String? {
        if case .namespace(let namespace) = self { return namespace }
        return nil
    }
}

/// A HorizontalPodAutoscaler's state: its replicas against its bounds, and
/// each metric's current value against its target (`status.currentMetrics`).
struct KubeHPAStatus: Equatable, Sendable {
    struct Metric: Equatable, Sendable {
        var name: String
        var current: String?
        var target: String?
    }

    var name: String
    var current: Int
    var desired: Int
    var min: Int
    var max: Int
    var scalingLimited: Bool
    var metrics: [Metric]
}

/// What a page wants usage for: the pods list, or the nodes (their list,
/// the Overview's totals).
enum KubeMetricsWant: Hashable, Sendable {
    case pods, nodes
}

/// One reading of a target: what came, when it came, and what went wrong
/// since (the last one stands, aging, until it is too old to show).
struct KubeMetricsSample: Equatable, Sendable {
    var pods: [KubeRowID: KubePodMetrics] = [:]
    var nodes: [String: KubeNodeMetrics] = [:]
    /// Each node's allocatable (nodes only; read now and then, not each time).
    var allocatable: [String: KubeUsage] = [:]
    /// Each node's capacity, read with its allocatable.
    var capacity: [String: KubeUsage] = [:]
    /// When the answer came.
    var read: Date
    /// The oldest sample in it, as metrics-server stamped it.
    var oldest: Date?
    /// An HPA's (an `.hpa` target's).
    var hpa: KubeHPAStatus?
    /// A workload's replicas (a `.replicas` target's).
    var replicas: KubeReplicaStatus?
    /// A node's pods, decoded (a `.nodePods` target's).
    var nodePods: KubeNodePods?
    /// A namespace's pods' owners and statuses (a `.namespacePods` target's).
    var namespacePods: KubeNamespacePods?
    /// A pods target's reads refused (a 403), their pods left out: the
    /// namespaces (nil, across the cluster).
    var refusedReads: [String?] = []

    /// What the refused reads say, once: nil when none was.
    var refusal: String? { refusedReads.isEmpty ? nil : KubeMetricsTarget.podsRefusal(refusedReads) }

    /// Whether a pod in `namespace` was left out by a refused read.
    func refuses(_ namespace: String?) -> Bool { refusedReads.contains(nil) || refusedReads.contains(namespace) }

    init(read: Date) { self.read = read }

    init(hpa: KubeHPAStatus, read: Date) {
        self.read = read
        self.hpa = hpa
    }

    init(pods: [KubePodMetrics], read: Date) {
        self.read = read
        self.pods = Dictionary(pods.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        oldest = pods.compactMap(\.timestamp).min()
    }

    init(nodes: [KubeNodeMetrics], allocatable: [String: KubeUsage], read: Date) {
        self.read = read
        self.nodes = Dictionary(nodes.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        self.allocatable = allocatable
        oldest = nodes.compactMap(\.timestamp).min()
    }

    /// The longest window a sample in it was taken over: metrics-server's
    /// resolution (`--metric-resolution`, 15 s by default, often 60 s) —
    /// how far apart its samples come, however often it is asked.
    var resolution: TimeInterval? {
        (pods.values.map(\.window) + nodes.values.map(\.window)).compactMap(KubeMetricsReader.seconds).max()
    }

    /// Every node's usage and allocatable added up: the cluster's.
    var clusterUsage: KubeUsage { nodes.values.map(\.usage).reduce(.zero, +) }
    var clusterAllocatable: KubeUsage? {
        allocatable.isEmpty ? nil : allocatable.values.reduce(.zero, +)
    }
    var clusterCapacity: KubeUsage? {
        capacity.isEmpty ? nil : capacity.values.reduce(.zero, +)
    }
}

/// How a target's reading stands.
struct KubeMetricsReading: Equatable, Sendable {
    var sample: KubeMetricsSample?
    /// Why the last read failed (a 403, metrics-server down), nil when it didn't.
    var problem: String?
    /// The target was refused (a 403): said once, in these words, and not
    /// asked again until the context's credentials change.
    var refused: String?
}

/// A usage cell: a number, or a dash and why. Pure.
enum KubeUsageCell: Equatable, Sendable {
    /// The value as drawn (`250m`, `48Mi`, with `12%` of allocatable for a
    /// node), and the number it sorts by.
    case value(String, sort: Double, percent: Int?)
    case dash(String)
    /// Asked, not answered yet.
    case waiting

    var text: String {
        switch self {
        case .value(let text, _, let percent): percent.map { "\(text) (\($0)%)" } ?? text
        case .dash: "—"
        case .waiting: "…"
        }
    }

    var sort: Double? {
        if case .value(_, let sort, _) = self { return sort }
        return nil
    }

    var help: String? {
        if case .dash(let why) = self { return why }
        return nil
    }

    enum Measure: Sendable { case cpu, memory }

    /// A row's cell: a pod's (its containers summed) or a node's (with its
    /// share of allocatable), else a dash saying why — no metrics-server, a
    /// read that failed, a sample too old to show as current, a pod not
    /// sampled (not running yet).
    static func of(
        _ measure: Measure, row id: KubeRowID, isNode: Bool, availability: KubeMetricsAvailability, reading: KubeMetricsReading?, now: Date,
        staleAfter: TimeInterval
    ) -> KubeUsageCell {
        if let reason = availability.reason, availability != .unknown { return .dash(reason) }
        guard availability == .served, let reading else { return .waiting }
        guard let sample = reading.sample else {
            if let refused = reading.refused { return .dash(refused) }
            return reading.problem.map { .dash("Usage couldn't be read: \($0)") } ?? .waiting
        }
        let age = now.timeIntervalSince(sample.read)
        if age > staleAfter {
            let why = reading.problem.map { ": \($0)" } ?? ""
            return .dash("Not read for \(KubeMetricsFormat.age(age))\(why) — never shown as current.")
        }
        let usage: KubeUsage
        var total: KubeUsage?
        if isNode {
            guard let node = sample.nodes[id.name] else { return .dash("metrics-server has no sample of this node.") }
            usage = node.usage
            total = sample.allocatable[id.name]
        } else {
            guard let pod = sample.pods[id] else {
                if sample.refuses(id.namespace), let refusal = sample.refusal { return .dash(refusal) }
                return .dash("metrics-server has no sample of this pod yet (it samples running pods).")
            }
            usage = pod.total
        }
        switch measure {
        case .cpu: return .value(KubeMetricsFormat.cpu(usage.cpu), sort: usage.cpu, percent: KubeMetricsFormat.percent(usage.cpu, of: total?.cpu))
        case .memory:
            return .value(KubeMetricsFormat.memory(usage.memory), sort: usage.memory, percent: KubeMetricsFormat.percent(usage.memory, of: total?.memory))
        }
    }
}

/// A pod's containers' usage against what they request and are limited
/// to, from its spec (the detail's one GET) and the list's sample. Pure.
enum KubeContainerUsage {
    struct Line: Equatable, Sendable {
        var container: String
        var cpu: String
        var memory: String
        /// Over its memory limit by nine tenths or more: OOMKilled is near.
        var nearLimit: Bool
    }

    static func lines(_ pod: [String: Any], _ metrics: KubePodMetrics) -> [Line] {
        let containers = (pod["spec"] as? [String: Any])?["containers"] as? [[String: Any]] ?? []
        var lines: [Line] = []
        var named = Set<String>()
        for container in containers {
            guard let name = container["name"] as? String, let usage = metrics.containers[name] else { continue }
            named.insert(name)
            let resources = container["resources"] as? [String: Any] ?? [:]
            let requests = resources["requests"] as? [String: Any] ?? [:]
            let limits = resources["limits"] as? [String: Any] ?? [:]
            func said(_ used: Double, _ key: String, _ format: (Double) -> String) -> String {
                var text = format(used)
                if let request = (requests[key] as? String).flatMap(KubeQuantity.value), let percent = KubeMetricsFormat.percent(used, of: request) {
                    text += " · \(percent)% of \(format(request)) requested"
                }
                if let limit = (limits[key] as? String).flatMap(KubeQuantity.value), let percent = KubeMetricsFormat.percent(used, of: limit) {
                    text += " · \(percent)% of its \(format(limit)) limit"
                }
                return text
            }
            let memoryLimit = (limits["memory"] as? String).flatMap(KubeQuantity.value)
            lines.append(
                Line(
                    container: name, cpu: said(usage.cpu, "cpu", KubeMetricsFormat.cpu), memory: said(usage.memory, "memory", KubeMetricsFormat.memory),
                    nearLimit: memoryLimit.map { $0 > 0 && usage.memory >= $0 * 0.9 } ?? false))
        }
        // A container the spec doesn't name (an ephemeral one): its usage alone.
        for name in metrics.containers.keys.sorted() where !named.contains(name) {
            let usage = metrics.containers[name]!
            lines.append(Line(container: name, cpu: KubeMetricsFormat.cpu(usage.cpu), memory: KubeMetricsFormat.memory(usage.memory), nearLimit: false))
        }
        return lines
    }
}
