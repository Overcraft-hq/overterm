import Foundation

// Stage 2b — docs/design/kubernetes/analysis.md, 2.8 and 3.3: a manifest in
// the editor (a resource's YAML opened with `y`, or a file of the
// checkout's) diffed against the cluster through a server-side apply with
// `dryRun=All`, and applied as a separate confirmed step. All of this file
// is pure: the session (`KubeManifestSession`) does the requests.

/// Why a manifest can't be diffed or applied as it stands.
struct KubeManifestProblem: Error, Equatable, LocalizedError, CustomStringConvertible {
    var message: String
    var errorDescription: String? { message }
    var description: String { message }

    init(_ message: String) { self.message = message }
}

/// One object of a manifest, as its file says it.
struct KubeManifestObject {
    var object: [String: Any]
    var apiVersion: String
    var kind: String
    var name: String
    /// `metadata.namespace`, when the file says one.
    var namespace: String?

    /// `apps` of `apps/v1`; the core group is "".
    var group: String { Self.parts(apiVersion)?.group ?? "" }
    var version: String { Self.parts(apiVersion)?.version ?? apiVersion }

    /// `apps/v1` as its group and version, `v1` as the core group's: nil
    /// for anything else — an empty half (`apps/`, `/v1`), three parts.
    /// `split` alone drops an empty half, and the version read past it
    /// took the app down (`k8s_apply`, Diff with Cluster).
    static func parts(_ apiVersion: String) -> (group: String, version: String)? {
        let pieces = apiVersion.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch pieces.count {
        case 1 where !pieces[0].isEmpty: return ("", pieces[0])
        case 2 where !pieces[0].isEmpty && !pieces[1].isEmpty: return (pieces[0], pieces[1])
        default: return nil
        }
    }
    var isSecret: Bool { group.isEmpty && kind == "Secret" }
    /// `deployment shop/web`, `namespace payments`.
    var spoken: String { "\(kind.lowercased()) \(namespace.map { "\($0)/" } ?? "")\(name)" }
}

