import Foundation

/// What a summary knows of one Argo CD or Flux object (docs/design/
/// kubernetes/gitops.md, 2.4): built from `KubeGitOpsWire`'s allow-listed
/// decode alone, so nothing it holds was ever a value, a parameter, a patch
/// or a manifest; every message through `KubeGitOpsMessage` (5.3). Its
/// `state` is the ladder's (`KubeGitOpsLadder`), set by
/// `KubeGitOpsSummary.ranked` — again on every tick, with no read. Pure,
/// Sendable.
struct KubeGitOpsObject: Equatable, Sendable, Identifiable {
    enum Tool: String, Equatable, Hashable, Sendable {
        case argo, flux

        var said: String { self == .argo ? "Argo CD" : "Flux" }
    }

    enum Role: Equatable, Hashable, Sendable {
        case application, applicationSet, kustomization, helmRelease
        /// A Flux source, by its kind: `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart`, `Bucket`.
        case source(String)

        /// What the Kind column says.
        var short: String {
            switch self {
            case .application: "App"
            case .applicationSet: "AppSet"
            case .kustomization: "Ks"
            case .helmRelease: "HR"
            case .source("GitRepository"): "Git"
            case .source("OCIRepository"): "OCI"
            case .source("HelmRepository"): "HelmRepo"
            case .source("HelmChart"): "Chart"
            case .source("Bucket"): "Bucket"
            case .source(let kind): kind
            }
        }
    }

    /// A condition, its message through 5.3 (at most 4 KB).
    struct Condition: Equatable, Sendable {
        var type: String
        var status: String
        var reason: String?
        var message: String?
        var since: Date?

        var isTrue: Bool { status == "True" }
        var isFalse: Bool { status == "False" }
    }

    struct AutoSync: Equatable, Sendable {
        var enabled: Bool
        var prune: Bool
        var selfHeal: Bool
    }

    struct Suspension: Equatable, Sendable {
        /// When `spec.suspend` was last set, and by whom (managedFields').
        var at: Date?
        var by: String?
    }

    struct Destination: Equatable, Sendable {
        /// The server's URL or the cluster's name, as written.
        var cluster: String?
        var namespace: String?
        var inCluster: Bool
    }

    struct Revisions: Equatable, Sendable {
        /// What is applied: Argo CD's live revision(s) (history's last, else
        /// the last operation's); a Kustomization's `lastAppliedRevision`.
        var applied: [String] = []
        /// Flux's `lastAttemptedRevision`.
        var attempted: String?
        /// A HelmRelease's `lastAttemptedRevisionDigest`: its `chartRef`'s OCI digest.
        var attemptedDigest: String?
        /// What git has now: Argo CD's `sync.revision(s)`.
        var wanted: [String] = []
        /// A HelmRelease's newest history entry.
        var helmHistory: HelmHistory?
    }

    struct HelmHistory: Equatable, Sendable {
        var chartVersion: String?
        var status: String?
        var lastDeployed: Date?
    }

    struct Artifact: Equatable, Sendable {
        var revision: String?
        var lastUpdateTime: Date?
    }

    struct Operation: Equatable, Sendable {
        var phase: String
        var startedAt: Date?
        var finishedAt: Date?
        /// The revision(s) it synced (`syncResult`).
        var revisions: [String]
        var message: String?
        var retryCount: Int?
        var startedBy: String?
        var automated: Bool
        /// The first resource whose sync failed: `Deployment/acme-web: …`.
        var failedResource: String?
    }

    struct Origin: Equatable, Sendable {
        var repo: GitRemoteURL
        var revision: String?
    }

    /// A Flux object's or Argo source's key among the summaries.
    struct Key: Hashable, Sendable, CustomStringConvertible {
        var kind: String
        var namespace: String?
        var name: String

        var description: String { "\(kind) \(namespace.map { "\($0)/" } ?? "")\(name)" }
    }

    // Identity
    var ref: KubeRowID
    /// `applications.argoproj.io`.
    var resource: String
    var kind: String
    var apiVersion: String
    var role: Role
    var tool: Tool
    var uid: String?
    var resourceVersion: String?
    var generation: Int?
    var observedGeneration: Int?
    /// When `spec` last changed, from the newest managedFields entry that owns it.
    var generationChangedAt: Date?
    var created: Date?
    var deleting = false
    /// The cells the summary was taken with, date columns left out (set by the reader).
    var cells: [String] = []

    // The ladder's
    var state: KubeGitOpsState = .unknown
    var why = ""
    var stateSince: Date?
    var tags: [KubeGitOpsTag] = []

