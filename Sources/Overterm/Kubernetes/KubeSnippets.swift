import Foundation

/// Kubernetes snippets (decision 18, k9s's plugins.yaml): a snippet of the
/// Snippets store whose command names `${context}`, `${namespace}`,
/// `${pod}`, `${container}`, `${name}` or `${kind}` is offered in the
/// page's verb menu, those filled from the object picked — each value
/// quoted for zsh — and typed into a tab pinned to its context and
/// namespace, as a pod's shell is. They are the user's own commands, not a
/// plugin API: whatever they do is the user's kubectl with the user's
/// rights, so on production each is asked first, the filled line shown.
/// `{{name}}` placeholders are still asked for as any snippet's are. Pure.
enum KubeSnippet {
    static let placeholders = ["context", "namespace", "pod", "container", "name", "kind"]

    /// The Kubernetes placeholders `command` names.
    static func uses(_ command: String) -> Set<String> {
        Set(placeholders.filter { command.contains("${\($0)}") })
    }

    static func isKubernetes(_ snippet: Snippet) -> Bool { !uses(snippet.command).isEmpty }

    /// Offered on `ref`: a pod's placeholders only on a pod, a namespace's
    /// only where there is one (a namespaced object, or the namespace shown).
    static func offered(_ snippet: Snippet, on ref: KubeObjectRef, shownNamespace: String?) -> Bool {
        let used = uses(snippet.command)
        guard !used.isEmpty else { return false }
        if !used.isDisjoint(with: ["pod", "container"]), !ref.isPod { return false }
        if used.contains("namespace"), namespace(of: ref, shown: shownNamespace) == nil { return false }
        return true
    }

    /// The namespace a snippet runs in: the object's, a Namespace's own
    /// name, else the one shown.
    static func namespace(of ref: KubeObjectRef, shown: String?) -> String? {
        if ref.kind.group.isEmpty, ref.kind.resource == "namespaces" { return ref.name }
        return ref.namespace ?? shown
    }

    /// The values for `ref` (`container` given when the snippet uses it).
    static func values(for ref: KubeObjectRef, namespace: String?, container: String?, discovery: KubeDiscovery? = nil) -> [String: String] {
        var values = ["context": ref.context, "name": ref.name, "kind": KubectlLine.resource(ref.kind, in: discovery)]
        if let namespace { values["namespace"] = namespace }
        if ref.isPod { values["pod"] = ref.name }
        if let container { values["container"] = container }
        return values
    }

    /// `command` with each placeholder it names replaced by its value,
    /// quoted for zsh — a name with a space or a quote stays one word, and
    /// nothing in it is expanded. A placeholder without a value is left as
    /// it is (zsh then expands it to nothing, which kubectl refuses). One
    /// pass over the command as written: a value is never read again, so
    /// one holding `${namespace}` stays that text, inside its own quotes.
    static func fill(_ command: String, values: [String: String]) -> String {
        var result = ""
        var rest = Substring(command)
        while let open = rest.range(of: "${") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.firstIndex(of: "}"), case let name = String(after[..<close]), placeholders.contains(name), let value = values[name] {
                result += KubectlLine.quoted(value)
                rest = after[after.index(after: close)...]
            } else {
                result += "${"
                rest = after
            }
        }
        return result + rest
    }

    /// A placeholder the snippet names that has no value here.
    static func missing(_ command: String, values: [String: String]) -> [String] {
        placeholders.filter { command.contains("${\($0)}") && values[$0] == nil }
    }
}
