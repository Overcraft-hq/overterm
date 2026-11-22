import Foundation

/// What the Overview's cards say (`KubeClusterOverviewView`), from the
/// overview and the health report it already has: the header's pills, a
/// kind's card (its number, its line, its bar), what needs attention as
/// rows worst first with a reason pill each, a usage's tone. Nothing read
/// here. Pure.
package enum KubeOverviewCards {
    /// A status as the cards colour it — always said in words beside it.
    package enum Tone: Int, Comparable, Sendable {
        case neutral, done, waiting, failed

        package static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A small rounded capsule: its words and its tone.
    package struct Pill: Equatable, Sendable {
        package var text: String
        package var tone: Tone
    }

    // MARK: The header

    /// `3 need attention` (failed) while anything fails, and
    /// `N checks pass` (done) once the health checks are read.
    package static func pills(_ overview: KubeClusterOverview, health: KubeHealth.Report?) -> [Pill] {
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
    package static func passingChecks(_ report: KubeHealth.Report) -> Int {
        let found = Set(report.findings.map(\.check))
        return report.ran.subtracting(found).count
    }

    /// The health report's severities as chips: `2 problems`, `5 warnings`.
    package static func severities(_ report: KubeHealth.Report) -> [Pill] {
        var pills: [Pill] = []
        if report.errors > 0 { pills.append(Pill(text: "\(report.errors) problem\(report.errors == 1 ? "" : "s")", tone: .failed)) }
        if report.warnings > 0 { pills.append(Pill(text: "\(report.warnings) warning\(report.warnings == 1 ? "" : "s")", tone: .waiting)) }
        return pills
    }

    // MARK: GitOps

    /// The Overview's GitOps line (docs/design/kubernetes/gitops.md, 2.1),
    /// from the findings the health report already holds — no read: Argo
    /// CD's Failed (K602) and Flux's own Ready False (K601's `fluxFailing`:
    /// never a generation not yet looked at, nor a blocked source or
    /// dependency — the section calls those Progressing, Unknown, Blocked)
    /// as failing, Argo CD's drifted or stuck (K603). It counts what *lives*
    /// in the scope, and says so — the section (`g`) counts what lives in
    /// or deploys into it, so the two can differ. Nil when there is
    /// nothing to say.
    package struct GitOpsLine: Equatable, Sendable {
        /// `GitOps living in shop`.
        package var title: String
        /// `2 failing`, `1 drifted or stuck`: a pill each.
        package var counts: [Pill]
        package var tone: Tone

        /// The line in words: `GitOps living in shop: 2 failing — press g for what deploys here`.
        package var text: String { "\(title): \(counts.map(\.text).joined(separator: ", ")) — press \(KubeSection.gitops.key) for what deploys here" }
    }

    package static func gitOps(_ report: KubeHealth.Report, scope: KubeScope?) -> GitOpsLine? {
        let failing = report.findings.count { $0.check == .argoDegraded || ($0.check == .notReady && $0.fluxFailing) }
        let behind = report.findings.count { $0.check == .argoOutOfSync }
        guard failing + behind > 0 else { return nil }
        let place = scope.map { $0 == .all ? "across the cluster" : "living in \($0.names?.joined(separator: ", ") ?? "")" } ?? "here"
        var counts: [Pill] = []
        if failing > 0 { counts.append(Pill(text: "\(failing) failing", tone: .failed)) }
        if behind > 0 { counts.append(Pill(text: "\(behind) drifted or stuck", tone: .waiting)) }
        return GitOpsLine(title: "GitOps \(place)", counts: counts, tone: failing > 0 ? .failed : .waiting)
    }

    // MARK: A kind's card

    /// One kind's card: its count, its line (the counts the bar draws,
    /// said), its bar's parts, what its press shows.
    package struct Kind: Equatable, Sendable, Identifiable {
        package var title: String
        /// The list it opens: a kind's full name (`pods`, `deployments.apps`, `nodes`).
        package var resource: String
        package var total: Int
        package var line: String
        package var bar: [Segment]

        package var id: String { resource }
    }

    package struct Segment: Equatable, Sendable {
        package var tone: Tone
        package var count: Int
    }

    /// Pods, each workload kind the overview counted, and the nodes.
    package static func kinds(_ overview: KubeClusterOverview) -> [Kind] {
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
    package static func said(_ parts: [(count: Int, word: String)], total: Int) -> String {
        guard total > 0 else { return "none" }
        let shown = parts.filter { $0.count > 0 }
        if shown.count == 1, let only = shown.first, ["ready", "running"].contains(only.word), only.count == total { return total == 1 ? only.word : "all \(total) \(only.word)" }
        return shown.map { "\($0.count) \($0.word)" }.joined(separator: " · ")
    }

    /// How many cards across: as many as fit at `minimum` or wider, never
    /// more than there are (so the row fills), at least one.
    package static func columns(count: Int, width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        let fit = Int(((width + spacing) / (minimum + spacing)).rounded(.down))
        return max(1, min(count, fit))
    }

    private static func segments(_ parts: [(Tone, Int)]) -> [Segment] {
        parts.filter { $0.1 > 0 }.map { Segment(tone: $0.0, count: $0.1) }
    }

    // MARK: What needs attention

    /// A row of the Needs-attention card: what it is, where, why, and what its press opens.
    package struct Attention: Equatable, Sendable, Identifiable {
        package enum Subject: Int, Comparable, Sendable {
            case node, pod, workload

            package static func < (lhs: Subject, rhs: Subject) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        package var subject: Subject
        package var tone: Tone
        /// `pod/worker-1`, `deployment/web`, `node/fake-node-2`.
        package var title: String
        package var namespace: String?
        package var pill: String
        /// What the press opens: the kind's full name and the row.
        package var resource: String
        package var row: KubeRowID
        /// How bad within its tone: a pod's restarts.
        package var weight: Int

        package var id: String { resource + "\u{0}" + row.description }

        package var symbol: String {
            switch subject {
            case .node: "server.rack"
            case .pod: tone == .failed ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
            case .workload: "exclamationmark.triangle.fill"
            }
        }

        /// Worst first: failing before not ready, nodes before pods before
        /// workloads, the most restarted first, then by name.
        package static func ordered(_ a: Attention, _ b: Attention) -> Bool {
            if a.tone != b.tone { return a.tone > b.tone }
            if a.subject != b.subject { return a.subject < b.subject }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.id < b.id
        }
    }

    /// Every pod failing, workload not ready and node not ready, worst first.
    package static func attention(_ overview: KubeClusterOverview) -> [Attention] {
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
    package static func podPill(_ pod: KubePodSummary) -> String {
        let reason = pod.exitReason ?? pod.status
        guard let restarts = pod.restarts, restarts > 0 else { return reason }
        return "\(reason) · \(restarts)×"
    }

    /// `Deployments` → `deployment`.
    package static func workloadWord(_ title: String) -> String {
        let lower = title.lowercased()
        return lower.hasSuffix("s") ? String(lower.dropLast()) : lower
    }

    // MARK: Usage

    /// A share of allocatable as its bar is coloured: ≥ 90 failed, ≥ 70 waiting, else done.
    package static func usageTone(_ percent: Int) -> Tone { percent >= 90 ? .failed : percent >= 70 ? .waiting : .done }
}
