import Foundation

/// Reading what a brief says (docs/design/kubernetes/analysis.md, 3.4):
/// once, when Ask Why is pressed; nothing polls for it. Every read is a GET
/// through the context's proxy (the client given) — the object, its
/// events, its containers' last log lines (`previous` for one that
/// restarted), its owners and their pod template, a Deployment's
/// ReplicaSets, for a Pending pod the nodes — each bounded in time
/// (`readTimeout`), size and count; one that fails or is refused leaves its
/// part out, saying so. **No Secret is read**: the brief names where an
/// env value comes from, never what it is; and a Secret asked about is
/// refused before anything is read.
///
/// Scrubbing: every word goes through `Secrets` before the brief is made —
/// the pod's (and its template's) env values whose names look secret,
/// every URL's password, and what looks like a credential (bearer tokens,
/// JWTs, PEM blocks, AWS keys, a kubeconfig's fields, base64 blobs). The
/// names the brief says anyway — the pod, its containers, its images, its
/// owners — are kept out of what is taken out (`KubeAgentText.names`).
@MainActor
enum KubeAgentBriefing {
    /// How long one read may take before the brief goes without it.
    static var readTimeout: Duration = .seconds(10)

    /// The brief on `ref`: a pod's, or a Deployment's.
    static func brief(
        _ ref: KubeObjectRef, client: KubeClient, context: KubeBriefContext, discovery: KubeDiscovery? = nil, now: Date = Date()
    ) async throws -> KubeAgentBrief {
        try await read(ref, client: client, context: context, discovery: discovery, now: now).brief
    }

    /// The brief on `ref`, and what it read that its usage part reads
    /// too (`KubeMCP.usagePart`): handed on, never read twice.
    static func read(
        _ ref: KubeObjectRef, client: KubeClient, context: KubeBriefContext, discovery: KubeDiscovery? = nil, now: Date = Date()
    ) async throws -> (brief: KubeAgentBrief, reads: KubeBriefReads) {
        guard !ref.isSecret else { throw KubeBriefProblem.unsupported("A Secret is never put in a brief.") }
        if ref.isPod { return try await pod(ref, client: client, context: context, discovery: discovery, now: now) }
        if ref.kind.group == "apps", ref.kind.kind == "Deployment", ref.namespace != nil {
            return try await deployment(ref, client: client, context: context, now: now)
        }
        throw KubeBriefProblem.unsupported("Ask Why is a pod's or a Deployment's.")
    }

    // MARK: A pod

