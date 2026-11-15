import Foundation

/// One state for Argo CD and Flux alike (docs/design/kubernetes/gitops.md,
/// 2.3). Shown problems first, in this order; evaluated in
/// `evaluationOrder` (`KubeGitOpsLadder`). Pure.
enum KubeGitOpsState: Int, CaseIterable, Comparable, Sendable {
    case failed, blocked, stuck, drift, progressing, paused, ready, unknown

    /// The ladder's order: the first that holds wins.
    static let evaluationOrder: [KubeGitOpsState] = [.paused, .blocked, .failed, .stuck, .drift, .progressing, .ready, .unknown]

    static func < (lhs: KubeGitOpsState, rhs: KubeGitOpsState) -> Bool { lhs.rawValue < rhs.rawValue }

    var word: String {
        switch self {
        case .failed: "Failed"
        case .blocked: "Blocked"
        case .stuck: "Stuck"
        case .drift: "Drift"
        case .progressing: "Progressing"
        case .paused: "Paused"
        case .ready: "Ready"
        case .unknown: "Unknown"
        }
    }

    /// Said beside a word, never alone.
    var glyph: String {
        switch self {
        case .failed, .blocked: "●"
        case .stuck, .progressing: "◐"
        case .drift: "◇"
        case .paused: "‖"
        case .ready: "✓"
        case .unknown: "?"
        }
    }

    /// Its colour, as the trees say it: Failed and Blocked bad; Stuck,
    /// Drift and Progressing waiting; Paused dim; Ready good; Unknown grey.
    var mark: KubeTreeHealth {
        switch self {
        case .failed, .blocked: .bad
        case .stuck, .drift, .progressing: .waiting
        case .paused: .dim
        case .ready: .good
        case .unknown: .unknown
        }
    }

    /// What Ask Why is offered on.
    var isProblem: Bool { self == .failed || self == .blocked || self == .stuck }
}

/// What the ladder says of one object: its state, why in one line, since
/// when (from the object's own times), the tags beside it.
struct KubeGitOpsVerdict: Equatable, Sendable {
    var state: KubeGitOpsState
    var why: String
    var since: Date?
    var tags: [KubeGitOpsTag] = []
}

/// The state ladder (gitops.md, 2.3): rules evaluated in order, the first
/// that holds wins, every time read from the object — `lastTransitionTime`,
/// the operation's `startedAt`/`finishedAt`, an artifact's
/// `lastUpdateTime`, managedFields' — never from when the app first saw
/// it, so a tick (`KubeGitOpsSummary.ranked` again, no read) ranks an
/// object the same whenever the section was opened. A Flux object's
/// Blocked looks at its peers (the other summaries) and nothing else: no
/// read. K602 and K603 (`KubeHealth`) are this. Pure.
enum KubeGitOpsLadder {
    /// An Argo CD operation Running longer than this is Stuck.
    static let argoOperationLimit: TimeInterval = 600
    /// Argo CD's default reconcile period: auto-sync starts within it.
    static let argoReconcilePeriod: TimeInterval = 180
    /// Three periods without a reconcile: "not reconciled for…".
    static let notReconciledAfter: TimeInterval = 3 * 180
    /// A Flux object reconciling longer than `max(2 × interval, this)` is Stuck.
    static let fluxStuckFloor: TimeInterval = 300
    /// Flux not yet at the latest generation for less than this is Progressing.
    static let generationGrace: TimeInterval = 60
    /// How far a dependency chain is followed among the summaries.
    static let chainHops = 5

    typealias Peers = [KubeGitOpsObject.Key: KubeGitOpsObject]

    /// The verdict, its `why` one line of at most `KubeGitOpsMessage.rowLimit`
    /// (gitops.md, 2.2 column 5 and 5.3): the messages it quotes are kept
    /// at the hover's 4 KB, several lines when a manifest was cut from them.
    static func evaluate(_ object: KubeGitOpsObject, now: Date, peers: Peers = [:]) -> KubeGitOpsVerdict {
        var verdict: KubeGitOpsVerdict
        switch object.role {
        case .application: verdict = argo(object, now: now)
        case .applicationSet: verdict = applicationSet(object)
        default: verdict = flux(object, now: now, peers: peers)
        }
        verdict.why = KubeGitOpsMessage.oneLine(verdict.why, limit: KubeGitOpsMessage.rowLimit)
        return verdict
    }

