import Foundation

/// The Pods list's `%CPU/R %CPU/L %MEM/R %MEM/L` (metrics.md 2.1, stage
/// M5b; k9s's columns): each pod's usage, from the metrics-server sample
/// the list already reads, against its containers' requests and limits.
/// A list row carries no spec (a Table, `includeObject=None`), so the
/// denominators come from kube-state-metrics through Prometheus — one
/// instant query a namespace shown (`query`) — and nowhere else: without
/// Prometheus the cells are a dash and one sentence (decision 10), no pod
/// object is read for them. A share is never a guess: a pod some of whose
/// containers set no request (no limit) has no share of one, said so,
/// rather than a share of what the others set. Pure.
enum KubePodShares {
    /// The four columns, in k9s's order, part of the wide view (`w`).
    enum Column: String, CaseIterable, Sendable {
        case cpuRequest = "shares.cpu.request"
        case cpuLimit = "shares.cpu.limit"
        case memoryRequest = "shares.memory.request"
        case memoryLimit = "shares.memory.limit"

        var title: String {
            switch self {
            case .cpuRequest: "%CPU/R"
            case .cpuLimit: "%CPU/L"
            case .memoryRequest: "%MEM/R"
            case .memoryLimit: "%MEM/L"
            }
        }

        var measure: KubeUsageCell.Measure { self == .cpuRequest || self == .cpuLimit ? .cpu : .memory }
        var isLimit: Bool { self == .cpuLimit || self == .memoryLimit }

        var help: String {
            let what = measure == .cpu ? "CPU" : "memory (working set)"
            let side = isLimit ? "limit" : "request"
            return "The pod's \(what) used, from metrics-server, as a share of its containers' \(side)s, from kube-state-metrics through Prometheus — "
                + "read with the column and every 5 min, a namespace at a time." + (isLimit ? " Orange from 80%, red from 100%." : "")
        }
    }

    /// What kube-state-metrics says of one pod: how many containers it
    /// has, and their requests and limits added up — nil where not every
    /// one of them sets it (then the pod has no request, no limit, of it
    /// as a whole).
    struct Spec: Equatable, Sendable {
        var containers = 0
        var cpuRequest: Double?
        var cpuLimit: Double?
        var memoryRequest: Double?
        var memoryLimit: Double?
        /// Each container's own, where the pod's object was read (an agent's named pod).
        var byContainer: [String: Spec] = [:]

        func containers(named name: String) -> Spec? { byContainer[name] }

        func total(_ column: Column) -> Double? {
            switch column {
            case .cpuRequest: cpuRequest
            case .cpuLimit: cpuLimit
            case .memoryRequest: memoryRequest
            case .memoryLimit: memoryLimit
            }
        }
    }

    /// The label the one query's three arms are told apart by (`__` names are Prometheus's own).
    static let label = "overterm_s"
    /// Five series a pod at most: its containers' count, a request and a
    /// limit for CPU and for memory. The reader's cap is that many pods.
    static let seriesPerPod = 5
    static var maxPods: Int { KubePrometheusReader.maxSeries / seriesPerPod }

