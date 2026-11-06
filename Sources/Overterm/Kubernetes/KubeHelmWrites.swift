import Foundation

/// A Helm write (stage 2f — docs/design/kubernetes/analysis.md, 2.12,
/// Section 5 and decision 15): a release rolled back to a revision picked
/// from its history, or uninstalled. Each is `helm` in a terminal tab
/// pinned to the context — its output and its waiting are helm's, the
/// user sees what ran and can run it again —, never a request of
/// Overterm's: a writing process (`KubeProcessVerb.writes`), refused on a
/// read-only context by the process class check, its access reviewed
/// where it can be (the release's records, and the kinds its manifest
/// names once it was read), confirmed in the window naming the context
/// and namespace — the release's name typed for a rollback on production
/// and for an uninstall on every class (rule 4) —, then typed into the tab
/// with `--kube-context` and `-n` always (rule 7), every word not ours
/// quoted for zsh. A release kept in ConfigMaps says so to helm
/// (`HELM_DRIVER=configmap`); Helm 2's (Tiller's) are refused. Pure.
enum KubeHelmWrite: Equatable, Sendable, KubeTabCommand {
    /// `helm rollback NAME REVISION`: a new revision made from `revision`'s
    /// chart and values; `from`, the one it is at now, for the confirmation.
    case rollback(release: String, namespace: String, storage: KubeHelmStorage, revision: Int, from: Int)
    /// `helm uninstall NAME`: every resource the release made, and its
    /// records (`revisions` of them), deleted.
    case uninstall(release: String, namespace: String, storage: KubeHelmStorage, revisions: Int)

    var verb: KubeProcessVerb {
        switch self {
        case .rollback: .helmRollback
        case .uninstall: .helmUninstall
        }
    }

    /// The release's name — what rule 4 asks to be typed.
    var name: String {
        switch self {
        case .rollback(let release, _, _, _, _), .uninstall(let release, _, _, _): release
        }
    }

    var namespace: String {
        switch self {
        case .rollback(_, let namespace, _, _, _), .uninstall(_, let namespace, _, _): namespace
        }
    }

    var storage: KubeHelmStorage {
        switch self {
        case .rollback(_, _, let storage, _, _), .uninstall(_, _, let storage, _): storage
        }
    }

    var refused: String? { Self.refusal(name: name, storage: storage) }

    /// Why a release kept there can't be changed by Overterm's helm: nil when it can.
    static func refusal(_ storage: KubeHelmStorage) -> String? {
        storage == .tiller
            ? "A Helm 2 (Tiller) release: Helm 3's helm can't change it. helm 2to3 moves it to Helm 3's storage first." : nil
    }

    /// Why the release named so, kept there, can't be changed: its name
    /// one helm itself wouldn't have made, else its storage's refusal.
    static func refusal(name: String, storage: KubeHelmStorage) -> String? {
        if !isReleaseName(name) {
            return "\"\(name)\" isn't a name helm gives a release (lowercase letters, digits, - and ., at most \(maxNameLength)): "
                + "Overterm types nothing for it."
        }
        return refusal(storage)
    }

    /// The longest name helm installs a release with.
    static let maxNameLength = 53

