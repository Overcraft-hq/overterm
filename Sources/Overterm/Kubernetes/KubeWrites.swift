import Foundation
import NIOHTTP1

/// A write refused before it left Overterm: the context is read-only (its
/// writable flag; production without its switch for the session), or the
/// connection reads only.
struct KubeWriteRefused: Error, Equatable, LocalizedError, CustomStringConvertible {
    var reason: String
    var errorDescription: String? { reason }
    var description: String { reason }
}

/// What the page can change in a cluster (stage 2a, part 1 —
/// docs/design/kubernetes/analysis.md, Sections 2.4, 2.9 and 5). Each goes
/// through one guard path (`KubernetesPageModel+Writes`): the class check
/// (`KubeWriteCheck`), the access review, the confirmation naming the
/// context and namespace, the typed name where rule 4 says, then the
/// request (`KubeWrites`) and its outcome said (`KubeWriteOutcome`).
enum KubeWriteVerb: String, CaseIterable, Sendable {
    /// `DELETE`, in the background, after the pod's grace period.
    case delete
    /// A pod deleted so its controller makes it again (`r` on a pod).
    case recreate
    /// A pod deleted with no grace period: the kubelet isn't waited for.
    case forceDelete
    /// The object's finalizers taken away: a JSON patch.
    case removeFinalizers
    /// A pod evicted through its `eviction` subresource, as drain does: PDBs respected.
    case evict
    /// A rollout restarted: kubectl's `restartedAt` annotation on the template.
    case restart
    /// The `scale` subresource's replicas.
    case scale

    var title: String {
        switch self {
        case .delete: "Delete…"
        case .recreate: "Delete to Recreate…"
        case .forceDelete: "Force Delete…"
        case .removeFinalizers: "Remove Finalizers…"
        case .evict: "Evict…"
        case .restart: "Rollout Restart…"
        case .scale: "Scale…"
        }
    }

    var label: String {
        switch self {
        case .delete: "Delete"
        case .recreate: "Recreate"
        case .forceDelete: "Force Delete"
        case .removeFinalizers: "Finalizers"
        case .evict: "Evict"
        case .restart: "Restart"
        case .scale: "Scale"
        }
    }

    var symbol: String {
        switch self {
        case .delete, .forceDelete: "trash"
        case .recreate, .restart: "arrow.clockwise"
        case .removeFinalizers: "scissors"
        case .evict: "arrow.up.forward.square"
        case .scale: "plusminus"
        }
    }
}

/// Whether a write may be done on a context, and what it asks first. Pure.
struct KubeWriteRule: Equatable, Sendable {
    /// Why it may not be done here; nil when it may.
    var refused: String?
    /// What the access review (SelfSubjectAccessReview) is asked first.
    var access: KubeAccess?
    /// The object's name typed to confirm (rule 4).
    var typedName = false
    /// What the confirmation warns of.
    var warning: String?

    var allowed: Bool { refused == nil }
}

/// The class check for writes (rules 1, 2 and 4): every write verb against
/// the context's class and writability, and the kind's verbs as discovery
/// says them. Nothing it refuses is sent. Pure.
enum KubeWriteCheck {
    /// Whether `kind` has the verb at all — offered in its menu.
    static func offered(_ verb: KubeWriteVerb, on kind: KubeResourceKind) -> Bool {
        let pods = kind.group.isEmpty && kind.resource == "pods"
        switch verb {
        case .delete: return kind.verbs.contains("delete")
        case .recreate, .forceDelete: return pods && kind.verbs.contains("delete")
        case .removeFinalizers: return kind.verbs.contains("patch")
        case .evict: return pods && kind.subresources.contains("eviction")
        case .restart: return kind.group == "apps" && ["deployments", "statefulsets", "daemonsets"].contains(kind.resource) && kind.verbs.contains("patch")
        case .scale: return kind.subresources.contains("scale")
        }
    }

    /// What the access review is asked: `delete pods`, `patch deployments.apps/scale`, `create pods/eviction`.
    static func access(_ verb: KubeWriteVerb, on kind: KubeResourceKind) -> KubeAccess {
        switch verb {
        case .delete, .recreate, .forceDelete: KubeAccess(verb: "delete", resource: kind.fullName)
        case .removeFinalizers, .restart: KubeAccess(verb: "patch", resource: kind.fullName)
        case .evict: KubeAccess(verb: "create", resource: "pods/eviction")
        case .scale: KubeAccess(verb: "patch", resource: kind.fullName + "/scale")
        }
    }

