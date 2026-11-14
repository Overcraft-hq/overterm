import AppKit

/// Usage (stage 2d; docs/design/kubernetes/analysis.md, 2.11): CPU and
/// Memory columns on the pods and nodes lists — a node's with its share of
/// allocatable, as `kubectl top nodes` says it — from metrics.k8s.io,
/// polled by the model's monitor only while the page shows one of them in
/// a window on screen (or the Overview's totals). A dash, with why, where
/// metrics-server is absent, down, refused or its sample too old; none of
/// it with the context's `metrics: none`. A pod's detail says its
/// containers' usage against their requests and limits.
extension KubernetesPageModel {
    static let cpuColumn = "metrics.cpu"
    static let memoryColumn = "metrics.memory"

    static func measure(of column: String) -> KubeUsageCell.Measure? {
        switch column {
        case cpuColumn: .cpu
        case memoryColumn: .memory
        default: nil
        }
    }

    static func metricsColumns(_ want: KubeMetricsWant) -> [ResourceColumn] {
        let of =
            want == .nodes
            ? " — with its share of the node's allocatable, as kubectl top nodes says it, and the last 15 min of that share as a strip of 15 s cells (taller and warmer as it nears allocatable; blank where nothing was sampled)"
            : " — its containers', summed"
        // Never narrower than a value: at 1400 pt with the wide view's
        // columns beside them, 40 pt drew "1.m" and "1..i" (the list
        // scrolls sideways instead). A node's value has its strip beside
        // it. `usageMinWidth`.
        let node = want == .nodes
        let cpuMin = usageMinWidth(.cpu, node: node)
        let memoryMin = usageMinWidth(.memory, node: node)
        return [
            ResourceColumn(
                id: cpuColumn, title: "CPU", width: max(node ? 180 : 80, cpuMin), minWidth: cpuMin,
                help: "CPU used, in millicores, from metrics.k8s.io (kubectl top)\(of). Read every 15 s while shown."),
            ResourceColumn(
                id: memoryColumn, title: "Memory", width: max(node ? 190 : 90, memoryMin), minWidth: memoryMin,
                help: "Memory used (working set) from metrics.k8s.io (kubectl top)\(of). Read every 15 s while shown."),
        ]
    }

    /// A usage cell's text font: 12 pt monospaced, as the list draws it.
    static let usageFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// The width a usage cell's content takes: its text, and for a node
    /// its heat strip and the 6 pt between them (`KubernetesPageView.cell`).
    static func usageContentWidth(_ text: String, strip: Bool) -> CGFloat {
        let drawn = (text as NSString).size(withAttributes: [.font: usageFont]).width.rounded(.up)
        return drawn + (strip ? KubeHeatStripView.width + 6 : 0)
    }

    /// A usage column's least width: its longest likely value ("12000m",
    /// "65536Mi"; a node's with its share, "12000m (100%)", and its strip)
    /// and the cell's 6 pt either side.
    static func usageMinWidth(_ measure: KubeUsageCell.Measure, node: Bool = false) -> CGFloat {
        let value = measure == .cpu ? "12000m" : "65536Mi"
        // At least what a pod's took before it was measured (64, 72 pt).
        return max(usageContentWidth(node ? value + " (100%)" : value, strip: node) + 12, measure == .cpu ? 64 : 72)
    }

    /// The Pods list's shares of request and limit (metrics.md 2.1, M5b):
    /// part of the wide view.
    var showsShareColumns: Bool { wide && metricsWant == .pods }

    static var shareColumns: [ResourceColumn] {
        // 56 pt: the header's "%MEM/R" whole, not "%ME…".
        KubePodShares.Column.allCases.map { ResourceColumn(id: $0.rawValue, title: $0.title, width: 70, minWidth: 56, help: $0.help) }
    }

    /// A pod's share cell: without Prometheus a dash and its sentence (no
    /// pod object read for it, decision 10); else the usage's own dash
    /// while there is no number, else kube-state-metrics' answer.
    func share(_ column: KubePodShares.Column, of row: KubeListRow, now: Date = Date()) -> KubeUsageCell {
        guard metricsWant == .pods else { return .dash(KubeMetricsAvailability.off.reason ?? "") }
        guard prometheusOn else { return .dash(KubeChartEmpty.sharesNeedPrometheus.sentence) }
        let used = usage(column.measure, of: row, now: now)
        guard used.sort != nil, let pod = model.metrics.reading(.pods)?.sample?.pods[row.row.id] else { return used }
        return model.prometheus.shareCell(column, row.row.id, used: pod.total, sampled: pod.containers.count)
    }

    /// The usage the list shows: its pods', its nodes' — nil for another
    /// kind, or with the context's `metrics: none`.
    var metricsWant: KubeMetricsWant? {
        guard model.selected?.settings.metrics != KubeMetricsSource.none else { return nil }
        switch model.kind.fullName {
        case KubeResourceKind.pods.fullName: return .pods
        case "nodes": return .nodes
        default: return nil
        }
    }

