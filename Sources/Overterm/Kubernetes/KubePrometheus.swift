import Foundation

/// Prometheus per context (stage 4; docs/design/kubernetes/analysis.md,
/// 2.1, 2.11, 2.17, Section 4's Prometheus, decision 16). Pure.
///
/// Opt-in: a context's `metrics` is `prometheus` (or `auto`, set in its
/// entry), or its entry names a `prometheus` service. The service is found
/// as Freelens finds it — Lens's own `lens-metrics/prometheus`, the Helm
/// chart's `app=prometheus,component=server,heritage=Helm`, the operator's
/// `operated-prometheus=true` — by a GET through the context's own proxy,
/// or named in the entry (`namespace/service:port`). Its queries go
/// through the apiserver's service proxy, on a second `kubectl proxy`
/// whose `--accept-paths` names that one service's `query` and
/// `query_range` paths and nothing else (`KubePrometheusFlags`).

/// A Prometheus server's Service, as the apiserver's service proxy reaches it.
struct KubePrometheusService: Hashable, Sendable, CustomStringConvertible {
    let namespace: String
    let name: String
    /// The Service's port: a number, or its name.
    let port: String

    /// Nil unless each part is what Kubernetes allows: a namespace and a
    /// Service are DNS labels (lowercase letters, digits, `-`; 63 at most),
    /// a port a number (1–65535) or an IANA name (15 at most, a letter in
    /// it) — so nothing in them can change the path they go in.
    init?(namespace: String, name: String, port: String) {
        guard Self.isLabel(namespace), Self.isLabel(name), Self.isPort(port) else { return nil }
        self.namespace = namespace
        self.name = name
        self.port = port
    }

    /// The entry's `prometheus`: `namespace/service:port` (`:port` left out, 80).
    init?(setting: String) {
        let text = setting.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let service = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard service.count <= 2 else { return nil }
        self.init(namespace: String(parts[0]), name: String(service[0]), port: service.count == 2 ? String(service[1]) : "80")
    }

    var description: String { "\(namespace)/\(name):\(port)" }

    static func isLabel(_ text: String) -> Bool {
        guard (1...63).contains(text.utf8.count), let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else { return false }
        func alnum(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("0"..."9").contains(c) }
        return alnum(first) && alnum(last) && text.unicodeScalars.allSatisfy { alnum($0) || $0 == "-" }
    }

    static func isPort(_ text: String) -> Bool {
        if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int(text).map { (1...65535).contains($0) } ?? false }
        return text.utf8.count <= 15 && isLabel(text) && text.contains { $0.isLetter }
    }

    /// The service proxy's root for this Service.
    var proxyBase: String { "/api/v1/namespaces/\(namespace)/services/\(name):\(port)/proxy" }
    var queryPath: String { proxyBase + "/api/v1/query" }
    var rangePath: String { proxyBase + "/api/v1/query_range" }

    /// Whether `path` (its query string aside) is one of the two paths the
    /// metrics proxy lets through — what Overterm sends it is checked here
    /// before any socket too.
    func allows(_ path: String) -> Bool {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return bare == queryPath || bare == rangePath
    }
}

/// A path the metrics proxy isn't for, refused before it reaches any socket.
struct KubePrometheusRefused: Error, LocalizedError, Equatable {
    var path: String
    var errorDescription: String? { "Only the Prometheus Service's query and query_range paths go through its proxy." }
}

/// The second proxy's flags: only the Prometheus Service's two query
/// paths, GETs only. `--accept-paths` is anchored at both ends, the
/// namespace, Service and port escaped, so another Service's proxy,
/// another path under this one's, a `..` or a `%2F` decoded into one
/// (kubectl matches the decoded path) never matches. kubectl's own
/// rejected paths (exec, attach) are kept, and the pods' and nodes'
/// proxies refused as on every socket — not the Services' proxy, which
/// this one is for: its `--accept-paths` narrows that to one Service's
/// queries. Pure.
enum KubePrometheusFlags {
    static let rejectedPaths = [
        #"^/api/.*/pods/.*/(exec|attach|portforward|proxy)"#,
        #"^/api/.*/nodes/.*/proxy"#,
        #"^/apis/subresources\.kubevirt\.io/"#,
    ]

