import Foundation

/// One field of a GitOps object an apply changes that decides what its
/// controller deploys, where, or whether it deletes (docs/design/kubernetes/
/// gitops.md, 1.1 row 9, G0d): `.spec.prune: false → true`. Its values said
/// without a URL's userinfo, a map by its scalar leaves, a `kubeConfig` by
/// its reference's name alone. Pure.
struct KubeGitOpsChange: Equatable, Sendable {
    /// What kind of change it is: what the confirmation warns of.
    enum Field: Equatable, Sendable {
        case prune, autoSync, source, path, destination, suspend
    }

    var field: Field
    /// `.spec.prune`, `.spec.template.spec.source.repoURL`.
    var path: String
    var before: String
    var after: String

    /// `.spec.prune: false → true`.
    var said: String { "\(path): \(before) → \(after)" }
}

/// What an apply or a YAML save changes in an Argo CD Application or
/// ApplicationSet, a Flux Kustomization or HelmRelease, against the live
/// object (gitops.md 1.1 row 9, G0d): its prune, its destination
/// (`destination`, `targetNamespace`, `kubeConfig`), its source (`repoURL`,
/// `path`, `chart`, `sourceRef`, `chartRef`), its suspension or Argo CD's
/// auto-sync. Each is a mass delete or a redeploy, so the confirmation
/// names each change and the name is typed on every class. Only those
/// paths are read — never a value, a parameter or a patch. Pure.
enum KubeGitOpsApply {
    typealias Tool = KubeGitOpsDelete.Tool

    /// How a field is read.
    private enum Read {
        /// A boolean, absent being false.
        case flag
        /// A string, a URL without its userinfo.
        case text
        /// A map's scalar leaves, sorted: `kind=GitRepository, name=fleet`.
        case map
        /// Only which Secret or ConfigMap it names.
        case reference
        /// Argo CD's `automated`: on when there, unless `enabled: false` (Argo CD 3).
        case autoSync
        /// `spec.sources`: each one's repository and place.
        case sources
    }

    private struct Watched {
        var path: [String]
        var field: KubeGitOpsChange.Field
        var read: Read
    }

    private static func argo(_ base: [String]) -> [Watched] {
        [
            Watched(path: base + ["source", "repoURL"], field: .source, read: .text),
            Watched(path: base + ["source", "path"], field: .path, read: .text),
            Watched(path: base + ["source", "chart"], field: .path, read: .text),
            Watched(path: base + ["sources"], field: .source, read: .sources),
            Watched(path: base + ["destination", "server"], field: .destination, read: .text),
            Watched(path: base + ["destination", "name"], field: .destination, read: .text),
            Watched(path: base + ["destination", "namespace"], field: .destination, read: .text),
            Watched(path: base + ["syncPolicy", "automated"], field: .autoSync, read: .autoSync),
            Watched(path: base + ["syncPolicy", "automated", "prune"], field: .prune, read: .flag),
        ]
    }

    private static func watched(_ tool: Tool) -> [Watched] {
        switch tool {
        case .application: argo(["spec"])
        case .applicationSet: argo(["spec", "template", "spec"])
        case .kustomization:
            [
                Watched(path: ["spec", "prune"], field: .prune, read: .flag),
                Watched(path: ["spec", "deletionPolicy"], field: .prune, read: .text),
                Watched(path: ["spec", "path"], field: .path, read: .text),
                Watched(path: ["spec", "sourceRef"], field: .source, read: .map),
                Watched(path: ["spec", "targetNamespace"], field: .destination, read: .text),
                Watched(path: ["spec", "kubeConfig"], field: .destination, read: .reference),
                Watched(path: ["spec", "suspend"], field: .suspend, read: .flag),
            ]
        case .helmRelease:
            [
                Watched(path: ["spec", "chart", "spec", "chart"], field: .path, read: .text),
                Watched(path: ["spec", "chart", "spec", "sourceRef"], field: .source, read: .map),
                Watched(path: ["spec", "chartRef"], field: .source, read: .map),
                Watched(path: ["spec", "targetNamespace"], field: .destination, read: .text),
                Watched(path: ["spec", "kubeConfig"], field: .destination, read: .reference),
                Watched(path: ["spec", "suspend"], field: .suspend, read: .flag),
            ]
        }
    }

