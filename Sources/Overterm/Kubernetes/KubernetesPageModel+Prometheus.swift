import Foundation

/// Prometheus on the page (stage 4; analysis 2.1, 2.11, 2.17): what this
/// page shows now that needs it — the Overview's cluster chart (its
/// requests and limits against allocatable), a pod's or a claim's chart in
/// its detail's Overview, the PVC list's Used column — told to the
/// model's monitor, only while the page is on screen. Only where the
/// context opts in; elsewhere none of it shows and nothing is asked.
extension KubernetesPageModel {
    static let volumeColumn = "prometheus.volume"
    static let claimsKind = "persistentvolumeclaims"

    /// Whether the context shown opts in to Prometheus.
    var prometheusOn: Bool {
        guard let context = model.selected else { return false }
        return KubePrometheusUse.of(context.settings).isOn
    }

    /// The chart a detail shows, for the object open: a pod's, a claim's.
    func chart(for ref: KubeObjectRef) -> KubeChart? {
        guard let namespace = ref.namespace, ref.kind.group.isEmpty else { return nil }
        if ref.isPod { return .pod(namespace: namespace, name: ref.name) }
        if ref.kind.resource == Self.claimsKind { return .volume(namespace: namespace, claim: ref.name) }
        return nil
    }

    /// What the page shows now that reads Prometheus.
    var prometheusWants: Set<KubePrometheusMonitor.Want> {
        guard visible, windowVisible, prometheusOn else { return [] }
        if section == .overview { return [.chart(.cluster)] }
        guard section.listsKinds else { return [] }
        var wants: Set<KubePrometheusMonitor.Want> = []
        if model.kind.fullName == Self.claimsKind { wants.insert(.volumes) }
        if let detail, detailTab == .overview, let chart = chart(for: detail.ref) { wants.insert(.chart(chart)) }
        return wants
    }

    func updatePrometheusWanted() {
        model.prometheus.want(prometheusWants, for: self)
    }

    /// The PVC list gets a Used column where the context opts in.
    var showsVolumeColumn: Bool { model.kind.fullName == Self.claimsKind && prometheusOn }

    static var volumeColumnSpec: ResourceColumn {
        ResourceColumn(
            id: volumeColumn, title: "Used", width: 180, minWidth: 40,
            help: "What the volume holds against its capacity, from Prometheus (kubelet_volume_stats_used_bytes and _capacity_bytes). Read every minute while shown.")
    }

    func volumeUsage(of row: KubeListRow) -> KubeUsageCell {
        model.prometheus.volumeCell(row.row.id)
    }

    /// The range every chart shows; picking one asks again.
    var chartRange: KubeChartRange {
        get { model.prometheus.range }
        set { model.prometheus.range = newValue }
    }

    /// Whether charts read Prometheus here (a picker), or only what was sampled while shown.
    var chartsFromPrometheus: Bool { prometheusOn && model.prometheus.service != nil }

    /// Why the PVC list's column has no numbers: Prometheus not found, or not asked yet.
    var volumeNote: String? {
        guard showsVolumeColumn, showsSection else { return nil }
        if case .unavailable(let why) = model.prometheus.state { return why }
        return model.prometheus.volumes?.problem.map { "Volume usage couldn't be read: \($0)" }
    }
}