    // MARK: Argo CD

    private static func argo(_ o: KubeGitOpsObject, now: Date) -> KubeGitOpsVerdict {
        var tags: [KubeGitOpsTag] = []
        let auto = o.autoSync?.enabled ?? false
        if !auto { tags.append(.manual) }
        if let reconciled = o.reconciledAt, o.readAt.timeIntervalSince(reconciled) > notReconciledAfter {
            tags.append(.notReconciled(o.readAt.timeIntervalSince(reconciled)))
        }
        func verdict(_ state: KubeGitOpsState, _ why: String, _ since: Date? = nil) -> KubeGitOpsVerdict {
            KubeGitOpsVerdict(state: state, why: why, since: since, tags: tags)
        }
        let wanted = o.revisions.wanted
        let target = wanted.map(KubeGitOpsRevision.shown).joined(separator: " · ")
        let operation = o.operation
        let forCurrent = operation.map { !wanted.isEmpty && $0.revisions == wanted } ?? false
        let running = operation?.phase == "Running"
        let health = o.healthMessage.map { ": \($0)" } ?? ""

        // 3. Failed
        if let error = o.conditions.first(where: { $0.type.hasSuffix("Error") }) {
            return verdict(.failed, error.message.map { "\(error.type): \($0)" } ?? error.type, error.since)
        }
        if o.health == "Degraded" { return verdict(.failed, "Degraded\(health)") }
        if o.health == "Missing", o.sync == "Synced" { return verdict(.failed, "Missing while Synced\(health)") }
        if let operation, ["Failed", "Error"].contains(operation.phase) {
            if forCurrent {
                let because = operation.message.map { ": \($0)" } ?? ""
                // Auto-sync tries a revision once, unless syncPolicy.retry says more.
                let why =
                    auto && o.retryLimit == nil
                    ? "auto-sync failed for \(target) and won't retry it\(because)" : "sync failed for \(target)\(because)"
                return verdict(.failed, why, operation.finishedAt)
            }
            tags.append(.lastSyncFailed(operation.finishedAt))
        }
        if let operation, running, let retries = operation.retryCount, retries > 0 {
            return verdict(.failed, "retrying (attempt \(retries + 1))" + (operation.message.map { ": \($0)" } ?? ""), operation.startedAt)
        }
        // 4. Stuck
        if let operation, running || operation.phase == "Terminating", let started = operation.startedAt,
            now.timeIntervalSince(started) > argoOperationLimit
        {
            let doing = running ? "syncing" : "terminating"
            let what = operation.message.map { ": \($0)" } ?? ""
            return verdict(.stuck, "\(doing) \(KubeAge.format(now.timeIntervalSince(started)))\(what)", started)
        }
        // 5. Drift
        if o.sync == "OutOfSync" {
            if o.pruneNeeded > 0, o.autoSync?.prune != true {
                let count = o.pruneNeeded == 1 ? "1 resource needs" : "\(o.pruneNeeded) resources need"
                return verdict(.drift, "\(count) pruning; prune is off")
            }
            if !auto { return verdict(.drift, "OutOfSync, auto-sync off") }
            if !running {
                if forCurrent, operation?.phase == "Succeeded" {
                    let why =
                        o.autoSync?.selfHeal == true
                        ? "OutOfSync after syncing \(target): a difference Argo CD doesn't ignore"
                        : "OutOfSync after syncing \(target): self-heal is off, or a difference isn't ignored"
                    return verdict(.drift, why, operation?.finishedAt)
                }
                let last = operation?.finishedAt ?? o.created
                if !forCurrent, last.map({ now.timeIntervalSince($0) > argoReconcilePeriod }) ?? true {
                    return verdict(.drift, "auto-sync on, not started for \(target.isEmpty ? "the new revision" : target)", last)
                }
            }
        }
        // 6. Progressing
        if o.health == "Progressing" { return verdict(.progressing, "Progressing\(health)") }
        if let operation, running {
            let age = operation.startedAt.map { " \(KubeAge.format(now.timeIntervalSince($0)))" } ?? ""
            let what = operation.revisions.isEmpty ? "" : " \(operation.revisions.map(KubeGitOpsRevision.shown).joined(separator: " · "))"
            return verdict(.progressing, "syncing\(what)\(age)", operation.startedAt)
        }
        if o.sync == "OutOfSync" { return verdict(.progressing, "auto-sync on, syncing \(target.isEmpty ? "the new revision" : target) soon") }
        // 7. Ready
        if o.sync == "Synced", o.health == "Healthy" || o.health == "Suspended" || o.health == nil {
            return verdict(.ready, o.health == "Suspended" ? "Synced, Suspended" : "Synced, Healthy")
        }
        // 8. Unknown
        if o.sync == "Unknown" { return verdict(.unknown, "Argo CD can't compare it with its source (sync Unknown)") }
        return verdict(.unknown, [o.sync, o.health].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "Argo CD says nothing of it yet")
    }