    /// The GitOps kind `kind` is, among the four whose apply is watched.
    static func tool(_ kind: KubeResourceKind) -> Tool? { KubeGitOpsDelete.tool(kind) }

    /// What changes from `live` to `after` (the dry run's answer, or the
    /// file merged over the live object): nothing for a new object — it
    /// replaces nothing.
    static func changes(_ tool: Tool, live: [String: Any]?, after: [String: Any]) -> [KubeGitOpsChange] {
        guard let live else { return [] }
        var out: [KubeGitOpsChange] = []
        for watch in watched(tool) {
            let before = said(value(live, watch.path), watch.read)
            let now = said(value(after, watch.path), watch.read)
            guard before != now else { continue }
            out.append(KubeGitOpsChange(field: watch.field, path: "." + watch.path.joined(separator: "."), before: shown(before), after: shown(now)))
        }
        return out
    }

    /// The confirmation's warning: each change named, then what it does.
    static func warning(_ changes: [KubeGitOpsChange], tool: Tool, after: [String: Any], spoken: String) -> String? {
        guard !changes.isEmpty else { return nil }
        let fields = Set(changes.map(\.field))
        var text = "\(spoken)'s source, destination, prune or suspension changes: " + changes.map(\.said).joined(separator: "; ") + "."
        let moved = !fields.isDisjoint(with: [.source, .path, .destination])
        switch tool {
        case .application, .applicationSet:
            let base = tool == .application ? ["spec"] : ["spec", "template", "spec"]
            let automated = said(value(after, base + ["syncPolicy", "automated"]), .autoSync) == "on"
            let prunes = automated && said(value(after, base + ["syncPolicy", "automated", "prune"]), .flag) == "true"
            if fields.contains(.autoSync), automated { text += " With auto-sync on, Argo CD syncs it from git at once." }
            if prunes, moved || fields.contains(.prune) || fields.contains(.autoSync) {
                text += " With auto-sync's prune on, Argo CD deletes whatever it manages that the new spec doesn't make."
            } else if moved {
                text += " Argo CD deploys from the new spec; what the old one made and the new one doesn't is left out of sync."
            }
            if tool == .applicationSet { text += " Every Application it generates changes with it." }
        case .kustomization:
            // deletionPolicy is for its own delete (G0b); a reconcile prunes by spec.prune alone.
            let prunes = said(value(after, ["spec", "prune"]), .flag) == "true"
            let suspended = said(value(after, ["spec", "suspend"]), .flag) == "true"
            if fields.contains(.suspend) { text += suspended ? " Suspended, Flux applies nothing from its source." : " Resumed, Flux applies what its source holds now." }
            if prunes, !suspended, moved || fields.contains(.prune) || fields.contains(.suspend) {
                text += " With prune on, Flux deletes whatever it applied that the new spec doesn't make."
            } else if moved, !suspended {
                text += " Flux applies the new spec; what the old one made stays, no longer managed."
            }
        case .helmRelease:
            let suspended = said(value(after, ["spec", "suspend"]), .flag) == "true"
            if fields.contains(.suspend) {
                text += suspended ? " Suspended, Flux upgrades nothing." : " Resumed, Flux upgrades the release to what its chart's source holds now."
            }
            if moved, !suspended { text += " Flux upgrades or reinstalls the release from the new spec." }
        }
        return text
    }

    // MARK: Reading

    static func value(_ object: [String: Any], _ path: [String]) -> Any? {
        var current: Any? = object
        for key in path {
            guard let map = current as? [String: Any] else { return nil }
            current = map[key]
        }
        return current is NSNull ? nil : current
    }

