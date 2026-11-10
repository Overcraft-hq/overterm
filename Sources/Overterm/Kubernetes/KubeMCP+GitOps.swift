import Foundation

/// `k8s_gitops` (docs/design/kubernetes/gitops.md, 6.1; G7): Argo CD's and
/// Flux's objects as the GitOps section ranks them, one scrubbed line each
/// — its state on the one ladder (`KubeGitOpsLadder`), why, the revision
/// applied (and Flux's failed attempt), the source, where it deploys, the
/// last error. Read on demand, never followed: one paged, byte-bounded
/// list of whole objects a kind (`pagedObjects`, decoded straight into the
/// allow-list — no value, patch, manifest or `status.resources` is ever
/// held; a count only), at 200 objects or 16 MB a kind, through the
/// agent's background slot, each within `readTimeout`. A kind refused
/// across the cluster is read where it lives (the scope's namespaces,
/// `argocd`, `flux-system`), said. Scope as the section's: an object in
/// the namespace or deploying into it, and what it takes from.
///
/// **`checkout: true`** is what deploys the calling pane's checkout (4),
/// and only on its binding's context: refused unbound, refused naming
/// another context. The bound workloads' owners by one GET each (P0–P2);
/// what the rail listed in the last five minutes when it is kept
/// (`KubeGitOpsMatchCache`); else, off production, its lists across the
/// cluster (P3–P4) at the agent's bounds, not kept. On production it never
/// lists across the cluster: it says to press Find What Deploys This. Each
/// match with the deployed sentence (`KubeGitOpsReach`, the checkout's
/// git, nothing fetched) and Flux's attempted line.
///
/// Every message has been through 5.3 already (the summaries'); the whole
/// answer goes through `Secrets` once more. No write tool exists for
/// GitOps; `k8s_apply` on these kinds has the person type the name (G0d).
extension KubeMCP {
    /// An agent's read: 200 objects or 16 MB a kind (the section's are 500 and 64 MB).
    static let gitOpsObjects = 200
    static let gitOpsBytes = 16 << 20
    /// At most this many matches are asked of the checkout's git.
    static let gitOpsReaches = 10
    /// A refused kind is read in at most this many namespaces.
    static let gitOpsFallbackNamespaces = 6
    /// What the rail read (a test's own), and the checkouts' remotes.
    static var gitOpsCache: KubeGitOpsMatchCache = .shared
    static var gitOpsCheckouts: KubeGitOpsCheckouts = .shared

    /// `kind`: which objects.
    enum GitOpsFilter: String, CaseIterable, Sendable {
        case application, applicationset, kustomization, helmrelease, source, all

        init?(typed: String) {
            switch typed.lowercased() {
            case "application", "applications", "app", "apps", "applications.argoproj.io": self = .application
            case "applicationset", "applicationsets", "appset", "appsets", "applicationsets.argoproj.io": self = .applicationset
            case "kustomization", "kustomizations", "ks", "kustomizations.kustomize.toolkit.fluxcd.io": self = .kustomization
            case "helmrelease", "helmreleases", "hr", "helmreleases.helm.toolkit.fluxcd.io": self = .helmrelease
            case "source", "sources": self = .source
            case "all", "*": self = .all
            default: return nil
            }
        }

        func includes(_ role: KubeGitOpsObject.Role) -> Bool {
            switch (self, role) {
            case (.all, _), (.application, .application), (.applicationset, .applicationSet), (.kustomization, .kustomization),
                (.helmrelease, .helmRelease), (.source, .source):
                true
            default: false
            }
        }

        /// The kinds read: those shown, and what their state rests on (a
        /// Flux object's sources and charts, an ApplicationSet's Applications).
        var reads: Set<KubeGitOpsSummary.Kind> {
            let sources = Set(KubeGitOpsSummary.summarised.filter { $0.group == "source.toolkit.fluxcd.io" })
            func kind(_ group: String, _ resource: String) -> KubeGitOpsSummary.Kind { .init(group: group, resource: resource) }
            switch self {
            case .application: return [kind("argoproj.io", "applications")]
            case .applicationset: return [kind("argoproj.io", "applications"), kind("argoproj.io", "applicationsets")]
            case .kustomization: return sources.union([kind("kustomize.toolkit.fluxcd.io", "kustomizations")])
            case .helmrelease: return sources.union([kind("helm.toolkit.fluxcd.io", "helmreleases")])
            case .source: return sources
            case .all: return Set(KubeGitOpsSummary.summarised)
            }
        }
    }