    private static func pod(
        _ ref: KubeObjectRef, client: KubeClient, context: KubeBriefContext, discovery: KubeDiscovery?, now: Date
    ) async throws -> (brief: KubeAgentBrief, reads: KubeBriefReads) {
        let namespace = ref.namespace ?? "default"
        let object = try await within { try await client.object(ref.kind, namespace: namespace, name: ref.name) }
        let json = object.json
        guard !KubeObjectStrip.isSecret(json) else { throw KubeBriefProblem.unsupported("A Secret is never put in a brief.") }
        guard let trouble = KubeTrouble.of(pod: json) else {
            throw KubeBriefProblem.notFailing(KubeTrouble.notFailing(object: json) ?? "pod/\(ref.name) isn't failing.")
        }
        var notes: [String] = []
        var parts: [AskAgentModel.Part] = []

        // Its owners, up to the Deployment: whose template it runs — the
        // last read that has one (`spec.template`): a CronJob's is a Job's
        // template, so its Job's stays. A Secret named owner is not read.
        var owners: [String] = []
        var ownerNames: [String] = []
        var templateOwner: (said: String, json: [String: Any])?
        var diff: String?
        var current = json
        for _ in 0..<2 {
            guard let owner = KubeAgentText.controller(of: current) else { break }
            owners.append("\(owner.kind) \(owner.name)")
            ownerNames.append(owner.name)
            if isSecretOwner(apiVersion: owner.apiVersion, kind: owner.kind) {
                notes.append("its owner Secret \(owner.name) (a Secret is never read)")
                break
            }
            guard let kind = ownerKind(apiVersion: owner.apiVersion, kind: owner.kind, discovery: discovery) else { break }
            do {
                let read = try await within { try await client.object(kind, namespace: namespace, name: owner.name) }.json
                guard !KubeObjectStrip.isSecret(read) else { break }
                current = read
                if !KubeAgentText.map(KubeAgentText.map(read["spec"])["template"]).isEmpty { templateOwner = ("\(owner.kind) \(owner.name)", read) }
            } catch {
                notes.append("its \(owner.kind) \(owner.name) (\(said(error)))")
                break
            }
            if owner.kind == "Deployment" {
                diff = await templateDiff(of: current, client: client, namespace: namespace, notes: &notes)
                break
            }
        }

        // Its env, and its template's: whose values are taken out of every word.
        var env = KubeLogScrub.env(of: json)
        var names = KubeAgentText.names(of: json, owners: ownerNames)
        if let owner = templateOwner?.json {
            env += KubeLogScrub.env(of: KubeAgentText.map(KubeAgentText.map(owner["spec"])["template"]))
            names.formUnion(KubeAgentText.names(of: owner))
        }
        let scrub = scrubber(env: env, names: names)

        var reads = KubeBriefReads(object: json, failingContainer: trouble.container)
        do {
            let events = try await within { try await client.events(kind: "Pod", name: ref.name, namespace: namespace, uid: object.uid) }
            reads.events = events
            if let text = KubeAgentText.events(events, about: "pod/\(ref.name)", now: now) { parts.append(.init(title: "events", text: scrub(text))) }
        } catch {
            notes.append("its events (\(said(error)))")
        }
        for target in KubeAgentText.logTargets(json, trouble: trouble) {
            let query = logQuery(target)
            do {
                let read = try await within { try await client.logTail(namespace: namespace, pod: ref.name, query: query, keep: KubeAgentText.logKeepBytes) }
                if let logs = KubeAgentText.logs(
                    read.lines.map { scrub(KubeAgentText.bounded($0.plain)) }, container: target.container, previous: target.previous, stopped: read.stopped)
                {
                    parts.append(.init(title: (target.previous ? "previous log of " : "log of ") + target.container, text: logs.text))
                }
            } catch {
                notes.append("\(target.container)'s \(target.previous ? "previous " : "")log (\(said(error)))")
            }
        }
        if trouble == .pending {
            var nodes: [[String: Any]]?
            var problem: String?
            do {
                nodes = items(try await within { try await client.get(KubePath.query("/api/v1/nodes", [("limit", "50")])).body })
            } catch {
                problem = said(error)
            }
            parts.append(.init(title: "scheduling", text: scrub(KubeAgentText.scheduling(json, nodes: nodes, nodesProblem: problem))))
        }
        if let owner = templateOwner, let text = KubeAgentText.template(KubeAgentText.map(KubeAgentText.map(owner.json["spec"])["template"]), of: owner.said) {
            parts.append(.init(title: "pod template", text: scrub(text)))
        }
        if let diff { parts.append(.init(title: "template diff", text: scrub(diff))) }

        var text = KubeAgentText.pod(json, trouble: trouble, context: context, owners: owners)
        if !notes.isEmpty { text += "\nNot in this brief, couldn't be read: " + notes.joined(separator: "; ") + "." }
        let brief = KubeAgentBrief(
            message: trouble.question("pod \(namespace)/\(ref.name)"), subject: "pod/\(ref.name) \(trouble.reason)", text: scrub(text), parts: parts,
            production: context.production, context: ref.context, namespace: namespace, images: images(of: json["spec"]))
        return (brief, reads)
    }

    // MARK: A Deployment

