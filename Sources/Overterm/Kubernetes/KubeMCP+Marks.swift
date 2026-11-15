import Foundation

/// `k8s_gitops`' Argo CD apps read from the marks on their objects (docs/
/// design/kubernetes/gitops.md, 14.2.6, D6), where no Application here
/// deploys them — Argo CD's Applications not served (`notServed`: "another
/// cluster", said only then), argoproj.io not answering discovery
/// (`undiscovered`), refused everywhere (`forbidden`), served and listed
/// whole across the cluster with none (`noApplications`) —; with `kind:
/// "marks"`, beside Applications that are read too, the marked apps with
/// none here (only from a whole read).
///
/// **The section's store first**: the page's GitOps section's apps of the
/// same cluster and user (`KubernetesModel.markedApps(of:)`), ranked in the
/// last five minutes in a scope covering the call's, with the mode they
/// were derived in — used as they are, with their age, and nothing is read
/// for them. **Else the agent's own read, once**: the workloads' rows with
/// their marks (Deployments, StatefulSets, DaemonSets and, where served,
/// Argo Rollouts — read for their apps' health only), at most 2,000
/// objects or 16 MB a kind, refused across the cluster read in the
/// context's `accessibleNamespaces`, else the scope's; then a GET of at
/// most 20 that may be problems — not ready by their rows, an Argo
/// Rollout's phase —, the most recently changed by Argo CD first, 4 in
/// flight, 4 MB each and 16 MB in all (`KubeMarkedFetch`); every other
/// state from its row; where Argo Rollouts are served and weren't read
/// whole, an app a Rollout may run Unknown, never Ready. Made into apps
/// and ranked off the main thread. No watch, no list of whole objects, no
/// Secret or ConfigMap, nothing of Argo CD's or Flux's where it isn't
/// served, never a write.
///
/// One line an app, problems first, at most 100 — the rest counted by
/// state —; Ready ones only counted unless `kind: "marks"` with `state:
/// "all"`. A cut, refused or unread read says what was read, never "no
/// marked apps". Every count plain, whatever the person's locale writes
/// (`KubeCountedText`). Every word through `Secrets` (`KubeMCPText.finished`).
extension KubeMCP {
    /// An agent's read of the marks' rows: 2,000 objects or 16 MB a kind
    /// (a test's own).
    static var marksRows = KubeMarkedAppsSession.Bounds(rowsPage: 500, pageBytes: 16 << 20, rowsObjects: 2000, rowsBytes: 16 << 20, getBytes: 4 << 20)
    /// Then a GET of at most this many, 16 MB in all.
    nonisolated static let marksGets = 20
    nonisolated static let marksGetsBytes = 16 << 20
    /// At most this many apps' lines; the rest counted by state.
    nonisolated static let marksLines = 100

    /// The apps read from marks, as an agent is told them.
    struct MarkedAppsRead {
        var apps: [KubeMarkedRanked] = []
        var reading = KubeMarkedReading()
        var tally = KubeMarkedApps.Tally()
        var probable = false
        /// The section's mode, when its store answered.
        var mode: KubeMarkedAppsMode?
        /// When the section ranked them; nil: read for this answer.
        var section: Date?
        /// Read for this answer: how many objects a GET settled, and what
        /// it couldn't settle, said.
        var settled = 0
        var unsettled: [String] = []
    }

    /// `state`: whether Ready apps read from marks are listed too.
    static func marksState(_ call: Call) throws -> Bool {
        switch call.string("state")?.lowercased() {
        case nil, "problems": return false
        case "all": return true
        case let other?: throw BrowserMCP.ToolError(message: "“state” is problems or all, not “\(other)”.")
        }
    }

    /// The section's apps of the target's context when its store answers
    /// for the call's scope: same cluster and user, under five minutes old,
    /// its reads done, its mode deriving them; the apps in the scope.
    static func keptMarks(_ target: Target, kubernetes: KubernetesModel, now: Date) -> MarkedAppsRead? {
        guard let kept = kubernetes.markedApps(of: target.context, now: now), kept.mode != .off, !kept.reading.kinds.isEmpty, !kept.reading.isReading else { return nil }
        if let wanted = target.scope.names {
            if let held = kept.scope.names, !Set(held).isSuperset(of: wanted) { return nil }
        } else if kept.scope != .all {
            return nil
        }
        let apps = kept.apps.filter { inScope($0.app, target.scope) }
        return MarkedAppsRead(apps: apps, reading: kept.reading, tally: kept.tally, probable: kept.probable, mode: kept.mode, section: kept.at)
    }

    /// An app in or deploying into the scope: one of its namespaces in it.
    static func inScope(_ app: KubeMarkedApp, _ scope: KubeScope) -> Bool {
        guard scope != .all else { return true }
        return app.namespaces.contains { scope.includes($0) }
    }

