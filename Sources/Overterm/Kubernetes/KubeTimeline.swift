import Foundation

/// One revision of a workload's pod template: a Deployment's ReplicaSet,
/// a StatefulSet's or DaemonSet's ControllerRevision. Its template is held
/// raw — in memory, for the diffs, and dropped with the detail — so a
/// secret-looking env value that changed can say so masked (`*** (before)`,
/// `*** (after)`) without saying what it is. Pure.
struct KubeTemplateRevision: Equatable, Sendable, Identifiable {
    struct Image: Equatable, Sendable {
        var container: String
        var image: String
    }

    var revision: Int
    /// The ReplicaSet's or ControllerRevision's name.
    var name: String
    var created: Date?
    /// `spec.template` as JSON, the controller's own hash label left out:
    /// never shown as it is — `KubeTimeline.templateDiff` masks it.
    var template: Data
    var images: [Image]
    /// `kubectl.kubernetes.io/restartedAt` on the template.
    var restartedAt: String?
    /// The revisions it was before (`deployment.kubernetes.io/revision-history`):
    /// a rollback made it the newest again.
    var reused: [Int] = []
    /// A ReplicaSet's wanted replicas.
    var replicas: Int?

    var id: String { name }
    /// Its template, parsed.
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: template) as? [String: Any]) ?? [:] }
}

/// What opens a change's diff in the changes pane.
enum KubeTimelineChange: Hashable, Sendable {
    /// One template revision against another (`from` nil: the first, against nothing).
    case template(from: Int?, to: Int)
    /// One Helm revision against another.
    case helm(from: Int?, to: Int)
}

/// One change in a workload's timeline. Pure.
struct KubeTimelineEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A new pod template: an image, its env, its resources…
        case revision
        /// The template the same but for `restartedAt`: a rollout restart.
        case restart
        /// An older template made the newest again.
        case rollback
        case helm
        /// A replica count changed (the controller's events).
        case scale
        case warning
    }

    var id: String
    var kind: Kind
    /// When: nil when the cluster doesn't say.
    var time: Date?
    /// The time is a bound, not the moment: a rolled-back revision's
    /// object is older than the change, so it is placed after the one before.
    var approximate = false
    var title: String
    var detail: String?
    /// How often a warning came.
    var count = 1
    var change: KubeTimelineChange?
}

/// A workload's change timeline (docs/design/kubernetes/analysis.md, 3.6):
/// its template revisions — images and template changes, `restartedAt`
/// restarts, rollbacks —, its Helm release's revisions, scale changes
/// from its events, and its warning events and those of what it owns
/// (its ReplicaSets, its pods), newest first, bounded. And
/// the diffs a change opens: template against template, Helm revision
/// against revision — stripped and masked together. Pure.
enum KubeTimeline {
    static let revisionAnnotation = "deployment.kubernetes.io/revision"
    static let historyAnnotation = "deployment.kubernetes.io/revision-history"
    static let restartedAt = "kubectl.kubernetes.io/restartedAt"
    static let helmRelease = "meta.helm.sh/release-name"
    static let helmNamespace = "meta.helm.sh/release-namespace"
    /// The template revisions read: Kubernetes keeps 10 by default.
    static let revisionLimit = 50
    /// The entries shown.
    static let entryLimit = 100
    /// The namespace's warnings read about one Kind (its ReplicaSets', its pods').
    static let warningLimit = 500

    /// Which kinds have a history, and where their revisions are kept.
    enum Source: Equatable, Sendable {
        case replicaSets
        case controllerRevisions

        static func of(_ ref: KubeObjectRef) -> Source? {
            guard ref.kind.group == "apps", ref.namespace != nil else { return nil }
            switch ref.kind.resource {
            case "deployments": return .replicaSets
            case "statefulsets", "daemonsets": return .controllerRevisions
            default: return nil
            }
        }

        /// The collection's path: `apps/v1`, in the workload's namespace.
        func path(namespace: String) -> String {
            "/apis/apps/v1/namespaces/\(KubePath.segment(namespace))/\(self == .replicaSets ? "replicasets" : "controllerrevisions")"
        }
    }