    private static func deployment(
        _ ref: KubeObjectRef, client: KubeClient, context: KubeBriefContext, now: Date
    ) async throws -> (brief: KubeAgentBrief, reads: KubeBriefReads) {
        let namespace = ref.namespace ?? "default"
        let object = try await within { try await client.object(ref.kind, namespace: namespace, name: ref.name) }
        let json = object.json
        guard let trouble = KubeTrouble.of(deployment: json) else {
            throw KubeBriefProblem.notFailing(KubeTrouble.notFailing(object: json) ?? "deploy/\(ref.name) is available.")
        }
        var notes: [String] = []
        var parts: [AskAgentModel.Part] = []
        let template = KubeAgentText.map(KubeAgentText.map(json["spec"])["template"])
        let env = KubeLogScrub.env(of: template)
        var names = KubeAgentText.names(of: json)

        let read = await replicaSets(of: json, client: client, namespace: namespace, notes: &notes)
        var reads = KubeBriefReads(object: json, replicaSets: read)
        let sets = read ?? []
        let (current, previous) = KubeAgentText.currentAndPrevious(sets, of: json)
        names.formUnion([current, previous].compactMap { $0 }.map(KubeAgentText.name))

        // Its newest ReplicaSet's pods, and the first of them that fails, read.
        var failing: (json: [String: Any], trouble: KubeTrouble)?
        var podParts: [AskAgentModel.Part] = []
        var podEnv: [(key: String, value: String)] = []
        var selector = KubeForwardResolve.labelSelector(KubeAgentText.map(json["spec"])["selector"] as? [String: Any])
        if let current, let hash = KubeAgentText.string(KubeAgentText.map(KubeAgentText.map(current["metadata"])["labels"])["pod-template-hash"]) {
            selector = (selector.map { $0 + "," } ?? "") + "pod-template-hash=\(hash)"
        }
        let owner = current.map { "ReplicaSet \(KubeAgentText.name($0))" } ?? "deploy/\(ref.name)"
        if let selector {
            do {
                let table = try await within { try await client.list(.pods, in: .namespace(namespace), options: KubeListOptions(labelSelector: selector)) }
                let pods = table.rows.sorted { $0.id < $1.id }.compactMap { KubePodSummary(row: $0, columns: table.columns) }
                if let text = KubeAgentText.pods(pods, of: owner) { podParts.append(.init(title: "pods", text: text)) }
                if let bad = pods.first(where: { $0.isFailing || $0.status == "Pending" }) {
                    do {
                        let pod = try await within { try await client.object(.pods, namespace: namespace, name: bad.id.name) }.json
                        if let podTrouble = KubeTrouble.of(pod: pod) {
                            failing = (pod, podTrouble)
                            podEnv = KubeLogScrub.env(of: pod)
                            names.formUnion(KubeAgentText.names(of: pod))
                        }
                    } catch {
                        notes.append("pod \(bad.id.name) (\(said(error)))")
                    }
                }
            } catch {
                notes.append("its pods (\(said(error)))")
            }
        }
        let scrub = scrubber(env: env + podEnv, names: names)

        do {
            let events = try await within { try await client.events(kind: "Deployment", name: ref.name, namespace: namespace, uid: object.uid) }
            reads.events = events
            if let text = KubeAgentText.events(events, about: "deploy/\(ref.name)", now: now) { parts.append(.init(title: "events", text: scrub(text))) }
        } catch {
            notes.append("its events (\(said(error)))")
        }
        if let current {
            let name = KubeAgentText.name(current)
            let uid = KubeAgentText.string(KubeAgentText.map(current["metadata"])["uid"])
            do {
                let events = try await within { try await client.events(kind: "ReplicaSet", name: name, namespace: namespace, uid: uid) }
                if let text = KubeAgentText.events(events, about: "ReplicaSet \(name)", now: now) {
                    parts.append(.init(title: "ReplicaSet events", text: scrub(text)))
                }
            } catch {
                notes.append("ReplicaSet \(name)'s events (\(said(error)))")
            }
        }
        parts += podParts.map { .init(title: $0.title, text: scrub($0.text)) }
        if let failing {
            let pod = failing.json
            let name = KubeAgentText.name(pod)
            let statuses = KubeAgentText.list(KubeAgentText.map(pod["status"])["containerStatuses"])
            let containers = KubeAgentText.list(KubeAgentText.map(pod["spec"])["containers"])
            var lines = ["Pod \(name), the first of them failing: \(failing.trouble.reason)."]
            for container in containers {
                let status = statuses.first { $0["name"] as? String == container["name"] as? String }
                lines += KubeAgentText.container(container, status: status)
            }
            parts.append(.init(title: "pod/\(name)", text: scrub(lines.joined(separator: "\n"))))
            if let target = KubeAgentText.logTargets(pod, trouble: failing.trouble).first {
                let query = logQuery(target)
                do {
                    let read = try await within { try await client.logTail(namespace: namespace, pod: name, query: query, keep: KubeAgentText.logKeepBytes) }
                    if let logs = KubeAgentText.logs(
                        read.lines.map { scrub(KubeAgentText.bounded($0.plain)) }, container: target.container, previous: target.previous,
                        stopped: read.stopped)
                    {
                        parts.append(.init(title: "log of \(name)", text: "Pod \(name). " + logs.text))
                    }
                } catch {
                    notes.append("\(name)'s log (\(said(error)))")
                }
            }
        }
        if let text = KubeAgentText.template(template, of: "deploy/\(ref.name)") { parts.append(.init(title: "pod template", text: scrub(text))) }
        if let current, let previous {
            let diff = KubeAgentText.templateDiff(
                current: KubeAgentText.map(KubeAgentText.map(current["spec"])["template"]),
                previous: KubeAgentText.map(KubeAgentText.map(previous["spec"])["template"]), currentName: KubeAgentText.name(current),
                previousName: KubeAgentText.name(previous))
            parts.append(.init(title: "template diff", text: scrub(diff)))
        }

        var text = KubeAgentText.deployment(json, trouble: trouble, context: context, current: current, previous: previous)
        if !notes.isEmpty { text += "\nNot in this brief, couldn't be read: " + notes.joined(separator: "; ") + "." }
        let brief = KubeAgentBrief(
            message: trouble.question("deployment \(namespace)/\(ref.name)"), subject: "deploy/\(ref.name) \(trouble.reason)", text: scrub(text),
            parts: parts, production: context.production, context: ref.context, namespace: namespace, images: images(of: template["spec"]))
        return (brief, reads)
    }

