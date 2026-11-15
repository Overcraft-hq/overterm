import Foundation

/// The Overview's usage on the page (metrics.md 2.9, X1–X4; stage M8):
/// sampled from the nodes' read the Overview already makes while it
/// shows, or from Prometheus (the monitor's `.cluster`, `.namespaces` and
/// `.nodes` readings, wanted in `prometheusWants`). Nothing more is read for it.
extension KubernetesPageModel {
    /// The nodes' allocatable and capacity, as the `/nodes` read last gave them.
    var nodeAllocatable: [String: KubeUsage] { model.metrics.reading(.nodes)?.sample?.allocatable ?? [:] }

    /// X1 and X2 sampled: the cluster's samples taken while the Overview
    /// showed, against its nodes' allocatable and capacity; empty until
    /// metrics-server's usage is current.
    func sampledClusterCharts(now: Date = Date()) -> [KubePodCharts.Chart] {
        guard clusterUsage != nil, let sample = model.metrics.reading(.nodes)?.sample else { return [] }
        return KubeClusterCharts.sampled(
            clusterHistory, allocatable: sample.clusterAllocatable, capacity: sample.clusterCapacity, interval: sampledInterval, now: now)
    }

    /// How far apart the nodes' samples come: the poll's, metrics-server's resolution, 15 s at least.
    var sampledInterval: TimeInterval {
        max(15, KubeChartBuild.sampleInterval(model.metrics.interval), model.metrics.reading(.nodes)?.sample?.resolution ?? 0)
    }

    /// What the sampled charts' caption says: since when, how often.
    func sampledClusterCaption() -> String {
        KubeChartBuild.caption(first: clusterHistory.first?.time, range: .live, interval: sampledInterval, of: "the cluster")
    }

    /// X4 sampled: each node's last 15 minutes, as the Nodes list's strips are.
    func sampledNodeRows(now: Date = Date()) -> (rows: [KubeNodeStripRow], more: Int) {
        guard clusterUsage != nil else { return ([], 0) }
        return KubeClusterCharts.nodeRows(model.metrics.ring, allocatable: nodeAllocatable, now: now)
    }

    /// A node's row clicked: its detail on its Metrics tab.
    func openNodeMetrics(_ node: String) {
        openFromOverview(kind: "nodes", KubeRowID(namespace: nil, name: node))
        if detail?.ref.name == node { showTab(.metrics) }
    }
}

extension KubeChartBuild {
    /// How often metrics-server is asked (15 s), as the captions say it.
    static func sampleInterval(_ interval: Duration) -> TimeInterval {
        let parts = interval.components
        return max(1, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}