    /// `replicas`: what a scale would set, for scaling to 0.
    static func rule(_ verb: KubeWriteVerb, for context: KubeContext, kind: KubeResourceKind, replicas: Int? = nil) -> KubeWriteRule {
        guard offered(verb, on: kind) else {
            return KubeWriteRule(refused: "A \(kind.kind.isEmpty ? kind.resource : kind.kind) has no \(verb.label.lowercased()).")
        }
        guard context.isWritable else { return KubeWriteRule(refused: readOnly(context)) }
        let production = context.isProduction
        let namespace = kind.group.isEmpty && kind.resource == "namespaces"
        let typed: Bool =
            switch verb {
            // Section 2.4: always with the name typed.
            case .forceDelete, .removeFinalizers: true
            case .delete: production || namespace
            case .recreate: production
            case .scale: production && replicas == 0
            case .evict, .restart: false
            }
        return KubeWriteRule(access: access(verb, on: kind), typedName: typed, warning: warning(verb, kind: kind))
    }

    static func warning(_ verb: KubeWriteVerb, kind: KubeResourceKind) -> String? {
        switch verb {
        case .forceDelete:
            "Force deleting doesn't wait for the kubelet to say the pod stopped: its containers may still be running on their node, "
                + "and a StatefulSet's pod may run twice."
        case .removeFinalizers:
            "A finalizer is a controller's promise to clean up — a volume, a load balancer, DNS — before the object goes. "
                + "Removed, that cleanup may never happen, and an object already being deleted goes at once."
        case .delete where kind.group.isEmpty && kind.resource == "namespaces":
            "Everything in the namespace is deleted with it."
        default: nil
        }
    }

    /// Why a context takes no write.
    static func readOnly(_ context: KubeContext) -> String {
        context.isProduction
            ? "Production is read-only: turn on writes for this session on its card first."
            : "This context is read-only: Overterm changes nothing here (its writable setting)."
    }
}

/// One write as it goes to the API server. Pure.
struct KubeWriteRequest: Equatable, Sendable {
    var method: HTTPMethod
    /// With its query.
    var path: String
    var body: Data
    var contentType: String

    /// The body read back, for the tests.
    var json: Any? { try? JSONSerialization.jsonObject(with: body) }
}

/// The requests each verb is, as kubectl makes them (docs/design/kubernetes/
/// analysis.md, Section 4, Writes). Pure.
enum KubeWrites {
    /// managedFields says who changed it.
    static let fieldManager = "overterm"
    static let restartedAt = "kubectl.kubernetes.io/restartedAt"
    static let mergePatch = "application/merge-patch+json"
    static let strategicPatch = "application/strategic-merge-patch+json"
    static let jsonPatch = "application/json-patch+json"

    /// `DELETE` with DeleteOptions: in the background (what it owns goes
    /// after it), `gracePeriodSeconds` only when given — 0 forces it.
    static func delete(_ ref: KubeObjectRef, gracePeriod: Int? = nil) -> KubeWriteRequest {
        var options: [String: Any] = ["apiVersion": "v1", "kind": "DeleteOptions", "propagationPolicy": "Background"]
        if let gracePeriod { options["gracePeriodSeconds"] = gracePeriod }
        return KubeWriteRequest(method: .DELETE, path: path(ref), body: encode(options), contentType: "application/json")
    }

    /// A JSON patch: the finalizers confirmed are tested first, so one
    /// added meanwhile fails the patch (422) instead of going unseen.
    static func removeFinalizers(_ ref: KubeObjectRef, finalizers: [String]) -> KubeWriteRequest {
        let patch: [[String: Any]] = [
            ["op": "test", "path": "/metadata/finalizers", "value": finalizers], ["op": "remove", "path": "/metadata/finalizers"],
        ]
        return KubeWriteRequest(method: .PATCH, path: managed(path(ref)), body: encode(patch), contentType: jsonPatch)
    }

