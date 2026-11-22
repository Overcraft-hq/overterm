import Foundation

/// What Ask Why on an Argo CD app read from the marks on its objects knows
/// (docs/design/kubernetes/gitops.md, 14.2.6, D6): the app as the section,
/// its detail or the checkout's rail ranked it — its members settled by the
/// objects the brief read —, why it is read from marks and where the
/// Application is, in the mode's words (or the rail's), whose health it is,
/// and what the brief read: each not-ready object's conditions (every
/// message scrubbed and cut to 300 characters as it was decoded), the
/// not-ready workloads' pods as their rows say them, the causes' events.
/// Nothing in it is a value, an env, a template or a field set.
package struct KubeMarkedBriefFacts: Sendable {
    package var ranked: KubeMarkedRanked
    /// Why it is read from marks: the mode's line, or where the rail
    /// placed its Application.
    package var lead: String?
    /// Where the Application is: what only it knows is there
    /// (`KubeMarkedAppDetail.whereTheApplicationIs`).
    package var whereApplication: String
    /// Whose health it is when it isn't the app's: "health of the 2
    /// objects bound here" (the rail's).
    package var scope: String?
    package var context: KubeBriefContext
    /// Each object read for the brief: its conditions, its counts.
    package var objects: [KubeMarkedMember.ID: KubeMarkedWorkloadWire] = [:]
    /// The not-ready workloads' pods, from their rows.
    package var pods: [KubeMarkedMember.ID: [KubeMarkedAppDetail.Child]] = [:]
    /// The causes' events.
    package var events: [KubeMarkedMember.ID: [KubeEvent]] = [:]
    /// What couldn't be read, said.
    package var notes: [String] = []
}

extension KubeAgentBrief {
    /// A not-ready workload's pods said, at most.
    package static let markedPods = 10

    /// The brief on an app read from marks that isn't Ready (Progressing
    /// included: under Argo CD's rules a crash-looping Deployment after a
    /// finished rollout, or a `0/3` StatefulSet, is Progressing): the
    /// question in Argo CD's own word; what is always sent — the app, why
    /// it is read from marks, what only its Application knows and where
    /// that is, its health by Argo CD's built-in rules and whose, each
    /// object as its app counts it, its hooks, its images, how to look
    /// with kubectl and argocd —; each object read's conditions, the
    /// not-ready workloads' pods and the causes' events a chip each. Every
    /// word through `Secrets` (`KubeAgentBriefing.scrubber`), the app's and
    /// its objects' names kept out of what is taken out. Pure.
    package static func markedApp(_ facts: KubeMarkedBriefFacts, now: Date = Date()) -> KubeAgentBrief {
        let app = facts.ranked.app
        let health = facts.ranked.health
        let probable = app.mark == .appInstance
        let scrub = KubeAgentBriefing.scrubber(env: [], names: markedNames(facts))
        let name = probable ? "app \(app.said) (probably Argo CD's)" : "Argo CD app \(app.said)"
        let cause = health.causes.first.map { " — \($0.sentence), \($0.said)" } ?? (health.why.isEmpty ? "" : " — \(health.why)")
        let message: String
        switch health.status {
        case .degraded: message = "Why is \(name) Degraded\(cause)?"
        case .progressing: message = "Why is \(name) still Progressing\(cause)?"
        case .suspended: message = "Why is \(name) Suspended\(cause)?"
        case .healthy: message = "Is anything wrong with \(name)?"
        case .missing, .unknown: message = "What is wrong with \(name) (Unknown\(cause))?"
        }
        var lines = [markedLead(facts.ranked, lead: facts.lead, whereApplication: facts.whereApplication, context: facts.context)]
        var state = "Its health, by Argo CD's built-in rules applied to its objects here (custom health checks configured in Argo CD aren't known): \(health.status.word) — \(health.why)"
        if health.status == .unknown, health.state != .unknown { state += " (ranked with \(health.state.word): its worst known member)" }
        if let scope = facts.scope { state += "; \(scope)" }
        if health.status != .healthy, let since = health.since {
            state += "; for \(KubeAge.format(max(0, now.timeIntervalSince(since))))" + (health.sinceSaid.map { " (\($0))" } ?? "")
        }
        lines.append(state + ".")
        if health.fromRows { lines.append("Some of it is from rows alone: cells can hide a paused Deployment or a stuck rollout whose old pods still serve.") }
        lines += markedObjects(app)
        if !app.images.isEmpty {
            let images = app.images.prefix(10).joined(separator: ", ")
            lines.append("Images: \(images)\(app.images.count > 10 ? " and \(app.images.count - 10) more" : "").")
        }
        for cause in health.causes {
            guard let namespace = cause.member.namespace else { continue }
            let q = KubectlLine.quoted
            lines.append(
                "Read \(cause.said) with: kubectl --context \(q(facts.context.name)) -n \(q(namespace)) describe \(resource(cause.member.kind))/\(q(cause.member.name))")
        }
        if !probable, let argocd = KubeMarkedSection.cliLine(key: app.key) {
            lines.append("Its Application, against your own Argo CD server (never this kubeconfig): \(argocd)")
        }
        if !facts.notes.isEmpty { lines.append("Not in this brief, couldn't be read: " + facts.notes.joined(separator: "; ") + ".") }

        var parts: [AskAgentModel.Part] = []
        let conditions = markedConditions(facts)
        if !conditions.isEmpty { parts.append(.init(title: "conditions", text: scrub(conditions.joined(separator: "\n")))) }
        let pods = markedPodLines(facts)
        if !pods.isEmpty { parts.append(.init(title: "pods", text: scrub(pods.joined(separator: "\n")))) }
        var events: [String] = []
        for cause in health.causes {
            guard let read = facts.events[cause.member], let text = KubeAgentText.events(read, about: cause.said, now: now) else { continue }
            events.append(text)
        }
        if !events.isEmpty { parts.append(.init(title: "events", text: scrub(events.joined(separator: "\n\n")))) }
        let namespace = health.causes.first?.member.namespace ?? app.namespaces.first
        return KubeAgentBrief(
            message: scrub(message), subject: scrub("\(probable ? "app" : "Argo CD app") \(app.said) \(health.status.word)"), text: scrub(lines.joined(separator: "\n")),
            parts: parts, production: facts.context.production, context: facts.context.name, namespace: namespace, images: app.images)
    }

