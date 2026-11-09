import Foundation

/// G1–G3 from DCGM exporter (docs/design/kubernetes/metrics.md, decision
/// 12; stage M8c): each GPU's utilisation, its framebuffer memory against
/// its total, its power and its temperature — per GPU on a node's tab, per
/// container on a pod's, by pod on a workload's; MIG instances named by
/// their profile; an allocated GPU idle over the whole range said plainly
/// (the costly case: held, paid for, unused). From the tab's one `gpu`
/// query (`KubePromQL.gpus`), whatever its source. Pure.
enum KubeGPUCharts {
    /// Whose GPUs: what a series is named by besides its GPU.
    enum Whose: Equatable, Sendable {
        /// A node's: each GPU, and the pods that held it.
        case node
        /// A pod's: each container's GPUs.
        case pod
        /// A workload's: each pod's.
        case workload
    }

    /// Never busier than this over the range, held: idle.
    static let idleAtMost = 0.05
    /// At most this many GPUs drawn a chart (metrics.md 6.3's 12 series).
    static let shownAtMost = 12
    static let groupTitle = "GPUs (DCGM exporter)"

    /// One GPU (or MIG instance) as the answer says it.
    struct GPU: Equatable, Sendable {
        var key: String
        var name: String
        var model: String?
        /// Who held it over the range: a node's pods, or the container or pod it is.
        var holders: [String] = []
        var utilisation: [KubeSeriesPoint] = []
        var used: [KubeSeriesPoint] = []
        /// Its framebuffer's size: used + free at one sample, never peaked.
        var size: [KubeSeriesPoint] = []
        var power: [KubeSeriesPoint] = []
        var temperature: [KubeSeriesPoint] = []

        /// Held by someone: on a pod's or a workload's tab always, on a node's when a pod label said so.
        var allocated: Bool { !holders.isEmpty }

        /// Its total framebuffer at the last reading.
        var total: Double? { size.last?.value }

        /// Held, read twice or more, and never above `idleAtMost`.
        var idle: Bool {
            allocated && utilisation.count >= 2 && utilisation.allSatisfy { $0.value <= KubeGPUCharts.idleAtMost }
        }
    }

    /// A series whose pod (or container) is DCGM exporter's own.
    private static func exporter(_ labels: [String: String], _ dcgm: KubePromProfile.DCGM) -> Bool {
        KubePromProfile.DCGM.isExporter(pod: labels[dcgm.pod], container: labels[dcgm.container])
    }

