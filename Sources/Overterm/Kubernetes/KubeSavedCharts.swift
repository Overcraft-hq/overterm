import Foundation

/// A context's saved queries drawn on a workload's Metrics tab
/// (docs/design/kubernetes/metrics.md, decision 11; stage M8d): a chart
/// each, in the order the entry lists them, titled and in the unit the
/// user gave; its series named by the labels that tell them apart; past
/// twelve, the largest by the range's mean — the rest summed as "other"
/// where its lines add up, else left out and said. A group of their own,
/// last, read only while on screen (`KubePromTabCharts.readWhenShown`). A
/// query refused before it was sent, or by Prometheus, is said under the
/// charts in its title's name. Pure.
enum KubeSavedCharts {
    static let groupTitle = "Saved queries"
    /// The series a chart draws (metrics.md 6.3), "other" aside.
    static let seriesAtMost = 12

    /// Prometheus refused the query as sent (`bad_data`, a 422): its
    /// words (the reader's sentence), and that it isn't asked again.
    static func rejected(_ message: String) -> String {
        var said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty { said = "Prometheus refused it" }
        if !said.hasSuffix(".") { said += "." }
        return said + " Not asked again until it is edited."
    }

    /// It failed for another reason: a timeout, the Service away.
    static func failed(_ sentence: String) -> String { "it couldn't be read: \(sentence)" }

    /// What is said of a saved chart that drew nothing.
    static func sentence(title: String, _ why: String) -> String { "Saved query \u{201C}\(title)\u{201D}: \(why)" }

    /// The entry holds more than are asked.
    static func beyond(_ count: Int) -> String {
        "\(count) saved quer\(count == 1 ? "y" : "ies") more \(count == 1 ? "isn't" : "aren't") asked: at most \(KubeSavedQueries.atMost) a context."
    }

    /// Saved queries, and no Prometheus to ask them of.
    static let needsPrometheus =
        "This context's saved queries are read from Prometheus, which isn't on for it: set \"metrics\": \"prometheus\" in its kubernetes.contexts entry."

    /// The workload's group — pending until read, its sentences — for
    /// `saved` (all the entry's, `reading` nil: not read yet); nil without any.
    static func group(subject: String, saved: [KubeSavedChart], reading: KubeTabReading?) -> (group: KubeObjectCharts.Group?, notes: [String]) {
        guard !saved.isEmpty else { return (nil, []) }
        var notes: [String] = []
        if saved.count > KubeSavedQueries.atMost { notes.append(beyond(saved.count - KubeSavedQueries.atMost)) }
        let asked = Array(saved.prefix(KubeSavedQueries.atMost))
        guard let reading, let span = reading.span else {
            return (KubeObjectCharts.Group(title: groupTitle, charts: [], readsWhenShown: true, pending: true), notes)
        }
        var charts: [KubePodCharts.Chart] = []
        var read = false
        for (index, chart) in asked.enumerated() {
            let id = KubeSavedQueries.id(index)
            if let why = reading.saved[id] {
                notes.append(sentence(title: chart.title, why))
                read = true
            } else if let answer = reading.results[id] {
                read = true
                if let made = self.chart(chart, index: index, subject: subject, answer: answer, span: span) {
                    charts.append(made.chart)
                    notes += made.notes.map { sentence(title: chart.title, $0) }
                } else {
                    notes.append(sentence(title: chart.title, "Prometheus answered no series for this workload over the range."))
                }
            }
        }
        return (KubeObjectCharts.Group(title: groupTitle, charts: charts, readsWhenShown: true, pending: !read), notes)
    }

    /// One saved chart from its answer; nil, no series.
    static func chart(_ saved: KubeSavedChart, index: Int, subject: String, answer: [KubeSeries], span: KubePromSpan) -> (
        chart: KubePodCharts.Chart, notes: [String]
    )? {
        let lines = answer.filter { !$0.points.isEmpty }
        guard !lines.isEmpty else { return nil }
        let names = self.names(lines.map(\.labels))
        var ranked = zip(names, lines).map { (name: $0.0, points: $0.1.points.sorted { $0.time < $1.time }) }
        ranked.sort { KubeChartBuild.mean($0.points, since: .distantPast) > KubeChartBuild.mean($1.points, since: .distantPast) }
        let unit = saved.unit.chartUnit
        var series = ranked.prefix(seriesAtMost).enumerated().map { KubeChartSeries(id: "s\($0.offset)", name: $0.element.name, points: $0.element.points) }
        var notes: [String] = []
        let rest = ranked.dropFirst(seriesAtMost)
        if !rest.isEmpty {
            if saved.unit.additive {
                series.append(KubeChartSeries(id: "other", name: "other", points: KubePromTabCharts.sum(rest.map(\.points))))
            } else {
                notes.append("\(rest.count) series more aren't drawn: the \(seriesAtMost) largest are (\(saved.unit.rawValue) don't add up into \"other\").")
            }
        }
        let latest = series.count == 1 ? series[0].points.last?.value : nil
        let headline = latest.map { "\(unit.format($0)) now" } ?? "\(ranked.count) series"
        return (
            KubePodCharts.Chart(
                data: KubePromTabCharts.data(id: "\(subject).saved.\(index)", title: saved.title, unit: unit, series: series, span: span, tier: "saved query"),
                headline: headline),
            notes
        )
    }

    /// Each series' name: the values of the labels that tell them apart
    /// (`__name__` and Overterm's own aside), `label=value` where only
    /// one label does; "value" for a lone series.
    static func names(_ labels: [[String: String]]) -> [String] {
        let keys = Set(labels.flatMap(\.keys)).subtracting(["__name__", "overterm_s"])
        let varying = keys.filter { key in Set(labels.map { $0[key] ?? "" }).count > 1 }.sorted()
        guard labels.count > 1, !varying.isEmpty else {
            return labels.count == 1 ? ["value"] : labels.indices.map { "series \($0 + 1)" }
        }
        return labels.map { label in
            varying.map { key in varying.count == 1 ? (label[key] ?? "") : "\(key)=\(label[key] ?? "")" }.joined(separator: " · ")
        }
    }

    /// The workload's charts with its saved group added, last, and its sentences.
    static func add(_ charts: KubeObjectCharts, subject: String, saved: [KubeSavedChart], reading: KubeTabReading?) -> KubeObjectCharts {
        let made = group(subject: subject, saved: saved, reading: reading)
        var out = charts
        if let group = made.group { out.groups.append(group) }
        out.notes = KubePromTabCharts.unique(out.notes + made.notes)
        return out
    }
}