    /// The brief's first lines: the app and where it is, why it is read
    /// from marks, and what only its Application knows — where that is.
    package static func markedLead(_ ranked: KubeMarkedRanked, lead: String?, whereApplication: String, context: KubeBriefContext) -> String {
        let app = ranked.app
        let probable = app.mark == .appInstance
        var lines: [String] = []
        if probable {
            lines.append(
                "App \(app.said) in \(context.said): \(KubeMarkedSection.probablyArgos) No object of it carries Argo CD's tracking id or its instance label.")
        } else {
            lines.append("Argo CD app \(app.said), read from the marks Argo CD leaves on its objects, in \(context.said).")
            if let installation = app.installation { lines.append("Its marks carry installation id \(installation).") }
        }
        if let lead, !lead.isEmpty { lines.append(lead.hasSuffix(".") ? lead : lead + ".") }
        lines.append(
            "What only its Application knows isn't here — sync status, repository and path, target and live revision, sync policy (automated, prune, selfHeal), last sync, project: \(whereApplication)."
        )
        return lines.joined(separator: "\n")
    }

    /// Each object as its app counts it, then its hooks — a namespace in
    /// front of each name.
    package static func markedObjects(_ app: KubeMarkedApp) -> [String] {
        var lines = ["Its objects (\(app.countsSaid)):"]
        for member in app.members {
            var line = "- \(member.id.kind.kind) \(member.id.namespace.map { "\($0)/" } ?? "")\(member.id.name): "
            if let verdict = KubeMarkedHealth.member(member, in: app) {
                line += "\(verdict.status?.word ?? "not read yet") — \(verdict.sentence)" + (verdict.fromRow ? " (from its row)" : "")
                if let detail = verdict.detail, verdict.status != .healthy { line += " — \(detail)" }
            } else {
                line += "no health rule here"
            }
            if member.marks.ignoreHealthcheck { line += " — ignore-healthcheck: not counted, as in Argo CD" }
            lines.append(line)
        }
        for hook in app.hooks {
            let health = hook.health.map { "\($0.status?.word ?? "not read yet") — \($0.sentence)" } ?? "no health read"
            lines.append("- hook \(hook.id.kind.kind) \(hook.id.namespace.map { "\($0)/" } ?? "")\(hook.id.name): \(health) — not counted, as in Argo CD")
        }
        return lines
    }