/// A manifest's text read into its objects: YAML (several documents,
/// `---` between them) or JSON, a `List`'s items each an object. Pure.
enum KubeManifest {
    static func parse(_ text: String) throws -> [KubeManifestObject] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KubeManifestProblem("The manifest is empty: there is nothing to compare.") }
        let documents: [Any]
        if trimmed.first == "{", let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            documents = [json]
        } else if let yaml = YAMLReader.documents(text) {
            documents = yaml
        } else {
            throw KubeManifestProblem("The manifest isn't YAML Overterm can read whole: look for a stray indent or tab.")
        }
        var objects: [KubeManifestObject] = []
        for (index, document) in documents.enumerated() where !(document is NSNull) {
            guard let map = document as? [String: Any] else { throw KubeManifestProblem("Document \(index + 1) isn't an object.") }
            if (map["kind"] as? String)?.hasSuffix("List") == true, let items = map["items"] as? [Any] {
                for item in items {
                    guard let item = item as? [String: Any] else { throw KubeManifestProblem("An item of document \(index + 1)'s list isn't an object.") }
                    objects.append(try object(item, document: index + 1))
                }
            } else {
                objects.append(try object(map, document: index + 1))
            }
        }
        guard !objects.isEmpty else { throw KubeManifestProblem("The manifest holds no object.") }
        return objects
    }

    static func object(_ map: [String: Any], document: Int) throws -> KubeManifestObject {
        guard let apiVersion = map["apiVersion"] as? String, !apiVersion.isEmpty else {
            throw KubeManifestProblem("Document \(document) has no apiVersion.")
        }
        guard KubeManifestObject.parts(apiVersion) != nil else {
            throw KubeManifestProblem("Document \(document)'s apiVersion “\(apiVersion)” isn't group/version (apps/v1) or a version (v1).")
        }
        guard let kind = map["kind"] as? String, !kind.isEmpty else { throw KubeManifestProblem("Document \(document) has no kind.") }
        let metadata = map["metadata"] as? [String: Any] ?? [:]
        guard let name = metadata["name"] as? String, !name.isEmpty else {
            if metadata["generateName"] != nil {
                throw KubeManifestProblem("Document \(document)'s \(kind) has only a generateName: an apply needs its name, the same each time.")
            }
            throw KubeManifestProblem("Document \(document)'s \(kind) has no metadata.name.")
        }
        let namespace = (metadata["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return KubeManifestObject(object: map, apiVersion: apiVersion, kind: kind, name: name, namespace: namespace)
    }

    /// Whether a YAML file's text looks like a manifest: `apiVersion:` and
    /// `kind:` at the top level. Cheap — every YAML file opened is asked.
    static func looksLikeManifest(_ text: String) -> Bool {
        let head = text.prefix(64 * 1024)
        return head.range(of: #"(?m)^apiVersion:[ \t]*\S"#, options: .regularExpression) != nil
            && head.range(of: #"(?m)^kind:[ \t]*\S"#, options: .regularExpression) != nil
    }

    /// kustomize's own file names: the folder holding one is rendered.
    static let kustomizationNames: Set<String> = ["kustomization.yaml", "kustomization.yml", "Kustomization"]

    static func isKustomization(_ url: URL) -> Bool { kustomizationNames.contains(url.lastPathComponent) }

    /// Whether a file may be a manifest at all, by its name.
    static func isYAML(_ url: URL) -> Bool { ["yaml", "yml", "json"].contains(url.pathExtension.lowercased()) || isKustomization(url) }
}

/// The requests a server-side apply is, as kubectl makes them (`kubectl
/// apply --server-side`; docs/design/kubernetes/analysis.md, Section 4,
/// Writes): a PATCH of the object with `Content-Type:
/// application/apply-patch+yaml` and `fieldManager=overterm`, `dryRun=All`
/// for the diff, `force=true` only when asked again after a conflict. The
/// body is JSON, which is YAML. Pure.
enum KubeApply {
    static let contentType = "application/apply-patch+yaml"

    /// The kind an object is, as `discovery` serves it: its apiVersion's
    /// group and version, its Kind. Discovery holds each group's preferred
    /// version only: a manifest at another one the server serves
    /// (`autoscaling/v1`, a CRD's older version) is found once that
    /// version's list is added (`KubeManifestRun.served`).
    static func kind(of object: KubeManifestObject, in discovery: KubeDiscovery) -> KubeResourceKind? {
        discovery.kinds.first { $0.group == object.group && $0.version == object.version && $0.kind == object.kind }
    }

    /// Where the object goes: its kind as the context serves it, its
    /// namespace — the file's, else `fallback` (the page's, the context's
    /// own) — nil for a cluster-wide kind.
    static func ref(_ object: KubeManifestObject, context: String, discovery: KubeDiscovery, namespace fallback: String?) throws -> KubeObjectRef {
        guard let kind = kind(of: object, in: discovery) else {
            let served = discovery.kinds.filter { $0.kind == object.kind && $0.group == object.group }.map(\.groupVersion)
            throw KubeManifestProblem(
                "\(context) serves no \(object.kind) at \(object.apiVersion)" + (served.isEmpty ? "." : " — it has \(served.joined(separator: ", ")).")
            )
        }
        guard kind.verbs.contains("patch") else { throw KubeManifestProblem("\(context)'s \(kind.resource) can't be patched, so not applied.") }
        guard kind.namespaced else { return KubeObjectRef(context: context, kind: kind, namespace: nil, name: object.name) }
        guard let namespace = object.namespace ?? fallback else {
            throw KubeManifestProblem("\(object.spoken) names no namespace, and none is picked for it.")
        }
        return KubeObjectRef(context: context, kind: kind, namespace: namespace, name: object.name)
    }

    /// What is sent: the object as the file says it, in the namespace it
    /// goes to (none for a cluster-wide kind), without what the server keeps
    /// for itself (managedFields, status), with the resourceVersion it was
    /// opened at when given — a change since is a 409, not an overwrite.
    static func body(_ object: [String: Any], ref: KubeObjectRef, resourceVersion: String?) -> [String: Any] {
        var body = object
        var metadata = body["metadata"] as? [String: Any] ?? [:]
        metadata["managedFields"] = nil
        metadata["namespace"] = ref.namespace
        if let resourceVersion { metadata["resourceVersion"] = resourceVersion }
        body["metadata"] = metadata
        body["status"] = nil
        return body
    }

    static func request(_ body: [String: Any], ref: KubeObjectRef, dryRun: Bool, force: Bool = false) -> KubeWriteRequest {
        var query: [(String, String?)] = [("fieldManager", KubeWrites.fieldManager)]
        if dryRun { query.append(("dryRun", "All")) }
        if force { query.append(("force", "true")) }
        return KubeWriteRequest(method: .PATCH, path: KubePath.query(KubeWrites.path(ref), query), body: KubeWrites.encode(body), contentType: contentType)
    }

    /// The kubectl it equals: `kubectl apply --server-side
    /// --field-manager=overterm -f FILE --context C [-n NS]`, quoted for zsh.
    static func kubectl(file: String, context: String, namespace: String?, force: Bool = false) -> String {
        var words = ["kubectl", "apply", "--server-side", "--field-manager=\(KubeWrites.fieldManager)"]
        if force { words.append("--force-conflicts") }
        words += ["-f", KubectlLine.quoted(file), "--context", KubectlLine.quoted(context)]
        if let namespace { words += ["-n", KubectlLine.quoted(namespace)] }
        return words.joined(separator: " ")
    }

    /// `kubectl kustomize DIR`: rendered here, from files alone.
    static func kustomizeArguments(_ folder: String) -> [String] { ["kustomize", folder] }
}

/// What the diff shows of each side, as `kubectl diff --server-side` shows
/// it: managedFields, status and the last-applied annotation left out, a
/// Secret's values masked `***`, `*** (before)`, `*** (after)` — and, as
/// everywhere, an env value whose name looks secret masked the same way.
/// Pure.
enum KubeManifestDiff {
    static let mask = KubeObjectStrip.mask
    static let envMask = Secrets.mask("x")

    /// What neither side shows: what the server keeps for itself, and the
    /// last-applied annotation — the whole object again, a Secret's values with it.
    static func stripped(_ object: [String: Any]) -> [String: Any] {
        var object = object
        object["status"] = nil
        if var metadata = object["metadata"] as? [String: Any] {
            metadata["managedFields"] = nil
            if var annotations = metadata["annotations"] as? [String: Any] {
                annotations[KubeObjectStrip.lastApplied] = nil
                metadata["annotations"] = annotations.isEmpty ? nil : annotations
            }
            object["metadata"] = metadata
        }
        return object
    }

    /// What an editor copy of a cluster object holds (`y`): stripped, and
    /// without what identifies this one version of it — its resourceVersion
    /// is kept by the session and sent with the apply, so a change since
    /// is a 409. Masked as the YAML tab masks it.
    static func forEditing(_ object: [String: Any]) -> [String: Any] {
        var object = stripped(object)
        if var metadata = object["metadata"] as? [String: Any] {
            for key in ["resourceVersion", "uid", "creationTimestamp", "generation", "selfLink"] { metadata[key] = nil }
            object["metadata"] = metadata
        }
        return KubeObjectStrip.shown(object, full: false)
    }

    /// Both sides masked together, so a value that changed says so without
    /// saying what it is: a Secret's `data` and `stringData`, and every
    /// env value whose name looks secret (a URL's password too).
    static func masked(before: [String: Any]?, after: [String: Any]?) -> (before: [String: Any]?, after: [String: Any]?) {
        let secret = [before, after].contains { $0.map(KubeObjectStrip.isSecret) == true }
        var a = before
        var b = after
        if secret {
            for key in ["data", "stringData"] {
                let (x, y) = maskedValues(a?[key] as? [String: Any], b?[key] as? [String: Any], mask: mask)
                if a?[key] != nil { a?[key] = x }
                if b?[key] != nil { b?[key] = y }
            }
        }
        let (x, y) = maskedEnv(a, b)
        return (x as? [String: Any], y as? [String: Any])
    }

    /// Two maps' values masked key by key: the same value `mask` on both
    /// sides, a changed one `mask (before)` and `mask (after)`.
    static func maskedValues(_ a: [String: Any]?, _ b: [String: Any]?, mask: String) -> ([String: Any]?, [String: Any]?) {
        var x = a
        var y = b
        for key in Set((a ?? [:]).keys).union((b ?? [:]).keys) {
            let left = a?[key]
            let right = b?[key]
            if let left, let right {
                let same = (left as AnyObject).isEqual(right as AnyObject)
                x?[key] = same ? mask : mask + " (before)"
                y?[key] = same ? mask : mask + " (after)"
            } else {
                if left != nil { x?[key] = mask }
                if right != nil { y?[key] = mask }
            }
        }
        return (x, y)
    }

    /// Walks both sides together: an `env` list's entries paired by name,
    /// a secret-looking one's value masked as `maskedValues` does; a URL's
    /// password masked on each side.
    static func maskedEnv(_ a: Any?, _ b: Any?) -> (Any?, Any?) {
        switch (a, b) {
        case (let x as [String: Any], let y as [String: Any]):
            var left = x
            var right = y
            for key in Set(x.keys).union(y.keys) {
                let ex = x[key] as? [[String: Any]]
                let ey = y[key] as? [[String: Any]]
                if key == "env", ex != nil || ey != nil {
                    let (mx, my) = pairedEnv(ex ?? [], ey ?? [])
                    if ex != nil { left[key] = mx }
                    if ey != nil { right[key] = my }
                    continue
                }
                let (mx, my) = maskedEnv(x[key], y[key])
                if x[key] != nil { left[key] = mx }
                if y[key] != nil { right[key] = my }
            }
            return (left, right)
        case (let x as [Any], let y as [Any]):
            var left: [Any] = []
            var right: [Any] = []
            for index in 0..<max(x.count, y.count) {
                let (mx, my) = maskedEnv(index < x.count ? x[index] : nil, index < y.count ? y[index] : nil)
                if index < x.count, let mx { left.append(mx) }
                if index < y.count, let my { right.append(my) }
            }
            return (left, right)
        default:
            return (a.map(KubeObjectStrip.maskingEnv), b.map(KubeObjectStrip.maskingEnv))
        }
    }

    private static func pairedEnv(_ a: [[String: Any]], _ b: [[String: Any]]) -> ([[String: Any]], [[String: Any]]) {
        func value(_ entries: [[String: Any]], _ name: String) -> String? { entries.first { $0["name"] as? String == name }?["value"] as? String }
        func masking(_ entries: [[String: Any]], other: [[String: Any]], side: String) -> [[String: Any]] {
            entries.map { entry in
                guard let name = entry["name"] as? String, let text = entry["value"] as? String else { return entry }
                var entry = entry
                if Secrets.isSecret(name), !text.isEmpty {
                    let twin = value(other, name)
                    entry["value"] = twin == nil || twin == text ? envMask : envMask + " (\(side))"
                } else {
                    entry["value"] = Secrets.maskURL(text)
                }
                return entry
            }
        }
        return (masking(a, other: b, side: "before"), masking(b, other: a, side: "after"))
    }

    /// The client-side guess, when the cluster won't dry-run it (a
    /// read-only context, RBAC): the file merged over the live object —
    /// maps merged, anything else replaced, `null` removing — a Secret's
    /// `stringData` folded into `data` as the server folds it. Defaults
    /// and admission aren't applied: the diff is labelled so.
    static func clientSide(live: [String: Any]?, manifest: [String: Any]) -> [String: Any] {
        var merged = (merge(live ?? [:], manifest) as? [String: Any]) ?? manifest
        if KubeObjectStrip.isSecret(merged), let plain = merged["stringData"] as? [String: Any] {
            var data = merged["data"] as? [String: Any] ?? [:]
            for (key, value) in plain { data[key] = Data("\(value)".utf8).base64EncodedString() }
            merged["data"] = data
            merged["stringData"] = nil
        }
        return merged
    }

    /// RFC 7386's merge.
    static func merge(_ target: Any, _ patch: Any) -> Any {
        guard let patch = patch as? [String: Any] else { return patch }
        var result = target as? [String: Any] ?? [:]
        for (key, value) in patch {
            if value is NSNull { result[key] = nil } else { result[key] = merge(result[key] as Any, value) }
        }
        return result
    }

    /// The two sides as YAML, masked and stripped — what is diffed.
    static func sides(live: [String: Any]?, after: [String: Any]) -> (before: String, after: String) {
        let (a, b) = masked(before: live.map(stripped), after: stripped(after))
        return (a.map { KubeYAML.text($0) } ?? "", KubeYAML.text(b ?? [:]))
    }

    /// A unified diff of the two texts, three lines of context, with its
    /// headers — the changes pane's format — and how many lines each way.
    static func unified(before: String, after: String, from: String, to: String, context: Int = 3) -> (text: String, added: Int, removed: Int) {
        let old = lines(before)
        let new = lines(after)
        let blocks = LineDiff.blocks(base: before, current: after)
        guard !blocks.isEmpty else { return ("", 0, 0) }
        var out = ["--- \(from)", "+++ \(to)"]
        var added = 0
        var removed = 0
        // Blocks whose context touches join one hunk.
        var groups: [[LineDiff.Block]] = []
        for block in blocks {
            if let last = groups.last?.last, block.aLow - last.aHigh <= 2 * context { groups[groups.count - 1].append(block) } else { groups.append([block]) }
        }
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let aStart = max(0, first.aLow - context)
            let bStart = max(0, first.bLow - context)
            let aEnd = min(old.count, last.aHigh + context)
            let bEnd = min(new.count, last.bHigh + context)
            out.append("@@ -\(aStart + 1),\(aEnd - aStart) +\(bStart + 1),\(bEnd - bStart) @@")
            var a = aStart
            for block in group {
                while a < block.aLow {
                    out.append(" " + old[a])
                    a += 1
                }
                for line in old[block.aLow..<block.aHigh] { out.append("-" + line) }
                for line in new[block.bLow..<block.bHigh] { out.append("+" + line) }
                removed += block.aHigh - block.aLow
                added += block.bHigh - block.bLow
                a = block.aHigh
            }
            while a < aEnd {
                out.append(" " + old[a])
                a += 1
            }
        }
        return (out.joined(separator: "\n") + "\n", added, removed)
    }

    /// The text's lines, as `LineDiff` counts them: a last newline ends the last line.
    static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}

/// Who else owns what a manifest changes (3.3): the live object's
/// managedFields, read before anything is applied — "Argo CD manages
/// this; your change will be reverted". Pure.
enum KubeFieldOwners {
    /// A tool that sets its fields back.
    enum Tool: String, Equatable, Sendable {
        case helm, argoCD, fluxKustomize, fluxHelm
        /// Only Argo CD 2.x's default tracking label, `app.kubernetes.io/instance`,
        /// which Helm charts set too (`KubeGitOpsOwner`).
        case argoCDProbably

        var title: String {
            switch self {
            case .helm: "Helm"
            case .argoCD: "Argo CD"
            case .argoCDProbably: "Argo CD (probably)"
            case .fluxKustomize: "Flux (kustomize-controller)"
            case .fluxHelm: "Flux (helm-controller)"
            }
        }

        /// What happens to a change made under it.
        var warning: String {
            switch self {
            case .helm: "Helm manages this: its next upgrade sets these fields back."
            case .argoCD: "Argo CD manages this; your change will be reverted."
            case .argoCDProbably:
                "Argo CD probably manages this (its app.kubernetes.io/instance label, which Helm charts set too); your change may be reverted."
            case .fluxKustomize: "Flux (kustomize-controller) manages this; your change will be reverted."
            case .fluxHelm: "Flux (helm-controller) manages this; your change will be reverted at its next reconcile."
            }
        }

        /// By its field manager's name.
        static func of(manager: String) -> Tool? {
            switch manager {
            case "helm": .helm
            case "argocd-controller", "argocd-application-controller", "argocd-server": .argoCD
            case "kustomize-controller": .fluxKustomize
            case "helm-controller": .fluxHelm
            default: nil
            }
        }
    }

    /// One other manager owning fields the manifest changes.
    struct Owner: Equatable, Sendable {
        var manager: String
        var operation: String
        /// `.spec.replicas`, `.spec.template.spec.containers`.
        var fields: [String]
        var tool: Tool? { Tool.of(manager: manager) }

        /// `helm owns .spec.replicas (Apply)`.
        var said: String { "\(manager) owns \(fields.joined(separator: ", ")) (\(operation))" }
    }

    /// The paths whose value the apply's result (`after`: the dry run's
    /// answer, stripped — the server's defaults in it, so a list a checkout
    /// writes without them isn't "changed") has other than the live
    /// object's, at the depth a field is owned: maps walked into, anything
    /// else (a list, a scalar) one path.
    static func changed(_ after: [String: Any], live: [String: Any]?) -> Set<String> {
        var out = Set<String>()
        func walk(_ value: Any, _ old: Any?, _ path: String) {
            if let map = value as? [String: Any], !map.isEmpty {
                let before = old as? [String: Any]
                for (key, inner) in map { walk(inner, before?[key], path + "." + key) }
                return
            }
            if let old, (old as AnyObject).isEqual(value as AnyObject) { return }
            out.insert(path)
        }
        for (key, value) in after where !["apiVersion", "kind", "status"].contains(key) {
            if key == "metadata", let metadata = value as? [String: Any] {
                let old = live?["metadata"] as? [String: Any]
                for (field, inner) in metadata where !["name", "namespace", "resourceVersion", "uid", "creationTimestamp", "generation", "managedFields"].contains(field) {
                    walk(inner, old?[field], ".metadata." + field)
                }
                continue
            }
            walk(value, live?[key], "." + key)
        }
        return out
    }

    /// A managedFields entry's `fieldsV1` as paths: `f:spec` → `.spec`; a
    /// list's items (`k:{…}`, `v:…`, `i:…`) owned as the list's own path;
    /// `.` — the node itself — as its path.
    static func paths(_ fields: [String: Any], _ path: String = "") -> Set<String> {
        var out = Set<String>()
        for (key, inner) in fields {
            if key == "." {
                if !path.isEmpty { out.insert(path) }
            } else if key.hasPrefix("f:") {
                let next = path + "." + String(key.dropFirst(2))
                let nested = inner as? [String: Any] ?? [:]
                if nested.isEmpty { out.insert(next) } else { out.formUnion(paths(nested, next)) }
            } else if key.hasPrefix("k:") || key.hasPrefix("v:") || key.hasPrefix("i:") {
                if !path.isEmpty { out.insert(path) }
            }
        }
        return out
    }

    static func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".") }

    /// The managers other than Overterm that own a field the apply
    /// changes — `after` against `live` —, as the live object's
    /// managedFields say it. A field owned by several is said for each.
    static func others(after: [String: Any], live: [String: Any]?) -> [Owner] {
        guard let live, let entries = (live["metadata"] as? [String: Any])?["managedFields"] as? [[String: Any]] else { return [] }
        let changed = changed(after, live: live)
        guard !changed.isEmpty else { return [] }
        var owners: [Owner] = []
        for entry in entries {
            guard let manager = entry["manager"] as? String, manager != KubeWrites.fieldManager, let fields = entry["fieldsV1"] as? [String: Any] else { continue }
            // Status is the controllers' — never in what is applied.
            let owned = paths(fields).filter { !$0.hasPrefix(".status") }
            let hit = changed.filter { field in owned.contains { overlaps($0, field) } }.sorted()
            guard !hit.isEmpty else { continue }
            let operation = entry["operation"] as? String ?? "Update"
            if let index = owners.firstIndex(where: { $0.manager == manager }) {
                owners[index].fields = Array(Set(owners[index].fields).union(hit)).sorted()
            } else {
                owners.append(Owner(manager: manager, operation: operation, fields: hit))
            }
        }
        return owners.sorted { $0.manager < $1.manager }
    }

    /// The fields Overterm's own apply owns on the live object (its
    /// `overterm` managedFields entry): one of them left out of the next
    /// apply is removed from the object.
    static func overterms(_ live: [String: Any]?) -> Set<String> {
        let entries = (live?["metadata"] as? [String: Any])?["managedFields"] as? [[String: Any]] ?? []
        var out = Set<String>()
        for entry in entries where entry["manager"] as? String == KubeWrites.fieldManager && (entry["operation"] as? String ?? "Apply") == "Apply" {
            out.formUnion(paths(entry["fieldsV1"] as? [String: Any] ?? [:]))
        }
        return out
    }

    /// The tools whose marks the live object carries — Argo CD's tracking
    /// annotation or labels and Flux's labels (`KubeGitOpsOwner`), Helm's
    /// `managed-by` — even where no field of theirs is changed.
    static func managedBy(_ live: [String: Any]?) -> [Tool] {
        let metadata = live?["metadata"] as? [String: Any] ?? [:]
        let labels = metadata["labels"] as? [String: Any] ?? [:]
        let annotations = metadata["annotations"] as? [String: Any] ?? [:]
        var tools: [Tool] = []
        // Argo CD's own marks, even where they name no Application this
        // reads (an odd tracking id, an empty instance label): it is Argo's.
        if annotations[KubeGitOpsOwner.trackingAnnotation] != nil || labels[KubeGitOpsOwner.argoInstanceLabel] != nil { tools.append(.argoCD) }
        for owner in KubeGitOpsOwner.parse(metadata: metadata) {
            let tool: Tool =
                switch owner.tool {
                case .argoCD: owner.isCertain ? .argoCD : .argoCDProbably
                case .fluxKustomize: .fluxKustomize
                case .fluxHelm: .fluxHelm
                }
            if !tools.contains(tool), !(tool == .argoCDProbably && tools.contains(.argoCD)) { tools.append(tool) }
        }
        if (labels["app.kubernetes.io/managed-by"] as? String)?.lowercased() == "helm" || annotations[KubeGitOpsOwner.helmReleaseAnnotation] != nil {
            if !tools.contains(.fluxHelm) { tools.append(.helm) }
        }
        return tools
    }

    /// What the diff and the confirmation say of them, before anything is
    /// applied: each tool's warning once, then who owns which fields.
    static func warnings(_ owners: [Owner], managedBy: [Tool]) -> [String] {
        var tools: [Tool] = []
        for tool in owners.compactMap(\.tool) + managedBy where !tools.contains(tool) { tools.append(tool) }
        // A field Argo CD's controller owns says it surely.
        if tools.contains(.argoCD) { tools.removeAll { $0 == .argoCDProbably } }
        return tools.map(\.warning) + owners.map { "Also owned: \($0.said)." }
    }
}

