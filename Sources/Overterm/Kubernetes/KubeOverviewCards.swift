import Foundation

/// What the Overview's cards say (`KubeClusterOverviewView`), from the
/// overview and the health report it already has: the header's pills, a
/// kind's card (its number, its line, its bar), what needs attention as
/// rows worst first with a reason pill each, a usage's tone. Nothing read
/// here. Pure.
enum KubeOverviewCards {
    /// A status as the cards colour it — always said in words beside it.
    enum Tone: Int, Comparable, Sendable {
        case neutral, done, waiting, failed

        static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A small rounded capsule: its words and its tone.
    struct Pill: Equatable, Sendable {
        var text: String
        var tone: Tone
    }

    // MARK: The header

    /// `3 need attention` (failed) while anything fails, and
    /// `N checks pass` (done) once the health checks are read.
    static func pills(_ overview: KubeClusterOverview, health: KubeHealth.Report?) -> [Pill] {
        var pills: [Pill] = []
        if overview.problems > 0 { pills.append(Pill(text: "\(overview.problems) need\(overview.problems == 1 ? "s" : "") attention", tone: .failed)) }
        if let health {
            let passing = passingChecks(health)
            if passing > 0 { pills.append(Pill(text: "\(passing) check\(passing == 1 ? "" : "s") pass", tone: .done)) }
        }
        return pills
    }

    /// The checks that ran over lists read whole and found nothing — never
    /// one over a list refused, cut at its limit or not served (Argo CD's
    /// only where Argo CD answered): no all-clear for what wasn't checked.
    static func passingChecks(_ report: KubeHealth.Report) -> Int {
        let found = Set(report.findings.map(\.check))
        return report.ran.subtracting(found).count
    }

    /// The health report's severities as chips: `2 problems`, `5 warnings`.
    static func severities(_ report: KubeHealth.Report) -> [Pill] {
        var pills: [Pill] = []
        if report.errors > 0 { pills.append(Pill(text: "\(report.errors) problem\(report.errors == 1 ? "" : "s")", tone: .failed)) }
        if report.warnings > 0 { pills.append(Pill(text: "\(report.warnings) warning\(report.warnings == 1 ? "" : "s")", tone: .waiting)) }
        return pills
    }

    // MARK: A kind's card

    /// One kind's card: its count, its line (the counts the bar draws,
    /// said), its bar's parts, what its press shows.
    struct Kind: Equatable, Sendable, Identifiable {
        var title: String
        /// The list it opens: a kind's full name (`pods`, `deployments.apps`, `nodes`).
        var resource: String
        var total: Int
        var line: String
        var bar: [Segment]

        var id: String { resource }
    }

    struct Segment: Equatable, Sendable {
        var tone: Tone
        var count: Int
    }

    /// Pods, each workload kind the overview counted, and the nodes.
    static func kinds(_ overview: KubeClusterOverview) -> [Kind] {
        var kinds: [Kind] = []
        // By phase, as the server says it — a Running pod isn't said
        // ready (its probe may fail), a completed Job's pod isn't green — a
        // failing pod counted once, as failing, whatever its phase.
        let failing = overview.failingPods.count
        let failedPhase = (overview.phases["Failed"] ?? 0) + (overview.phases["Unknown"] ?? 0)
        let failingRunning = max(0, failing - overview.failingPending - failedPhase)
        let running = max(0, (overview.phases["Running"] ?? 0) - failingRunning)
        let completed = overview.phases["Succeeded"] ?? 0
        let pending = max(0, (overview.phases["Pending"] ?? 0) - overview.failingPending)
        kinds.append(
            Kind(
                title: "Pods", resource: KubeResourceKind.pods.fullName, total: overview.pods,
                line: said([(running, "running"), (completed, "completed"), (pending, "pending"), (failing, "failing")], total: overview.pods),
                bar: segments([(.done, running), (.neutral, completed), (.waiting, pending), (.failed, failing)])))
        for count in overview.workloads {
            let bad = count.notReady.count
            kinds.append(
                Kind(
                    title: count.title, resource: count.resource, total: count.total,
                    line: said([(count.total - bad, "ready"), (bad, "not ready")], total: count.total),
                    bar: segments([(.done, count.total - bad), (.failed, bad)])))
        }
        if overview.nodes > 0 {
            let bad = overview.notReadyNodes.count
            kinds.append(
                Kind(
                    title: "Nodes", resource: "nodes", total: overview.nodes,
                    line: said([(overview.nodes - bad, "ready"), (bad, "not ready")], total: overview.nodes),
                    bar: segments([(.done, overview.nodes - bad), (.failed, bad)])))
        }
        return kinds
    }

