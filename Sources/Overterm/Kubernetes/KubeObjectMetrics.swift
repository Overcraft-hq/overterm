import Foundation

// What the Metrics tabs of a workload, an HPA, a node and a namespace read
// besides metrics-server's samples (docs/design/kubernetes/metrics.md,
// 2.5–2.8, 4.1; stage M3b): the objects' own status, decoded and dropped —
// a workload's replicas, a node's pods' requests, a namespace's pods'
// owners — and the small in-memory history of those numbers kept while
// shown (`KubeStatusHistory`). Pure.

/// A workload's replicas as its status says them (W4): desired, available,
/// unavailable — a Job's active, succeeded and failed.
struct KubeReplicaStatus: Equatable, Sendable {
    struct Value: Equatable, Sendable {
        var id: String
        var name: String
        var value: Double
    }

    var kind: String
    var values: [Value]

    struct Malformed: Error, LocalizedError {
        var errorDescription: String? { "The workload's answer isn't an object." }
    }

    static func read(_ data: Data, kind: String) throws -> KubeReplicaStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Malformed() }
        return of(object, kind: kind)
    }

    static func of(_ object: [String: Any], kind: String) -> KubeReplicaStatus {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        func int(_ value: Any?) -> Double { Double(KubeRollout.int(value) ?? 0) }
        func value(_ id: String, _ name: String, _ number: Double) -> Value { Value(id: id, name: name, value: number) }
        switch kind {
        case "Job":
            return KubeReplicaStatus(
                kind: kind,
                values: [value("active", "active", int(status["active"])), value("succeeded", "succeeded", int(status["succeeded"])), value("failed", "failed", int(status["failed"]))])
        case "DaemonSet":
            return KubeReplicaStatus(
                kind: kind,
                values: [
                    value("desired", "desired", int(status["desiredNumberScheduled"])), value("available", "available", int(status["numberAvailable"])),
                    value("unavailable", "unavailable", int(status["numberUnavailable"])),
                ])
        default:
            let desired = KubeRollout.int(spec["replicas"]).map(Double.init) ?? 1
            let available = int(status["availableReplicas"])
            let unavailable = status["unavailableReplicas"] != nil ? int(status["unavailableReplicas"]) : max(0, desired - available)
            return KubeReplicaStatus(
                kind: kind, values: [value("desired", "desired", desired), value("available", "available", available), value("unavailable", "unavailable", unavailable)])
        }
    }

    var numbers: [String: Double] { Dictionary(values.map { ($0.id, $0.value) }, uniquingKeysWith: { $1 }) }
}

/// A node's pods as objects (metrics.md 2.8, review): one list
/// (`fieldSelector=spec.nodeName`, at most `limit`), each decoded to its
/// requests, limits and phase on a background queue — everything else
/// dropped as it is decoded, env values first; no object kept.
struct KubeNodePods: Equatable, Sendable {
    struct Pod: Equatable, Sendable {
        var id: KubeRowID
        var phase: String
        var cpuRequest: Double
        var memoryRequest: Double
        /// The GPUs its containers are given, by resource (decision 12).
        var gpus: [String: Double] = [:]

        /// Pending or Running: what the scheduler counts.
        var isActive: Bool { phase == "Pending" || phase == "Running" }
    }

    /// A node holds at most 110 pods on EKS's largest default.
    static let limit = 250

    var pods: [Pod]
    /// More than `limit`: the requested line is left out.
    var more: Bool

    var active: [Pod] { pods.filter(\.isActive) }
    /// What its active pods request, added up.
    var requested: KubeUsage { active.reduce(.zero) { $0 + KubeUsage(cpu: $1.cpuRequest, memory: $1.memoryRequest) } }

    /// The active pods requesting the most CPU (then memory): whose usage "Sample top pods" reads.
    func largest(_ count: Int) -> [Pod] {
        Array(active.sorted { ($0.cpuRequest, $0.memoryRequest, $1.id.description) > ($1.cpuRequest, $1.memoryRequest, $0.id.description) }.prefix(count))
    }

