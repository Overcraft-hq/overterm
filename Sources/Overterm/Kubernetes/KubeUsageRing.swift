import Foundation

/// Where a sample is kept in `KubeUsageRing`.
enum KubeUsageKey: Hashable, Sendable {
    /// Every node's, added up.
    case cluster
    case node(String)
    /// A pod's containers, summed.
    case pod(namespace: String, name: String)
    case container(namespace: String, pod: String, container: String)
    /// A workload's pods, summed per poll.
    case workload(namespace: String, kind: String, name: String)
    /// A namespace's pods, summed per poll.
    case namespace(String)
    /// One part of a sum, summed per poll as its whole is: a workload's
    /// revision (`whole` the workload, `part` `rev:<hash>`), a namespace's
    /// workload (`whole` empty, `part` `<Kind>/<name>`).
    case part(namespace: String, whole: String, part: String)

    static func pod(_ id: KubeRowID) -> KubeUsageKey { .pod(namespace: id.namespace ?? "", name: id.name) }

    /// What its names take on the heap (a name up to 15 bytes is inline).
    var heapBytes: Int {
        func heap(_ text: String) -> Int { text.utf8.count <= 15 ? 0 : 48 + text.utf8.count }
        switch self {
        case .cluster: return 0
        case .node(let name), .namespace(let name): return heap(name)
        case .pod(let namespace, let name): return heap(namespace) + heap(name)
        case .container(let namespace, let pod, let container): return heap(namespace) + heap(pod) + heap(container)
        case .workload(let namespace, let kind, let name): return heap(namespace) + heap(kind) + heap(name)
        case .part(let namespace, let whole, let part): return heap(namespace) + heap(whole) + heap(part)
        }
    }

    /// A pod's own, a node's or the cluster's: what a list row is.
    var isListRow: Bool {
        switch self {
        case .cluster, .node, .pod: true
        case .container, .workload, .namespace, .part: false
        }
    }
}

/// One sample's usage, and when metrics-server took it.
struct KubeUsagePoint: Equatable, Sendable {
    var time: Date
    var usage: KubeUsage
}

/// A minute of samples, folded: the least, the mean and the most.
struct KubeUsageBucket: Equatable, Sendable {
    var start: Date
    var min: KubeUsage
    var avg: KubeUsage
    var max: KubeUsage
    var count: Int
}

/// Overterm's own ring of the samples taken while something is shown
/// (docs/design/kubernetes/metrics.md, 4.1) — metrics-server keeps no
/// history. In memory only, pure; each key has two tiers:
///
/// - **raw**: the samples by metrics-server's own `timestamp` (a sample
///   whose stamp didn't move is dropped, so polling faster adds nothing),
///   15 minutes, at most 60; a stretch longer than 2.5 × `interval` is
///   kept as a break, drawn as a gap — never a line, never a zero;
/// - **folded**: one-minute buckets of min, mean and max, 6 hours, at most
///   360.
///
/// Two populations, so the Pods list's 5,000 rows never push out the pod
/// being looked at: list-fed keys (a list's pods, the nodes, the cluster)
/// keep the raw tier only, `listPoints` of it, and are forgotten as soon as
/// their row isn't sampled; detail-fed keys (what a detail polls) keep both
/// tiers, at most `detailKeys`, the least recently fed dropped first, and
/// each is forgotten `keepDetail` (an hour, decision 1) after it was last
/// fed — coming back to a pod shows what was sampled before, the time away a
/// gap. A point is an `Int32` second and `Float32` values; the whole ring
/// stays under `byteCap` (6 MB), list rows given up first. The monitor
/// drops it on a context switch and a credential failure; nothing of it is
/// written anywhere.
struct KubeUsageRing: Sendable {
    enum Population: Sendable { case list, detail }

    static let rawSpan: Int32 = 15 * 60
    static let rawPoints = 60
    static let listPoints = 40
    static let bucketSeconds: Int32 = 60
    static let foldedSpan: Int32 = 6 * 3600
    static let foldedBuckets = 360
    static let detailKeys = 200
    static let keepDetail: TimeInterval = 3600
    static let defaultByteCap = 6 * 1_048_576