    /// `POST pods/{p}/eviction`: the API refuses with a 429 when a
    /// PodDisruptionBudget doesn't allow it now.
    static func evict(_ ref: KubeObjectRef) -> KubeWriteRequest {
        var metadata = ["name": ref.name]
        if let namespace = ref.namespace { metadata["namespace"] = namespace }
        let eviction: [String: Any] = ["apiVersion": "policy/v1", "kind": "Eviction", "metadata": metadata]
        return KubeWriteRequest(method: .POST, path: path(ref) + "/eviction", body: encode(eviction), contentType: "application/json")
    }

    /// kubectl rollout restart's patch: the template's `restartedAt`
    /// annotation set to now, so the controller rolls every pod.
    static func restart(_ ref: KubeObjectRef, at date: Date) -> KubeWriteRequest {
        let patch: [String: Any] = ["spec": ["template": ["metadata": ["annotations": [restartedAt: stamp(date)]]]]]
        return KubeWriteRequest(method: .PATCH, path: managed(path(ref)), body: encode(patch), contentType: strategicPatch)
    }

    /// The `scale` subresource's replicas, as a merge patch (RBAC: `patch` on `<kind>/scale`).
    static func scale(_ ref: KubeObjectRef, replicas: Int) -> KubeWriteRequest {
        KubeWriteRequest(
            method: .PATCH, path: managed(path(ref) + "/scale"), body: encode(["spec": ["replicas": replicas]]), contentType: mergePatch)
    }

    /// A SelfSubjectAccessReview: may this user do it here.
    static func review(_ access: KubeAccess, namespace: String?, name: String? = nil) -> KubeWriteRequest {
        let review: [String: Any] = [
            "apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
            "spec": ["resourceAttributes": KubeAccessReview.attributes(access, namespace: namespace, name: name)],
        ]
        return KubeWriteRequest(method: .POST, path: KubeAccessReview.path, body: encode(review), contentType: "application/json")
    }

    static func path(_ ref: KubeObjectRef) -> String { ref.kind.path(namespace: ref.namespace, name: ref.name) }

    private static func managed(_ path: String) -> String { KubePath.query(path, [("fieldManager", fieldManager)]) }

    /// RFC 3339, as kubectl writes `restartedAt`.
    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    static func encode(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data() }

    /// The kubectl command a write equals, for the confirmation (rule 3):
    /// `--context` and `-n` always, quoted for zsh. Nil for an eviction —
    /// no kubectl command evicts one pod (drain evicts this way).
    static func kubectl(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, replicas: Int? = nil, discovery: KubeDiscovery? = nil) -> String? {
        let resource = KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery))
        let name = KubectlLine.quoted(ref.name)
        var words: [String]
        switch verb {
        case .delete, .recreate: words = ["kubectl", "delete", resource, name]
        case .forceDelete: words = ["kubectl", "delete", resource, name, "--grace-period=0", "--force"]
        case .removeFinalizers:
            words = ["kubectl", "patch", resource, name, "--type=json", "-p", KubectlLine.quoted(#"[{"op":"remove","path":"/metadata/finalizers"}]"#)]
        case .evict: return nil
        case .restart: words = ["kubectl", "rollout", "restart", KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery) + "/" + ref.name)]
        case .scale:
            words = ["kubectl", "scale", KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery) + "/" + ref.name), "--replicas=\(replicas ?? 0)"]
        }
        words += ["--context", KubectlLine.quoted(ref.context)]
        if let namespace = ref.namespace { words += ["-n", KubectlLine.quoted(namespace)] }
        return words.joined(separator: " ")
    }
}

/// SelfSubjectAccessReview (decision 12): asked through a writable
/// context's socket — a read-only one's refuses every POST, and takes no
/// write anyway. Authoritative per verb; `SelfSubjectRulesReview` would
/// only be a hint. Pure.
enum KubeAccessReview {
    static let path = "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews"

    /// `KubeAccess`'s resource, as kubectl names it (`deployments.apps/scale`),
    /// taken apart: resource, group, subresource.
    static func attributes(_ access: KubeAccess, namespace: String?, name: String? = nil) -> [String: String] {
        let parts = access.resource.split(separator: "/", maxSplits: 1).map(String.init)
        let full = parts.first ?? access.resource
        var attributes = ["verb": access.verb]
        if let dot = full.firstIndex(of: ".") {
            attributes["resource"] = String(full[..<dot])
            attributes["group"] = String(full[full.index(after: dot)...])
        } else {
            attributes["resource"] = full
            attributes["group"] = ""
        }
        if parts.count > 1 { attributes["subresource"] = parts[1] }
        if let namespace, !namespace.isEmpty { attributes["namespace"] = namespace }
        if let name { attributes["name"] = name }
        return attributes
    }