    /// A filter's one kind as `discovery` serves it (`application` →
    /// `applications.argoproj.io`), for `k8s_why`.
    static func gitOpsKind(_ filter: GitOpsFilter, in discovery: KubeDiscovery) -> KubeResourceKind? {
        let name: String? =
            switch filter {
            case .application: "Application"
            case .applicationset: "ApplicationSet"
            case .kustomization: "Kustomization"
            case .helmrelease: "HelmRelease"
            case .source, .all: nil
            }
        return name.flatMap { KubePanelGitOps.kind(of: $0, in: discovery) }
    }

    // MARK: k8s_gitops

    static func gitops(_ call: Call, _ target: Target, kubernetes: KubernetesModel, pane: String?, list: KubeContextList, now: Date) async throws -> String {
        let typed = call.string("kind") ?? "all"
        guard let filter = GitOpsFilter(typed: typed) else {
            throw BrowserMCP.ToolError(message: "“kind” is application, applicationset, kustomization, helmrelease, source or all.")
        }
        let limit = call.int("limit", default: defaultRows, in: 1...maxRows)
        let failing = call.bool("failing_only")
        if call.bool("checkout") {
            return try await gitOpsCheckout(call, kubernetes: kubernetes, pane: pane, list: list, filter: filter, failing: failing, limit: limit, now: now)
        }
        let discovery = try await discovery(for: target, kubernetes: kubernetes)
        var lines = [target.header()]
        guard KubeGitOpsSummary.served(discovery) else {
            lines.append("\(target.context.name) serves neither Argo CD's Applications nor any Flux kind.")
            return KubeMCPText.finished(lines.joined(separator: "\n"))
        }
        let wanted = filter.reads
        let kinds = KubeGitOpsSummary.kinds(discovery).filter { wanted.contains(.init(group: $0.group, resource: $0.resource)) }
        var objects: [KubeGitOpsObject] = []
        var notes: [String] = []
        for kind in kinds {
            let read = await gitOpsRead(kind, target, now: now)
            objects += read.objects
            notes += read.notes
        }
        let ranked = KubeGitOpsSummary.ranked(objects, now: now)
        var peers: KubeGitOpsLadder.Peers = [:]
        for object in ranked { peers[object.key] = object }
        var shown = KubeGitOpsSummary.kept(ranked, scope: target.scope).filter { filter.includes($0.role) }
        if failing { shown = shown.filter(\.state.isProblem) }
        lines.append(KubeMCPGitOpsText.counts(shown, filter: filter, failing: failing, scope: target.scope))
        lines += shown.prefix(limit).map { KubeMCPGitOpsText.line($0, peers: peers, now: now) }
        if shown.count > limit { lines.append("… \(shown.count - limit) more not listed: narrow it with kind, failing_only or a namespace, or raise limit.") }
        lines += notes
        return KubeMCPText.finished(lines.joined(separator: "\n"))
    }

