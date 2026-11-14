import Foundation

// Rightsizing (docs/design/kubernetes/metrics.md, 2.10, 4.6's R1, 6.3;
// stage M10): seven days of a pod's or a workload's usage — or what
// Prometheus keeps, if less — asked once, on the press, and turned into a
// request. Per pod, never per workload: a request is a pod's, so each
// quantile is taken over each pod's own series (`by (namespace, pod,
// container)`) and the highest pod's figure is the container's; a quantile
// of the workload's sum would suggest N times too much. CPU is
// compressible, so its request is p95 × 1.15; memory isn't — an
// over-limit container is OOMKilled — so its request and limit are the max
// × 1.15, and an OOMKill in the window says the max understates the need
// (VPA's practice). Raw cAdvisor needs a subquery for a quantile of a rate
// (or of a de-duplicated gauge), so without recording rules it is offered
// for one pod, or a workload of at most 50 pods (`KubeQueryCost.subquery`):
// its pods are listed first, from a cheap source (kube-state-metrics, the
// rule — never the week's cAdvisor samples), and the subqueries then read
// those pods' series alone, by name — what was counted is what is read. With
// the mixin's rules no subquery is needed. Advice only: nothing is applied,
// nothing typed anywhere. Pure.

/// Whose usage is sized: a pod's containers, or a workload's (per pod).
enum KubeSizingSubject: Hashable, Sendable {
    case pod(namespace: String, name: String)
    case workload(namespace: String, kind: String, name: String)

    var object: String {
        switch self {
        case .pod(let namespace, let name): "pod/\(namespace)/\(name)"
        case .workload(let namespace, let kind, let name): "\(kind)/\(namespace)/\(name)"
        }
    }

    var namespace: String {
        switch self {
        case .pod(let namespace, _), .workload(let namespace, _, _): namespace
        }
    }
}

/// One press of Sizing: in which context, whose, and when — each press its own, asked once.
struct KubeSizingRequest: Hashable, Sendable {
    var context: String
    var subject: KubeSizingSubject
    var asked: Date
}

/// What R1 asks: its five measures (CPU p50, p95, max; memory p95, max),
/// and which containers last ended OOMKilled, as kube-state-metrics says.
enum KubeSizingMeasure: String, CaseIterable, Sendable {
    case cpu50, cpu95, cpuMax, memory95, memoryMax, oom

    var isCPU: Bool { self == .cpu50 || self == .cpu95 || self == .cpuMax }
}

/// One container's seven days: the highest pod's figure for each measure.
struct KubeSizingFigures: Equatable, Sendable {
    var container: String
    var cpu50: Double?
    var cpu95: Double?
    var cpuMax: Double?
    var memory95: Double?
    var memoryMax: Double?
    /// kube-state-metrics says one of its pods' last end was OOMKilled (no
    /// time; where its restarts are kept, a pod that restarted in the window).
    var lastOOMKilled = false

    subscript(_ measure: KubeSizingMeasure) -> Double? {
        get {
            switch measure {
            case .cpu50: cpu50
            case .cpu95: cpu95
            case .cpuMax: cpuMax
            case .memory95: memory95
            case .memoryMax: memoryMax
            case .oom: lastOOMKilled ? 1 : nil
            }
        }
        set {
            switch measure {
            case .cpu50: cpu50 = newValue
            case .cpu95: cpu95 = newValue
            case .cpuMax: cpuMax = newValue
            case .memory95: memory95 = newValue
            case .memoryMax: memoryMax = newValue
            case .oom: lastOOMKilled = (newValue ?? 0) > 0
            }
        }
    }
}

