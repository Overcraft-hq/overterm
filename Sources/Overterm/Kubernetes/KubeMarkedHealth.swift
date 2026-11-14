import Foundation

/// A marked object's kind, as the marks' reads know it (docs/design/
/// kubernetes/gitops.md, 14.4.1): the kinds with a health rule here, and
/// any other by its group and Kind. Pure.
enum KubeMarkedKind: Hashable, Sendable, Comparable {
    case deployment, statefulSet, daemonSet, rollout, cronJob, job, service, ingress, persistentVolumeClaim, horizontalPodAutoscaler
    case other(group: String, kind: String)

    init(group: String, kind: String) {
        switch (group, kind) {
        case ("apps", "Deployment"): self = .deployment
        case ("apps", "StatefulSet"): self = .statefulSet
        case ("apps", "DaemonSet"): self = .daemonSet
        case ("argoproj.io", "Rollout"): self = .rollout
        case ("batch", "CronJob"): self = .cronJob
        case ("batch", "Job"): self = .job
        case ("", "Service"): self = .service
        case ("networking.k8s.io", "Ingress"), ("extensions", "Ingress"): self = .ingress
        case ("", "PersistentVolumeClaim"): self = .persistentVolumeClaim
        case ("autoscaling", "HorizontalPodAutoscaler"): self = .horizontalPodAutoscaler
        default: self = .other(group: group, kind: kind)
        }
    }

    init(_ kind: KubeResourceKind) { self.init(group: kind.group, kind: kind.kind) }

    var group: String {
        switch self {
        case .deployment, .statefulSet, .daemonSet: "apps"
        case .rollout: "argoproj.io"
        case .cronJob, .job: "batch"
        case .service, .persistentVolumeClaim: ""
        case .ingress: "networking.k8s.io"
        case .horizontalPodAutoscaler: "autoscaling"
        case .other(let group, _): group
        }
    }

    var kind: String {
        switch self {
        case .deployment: "Deployment"
        case .statefulSet: "StatefulSet"
        case .daemonSet: "DaemonSet"
        case .rollout: "Rollout"
        case .cronJob: "CronJob"
        case .job: "Job"
        case .service: "Service"
        case .ingress: "Ingress"
        case .persistentVolumeClaim: "PersistentVolumeClaim"
        case .horizontalPodAutoscaler: "HorizontalPodAutoscaler"
        case .other(_, let kind): kind
        }
    }

    /// As a row's tags count it: `2 Deploy · 1 Svc`.
    var short: String {
        switch self {
        case .deployment: "Deploy"
        case .statefulSet: "STS"
        case .daemonSet: "DS"
        case .rollout: "Rollout"
        case .cronJob: "CronJob"
        case .job: "Job"
        case .service: "Svc"
        case .ingress: "Ing"
        case .persistentVolumeClaim: "PVC"
        case .horizontalPodAutoscaler: "HPA"
        case .other(_, let kind): kind
        }
    }

    /// What runs an app's code: without one read, an app's health can't
    /// be said from its Service alone (14.5).
    var isWorkload: Bool {
        switch self {
        case .deployment, .statefulSet, .daemonSet, .rollout, .cronJob, .job: true
        default: false
        }
    }

    private var order: Int {
        switch self {
        case .deployment: 0
        case .rollout: 1
        case .statefulSet: 2
        case .daemonSet: 3
        case .cronJob: 4
        case .job: 5
        case .service: 6
        case .ingress: 7
        case .persistentVolumeClaim: 8
        case .horizontalPodAutoscaler: 9
        case .other: 10
        }
    }

    static func < (a: KubeMarkedKind, b: KubeMarkedKind) -> Bool {
        a.order != b.order ? a.order < b.order : (a.group, a.kind) < (b.group, b.kind)
    }
}

/// Argo CD's health of the objects marks name, by gitops-engine's built-in
/// rules as far as what is here can say (docs/design/kubernetes/gitops.md,
/// 14.5): from a row's cells (said "from its row" where cells can hide a
/// paused or stuck rollout), from the object (`KubeMarkedWorkloadWire`,
/// Argo CD's rule), and the app's verdict — the worst member, up to three
/// causes. Fixed English built from the facts; a condition's message only
/// in `detail`, for the hover and the brief. Pure.
enum KubeMarkedHealth {
    /// Argo CD's health, in its order (`healthOrder`): best to worst.
    enum Status: Int, CaseIterable, Comparable, Sendable {
        case healthy, suspended, progressing, missing, degraded, unknown

        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

