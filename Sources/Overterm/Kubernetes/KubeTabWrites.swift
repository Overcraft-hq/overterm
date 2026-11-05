import Foundation

/// A write that runs as kubectl in a terminal tab rather than as a request
/// (stage 2a, part 3 — docs/design/kubernetes/analysis.md, Sections 2.4,
/// 2.9, 2.15 and 5): a drain, where evictions and what a
/// PodDisruptionBudget blocks show as they go; a rollback to a revision
/// picked from the ReplicaSets' history (`rollout undo` is kubectl's own
/// logic, not copied); a debug container in a pod, and a node debugged.
/// Each is a writing process (`KubeProcessVerb.writes`): refused on a
/// read-only context by the process class check, its access reviewed,
/// confirmed in the window naming the context and namespace — the name
/// typed where rule 4 says — then typed into a tab pinned to the context,
/// `--context` and `-n` always, quoted for zsh. Pure.
enum KubeTabWrite: Equatable, Sendable {
    /// `kubectl drain NODE --ignore-daemonsets`: cordoned, then its pods
    /// evicted (DaemonSets' stay), each as its PodDisruptionBudgets allow.
    /// `namespace`: its tab's, for `-n` (rule 7: always; a node's drain
    /// reads none, and evicts across the cluster).
    case drain(node: String, namespace: String)
    /// `kubectl rollout undo deployment/NAME --to-revision=N`; `images`:
    /// that revision's, for the confirmation.
    case rolloutUndo(deployment: String, namespace: String, revision: Int, images: [String])
    /// `kubectl debug -it POD --image=I --target=C`: an ephemeral container
    /// beside C, sharing its processes, attached.
    case debug(pod: String, namespace: String, container: String?, image: String)
    /// `kubectl debug node/NODE -it --image=I`: a pod on the node, its
    /// filesystem at /host, made in `namespace`.
    case nodeDebug(node: String, namespace: String, image: String)

    var verb: KubeProcessVerb {
        switch self {
        case .drain: .drain
        case .rolloutUndo: .rolloutUndo
        case .debug: .debug
        case .nodeDebug: .nodeShell
        }
    }

    /// The object's own name — what rule 4 asks to be typed.
    var name: String {
        switch self {
        case .drain(let node, _), .nodeDebug(let node, _, _): node
        case .rolloutUndo(let deployment, _, _, _): deployment
        case .debug(let pod, _, _, _): pod
        }
    }

    /// The namespace its command names (`-n`, always).
    var namespace: String {
        switch self {
        case .drain(_, let namespace), .rolloutUndo(_, let namespace, _, _), .debug(_, let namespace, _, _), .nodeDebug(_, let namespace, _): namespace
        }
    }

    /// Where it acts, for the confirmation: nil across the cluster — a
    /// drain evicts in every namespace, whatever its `-n`.
    var scopeNamespace: String? {
        if case .drain = self { return nil }
        return namespace
    }

    /// `node fake-node-1`, `deployment shop/web`, `pod shop/web-7d9`.
    var spoken: String {
        switch self {
        case .drain(let node, _), .nodeDebug(let node, _, _): "node \(node)"
        case .rolloutUndo(let deployment, let namespace, _, _): "deployment \(namespace)/\(deployment)"
        case .debug(let pod, let namespace, _, _): "pod \(namespace)/\(pod)"
        }
    }

    /// The words, unchecked (`KubeCommands.command(_:in:)` checks them first).
    func line(context: String) -> String {
        let q = KubeCommands.quoted
        var words: [String]
        switch self {
        case .drain(let node, _):
            words = ["kubectl", "drain", q(node), "--ignore-daemonsets"]
        case .rolloutUndo(let deployment, _, let revision, _):
            words = ["kubectl", "rollout", "undo", q("deployment/" + deployment), "--to-revision=\(revision)"]
        case .debug(let pod, _, let container, let image):
            words = ["kubectl", "debug", "-it", q(pod), "--image=" + q(image)]
            if let container, !container.isEmpty { words.append("--target=" + q(container)) }
        case .nodeDebug(let node, _, let image):
            words = ["kubectl", "debug", q("node/" + node), "-it", "--image=" + q(image)]
        }
        words += ["--context", q(context), "-n", q(namespace)]
        return words.joined(separator: " ")
    }

    /// What the cluster's access review is asked first, and where (nil:
    /// across the cluster — a drain evicts in every namespace).
    var accesses: [(access: KubeAccess, namespace: String?)] {
        switch self {
        case .drain:
            [(KubeAccess(verb: "patch", resource: "nodes"), nil), (KubeAccess(verb: "create", resource: "pods/eviction"), nil)]
        case .rolloutUndo(_, let namespace, _, _):
            [(KubeAccess(verb: "patch", resource: "deployments.apps"), namespace)]
        case .debug(_, let namespace, _, _):
            [(KubeAccess(verb: "patch", resource: "pods/ephemeralcontainers"), namespace), (KubeAccess.attach, namespace)]
        case .nodeDebug(_, let namespace, _):
            [(KubeAccess(verb: "create", resource: "pods"), namespace), (KubeAccess.attach, namespace)]
        }
    }