    /// One kind's objects at the agent's bounds: across the cluster, else
    /// — refused — where it lives. What was cut or refused, said.
    private static func gitOpsRead(_ kind: KubeResourceKind, _ target: Target, now: Date) async -> (objects: [KubeGitOpsObject], notes: [String]) {
        let client = target.client
        let title = KubeKindCatalog.title(of: kind)
        func cut(_ paged: KubeGitOpsPaged, in place: String? = nil) -> String? {
            paged.cut.map {
                "\(title)\(place.map { " in \($0)" } ?? ""): \($0.replacingOccurrences(of: "; the rest show their state only", with: "")); the rest not read — narrow it with a namespace or kind."
            }
        }
        do {
            let paged = try await within {
                try await client.pagedObjects(kind, in: nil, stopAfter: gitOpsObjects, totalBytes: gitOpsBytes, readAt: now)
            }
            return (paged.objects, [cut(paged)].compactMap { $0 })
        } catch let error as KubeAPIError where error.isForbidden {
            // Refused across the cluster: where it lives.
        } catch {
            return ([], ["\(title): couldn't be read — \(said(error))"])
        }
        var places = target.scope.names?.sorted() ?? []
        places.append(kind.group == "argoproj.io" ? KubeGitOps.argoDefaultNamespace : KubeGitOpsControllers.fluxNamespace)
        if kind.group == "argoproj.io" { places += gitOpsCache.seenApplications(target.context.name).sorted() }
        var seen: Set<String> = []
        places = Array(places.filter { seen.insert($0).inserted }.prefix(gitOpsFallbackNamespaces))
        var objects: [KubeGitOpsObject] = []
        var notes: [String] = []
        var readIn: [String] = []
        var refused: [String] = []
        // The kind's bound, objects and bytes, held across every place it is read in.
        var budget = KubeGitOpsBudget(objects: gitOpsObjects, bytes: gitOpsBytes)
        for place in places {
            guard budget.allows(place) else { continue }
            let left = budget.left
            do {
                let paged = try await within {
                    try await client.pagedObjects(kind, in: place, stopAfter: left.objects, totalBytes: left.bytes, readAt: now)
                }
                budget.spend(paged)
                objects += paged.objects
                readIn.append(place)
                if let said = cut(paged, in: place) { notes.append(said) }
            } catch let error as KubeAPIError where error.isForbidden || error.isNotFound {
                refused.append(place)
            } catch {
                notes.append("\(title) in \(place): couldn't be read — \(said(error))")
            }
        }
        var said = "\(title): forbidden across the cluster; read in \(readIn.isEmpty ? "none" : readIn.joined(separator: ", "))"
        if !refused.isEmpty { said += "; refused in \(refused.joined(separator: ", "))" }
        return (objects, [said + "."] + notes + [budget.said(title).map { $0 + " — narrow it with a namespace or kind." }].compactMap { $0 })
    }

    // MARK: checkout: true