    /// RE2's metacharacters, escaped (a name can't hold them; still).
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if #"\.+*?()|[]{}^$"#.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    static func acceptedPaths(_ service: KubePrometheusService) -> String {
        "^" + escaped(service.proxyBase) + "/api/v1/(query|query_range)$"
    }

    static func arguments(context: String, socket: String, service: KubePrometheusService, cacheDirectory: String? = nil) -> [String] {
        var arguments = ["--context=\(context)"]
        if let cacheDirectory { arguments.append("--cache-dir=\(cacheDirectory)") }
        return arguments + [
            "proxy",
            "--unix-socket=\(socket)",
            "--disable-filter=false",
            "--accept-hosts=\(KubeProxyFlags.acceptedHosts)",
            "--accept-paths=\(acceptedPaths(service))",
            "--reject-paths=\(rejectedPaths.joined(separator: ","))",
            "--reject-methods=\(KubeProxyFlags.rejectedMethods)",
        ]
    }

    /// The metrics proxy's socket beside the context's own: `<hash>-metrics.sock`.
    static func socket(beside socket: String) throws -> String {
        let path = (socket.hasSuffix(".sock") ? String(socket.dropLast(5)) : socket) + "-metrics.sock"
        guard path.utf8.count <= KubeSocketFolder.maxPathBytes else {
            throw KubeProxyProblem.socket("The metrics socket's path would be \(path.utf8.count) bytes; a unix socket's is \(KubeSocketFolder.maxPathBytes) at most.")
        }
        return path
    }
}

/// Whether a context uses Prometheus, as its entry says. Pure.
enum KubePrometheusUse: Equatable, Sendable {
    /// Not opted in: no Prometheus is looked for.
    case off
    /// Looked for, Freelens's way.
    case detect
    /// The entry names it.
    case configured(KubePrometheusService)
    /// The entry names one that isn't a namespace, Service and port.
    case invalid(String)

    static func of(_ settings: KubeContextSettings) -> KubePrometheusUse {
        if settings.metrics == KubeMetricsSource.none || settings.metrics == .metricsServer { return .off }
        if let text = settings.prometheus {
            guard let service = KubePrometheusService(setting: text) else {
                return .invalid("The context's prometheus setting isn't namespace/service:port: \(text)")
            }
            return .configured(service)
        }
        return settings.metrics == .prometheus || settings.metrics == .auto ? .detect : .off
    }

    var isOn: Bool { self != .off }
}

/// Where Freelens finds a Prometheus, in its order. Pure.
enum KubePrometheusProvider: String, CaseIterable, Sendable {
    case lens, helm, operatorManaged

    var title: String {
        switch self {
        case .lens: "Lens metrics (lens-metrics/prometheus)"
        case .helm: "the prometheus Helm chart"
        case .operatorManaged: "the Prometheus Operator"
        }
    }

    static let helmSelector = "app=prometheus,component=server,heritage=Helm"
    static let operatorSelector = "operated-prometheus=true"

    /// The one GET that looks for it, through the context's own proxy.
    var path: String {
        switch self {
        case .lens: "/api/v1/namespaces/lens-metrics/services/prometheus"
        case .helm: KubePath.query("/api/v1/services", [("labelSelector", Self.helmSelector), ("limit", "20")])
        case .operatorManaged: KubePath.query("/api/v1/services", [("labelSelector", Self.operatorSelector), ("limit", "20")])
        }
    }

    /// The Service an answer names: a Service (Lens's), or the first of a
    /// ServiceList by namespace and name; its first port's number — the
    /// operator's `web` first, Prometheus's own. Nil when there is none.
    func service(in data: Data) -> KubePrometheusService? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items = object["items"] as? [[String: Any]] ?? (object["kind"] as? String == "Service" ? [object] : [])
        let services: [KubePrometheusService] = items.compactMap { item in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            let ports = (item["spec"] as? [String: Any])?["ports"] as? [[String: Any]] ?? []
            let named = self == .operatorManaged ? ports.first { $0["name"] as? String == "web" } : nil
            guard let namespace = metadata["namespace"] as? String, let name = metadata["name"] as? String,
                let port = ((named ?? ports.first)?["port"] as? Int).map(String.init)
            else { return nil }
            return KubePrometheusService(namespace: namespace, name: name, port: port)
        }
        return services.min { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }
}

