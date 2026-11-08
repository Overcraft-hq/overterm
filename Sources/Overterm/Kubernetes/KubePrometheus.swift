import Foundation

/// Prometheus per context (stage 4; docs/design/kubernetes/analysis.md,
/// 2.1, 2.11, 2.17, Section 4's Prometheus, decision 16). Pure.
///
/// Opt-in: a context's `metrics` is `prometheus` (or `auto`, set in its
/// entry), or its entry names a `prometheus` service. The service is found
/// as Freelens finds it — Lens's own `lens-metrics/prometheus`, the
/// operator's `operated-prometheus=true`, the prometheus Helm chart's
/// `app.kubernetes.io/*` labels (v15 on) and its older
/// `app=prometheus,component=server,heritage=Helm` — by a GET through the
/// context's own proxy,
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
///
/// The prometheus Helm chart labels its Service `app.kubernetes.io/*`
/// since v15 (2022); before, `app=prometheus,component=server,heritage=Helm`
/// — both are looked for, the current one first (metrics.md, 1.1).
enum KubePrometheusProvider: String, CaseIterable, Sendable {
    case lens, operatorManaged, helm, helm14

    var title: String {
        switch self {
        case .lens: "Lens metrics (lens-metrics/prometheus)"
        case .helm, .helm14: "the prometheus Helm chart"
        case .operatorManaged: "the Prometheus Operator"
        }
    }

    static let helmSelector = "app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server,app.kubernetes.io/managed-by=Helm"
    /// The chart before v15.
    static let helm14Selector = "app=prometheus,component=server,heritage=Helm"
    static let operatorSelector = "operated-prometheus=true"