    /// What the page shows now that needs usage: the list's, the Overview's
    /// (the nodes') — only while the page is on screen.
    var metricsOnScreen: KubeMetricsWant? {
        guard visible, windowVisible else { return nil }
        if section == .overview { return model.selected?.settings.metrics == KubeMetricsSource.none ? nil : .nodes }
        return section.listsKinds ? metricsWant : nil
    }

    /// What the detail shows now that reads its own usage (metrics.md
    /// 4.1): a pod's Overview (its usage block) or its Metrics tab — the
    /// pod's own PodMetrics, whatever the list beside it shows — only while
    /// the page is on screen.
    /// Its Metrics tab, a workload's, an HPA's, a node's or a namespace's:
    /// what that tab charts (`objectMetricsDetails`).
    /// Not while every chart of the tab is Prometheus' (1h on), nor while Live is paused.
    var metricsDetailsOnScreen: [KubeMetricsDetail] {
        guard chartsShown, section.listsKinds, model.selected?.settings.metrics != KubeMetricsSource.none, let detail else { return [] }
        let sampled = detailTab == .metrics && !metricsLivePaused && metricsSource(of: detail.ref).map { $0 != .prometheus } ?? true
        if detail.ref.isPod, let namespace = detail.ref.namespace {
            guard detailTab == .overview || sampled else { return [] }
            return [.pod(namespace: namespace, name: detail.ref.name)]
        }
        guard sampled else {
            // Every chart Prometheus': who holds a node's GPUs is still its pods' to say (decision 12).
            let shows = detailTab == .metrics && !metricsLivePaused && detail.ref.metricsSubject == .node
            return shows && gpuAllocation(of: detail) != nil ? [.nodePods(detail.ref.name)] : []
        }
        return objectMetricsDetails(detail)
    }

    /// The monitor told what this page shows.
    func updateMetricsWanted() {
        // An expanded chart on screen, the page hidden: its tab's usage and Prometheus still read (M9).
        model.holdCharts(holdsChartsForExpansion, for: self)
        model.metrics.want(metricsOnScreen, for: self)
        model.metrics.wantDetail(metricsDetailsOnScreen, for: self)
        if chartsShown { askChartLookups() }
        updateChartChanges()
        updatePrometheusWanted()
        updateMetricsPause()
    }

    /// A row's usage cell.
    func usage(_ measure: KubeUsageCell.Measure, of row: KubeListRow, now: Date = Date()) -> KubeUsageCell {
        guard let want = metricsWant else { return .dash(KubeMetricsAvailability.off.reason ?? "") }
        return model.metrics.cell(measure, row: row.row.id, want: want, now: now)
    }

    /// A node's row's heat strip (metrics.md 2.1, M3c): its last 15
    /// minutes as the ring holds them, against the allocatable the nodes'
    /// read gave — only beside a number, where the cell shows one: a dash
    /// has no strip. Nothing is read for it.
    func heatStrip(_ measure: KubeUsageCell.Measure, of row: KubeListRow, now: Date = Date()) -> KubeHeatStrip? {
        guard metricsWant == .nodes, row.row.id.namespace == nil, usage(measure, of: row, now: now).sort != nil,
            let allocatable = model.metrics.reading(.nodes)?.sample?.allocatable[row.row.id.name]
        else { return nil }
        return KubeHeatStrip.of(
            model.metrics.ring.segments(.node(row.row.id.name), .list, now: now), measure, allocatable: measure == .cpu ? allocatable.cpu : allocatable.memory)
    }

    /// A strip's identifier: `kubernetes.heat.<node>.cpu`.
    static func heatStripIdentifier(_ node: String, _ measure: KubeUsageCell.Measure) -> String {
        "kubernetes.heat.\(node).\(measure == .cpu ? "cpu" : "memory")"
    }

