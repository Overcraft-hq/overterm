import CryptoKit
import Foundation

/// "Compare with…" (docs/design/kubernetes/analysis.md, 3.10): the same
/// kind and name in another context or namespace — staging against
/// production — each side one GET through its own context's proxy, both
/// stripped and masked, as a diff in the changes pane. Pure.
///
/// - **Stripped**: what the server keeps for itself (status, managedFields,
///   the last-applied annotation) and what names this one copy of it (its
///   uid, resourceVersion, creation time, generation, namespace, its
///   owners' uids) — they differ wherever the object lives.
/// - **Masked**: env values whose names look secret, a URL's password,
///   `*** (before)` / `*** (after)` where one differs (`KubeManifestDiff.masked`).
/// - **A Secret**: its keys, and each value as a hash keyed for this one
///   comparison (HMAC-SHA256 under a key made for it and dropped with it):
///   the same value on both sides is the same hash, and no hash can be
///   looked up or compared with any other. The values are replaced as the
///   answer is read; nothing of them is kept.
enum KubeCompare {
    /// One side: where it was read.
    struct Side: Equatable, Hashable, Sendable {
        var context: String
        var namespace: String?
        var production: Bool

        /// `fake-dev/shop`, `fake-dev` for a cluster-wide object.
        var said: String { namespace.map { "\(context)/\($0)" } ?? context }
    }

    /// What names one copy of an object, left out on both sides.
    static let identity = ["uid", "resourceVersion", "creationTimestamp", "generation", "selfLink", "namespace", "managedFields"]

    /// An object as it is compared: stripped (`KubeManifestDiff.stripped`)
    /// and without what names this copy of it.
    static func comparable(_ object: [String: Any]) -> [String: Any] {
        var object = KubeManifestDiff.stripped(object)
        if var metadata = object["metadata"] as? [String: Any] {
            for key in identity { metadata[key] = nil }
            if let owners = metadata["ownerReferences"] as? [[String: Any]] {
                metadata["ownerReferences"] = owners.map { owner in
                    var owner = owner
                    owner["uid"] = nil
                    return owner
                }
            }
            object["metadata"] = metadata
        }
        return object
    }

    /// A Secret's values, each its keyed hash: `hmac:1a2b3c4d5e6f`.
    static func hashingSecret(_ object: [String: Any], key: SymmetricKey) -> [String: Any] {
        guard KubeObjectStrip.isSecret(object) else { return object }
        var object = object
        for field in ["data", "stringData"] {
            guard let values = object[field] as? [String: Any] else { continue }
            object[field] = values.mapValues { value -> String in
                let text = (value as? String) ?? "\(value)"
                let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
                return "hmac:" + mac.prefix(6).map { String(format: "%02x", $0) }.joined()
            }
        }
        // Whatever an annotation held of the values is gone with it.
        return comparable(object)
    }

    /// One side's answer, read: nil when it isn't an object. A Secret's
    /// values are hashed as it is read.
    static func side(_ body: Data, key: SymmetricKey) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["metadata"] is [String: Any] else { return nil }
        return KubeObjectStrip.isSecret(object) ? hashingSecret(object, key: key) : comparable(object)
    }

    /// The two answers compared: `left` the object the detail shows,
    /// `right` the other side's — nil where it has none (a 404). Each read
    /// and hashed under a key made here and dropped here.
    static func diff(ref: KubeObjectRef, kind: String, left: Data, right: Data?, from: Side, to: Side) -> KubeChangeDiff? {
        let key = SymmetricKey(size: .bits256)
        guard let a = side(left, key: key) else { return nil }
        let b = right.flatMap { side($0, key: key) }
        return diff(ref: ref, kind: kind, left: a, right: b, rightMissing: right == nil, from: from, to: to)
    }

    /// Two sides already read (`side`): masked together, as YAML, diffed.
    static func diff(ref: KubeObjectRef, kind: String, left: [String: Any], right: [String: Any]?, rightMissing: Bool, from: Side, to: Side) -> KubeChangeDiff {
        let secret = KubeObjectStrip.isSecret(left) || right.map(KubeObjectStrip.isSecret) == true
        // A Secret's values are hashes already; anything else's env masked together.
        let (a, b): ([String: Any]?, [String: Any]?) = secret ? (left, right) : KubeManifestDiff.masked(before: left, after: right)
        let file = "\(kind.lowercased())-\(ref.name).yaml"
        let unified = KubeManifestDiff.unified(
            before: KubeYAML.text(a ?? [:]), after: b.map { KubeYAML.text($0) } ?? "", from: "\(from.said)/\(file)", to: rightMissing ? "/dev/null" : "\(to.said)/\(file)")
        let change: KubeHelmDiffItem.Change = rightMissing ? .removed : unified.text.isEmpty ? .unchanged : .modified
        let item = KubeHelmDiffItem(
            id: "compare/\(ref.kind.fullName)/\(ref.name)", kind: kind, name: ref.name, namespace: from.namespace, file: file, change: change, diff: unified.text,
            added: unified.added, removed: unified.removed, group: ref.kind.group)
        let spoken = "\(kind.lowercased())/\(ref.name)"
        let across = from.context == to.context ? "\(from.namespace ?? "") ↔ \(to.namespace ?? "")" : "\(from.said) ↔ \(to.said)"
        var label = "\(spoken) in \(from.said) against \(to.said), one GET each through its context's proxy"
        if rightMissing {
            label += " — \(to.said) has no \(spoken)."
        } else if secret {
            label += " — its keys, and each value as a hash keyed for this comparison alone: the same hash is the same value; no value is shown or kept."
        } else {
            label += " — stripped (status, managedFields, what names each copy); env values that look secret masked, *** (before) and *** (after) where one differs."
        }
        return KubeChangeDiff(
            id: "compare/\(from.said)/\(to.said)/\(ref.kind.fullName)/\(ref.name)", title: "\(spoken): \(across)",
            context: from.context == to.context ? from.context : "\(from.context) ↔ \(to.context)", production: from.production || to.production, label: label,
            diff: KubeHelmDiff(items: [item], withheld: 0, secrets: secret ? 1 : 0))
    }
}
