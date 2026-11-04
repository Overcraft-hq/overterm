import Foundation

/// Copy as kubectl (`k`, the right-click menu, the detail's button): the
/// kubectl command that shows what the page shows — a list with its
/// namespace and the selectors sent to the server, one object's YAML, an
/// object's events — always with `--context`, so it runs against the
/// context on the page whatever kubectl's current one is
/// (docs/design/kubernetes/analysis.md, 3.14). It is only text for the
/// user to run: copying is offered on every class, production too.
///
/// Every word that isn't ours is quoted for zsh (and any POSIX shell):
/// bare when it is only letters, digits and `_ . / : @ + , -` with no `=`
/// or `-` in front, else in single quotes — where zsh expands nothing, not
/// `!`, `*`, `$` or `~` — a quote inside as `'\''`. A command never holds
/// a Secret's value: it names objects and selectors, nothing read from one,
/// and a Secret's own command is `describe`, which prints its keys' sizes
/// as the masked detail does, not `-o yaml`, which would print them. Pure.
enum KubectlLine {
    /// The list: `kubectl --context C get deploy -n NS -l app=web --field-selector status.phase=Running`.
    static func list(
        context: String, kind: KubeResourceKind, scope: KubeScope, selectors: KubeListSelectors = KubeListSelectors(), wide: Bool = false,
        discovery: KubeDiscovery? = nil
    ) -> String {
        var words = ["kubectl", "--context", quoted(context), "get", quoted(resource(kind, in: discovery))]
        if kind.namespaced {
            switch scope {
            case .all: words.append("-A")
            case .namespace(let name): words += ["-n", quoted(name)]
            }
        }
        if let label = selectors.label { words += ["-l", quoted(label)] }
        if let field = selectors.field { words += ["--field-selector", quoted(field)] }
        if wide { words += ["-o", "wide"] }
        return words.joined(separator: " ")
    }

    /// One object as the detail's YAML shows it:
    /// `kubectl --context C -n NS get deploy NAME -o yaml` — a Secret
    /// `describe`d instead, its values left out.
    static func object(_ ref: KubeObjectRef, discovery: KubeDiscovery? = nil) -> String {
        var words = ["kubectl", "--context", quoted(ref.context)]
        if let namespace = ref.namespace { words += ["-n", quoted(namespace)] }
        if ref.isSecret {
            words += ["describe", quoted(resource(ref.kind, in: discovery)), quoted(ref.name)]
        } else {
            words += ["get", quoted(resource(ref.kind, in: discovery)), quoted(ref.name), "-o", "yaml"]
        }
        return words.joined(separator: " ")
    }

    /// An object's events, as its Events tab lists them:
    /// `kubectl --context C -n NS events --for deploy/NAME`. A cluster-wide
    /// object's (a node's) are in whichever namespace reported them: `-A`,
    /// after `events` — it is that command's flag, not a global one like
    /// `--context` and `-n`, and kubectl refuses it before the subcommand.
    static func events(for ref: KubeObjectRef, discovery: KubeDiscovery? = nil) -> String {
        var words = ["kubectl", "--context", quoted(ref.context)]
        if let namespace = ref.namespace { words += ["-n", quoted(namespace)] }
        words.append("events")
        if ref.namespace == nil { words.append("-A") }
        words += ["--for", quoted(resource(ref.kind, in: discovery) + "/" + ref.name)]
        return words.joined(separator: " ")
    }

    /// What kubectl is told the kind is: the core group's short name (it
    /// wins in kubectl's lookup: `po`, `svc`, `cm`); a built-in group's
    /// short name or plural where no other kind served claims it
    /// (`deploy`, `cronjobs`); else `plural.group`, which can mean only
    /// one (`events.events.k8s.io` beside the core's events, every CRD's —
    /// `widgets.example.com`).
    static func resource(_ kind: KubeResourceKind, in discovery: KubeDiscovery?) -> String {
        if kind.group.isEmpty { return kind.shortNames.first ?? kind.resource }
        guard KubeKindCatalog.isBuiltIn(group: kind.group) else { return kind.fullName }
        let others = (discovery?.kinds ?? []).filter { $0.fullName != kind.fullName }
        func claimed(_ name: String) -> Bool { others.contains { $0.resource == name || $0.singular == name || $0.shortNames.contains(name) } }
        if let short = kind.shortNames.first, !claimed(short) { return short }
        return claimed(kind.resource) ? kind.fullName : kind.resource
    }

    /// A word as zsh reads it back unchanged.
    static func quoted(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        let bare = word.unicodeScalars.allSatisfy { safe.contains($0) } && !word.hasPrefix("=") && !word.hasPrefix("-")
        if bare { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What stays bare: no glob, expansion, history, quote or separator character.
    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@+,-=")
}
