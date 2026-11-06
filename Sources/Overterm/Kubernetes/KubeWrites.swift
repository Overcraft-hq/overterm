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
    /// A Deployment's rollout paused: `spec.paused` (kubectl rollout pause).
    case pause
    /// …and resumed.
    case resume
    /// A CronJob run now: a Job made from its `jobTemplate`, as `kubectl
    /// create job --from=cronjob/…` makes it.
    case trigger
    /// A CronJob's schedule suspended: `spec.suspend`.
    case suspend
    /// …and resumed.
    case unsuspend
    /// A node marked unschedulable: `spec.unschedulable` (kubectl cordon).
    case cordon
    /// …and schedulable again.
    case uncordon
    /// A namespace made: the page's, not a row's (`N`, its sheet).
    case createNamespace

    var title: String {
        switch self {
        case .delete: "Delete…"
        case .recreate: "Delete to Recreate…"
        case .forceDelete: "Force Delete…"
        case .removeFinalizers: "Remove Finalizers…"
        case .evict: "Evict…"
        case .restart: "Rollout Restart…"
        case .scale: "Scale…"
        case .pause: "Pause Rollout…"
        case .resume: "Resume Rollout…"
        case .trigger: "Trigger Now…"
        case .suspend: "Suspend…"
        case .unsuspend: "Resume Schedule…"
        case .cordon: "Cordon…"
        case .uncordon: "Uncordon…"
        case .createNamespace: "New Namespace…"
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
        case .pause: "Pause"
        case .resume, .unsuspend: "Resume"
        case .trigger: "Trigger"
        case .suspend: "Suspend"
        case .cordon: "Cordon"
        case .uncordon: "Uncordon"
        case .createNamespace: "Create"
        }
    }

    var symbol: String {
        switch self {
        case .delete, .forceDelete: "trash"
        case .recreate, .restart: "arrow.clockwise"
        case .removeFinalizers: "scissors"
        case .evict: "arrow.up.forward.square"
        case .scale: "plusminus"
        case .pause, .suspend: "pause.circle"
        case .resume, .unsuspend: "play.circle"
        case .trigger: "play.fill"
        case .cordon: "nosign"
        case .uncordon: "checkmark.circle"
        case .createNamespace: "plus.square.dashed"
        }
    }

    /// What a verb that sets a state sets (`KubeWriteToggle`): pause,
    /// suspend, cordon true; their opposites false.
    var toggle: (KubeWriteToggle, Bool)? {
        switch self {
        case .pause: (.paused, true)
        case .resume: (.paused, false)
        case .suspend: (.suspended, true)
        case .unsuspend: (.suspended, false)
        case .cordon: (.unschedulable, true)
        case .uncordon: (.unschedulable, false)
        default: nil
        }
    }

    /// Pause's resume, cordon's uncordon: the same state the other way.
    var opposite: KubeWriteVerb? {
        switch self {
        case .pause: .resume
        case .resume: .pause
        case .suspend: .unsuspend
        case .unsuspend: .suspend
        case .cordon: .uncordon
        case .uncordon: .cordon
        default: nil
        }
    }
}

/// A state a verb turns on or off, each a field of the object's spec: a
/// Deployment's rollout paused, a CronJob suspended, a node unschedulable.
/// Read from the object whole (never a Secret: these kinds have no
/// values to hide), or from a row's cells where the server's Table says
/// it (a CronJob's Suspend, a node's Status). Pure.
enum KubeWriteToggle: String, Sendable {
    case paused, suspended, unschedulable

    var field: String {
        switch self {
        case .paused: "paused"
        case .suspended: "suspend"
        case .unschedulable: "unschedulable"
        }
    }

    /// The object's spec says it.
    func state(of object: [String: Any]) -> Bool {
        ((object["spec"] as? [String: Any])?[field] as? Bool) == true
    }

    /// What a row's cells say, where the server's columns say it; nil where
    /// they don't (a Deployment's rows don't say it's paused).
    func state(cells: [String: String]) -> Bool? {
        switch self {
        case .paused: nil
        case .suspended: cells["Suspend"].flatMap { ["true": true, "false": false][$0.lowercased()] }
        case .unschedulable: cells["Status"].map { $0.split(separator: ",").contains("SchedulingDisabled") }
        }
    }