    /// The one instant query for `namespace`: kube-state-metrics' series
    /// taken `max by` what identifies them (two replicas scrape the same),
    /// its job pinned where the profile found two; each pod's containers
    /// counted, and its requests and limits summed only where as many
    /// containers set them as it has (`and on(…)`). A native sidecar (an
    /// init container restarting `Always`, KSM 2.10's `restart_policy`) is
    /// one of them: it runs, so metrics-server's sample counts it. KSM
    /// 1.x's own names where that is what it is — it can't tell a sidecar,
    /// which `cell`'s `sampled` check then catches.
    static func query(namespace: String, profile: KubePromProfile) -> String {
        let job = profile.ksmMatcher
        let scope = (job.isEmpty ? "" : job + ",") + KubePromQL.matchers([("namespace", namespace)])
        let old = profile.ksmMajor == 1
        let regular = "max by (namespace,pod,container)(kube_pod_container_info{\(scope)})"
        let sidecars = "max by (namespace,pod,container)(kube_pod_init_container_info{\(scope),restart_policy=\"Always\"})"
        let containers = "count by (namespace,pod)(\(old ? regular : "\(regular) or \(sidecars)"))"
        func side(_ which: String) -> String {
            if old {
                let cpu = "label_replace(max by (namespace,pod,container)(kube_pod_container_resource_\(which)_cpu_cores{\(scope)}),\"resource\",\"cpu\",\"\",\"\")"
                let memory =
                    "label_replace(max by (namespace,pod,container)(kube_pod_container_resource_\(which)_memory_bytes{\(scope)}),\"resource\",\"memory\",\"\",\"\")"
                return "(\(cpu) or \(memory))"
            }
            let selector = "{\(scope),resource=~\"cpu|memory\"}"
            return "(max by (namespace,pod,container,resource)(kube_pod_container_resource_\(which)\(selector)) or "
                + "(max by (namespace,pod,container,resource)(kube_pod_init_container_resource_\(which)\(selector)) and on(namespace,pod,container) \(sidecars)))"
        }
        func complete(_ which: String) -> String {
            let each = side(which)
            return "sum by (namespace,pod,resource)(\(each)) and on(namespace,pod,resource) "
                + "(count by (namespace,pod,resource)(\(each)) == on(namespace,pod) group_left() \(containers))"
        }
        func arm(_ expression: String, _ name: String) -> String { "label_replace(\(expression),\"\(label)\",\"\(name)\",\"\",\"\")" }
        return [arm(containers, "containers"), arm(complete("requests"), "request"), arm(complete("limits"), "limit")].joined(separator: " or ")
    }

    /// A pod's object decoded to its containers' requests and limits (and
    /// native sidecars'), everything else dropped: an agent's named pod.
    static func spec(ofPod object: [String: Any]) -> Spec {
        let containers = KubePodCharts.containers(of: object)
        func sum(_ value: (KubePodCharts.Container) -> Double?) -> Double? {
            let values = containers.map(value)
            guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
            return values.reduce(0) { $0 + ($1 ?? 0) }
        }
        var spec = Spec(
            containers: containers.count, cpuRequest: sum(\.cpuRequest), cpuLimit: sum(\.cpuLimit), memoryRequest: sum(\.memoryRequest),
            memoryLimit: sum(\.memoryLimit))
        for container in containers {
            spec.byContainer[container.name] = Spec(
                containers: 1, cpuRequest: container.cpuRequest, cpuLimit: container.cpuLimit, memoryRequest: container.memoryRequest,
                memoryLimit: container.memoryLimit)
        }
        return spec
    }

    /// The answer, by pod.
    static func read(_ series: [KubeSeries]) -> [KubeRowID: Spec] {
        var out: [KubeRowID: Spec] = [:]
        for item in series {
            guard let pod = item.labels["pod"], let value = item.points.last?.value else { continue }
            let id = KubeRowID(namespace: item.labels["namespace"], name: pod)
            var spec = out[id] ?? Spec()
            switch (item.labels[label], item.labels["resource"]) {
            case ("containers", _): spec.containers = Int(value)
            case ("request", "cpu"): spec.cpuRequest = value
            case ("request", "memory"): spec.memoryRequest = value
            case ("limit", "cpu"): spec.cpuLimit = value
            case ("limit", "memory"): spec.memoryLimit = value
            default: continue
            }
            out[id] = spec
        }
        return out
    }

    /// Whether an answer was cut at the reader's cap: then some of the
    /// namespace's pods are missing from it, and none of it is shown as whole.
    static func isCut(_ series: [KubeSeries]) -> Bool { series.count >= KubePrometheusReader.maxSeries }