    private static func applicationSet(_ o: KubeGitOpsObject) -> KubeGitOpsVerdict {
        if let error = o.condition("ErrorOccurred"), error.isTrue {
            return KubeGitOpsVerdict(state: .failed, why: error.message ?? error.reason ?? "ErrorOccurred", since: error.since)
        }
        if let rollout = o.condition("RolloutProgressing"), rollout.isTrue {
            return KubeGitOpsVerdict(state: .progressing, why: rollout.message ?? "rolling out", since: rollout.since)
        }
        if let upToDate = o.condition("ResourcesUpToDate"), upToDate.isTrue {
            return KubeGitOpsVerdict(state: .ready, why: "its Applications are up to date", since: upToDate.since)
        }
        return KubeGitOpsVerdict(state: .unknown, why: "no condition yet")
    }

    // MARK: Flux

    /// A peer that blocks its users: a source (or chart) not Ready, or stalled.
    private static func blocks(_ peer: KubeGitOpsObject) -> Bool {
        if peer.suspended { return false }
        return peer.condition("Ready")?.isFalse == true || peer.condition("Stalled")?.isTrue == true
    }

    /// Why a peer isn't ready: its reason, else its message.
    private static func cause(_ peer: KubeGitOpsObject) -> String {
        let ready = peer.condition("Ready")
        let stalled = peer.condition("Stalled")
        return ready?.reason ?? stalled?.reason ?? peer.lastError ?? "not Ready"
    }

    /// What a Flux object takes its artifact from, in order: a HelmRelease's
    /// `chartRef`, else the HelmChart its template makes (`<ns>-<name>`, in
    /// its source's namespace) and that source; a Kustomization's or a
    /// HelmChart's `sourceRef`.
    static func upstream(_ o: KubeGitOpsObject) -> [KubeGitOpsObject.Key] {
        func key(_ source: KubeGitOps.FluxSource) -> KubeGitOpsObject.Key {
            KubeGitOpsObject.Key(kind: source.kind, namespace: source.namespace, name: source.name)
        }
        switch o.role {
        case .helmRelease:
            if let chart = o.chartRef { return [key(chart)] }
            guard let origin = o.sourceRef else { return [] }
            return [KubeGitOpsObject.Key(kind: "HelmChart", namespace: origin.namespace, name: "\(o.ref.namespace ?? "")-\(o.ref.name)"), key(origin)]
        default:
            return o.sourceRef.map { [key($0)] } ?? []
        }
    }