/// How a context's Prometheus stands.
enum KubePrometheusState: Equatable, Sendable {
    /// Not opted in (or nobody looks).
    case off
    case detecting
    /// Found by `provider`, or named in the entry (`provider` nil).
    case found(KubePrometheusService, KubePrometheusProvider?)
    /// Looked for and not found, or the entry's isn't usable: why.
    case unavailable(String)

    var service: KubePrometheusService? {
        if case .found(let service, _) = self { return service }
        return nil
    }

    /// What the page says of it.
    var said: String? {
        switch self {
        case .off: nil
        case .detecting: "Looking for Prometheus…"
        case .found(let service, let provider): "Prometheus \(service)" + (provider.map { ", found as \($0.title)" } ?? ", as this context's setting names it")
        case .unavailable(let why): why
        }
    }

    static let notFound =
        "No Prometheus found: none at lens-metrics/prometheus, and no Service labelled \(KubePrometheusProvider.helmSelector) or \(KubePrometheusProvider.operatorSelector). Name one in the context's prometheus setting (namespace/service:port). Overterm installs nothing."
}

/// A chart's time range (2.11): `query_range`'s start, end and step. Pure.
enum KubeChartRange: String, CaseIterable, Sendable, Identifiable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"

    var id: String { rawValue }
    var title: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }

    /// 120 points (168 for a week, an hour each).
    var step: TimeInterval {
        switch self {
        case .hour: 30
        case .sixHours: 180
        case .day: 720
        case .week: 3600
        }
    }

    /// How often the chart is asked again: as often as a point is added, a minute at least.
    var refresh: Duration { .seconds(Int(max(60, step))) }

    /// A `rate()`'s window: a step at least (a shorter one skips samples
    /// between points), a minute at least.
    var rateWindow: String { KubePromQL.duration(max(60, step)) }

    /// `[start, end]` ending at `now` rounded down to a step, so a chart
    /// asked again within a step asks the same.
    func window(now: Date) -> (start: Date, end: Date) {
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        return (end.addingTimeInterval(-seconds), end)
    }
}

/// The queries, Freelens's (cAdvisor, kube-state-metrics, kubelet). Pure.
enum KubePromQL {
    /// A PromQL string literal's inside: `\` and `"` escaped (a name can't hold them; still).
    static func literal(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func matchers(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\"\(literal($0.1))\"" }.joined(separator: ",")
    }

    /// `30s`, `3m`, `1h`.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        if whole % 3600 == 0 { return "\(whole / 3600)h" }
        if whole % 60 == 0 { return "\(whole / 60)m" }
        return "\(whole)s"
    }

    static func podCPU(namespace: String, pod: String, window: String) -> String {
        "sum(rate(container_cpu_usage_seconds_total{container!=\"\",image!=\"\",\(matchers([("namespace", namespace), ("pod", pod)]))}[\(window)]))"
    }

    static func podMemory(namespace: String, pod: String) -> String {
        "sum(container_memory_working_set_bytes{container!=\"\",image!=\"\",\(matchers([("namespace", namespace), ("pod", pod)]))})"
    }

    static func clusterCPU(window: String) -> String { "sum(rate(container_cpu_usage_seconds_total{container!=\"\",image!=\"\"}[\(window)]))" }
    static let clusterMemory = "sum(container_memory_working_set_bytes{container!=\"\",image!=\"\"})"

    /// kube-state-metrics' requests and limits, and the nodes' allocatable, summed.
    static func requests(_ resource: String) -> String { "sum(kube_pod_container_resource_requests{resource=\"\(literal(resource))\"})" }
    static func limits(_ resource: String) -> String { "sum(kube_pod_container_resource_limits{resource=\"\(literal(resource))\"})" }
    static func allocatable(_ resource: String) -> String { "sum(kube_node_status_allocatable{resource=\"\(literal(resource))\"})" }

    /// kubelet's volume stats, by claim — a namespace's, or every one's.
    static func volumes(_ metric: String, namespace: String?) -> String {
        let filter = namespace.map { "{\(matchers([("namespace", $0)]))}" } ?? ""
        return "sum by (namespace, persistentvolumeclaim) (\(metric)\(filter))"
    }

    static func volume(_ metric: String, namespace: String, claim: String) -> String {
        "sum(\(metric){\(matchers([("namespace", namespace), ("persistentvolumeclaim", claim)]))})"
    }

    static let volumeUsed = "kubelet_volume_stats_used_bytes"
    static let volumeCapacity = "kubelet_volume_stats_capacity_bytes"

    static func rangePath(_ service: KubePrometheusService, _ query: String, _ range: KubeChartRange, now: Date) -> String {
        let (start, end) = range.window(now: now)
        return KubePath.query(
            service.rangePath,
            [("query", query), ("start", stamp(start)), ("end", stamp(end)), ("step", duration(range.step))])
    }

    static func instantPath(_ service: KubePrometheusService, _ query: String) -> String {
        KubePath.query(service.queryPath, [("query", query)])
    }

    static func stamp(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }
}