    /// The Helm release a workload says it belongs to (Helm's own annotations).
    static func helmRelease(of object: [String: Any]) -> (name: String, namespace: String?)? {
        let annotations = (object["metadata"] as? [String: Any])?["annotations"] as? [String: Any] ?? [:]
        guard let name = annotations[helmRelease] as? String, !name.isEmpty else { return nil }
        return (name, (annotations[helmNamespace] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Reading revisions

    /// A list's items owned by `owner` (its uid; any when empty), as
    /// template revisions, oldest first — and whether the list had more
    /// than was read.
    static func revisions(_ body: Data, source: Source, owner: String) -> (revisions: [KubeTemplateRevision], more: Bool) {
        guard let list = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return ([], false) }
        let more = ((list["metadata"] as? [String: Any])?["continue"] as? String).map { !$0.isEmpty } ?? false
        return (revisions(items: list["items"] as? [[String: Any]] ?? [], source: source, owner: owner), more)
    }

    /// The revisions of a list's items already read (Ask Why's ReplicaSets), oldest first.
    static func revisions(items: [[String: Any]], source: Source, owner: String) -> [KubeTemplateRevision] {
        let out = items.compactMap { item -> KubeTemplateRevision? in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            if !owner.isEmpty {
                let owners = metadata["ownerReferences"] as? [[String: Any]] ?? []
                guard owners.contains(where: { $0["uid"] as? String == owner }) else { return nil }
            }
            return source == .replicaSets ? replicaSet(item) : controllerRevision(item)
        }
        return out.sorted { $0.revision < $1.revision }
    }

    static func replicaSet(_ item: [String: Any]) -> KubeTemplateRevision? {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let annotations = metadata["annotations"] as? [String: Any] ?? [:]
        guard let name = metadata["name"] as? String, let revision = (annotations[revisionAnnotation] as? String).flatMap({ Int($0) }) else { return nil }
        let spec = item["spec"] as? [String: Any] ?? [:]
        let reused = (annotations[historyAnnotation] as? String ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return makeRevision(
            revision, name: name, created: metadata["creationTimestamp"] as? String, template: spec["template"] as? [String: Any] ?? [:], reused: reused,
            replicas: KubeRollout.int(spec["replicas"]))
    }

    static func controllerRevision(_ item: [String: Any]) -> KubeTemplateRevision? {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        guard let name = metadata["name"] as? String, let number = KubeRollout.int(item["revision"]) else { return nil }
        // A StatefulSet's or DaemonSet's revision: a patch of its spec, the
        // template whole (`$patch: replace`).
        let data = item["data"] as? [String: Any] ?? [:]
        let template = (data["spec"] as? [String: Any])?["template"] as? [String: Any] ?? [:]
        return makeRevision(number, name: name, created: metadata["creationTimestamp"] as? String, template: template, reused: [], replicas: nil)
    }

    private static func makeRevision(
        _ number: Int, name: String, created: String?, template: [String: Any], reused: [Int], replicas: Int?
    ) -> KubeTemplateRevision {
        var template = template
        template["$patch"] = nil
        var metadata = template["metadata"] as? [String: Any] ?? [:]
        // What the controller adds to tell its own apart: not a change.
        if var labels = metadata["labels"] as? [String: Any] {
            labels["pod-template-hash"] = nil
            labels["controller-revision-hash"] = nil
            metadata["labels"] = labels.isEmpty ? nil : labels
        }
        metadata["creationTimestamp"] = nil
        template["metadata"] = metadata.isEmpty ? nil : metadata
        let annotations = metadata["annotations"] as? [String: Any] ?? [:]
        let spec = template["spec"] as? [String: Any] ?? [:]
        let containers = (spec["initContainers"] as? [[String: Any]] ?? []) + (spec["containers"] as? [[String: Any]] ?? [])
        let images = containers.compactMap { container -> KubeTemplateRevision.Image? in
            guard let name = container["name"] as? String, let image = container["image"] as? String else { return nil }
            return KubeTemplateRevision.Image(container: name, image: image)
        }
        let data = (try? JSONSerialization.data(withJSONObject: template, options: [.sortedKeys])) ?? Data("{}".utf8)
        return KubeTemplateRevision(
            revision: number, name: name, created: created.flatMap(KubeTime.date), template: data, images: images,
            restartedAt: annotations[restartedAt] as? String, reused: reused, replicas: replicas)
    }

    // MARK: What changed

    /// What changed from one template to the next, in words: the images,
    /// a restart, the template's other paths — never a value.
    static func summary(from old: KubeTemplateRevision?, to new: KubeTemplateRevision) -> (kind: KubeTimelineEntry.Kind, title: String, detail: String?) {
        if !new.reused.isEmpty {
            let was = new.reused.map { "revision \($0)" }.joined(separator: ", ")
            return (.rollback, "Rolled back: revision \(new.revision)", "The template of \(was) again · \(imagesSaid(new.images))")
        }
        guard let old else { return (.revision, "Revision \(new.revision)", imagesSaid(new.images)) }
        let changedImages = new.images.compactMap { image -> String? in
            let before = old.images.first { $0.container == image.container }?.image
            if before == image.image { return nil }
            return before.map { "\(image.container): \($0) → \(image.image)" } ?? "\(image.container): \(image.image) (new)"
        }
        let gone = old.images.filter { image in !new.images.contains { $0.container == image.container } }.map { "\($0.container) removed" }
        var a = old.object
        var b = new.object
        let restarted = old.restartedAt != new.restartedAt && new.restartedAt != nil
        removeRestartedAt(&a)
        removeRestartedAt(&b)
        let paths = changedPaths(a, b, path: "")
        if restarted, paths.isEmpty {
            return (.restart, "Restarted: revision \(new.revision)", "kubectl rollout restart (restartedAt \(new.restartedAt ?? ""))")
        }
        if !changedImages.isEmpty || !gone.isEmpty {
            let others = paths.filter { !$0.hasSuffix(".image") }
            var detail = (changedImages + gone).joined(separator: " · ")
            if !others.isEmpty { detail += " · also " + said(others) }
            return (.revision, "Revision \(new.revision): image\(changedImages.count + gone.count == 1 ? "" : "s") changed", detail)
        }
        return (.revision, "Revision \(new.revision): template changed", paths.isEmpty ? nil : said(paths) + (restarted ? " · restarted" : ""))
    }

    private static func said(_ paths: [String]) -> String {
        let shown = paths.prefix(3).joined(separator: ", ")
        return paths.count > 3 ? "\(shown) and \(paths.count - 3) more" : shown
    }

    private static func imagesSaid(_ images: [KubeTemplateRevision.Image]) -> String {
        images.isEmpty ? "no image" : images.map { "\($0.container): \($0.image)" }.joined(separator: " · ")
    }

    private static func removeRestartedAt(_ template: inout [String: Any]) {
        guard var metadata = template["metadata"] as? [String: Any], var annotations = metadata["annotations"] as? [String: Any] else { return }
        annotations[restartedAt] = nil
        metadata["annotations"] = annotations.isEmpty ? nil : annotations
        template["metadata"] = metadata
    }

    /// The paths where two templates differ, as names only (`spec.containers[web].env[LOG_LEVEL]`),
    /// at most 12 — a list of named things (containers, env) by name.
    static func changedPaths(_ a: Any?, _ b: Any?, path: String, limit: Int = 12) -> [String] {
        var out: [String] = []
        walk(a, b, path: path, into: &out, limit: limit)
        return out
    }

    private static func walk(_ a: Any?, _ b: Any?, path: String, into out: inout [String], limit: Int) {
        guard out.count < limit else { return }
        switch (a, b) {
        case (let x as [String: Any], let y as [String: Any]):
            for key in Set(x.keys).union(y.keys).sorted() {
                walk(x[key], y[key], path: path.isEmpty ? key : "\(path).\(key)", into: &out, limit: limit)
            }
        case (let x as [Any], let y as [Any]):
            let named = (x + y).allSatisfy { ($0 as? [String: Any])?["name"] is String }
            if named {
                func name(_ item: Any) -> String { (item as? [String: Any])?["name"] as? String ?? "" }
                var order: [String] = []
                for item in x + y where !order.contains(name(item)) { order.append(name(item)) }
                for key in order {
                    walk(x.first { name($0) == key }, y.first { name($0) == key }, path: "\(path)[\(key)]", into: &out, limit: limit)
                }
            } else if !(x as NSArray).isEqual(to: y) {
                out.append(path)
            }
        case (nil, nil): return
        default:
            guard let a, let b else { return out.append(path) }
            if !(a as AnyObject).isEqual(b as AnyObject) { out.append(path) }
        }
    }

    // MARK: Whose events

    /// Whether an event is about something the workload owns: one of its
    /// ReplicaSets (`replicaSets`, the names read), or one of its pods —
    /// a ReplicaSet's `<rs>-xxxxx`, a DaemonSet's `<name>-xxxxx`, a
    /// StatefulSet's `<name>-<ordinal>`. The workload's own events are
    /// read by its name: never here.
    static func owns(_ event: KubeEvent, kind: String, name: String, replicaSets: Set<String>) -> Bool {
        switch event.objectKind {
        case "ReplicaSet": return kind == "Deployment" && replicaSets.contains(event.object)
        case "Pod":
            let pod = event.object
            guard let dash = pod.lastIndex(of: "-") else { return false }
            let stem = String(pod[..<dash])
            let suffix = pod[pod.index(after: dash)...]
            switch kind {
            case "StatefulSet": return stem == name && !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && $0.isNumber })
            case "DaemonSet": return stem == name && generated(suffix)
            case "Deployment": return replicaSets.contains(stem) && generated(suffix)
            default: return false
            }
        default: return false
        }
    }

    /// A name's generated suffix: five of the API server's lowercase consonants and digits.
    private static func generated(_ suffix: Substring) -> Bool {
        suffix.count == 5 && suffix.allSatisfy { ($0.isASCII && $0.isNumber) || ($0.isASCII && $0.isLowercase) }
    }

    /// The ReplicaSet a `ScalingReplicaSet` event names
    /// (`Scaled up replica set web-7d9f8c from 1 to 2`).
    static func scaledReplicaSet(_ message: String) -> String? {
        guard let range = message.range(of: "replica set ") else { return nil }
        let name = message[range.upperBound...].prefix { !$0.isWhitespace }
        return name.isEmpty ? nil : String(name)
    }

    /// A StatefulSet's pod made or removed (`create Pod db-2 in StatefulSet db successful`).
    static func statefulSetPod(_ event: KubeEvent) -> (created: Bool, pod: String)? {
        guard ["SuccessfulCreate", "SuccessfulDelete"].contains(event.reason) else { return nil }
        let words = event.message.split(separator: " ")
        guard words.count >= 3, words[0] == "create" || words[0] == "delete", words[1] == "Pod" else { return nil }
        return (words[0] == "create", String(words[2]))
    }

    /// A rollout's own scaling, told apart from a change of replicas:
    /// an older ReplicaSet scaled, or the newest while another one is
    /// scaled within `window` — a rollout moves pods from one to the other.
    static func isRolloutStep(_ event: KubeEvent, among scaling: [KubeEvent], newest: String?, window: TimeInterval = 600) -> Bool {
        guard let name = scaledReplicaSet(event.message) else { return false }
        if let newest, name != newest { return true }
        guard let at = event.last ?? event.first else { return false }
        return scaling.contains { other in
            guard other.id != event.id, let otherName = scaledReplicaSet(other.message), otherName != name else { return false }
            return [other.first, other.last].contains { $0.map { abs($0.timeIntervalSince(at)) <= window } == true }
        }
    }

    // MARK: The timeline

    /// Every change, newest first, at most `limit`, and how many were left out.
    static func entries(
        revisions: [KubeTemplateRevision], helm: [KubeHelmRecord], events: [KubeEvent], kind: String = "Deployment", limit: Int = entryLimit
    ) -> (entries: [KubeTimelineEntry], cut: Int) {
        var out: [KubeTimelineEntry] = []
        let sorted = revisions.sorted { $0.revision < $1.revision }
        var bound: Date?
        for (index, revision) in sorted.enumerated() {
            let previous = index > 0 ? sorted[index - 1] : nil
            let (kind, title, detail) = summary(from: previous, to: revision)
            // A rolled-back revision's object is the old one: it came after the one before it.
            var time = revision.created
            var approximate = false
            if let created = time, let bound, created < bound {
                time = bound
                approximate = true
            }
            if let time { bound = max(bound ?? time, time) }
            out.append(
                KubeTimelineEntry(
                    id: "revision/\(revision.revision)", kind: kind, time: time, approximate: approximate, title: title, detail: detail,
                    change: .template(from: previous?.revision, to: revision.revision)))
        }
        let records = helm.sorted { $0.revision < $1.revision }
        for (index, record) in records.enumerated() {
            out.append(
                KubeTimelineEntry(
                    id: "helm/\(record.revision)", kind: .helm, time: record.updated, title: "Helm revision \(record.revision) · \(record.status)",
                    detail: "Release \(record.release)" + (index == 0 ? "" : ", after revision \(records[index - 1].revision)"),
                    change: .helm(from: index > 0 ? records[index - 1].revision : nil, to: record.revision)))
        }
        // Scaling as each controller says it: a Deployment's
        // `ScalingReplicaSet` (a rollout's steps told apart), a
        // StatefulSet's pods made and removed one by one (a pod replaced
        // says the same: said as what it is, not as a scale).
        let scaling = events.filter { !$0.isWarning && $0.reason == "ScalingReplicaSet" }
        let newestReplicaSet = sorted.last?.name
        for event in events {
            let time = event.last ?? event.first
            if event.isWarning {
                let about = event.object.isEmpty || event.objectKind == kind ? "" : "\(event.objectKind.lowercased())/\(event.object): "
                out.append(
                    KubeTimelineEntry(id: "event/\(event.id)", kind: .warning, time: time, title: event.reason, detail: about + event.message, count: event.count))
            } else if kind == "Deployment", event.reason == "ScalingReplicaSet" {
                let step = isRolloutStep(event, among: scaling, newest: newestReplicaSet)
                out.append(
                    KubeTimelineEntry(
                        id: "event/\(event.id)", kind: .scale, time: time, title: step ? "Rollout step" : "Scaled", detail: event.message, count: event.count))
            } else if kind == "StatefulSet", let pod = statefulSetPod(event) {
                out.append(
                    KubeTimelineEntry(
                        id: "event/\(event.id)", kind: .scale, time: time, title: pod.created ? "Pod created: \(pod.pod)" : "Pod deleted: \(pod.pod)",
                        detail: event.message, count: event.count))
            }
        }
        let order: [KubeTimelineEntry.Kind] = [.helm, .rollback, .restart, .revision, .scale, .warning]
        let newest = out.enumerated()
            .sorted { a, b in
                switch (a.element.time, b.element.time) {
                case (let x?, let y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default:
                    let (i, j) = (order.firstIndex(of: a.element.kind) ?? 0, order.firstIndex(of: b.element.kind) ?? 0)
                    return i != j ? i < j : a.offset > b.offset
                }
            }
            .map(\.element)
        return (Array(newest.prefix(limit)), max(0, newest.count - limit))
    }

    // MARK: The diffs

    /// One template against another, as the changes pane shows it:
    /// stripped, masked together — a secret-looking env value that changed
    /// says so as `*** (before)` / `*** (after)` —, credentials in text out.
    static func templateDiff(
        kind: String, name: String, namespace: String, from old: KubeTemplateRevision?, to new: KubeTemplateRevision
    ) -> KubeHelmDiffItem {
        let (before, after) = KubeHelmUpgrade.sides(old.map(\.object), new.object)
        let file = "\(kind.lowercased())-\(name)-template.yaml"
        let unified = KubeManifestDiff.unified(
            before: before, after: after, from: old.map { "revision \($0.revision)/\(file)" } ?? "/dev/null", to: "revision \(new.revision)/\(file)")
        return KubeHelmDiffItem(
            id: "template/\(old?.revision ?? 0)-\(new.revision)", kind: "Pod template", name: name, namespace: namespace, file: file,
            change: old == nil ? .added : unified.text.isEmpty ? .unchanged : .modified, diff: unified.text, added: unified.added, removed: unified.removed,
            group: "")
    }

    /// Two Helm revisions' user values (`config`), masked together: under
    /// a secret-looking key a value that changed is `*** (before)` /
    /// `*** (after)`, one that didn't `***`; credentials in other text out.
    static func helmValues(before: [String: Any]?, after: [String: Any]) -> (before: String, after: String) {
        let (a, b) = paired(before, after, secret: false, key: nil)
        func text(_ value: Any?) -> String {
            guard let map = value as? [String: Any], !map.isEmpty else { return "{}\n" }
            return KubeYAML.text(map)
        }
        return (before == nil ? "" : text(a), text(b))
    }

    private static func paired(_ a: Any?, _ b: Any?, secret: Bool, key: String?) -> (Any?, Any?) {
        switch (a, b) {
        case (let x as [String: Any], let y as [String: Any]):
            let entry = [x["name"], y["name"]].contains { ($0 as? String).map(Secrets.isSecret) == true }
            var left: [String: Any] = [:]
            var right: [String: Any] = [:]
            for inner in Set(x.keys).union(y.keys) {
                let secretPath = secret || Secrets.isSecret(inner) || (entry && inner == "value")
                let (l, r) = paired(x[inner], y[inner], secret: secretPath, key: inner)
                if x[inner] != nil { left[inner] = l }
                if y[inner] != nil { right[inner] = r }
            }
            return (a == nil ? nil : left, b == nil ? nil : right)
        case (let x as [Any], let y as [Any]):
            var left: [Any] = []
            var right: [Any] = []
            for index in 0..<max(x.count, y.count) {
                let (l, r) = paired(index < x.count ? x[index] : nil, index < y.count ? y[index] : nil, secret: secret, key: key)
                if index < x.count, let l { left.append(l) }
                if index < y.count, let r { right.append(r) }
            }
            return (left, right)
        case (let x as [String: Any], _): return (paired(x, [String: Any](), secret: secret, key: key).0, b.map { leaf($0, secret: secret, key: key) })
        case (_, let y as [String: Any]): return (a.map { leaf($0, secret: secret, key: key) }, paired([String: Any](), y, secret: secret, key: key).1)
        case (let x as [Any], _): return (paired(x, [Any](), secret: secret, key: key).0, b.map { leaf($0, secret: secret, key: key) })
        case (_, let y as [Any]): return (a.map { leaf($0, secret: secret, key: key) }, paired([Any](), y, secret: secret, key: key).1)
        default:
            let masks = { (value: Any) -> Bool in
                switch value {
                case let text as String: return secret && !text.isEmpty
                case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return secret || key.map(Secrets.isSecret) == true
                default: return false
                }
            }
            guard let x = a, let y = b, masks(x) || masks(y) else { return (a.map { leaf($0, secret: secret, key: key) }, b.map { leaf($0, secret: secret, key: key) }) }
            let same = (x as AnyObject).isEqual(y as AnyObject)
            return (same ? KubeHelmMask.mask : KubeHelmMask.mask + " (before)", same ? KubeHelmMask.mask : KubeHelmMask.mask + " (after)")
        }
    }

    /// One side alone: masked as `KubeHelmMask.values` masks it.
    private static func leaf(_ value: Any, secret: Bool, key: String?) -> Any {
        switch value {
        case let text as String: return secret && !text.isEmpty ? KubeHelmMask.mask : KubeHelmMask.scrubbed(text)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return secret || key.map(Secrets.isSecret) == true ? KubeHelmMask.mask : number
        default: return value
        }
    }

    /// Two Helm revisions against each other: their values, then their
    /// manifests object by object (`KubeHelmUpgrade.diff`'s masking: a
    /// Secret's data `***`, `*** (before)` / `*** (after)`).
    static func helmDiff(release: String, namespace: String, from old: KubeHelm.UpgradeInputs?, to new: KubeHelm.UpgradeInputs) -> KubeHelmDiff {
        func values(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
        let (a, b) = helmValues(before: old.map { values($0.values) }, after: values(new.values))
        let from = old.map { "revision \($0.revision)" }
        let to = "revision \(new.revision)"
        let unified = KubeManifestDiff.unified(before: a, after: b, from: from.map { "\($0)/values.yaml" } ?? "/dev/null", to: "\(to)/values.yaml")
        let valuesItem = KubeHelmDiffItem(
            id: "values", kind: "Values", name: release, namespace: namespace, file: "values.yaml",
            change: old == nil ? .added : unified.text.isEmpty ? .unchanged : .modified, diff: unified.text, added: unified.added, removed: unified.removed)
        var manifest = KubeHelmUpgrade.diff(current: old?.manifest ?? "", rendered: new.manifest, namespace: namespace, from: from ?? "none", to: to)
        manifest.items.insert(valuesItem, at: 0)
        return manifest
    }
}

/// A change's diff, as the changes pane shows it: what it compares, where,
/// and each part's diff — masked. Nothing raw is in it.
struct KubeChangeDiff: Equatable, Sendable, Identifiable {
    var id: String
    /// `deployment/web: revision 2 → 3`.
    var title: String
    var context: String
    var production: Bool
    /// What is compared with what.
    var label: String
    var diff: KubeHelmDiff
}