    /// `deployment shop/web is paused already.`
    func already(_ on: Bool, _ object: String) -> String {
        switch (self, on) {
        case (.paused, true): "\(object)'s rollout is paused already."
        case (.paused, false): "\(object)'s rollout isn't paused."
        case (.suspended, true): "\(object) is suspended already."
        case (.suspended, false): "\(object) isn't suspended."
        case (.unschedulable, true): "\(object) is cordoned already."
        case (.unschedulable, false): "\(object) isn't cordoned."
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
        // kubectl rollout pause takes Deployments only.
        case .pause, .resume: return kind.group == "apps" && kind.resource == "deployments" && kind.verbs.contains("patch")
        // The CronJob is read whole for its jobTemplate.
        case .trigger: return isCronJob(kind) && kind.verbs.contains("get")
        case .suspend, .unsuspend: return isCronJob(kind) && kind.verbs.contains("patch")
        case .cordon, .uncordon: return kind.group.isEmpty && kind.resource == "nodes" && kind.verbs.contains("patch")
        case .createNamespace: return isNamespace(kind) && kind.verbs.contains("create")
        }
    }

    static func isCronJob(_ kind: KubeResourceKind) -> Bool { kind.group == "batch" && kind.resource == "cronjobs" }
    static func isNamespace(_ kind: KubeResourceKind) -> Bool { kind.group.isEmpty && kind.resource == "namespaces" }