    /// The same, for a verb before its object is read.
    static func accesses(_ verb: KubeProcessVerb, namespace: String?) -> [(access: KubeAccess, namespace: String?)] {
        switch verb {
        case .drain: KubeTabWrite.drain(node: "", namespace: namespace ?? "").accesses
        case .rolloutUndo: KubeTabWrite.rolloutUndo(deployment: "", namespace: namespace ?? "", revision: 0, images: []).accesses
        case .debug: KubeTabWrite.debug(pod: "", namespace: namespace ?? "", container: nil, image: "").accesses
        case .nodeShell: KubeTabWrite.nodeDebug(node: "", namespace: namespace ?? "", image: "").accesses
        default: []
        }
    }

    /// The tab verbs a kind has: a node's drain and debug, a Deployment's
    /// rollback, a pod's debug container (where the server serves
    /// ephemeral containers).
    static func offered(_ verb: KubeProcessVerb, on kind: KubeResourceKind) -> Bool {
        let core = kind.group.isEmpty
        switch verb {
        case .drain, .nodeShell: return core && kind.resource == "nodes"
        case .rolloutUndo: return kind.group == "apps" && kind.resource == "deployments" && kind.verbs.contains("patch")
        case .debug: return core && kind.resource == "pods" && kind.subresources.contains("ephemeralcontainers")
        default: return false
        }
    }

    /// The verbs in a menu's order.
    static let verbs: [KubeProcessVerb] = [.debug, .nodeShell, .rolloutUndo, .drain]

    static func title(_ verb: KubeProcessVerb) -> String {
        switch verb {
        case .debug: "Debug Container in a Tab…"
        case .nodeShell: "Debug Node in a Tab…"
        case .rolloutUndo: "Roll Back in a Tab…"
        case .drain: "Drain in a Tab…"
        default: verb.title
        }
    }

    static func label(_ verb: KubeProcessVerb) -> String {
        switch verb {
        case .debug, .nodeShell: "Debug"
        case .rolloutUndo: "Roll Back"
        case .drain: "Drain"
        default: verb.title
        }
    }

    static func symbol(_ verb: KubeProcessVerb) -> String {
        switch verb {
        case .debug, .nodeShell: "ladybug"
        case .rolloutUndo: "clock.arrow.circlepath"
        case .drain: "arrow.down.to.line"
        default: "terminal"
        }
    }

    /// What the confirmation says (rule 3): the context and namespace —
    /// production in capitals —, what happens, the command the tab runs,
    /// and the name to type where `rule` asks it.
    func confirmation(context: KubeContext, rule: KubeProcessRule) -> KubeWriteConfirmation {
        let command = line(context: context.name)
        let place =
            (context.isProduction ? KubeWriteConfirmation.productionMark : "") + context.name + " · "
            + (scopeNamespace.map { "namespace \($0)" } ?? "cluster-wide")
        let title: String
        let what: String
        let button: String
        switch self {
        case .drain(let node, _):
            title = "Drain node \(node)?"
            what =
                "It is cordoned, then its pods are evicted — DaemonSets' stay — each only as its PodDisruptionBudgets allow: "
                + "the tab shows what is evicted and what blocks it. Uncordon it after."
            button = "Drain in a Tab"
        case .rolloutUndo(let deployment, let namespace, let revision, let images):
            title = "Roll back deployment \(namespace)/\(deployment) to revision \(revision)?"
            what =
                "Its pod template goes back to revision \(revision)'s"
                + (images.isEmpty ? "" : " (" + images.joined(separator: ", ") + ")")
                + ", as kubectl rollout undo puts it back: a rollout then replaces its pods."
            button = "Roll Back in a Tab"
        case .debug(let pod, let namespace, let container, let image):
            title = "Add a debug container to pod \(namespace)/\(pod)?"
            what =
                "An ephemeral container running \(image) joins the pod"
                + (container.map { ", seeing container \($0)'s processes" } ?? "")
                + ", and the tab attaches to it. It stays in the pod's spec until the pod goes: it can't be removed."
            button = "Debug in a Tab"
        case .nodeDebug(let node, let namespace, let image):
            title = "Debug node \(node)?"
            what =
                "A pod running \(image) is made on the node in namespace \(namespace), with the node's filesystem at /host and its "
                + "process and network namespaces: what runs in it can change the node. Delete the pod when you are done."
            button = "Debug Node in a Tab"
        }
        var lines = [what, "Runs in a new tab pinned to \(context.displayName): \(command)"]
        let typed = rule.typedName ? name : nil
        if let typed { lines.append("Type \(typed) to confirm.") }
        return KubeWriteConfirmation(
            verb: nil, title: title, scope: place, detail: lines.joined(separator: "\n"), button: button, typedName: typed,
            production: context.isProduction, kubectl: command)
    }