    /// The review's answer: allowed, or not with the authorizer's reason.
    static func parse(_ data: Data) -> KubeCanIAnswer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = object["status"] as? [String: Any] else {
            return .failed("The access review's answer couldn't be read.")
        }
        if status["allowed"] as? Bool == true { return .yes }
        let reason = [status["reason"] as? String, (status["evaluationError"] as? String).map { "evaluation error: \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
        return .no(reason.isEmpty ? nil : reason)
    }
}

/// What a write's pre-read finds in an object's metadata alone
/// (`PartialObjectMetadata`: never a Secret's values): its finalizers,
/// its controller, whether it is being deleted.
struct KubeObjectMeta: Equatable, Sendable {
    var finalizers: [String] = []
    /// The owner with `controller: true`: `ReplicaSet web-7d9f`.
    var controller: String?
    var deleting = false

    init(finalizers: [String] = [], controller: String? = nil, deleting: Bool = false) {
        self.finalizers = finalizers
        self.controller = controller
        self.deleting = deleting
    }

    init(_ object: [String: Any]) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        finalizers = metadata["finalizers"] as? [String] ?? []
        deleting = metadata["deletionTimestamp"] != nil
        let owners = metadata["ownerReferences"] as? [[String: Any]] ?? []
        if let owner = owners.first(where: { $0["controller"] as? Bool == true }), let kind = owner["kind"] as? String, let name = owner["name"] as? String {
            controller = "\(kind) \(name)"
        }
    }
}

extension KubeClient {
    static let metadataAccept = "application/json;as=PartialObjectMetadata;g=meta.k8s.io;v=v1"

    /// One write, refused here unless the connection's context is writable
    /// for this session. Never retried: a 429 from an eviction is a
    /// PodDisruptionBudget saying no. The answer's body isn't kept — a
    /// deleted Secret's would carry its values.
    @discardableResult
    func write(_ request: KubeWriteRequest) async throws -> Int {
        guard connection.writable else { throw KubeWriteRefused(reason: "This context is read-only: Overterm changes nothing here.") }
        let response: HTTPResponse
        do {
            response = try await connection.write(
                request.method, request.path, body: request.body, headers: [("Content-Type", request.contentType), ("Accept", "application/json")])
        } catch {
            throw Self.mapped(error, signIn: connection.signIn)
        }
        if (200..<300).contains(response.status) { return response.status }
        if let problem = KubeProxyProblem.classify(
            status: response.status, contentType: response.header("Content-Type"), text: String(decoding: response.body.prefix(4096), as: UTF8.self),
            stderr: "", signIn: connection.signIn)
        {
            throw problem
        }
        throw KubeAPIError.from(response)
    }

    /// Whether this user may do `access` in `namespace`: a
    /// SelfSubjectAccessReview through the (writable) context's socket.
    func review(_ access: KubeAccess, namespace: String?, name: String? = nil) async -> KubeCanIAnswer {
        let request = KubeWrites.review(access, namespace: namespace, name: name)
        guard connection.writable else { return .failed("The context is read-only: its socket takes no access review.") }
        do {
            let response = try await connection.write(
                request.method, request.path, body: request.body, headers: [("Content-Type", request.contentType), ("Accept", "application/json")])
            guard (200..<300).contains(response.status) else {
                if let problem = KubeProxyProblem.classify(
                    status: response.status, contentType: response.header("Content-Type"),
                    text: String(decoding: response.body.prefix(4096), as: UTF8.self), stderr: "", signIn: connection.signIn)
                {
                    return .failed(problem.reason)
                }
                return .failed(KubeAPIError.from(response).message)
            }
            return KubeAccessReview.parse(response.body)
        } catch {
            return .failed(KubernetesModel.said(Self.mapped(error, signIn: connection.signIn)))
        }
    }