        /// Argo CD's own word.
        var word: String {
            switch self {
            case .healthy: "Healthy"
            case .suspended: "Suspended"
            case .progressing: "Progressing"
            case .missing: "Missing"
            case .degraded: "Degraded"
            case .unknown: "Unknown"
            }
        }

        /// The section's state for it. Never Drift, Blocked or Stuck:
        /// those need the Application.
        var state: KubeGitOpsState {
            switch self {
            case .healthy: .ready
            case .suspended: .paused
            case .progressing: .progressing
            case .degraded: .failed
            case .missing, .unknown: .unknown
            }
        }

        /// Which cause is named first: Degraded, then Unknown, then the rest.
        fileprivate var causeOrder: Int {
            switch self {
            case .degraded: 0
            case .unknown: 1
            case .progressing: 2
            case .missing: 3
            case .suspended: 4
            case .healthy: 5
            }
        }
    }

    /// One object's health.
    struct Verdict: Equatable, Hashable, Sendable {
        /// nil: no rule for its kind (it neither helps nor hurts), or not
        /// read yet (`unread`).
        var status: Status?
        /// Fixed English: "2/4 updated", "rollout paused".
        var sentence: String
        /// Settled from cells alone, which can hide a paused Deployment, a
        /// stale generation or a stuck rollout whose old pods still serve.
        var fromRow = false
        /// Its rule needs the object, which hasn't been read (a CronJob, an
        /// HPA with an `<unknown>` target).
        var unread = false
        /// Its state was scaled to zero (for the Rollout that runs instead).
        var scaledToZero = false
        /// When its state began: a condition's `lastTransitionTime`.
        var since: Date?
        /// A condition's or a Rollout's message, scrubbed and cut: the
        /// hover's and the brief's only.
        var detail: String?
    }

    // MARK: From a row