    /// What the page says once its tab is open.
    func opened(context: String) -> String {
        switch self {
        case .drain(let node, _): "Draining node \(node) in a new tab, in \(context)."
        case .rolloutUndo(let deployment, let namespace, let revision, _):
            "Rolling back deployment \(namespace)/\(deployment) to revision \(revision) in a new tab, in \(context)."
        case .debug(let pod, let namespace, _, _): "A debug container for pod \(namespace)/\(pod) in a new tab, in \(context)."
        case .nodeDebug(let node, _, _): "Debugging node \(node) in a new tab, in \(context)."
        }
    }
}

/// A write that runs as a command in a tab pinned to its context —
/// kubectl's (`KubeTabWrite`) or helm's (`KubeHelmWrite`) — as the page's
/// one path for them takes it (`confirmTabWrite`): its process verb for
/// the class check, the name rule 4 asks to be typed, its words, its
/// confirmation and what the page says once its tab is open.
protocol KubeTabCommand: Sendable {
    var verb: KubeProcessVerb { get }
    var name: String { get }
    /// Why it can't be built whatever the context: nil when it can.
    var refused: String? { get }
    func line(context: String) -> String
    func confirmation(context: KubeContext, rule: KubeProcessRule) -> KubeWriteConfirmation
    func opened(context: String) -> String
}

extension KubeTabCommand {
    var refused: String? { nil }
}

extension KubeTabWrite: KubeTabCommand {}

extension KubeCommands {
    /// The debug container's image when neither the context nor the setting names one.
    static let defaultDebugImage = "busybox:1.36"

    /// A tab write's command, checked against the context first: nothing
    /// the process class check refuses is built.
    static func command(_ write: some KubeTabCommand, in context: KubeContext) throws -> String {
        if let refused = KubeProcessCheck.rule(write.verb, for: context).refused { throw Refused(reason: refused) }
        if let refused = write.refused { throw Refused(reason: refused) }
        return write.line(context: context.name)
    }
}

/// One revision of a Deployment: a ReplicaSet it owns, by its
/// `deployment.kubernetes.io/revision`. Pure.
struct KubeRevision: Equatable, Sendable {
    var revision: Int
    var name: String
    var images: [String]
    var created: Date?
    var cause: String?
    var current: Bool

    /// The Deployment's ReplicaSets as revisions, newest first: only those
    /// it owns (its uid, else its kind and name), the one it says it is at
    /// marked current.
    static func of(_ sets: [[String: Any]], deployment: [String: Any]) -> [KubeRevision] {
        let metadata = KubeAgentText.map(deployment["metadata"])
        let uid = metadata["uid"] as? String
        let name = metadata["name"] as? String ?? ""
        let at = KubeAgentText.string(KubeAgentText.map(metadata["annotations"])["deployment.kubernetes.io/revision"]).flatMap { Int($0) }
        let owned = sets.filter { KubeMCPText.isOwned($0, by: uid, name: name, kind: "Deployment") }
        let revisions = owned.compactMap { set -> KubeRevision? in
            guard let revision = KubeAgentText.revision(set) else { return nil }
            let setMetadata = KubeAgentText.map(set["metadata"])
            let template = KubeAgentText.map(KubeAgentText.map(set["spec"])["template"])
            let images = KubeAgentText.list(KubeAgentText.map(template["spec"])["containers"]).compactMap { $0["image"] as? String }
            return KubeRevision(
                revision: revision, name: KubeAgentText.name(set), images: images,
                created: (setMetadata["creationTimestamp"] as? String).flatMap(KubeTime.date),
                cause: KubeAgentText.string(KubeAgentText.map(setMetadata["annotations"])["kubernetes.io/change-cause"]), current: false)
        }.sorted { $0.revision > $1.revision }
        let current = at ?? revisions.first?.revision
        return revisions.map {
            var revision = $0; revision.current = revision.revision == current; return revision
        }
    }

    /// What a rollback may go to: every revision but the current one,
    /// newest first, at most `limit` (a sheet's buttons).
    static func choices(_ revisions: [KubeRevision], limit: Int = 8) -> [KubeRevision] {
        Array(revisions.filter { !$0.current }.prefix(limit))
    }

    /// `Revision 1 — nginx:1.26 · 3h ago`.
    func label(now: Date) -> String {
        var text = "Revision \(revision)"
        if !images.isEmpty { text += " — " + images.joined(separator: ", ") }
        if let created { text += " · \(KubeAge.format(max(0, now.timeIntervalSince(created)))) ago" }
        return text
    }
}
