import Foundation

/// The trees of what GitOps manages (docs/design/kubernetes/analysis.md,
/// 2.23, decision 24): an Argo CD Application's `status.resources` — each
/// with Argo's own sync and health —, a Flux Kustomization's inventory and
/// a Flux HelmRelease's objects (those Helm's controller labelled), with
/// their source and what they depend on. Read-only views: Argo and Flux say
/// what they manage, so an Application or a Kustomization needs no read
/// beyond its own object; a HelmRelease's objects are a few lists by
/// Helm's labels. Sync and reconcile are their own CLIs' (stage 4). Pure.
enum KubeGitOpsTree {
    /// What is drawn of one; the rest counted.
    static let shownLimit = 300

    static func build(_ root: KubeTree.Root, object: [String: Any], read: KubeTreeRead) -> KubeTree {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let kind = object["kind"] as? String ?? ""
        let name = metadata["name"] as? String ?? ""
        let namespace = metadata["namespace"] as? String
        var tree = KubeTree(
            root: KubeTreeNode(
                id: "\(kind)/\(name)", kind: kind, name: name, namespace: namespace, apiVersion: object["apiVersion"] as? String, relation: .root,
                health: .unknown, status: nil),
            notes: read.notes)
        switch root {
        case .argoApplication: argo(&tree, object)
        case .fluxKustomization: kustomization(&tree, object)
        default: helmRelease(&tree, object, read: read)
        }
        return tree
    }

    // MARK: Argo CD

    /// Argo's health words, as its UI colours them.
    static func argoHealth(_ status: String?) -> KubeTreeHealth {
        switch status {
        case "Healthy": .good
        case "Progressing": .waiting
        case "Degraded": .bad
        case "Missing": .missing
        case "Suspended": .dim
        case nil: .dim
        default: .unknown
        }
    }

    /// Whether an Application deploys to the cluster it lives in: its
    /// objects can be opened here only then (`KubeGitOpsSource.inCluster`).
    static func argoInCluster(_ destination: [String: Any]) -> Bool {
        KubeGitOpsSource.inCluster(server: destination["server"] as? String, name: destination["name"] as? String)
    }

    /// Said once of an Argo CD 3 Application whose resources carry no health.
    static let appTreeNote = "Argo CD 3 keeps each resource's health outside the Application: its objects are shown by sync alone."

    /// `status.resourceHealthSource: appTree` — Argo CD 3's default: each
    /// resource's health isn't in `status.resources`.
    static func isHealthElsewhere(_ status: [String: Any]) -> Bool { status["resourceHealthSource"] as? String == "appTree" }

