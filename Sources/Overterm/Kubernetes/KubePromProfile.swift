import Foundation

/// What a context's Prometheus holds, asked once (metrics.md, 4.4): which
/// metrics exist and how many series each has, whether cAdvisor is scraped
/// twice (kubelet's `/metrics/cadvisor` and `/metrics/resource` both carry
/// its counters) and kube-state-metrics by two jobs — then pinned —, which
/// label names a node on cAdvisor's series, the cAdvisor job's own scrape
/// interval, and how far back it keeps data. Kept in memory with the
/// context, never on disk; asked again after an hour while charts show,
/// on a 404 or 422, or when the Service changes.
///
/// Four instant queries, one after another, each `timeout=20s`
/// (`probe`): the third needs the second's cAdvisor job, the fourth only
/// where Prometheus scrapes itself. A first query that Prometheus refuses
/// leaves the profile unknown — the charts read as they did before it
/// (raw cAdvisor, a minute's scrape, nothing pinned) — and one that says
/// it is an agent marks the server agent-only: never asked within the hour.
/// Pure but for `probe`, which asks through whatever it is given.
struct KubePromProfile: Equatable, Sendable {
    /// What names a node on cAdvisor's series: kube-prometheus-stack's
    /// kubelet ServiceMonitor relabels `node`; the prometheus chart's
    /// `kubernetes-nodes-cadvisor` job sets `instance` to the node's name.
    enum NodeLabel: String, Equatable, Sendable {
        case node, instance
    }

    /// Each metric asked about, by its series count; nil, unknown (the probe
    /// couldn't say): then every raw metric is assumed there, no rule is.
    var metrics: [String: Int]?
    /// `metrics_path` pinned on cAdvisor's series (more than one seen).
    var cadvisorPath: String?
    /// The cAdvisor job, as the duplicates said it; `cadvisorJobPinned`
    /// when more than one job carries its series.
    var cadvisorJob: String?
    var cadvisorJobPinned = false
    /// kube-state-metrics' job, pinned when more than one answers.
    var ksmJob: String?
    var nodeLabel: NodeLabel?
    /// The cAdvisor job's scrape interval (15, 30 or 60 s); nil, assumed.
    var scrape: TimeInterval?
    /// The oldest sample Prometheus keeps; nil where it doesn't scrape
    /// itself (Thanos, VictoriaMetrics) — then unknown.
    var retention: Date?
    /// The server only forwards metrics (agent mode): nothing is asked.
    var agentOnly = false
    /// Why the probe couldn't read what exists (its first query refused).
    var problem: String?
    /// When it was asked.
    var probed: Date
    /// A namespace's cAdvisor CPU series, counted when its tab first asks
    /// without recording rules (metrics.md 4.4): raw across it only below
    /// 2,000 (`KubeQueryCost`). Kept with the profile, asked again with it.
    var namespaceSeries: [String: Int] = [:]
    /// The namespaces whose count failed in this reading: raw across them
    /// refused, said so. Never kept with the profile — counted again at
    /// the next refresh.
    var uncounted: Set<String> = []

    /// Nothing known: the charts as before the probe.
    static let unknown = KubePromProfile(probed: .distantPast)

    /// How long a profile holds while charts show.
    static let lifetime: TimeInterval = 3600

    func isStale(at now: Date) -> Bool { now.timeIntervalSince(probed) >= Self.lifetime }

    var known: Bool { metrics != nil }

    /// Its series count, where the probe counted it.
    func count(_ metric: String) -> Int? { metrics?[metric] }

    func has(_ metric: String) -> Bool { (metrics?[metric] ?? 0) > 0 }

    /// A raw metric: there, or nothing known (then assumed).
    func mayHave(_ metric: String) -> Bool { metrics == nil || has(metric) }

    var scrapeInterval: TimeInterval { scrape ?? KubeRateWindow.assumedScrape }

    // MARK: What it holds, derived

    static let cpuMetric = "container_cpu_usage_seconds_total"
    static let memoryMetric = "container_memory_working_set_bytes"
    static let requestsMetric = "kube_pod_container_resource_requests"
    static let requestsCPUCores = "kube_pod_container_resource_requests_cpu_cores"
    static let containerCPURate5m = "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m"
    static let containerCPUIrate = "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate"
    static let containerMemoryRule = "node_namespace_pod_container:container_memory_working_set_bytes"
    /// The mixin's pods by workload: `workload`, `workload_type` (lower case).
    static let workloadRule = "namespace_workload_pod:kube_pod_owner:relabel"
    static let activeRequestsRule = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests"
    static let nodeCPURule = "instance:node_cpu_utilisation:rate5m"
    static let nodeMemoryRule = "instance:node_memory_utilisation:ratio"
    static let nodeCPUCountRule = "instance:node_num_cpu:sum"