    /// A row's health from its cells, where Argo CD's rule reads a field
    /// a cell shows. `notReadySince`: when the session first saw the row
    /// not ready, said as a duration ("0/3 ready for 2h").
    static func row(_ kind: KubeMarkedKind, _ row: KubeRow, columns: [KubeColumn], marks: KubeMarkWire?, notReadySince: Date? = nil, now: Date) -> Verdict? {
        if marks?.deleting == true { return Verdict(status: .progressing, sentence: "pending deletion") }
        func cell(_ name: String) -> String? { row.cell(name, in: columns)?.text.trimmingCharacters(in: .whitespaces) }
        func number(_ name: String) -> Int? { cell(name).flatMap { Int($0) } }
        func lasting(_ text: String) -> String {
            guard let notReadySince else { return text }
            return "\(text) for \(KubeAge.format(now.timeIntervalSince(notReadySince)))"
        }
        switch kind {
        case .deployment, .rollout:
            // A Deployment's Ready is `ready/spec`; a Rollout's cells are counts.
            let ready = fraction(cell("Ready"))
            guard let desired = ready?.of ?? number("Desired") else { return nil }
            let readyCount = ready?.count ?? number("Current") ?? 0
            let updated = number("Up-to-date") ?? desired
            let available = number("Available") ?? desired
            if desired == 0, readyCount == 0, available == 0 { return Verdict(status: .healthy, sentence: "scaled to 0", scaledToZero: true) }
            if updated < desired { return Verdict(status: .progressing, sentence: lasting("\(updated)/\(desired) updated"), fromRow: true) }
            if available < updated { return Verdict(status: .progressing, sentence: lasting("\(available)/\(updated) available"), fromRow: true, detail: podsHint) }
            if readyCount < desired { return Verdict(status: .progressing, sentence: lasting("\(readyCount)/\(desired) ready"), fromRow: true) }
            return Verdict(status: .healthy, sentence: "\(readyCount)/\(desired) ready", fromRow: true)
        case .statefulSet:
            guard let ready = fraction(cell("Ready")) else { return nil }
            if ready.count < ready.of { return Verdict(status: .progressing, sentence: lasting("\(ready.count)/\(ready.of) ready"), fromRow: true) }
            return Verdict(status: .healthy, sentence: ready.of == 0 ? "scaled to 0" : "\(ready.count)/\(ready.of) ready", fromRow: true, scaledToZero: ready.of == 0)
        case .daemonSet:
            guard let desired = number("Desired") else { return nil }
            let updated = number("Up-to-date") ?? desired
            let available = number("Available") ?? desired
            if updated < desired { return Verdict(status: .progressing, sentence: lasting("\(updated)/\(desired) updated"), fromRow: true) }
            if available < desired { return Verdict(status: .progressing, sentence: lasting("\(available)/\(desired) available"), fromRow: true) }
            return Verdict(status: .healthy, sentence: "\(available)/\(desired) available", fromRow: true)
        case .service:
            // kubectl prints `<pending>` for a LoadBalancer with no ingress yet.
            guard cell("Type") == "LoadBalancer" else { return Verdict(status: .healthy, sentence: "service") }
            let external = cell("External-IP") ?? ""
            if external.isEmpty || external == "<pending>" || external == "<none>" { return Verdict(status: .progressing, sentence: "load balancer not assigned") }
            return Verdict(status: .healthy, sentence: "load balancer assigned")
        case .ingress:
            let address = cell("Address") ?? ""
            return address.isEmpty
                ? Verdict(status: .progressing, sentence: "no address yet", detail: "as Argo CD shows it: many ingress controllers never fill the address")
                : Verdict(status: .healthy, sentence: "address assigned")
        case .persistentVolumeClaim:
            switch cell("Status") ?? "" {
            case "Bound": return Verdict(status: .healthy, sentence: "volume claim Bound")
            case "Pending": return Verdict(status: .progressing, sentence: lasting("volume claim Pending"))
            case "Lost": return Verdict(status: .degraded, sentence: "volume claim Lost")
            case let other: return Verdict(status: .unknown, sentence: other.isEmpty ? "volume claim's phase not said" : "volume claim \(KubeMarkWire.text(other, cap: 32) ?? "")")
            }
        case .horizontalPodAutoscaler:
            if (cell("Targets") ?? "").contains("<unknown>") { return Verdict(status: nil, sentence: "a target reads <unknown>", unread: true) }
            return Verdict(status: .healthy, sentence: "every target read", fromRow: true)
        case .cronJob:
            return Verdict(status: nil, sentence: "its last run isn't read yet", unread: true)
        case .job:
            switch cell("Status") ?? "" {
            case "Failed": return Verdict(status: .degraded, sentence: "job failed", fromRow: true)
            case "Complete", "Completed": return Verdict(status: .healthy, sentence: "job complete", fromRow: true)
            case "Suspended": return Verdict(status: .suspended, sentence: "job suspended", fromRow: true)
            default:
                if let done = fraction(cell("Completions")), done.count >= done.of {
                    return Verdict(status: .healthy, sentence: "job complete", fromRow: true)
                }
                return Verdict(status: .progressing, sentence: "job running", fromRow: true)
            }
        case .other:
            return nil
        }
    }

    // MARK: From the object