/// An apply's 409, read (decision 11): fields another manager owns
/// (`FieldManagerConflict` causes — forcing takes them from it), or the
/// object changed since it was opened (the resourceVersion sent is old).
/// Pure.
enum KubeApplyConflict: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var manager: String
        var field: String
    }

    case fields([Field])
    case changed(String)

    static func read(_ error: KubeAPIError) -> KubeApplyConflict? {
        guard error.status == 409 else { return nil }
        var fields: [Field] = []
        for cause in error.causes where cause.reason == "FieldManagerConflict" {
            fields.append(Field(manager: manager(in: cause.message) ?? "another manager", field: cause.field))
        }
        if fields.isEmpty, error.message.hasPrefix("Apply failed with") {
            // `Apply failed with 1 conflict: conflict with "helm" using apps/v1: .spec.replicas`
            for part in error.message.components(separatedBy: "conflict with ").dropFirst() {
                guard let name = manager(in: "conflict with " + part) else { continue }
                let field = part.components(separatedBy: ": ").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                fields.append(Field(manager: name, field: field))
            }
        }
        return fields.isEmpty ? .changed(error.message) : .fields(fields)
    }

    /// `conflict with "helm" using apps/v1` → helm.
    static func manager(in text: String) -> String? {
        guard let range = text.range(of: #"conflict with "([^"]+)""#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("conflict with \"".count).dropLast())
    }

    var managers: [String] {
        guard case .fields(let fields) = self else { return [] }
        var names: [String] = []
        for field in fields where !names.contains(field.manager) { names.append(field.manager) }
        return names
    }

    /// `helm owns .spec.replicas; argocd-controller owns .spec.template…`
    var said: String {
        switch self {
        case .fields(let fields):
            return managers.map { manager in
                "\(manager) owns " + fields.filter { $0.manager == manager }.map(\.field).joined(separator: ", ")
            }.joined(separator: "; ")
        case .changed(let message): return message
        }
    }
}