    /// A pod's cell: its usage as a share of what its spec says, or a dash
    /// and why. `sampled`, how many containers metrics-server's sample
    /// has: more than the spec counts, and the usage covers a container
    /// the denominator doesn't (a native sidecar KSM before 2.10 can't
    /// tell) — no share then, rather than an overstated one.
    static func cell(_ column: Column, used: KubeUsage, spec: Spec, sampled: Int? = nil) -> KubeUsageCell {
        let what = column.measure == .cpu ? "CPU" : "memory"
        if let sampled, sampled > spec.containers {
            return .dash(
                "metrics-server samples \(sampled) containers of this pod, kube-state-metrics lists \(spec.containers) "
                    + "(a native sidecar, before kube-state-metrics 2.10): the usage and the requests don't cover the same containers.")
        }
        guard let total = spec.total(column) else {
            return .dash(
                column.isLimit
                    ? "Not every container of this pod has a \(what) limit: the pod has none as a whole."
                    : "Not every container of this pod requests \(what): there is no request to share against.")
        }
        guard total > 0 else { return .dash("Its containers' \(what) \(column.isLimit ? "limits" : "requests") add up to 0.") }
        let share = (column.measure == .cpu ? used.cpu : used.memory) / total * 100
        return .value("\(Int(share.rounded()))%", sort: share, percent: nil)
    }

    /// How warm a cell is drawn: a limit's share from 80% (near it), from 100% (at or over it).
    enum Level: Equatable, Sendable { case normal, near, over }

    static func level(_ column: Column, _ cell: KubeUsageCell) -> Level {
        guard column.isLimit, let share = cell.sort else { return .normal }
        if share >= 100 { return .over }
        return share >= 80 ? .near : .normal
    }
}

/// The Pods list's shares as kube-state-metrics answered them, a namespace
/// at a time, for the scope shown: what each pod's containers request and
/// are limited to, which namespaces answered, which failed and why.
struct KubeShareReading: Equatable, Sendable {
    var scope: KubeScope
    var pods: [KubeRowID: KubePodShares.Spec] = [:]
    /// The namespaces answered at least once.
    var answered: Set<String> = []

    /// The namespaces whose last answer is whole and current: answered, not cut, not failing since.
    var whole: Set<String> { answered.subtracting(cut).subtracting(problems.keys) }
    /// A namespace's last failure.
    var problems: [String: String] = [:]
    /// Namespaces whose answer the reader's cap cut.
    var cut: Set<String> = []
    /// Why none of it can be read here: agent mode, no kube-state-metrics,
    /// every namespace at once, the probe's failure.
    var unavailable: String?
    var read: Date?

    /// One namespace's answer, in place of what it said before.
    mutating func take(_ series: [KubeSeries], namespace: String) {
        pods = pods.filter { $0.key.namespace != namespace }
        let isCut = KubePodShares.isCut(series)
        if isCut { cut.insert(namespace) } else { cut.remove(namespace) }
        if !isCut { pods.merge(KubePodShares.read(series).filter { $0.key.namespace == namespace }) { $1 } }
        answered.insert(namespace)
        problems[namespace] = nil
    }

    /// A pod's cell, its usage given (and how many containers it was sampled from).
    func cell(_ column: KubePodShares.Column, _ id: KubeRowID, used: KubeUsage, sampled: Int? = nil) -> KubeUsageCell {
        if let unavailable { return .dash(unavailable) }
        let namespace = id.namespace ?? ""
        if cut.contains(namespace) { return .dash(KubeChartEmpty.sharesCut(namespace).sentence) }
        if let spec = pods[id] { return KubePodShares.cell(column, used: used, spec: spec, sampled: sampled) }
        if let problem = problems[namespace] { return .dash("Shares couldn't be read: \(problem)") }
        guard answered.contains(namespace) else { return .waiting }
        return .dash("kube-state-metrics doesn't list this pod yet: its shares come with its next scrape.")
    }
}