    /// An object's metadata alone — its finalizers, its owner — never its
    /// data: a Secret's values stay unread.
    func metadata(_ ref: KubeObjectRef) async throws -> KubeObjectMeta {
        let response = try await get(KubeWrites.path(ref), accept: Self.metadataAccept)
        return KubeObjectMeta((try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:])
    }

    /// What the `scale` subresource says the replicas are.
    func replicas(_ ref: KubeObjectRef) async throws -> Int {
        let response = try await get(KubeWrites.path(ref) + "/scale")
        let object = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
        return ((object["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue ?? 0
    }
}

/// A write's error said plainly — the API's 403, 404, 409, 422, an
/// eviction's 429 — or what it did. Pure.
enum KubeWriteOutcome {
    /// `pod shop/web-7d9`, `deployment shop/web`, `node fake-node-1`.
    static func spoken(_ ref: KubeObjectRef) -> String {
        let kind = ref.kind.kind.isEmpty ? ref.kind.singular : ref.kind.kind.lowercased()
        return "\(kind) \(ref.namespace.map { "\($0)/" } ?? "")\(ref.name)"
    }

    static func done(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, from: Int? = nil, replicas: Int? = nil) -> String {
        let object = spoken(ref)
        switch verb {
        case .delete: return "Deleted \(object) in \(ref.context)."
        case .recreate: return "Deleted \(object) in \(ref.context): its controller makes it again."
        case .forceDelete: return "Force deleted \(object) in \(ref.context)."
        case .removeFinalizers: return "Removed \(object)'s finalizers in \(ref.context)."
        case .evict: return "Evicted \(object) in \(ref.context)."
        case .restart: return "Restarted \(object)'s rollout in \(ref.context)."
        case .scale:
            let to = replicas.map(String.init) ?? "?"
            return "Scaled \(object) " + (from.map { "from \($0) " } ?? "") + "to \(to) in \(ref.context)."
        }
    }

    static func failed(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, _ error: Error) -> String {
        let object = spoken(ref)
        if let refused = error as? KubeWriteRefused { return refused.reason }
        if let problem = error as? KubeProxyProblem { return "\(object): \(problem.reason)" }
        guard let api = error as? KubeAPIError else { return "Couldn't \(verb.label.lowercased()) \(object): \(error.localizedDescription)" }
        switch api.status {
        case 403: return "\(ref.context) refused it — you may not \(verb.label.lowercased()) \(object): \(api.message)"
        case 404: return "\(object) isn't there any more: nothing to \(verb.label.lowercased())."
        case 409: return "\(object) changed meanwhile: \(api.message) — look again and retry."
        case 422: return "The cluster wouldn't take it: \(api.message)"
        case 429 where verb == .evict:
            return "A PodDisruptionBudget doesn't allow evicting \(object) now: \(api.message) — try later, or delete it."
        case 429: return "The cluster is busy (429): \(api.message) — try again."
        default: return "Couldn't \(verb.label.lowercased()) \(object) (HTTP \(api.status)): \(api.message)"
        }
    }
}

/// What the confirmation says (rule 3): the context and namespace —
/// production in capitals —, the object, what will happen, the kubectl
/// command it equals, what it warns of, and the name to type where rule 4
/// says. Its answer is checked here, not in the window. Pure.
struct KubeWriteConfirmation: Equatable, Sendable {
    var verb: KubeWriteVerb
    var title: String
    /// The context and namespace, drawn on their own line — in production's
    /// red on production (`WriteConfirmation`).
    var scope: String
    var detail: String
    var button: String
    /// The name to type before the button counts; nil when none is asked.
    var typedName: String?
    var production: Bool
    var kubectl: String?

    /// How a production scope begins, wherever one is asked.
    static let productionMark = "PRODUCTION · "

    /// Whether what was typed confirms it.
    func accepts(_ typed: String) -> Bool {
        guard let typedName else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines) == typedName
    }

    /// `from`/`to`: a scale's replicas; `meta`: what the pre-read found.
    static func make(
        _ verb: KubeWriteVerb, _ ref: KubeObjectRef, context: KubeContext, rule: KubeWriteRule, from: Int? = nil, to: Int? = nil,
        meta: KubeObjectMeta? = nil, discovery: KubeDiscovery? = nil
    ) -> KubeWriteConfirmation {
        let object = KubeWriteOutcome.spoken(ref)
        let place = (context.isProduction ? productionMark : "") + context.name + " · " + (ref.namespace.map { "namespace \($0)" } ?? "cluster-wide")
        let title: String
        let what: String
        let button: String
        switch verb {
        case .delete:
            title = "Delete \(object)?"
            what =
                "It is deleted in the background: what it owns goes after it."
                + (ref.kind.group.isEmpty && ref.kind.resource == "pods" ? " The pod stops after its grace period." : "")
            button = "Delete"
        case .recreate:
            title = "Delete \(object) so it is made again?"
            what =
                meta?.controller.map { "Its \($0) makes a new pod in its place, after this one's grace period." }
                ?? "It has no controller: nothing makes it again once it is deleted."
            button = "Delete Pod"
        case .forceDelete:
            title = "Force delete \(object)?"
            what = "It goes at once: no grace period."
            button = "Force Delete"
        case .removeFinalizers:
            title = "Remove \(object)'s finalizers?"
            what = "Its finalizers: " + (meta?.finalizers.joined(separator: ", ") ?? "—") + "." + (meta?.deleting == true ? " It is being deleted: it goes at once." : "")
            button = "Remove Finalizers"
        case .evict:
            title = "Evict \(object)?"
            what = "Through the eviction subresource, as kubectl drain does: it goes only if its PodDisruptionBudgets allow it now."
            button = "Evict"
        case .restart:
            title = "Restart \(object)'s rollout?"
            what = "Its pods are replaced as a rollout replaces them (the template's \(KubeWrites.restartedAt) annotation, as kubectl rollout restart sets it)."
            button = "Restart"
        case .scale:
            title = "Scale \(object)" + (from.map { " from \($0)" } ?? "") + " to \(to ?? 0) replicas?"
            what = to == 0 ? "Every one of its pods stops." : "Its controller adds or removes pods to match."
            button = "Scale"
        }
        var lines = [what]
        if let warning = rule.warning { lines.append("⚠︎ " + warning) }
        let kubectl = KubeWrites.kubectl(verb, ref, replicas: to, discovery: discovery)
        lines.append(kubectl.map { "Equals: \($0)" } ?? "kubectl drain evicts this way; no kubectl command evicts one pod.")
        let typed = rule.typedName ? ref.name : nil
        if let typed { lines.append("Type \(typed) to confirm.") }
        return KubeWriteConfirmation(
            verb: verb, title: title, scope: place, detail: lines.joined(separator: "\n"), button: button, typedName: typed, production: context.isProduction,
            kubectl: kubectl)
    }
}

/// How the last write stands, as the page says it.
enum KubeWriteStatus: Equatable {
    case working(String)
    case done(String)
    case failed(String)

    var text: String {
        switch self {
        case .working(let text), .done(let text), .failed(let text): text
        }
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }
}

/// The production contexts whose writes are on for this session (rule 2,
/// decision 4): in memory only, so a relaunch is read-only again, and kept
/// only while the context's name reaches the same cluster as the same
/// user (a kubeconfig read again may point it elsewhere). Pure.
struct KubeProductionWrites: Equatable, Sendable {
    /// Each one as it was read when its writes were turned on.
    private(set) var on: [String: KubeContext] = [:]

    func isOn(_ name: String) -> Bool { on[name] != nil }

    mutating func turnOn(_ context: KubeContext) {
        guard context.isProduction else { return }
        var kept = context
        kept.sessionWrites = false
        on[context.name] = kept
    }

    mutating func turnOff(_ name: String) { on[name] = nil }

    /// `list` with each production context's switch as it stands; those a
    /// kubeconfig read again no longer has, or points elsewhere, turned
    /// off — their names returned, for the proxies.
    mutating func apply(to list: inout KubeContextList) -> [String] {
        var dropped: [String] = []
        for (name, old) in on {
            guard let now = list.context(named: name), now.isProduction, KubernetesModel.sameAccess(old, now) else {
                on[name] = nil
                dropped.append(name)
                continue
            }
        }
        for index in list.contexts.indices {
            list.contexts[index].sessionWrites = list.contexts[index].isProduction && on[list.contexts[index].name] != nil
        }
        return dropped.sorted()
    }
}