    /// The agent's own read (above): the rows with their marks, then a GET
    /// of at most 20 that may be problems. The rows made into members and
    /// apps, those that may be problems picked and every app ranked off the
    /// main thread (14.4.6: 2,000 rows a kind, four kinds) — the main
    /// thread only waits for the reads.
    static func readMarks(_ target: Target, discovery: KubeDiscovery, now: Date) async -> MarkedAppsRead {
        let kinds = KubeMarkedAppsSession.kinds(discovery).workloads
        var reading = KubeMarkedReading()
        reading.kinds = kinds.map(KubeKindCatalog.title(of:))
        reading.rolloutsServed = kinds.contains { $0.fullName == KubeMarkedAppsSession.rollouts }
        reading.rereads = false
        let client = target.client
        let scope = target.scope
        let accessible = target.context.settings.accessibleNamespaces
        let bounds = marksRows
        var listed: [(kind: KubeMarkedKind, rows: KubeRows)] = []
        for kind in kinds {
            let title = KubeKindCatalog.title(of: kind)
            let places = scope.reads(for: kind)
            var read: KubeMarkedAppsSession.RowsRead
            do {
                read = try await within { await KubeMarkedAppsSession.readRows(kind, places: places, client: client, bounds: bounds) }
                if case .refusedAcross = read {
                    // Refused across the cluster: where it may be.
                    let fallback = accessible.isEmpty ? (scope.names ?? []) : accessible
                    if !fallback.isEmpty {
                        reading.fallback[title] = fallback
                        read = try await within { await KubeMarkedAppsSession.readRows(kind, places: fallback, client: client, bounds: bounds) }
                    }
                }
            } catch {
                reading.failed[title] = said(error)
                continue
            }
            switch read {
            case .read(let rows, let refused, let cut, _):
                reading.listed.insert(title)
                if !refused.isEmpty { reading.refused[title] = refused }
                if cut { reading.rowCuts[title] = "\(title): the list stopped at \(count: rows.count); the rest not read" }
                listed.append((KubeMarkedKind(kind), rows))
            case .refusedAcross:
                reading.refused[title] = [KubeMarkedReading.acrossTheCluster]
            case .failed(let error):
                reading.failed[title] = said(error)
            }
        }
        let rows = listed
        let made = await KubeBlocking.run { marksMade(rows, scope: scope, now: now) }
        var paths: [(id: KubeMarkedMember.ID, path: String)] = []
        for member in made.candidates.prefix(marksGets) {
            guard let kind = kinds.first(where: { KubeMarkedKind($0) == member.id.kind }) else { continue }
            paths.append((member.id, kind.path(namespace: member.id.namespace, name: member.id.name)))
        }
        let fetched = await KubeMarkedFetch.objects(paths, client: client, maxBytes: bounds.getBytes, totalBytes: marksGetsBytes, timeout: readTimeout)
        var wires: [KubeMarkedMember.ID: KubeMarkedWorkloadWire] = [:]
        var failed = 0
        for answer in fetched.answers {
            guard case .success(var wire) = answer.result, let kind = kinds.first(where: { KubeMarkedKind($0) == answer.id.kind }) else {
                failed += 1
                continue
            }
            if wire.kind == nil { wire.kind = kind.kind }
            if wire.apiVersion == nil { wire.apiVersion = kind.groupVersion }
            wires[answer.id] = wire
        }
        // Argo Rollouts served and not read whole: a Deployment scaled to 0 with no Rollout of its app read is Unknown, never Ready.
        let rollouts = marksRollouts(reading, title: kinds.first { $0.fullName == KubeMarkedAppsSession.rollouts }.map(KubeKindCatalog.title(of:)), scope: scope)
        let apps = made.apps
        let candidates = made.candidates
        let settled = wires
        let ranked = await KubeBlocking.run { marksRanked(apps, candidates: candidates, wires: settled, rollouts: rollouts) }
        // What a GET didn't settle, said: never as if it had — those not asked, and those whose GET failed.
        let answered = Set(fetched.answers.map(\.id))
        let left = candidates.filter { !answered.contains($0.id) }
        var unsettled: [String] = []
        let rolloutsLeft = left.count { $0.id.kind == .rollout }
        let workloads = left.count - rolloutsLeft
        let why = candidates.count > marksGets || !fetched.skipped.isEmpty ? " (an agent reads \(marksGets) objects at most)" : ""
        if rolloutsLeft > 0 {
            let phases = rolloutsLeft == 1 ? "1 Argo Rollout's phase" : "\(rolloutsLeft) Argo Rollouts' phases"
            unsettled.append("\(phases) not read\(why): \(rolloutsLeft == 1 ? "its app says" : "their apps say") Unknown")
        }
        if workloads > 0 { unsettled.append("\(KubeMCPMarksText.counted(workloads, "workload")) not ready by \(workloads == 1 ? "its row" : "their rows") not settled by Argo CD's rule\(why)") }
        if failed > 0 { unsettled.append("\(KubeMCPMarksText.counted(failed, "object")) couldn't be read: from \(failed == 1 ? "its row" : "their rows")") }
        return MarkedAppsRead(
            apps: ranked.apps, reading: reading, tally: ranked.tally, probable: ranked.probable, mode: nil, section: nil, settled: wires.count, unsettled: unsettled)
    }

    /// The rows made into members in the scope and grouped into apps, and
    /// what may be a problem among them — not ready by its row, an Argo
    /// Rollout's phase —, the most recently changed by Argo CD first. Off
    /// the main thread.
    nonisolated static func marksMade(
        _ listed: [(kind: KubeMarkedKind, rows: KubeRows)], scope: KubeScope, now: Date
    ) -> (apps: KubeMarkedApps, candidates: [KubeMarkedMember]) {
        var members: [KubeMarkedMember] = []
        for (kind, rows) in listed {
            for row in rows.sorted where scope.includes(row.id.namespace) {
                if let member = KubeMarkedMember.row(row, kind: kind, columns: rows.columns, now: now) { members.append(member) }
            }
        }
        let apps = KubeMarkedApps.group(members)
        var candidates: [KubeMarkedMember] = []
        for app in apps.apps {
            for member in app.members where member.id.kind.cellsMayHide && member.marks.hasArgoMark {
                guard let verdict = KubeMarkedHealth.member(member, in: app), verdict.status != .healthy else { continue }
                candidates.append(member)
            }
        }
        candidates.sort { a, b in
            let first = a.marks.argoChanged ?? a.created ?? .distantPast
            let second = b.marks.argoChanged ?? b.created ?? .distantPast
            return first != second ? first > second : a.id < b.id
        }
        return (apps, candidates)
    }