    /// A pod spec's containers' images (init containers after), as the
    /// deployed commit reads them.
    static func images(of spec: Any?) -> [String] {
        let spec = KubeAgentText.map(spec)
        let containers = KubeAgentText.list(spec["containers"]) + KubeAgentText.list(spec["initContainers"])
        var seen = Set<String>()
        return containers.compactMap { $0["image"] as? String }.filter { seen.insert($0).inserted }
    }

    // MARK: The bound checkout's deployed commit (3.2)

    /// The brief with the bound checkout's deployed commit — its images'
    /// commit looked up there (`Git.run`, nothing fetched) — as a part of
    /// its own. Nothing is read from the cluster for it; a commit only
    /// the revision label would give (asked for in the rail) isn't here.
    static func withDeployedCommit(_ brief: KubeAgentBrief, checkout: URL) async -> KubeAgentBrief {
        let answer = await KubeDeployedCommit.answer(KubeDeployedCommit.candidates(images: brief.images), in: checkout)
        var brief = brief
        var text = "Checkout \(checkout.path): " + answer.text + (answer.sourceSaid.map { " (\($0))" } ?? "") + "."
        if let found = answer.found, !found.isHead {
            text += " What it has that isn't deployed: git log \(found.short)..HEAD."
        }
        brief.deployedCommit = text
        brief.checkout = checkout.path
        brief.parts.append(AskAgentModel.Part(title: "deployed commit", text: text))
        return brief
    }

    // MARK: Reads

    /// A Deployment's ReplicaSets, by its selector: one page of them; nil, not read.
    private static func replicaSets(
        of deployment: [String: Any], client: KubeClient, namespace: String, notes: inout [String]
    ) async -> [[String: Any]]? {
        guard let selector = KubeForwardResolve.labelSelector(KubeAgentText.map(deployment["spec"])["selector"] as? [String: Any]) else { return nil }
        let path = KubePath.query(
            KubeResourceKind.replicaSets.path(namespace: namespace), [("labelSelector", selector), ("limit", String(KubeTimeline.revisionLimit))])
        do {
            return items(try await within { try await client.get(path).body })
        } catch {
            notes.append("its ReplicaSets (\(said(error)))")
            return nil
        }
    }

    /// The diff of a Deployment's current ReplicaSet's template with the
    /// previous one's; nil when it has only one.
    private static func templateDiff(of deployment: [String: Any], client: KubeClient, namespace: String, notes: inout [String]) async -> String? {
        let sets = await replicaSets(of: deployment, client: client, namespace: namespace, notes: &notes) ?? []
        let (current, previous) = KubeAgentText.currentAndPrevious(sets, of: deployment)
        guard let current else { return nil }
        guard let previous else { return "No previous ReplicaSet: ReplicaSet \(KubeAgentText.name(current)) is the Deployment's only revision kept." }
        return KubeAgentText.templateDiff(
            current: KubeAgentText.map(KubeAgentText.map(current["spec"])["template"]),
            previous: KubeAgentText.map(KubeAgentText.map(previous["spec"])["template"]), currentName: KubeAgentText.name(current),
            previousName: KubeAgentText.name(previous))
    }

    /// A container's last lines, as a brief asks for them: bounded in
    /// lines and bytes, read once.
    static func logQuery(_ target: (container: String, previous: Bool)) -> KubeLogQuery {
        KubeLogQuery(container: target.container, previous: target.previous, tailLines: KubeAgentText.logLines, limitBytes: KubeAgentText.logReadBytes)
    }

    /// Whether an owner reference names a Secret: never followed.
    static func isSecretOwner(apiVersion: String, kind: String) -> Bool {
        kind == "Secret" && (apiVersion == "v1" || apiVersion.isEmpty)
    }

