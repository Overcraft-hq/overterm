import Foundation

/// What the detail says of an Argo CD Application or ApplicationSet, a
/// Flux Kustomization or HelmRelease (docs/design/kubernetes/gitops.md,
/// 2.9, G3): read from the body the detail's one GET already brought,
/// through the same allow-list as a summary (`KubeGitOpsWire`) plus what
/// only the detail shows — Argo CD's last 10 history entries, the
/// resources out of sync or needing pruning and the operation's failed
/// ones, 50 of each at most. Its state is the ladder's, with the section's
/// summaries as its peers when the page holds them: nothing is read for
/// the chain. Ask Why's brief on these kinds (6.2) is said from it too.
/// Every message went through 5.3 as it was decoded. Pure.
struct KubeGitOpsDetail: Equatable, Sendable {
    struct Resource: Equatable, Sendable {
        var group: String
        var version: String
        var kind: String
        var namespace: String?
        var name: String
        var status: String?
        var health: String?
        var requiresPruning: Bool

        /// `Deployment shop/api`.
        var said: String { "\(kind) \(namespace.map { "\($0)/" } ?? "")\(name)" }

        var link: KubeLink {
            KubeLink(apiVersion: group.isEmpty ? version : "\(group)/\(version)", kind: kind, namespace: namespace, name: name)
        }
    }

    struct HistoryEntry: Equatable, Sendable {
        var revisions: [String]
        var deployedAt: Date?
    }

    struct Failure: Equatable, Sendable {
        var kind: String
        var namespace: String?
        var name: String
        /// Through 5.3, at most 4 KB.
        var message: String?

        var said: String { "\(kind) \(namespace.map { "\($0)/" } ?? "")\(name)" + (message.map { ": \($0)" } ?? "") }
    }

    /// The summary of the object itself (its state not yet ranked).
    var object: KubeGitOpsObject
    /// Argo CD's history, newest first, at most 10.
    var history: [HistoryEntry] = []
    /// Out of sync or needing pruning, at most 50; `resourcesPast` more.
    var resources: [Resource] = []
    var resourcesPast = 0
    /// The last operation's resources that failed, at most 50; `failuresPast` more.
    var failures: [Failure] = []
    var failuresPast = 0

    /// The kinds the detail has a GitOps header for, and Ask Why asks about.
    static func isGitOps(_ kind: KubeResourceKind) -> Bool { KubeGitOpsDelete.tool(kind) != nil }

    /// The detail of one GET's body, parsed once; nil for a kind that
    /// isn't one of the four. Bodies run to megabytes (an Application's
    /// `status.resources`): called off the main thread (`KubeBlocking.run`).
    static func read(_ data: Data, readAt: Date) -> KubeGitOpsDetail? {
        guard let read = try? KubeGitOpsWire.detailRead(data), let object = KubeGitOpsObject(read.object, readAt: readAt) else { return nil }
        switch object.role {
        case .application, .applicationSet, .kustomization, .helmRelease: break
        case .source: return nil
        }
        var detail = KubeGitOpsDetail(object: object)
        guard object.role == .application, let status = read.detail?.status else { return detail }
        detail.history = status.history.reversed().map { HistoryEntry(revisions: $0.said, deployedAt: KubeGitOpsTime.date($0.deployedAt)) }
        detail.resources = status.resources.compactMap { entry in
            guard let kind = entry.kind, let name = entry.name, !name.isEmpty else { return nil }
            return Resource(
                group: entry.group ?? "", version: entry.version ?? "v1", kind: kind, namespace: entry.namespace.flatMap { $0.isEmpty ? nil : $0 }, name: name,
                status: entry.status, health: entry.health?.status, requiresPruning: entry.requiresPruning == true)
        }
        detail.resourcesPast = status.resourcesPast
        if let result = status.operationState?.syncResult {
            detail.failures = result.failed.compactMap { failed in
                guard let kind = failed.kind, let name = failed.name else { return nil }
                return Failure(
                    kind: kind, namespace: failed.namespace.flatMap { $0.isEmpty ? nil : $0 }, name: name,
                    message: failed.message.map { KubeGitOpsMessage.scrubbed($0, limit: KubeGitOpsMessage.hoverLimit) }.flatMap { $0.isEmpty ? nil : $0 })
            }
            detail.failuresPast = result.failedPast
        }
        return detail
    }

