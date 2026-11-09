import Foundation

/// The Metrics tab's charts from Prometheus (docs/design/kubernetes/metrics.md,
/// 2.3–2.8; stages M6, M7): the same charts as the sampled ones — a pod's
/// stacked by container then each container's against its spec's request
/// and limit, a workload's top five pods and the rest against its template
/// and by revision, an HPA's replicas and metrics, a node's usage against
/// its pods' requests and its allocatable, a namespace's top eight
/// workloads and the rest against its quota, its pods by phase — over the
/// range or window Prometheus was asked, plus what
/// only Prometheus has: a container's throttling (C3), a pod's network
/// (P3) and restarts (P4), a workload's restarts (W5), and the OOMKills
/// kube-state-metrics saw, marked. In Live with metrics-server, only those
/// are added to the sampled charts (`mixed`). Pure.
enum KubePromTabCharts {
    /// More than this share of CPU periods throttled is high (the mixin's `CPUThrottlingHigh`).
    static let throttlingGuide = 0.25

    /// The families a source asks of Prometheus for a subject.
    static func families(_ subject: KubeMetricsSubject, source: KubeChartSource) -> Set<KubeTabFamily> {
        let all: Set<KubeTabFamily>
        switch subject {
        case .pod: all = [.cpu, .memory, .throttling, .network, .restarts, .oom, .cpuPeak, .rss, .fs, .gpu]
        case .workload: all = [.cpu, .memory, .revisions, .restarts, .oom, .replicas, .hpa, .hpaMetrics, .gpu]
        case .hpa: all = [.hpa, .hpaMetrics]
        case .node: all = [.cpu, .memory, .nodePods, .conditions, .topCPU, .topMemory, .disks, .nodeNetwork, .gpu]
        case .namespace: all = [.cpu, .memory, .phases, .quota, .idle]
        }
        switch source {
        case .sampled: return []
        case .prometheus: return all
        case .mixed: return all.intersection(KubeTabFamily.prometheusOnly)
        }
    }

    // MARK: Shared

    /// A query's series by one of their labels' values.
    static func by(_ series: [KubeSeries]?, _ label: String) -> [String: [KubeSeriesPoint]] {
        var out: [String: [KubeSeriesPoint]] = [:]
        for one in series ?? [] { out[one.labels[label] ?? "", default: []] += one.points }
        return out.mapValues { $0.sorted { $0.time < $1.time } }
    }

    /// Points summed at each time any of them has.
    static func sum(_ lines: [[KubeSeriesPoint]]) -> [KubeSeriesPoint] {
        var sums: [Date: Double] = [:]
        for line in lines { for point in line { sums[point.time, default: 0] += point.value } }
        return sums.keys.sorted().map { KubeSeriesPoint(time: $0, value: sums[$0] ?? 0) }
    }

    /// What the caption says of a reading: whose, over what, at which step, the tier.
    static func caption(_ reading: KubeTabReading, window: KubeChartWindow?) -> String {
        guard let span = reading.span else { return "Asking Prometheus…" }
        var parts: [String] = []
        if let service = reading.service { parts.append("Prometheus \(service)") }
        let what = window.map { "\($0.kind == .zoom ? "Zoomed" : "Custom") \($0.title)" } ?? "the last \(KubePromQL.duration(span.end.timeIntervalSince(span.start)))"
        parts.append("\(what) at \(KubePromQL.duration(span.step))")
        if let tier = reading.tier { parts.append(tier.title + (tier == .rules ? " (5 min averages)" : "")) }
        if let scrape = reading.profile.scrape { parts.append("scrape \(KubePromQL.duration(scrape))") }
        return parts.joined(separator: " · ")
    }

    static func tier(_ reading: KubeTabReading, selection: Bool = false) -> String {
        (reading.tier?.title ?? "raw cAdvisor") + (selection ? reading.selection.map { " · \($0.title)" } ?? "" : "")
    }

    /// The top N's lines, as ranked: those the ranking named and the range
    /// query answered, largest first; nil where the ranking said nothing.
    static func ranked(_ reading: KubeTabReading, _ measure: String, by key: (KubeSeries) -> String?) -> [(id: String, points: [KubeSeriesPoint])] {
        var lines: [String: [KubeSeriesPoint]] = [:]
        for series in reading.results[measure + "Top"] ?? [] {
            guard let id = key(series) else { continue }
            lines[id, default: []] += series.points
        }
        return (reading.ranking?.names[measure] ?? []).compactMap { id in lines[id].map { (id, $0.sorted { $0.time < $1.time }) } }
    }