    /// An owner's kind, as the context serves it, else Kubernetes' own;
    /// nil for a Secret, which is never read.
    static func ownerKind(apiVersion: String, kind: String, discovery: KubeDiscovery?) -> KubeResourceKind? {
        guard !isSecretOwner(apiVersion: apiVersion, kind: kind) else { return nil }
        if let served = discovery?.kind(apiVersion: apiVersion, kind: kind) {
            return served.group.isEmpty && served.resource == "secrets" ? nil : served
        }
        let builtIn: [KubeResourceKind] = [.replicaSets, .deployments, .statefulSets, .daemonSets, .jobs, .cronJobs]
        return builtIn.first { $0.kind == kind && apiVersion.hasPrefix($0.group + "/") }
    }

    /// A plain list's items.
    nonisolated static func items(_ body: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    /// What every word of the brief goes through: the env's secret values
    /// (but `names`), every URL's password, then credentials and blobs.
    nonisolated static func scrubber(env: [(key: String, value: String)], names: Set<String>) -> (String) -> String {
        { Secrets.scrubCredentials(Secrets.scrub($0, env: env, keeping: names)) }
    }

    private static func said(_ error: Error) -> String {
        error is KubeBriefTimeout ? "no answer in \(readTimeout)" : KubernetesModel.said(error)
    }

    /// One read, or `KubeBriefTimeout` once `readTimeout` has passed — its
    /// request cancelled, and the brief goes on without it.
    static func within<T: Sendable>(_ read: @escaping @Sendable () async throws -> T) async throws -> T {
        try await KubeBriefRace.run(limit: readTimeout, read)
    }
}

/// What a brief read that its usage part reads too (`KubeMCP.usagePart`,
/// metrics.md 7): handed on within one Ask Why, so nothing is read twice.
struct KubeBriefReads: @unchecked Sendable {
    /// The object asked about: the pod's, or the Deployment's.
    var object: [String: Any]
    /// Its own events; nil, they couldn't be read.
    var events: [KubeEvent]?
    /// A Deployment's ReplicaSets, one page by its selector; nil, not read.
    var replicaSets: [[String: Any]]?
    /// The pod's failing container, as `KubeTrouble` names it.
    var failingContainer: String?
}

/// A read that took longer than the brief waits.
struct KubeBriefTimeout: Error {}

/// A read raced against a clock: whichever ends first answers, once.
final class KubeBriefRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    static func run(limit: Duration, _ read: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = KubeBriefRace<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.lock.lock()
            race.continuation = continuation
            race.lock.unlock()
            let work = Task {
                do {
                    race.finish(.success(try await read()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                race.finish(.failure(KubeBriefTimeout()))
                work.cancel()
            }
        }
    }
}

extension KubeResourceKind {
    static let replicaSets = KubeResourceKind(
        group: "apps", version: "v1", resource: "replicasets", kind: "ReplicaSet", singular: "replicaset", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["rs"], categories: ["all"],
        subresources: ["scale", "status"])
    static let statefulSets = KubeResourceKind(
        group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", singular: "statefulset", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["sts"], categories: ["all"],
        subresources: ["scale", "status"])
    static let daemonSets = KubeResourceKind(
        group: "apps", version: "v1", resource: "daemonsets", kind: "DaemonSet", singular: "daemonset", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["ds"], categories: ["all"],
        subresources: ["status"])
    static let jobs = KubeResourceKind(
        group: "batch", version: "v1", resource: "jobs", kind: "Job", singular: "job", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], categories: ["all"], subresources: ["status"])
    static let cronJobs = KubeResourceKind(
        group: "batch", version: "v1", resource: "cronjobs", kind: "CronJob", singular: "cronjob", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["cj"], categories: ["all"],
        subresources: ["status"])
}

/// The agents Ask Why's brief is offered to, in order (3.4): the agents in
/// a tab of a checkout bound to the brief's namespace — the brief's own
/// checkout's (the selected tab's binding when it is bound there) first —,
/// then the selected tab's agent, then the others. Pure over what it is given.
enum KubeBriefTargets {
    static func ordered<Agent: AnyObject>(
        _ agents: [Agent], selected: Agent?, checkout: (Agent) -> String?, bound: Set<String>, first: String?
    ) -> [Agent] {
        var ordered = agents.filter { checkout($0).map(bound.contains) ?? false }
        if let first, let index = ordered.firstIndex(where: { checkout($0) == first }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        if let selected, agents.contains(where: { $0 === selected }), !ordered.contains(where: { $0 === selected }) { ordered.append(selected) }
        return ordered + agents.filter { agent in !ordered.contains { $0 === agent } }
    }
}