    /// Each object read's conditions and counts: the not-ready ones' why.
    private static func markedConditions(_ facts: KubeMarkedBriefFacts) -> [String] {
        var lines: [String] = []
        for member in facts.ranked.app.members {
            guard let wire = facts.objects[member.id] else { continue }
            var said = ["\(member.id.kind.kind) \(member.id.namespace.map { "\($0)/" } ?? "")\(member.id.name):"]
            let status = wire.status
            switch member.id.kind {
            case .deployment, .statefulSet:
                let generation = wire.metadata?.generation.map(String.init) ?? "?"
                let observed = status?.observedGeneration.map(String.init) ?? "?"
                said.append(
                    "  replicas: \(wire.spec?.replicas ?? 1) wanted, \(status?.replicas ?? 0) current, \(status?.updatedReplicas ?? 0) updated, \(status?.readyReplicas ?? 0) ready, \(status?.availableReplicas ?? 0) available; generation \(generation), observed \(observed)"
                        + (wire.spec?.paused == true ? "; paused" : ""))
            case .daemonSet:
                said.append(
                    "  \(status?.desiredNumberScheduled ?? 0) desired, \(status?.updatedNumberScheduled ?? 0) updated, \(status?.numberAvailable ?? 0) available")
            case .rollout:
                said.append("  phase \(status?.phase ?? "not reported")" + (status?.message.map { ": \($0)" } ?? ""))
            case .cronJob:
                said.append(
                    "  last scheduled \(status?.lastScheduleTime ?? "never"), last succeeded \(status?.lastSuccessfulTime ?? "never"), \(status?.active ?? 0) running"
                        + (wire.spec?.suspend == true ? "; suspended" : ""))
            default:
                break
            }
            for condition in status?.conditions ?? [] {
                var line = "  \(condition.type ?? "?") \(condition.status ?? "?")"
                if let reason = condition.reason { line += " (\(reason))" }
                if let message = condition.message { line += ": \(message)" }
                if let time = condition.lastTransitionTime { line += " — since \(time)" }
                said.append(line)
            }
            lines += said
        }
        return lines
    }

    /// The not-ready workloads' pods, as their rows say them.
    private static func markedPodLines(_ facts: KubeMarkedBriefFacts) -> [String] {
        var lines: [String] = []
        for member in facts.ranked.app.members {
            guard let pods = facts.pods[member.id], !pods.isEmpty else { continue }
            lines.append("Pods of \(member.id.kind.kind) \(member.id.namespace.map { "\($0)/" } ?? "")\(member.id.name):")
            for pod in pods.prefix(markedPods) {
                let health = pod.health.map { "\($0.sentence) — \($0.status?.word ?? "its state isn't said")" } ?? "its state isn't said"
                lines.append("  \(pod.name): \(health)")
            }
            if pods.count > markedPods { lines.append("  … \(pods.count - markedPods) more") }
        }
        return lines
    }

    /// The kind as kubectl takes it: `deployment.apps`, `service`.
    private static func resource(_ kind: KubeMarkedKind) -> String {
        kind.group.isEmpty ? kind.kind.lowercased() : "\(kind.kind.lowercased()).\(kind.group)"
    }

    /// What the brief names anyway, kept out of what scrubbing takes out:
    /// the app, its namespaces, its objects, their pods, its images'
    /// repositories.
    package static func markedNames(_ facts: KubeMarkedBriefFacts) -> Set<String> {
        let app = facts.ranked.app
        var names: Set<String> = [app.key.instance, app.appName, app.said, facts.context.name]
        if let namespace = app.appNamespace { names.insert(namespace) }
        names.formUnion(app.namespaces)
        for member in app.members + app.hooks { names.insert(member.id.name) }
        for pods in facts.pods.values { names.formUnion(pods.map(\.name)) }
        for image in app.images {
            var repository = image.split(separator: "@").first.map(String.init) ?? image
            if let colon = repository.lastIndex(of: ":"), !repository[colon...].contains("/") { repository = String(repository[..<colon]) }
            names.insert(repository)
            names.formUnion(repository.split(separator: "/").map(String.init))
        }
        return names
    }
}

// MARK: The reads (gitops.md 14.2.6)

extension KubeAgentBriefing {
    /// At most this many of an app's objects read for its brief, its causes first.
    package static let markedObjects = 6
    /// At most this many not-ready workloads' pods listed and causes' events read.
    package static let markedWorkloads = 3
    /// A not-ready workload's pods: at most this many rows, 8 MB.
    package static let markedPodRows = 50
    package static let markedListBytes = 8 << 20
    /// An object's GET, at most.
    package static let markedGetBytes = 4 << 20

