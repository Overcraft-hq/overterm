import Foundation

/// One source of an Argo CD Application (`spec.source`, or one of
/// `spec.sources` — a multi-source Application), and the one reader of the
/// singular/plural pairs Argo writes (docs/design/kubernetes/gitops.md,
/// 1.1): a single-source Application says `revision`, `source` and
/// `sourceType`; a multi-source one leaves those empty and says
/// `revisions[]`, `sources[]` and `sourceTypes[]` — in `status.sync`,
/// `status.operationState.syncResult`, each `status.history[]` entry and
/// `status.sourceType(s)` alike. Whatever reads a revision reads it here,
/// so neither form comes back empty. Pure.
struct KubeGitOpsSource: Equatable, Sendable {
    /// As the Application says it — a URL may carry userinfo, so it is
    /// shown only where the tree already shows it.
    var repoURL: String
    var path: String?
    var chart: String?
    var targetRevision: String?
    /// A values-only source (`ref: values`), read by another one's `$values/…`.
    var ref: String?

    /// `chart`, else `path`: where in the repository.
    var place: String? { chart ?? path }

    /// The Application's sources, in order: `spec.sources`, else
    /// `spec.source` as one. A source with no `repoURL` is kept (its
    /// index is what `revisions[i]` pairs with).
    static func all(in spec: [String: Any]) -> [KubeGitOpsSource] {
        maps(spec, "source", "sources").map { map in
            KubeGitOpsSource(
                repoURL: map["repoURL"] as? String ?? "", path: nonEmpty(map["path"]), chart: nonEmpty(map["chart"]),
                targetRevision: nonEmpty(map["targetRevision"]), ref: nonEmpty(map["ref"]))
        }
    }

    /// The revisions a map says — `revisions[]` when it has any, else its
    /// one `revision` —, one per source in a multi-source Application.
    /// Empty strings kept in place (a source with nothing fetched yet keeps
    /// its index); nothing at all is `[]`.
    static func revisions(_ map: [String: Any]?) -> [String] {
        guard let map else { return [] }
        if let list = map["revisions"] as? [Any], !list.isEmpty { return list.map { $0 as? String ?? "" } }
        if let one = map["revision"] as? String, !one.isEmpty { return [one] }
        return []
    }

    /// `sourceType` or `sourceTypes[]` (Helm, Kustomize, Directory, Plugin).
    static func sourceTypes(_ map: [String: Any]?) -> [String] {
        guard let map else { return [] }
        if let list = map["sourceTypes"] as? [Any], !list.isEmpty { return list.map { $0 as? String ?? "" } }
        if let one = map["sourceType"] as? String, !one.isEmpty { return [one] }
        return []
    }

    /// The revision for the source at `index`: its own from `revisions[]`,
    /// else the single `revision` when there is only one source.
    static func revision(_ map: [String: Any]?, source index: Int) -> String? {
        let all = revisions(map)
        guard all.indices.contains(index) else { return nil }
        return all[index].isEmpty ? nil : all[index]
    }

    /// What Argo has applied: the last `history` entry's revision(s), else
    /// the last operation's `syncResult`'s. `status.sync`'s is what git has
    /// now, which may not be applied yet.
    static func applied(_ status: [String: Any]) -> [String] {
        if let last = (status["history"] as? [[String: Any]])?.last {
            let said = revisions(last)
            if !said.isEmpty { return said }
        }
        return revisions((status["operationState"] as? [String: Any])?["syncResult"] as? [String: Any])
    }

    /// What git has now, as Argo last compared it (`status.sync`).
    static func wanted(_ status: [String: Any]) -> [String] { revisions(status["sync"] as? [String: Any]) }

    /// `key`'s map as a one-element list, else `plural`'s list of maps.
    private static func maps(_ map: [String: Any], _ key: String, _ plural: String) -> [[String: Any]] {
        if let list = map[plural] as? [[String: Any]], !list.isEmpty { return list }
        if let one = map[key] as? [String: Any] { return [one] }
        return []
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