/// Whether a manifest may be applied on a context (rules 1–4, decisions
/// 11 and 30), and what is still masked in it. Pure.
enum KubeApplyCheck {
    /// Why Apply isn't offered; nil when it is. `force`: asked again after
    /// a conflict — never on production.
    static func refused(_ context: KubeContext, force: Bool = false) -> String? {
        guard context.isWritable else {
            return KubeWriteCheck.readOnly(context) + " Diff with Cluster still shows what would change."
        }
        if context.isProduction {
            guard context.settings.applyOnProduction == true else {
                return "Apply is off on production, even with its writes on: the context's applyOnProduction setting turns it on. Diff with Cluster still works."
            }
            if force { return "An apply is never forced on production: change the field's owner, or the manifest." }
        }
        return nil
    }

    /// The rule as the page's writes have it: the name typed on production
    /// (rule 4: apply where applyOnProduction allows it), the owners warned of.
    static func rule(_ context: KubeContext, force: Bool = false, warning: String? = nil) -> KubeWriteRule {
        if let refused = refused(context, force: force) { return KubeWriteRule(refused: refused) }
        return KubeWriteRule(access: nil, typedName: context.isProduction, warning: warning)
    }

    /// What an apply needs: `patch` on the kind, `create` too for an
    /// object that isn't there yet (server-side apply makes it).
    static func accesses(_ ref: KubeObjectRef, exists: Bool) -> [KubeAccess] {
        exists ? [KubeAccess(verb: "patch", resource: ref.kind.fullName)] : [KubeAccess(verb: "create", resource: ref.kind.fullName)]
    }