    /// The apps with what the GETs settled, each ranked — where Argo
    /// Rollouts weren't read whole, a Deployment scaled to 0 with no
    /// Rollout of its app read Unknown (`KubeGitOpsMatch.health`). Off the
    /// main thread.
    nonisolated static func marksRanked(
        _ apps: KubeMarkedApps, candidates: [KubeMarkedMember], wires: [KubeMarkedMember.ID: KubeMarkedWorkloadWire], rollouts: KubeGitOpsMatch.RolloutsRead
    ) -> (apps: [KubeMarkedRanked], tally: KubeMarkedApps.Tally, probable: Bool) {
        var apps = apps
        let settled = candidates.compactMap { member in wires[member.id].map { member.settled(by: $0) } }
        if !settled.isEmpty { apps.merge(changed: settled, removed: []) }
        let ranked = apps.apps.map { KubeMarkedRanked(app: $0, health: KubeGitOpsMatch.health($0, rollouts: rollouts)) }.sorted(by: KubeMarkedBook.ordered)
        return (ranked, apps.tally, apps.isProbable)
    }

    /// Whether Argo Rollouts were read whole where the call reads (14.12's
    /// second consequence: a Deployment scaled to 0 may be the one a
    /// Rollout runs by `workloadRef`): not served; read — listed, none
    /// refused or cut, refused across the cluster only where read in every
    /// one of the scope's namespaces —; or not, and why. `title`: the
    /// Rollouts' title among the reading's kinds, nil where not served.
    nonisolated static func marksRollouts(_ reading: KubeMarkedReading, title: String?, scope: KubeScope) -> KubeGitOpsMatch.RolloutsRead {
        guard let title else { return .notServed }
        if let why = reading.failed[title] { return .unread("Argo Rollouts couldn't be read: \(why)") }
        guard reading.listed.contains(title) else {
            return .unread(reading.refused[title] != nil ? "Argo Rollouts can't be read here (forbidden)" : "Argo Rollouts not read")
        }
        let covered = reading.fallback[title].map { places in scope.names.map { Set(places).isSuperset(of: $0) } ?? false } ?? true
        if reading.refused[title] != nil || reading.rowCuts[title] != nil || !covered { return .unread("Argo Rollouts read in part") }
        return .read
    }

