import Foundation

/// What a query would cost, decided before it is sent, from the context's
/// probed profile (metrics.md, 4.5, 6.3): raw cAdvisor across the cluster
/// only over 6 h or less; across a namespace only below 2,000 series;
/// a subquery (a peak band, sizing) only for one pod or container, one
/// workload of at most 50 pods, or where recording rules exist; a regex of
/// names 50 at most. A samples estimate — series × span ÷ scrape — says
/// how much a refused one would read. A refused query is never sent; its
/// sentence (`KubeChartEmpty.costRefused`) says why and what to pick. Pure.
enum KubeQueryCost {
    /// Raw cAdvisor across the whole cluster, at most this span.
    static let rawClusterSpan: TimeInterval = 6 * 3600
    /// Raw cAdvisor across one namespace, below this many series.
    static let rawNamespaceSeries = 2000
    /// The top-N ranking reads every raw sample of its span: under this, at any span.
    static let rankingSamples = 10_000_000
    /// A ranking past `rankingSamples` ranks over this span instead.
    static let rankingFallback: TimeInterval = 24 * 3600
    /// The most names a regex of pods holds; beyond, pods are selected by owner.
    static let maxNames = 50
    /// The most pods a workload's subquery covers without recording rules.
    static let maxSubqueryPods = 50

    /// Whom a query covers.
    enum Scope: Equatable, Sendable {
        case cluster
        /// A namespace, with its cAdvisor series counted (nil: not yet).
        case namespace(String, series: Int?)
        case pod
        case workload(pods: Int)
    }

    enum Verdict: Equatable, Sendable {
        case allowed
        case refused(KubeChartEmpty)

        var isAllowed: Bool { self == .allowed }
        var sentence: String? {
            if case .refused(let why) = self { return why.sentence }
            return nil
        }
    }

    /// About how many raw samples `series` hold over `span` at `scrape`.
    static func samples(series: Int, span: TimeInterval, scrape: TimeInterval) -> Int {
        guard series > 0, span > 0, scrape > 0 else { return 0 }
        return Int((Double(series) * span / scrape).rounded())
    }

    /// `30M`, `450k`, `800`.
    static func said(_ samples: Int) -> String {
        if samples >= 1_000_000 { return "\(Int((Double(samples) / 1_000_000).rounded()))M" }
        if samples >= 1000 { return "\(Int((Double(samples) / 1000).rounded()))k" }
        return "\(samples)"
    }

    /// Raw cAdvisor over `scope` for `span`.
    static func raw(_ scope: Scope, span: TimeInterval, profile: KubePromProfile) -> Verdict {
        let series = profile.count(KubePromProfile.cpuMetric)
        switch scope {
        case .pod, .workload:
            return .allowed
        case .cluster:
            guard span > rawClusterSpan else { return .allowed }
            return .refused(
                .costRefused(
                    what: "Raw container metrics", span: KubePromQL.duration(span),
                    samples: series.map { samples(series: $0, span: span, scrape: profile.scrapeInterval) }, rules: profile.hasNodeRules,
                    pick: "\(KubePromQL.duration(rawClusterSpan)) or less"))
        case .namespace(let name, let counted):
            guard let counted else { return span > rawClusterSpan ? raw(.cluster, span: span, profile: profile) : .allowed }
            guard counted >= rawNamespaceSeries else { return .allowed }
            return .refused(
                .costRefused(
                    what: "Raw container metrics of \(name) (\(counted) series)", span: KubePromQL.duration(span),
                    samples: samples(series: counted, span: span, scrape: profile.scrapeInterval), rules: profile.hasContainerRules,
                    pick: "a workload in it"))
        }
    }

    /// A subquery (a peak band, sizing) over `scope`.
    static func subquery(_ scope: Scope, profile: KubePromProfile) -> Verdict {
        switch scope {
        case .pod: return .allowed
        case .workload(let pods) where pods <= maxSubqueryPods: return .allowed
        default:
            if profile.hasContainerRules { return .allowed }
            let what: String
            switch scope {
            case .workload(let pods): what = "A subquery over \(pods) pods"
            case .namespace(let name, _): what = "A subquery over \(name)"
            default: what = "A subquery across the cluster"
            }
            return .refused(.costRefused(what: what, span: "the range", samples: nil, rules: false, pick: "one workload of at most \(maxSubqueryPods) pods"))
        }
    }

    /// A regex of `count` pod names.
    static func names(_ count: Int) -> Verdict {
        guard count > maxNames else { return .allowed }
        return .refused(
            .costRefused(what: "A pattern of \(count) pods", span: "the range", samples: nil, rules: true, pick: "a workload, which selects its pods by owner"))
    }

    /// The span a raw CPU ranking reads: the range under `rankingSamples`,
    /// else the last 24 h, and the note that says so.
    static func rankingSpan(series: Int, span: TimeInterval, scrape: TimeInterval) -> (span: TimeInterval, note: String?) {
        guard samples(series: series, span: span, scrape: scrape) >= rankingSamples, span > rankingFallback else { return (span, nil) }
        return (rankingFallback, "ranked by the last \(KubePromQL.duration(rankingFallback))")
    }
}