    // MARK: Its state

    /// The ladder's verdict on it, the summaries as its peers.
    func verdict(peers: KubeGitOpsLadder.Peers, now: Date) -> KubeGitOpsVerdict {
        var verdict = KubeGitOpsLadder.evaluate(object, now: now, peers: peers)
        verdict.tags += object.ownTags
        return verdict
    }

    /// `Failed: upgrade to 1.5.0 failed; rolled back to 1.4.2 (4m)`.
    static func sentence(_ verdict: KubeGitOpsVerdict, now: Date) -> String {
        let age = verdict.since.map { " (\(KubeAge.format(now.timeIntervalSince($0))))" } ?? ""
        return "\(verdict.state.word): \(verdict.why)\(age)"
    }

    // MARK: Links

    /// The group and version a key's kind is served at, as references say it.
    static func apiVersion(of kind: String) -> String {
        switch kind {
        case "Application", "ApplicationSet": "argoproj.io/v1alpha1"
        case "Kustomization": "kustomize.toolkit.fluxcd.io/v1"
        case "HelmRelease": "helm.toolkit.fluxcd.io/v2"
        default: "source.toolkit.fluxcd.io/v1"
        }
    }

    /// The object a key names: its peer's own version (and namespace, when
    /// the key's marks didn't say it) when summarised.
    static func link(_ key: KubeGitOpsObject.Key, peer: KubeGitOpsObject?) -> KubeLink {
        KubeLink(
            apiVersion: peer?.apiVersion.nilIfEmpty ?? apiVersion(of: key.kind), kind: key.kind, namespace: key.namespace ?? peer?.ref.namespace, name: key.name)
    }

    /// What it takes from and waits for, in order — its source (and a
    /// HelmRelease's chart), each `dependsOn`, the ApplicationSet or the
    /// object that manages it — each with its peer when summarised.
    func chain(peers: KubeGitOpsLadder.Peers) -> [(role: String, key: KubeGitOpsObject.Key, peer: KubeGitOpsObject?)] {
        var links: [(String, KubeGitOpsObject.Key)] = []
        for key in KubeGitOpsLadder.upstream(object) { links.append((key.kind == "HelmChart" ? "Chart" : "Source", key)) }
        for key in object.dependsOn { links.append(("Depends on", key)) }
        if let set = object.ownerAppSet {
            links.append(("Generated by", KubeGitOpsObject.Key(kind: "ApplicationSet", namespace: set.namespace, name: set.name)))
        }
        if let owner = object.parentOwner, owner.isCertain {
            let namespace = owner.namespace ?? (owner.tool == .argoCD ? nil : object.ref.namespace)
            links.append(("Managed by", KubeGitOpsObject.Key(kind: owner.tool.kind, namespace: namespace, name: owner.name)))
        }
        return links.map { role, key in (role, key, peers[key] ?? Self.named(key, in: peers)) }
    }

    /// A peer by kind and name when the key's namespace isn't known (an Argo CD owner's).
    private static func named(_ key: KubeGitOpsObject.Key, in peers: KubeGitOpsLadder.Peers) -> KubeGitOpsObject? {
        guard key.namespace == nil else { return nil }
        return peers.values.first { $0.kind == key.kind && $0.ref.name == key.name }
    }