    /// The answer's GPUs, in order (index, MIG instance, then holder):
    /// a GPU's utilisation the device's, or — a MIG instance's, or where
    /// profiling metrics are on — its graphics engine's activity.
    static func gpus(_ reading: KubeTabReading, whose: Whose) -> [GPU] {
        guard let answer = reading.results["gpu"] else { return [] }
        let dcgm = reading.profile.dcgm ?? KubePromProfile.DCGM(podPrefix: "", namesPods: true, nodeLabel: nil, mig: false)
        var byKey: [String: GPU] = [:]
        var engine: [String: [KubeSeriesPoint]] = [:]
        var util: [String: [KubeSeriesPoint]] = [:]
        for series in answer {
            let labels = series.labels
            let index = labels["gpu"] ?? "?"
            let profile = labels["GPU_I_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
            let instance = labels["GPU_I_ID"].flatMap { $0.isEmpty ? nil : $0 }
            var device = "GPU \(index)"
            if let profile { device += " · MIG \(profile)" + (instance.map { " #\($0)" } ?? "") }
            let holder: String?
            let key: String
            switch whose {
            case .node:
                // The exporter's own target label is never a GPU's holder.
                let pod = labels[dcgm.pod].flatMap { $0.isEmpty || exporter(labels, dcgm) ? nil : $0 }
                holder = pod.map { pod in labels[dcgm.namespace].map { "\($0)/\(pod)" } ?? pod }
                key = device
            case .pod:
                holder = labels[dcgm.container].flatMap { $0.isEmpty ? nil : $0 } ?? "pod"
                key = "\(holder ?? "") · \(device)"
            case .workload:
                holder = labels[dcgm.pod].flatMap { $0.isEmpty || exporter(labels, dcgm) ? nil : $0 } ?? "pod"
                key = "\(holder ?? "") · \(device)"
            }
            var gpu = byKey[key] ?? GPU(key: key, name: whose == .node ? device : key, model: labels["modelName"].flatMap { $0.isEmpty ? nil : $0 })
            if let holder, !gpu.holders.contains(holder) { gpu.holders.append(holder) }
            let points = series.points.filter { $0.value.isFinite }
            switch labels["overterm_s"] {
            case "util": util[key, default: []] += points
            case "engine": engine[key, default: []] += points
            case "used": gpu.used += points
            case "total": gpu.size += points
            case "power": gpu.power += points
            case "temp": gpu.temperature += points
            default: break
            }
            byKey[key] = gpu
        }
        func sorted(_ points: [KubeSeriesPoint]) -> [KubeSeriesPoint] {
            // One GPU held by two pods in turn answers as two series: one line, a point a time.
            var seen: [Date: Double] = [:]
            for point in points { seen[point.time] = max(seen[point.time] ?? -.infinity, point.value) }
            return seen.keys.sorted().map { KubeSeriesPoint(time: $0, value: seen[$0] ?? 0) }
        }
        return byKey.values.map { gpu in
            var gpu = gpu
            let busy = engine[gpu.key].map(sorted) ?? []
            gpu.utilisation = busy.isEmpty ? sorted(util[gpu.key] ?? []) : busy
            gpu.used = sorted(gpu.used)
            gpu.size = sorted(gpu.size)
            gpu.power = sorted(gpu.power)
            gpu.temperature = sorted(gpu.temperature)
            gpu.holders.sort()
            return gpu
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    /// The charts — utilisation, memory, power, temperature — those the
    /// answer has; none where it wasn't asked.
    static func charts(subject: String, reading: KubeTabReading, span: KubePromSpan, whose: Whose) -> [KubePodCharts.Chart] {
        let all = gpus(reading, whose: whose)
        guard !all.isEmpty else { return [] }
        // Past twelve, the busiest (the idle held ones are said in a note).
        let shown =
            all.count <= shownAtMost
            ? all : Array(all.sorted { KubeChartBuild.mean($0.utilisation, since: .distantPast) > KubeChartBuild.mean($1.utilisation, since: .distantPast) }.prefix(shownAtMost))
        let tier = "DCGM exporter" + (reading.profile.has(KubePromProfile.dcgmEngineActive) ? " · engine activity (profiling)" : "")
        let models = Array(Set(shown.compactMap(\.model))).sorted()
        var out: [KubePodCharts.Chart] = []
        func line(_ gpu: GPU, _ points: [KubeSeriesPoint]) -> KubeChartSeries { KubeChartSeries(id: gpu.key, name: gpu.name, points: points) }

        let busy = shown.filter { !$0.utilisation.isEmpty }
        if !busy.isEmpty {
            let latest = busy.compactMap { $0.utilisation.last?.value }
            let mean = latest.isEmpty ? nil : latest.reduce(0, +) / Double(latest.count)
            let idle = all.filter(\.idle).count
            var chips: [KubeChartChip] = []
            if idle > 0 { chips.append(KubeChartChip(text: "\(idle) allocated GPU\(idle == 1 ? "" : "s") idle", alert: true)) }
            out.append(
                KubePodCharts.Chart(
                    data: KubePromTabCharts.data(
                        id: "\(subject).gpu.utilisation", title: "GPU utilisation", unit: .ratio, series: busy.map { line($0, $0.utilisation) }, span: span,
                        tier: tier),
                    headline: mean.map { "\(KubeChartUnit.ratio.format($0)) now" + (models.isEmpty ? "" : " · " + models.joined(separator: ", ")) }, chips: chips))
        }
        let memory = shown.filter { !$0.used.isEmpty }
        if !memory.isEmpty {
            var series = memory.map { line($0, $0.used) }
            let totals = memory.compactMap(\.total)
            // One total a GPU where every GPU has the same (else each GPU's own is in its tooltip).
            if let first = totals.first, totals.count == memory.count, totals.allSatisfy({ abs($0 - first) < 1_048_576 }) {
                series.append(KubeChartSeries(id: "total", name: memory.count == 1 ? "total" : "total a GPU", role: .capacity, points: [KubeSeriesPoint(time: span.end, value: first)]))
            }
            let used = memory.compactMap { $0.used.last?.value }.reduce(0, +)
            let total = totals.count == memory.count ? totals.reduce(0, +) : nil
            let percent = KubeMetricsFormat.percent(used, of: total)
            out.append(
                KubePodCharts.Chart(
                    data: KubePromTabCharts.data(id: "\(subject).gpu.memory", title: "GPU memory", unit: .bytes, series: series, span: span, tier: "DCGM exporter, framebuffer"),
                    headline: KubeVolumeFormat.bytes(used) + (total.map { " of " + KubeVolumeFormat.bytes($0) } ?? ""),
                    chips: percent.map { [KubeChartChip(text: "\($0)% of total", alert: $0 >= 95)] } ?? []))
        }
        let power = shown.filter { !$0.power.isEmpty }
        if !power.isEmpty {
            let now = power.compactMap { $0.power.last?.value }.reduce(0, +)
            out.append(
                KubePodCharts.Chart(
                    data: KubePromTabCharts.data(id: "\(subject).gpu.power", title: "GPU power", unit: .watts, series: power.map { line($0, $0.power) }, span: span, tier: "DCGM exporter"),
                    headline: "\(KubeChartUnit.watts.format(now)) now"))
        }
        let temperature = shown.filter { !$0.temperature.isEmpty }
        if !temperature.isEmpty {
            let hottest = temperature.compactMap { $0.temperature.last?.value }.max()
            out.append(
                KubePodCharts.Chart(
                    data: KubePromTabCharts.data(
                        id: "\(subject).gpu.temperature", title: "GPU temperature", unit: .celsius, series: temperature.map { line($0, $0.temperature) }, span: span,
                        tier: "DCGM exporter"),
                    headline: hottest.map { "hottest \(KubeChartUnit.celsius.format($0))" }))
        }
        return out
    }

    /// What is said under them: each allocated GPU idle over the whole
    /// range, MIG without profiling metrics, nothing answered, the GPUs past twelve.
    static func notes(_ reading: KubeTabReading, span: KubePromSpan, whose: Whose, window: KubeChartWindow?) -> [String] {
        guard let answer = reading.results["gpu"] else { return [] }
        guard !answer.isEmpty else { return [KubeChartEmpty.gpuNone.sentence] }
        let all = gpus(reading, whose: whose)
        let length = window?.title ?? "the last " + KubePromQL.duration(span.end.timeIntervalSince(span.start))
        var out: [String] = []
        for gpu in all where gpu.idle {
            let peak = gpu.utilisation.map(\.value).max() ?? 0
            let held = whose == .node ? ", held by \(gpu.holders.joined(separator: ", "))," : ""
            out.append(
                "\(gpu.name)\(held) was idle over \(length) (never above \(KubeChartUnit.ratio.format(max(peak, 0)))): allocated, and paid for, but unused.")
        }
        if reading.profile.dcgm?.mig == true, !reading.profile.has(KubePromProfile.dcgmEngineActive), all.contains(where: { $0.name.contains("MIG") }) {
            out.append(KubeChartEmpty.migNeedsProfiling.sentence)
        }
        if all.count > shownAtMost { out.append("\(all.count - shownAtMost) GPUs more aren't drawn: the \(shownAtMost) busiest are.") }
        return out
    }

    /// A node's or a workload's group of them; nil where none was asked or answered.
    static func group(subject: String, reading: KubeTabReading?, whose: Whose, window: KubeChartWindow?) -> (group: KubeObjectCharts.Group?, notes: [String]) {
        guard let reading, let span = reading.span, reading.results["gpu"] != nil else { return (nil, []) }
        let charts = charts(subject: subject, reading: reading, span: span, whose: whose)
        let notes = notes(reading, span: span, whose: whose, window: window)
        return (charts.isEmpty ? nil : KubeObjectCharts.Group(title: groupTitle, charts: charts), notes)
    }

    /// Live with metrics-server: the sampled charts, the GPUs' group added
    /// (inserted after the first, the object's own), what Prometheus refused said.
    static func add(_ charts: KubeObjectCharts, subject: String, reading: KubeTabReading?, whose: Whose) -> KubeObjectCharts {
        let made = group(subject: subject, reading: reading, whose: whose, window: nil)
        var out = charts
        if let group = made.group { out.groups.insert(group, at: min(1, out.groups.count)) }
        out.notes = KubePromTabCharts.unique(out.notes + made.notes)
        return out
    }
}