    /// An object's health by Argo CD's own rule; nil for a kind with none here.
    static func object(_ wire: KubeMarkedWorkloadWire) -> Verdict? {
        let kind = KubeMarkedKind(group: wire.group, kind: wire.kind ?? "")
        if wire.metadata?.deletionTimestamp != nil { return Verdict(status: .progressing, sentence: "pending deletion") }
        let spec = wire.spec
        let status = wire.status
        let generation = wire.metadata?.generation ?? 0
        let observed = status?.observedGeneration ?? 0
        switch kind {
        case .deployment:
            if spec?.paused == true { return Verdict(status: .suspended, sentence: "rollout paused") }
            if generation > observed { return Verdict(status: .progressing, sentence: "waiting for the rollout to be observed") }
            if let stalled = wire.condition("Progressing"), stalled.reason == "ProgressDeadlineExceeded" {
                return Verdict(status: .degraded, sentence: "rollout stalled (ProgressDeadlineExceeded)", since: stalled.since, detail: stalled.message)
            }
            let wanted = spec?.replicas ?? 1
            let updated = status?.updatedReplicas ?? 0
            let replicas = status?.replicas ?? 0
            let available = status?.availableReplicas ?? 0
            let since = wire.condition("Progressing")?.since
            if updated < wanted { return Verdict(status: .progressing, sentence: "\(updated)/\(wanted) updated", since: since) }
            if replicas > updated {
                let old = replicas - updated
                return Verdict(status: .progressing, sentence: "\(old) old \(old == 1 ? "replica" : "replicas") pending termination", since: since)
            }
            if available < updated { return Verdict(status: .progressing, sentence: "\(available)/\(updated) available", since: since, detail: podsHint) }
            return Verdict(status: .healthy, sentence: wanted == 0 ? "scaled to 0" : "\(available)/\(wanted) available", scaledToZero: wanted == 0)
        case .statefulSet:
            if observed == 0 || generation > observed { return Verdict(status: .progressing, sentence: "waiting for the update to be observed") }
            let wanted = spec?.replicas ?? 1
            let ready = status?.readyReplicas ?? 0
            if ready < wanted { return Verdict(status: .progressing, sentence: "\(ready)/\(wanted) ready") }
            let strategy = spec?.updateStrategy
            if strategy?.type == "RollingUpdate", let partition = strategy?.rollingUpdate?.partition {
                let updated = status?.updatedReplicas ?? 0
                if updated < wanted - partition { return Verdict(status: .progressing, sentence: "\(updated)/\(wanted - partition) updated (partitioned)") }
                return Verdict(status: .healthy, sentence: "partitioned roll out complete")
            }
            if strategy?.type == "OnDelete" { return Verdict(status: .healthy, sentence: "\(ready)/\(wanted) ready (OnDelete)") }
            if status?.updateRevision != status?.currentRevision { return Verdict(status: .progressing, sentence: "rolling update not complete") }
            return Verdict(status: .healthy, sentence: wanted == 0 ? "scaled to 0" : "\(ready)/\(wanted) ready", scaledToZero: wanted == 0)
        case .daemonSet:
            if generation > observed { return Verdict(status: .progressing, sentence: "waiting for the update to be observed") }
            if spec?.updateStrategy?.type == "OnDelete" { return Verdict(status: .healthy, sentence: "OnDelete") }
            let desired = status?.desiredNumberScheduled ?? 0
            let updated = status?.updatedNumberScheduled ?? 0
            let available = status?.numberAvailable ?? 0
            if updated < desired { return Verdict(status: .progressing, sentence: "\(updated)/\(desired) updated") }
            if available < desired { return Verdict(status: .progressing, sentence: "\(available)/\(desired) available") }
            return Verdict(status: .healthy, sentence: "\(available)/\(desired) available")
        case .rollout:
            // Argo CD's bundled Rollout check: the controller's own phase.
            if let observed = status?.observedGeneration, generation != 0, observed != generation {
                return Verdict(status: .progressing, sentence: "waiting for the rollout to be observed")
            }
            let detail = status?.message
            switch status?.phase {
            case "Healthy": return Verdict(status: .healthy, sentence: "rollout healthy", detail: detail)
            case "Paused": return Verdict(status: .suspended, sentence: "rollout paused", detail: detail)
            case "Degraded": return Verdict(status: .degraded, sentence: "rollout degraded", detail: detail)
            case "Progressing": return Verdict(status: .progressing, sentence: "rollout progressing", detail: detail)
            case nil: return Verdict(status: .progressing, sentence: "rollout not yet reported", detail: detail)
            case let other?: return Verdict(status: .unknown, sentence: "rollout phase \(other)", detail: detail)
            }
        case .cronJob:
            // Argo CD's bundled Lua (resource_customizations/batch/CronJob).
            if spec?.suspend == true { return Verdict(status: .healthy, sentence: "suspended") }
            guard let status else { return Verdict(status: .progressing, sentence: "not run yet") }
            if (status.active ?? 0) > 0 { return Verdict(status: .healthy, sentence: "a run is going") }
            guard let scheduled = status.lastScheduleTime.flatMap(date) else { return Verdict(status: .healthy, sentence: "not run yet") }
            guard let succeeded = status.lastSuccessfulTime.flatMap(date) else {
                return Verdict(status: .healthy, sentence: "never succeeded yet", detail: "Argo CD shows a CronJob that never succeeded Healthy: it may not be")
            }
            if succeeded < scheduled {
                let name = wire.metadata?.name.flatMap { KubeMarkWire.text($0, cap: 253) }
                return Verdict(status: .degraded, sentence: name.map { "last run of CronJob \($0) failed" } ?? "last run failed", since: scheduled)
            }
            return Verdict(status: .healthy, sentence: "last run succeeded")
        case .horizontalPodAutoscaler:
            // Argo CD's v2 rule, from the conditions.
            let scale = wire.condition("AbleToScale")
            let active = wire.condition("ScalingActive")
            if let scale, ["FailedGetScale", "FailedUpdateScale"].contains(scale.reason ?? "") {
                return Verdict(status: .degraded, sentence: "can't scale (\(scale.reason ?? ""))", since: scale.since, detail: scale.message)
            }
            if let active, let reason = active.reason, failedMetric(reason) {
                return Verdict(status: .degraded, sentence: "metrics unavailable (\(reason))", since: active.since, detail: active.message)
            }
            if scale?.status == "True" || wire.condition("ScalingLimited")?.status == "True" { return Verdict(status: .healthy, sentence: "scaling") }
            return Verdict(status: .progressing, sentence: "waiting to scale")
        case .job:
            if wire.condition("Failed")?.status == "True" {
                let failed = wire.condition("Failed")
                return Verdict(status: .degraded, sentence: "job failed", since: failed?.since, detail: failed?.message)
            }
            if wire.condition("Suspended")?.status == "True" { return Verdict(status: .suspended, sentence: "job suspended") }
            if wire.condition("Complete")?.status == "True" { return Verdict(status: .healthy, sentence: "job complete") }
            return Verdict(status: .progressing, sentence: "job running")
        case .service, .ingress, .persistentVolumeClaim, .other:
            return nil
        }
    }