    /// What deploys the calling pane's checkout, on its binding's context only.
    private static func gitOpsCheckout(
        _ call: Call, kubernetes: KubernetesModel, pane: String?, list: KubeContextList, filter: GitOpsFilter, failing: Bool, limit: Int, now: Date
    ) async throws -> String {
        guard let binding = binding(for: pane, in: list), let context = list.context(named: binding.context) else {
            throw BrowserMCP.ToolError(
                message:
                    "checkout: true answers for the calling pane's checkout, and it isn't bound to a context (bind it in the Kubernetes rail). Without checkout, k8s_gitops reads a context's objects.")
        }
        if let named = call.string("context"), named != binding.context {
            throw BrowserMCP.ToolError(
                message: "checkout: true answers only on the checkout's own context, \(binding.context) — not “\(named)”. Without checkout, k8s_gitops reads \(named)'s objects.")
        }
        let target = Target(context: context, client: kubernetes.agentClient(for: context), scope: .namespace(binding.namespace))
        let client = target.client
        let root = URL(fileURLWithPath: binding.checkout)
        let facts = await gitOpsCheckouts.facts(root)
        let key = KubeGitOpsMatchCache.Key(context: context.name, checkout: binding.checkout, namespace: binding.namespace, remotes: facts.remotesKey)
        var lines = [target.header(), "What deploys this checkout (\(root.lastPathComponent)), bound to \(context.name)/\(binding.namespace):"]
        var notes: [String] = []

        // P0
        let discovery = try await discovery(for: target, kubernetes: kubernetes)
        let served = KubeGitOpsSummary.served(discovery)
        if !served { notes.append("\(context.name) serves neither Argo CD's Applications nor any Flux kind: only the workloads' own marks are said.") }

        // P1: the bound workloads, their owner marks and images, in the binding's namespace.
        var workloads: [(ref: KubeWorkloadRef, owners: [KubeGitOpsOwner], images: [String])] = []
        let options = KubeListOptions(labelSelector: binding.selector, metadata: true, owners: true)
        for workload in KubeWorkloadKind.allCases {
            let kind = workload.kind
            do {
                let table = try await within { try await client.list(kind, in: .namespace(binding.namespace), options: options) }
                for row in table.rows where binding.includes(workload, row.id.name) {
                    let images = KubeDeployedCommit.images(inCell: row.cell("Images", in: table.columns)?.text)
                    workloads.append((KubeWorkloadRef(kind: workload, name: row.id.name), row.owners, images))
                }
            } catch {
                notes.append("Couldn't list \(kind.kind)s in \(binding.namespace): \(said(error))")
            }
        }

        // P2: each owner named, by one GET.
        let named = KubeGitOpsMatch.owners(workloads.map { ($0.ref, $0.owners) })
        let owners =
            try await within {
                await KubePanelGitOps.readOwners(named, client: client, discovery: discovery, namespace: binding.namespace, now: now)
            } ?? KubePanelGitOps.OwnersRead()
        notes += owners.problems

        // P3–P4: the rail's, when kept; else off production, at the agent's bounds.
        var listing = KubeGitOpsMatchCache.Listing()
        if let kept = gitOpsCache.listing(key) {
            listing = kept
            notes.append("The sources and what takes from them: as the rail read them in the last five minutes.")
        } else if !served {
            // Nothing to list.
        } else if context.isProduction {
            notes.append(
                "On \(context.name) only the owners of the bound workloads were read; press Find What Deploys This in the rail for more (it lists across the cluster).")
        } else {
            let argo = KubePanelGitOps.argoNamespaces(binding, cache: gitOpsCache)
            let read = try await within {
                await KubePanelGitOps.listing(
                    client: client, discovery: discovery, checkout: facts, namespace: binding.namespace, argo: argo, objects: gitOpsObjects, bytes: gitOpsBytes)
            }
            switch read {
            case .success(let found): listing = found
            case .failure(let error): notes.append("Couldn't look for what deploys this: \(said(error))")
            }
        }
        notes += listing.searched

        var objects = listing.objects
        objects.merge(owners.objects) { _, owner in owner }
        let owned = named.compactMap { owner, refs in owners.reads[owner].map { (owner: owner, workloads: refs, read: $0) } }
        let found = KubeGitOpsMatch.found(
            owned: owned, objects: objects, workloads: workloads.map { ($0.ref, $0.images) }, checkout: facts, context: context.name)
        var matches: [(found: KubeGitOpsMatch.Found, object: KubeGitOpsObject?)] = found.map { found in
            (found, objects[found.key].map { KubeGitOpsSummary.evaluated($0, now: now, peers: objects) })
        }
        matches = matches.filter { match in match.object.map { filter.includes($0.role) } ?? (filter == .all || filter.rawValue == match.found.key.kind.lowercased()) }
        if failing { matches = matches.filter { $0.object?.state.isProblem ?? false } }
        matches.sort { a, b in
            switch (a.object, b.object) {
            case let (x?, y?): return KubeGitOpsSummary.ordered(x, y)
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.found.key.description < b.found.key.description
            }
        }
        if matches.isEmpty {
            let searched = listing.searched.isEmpty ? "" : " (the search was cut: see below)"
            lines.append(
                workloads.isEmpty
                    ? "No workload in \(binding.namespace) is bound\(binding.selector.map { " (selector \($0))" } ?? ""), and nothing found takes from this checkout's repository\(searched)."
                    : "Nothing found\(failing ? " failing" : "") that deploys this checkout\(searched).")
        }
        var asked = 0
        for match in matches.prefix(limit) {
            guard let object = match.object else {
                lines.append("\(match.found.key)  \(match.found.whys.map(\.said).joined(separator: " · "))")
                continue
            }
            lines.append(KubeMCPGitOpsText.line(object, peers: objects, now: now))
            let why = ([match.found.whys.map(\.said).joined(separator: " · ")] + [match.found.tracks].compactMap { $0 }).joined(separator: "; ")
            lines.append("  matched: \(why)")
            guard asked < gitOpsReaches, let repository = match.found.whys.first(where: \.isRepository),
                let question = KubeGitOpsReach.question(object, why: repository, checkout: facts, peers: objects)
            else { continue }
            asked += 1
            let answer = KubeGitOpsReach.labeled(await KubeGitOpsReach.answer(question, in: root, git: gitOpsCheckouts.git), question)
            lines.append("  \(answer.deployed.text) (\(answer.source); as of the last fetch)")
            if let attempted = answer.attempted { lines.append("  \(attempted)") }
            if let fetched = answer.fetched { lines.append("  \(fetched)") }
        }
        if matches.count > limit { lines.append("… \(matches.count - limit) more not listed.") }
        lines += notes
        return KubeMCPText.finished(lines.joined(separator: "\n"))
    }
}