    /// What is refused before anything is read: a Secret's masked values
    /// (they can only be retyped). An env value's mask waits for the live
    /// object, which gives an untouched one its value back (`restoringEnv`).
    static func maskedBeforeReading(_ object: KubeManifestObject) -> [String] {
        object.isSecret ? masked(object) : []
    }

    /// Where a manifest still holds a mask (a Secret's `***`, an env
    /// value's `••••••`): such a manifest isn't applied — its values would
    /// become the masks. `.data.password`, `.spec.…env[DB_PASSWORD]`.
    static func masked(_ object: KubeManifestObject) -> [String] {
        var out: [String] = []
        if object.isSecret {
            for key in ["data", "stringData"] {
                for (name, value) in object.object[key] as? [String: Any] ?? [:] where "\(value)".hasPrefix(KubeObjectStrip.mask) {
                    out.append(".\(key).\(name)")
                }
            }
        }
        func walk(_ value: Any, _ path: String) {
            switch value {
            case let map as [String: Any]:
                if path.hasSuffix(".env") { return }
                for (key, inner) in map {
                    if key == "env", let entries = inner as? [[String: Any]] {
                        for entry in entries {
                            if let text = entry["value"] as? String, text.contains(KubeManifestDiff.envMask) {
                                out.append("\(path).env[\(entry["name"] as? String ?? "?")]")
                            }
                        }
                    } else {
                        walk(inner, path + "." + key)
                    }
                }
            case let list as [Any]:
                for (index, item) in list.enumerated() { walk(item, "\(path)[\(index)]") }
            case let text as String where text.contains(KubeManifestDiff.envMask) && !path.hasPrefix(".data") && !path.hasPrefix(".stringData"):
                out.append(path)
            default: break
            }
        }
        walk(object.object, "")
        return out.sorted()
    }