    /// What the access review is asked: `delete pods`, `patch deployments.apps/scale`, `create pods/eviction`.
    static func access(_ verb: KubeWriteVerb, on kind: KubeResourceKind) -> KubeAccess {
        switch verb {
        case .delete, .recreate, .forceDelete: KubeAccess(verb: "delete", resource: kind.fullName)
        case .removeFinalizers, .restart, .pause, .resume, .suspend, .unsuspend, .cordon, .uncordon: KubeAccess(verb: "patch", resource: kind.fullName)
        case .evict: KubeAccess(verb: "create", resource: "pods/eviction")
        case .scale: KubeAccess(verb: "patch", resource: kind.fullName + "/scale")
        // What is made is a Job, in the CronJob's namespace.
        case .trigger: KubeAccess(verb: "create", resource: "jobs.batch")
        case .createNamespace: KubeAccess(verb: "create", resource: "namespaces")
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
            // Not in rule 4's list: each is undone by its opposite (a
            // triggered Job by deleting it), and asked all the same.
            case .evict, .restart, .pause, .resume, .trigger, .suspend, .unsuspend, .cordon, .uncordon, .createNamespace: false
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

    /// A state's field set, as kubectl sets it: rollout pause and cordon
    /// as a strategic merge patch, their opposites with the field taken
    /// away (`null`: false is its default and kubectl's patch omits it); a
    /// CronJob's `suspend` as a merge patch, false said, as `kubectl patch`
    /// would be typed.
    static func toggle(_ ref: KubeObjectRef, _ toggle: KubeWriteToggle, on: Bool) -> KubeWriteRequest {
        switch toggle {
        case .suspended:
            return KubeWriteRequest(method: .PATCH, path: managed(path(ref)), body: encode(["spec": ["suspend": on]]), contentType: mergePatch)
        case .paused, .unschedulable:
            let value: Any = on ? true : NSNull()
            return KubeWriteRequest(method: .PATCH, path: managed(path(ref)), body: encode(["spec": [toggle.field: value]]), contentType: strategicPatch)
        }
    }

    static let instantiate = "cronjob.kubernetes.io/instantiate"

    /// A manual run's name: the CronJob's, `-manual-` and five characters,
    /// within a Job's 63 (a CronJob's own may be 52).
    static func manualJobName(_ cronJob: String, suffix: String) -> String {
        let tail = "-manual-" + suffix
        var head = String(cronJob.prefix(63 - tail.count))
        while head.hasSuffix("-") || head.hasSuffix(".") { head.removeLast() }
        return head + tail
    }

    /// Five characters a Job name may hold.
    static func randomSuffix() -> String { String((0..<5).map { _ in "bcdfghjklmnpqrstvwxz2456789".randomElement()! }) }

    /// `kubectl create job <name> --from=cronjob/<c>`, as kubectl makes the
    /// Job: the CronJob's `jobTemplate` spec, its labels, its annotations
    /// over `cronjob.kubernetes.io/instantiate: manual`, and the CronJob as
    /// its controller (so it is listed among the CronJob's jobs), blocking
    /// its owner's foreground deletion as `metav1.NewControllerRef` does. Nil when
    /// the object isn't a CronJob with a jobTemplate.
    static func trigger(_ ref: KubeObjectRef, cronJob object: [String: Any], job name: String) -> KubeWriteRequest? {
        guard let metadata = object["metadata"] as? [String: Any], let uid = metadata["uid"] as? String,
            let template = (object["spec"] as? [String: Any])?["jobTemplate"] as? [String: Any], let spec = template["spec"] as? [String: Any]
        else { return nil }
        let own = template["metadata"] as? [String: Any] ?? [:]
        var annotations: [String: Any] = [instantiate: "manual"]
        for (key, value) in own["annotations"] as? [String: Any] ?? [:] { annotations[key] = value }
        var jobMetadata: [String: Any] = [
            "name": name, "annotations": annotations,
            "ownerReferences": [["apiVersion": "batch/v1", "kind": "CronJob", "name": ref.name, "uid": uid, "controller": true, "blockOwnerDeletion": true]],
        ]
        if let namespace = ref.namespace { jobMetadata["namespace"] = namespace }
        if let labels = own["labels"] as? [String: Any], !labels.isEmpty { jobMetadata["labels"] = labels }
        let job: [String: Any] = ["apiVersion": "batch/v1", "kind": "Job", "metadata": jobMetadata, "spec": spec]
        let jobs = "/apis/batch/v1" + (ref.namespace.map { "/namespaces/\(KubePath.segment($0))" } ?? "") + "/jobs"
        return KubeWriteRequest(method: .POST, path: managed(jobs), body: encode(job), contentType: "application/json")
    }

    /// A namespace made, nothing but its name.
    static func createNamespace(_ ref: KubeObjectRef) -> KubeWriteRequest {
        let namespace: [String: Any] = ["apiVersion": "v1", "kind": "Namespace", "metadata": ["name": ref.name]]
        return KubeWriteRequest(method: .POST, path: managed(ref.kind.path()), body: encode(namespace), contentType: "application/json")
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
    /// `job`: a trigger's Job name.
    static func kubectl(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, replicas: Int? = nil, job: String? = nil, discovery: KubeDiscovery? = nil) -> String? {
        let resource = KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery))
        let name = KubectlLine.quoted(ref.name)
        let slash = KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery) + "/" + ref.name)
        var words: [String]
        switch verb {
        case .delete, .recreate: words = ["kubectl", "delete", resource, name]
        case .forceDelete: words = ["kubectl", "delete", resource, name, "--grace-period=0", "--force"]
        case .removeFinalizers:
            words = ["kubectl", "patch", resource, name, "--type=json", "-p", KubectlLine.quoted(#"[{"op":"remove","path":"/metadata/finalizers"}]"#)]
        case .evict: return nil
        case .restart: words = ["kubectl", "rollout", "restart", KubectlLine.quoted(KubectlLine.resource(ref.kind, in: discovery) + "/" + ref.name)]
        case .scale:
            words = ["kubectl", "scale", slash, "--replicas=\(replicas ?? 0)"]
        case .pause: words = ["kubectl", "rollout", "pause", slash]
        case .resume: words = ["kubectl", "rollout", "resume", slash]
        case .trigger: words = ["kubectl", "create", "job", KubectlLine.quoted(job ?? ref.name + "-manual"), "--from=cronjob/" + KubectlLine.quoted(ref.name)]
        case .suspend, .unsuspend:
            // A merge patch, as it is sent: kubectl's default is a strategic one.
            words = ["kubectl", "patch", resource, name, "--type=merge", "-p", KubectlLine.quoted(#"{"spec":{"suspend":\#(verb == .suspend)}}"#)]
        case .cordon: words = ["kubectl", "cordon", name]
        case .uncordon: words = ["kubectl", "uncordon", name]
        case .createNamespace: words = ["kubectl", "create", "namespace", name]
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

/// What a namespace holds, as its delete warns of it: counts from Tables
/// of rows alone, per kind, and the kinds that couldn't be counted — a
/// 403 apart from any other failure. Only the kinds in `wanted`: said as
/// a lower bound, since custom resources, roles, policies… go with it
/// too. Pure.
struct KubeNamespaceContents: Equatable, Sendable {
    struct Count: Equatable, Sendable {
        var kind: KubeResourceKind
        var count: Int
        /// A further page without the server's count of it: "500+".
        var atLeast = false

        var said: String {
            "\(count)\(atLeast ? "+" : "") " + (count == 1 && !atLeast ? (kind.singular.isEmpty ? kind.resource : kind.singular) : kind.resource)
        }
    }

    var counts: [Count] = []
    /// Kinds the server wouldn't list here (a 403): not said as none.
    var forbidden: [String] = []
    /// Kinds whose list failed some other way (a timeout, a 5xx, the
    /// proxy gone): not said as none, nor as refused.
    var uncounted: [String] = []

    /// The kinds counted, in this order, as far as the server serves them.
    static let wanted = [
        "pods", "deployments.apps", "statefulsets.apps", "daemonsets.apps", "jobs.batch", "cronjobs.batch", "services", "ingresses.networking.k8s.io",
        "persistentvolumeclaims", "configmaps", "secrets", "serviceaccounts",
    ]

    /// The kinds to count; nil while what the server serves isn't known.
    static func kinds(in discovery: KubeDiscovery?) -> [KubeResourceKind]? {
        guard let discovery else { return nil }
        return wanted.compactMap { name in discovery.kinds.first { $0.fullName == name && $0.namespaced && $0.canList } }
    }

    /// A kind's list failed: refused (a 403), or not answered.
    mutating func failed(_ kind: KubeResourceKind, _ error: Error) {
        if (error as? KubeAPIError)?.isForbidden == true { forbidden.append(kind.resource) } else { uncounted.append(kind.resource) }
    }

    /// `Among the kinds Overterm counts, it holds 3 pods, 1 deployment and
    /// 2 secrets.` — and what it may hold besides.
    var said: String {
        var text: String
        if counts.isEmpty {
            text = forbidden.isEmpty && uncounted.isEmpty ? "It holds none of the kinds Overterm counts." : "Overterm counted none of what it holds."
        } else {
            let parts = counts.map(\.said)
            text = "Among the kinds Overterm counts, it holds " + (parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!) + "."
        }
        if !forbidden.isEmpty { text += " Not counted (not allowed to list): " + forbidden.joined(separator: ", ") + "." }
        if !uncounted.isEmpty { text += " Couldn't be counted: " + uncounted.joined(separator: ", ") + "." }
        return text + " Whatever else it holds — custom resources, roles, policies… — goes with it too."
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

    /// An object whole, as JSON — only for the kinds whose writes need
    /// their spec (a Deployment, a CronJob, a node), never a Secret.
    func spec(_ ref: KubeObjectRef) async throws -> [String: Any] {
        guard !(ref.kind.group.isEmpty && ref.kind.resource == "secrets") else { throw KubeWriteRefused(reason: "A Secret is never read for a write.") }
        let object = try await object(ref.kind, namespace: ref.namespace, name: ref.name)
        return (try? JSONSerialization.jsonObject(with: object.data) as? [String: Any]) ?? [:]
    }

    /// How many objects of `kind` a namespace holds: one Table page of
    /// rows alone (`includeObject=None`, so not a Secret's metadata
    /// either), and the server's count of the rest (`remainingItemCount`).
    func count(_ kind: KubeResourceKind, in namespace: String, limit: Int = 500) async throws -> KubeNamespaceContents.Count {
        let path = KubePath.query(kind.path(namespace: namespace), [("limit", String(limit)), ("includeObject", "None")])
        let page = try KubeTableReader.read(try await get(path, accept: Self.tableAccept).body, namespace: namespace)
        let more = page.continueToken != nil
        return KubeNamespaceContents.Count(kind: kind, count: page.rows.count + (page.remainingItemCount ?? 0), atLeast: more && page.remainingItemCount == nil)
    }

    /// What a namespace holds, kind by kind — what its delete takes with
    /// it; nil while the context's discovery isn't known. A row each, with
    /// the server's count of the rest; a page of 500 only where the
    /// server gives no count.
    func contents(of namespace: String, discovery: KubeDiscovery?) async -> KubeNamespaceContents? {
        guard let kinds = KubeNamespaceContents.kinds(in: discovery) else { return nil }
        var contents = KubeNamespaceContents()
        for kind in kinds {
            do {
                var count = try await count(kind, in: namespace, limit: 1)
                if count.atLeast { count = try await self.count(kind, in: namespace) }
                if count.count > 0 { contents.counts.append(count) }
            } catch {
                contents.failed(kind, error)
            }
        }
        return contents
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

    static func done(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, from: Int? = nil, replicas: Int? = nil, job: String? = nil) -> String {
        let object = spoken(ref)
        switch verb {
        case .pause: return "Paused \(object)'s rollout in \(ref.context)."
        case .resume: return "Resumed \(object)'s rollout in \(ref.context)."
        case .trigger: return "Triggered \(object) in \(ref.context): job \(ref.namespace.map { "\($0)/" } ?? "")\(job ?? "?") made."
        case .suspend: return "Suspended \(object) in \(ref.context): no Job is scheduled until it is resumed."
        case .unsuspend: return "Resumed \(object)'s schedule in \(ref.context)."
        case .cordon: return "Cordoned \(object) in \(ref.context): no new pod is scheduled on it."
        case .uncordon: return "Uncordoned \(object) in \(ref.context)."
        case .createNamespace: return "Made namespace \(ref.name) in \(ref.context)."
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
        case 409 where verb == .createNamespace: return "\(object) is there already: \(api.message)"
        case 409 where verb == .trigger: return "That Job's name is taken already: \(api.message) — trigger it again."
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
    /// The request's verb; nil for a write that runs as kubectl in a tab (`KubeTabWrite`).
    var verb: KubeWriteVerb?
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
        meta: KubeObjectMeta? = nil, job: String? = nil, contents: KubeNamespaceContents? = nil, discovery: KubeDiscovery? = nil
    ) -> KubeWriteConfirmation {
        let object = KubeWriteOutcome.spoken(ref)
        let place = (context.isProduction ? productionMark : "") + context.name + " · " + (ref.namespace.map { "namespace \($0)" } ?? "cluster-wide")
        let title: String
        let what: String
        let button: String
        switch verb {
        case .delete where KubeWriteCheck.isNamespace(ref.kind):
            title = "Delete \(object) and everything in it?"
            what = contents?.said ?? "What it holds wasn't counted."
            button = "Delete Namespace"
        case .delete:
            title = "Delete \(object)?"
            what =
                "It is deleted in the background: what it owns goes after it."
                + (ref.kind.group.isEmpty && ref.kind.resource == "pods" ? " The pod stops after its grace period." : "")
            button = "Delete"
        case .pause:
            title = "Pause \(object)'s rollout?"
            what = "A change to its pod template no longer rolls out until it is resumed (spec.paused); its pods keep running."
            button = "Pause"
        case .resume:
            title = "Resume \(object)'s rollout?"
            what = "A pod template changed while it was paused rolls out now."
            button = "Resume"
        case .trigger:
            title = "Trigger \(object) now?"
            what =
                "Job \(job ?? "?") is made from its jobTemplate, owned by the CronJob and marked "
                + "\(KubeWrites.instantiate)=manual, as kubectl create job --from makes it. Its schedule is unchanged."
            button = "Trigger"
        case .suspend:
            title = "Suspend \(object)?"
            what = "No Job is scheduled until it is resumed; Jobs running now go on."
            button = "Suspend"
        case .unsuspend:
            title = "Resume \(object)'s schedule?"
            what = "Its next run is scheduled again. A run it missed while suspended may start at once, within its startingDeadlineSeconds."
            button = "Resume"
        case .cordon:
            title = "Cordon \(object)?"
            what = "No new pod is scheduled on it (spec.unschedulable); the pods on it keep running — drain evicts them."
            button = "Cordon"
        case .uncordon:
            title = "Uncordon \(object)?"
            what = "Pods may be scheduled on it again."
            button = "Uncordon"
        case .createNamespace:
            title = "Create \(object)?"
            what = "An empty namespace, nothing but its name."
            button = "Create"
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
        let kubectl = KubeWrites.kubectl(verb, ref, replicas: to, job: job, discovery: discovery)
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
    var isWorking: Bool { if case .working = self { true } else { false } }
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

/// A new namespace's name, checked as the API server checks it: an RFC
/// 1123 DNS label — lowercase letters, digits and `-`, starting and ending
/// with a letter or digit, at most 63 characters. Pure.
enum KubeNamespaceName {
    /// Why `name` won't do; nil when it will.
    static func problem(_ name: String) -> String? {
        if name.isEmpty { return "A name, please." }
        if name.count > 63 { return "At most 63 characters (this is \(name.count))." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        if let bad = name.first(where: { !allowed.contains($0) }) {
            return bad.isUppercase
                ? "Lowercase only: \(name.lowercased())?" : "Only lowercase letters, digits and - (not \(bad == " " ? "a space" : "“\(bad)”"))."
        }
        if name.hasPrefix("-") || name.hasSuffix("-") { return "It must start and end with a letter or a digit." }
        return nil
    }
}

/// `N`: a new namespace's name, before the write is asked for.
struct KubeNamespaceDraft: Equatable {
    /// The context it is made in: the one shown as the sheet opened.
    var context: String
    var name = ""
    /// Why what is typed won't do.
    var problem: String?
}