/// What `k8s_gitops` says of each object: one line, every message already
/// through 5.3 (the summaries'), never `status.resources` (a count), the
/// history, values, patches or a URL's userinfo. Pure.
enum KubeMCPGitOpsText {
    /// A line's longest.
    static let lineLimit = 1200

    /// `Kustomization flux-system/acme-cron  Failed  c03f9aa failed; applied main@a77b0d1  source acme/fleet ./apps/cron @main  into shop  last error: BuildFailed: …`
    static func line(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers, now: Date) -> String {
        var parts = ["\(object.kind) \(object.ref.description)", object.state.word]
        let tags = object.tags.map { $0.said(now: now) }
        if !tags.isEmpty { parts[1] += " (\(tags.joined(separator: ", ")))" }
        if let revision = revision(object), !revision.isEmpty { parts.append(revision) }
        let source = KubeGitOpsSection.source(object, peers: peers)
        if !source.isEmpty { parts.append("source \(source)") }
        if let remote = object.remote {
            parts.append("into another cluster, \(GitRemoteURL.withoutUserinfo(remote))")
        } else {
            let into = KubeGitOpsSection.into(object).replacingOccurrences(of: "→ ", with: "")
            if !into.isEmpty { parts.append("into \(into)") }
        }
        if let count = object.managedCount { parts.append("manages \(count)") }
        if object.state != .ready, !object.why.isEmpty { parts.append("why: \(object.why)") }
        if let error = object.lastError, !error.isEmpty, !object.why.contains(error) { parts.append("last error: \(error)") }
        // Each part on one line, two spaces between them (a message's own runs of spaces folded).
        let line = parts.map { KubeGitOpsMessage.oneLine($0, limit: lineLimit) }.joined(separator: "  ")
        guard line.count > lineLimit else { return line }
        return String(line.prefix(lineLimit - 1)) + "…"
    }

    /// Flux's failed attempt beside what is applied, else the Revision column's.
    static func revision(_ object: KubeGitOpsObject) -> String? {
        let applied = object.revisions.applied.first { !$0.isEmpty }
        if [.kustomization, .helmRelease].contains(object.role), let attempted = object.revisions.attempted, !attempted.isEmpty,
            object.state == .failed || object.state == .stuck, attempted != applied
        {
            let tried = KubeGitOpsRevision.shown(attempted)
            let kept = object.role == .helmRelease ? object.revisions.helmHistory?.chartVersion : applied.map(KubeGitOpsRevision.shown)
            return kept.map { "\(tried) failed; applied \($0)" } ?? "\(tried) failed; nothing applied"
        }
        let column = KubeGitOpsRevision.column(object)
        return column.isEmpty ? nil : column
    }

    /// "9 GitOps objects in or deploying into shop: 2 Failed, 1 Blocked, 6 Ready."
    static func counts(_ objects: [KubeGitOpsObject], filter: KubeMCP.GitOpsFilter, failing: Bool, scope: KubeScope) -> String {
        let what: String =
            switch filter {
            case .all: "GitOps objects"
            case .application: "Applications"
            case .applicationset: "ApplicationSets"
            case .kustomization: "Kustomizations"
            case .helmrelease: "HelmReleases"
            case .source: "Flux sources"
            }
        let place = scope == .all ? "in any namespace" : "in or deploying into \(scope.said)"
        let failingSaid = failing ? " failing" : ""
        guard !objects.isEmpty else { return "No\(failingSaid) \(what) \(place)." }
        let counts = KubeGitOpsSummary.counts(objects)
        let said = KubeGitOpsState.allCases.compactMap { state in counts[state].map { "\($0) \(state.word)" } }.joined(separator: ", ")
        return "\(objects.count)\(failingSaid) \(what) \(place), problems first: \(said)."
    }
}