/// What R1 asks for a subject: its queries (instant, at the window's end),
/// or the pods to count first, or why it isn't asked.
struct KubeSizingPlan: Equatable, Sendable {
    /// The span read: seven days, or what Prometheus keeps.
    var window: TimeInterval
    var tier: KubePromTier
    /// How a workload's pods were told; nil for a pod.
    var selection: KubeTabSelection?
    var queries: [KubeChartQuery] = []
    /// A raw workload's pods over the window, a series each by `(namespace,
    /// pod)`, listed before its subqueries — which then read those pods alone.
    var count: KubeChartQuery?
    /// Not asked: why.
    var refused: String?
    /// What the reading should say beside its figures (pods listed over less than the window).
    var notes: [String] = []
}

/// A press's answer, as it stands: asked, then read — once, never refreshed.
struct KubeSizingReading: Equatable, Sendable {
    var request: KubeSizingRequest
    var window: TimeInterval?
    var tier: KubePromTier?
    var selection: KubeTabSelection?
    /// A raw workload's pods over the window, as counted.
    var pods: Int?
    var figures: [KubeSizingFigures] = []
    /// What was asked (Copy PromQL).
    var queries: [KubeChartQuery] = []
    /// A query failed, or the read stopped: what.
    var problem: String?
    /// Not asked: why (the bounds, the retention).
    var refused: String?
    /// Prometheus can't be asked here at all (agent mode).
    var unavailable: String?
    /// Prometheus' warnings beside its answers.
    var notes: [String] = []
    var read: Date?
    /// Finished, whatever it found: never asked again for this press.
    var done = false
}

enum KubeSizing {
    /// The span asked: seven days.
    static let span: TimeInterval = 7 * 86400
    /// A subquery's resolution.
    static let resolution: TimeInterval = 300
    /// Less kept than this, nothing is sized.
    static let shortest: TimeInterval = 3600
    /// The headroom over the figure a suggestion takes.
    static let headroom = 1.15
    static let quantiles: [KubeSizingMeasure: String] = [.cpu50: "0.5", .cpu95: "0.95", .memory95: "0.95"]

    /// The span read at `now`: seven days, or what Prometheus keeps (its
    /// oldest sample, where it scrapes itself), in whole hours; nil, less
    /// than an hour kept.
    static func window(_ profile: KubePromProfile, now: Date) -> TimeInterval? {
        var window = span
        if let oldest = profile.retention { window = min(window, now.timeIntervalSince(oldest)) }
        window = (window / 3600).rounded(.down) * 3600
        return window >= shortest ? window : nil
    }

    /// `$w5`: a rate over 5 minutes, or four scrapes where they are longer.
    static func rateWindow(scrape: TimeInterval) -> TimeInterval { max(resolution, 4 * scrape) }

    /// "7 days", "2 days (what Prometheus keeps)", "18 hours (…)".
    static func said(window: TimeInterval) -> String {
        let hours = Int(window / 3600)
        let length = hours % 24 == 0 ? "\(hours / 24) day\(hours == 24 ? "" : "s")" : "\(hours) hour\(hours == 1 ? "" : "s")"
        return window >= span ? length : "\(length) (what Prometheus keeps)"
    }

    /// Why a raw workload of `pods` pods isn't sized; nil, it is.
    static func refusal(pods: Int, window: TimeInterval, profile: KubePromProfile) -> String? {
        guard !KubeQueryCost.subquery(.workload(pods: pods), profile: profile).isAllowed else { return nil }
        let samples = KubeQueryCost.said(KubeQueryCost.samples(series: pods, span: window, scrape: profile.scrapeInterval))
        return "Sizing reads each of its \(pods) pods' \(said(window: window)) in a subquery, about \(samples) samples a measure, and this Prometheus "
            + "has no recording rules: it is offered for a workload of at most \(KubeQueryCost.maxSubqueryPods) pods, or one of its pods."
    }

    /// Why a raw workload whose pods weren't found isn't sized: no names,
    /// no bound on what its subqueries would read.
    static let noPods = "None of its pods were found in Prometheus over the window, so nothing is sized: its subqueries are sent only for the pods they read."

    /// A raw workload's pods without kube-state-metrics: listed over this, the last hour's.
    static let recentPods: TimeInterval = 3600