    /// kube-state-metrics' major version: 2 with `…_requests{resource}`,
    /// 1 with only `…_requests_cpu_cores` (its HPA label is then `hpa`);
    /// nil, not scraped (or unknown).
    var ksmMajor: Int? {
        if has(Self.requestsMetric) { return 2 }
        if has(Self.requestsCPUCores) { return 1 }
        return nil
    }

    /// Known and no kube-state-metrics: no requests or limits over time.
    var ksmMissing: Bool { known && ksmMajor == nil }

    /// The mixin's per-container CPU rule: `sum_rate5m`, older mixins' `sum_irate`.
    var containerCPURule: String? {
        if has(Self.containerCPURate5m) { return Self.containerCPURate5m }
        if has(Self.containerCPUIrate) { return Self.containerCPUIrate }
        return nil
    }

    var hasContainerRules: Bool { containerCPURule != nil && has(Self.containerMemoryRule) }
    var hasActiveRules: Bool { has(Self.activeRequestsRule) }
    var hasNodeRules: Bool { has(Self.nodeCPURule) && has(Self.nodeMemoryRule) && has(Self.nodeCPUCountRule) && has("node_memory_MemTotal_bytes") }
    var hasNodeExporter: Bool { has("node_cpu_seconds_total") && has("node_memory_MemAvailable_bytes") && has("node_memory_MemTotal_bytes") }
    /// node-exporter's instances map to nodes (`node_uname_info`'s nodename).
    var nodeExporterMapped: Bool { has("node_uname_info") }
    var hasThrottling: Bool { mayHave("container_cpu_cfs_throttled_periods_total") && mayHave("container_cpu_cfs_periods_total") }

    // MARK: Pins

    /// cAdvisor's containers, pinned to one path and job where two scrape them.
    var cadvisorMatchers: String {
        var matchers = KubePromQL.containers
        if let cadvisorPath { matchers += ",metrics_path=\"\(KubePromQL.literal(cadvisorPath))\"" }
        if cadvisorJobPinned, let cadvisorJob { matchers += ",job=\"\(KubePromQL.literal(cadvisorJob))\"" }
        return matchers
    }

    /// kube-state-metrics' job pinned where two answer; empty, none.
    var ksmMatcher: String { ksmJob.map { "job=\"\(KubePromQL.literal($0))\"" } ?? "" }

    // MARK: The four queries

    /// What query 1 asks about: every metric a chart reads, the rules
    /// that stand in for them, and Prometheus' own oldest sample.
    static let names = [
        cpuMetric, memoryMetric, "container_memory_rss", "container_cpu_cfs_throttled_periods_total", "container_cpu_cfs_periods_total", "container_fs_usage_bytes",
        "container_network_receive_bytes_total", "container_oom_events_total", "kube_pod_status_phase", requestsMetric, requestsCPUCores,
        "kube_pod_container_status_last_terminated_reason", "kube_pod_owner", "kube_replicaset_owner", "kube_node_status_allocatable",
        "kube_horizontalpodautoscaler_status_current_replicas", "kube_hpa_status_current_replicas", "kube_horizontalpodautoscaler_status_target_metric",
        "kube_resourcequota", "node_cpu_seconds_total", "node_memory_MemAvailable_bytes", "node_memory_MemTotal_bytes", "node_uname_info",
        KubePromQL.nodeFilesystemMetric, KubePromQL.nodeNetworkMetric,
        "kubelet_volume_stats_used_bytes", "kubelet_volume_stats_inodes_used", containerCPURate5m, containerCPUIrate, containerMemoryRule,
        workloadRule, activeRequestsRule, nodeCPURule, nodeMemoryRule, nodeCPUCountRule,
        "prometheus_tsdb_lowest_timestamp_seconds",
    ]

    /// 1. What exists, and how many series each has — one instant read
    /// touching each of these series once (about 50k on a 2–5k-pod
    /// cluster), which is why the probe runs at most once an hour.
    static var existsQuery: String {
        "count by (__name__) ({__name__=~\"" + KubePromQL.literal(names.map(KubePromQL.regexLiteral).joined(separator: "|")) + "\"})"
    }

    /// 2. Duplicates: cAdvisor's series by job and path, kube-state-metrics'
    /// jobs, and whether cAdvisor's series carry `node` — one union, each
    /// arm tagged `overterm_s` (a label of Overterm's: `__` names are
    /// Prometheus' own, and front ends may drop them).
    static let duplicatesQuery =
        #"label_replace(count by (job, metrics_path) (container_cpu_usage_seconds_total{container!=""}),"overterm_s","cadvisor","","")"#
        + #" or label_replace(count by (job) (kube_node_info),"overterm_s","ksm","","")"#
        + #" or label_replace(count(container_cpu_usage_seconds_total{container!="",node!=""}),"overterm_s","node","","")"#

    /// 3. The cAdvisor job's own scrape interval — every target's `up`
    /// would give the slowest job in the server, often a 2-minute probe.
    static func scrapeQuery(job: String) -> String {
        "600 / max(count_over_time(up{job=\"\(KubePromQL.literal(job))\"}[10m]))"
    }

