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

    /// A PodMetricsList.
    static func pods(_ data: Data) throws -> [KubePodMetrics] {
        try items(data).compactMap { item in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            guard let name = metadata["name"] as? String else { return nil }
            var containers: [String: KubeUsage] = [:]
            for container in item["containers"] as? [[String: Any]] ?? [] {
                guard let name = container["name"] as? String, let usage = KubeUsage(container["usage"]) else { continue }
                containers[name] = usage
            }
            return KubePodMetrics(
                id: KubeRowID(namespace: metadata["namespace"] as? String, name: name), timestamp: time(item["timestamp"]), window: item["window"] as? String,
                containers: containers)
        }
    }

    /// A NodeMetricsList.
    static func nodes(_ data: Data) throws -> [KubeNodeMetrics] {
        try items(data).compactMap { item in
            guard let name = (item["metadata"] as? [String: Any])?["name"] as? String, let usage = KubeUsage(item["usage"]) else { return nil }
            return KubeNodeMetrics(name: name, timestamp: time(item["timestamp"]), window: item["window"] as? String, usage: usage)
        }
    }

    /// A NodeList's `status.allocatable`, by node, and where the next page starts.
    static func allocatable(_ data: Data) throws -> (nodes: [String: KubeUsage], continueToken: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        var nodes: [String: KubeUsage] = [:]
        for item in object["items"] as? [[String: Any]] ?? [] {
            guard let name = (item["metadata"] as? [String: Any])?["name"] as? String,
                let usage = KubeUsage((item["status"] as? [String: Any])?["allocatable"])
            else { continue }
            nodes[name] = usage
        }
        let token = ((object["metadata"] as? [String: Any])?["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (nodes, token)
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
/// it (`auto`, the default), metrics-server only, or none — `none` skips
/// the check entirely: no column, nothing asked. Prometheus is stage 4's.
enum KubeMetricsSource: String, CaseIterable, Sendable {
    case auto, metricsServer, none

    var title: String {
        switch self {
        case .auto: "metrics-server, when served"
        case .metricsServer: "metrics-server"
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
/// selector), or the nodes — and then their allocatable too.
enum KubeMetricsTarget: Hashable, Sendable {
    case pods(KubeScope, labels: String?)
    case nodes

    /// Its metrics.k8s.io list.
    var path: String {
        switch self {
        case .pods(let scope, let labels):
            let base = "/apis/metrics.k8s.io/v1beta1" + (scope.namespace(for: .pods).map { "/namespaces/\(KubePath.segment($0))" } ?? "") + "/pods"
            return KubePath.query(base, [("labelSelector", labels)])
        case .nodes: return "/apis/metrics.k8s.io/v1beta1/nodes"
        }
    }
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
    /// When the answer came.
    var read: Date
    /// The oldest sample in it, as metrics-server stamped it.
    var oldest: Date?

    init(read: Date) { self.read = read }

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

    /// Every node's usage and allocatable added up: the cluster's.
    var clusterUsage: KubeUsage { nodes.values.map(\.usage).reduce(.zero, +) }
    var clusterAllocatable: KubeUsage? {
        allocatable.isEmpty ? nil : allocatable.values.reduce(.zero, +)
    }
}

/// How a target's reading stands.
struct KubeMetricsReading: Equatable, Sendable {
    var sample: KubeMetricsSample?
    /// Why the last read failed (a 403, metrics-server down), nil when it didn't.
    var problem: String?
    /// The samples taken while it was shown (analysis.md, 2.4 and 2.11):
    /// in memory only, gone with the reading.
    var history = KubeUsageHistory()
}

/// One sample's usage, and when it came.
struct KubeUsagePoint: Equatable, Sendable {
    var read: Date
    var usage: KubeUsage
}

/// Overterm's own ring of the samples taken while a target is polled — a
/// pod's total, a node's, the cluster's (every node's) — for the
/// sparklines: the last `capacity` (ten minutes at 15 s), in memory, a row
/// no longer sampled forgotten. metrics-server keeps no history; nothing
/// here outlives the reading (hidden, another context, a credential
/// failure: gone). Pure.
struct KubeUsageHistory: Equatable, Sendable {
    static let capacity = 40

    private(set) var cluster: [KubeUsagePoint] = []
    private(set) var rows: [KubeRowID: [KubeUsagePoint]] = [:]

    func points(_ id: KubeRowID) -> [KubeUsagePoint] { rows[id] ?? [] }

    mutating func record(_ sample: KubeMetricsSample) {
        var seen = Set<KubeRowID>()
        func add(_ id: KubeRowID, _ usage: KubeUsage) {
            seen.insert(id)
            Self.append(&rows[id, default: []], KubeUsagePoint(read: sample.read, usage: usage))
        }
        for (id, pod) in sample.pods { add(id, pod.total) }
        for (name, node) in sample.nodes { add(KubeRowID(namespace: nil, name: name), node.usage) }
        if !sample.nodes.isEmpty { Self.append(&cluster, KubeUsagePoint(read: sample.read, usage: sample.clusterUsage)) }
        if rows.count != seen.count { rows = rows.filter { seen.contains($0.key) } }
    }

    private static func append(_ points: inout [KubeUsagePoint], _ point: KubeUsagePoint) {
        points.append(point)
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    /// What a sparkline's caption says of `points`: over how long.
    static func span(_ points: [KubeUsagePoint]) -> String? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        return "the last \(KubeMetricsFormat.age(last.read.timeIntervalSince(first.read))), sampled while shown"
    }
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
        guard let sample = reading.sample else { return reading.problem.map { .dash("Usage couldn't be read: \($0)") } ?? .waiting }
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
            guard let pod = sample.pods[id] else { return .dash("metrics-server has no sample of this pod yet (it samples running pods).") }
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