    /// Said when a manifest still holds masks. `owned`: the fields
    /// Overterm's own apply owns on the live object (`KubeFieldOwners.overterms`),
    /// when it was read — a key of those left out of an apply is removed
    /// from the cluster, so it is never offered as the way out.
    static func maskedSaid(_ paths: [String], of spoken: String, owned: Set<String>?) -> String {
        let head =
            "\(spoken) still holds masked values (\(paths.joined(separator: ", "))): Overterm never puts a value it masked into a file, so it can't apply them back. "
            + "Retype each value — Overterm's copy is never saved, so what you type stays in memory."
        guard let owned else {
            return head + " Taking a key out keeps it in the cluster only if Overterm never applied it: one it applied before is removed — Diff with Cluster shows it."
        }
        let applied = paths.filter { path in
            let field = path.split(separator: "[", maxSplits: 1).first.map(String.init) ?? path
            let data = field.hasPrefix(".stringData.") ? ".data." + field.dropFirst(".stringData.".count) : field
            return owned.contains { KubeFieldOwners.overlaps($0, field) || KubeFieldOwners.overlaps($0, data) }
        }
        let others = paths.filter { !applied.contains($0) }
        var said = head
        if !applied.isEmpty {
            said +=
                " Don't take \(applied.joined(separator: ", ")) out: Overterm applied \(applied.count == 1 ? "it" : "them") before, so leaving \(applied.count == 1 ? "it" : "them") out removes \(applied.count == 1 ? "it" : "them") from the cluster."
        }
        if !others.isEmpty {
            said +=
                " \(others.joined(separator: ", ")) may be taken out instead: Overterm never applied \(others.count == 1 ? "it" : "them"), so \(others.count == 1 ? "it stays" : "they stay") as \(others.count == 1 ? "it is" : "they are") in the cluster."
        }
        return said
    }