    /// The first link in the chain that isn't ready, followed while each
    /// is among the peers (at most 5 hops): the cause of a Blocked one.
    func rootCause(peers: KubeGitOpsLadder.Peers, now: Date) -> (key: KubeGitOpsObject.Key, peer: KubeGitOpsObject, verdict: KubeGitOpsVerdict)? {
        var current = object
        var seen: Set<KubeGitOpsObject.Key> = [object.key]
        var found: (KubeGitOpsObject.Key, KubeGitOpsObject, KubeGitOpsVerdict)?
        for _ in 0..<KubeGitOpsLadder.chainHops {
            var next: (KubeGitOpsObject.Key, KubeGitOpsObject, KubeGitOpsVerdict)?
            for key in KubeGitOpsLadder.upstream(current) + current.dependsOn where !seen.contains(key) {
                guard let peer = peers[key] else { continue }
                let verdict = KubeGitOpsLadder.evaluate(peer, now: now, peers: peers)
                if verdict.state != .ready && verdict.state != .progressing {
                    next = (key, peer, verdict)
                    break
                }
            }
            guard let next else { break }
            seen.insert(next.0)
            found = next
            current = next.1
        }
        return found
    }

    // MARK: What it says

    /// Its sources as the header says them: the repository with its host,
    /// the path or the chart and its version, the ref; "values from this
    /// repo" for a `ref:` source. A Flux object's through its source's summary.
    func sourceLines(peers: KubeGitOpsLadder.Peers) -> [String] {
        func repository(_ url: String) -> String { GitRemoteURL(url)?.description ?? GitRemoteURL.withoutUserinfo(url) }
        switch object.role {
        case .application, .applicationSet:
            return object.sources.map { source in
                if let chart = source.chart {
                    return "\(chart)\(source.targetRevision.map { "@\($0)" } ?? "") from \(GitRemoteURL.withoutUserinfo(source.repoURL))"
                }
                var line = [repository(source.repoURL), source.path ?? (source.isValuesRef ? nil : "/"), "@\(source.targetRevision ?? "HEAD")"]
                    .compactMap { $0 }.joined(separator: " ")
                if source.isValuesRef { line += " — values from this repo" }
                return line
            }
        case .kustomization:
            let path = object.sources.first?.path ?? "./"
            guard let reference = object.sourceRef else { return [path] }
            let peer = peers[KubeGitOpsObject.Key(kind: reference.kind, namespace: reference.namespace, name: reference.name)]
            let where_ = peer?.sources.first.map { repository($0.repoURL) } ?? "\(reference.kind) \(reference.namespace)/\(reference.name)"
            return [[where_, path, peer?.tracks.map { "@\($0)" }].compactMap { $0 }.joined(separator: " ")]
        case .helmRelease:
            if let chart = object.sources.first?.chart, let reference = object.sourceRef {
                let version = object.sources.first?.targetRevision.map { "@\($0)" } ?? ""
                let peer = peers[KubeGitOpsObject.Key(kind: reference.kind, namespace: reference.namespace, name: reference.name)]
                let from = peer?.sources.first.map { repository($0.repoURL) } ?? "\(reference.kind) \(reference.namespace)/\(reference.name)"
                return ["\(chart)\(version) from \(from)"]
            }
            if let chart = object.chartRef {
                let peer = peers[KubeGitOpsObject.Key(kind: chart.kind, namespace: chart.namespace, name: chart.name)]
                return ["\(chart.kind) \(chart.namespace)/\(chart.name)" + (peer?.sources.first.map { " — \(repository($0.repoURL))" } ?? "")]
            }
            return []
        case .source: return []
        }
    }