    private static func argo(_ tree: inout KubeTree, _ object: [String: Any]) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let sync = (status["sync"] as? [String: Any])?["status"] as? String
        let health = (status["health"] as? [String: Any])?["status"] as? String
        var mark = argoHealth(health)
        if mark == .good, sync == "OutOfSync" { mark = .waiting }
        if let phase = (status["operationState"] as? [String: Any])?["phase"] as? String, ["Failed", "Error"].contains(phase) { mark = .bad }
        tree.root.health = mark
        tree.root.status = [sync, health].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        let id = tree.root.id
        // A multi-source Application says `revisions[]`, one per source.
        let synced = status["sync"] as? [String: Any]
        for (index, source) in KubeGitOpsSource.all(in: spec).enumerated() {
            tree.root.children.append(
                KubeTreeNode(
                    id: "\(id)/source/\(index)", kind: "Repository", name: source.repoURL, namespace: nil, apiVersion: nil, relation: .source,
                    how: [source.place, source.targetRevision.map { "@ \($0)" }, source.ref.map { "ref \($0)" }].compactMap { $0 }.joined(separator: " ")
                        .nilIfEmpty, health: .dim,
                    status: KubeGitOpsSource.revision(synced, source: index).map { String($0.prefix(12)) }))
        }
        let destination = spec["destination"] as? [String: Any] ?? [:]
        let here = argoInCluster(destination)
        if !here {
            let said = destination["name"] as? String ?? destination["server"] as? String ?? ""
            tree.notes.append("It deploys to another cluster (\(said)): its objects are listed as Argo CD says them, not opened here.")
        }
        let resources = status["resources"] as? [[String: Any]] ?? []
        // Argo CD 3 keeps each resource's health in its tree, not the
        // Application, unless `controller.resource.health.persist` is set:
        // the children are drawn by sync alone, never as unknown.
        let healthElsewhere = isHealthElsewhere(status)
        if healthElsewhere, !resources.isEmpty { tree.notes.append(appTreeNote) }
        if resources.count > shownLimit { tree.notes.append("\(resources.count - shownLimit) more objects not drawn — the first \(shownLimit) are.") }
        for resource in resources.prefix(shownLimit) {
            let group = resource["group"] as? String ?? ""
            let version = resource["version"] as? String ?? ""
            let kind = resource["kind"] as? String ?? ""
            let name = resource["name"] as? String ?? ""
            let namespace = (resource["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let health = healthElsewhere ? nil : (resource["health"] as? [String: Any])?["status"] as? String
            let sync = resource["status"] as? String
            var mark = argoHealth(health)
            if sync == "OutOfSync", !mark.isProblem { mark = .waiting }
            var words = [sync, health].compactMap { $0 }
            if resource["requiresPruning"] as? Bool == true { words.append("requires pruning") }
            tree.root.children.append(
                KubeTreeNode(
                    id: "\(id)/manages/\(group)/\(kind)/\(namespace ?? "")/\(name)", kind: kind, name: name, namespace: namespace,
                    apiVersion: here && !version.isEmpty ? (group.isEmpty ? version : "\(group)/\(version)") : nil, relation: .manages,
                    how: (resource["hook"] as? Bool == true) ? "hook" : nil, health: mark, status: words.joined(separator: " · ").nilIfEmpty))
        }
        if resources.isEmpty { tree.notes.append("Argo CD lists no objects for it yet.") }
    }

    // MARK: Flux

    /// Where a Kustomization or a HelmRelease applies to another cluster
    /// (`spec.kubeConfig`): the Secret (or ConfigMap) that says how; nil
    /// when it applies to its own.
    static func fluxRemote(_ spec: [String: Any]) -> String? {
        guard let config = spec["kubeConfig"] as? [String: Any] else { return nil }
        if let name = (config["secretRef"] as? [String: Any])?["name"] as? String { return "spec.kubeConfig.secretRef \(name)" }
        if let name = (config["configMapRef"] as? [String: Any])?["name"] as? String { return "spec.kubeConfig.configMapRef \(name)" }
        return "spec.kubeConfig"
    }

    /// Said of one deploying elsewhere: its objects not opened here — a
    /// verb on one would reach a same-named object of this cluster.
    static func remoteNote(_ how: String) -> String {
        "It deploys to another cluster through \(how): its objects are listed as Flux says them, not opened here."
    }

    /// A Flux source reference (`sourceRef`, `chartRef`): its kind in
    /// source.toolkit.fluxcd.io, unless it says its own `apiVersion`.
    private static func source(_ ref: [String: Any]?, defaultNamespace: String?, parent: String, how: String? = nil) -> KubeTreeNode? {
        guard let ref, let kind = ref["kind"] as? String, let name = ref["name"] as? String else { return nil }
        let namespace = (ref["namespace"] as? String) ?? defaultNamespace
        return KubeTreeNode(
            id: "\(parent)/source/\(kind)/\(namespace ?? "")/\(name)", kind: kind, name: name, namespace: namespace,
            apiVersion: ref["apiVersion"] as? String ?? "source.toolkit.fluxcd.io/v1", relation: .source, how: how, health: .unknown, status: "not read")
    }

    /// `dependsOn`: others of its own kind, by name (and namespace).
    private static func dependsOn(_ spec: [String: Any], kind: String, apiVersion: String?, namespace: String?, parent: String) -> [KubeTreeNode] {
        (spec["dependsOn"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let place = item["namespace"] as? String ?? namespace
            return KubeTreeNode(
                id: "\(parent)/uses/\(kind)/\(place ?? "")/\(name)", kind: kind, name: name, namespace: place, apiVersion: apiVersion, relation: .uses,
                how: "dependsOn", health: .unknown, status: "not read")
        }
    }

    private static func kustomization(_ tree: inout KubeTree, _ object: [String: Any]) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let namespace = tree.root.namespace
        (tree.root.health, tree.root.status) = KubeTree.readyHealth(object)
        tree.root.how = (status["lastAppliedRevision"] as? String).map { "applied \($0)" }
        let id = tree.root.id
        if let source = source(spec["sourceRef"] as? [String: Any], defaultNamespace: namespace, parent: id, how: spec["path"] as? String) {
            tree.root.children.append(source)
        }
        tree.root.children += dependsOn(spec, kind: "Kustomization", apiVersion: object["apiVersion"] as? String, namespace: namespace, parent: id)
        let remote = fluxRemote(spec)
        if let remote { tree.notes.append(remoteNote(remote)) }
        let entries = (status["inventory"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        if entries.count > shownLimit { tree.notes.append("\(entries.count - shownLimit) more objects not drawn — the first \(shownLimit) are.") }
        for entry in entries.prefix(shownLimit) {
            guard let found = KubeGitOpsSource.inventoryEntry(entry["id"] as? String ?? "", version: entry["v"] as? String ?? "v1") else { continue }
            tree.root.children.append(
                KubeTreeNode(
                    id: "\(id)/manages/\(entry["id"] as? String ?? "")", kind: found.kind, name: found.name, namespace: found.namespace,
                    apiVersion: remote == nil ? found.apiVersion : nil,
                    relation: .manages, health: .unknown, status: nil))
        }
        if entries.isEmpty { tree.notes.append("Its inventory is empty: nothing applied yet, or pruning is off (spec.prune).") }
    }

    private static func helmRelease(_ tree: inout KubeTree, _ object: [String: Any], read: KubeTreeRead) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let namespace = tree.root.namespace
        (tree.root.health, tree.root.status) = KubeTree.readyHealth(object)
        let history = (status["history"] as? [[String: Any]])?.first
        let chartSpec = (spec["chart"] as? [String: Any])?["spec"] as? [String: Any]
        let chart = history?["chartName"] as? String ?? chartSpec?["chart"] as? String
        let version = history?["chartVersion"] as? String ?? chartSpec?["version"] as? String
        tree.root.how = [chart, version].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        let id = tree.root.id
        if let source = source(spec["chartRef"] as? [String: Any], defaultNamespace: namespace, parent: id, how: "chartRef")
            ?? source(chartSpec?["sourceRef"] as? [String: Any], defaultNamespace: namespace, parent: id, how: chart)
        {
            tree.root.children.append(source)
        }
        tree.root.children += dependsOn(spec, kind: "HelmRelease", apiVersion: object["apiVersion"] as? String, namespace: namespace, parent: id)
        let target = spec["targetNamespace"] as? String ?? namespace ?? ""
        if let remote = fluxRemote(spec) {
            // Nothing was read here: what it made lives in that cluster.
            tree.notes.append("It deploys to another cluster through \(remote): what it made there isn't read from this one.")
            return
        }
        var found = 0
        let lists: [(KubeTree.Read.What, String, String)] = [
            (.deployments, "Deployment", "apps/v1"), (.statefulSets, "StatefulSet", "apps/v1"), (.daemonSets, "DaemonSet", "apps/v1"), (.services, "Service", "v1"),
        ]
        for (what, kind, apiVersion) in lists {
            for item in read.items(what).sorted(by: { KubeTree.name(of: $0) < KubeTree.name(of: $1) }) {
                let name = KubeTree.name(of: item)
                let (health, said) = KubeTree.health(kind: kind, object: item)
                tree.root.children.append(
                    KubeTreeNode(
                        id: "\(id)/manages/\(kind)/\(name)", kind: kind, name: name, namespace: target, apiVersion: apiVersion, relation: .manages, health: health,
                        status: said))
                found += 1
            }
        }
        if found == 0 {
            tree.notes.append(
                "No Deployment, StatefulSet, DaemonSet or Service in \(target) carries its Helm labels (\(KubeTree.fluxHelmName)=\(tree.root.name)).")
        }
    }
}