    /// Why Ask Why isn't offered on an app read from marks: it is Ready.
    package static func markedNotAsked(_ ranked: KubeMarkedRanked) -> String? {
        guard ranked.health.state == .ready else { return nil }
        let name = ranked.app.mark == .appInstance ? "App \(ranked.app.said)" : "Argo CD app \(ranked.app.said)"
        return "\(name) is Ready (\(ranked.health.why)): Ask Why is for one that isn't."
    }

    /// The kinds an object of is read by a GET when what the context
    /// serves couldn't be read: the built-in workloads' — never "not
    /// served" said of a kind without a discovery to say so.
    package static let markedBuiltInKinds: [KubeResourceKind] = [.deployments, .statefulSets, .daemonSets, .jobs, .cronJobs]

    /// The brief on an app read from marks that isn't Ready — asked by a
    /// person (`a`, the detail's button, the rail's): one failing
    /// Deployment hands off to the Deployment's own brief, the app named
    /// in it (`withMarkedApp`); else a GET of its causes and its other
    /// objects whose rule reads the object and that aren't Healthy (6 at
    /// most, 4 in flight, 4 MB each, the allow-list's — one the section or
    /// the detail read in the last 15 s stands, `known`), its health made
    /// again from them (Ready now: not asked), the not-ready workloads'
    /// pods by their own selector as Table rows (3 at most, 50 rows each) —
    /// an Argo Rollout's by the selector of the Deployment its
    /// `workloadRef` runs, read within the same 6 —, the causes' events.
    /// What the context serves: `discovery`, else read here once, else the
    /// built-in workloads' kinds. Only GETs, each within `readTimeout`;
    /// never a Secret, a ConfigMap, a pod's or a template's values; a read
    /// that fails is said, the brief going on without it.
    package static func markedApp(
        _ asked: KubeMarkedRanked, lead: String?, whereApplication: String, scope: String? = nil, known: [KubeMarkedMember.ID: KubeMarkedSettled] = [:],
        client: KubeClient, context: KubeBriefContext, discovery discovered: KubeDiscovery?, now: Date = Date()
    ) async throws -> KubeAgentBrief {
        if let why = markedNotAsked(asked) { throw KubeBriefProblem.notFailing(why) }
        let given = asked.health
        if given.causes.count == 1, given.more == 0, let cause = given.causes.first, cause.member.kind == .deployment, let namespace = cause.member.namespace {
            let kind = discovered?.kinds.first { $0.fullName == KubeResourceKind.deployments.fullName } ?? .deployments
            let ref = KubeObjectRef(context: context.name, kind: kind, namespace: namespace, name: cause.member.name)
            do {
                let read = try await read(ref, client: client, context: context, discovery: discovered, now: now)
                return withMarkedApp(read.brief, asked, lead: lead, whereApplication: whereApplication, scope: scope, context: context)
            } catch let problem as KubeBriefProblem {
                // Not failing as its own brief reads it (a single replica stuck behind its old pod): the app's.
                guard case .notFailing = problem else { throw problem }
            }
        }
        var notes: [String] = []
        // What the context serves: given, else read once — a context the page hasn't read (the rail's, on another one).
        var discovery = discovered
        var unknownServed: String?
        if discovery == nil {
            do {
                discovery = try await within { try await client.discover() }
            } catch {
                unknownServed = "what \(context.name) serves couldn't be read: \(said(error))"
            }
        }
        var app = asked.app
        let objectKinds = discovery.map { served in KubeMarkedAppsSession.kinds(served).workloads + KubeMarkedAppsSession.kinds(served).rows } ?? markedBuiltInKinds
        func objectKind(_ kind: KubeMarkedKind) -> KubeResourceKind? { objectKinds.first { KubeMarkedKind($0) == kind } }
        // Its causes first, then the others whose rule reads the object and that aren't Healthy.
        var wanted = given.causes.map(\.member).filter { KubeMarkedAppDetail.readsObject($0.kind) }
        for member in app.members where KubeMarkedAppDetail.readsObject(member.id.kind) && !wanted.contains(member.id) {
            guard let verdict = KubeMarkedHealth.member(member, in: app), verdict.status != .healthy, verdict.status != nil || verdict.unread else { continue }
            wanted.append(member.id)
        }
        wanted = Array(wanted.prefix(markedObjects))
        var objects: [KubeMarkedMember.ID: KubeMarkedSettled] = [:]
        let readAt = now
        // Each one: as `known` holds it when fresh, else by a GET of its kind as served.
        func fetch(_ ids: [KubeMarkedMember.ID]) async {
            var paths: [(id: KubeMarkedMember.ID, path: String)] = []
            for id in ids {
                if let kept = known[id], now.timeIntervalSince(kept.at) < KubeMarkedDetailSession.freshFor {
                    objects[id] = kept
                } else if let kind = objectKind(id.kind) {
                    paths.append((id, kind.path(namespace: id.namespace, name: id.name)))
                } else if let unknownServed {
                    notes.append("\(id.said) (\(unknownServed))")
                } else {
                    notes.append("\(id.said) (\(id.kind.kind)s aren't served here)")
                }
            }
            for answer in await KubeMarkedFetch.objects(paths, client: client, maxBytes: markedGetBytes, timeout: readTimeout).answers {
                let id = answer.id
                switch answer.result {
                case .success(var wire):
                    if wire.kind == nil { wire.kind = id.kind.kind }
                    if wire.apiVersion == nil { wire.apiVersion = objectKind(id.kind)?.groupVersion }
                    objects[id] = KubeMarkedSettled(wire, at: readAt)
                case .failure(let error):
                    notes.append("\(id.said) (\(said(error)))")
                }
            }
        }
        await fetch(wanted)
        var health = given
        if !objects.isEmpty {
            // Argo CD's rules over what was read now — unless the asker's verdict wasn't those
            // rules' alone (the rail's: a Deployment scaled to 0 Unknown where Argo Rollouts
            // weren't read), which stands, its objects read for their conditions all the same.
            let own = given == asked.app.health
            app.members = app.members.map { member in objects[member.id].map { member.settled(by: $0.wire) } ?? member }
            if own { health = KubeMarkedHealth.app(app) }
        }
        let ranked = KubeMarkedRanked(app: app, health: health)
        if let why = markedNotAsked(ranked) { throw KubeBriefProblem.notFailing(why.replacingOccurrences(of: " is Ready (", with: " is Ready now (")) }

        // The not-ready workloads' pods, by their own selectors.
        let notReady = app.members.filter { member in
            [.deployment, .statefulSet, .daemonSet, .rollout, .job].contains(member.id.kind)
                && KubeMarkedHealth.member(member, in: app).map { $0.status != .healthy } ?? false
        }.prefix(markedWorkloads).map(\.id)
        // An Argo Rollout with no selector of its own runs the Deployment its `workloadRef` names (all of
        // them on the surveyed spokes): that Deployment's selector finds its pods — read within the same 6.
        var referenced: [KubeMarkedMember.ID] = []
        for id in notReady where id.kind == .rollout {
            guard let wire = objects[id]?.wire, KubeMarkedAppDetail.selector(wire) == nil, let name = wire.spec?.workloadRef?.name else { continue }
            let deployment = KubeMarkedMember.ID(kind: .deployment, namespace: id.namespace, name: name)
            guard objects[deployment] == nil, app.members.contains(where: { $0.id == deployment }), !referenced.contains(deployment) else { continue }
            referenced.append(deployment)
        }
        let room = max(0, markedObjects - wanted.count)
        await fetch(Array(referenced.prefix(room)))
        for deployment in referenced.dropFirst(room) { notes.append("\(deployment.said), whose pods are its Rollout's (\(markedObjects) objects read at most)") }
        var facts = KubeMarkedBriefFacts(ranked: ranked, lead: lead, whereApplication: whereApplication, scope: scope, context: context)
        // A Rollout's Deployment read for its selector alone: its own conditions, scaled to 0 by the Rollout, aren't the app's why.
        facts.objects = objects.filter { !referenced.contains($0.key) }.mapValues(\.wire)
        // The not-ready workloads alone: a Rollout's pods under it, never under the Deployment it scales to 0 (one list once).
        var waiting = app
        waiting.members = app.members.filter { notReady.contains($0.id) }
        let bounds = KubeMarkedAppDetail.Bounds(pods: markedPodRows)
        let lists = KubeMarkedAppDetail.lists(waiting, objects: objects, bounds: bounds).filter { $0.what == .pod }
        let podKind = discovery?.kinds.first { $0.fullName == KubeResourceKind.pods.fullName && $0.canList } ?? .pods
        let maxBytes = markedListBytes
        for list in lists {
            let path = KubeMarkedDetailSession.path(list, kind: podKind)
            let read: Result<(children: [KubeMarkedAppDetail.Child], more: Int?), Error>
            do {
                read = try await within { await KubeMarkedDetailSession.list(path, list: list, kind: podKind, client: client, maxBytes: maxBytes, now: now) }
            } catch {
                read = .failure(error)
            }
            switch read {
            case .success(let found):
                facts.pods[list.of, default: []] += found.children
                if let more = found.more { notes.append("pods of \(list.of.said): the first \(list.limit) read" + (more > 0 ? ", \(more) more not" : ", more not")) }
            case .failure(let error):
                notes.append("pods of \(list.of.said) (\(said(error)))")
            }
        }
        // The causes' events.
        for cause in health.causes.prefix(markedWorkloads) {
            let id = cause.member
            do {
                facts.events[id] = try await within { try await client.events(kind: id.kind.kind, name: id.name, namespace: id.namespace, uid: nil) }
            } catch {
                notes.append("\(id.said)'s events (\(said(error)))")
            }
        }
        facts.notes = notes
        return KubeAgentBrief.markedApp(facts, now: now)
    }