    /// How often metrics-server samples: a stretch past 2.5 × it is a break.
    var interval: TimeInterval
    var byteCap: Int

    init(interval: TimeInterval = 15, byteCap: Int = KubeUsageRing.defaultByteCap) {
        self.interval = interval
        self.byteCap = byteCap
    }

    /// A raw point; NaN values mark a break.
    struct Raw: Equatable, Sendable {
        var offset: Int32
        var cpu: Float32
        var memory: Float32
        var isBreak: Bool { cpu.isNaN }
    }

    /// A folded minute.
    struct Fold: Equatable, Sendable {
        var offset: Int32
        var count: UInt16
        var minCPU: Float32
        var minMemory: Float32
        var avgCPU: Float32
        var avgMemory: Float32
        var maxCPU: Float32
        var maxMemory: Float32
    }

    fileprivate struct Series: Sendable {
        var raw: [Raw] = []
        var folded: [Fold] = []
        /// The newest sample's second: a sample not after it is dropped.
        var last: Int32?
        /// When it was last polled.
        var fed: Date
        /// A sum's members' newest stamps (a workload's pods, the nodes).
        var members: [String: Int32] = [:]

        /// What it takes on the heap: its arrays' whole capacity (not only
        /// their points) with their headers, and a sum's members — their
        /// table and the names that don't fit in a String.
        var bytes: Int {
            var total = 0
            if raw.capacity > 0 { total += KubeUsageRing.bufferHeader + raw.capacity * MemoryLayout<Raw>.stride }
            if folded.capacity > 0 { total += KubeUsageRing.bufferHeader + folded.capacity * MemoryLayout<Fold>.stride }
            if members.capacity > 0 {
                total += KubeUsageRing.bufferHeader + members.capacity * (MemoryLayout<String>.stride + MemoryLayout<Int32>.stride + 1)
                for name in members.keys { total += KubeUsageRing.heap(name) }
            }
            return total
        }
    }

    /// A heap buffer's header (its object header, count and capacity) and
    /// malloc's rounding, about.
    fileprivate static let bufferHeader = 48

    /// What a String takes on the heap: nothing up to 15 bytes (it is kept inline).
    fileprivate static func heap(_ text: String) -> Int {
        let count = text.utf8.count
        return count <= 15 ? 0 : bufferHeader + count
    }

    /// An array about to take `adding` more past its capacity: grown, but
    /// never past `limit` (what it holds at most, transiently) — the
    /// doubling an append does would leave a 361-bucket tier in 512 slots.
    fileprivate static func grow<T>(_ array: inout [T], adding: Int, limit: Int) {
        guard array.count + adding > array.capacity else { return }
        array.reserveCapacity(Swift.min(limit, Swift.max(array.count + adding, array.capacity * 2, 4)))
    }

    /// The seconds every offset counts from, on a minute.
    private var epoch: Int?
    private var list: [KubeUsageKey: Series] = [:]
    private var detail: [KubeUsageKey: Series] = [:]

    // MARK: Recording

    /// One key's sample, stamped `time` (metrics-server's). False: dropped,
    /// its stamp not after the last one's.
    @discardableResult
    mutating func record(_ key: KubeUsageKey, _ usage: KubeUsage, at time: Date, _ population: Population, now: Date) -> Bool {
        let t = offset(time)
        switch population {
        case .list:
            return Self.add(&list[key, default: Series(fed: now)], usage, at: t, fold: false, interval: interval, now: now)
        case .detail:
            if detail[key] == nil { makeRoomForDetail() }
            return Self.add(&detail[key, default: Series(fed: now)], usage, at: t, fold: true, interval: interval, now: now)
        }
    }