    /// The marks' part of a `k8s_gitops` answer (above), and a word for the
    /// end of it: beside Applications read, how to ask for the marked apps
    /// with none here. `applications`: what the call's read of Argo CD's
    /// Applications said (`.notYetListed`: not read, or cut — `unlisted`
    /// saying which: "couldn't be read — …", "were cut at …"). Every count
    /// plain, whatever the person's locale writes.
    static func gitOpsMarks(
        filter: GitOpsFilter, _ target: Target, discovery: KubeDiscovery, applications: KubeMarkedAppsMode.ApplicationsRead, unlisted: String? = nil,
        kept: MarkedAppsRead?, kubernetes: KubernetesModel, failing: Bool, every: Bool, limit: Int, now: Date
    ) async -> (lines: [String], hint: String?) {
        let context = target.context.name
        var read: MarkedAppsRead
        let mode: KubeMarkedAppsMode
        if let kept, let keptMode = kept.mode {
            if case .beside(let coexistence) = keptMode, filter != .marks {
                // Applications are read here: kind marks lists those with none.
                let count = coexistence.listed.count
                let chip = "\(KubeMCPMarksText.counted(count, "marked app")) with no Application here"
                return ([], count == 0 ? nil : "\(chip) (as the GitOps section read them): kind marks lists them.")
            }
            read = kept
            mode = keptMode
        } else {
            if case .only = KubeMarkedAppsMode.of(discovery: discovery, applications: applications, marked: []) {
                // No Application here deploys them: read.
            } else {
                // Applications are read here.
                guard filter == .marks else {
                    let hint = kubernetes.marksSeen.contains(context) ? "Objects here carry Argo CD's marks too: kind marks lists the apps among them with no Application here." : nil
                    return ([], hint)
                }
                guard applications != .notYetListed else {
                    // Said by its cause: a list cut at the agent's bound, or one that couldn't be read — never one for the other.
                    let why = unlisted ?? "weren't all read"
                    return (
                        [
                            "Argo CD's Applications are served here and \(why): which marked apps have none here can't be told. The GitOps section on the Kubernetes page says it (it reads every Application's name)."
                        ], nil
                    )
                }
            }
            read = await readMarks(target, discovery: discovery, now: now)
            mode = KubeMarkedAppsMode.of(discovery: discovery, applications: applications, marked: Set(read.apps.map(\.app.key)), probable: read.probable)
        }
        let unread = read.reading.unread(plain: true)
        var lines: [String] = []
        var apps = read.apps
        var beside: [KubeTrackingID.AppKey: KubeMarkedSection.Beside] = [:]
        var unknown = 0
        switch mode {
        case .off:
            lines.append(KubeMCPMarksText.source(read, kinds: read.reading.kinds, rows: marksRows, now: now))
            if apps.isEmpty {
                lines.append(
                    read.reading.isWhole
                        ? "Argo CD's Applications are read here (k8s_gitops lists them), and \(read.reading.carriers(scope: target.scope))"
                        : "No Argo CD marks found in what could be read: \(unread.joined(separator: "; ")).")
            } else if read.probable {
                // Grouped by app.kubernetes.io/instance alone: never compared with the Applications listed — never listed, never said to lack one (14.3).
                let these = apps.count == 1 ? "the 1 app grouped by app.kubernetes.io/instance is" : "the \(apps.count) apps grouped by app.kubernetes.io/instance are"
                lines.append(
                    "No object read carries Argo CD's tracking id or its instance label: \(these) only probably Argo CD's — a label Helm and kustomize set too —, so beside the Applications read here none is listed, nor said to lack one."
                )
            } else {
                // Every marked app's name is among the Applications listed (`KubeMarkedAppsMode.beside` found none without).
                lines.append("Every marked app read here (\(KubeMCPMarksText.counted(apps.count, "app"))) has an Application of its name here: k8s_gitops lists them.")
            }
            return (lines, nil)
        case .beside(let coexistence):
            var whole = false
            if read.section == nil, case .acrossCluster = applications { whole = true }
            apps = apps.filter { coexistence.listed.contains($0.app.key) }
            for app in apps {
                if let same = coexistence.maybe[app.app.key] {
                    beside[app.app.key] = .maybe(same)
                } else if coexistence.otherInstallation.contains(app.app.key) {
                    beside[app.app.key] = .otherInstallation(app.app.key.installation)
                } else {
                    beside[app.app.key] = .missing(whole: whole)
                }
            }
            unknown = coexistence.unknown.count
        case .only:
            break
        }
        let total = apps
        if failing { apps = apps.filter { $0.health.state.isProblem } }
        guard !total.isEmpty else {
            // None: what was read, in the mode's words — never "carries no marks" from a read that wasn't whole.
            if case .only(let reason) = mode {
                lines.append(KubeMarkedSection.empty(reason, context: context, scope: target.scope, reading: read.reading, plain: true))
            } else {
                lines.append(
                    unknown > 0
                        ? "No marked app is said to lack its Application here: each has one of its name, or its Application's namespace couldn't be read."
                        : "Every marked app read has an Application of its name here.")
            }
            lines.append(KubeMCPMarksText.source(read, kinds: read.reading.kinds, rows: marksRows, now: now))
            lines += KubeMCPMarksText.notes(read, counted: false)
            if unknown > 0 { lines.append("\(KubeMCPMarksText.counted(unknown, "marked app")) whose Application's namespace couldn't be read: not listed.") }
            return (lines, nil)
        }
        lines.append(KubeMCPMarksText.opening(mode, context: context, probable: read.probable))
        lines.append(KubeMCPMarksText.health)
        lines.append(KubeMCPMarksText.source(read, kinds: read.reading.kinds, rows: marksRows, now: now))
        let whole = read.reading.isWhole
        lines.append(KubeMCPMarksText.counts(apps, whole: whole, unread: unread, scope: target.scope, failing: failing))
        // Ready ones counted, listed only when kind marks asks every state.
        let listed = every && filter == .marks ? apps : apps.filter { $0.health.state != .ready }
        let cap = min(limit, marksLines)
        lines += listed.prefix(cap).map { KubeMCPMarksText.line($0, beside: beside[$0.app.key], now: now) }
        if listed.count > cap {
            let rest = listed.dropFirst(cap)
            let byState = KubeGitOpsState.allCases.compactMap { state -> String? in
                let count = rest.count { $0.health.state == state }
                return count > 0 ? "\(count) \(state.word)" : nil
            }
            lines.append("… \(rest.count) more not listed (\(byState.joined(separator: ", "))): narrow it with a namespace or failing_only.")
        }
        let ready = apps.count { $0.health.state == .ready }
        if ready > 0, listed.count != apps.count {
            lines.append("\(KubeMCPMarksText.counted(ready, "Ready app")) counted, not listed: kind marks with state all lists them.")
        }
        lines += KubeMCPMarksText.notes(read, counted: !whole)
        if let installations = KubeMCPMarksText.installations(total.map(\.app)) { lines.append(installations) }
        if unknown > 0 { lines.append("\(KubeMCPMarksText.counted(unknown, "marked app")) whose Application's namespace couldn't be read: not listed.") }
        return (lines, nil)
    }

    // MARK: checkout: true (14.2.5, 14.2.6)

    /// What deploys the checkout among Argo CD's apps read from marks, as
    /// the rail says it (`KubePanelGitOps`): its matches with their health,
    /// whose it is and where their Application stands; what B, C and D
    /// said; the owners whose "not in" lines they replace.
    struct CheckoutMarks {
        struct Match {
            var entry: KubeGitOpsMatch.MarkedFound
            var health: KubeMarkedHealth.AppVerdict
            var scope: KubeGitOpsMatch.MarkedScope
            var place: KubeGitOpsMatch.MarkedPlace
        }

        /// Why it reads from marks across the cluster: the rail's line.
        var line: String?
        var found: [Match] = []
        var probably: [Match] = []
        var tooMany: String?
        /// Those by name or image outside the binding's namespace, beside those in it: counted.
        var elsewhere: String?
        var nothing: String?
        var caveats: [String] = []
        var notes: [String] = []
        /// The Argo CD owners an app read from marks says now: their "not in" lines go.
        var replaced: Set<KubeGitOpsObject.Key> = []
        var derivedOwners: Set<KubeGitOpsOwner> = []
    }