    // Argo CD
    var sync: String?
    var health: String?
    var healthMessage: String?
    var autoSync: AutoSync?
    var retryLimit: Int?
    var reconciledAt: Date?
    var operation: Operation?
    var healthElsewhere = false
    var images: [String] = []
    var manifestPaths: [String] = []
    var pruneNeeded = 0

    // Both
    var conditions: [Condition] = []
    var sources: [KubeGitOpsSource] = []
    var destination: Destination?
    /// Deploys to another cluster: said, never followed, never scope.
    var remote: String?
    var managedNamespaces: Set<String> = []
    var managedCount: Int?
    var revisions = Revisions()
    var parentOwner: KubeGitOpsOwner?
    var ownerAppSet: KubeRowID?

    // Flux
    var suspended = false
    var suspension: Suspension?
    var interval: TimeInterval?
    var retryInterval: TimeInterval?
    var prune = false
    var sourceRef: KubeGitOps.FluxSource?
    var chartRef: KubeGitOps.FluxSource?
    var dependsOn: [Key] = []
    var tracks: String?
    var artifact: Artifact?
    var artifactOrigin: Origin?

    /// The first message that says something (2.4), through 5.3, at most 300 characters.
    var lastError: String?
    /// When the summary was read.
    var readAt: Date

    var id: KubeRowID { ref }

    /// What it is, whatever its state: several sources, values from a repository.
    var ownTags: [KubeGitOpsTag] {
        guard role == .application else { return [] }
        var tags: [KubeGitOpsTag] = []
        if sources.count > 1 { tags.append(.multiSource) }
        if sources.contains(where: \.isValuesRef) { tags.append(.valuesRef) }
        return tags
    }
    var key: Key { Key(kind: kind, namespace: ref.namespace, name: ref.name) }

    func condition(_ type: String) -> Condition? { conditions.first { $0.type == type } }

    // MARK: From the wire

    /// The kinds a summary is made of, by group: Argo CD's and Flux's.
    static func role(group: String, kind: String) -> (Role, Tool)? {
        switch (group, kind) {
        case ("argoproj.io", "Application"): (.application, .argo)
        case ("argoproj.io", "ApplicationSet"): (.applicationSet, .argo)
        case ("kustomize.toolkit.fluxcd.io", "Kustomization"): (.kustomization, .flux)
        case ("helm.toolkit.fluxcd.io", "HelmRelease"): (.helmRelease, .flux)
        case ("source.toolkit.fluxcd.io", let kind) where KubeGitOps.sourceResources[kind] != nil: (.source(kind), .flux)
        default: nil
        }
    }

    /// A summary of `wire`; nil for a kind that isn't Argo CD's or Flux's,
    /// or an object with no name.
    init?(_ wire: KubeGitOpsWire.Object, readAt: Date) {
        let apiVersion = wire.apiVersion ?? ""
        let group = apiVersion.contains("/") ? String(apiVersion.split(separator: "/").first ?? "") : ""
        guard let kind = wire.kind, let (role, tool) = Self.role(group: group, kind: kind), let name = wire.metadata?.name, !name.isEmpty else {
            return nil
        }
        let metadata = wire.metadata
        let namespace = metadata?.namespace.flatMap { $0.isEmpty ? nil : $0 }
        let spec = wire.spec
        let status = wire.status
        ref = KubeRowID(namespace: namespace, name: name)
        self.kind = kind
        self.apiVersion = apiVersion
        self.role = role
        self.tool = tool
        self.readAt = readAt
        let plural = KubeGitOps.sourceResources[kind].map { String($0.split(separator: ".").first ?? "") } ?? Self.plural(role)
        resource = "\(plural).\(group)"
        uid = metadata?.uid
        resourceVersion = metadata?.resourceVersion
        generation = metadata?.generation
        observedGeneration = status?.observedGeneration
        created = KubeGitOpsTime.date(metadata?.creationTimestamp)
        deleting = metadata?.deletionTimestamp != nil
        conditions = (status?.conditions ?? []).compactMap { condition in
            guard let type = condition.type else { return nil }
            return Condition(
                type: type, status: condition.status ?? "Unknown", reason: condition.reason.flatMap { $0.isEmpty ? nil : $0 },
                message: condition.message.map { KubeGitOpsMessage.scrubbed($0, limit: KubeGitOpsMessage.hoverLimit) }.flatMap { $0.isEmpty ? nil : $0 },
                since: KubeGitOpsTime.date(condition.lastTransitionTime))
        }

        // managedFields: when spec last changed, when suspend was set and by whom.
        var specChanged: Date?
        var suspendSet: (Date?, String?)?
        for entry in metadata?.managedFields ?? [] {
            let time = KubeGitOpsTime.date(entry.time)
            if entry.fieldsV1?.spec == true, let time, specChanged.map({ time > $0 }) ?? true { specChanged = time }
            if entry.fieldsV1?.suspend == true {
                if suspendSet == nil || (time ?? .distantPast) > (suspendSet?.0 ?? .distantPast) { suspendSet = (time, entry.manager) }
            }
        }
        generationChangedAt = specChanged

        // Who deploys it.
        parentOwner = KubeGitOpsOwner.parse(labels: metadata?.labels?.marks ?? [:], annotations: metadata?.annotations?.marks ?? [:])
            .first { !($0.tool.kind == kind && $0.name == name) }
        if let set = metadata?.ownerReferences?.first(where: { $0.kind == "ApplicationSet" }), let setName = set.name, !setName.isEmpty {
            ownerAppSet = KubeRowID(namespace: namespace, name: setName)
        }
        manifestPaths = (metadata?.annotations?.manifestGeneratePaths ?? "").split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }

        switch tool {
        case .argo: readArgo(spec, status)
        case .flux: readFlux(spec, status, namespace: namespace, suspendSet: suspendSet)
        }
        lastError = Self.lastError(self, status: status).map { KubeGitOpsMessage.scrubbed($0, limit: KubeGitOpsMessage.rowLimit) }
    }

    private static func plural(_ role: Role) -> String {
        switch role {
        case .application: "applications"
        case .applicationSet: "applicationsets"
        case .kustomization: "kustomizations"
        case .helmRelease: "helmreleases"
        case .source(let kind): kind.lowercased() + "s"
        }
    }

    private mutating func readArgo(_ spec: KubeGitOpsWire.Spec?, _ status: KubeGitOpsWire.Status?) {
        guard role == .application else { return }
        sources = (spec?.sources?.isEmpty == false ? spec?.sources ?? [] : spec?.source.map { [$0] } ?? []).map(\.source)
        if let destination = spec?.destination {
            let here = KubeGitOpsSource.inCluster(server: destination.server, name: destination.name)
            let cluster = [destination.server, destination.name].compactMap { $0 }.first { !$0.isEmpty }
            self.destination = Destination(cluster: cluster, namespace: destination.namespace.flatMap { $0.isEmpty ? nil : $0 }, inCluster: here)
            if !here { remote = cluster ?? "another cluster" }
        }
        if let automated = spec?.syncPolicy?.automated {
            autoSync = AutoSync(enabled: automated.enabled ?? true, prune: automated.prune ?? false, selfHeal: automated.selfHeal ?? false)
        }
        retryLimit = spec?.syncPolicy?.retry.map { $0.limit ?? -1 }
        sync = status?.sync?.status
        health = status?.health?.status
        healthMessage = status?.health?.message.map { KubeGitOpsMessage.scrubbed($0, limit: KubeGitOpsMessage.hoverLimit) }
        reconciledAt = KubeGitOpsTime.date(status?.reconciledAt)
        healthElsewhere = status?.resourceHealthSource == "appTree"
        images = Array((status?.summary?.images ?? []).prefix(KubeGitOpsWire.imagesKept))
        if let resources = status?.resources {
            managedCount = resources.count
            managedNamespaces = resources.namespaces
            pruneNeeded = resources.pruneNeeded
        }
        let historyApplied = status?.historyLast?.said ?? []
        let operation = status?.operationState
        // A failed operation's result was never applied: only a succeeded one stands in for history.
        revisions.applied = historyApplied.isEmpty && operation?.phase == "Succeeded" ? (operation?.syncResult?.said ?? []) : historyApplied
        revisions.wanted = status?.sync?.said ?? []
        if let operation, let phase = operation.phase {
            let failed = operation.syncResult?.resources?.first.map { resource -> String in
                let what = [resource.kind, resource.name].compactMap { $0 }.joined(separator: "/")
                return resource.message.map { "\(what): \($0)" } ?? what
            }
            self.operation = Operation(
                phase: phase, startedAt: KubeGitOpsTime.date(operation.startedAt), finishedAt: KubeGitOpsTime.date(operation.finishedAt),
                revisions: operation.syncResult?.said ?? [], message: operation.message.map { KubeGitOpsMessage.scrubbed($0, limit: KubeGitOpsMessage.hoverLimit) },
                retryCount: operation.retryCount, startedBy: operation.operation?.initiatedBy?.username,
                automated: operation.operation?.initiatedBy?.automated == true,
                failedResource: failed.map { KubeGitOpsMessage.scrubbed($0, limit: KubeGitOpsMessage.hoverLimit) })
        }
    }

    private mutating func readFlux(
        _ spec: KubeGitOpsWire.Spec?, _ status: KubeGitOpsWire.Status?, namespace: String?, suspendSet: (Date?, String?)?
    ) {
        suspended = spec?.suspend == true
        if suspended { suspension = Suspension(at: suspendSet?.0, by: suspendSet?.1) }
        interval = spec?.interval.flatMap(KubeGitOpsTime.duration)
        retryInterval = spec?.retryInterval.flatMap(KubeGitOpsTime.duration)
        prune = spec?.prune == true
        let own = namespace ?? ""
        func flux(_ reference: KubeGitOpsWire.Reference?) -> KubeGitOps.FluxSource? {
            guard let reference, let kind = reference.kind, let name = reference.name, !name.isEmpty, let resource = KubeGitOps.sourceResources[kind]
            else { return nil }
            return KubeGitOps.FluxSource(kind: kind, resource: resource, name: name, namespace: reference.namespace.flatMap { $0.isEmpty ? nil : $0 } ?? own)
        }
        switch role {
        case .kustomization:
            sourceRef = flux(spec?.sourceRef)
            dependsOn = (spec?.dependsOn ?? []).compactMap { dependsOnKey($0, kind: "Kustomization", own: namespace) }
            if let applied = status?.lastAppliedRevision, !applied.isEmpty { revisions.applied = [applied] }
            revisions.attempted = status?.lastAttemptedRevision.flatMap { $0.isEmpty ? nil : $0 }
            if let inventory = status?.inventory {
                managedCount = inventory.count
                managedNamespaces = inventory.namespaces
            }
            let target = spec?.targetNamespace.flatMap { $0.isEmpty ? nil : $0 }
            destination = Destination(cluster: nil, namespace: target, inCluster: spec?.kubeConfig == nil)
            if let path = spec?.path { sources = [KubeGitOpsSource(repoURL: "", path: path, chart: nil, targetRevision: nil, ref: nil)] }
        case .helmRelease:
            chartRef = flux(spec?.chartRef)
            sourceRef = flux(spec?.chart?.spec?.sourceRef)
            dependsOn = (spec?.dependsOn ?? []).compactMap { dependsOnKey($0, kind: "HelmRelease", own: namespace) }
            revisions.attempted = status?.lastAttemptedRevision.flatMap { $0.isEmpty ? nil : $0 }
            revisions.attemptedDigest = status?.lastAttemptedRevisionDigest.flatMap { $0.isEmpty ? nil : $0 }
            if let first = status?.historyFirst { revisions.helmHistory = HelmHistory(chartVersion: first.chartVersion, status: first.status, lastDeployed: KubeGitOpsTime.date(first.lastDeployed)) }
            // A HelmRelease's namespace is its target's, else its own.
            let target = spec?.targetNamespace.flatMap { $0.isEmpty ? nil : $0 } ?? namespace
            destination = Destination(cluster: nil, namespace: target, inCluster: spec?.kubeConfig == nil)
            if let chart = spec?.chart?.spec?.chart {
                sources = [KubeGitOpsSource(repoURL: "", path: nil, chart: chart, targetRevision: spec?.chart?.spec?.version, ref: nil)]
            }
        case .source(let sourceKind):
            if let url = spec?.url ?? spec?.endpoint {
                sources = [
                    KubeGitOpsSource(repoURL: url, path: nil, chart: nil, targetRevision: spec?.ref?.tracks, ref: nil)
                ]
            }
            if sourceKind == "HelmChart" { sourceRef = flux(spec?.sourceRef) }
            tracks = spec?.ref?.tracks ?? (sourceKind == "GitRepository" ? "master" : nil)
            if let artifact = status?.artifact {
                self.artifact = Artifact(revision: artifact.revision, lastUpdateTime: KubeGitOpsTime.date(artifact.lastUpdateTime))
                if let origin = artifact.metadata?.source, let repo = GitRemoteURL(origin) {
                    artifactOrigin = Origin(repo: repo, revision: artifact.metadata?.revision)
                }
            }
        default: break
        }
        if let kubeConfig = spec?.kubeConfig { remote = kubeConfig.said }
    }

    private func dependsOnKey(_ reference: KubeGitOpsWire.Reference, kind: String, own: String?) -> Key? {
        guard let name = reference.name, !name.isEmpty else { return nil }
        return Key(kind: kind, namespace: reference.namespace.flatMap { $0.isEmpty ? nil : $0 } ?? own, name: name)
    }

    /// The first message that says something (2.4): Argo CD's `*Error`
    /// condition, its failed operation's (with the first resource that
    /// failed), its health's, then its warnings; Flux's Ready False,
    /// Stalled, Reconciling with retries, a HelmRelease's Released or
    /// Remediated False; an ApplicationSet's ErrorOccurred.
    private static func lastError(_ object: KubeGitOpsObject, status: KubeGitOpsWire.Status?) -> String? {
        func said(_ condition: Condition?) -> String? {
            guard let condition else { return nil }
            let text = [condition.reason, condition.message].compactMap { $0 }.joined(separator: ": ")
            return text.isEmpty ? nil : text
        }
        switch object.role {
        case .application:
            if let error = object.conditions.first(where: { $0.type.hasSuffix("Error") }) {
                return error.message ?? error.type
            }
            if let operation = object.operation, ["Failed", "Error"].contains(operation.phase) {
                let parts = [operation.message, operation.failedResource].compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty { return parts.joined(separator: " — ") }
            }
            if let message = object.healthMessage, !message.isEmpty { return message }
            if let warning = object.conditions.first(where: { ["OrphanedResourceWarning", "SharedResourceWarning"].contains($0.type) }) {
                return warning.message.map { "\(warning.type): \($0)" } ?? warning.type
            }
            return nil
        case .applicationSet:
            return object.condition("ErrorOccurred").flatMap { $0.isTrue ? ($0.message ?? $0.reason) : nil }
        default:
            if let ready = object.condition("Ready"), ready.isFalse, let text = said(ready) { return text }
            if let stalled = object.condition("Stalled"), stalled.isTrue, let text = said(stalled) { return text }
            if let reconciling = object.condition("Reconciling"), reconciling.isTrue, reconciling.reason == "ProgressingWithRetry",
                let text = said(reconciling)
            {
                return text
            }
            for type in ["Released", "Remediated"] {
                if let condition = object.condition(type), condition.isFalse, let text = said(condition) { return text }
            }
            return nil
        }
    }
}