    struct Malformed: Error, LocalizedError {
        var errorDescription: String? { "The node's pods' answer isn't a pod list." }
    }

    static func read(_ data: Data) throws -> KubeNodePods {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object["items"] as? [[String: Any]] else {
            throw Malformed()
        }
        let pods = items.compactMap { item -> Pod? in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            guard let name = metadata["name"] as? String else { return nil }
            let containers = KubePodCharts.containers(of: item)
            return Pod(
                id: KubeRowID(namespace: metadata["namespace"] as? String, name: name),
                phase: (item["status"] as? [String: Any])?["phase"] as? String ?? "Unknown",
                cpuRequest: containers.reduce(0) { $0 + ($1.cpuRequest ?? 0) }, memoryRequest: containers.reduce(0) { $0 + ($1.memoryRequest ?? 0) },
                gpus: containers.reduce(into: [:]) { sum, container in sum.merge(container.gpus, uniquingKeysWith: +) })
        }
        let token = ((object["metadata"] as? [String: Any])?["continue"] as? String) ?? ""
        return KubeNodePods(pods: pods, more: !token.isEmpty)
    }
}

/// A namespace's pods as Metadata rows (metrics.md 2.7, review): each one's
/// workload — its controller owner, a ReplicaSet's Deployment by its
/// `pod-template-hash` — and its status, as the row says it.
struct KubeNamespacePods: Equatable, Sendable {
    struct Pod: Equatable, Sendable {
        var name: String
        /// `Deployment/web`; a pod of no owner's, `Pod/<name>`.
        var owner: String
        var phase: String
    }

    static let pageSize = 500
    static let pages = 10

    var pods: [Pod]
    /// Past `pages` pages: the rest not read.
    var more = false

    /// Each pod's workload, by its name.
    var owners: [String: String] { Dictionary(pods.map { ($0.name, $0.owner) }, uniquingKeysWith: { $1 }) }

    /// How many pods are in each phase.
    var phases: [String: Double] { pods.reduce(into: [:]) { $0[$1.phase, default: 0] += 1 } }

    struct Malformed: Error, LocalizedError {
        var errorDescription: String? { "The namespace's pods' answer isn't a Table." }
    }