    /// The HPA reasons Argo CD's rule calls Degraded.
    private static func failedMetric(_ reason: String) -> Bool {
        ["FailedGetResourceMetric", "FailedGetObjectMetric", "FailedGetPodsMetric", "FailedGetExternalMetric", "FailedGetContainerResourceMetric"]
            .contains(reason) || reason == "FailedComputeMetricsReplicas" || reason == "InvalidSelector"
    }

    /// What a Progressing Deployment whose updated replicas aren't all
    /// available may hide: the list reads no pods.
    static let podsHint = "not every updated replica is available: its pods may be failing, which the detail shows"

    private static func date(_ text: String) -> Date? { try? Date(text, strategy: .iso8601) }

    /// `3/4` as counts; nil for anything else.
    static func fraction(_ text: String?) -> (count: Int, of: Int)? {
        guard let text else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let count = Int(parts[0].trimmingCharacters(in: .whitespaces)), let of = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (count, of)
    }

    // MARK: The app

    /// One member named as a cause.
    struct Cause: Equatable, Sendable {
        var member: KubeMarkedMember.ID
        var status: Status
        var sentence: String
        var detail: String?

        /// "Deployment checkout-api".
        var said: String { member.said }
    }

    /// An app's health.
    struct AppVerdict: Equatable, Sendable {
        /// Argo CD's word for the app.
        var status: Status
        /// Where it ranks: an Unknown app with a Degraded member sorts with
        /// Failed (decision D-7), one with none known worse stays Unknown —
        /// never hidden with the Ready ones.
        var state: KubeGitOpsState
        /// What the row says: the state's word, or "Unknown" when Unknown
        /// ranks with a worse member.
        var word: String
        /// The worst cause's sentence and its object, then how many more.
        var why: String
        /// At most three, worst first (Argo CD names up to three).
        var causes: [Cause] = []
        /// Causes past those three.
        var more = 0
        /// Some member's state is from its row alone, or not read yet.
        var fromRows = false
        /// When its state began: the worst cause's, or — Ready — Argo CD's
        /// last change, else the newest member's creation.
        var since: Date?
        /// What `since` is, for the hover.
        var sinceSaid: String?
        /// The hover's lines.
        var notes: [String] = []
    }

    static let noWorkload =
        "no Deployment, StatefulSet, DaemonSet, CronJob or Argo Rollout of it was read: its workload may be a kind not read here (a Job, a custom resource)"