    /// What an apply sends of a manifest that isn't a Secret: an env value
    /// still masked as `y` masked it (`••••••`, a URL's password) given back
    /// the live entry's value of the same name in the same container —
    /// untouched, so the cluster keeps it. In memory only, never written to
    /// the copy; the diff masks it again. A Secret's values are never given
    /// back: they are retyped.
    static func restoringEnv(_ object: [String: Any], live: [String: Any]?) -> [String: Any] {
        guard let live, !KubeObjectStrip.isSecret(object) else { return object }
        return restoredEnv(object, live) as? [String: Any] ?? object
    }

    private static func restoredEnv(_ value: Any, _ live: Any?) -> Any {
        switch value {
        case var map as [String: Any]:
            let old = live as? [String: Any]
            for (key, inner) in map {
                if key == "env", let entries = inner as? [[String: Any]] {
                    let liveEntries = old?[key] as? [[String: Any]] ?? []
                    map[key] = entries.map { entry -> [String: Any] in
                        guard let name = entry["name"] as? String, let text = entry["value"] as? String, text.contains(KubeManifestDiff.envMask),
                            let twin = liveEntries.first(where: { $0["name"] as? String == name })?["value"] as? String,
                            DockerSecrets.masked(name, twin) == text
                        else { return entry }
                        var entry = entry
                        entry["value"] = twin
                        return entry
                    }
                } else {
                    map[key] = restoredEnv(inner, old?[key])
                }
            }
            return map
        case let list as [Any]:
            let old = live as? [Any] ?? []
            return list.enumerated().map { index, item in restoredEnv(item, twin(of: item, at: index, in: old)) }
        default:
            return value
        }
    }

    /// A list item's live twin: by its name where it has one (a container),
    /// else by its place.
    private static func twin(of item: Any, at index: Int, in old: [Any]) -> Any? {
        if let name = (item as? [String: Any])?["name"] as? String {
            return old.first { ($0 as? [String: Any])?["name"] as? String == name }
        }
        return index < old.count ? old[index] : nil
    }

    /// Masked values replaced by the live object's at the same place — for
    /// the diff only, never an apply: what is still masked is shown as
    /// unchanged. Values stay in memory, and are masked again in the diff.
    static func unmasked(_ object: [String: Any], live: [String: Any]?) -> [String: Any] {
        guard let live else { return object }
        var object = object
        if KubeObjectStrip.isSecret(object) {
            for key in ["data", "stringData"] {
                guard var values = object[key] as? [String: Any] else { continue }
                let own = live["data"] as? [String: Any] ?? [:]
                for (name, value) in values where "\(value)".hasPrefix(KubeObjectStrip.mask) {
                    // stringData's mask stands for data's value, decoded.
                    if key == "stringData" {
                        values[name] = (own[name] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
                    } else {
                        values[name] = own[name]
                    }
                }
                object[key] = values
            }
        }
        return unmaskedEnv(object, live) as? [String: Any] ?? object
    }

    private static func unmaskedEnv(_ value: Any, _ live: Any?) -> Any {
        switch value {
        case var map as [String: Any]:
            let old = live as? [String: Any]
            for (key, inner) in map {
                if key == "env", let entries = inner as? [[String: Any]] {
                    let liveEntries = old?[key] as? [[String: Any]] ?? []
                    map[key] = entries.map { entry -> [String: Any] in
                        guard let text = entry["value"] as? String, text.contains(KubeManifestDiff.envMask), let name = entry["name"] as? String,
                            let twin = liveEntries.first(where: { $0["name"] as? String == name })?["value"] as? String
                        else { return entry }
                        var entry = entry
                        entry["value"] = twin
                        return entry
                    }
                } else {
                    map[key] = unmaskedEnv(inner, old?[key])
                }
            }
            return map
        case let list as [Any]:
            let old = live as? [Any] ?? []
            return list.enumerated().map { index, item in unmaskedEnv(item, index < old.count ? old[index] : nil) }
        default:
            return value
        }
    }
}

/// One object's diff with the cluster, as the changes pane shows it.
struct KubeManifestItem: Identifiable {
    var ref: KubeObjectRef
    /// The live object stripped and masked as YAML; "" when it isn't there yet.
    var before: String
    var after: String
    /// The unified diff, "" when nothing changes.
    var diff: String
    var added: Int
    var removed: Int
    var isNew: Bool
    var owners: [KubeFieldOwners.Owner]
    var managedBy: [KubeFieldOwners.Tool]
    /// Masked values the manifest still holds: Apply refuses.
    var masked: [String]
    /// What an apply of it sends: the object the diff was made from, an
    /// untouched env mask given back its live value (`restoringEnv`) — in
    /// memory only. Applied with this item's ref, never another's.
    var sent: [String: Any] = [:]
    /// The fields Overterm's own apply owns on the live object.
    var overterms: Set<String> = []

