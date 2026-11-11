import AppKit
import SwiftUI

/// The rest of the charts' budgets at scale (docs/design/kubernetes/metrics.md,
/// 5.3, stage M12): the Overview over Prometheus with 60 nodes — X4 the
/// hottest 50 — built and first drawn in 50 ms or less on the main thread;
/// an answer of 8 MB (a thousand series of 300 points) decoded off the
/// main thread in 150 ms or less and merged into the chart cache there too,
/// the cache's bounds kept; the usage ring full — 200 detail keys' six
/// hours and 5,000 list rows — merging a poll off the main thread, held
/// under its 6 MB. Pure parts and the app's own views, in a window of the
/// app's own; nothing reaches a cluster.
extension E2ERunner {
    func kubernetesChartBudget(_ theme: ChromeTheme) async {
        await overviewAtScale(theme)
        await answerAtScale()
        await ringAtScale()
    }

    /// X1–X4 over the last hour from Prometheus: 60 nodes, 8 namespaces and
    /// the rest, the cluster's lines against its requests, limits,
    /// allocatable and capacity.
    private func overviewAtScale(_ theme: ChromeTheme) async {
        let read = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 30).rounded(.down) * 30)
        var reading = KubeChartReading(range: .hour)
        reading.read = read
        reading.tier = .raw
        let window = KubeChartRange.hour.window(now: read)
        func line(_ step: TimeInterval, _ value: (Int) -> Double) -> [KubeSeriesPoint] {
            (0..<Int(3600 / step)).map { KubeSeriesPoint(time: window.start.addingTimeInterval(Double($0 + 1) * step), value: value($0)) }
        }
        reading.series[.cpu] = line(30) { 60 + 10 * sin(Double($0) / 9) }
        reading.series[.memory] = line(30) { 400e9 + 20e9 * sin(Double($0) / 7) }
        reading.totals = [
            .cpuRequests: 150, .cpuLimits: 260, .cpuAllocatable: 236, .cpuCapacity: 240,
            .memoryRequests: 600e9, .memoryLimits: 900e9, .memoryAllocatable: 900e9, .memoryCapacity: 960e9,
        ]
        let nodes = (0..<60).map { "ip-10-0-\($0 / 10)-\($0).eu-west-1.compute.internal" }
        var cpu: [String: [KubeSeriesPoint]] = [:]
        var memory: [String: [KubeSeriesPoint]] = [:]
        for (index, node) in nodes.enumerated() {
            cpu[node] = line(60) { 0.2 + 0.05 * Double(index % 30) + 0.1 * sin(Double($0 + index) / 5) }
            memory[node] = line(60) { _ in Double(2 + index % 12) * 1e9 }
        }
        reading.parts = [.cpu: cpu, .memory: memory]
        reading.partTotals = [
            .cpuAllocatable: Dictionary(uniqueKeysWithValues: nodes.map { ($0, 3.92) }),
            .memoryAllocatable: Dictionary(uniqueKeysWithValues: nodes.map { ($0, 15e9) }),
        ]
        var byNamespace = KubeChartReading(range: .hour)
        byNamespace.read = read
        byNamespace.tier = .raw
        let names = (0..<8).map { "acme-team-\($0)" }
        byNamespace.series[.cpu] = line(30) { 60 + 10 * sin(Double($0) / 9) }
        byNamespace.ranked = names
        byNamespace.parts[.cpu] = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in (name, line(30) { 2 + Double(index) + sin(Double($0) / 6) }) })

        var builds: [Double] = []
        for _ in 0..<20 {
            let begun = CACurrentMediaTime()
            _ = KubeClusterCharts.nodeRows(reading, allocatable: [:])
            builds.append((CACurrentMediaTime() - begun) * 1000)
        }
        let rowsBuilt = Self.summary(builds)
        note("kubernetes X4 of 60 nodes built: \(rowsBuilt)")
        // The Overview's body builds them as it runs: a monitor's publish runs it again.
        check("X4's rows of 60 nodes built in 5 ms or less on the main thread (median)", rowsBuilt.median <= 5, "\(rowsBuilt)")

        let scope = ObjectIdentifier(theme)
        let page = app.kubernetesPage
        var samples: [Double] = []
        for attempt in 0..<5 {
            // The Overview's own view over a monitor of its own holding these
            // readings, as a poll leaves them: its body builds X1–X4 as it runs.
            let monitor = KubePrometheusMonitor()
            monitor.present(
                [.cluster: reading, page.namespacesChart: byNamespace, .nodes: reading], service: KubePrometheusService(namespace: "monitoring", name: "prometheus-k8s", port: "9090")!)
            let begun = CACurrentMediaTime()
            let host = NSHostingView(rootView: KubePrometheusChartView(page: page, monitor: monitor, chart: .cluster, theme: theme).frame(width: 1100, height: 2200))
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 2200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            samples.append((CACurrentMediaTime() - begun) * 1000)
            if attempt == 0 {
                let rows = KubeClusterCharts.nodeRows(reading, allocatable: [:])
                let namespaces = KubeClusterCharts.namespaces(byNamespace)
                check("X4: the hottest 50 of 60 nodes, ten more said", rows.rows.count == KubeClusterCharts.nodesAtMost && rows.more == 10, "\(rows.rows.count) + \(rows.more)")
                check("X3: eight namespaces and the rest, stacked", namespaces?.data.usage.count == 9 && namespaces?.data.stacked == true)
                let drawn = await eventually(10) {
                    host.displayIfNeeded()
                    return KubeHeatStripRegistry.shared.lines(in: scope).count >= 2 * KubeClusterCharts.nodesAtMost
                        && ["kubernetes.chart.cluster.cpu", "kubernetes.chart.cluster.memory", "kubernetes.chart.cluster.namespaces.cpu"].allSatisfy {
                            KubeChartRegistry.shared.chart($0, in: scope)?.plot != nil
                        }
                }
                check("its three charts plotted and its 100 strips drawn", drawn, "\(KubeHeatStripRegistry.shared.lines(in: scope).count) strips")
            }
            window.orderOut(nil)
            window.contentView = nil
            await pause(0.2)
        }
        let first = Self.summary(samples)
        note("kubernetes Overview first draw, 60 nodes from Prometheus: \(first)")
        check("the Overview's own view built and drawn in 50 ms or less on the main thread (median)", first.median <= 50, "\(first)")
    }

    /// The largest answer read (`KubePrometheusReader.maxBytes`): a
    /// thousand series of 300 points, decoded where the monitor decodes
    /// it — off the main thread —, merged into a context's cache off it
    /// too, and kept within the cache's 12 MB.
    private func answerAtScale() async {
        let data = Self.largestAnswer()
        check("an answer of nearly 8 MB", data.count > 7 << 20 && data.count <= KubePrometheusReader.maxBytes, "\(data.count) bytes")
        var decodes: [Double] = []
        var merges: [Double] = []
        var kept: [Double] = []
        var cache = KubeChartCache()
        let step: TimeInterval = 30
        for attempt in 0..<5 {
            let (answer, decoded, onMain) = await Task.detached(priority: .userInitiated) { () -> (KubePrometheusReader.Answer?, Double, Bool) in
                let begun = CACurrentMediaTime()
                let answer = try? KubePrometheusReader.answer(data)
                return (answer, (CACurrentMediaTime() - begun) * 1000, pthread_main_np() != 0)
            }.value
            decodes.append(decoded)
            guard let answer else { return check("the 8 MB answer read", false) }
            if attempt == 0 {
                check(
                    "read whole: 300 points a series, off the main thread", answer.series.count > 900 && answer.series.allSatisfy { $0.points.count == 300 } && !onMain, "\(answer.series.count) series"
                )
            }
            // A query's own key each time: the cache holds two such answers at most.
            let key = KubeChartCache.Key(query: "perf-\(attempt)", range: "1h", step: step)
            let start = Date(timeIntervalSince1970: Self.answerStart)
            let asked = (start: start, end: start.addingTimeInterval(299 * step))
            let old = cache.entry(key)
            let (entry, merged) = await Task.detached(priority: .userInitiated) { () -> (KubeChartCache.Entry, Double) in
                let begun = CACurrentMediaTime()
                let entry = KubeChartCache.merged(old, series: answer.series, asked: asked, start: start)
                return (entry, (CACurrentMediaTime() - begun) * 1000)
            }.value
            merges.append(merged)
            let begun = CACurrentMediaTime()
            cache.put(key, entry)
            kept.append((CACurrentMediaTime() - begun) * 1000)
        }
        let decoded = Self.summary(decodes)
        note("kubernetes 8 MB Prometheus answer decoded: \(decoded)")
        check("decoded off the main thread in 150 ms or less (median)", decoded.median <= 150, "\(decoded)")
        let merged = Self.summary(merges)
        note("kubernetes 8 MB answer merged into the cache off the main thread: \(merged)")
        check("merged into the cache off the main thread in 50 ms or less (median)", merged.median <= 50, "\(merged)")
        let put = Self.summary(kept)
        check("and kept on the main thread in 1 ms or less (median)", put.median <= 1, "\(put)")
        check("the cache within its 12 MB", cache.bytes <= KubeChartCache.maxBytes && cache.count >= 1, "\(cache.bytes) bytes in \(cache.count)")
        // Past the bound: said, never parsed.
        var over = data
        over.append(contentsOf: [UInt8](repeating: 0x20, count: KubePrometheusReader.maxBytes + 1 - data.count))
        let begun = CACurrentMediaTime()
        let refused = (try? KubePrometheusReader.answer(over)) == nil
        let took = (CACurrentMediaTime() - begun) * 1000
        check("a byte past 8 MB refused unread", refused && took < 5, String(format: "%.2f ms", took))
    }

    /// The usage ring full: 200 detail keys of six hours (60 raw points and
    /// 360 minutes each) and the Pods list's 5,000 rows, its polls merged
    /// as the monitor merges them — off the main thread, over a copy.
    private func ringAtScale() async {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 15).rounded(.down) * 15)
        let filled = await Task.detached(priority: .userInitiated) { () -> KubeUsageRing in
            var ring = KubeUsageRing()
            let begin = now.addingTimeInterval(-21_600)
            for index in 0..<KubeUsageRing.detailKeys {
                let key = KubeUsageKey.pod(namespace: "acme-shop", name: "detail-\(index)")
                for sample in 0..<1440 {
                    ring.record(key, KubeUsage(cpu: 0.1, memory: 64 * 1_048_576), at: begin.addingTimeInterval(Double(sample) * 15), .detail, now: now)
                }
            }
            return ring
        }.value
        var ring = filled
        let ids = (0..<5000).map { KubeRowID(namespace: "acme-shop", name: String(format: "checkout-api-%05d", $0)) }
        var polls: [Double] = []
        for poll in 0..<45 {
            let time = now.addingTimeInterval(Double(poll) * 15)
            var sample = KubeMetricsSample(read: time)
            for (index, id) in ids.enumerated() {
                sample.pods[id] = KubePodMetrics(
                    id: id, timestamp: time, window: "15s", containers: ["app": KubeUsage(cpu: 0.001 * Double(index % 900 + 1), memory: Double(index % 500 + 16) * 1_048_576)])
            }
            let (merged, took) = await Task.detached(priority: .utility) { [ring, sample] () -> (KubeUsageRing, Double) in
                var ring = ring
                let begun = CACurrentMediaTime()
                ring.record(sample, for: .pods(.namespace("acme-shop"), labels: nil), asList: true, asDetail: false, sums: [], now: time)
                return (ring, (CACurrentMediaTime() - begun) * 1000)
            }.value
            ring = merged
            polls.append(took)
        }
        let merged = Self.summary(polls)
        note("kubernetes full usage ring, a 5,000-row poll merged off the main thread: \(merged); \(ring.bytes / 1024) KB")
        check("a poll merged in 50 ms or less off the main thread (p95)", merged.p95 <= 50, "\(merged)")
        check("the ring under its 6 MB", ring.bytes <= KubeUsageRing.defaultByteCap, "\(ring.bytes) bytes")
        check("every detail key kept, the list's rows given up first", ring.detailKeyCount == KubeUsageRing.detailKeys && ring.listKeys > 0, "\(ring.detailKeyCount) details, \(ring.listKeys) rows")
        var reads: [Double] = []
        for index in 0..<50 {
            let begun = CACurrentMediaTime()
            _ = ring.segments(.pod(namespace: "acme-shop", name: "detail-\(index)"), .detail, now: now)
            reads.append((CACurrentMediaTime() - begun) * 1000)
        }
        let read = Self.summary(reads)
        note("kubernetes a detail's six hours read from the full ring: \(read)")
        check("a detail's six hours read in 1 ms or less (median)", read.median <= 1, "\(read)")
    }

    private static let answerStart = 1_799_990_010.0

    /// A matrix just under `KubePrometheusReader.maxBytes`: a thousand-odd
    /// series of 300 points, as `query_range` answers one.
    private static func largestAnswer() -> Data {
        var data = Data(#"{"status":"success","data":{"resultType":"matrix","result":["#.utf8)
        let tail = Data("]}}".utf8)
        var index = 0
        while true {
            var item = index == 0 ? "" : ","
            item += #"{"metric":{"namespace":"acme-shop","pod":"checkout-api-7f9c6d-\#(index)","container":"app"},"values":["#
            item += (0..<300).map { "[\(answerStart + Double($0) * 30),\"\(0.05 + Double(($0 * 7 + index) % 100) / 1000)\"]" }.joined(separator: ",")
            item += "]}"
            let bytes = Data(item.utf8)
            guard data.count + bytes.count + tail.count <= KubePrometheusReader.maxBytes else { break }
            data.append(bytes)
            index += 1
        }
        data.append(tail)
        return data
    }
}