    /// The app's health: the worst member by Argo CD's order, hooks and
    /// `ignore-healthcheck` members skipped, kinds with no rule left out;
    /// a Deployment scaled to 0 beside a Rollout said scaled by it. An app
    /// with members that have a rule but no workload read is Unknown, not
    /// Ready from its Service; one none of whose members has a rule is
    /// Ready, as Argo CD says.
    static func app(_ app: KubeMarkedApp) -> AppVerdict {
        let rolloutTargets = Set(app.members.compactMap(\.workloadRef))
        let hasRollout = app.members.contains { $0.id.kind == .rollout }
        var counted: [(member: KubeMarkedMember, verdict: Verdict?)] = []
        for member in app.members where !member.marks.ignoreHealthcheck {
            var verdict = member.health
            if member.id.kind == .deployment, hasRollout, verdict?.scaledToZero == true,
                rolloutTargets.isEmpty || rolloutTargets.contains(member.id.name)
            {
                verdict = Verdict(status: .healthy, sentence: "scaled by its Rollout")
            }
            counted.append((member, verdict))
        }
        var notes: [String] = []
        let ignored = app.members.count - counted.count
        if ignored > 0 { notes.append("\(ignored) with ignore-healthcheck: not counted, as in Argo CD") }
        if !app.hooks.isEmpty { notes.append("\(app.hooks.count) \(app.hooks.count == 1 ? "hook" : "hooks"): not counted, as in Argo CD") }
        let rated = counted.filter { $0.verdict?.status != nil }
        let unread = counted.filter { $0.verdict?.unread == true }
        for (member, _) in unread {
            notes.append(member.id.kind == .horizontalPodAutoscaler ? "an HPA's state wasn't read: \(member.said)" : "not read yet: \(member.said)")
        }
        let fromRows = !unread.isEmpty || rated.contains { $0.verdict?.fromRow == true }
        if rated.contains(where: { $0.verdict?.fromRow == true }) {
            notes.append("from its row: cells alone can hide a paused Deployment or a stuck rollout whose old pods still serve")
        }
        if counted.isEmpty || (rated.isEmpty && unread.isEmpty) {
            notes.append("no member here has a health check; Argo CD shows such an app Healthy")
            return ready(app, count: 0, fromRows: false, notes: notes)
        }
        if !counted.contains(where: { $0.member.id.kind.isWorkload }) {
            return AppVerdict(status: .unknown, state: .unknown, word: "Unknown", why: noWorkload, fromRows: fromRows, notes: notes)
        }
        guard let worst = rated.compactMap(\.verdict?.status).max() else {
            return AppVerdict(status: .unknown, state: .unknown, word: "Unknown", why: "not read yet", fromRows: true, notes: notes)
        }
        if worst == .healthy { return ready(app, count: rated.count, fromRows: fromRows, notes: notes) }
        var causes = rated.compactMap { entry -> Cause? in
            guard let verdict = entry.verdict, let status = verdict.status, status != .healthy else { return nil }
            return Cause(member: entry.member.id, status: status, sentence: verdict.sentence, detail: verdict.detail)
        }
        causes.sort { ($0.status.causeOrder, $0.member) < ($1.status.causeOrder, $1.member) }
        let known = rated.compactMap(\.verdict?.status).filter { $0 != .unknown && $0 != .missing }.max()
        let state: KubeGitOpsState
        if worst == .unknown {
            state = known.map { $0 > .healthy ? $0.state : .unknown } ?? .unknown
        } else {
            state = worst.state
        }
        let first = causes[0]
        var why = "\(first.sentence) · \(first.said)"
        if causes.count > 1 { why += " · and \(causes.count - 1) more" }
        let since = rated.first { $0.member.id == first.member }?.verdict?.since
        notes.insert("Argo CD's rule: \(worst.word)", at: 0)
        return AppVerdict(
            status: worst, state: state, word: worst == .unknown ? "Unknown" : state.word, why: why, causes: Array(causes.prefix(3)),
            more: max(0, causes.count - 3), fromRows: fromRows, since: since, sinceSaid: since == nil ? nil : "since its condition changed", notes: notes)
    }

    private static func ready(_ app: KubeMarkedApp, count: Int, fromRows: Bool, notes: [String]) -> AppVerdict {
        var notes = notes
        notes.insert("Argo CD's rule: Healthy", at: 0)
        let since: Date?
        let sinceSaid: String?
        if let changed = app.argoChanged {
            since = changed
            sinceSaid = "last change applied by Argo CD"
        } else {
            since = app.members.compactMap(\.created).max()
            sinceSaid = since == nil ? nil : "its newest object's age"
            notes.append("Argo CD's last change isn't readable here")
        }
        let why = count == 0 ? "no member with a health check" : "\(count) \(count == 1 ? "object" : "objects") ready"
        return AppVerdict(status: .healthy, state: .ready, word: KubeGitOpsState.ready.word, why: why, fromRows: fromRows, since: since, sinceSaid: sinceSaid, notes: notes)
    }
}