    /// The one GET that looks for it, through the context's own proxy.
    var path: String {
        switch self {
        case .lens: "/api/v1/namespaces/lens-metrics/services/prometheus"
        case .helm: KubePath.query("/api/v1/services", [("labelSelector", Self.helmSelector), ("limit", "20")])
        case .helm14: KubePath.query("/api/v1/services", [("labelSelector", Self.helm14Selector), ("limit", "20")])
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
        "No Prometheus found: none at lens-metrics/prometheus, and no Service labelled \(KubePrometheusProvider.operatorSelector), \(KubePrometheusProvider.helmSelector) or \(KubePrometheusProvider.helm14Selector). Name one in the context's prometheus setting (namespace/service:port). Overterm installs nothing."
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

    /// A `rate()`'s window (`KubeRateWindow`), the scrape taken as a
    /// minute until a probe says otherwise.
    var rateWindow: String { KubePromQL.duration(KubeRateWindow.of(step: step, scrape: KubeRateWindow.assumedScrape)) }

    /// Raw cAdvisor across the whole cluster is read up to this range: past
    /// it, about 10k series on a 2–5k-pod cluster are tens of millions of
    /// samples, against Prometheus' `query.max-samples` and its timeout.
    static let rawClusterLimit: KubeChartRange = .sixHours

    var allowsRawAcrossCluster: Bool { seconds <= Self.rawClusterLimit.seconds }

    /// `[start, end]` ending at `now` rounded down to a step, so a chart
    /// asked again within a step asks the same.
    func window(now: Date) -> (start: Date, end: Date) {
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        return (end.addingTimeInterval(-seconds), end)
    }
}

/// A `rate()`'s window, Grafana's `$__rate_interval`: a step and a scrape,
/// four scrapes at least, rounded up to a whole minute — a window of one
/// scrape holds 0 or 1 samples and `rate` answers nothing (Prometheus 3's
/// left-open range selectors make it worse). Pure (metrics.md, 1.1).
enum KubeRateWindow {
    /// The prometheus chart's default scrape interval: what is assumed until
    /// a probe reads the cAdvisor job's own.
    static let assumedScrape: TimeInterval = 60

    static func of(step: TimeInterval, scrape: TimeInterval) -> TimeInterval {
        let window = max(step + scrape, 4 * scrape)
        return (window / 60).rounded(.up) * 60
    }
}

/// The queries, Freelens's (cAdvisor, kube-state-metrics, kubelet), each
/// series de-duplicated before it is summed: a container's gauge is its
/// highest series (`max by` container — a restarted container's old series
/// lingers until it goes stale, and a sum would count it twice right where
/// an OOM is looked at), its counters' rates summed by container (a dead
/// counter's rate falls to 0), kube-state-metrics' series taken `max by`
/// what identifies them (two replicas, or two jobs, scrape the same), and
/// requests and limits only of active pods (KSM keeps Succeeded and Failed
/// ones until they are deleted). Pure (metrics.md, 1.1, 4.2).
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

    /// A regex matcher's value inside its string: RE2's metacharacters
    /// escaped — first, then `literal` — so a `.` in a name is `\\.` in
    /// the query, its backslash kept. Prometheus anchors it.
    static func regexLiteral(_ text: String) -> String {
        var out = ""
        for character in text {
            if #"\.+*?()|[]{}^$"#.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// `namespace="shop"`, or `namespace=~"a|b"` for several.
    static func namespaces(_ names: [String]) -> String {
        if names.count == 1 { return matchers([("namespace", names[0])]) }
        return "namespace=~\"" + literal(names.map(regexLiteral).joined(separator: "|")) + "\""
    }

    /// cAdvisor's containers: not the pod's sandbox (`POD`, or none), not a
    /// cgroup without an image.
    static let containers = #"container!="",image!="",container!="POD""#

    /// A container's gauge, one series a container — cAdvisor's path and
    /// job pinned where the profile found two.
    static func containerGauge(_ metric: String, _ filter: String = "", profile: KubePromProfile = .unknown) -> String {
        "max by (namespace,pod,container)(\(metric){\(profile.cadvisorMatchers)\(filter.isEmpty ? "" : "," + filter)})"
    }

    /// A container's counter's rate, one series a container.
    static func containerRate(_ metric: String, _ filter: String = "", window: String, profile: KubePromProfile = .unknown) -> String {
        "sum by (namespace,pod,container)(rate(\(metric){\(profile.cadvisorMatchers)\(filter.isEmpty ? "" : "," + filter)}[\(window)]))"
    }

    /// The pods kube-state-metrics says are Pending or Running: 1 each.
    static let activePods = active(profile: .unknown)

    static func active(profile: KubePromProfile) -> String {
        let job = profile.ksmMatcher
        return "max by (namespace,pod)(kube_pod_status_phase{\(job.isEmpty ? "" : job + ",")phase=~\"Pending|Running\"} == 1)"
    }

    static func podCPU(namespace: String, pod: String, window: String, profile: KubePromProfile = .unknown) -> String {
        "sum(" + containerRate("container_cpu_usage_seconds_total", matchers([("namespace", namespace), ("pod", pod)]), window: window, profile: profile) + ")"
    }

    static func podMemory(namespace: String, pod: String, profile: KubePromProfile = .unknown) -> String {
        "sum(" + containerGauge("container_memory_working_set_bytes", matchers([("namespace", namespace), ("pod", pod)]), profile: profile) + ")"
    }

    /// A pod's CPU and memory from the mixin's per-container rules (`rule` the CPU one the profile found).
    static func podCPURule(_ rule: String, namespace: String, pod: String) -> String {
        "sum(max by (container)(\(rule){\(matchers([("namespace", namespace), ("pod", pod)])),container!=\"\",container!=\"POD\"}))"
    }

    static func podMemoryRule(namespace: String, pod: String) -> String {
        "sum(max by (container)(\(KubePromProfile.containerMemoryRule){\(matchers([("namespace", namespace), ("pod", pod)])),container!=\"\",container!=\"POD\"}))"
    }

    static func clusterCPU(window: String, profile: KubePromProfile = .unknown) -> String {
        "sum(" + containerRate("container_cpu_usage_seconds_total", window: window, profile: profile) + ")"
    }

    static let clusterMemory = clusterMemory(profile: .unknown)

    static func clusterMemory(profile: KubePromProfile) -> String { "sum(" + containerGauge("container_memory_working_set_bytes", profile: profile) + ")" }

    /// The cluster's CPU and memory from the mixin's node rules: each
    /// node's utilisation times its CPUs (its memory).
    static let ruleClusterCPU = "sum(\(KubePromProfile.nodeCPURule) * on(instance) \(KubePromProfile.nodeCPUCountRule))"
    static let ruleClusterMemory = "sum(\(KubePromProfile.nodeMemoryRule) * on(instance) node_memory_MemTotal_bytes)"

    /// The cluster's CPU and memory from node-exporter: busy CPU time,
    /// memory not available.
    static func nodeClusterCPU(window: String) -> String { "sum(rate(node_cpu_seconds_total{mode!~\"idle|iowait|steal\"}[\(window)]))" }
    static let nodeClusterMemory = "sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)"

    /// kube-state-metrics' requests and limits of active pods, and the
    /// nodes' allocatable, summed — its 1.x names where that is what it
    /// is, the mixin's active-pod rules where it has them.
    static func requests(_ resource: String, profile: KubePromProfile = .unknown) -> String { resourceSum("requests", resource, profile) }
    static func limits(_ resource: String, profile: KubePromProfile = .unknown) -> String { resourceSum("limits", resource, profile) }

    static func allocatable(_ resource: String, profile: KubePromProfile = .unknown) -> String {
        if profile.ksmMajor == 1 { return "sum(max by (node)(kube_node_status_allocatable_\(oldSuffix(resource)){\(profile.ksmMatcher)}))" }
        let job = profile.ksmMatcher
        return "sum(max by (node)(kube_node_status_allocatable{\(job.isEmpty ? "" : job + ",")resource=\"\(literal(resource))\"}))"
    }

    /// kube-state-metrics 1.x's suffixes: `cpu_cores`, `memory_bytes`.
    private static func oldSuffix(_ resource: String) -> String { resource == "cpu" ? "cpu_cores" : resource + "_bytes" }

    private static func resourceSum(_ which: String, _ resource: String, _ profile: KubePromProfile) -> String {
        if profile.hasActiveRules {
            // The rule keeps kube-state-metrics' `instance`: two replicas, two of each series.
            return "sum(max by (namespace,pod,container,node)(cluster:namespace:pod_\(resource == "cpu" ? "cpu" : "memory"):active:kube_pod_container_resource_\(which)))"
        }
        let job = profile.ksmMatcher
        let selector: String
        if profile.ksmMajor == 1 {
            selector = "kube_pod_container_resource_\(which)_\(oldSuffix(resource)){\(job)}"
        } else {
            selector = "kube_pod_container_resource_\(which){\(job.isEmpty ? "" : job + ",")resource=\"\(literal(resource))\"}"
        }
        return "sum(max by (namespace,pod,container,node)(\(selector)) * on(namespace,pod) group_left() \(active(profile: profile)))"
    }

    /// kubelet's volume stats, by claim — a namespace's, several, or every one's.
    static func volumes(_ metric: String, namespaces names: [String]?) -> String {
        let filter = names.map { "{\(namespaces($0))}" } ?? ""
        return "sum by (namespace, persistentvolumeclaim) (\(metric)\(filter))"
    }

    static func volume(_ metric: String, namespace: String, claim: String) -> String {
        "sum(\(metric){\(matchers([("namespace", namespace), ("persistentvolumeclaim", claim)]))})"
    }

    static let volumeUsed = "kubelet_volume_stats_used_bytes"
    static let volumeCapacity = "kubelet_volume_stats_capacity_bytes"

    /// How long Prometheus may take over a query (`timeout`), and how long
    /// Overterm waits for its answer: a slow query otherwise holds its place
    /// until the HTTP timeout.
    static let timeout: TimeInterval = 20
    static let deadline: Duration = .seconds(25)

    static func rangePath(_ service: KubePrometheusService, _ query: String, _ range: KubeChartRange, now: Date) -> String {
        let (start, end) = range.window(now: now)
        return KubePath.query(
            service.rangePath,
            [("query", query), ("start", stamp(start)), ("end", stamp(end)), ("step", duration(range.step)), ("timeout", duration(timeout))])
    }

    static func instantPath(_ service: KubePrometheusService, _ query: String) -> String {
        KubePath.query(service.queryPath, [("query", query), ("timeout", duration(timeout))])
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

/// Prometheus's HTTP API answers read: a matrix (`query_range`), a vector
/// or a scalar (`query`), bounded, the values that aren't numbers (`NaN`,
/// `+Inf`) left out; native-histogram series skipped and counted; its
/// warnings and infos (Thanos' partial responses) kept as notes, said
/// under the chart. Pure (metrics.md, 1.1).
enum KubePrometheusReader {
    static let maxSeries = 2000
    static let maxPoints = 2000
    /// An answer larger than this isn't parsed: a runaway query, or a
    /// Prometheus misbehaving — said, never handed whole to the parser.
    static let maxBytes = 8 << 20
    /// The notes kept of an answer, each cut to this.
    static let maxNotes = 3
    static let maxNoteLength = 253

    struct Failure: Error, LocalizedError, Equatable {
        /// What failed, as the queue and the probe act on it.
        enum Kind: Equatable, Sendable {
            /// Prometheus' `timeout`, or the deadline after it.
            case timeout
            /// `bad_data`: Prometheus refused the query.
            case badData
            /// The server only forwards metrics (agent mode).
            case agentMode
            /// A 404 that isn't the apiserver's: the Service answers, its query API doesn't.
            case notFound
            /// A 422: the query couldn't be executed (the probe is asked again).
            case unprocessable
            /// The apiserver's 404: no such Service, or no endpoints.
            case serviceMissing
            /// The apiserver's 403: `get services/proxy` refused.
            case serviceProxyForbidden
            /// The metrics proxy's own filter: a path it doesn't accept.
            case filterRefused
            /// A 429, or a 503 with a `Retry-After`: that honoured.
            case busy
            case other
        }

        var message: String
        var kind: Kind = .other
        /// A busy answer's `Retry-After`, in seconds.
        var retryAfter: TimeInterval?
        var errorDescription: String? { message }

        /// It stops the context's queries: asking again changes nothing
        /// until its credentials do (a 403), or until the pause ends.
        var stopsQueries: Bool { kind == .serviceProxyForbidden || kind == .busy }
    }

    /// One answer: its series, what Prometheus said beside them, its type.
    struct Answer: Equatable, Sendable {
        var series: [KubeSeries] = []
        var notes: [String] = []
        var resultType = ""
    }

    /// Prometheus' own timeout (`timeout=20s`), or Overterm's deadline after it.
    static let tookTooLong = KubeChartEmpty.timeout.sentence

    static func read(_ data: Data, status: Int = 200) throws -> [KubeSeries] { try answer(data, status: status).series }

    /// An HTTP answer read: its body, its status, a busy one's `Retry-After`.
    static func answer(_ response: HTTPResponse) throws -> Answer {
        let after = retryAfter(response.header("Retry-After"))
        do {
            return try answer(response.body, status: response.status, retryAfter: after)
        } catch var failure as Failure where failure.kind == .busy {
            failure.retryAfter = after
            failure.message = KubeChartEmpty.busy(status: response.status, retryAfter: after.map { Int($0) }).sentence
            throw failure
        }
    }

    /// A `Retry-After` the queue honours: a whole number of seconds, not
    /// negative, at most `KubePromQueue.maxPause` — the pause the queue
    /// takes and the one the sentence says are the same. An HTTP-date, a
    /// fraction, `nan` or `1e300` are read as none (the server's text never
    /// reaches a conversion that can trap).
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), text.count <= 12, let seconds = Int(text), seconds >= 0 else { return nil }
        return TimeInterval(min(seconds, Int(KubePromQueue.maxPause)))
    }

    /// `retryAfter`: the answer's, read by `retryAfter(_:)`. A 429 is busy;
    /// a 503 only with a `Retry-After` — without one it is a server down or
    /// not ready (the apiserver's "no endpoints available"), said as it is.
    static func answer(_ data: Data, status: Int = 200, retryAfter: TimeInterval? = nil) throws -> Answer {
        guard data.count <= maxBytes else {
            throw Failure(message: "Prometheus's answer is too large (\(data.count / 1_048_576) MB, at most \(maxBytes / 1_048_576) MB is read).")
        }
        let busy = status == 429 || (status == 503 && retryAfter != nil)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // kubectl proxy's filter answers a plain `Forbidden`.
            if status == 403, text == "Forbidden" { throw Failure(message: KubeChartEmpty.filterRefused.sentence, kind: .filterRefused) }
            let kind: Failure.Kind = busy ? .busy : status == 404 ? .notFound : status == 422 ? .unprocessable : .other
            throw Failure(message: status == 200 ? "Prometheus's answer isn't JSON." : "Prometheus answered \(status)\(text.isEmpty ? "" : ": \(text)")", kind: kind)
        }
        if object["kind"] as? String == "Status" {
            // The apiserver's own answer: the Service isn't there, has no endpoints, is refused.
            let kind: Failure.Kind = status == 403 ? .serviceProxyForbidden : status == 404 ? .serviceMissing : busy ? .busy : .other
            throw Failure(message: "The service proxy answered \(status): " + (object["message"] as? String ?? "no reason given"), kind: kind)
        }
        if object["status"] as? String != "success" {
            let type = object["errorType"] as? String
            let error = object["error"] as? String ?? "HTTP \(status)"
            if type == "timeout" { throw Failure(message: tookTooLong, kind: .timeout) }
            if type == "bad_data" { throw Failure(message: KubeChartEmpty.badData(error).sentence, kind: .badData) }
            // An agent's every query: `unavailable with Prometheus Agent`.
            if error.range(of: "agent", options: .caseInsensitive) != nil, type == "unavailable" || busy || status == 422 {
                throw Failure(message: "Prometheus: \(error)", kind: .agentMode)
            }
            let kind: Failure.Kind = busy ? .busy : status == 404 ? .notFound : status == 422 ? .unprocessable : .other
            throw Failure(message: "Prometheus: " + (type.map { "\($0): " } ?? "") + error, kind: kind)
        }
        guard let body = object["data"] as? [String: Any] else { throw Failure(message: "Prometheus's answer has no result.") }
        var answer = Answer(resultType: body["resultType"] as? String ?? "")
        var notes = (object["warnings"] as? [String] ?? []).map { KubeChartEmpty.partial($0).sentence }
        notes += (object["infos"] as? [String] ?? []).map { "Prometheus notes: " + $0 }
        if answer.resultType == "scalar" {
            // `[time, "value"]`, no labels.
            guard let pair = body["result"] as? [Any] else { throw Failure(message: "Prometheus's answer has no result.") }
            answer.series = [KubeSeries(labels: [:], points: point(pair).map { [$0] } ?? [])]
        } else if answer.resultType == "string" {
            answer.series = []
        } else {
            guard let result = body["result"] as? [[String: Any]] else { throw Failure(message: "Prometheus's answer has no result.") }
            var histograms = 0
            for item in result {
                var raw: [[Any]] = []
                if let values = item["values"] as? [[Any]] { raw = values }
                if let value = item["value"] as? [Any] { raw = [value] }
                // A native histogram's series carries `histogram(s)` and no float to draw.
                if raw.isEmpty, item["histogram"] != nil || item["histograms"] != nil {
                    histograms += 1
                    continue
                }
                guard answer.series.count < maxSeries else { continue }
                let labels = (item["metric"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
                answer.series.append(KubeSeries(labels: labels, points: raw.suffix(maxPoints).compactMap(point)))
            }
            if histograms > 0 { notes.append("\(histograms) native-histogram series skipped: only float series are drawn.") }
            if result.count - histograms > maxSeries { notes.append("Prometheus answered \(result.count - histograms) series; the first \(maxSeries) are read.") }
        }
        answer.notes = notes.prefix(maxNotes).map { String($0.prefix(maxNoteLength)) }
        return answer
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

    /// A line's runs: broken where two points are more than two steps
    /// apart — a gap drawn as a gap, never bridged nor drawn as zero.
    static func segments(_ points: [KubeSeriesPoint], step: TimeInterval) -> [[KubeSeriesPoint]] {
        var runs: [[KubeSeriesPoint]] = []
        for point in points {
            if let last = runs.last?.last, point.time.timeIntervalSince(last.time) <= 2 * step {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs
    }
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

/// What a chart asks over a range: range queries (its lines), instant
/// ones (its totals), and why a line isn't asked, when it isn't; the tier
/// its lines read and what the profile has it say beside them.
struct KubeChartQueries {
    var series: [(KubeChartMeasure, String)]
    var totals: [(KubeChartMeasure, String)]
    /// Said in place of the lines it doesn't ask.
    var refused: String?
    var tier: KubePromTier?
    /// Footnotes and sentences from the profile (kube-state-metrics old or missing).
    var notes: [String] = []
}

extension KubeChart {
    /// Raw cAdvisor across the cluster past `KubeChartRange.rawClusterLimit`.
    static func rawRefusal(_ range: KubeChartRange) -> String {
        "Raw container metrics across the cluster are read over \(KubeChartRange.rawClusterLimit.title) at most: over \(range.title) they would be tens "
            + "of millions of samples, more than Prometheus answers in time. Pick \(KubeChartRange.rawClusterLimit.title) or less."
    }

    /// Its place among the charts on screen, top first: the queue's order.
    var order: Int {
        switch self {
        case .cluster: 0
        case .pod: 1
        case .volume: 2
        }
    }

    /// Whether its queries depend on what the context's Prometheus holds
    /// (the probe runs for it): a volume's don't.
    var needsProfile: Bool {
        if case .volume = self { return false }
        return true
    }

    /// The cluster's lines' tier over `range`: the mixin's node rules,
    /// node-exporter, else raw cAdvisor where `KubeQueryCost` allows it;
    /// nil, none can be read.
    static func clusterTier(_ range: KubeChartRange, profile: KubePromProfile) -> KubePromTier? {
        if profile.hasNodeRules { return .rules }
        if profile.hasNodeExporter { return .nodeExporter }
        return KubeQueryCost.raw(.cluster, span: range.seconds, profile: profile).isAllowed ? .raw : nil
    }

    /// A pod's lines' tier: raw cAdvisor over an hour or less, where one
    /// pod's series are cheap and a 5-minute rule would smooth a spike
    /// away; the rules past it, where they exist.
    static func podTier(_ range: KubeChartRange, profile: KubePromProfile) -> KubePromTier {
        range.seconds > KubeChartRange.hour.seconds && profile.hasContainerRules ? .rules : .raw
    }

    /// The range queries (charts) and the instant ones (totals) this chart
    /// asks, read in the tier the profile allows, pinned as it says.
    func queries(range: KubeChartRange, profile: KubePromProfile = .unknown) -> KubeChartQueries {
        let window = KubePromQL.duration(KubeRateWindow.of(step: range.step, scrape: profile.scrapeInterval))
        switch self {
        case .cluster:
            var totals: [(KubeChartMeasure, String)] = []
            var notes: [String] = []
            if profile.ksmMissing {
                notes.append(KubeChartEmpty.ksmMissing.sentence)
            } else {
                if profile.ksmMajor == 1 { notes.append(KubeChartEmpty.ksmOld.sentence) }
                totals = [
                    (.cpuRequests, KubePromQL.requests("cpu", profile: profile)), (.cpuLimits, KubePromQL.limits("cpu", profile: profile)),
                    (.cpuAllocatable, KubePromQL.allocatable("cpu", profile: profile)),
                    (.memoryRequests, KubePromQL.requests("memory", profile: profile)), (.memoryLimits, KubePromQL.limits("memory", profile: profile)),
                    (.memoryAllocatable, KubePromQL.allocatable("memory", profile: profile)),
                ]
            }
            switch Self.clusterTier(range, profile: profile) {
            case .rules:
                return KubeChartQueries(
                    series: [(.cpu, KubePromQL.ruleClusterCPU), (.memory, KubePromQL.ruleClusterMemory)], totals: totals, tier: .rules, notes: notes)
            case .nodeExporter:
                return KubeChartQueries(
                    series: [(.cpu, KubePromQL.nodeClusterCPU(window: window)), (.memory, KubePromQL.nodeClusterMemory)], totals: totals,
                    tier: .nodeExporter, notes: notes)
            case .raw:
                return KubeChartQueries(
                    series: [(.cpu, KubePromQL.clusterCPU(window: window, profile: profile)), (.memory, KubePromQL.clusterMemory(profile: profile))],
                    totals: totals, tier: .raw, notes: notes)
            case nil:
                // Known: the samples it would read; unknown: as before the probe.
                let refused = profile.known ? KubeQueryCost.raw(.cluster, span: range.seconds, profile: profile).sentence : nil
                return KubeChartQueries(series: [], totals: totals, refused: refused ?? Self.rawRefusal(range), notes: notes)
            }
        case .pod(let namespace, let name):
            switch Self.podTier(range, profile: profile) {
            case .rules:
                return KubeChartQueries(
                    series: [
                        (.cpu, KubePromQL.podCPURule(profile.containerCPURule ?? KubePromProfile.containerCPURate5m, namespace: namespace, pod: name)),
                        (.memory, KubePromQL.podMemoryRule(namespace: namespace, pod: name)),
                    ], totals: [], tier: .rules)
            default:
                return KubeChartQueries(
                    series: [
                        (.cpu, KubePromQL.podCPU(namespace: namespace, pod: name, window: window, profile: profile)),
                        (.memory, KubePromQL.podMemory(namespace: namespace, pod: name, profile: profile)),
                    ], totals: [], tier: .raw)
            }
        case .volume(let namespace, let claim):
            return KubeChartQueries(
                series: [
                    (.volumeUsed, KubePromQL.volume(KubePromQL.volumeUsed, namespace: namespace, claim: claim)),
                    (.volumeCapacity, KubePromQL.volume(KubePromQL.volumeCapacity, namespace: namespace, claim: claim)),
                ], totals: [])
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
    /// What Prometheus said beside its answers (warnings, infos), and the
    /// profile's footnotes, said under the chart.
    var notes: [String] = []
    /// Why its lines weren't asked over this range (`KubeChartQueries.refused`).
    var refused: String?
    /// The form its lines were read in, and what the caption says of it.
    var tier: KubePromTier?
    var caption: String?
    /// Prometheus keeps data from then: hatched before it.
    var retention: Date?
    /// Why nothing is asked at all (agent mode): said in the chart's place.
    var unavailable: String?

    /// `used` against `of`, as the Overview says it: `1.2 of 4 cores · 30%`.
    func share(_ used: KubeChartMeasure, of total: KubeChartMeasure) -> (used: Double, total: Double, percent: Int?)? {
        guard let value = totals[used] else { return nil }
        let whole = totals[total] ?? 0
        return (value, whole, KubeMetricsFormat.percent(value, of: whole > 0 ? whole : nil))
    }

    /// The caption's tail: the tier, the scrape the profile read —
    /// `recording rules (5 min averages) · scrape 30s`, `raw cAdvisor (≤ 6h)`.
    static func caption(_ tier: KubePromTier?, chart: KubeChart, profile: KubePromProfile) -> String? {
        guard let tier else { return nil }
        var text = tier.title
        if tier == .rules { text += " (5 min averages)" }
        if tier == .raw, chart == .cluster { text += " (≤ \(KubeChartRange.rawClusterLimit.title))" }
        if let scrape = profile.scrape { text += " · scrape \(KubePromQL.duration(scrape))" }
        return text
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