    /// 4. How far back it keeps data.
    static let retentionQuery = "min(prometheus_tsdb_lowest_timestamp_seconds)"

    // MARK: Reading the answers

    /// Query 1's answer: each `__name__` and its count.
    static func metrics(_ series: [KubeSeries]) -> [String: Int] {
        var out: [String: Int] = [:]
        for item in series {
            guard let name = item.labels["__name__"], let value = item.points.last?.value, value.isFinite else { continue }
            out[name] = Int(value.rounded())
        }
        return out
    }

    /// Query 2's answer, into the pins and the node label.
    mutating func read(duplicates series: [KubeSeries]) {
        let cadvisor = series.filter { $0.labels["overterm_s"] == "cadvisor" }
        let paths = Set(cadvisor.compactMap { $0.labels["metrics_path"] }.filter { !$0.isEmpty })
        // The prometheus chart sets no metrics_path: then nothing is pinned by it.
        cadvisorPath = paths.count > 1 && paths.contains("/metrics/cadvisor") ? "/metrics/cadvisor" : nil
        let jobs = Set(cadvisor.compactMap { $0.labels["job"] }).sorted()
        if jobs.count > 1 {
            let byPath = cadvisor.first { $0.labels["metrics_path"] == "/metrics/cadvisor" }?.labels["job"]
            cadvisorJob = byPath ?? jobs.first
            cadvisorJobPinned = true
        } else {
            cadvisorJob = jobs.first
            cadvisorJobPinned = false
        }
        let ksm = Set(series.filter { $0.labels["overterm_s"] == "ksm" }.compactMap { $0.labels["job"] }).sorted()
        ksmJob = ksm.count > 1 ? ksm.first : nil
        let node = series.contains { $0.labels["overterm_s"] == "node" && ($0.points.last?.value ?? 0) > 0 }
        nodeLabel = cadvisor.isEmpty ? nil : (node ? .node : .instance)
    }

    /// Query 3's answer, `600 / samples in 10 min`, rounded to 15, 30 or 60 s.
    static func scrape(_ seconds: Double?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds <= 22.5 { return 15 }
        if seconds <= 45 { return 30 }
        return 60
    }

    /// Query 4's answer: seconds since 1970; nonsense, unknown.
    static func retention(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// What exists said as the charts' sentences: what is missing.
    var missing: [KubeChartEmpty] {
        guard known else { return [] }
        var out: [KubeChartEmpty] = []
        if ksmMissing { out.append(.ksmMissing) } else if ksmMajor == 1 { out.append(.ksmOld) }
        if !hasThrottling { out.append(.noThrottling) }
        return out
    }

    // MARK: Asking

    /// The four queries through `ask` (an instant query's answer), one
    /// after another. Agent mode — the server saying queries are
    /// unavailable, or a 404 on `/api/v1/query` that isn't the apiserver's
    /// — marks the profile agent-only. Any other refusal of the first
    /// query leaves the profile unknown, said in `problem`; of a later one,
    /// that part unknown. What stops the context's reads (a credential, a
    /// `services/proxy` 403, a busy server's `Retry-After`) is thrown, as
    /// is a cancellation, and nothing is kept.
    static func probe(at now: Date, _ ask: @Sendable (String) async throws -> KubePrometheusReader.Answer) async throws -> KubePromProfile {
        var profile = KubePromProfile(probed: now)
        do {
            profile.metrics = metrics(try await ask(existsQuery).series)
        } catch let failure as KubePrometheusReader.Failure {
            if failure.kind == .agentMode || failure.kind == .notFound {
                profile.agentOnly = true
                return profile
            }
            guard !failure.stopsQueries else { throw failure }
            profile.problem = failure.message
            return profile
        }
        func part(_ query: String) async throws -> KubePrometheusReader.Answer? {
            do {
                return try await ask(query)
            } catch let failure as KubePrometheusReader.Failure where !failure.stopsQueries {
                return nil
            }
        }
        if let duplicates = try await part(duplicatesQuery) { profile.read(duplicates: duplicates.series) }
        if let job = profile.cadvisorJob, let answer = try await part(scrapeQuery(job: job)) {
            profile.scrape = scrape(KubePrometheusReader.value(answer.series))
        }
        if profile.has("prometheus_tsdb_lowest_timestamp_seconds"), let answer = try await part(retentionQuery) {
            profile.retention = retention(KubePrometheusReader.value(answer.series))
        }
        return profile
    }
}

/// Which form of a series a chart reads (metrics.md, 4.3): the
/// kubernetes-mixin's recording rules, node-exporter, or raw cAdvisor and
/// kube-state-metrics — the best the profile allows, named in the caption.
enum KubePromTier: String, Equatable, Sendable {
    case rules, nodeExporter, raw

    var title: String {
        switch self {
        case .rules: "recording rules"
        case .nodeExporter: "node-exporter"
        case .raw: "raw cAdvisor"
        }
    }
}