/// §5.3's steady states and the hidden page (M12), on a pod's Metrics tab
/// over fake-dev's Prometheus — `kubernetesCharts`' part over Prometheus,
/// which leaves the tab at 24h: the refreshes counted in the fake's
/// recorded requests, the tab's clock moved where five minutes would take.
extension E2ERunner {
    /// This process's CPU over three windows of 3 s each, in percent of a
    /// core: each said, so one window's transient (a git status, the
    /// fake's own threads answering in this process — it moved a single
    /// 6 s window from 1% to 6.5% between runs of the same code) shows
    /// for what it is; the budget is held on their mean.
    func cpuWindows() async -> [Double] {
        var windows: [Double] = []
        for _ in 0..<3 {
            let cpu0 = Self.cpuSeconds()
            let wall0 = Date()
            await pause(3)
            windows.append((Self.cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100)
        }
        return windows
    }

    func kubernetesChartsSteady(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, service: KubePrometheusService) async {
        let interval = model.prometheus.interval
        let metricsInterval = model.metrics.interval
        defer {
            model.prometheus.clock = { Date() }
            model.prometheus.forgetCaches()
            model.prometheus.interval = interval
            model.metrics.interval = metricsInterval
        }
        func ranges() -> [FakeKubeAPI.Request] { fake.requests.filter { $0.path == service.rangePath } }
        func spans(_ requests: [FakeKubeAPI.Request]) -> [TimeInterval] {
            requests.compactMap { request in Double(request.query["end"] ?? "").flatMap { end in Double(request.query["start"] ?? "").map { end - $0 } } }
        }
        func perQuery(_ requests: [FakeKubeAPI.Request]) -> [String: Int] {
            Dictionary(grouping: requests, by: { $0.query["query"] ?? "" }).mapValues(\.count)
        }

        // 24h: refreshed every 500 ms here, its range's 5 minutes standing still.
        check("the tab at 24h", page.shownMetricsRange == .day, "\(page.shownMetricsRange)")
        let frozen = Date()
        model.prometheus.clock = { frozen }
        model.prometheus.interval = .milliseconds(500)
        model.prometheus.forgetCaches()
        fake.forgetRequests()
        let whole = await eventually(15) { !ranges().isEmpty }
        await pause(1.5)
        let day = ranges()
        check(
            "24h asked whole once, at its 5 min step", whole && !day.isEmpty && spans(day).allSatisfy { $0 >= 86_400 } && day.allSatisfy { $0.query["step"] == "5m" },
            "\(day.map(\.query))")
        fake.forgetRequests()
        await pause(3)
        check("refreshed six times within its step: no query_range again", ranges().isEmpty, "\(ranges().map(\.query))")
        // Five minutes on: each chart's query asked once more, its last steps only.
        model.prometheus.clock = { frozen.addingTimeInterval(300) }
        fake.forgetRequests()
        let tail = await eventually(10) { !ranges().isEmpty }
        await pause(3)
        let asked = ranges()
        let counts = perQuery(asked)
        note("kubernetes 24h, five minutes on: \(asked.count) query_range for \(perQuery(day).count) queries, spans \(spans(asked).map { Int($0) })")
        check(
            "five minutes on, at most one query_range a chart's query",
            tail && counts.values.allSatisfy { $0 == 1 } && Set(counts.keys).isSubset(of: Set(perQuery(day).keys)), "\(counts)")
        check("each incremental: its last steps, not the day", spans(asked).allSatisfy { $0 > 0 && $0 <= 3600 }, "\(spans(asked))")
        model.prometheus.clock = { Date() }
        model.prometheus.forgetCaches()

        // Live on a quiet cluster at its own intervals: metrics-server's 15 s, Prometheus' step.
        check("Live's sampled reads every 15 s", KubeMetricsMonitor().interval == .seconds(15))
        page.pickMetricsRange(.live)
        model.prometheus.interval = nil
        model.metrics.interval = .seconds(15)
        let settled = await eventually(15) { !ranges().isEmpty && model.prometheus.tabs.values.contains { $0.read != nil } }
        await pause(2)  // the last 500 ms polls land, the first Live answers drawn
        fake.forgetRequests()
        note("kubernetes Live tab: steady window starts")
        let windows = await cpuWindows()
        // The whole 9 s, as the budget is held (a mean, no window left out).
        let cpu = windows.reduce(0, +) / Double(windows.count)
        let metrics = Dictionary(grouping: fake.requests.filter { $0.path.hasPrefix("/apis/metrics.k8s.io/") }, by: \.path).mapValues(\.count)
        let live = perQuery(ranges())
        let said = windows.map { String(format: "%.2f%%", $0) }.joined(separator: ", ")
        note(String(format: "kubernetes Live tab, quiet, steady: CPU %.2f%% ", cpu) + "(mean of \(said)); metrics GETs \(metrics), query_range \(live.values.reduce(0, +))")
        check("Live read, then steady", settled)
        check("at most one GET a target in 9 s (its 15 s interval)", metrics.values.allSatisfy { $0 <= 1 }, "\(metrics)")
        check("at most one query_range a chart's query in 9 s (its 30 s step)", live.values.allSatisfy { $0 <= 1 }, "\(live)")
        // The page's budget is the app's idle one, held absolutely
        // (analysis.md 10; metrics.md M-tests): it fails, as `performance`'s
        // idle CPU does, on a Mac whose idle app alone passes 3%.
        check("steady, within the idle budget (< 3% CPU)", cpu < 3, "mean of \(said)")

        // Hidden: no metrics read at all, the metrics proxy closed within 60 s.
        model.prometheus.interval = .milliseconds(300)
        model.metrics.interval = .milliseconds(300)
        let closes = model.prometheus.proxyCloses
        let hidden = CACurrentMediaTime()
        app.toggleKubernetesPage(nil)
        let closed = await eventually(60) {
            !model.prometheus.isPolling && !model.metrics.isPolling && model.prometheus.closing == 0 && model.prometheus.proxyCloses > closes
        }
        let took = CACurrentMediaTime() - hidden
        note(String(format: "kubernetes hidden: readings stopped and the metrics proxy closed in %.2f s", took))
        check("hidden, the readings stop and the metrics proxy closes within 60 s", closed && took <= 60, String(format: "%.1f s", took))
        fake.forgetRequests()
        await pause(2)
        let read = fake.requests.filter { $0.isPrometheusQuery || $0.path.hasPrefix("/apis/metrics.k8s.io/") }
        check("then nothing of metrics read, at 300 ms intervals", read.isEmpty, "\(read.map(\.path))")
        // The same window without the page, at the same intervals: what the
        // app costs here anyway — its agents' process-tree poll and the
        // checkout's git, which on a Mac running many processes alone
        // passes 3%. Said beside the absolute budget, never in its place:
        // with the page hidden the terminal shows and its checkout's git
        // runs, neither of which costs while the page covers it, so this
        // baseline is high and the difference only a guide.
        model.prometheus.interval = nil
        model.metrics.interval = .seconds(15)
        // Past what hiding itself sets off (the terminal shown again, its checkout's git).
        await pause(5)
        note("kubernetes hidden: baseline window starts")
        let bare = await cpuWindows()
        let baseline = bare.reduce(0, +) / Double(bare.count)
        let bareSaid = bare.map { String(format: "%.2f%%", $0) }.joined(separator: ", ")
        note(
            String(format: "kubernetes hidden, the same window without the page: CPU %.2f%% ", baseline)
                + "(mean of \(bareSaid)); the Live tab's over it: " + String(format: "%+.2f%%", cpu - baseline))
        app.toggleKubernetesPage(nil)
        check("shown again", await eventually(5) { app.store.showingOverlay == .kubernetes })
    }
}
