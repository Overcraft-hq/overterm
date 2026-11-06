import Foundation

// MARK: Attention marks (stage 3a — docs/design/kubernetes/analysis.md, 3.13)

/// A failure in a bound namespace that marks the checkout's tab: a pod
/// going into `CrashLoopBackOff`, `OOMKilled` or `ImagePullBackOff`, or a
/// Deployment's rollout past its `progressDeadlineSeconds`. Its object is
/// what Ask Why on the mark asks about.
struct KubeAttentionAlert: Equatable, Hashable, Sendable, Identifiable {
    var ref: KubeObjectRef
    /// `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`, `ProgressDeadlineExceeded`.
    var reason: String

    var id: String { "\(ref.context)\u{1F}\(ref.namespace ?? "")\u{1F}\(ref.kind.fullName)\u{1F}\(ref.name)" }

    /// `pod/web-7d9`, `deploy/web`.
    var object: String { (ref.isPod ? "pod/" : "deploy/") + ref.name }

    /// What the mark, the notification and the Inbox say:
    /// `pod/web-7d9 CrashLoopBackOff — fake-dev · shop`.
    var note: String {
        let what = ref.isPod ? reason : "rollout stuck (\(reason))"
        return "\(object) \(what) — \(ref.context) · \(ref.namespace ?? "")"
    }
}

/// One bound namespace's failures as its two watches see them, turned
/// into marks: what is new since the watches began, and what has gone.
/// Pure — fed the rows as they stand after each batch of events.
///
/// - **News only.** The first rows a kind gives are where things stand:
///   what already fails there marks nothing (the app started, a slot came
///   free). After that a pod marks once — the first time its Status is
///   one of `podReasons` —, so a crash loop's restarts (Running, Error,
///   CrashLoopBackOff again) don't mark it again and again; a new pod (a
///   new rollout) is news of its own.
/// - **Cleared** when what marked goes: a pod deleted (replaced, rolled
///   back), a Deployment progressing again or deleted. A Deployment that
///   gets stuck again marks again.
/// - Deployments are those the binding includes; the label selector was
///   the server's already.
struct KubeAttention: Sendable {
    static let podReasons: Set<String> = ["CrashLoopBackOff", "OOMKilled", "ImagePullBackOff"]

    let context: String
    let namespace: String

    struct Change: Equatable, Sendable {
        var raised: [KubeAttentionAlert] = []
        var cleared: [KubeAttentionAlert] = []
        var isEmpty: Bool { raised.isEmpty && cleared.isEmpty }
    }

    private var podsSeen = false
    private var deploymentsSeen = false
    /// Pods that marked, by name, and why.
    private var podsMarked: [String: String] = [:]
    /// Pods failing when the watch began (or that marked once): never news again.
    private var podsKnown: Set<String> = []
    private var stuckMarked: Set<String> = []
    private var stuckKnown: Set<String> = []

    init(context: String, namespace: String) {
        self.context = context
        self.namespace = namespace
    }

    /// What marks a pod's row: its Status (an init container's too), when it is one of `podReasons`.
    static func reason(of summary: KubePodSummary) -> String? {
        let bare = summary.status.hasPrefix("Init:") ? String(summary.status.dropFirst(5)) : summary.status
        return podReasons.contains(bare) ? bare : nil
    }

    /// A Deployment's row with its conditions (`includeObject=Object`):
    /// `Progressing` False with `ProgressDeadlineExceeded`.
    static func isStuck(_ row: KubeRow) -> Bool {
        row.conditions.contains { $0.type == "Progressing" && $0.status == "False" && $0.reason == "ProgressDeadlineExceeded" }
    }

    /// The marks still standing: pods that marked and are still there,
    /// Deployments stuck since they marked.
    var standing: [KubeAttentionAlert] {
        podsMarked.sorted { $0.key < $1.key }.map { pod($0.key, $0.value) } + stuckMarked.sorted().map(deployment)
    }

