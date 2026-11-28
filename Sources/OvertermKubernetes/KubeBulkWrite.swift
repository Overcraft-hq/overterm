import Foundation

/// A write on several rows at once (K8S-G1), narrow by design: pods and
/// Jobs deleted, Deployments, StatefulSets and DaemonSets restarted — the
/// two people do by the dozen. Scale and Flux's suspend stay one at a time.
/// It goes the one guard path's way, all at once: the class check, an
/// access review for each namespace, one confirmation naming every object,
/// the count typed on production, then a request each, said one by one.
/// Pure.
package enum KubeBulkWrite {
    /// The most rows one write takes: past it, said, nothing sent.
    package static let maxObjects = 50

    /// The verbs several rows of `kind` are offered.
    package static func verbs(for kind: KubeResourceKind) -> [KubeWriteVerb] {
        let deletes = (kind.group.isEmpty && kind.resource == "pods") || (kind.group == "batch" && kind.resource == "jobs")
        var verbs: [KubeWriteVerb] = []
        if KubeWriteCheck.offered(.restart, on: kind) { verbs.append(.restart) }
        if deletes, KubeWriteCheck.offered(.delete, on: kind) { verbs.append(.delete) }
        return verbs
    }

    /// Why these rows can't take `verb` together; nil when they can. One
    /// context and one kind, as a page's list shows them; not past the cap.
    package static func refusal(_ verb: KubeWriteVerb, _ refs: [KubeObjectRef]) -> String? {
        guard refs.count > 1 else { return "Pick more than one row." }
        guard refs.count <= maxObjects else { return "\(refs.count) rows: at most \(maxObjects) at once — filter the list or pick fewer." }
        guard Set(refs.map(\.context)).count == 1, Set(refs.map(\.kind.fullName)).count == 1 else { return "The rows are of one context and one kind only." }
        guard let kind = refs.first?.kind, verbs(for: kind).contains(verb) else {
            return "\(verb.label) isn't done on several \(refs.first.map { $0.kind.resource } ?? "rows") at once."
        }
        return nil
    }

    /// The namespaces the rows are in, in their order: each asked its own access review.
    package static func namespaces(_ refs: [KubeObjectRef]) -> [String] {
        var seen: [String] = []
        for ref in refs where !seen.contains(ref.namespace ?? "") { seen.append(ref.namespace ?? "") }
        return seen
    }

    /// "10 pods", "1 Deployment".
    package static func counted(_ refs: [KubeObjectRef]) -> String {
        guard let kind = refs.first?.kind else { return "nothing" }
        return refs.count == 1 ? KubeWriteOutcome.spoken(refs[0]) : "\(refs.count) \(kind.resource)"
    }

    /// How many names the confirmation lists before "and N more".
    package static let listed = 12

    /// The one question for all of them: every object named (the first
    /// `listed`, then how many more), where, the kubectl it equals, the
    /// rule's warning; on production the count typed.
    package static func confirmation(
        _ verb: KubeWriteVerb, _ refs: [KubeObjectRef], context: KubeContext, rule: KubeWriteRule, discovery: KubeDiscovery? = nil
    ) -> KubeWriteConfirmation {
        let spaces = namespaces(refs)
        let place =
            (context.isProduction ? KubeWriteConfirmation.productionMark : "") + context.name + " · "
            + (spaces.count == 1 ? (spaces[0].isEmpty ? "cluster-wide" : "namespace \(spaces[0])") : "\(spaces.count) namespaces")
        let names = refs.prefix(listed).map { ref in spaces.count > 1 ? "\(ref.namespace ?? "-")/\(ref.name)" : ref.name }
        let more = refs.count > listed ? "\n…and \(refs.count - listed) more." : ""
        let what: String
        let title: String
        let button: String
        switch verb {
        case .restart:
            title = "Restart \(counted(refs))?"
            what = "Each rolls out its pods again, one rollout each, as kubectl rollout restart does."
            button = "Restart \(refs.count)"
        default:
            title = "Delete \(counted(refs))?"
            what = "Each is deleted in the background: what it owns goes after it." + (refs.first?.kind.resource == "pods" ? " A pod stops after its grace period." : "")
            button = "Delete \(refs.count)"
        }
        let kubectl = spaces.count == 1 ? line(verb, refs, discovery: discovery) : "One kubectl a namespace: \(line(verb, Array(refs.prefix(1)), discovery: discovery))…"
        // Rule 4 on production: the count typed, a name standing for all of them.
        let typed = context.isProduction || rule.typedName ? "\(refs.count)" : nil
        // As one object's question is laid out: what it does, the warning, what it equals, what to type.
        var lines = [what, names.map { "• \($0)" }.joined(separator: "\n") + more]
        if let warning = rule.warning { lines.append("⚠︎ " + warning) }
        lines.append("Equals: \(kubectl)")
        if let typed { lines.append("Type \(typed) to confirm.") }
        let detail = lines.joined(separator: "\n\n")
        return KubeWriteConfirmation(
            verb: verb, title: title, scope: place, detail: detail, button: button,
            typedName: typed, production: context.isProduction, kubectl: kubectl,
            destroys: verb.destroys)
    }

    /// The kubectl the write equals, every name in it.
    package static func line(_ verb: KubeWriteVerb, _ refs: [KubeObjectRef], discovery: KubeDiscovery? = nil) -> String {
        guard let first = refs.first else { return "" }
        let resource = KubectlLine.resource(first.kind, in: discovery)
        var words: [String]
        switch verb {
        case .restart: words = ["kubectl", "rollout", "restart"] + refs.map { KubectlLine.quoted(resource + "/" + $0.name) }
        default: words = ["kubectl", "delete", KubectlLine.quoted(resource)] + refs.map { KubectlLine.quoted($0.name) }
        }
        words += ["--context", KubectlLine.quoted(first.context)]
        if let namespace = first.namespace { words += ["-n", KubectlLine.quoted(namespace)] }
        return words.joined(separator: " ")
    }

    /// What came of it, one object at a time: all done, or how many and
    /// which failed with why (the first three).
    package static func outcome(_ verb: KubeWriteVerb, _ results: [(ref: KubeObjectRef, error: String?)]) -> (done: Bool, said: String) {
        let failed = results.filter { $0.error != nil }
        let refs = results.map(\.ref)
        let did = verb == .restart ? "Restarted" : "Deleted"
        guard !failed.isEmpty else { return (true, "\(did) \(counted(refs)).") }
        let reasons = failed.prefix(3).map { "\($0.ref.name): \($0.error ?? "")" }.joined(separator: "; ")
        let rest = failed.count > 3 ? "; and \(failed.count - 3) more" : ""
        return (false, "\(did) \(results.count - failed.count) of \(counted(refs)). \(failed.count) failed — \(reasons)\(rest).")
    }
}