    /// Each revision, with when it was applied, attempted or fetched.
    func revisionLines(peers: KubeGitOpsLadder.Peers, now: Date) -> [(label: String, value: String, when: String?)] {
        func ago(_ date: Date?, _ verb: String) -> String? { date.map { "\(verb) \(KubeAge.format(now.timeIntervalSince($0))) ago" } }
        func said(_ revisions: [String]) -> String { revisions.filter { !$0.isEmpty }.map(KubeGitOpsRevision.shown).joined(separator: " · ") }
        var lines: [(String, String, String?)] = []
        let revisions = object.revisions
        switch object.role {
        case .application:
            let applied = said(revisions.applied)
            if !applied.isEmpty { lines.append(("Applied", applied, ago(history.first?.deployedAt ?? object.operation?.finishedAt, "deployed"))) }
            let wanted = said(revisions.wanted)
            if !wanted.isEmpty { lines.append(("Wanted", wanted, ago(object.reconciledAt, "compared"))) }
            if let operation = object.operation, !operation.revisions.isEmpty, operation.revisions != revisions.applied {
                let when = (operation.finishedAt ?? operation.startedAt).map { " \(KubeAge.format(now.timeIntervalSince($0))) ago" } ?? ""
                lines.append(("Last sync", said(operation.revisions), operation.phase.lowercased() + when))
            }
        case .kustomization:
            let ready = object.condition("Ready")
            if let applied = revisions.applied.first {
                lines.append(("Applied", KubeGitOpsRevision.shown(applied), ready?.isTrue == true ? ago(ready?.since, "applied") : nil))
            }
            if let attempted = revisions.attempted, attempted != revisions.applied.first {
                let how = ready?.isFalse == true ? "failed" + (ready?.reason.map { " (\($0))" } ?? "") : "attempted"
                lines.append(("Attempted", KubeGitOpsRevision.shown(attempted), ready?.since.map { "\(how) \(KubeAge.format(now.timeIntervalSince($0))) ago" } ?? how))
            }
        case .helmRelease:
            // The release history's head: its version, its status and when.
            if let head = revisions.helmHistory, let version = head.chartVersion {
                let status = head.status ?? "deployed"
                lines.append(("Release", version, ago(head.lastDeployed, status) ?? head.status))
            }
            // The chart last tried — its digest beside it — and how it went, when.
            if let attempted = revisions.attempted {
                let value = KubeGitOpsRevision.shown(attempted) + (revisions.attemptedDigest.map { " @ \(KubeGitOpsRevision.shown($0))" } ?? "")
                let ready = object.condition("Ready")
                let how = ready?.isFalse == true ? "failed" + (ready?.reason.map { " (\($0))" } ?? "") : "attempted"
                lines.append(("Attempted", value, ready?.since.map { "\(how) \(KubeAge.format(now.timeIntervalSince($0))) ago" } ?? how))
            }
        case .applicationSet, .source: break
        }
        // What its source fetched, and when.
        if let key = KubeGitOpsLadder.upstream(object).first, let peer = peers[key], let fetched = peer.artifact?.revision {
            lines.append(("Fetched", KubeGitOpsRevision.shown(fetched), ago(peer.artifact?.lastUpdateTime, "by \(key.kind) \(key.name)")))
        }
        return lines
    }