    private func pod(_ name: String, _ reason: String) -> KubeAttentionAlert {
        KubeAttentionAlert(ref: KubeObjectRef(context: context, kind: .pods, namespace: namespace, name: name), reason: reason)
    }

    private func deployment(_ name: String) -> KubeAttentionAlert {
        KubeAttentionAlert(ref: KubeObjectRef(context: context, kind: .deployments, namespace: namespace, name: name), reason: "ProgressDeadlineExceeded")
    }

    /// The pods as they stand now.
    mutating func observePods(_ rows: KubeRows) -> Change {
        var failing: [String: String] = [:]
        var present = Set<String>()
        for row in rows.sorted {
            present.insert(row.id.name)
            if let summary = KubePodSummary(row: row, columns: rows.columns), let reason = Self.reason(of: summary) { failing[row.id.name] = reason }
        }
        var change = Change()
        guard podsSeen else {
            podsSeen = true
            podsKnown = Set(failing.keys)
            return change
        }
        for (name, reason) in failing.sorted(by: { $0.key < $1.key }) where podsMarked[name] == nil && !podsKnown.contains(name) {
            podsMarked[name] = reason
            podsKnown.insert(name)
            change.raised.append(pod(name, reason))
        }
        for name in podsKnown.subtracting(present) { podsKnown.remove(name) }
        for (name, reason) in podsMarked.sorted(by: { $0.key < $1.key }) where !present.contains(name) {
            podsMarked[name] = nil
            change.cleared.append(pod(name, reason))
        }
        return change
    }

    /// The Deployments as they stand now; `includes`: the binding's own.
    mutating func observeDeployments(_ rows: KubeRows, includes: (String) -> Bool = { _ in true }) -> Change {
        let stuck = Set(rows.sorted.filter { includes($0.id.name) && Self.isStuck($0) }.map(\.id.name))
        var change = Change()
        guard deploymentsSeen else {
            deploymentsSeen = true
            stuckKnown = stuck
            return change
        }
        // Known stuck ones that moved on may mark the next time.
        stuckKnown.formIntersection(stuck)
        for name in stuck.sorted() where !stuckMarked.contains(name) && !stuckKnown.contains(name) {
            stuckMarked.insert(name)
            change.raised.append(deployment(name))
        }
        for name in stuckMarked.subtracting(stuck).sorted() {
            stuckMarked.remove(name)
            change.cleared.append(deployment(name))
        }
        return change
    }
}

/// Which bound namespaces the attention watches follow (3.13's budget):
/// one scope a context, namespace and selector, for the checkouts bound
/// there that have a tab open — the most recently used first, at most
/// `budget` of them. Pure.
enum KubeAttentionBudget {
    /// What two watches follow: the binding's context, namespace and selector.
    struct Scope: Hashable, Sendable, Comparable, CustomStringConvertible {
        var context: String
        var namespace: String
        var selector: String?

        var description: String { "\(context) · \(namespace)" + (selector.map { " (\($0))" } ?? "") }

        static func < (a: Scope, b: Scope) -> Bool { (a.context, a.namespace, a.selector ?? "") < (b.context, b.namespace, b.selector ?? "") }
    }

    /// The watches per scope: Pods and Deployments.
    static let watchesPerScope = 2

    static func scope(of binding: KubeBinding) -> Scope { Scope(context: binding.context, namespace: binding.namespace, selector: binding.selector) }

    /// The scopes to follow, the most recently used first, and those left
    /// over the budget: `open`, the checkouts with a tab (by key), each
    /// with when it was last used; `bindings`, by checkout.
    static func plan(open: [String: Date], bindings: [String: KubeBinding], budget: Int) -> (watched: [Scope], over: [Scope]) {
        var latest: [Scope: Date] = [:]
        for (checkout, used) in open {
            guard let binding = bindings[checkout] else { continue }
            let scope = scope(of: binding)
            latest[scope] = max(latest[scope] ?? .distantPast, used)
        }
        let ordered = latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let count = max(0, budget)
        return (Array(ordered.prefix(count)), Array(ordered.dropFirst(count)))
    }
}