    /// What R1 asks for `subject` at `now`. A raw workload's pods are
    /// listed first: `pods` nil, the plan holds that list's query alone;
    /// given, the subqueries read those pods' series by name and no others
    /// (a sibling that shares the prefix, api and api-gateway, isn't read).
    static func plan(_ subject: KubeSizingSubject, profile: KubePromProfile, now: Date, pods: [String]? = nil) -> KubeSizingPlan {
        let rules = profile.hasContainerRules ? profile.containerCPURule : nil
        guard let window = window(profile, now: now) else {
            return KubeSizingPlan(
                window: 0, tier: rules == nil ? .raw : .rules,
                refused: "Prometheus keeps less than an hour here: there is nothing to size from yet.")
        }
        var plan = KubeSizingPlan(window: window, tier: rules == nil ? .raw : .rules)
        let over = KubePromQL.duration(window)
        let ksm = profile.ksmMatcher
        var scope: String
        var owners: String?
        switch subject {
        case .pod(let namespace, let name):
            scope = KubePromQL.matchers([("namespace", namespace), ("pod", name)])
            owners = nil
        case .workload(let namespace, let kind, let name):
            let selection = KubeTabQueries.workloadSelection(kind: kind, profile: profile)
            plan.selection = selection
            scope = KubeTabQueries.workloadScope(namespace: namespace, kind: kind, name: name, selection: selection)
            owners = ownersOver(kind: kind, namespace: namespace, name: name, selection: selection, window: over, profile: profile)
            if rules == nil {
                let listed = podsOver(kind: kind, namespace: namespace, name: name, selection: selection, owners: owners, window: window, profile: profile)
                if listed.recent { plan.notes = [recentNote] }
                guard let pods else {
                    plan.count = KubeChartQuery(id: "pods", promql: listed.promql, instant: true)
                    return plan
                }
                guard !pods.isEmpty else {
                    plan.refused = noPods
                    return plan
                }
                if let why = refusal(pods: pods.count, window: window, profile: profile) {
                    plan.refused = why
                    return plan
                }
                // What was counted is what is read: these pods by name, the owner join no longer needed.
                scope = KubeTabQueries.joined([KubePromQL.matchers([("namespace", namespace)]), KubeTabQueries.podsMatcher(pods.sorted())])
                owners = nil
            }
        }
        /// Each container's highest pod: a workload's pods alone, by who owned them in the window.
        func perContainer(_ perPod: String) -> String {
            "max by (container)(" + (owners.map { "(\(perPod)) * on(namespace,pod) group_left() \($0)" } ?? perPod) + ")"
        }
        func add(_ measure: KubeSizingMeasure, _ promql: String) {
            plan.queries.append(KubeChartQuery(id: measure.rawValue, promql: promql, instant: true))
        }
        if let rules {
            // The mixin's rules: a series a container already, no subquery.
            let selector = KubeTabQueries.joined([scope, #"container!="""#, #"container!="POD""#])
            for (measure, rule) in [
                (KubeSizingMeasure.cpu50, rules), (.cpu95, rules), (.cpuMax, rules), (.memory95, KubePromProfile.containerMemoryRule), (.memoryMax, KubePromProfile.containerMemoryRule),
            ] {
                let stat = quantiles[measure].map { "quantile_over_time(\($0), \(rule){\(selector)}[\(over)])" } ?? "max_over_time(\(rule){\(selector)}[\(over)])"
                add(measure, perContainer("max by (namespace,pod,container)(\(stat))"))
            }
        } else {
            // Raw cAdvisor: each container's rate (its series summed — one a
            // container instance) and gauge (taken once — kubelet's two paths)
            // per pod, then its quantile over the window in a subquery.
            let selector = KubeTabQueries.joined([profile.cadvisorMatchers, scope])
            let rate = KubePromQL.duration(rateWindow(scrape: profile.scrapeInterval))
            let step = KubePromQL.duration(resolution)
            let cpu = "sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{\(selector)}[\(rate)]))"
            let memory = "max by (namespace,pod,container)(container_memory_working_set_bytes{\(selector)})"
            add(.cpu50, perContainer("quantile_over_time(0.5, (\(cpu))[\(over):\(step)])"))
            add(.cpu95, perContainer("quantile_over_time(0.95, (\(cpu))[\(over):\(step)])"))
            add(.cpuMax, perContainer("max_over_time((\(cpu))[\(over):\(step)])"))
            add(.memory95, perContainer("quantile_over_time(0.95, (\(memory))[\(over):\(step)])"))
            // A max of maxes needs no subquery: every sample, each series' highest, then the pod's.
            add(.memoryMax, perContainer("max by (namespace,pod,container)(max_over_time(container_memory_working_set_bytes{\(selector)}[\(over)]))"))
        }
        if !profile.ksmMissing, profile.mayHave("kube_pod_container_status_last_terminated_reason") {
            // kube-state-metrics' last end has no time: only a container that
            // restarted in the window ended in it, so only its OOMKill is this window's.
            let reason = "kube_pod_container_status_last_terminated_reason{\(KubeTabQueries.joined([ksm, #"reason="OOMKilled""#, scope]))}"
            var killed = "max by (namespace,pod,container)(\(reason)) == 1"
            if profile.mayHave("kube_pod_container_status_restarts_total") {
                let restarts = "kube_pod_container_status_restarts_total{\(KubeTabQueries.joined([ksm, scope]))}"
                killed = "(\(killed)) and on(namespace,pod,container) (max by (namespace,pod,container)(increase(\(restarts)[\(over)])) > 0)"
            }
            add(.oom, perContainer(killed))
        }
        return plan
    }

    /// Said when a raw workload's pods were listed over the last hour only.
    static let recentNote =
        "Its pods are those Prometheus saw in the last hour: without kube-state-metrics, earlier ones (before a rollout) can't be told without reading their week."

    /// A raw workload's pods over the window, a series each by `(namespace,
    /// pod)`, from what is cheap to read: its owners (kube-state-metrics,
    /// the rule), else kube-state-metrics' `kube_pod_info` by the name
    /// pattern — one series a pod, no cAdvisor. Without kube-state-metrics,
    /// cAdvisor's last hour (`recent`), never its week: listing the week's
    /// samples would cost what the subqueries do.
    static func podsOver(
        kind: String, namespace: String, name: String, selection: KubeTabSelection, owners: String?, window: TimeInterval, profile: KubePromProfile
    ) -> (promql: String, recent: Bool) {
        if let owners { return (owners, false) }
        let named = KubeTabQueries.joined([KubePromQL.matchers([("namespace", namespace)]), KubeTabQueries.podMatcher(kind: kind, name: name)])
        if !profile.ksmMissing, profile.mayHave("kube_pod_info") {
            return ("max by (namespace,pod)(max_over_time(kube_pod_info{\(KubeTabQueries.joined([profile.ksmMatcher, named]))}[\(KubePromQL.duration(window))]))", false)
        }
        let recent = KubePromQL.duration(min(window, recentPods))
        return ("max by (namespace,pod)(last_over_time(container_cpu_usage_seconds_total{\(KubeTabQueries.joined([profile.cadvisorMatchers, named]))}[\(recent)]))", true)
    }

    /// A workload's pods, 1 each by `(namespace, pod)`, owned by it at any
    /// time in the window — not only now: last week's ReplicaSets' pods too.
    /// No subquery: each owner series' highest over the window. Nil: the
    /// pods are told by their names (the scope's regex).
    static func ownersOver(kind: String, namespace: String, name: String, selection: KubeTabSelection, window: String, profile: KubePromProfile) -> String? {
        let ksm = profile.ksmMatcher
        switch selection {
        case .name:
            return nil
        case .rule:
            let matchers = KubePromQL.matchers([("namespace", namespace), ("workload", name), ("workload_type", kind.lowercased())])
            return "max by (namespace,pod)(max_over_time(\(KubePromProfile.workloadRule){\(matchers)}[\(window)]))"
        case .owner where kind == "Deployment":
            let pods = KubeTabQueries.joined([ksm, KubePromQL.matchers([("namespace", namespace), ("owner_kind", "ReplicaSet")])])
            let sets = KubeTabQueries.joined([ksm, KubePromQL.matchers([("namespace", namespace), ("owner_kind", "Deployment"), ("owner_name", name)])])
            return "max by (namespace,pod)(label_replace(max_over_time(kube_pod_owner{\(pods)}[\(window)]),\"replicaset\",\"$1\",\"owner_name\",\"(.*)\")"
                + " * on(namespace,replicaset) group_left() max by (namespace,replicaset)(max_over_time(kube_replicaset_owner{\(sets)}[\(window)])))"
        case .owner:
            let pods = KubeTabQueries.joined([ksm, KubePromQL.matchers([("namespace", namespace), ("owner_kind", kind), ("owner_name", name)])])
            return "max by (namespace,pod)(max_over_time(kube_pod_owner{\(pods)}[\(window)]))"
        }
    }

    /// The answers, a container each (by its `container` label), in name order.
    static func figures(_ answers: [KubeSizingMeasure: [KubeSeries]]) -> [KubeSizingFigures] {
        var byContainer: [String: KubeSizingFigures] = [:]
        for (measure, series) in answers {
            for one in series {
                guard let container = one.labels["container"], !container.isEmpty, let value = one.points.last?.value, value.isFinite else { continue }
                var figures = byContainer[container] ?? KubeSizingFigures(container: container)
                figures[measure] = max(figures[measure] ?? value, value)
                byContainer[container] = figures
            }
        }
        return byContainer.values.filter { figures in KubeSizingMeasure.allCases.contains { $0 != .oom && figures[$0] != nil } }.sorted { $0.container < $1.container }
    }

    /// CPU's suggested request: p95 × 1.15, up to the next 5 millicores.
    static func cpuRequest(p95: Double) -> Double { max(5, ((p95 * headroom * 1000) / 5).rounded(.up) * 5) / 1000 }

    /// Memory's suggested request and limit: the max × 1.15, up to the next Mi.
    static func memory(max: Double) -> Double { Swift.max(1, (max * headroom / 1_048_576).rounded(.up)) * 1_048_576 }
}

/// What the Sizing card shows: a container each — CPU's p50, p95 and max
/// and memory's p95 and max as bars against its request and limit, the
/// suggestion and how it was made, and an OOMKill's warning. Pure.
struct KubeSizingCard: Equatable {
    struct Bar: Equatable, Identifiable {
        var label: String
        var value: Double
        var text: String
        var id: String { label }
    }

    struct Measure: Equatable {
        var title: String
        var bars: [Bar]
        var request: Double?
        var limit: Double?
        var suggested: Double
        /// "suggested request ≈ p95 × 1.15 = 245m".
        var suggestion: String
        /// "request 1000m · limit 2", or that none is set.
        var now: String
        /// The bars' full width: the largest of the bars and the lines.
        var scale: Double { max([bars.map(\.value).max() ?? 0, request ?? 0, limit ?? 0, suggested].max() ?? 0, 1e-9) }
    }

    struct Row: Equatable, Identifiable {
        var container: String
        var cpu: Measure?
        var memory: Measure?
        var note: String?
        var id: String { container }
    }

    /// "Sizing · 7 days · per pod · recording rules".
    var title: String
    var rows: [Row]
    /// The same in words for VoiceOver, a row each.
    var summary: [String]

    static let advice = "Advice only: nothing is changed. Requests are per pod — each pod's own usage, the highest pod's figure."

    /// `reading`'s figures against `containers`' requests and limits (the
    /// pod's spec, or its workload's template); `oomKilled`, the times the
    /// objects say a container was OOMKilled (only those in the window count).
    static func of(_ reading: KubeSizingReading, containers: [KubePodCharts.Container], oomKilled: [String: Date], now: Date) -> KubeSizingCard {
        let window = reading.window ?? KubeSizing.span
        var title = "Sizing · \(KubeSizing.said(window: window)) · per pod"
        if let tier = reading.tier { title += " · \(tier.title)" }
        if let selection = reading.selection { title += " · \(selection.title)" }
        let order = containers.map(\.name)
        let figures = reading.figures.sorted { (order.firstIndex(of: $0.container) ?? .max, $0.container) < (order.firstIndex(of: $1.container) ?? .max, $1.container) }
        var rows: [Row] = []
        var summary: [String] = []
        for one in figures {
            let spec = containers.first { $0.name == one.container }
            var row = Row(container: one.container)
            if let p95 = one.cpu95 {
                let bars = [("p50", one.cpu50), ("p95", one.cpu95), ("max", one.cpuMax)].compactMap { label, value in
                    value.map { Bar(label: label, value: $0, text: KubeMetricsFormat.cpu($0)) }
                }
                let suggested = KubeSizing.cpuRequest(p95: p95)
                row.cpu = Measure(
                    title: "CPU", bars: bars, request: spec?.cpuRequest, limit: spec?.cpuLimit, suggested: suggested,
                    suggestion: "suggested request ≈ p95 × \(headroom) = \(KubeMetricsFormat.cpu(suggested))",
                    now: said(request: spec?.cpuRequest, limit: spec?.cpuLimit, KubeMetricsFormat.cpu))
            }
            if let max = one.memoryMax {
                let bars = [("p95", one.memory95), ("max", one.memoryMax)].compactMap { label, value in
                    value.map { Bar(label: label, value: $0, text: KubeMetricsFormat.memory($0)) }
                }
                let suggested = KubeSizing.memory(max: max)
                row.memory = Measure(
                    title: "Memory", bars: bars, request: spec?.memoryRequest, limit: spec?.memoryLimit, suggested: suggested,
                    suggestion: "suggested request and limit ≈ max × \(headroom) = \(KubeMetricsFormat.memory(suggested))",
                    now: said(request: spec?.memoryRequest, limit: spec?.memoryLimit, KubeMetricsFormat.memory))
            }
            if let killed = oomKilled[one.container] {
                // The objects' time decides: before the window, not this week's max.
                if killed >= now.addingTimeInterval(-window), killed <= now.addingTimeInterval(60) {
                    row.note = "OOMKilled at \(KubeSizing.time(killed, now: now)); the max understates the need."
                }
            } else if one.lastOOMKilled {
                // No time from the objects: kube-state-metrics', its pod restarted in the window.
                row.note = "A pod's last end was OOMKilled; the max understates the need."
            }
            var words = ["\(one.container):"]
            if let cpu = row.cpu { words.append("CPU " + cpu.bars.map { "\($0.label) \($0.text)" }.joined(separator: ", ") + ", " + cpu.suggestion + ", " + cpu.now + ".") }
            if let memory = row.memory {
                words.append("Memory " + memory.bars.map { "\($0.label) \($0.text)" }.joined(separator: ", ") + ", " + memory.suggestion + ", " + memory.now + ".")
            }
            if let note = row.note { words.append(note) }
            summary.append(words.joined(separator: " "))
            rows.append(row)
        }
        return KubeSizingCard(title: title, rows: rows, summary: summary)
    }

    static var headroom: String { String(format: "%.2f", KubeSizing.headroom) }

    private static func said(request: Double?, limit: Double?, _ format: (Double) -> String) -> String {
        "now: request " + (request.map(format) ?? "none") + " · limit " + (limit.map(format) ?? "none")
    }
}

extension KubeSizing {
    /// "14:11", or "Nov 7, 14:11" on another day — the Mac's zone.
    static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            : date.formatted(.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}
