import Foundation

/// Why a chart is empty or partial, in one sentence each — table-driven,
/// so every chart says the same thing for the same cause, and each cause
/// has its test (metrics.md, 3.10, 4.7). A footnote is said under a chart
/// that still draws; the others stand in its place. Pure.
enum KubeChartEmpty: Equatable, Sendable {
    /// No metrics.k8s.io, and Prometheus not on.
    case noMetricsServer
    /// No metrics.k8s.io, Prometheus on: the pod's chart is on its Overview.
    case noMetricsServerChartOnOverview
    /// kube-state-metrics isn't scraped: no requests or limits.
    case ksmMissing
    /// kube-state-metrics 1.x: its old metric names (a footnote).
    case ksmOld
    /// The kubelet reports no CFS periods.
    case noThrottling
    /// A query `KubeQueryCost` refuses before it is sent: what it would
    /// read, over which span, about how many samples (nil, not counted),
    /// whether the server has recording rules, and what to pick instead.
    case costRefused(what: String, span: String, samples: Int?, rules: Bool, pick: String)
    /// Prometheus' own `timeout`, or Overterm's deadline after it.
    case timeout
    /// `bad_data`: Prometheus refused the query — a bug report.
    case badData(String)
    /// Thanos' (or a federation's) partial answer (a footnote).
    case partial(String)
    /// The pod started inside the window: the time before it is hatched.
    case youngPod(Date)
    /// The Service answers but only forwards metrics (Prometheus' agent mode).
    case agentMode(KubePrometheusService)
    /// The apiserver refused `get services/proxy` in the Service's namespace.
    case serviceProxyForbidden(KubePrometheusService)
    /// metrics.k8s.io refused: `verb resource` and where (" in shop", "").
    case metricsServerForbidden(verb: String, resource: String, place: String)
    /// The context's sign-in failed: its own sentence (the context's card has the button).
    case credential(String)
    /// The metrics proxy's own filter answered 403 — only a bug can send it
    /// a path it refuses, since every query is one of the two it accepts.
    case filterRefused
    /// Sampled, and the requests line needs the pods' specs.
    case requestsNeedSpecs
    /// A 429 or 503 from the service proxy: paused for its `Retry-After`.
    case busy(status: Int, retryAfter: Int?)
    /// Prometheus keeps data from this time: the chart hatches before it (a footnote).
    case retention(Date)
    /// The Pods list's shares, without Prometheus: the rows carry no spec (decision 10).
    case sharesNeedPrometheus
    /// The Pods list's shares across every namespace: read a namespace at a time.
    case sharesNeedNamespaces
    /// kube-state-metrics' answer for the namespace's shares cut at the reader's cap.
    case sharesCut(String)
    /// kube-state-metrics isn't scraped: no requests or limits to share against.
    case sharesNeedKSM
    /// `k8s_top` across a namespace without the specs in hand.
    case topSharesNeedSpecs
    /// `k8s_top`'s shares across every namespace (or more than a page reads): none asked.
    case topSharesNeedNamespaces

    var sentence: String {
        switch self {
        case .noMetricsServer:
            return "No metrics-server in this cluster: there are no usage numbers without it or Prometheus."
        case .noMetricsServerChartOnOverview:
            return "No metrics-server in this cluster: the Metrics tab's sampled charts need it. The pod's Prometheus chart is on the Overview tab."
        case .ksmMissing:
            return "kube-state-metrics isn't scraped: no requests or limits over time."
        case .ksmOld:
            return "kube-state-metrics is older than 2.0; requests and limits use its old names."
        case .noThrottling:
            return "This cluster's kubelet doesn't report CPU throttling."
        case .costRefused(let what, let span, let samples, let rules, let pick):
            let read = samples.map { " would read about \(KubeQueryCost.said($0)) samples" } ?? " are too many samples to read"
            return "\(what) over \(span)\(read)" + (rules ? "" : ", and this Prometheus has no recording rules") + ". Pick \(pick)."
        case .timeout:
            return "Prometheus took longer than \(Int(KubePromQL.timeout)) s. Pick a shorter range."
        case .badData(let error):
            let said = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Prometheus refused the query: \(said.prefix(KubePrometheusReader.maxNoteLength))" + (said.hasSuffix(".") ? "" : ".")
        case .partial(let warning):
            return "Partial answer: \(warning)"
        case .youngPod(let started):
            return "Pod started \(KubeChartEmpty.clock(started))"
        case .agentMode(let service):
            return "Prometheus at \(service.namespace)/\(service.name) only forwards metrics to a remote store (agent mode); it can't be asked."
        case .serviceProxyForbidden(let service):
            return "You can't reach \(service.namespace)/\(service.name) here: `get services/proxy` is refused in \(service.namespace)."
        case .metricsServerForbidden(let verb, let resource, let place):
            return "metrics-server answered 403: you can't \(verb) \(resource)\(place)."
        case .credential(let reason):
            return reason
        case .filterRefused:
            return "Overterm's metrics proxy refused this path."
        case .requestsNeedSpecs:
            return "Requests need the pods' specs; pick one node or turn Prometheus on."
        case .busy(let status, let retryAfter):
            return "Prometheus is busy (HTTP \(status))" + (retryAfter.map { "; asked again in \($0) s." } ?? "; asked again at the next refresh.")
        case .retention(let date):
            return "Prometheus keeps data from \(KubeChartEmpty.day(date))"
        case .sharesNeedPrometheus:
            return "Shares of request and limit need each pod's spec, which the list's rows don't carry: turn Prometheus on for this context (its kube-state-metrics has them)."
        case .sharesNeedNamespaces:
            return "Shares of request and limit are read a namespace at a time: pick one, or up to \(KubeScope.watchCap) (n)."
        case .sharesCut(let namespace):
            return "\(namespace) has more than \(KubePodShares.maxPods) pods: kube-state-metrics' answer for their shares is cut, so none is shown."
        case .topSharesNeedSpecs:
            return "Shares of request and limit need the pods' specs: name a pod, or turn Prometheus on for this context (its kube-state-metrics has them)."
        case .topSharesNeedNamespaces:
            return "Shares of request and limit are read a namespace at a time: name one, or up to \(KubeScope.watchCap) (or a pod)."
        case .sharesNeedKSM:
            return "kube-state-metrics isn't scraped: there are no requests or limits to share against."
        }
    }

    /// Said under a chart that still draws, rather than in its place.
    var isFootnote: Bool {
        switch self {
        case .ksmOld, .partial, .retention, .youngPod: true
        default: false
        }
    }

    /// The query is worth reporting: Copy PromQL is offered beside it.
    var offersCopyPromQL: Bool {
        switch self {
        case .badData, .filterRefused: true
        default: false
        }
    }

    /// `14:02`, in the time zone shown everywhere else (local).
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `Oct 28` — month names in English whatever the locale (the page's language).
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