    /// The value as compared and shown; "" when unset.
    private static func said(_ value: Any?, _ read: Read) -> String {
        switch read {
        case .flag:
            return ((value as? Bool) ?? false) ? "true" : "false"
        case .text:
            return value.map { text("\($0)") } ?? ""
        case .map:
            guard let map = value as? [String: Any] else { return value.map { text("\($0)") } ?? "" }
            return leaves(map).joined(separator: ", ")
        case .reference:
            guard let map = value as? [String: Any] else { return value == nil ? "" : "set" }
            for key in ["secretRef", "configMapRef"] {
                if let name = (map[key] as? [String: Any])?["name"] as? String { return "\(key) \(text(name))" }
            }
            return "set"
        case .autoSync:
            guard let map = value as? [String: Any] else { return value == nil ? "off" : "on" }
            return (map["enabled"] as? Bool) == false ? "off" : "on"
        case .sources:
            guard let list = value as? [Any] else { return "" }
            return list.map { item -> String in
                let map = item as? [String: Any] ?? [:]
                return ["repoURL", "path", "chart", "ref"].compactMap { key in (map[key] as? String).map { "\(key)=\(text($0))" } }.joined(separator: " ")
            }.joined(separator: " + ")
        }
    }

    /// `kind=GitRepository, name=fleet`: scalars only, a nested map's by its path.
    private static func leaves(_ map: [String: Any], prefix: String = "") -> [String] {
        var out: [String] = []
        for key in map.keys.sorted() {
            switch map[key] {
            case let inner as [String: Any]: out += leaves(inner, prefix: prefix + key + ".")
            case is [Any], is NSNull, nil: continue
            case let scalar?: out.append("\(prefix)\(key)=\(text("\(scalar)"))")
            }
        }
        return out
    }

    /// A string as said: no URL's userinfo, no credential, one line.
    private static func text(_ value: String) -> String {
        Secrets.scrubCredentials(GitRemoteURL.stripUserinfo(inText: GitRemoteURL.withoutUserinfo(value)))
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func shown(_ value: String) -> String {
        if value.isEmpty { return "(unset)" }
        return value.count > 120 ? String(value.prefix(119)) + "…" : value
    }
}

/// What resuming a Flux Kustomization or HelmRelease on production applies
/// (gitops.md 1.1 row 10, G0d): whatever its source holds now, possibly
/// many commits after what is applied, with prune. Read from the object
/// the review's toggle read decided Resume on, and from its source's
/// `status.artifact.revision` (one bounded GET, that field alone decoded).
/// A Kustomization with `spec.prune` has its name typed. Pure.
struct KubeFluxResume: Equatable, Sendable {
    var tool: KubeGitOpsDelete.Tool
    var prune = false
    /// What is applied now: a Kustomization's `lastAppliedRevision`, a HelmRelease's `history[0].chartVersion`.
    var applied: String?
    /// What was last tried, when it isn't what is applied.
    var attempted: String?
    /// The source it applies from: `gitrepository flux-system/fleet`.
    var source: String?
    /// What that source holds now.
    var next: String?
    /// Why the source's revision wasn't read; nil when it was.
    var unread: String?

    /// The two kinds whose resume applies something.
    static func tool(_ kind: KubeResourceKind) -> KubeGitOpsDelete.Tool? {
        switch KubeGitOpsDelete.tool(kind) {
        case .kustomization: .kustomization
        case .helmRelease: .helmRelease
        default: nil
        }
    }

    /// The facts the object says, and the source whose revision says what
    /// it applies (a HelmRelease's chart, as `flux` finds it).
    static func facts(_ object: [String: Any], tool: KubeGitOpsDelete.Tool, resource: String) -> (KubeFluxResume, KubeGitOps.FluxSource?) {
        var facts = KubeFluxResume(tool: tool)
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        facts.prune = tool == .kustomization && (spec["prune"] as? Bool) == true
        let lastApplied = nonEmpty(status["lastAppliedRevision"])
        if tool == .helmRelease, let history = status["history"] as? [[String: Any]], let head = history.first {
            facts.applied = nonEmpty(head["chartVersion"]) ?? lastApplied
        } else {
            facts.applied = lastApplied
        }
        let attempted = nonEmpty(status["lastAttemptedRevision"])
        if let attempted, attempted != facts.applied, attempted != lastApplied { facts.attempted = attempted }
        let source = KubeGitOps.sources(of: object, resource: resource)?.first
        facts.source = source?.spoken
        return (facts, source)
    }