    /// Helm's own check of a release's name (`chartutil.ValidateReleaseName`):
    /// DNS-1123 subdomain, at most 53 characters. The name goes before the
    /// flags in `line`, so this is what keeps one from being read as a flag
    /// (`-x`, `--kubeconfig=…`) — a quoted word reaches helm unquoted.
    static func isReleaseName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.first, let last = part.last else { return false }
            let alnum: (Character) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            return alnum(first) && alnum(last) && part.allSatisfy { alnum($0) || $0 == "-" }
        }
    }

    /// helm's settings from the shell that would send a write elsewhere than
    /// the context the confirmation named — another server, token, user or
    /// group, another CA — taken off for the one command: the user's rc
    /// files run after a pinned tab's environment is set, so only the line
    /// itself can be sure.
    static let unsetForWrites = [
        "HELM_KUBEAPISERVER", "HELM_KUBETOKEN", "HELM_KUBEASUSER", "HELM_KUBEASGROUPS", "HELM_KUBECAFILE", "HELM_KUBEINSECURE_SKIP_TLS_VERIFY",
        "HELM_KUBETLS_SERVER_NAME",
    ]

    /// What goes before `helm` in every write's line: those settings
    /// unset, and the driver always said — the store the diff read and the
    /// review checked, whatever `HELM_DRIVER` the shell exports.
    /// `env -u HELM_KUBEAPISERVER … HELM_DRIVER=secret`.
    static func prefix(_ storage: KubeHelmStorage) -> [String] {
        ["env"] + unsetForWrites.flatMap { ["-u", $0] } + ["HELM_DRIVER=" + (storage == .configMap ? "configmap" : "secret")]
    }

    /// `env -u HELM_KUBEAPISERVER … HELM_DRIVER=secret helm rollback 'web' 1 --kube-context C -n NS`.
    func line(context: String) -> String {
        let q = KubeCommands.quoted
        var words = Self.prefix(storage)
        switch self {
        case .rollback(let release, _, _, let revision, _): words += ["helm", "rollback", q(release), String(revision)]
        case .uninstall(let release, _, _, _): words += ["helm", "uninstall", q(release)]
        }
        words += ["--kube-context", q(context), "-n", q(namespace)]
        return words.joined(separator: " ")
    }

    /// `release shop/web`.
    var spoken: String { "Helm release \(namespace)/\(name)" }

    // MARK: Access

    /// What the cluster's access review is asked first: the release's
    /// records — a rollback writes a new one and marks the old one
    /// superseded, an uninstall marks them, then deletes them.
    static func accesses(_ verb: KubeProcessVerb, storage: KubeHelmStorage, namespace: String) -> [(access: KubeAccess, namespace: String?)] {
        let resource = storage == .secret ? "secrets" : "configmaps"
        let verbs: [String] =
            switch verb {
            case .helmRollback: ["create", "update"]
            case .helmUninstall: ["update", "delete"]
            default: []
            }
        return verbs.map { (KubeAccess(verb: $0, resource: resource), namespace) }
    }

    /// The most kinds of a manifest whose access is reviewed: a chart's
    /// usual dozen kinds is a dozen reviews, asked one after another.
    static let reviewedKinds = 8

    /// What the release's own resources need — a rollback patches them,
    /// an uninstall deletes them — for the kinds its manifest names that
    /// the server serves (`discovery`), each where it lives: the release's
    /// namespace, or across the cluster. Only from a manifest already read
    /// (reading one is reading a Secret: never only for this); a kind the
    /// server doesn't serve is helm's to say.
    static func resourceAccesses(_ verb: KubeProcessVerb, manifest: String, discovery: KubeDiscovery?, namespace: String) -> [(
        access: KubeAccess, namespace: String?
    )] {
        guard let discovery, verb == .helmRollback || verb == .helmUninstall else { return [] }
        let action = verb == .helmRollback ? "patch" : "delete"
        var seen = Set<String>()
        var out: [(access: KubeAccess, namespace: String?)] = []
        for (group, kind) in manifestKinds(manifest) {
            guard let served = discovery.kinds.first(where: { $0.group == group && $0.kind == kind }) else { continue }
            let resource = served.group.isEmpty ? served.resource : "\(served.resource).\(served.group)"
            guard seen.insert(resource).inserted else { continue }
            out.append((KubeAccess(verb: action, resource: resource), served.namespaced ? namespace : nil))
            if out.count == reviewedKinds { break }
        }
        return out
    }

    /// The group and kind of each document of a manifest as the detail
    /// shows it (`KubeHelmMask.manifest`: `---` documents, their top-level
    /// keys at the line's start), in order; a list's or a document without
    /// both left out.
    static func manifestKinds(_ manifest: String) -> [(group: String, kind: String)] {
        var out: [(group: String, kind: String)] = []
        var apiVersion: String?
        var kind: String?
        func flush() {
            if let apiVersion, let kind, !kind.hasSuffix("List") {
                let group = apiVersion.contains("/") ? String(apiVersion[..<apiVersion.firstIndex(of: "/")!]) : ""
                out.append((group, kind))
            }
            apiVersion = nil
            kind = nil
        }
        func value(_ line: Substring, _ key: String) -> String? {
            guard line.hasPrefix(key + ":") else { return nil }
            let text = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            let unquoted = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" || line.hasPrefix("--- ") {
                flush()
            } else if apiVersion == nil, let found = value(line, "apiVersion") {
                apiVersion = found
            } else if kind == nil, let found = value(line, "kind") {
                kind = found
            }
        }
        flush()
        return out
    }

    // MARK: The revision

    /// What a rollback may go to: every revision but the latest, newest
    /// first, at most `limit` (a sheet's buttons) — 9, every earlier one
    /// helm keeps by default (`--history-max` 10).
    static func choices(_ release: KubeHelmRelease, limit: Int = 9) -> [KubeHelmRecord] {
        Array(release.history.filter { $0.revision != release.revision }.prefix(limit))
    }

    /// Whether `revision` is one the release can roll back to: any kept
    /// revision but the latest, whatever the sheet's limit (a History row's).
    static func canRollBack(_ release: KubeHelmRelease, to revision: Int) -> Bool {
        revision != release.revision && release.history.contains { $0.revision == revision }
    }

    /// `Revision 1 — superseded · 3h ago · Install complete`.
    static func label(_ record: KubeHelmRecord, summary: String?, now: Date) -> String {
        var text = "Revision \(record.revision) — \(record.status)"
        if let updated = record.updated { text += " · \(KubeAge.format(max(0, now.timeIntervalSince(updated)))) ago" }
        if let summary, !summary.isEmpty { text += " · " + summary }
        return text
    }

    // MARK: Words

    static func title(_ verb: KubeProcessVerb) -> String {
        verb == .helmUninstall ? "Uninstall in a Tab…" : "Roll Back in a Tab…"
    }

    static func label(_ verb: KubeProcessVerb) -> String {
        verb == .helmUninstall ? "Uninstall" : "Roll Back"
    }

    static func symbol(_ verb: KubeProcessVerb) -> String {
        verb == .helmUninstall ? "trash" : "clock.arrow.circlepath"
    }

    /// What the confirmation says (rule 3): the context and namespace —
    /// production in capitals —, what happens, the command the tab runs,
    /// and the name to type where `rule` asks it.
    func confirmation(context: KubeContext, rule: KubeProcessRule) -> KubeWriteConfirmation {
        let command = line(context: context.name)
        let place = (context.isProduction ? KubeWriteConfirmation.productionMark : "") + context.name + " · namespace \(namespace)"
        let title: String
        let what: String
        let button: String
        switch self {
        case .rollback(_, _, _, let revision, let from):
            title = "Roll back \(spoken) to revision \(revision)?"
            what =
                "helm makes revision \(from + 1) from revision \(revision)'s chart and values (it is at \(from) now): "
                + "the resources go back to what revision \(revision) had, hooks run, and helm history keeps both."
            button = "Roll Back in a Tab"
        case .uninstall(_, _, _, let revisions):
            title = "Uninstall \(spoken)?"
            what =
                "helm deletes every resource the release made, runs its delete hooks, and deletes its history "
                + "(\(revisions) revision\(revisions == 1 ? "" : "s")): it can't be rolled back after."
            button = "Uninstall in a Tab"
        }
        var lines = [what]
        if storage == .configMap { lines.append("Its records are ConfigMaps, so helm is told so (HELM_DRIVER=configmap).") }
        lines.append("Runs in a new tab pinned to \(context.displayName): \(command)")
        let typed = rule.typedName ? name : nil
        if let typed { lines.append("Type \(typed) to confirm.") }
        return KubeWriteConfirmation(
            verb: nil, title: title, scope: place, detail: lines.joined(separator: "\n"), button: button, typedName: typed,
            production: context.isProduction, kubectl: command)
    }

    /// What the page says once its tab is open.
    func opened(context: String) -> String {
        switch self {
        case .rollback(_, _, _, let revision, _): "Rolling back \(spoken) to revision \(revision) in a new tab, in \(context)."
        case .uninstall: "Uninstalling \(spoken) in a new tab, in \(context)."
        }
    }
}