    private static func flux(_ o: KubeGitOpsObject, now: Date, peers: Peers) -> KubeGitOpsVerdict {
        let ready = o.condition("Ready")
        let stalled = o.condition("Stalled")
        let reconciling = o.condition("Reconciling")
        let lag = o.observedGeneration.map { $0 >= 0 && $0 < (o.generation ?? $0) } ?? false
        let applied = o.revisions.applied.first.map(KubeGitOpsRevision.shown)

        // 1. Paused: whatever its conditions say, kept as a tag.
        if o.suspended {
            var tags: [KubeGitOpsTag] = []
            if let ready, ready.isFalse {
                tags.append(.last(ready.reason ?? "Ready False"))
            } else if let ready, ready.isTrue {
                tags.append(.last(["Ready", applied ?? o.artifact?.revision.map(KubeGitOpsRevision.shown)].compactMap { $0 }.joined(separator: " ")))
            }
            var why = "suspended"
            if let at = o.suspension?.at { why += " \(KubeAge.format(now.timeIntervalSince(at))) ago" }
            if let by = o.suspension?.by, !by.isEmpty { why += " by \(by)" }
            return KubeGitOpsVerdict(state: .paused, why: why, since: o.suspension?.at, tags: tags)
        }

        // 2. Blocked: by its source (or chart), whatever reason it gives itself.
        for key in upstream(o) {
            if let peer = peers[key], blocks(peer) {
                let since = peer.condition("Ready")?.since ?? peer.condition("Stalled")?.since
                return KubeGitOpsVerdict(state: .blocked, why: "\(key.kind == "HelmChart" ? "chart" : "source") \(peer.ref.name): \(cause(peer))", since: since)
            }
        }
        if let ready, ready.isFalse, ready.reason == "DependencyNotReady" {
            return KubeGitOpsVerdict(state: .blocked, why: chain(o, peers: peers) ?? "dependency not ready" + (ready.message.map { ": \($0)" } ?? ""), since: ready.since)
        }

        // 3. Failed
        let attempted = o.revisions.attempted
        if let ready, ready.isFalse {
            if o.role == .helmRelease, ["RollbackSucceeded", "UninstallSucceeded"].contains(ready.reason ?? "") {
                let to = attempted.map { " to \(KubeGitOpsRevision.shown($0))" } ?? ""
                let after = ready.reason == "UninstallSucceeded" ? "uninstalled" : "rolled back" + (o.revisions.helmHistory?.chartVersion.map { " to \($0)" } ?? "")
                return KubeGitOpsVerdict(state: .failed, why: "upgrade\(to) failed; \(after)", since: ready.since)
            }
            if o.role == .kustomization, let attempted, let appliedRevision = o.revisions.applied.first, attempted != appliedRevision {
                let reason = ready.reason.map { " (\($0))" } ?? ""
                return KubeGitOpsVerdict(
                    state: .failed,
                    why: "\(KubeGitOpsRevision.shown(attempted)) failed\(reason); \(KubeGitOpsRevision.shown(appliedRevision)) still applied",
                    since: ready.since)
            }
            return KubeGitOpsVerdict(state: .failed, why: o.lastError ?? ready.reason ?? "Ready False", since: ready.since)
        }
        if let stalled, stalled.isTrue {
            return KubeGitOpsVerdict(state: .failed, why: "stalled: " + ([stalled.reason, stalled.message].compactMap { $0 }.joined(separator: ": ")), since: stalled.since)
        }
        if let reconciling, reconciling.isTrue, reconciling.reason == "ProgressingWithRetry" {
            return KubeGitOpsVerdict(state: .failed, why: "retrying after: \(reconciling.message ?? "a failure")", since: reconciling.since)
        }
        if o.role == .helmRelease, o.revisions.helmHistory?.status == "failed" {
            let version = o.revisions.helmHistory?.chartVersion.map { "\($0) " } ?? ""
            return KubeGitOpsVerdict(state: .failed, why: "\(version)failed" + (o.lastError.map { ": \($0)" } ?? ""), since: ready?.since)
        }

        // 4. Stuck
        let window = max(2 * (o.interval ?? 0), fluxStuckFloor)
        if let reconciling, reconciling.isTrue, let since = reconciling.since, now.timeIntervalSince(since) > window {
            let what = reconciling.message.map { ": \($0)" } ?? ""
            return KubeGitOpsVerdict(state: .stuck, why: "reconciling for \(KubeAge.format(now.timeIntervalSince(since)))\(what)", since: since)
        }

        // 5. Drift: a source (or chart) fetched what its Kustomization or HelmRelease didn't try yet.
        var fetching: KubeGitOpsVerdict?
        if let (fetched, peer) = unattempted(o, peers: peers) {
            let patience = (o.interval ?? 0) + (o.retryInterval ?? o.interval ?? 0)
            let current = o.role == .helmRelease ? o.revisions.helmHistory?.chartVersion.map { "\($0) deployed" } : applied.map { "\($0) applied" }
            let why = "fetched \(KubeGitOpsRevision.shown(fetched)), not applied" + (current.map { "; \($0)" } ?? "")
            if let updated = peer.artifact?.lastUpdateTime, now.timeIntervalSince(updated) > patience {
                return KubeGitOpsVerdict(state: .drift, why: why, since: updated)
            }
            fetching = KubeGitOpsVerdict(state: .progressing, why: "fetched \(KubeGitOpsRevision.shown(fetched)), applying it", since: peer.artifact?.lastUpdateTime)
        }

        // 6. Progressing
        if let reconciling, reconciling.isTrue {
            return KubeGitOpsVerdict(state: .progressing, why: "reconciling" + (reconciling.message.map { ": \($0)" } ?? ""), since: reconciling.since)
        }
        if let ready, ready.status == "Unknown" {
            return KubeGitOpsVerdict(state: .progressing, why: ready.message ?? ready.reason ?? "Ready Unknown", since: ready.since)
        }
        if let fetching { return fetching }
        if lag, let changed = o.generationChangedAt, now.timeIntervalSince(changed) <= generationGrace {
            return KubeGitOpsVerdict(state: .progressing, why: "Flux is looking at its latest change", since: changed)
        }

        // 7. Ready
        if let ready, ready.isTrue, !lag {
            let why: String
            switch o.role {
            case .kustomization: why = applied.map { "applied \($0)" } ?? "Ready"
            case .helmRelease: why = o.revisions.helmHistory?.chartVersion.map { "\($0) deployed" } ?? "Ready"
            default: why = o.artifact?.revision.map { "fetched \(KubeGitOpsRevision.shown($0))" } ?? "Ready"
            }
            return KubeGitOpsVerdict(state: .ready, why: why, since: ready.since)
        }

        // 8. Unknown
        if lag {
            return KubeGitOpsVerdict(
                state: .unknown, why: "not yet looked at (generation \(o.generation ?? 0), last looked at \(o.observedGeneration ?? 0))",
                since: o.generationChangedAt)
        }
        return KubeGitOpsVerdict(state: .unknown, why: "no Ready condition yet")
    }