    /// `main@sha1:c03f9aa0…` → `main@c03f9aa`; `sha256:` digests to 12; a chart version as it is.
    static func short(_ revision: String) -> String {
        var text = GitRemoteURL.stripUserinfo(inText: revision)
        if let range = text.range(of: "sha1:") {
            let hash = text[range.upperBound...].prefix(7)
            text = String(text[..<range.lowerBound]) + hash
        } else if let range = text.range(of: "sha256:") {
            let hash = text[range.upperBound...].prefix(12)
            text = String(text[..<range.lowerBound]) + "sha256:" + hash
        }
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    /// `a77b0d1` when it is on the same ref as `next` (`main@…`), else whole.
    private static func applied(_ applied: String, beside next: String?) -> String {
        let a = short(applied)
        guard let next, let at = a.firstIndex(of: "@") else { return a }
        let n = short(next)
        guard let nextAt = n.firstIndex(of: "@"), a[..<at] == n[..<nextAt] else { return a }
        return String(a[a.index(after: at)...])
    }

    /// The confirmation's warning.
    var said: String {
        var text: String
        let from = source.map { "what \($0) holds now" } ?? "what its source holds now"
        // Compared whole (`main@c03f9aa`), said short beside `next` (`c03f9aa`).
        let now = applied.map { Self.applied($0, beside: next) }
        let same = next.map { n in applied.map(Self.short) == Self.short(n) } ?? false
        switch tool {
        case .helmRelease:
            if let next, unread == nil {
                text = "Resuming upgrades it to \(from): chart \(Self.short(next))"
                text += now.map { same ? ", the version deployed now." : "; \($0) is deployed." } ?? "; nothing is deployed yet."
            } else {
                text = "Resuming upgrades it to whatever \(source ?? "its source") holds now (\(unread.map { "its version couldn't be read: \($0)" } ?? "unread"))"
                text += now.map { "; \($0) is deployed." } ?? "."
            }
        default:
            if let next, unread == nil {
                text = "Resuming applies \(from): applies \(Self.short(next))"
                text += now.map { same ? ", the revision applied now — what was changed by hand is put back." : "; \($0) is applied." } ?? "; nothing is applied yet."
            } else {
                text = "Resuming applies whatever \(source ?? "its source") holds now (\(unread.map { "its revision couldn't be read: \($0)" } ?? "unread"))"
                text += now.map { "; \($0) is applied." } ?? "."
            }
        }
        if let attempted { text += " \(Self.short(attempted)) was last attempted." }
        if prune { text += " spec.prune is on: whatever left the source since is deleted from the cluster." }
        return text
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A source's revision alone; nothing else of it is decoded.
    struct SourceWire: Decodable, Sendable {
        var status: Status?

        struct Status: Decodable, Sendable {
            var artifact: Artifact?
        }

        struct Artifact: Decodable, Sendable {
            var revision: String?
        }
    }

    static let sourceBytes = 4 << 20
}

extension KubeClient {
    /// What resuming `object` applies: its source's revision read once,
    /// bounded; a source not served, not named or not readable is said as
    /// unread, never no sentence.
    func fluxResume(_ object: [String: Any], ref: KubeObjectRef, discovery: KubeDiscovery?) async -> KubeFluxResume? {
        guard let tool = KubeFluxResume.tool(ref.kind) else { return nil }
        var (facts, source) = KubeFluxResume.facts(object, tool: tool, resource: ref.kind.fullName)
        guard let source else {
            facts.unread = "it names no source Overterm can read"
            return facts
        }
        guard let kind = discovery?.kinds.first(where: { $0.fullName == source.resource }) else {
            facts.unread = discovery == nil ? "what \(ref.context) serves isn't known yet" : "\(ref.context) serves no \(source.kind)"
            return facts
        }
        do {
            let data = try await get(KubeWrites.path(KubeObjectRef(context: ref.context, kind: kind, namespace: source.namespace, name: source.name)), maxBytes: KubeFluxResume.sourceBytes)
            let wire = try JSONDecoder().decode(KubeFluxResume.SourceWire.self, from: data)
            if let revision = wire.status?.artifact?.revision, !revision.isEmpty {
                facts.next = revision
            } else {
                facts.unread = "it has no artifact yet"
            }
        } catch {
            facts.unread = KubernetesModel.said(error)
        }
        return facts
    }
}