    /// A sum across members (a workload's pods, a namespace's, the nodes),
    /// keyed by the poll: recorded only when a member's stamp moved (or a
    /// member came), stamped with the newest stamp in it; a member missing
    /// from the poll ends its part — the sum is what was sampled, never a
    /// guess for what wasn't.
    @discardableResult
    mutating func recordSum(_ key: KubeUsageKey, _ members: [String: (time: Date, usage: KubeUsage)], _ population: Population, now: Date) -> Bool {
        guard !members.isEmpty else { return false }
        var stamps: [String: Int32] = [:]
        for (id, member) in members { stamps[id] = offset(member.time) }
        if population == .detail, detail[key] == nil { makeRoomForDetail() }
        let total = members.values.map(\.usage).reduce(.zero, +)
        let interval = interval
        func sum(_ series: inout Series) -> Bool {
            let previous = series.members
            series.members = stamps
            series.fed = now
            let moved = stamps.contains { id, stamp in previous[id].map { stamp > $0 } ?? true }
            guard moved, var newest = stamps.values.max() else { return false }
            // A member joining with an older stamp still moves the sum on.
            if let last = series.last, newest <= last { newest = last + 1 }
            return Self.add(&series, total, at: newest, fold: population == .detail, interval: interval, now: now)
        }
        switch population {
        case .list: return sum(&list[key, default: Series(fed: now)])
        case .detail: return sum(&detail[key, default: Series(fed: now)])
        }
    }

    private static func add(_ series: inout Series, _ usage: KubeUsage, at t: Int32, fold: Bool, interval: TimeInterval, now: Date) -> Bool {
        series.fed = now
        if let last = series.last, t <= last { return false }
        let limit = fold ? rawPoints : listPoints
        let gap = series.last.map { Double(t - $0) > interval * 2.5 } ?? false
        grow(&series.raw, adding: gap ? 2 : 1, limit: limit + 2)
        if gap, let last = series.last {
            series.raw.append(Raw(offset: last, cpu: .nan, memory: .nan))
        }
        let cpu = Float32(usage.cpu)
        let memory = Float32(usage.memory)
        series.raw.append(Raw(offset: t, cpu: cpu, memory: memory))
        series.last = t
        let oldest = t - rawSpan
        var drop = 0
        while drop < series.raw.count - 1,
            series.raw.count - drop > limit || series.raw[drop].offset < oldest || series.raw[drop].isBreak
        {
            drop += 1
        }
        if drop > 0 { series.raw.removeFirst(drop) }
        guard fold else { return true }
        let start = t - mod(t, bucketSeconds)
        if let index = series.folded.indices.last, series.folded[index].offset == start {
            var bucket = series.folded[index]
            let count = Float32(bucket.count) + 1
            bucket.avgCPU += (cpu - bucket.avgCPU) / count
            bucket.avgMemory += (memory - bucket.avgMemory) / count
            bucket.minCPU = min(bucket.minCPU, cpu)
            bucket.minMemory = min(bucket.minMemory, memory)
            bucket.maxCPU = max(bucket.maxCPU, cpu)
            bucket.maxMemory = max(bucket.maxMemory, memory)
            bucket.count = bucket.count == .max ? .max : bucket.count + 1
            series.folded[index] = bucket
        } else {
            grow(&series.folded, adding: 1, limit: foldedBuckets + 1)
            series.folded.append(
                Fold(offset: start, count: 1, minCPU: cpu, minMemory: memory, avgCPU: cpu, avgMemory: memory, maxCPU: cpu, maxMemory: memory))
        }
        let foldedOldest = t - foldedSpan
        var dropFolded = 0
        while dropFolded < series.folded.count - 1,
            series.folded.count - dropFolded > foldedBuckets || series.folded[dropFolded].offset < foldedOldest
        {
            dropFolded += 1
        }
        if dropFolded > 0 { series.folded.removeFirst(dropFolded) }
        return true
    }

    private static func mod(_ value: Int32, _ divisor: Int32) -> Int32 { ((value % divisor) + divisor) % divisor }

    private mutating func offset(_ date: Date) -> Int32 {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        if epoch == nil { epoch = seconds - ((seconds % 60) + 60) % 60 }
        return Int32(clamping: seconds - epoch!)
    }