    /// One page: its pods and where the next starts.
    static func read(_ data: Data) throws -> (pods: [Pod], continueToken: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["kind"] as? String == "Table" else { throw Malformed() }
        let columns = (object["columnDefinitions"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
        let nameIndex = columns.firstIndex { $0.lowercased() == "name" } ?? 0
        let statusIndex = columns.firstIndex { $0.lowercased() == "status" }
        let pods = (object["rows"] as? [[String: Any]] ?? []).compactMap { row -> Pod? in
            let cells = row["cells"] as? [Any] ?? []
            let metadata = (row["object"] as? [String: Any])?["metadata"] as? [String: Any] ?? [:]
            guard let name = (metadata["name"] as? String) ?? (nameIndex < cells.count ? cells[nameIndex] as? String : nil), !name.isEmpty else { return nil }
            let status = statusIndex.flatMap { $0 < cells.count ? cells[$0] as? String : nil } ?? ""
            return Pod(name: name, owner: owner(name: name, metadata: metadata), phase: KubePodPhase.of(status: status))
        }
        let token = ((object["metadata"] as? [String: Any])?["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (pods, token)
    }

    /// A pod's workload from its metadata: its controller (else first)
    /// owner — a ReplicaSet named `<deployment>-<pod-template-hash>` is
    /// that Deployment's —; a pod the rows say has no owner, `Pod/<name>`;
    /// a row without its metadata, its name read (`KubeWorkloadName`).
    static func owner(name: String, metadata: [String: Any]) -> String {
        guard !metadata.isEmpty else { return KubeWorkloadName.of(pod: name).id }
        let owners = metadata["ownerReferences"] as? [[String: Any]] ?? []
        guard let owner = owners.first(where: { ($0["controller"] as? Bool) == true }) ?? owners.first, let kind = owner["kind"] as? String,
            let ownerName = owner["name"] as? String
        else { return "Pod/" + name }
        let hash = (metadata["labels"] as? [String: Any])?["pod-template-hash"] as? String
        if kind == "ReplicaSet", let hash, ownerName.hasSuffix("-" + hash) { return "Deployment/" + ownerName.dropLast(hash.count + 1) }
        return kind + "/" + ownerName
    }
}

/// A pod's workload read off its name alone — only where no rows say its
/// owner (metrics.md 2.7, review): `-<hash>-<5>` a Deployment's, `-<n>` a
/// StatefulSet's, `-<5>` a DaemonSet's or a Job's (which one, the name
/// can't say). Pure.
enum KubeWorkloadName {
    struct Name: Equatable, Sendable {
        var kind: String?
        var name: String
        /// `Deployment/web`, or the bare name when the kind isn't known.
        var id: String { kind.map { "\($0)/\(name)" } ?? name }
    }

    /// Kubernetes' safe alphabet for generated names.
    private static let safe = Set("bcdfghjklmnpqrstvwxz2456789")

    static func of(pod: String) -> Name {
        let parts = pod.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func generated(_ part: String, _ lengths: ClosedRange<Int>) -> Bool { lengths.contains(part.count) && part.allSatisfy(safe.contains) }
        if parts.count >= 3, generated(parts[parts.count - 1], 5...5), generated(parts[parts.count - 2], 1...10) {
            return Name(kind: "Deployment", name: parts.dropLast(2).joined(separator: "-"))
        }
        if parts.count >= 2, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber) {
            return Name(kind: "StatefulSet", name: parts.dropLast().joined(separator: "-"))
        }
        if parts.count >= 2, generated(parts[parts.count - 1], 5...5) { return Name(kind: nil, name: parts.dropLast().joined(separator: "-")) }
        return Name(kind: "Pod", name: pod)
    }
}

/// A pod's phase as its row's Status says it (the rows carry no status):
/// Completed is Succeeded; Error, Evicted and the like Failed; waiting to
/// start Pending; the rest Running. Pure.
enum KubePodPhase {
    static let order = ["Running", "Pending", "Succeeded", "Failed", "Unknown"]

    static func of(status: String) -> String {
        switch status {
        case "Running", "Terminating", "CrashLoopBackOff", "NotReady": return "Running"
        case "Completed", "Succeeded": return "Succeeded"
        case "Error", "Failed", "Evicted", "OOMKilled", "DeadlineExceeded", "ContainerStatusUnknown": return "Failed"
        case "Unknown": return "Unknown"
        case "Pending", "ContainerCreating", "PodInitializing", "ErrImagePull", "ImagePullBackOff", "CreateContainerConfigError",
            "CreateContainerError", "InvalidImageName":
            return "Pending"
        default: return status.hasPrefix("Init:") ? "Pending" : "Running"
        }
    }
}

/// What a node object says of itself for its charts (K1, K2, K4, K5):
/// allocatable and capacity, how many pods it takes, and since when it is
/// under pressure or cordoned. Pure.
struct KubeNodeFacts: Equatable, Sendable {
    /// A pressure (or the cordon) and since when; nil, not known.
    struct Spell: Equatable, Sendable {
        var title: String
        var since: Date?
    }

    var allocatable: KubeUsage?
    var capacity: KubeUsage?
    var allocatablePods: Int?
    var spells: [Spell]

    static func of(_ node: [String: Any]) -> KubeNodeFacts {
        let status = node["status"] as? [String: Any] ?? [:]
        let spec = node["spec"] as? [String: Any] ?? [:]
        var spells: [Spell] = []
        for condition in status["conditions"] as? [[String: Any]] ?? [] {
            guard let type = condition["type"] as? String, ["MemoryPressure", "DiskPressure", "PIDPressure"].contains(type),
                condition["status"] as? String == "True"
            else { continue }
            spells.append(Spell(title: type, since: KubeMetricsReader.time(condition["lastTransitionTime"])))
        }
        if spec["unschedulable"] as? Bool == true {
            let taint = (spec["taints"] as? [[String: Any]] ?? []).first { $0["key"] as? String == "node.kubernetes.io/unschedulable" }
            spells.append(Spell(title: "Cordoned", since: KubeMetricsReader.time(taint?["timeAdded"])))
        }
        let pods = ((status["allocatable"] as? [String: Any])?["pods"] as? String).flatMap { Int($0) }
        return KubeNodeFacts(allocatable: KubeUsage(status["allocatable"]), capacity: KubeUsage(status["capacity"]), allocatablePods: pods, spells: spells)
    }
}

/// A namespace's ResourceQuota for its requests (N1, N2's reference): the
/// tightest `requests.cpu` and `requests.memory` hard, and what is used. Pure.
struct KubeQuota: Equatable, Sendable {
    var cpuHard: Double?
    var cpuUsed: Double?
    var memoryHard: Double?
    var memoryUsed: Double?

    var isEmpty: Bool { cpuHard == nil && memoryHard == nil }

    static func read(_ data: Data) -> KubeQuota {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return KubeQuota() }
        var quota = KubeQuota()
        for item in object["items"] as? [[String: Any]] ?? [] {
            let status = item["status"] as? [String: Any] ?? [:]
            let hard = (status["hard"] as? [String: Any]) ?? ((item["spec"] as? [String: Any])?["hard"] as? [String: Any]) ?? [:]
            let used = status["used"] as? [String: Any] ?? [:]
            func value(_ map: [String: Any], _ key: String) -> Double? { (map[key] as? String).flatMap(KubeQuantity.value) }
            if let cpu = value(hard, "requests.cpu") ?? value(hard, "cpu"), cpu < (quota.cpuHard ?? .infinity) {
                quota.cpuHard = cpu
                quota.cpuUsed = value(used, "requests.cpu") ?? value(used, "cpu")
            }
            if let memory = value(hard, "requests.memory") ?? value(hard, "memory"), memory < (quota.memoryHard ?? .infinity) {
                quota.memoryHard = memory
                quota.memoryUsed = value(used, "requests.memory") ?? value(used, "memory")
            }
        }
        return quota
    }
}

extension KubeHPAStatus.Metric {
    /// Its current and target as numbers in one unit: `45%` a ratio, a
    /// CPU quantity cores, memory bytes, anything else a count.
    var numbers: (unit: KubeChartUnit, current: Double?, target: Double?) {
        let percent = (target ?? current ?? "").hasSuffix("%")
        let unit: KubeChartUnit = percent ? .ratio : name == "cpu" ? .cores : name == "memory" ? .bytes : .count
        func parse(_ text: String?) -> Double? {
            guard let text else { return nil }
            if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
            return KubeQuantity.value(text)
        }
        return (unit, parse(current), parse(target))
    }
}

extension KubeHPAStatus {
    /// What the history keeps of it: the replicas and each metric's current and target.
    var numbers: [String: Double] {
        var out: [String: Double] = ["current": Double(current), "desired": Double(desired), "min": Double(min), "max": Double(max)]
        if scalingLimited { out["limited"] = 1 }
        for metric in metrics {
            let numbers = metric.numbers
            if let current = numbers.current { out["metric.\(metric.name).current"] = current }
            if let target = numbers.target { out["metric.\(metric.name).target"] = target }
        }
        return out
    }
}

/// Where `KubeStatusHistory` keeps an object's numbers.
enum KubeStatusKey: Hashable, Sendable {
    case hpa(namespace: String, name: String)
    case replicas(namespace: String, kind: String, name: String)
    /// A node's active pods, and what they request.
    case nodePods(String)
    /// A namespace's pods by phase.
    case phases(String)
}

/// One reading of an object's numbers; a break (no values) ends a run.
struct KubeStatusPoint: Equatable, Sendable {
    var time: Date
    var values: [String: Double]
    var isBreak: Bool { values.isEmpty }
}

/// The numbers objects' status gave while their tab showed — an HPA's
/// replicas and metrics, a workload's replicas, a node's pods, a
/// namespace's phases (metrics.md 2.5–2.8): in memory, a point only when
/// they change (they hold between, drawn stepped), a break where they
/// weren't read for longer than 2.5 reads, 6 hours, each key forgotten an
/// hour after it was last fed, at most `keys` (the least recently fed go).
/// Dropped with the ring. Pure.
struct KubeStatusHistory: Sendable {
    static let span: TimeInterval = 6 * 3600
    static let points = 720
    static let keys = 50
    static let keep: TimeInterval = 3600

    struct Series: Sendable {
        var points: [KubeStatusPoint] = []
        /// When the numbers were last read (they held until then).
        var seen: Date
        var fed: Date
    }

    private var series: [KubeStatusKey: Series] = [:]

    /// `values` read at `time`; `expected`, how often they are read.
    mutating func record(_ key: KubeStatusKey, _ values: [String: Double], at time: Date, expected: TimeInterval, now: Date) {
        guard !values.isEmpty else { return }
        if series[key] == nil, series.count >= Self.keys, let oldest = series.min(by: { $0.value.fed < $1.value.fed })?.key { series[oldest] = nil }
        var kept = series[key] ?? Series(seen: time, fed: now)
        defer { series[key] = kept }
        kept.fed = now
        if let last = kept.points.last {
            guard time > kept.seen || kept.points.isEmpty else { return }
            if time.timeIntervalSince(kept.seen) > expected * 2.5 {
                kept.points.append(KubeStatusPoint(time: kept.seen, values: [:]))
                kept.points.append(KubeStatusPoint(time: time, values: values))
            } else if last.values != values {
                kept.points.append(KubeStatusPoint(time: time, values: values))
            }
        } else {
            kept.points.append(KubeStatusPoint(time: time, values: values))
        }
        kept.seen = time
        let oldest = time.addingTimeInterval(-Self.span)
        var drop = 0
        // The point a run starts from stays while it still holds at the window's start.
        while drop < kept.points.count - 1, kept.points.count - drop > Self.points || kept.points[drop + 1].time < oldest || kept.points[drop].isBreak {
            drop += 1
        }
        if drop > 0 { kept.points.removeFirst(drop) }
    }

    /// A key's points, oldest first, and when they were last read; nil past its hour.
    func of(_ key: KubeStatusKey, now: Date = Date()) -> (points: [KubeStatusPoint], seen: Date)? {
        guard let kept = series[key], kept.fed >= now.addingTimeInterval(-Self.keep) else { return nil }
        return (kept.points, kept.seen)
    }

    /// One number of a key as chart points: stepped — each value held to
    /// the next reading, the last to when it was last read — broken where
    /// it wasn't read; nil values left out.
    func points(_ key: KubeStatusKey, _ name: String, from start: Date, now: Date = Date()) -> (points: [KubeSeriesPoint], breaks: Set<Date>) {
        guard let kept = of(key, now: now) else { return ([], []) }
        var points: [KubeSeriesPoint] = []
        var breaks = Set<Date>()
        var broken = false
        for point in kept.points {
            if point.isBreak {
                if let last = points.last { points.append(KubeSeriesPoint(time: point.time, value: last.value)) }
                broken = true
                continue
            }
            guard let value = point.values[name] else { continue }
            if broken, !points.isEmpty { breaks.insert(point.time) }
            broken = false
            points.append(KubeSeriesPoint(time: point.time, value: value))
        }
        if let last = points.last, kept.seen > last.time { points.append(KubeSeriesPoint(time: kept.seen, value: last.value)) }
        // Held from before the window: from its start.
        if let index = points.lastIndex(where: { $0.time < start }) {
            let held = points[index].value
            points.removeFirst(index + 1)
            if points.first.map({ $0.time > start }) ?? false { points.insert(KubeSeriesPoint(time: start, value: held), at: 0) }
        }
        return (points, breaks)
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keep)
        series = series.filter { $0.value.fed >= cutoff }
    }

    mutating func removeAll() { series = [:] }

    var isEmpty: Bool { series.isEmpty }
    var count: Int { series.count }
}