/// A tag beside a row's state: what doesn't change its state but is worth saying.
enum KubeGitOpsTag: Equatable, Hashable, Sendable {
    /// Argo CD's sync by hand (no auto-sync): a choice, not a state.
    case manual
    case multiSource
    /// A `ref:` source: values from a repository.
    case valuesRef
    /// A failed operation for an older revision.
    case lastSyncFailed(Date?)
    /// Paused: the state its conditions show.
    case last(String)
    /// Its controller isn't ready: its state may be stale.
    case mayBeStale
    /// Argo CD hasn't reconciled it for this long (past 3 × 180 s).
    case notReconciled(TimeInterval)

    func said(now: Date) -> String {
        switch self {
        case .manual: "manual"
        case .multiSource: "several sources"
        case .valuesRef: "values from a repository"
        case .lastSyncFailed(let at): at.map { "last sync failed \(KubeAge.format(now.timeIntervalSince($0))) ago" } ?? "last sync failed"
        case .last(let state): "last: \(state)"
        case .mayBeStale: "may be stale"
        case .notReconciled(let seconds): "not reconciled for \(KubeAge.format(seconds))"
        }
    }
}

/// Every message a summary keeps (gitops.md, 5.3), in order: cut at its
/// first manifest line, every URL's password masked and userinfo dropped,
/// credentials scrubbed, then cut to its length — 300 characters in a row,
/// 4 KB where it is read whole (the hover, a condition, a brief). Pure.
enum KubeGitOpsMessage {
    static let rowLimit = 300
    static let hoverLimit = 4096

    static func scrubbed(_ message: String, limit: Int) -> String {
        var text = KubeHealth.cutAtManifest(message)
        text = Secrets.maskURLs(in: text)
        text = GitRemoteURL.stripUserinfo(inText: text)
        text = Secrets.scrubCredentials(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Already-scrubbed text as one row's line: every run of whitespace
    /// (newlines too) one space, cut to `limit`.
    static func oneLine(_ text: String, limit: Int) -> String {
        let folded = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit - 1)) + "…"
    }
}

/// The times and durations Argo CD and Flux write. Pure.
enum KubeGitOpsTime {
    /// RFC 3339, with or without a fraction.
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Go's duration (`10m`, `1h0m0s`, `30s`, `500ms`, `1.5h`) in seconds; nil for anything else.
    static func duration(_ text: String) -> TimeInterval? {
        let units: [(String, TimeInterval)] = [("ms", 0.001), ("us", 0.000_001), ("µs", 0.000_001), ("ns", 0.000_000_001), ("h", 3600), ("m", 60), ("s", 1)]
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        var total: TimeInterval = 0
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            guard let unit = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += value * unit.1
            rest = rest.dropFirst(unit.0.count)
        }
        return total
    }
}