    /// What the header says of the usage: why there's none, how old it is.
    var metricsNote: String? {
        guard let want = metricsWant, showsSection else { return volumeNote }
        // Both said where both have something to say: neither hides the other.
        let notes = [model.metrics.note(want), sharesNote].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    /// Why none of the shares can be shown, said once in the header: the
    /// sentence each dash says too. Without metrics-server's usage there
    /// is nothing to share: the usage's own note says why.
    var sharesNote: String? {
        guard showsShareColumns, model.metrics.availability == .served || !prometheusOn else { return nil }
        guard prometheusOn else { return KubeChartEmpty.sharesNeedPrometheus.sentence }
        if case .unavailable(let why) = model.prometheus.state { return why }
        return model.prometheus.shares?.unavailable
    }

    /// Whether the header's note is a refusal: Try Again beside it.
    var metricsNoteIsRefusal: Bool {
        guard let want = metricsWant, showsSection else { return false }
        return model.metrics.isRefused(want)
    }

    /// A pod's current sample: its own read (the detail's), else the
    /// list's — nil when neither is current.
    func podSample(of ref: KubeObjectRef, now: Date = Date()) -> KubePodMetrics? {
        guard ref.isPod, let namespace = ref.namespace, model.metrics.availability == .served else { return nil }
        let id = KubeRowID(namespace: namespace, name: ref.name)
        let readings = [model.metrics.reading(.pod(namespace: namespace, name: ref.name)), model.metrics.reading(.pods)]
        for reading in readings {
            guard let sample = reading?.sample, now.timeIntervalSince(sample.read) <= model.metrics.staleAfter, let pod = sample.pods[id] else { continue }
            return pod
        }
        return nil
    }

    /// A pod's containers' usage against their requests and limits: the
    /// detail's object and the pod's sample. Nil without either.
    func containerUsage(of ref: KubeObjectRef, object: [String: Any]?) -> [KubeContainerUsage.Line]? {
        guard let object, let pod = podSample(of: ref) else { return nil }
        return KubeContainerUsage.lines(object, pod)
    }

    /// Why a pod's own usage read has nothing: its refusal, its failure.
    func podUsageProblem(of ref: KubeObjectRef) -> String? {
        guard ref.isPod, let namespace = ref.namespace, podSample(of: ref) == nil,
            let reading = model.metrics.reading(.pod(namespace: namespace, name: ref.name))
        else { return nil }
        return reading.refused ?? reading.problem.map { "Usage couldn't be read: \($0)" }
    }

    /// Whether a pod's own usage read was refused: Try Again beside it.
    func podUsageRefused(of ref: KubeObjectRef) -> Bool {
        guard ref.isPod, let namespace = ref.namespace, podSample(of: ref) == nil else { return false }
        return model.metrics.reading(.pod(namespace: namespace, name: ref.name))?.refused != nil
    }

    /// A pod's samples taken while shown — its detail's, kept an hour, else
    /// the list's (its sparkline): only while its usage is current, as the
    /// numbers are.
    func usageHistory(of ref: KubeObjectRef) -> [KubeUsagePoint] {
        guard podSample(of: ref) != nil else { return [] }
        return model.metrics.ring.points(.pod(namespace: ref.namespace ?? "", name: ref.name))
    }
}

/// The Overview section (`1`): read while it shows on a page on screen,
/// in the context and namespace shown (`KubeClusterOverviewSession`).
extension KubernetesPageModel {
    var overviewShows: Bool { section == .overview && visible && windowVisible }

    /// Shown: followed there; hidden, nothing is.
    func updateOverviewReading() {
        guard overviewShows, model.enabled, let context = model.selectedName else {
            clusterOverview.hide()
            health.hide()
            pinnedHealth.hide(by: self)
            return
        }
        if detail != nil, section == .overview { closeDetail() }
        clusterOverview.sawMarks = { [weak model] context in model?.sawMarks(in: context) }
        clusterOverview.show(context: context, scope: model.scope, discovery: model.discovery, client: model.client(for: context))
        health.show(context: context, scope: model.scope, discovery: model.discovery, client: model.client(for: context))
        showPinnedHealth()
    }

    /// An object the Overview names (a failing pod, a workload, a node):
    /// its kind's list, and its detail.
    func openFromOverview(kind fullName: String, _ id: KubeRowID, from section: KubeSection = .overview) {
        guard let context = model.selectedName else { return }
        detailOpenedFrom = section
        let kind = model.catalog.kind(fullName: fullName) ?? (fullName == KubeResourceKind.pods.fullName ? .pods : nil)
        guard let kind else { return }
        showKind(kind)
        open(KubeObjectRef(context: context, kind: kind, namespace: kind.namespaced ? id.namespace : nil, name: id.name), from: .overview)
        if kind.fullName == KubeResourceKind.pods.fullName { detailTab = .overview }
    }

    /// A key while the Overview shows: the page's own (sections, `n`, `c`,
    /// `:`, `0`, `?`, `/`); the list's verbs would act on a kind not on
    /// screen, so they are refused. Nil: the page's to decide.
    func overviewPress(_ characters: String) -> Bool? {
        guard !cheatSheet, case .key(let key) = KubernetesKey.press(characters, sheetShowing: cheatSheet) else { return nil }
        return [.command, .namespace, .context, .allNamespaces].contains(key) ? nil : false
    }

    /// The cluster's CPU and memory used against what its nodes can give,
    /// from the nodes' sample: nil until it is read (or without metrics-server).
    var clusterUsage: (used: KubeUsage, allocatable: KubeUsage?)? {
        guard model.metrics.availability == .served, let reading = model.metrics.reading(.nodes), let sample = reading.sample,
            Date().timeIntervalSince(sample.read) <= model.metrics.staleAfter, !sample.nodes.isEmpty
        else { return nil }
        return (sample.clusterUsage, sample.clusterAllocatable)
    }

    /// The cluster's samples taken while the Overview showed: only while
    /// its usage is current.
    var clusterHistory: [KubeUsagePoint] {
        guard clusterUsage != nil else { return [] }
        return model.metrics.ring.points(.cluster)
    }
}