/// One point of a series.
struct KubeSeriesPoint: Equatable, Sendable {
    var time: Date
    var value: Double
}

/// One series of an answer: its labels and points.
struct KubeSeries: Equatable, Sendable {
    var labels: [String: String]
    var points: [KubeSeriesPoint]
}

/// Prometheus's HTTP API answers read: a matrix (`query_range`) or a
/// vector (`query`), bounded, the values that aren't numbers (`NaN`,
/// `+Inf`) left out. Pure.
enum KubePrometheusReader {
    static let maxSeries = 2000
    static let maxPoints = 2000
    /// An answer larger than this isn't parsed: a runaway query, or a
    /// Prometheus misbehaving — said, never handed whole to the parser.
    static let maxBytes = 8 << 20

    struct Failure: Error, LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static func read(_ data: Data, status: Int = 200) throws -> [KubeSeries] {
        guard data.count <= maxBytes else {
            throw Failure(message: "Prometheus's answer is too large (\(data.count / 1_048_576) MB, at most \(maxBytes / 1_048_576) MB is read).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: status == 200 ? "Prometheus's answer isn't JSON." : "Prometheus answered \(status)\(text.isEmpty ? "" : ": \(text)")")
        }
        if object["kind"] as? String == "Status" {
            // The apiserver's own answer: the Service isn't there, has no endpoints, is refused.
            throw Failure(message: "The service proxy answered \(status): " + (object["message"] as? String ?? "no reason given"))
        }
        if object["status"] as? String != "success" {
            let type = object["errorType"] as? String
            let error = object["error"] as? String ?? "HTTP \(status)"
            throw Failure(message: "Prometheus: " + (type.map { "\($0): " } ?? "") + error)
        }
        guard let body = object["data"] as? [String: Any], let result = body["result"] as? [[String: Any]] else {
            throw Failure(message: "Prometheus's answer has no result.")
        }
        var series: [KubeSeries] = []
        for item in result.prefix(maxSeries) {
            let labels = (item["metric"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            var raw: [[Any]] = []
            if let values = item["values"] as? [[Any]] { raw = values }
            if let value = item["value"] as? [Any] { raw = [value] }
            let points = raw.suffix(maxPoints).compactMap(point)
            series.append(KubeSeries(labels: labels, points: points))
        }
        return series
    }

    /// `[1730000000.123, "0.25"]`.
    private static func point(_ pair: [Any]) -> KubeSeriesPoint? {
        guard pair.count == 2, let text = pair[1] as? String, let value = Double(text), value.isFinite else { return nil }
        let time: Double
        if let number = pair[0] as? Double {
            time = number
        } else if let number = pair[0] as? Int {
            time = Double(number)
        } else {
            return nil
        }
        return KubeSeriesPoint(time: Date(timeIntervalSince1970: time), value: value)
    }

    /// The one series a `sum(…)` answers: its points; none, empty.
    static func points(_ series: [KubeSeries]) -> [KubeSeriesPoint] { series.first?.points ?? [] }

    /// The one value an instant `sum(…)` answers.
    static func value(_ series: [KubeSeries]) -> Double? { series.first?.points.last?.value }
}

/// What a chart is of, and what it asks for.
enum KubeChart: Hashable, Sendable {
    /// The cluster's CPU and memory, its requests and limits against allocatable (the Overview).
    case cluster
    case pod(namespace: String, name: String)
    case volume(namespace: String, claim: String)
}

/// One measure a chart reads.
enum KubeChartMeasure: String, CaseIterable, Sendable {
    case cpu, memory, volumeUsed, volumeCapacity
    case cpuRequests, cpuLimits, cpuAllocatable, memoryRequests, memoryLimits, memoryAllocatable

    var isBytes: Bool { ![.cpu, .cpuRequests, .cpuLimits, .cpuAllocatable].contains(self) }

    func format(_ value: Double) -> String { isBytes ? KubeVolumeFormat.bytes(value) : KubeMetricsFormat.cpu(value) }
}

extension KubeChart {
    /// The range queries (charts) and the instant ones (totals) this chart asks.
    func queries(range: KubeChartRange) -> (series: [(KubeChartMeasure, String)], totals: [(KubeChartMeasure, String)]) {
        switch self {
        case .cluster:
            return (
                [(.cpu, KubePromQL.clusterCPU(window: range.rateWindow)), (.memory, KubePromQL.clusterMemory)],
                [
                    (.cpuRequests, KubePromQL.requests("cpu")), (.cpuLimits, KubePromQL.limits("cpu")), (.cpuAllocatable, KubePromQL.allocatable("cpu")),
                    (.memoryRequests, KubePromQL.requests("memory")), (.memoryLimits, KubePromQL.limits("memory")),
                    (.memoryAllocatable, KubePromQL.allocatable("memory")),
                ]
            )
        case .pod(let namespace, let name):
            return (
                [
                    (.cpu, KubePromQL.podCPU(namespace: namespace, pod: name, window: range.rateWindow)),
                    (.memory, KubePromQL.podMemory(namespace: namespace, pod: name)),
                ], []
            )
        case .volume(let namespace, let claim):
            return (
                [
                    (.volumeUsed, KubePromQL.volume(KubePromQL.volumeUsed, namespace: namespace, claim: claim)),
                    (.volumeCapacity, KubePromQL.volume(KubePromQL.volumeCapacity, namespace: namespace, claim: claim)),
                ], []
            )
        }
    }
}

/// How a chart's reading stands: its series over the range, its totals,
/// when it was read, why not.
struct KubeChartReading: Equatable, Sendable {
    var range: KubeChartRange
    var series: [KubeChartMeasure: [KubeSeriesPoint]] = [:]
    var totals: [KubeChartMeasure: Double] = [:]
    var read: Date?
    var problem: String?

    /// `used` against `of`, as the Overview says it: `1.2 of 4 cores · 30%`.
    func share(_ used: KubeChartMeasure, of total: KubeChartMeasure) -> (used: Double, total: Double, percent: Int?)? {
        guard let value = totals[used] else { return nil }
        let whole = totals[total] ?? 0
        return (value, whole, KubeMetricsFormat.percent(value, of: whole > 0 ? whole : nil))
    }
}

/// A claim's volume usage, as the PVC list's column says it. Pure.
struct KubeVolumeUsage: Equatable, Sendable {
    var used: Double
    var capacity: Double?

    var percent: Int? { KubeMetricsFormat.percent(used, of: capacity) }

    var text: String {
        KubeVolumeFormat.bytes(used) + (capacity.map { " of \(KubeVolumeFormat.bytes($0))" } ?? "") + (percent.map { " (\($0)%)" } ?? "")
    }

    /// The two instant answers by claim, put together.
    static func by(used: [KubeSeries], capacity: [KubeSeries]) -> [KubeRowID: KubeVolumeUsage] {
        func id(_ labels: [String: String]) -> KubeRowID? {
            guard let claim = labels["persistentvolumeclaim"] else { return nil }
            return KubeRowID(namespace: labels["namespace"], name: claim)
        }
        var capacities: [KubeRowID: Double] = [:]
        for series in capacity { if let id = id(series.labels), let value = series.points.last?.value { capacities[id] = value } }
        var out: [KubeRowID: KubeVolumeUsage] = [:]
        for series in used {
            guard let id = id(series.labels), let value = series.points.last?.value else { continue }
            out[id] = KubeVolumeUsage(used: value, capacity: capacities[id])
        }
        return out
    }
}

/// Bytes as `kubectl` says capacities: Ki, Mi, Gi, Ti, one decimal under ten. Pure.
enum KubeVolumeFormat {
    static func bytes(_ value: Double) -> String {
        let units: [(String, Double)] = [("Ti", 1_099_511_627_776), ("Gi", 1_073_741_824), ("Mi", 1_048_576), ("Ki", 1024)]
        for (unit, scale) in units where value >= scale {
            let scaled = value / scale
            return (scaled < 10 ? String(format: "%.1f", scaled) : String(Int(scaled.rounded()))) + unit
        }
        return "\(Int(value.rounded()))B"
    }
}
