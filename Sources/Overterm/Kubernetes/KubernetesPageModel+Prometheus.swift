import Foundation

/// Prometheus on the page (stage 4; analysis 2.1, 2.11, 2.17): what this
/// page shows now that needs it — the Overview's charts (the cluster's
/// against its requests, limits and allocatable, its CPU by namespace, its
/// nodes; metrics.md 2.9, M8), a claim's chart in its detail's Overview
/// (and its inodes while they show), the PVC list's Used column — told to the
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

    /// The chart a detail's Overview shows, for the object open: a claim's
    /// (a pod's are its Metrics tab's).
    func chart(for ref: KubeObjectRef) -> KubeChart? {
        guard let namespace = ref.namespace, ref.kind.group.isEmpty, ref.kind.resource == Self.claimsKind else { return nil }
        return .volume(namespace: namespace, claim: ref.name)
    }

    /// What the page shows now that reads Prometheus.
    var prometheusWants: Set<KubePrometheusMonitor.Want> {
        guard windowVisible, prometheusOn else { return [] }
        // The page hidden: only its Metrics tab's, for a chart expanded into the right slot (M9).
        guard visible else { return metricsTabWant.map { [.tab($0)] } ?? [] }
        if section == .overview { return Set(overviewCharts.map { .chart($0) }) }
        guard section.listsKinds else { return [] }
        var wants: Set<KubePrometheusMonitor.Want> = []
        if model.kind.fullName == Self.claimsKind { wants.insert(.volumes) }
        // The shares divide metrics-server's usage: none read where it isn't served (availability's change asks again).
        if showsShareColumns, model.metrics.availability == .served { wants.insert(.shares) }
        if let detail, detailTab == .overview, let chart = chart(for: detail.ref) {
            wants.insert(.chart(chart))
            if volumeInodesShown, case .volume(let namespace, let claim) = chart { wants.insert(.chart(.volumeInodes(namespace: namespace, claim: claim))) }
        }
        // The Metrics tab's queries, over its range or window (M6) — where
        // Prometheus is found first: its ranges need it.
        if let request = metricsTabWant { wants.insert(.tab(request)) }
        if let request = sizingWant { wants.insert(.sizing(request)) }
        if detail != nil, metricsTabShows, model.prometheus.service == nil, model.prometheus.state == .off || model.prometheus.state == .detecting,
            detail?.ref.metricsSubject != nil
        {
            wants.insert(.locate)
        }
        return wants
    }

    /// The Overview's charts over Prometheus: the cluster's (X1, X2), its
    /// CPU by namespace — the namespaces picked, or every one — (X3) and
    /// its nodes (X4).
    var overviewCharts: [KubeChart] { [.cluster, namespacesChart, .nodes] }

    /// X3 for the namespaces picked: one, several, or (none) every one.
    var namespacesChart: KubeChart { .namespaces(model.scope.names ?? []) }

    func updatePrometheusWanted() {
        // Sizing left before it answered: dropped, asked again only by another press.
        if let asked = sizingAsked, sizingWant == nil, model.prometheus.sizings[asked]?.done != true { sizingAsked = nil }
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