    /// What a Kustomization's or a HelmRelease's source fetched that it
    /// hasn't attempted (gitops.md, 2.3 rules 5 and 6): the artifact's
    /// revision and the peer holding it; nil when it has, or can't be told.
    /// A HelmChart's artifact is the chart's version, as the HelmRelease's
    /// `lastAttemptedRevision` is; a `chartRef` OCIRepository's is
    /// `<tag>@sha256:…`, compared by its digest with
    /// `lastAttemptedRevisionDigest` — a tag needn't be the chart's version.
    static func unattempted(_ o: KubeGitOpsObject, peers: Peers) -> (revision: String, peer: KubeGitOpsObject)? {
        guard o.role == .kustomization || o.role == .helmRelease, let source = upstream(o).first, let peer = peers[source],
            let fetched = peer.artifact?.revision, let attempted = o.revisions.attempted
        else { return nil }
        if o.role == .helmRelease, source.kind == "OCIRepository" {
            guard let digest = o.revisions.attemptedDigest, let at = fetched.range(of: "@", options: .backwards) else { return nil }
            return String(fetched[at.upperBound...]) != digest ? (fetched, peer) : nil
        }
        return fetched != attempted ? (fetched, peer) : nil
    }

    /// `acme-infra ← cert-manager: HealthCheckFailed`: the first dependency
    /// that isn't ready, followed while each link is among the summaries,
    /// at most `chainHops`; nil when none is.
    static func chain(_ o: KubeGitOpsObject, peers: Peers) -> String? {
        var names: [String] = []
        var current = o
        var seen: Set<KubeGitOpsObject.Key> = [o.key]
        for _ in 0..<chainHops {
            var found: KubeGitOpsObject?
            for key in current.dependsOn {
                if let peer = peers[key], peer.condition("Ready")?.isTrue != true {
                    found = peer
                    break
                }
            }
            guard let next = found, !seen.contains(next.key) else { break }
            seen.insert(next.key)
            names.append(next.ref.name)
            current = next
            let ready = next.condition("Ready")
            if ready?.reason != "DependencyNotReady" {
                return "dependency \(names.joined(separator: " ← ")): \(ready?.reason ?? (next.suspended ? "suspended" : "not Ready"))"
            }
        }
        guard !names.isEmpty else { return nil }
        return "dependency \(names.joined(separator: " ← ")): not ready"
    }
}