    /// The rail's marks part for an agent (14.2.5), once: **B**, the
    /// checkout's committed manifests against the cluster's marked
    /// workloads — as the rail compared them in the last five minutes
    /// (`KubeGitOpsMatchCache`, on production only that: a person's press's),
    /// its reason with it; else off production at the agent's bounds —
    /// where Applications are served and none is held here, one row of them
    /// asked first (`markedListing`'s), as the rail asks it: none, and the
    /// reason is "none here" —; **A**, the bound workloads
    /// whose own Argo CD mark names an app whose Application isn't read
    /// present here — each settled by one GET within what the owners' GETs
    /// left of the read's 8, the bound apps' Argo Rollouts first (the
    /// binding namespace's Rollouts listed once where a bound Deployment is
    /// scaled to 0); **C** and **D** "probably", the binding namespace's
    /// first and those elsewhere counted. An app the section ranked in the
    /// last five minutes is said with its verdict. Its counts plain.
    static func gitOpsCheckoutMarks(
        _ workloads: [KubePanelGitOps.Bound], owners: KubePanelGitOps.OwnersRead, held: Bool, binding: KubeBinding, context: KubeContext, client: KubeClient,
        discovery: KubeDiscovery, facts: KubeGitOpsMatch.Checkout, key: KubeGitOpsMatchCache.Key, kubernetes: KubernetesModel, now: Date
    ) async -> CheckoutMarks {
        var out = CheckoutMarks()
        var reason = KubePanelGitOps.marksReason(discovery, said: kubernetes.marksReason(of: context, now: now))
        // Applications held among what was read here: what deploys the checkout is theirs to say.
        if reason == .noApplications || reason == .forbidden, held { reason = nil }
        let section = kubernetes.markedApps(of: context, now: now)
        // B, C and D: the rail's comparison when kept, its reason too where no section said one (the
        // rail's `listedReason`); else off production, at the agent's bounds — where Applications are
        // served and none is held, one row of them asked first, as the rail does. On production only
        // a person's press's, kept (14.2.6). Something here must carry a mark (the rail's
        // `marksEvidence`): else B lists nothing.
        var listing: KubeGitOpsMatch.MarkedListing?
        let served = KubePanelGitOps.kind(of: "Application", in: discovery) != nil
        let evidence =
            workloads.contains { $0.member?.marks.hasArgoMark == true } || kubernetes.marksSeen.contains(context.name) || section != nil
        if let kept = gitOpsCache.marked(key) {
            listing = kept
            if reason == nil, !held { reason = kept.reason }
            out.notes.append("The cluster's marked apps against this checkout's manifests: as the rail compared them in the last five minutes.")
        } else if evidence, reason != nil || (served && !held) {
            if context.isProduction {
                out.notes.append(
                    "On \(context.name) the cluster's marked workloads are compared with this checkout's manifests only once Find What Deploys This is pressed in the rail (it lists across the cluster)."
                )
            } else {
                let fromSection: (apps: [KubeMarkedApp], at: Date)? =
                    section.flatMap { $0.scope == .all && $0.whole ? ($0.apps.map(\.app), $0.at) : nil }
                let accessible = context.settings.accessibleNamespaces
                let git = gitOpsCheckouts.git
                let namespace = binding.namespace
                let known = reason
                // An agent's B: every kind's rows together within the agent's bound.
                let bounds = marksRows
                do {
                    let read = try await within {
                        await KubePanelGitOps.markedListing(
                            client: client, discovery: discovery, checkout: facts, namespace: namespace, reason: known, accessible: accessible, section: fromSection,
                            git: git, bounds: bounds)
                    }
                    switch read {
                    case .success(let found?):
                        listing = found
                        reason = found.reason
                    case .success(nil):
                        // Applications are listed here: what deploys the checkout is theirs to say.
                        break
                    case .failure(let error):
                        out.notes.append("Couldn't compare the workloads' marks with this checkout: \(said(error))")
                    }
                } catch {
                    out.notes.append("Couldn't compare the workloads' marks with this checkout: \(said(error))")
                }
            }
        }
        // A: the bound workloads whose own mark names an app whose Application isn't read present here.
        var bound: [(member: KubeMarkedMember, ref: KubeWorkloadRef, owner: KubeGitOpsOwner?)] = []
        for workload in workloads {
            guard let member = workload.member, member.marks.hasArgoMark, case .app = KubeMarkedApps.place(member.marks) else { continue }
            let owner = workload.owners.first { $0.tool == .argoCD && $0.isCertain }
            if let owner {
                guard let read = owners.reads[owner], read != .present else { continue }
            } else if reason == nil {
                continue
            }
            bound.append((member, workload.ref, owner))
        }
        let ranked = Set((section?.apps ?? []).map(\.app.key))
        let boundKeys = Set(
            bound.compactMap { entry -> KubeTrackingID.AppKey? in
                if case .app(let key) = KubeMarkedApps.place(entry.member.marks) { key } else { nil }
            })
        // A bound Deployment scaled to 0 where Argo Rollouts are served: the namespace's Rollouts, once.
        var rollouts: [KubeMarkedMember] = []
        var rolloutsRead = KubeGitOpsMatch.RolloutsRead.notServed
        let rolloutKind = KubePanelGitOps.rolloutKind(discovery)
        if let rolloutKind, bound.contains(where: { $0.member.id.kind == .deployment && $0.member.health?.scaledToZero == true }) {
            let namespace = binding.namespace
            let read = (try? await within { await KubeMarkedAppsSession.readRows(rolloutKind, places: [namespace], client: client, bounds: KubePanelGitOps.rolloutRows) })
            switch read {
            case .read(let rows, let refused, let cut, _)?:
                rollouts = rows.sorted.compactMap { KubeMarkedMember.row($0, kind: .rollout, columns: rows.columns, now: now) }
                rolloutsRead = !refused.isEmpty ? .unread("\(namespace)'s Rollouts can't be read (forbidden)") : cut ? .unread("\(namespace)'s Rollouts read in part") : .read
            case .refusedAcross?:
                rolloutsRead = .unread("\(namespace)'s Rollouts can't be read (forbidden)")
            case .failed?, nil:
                rolloutsRead = .unread("\(namespace)'s Rollouts couldn't be read")
            }
        }
        let theirRollouts = rollouts.filter { rollout in
            if case .app(let key) = KubeMarkedApps.place(rollout.marks) { boundKeys.contains(key) } else { false }
        }
        // Each one's GET within what the owners' GETs left of the read's 8: their Rollouts first — none
        // for an app the section ranked, whose verdict is said.
        var wanted: [(id: KubeMarkedMember.ID, kind: KubeResourceKind)] = []
        let runByRollout = Set(
            theirRollouts.compactMap { rollout -> KubeTrackingID.AppKey? in
                if case .app(let key) = KubeMarkedApps.place(rollout.marks) { key } else { nil }
            })
        if let rolloutKind {
            for rollout in theirRollouts {
                guard case .app(let key) = KubeMarkedApps.place(rollout.marks), !ranked.contains(key) else { continue }
                wanted.append((rollout.id, rolloutKind))
            }
        }
        for entry in bound where entry.member.id.kind.cellsMayHide {
            guard case .app(let key) = KubeMarkedApps.place(entry.member.marks), !ranked.contains(key) else { continue }
            // A Deployment its Rollout scales to 0: the Rollout's GET says its app's health, its own can't.
            if rolloutKind != nil, entry.member.id.kind == .deployment, entry.member.health?.scaledToZero == true, rolloutsRead != .read || runByRollout.contains(key) {
                continue
            }
            wanted.append((entry.member.id, entry.ref.kind.kind))
        }
        let room = max(0, KubePanelGitOps.ownerReads - owners.spent)
        let paths = wanted.prefix(room).map { (id: $0.id, path: $0.kind.path(namespace: $0.id.namespace, name: $0.id.name)) }
        let fetched = await KubeMarkedFetch.objects(paths, client: client, maxBytes: KubePanelGitOps.getBytes, timeout: readTimeout)
        var wires: [KubeMarkedMember.ID: KubeMarkedWorkloadWire] = [:]
        for answer in fetched.answers {
            guard case .success(var wire) = answer.result, let kind = wanted.first(where: { $0.id == answer.id })?.kind else { continue }
            if wire.kind == nil { wire.kind = kind.kind }
            if wire.apiVersion == nil { wire.apiVersion = kind.groupVersion }
            wires[answer.id] = wire
        }
        let past = Set(wanted.dropFirst(room).map(\.id))
        func settled(_ member: KubeMarkedMember) -> KubeMarkedMember {
            if let wire = wires[member.id] { return member.settled(by: wire) }
            guard member.id.kind == .rollout else { return member }
            var unread = member
            unread.health = KubeMarkedHealth.Verdict(
                status: .unknown,
                sentence: past.contains(member.id) ? "its phase not read: the rail reads \(KubePanelGitOps.ownerReads) objects at most" : "its phase couldn't be read")
            return unread
        }
        let apps = KubeMarkedApps.group(bound.map { settled($0.member) } + theirRollouts.map(settled)).apps
        var boundApps: [(app: KubeMarkedApp, workloads: [KubeWorkloadRef])] = []
        var ownerOf: [KubeTrackingID.AppKey: KubeGitOpsOwner] = [:]
        for app in apps {
            let ids = Set(app.members.map(\.id))
            let mine = bound.filter { ids.contains($0.member.id) }
            boundApps.append((app, mine.map(\.ref)))
            if let owner = mine.compactMap(\.owner).first { ownerOf[app.key] = owner }
        }

        let answered = KubeGitOpsMatch.marked(bound: boundApps, listing: listing, plain: true)
        func place(_ key: KubeTrackingID.AppKey) -> KubeGitOpsMatch.MarkedPlace {
            if let reason { return .reason(reason) }
            guard let owner = ownerOf[key] else { return .unread }
            if owners.undiscovered.contains(owner) { return .reason(.undiscovered) }
            if owners.refused.contains(owner) { return .refused }
            if owners.unplaced.contains(owner) { return .notFound }
            return owners.reads[owner] == .absent ? .absent : .unread
        }
        func match(_ entry: KubeGitOpsMatch.MarkedFound) -> CheckoutMarks.Match {
            let app = entry.app
            if let section, let ranked = section.apps.first(where: { $0.app.key == app.key }) {
                return CheckoutMarks.Match(entry: entry, health: ranked.health, scope: .section(section.at), place: place(app.key))
            }
            if entry.bound {
                let count = app.members.count { $0.id.kind == .rollout }
                var elsewhere: [String: Int]?
                if let listed = listing?.members[app.key] {
                    let mine = Set(app.members.map(\.id))
                    var counts: [String: Int] = [:]
                    for id in listed where !mine.contains(id) { counts[id.namespace ?? "the cluster", default: 0] += 1 }
                    elsewhere = counts
                }
                return CheckoutMarks.Match(
                    entry: entry, health: KubeGitOpsMatch.health(app, rollouts: rolloutsRead),
                    scope: .bound(app.members.count - count, rollouts: count, elsewhere: elsewhere, whole: listing?.whole ?? true), place: place(app.key))
            }
            return CheckoutMarks.Match(
                entry: entry, health: KubeGitOpsMatch.health(app, rollouts: listing?.rollouts ?? .notServed), scope: .listed(app.members.count), place: place(app.key))
        }
        out.found = answered.found.map(match)
        out.probably = answered.probably.map(match)
        out.tooMany = answered.tooMany
        out.elsewhere = answered.elsewhere
        out.nothing = answered.nothing
        out.caveats = answered.caveats
        out.replaced = Set(ownerOf.values.map { KubeGitOpsMatch.key(of: $0) })
        out.derivedOwners = Set(ownerOf.values)
        if let reason, !out.found.isEmpty || !out.probably.isEmpty || out.nothing != nil || out.tooMany != nil {
            let fromBound = out.found.contains { $0.entry.bound }
            out.line = KubeGitOpsMatch.marksLine(reason, context: context.name, namespace: fromBound ? binding.namespace : nil)
        }
        return out
    }