    /// `12 ready · 1 pending · 2 failing`, the zeros left out; `all 3
    /// ready` (or running) when that is all; `none` for nothing.
    static func said(_ parts: [(count: Int, word: String)], total: Int) -> String {
        guard total > 0 else { return "none" }
        let shown = parts.filter { $0.count > 0 }
        if shown.count == 1, let only = shown.first, ["ready", "running"].contains(only.word), only.count == total { return total == 1 ? only.word : "all \(total) \(only.word)" }
        return shown.map { "\($0.count) \($0.word)" }.joined(separator: " · ")
    }

    /// How many cards across: as many as fit at `minimum` or wider, never
    /// more than there are (so the row fills), at least one.
    static func columns(count: Int, width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        let fit = Int(((width + spacing) / (minimum + spacing)).rounded(.down))
        return max(1, min(count, fit))
    }

    private static func segments(_ parts: [(Tone, Int)]) -> [Segment] {
        parts.filter { $0.1 > 0 }.map { Segment(tone: $0.0, count: $0.1) }
    }

    // MARK: What needs attention

    /// A row of the Needs-attention card: what it is, where, why, and what its press opens.
    struct Attention: Equatable, Sendable, Identifiable {
        enum Subject: Int, Comparable, Sendable {
            case node, pod, workload

            static func < (lhs: Subject, rhs: Subject) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        var subject: Subject
        var tone: Tone
        /// `pod/worker-1`, `deployment/web`, `node/fake-node-2`.
        var title: String
        var namespace: String?
        var pill: String
        /// What the press opens: the kind's full name and the row.
        var resource: String
        var row: KubeRowID
        /// How bad within its tone: a pod's restarts.
        var weight: Int

        var id: String { resource + "\u{0}" + row.description }

        var symbol: String {
            switch subject {
            case .node: "server.rack"
            case .pod: tone == .failed ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
            case .workload: "exclamationmark.triangle.fill"
            }
        }

        /// Worst first: failing before not ready, nodes before pods before
        /// workloads, the most restarted first, then by name.
        static func ordered(_ a: Attention, _ b: Attention) -> Bool {
            if a.tone != b.tone { return a.tone > b.tone }
            if a.subject != b.subject { return a.subject < b.subject }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.id < b.id
        }
    }

    /// Every pod failing, workload not ready and node not ready, worst first.
    static func attention(_ overview: KubeClusterOverview) -> [Attention] {
        var rows: [Attention] = []
        for pod in overview.failingPods {
            rows.append(
                Attention(
                    subject: .pod, tone: .failed, title: "pod/\(pod.id.name)", namespace: pod.id.namespace, pill: podPill(pod),
                    resource: KubeResourceKind.pods.fullName, row: pod.id, weight: pod.restarts ?? 0))
        }
        for node in overview.notReadyNodes {
            rows.append(
                Attention(
                    subject: .node, tone: .failed, title: "node/\(node)", namespace: nil, pill: "NotReady", resource: "nodes",
                    row: KubeRowID(namespace: nil, name: node), weight: 0))
        }
        for count in overview.workloads {
            let singular = workloadWord(count.title)
            for id in count.notReady {
                rows.append(
                    Attention(
                        subject: .workload, tone: .waiting, title: "\(singular)/\(id.name)", namespace: id.namespace,
                        pill: count.said[id] ?? "not ready", resource: count.resource, row: id, weight: 0))
            }
        }
        return rows.sorted(by: Attention.ordered)
    }

    /// `CrashLoopBackOff · 14×`: why the pod fails, and how often it restarted.
    static func podPill(_ pod: KubePodSummary) -> String {
        let reason = pod.exitReason ?? pod.status
        guard let restarts = pod.restarts, restarts > 0 else { return reason }
        return "\(reason) · \(restarts)×"
    }

    /// `Deployments` → `deployment`.
    static func workloadWord(_ title: String) -> String {
        let lower = title.lowercased()
        return lower.hasSuffix("s") ? String(lower.dropLast()) : lower
    }

    // MARK: Usage

    /// A share of allocatable as its bar is coloured: ≥ 90 failed, ≥ 70 waiting, else done.
    static func usageTone(_ percent: Int) -> Tone { percent >= 90 ? .failed : percent >= 70 ? .waiting : .done }
}
