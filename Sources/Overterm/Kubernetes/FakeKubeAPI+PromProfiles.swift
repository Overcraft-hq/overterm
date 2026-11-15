import Foundation

/// The kinds of Prometheus the fake can be (metrics.md, 8's profiles):
/// what the probe's four queries answer — which metrics exist and how
/// many series each has, the duplicates' jobs and paths, the cAdvisor
/// job's scrape, the retention — installed as fixtures matched by a
/// fragment of each query (`setPrometheusMatrix`), never a real server.
/// The charts' own queries still go to `FakePromQL` over the test's series.
struct FakePromProfile: Sendable {
    /// Each metric and its series count.
    var metrics: [String: Int]
    /// cAdvisor's series by job and `metrics_path` (nil: the label isn't set).
    var cadvisor: [(job: String, path: String?)]
    /// kube-state-metrics' jobs.
    var ksmJobs: [String]
    /// cAdvisor's series carry `node`.
    var nodeLabel: Bool
    var scrape: TimeInterval
    /// Seconds since 1970 of the oldest sample, where Prometheus scrapes itself.
    var retention: Double?
    /// Every query answered as an agent answers it.
    var agentMode = false
    /// What the probe's DCGM query (5) finds: the labels its series carry
    /// (`exported_pod`, `pod`, `exporter` — a pod that is the exporter's own —,
    /// `pod_other` — a pod that isn't —, `Hostname`, `node`, `mig`); empty, no DCGM exporter.
    var dcgm: [String] = []

    private static let raw = [
        "container_cpu_usage_seconds_total": 9000, "container_memory_working_set_bytes": 9000, "container_cpu_cfs_throttled_periods_total": 6000,
        "container_cpu_cfs_periods_total": 6000, "container_network_receive_bytes_total": 3000, "container_oom_events_total": 9000,
        "container_fs_usage_bytes": 9000, "container_memory_rss": 9000,
    ]
    private static let ksm = [
        "kube_pod_status_phase": 15000, "kube_pod_container_resource_requests": 8000, "kube_pod_container_status_last_terminated_reason": 500,
        "kube_pod_owner": 3000, "kube_replicaset_owner": 900, "kube_node_status_allocatable": 300, "kube_horizontalpodautoscaler_status_current_replicas": 20,
        "kube_horizontalpodautoscaler_status_target_metric": 20, "kube_resourcequota": 40,
    ]
    private static let nodeExporter = [
        "node_cpu_seconds_total": 3200, "node_memory_MemAvailable_bytes": 50, "node_memory_MemTotal_bytes": 50, "node_uname_info": 50,
        "node_filesystem_avail_bytes": 400, "node_network_receive_bytes_total": 300,
    ]
    private static let kubelet = ["kubelet_volume_stats_used_bytes": 60, "kubelet_volume_stats_inodes_used": 60]
    private static let rules = [
        KubePromProfile.containerCPURate5m: 4000, KubePromProfile.containerMemoryRule: 4000, "namespace_workload_pod:kube_pod_owner:relabel": 3000,
        KubePromProfile.activeRequestsRule: 400, KubePromProfile.nodeCPURule: 50, KubePromProfile.nodeMemoryRule: 50, KubePromProfile.nodeCPUCountRule: 50,
    ]

    /// kube-prometheus-stack: the mixin's rules, a 30 s scrape, kubelet's
    /// cAdvisor scraped at two paths, two kube-state-metrics jobs, `node`
    /// on cAdvisor's series, Prometheus scraping itself.
    static let kubePrometheusStack = FakePromProfile(
        metrics: raw.merging(ksm) { $1 }.merging(nodeExporter) { $1 }.merging(kubelet) { $1 }.merging(rules) { $1 }
            .merging(["prometheus_tsdb_lowest_timestamp_seconds": 1]) { $1 },
        cadvisor: [("kubelet", "/metrics/cadvisor"), ("kubelet", "/metrics/resource")], ksmJobs: ["kube-state-metrics", "kube-state-metrics-shard"],
        nodeLabel: true, scrape: 30, retention: Date().addingTimeInterval(-10 * 86400).timeIntervalSince1970)

    /// The prometheus chart: no rules, a minute's scrape, no `metrics_path`,
    /// `instance` as the node, node-exporter beside it.
    static let prometheusChart = FakePromProfile(
        metrics: raw.merging(ksm) { $1 }.merging(nodeExporter) { $1 }.merging(kubelet) { $1 }.merging(["prometheus_tsdb_lowest_timestamp_seconds": 1]) { $1 },
        cadvisor: [("kubernetes-nodes-cadvisor", nil)], ksmJobs: ["kubernetes-service-endpoints"], nodeLabel: false, scrape: 60,
        retention: Date().addingTimeInterval(-15 * 86400).timeIntervalSince1970)