    /// What is said under the charts: why a family wasn't asked, what failed, Prometheus' notes.
    static func notes(_ reading: KubeTabReading, leaving: Set<KubeTabFamily> = []) -> [String] {
        var out = reading.refused.filter { !leaving.contains($0.key) }.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
        if let problem = reading.problem { out.append("Prometheus couldn't be read: \(problem)") }
        out += reading.notes
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Sentences once each, in order.
    static func unique(_ sentences: [String]) -> [String] {
        var seen = Set<String>()
        return sentences.filter { seen.insert($0).inserted }
    }

    static func data(
        id: String, title: String, unit: KubeChartUnit, series: [KubeChartSeries], span: KubePromSpan, stacked: Bool = false, tier: String,
        bands: [KubeChartBand] = [], stepped: Bool = false
    ) -> KubeChartData {
        KubeChartBuild.data(
            id: id, title: title, unit: unit, series: series, start: span.start, end: span.end, step: span.step, stacked: stacked, source: "Prometheus", tier: tier,
            breaksMarked: false, bands: bands, stepped: stepped)
    }

    /// The steps kube-state-metrics (or cAdvisor) saw an OOMKill in, as
    /// markers: on the step, not the second (its reason carries no time) —
    /// those a container's `lastState` already marks exactly within a step left out.
    static func ooms(_ reading: KubeTabReading, namesPods: Bool, exact: [KubeChartMarker] = []) -> [KubeChartMarker] {
        guard let span = reading.span else { return [] }
        var out: [KubeChartMarker] = []
        for series in reading.results["oom"] ?? [] {
            guard let container = series.labels["container"] else { continue }
            let pod = namesPods ? series.labels["pod"] : nil
            var last: Date?
            for point in series.points where point.value > 0 {
                // One marker a run of steps: the restart that followed one OOMKill.
                if let last, point.time.timeIntervalSince(last) <= span.step * 1.5 {
                    continue
                }
                last = point.time
                let from = point.time.addingTimeInterval(-span.step)
                if exact.contains(where: { $0.kind == .oom && $0.container == container && abs($0.time.timeIntervalSince(point.time)) <= span.step }) { continue }
                let who = pod.map { "\($0)/\(container)" } ?? container
                out.append(
                    KubeChartMarker(
                        id: "prom.oom.\(pod ?? "").\(container).\(Int(point.time.timeIntervalSince1970))", kind: .oom, time: point.time,
                        title: "\(who): OOMKilled between \(KubeChartTime.clock(from)) and \(KubeChartTime.clock(point.time))", container: container,
                        detail: "kube-state-metrics saw the container restart after an OOMKill in this step; it keeps only the last reason, never its time.",
                        opens: .previousLog(pod: pod, container: container)))
            }
        }
        return out
    }

    /// A counter's changes a step, as a stepped count.
    static func restartsChart(id: String, _ reading: KubeTabReading, span: KubePromSpan) -> KubePodCharts.Chart? {
        guard let series = reading.results["restarts"] else { return nil }
        let points = sum(series.map(\.points)).map { KubeSeriesPoint(time: $0.time, value: $0.value.rounded()) }
        let total = Int(points.reduce(0) { $0 + $1.value })
        return KubePodCharts.Chart(
            data: data(id: id, title: "Restarts", unit: .count, series: [KubeChartSeries(id: "restarts", name: "restarts", points: points)], span: span, tier: "kube-state-metrics", stepped: true),
            headline: "\(total) in range")
    }

    // MARK: A pod

    /// A pod's charts, every one from Prometheus.
    static func pod(namespace: String, pod name: String, object: [String: Any], reading: KubeTabReading, changes: KubeChartChanges, window: KubeChartWindow?)
        -> KubePodCharts
    {
        let containers = KubePodCharts.containers(of: object)
        guard let span = reading.span else {
            return KubePodCharts(range: .hour, pod: [], sections: [], caption: caption(reading, window: window), span: "", hasSamples: false, notes: notes(reading))
        }
        let subject = "\(namespace).\(name)"
        let tier = tier(reading)
        let cpu = by(reading.results["cpu"], "container")
        let memory = by(reading.results["memory"], "container")
        var names = containers.map(\.name)
        for extra in Set(cpu.keys).union(memory.keys).subtracting(names).sorted() where !extra.isEmpty { names.append(extra) }
        func reference(_ id: String, _ role: KubeChartRole, _ value: Double?) -> KubeChartSeries? {
            KubeChartBuild.reference(id, role.label, role, value, at: span.end)
        }
        func total(_ value: (KubePodCharts.Container) -> Double?) -> Double? {
            guard !containers.isEmpty else { return nil }
            var sum = 0.0
            for container in containers {
                guard let one = value(container) else { return nil }
                sum += one
            }
            return sum
        }
        let cpuRequest = total(\.cpuRequest)
        let cpuLimit = total(\.cpuLimit)
        let memoryRequest = total(\.memoryRequest)
        let memoryLimit = total(\.memoryLimit)
        let cpuStack = names.map { KubeChartSeries(id: $0, name: $0, points: cpu[$0] ?? []) }.filter { !$0.points.isEmpty }
        let memoryStack = names.map { KubeChartSeries(id: $0, name: $0, points: memory[$0] ?? []) }.filter { !$0.points.isEmpty }
        let podCPU = sum(cpuStack.map(\.points)).last?.value
        let podMemory = sum(memoryStack.map(\.points)).last?.value
        var podCharts = [
            KubePodCharts.Chart(
                data: data(
                    id: "pod.\(subject).cpu", title: "CPU", unit: .cores,
                    series: cpuStack + [reference("request", .request, cpuRequest), reference("limit", .limit, cpuLimit)].compactMap { $0 }, span: span,
                    stacked: cpuStack.count > 1, tier: tier),
                headline: podCPU.map { "\(KubeMetricsFormat.cpu($0)) now" }, chips: KubePodCharts.cpuChips(podCPU, request: cpuRequest, limit: cpuLimit)),
            KubePodCharts.Chart(
                data: data(
                    id: "pod.\(subject).memory", title: "Memory", unit: .bytes,
                    series: memoryStack + [reference("request", .request, memoryRequest), reference("limit", .limit, memoryLimit)].compactMap { $0 }, span: span,
                    stacked: memoryStack.count > 1, tier: tier),
                headline: podMemory.map { "\(KubeMetricsFormat.memory($0)) now" },
                chips: KubePodCharts.memoryChips(podMemory, request: memoryRequest, limit: memoryLimit)),
        ]
        podCharts += only(namespace: namespace, pod: name, reading: reading, span: span)
        let throttling = by(reading.results["throttling"], "container")
        let peaks = by(reading.results["cpuPeak"], "container")
        let rss = by(reading.results["rss"], "container")
        let sections = names.map { container -> KubePodCharts.Section in
            let spec = containers.first { $0.name == container }
            let id = "container.\(subject).\(container)"
            let cpuNow = cpu[container]?.last?.value
            let memoryNow = memory[container]?.last?.value
            var charts = [
                KubePodCharts.Chart(
                    data: data(
                        id: id + ".cpu", title: "CPU", unit: .cores,
                        series: [KubeChartSeries(id: "cpu", name: "CPU", points: cpu[container] ?? [])]
                            + (peaks[container].map { [KubeChartSeries(id: "peak", name: "peak", role: .peak, points: $0)] } ?? [])
                            + [reference("request", .request, spec?.cpuRequest), reference("limit", .limit, spec?.cpuLimit)].compactMap { $0 }, span: span, tier: tier),
                    headline: cpuNow.map { "\(KubeMetricsFormat.cpu($0)) now" }, chips: KubePodCharts.cpuChips(cpuNow, request: spec?.cpuRequest, limit: spec?.cpuLimit)),
                KubePodCharts.Chart(
                    data: data(
                        id: id + ".memory", title: "Memory", unit: .bytes,
                        series: [KubeChartSeries(id: "memory", name: "Working set", points: memory[container] ?? [])]
                            + (rss[container].map { [KubeChartSeries(id: "rss", name: "RSS", points: $0, offByDefault: true)] } ?? [])
                            + [reference("request", .request, spec?.memoryRequest), reference("limit", .limit, spec?.memoryLimit)].compactMap { $0 }, span: span,
                        tier: tier),
                    headline: memoryNow.map { "\(KubeMetricsFormat.memory($0)) now" },
                    chips: KubePodCharts.memoryChips(memoryNow, request: spec?.memoryRequest, limit: spec?.memoryLimit)),
            ]
            var notes: [String] = []
            if let chart = throttlingChart(container, spec: spec, throttling: throttling, reading: reading, span: span, id: id) {
                charts.append(chart)
            } else if spec != nil, spec?.cpuLimit == nil, reading.refused[.throttling] == nil {
                notes.append("No CPU limit: never throttled.")
            }
            if let chart = fsChart(container, reading: reading, span: span, id: id) { charts.append(chart) }
            return KubePodCharts.Section(container: container, charts: charts, notes: notes)
        }
        let hasSamples = (podCharts + sections.flatMap(\.charts)).contains { $0.data.usage.contains { !$0.points.isEmpty } }
        let charts = KubePodCharts(
            range: .hour, pod: podCharts, sections: sections, caption: caption(reading, window: window), span: window?.title ?? KubePromQL.duration(span.end.timeIntervalSince(span.start)),
            hasSamples: hasSamples || reading.read != nil,
            notes: notes(reading) + fsNotes(reading) + KubeGPUCharts.notes(reading, span: span, whose: .pod, window: window))
        var marked = changes
        marked.ooms = ooms(reading, namesPods: false, exact: KubeChartMarkers.pods(changes.restarts, namesPods: false))
        return KubeChartMarkers.mark(charts, pod: name, changes: marked, window: nil, now: span.end)
    }

    /// A container's throttling against the 25% guide, where it has a CPU limit.
    static func throttlingChart(
        _ container: String, spec: KubePodCharts.Container?, throttling: [String: [KubeSeriesPoint]], reading: KubeTabReading, span: KubePromSpan, id: String
    ) -> KubePodCharts.Chart? {
        guard reading.results["throttling"] != nil, spec?.cpuLimit != nil || spec == nil, let points = throttling[container] else { return nil }
        let latest = points.last?.value
        let chips = latest.map { [KubeChartChip(text: "\(Int(($0 * 100).rounded()))% throttled", alert: $0 > throttlingGuide)] } ?? []
        return KubePodCharts.Chart(
            data: data(
                id: id + ".throttling", title: "Throttling", unit: .ratio,
                series: [
                    KubeChartSeries(id: "throttling", name: "throttled periods", points: points),
                    KubeChartSeries(id: "guide", name: "25% guide", role: .guide, points: [KubeSeriesPoint(time: span.end, value: throttlingGuide)]),
                ], span: span, tier: "cAdvisor CFS periods"),
            headline: latest.map { "\(Int(($0 * 100).rounded()))% now" }, chips: chips)
    }

    /// C4: a container's ephemeral storage — cAdvisor's filesystem use, a
    /// device each once — against its ephemeral-storage limit; nil where
    /// the answer has none of it.
    static func fsChart(_ container: String, reading: KubeTabReading, span: KubePromSpan, id: String) -> KubePodCharts.Chart? {
        let arms = reading.tagged("fs")
        guard let points = by(arms["usage"], "container")[container], !points.isEmpty else { return nil }
        let limit = by(arms["limit"], "container")[container]?.last?.value
        let latest = points.last?.value
        var series = [KubeChartSeries(id: "fs", name: "filesystem used", points: points)]
        if let limit { series.append(KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: span.end, value: limit)])) }
        let percent = latest.flatMap { KubeMetricsFormat.percent($0, of: limit) }
        return KubePodCharts.Chart(
            data: data(id: id + ".fs", title: "Ephemeral storage", unit: .bytes, series: series, span: span, tier: "cAdvisor filesystem use"),
            headline: latest.map { KubeVolumeFormat.bytes($0) + " now" },
            chips: percent.map { [KubeChartChip(text: "\($0)% of limit", alert: $0 >= 90)] } ?? (limit == nil ? [KubeChartChip(text: "no limit")] : []))
    }

    /// C4's sentence where the probe found the metric but this pod's node
    /// reports none of it (a containerd node in a mixed cluster).
    static func fsNotes(_ reading: KubeTabReading) -> [String] {
        guard let answer = reading.results["fs"], !answer.contains(where: { $0.labels["overterm_s"] == "usage" && !$0.points.isEmpty }) else { return [] }
        return [KubeChartEmpty.noContainerFS.sentence]
    }

    /// What only Prometheus has of a pod: its network (P3) and its restarts (P4).
    static func only(namespace: String, pod name: String, reading: KubeTabReading, span: KubePromSpan) -> [KubePodCharts.Chart] {
        var out: [KubePodCharts.Chart] = []
        let subject = "\(namespace).\(name)"
        let network = reading.tagged("network")
        if reading.results["network"] != nil {
            let rx = sum((network["rx"] ?? []).map(\.points))
            let tx = sum((network["tx"] ?? []).map(\.points))
            let drops = sum((network["drops"] ?? []).map(\.points)).last?.value ?? 0
            let headline = [rx.last.map { "rx \(KubeChartUnit.bytesPerSecond.format($0.value))" }, tx.last.map { "tx \(KubeChartUnit.bytesPerSecond.format($0.value))" }]
                .compactMap { $0 }.joined(separator: " · ")
            out.append(
                KubePodCharts.Chart(
                    data: data(
                        id: "pod.\(subject).network", title: "Network", unit: .bytesPerSecond,
                        series: [KubeChartSeries(id: "rx", name: "received", points: rx), KubeChartSeries(id: "tx", name: "sent", points: tx)], span: span,
                        tier: "cAdvisor, the pod's sandbox"),
                    headline: headline.isEmpty ? nil : headline, chips: drops > 0 ? [KubeChartChip(text: String(format: "drops %.1f/s", drops), alert: true)] : []))
        }
        if let restarts = restartsChart(id: "pod.\(subject).restarts", reading, span: span) { out.append(restarts) }
        // G1–G3: its containers' GPUs, DCGM exporter's.
        out += KubeGPUCharts.charts(subject: "pod.\(subject)", reading: reading, span: span, whose: .pod)
        return out
    }

    /// Live with metrics-server: the sampled charts, and what only
    /// Prometheus has added — its throttling to each container, its
    /// network and restarts to the pod, its OOMKills marked.
    static func addOnly(_ sampled: KubePodCharts, namespace: String, pod name: String, object: [String: Any], reading: KubeTabReading?, changes: KubeChartChanges)
        -> KubePodCharts
    {
        guard let reading, let span = reading.span else {
            var charts = sampled
            if let reading { charts.notes += notes(reading) }
            return charts
        }
        let containers = KubePodCharts.containers(of: object)
        let throttling = by(reading.results["throttling"], "container")
        var extra = KubePodCharts(
            range: sampled.range, pod: only(namespace: namespace, pod: name, reading: reading, span: span),
            sections: sampled.sections.map { section in
                let spec = containers.first { $0.name == section.container }
                let id = "container.\(namespace).\(name).\(section.container)"
                let chart = throttlingChart(section.container, spec: spec, throttling: throttling, reading: reading, span: span, id: id)
                return KubePodCharts.Section(
                    container: section.container, charts: (chart.map { [$0] } ?? []) + (fsChart(section.container, reading: reading, span: span, id: id).map { [$0] } ?? []))
            }, caption: "", span: sampled.span, hasSamples: true)
        var marked = changes
        let earlier = ooms(reading, namesPods: false, exact: KubeChartMarkers.pods(changes.restarts, namesPods: false))
        marked.ooms = earlier
        extra = KubeChartMarkers.mark(extra, pod: name, changes: marked, window: nil, now: span.end)
        // The OOMKills Prometheus saw, on the sampled CPU and memory too (C2,
        // P2), as a workload's are: the pod's charts every container's, a
        // container's its own.
        func withOOMs(_ chart: KubePodCharts.Chart, container: String?) -> KubePodCharts.Chart {
            guard chart.data.id.hasSuffix(".cpu") || chart.data.id.hasSuffix(".memory") else { return chart }
            let more = earlier.filter { container == nil || $0.container == container }
            guard !more.isEmpty else { return chart }
            var chart = chart
            chart.data = KubeChartMarkers.apply(more, eventsJoined: changes.eventsJoined, to: chart.data, now: chart.data.end)
            return chart
        }
        var charts = sampled
        charts.pod = charts.pod.map { withOOMs($0, container: nil) } + extra.pod
        charts.sections = zip(charts.sections, extra.sections).map { section, more in
            var section = section
            section.charts = section.charts.map { withOOMs($0, container: section.container) } + more.charts
            let spec = containers.first { $0.name == section.container }
            if !more.charts.contains(where: { $0.data.id.hasSuffix(".throttling") }), spec?.cpuLimit == nil, reading.refused[.throttling] == nil {
                section.notes.append("No CPU limit: never throttled.")
            }
            return section
        }
        charts.caption +=
            " · throttling, network, restarts and ephemeral storage from Prometheus over \(KubePromQL.duration(span.end.timeIntervalSince(span.start))) at \(KubePromQL.duration(span.step))"
        charts.notes += notes(reading) + fsNotes(reading) + KubeGPUCharts.notes(reading, span: span, whose: .pod, window: nil)
        return charts
    }

    // MARK: A workload

    /// A workload's charts from Prometheus: its pods chosen by owner (the
    /// rule, kube-state-metrics' owners, else their names) — its total and
    /// its top five as the ranking named them, Per pod as lines against the
    /// template's per-pod request and limit or Total stacked with "other"
    /// (the total less the five) against them × its replicas; by revision
    /// (a Deployment's ReplicaSets); its replicas from kube-state-metrics,
    /// its restarts; its HPA's.
    static func workload(_ input: KubeWorkloadCharts.Input, reading: KubeTabReading) -> KubeObjectCharts {
        guard let span = reading.span else {
            return KubeObjectCharts(range: .hour, groups: [], caption: caption(reading, window: input.window), span: "", hasSamples: false, notes: notes(reading))
        }
        let tier = tier(reading, selection: true)
        let subject = "workload.\(input.namespace).\(input.kind.lowercased()).\(input.name)"
        let (perPod, replicas) = KubeWorkloadCharts.template(input.object, kind: input.kind)
        let view = input.view ?? KubeWorkloadCharts.defaultView(pods: replicas)
        func usageChart(_ isCPU: Bool) -> KubePodCharts.Chart? {
            let measure = isCPU ? "cpu" : "memory"
            guard let answer = reading.results[measure] else { return nil }
            let unit: KubeChartUnit = isCPU ? .cores : .bytes
            let total = sum(answer.map(\.points))
            let top = ranked(reading, measure) { $0.labels["pod"] }
            var series: [KubeChartSeries]
            var stacked = false
            if view == .perPod, !top.isEmpty {
                series = top.map { KubeChartSeries(id: $0.id, name: $0.id, points: $0.points) }
            } else if top.isEmpty || (top.count == 1 && replicas <= 1) {
                series = [KubeChartSeries(id: "total", name: "total", points: total)]
            } else {
                series = top.map { KubeChartSeries(id: $0.id, name: $0.id, points: $0.points) }
                let other = KubeChartBuild.rest(total, minus: top.map(\.points))
                if replicas > top.count || other.contains(where: { $0.value > 1e-9 }) { series.append(KubeChartSeries(id: "other", name: "other", points: other)) }
                stacked = true
            }
            let request = isCPU ? perPod.cpuRequest : perPod.memoryRequest
            let limit = isCPU ? perPod.cpuLimit : perPod.memoryLimit
            let times = view == .total ? Double(replicas) : 1
            let suffix = view == .total ? " × \(replicas)" : " a pod"
            if view == .perPod || replicas > 0 {
                series += [
                    KubeChartBuild.reference("request", "request\(suffix) (template)", .request, request.map { $0 * times }, at: span.end),
                    KubeChartBuild.reference("limit", "limit\(suffix) (template)", .limit, limit.map { $0 * times }, at: span.end),
                ].compactMap { $0 }
            }
            let latest = total.last?.value
            let chips =
                isCPU
                ? KubePodCharts.cpuChips(latest, request: request.map { $0 * Double(replicas) }, limit: limit.map { $0 * Double(replicas) })
                : KubePodCharts.memoryChips(latest, request: request.map { $0 * Double(replicas) }, limit: limit.map { $0 * Double(replicas) })
            return KubePodCharts.Chart(
                data: data(id: "\(subject).\(measure)", title: isCPU ? "CPU" : "Memory", unit: unit, series: series, span: span, stacked: stacked, tier: tier),
                headline: latest.map { "total \(unit.format($0))" }, chips: chips)
        }
        var charts = [usageChart(true), usageChart(false)].compactMap { $0 }
        // W3: a Deployment's ReplicaSets, one line a revision, labelled from its History.
        if input.kind == "Deployment", let answer = reading.results["revisions"] {
            let byRevision = by(answer, "replicaset").filter { !$0.key.isEmpty }
            let prefix = input.name + "-"
            let series = byRevision.keys.sorted().map { replicaSet in
                let hash = replicaSet.hasPrefix(prefix) ? String(replicaSet.dropFirst(prefix.count)) : replicaSet
                return KubeChartSeries(
                    id: "rev:\(hash)", name: KubeWorkloadCharts.revisionName(hash, kind: input.kind, workload: input.name, revisions: input.revisions),
                    points: byRevision[replicaSet] ?? [])
            }
            if !series.isEmpty {
                charts.append(
                    KubePodCharts.Chart(
                        data: data(id: "\(subject).revisions", title: "CPU by revision", unit: .cores, series: series, span: span, tier: tier),
                        headline: "\(series.count) revision\(series.count == 1 ? "" : "s")"))
            }
        }
        // W4: its replicas as kube-state-metrics says them.
        let arms = reading.tagged("replicas")
        if !arms.isEmpty {
            func line(_ tag: String) -> [KubeSeriesPoint] { sum((arms[tag] ?? []).map(\.points)) }
            var series: [KubeChartSeries]
            if input.kind == "Job" {
                series = ["active", "succeeded", "failed"].map { KubeChartSeries(id: $0, name: $0, points: line($0)) }
            } else {
                let desired = line("desired")
                let available = line("available")
                var unavailable = line("unavailable")
                if arms["unavailable"] == nil {
                    let have = Dictionary(available.map { ($0.time, $0.value) }, uniquingKeysWith: { $1 })
                    unavailable = desired.compactMap { point in have[point.time].map { KubeSeriesPoint(time: point.time, value: max(0, point.value - $0)) } }
                }
                series = [KubeChartSeries(id: "available", name: "available", points: available), KubeChartSeries(id: "unavailable", name: "unavailable", points: unavailable)]
                if !desired.isEmpty { series.append(KubeChartSeries(id: "desired", name: "desired", role: .guide, points: desired)) }
            }
            let hpa = reading.tagged("hpa")
            if let min = hpa["min"]?.first?.points.last?.value {
                series.append(KubeChartSeries(id: "hpa.min", name: "HPA min", role: .allocatable, points: [KubeSeriesPoint(time: span.end, value: min)]))
            }
            if let max = hpa["max"]?.first?.points.last?.value { series.append(KubeChartSeries(id: "hpa.max", name: "HPA max", role: .limit, points: [KubeSeriesPoint(time: span.end, value: max)])) }
            charts.append(
                KubePodCharts.Chart(
                    data: data(
                        id: "\(subject).replicas", title: input.kind == "Job" ? "Pods" : "Replicas", unit: .count, series: series, span: span, tier: "kube-state-metrics",
                        stepped: true)))
        }
        if let restarts = restartsChart(id: "\(subject).restarts", reading, span: span) { charts.append(restarts) }
        var groups = [KubeObjectCharts.Group(title: input.kind, charts: charts)]
        if let hpa = input.hpa {
            let hpaCharts = hpaCharts(namespace: input.namespace, name: hpa.name, reading: reading, span: span)
            if !hpaCharts.isEmpty { groups.append(KubeObjectCharts.Group(title: "Autoscaler \(hpa.name)", charts: hpaCharts)) }
        }
        // G1–G3: its pods' GPUs, after its own charts.
        let gpus = KubeGPUCharts.group(subject: subject, reading: reading, whose: .workload, window: input.window)
        if let group = gpus.group { groups.insert(group, at: 1) }
        let said = unique(notes(reading) + gpus.notes)
        let hasSamples = charts.contains { $0.data.usage.contains { !$0.points.isEmpty } }
        let built = KubeObjectCharts(
            range: .hour, groups: groups, caption: caption(reading, window: input.window), span: input.window?.title ?? KubePromQL.duration(span.end.timeIntervalSince(span.start)),
            hasSamples: hasSamples || reading.read != nil, notes: said, view: view)
        var changes = input.changes
        changes.ooms = ooms(reading, namesPods: true, exact: KubeChartMarkers.pods(changes.restarts, namesPods: true))
        return KubeChartMarkers.mark(built, changes: changes, window: nil, now: span.end)
    }

    /// Live with metrics-server: the sampled charts, its restarts (W5) and OOMKills from Prometheus added.
    static func addOnly(_ sampled: KubeObjectCharts, subject: String, reading: KubeTabReading?, changes: KubeChartChanges, namesPods: Bool) -> KubeObjectCharts {
        guard let reading, let span = reading.span else {
            var charts = sampled
            if let reading { charts.notes += notes(reading) }
            return charts
        }
        var charts = sampled
        if var first = charts.groups.first, let restarts = restartsChart(id: "\(subject).restarts", reading, span: span) {
            var changes = changes
            changes.ooms = []
            let marked = KubeChartMarkers.mark(
                KubeObjectCharts(range: sampled.range, groups: [KubeObjectCharts.Group(title: first.title, charts: [restarts])], caption: "", span: "", hasSamples: true),
                changes: changes, window: nil, now: span.end)
            first.charts += marked.groups.first?.charts ?? []
            charts.groups[0] = first
        }
        // The OOMKills Prometheus saw, on the usage charts too.
        let more = ooms(reading, namesPods: namesPods, exact: KubeChartMarkers.pods(changes.restarts, namesPods: namesPods))
        if !more.isEmpty, var first = charts.groups.first {
            first.charts = first.charts.map { chart in
                guard chart.data.id.hasSuffix(".cpu") || chart.data.id.hasSuffix(".memory") else { return chart }
                var chart = chart
                chart.data = KubeChartMarkers.apply(more, eventsJoined: changes.eventsJoined, to: chart.data, now: span.end)
                return chart
            }
            charts.groups[0] = first
        }
        charts.caption += " · restarts from Prometheus over \(KubePromQL.duration(span.end.timeIntervalSince(span.start)))"
        charts.notes += notes(reading)
        return charts
    }

    // MARK: An HPA

    static func hpaCharts(namespace: String, name: String, reading: KubeTabReading, span: KubePromSpan) -> [KubePodCharts.Chart] {
        let arms = reading.tagged("hpa")
        guard !arms.isEmpty else { return [] }
        let subject = "hpa.\(namespace).\(name)"
        func line(_ tag: String) -> [KubeSeriesPoint] { sum((arms[tag] ?? []).map(\.points)) }
        let current = line("current")
        var series = [KubeChartSeries(id: "current", name: "current", points: current), KubeChartSeries(id: "desired", name: "desired", points: line("desired"))]
        let min = line("min")
        let max = line("max")
        if !min.isEmpty { series.append(KubeChartSeries(id: "min", name: "min", role: .allocatable, points: min)) }
        if !max.isEmpty { series.append(KubeChartSeries(id: "max", name: "max", role: .limit, points: max)) }
        let scaled = KubeHPACharts.scales(current, now: span.end)
        var chips: [KubeChartChip] = []
        if scaled > KubeHPACharts.flapping { chips.append(KubeChartChip(text: "flapping: \(scaled) scales in 1h", alert: true)) }
        let headline = current.last.map { "\(Int($0.value)) now" + (min.last.flatMap { low in max.last.map { " · \(Int(low.value))–\(Int($0.value))" } } ?? "") }
        var out = [
            KubePodCharts.Chart(
                data: data(id: "\(subject).replicas", title: "Replicas", unit: .count, series: series, span: span, tier: "kube-state-metrics", stepped: true),
                headline: headline, chips: chips)
        ]
        // H2: each metric against its target.
        let metrics = reading.tagged("hpaMetrics")
        let names = Set((metrics["current"] ?? []).compactMap { $0.labels["metric_name"] }).sorted()
        for metric in names {
            let now = sum((metrics["current"] ?? []).filter { $0.labels["metric_name"] == metric }.map(\.points))
            let target = sum((metrics["target"] ?? []).filter { $0.labels["metric_name"] == metric }.map(\.points))
            var lines = [KubeChartSeries(id: "current", name: "current", points: now)]
            if !target.isEmpty { lines.append(KubeChartSeries(id: "target", name: "target", role: .request, points: target)) }
            let share = now.last.flatMap { current in target.last.flatMap { KubeMetricsFormat.percent(current.value, of: $0.value) } }
            out.append(
                KubePodCharts.Chart(
                    data: data(id: "\(subject).\(KubeHPACharts.slug(metric))", title: metric, unit: .count, series: lines, span: span, tier: "kube-state-metrics", stepped: true),
                    headline: now.last.map { "\(KubeChartUnit.count.format($0.value)) now" },
                    chips: share.map { [KubeChartChip(text: "\($0)% of target", alert: $0 > 100)] } ?? []))
        }
        return out
    }

    static func hpa(namespace: String, name: String, reading: KubeTabReading, changes: KubeChartChanges, window: KubeChartWindow?) -> KubeObjectCharts {
        guard let span = reading.span else {
            return KubeObjectCharts(range: .hour, groups: [], caption: caption(reading, window: window), span: "", hasSamples: false, notes: notes(reading))
        }
        let charts = hpaCharts(namespace: namespace, name: name, reading: reading, span: span)
        let built = KubeObjectCharts(
            range: .hour, groups: [KubeObjectCharts.Group(title: "HorizontalPodAutoscaler", charts: charts)], caption: caption(reading, window: window),
            span: window?.title ?? KubePromQL.duration(span.end.timeIntervalSince(span.start)), hasSamples: !charts.isEmpty || reading.read != nil, notes: notes(reading))
        return KubeChartMarkers.mark(built, changes: changes, window: nil, now: span.end)
    }

    // MARK: A node

    /// A condition's stretches: its runs of answered steps.
    static func bands(_ reading: KubeTabReading, span: KubePromSpan) -> [KubeChartBand] {
        var out: [KubeChartBand] = []
        for series in reading.results["conditions"] ?? [] {
            let title = series.labels["condition"] ?? "condition"
            for run in KubePrometheusReader.segments(series.points.filter { $0.value > 0 }, step: span.step) {
                guard let first = run.first, let last = run.last else { continue }
                out.append(KubeChartBand(id: "\(title).\(Int(first.time.timeIntervalSince1970))", title: title, start: first.time, end: last.time.addingTimeInterval(span.step)))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static let topPodsTitle = "Top pods (by the range's mean)"
    static let nodeExporterTitle = "Disks and network (node-exporter)"
    /// A node's families read only while their group is on screen, by the
    /// group's title: its top pods (K3, a series a pod on the node), its
    /// disks and network (K6, K7, the lowest of its charts: scrolled to).
    static let readWhenShown: [String: Set<KubeTabFamily>] = [topPodsTitle: [.topCPU, .topMemory], nodeExporterTitle: [.disks, .nodeNetwork]]

    static func node(node: String, facts: KubeNodeFacts, reading: KubeTabReading, changes: KubeChartChanges, window: KubeChartWindow?) -> KubeObjectCharts {
        guard let span = reading.span else {
            return KubeObjectCharts(range: .hour, groups: [], caption: caption(reading, window: window), span: "", hasSamples: false, notes: notes(reading))
        }
        let subject = "node.\(node)"
        let bands = bands(reading, span: span)
        let tier = tier(reading)
        func chart(_ isCPU: Bool) -> KubePodCharts.Chart {
            let unit: KubeChartUnit = isCPU ? .cores : .bytes
            let arms = reading.tagged(isCPU ? "cpu" : "memory")
            // Without kube-state-metrics, the query is the usage alone, untagged.
            let usage = sum((arms["usage"] ?? arms[""] ?? []).map(\.points))
            let requested = sum((arms["request"] ?? []).map(\.points))
            var series = [KubeChartSeries(id: isCPU ? "cpu" : "memory", name: isCPU ? "CPU" : "Memory", points: usage)]
            // K2: the node's own memory in use (node-exporter), beside its pods'.
            let total = sum((arms["total"] ?? []).map(\.points))
            if !isCPU, !total.isEmpty { series.append(KubeChartSeries(id: "nodeTotal", name: "node total", points: total)) }
            if !requested.isEmpty { series.append(KubeChartSeries(id: "requested", name: "requested", role: .request, points: requested)) }
            let allocatable = isCPU ? facts.allocatable?.cpu : facts.allocatable?.memory
            if let allocatable, allocatable > 0 {
                series.append(KubeChartSeries(id: "allocatable", name: "allocatable", role: .allocatable, points: [KubeSeriesPoint(time: span.end, value: allocatable)]))
            }
            if let capacity = isCPU ? facts.capacity?.cpu : facts.capacity?.memory, capacity > 0 {
                series.append(KubeChartSeries(id: "capacity", name: "capacity", role: .capacity, points: [KubeSeriesPoint(time: span.end, value: capacity)]))
            }
            let latest = usage.last?.value
            var chips: [KubeChartChip] = []
            if let latest, let percent = KubeMetricsFormat.percent(latest, of: allocatable) { chips.append(KubeChartChip(text: "\(percent)% of allocatable", alert: percent >= 90)) }
            if let last = requested.last?.value, let percent = KubeMetricsFormat.percent(last, of: allocatable) {
                chips.append(KubeChartChip(text: "requests \(percent)% of allocatable", alert: percent > 100))
            }
            return KubePodCharts.Chart(
                data: data(id: "\(subject).\(isCPU ? "cpu" : "memory")", title: isCPU ? "CPU" : "Memory", unit: unit, series: series, span: span, tier: tier, bands: bands),
                headline: latest.map { "\(unit.format($0)) now" }, chips: chips)
        }
        var charts: [KubePodCharts.Chart] = []
        if reading.results["cpu"] != nil { charts.append(chart(true)) }
        if reading.results["memory"] != nil { charts.append(chart(false)) }
        if let pods = reading.results["pods"] {
            let count = sum(pods.map(\.points))
            var series = [KubeChartSeries(id: "pods", name: "pods", points: count)]
            if let most = facts.allocatablePods {
                series.append(KubeChartSeries(id: "allocatable", name: "allocatable", role: .allocatable, points: [KubeSeriesPoint(time: span.end, value: Double(most))]))
            }
            let percent = count.last.flatMap { KubeMetricsFormat.percent($0.value, of: facts.allocatablePods.map(Double.init)) }
            charts.append(
                KubePodCharts.Chart(
                    data: data(id: "\(subject).pods", title: "Pods", unit: .count, series: series, span: span, tier: "kube-state-metrics, active pods", stepped: true),
                    headline: count.last.map { "\(Int($0.value)) active" }, chips: percent.map { [KubeChartChip(text: "\($0)% of allocatable", alert: $0 >= 90)] } ?? []))
        }
        var groups = [KubeObjectCharts.Group(title: "Node", charts: charts)]
        // G1–G3: its GPUs, DCGM exporter's, after its own charts.
        let gpus = KubeGPUCharts.group(subject: subject, reading: reading, whose: .node, window: window)
        if let group = gpus.group { groups.append(group) }
        // K3: its largest pods by the range's mean, stacked.
        func top(_ id: String, _ isCPU: Bool) -> KubePodCharts.Chart? {
            guard let answer = reading.results[id], !answer.isEmpty else { return nil }
            let lines = answer.map { series -> (name: String, points: [KubeSeriesPoint]) in
                let namespace = series.labels["namespace"] ?? ""
                let pod = series.labels["pod"] ?? ""
                return (namespace + "/" + pod, series.points)
            }
            .sorted { KubeChartBuild.mean($0.points, since: .distantPast) > KubeChartBuild.mean($1.points, since: .distantPast) }
            var series = lines.prefix(KubeNodeCharts.topPods).map { KubeChartSeries(id: $0.name, name: $0.name.split(separator: "/").last.map(String.init) ?? $0.name, points: $0.points) }
            let rest = lines.dropFirst(KubeNodeCharts.topPods).map(\.points)
            if !rest.isEmpty { series.append(KubeChartSeries(id: "other", name: "other", points: sum(rest))) }
            return KubePodCharts.Chart(
                data: data(
                    id: "\(subject).top.\(isCPU ? "cpu" : "memory")", title: isCPU ? "Top pods' CPU" : "Top pods' memory", unit: isCPU ? .cores : .bytes, series: series,
                    span: span, stacked: true, tier: tier))
        }
        // Asked only while its group is on screen: the group is there to be
        // scrolled to. Whether it exists is the profile's to say, never the
        // reading's: a refusal is recorded only for what is asked, so a group
        // dropped on one would come back once off screen, and loop.
        let tops = [top("topCPU", true), top("topMemory", false)].compactMap { $0 }
        if KubeTabQueries.nodeLabel(reading.profile) != nil {
            groups.append(
                KubeObjectCharts.Group(
                    title: topPodsTitle, charts: tops, readsWhenShown: true, pending: reading.results["topCPU"] == nil && reading.results["topMemory"] == nil))
        }
        let exporter = nodeExporterGroup(node: node, reading: reading, profile: reading.profile)
        if let group = exporter.group { groups.append(group) }
        let built = KubeObjectCharts(
            range: .hour, groups: groups, caption: caption(reading, window: window), span: window?.title ?? KubePromQL.duration(span.end.timeIntervalSince(span.start)),
            hasSamples: charts.contains { $0.data.usage.contains { !$0.points.isEmpty } } || reading.read != nil,
            notes: unique(notes(reading) + gpus.notes + exporter.notes))
        return KubeChartMarkers.mark(built, changes: changes, window: nil, now: span.end)
    }

    /// K6 and K7 (metrics.md 2.8, 4.6; stage M8b): a node's disks — a
    /// chart a mount, its used bytes against its size — and its network,
    /// received and sent, node-exporter's mapped to the node by
    /// `node_uname_info`. A group of their own, read only while on screen;
    /// none where the profile found node-exporter unmapped (the sentence
    /// says so instead). `profile`: the reading's, or the page's where
    /// nothing is read yet (Live, the group off screen).
    static func nodeExporterGroup(node: String, reading: KubeTabReading?, profile: KubePromProfile) -> (group: KubeObjectCharts.Group?, notes: [String]) {
        // Decided by the profile alone, whether shown or not (as the top pods'):
        // the plan refuses only what is asked, so a group dropped on the
        // reading's refusals would come back off screen, be shown, and loop.
        if profile.known, !profile.nodeExporterMapped { return (nil, [KubeChartEmpty.nodeExporterUnmapped.sentence]) }
        if profile.known, !profile.mayHave(KubePromQL.nodeFilesystemMetric), !profile.mayHave(KubePromQL.nodeNetworkMetric) {
            return (nil, [KubeChartEmpty.nodeExporterNoFilesystems.sentence, KubeChartEmpty.nodeExporterNoNetwork.sentence])
        }
        guard let reading, let span = reading.span else {
            return (KubeObjectCharts.Group(title: nodeExporterTitle, charts: [], readsWhenShown: true, pending: true), [])
        }
        let subject = "node.\(node)"
        var charts: [KubePodCharts.Chart] = []
        var notes: [String] = []
        if reading.results["disks"] != nil {
            let disks = diskCharts(subject: subject, reading: reading, span: span)
            if disks.isEmpty { notes.append(KubeChartEmpty.nodeDisksNone.sentence) }
            charts += disks
        }
        if let network = nodeNetworkChart(subject: subject, reading: reading, span: span) {
            charts.append(network)
        } else if reading.results["nodeNetwork"] != nil {
            notes.append(KubeChartEmpty.nodeNetworkNone.sentence)
        }
        let asked = reading.results["disks"] != nil || reading.results["nodeNetwork"] != nil
        return (KubeObjectCharts.Group(title: nodeExporterTitle, charts: charts, readsWhenShown: true, pending: !asked), notes)
    }

    /// K6: a chart a mount (`/` first), used against size.
    static func diskCharts(subject: String, reading: KubeTabReading, span: KubePromSpan) -> [KubePodCharts.Chart] {
        let arms = reading.tagged("disks")
        let used = by(arms["used"], "mountpoint")
        let size = by(arms["size"], "mountpoint")
        return used.keys.filter { !$0.isEmpty && !(used[$0] ?? []).isEmpty }.sorted().map { mount in
            let points = used[mount] ?? []
            let total = size[mount]?.last?.value
            var series = [KubeChartSeries(id: "used", name: "used", points: points)]
            if let total, total > 0 {
                series.append(KubeChartSeries(id: "size", name: "size", role: .capacity, points: [KubeSeriesPoint(time: span.end, value: total)]))
            }
            let latest = points.last?.value
            let percent = latest.flatMap { KubeMetricsFormat.percent($0, of: total) }
            let headline = latest.map { value in KubeVolumeFormat.bytes(value) + (total.map { " of " + KubeVolumeFormat.bytes($0) } ?? "") }
            return KubePodCharts.Chart(
                data: data(
                    id: "\(subject).disk.\(mount == "/" ? "root" : mount.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "."))",
                    title: "Disk \(mount)", unit: .bytes, series: series, span: span, tier: "node-exporter"),
                headline: headline, chips: percent.map { [KubeChartChip(text: "\($0)% used", alert: $0 >= 90)] } ?? [])
        }
    }

    /// K7: the node's own interfaces' received and sent bytes a second.
    static func nodeNetworkChart(subject: String, reading: KubeTabReading, span: KubePromSpan) -> KubePodCharts.Chart? {
        guard reading.results["nodeNetwork"] != nil else { return nil }
        let arms = reading.tagged("nodeNetwork")
        let rx = sum((arms["rx"] ?? []).map(\.points))
        let tx = sum((arms["tx"] ?? []).map(\.points))
        guard !rx.isEmpty || !tx.isEmpty else { return nil }
        let headline = [rx.last.map { "rx \(KubeChartUnit.bytesPerSecond.format($0.value))" }, tx.last.map { "tx \(KubeChartUnit.bytesPerSecond.format($0.value))" }]
            .compactMap { $0 }.joined(separator: " · ")
        return KubePodCharts.Chart(
            data: data(
                id: "\(subject).network", title: "Network", unit: .bytesPerSecond,
                series: [KubeChartSeries(id: "rx", name: "received", points: rx), KubeChartSeries(id: "tx", name: "sent", points: tx)], span: span,
                tier: "node-exporter, the node's own interfaces"),
            headline: headline.isEmpty ? nil : headline)
    }

    /// Live with metrics-server: a node's sampled charts, its disks and
    /// network from Prometheus added as their own group.
    static func addNodeExporter(_ sampled: KubeObjectCharts, node: String, reading: KubeTabReading?, profile: KubePromProfile) -> KubeObjectCharts {
        var charts = sampled
        let known = reading.flatMap { $0.profile.known ? $0.profile : nil } ?? profile
        let exporter = nodeExporterGroup(node: node, reading: reading, profile: known)
        if let group = exporter.group { charts.groups.append(group) }
        charts.notes = unique(charts.notes + exporter.notes + (reading.map { notes($0) } ?? []))
        return charts
    }

    // MARK: A namespace

    /// A namespace's charts from Prometheus (N1, N2, N4 and N3's chip): its
    /// CPU and memory, its top eight workloads stacked as the ranking named
    /// them and "other" (the total less them: the rest, and pods of no
    /// workload), against its ResourceQuota's hard and used requests over
    /// time (kube-state-metrics'; else the quota read as the tab opened),
    /// what it requests but leaves idle on average over the range as a
    /// chip; its pods by phase.
    static func namespace(namespace: String, reading: KubeTabReading, quota looked: KubeQuota?, changes: KubeChartChanges, window: KubeChartWindow?)
        -> KubeObjectCharts
    {
        guard let span = reading.span else {
            return KubeObjectCharts(range: .hour, groups: [], caption: caption(reading, window: window), span: "", hasSamples: false, notes: notes(reading))
        }
        let subject = "namespace.\(namespace)"
        let tier = tier(reading, selection: true)
        let quota = quotaLines(reading)
        let idle = reading.tagged("idle")
        let length = window?.title ?? KubePromQL.duration(span.end.timeIntervalSince(span.start))
        func chart(_ isCPU: Bool) -> KubePodCharts.Chart? {
            let measure = isCPU ? "cpu" : "memory"
            guard let answer = reading.results[measure] else { return nil }
            let unit: KubeChartUnit = isCPU ? .cores : .bytes
            let total = sum(answer.map(\.points))
            let top = ranked(reading, measure) { series in
                series.labels["workload"].map { KubeTabQueries.kindTitle(series.labels["workload_type"] ?? "") + "/" + $0 }
            }
            var series = top.map { KubeChartSeries(id: $0.id, name: $0.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? $0.id, points: $0.points) }
            if series.isEmpty {
                series = [KubeChartSeries(id: "total", name: "total", points: total)]
            } else {
                let other = KubeChartBuild.rest(total, minus: top.map(\.points))
                if other.contains(where: { $0.value > 1e-9 }) { series.append(KubeChartSeries(id: "other", name: "other", points: other)) }
            }
            let hard = isCPU ? quota.cpuHard : quota.memoryHard
            let used = isCPU ? quota.cpuUsed : quota.memoryUsed
            var lastHard = hard.last?.value
            var lastUsed = used.last?.value
            if !hard.isEmpty {
                series.append(KubeChartSeries(id: "quota", name: "quota (requests)", role: .quota, points: hard))
                if !used.isEmpty { series.append(KubeChartSeries(id: "quota.used", name: "quota used", role: .guide, points: used)) }
            } else if let looked {
                lastHard = isCPU ? looked.cpuHard : looked.memoryHard
                lastUsed = isCPU ? looked.cpuUsed : looked.memoryUsed
                series += [
                    KubeChartBuild.reference("quota", "quota (requests)", .quota, lastHard, at: span.end),
                    KubeChartBuild.reference("quota.used", "quota used", .guide, lastUsed, at: span.end),
                ].compactMap { $0 }
            }
            var chips: [KubeChartChip] = []
            if let lastUsed, let lastHard, let percent = KubeMetricsFormat.percent(lastUsed, of: lastHard) {
                chips.append(KubeChartChip(text: "requests \(percent)% of quota", alert: percent >= 90))
            }
            if let wasted = idle[measure]?.first?.points.last?.value, wasted.isFinite, wasted > 0 {
                chips.append(KubeChartChip(text: "requested but idle: \(unit.format(wasted)) (avg, \(length))", alert: false))
            }
            let latest = total.last?.value
            return KubePodCharts.Chart(
                data: data(
                    id: "\(subject).\(measure)", title: isCPU ? "CPU" : "Memory", unit: unit, series: series, span: span,
                    stacked: series.filter { !$0.role.isReference }.count > 1, tier: tier),
                headline: latest.map { "total \(unit.format($0))" }, chips: chips)
        }
        var charts = [chart(true), chart(false)].compactMap { $0 }
        // N4: pods by phase, as kube-state-metrics says them.
        if let answer = reading.results["phases"] {
            let phases = by(answer, "phase")
            let series = KubePodPhase.order.compactMap { phase in phases[phase].map { KubeChartSeries(id: phase, name: phase, points: $0) } }
                .filter { $0.points.contains { $0.value > 0 } }
            if !series.isEmpty {
                charts.append(
                    KubePodCharts.Chart(
                        data: data(
                            id: "\(subject).phases", title: "Pods by phase", unit: .count, series: series, span: span, stacked: true, tier: "kube-state-metrics",
                            stepped: true)))
            }
        }
        var said = notes(reading)
        if quota.cpuHard.isEmpty, quota.memoryHard.isEmpty, looked?.isEmpty ?? true { said.append("No ResourceQuota on requests here: no quota line.") }
        let built = KubeObjectCharts(
            range: .hour, groups: [KubeObjectCharts.Group(title: "Namespace", charts: charts)], caption: caption(reading, window: window), span: length,
            hasSamples: charts.contains { $0.data.usage.contains { !$0.points.isEmpty } } || reading.read != nil, notes: said)
        return KubeChartMarkers.mark(built, changes: changes, window: nil, now: span.end)
    }

    /// A namespace's quota over time: the tightest hard request, and its use
    /// — `requests.cpu` before the bare `cpu` it stands for.
    static func quotaLines(_ reading: KubeTabReading) -> (cpuHard: [KubeSeriesPoint], cpuUsed: [KubeSeriesPoint], memoryHard: [KubeSeriesPoint], memoryUsed: [KubeSeriesPoint]) {
        let answer = reading.results["quota"] ?? []
        func line(_ resource: String, _ type: String) -> [KubeSeriesPoint] {
            for name in ["requests." + resource, resource] {
                let points = answer.filter { $0.labels["resource"] == name && $0.labels["type"] == type }.flatMap(\.points)
                if !points.isEmpty { return points.sorted { $0.time < $1.time } }
            }
            return []
        }
        return (line("cpu", "hard"), line("cpu", "used"), line("memory", "hard"), line("memory", "used"))
    }
}