    /// A Deployment's own brief with the app it belongs to named: what is
    /// always sent says it is one of the app's objects, why the app is
    /// read from marks, what only its Application knows and where — and a
    /// chip with the app's objects as it counts them. Scrubbed as the rest.
    package static func withMarkedApp(
        _ brief: KubeAgentBrief, _ ranked: KubeMarkedRanked, lead: String?, whereApplication: String, scope: String?, context: KubeBriefContext
    ) -> KubeAgentBrief {
        var brief = brief
        let facts = KubeMarkedBriefFacts(ranked: ranked, lead: lead, whereApplication: whereApplication, scope: scope, context: context)
        let scrub = scrubber(env: [], names: KubeAgentBrief.markedNames(facts))
        let health = ranked.health
        let app = ranked.app
        var words =
            app.mark == .appInstance
            ? "\nIt is one of app \(app.said)'s objects: \(KubeMarkedSection.probablyArgos)"
            : "\nIt is one of Argo CD app \(app.said)'s objects, as the marks Argo CD leaves on them say."
        if let lead, !lead.isEmpty { words += "\n" + (lead.hasSuffix(".") ? lead : lead + ".") }
        words +=
            "\nWhat only its Application knows isn't here — sync status, repository and path, target and live revision, sync policy (automated, prune, selfHeal), last sync, project: \(whereApplication)."
        words += "\nThe app's health, by Argo CD's built-in rules applied to its objects here: \(health.status.word) — \(health.why)" + (scope.map { "; \($0)" } ?? "") + "."
        brief.text += scrub(words)
        brief.parts.insert(AskAgentModel.Part(title: "Argo CD app", text: scrub(KubeAgentBrief.markedObjects(ranked.app).joined(separator: "\n"))), at: 0)
        return brief
    }
}