    /// The prometheus chart without node-exporter, nor its own metrics.
    static let noNodeExporter: FakePromProfile = {
        var profile = prometheusChart
        for name in nodeExporter.keys { profile.metrics[name] = nil }
        profile.metrics["prometheus_tsdb_lowest_timestamp_seconds"] = nil
        profile.retention = nil
        return profile
    }()

    /// kube-state-metrics 1.x's names.
    static let ksm1x: FakePromProfile = {
        var profile = noNodeExporter
        profile.metrics["kube_pod_container_resource_requests"] = nil
        profile.metrics[KubePromProfile.requestsCPUCores] = 4000
        return profile
    }()

    /// containerd's kubelet: no per-container filesystem use.
    static let containerdNoFS: FakePromProfile = {
        var profile = noNodeExporter
        profile.metrics["container_fs_usage_bytes"] = nil
        return profile
    }()

    /// DCGM exporter's metrics (decision 12): the GPU operator's, without profiling.
    static let dcgmMetrics = [
        KubePromProfile.dcgmUtilisation: 8, KubePromProfile.dcgmMemoryUsed: 8, KubePromProfile.dcgmMemoryFree: 8, KubePromProfile.dcgmPower: 8,
        KubePromProfile.dcgmTemperature: 8,
    ]

    /// kube-prometheus-stack beside NVIDIA's GPU operator: DCGM exporter
    /// scraped with `honor_labels` off (the pod's labels `exported_*`),
    /// `Hostname` its node.
    static let gpuOperator: FakePromProfile = {
        var profile = kubePrometheusStack
        profile.metrics.merge(dcgmMetrics) { $1 }
        profile.dcgm = ["exported_pod", "pod", "exporter", "pod_other", "Hostname"]
        return profile
    }()

    /// The same with no GPU allocated anywhere when probed: no
    /// `exported_pod` yet, every series' `pod` the exporter's own
    /// (`nvidia-dcgm-exporter-…`), never a GPU's holder.
    static let gpuOperatorIdle: FakePromProfile = {
        var profile = gpuOperator
        profile.dcgm = ["pod", "exporter", "Hostname"]
        return profile
    }()

    /// Prometheus in agent mode: every query `unavailable with Prometheus Agent`.
    static let agentMode = FakePromProfile(metrics: [:], cadvisor: [], ksmJobs: [], nodeLabel: false, scrape: 30, agentMode: true)
}

extension FakeKubeAPI {
    /// The fake Prometheus answers the probe as `profile` would.
    func setPrometheusProfile(_ profile: FakePromProfile) {
        // An agent answers nothing: one fixture for every query (an empty fragment matches all).
        guard !profile.agentMode else {
            setPrometheusMatrix("", failure: FakePromFixture.Failure(status: 503, errorType: "unavailable", error: "unavailable with Prometheus Agent"))
            return
        }
        clearPrometheusMatrix("")
        setPrometheusMatrix(
            "count by (__name__)",
            profile.metrics.sorted { $0.key < $1.key }.map { name, count in FakePromFixture.Line(["__name__": name]) { _ in Double(count) } })
        var duplicates: [FakePromFixture.Line] = profile.cadvisor.map { job, path in
            var labels = ["job": job, "overterm_s": "cadvisor"]
            if let path { labels["metrics_path"] = path }
            return FakePromFixture.Line(labels) { _ in 4000 }
        }
        duplicates += profile.ksmJobs.map { job in FakePromFixture.Line(["job": job, "overterm_s": "ksm"]) { _ in 50 } }
        if profile.nodeLabel { duplicates.append(FakePromFixture.Line(["overterm_s": "node"]) { _ in 9000 }) }
        setPrometheusMatrix(#""overterm_s","cadvisor""#, duplicates)
        let samples = 600 / profile.scrape
        setPrometheusMatrix("count_over_time(up{", [FakePromFixture.Line { _ in 600 / samples }])
        if profile.dcgm.isEmpty {
            clearPrometheusMatrix(KubePromProfile.dcgmMemoryUsed + "{exported_pod")
        } else {
            setPrometheusMatrix(
                KubePromProfile.dcgmMemoryUsed + "{exported_pod", profile.dcgm.map { tag in FakePromFixture.Line(["overterm_s": tag]) { _ in 4 } })
        }
        if let retention = profile.retention {
            setPrometheusMatrix(KubePromProfile.retentionQuery, [FakePromFixture.Line { _ in retention }])
        } else {
            clearPrometheusMatrix(KubePromProfile.retentionQuery)
        }
    }
}