    var id: String { ref.description }
    var unchanged: Bool { diff.isEmpty && !isNew }
    var warnings: [String] { KubeFieldOwners.warnings(owners, managedBy: managedBy) }
    /// `deployment shop/web`.
    var spoken: String { KubeWriteOutcome.spoken(ref) }
}

/// A manifest's diff with one context.
struct KubeManifestDiffResult {
    /// How the "after" side was made.
    enum Method: Equatable {
        /// `dryRun=All`: defaults and admission applied.
        case serverSide
        /// The file merged over the live object here, with why.
        case clientSide(String)
    }

    var context: String
    var production: Bool
    var method: Method
    var items: [KubeManifestItem]
    /// The text it was made from — the objects applied are this text's.
    var text: String
    /// Rendered by `kubectl kustomize` from the files on disk.
    var kustomized = false

    static let clientSideLabel = "client-side: defaults and admission not applied"

    /// What the pane says it is.
    var label: String {
        let made =
            switch method {
            case .serverSide: "Server-side dry run (dryRun=All): what \(context) would make of it — its defaults and admission applied."
            case .clientSide(let why): "\(Self.clientSideLabel) — \(why)"
            }
        return made + (kustomized ? " Rendered by kubectl kustomize from the saved files." : "")
    }

    var isServerSide: Bool { method == .serverSide }
    var changes: Int { items.filter { !$0.unchanged }.count }
    var added: Int { items.reduce(0) { $0 + $1.added } }
    var removed: Int { items.reduce(0) { $0 + $1.removed } }
    /// The owners' warnings of the objects that change: one the dry run
    /// leaves as it is warns of nothing.
    var warnings: [String] {
        var seen: [String] = []
        for warning in items.filter({ !$0.unchanged }).flatMap(\.warnings) where !seen.contains(warning) { seen.append(warning) }
        return seen
    }

    /// What the confirmation shows of it: per object its counts and its
    /// diff's lines, at most `limit` lines in all — masked as the pane is.
    func summary(limit: Int = 60) -> String {
        var lines: [String] = []
        for item in items {
            if item.unchanged {
                lines.append("\(item.spoken): unchanged")
                continue
            }
            lines.append("\(item.spoken)" + (item.isNew ? " (new)" : "") + ": +\(item.added) −\(item.removed)")
            for line in item.diff.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2) where !line.isEmpty {
                lines.append("  " + line)
            }
        }
        if lines.count > limit { return lines.prefix(limit).joined(separator: "\n") + "\n  … the rest in the changes pane." }
        return lines.joined(separator: "\n")
    }
}

/// What the apply's confirmation says (rule 3): the context and namespace
/// — production in capitals —, the objects, the dry-run diff, the fields'
/// other owners, the kubectl it equals, the name typed where rule 4 asks.
/// Pure.
enum KubeApplyConfirmation {
    static func make(
        _ result: KubeManifestDiffResult, context: KubeContext, kubectl: String, force: KubeApplyConflict? = nil, replacing: Bool = false, agent: Bool = false
    ) -> KubeWriteConfirmation {
        let changed = result.items.filter { !$0.unchanged }
        let namespaces = Set(changed.map { $0.ref.namespace ?? "" })
        let place =
            (context.isProduction ? KubeWriteConfirmation.productionMark : "") + context.name + " · "
            + (namespaces.count == 1 ? (namespaces.first.flatMap { $0.isEmpty ? nil : "namespace \($0)" } ?? "cluster-wide") : "\(namespaces.count) namespaces")
        let what = changed.count == 1 ? changed[0].spoken : "\(changed.count) objects"
        let title: String
        var lines: [String] = []
        if let force {
            title = "Force the apply of \(what)?"
            lines.append("Forcing takes these fields from their managers: \(force.said).")
            if !force.managers.compactMap(KubeFieldOwners.Tool.of(manager:)).isEmpty {
                lines.append("⚠︎ " + force.managers.compactMap(KubeFieldOwners.Tool.of(manager:)).map(\.warning).joined(separator: " "))
            }
        } else if replacing {
            title = "Replace \(what) with your copy?"
            lines.append("It changed in \(context.name) since you opened it: applied again without the version you opened, your copy's fields win.")
        } else {
            title = "Apply \(what) to \(context.name)?"
        }
        lines.append(result.label)
        lines.append(result.summary())
        for warning in result.warnings { lines.append("⚠︎ " + warning) }
        lines.append("Equals: \(kubectl)")
        let typed = context.isProduction ? (changed.count == 1 ? changed[0].ref.name : context.name) : nil
        if let typed { lines.append("Type \(typed) to confirm.") }
        return KubeWriteConfirmation(
            verb: nil, title: title, scope: place, detail: lines.joined(separator: "\n"), button: force != nil ? "Force Apply" : (replacing ? "Replace" : "Apply"),
            typedName: typed, production: context.isProduction, kubectl: kubectl)
    }
}