    /// Where it deploys, how often, auto-sync or suspension.
    func settingLines(now: Date) -> [(label: String, value: String)] {
        var lines: [(String, String)] = []
        if let remote = object.remote {
            lines.append(("Into", "⇢ \(GitRemoteURL.withoutUserinfo(remote)) — another cluster, not followed"))
        } else if let destination = object.destination {
            let namespace = destination.namespace ?? (object.managedNamespaces.isEmpty ? nil : object.managedNamespaces.sorted().joined(separator: ", "))
            if object.tool == .argo {
                lines.append(("Into", [namespace, destination.inCluster ? "this cluster" : destination.cluster].compactMap { $0 }.joined(separator: " · ")))
            } else if let namespace {
                lines.append(("Into", namespace))
            }
        } else if !object.managedNamespaces.isEmpty {
            lines.append(("Into", object.managedNamespaces.sorted().joined(separator: ", ")))
        }
        if let count = object.managedCount { lines.append(("Manages", count == 1 ? "1 resource" : "\(count) resources")) }
        switch object.tool {
        case .argo where object.role == .application:
            if let auto = object.autoSync, auto.enabled {
                let with = [auto.prune ? "prune" : nil, auto.selfHeal ? "self-heal" : nil].compactMap { $0 }
                lines.append(("Auto-sync", "on" + (with.isEmpty ? "" : " — \(with.joined(separator: ", "))")))
            } else {
                lines.append(("Auto-sync", "off: synced by hand"))
            }
            if let limit = object.retryLimit { lines.append(("Retry", limit < 0 ? "on, no limit" : "up to \(limit) times")) }
        case .flux:
            if let interval = object.interval {
                lines.append(("Interval", KubeAge.format(interval) + (object.retryInterval.map { ", retried every \(KubeAge.format($0))" } ?? "")))
            }
            if object.role == .kustomization { lines.append(("Prune", object.prune ? "on: what leaves git is deleted" : "off")) }
            if object.suspended {
                var said = "yes"
                if let at = object.suspension?.at { said += ", \(KubeAge.format(now.timeIntervalSince(at))) ago" }
                if let by = object.suspension?.by, !by.isEmpty { said += " by \(by)" }
                lines.append(("Suspended", said))
            }
        default: break
        }
        return lines
    }

    /// Argo CD's last operation: its phase, who started it, how long ago,
    /// its retries, its message.
    func operationLines(now: Date) -> [(label: String, value: String)] {
        guard let operation = object.operation else { return [] }
        var lines: [(String, String)] = []
        var phase = operation.phase
        if let started = operation.startedAt {
            phase += operation.phase == "Running" ? ", for \(KubeAge.format(now.timeIntervalSince(started)))" : ", started \(KubeAge.format(now.timeIntervalSince(started))) ago"
        }
        lines.append(("Phase", phase))
        let who = operation.automated ? "auto-sync" : operation.startedBy
        if let who, !who.isEmpty { lines.append(("Started by", who)) }
        if let retries = operation.retryCount, retries > 0 { lines.append(("Retries", "\(retries)" + (object.retryLimit.map { $0 < 0 ? "" : " of \($0)" } ?? ""))) }
        if let message = operation.message, !message.isEmpty { lines.append(("Message", message)) }
        return lines
    }

    /// Each condition as one line: `Ready=False BuildFailed — …` (5.3's already).
    var conditionLines: [String] {
        object.conditions.map { condition in
            let words = [condition.reason, condition.message].compactMap { $0 }.joined(separator: ": ")
            return "\(condition.type)=\(condition.status)" + (words.isEmpty ? "" : " — \(words)")
        }
    }

    /// The whole conditions text Copy puts on the clipboard: at most 4 KB.
    var conditionsText: String {
        let text = conditionLines.joined(separator: "\n")
        guard text.utf8.count > KubeGitOpsMessage.hoverLimit else { return text }
        return String(text.prefix(KubeGitOpsMessage.hoverLimit - 1)) + "…"
    }

    // MARK: Ask Why (6.2)