    /// Where neither Argo CD's Applications nor Flux is served, what is
    /// said of Flux beside the marks.
    static func fluxUnserved(_ discovery: KubeDiscovery, context: String) -> String? {
        let mode = KubePanelGitOps.mode(of: discovery)
        if mode.contains("flux=served") { return nil }
        if mode.contains("flux=undiscovered") { return "Whether \(context) serves Flux can't be told: Flux's groups didn't answer discovery." }
        return "\(context) serves no Flux kind."
    }

    /// Where Argo CD's Applications are asked for and aren't here: the apps read from marks.
    static let marksHint = "Argo CD's apps read from the marks on their objects: kind marks lists them."
}

/// What `k8s_gitops` says of the apps read from marks (gitops.md 14.2.6):
/// why they are, in the mode's words — "another cluster" only for
/// `notServed`, nothing of where Argo CD runs for apps only probably its —;
/// what health is; where they were read; the count, a floor unless the
/// read was whole; one line each. Pure.
enum KubeMCPMarksText {
    /// A line's longest.
    static let lineLimit = 1200

    /// `1 app`, `1024 apps`: an agent's numbers are plain, whatever the
    /// person's locale writes (`2.000` is two in English).
    static func counted(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    /// `2 Argo CD installations mark objects here: hub-eu (812 apps), unnamed (82 apps).`; nil for one.
    static func installations(_ apps: [KubeMarkedApp]) -> String? {
        let all = KubeMarkedSection.installations(apps)
        guard all.count > 1 else { return nil }
        let each = all.map { "\($0.installation.isEmpty ? "unnamed" : $0.installation) (\(counted($0.apps, "app")))" }
        return "\(all.count) Argo CD installations mark objects here: \(each.joined(separator: ", "))."
    }

    /// After the context's line: why the apps are read from marks.
    static func opening(_ mode: KubeMarkedAppsMode, context: String, probable: Bool) -> String {
        let tail = "apps read from the marks on their objects; no sync status, repository or revision."
        if probable {
            return
                "No object read carries Argo CD's tracking id or its instance label: these apps are only probably Argo CD's, grouped by app.kubernetes.io/instance — a label Helm and kustomize set too; no sync status, repository or revision."
        }
        switch mode {
        case .only(.notServed): return "Argo CD runs in another cluster (not in the kubeconfig); " + tail
        case .only(.noApplications): return "Argo CD's Applications for these aren't in this cluster (none is listed here); " + tail
        case .only(.undiscovered): return "Couldn't tell whether Argo CD runs in \(context) (argoproj.io didn't answer discovery); " + tail
        case .only(.forbidden): return "Argo CD's Applications can't be read in \(context) (forbidden); " + tail
        case .beside, .off: return "Argo CD's Applications are read here; these marked apps have none of their name here — " + tail
        }
    }

    static let health =
        "Health is Argo CD's built-in rules applied to what is here (custom health checks configured in Argo CD aren't known): Failed is its Degraded, Paused its Suspended, Ready its Healthy; an app none of whose workloads was read is Unknown, never Ready."

    /// Where the apps were read: the section's store, or this answer's own read.
    static func source(_ read: KubeMCP.MarkedAppsRead, kinds: [String], rows: KubeMarkedAppsSession.Bounds, now: Date) -> String {
        if let at = read.section {
            let age = now.timeIntervalSince(at)
            return "As the GitOps section on the Kubernetes page read them \(age < 60 ? "just now" : "\(KubeAge.format(age)) ago"): nothing read for this answer."
        }
        let what = kinds.isEmpty ? "the workloads" : KubeMarkedReading.joined(kinds)
        return
            "Read for this answer: the marks on \(what) as rows (\(rows.rowsObjects) objects or \(rows.rowsBytes >> 20) MB a kind at most), then \(KubeMCPMarksText.counted(read.settled, "object")) settled by Argo CD's rule, a GET each (\(KubeMCP.marksGets) at most: those not ready by their rows and Argo Rollouts' phases, the most recently changed first); every other state is from its row. Services, Ingresses, claims, CronJobs, Jobs and HPAs aren't read for an agent: their health isn't in these apps', and an app made only of them isn't listed — the GitOps section on the Kubernetes page reads them."
    }

    /// "12 apps read from marks in any namespace, problems first: 4 Failed, …"
    /// — "At least" with what couldn't be read when the read wasn't whole.
    static func counts(_ apps: [KubeMarkedRanked], whole: Bool, unread: [String], scope: KubeScope, failing: Bool) -> String {
        let place = scope == .all ? "in any namespace" : "in or deploying into \(scope.said)"
        let said = KubeGitOpsState.allCases.compactMap { state -> String? in
            let these = apps.filter { $0.health.state == state }
            guard !these.isEmpty else { return nil }
            let fromRows = state == .ready ? these.count { $0.health.fromRows } : 0
            return "\(these.count) \(state.word)" + (fromRows > 0 ? " (\(fromRows) from rows only)" : "")
        }.joined(separator: ", ")
        let counted = KubeMCPMarksText.counted(apps.count, failing ? "failing app" : "app")
        let what = whole ? counted : "At least \(counted)"
        let read = whole || unread.isEmpty ? "" : ", from what could be read (\(unread.joined(separator: "; ")))"
        guard !apps.isEmpty else { return "No\(failing ? " failing" : "") app read from marks \(place)\(read)." }
        return "\(what) read from marks \(place)\(read), problems first: \(said)."
    }

    /// `marks  Failed  payments/checkout-api  ns=payments  2 Deploy 1 Svc  rollout stalled (ProgressDeadlineExceeded): Deployment checkout-api  image=…/checkout-api:4.12.0`
    static func line(_ ranked: KubeMarkedRanked, beside: KubeMarkedSection.Beside? = nil, now: Date) -> String {
        let app = ranked.app
        let health = ranked.health
        var word = health.state.word
        if health.status == .unknown, health.state != .unknown { word = "Unknown (ranked \(health.state.word))" }
        if health.fromRows { word += " (from rows)" }
        var parts = ["marks", word, app.said]
        let namespaces = app.namespaces
        if !namespaces.isEmpty { parts.append("ns=" + namespaces.prefix(5).joined(separator: ",") + (namespaces.count > 5 ? " +\(namespaces.count - 5)" : "")) }
        let counts = app.counts.map { "\($0.count) \($0.kind.short)" }.joined(separator: " ")
        if !counts.isEmpty { parts.append(counts) }
        if health.causes.isEmpty {
            parts.append(health.why)
        } else {
            var causes = health.causes.map { "\($0.sentence): \($0.said)" }.joined(separator: "; ")
            if health.more > 0 { causes += "; and \(health.more) more" }
            parts.append(causes)
        }
        if health.state != .ready, let since = health.since { parts.append("for \(KubeAge.format(max(0, now.timeIntervalSince(since))))") }
        if !app.images.isEmpty { parts.append("image=\(KubeMarkedSection.source(app.images))") }
        var tags: [String] = []
        var saysInstallation = false
        if let beside {
            tags.append(beside.tag)
            if case .otherInstallation = beside { saysInstallation = true }
        }
        if let installation = app.installation, !saysInstallation { tags.append("installation \(installation)") }
        switch app.mark {
        case .appInstance: tags.append("probably: app.kubernetes.io/instance")
        case .argoInstance: tags.append("label only")
        default: if app.labelOnly > 0 { tags.append("\(app.labelOnly) label only") }
        }
        if !app.hooks.isEmpty { tags.append("\(KubeMCPMarksText.counted(app.hooks.count, "hook")) not counted") }
        if !tags.isEmpty { parts.append("(" + tags.joined(separator: ", ") + ")") }
        let line = parts.map { KubeGitOpsMessage.oneLine($0, limit: lineLimit) }.joined(separator: "  ")
        guard line.count > lineLimit else { return line }
        return String(line.prefix(lineLimit - 1)) + "…"
    }

    /// The checkout's matches among the apps read from marks (14.2.5): each
    /// with its state and sentence, why it matched — B "describes N of its
    /// objects", never that it deploys the checkout —, whose health, where
    /// its Application stands; apart, "probably (by name)" — the binding
    /// namespace's, those elsewhere counted —; what B couldn't compare.
    /// Problems only with `failing`.
    static func checkout(_ marked: KubeMCP.CheckoutMarks, failing: Bool, limit: Int, context: String, now: Date) -> [String] {
        let found = failing ? marked.found.filter { $0.health.state.isProblem } : marked.found
        let probably = failing ? marked.probably.filter { $0.health.state.isProblem } : marked.probably
        var lines: [String] = []
        if let line = marked.line { lines.append(line + ".") }
        func said(_ match: KubeMCP.CheckoutMarks.Match) -> [String] {
            [
                Self.line(KubeMarkedRanked(app: match.entry.app, health: match.health), now: now),
                "  matched: " + match.entry.whys.map(\.said).joined(separator: " · "),
                "  " + match.scope.said(now: now),
                "  " + match.place.said(context: context),
            ]
        }
        for match in found.prefix(limit) { lines += said(match) }
        if found.count > limit { lines.append("… \(found.count - limit) more apps read from marks not listed.") }
        if !probably.isEmpty {
            lines.append("May deploy this checkout, probably (by name or image) — never said found:")
            for match in probably.prefix(limit) { lines += said(match) }
        }
        if let tooMany = marked.tooMany { lines.append(tooMany + ".") }
        if let elsewhere = marked.elsewhere { lines.append(elsewhere.hasSuffix("…") ? elsewhere : elsewhere + ".") }
        if let nothing = marked.nothing { lines.append(nothing + ".") }
        if !marked.caveats.isEmpty, marked.nothing == nil { lines.append("Not compared: " + marked.caveats.joined(separator: "; ") + ".") }
        return lines
    }

    /// What the reads couldn't say, cut or settle, and the marks counted:
    /// less what the count said already (`counted`: it named what couldn't be read).
    static func notes(_ read: KubeMCP.MarkedAppsRead, counted: Bool) -> [String] {
        var said = read.reading.said(plain: true)
        if counted {
            let unread = Set(read.reading.unread(plain: true))
            said = said.filter { !unread.contains($0) }
        }
        var lines = said.map { $0.hasSuffix(".") ? $0 : $0 + "." }
        lines += read.unsettled.map { $0 + "." }
        let tally = read.tally
        if tally.copied > 0 { lines.append("\(KubeMCPMarksText.counted(tally.copied, "object")) carry another object's mark (copied by a controller or an operator): not members.") }
        if tally.unparsed > 0 { lines.append("\(KubeMCPMarksText.counted(tally.unparsed, "mark")) Argo CD wouldn't write: counted, never shown.") }
        if tally.helm > 0 { lines.append("\(KubeMCPMarksText.counted(tally.helm, "workload")) with Helm's instance label alone: not Argo CD's apps.") }
        return lines
    }
}