    private func date(_ offset: Int32) -> Date { Date(timeIntervalSince1970: TimeInterval((epoch ?? 0) + Int(offset))) }

    /// A new detail key at the bound: the least recently fed one goes.
    private mutating func makeRoomForDetail() {
        guard detail.count >= Self.detailKeys, let oldest = detail.min(by: { $0.value.fed < $1.value.fed })?.key else { return }
        detail[oldest] = nil
    }

    // MARK: Forgetting

    /// The list's rows of one kind (`belongs`) sampled now: every other
    /// such list key is forgotten — a row no longer sampled has no line.
    mutating func keepListed(_ keys: Set<KubeUsageKey>, of belongs: (KubeUsageKey) -> Bool) {
        guard list.contains(where: { belongs($0.key) && !keys.contains($0.key) }) else { return }
        list = list.filter { !belongs($0.key) || keys.contains($0.key) }
    }

    /// A list no longer read: its keys go.
    mutating func forgetListed(_ belongs: (KubeUsageKey) -> Bool) {
        guard list.keys.contains(where: belongs) else { return }
        list = list.filter { !belongs($0.key) }
    }

    /// Detail keys not fed for `keepDetail`: forgotten.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keepDetail)
        guard detail.values.contains(where: { $0.fed < cutoff }) else { return }
        detail = detail.filter { $0.value.fed >= cutoff }
    }

    /// Under `byteCap`: list rows given up first — the shortest first, so
    /// a row dropped at the last poll and back with one point goes again
    /// rather than one holding its history; the cluster's last — then the
    /// least recently fed detail keys. (A table's slots stay until it is
    /// rebuilt, so what a key gives back is its series and its names.)
    mutating func enforceCap() {
        var total = bytes
        guard total > byteCap else { return }
        let rows = list.map { (key: $0.key, rank: ($0.key == .cluster ? 1 : 0, $0.value.raw.count)) }.sorted { $0.rank < $1.rank }.map(\.key)
        for key in rows where total > byteCap {
            total -= (list[key]?.bytes ?? 0) + key.heapBytes
            list[key] = nil
        }
        while total > byteCap, let oldest = detail.min(by: { $0.value.fed < $1.value.fed }) {
            total -= oldest.value.bytes + oldest.key.heapBytes
            detail[oldest.key] = nil
        }
    }

    mutating func removeAll() {
        list = [:]
        detail = [:]
        epoch = nil
    }

    // MARK: Reading

    private func series(_ key: KubeUsageKey, now: Date) -> Series? {
        if let kept = detail[key], kept.fed >= now.addingTimeInterval(-Self.keepDetail) { return kept }
        return list[key]
    }

    /// The raw tier's segments, oldest first: a break between two.
    func segments(_ key: KubeUsageKey, now: Date = Date()) -> [[KubeUsagePoint]] {
        guard let series = series(key, now: now) else { return [] }
        var segments: [[KubeUsagePoint]] = []
        var current: [KubeUsagePoint] = []
        for point in series.raw {
            if point.isBreak {
                if !current.isEmpty { segments.append(current) }
                current = []
            } else {
                current.append(KubeUsagePoint(time: date(point.offset), usage: KubeUsage(cpu: Double(point.cpu), memory: Double(point.memory))))
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// The raw tier's points, breaks left out (a sparkline's).
    func points(_ key: KubeUsageKey, now: Date = Date()) -> [KubeUsagePoint] { segments(key, now: now).flatMap { $0 } }

    /// The folded tier: a detail key's minutes, oldest first.
    func folded(_ key: KubeUsageKey, now: Date = Date()) -> [KubeUsageBucket] {
        guard let series = detail[key], series.fed >= now.addingTimeInterval(-Self.keepDetail) else { return [] }
        return series.folded.map { fold in
            KubeUsageBucket(
                start: date(fold.offset), min: KubeUsage(cpu: Double(fold.minCPU), memory: Double(fold.minMemory)),
                avg: KubeUsage(cpu: Double(fold.avgCPU), memory: Double(fold.avgMemory)),
                max: KubeUsage(cpu: Double(fold.maxCPU), memory: Double(fold.maxMemory)), count: Int(fold.count))
        }
    }

    /// Whether `key` is kept for `population`.
    func holds(_ key: KubeUsageKey, _ population: Population) -> Bool {
        switch population {
        case .list: list[key] != nil
        case .detail: detail[key] != nil
        }
    }

    var listKeys: Int { list.count }
    var detailKeyCount: Int { detail.count }
    var isEmpty: Bool { list.isEmpty && detail.isEmpty }

    /// What the ring takes, as near as can be said — the bound `byteCap`
    /// holds to: each key's series (`Series.bytes`), the two tables' slots
    /// (their capacity, a key and a series each) and the keys' own names.
    var bytes: Int {
        func of(_ table: [KubeUsageKey: Series]) -> Int {
            var total = table.capacity > 0 ? Self.bufferHeader + table.capacity * (MemoryLayout<KubeUsageKey>.stride + MemoryLayout<Series>.stride + 1) : 0
            for (key, series) in table { total += key.heapBytes + series.bytes }
            return total
        }
        return of(list) + of(detail)
    }

    /// What a sparkline's caption says of `points`: over how long.
    static func span(_ points: [KubeUsagePoint]) -> String? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        return "the last \(KubeMetricsFormat.age(last.time.timeIntervalSince(first.time))), sampled while shown"
    }
}

/// What a target's sample adds to the ring.
extension KubeUsageRing {
    /// `sample`, read for `target`: as the list's rows when a list reads it
    /// (`asList`), as a detail's when one does (`asDetail`), and into each
    /// of `sums` (a workload's, a namespace's). Then the hour's and the
    /// cap's bounds.
    mutating func record(
        _ sample: KubeMetricsSample, for target: KubeMetricsTarget, asList: Bool, asDetail: Bool, sums: [KubeUsageKey], parts: [KubeUsageParts] = [],
        owners: [String: String] = [:], now: Date
    ) {
        switch target {
        case .pods, .podsOn:
            if asList {
                var seen = Set<KubeUsageKey>()
                for (id, pod) in sample.pods {
                    let key = KubeUsageKey.pod(id)
                    seen.insert(key)
                    record(key, pod.total, at: pod.timestamp ?? sample.read, .list, now: now)
                }
                keepListed(seen) { if case .pod = $0 { true } else { false } }
            }
            if !sums.isEmpty {
                let members = Dictionary(
                    sample.pods.map { ($0.key.description, (time: $0.value.timestamp ?? sample.read, usage: $0.value.total)) }, uniquingKeysWith: { $1 })
                for key in sums { recordSum(key, members, .detail, now: now) }
            }
            for part in parts { record(part, of: sample, owners: owners, now: now) }
        case .nodes:
            guard asList else { break }
            var seen = Set<KubeUsageKey>()
            for (name, node) in sample.nodes {
                seen.insert(.node(name))
                record(.node(name), node.usage, at: node.timestamp ?? sample.read, .list, now: now)
            }
            keepListed(seen) { if case .node = $0 { true } else { false } }
            recordSum(.cluster, sample.nodes.mapValues { (time: $0.timestamp ?? sample.read, usage: $0.usage) }, .list, now: now)
        case .pod:
            guard asDetail else { break }
            for (id, pod) in sample.pods {
                let time = pod.timestamp ?? sample.read
                record(.pod(id), pod.total, at: time, .detail, now: now)
                for (name, usage) in pod.containers {
                    record(.container(namespace: id.namespace ?? "", pod: id.name, container: name), usage, at: time, .detail, now: now)
                }
            }
        case .node:
            guard asDetail else { break }
            for (name, node) in sample.nodes { record(.node(name), node.usage, at: node.timestamp ?? sample.read, .detail, now: now) }
        case .hpa, .replicas, .nodePods, .namespacePods:
            break
        }
        prune(now: now)
        enforceCap()
    }
}

/// How a pods target's samples are kept beside its sum (metrics.md 2.5,
/// 2.7, 2.8): what the charts break the sum into.
enum KubeUsageParts: Hashable, Sendable {
    /// Each pod its own detail key (`.pod`) — a workload's Per pod view and
    /// its top five, a node's top pods: at most `KubeUsageRing.podPartsAtMost`
    /// (past that, the sum alone), or only the pods named.
    case pods(only: [String]?)
    /// By revision (`KubePodMetrics.revision`: a Deployment's
    /// `pod-template-hash`, a StatefulSet's or DaemonSet's
    /// `controller-revision-hash`), as `.part(ns, whole, "rev:<hash>")`.
    case revisions(whole: String)
    /// By workload — the owner the namespace's Metadata rows say, else the
    /// pod's name read (`KubeWorkloadName`) — as `.part(ns, "", "<Kind>/<name>")`,
    /// the `workloadPartsAtMost` using the most CPU now.
    case workloads
}

extension KubeUsageRing {
    /// A workload's pods kept each on its own, at most.
    static let podPartsAtMost = 50
    /// A namespace's workloads kept each on its own, at most.
    static let workloadPartsAtMost = 30

    /// One part's samples: each a sum over its members, per poll, as the whole's.
    fileprivate mutating func record(_ parts: KubeUsageParts, of sample: KubeMetricsSample, owners: [String: String], now: Date) {
        func member(_ pod: KubePodMetrics) -> (time: Date, usage: KubeUsage) { (pod.timestamp ?? sample.read, pod.total) }
        switch parts {
        case .pods(let only):
            let pods = sample.pods.values.filter { only?.contains($0.id.name) ?? true }
            guard pods.count <= Self.podPartsAtMost else { return }
            for pod in pods { record(.pod(pod.id), pod.total, at: pod.timestamp ?? sample.read, .detail, now: now) }
        case .revisions(let whole):
            var groups: [String: [String: (time: Date, usage: KubeUsage)]] = [:]
            var namespace = ""
            for pod in sample.pods.values {
                guard let revision = pod.revision else { continue }
                namespace = pod.id.namespace ?? ""
                groups["rev:" + revision, default: [:]][pod.id.name] = member(pod)
            }
            for (part, members) in groups { recordSum(.part(namespace: namespace, whole: whole, part: part), members, .detail, now: now) }
        case .workloads:
            var groups: [String: [String: (time: Date, usage: KubeUsage)]] = [:]
            var namespace = ""
            for pod in sample.pods.values {
                namespace = pod.id.namespace ?? ""
                let owner = owners[pod.id.name] ?? KubeWorkloadName.of(pod: pod.id.name).id
                groups[owner, default: [:]][pod.id.name] = member(pod)
            }
            let kept = groups.sorted { a, b in
                let ca = a.value.values.reduce(0) { $0 + $1.usage.cpu }
                let cb = b.value.values.reduce(0) { $0 + $1.usage.cpu }
                return ca == cb ? a.key < b.key : ca > cb
            }.prefix(Self.workloadPartsAtMost)
            for (part, members) in kept { recordSum(.part(namespace: namespace, whole: "", part: part), members, .detail, now: now) }
            // Once the rows say the owners, what the names guessed before goes
            // (a DaemonSet's pods were `web`, now `DaemonSet/web`): one series each.
            for pod in sample.pods.values {
                guard let owner = owners[pod.id.name] else { continue }
                let guessed = KubeWorkloadName.of(pod: pod.id.name).id
                guard guessed != owner, groups[guessed] == nil else { continue }
                detail[.part(namespace: namespace, whole: "", part: guessed)] = nil
            }
        }
    }

    /// The parts of a sum kept now: a namespace's workloads, a workload's
    /// revisions — the names after `whole`'s.
    func parts(of whole: String, in namespace: String, now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-Self.keepDetail)
        return detail.compactMap { key, series in
            guard case .part(let ns, let w, let part) = key, ns == namespace, w == whole, series.fed >= cutoff else { return nil }
            return part
        }.sorted()
    }
}