    /// What Ask Why says on a Failed, Blocked or Stuck one: the summary's
    /// fields, its conditions, Argo CD's operation and the resources that
    /// failed or are out of sync, Flux's attempted against applied, a
    /// HelmRelease's history head, the chain's root cause. Not yet scrubbed
    /// as a whole: `KubeAgentBriefing.gitOps` puts every word through `Secrets`.
    func brief(context: KubeBriefContext, peers: KubeGitOpsLadder.Peers, now: Date) -> (message: String, subject: String, text: String, parts: [AskAgentModel.Part]) {
        let verdict = self.verdict(peers: peers, now: now)
        let where_ = "\(object.ref.namespace.map { "\($0)/" } ?? "")\(object.ref.name)"
        let what = "\(object.tool.said) \(object.kind) \(where_)"
        var lines = ["Kubernetes \(what), in \(context.said)."]
        lines.append("State: " + Self.sentence(verdict, now: now) + ".")
        let tags = verdict.tags.map { $0.said(now: now) }
        if !tags.isEmpty { lines.append("Also: \(tags.joined(separator: ", ")).") }
        for source in sourceLines(peers: peers) { lines.append("Source: \(source)") }
        for line in revisionLines(peers: peers, now: now) { lines.append("\(line.label): \(line.value)" + (line.when.map { " (\($0))" } ?? "")) }
        for line in settingLines(now: now) { lines.append("\(line.label): \(line.value)") }
        if let error = object.lastError, !verdict.why.contains(error) { lines.append("Last error: \(error)") }
        if let cause = rootCause(peers: peers, now: now) {
            let error = cause.peer.lastError.map { " — \($0)" } ?? ""
            lines.append("Root cause, along its chain: \(cause.key) is \(cause.verdict.state.word): \(cause.verdict.why)\(error)")
        }

        var parts: [AskAgentModel.Part] = []
        if !conditionLines.isEmpty { parts.append(.init(title: "conditions", text: conditionLines.joined(separator: "\n"))) }
        if object.role == .application {
            var operation = operationLines(now: now).map { "\($0.label): \($0.value)" }
            if !failures.isEmpty {
                operation.append("Resources that failed to sync:")
                operation += failures.map { "- \($0.said)" }
                if failuresPast > 0 { operation.append("- and \(failuresPast) more") }
            }
            if !operation.isEmpty { parts.append(.init(title: "operation", text: operation.joined(separator: "\n"))) }
            if !resources.isEmpty {
                var out = resources.map { resource in
                    "- \(resource.said): \(resource.status ?? "?")" + (resource.health.map { ", \($0)" } ?? "") + (resource.requiresPruning ? ", needs pruning" : "")
                }
                if resourcesPast > 0 { out.append("- and \(resourcesPast) more") }
                parts.append(.init(title: "out of sync", text: out.joined(separator: "\n")))
            }
            if !history.isEmpty {
                let entries = history.map { entry in
                    "- " + entry.revisions.map(KubeGitOpsRevision.shown).joined(separator: " · ")
                        + (entry.deployedAt.map { ", deployed \(KubeAge.format(now.timeIntervalSince($0))) ago" } ?? "")
                }
                parts.append(.init(title: "history", text: "Newest first:\n" + entries.joined(separator: "\n")))
            }
        }
        let chain = self.chain(peers: peers)
        if !chain.isEmpty {
            let said = chain.map { link -> String in
                guard let peer = link.peer else { return "\(link.role): \(link.key) — not summarised" }
                let verdict = KubeGitOpsLadder.evaluate(peer, now: now, peers: peers)
                return "\(link.role): \(link.key) — \(verdict.state.word): \(verdict.why)" + (peer.lastError.map { verdict.why.contains($0) ? "" : " (\($0))" } ?? "")
            }
            parts.append(.init(title: "chain", text: said.joined(separator: "\n")))
        }

        let message: String
        switch verdict.state {
        case .blocked: message = "Why is \(what) blocked, and what would unblock it?"
        case .stuck: message = "Why is \(what) stuck?"
        default: message = "Why does \(what) fail to deploy, and what should change?"
        }
        return (message, "\(object.kind)/\(object.ref.name) \(verdict.state.word)", lines.joined(separator: "\n"), parts)
    }

    /// Why Ask Why isn't offered: it isn't Failed, Blocked or Stuck.
    static func notAsked(_ object: KubeGitOpsObject, state: KubeGitOpsState, why: String) -> String? {
        guard !state.isProblem else { return nil }
        let where_ = "\(object.ref.namespace.map { "\($0)/" } ?? "")\(object.ref.name)"
        return "\(object.kind) \(where_) is \(state.word) (\(why)): Ask Why is for one that is Failed, Blocked or Stuck."
    }
}
