import Foundation

/// A node's health mark in a dependency tree: green, orange, red — red too
/// for what is referenced and not there — grey when there is nothing to
/// say, or it wasn't read.
enum KubeTreeHealth: String, Equatable, Sendable {
    case good, waiting, bad
    /// Referenced and not found: a missing ConfigMap, a Service gone.
    case missing
    /// Not read, or not checked (a list cut, refused).
    case unknown
    /// Nothing to say: scaled to 0, completed, suspended, no checks.
    case dim

    /// Red: what the tree is for.
    var isProblem: Bool { self == .bad || self == .missing }
}

/// One node of a dependency tree: an object (or a container), how it hangs
/// off its parent, its health, its children. Pure.
struct KubeTreeNode: Equatable, Sendable, Identifiable {
    enum Relation: String, Equatable, Sendable {
        /// The detail's own object.
        case root
        /// Down the owner chain: a ReplicaSet a Deployment owns, its pods.
        case owns
        /// A pod's container.
        case container
        /// A reference across: a ConfigMap, a Secret, a PVC, the
        /// ServiceAccount, a Gateway a route is attached to, a dependsOn.
        case uses
        /// A Service that selects the pods, or the pods a Service selects.
        case selects
        /// An Ingress or an HTTPRoute that sends to a Service, or the
        /// Service a rule sends to.
        case routes
        /// A GitOps object's source: a GitRepository, a HelmRepository.
        case source
        /// What Argo CD or Flux applied, as it says it.
        case manages
    }

    var id: String
    var kind: String
    var name: String
    var namespace: String?
    /// The reference's `apiVersion`; nil for what can't be opened (a container).
    var apiVersion: String?
    var relation: Relation
    /// How: `envFrom`, `volume`, `env DB_PASSWORD`, `/api → 80`.
    var how: String?
    var health: KubeTreeHealth
    /// What it is now: `CrashLoopBackOff`, `3/3 ready`, `not found`, `selects no pod`.
    var status: String?
    var children: [KubeTreeNode] = []

    /// The object it is, to open; nil for a container.
    var link: KubeLink? { apiVersion.map { KubeLink(apiVersion: $0, kind: kind, namespace: namespace, name: name) } }

    /// Every node under it, and it, depth first.
    var all: [KubeTreeNode] { [self] + children.flatMap(\.all) }
}

/// A detail's dependency tree (docs/design/kubernetes/analysis.md, 3.7 —
/// k9s's xray, kubectl tree): down the owner chain (a Deployment, its
/// ReplicaSets, their pods, their containers) and across references
/// (ConfigMaps, Secrets by name, PVCs, the ServiceAccount, the Services
/// selecting its pods and the Ingresses and HTTPRoutes routing to them),
/// each with a health mark — a missing ConfigMap or a Service selecting
/// nothing red. Argo CD's Applications and Flux's Kustomizations and
/// HelmReleases are trees too: what they say they manage (`KubeGitOpsTree`).
/// Built from what was read once (`KubeTreeRead`): the same namespace, no
/// watches. Pure.
struct KubeTree: Equatable, Sendable {
    var root: KubeTreeNode
    /// What couldn't be read, or was left out.
    var notes: [String] = []

    /// Depth first, with each node's depth: what the Overview draws.
    var rows: [(depth: Int, node: KubeTreeNode)] {
        func walk(_ node: KubeTreeNode, _ depth: Int) -> [(depth: Int, node: KubeTreeNode)] {
            [(depth, node)] + node.children.flatMap { walk($0, depth + 1) }
        }
        return walk(root, 0)
    }

    /// The red ones.
    var problems: [KubeTreeNode] { root.all.filter { $0.health.isProblem } }

    static func == (lhs: KubeTree, rhs: KubeTree) -> Bool { lhs.root == rhs.root && lhs.notes == rhs.notes }

    /// How many pods a list reads, how many objects any other.
    static let podLimit = 200
    static let listLimit = 500
    /// Pods drawn under one owner; the rest counted.
    static let podsShown = 50
    /// A CronJob's newest Jobs followed down to their pods.
    static let jobsFollowed = 5

    // MARK: Which kinds

    /// The kinds whose Overview has a tree.
    enum Root: String, Equatable, Sendable {
        case pod, deployment, statefulSet, daemonSet, replicaSet, job, cronJob, service, ingress, httpRoute
        case argoApplication, fluxKustomization, fluxHelmRelease

        static func of(_ kind: KubeResourceKind) -> Root? {
            switch (kind.group, kind.resource) {
            case ("", "pods"): .pod
            case ("apps", "deployments"): .deployment
            case ("apps", "statefulsets"): .statefulSet
            case ("apps", "daemonsets"): .daemonSet
            case ("apps", "replicasets"): .replicaSet
            case ("batch", "jobs"): .job
            case ("batch", "cronjobs"): .cronJob
            case ("", "services"): .service
            case ("networking.k8s.io", "ingresses"): .ingress
            case ("gateway.networking.k8s.io", "httproutes"): .httpRoute
            case ("argoproj.io", "applications"): .argoApplication
            case ("kustomize.toolkit.fluxcd.io", "kustomizations"): .fluxKustomization
            case ("helm.toolkit.fluxcd.io", "helmreleases"): .fluxHelmRelease
            default: nil
            }
        }

        /// Argo's or Flux's: a tree of what it says it manages.
        var isGitOps: Bool { [.argoApplication, .fluxKustomization, .fluxHelmRelease].contains(self) }

        /// A workload: its pods are what it owns, its pod template what they use.
        var isWorkload: Bool { [.deployment, .statefulSet, .daemonSet, .replicaSet, .job, .cronJob].contains(self) }
    }

    // MARK: What to read

    /// One list the tree reads: which kind (group and resource; discovery
    /// says where), in which namespace, by which selector, and whether as
    /// a Table (names only: ConfigMaps, Secrets, PVCs, ServiceAccounts) or
    /// as objects.
    struct Read: Equatable, Hashable, Sendable {
        enum What: String, Equatable, Hashable, Sendable {
            case replicaSets, pods, jobs, services, ingresses, routes, configMaps, secrets, claims, accounts
            /// A Flux HelmRelease's: what Helm made, by its labels.
            case deployments, statefulSets, daemonSets
        }

        var what: What
        var namespace: String
        var labelSelector: String?

        var group: String { Self.place[what]!.group }
        var resource: String { Self.place[what]!.resource }
        var kind: String { Self.place[what]!.kind }
        var limit: Int { what == .pods ? KubeTree.podLimit : KubeTree.listLimit }
        /// Names only, from the Table: never a Secret's data, nor a ConfigMap's.
        var table: Bool { [.configMaps, .secrets, .claims, .accounts].contains(what) }

        static let place: [What: (group: String, resource: String, kind: String)] = [
            .replicaSets: ("apps", "replicasets", "ReplicaSet"), .pods: ("", "pods", "Pod"), .jobs: ("batch", "jobs", "Job"),
            .services: ("", "services", "Service"), .ingresses: ("networking.k8s.io", "ingresses", "Ingress"),
            .routes: ("gateway.networking.k8s.io", "httproutes", "HTTPRoute"), .configMaps: ("", "configmaps", "ConfigMap"),
            .secrets: ("", "secrets", "Secret"), .claims: ("", "persistentvolumeclaims", "PersistentVolumeClaim"),
            .accounts: ("", "serviceaccounts", "ServiceAccount"), .deployments: ("apps", "deployments", "Deployment"),
            .statefulSets: ("apps", "statefulsets", "StatefulSet"), .daemonSets: ("apps", "daemonsets", "DaemonSet"),
        ]

        /// What a list says of itself in a note: `pods`, `ConfigMaps`.
        var said: String {
            switch what {
            case .pods: "pods"
            case .claims: "PersistentVolumeClaims"
            case .routes: "HTTPRoutes"
            default: kind + "s"
            }
        }
    }

    /// The lists the root's object needs, first: its owned objects by its
    /// selector, what it references by name, the Services and routes that
    /// could reach its pods. Only what it can use: a pod that references no
    /// ConfigMap reads no ConfigMap list. Argo's and Flux's need none, but a
    /// HelmRelease's objects by Helm's labels.
    static func reads(_ root: Root, object: [String: Any]) -> [Read] {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        guard let namespace = metadata["namespace"] as? String else { return [] }
        let spec = object["spec"] as? [String: Any] ?? [:]
        var reads: [Read] = []
        let selector = KubeSelector.text(spec["selector"])
        switch root {
        case .deployment:
            if let selector {
                reads.append(Read(what: .replicaSets, namespace: namespace, labelSelector: selector))
                reads.append(Read(what: .pods, namespace: namespace, labelSelector: selector))
            }
        case .statefulSet, .daemonSet, .replicaSet, .job:
            if let selector { reads.append(Read(what: .pods, namespace: namespace, labelSelector: selector)) }
        case .cronJob:
            reads.append(Read(what: .jobs, namespace: namespace))
        case .service:
            if let selector = KubeSelector.text(spec["selector"]) { reads.append(Read(what: .pods, namespace: namespace, labelSelector: selector)) }
            reads += [Read(what: .ingresses, namespace: namespace), Read(what: .routes, namespace: namespace)]
            return reads
        case .ingress:
            reads.append(Read(what: .services, namespace: namespace))
            if !ingressTLSSecrets(object).isEmpty { reads.append(Read(what: .secrets, namespace: namespace)) }
            return reads
        case .httpRoute:
            reads.append(Read(what: .services, namespace: namespace))
            return reads
        case .fluxHelmRelease:
            // Released into another cluster (spec.kubeConfig): its objects are there, not here.
            guard spec["kubeConfig"] == nil else { return [] }
            let name = metadata["name"] as? String ?? ""
            let target = spec["targetNamespace"] as? String ?? namespace
            let labels = "\(fluxHelmName)=\(name),\(fluxHelmNamespace)=\(namespace)"
            return [.deployments, .statefulSets, .daemonSets, .services].map { Read(what: $0, namespace: target, labelSelector: labels) }
        case .pod, .argoApplication, .fluxKustomization:
            break
        }
        guard !root.isGitOps else { return [] }
        let references = self.references(podSpec(root, object))
        let kinds = Set(references.map(\.kind))
        if kinds.contains("ConfigMap") { reads.append(Read(what: .configMaps, namespace: namespace)) }
        if kinds.contains("Secret") { reads.append(Read(what: .secrets, namespace: namespace)) }
        if kinds.contains("PersistentVolumeClaim") || !claimTemplates(root, object).isEmpty { reads.append(Read(what: .claims, namespace: namespace)) }
        if kinds.contains("ServiceAccount") { reads.append(Read(what: .accounts, namespace: namespace)) }
        reads += [
            Read(what: .services, namespace: namespace), Read(what: .ingresses, namespace: namespace), Read(what: .routes, namespace: namespace),
        ]
        return reads
    }

    /// The lists the first ones lead to: a CronJob's newest Jobs' pods (each
    /// Job's selector), the pods of the Services an Ingress or a route sends
    /// to (each Service's selector).
    static func followUps(_ root: Root, object: [String: Any], read: KubeTreeRead) -> [Read] {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        guard let namespace = metadata["namespace"] as? String else { return [] }
        switch root {
        case .cronJob:
            let uid = metadata["uid"] as? String ?? ""
            return ownedJobs(read.items(.jobs), owner: uid).prefix(jobsFollowed).compactMap { job in
                KubeSelector.text((job["spec"] as? [String: Any])?["selector"]).map { Read(what: .pods, namespace: namespace, labelSelector: $0) }
            }
        case .ingress, .httpRoute:
            let wanted = Set((root == .ingress ? ingressBackends(object) : routeBackends(object)).map(\.service))
            let services = read.items(.services).filter { wanted.contains(name(of: $0)) }
            var selectors: [String] = []
            for service in services {
                guard let selector = KubeSelector.text((service["spec"] as? [String: Any])?["selector"]), !selectors.contains(selector) else { continue }
                selectors.append(selector)
            }
            return selectors.prefix(10).map { Read(what: .pods, namespace: namespace, labelSelector: $0) }
        default:
            return []
        }
    }

    // MARK: Building

    /// The tree of `read`'s root, from what was read.
    static func build(_ root: Root, read: KubeTreeRead) -> KubeTree {
        let object = read.rootObject
        if root.isGitOps { return KubeGitOpsTree.build(root, object: object, read: read) }
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let kind = object["kind"] as? String ?? ""
        let name = metadata["name"] as? String ?? ""
        let namespace = metadata["namespace"] as? String
        let (health, status) = Self.health(kind: kind, object: object)
        var tree = KubeTree(
            root: KubeTreeNode(
                id: "\(kind)/\(name)", kind: kind, name: name, namespace: namespace, apiVersion: object["apiVersion"] as? String, relation: .root,
                health: health, status: status),
            notes: read.notes)
        switch root {
        case .service:
            serviceTree(&tree, object: object, read: read)
        case .ingress, .httpRoute:
            routeTree(&tree, root, object: object, read: read)
        default:
            workloadTree(&tree, root, object: object, read: read)
        }
        return tree
    }

    /// A pod or a workload: what it owns, down to containers; what its pods
    /// use; the Services that select them and the routes to those.
    private static func workloadTree(_ tree: inout KubeTree, _ root: Root, object: [String: Any], read: KubeTreeRead) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let uid = metadata["uid"] as? String ?? ""
        let namespace = metadata["namespace"] as? String
        let id = tree.root.id
        let pods = read.items(.pods)
        var allPods: [[String: Any]] = []
        switch root {
        case .pod:
            tree.root.children += containers(of: object, parent: id)
            allPods = [object]
        case .deployment:
            let sets = read.items(.replicaSets).filter { owners(of: $0).contains(uid) }.sorted { (revision(of: $0) ?? 0) > (revision(of: $1) ?? 0) }
            var hidden = 0
            for (index, set) in sets.enumerated() {
                let setUID = (set["metadata"] as? [String: Any])?["uid"] as? String ?? ""
                let owned = pods.filter { owners(of: $0).contains(setUID) }
                let replicas = KubeRollout.int((set["spec"] as? [String: Any])?["replicas"]) ?? 0
                guard index == 0 || replicas > 0 || !owned.isEmpty else {
                    hidden += 1
                    continue
                }
                var node = objectNode(set, kind: "ReplicaSet", apiVersion: "apps/v1", relation: .owns, parent: id)
                node.how = revision(of: set).map { "revision \($0)" }
                node.children = podNodes(owned, parent: node.id, notes: &tree.notes, owner: name(of: set))
                tree.root.children.append(node)
                allPods += owned
            }
            if hidden > 0 { tree.notes.append("\(hidden) older ReplicaSet\(hidden == 1 ? "" : "s"), scaled to 0, left out.") }
        case .cronJob:
            for job in ownedJobs(read.items(.jobs), owner: uid) {
                var node = objectNode(job, kind: "Job", apiVersion: "batch/v1", relation: .owns, parent: id)
                let jobUID = (job["metadata"] as? [String: Any])?["uid"] as? String ?? ""
                let owned = pods.filter { owners(of: $0).contains(jobUID) }
                node.children = podNodes(owned, parent: node.id, notes: &tree.notes, owner: name(of: job))
                tree.root.children.append(node)
                allPods += owned
            }
        default:
            let owned = pods.filter { owners(of: $0).contains(uid) }
            tree.root.children += podNodes(owned, parent: id, notes: &tree.notes, owner: name(of: object))
            allPods = owned
        }

        // Across: what its pods use, by name.
        let spec = podSpec(root, object)
        for reference in references(spec) {
            tree.root.children.append(referenceNode(reference, namespace: namespace, read: read, parent: id))
        }
        for template in claimTemplates(root, object) {
            tree.root.children += claimNodes(template: template, workload: name(of: object), namespace: namespace, read: read, parent: id)
        }

        // The Services that select its pods (by their labels, or the
        // template's), and what routes to them.
        let labels =
            root == .pod
            ? (metadata["labels"] as? [String: String] ?? [:])
            : ((((podTemplate(root, object))["metadata"] as? [String: Any])?["labels"]) as? [String: String] ?? [:])
        guard let services = read.list(.services) else { return }
        // No pod to select isn't always a fault: none wanted (scaled to 0,
        // no Job running, done), or its pods weren't listed (refused, failed).
        let podsRead = root == .pod || read.list(.pods) != nil
        let idle = allPods.isEmpty ? idleReason(root, object: object, jobs: ownedJobs(read.items(.jobs), owner: uid).count, podsRead: podsRead) : nil
        for service in services.items {
            guard let selector = (service["spec"] as? [String: Any])?["selector"] as? [String: String], !selector.isEmpty,
                selector.allSatisfy({ labels[$0.key] == $0.value })
            else { continue }
            let selected = allPods.filter { matches(selector, $0) }
            var node = objectNode(service, kind: "Service", apiVersion: "v1", relation: .selects, parent: id)
            if root == .pod {
                (node.health, node.status) = (.good, "selects this pod")
            } else if selected.isEmpty, let idle {
                (node.health, node.status) = (.dim, idle)
            } else if selected.isEmpty, !podsRead {
                (node.health, node.status) = (.unknown, "not checked: its pods weren't listed")
            } else if selected.isEmpty {
                (node.health, node.status) = (.bad, "selects none of its pods")
            } else {
                (node.health, node.status) = (.good, "selects \(selected.count) of its pod\(selected.count == 1 ? "" : "s")")
            }
            node.how = ports(of: service)
            node.children = routesTo(service, read: read, parent: node.id)
            tree.root.children.append(node)
        }
    }

    /// Why a workload with no pod has none to be selected — nil when it
    /// should have some: scaled to 0, a DaemonSet scheduling none, a Job
    /// done, a CronJob with no Job running a pod now.
    static func idleReason(_ root: Root, object: [String: Any], jobs: Int, podsRead: Bool) -> String? {
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        switch root {
        case .deployment, .statefulSet, .replicaSet:
            return KubeRollout.int(spec["replicas"]) == 0 ? "scaled to 0: no pod to select" : nil
        case .daemonSet:
            return KubeRollout.int(status["desiredNumberScheduled"]) == 0 ? "schedules no pod: none to select" : nil
        case .job:
            let done = status["completionTime"] != nil || ((KubeRollout.int(status["active"]) ?? 0) == 0 && (KubeRollout.int(status["succeeded"]) ?? 0) > 0)
            return done ? "the Job is done: no pod to select" : nil
        case .cronJob:
            return jobs == 0 ? "no Job now: no pod to select" : podsRead ? "none of its Jobs has a pod now" : nil
        default:
            return nil
        }
    }

    /// A Service: the pods it selects — none is red —, and what routes to it.
    private static func serviceTree(_ tree: inout KubeTree, object: [String: Any], read: KubeTreeRead) {
        let selector = (object["spec"] as? [String: Any])?["selector"] as? [String: String] ?? [:]
        let id = tree.root.id
        if selector.isEmpty {
            (tree.root.health, tree.root.status) = (.dim, "no selector: its endpoints are set by hand")
        } else if read.list(.pods) != nil {
            let pods = read.items(.pods).filter { matches(selector, $0) }
            tree.root.children += podNodes(pods, parent: id, notes: &tree.notes, owner: name(of: object), relation: .selects, containers: false)
            (tree.root.health, tree.root.status) =
                pods.isEmpty ? (.bad, "selects no pod") : (.good, "selects \(pods.count) pod\(pods.count == 1 ? "" : "s")")
        }
        tree.root.children += routesTo(object, read: read, parent: id)
    }

    /// An Ingress or an HTTPRoute: the Services it sends to — missing, or
    /// selecting nothing, red; a port the Service hasn't, red — with their
    /// pods; an Ingress's TLS Secrets by name, a route's Gateways.
    private static func routeTree(_ tree: inout KubeTree, _ root: Root, object: [String: Any], read: KubeTreeRead) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let namespace = metadata["namespace"] as? String
        let id = tree.root.id
        if root == .httpRoute {
            for parent in routeParents(object) {
                var node = KubeTreeNode(
                    id: "\(id)/uses/Gateway/\(parent.namespace ?? "")/\(parent.name)", kind: parent.kind, name: parent.name, namespace: parent.namespace ?? namespace,
                    apiVersion: parent.group + "/v1", relation: .uses, how: parent.section.map { "parent, listener \($0)" } ?? "parent", health: .unknown,
                    status: nil)
                if let condition = routeCondition(object, parent: parent.name) {
                    (node.health, node.status) = condition
                }
                tree.root.children.append(node)
            }
        }
        let backends = root == .ingress ? ingressBackends(object) : routeBackends(object)
        let services = read.list(.services)
        let pods = read.items(.pods)
        var seen: Set<String> = []
        for backend in backends where seen.insert(backend.service + "|" + (backend.port ?? "")).inserted {
            var node = KubeTreeNode(
                id: "\(id)/routes/Service/\(backend.service)/\(backend.port ?? "")", kind: "Service", name: backend.service, namespace: namespace,
                apiVersion: "v1", relation: .routes, how: backend.said, health: .unknown, status: "not checked")
            if let services {
                if let service = services.items.first(where: { name(of: $0) == backend.service }) {
                    let selector = (service["spec"] as? [String: Any])?["selector"] as? [String: String] ?? [:]
                    let selected = pods.filter { matches(selector, $0) }
                    if let port = backend.port, !hasPort(service, port) {
                        (node.health, node.status) = (.bad, "has no port \(port)")
                    } else if selector.isEmpty {
                        (node.health, node.status) = (.dim, "no selector")
                    } else if selected.isEmpty {
                        (node.health, node.status) = (.bad, "selects no pod")
                    } else {
                        (node.health, node.status) = (.good, "selects \(selected.count) pod\(selected.count == 1 ? "" : "s")")
                    }
                    if !selector.isEmpty {
                        node.children = podNodes(selected, parent: node.id, notes: &tree.notes, owner: backend.service, relation: .selects, containers: false)
                    }
                } else {
                    (node.health, node.status) = services.complete ? (.missing, "not found") : (.unknown, "not checked: the list was cut")
                }
            }
            tree.root.children.append(node)
        }
        if root == .ingress {
            for secret in ingressTLSSecrets(object) {
                tree.root.children.append(
                    referenceNode(Reference(kind: "Secret", name: secret, how: ["tls"], optional: false), namespace: namespace, read: read, parent: id))
            }
        }
    }

    // MARK: Nodes

    private static func objectNode(_ object: [String: Any], kind: String, apiVersion: String, relation: KubeTreeNode.Relation, parent: String) -> KubeTreeNode {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let name = metadata["name"] as? String ?? ""
        let (health, status) = health(kind: kind, object: object)
        return KubeTreeNode(
            id: "\(parent)/\(relation.rawValue)/\(kind)/\(name)", kind: kind, name: name, namespace: metadata["namespace"] as? String, apiVersion: apiVersion,
            relation: relation, health: health, status: status)
    }

    /// Pods, by name, each with its containers — at most `podsShown`, the rest said.
    private static func podNodes(
        _ pods: [[String: Any]], parent: String, notes: inout [String], owner: String, relation: KubeTreeNode.Relation = .owns, containers: Bool = true
    ) -> [KubeTreeNode] {
        let sorted = pods.sorted { name(of: $0) < name(of: $1) }
        if sorted.count > podsShown { notes.append("\(owner): \(sorted.count - podsShown) more pods not drawn — the first \(podsShown) are.") }
        return sorted.prefix(podsShown).map { pod in
            var node = objectNode(pod, kind: "Pod", apiVersion: "v1", relation: relation, parent: parent)
            if containers { node.children = self.containers(of: pod, parent: node.id) }
            return node
        }
    }

    /// A pod's containers, as its Overview says them.
    private static func containers(of pod: [String: Any], parent: String) -> [KubeTreeNode] {
        let spec = pod["spec"] as? [String: Any] ?? [:]
        let statuses = Dictionary(
            ((pod["status"] as? [String: Any])?["containerStatuses"] as? [[String: Any]] ?? []).compactMap { item in (item["name"] as? String).map { ($0, item) } },
            uniquingKeysWith: { first, _ in first })
        return (spec["containers"] as? [[String: Any]] ?? []).map { container in
            let name = container["name"] as? String ?? ""
            let item = KubeOverview.container(name: name, spec: container, status: statuses[name])
            return KubeTreeNode(
                id: "\(parent)/container/\(name)", kind: "Container", name: name, namespace: nil, apiVersion: nil, relation: .container,
                how: container["image"] as? String, health: health(item.tone), status: item.value)
        }
    }

    static func health(_ tone: KubeOverview.Tone) -> KubeTreeHealth {
        switch tone {
        case .good: .good
        case .waiting: .waiting
        case .bad: .bad
        case .dim: .dim
        case .plain: .unknown
        }
    }

    /// One reference across, checked against its kind's list: there (a
    /// Secret says its type, a PVC its status), missing — red, or grey
    /// when it is optional —, or not checked when the list was cut or refused.
    private static func referenceNode(_ reference: Reference, namespace: String?, read: KubeTreeRead, parent: String) -> KubeTreeNode {
        var node = KubeTreeNode(
            id: "\(parent)/uses/\(reference.kind)/\(reference.name)", kind: reference.kind, name: reference.name, namespace: namespace, apiVersion: "v1",
            relation: .uses, how: reference.how.joined(separator: ", "), health: .unknown, status: "not checked")
        let what: Read.What =
            switch reference.kind {
            case "ConfigMap": .configMaps
            case "Secret": .secrets
            case "PersistentVolumeClaim": .claims
            default: .accounts
            }
        guard let names = read.names(what) else { return node }
        if let status = names.status[reference.name] {
            if reference.kind == "PersistentVolumeClaim" {
                switch status {
                case "Bound": (node.health, node.status) = (.good, status)
                case "Lost": (node.health, node.status) = (.bad, status)
                case "": (node.health, node.status) = (.good, nil)
                default: (node.health, node.status) = (.waiting, status)
                }
            } else {
                (node.health, node.status) = (.good, status.isEmpty ? nil : status)
            }
        } else if !names.complete {
            node.status = "not checked: the list was cut"
        } else if reference.optional {
            (node.health, node.status) = (.dim, "not found (optional)")
        } else {
            (node.health, node.status) = (.missing, "not found")
        }
        return node
    }

    /// A StatefulSet's claims of one template: `<template>-<name>-<ordinal>`.
    private static func claimNodes(template: String, workload: String, namespace: String?, read: KubeTreeRead, parent: String) -> [KubeTreeNode] {
        let prefix = "\(template)-\(workload)-"
        guard let names = read.names(.claims) else {
            return [
                KubeTreeNode(
                    id: "\(parent)/uses/PersistentVolumeClaim/\(prefix)*", kind: "PersistentVolumeClaim", name: "\(prefix)*", namespace: namespace, apiVersion: nil,
                    relation: .uses, how: "volumeClaimTemplate \(template)", health: .unknown, status: "not checked")
            ]
        }
        let claims = names.status.keys.filter { $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count)) != nil }.sorted {
            (Int($0.dropFirst(prefix.count)) ?? 0) < (Int($1.dropFirst(prefix.count)) ?? 0)
        }
        return claims.map { claim in
            referenceNode(Reference(kind: "PersistentVolumeClaim", name: claim, how: ["volumeClaimTemplate \(template)"], optional: false), namespace: namespace, read: read, parent: parent)
        }
    }

    /// The Ingresses and HTTPRoutes that send to a Service: how, and
    /// whether the port they name is one it has.
    private static func routesTo(_ service: [String: Any], read: KubeTreeRead, parent: String) -> [KubeTreeNode] {
        let serviceName = name(of: service)
        var nodes: [KubeTreeNode] = []
        for (what, kind, apiVersion) in [(Read.What.ingresses, "Ingress", "networking.k8s.io/v1"), (.routes, "HTTPRoute", "gateway.networking.k8s.io/v1")] {
            for route in read.items(what) {
                let backends = (what == .ingresses ? ingressBackends(route) : routeBackends(route)).filter { $0.service == serviceName }
                guard !backends.isEmpty else { continue }
                var node = objectNode(route, kind: kind, apiVersion: route["apiVersion"] as? String ?? apiVersion, relation: .routes, parent: parent)
                node.how = backends.map(\.said).joined(separator: ", ")
                if let missing = backends.compactMap(\.port).first(where: { !hasPort(service, $0) }) {
                    (node.health, node.status) = (.bad, "sends to port \(missing), which \(serviceName) hasn't")
                } else if what == .routes, let condition = routeCondition(route, parent: nil), condition.0.isProblem {
                    (node.health, node.status) = condition
                } else {
                    (node.health, node.status) = (.good, nil)
                }
                nodes.append(node)
            }
        }
        return nodes
    }

    // MARK: Health

    /// What an object's own state says: a pod's phase and containers, a
    /// workload's replicas and rollout, a Job's outcome, a claim's phase,
    /// else its `Ready` condition. Grey when nothing says.
    static func health(kind: String, object: [String: Any]) -> (KubeTreeHealth, String?) {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let spec = object["spec"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        let int = KubeRollout.int
        if metadata["deletionTimestamp"] != nil { return (.waiting, "Terminating") }
        switch kind {
        case "Pod":
            return podHealth(object)
        case "Deployment", "StatefulSet", "DaemonSet":
            let (wanted, ready) =
                kind == "DaemonSet"
                ? (int(status["desiredNumberScheduled"]) ?? 0, int(status["numberReady"]) ?? 0) : (int(spec["replicas"]) ?? 1, int(status["readyReplicas"]) ?? 0)
            let replicas = "\(ready)/\(wanted) ready"
            // A list's items carry no `kind`: the rollout is read as the kind it is.
            var typed = object
            if typed["kind"] == nil { typed["kind"] = kind }
            switch KubeRollout.of(typed)?.state {
            case .stuck?: return (.bad, "\(replicas) · rollout stuck")
            case .paused?: return (.dim, "\(replicas) · paused")
            case .complete? where ready >= wanted: return (wanted == 0 ? .dim : .good, wanted == 0 ? "scaled to 0" : replicas)
            default: return (.waiting, replicas)
            }
        case "ReplicaSet":
            let wanted = int(spec["replicas"]) ?? 0
            let ready = int(status["readyReplicas"]) ?? 0
            if wanted == 0 { return (.dim, "scaled to 0") }
            return (ready >= wanted ? .good : .waiting, "\(ready)/\(wanted) ready")
        case "Job":
            let conditions = status["conditions"] as? [[String: Any]] ?? []
            if conditions.contains(where: { $0["type"] as? String == "Failed" && $0["status"] as? String == "True" }) {
                return (.bad, "Failed" + ((conditions.first { $0["type"] as? String == "Failed" }?["reason"] as? String).map { ": \($0)" } ?? ""))
            }
            if conditions.contains(where: { $0["type"] as? String == "Complete" && $0["status"] as? String == "True" }) { return (.good, "Complete") }
            if let active = int(status["active"]), active > 0 { return (.waiting, "\(active) running") }
            return (.dim, nil)
        case "CronJob":
            if spec["suspend"] as? Bool == true { return (.dim, "suspended") }
            return (.good, spec["schedule"] as? String)
        case "PersistentVolumeClaim":
            let phase = status["phase"] as? String ?? ""
            return (phase == "Bound" ? .good : phase == "Lost" ? .bad : .waiting, phase.isEmpty ? nil : phase)
        case "Service":
            return (.dim, spec["type"] as? String ?? "ClusterIP")
        default:
            return readyHealth(object)
        }
    }

    /// A pod: its first container that is failing or waiting says why;
    /// else its phase and readiness.
    static func podHealth(_ pod: [String: Any]) -> (KubeTreeHealth, String?) {
        let status = pod["status"] as? [String: Any] ?? [:]
        let phase = status["phase"] as? String ?? "Unknown"
        let containers = (status["initContainerStatuses"] as? [[String: Any]] ?? []) + (status["containerStatuses"] as? [[String: Any]] ?? [])
        let restarts = containers.reduce(0) { $0 + (KubeRollout.int($1["restartCount"]) ?? 0) }
        let said = { (text: String) in restarts > 0 ? "\(text) · \(restarts) restart\(restarts == 1 ? "" : "s")" : text }
        if phase == "Succeeded" { return (.dim, "Completed") }
        if phase == "Failed" { return (.bad, said(status["reason"] as? String ?? "Failed")) }
        for container in containers {
            let state = container["state"] as? [String: Any] ?? [:]
            if let waiting = state["waiting"] as? [String: Any], let reason = waiting["reason"] as? String, reason != "PodInitializing" {
                return (failingReasons.contains(reason) || reason.hasSuffix("Error") ? .bad : .waiting, said(reason))
            }
            if let terminated = state["terminated"] as? [String: Any], (KubeRollout.int(terminated["exitCode"]) ?? 0) != 0 {
                return (.bad, said(terminated["reason"] as? String ?? "Error"))
            }
        }
        if phase == "Pending" { return (.waiting, "Pending") }
        let regular = status["containerStatuses"] as? [[String: Any]] ?? []
        let ready = regular.filter { $0["ready"] as? Bool == true }.count
        if phase == "Running", ready == regular.count { return (.good, said("Running")) }
        return (.waiting, said("\(phase), \(ready)/\(regular.count) ready"))
    }

    /// An object's `Ready` condition, as Flux, cert-manager and Gateway
    /// API write it: True green, False red with its reason, Unknown orange.
    static func readyHealth(_ object: [String: Any]) -> (KubeTreeHealth, String?) {
        let spec = object["spec"] as? [String: Any] ?? [:]
        if spec["suspend"] as? Bool == true { return (.dim, "suspended") }
        let conditions = (object["status"] as? [String: Any])?["conditions"] as? [[String: Any]] ?? []
        guard let ready = conditions.first(where: { $0["type"] as? String == "Ready" }) else { return (.dim, nil) }
        let reason = ready["reason"] as? String
        switch ready["status"] as? String {
        case "True": return (.good, "Ready")
        case "False": return (.bad, "Not ready" + (reason.map { ": \($0)" } ?? ""))
        default: return (.waiting, reason ?? "Reconciling")
        }
    }

    // MARK: References

    /// A name a pod spec uses, and how.
    struct Reference: Equatable, Sendable {
        var kind: String
        var name: String
        var how: [String]
        /// `optional: true`: the pod starts without it.
        var optional: Bool
    }

    /// The pod spec its pods run: a pod's own, a workload's template's, a CronJob's Job's.
    static func podSpec(_ root: Root, _ object: [String: Any]) -> [String: Any] {
        root == .pod ? object["spec"] as? [String: Any] ?? [:] : podTemplate(root, object)["spec"] as? [String: Any] ?? [:]
    }

    static func podTemplate(_ root: Root, _ object: [String: Any]) -> [String: Any] {
        let spec = object["spec"] as? [String: Any] ?? [:]
        if root == .cronJob {
            return ((spec["jobTemplate"] as? [String: Any])?["spec"] as? [String: Any])?["template"] as? [String: Any] ?? [:]
        }
        return spec["template"] as? [String: Any] ?? [:]
    }

    /// The ConfigMaps, Secrets, PVCs and ServiceAccount a pod spec names —
    /// from its volumes (projected ones too), its containers' `env` and
    /// `envFrom`, its image pull secrets — each once, with every way it is
    /// used. A Secret is a name: its data is never read.
    static func references(_ spec: [String: Any]) -> [Reference] {
        var found: [Reference] = []
        func add(_ kind: String, _ name: String?, _ how: String, optional: Bool = false) {
            guard let name, !name.isEmpty else { return }
            if let index = found.firstIndex(where: { $0.kind == kind && $0.name == name }) {
                if !found[index].how.contains(how) { found[index].how.append(how) }
                found[index].optional = found[index].optional && optional
            } else {
                found.append(Reference(kind: kind, name: name, how: [how], optional: optional))
            }
        }
        for volume in spec["volumes"] as? [[String: Any]] ?? [] {
            let label = "volume \(volume["name"] as? String ?? "")"
            if let map = volume["configMap"] as? [String: Any] { add("ConfigMap", map["name"] as? String, label, optional: map["optional"] as? Bool == true) }
            if let secret = volume["secret"] as? [String: Any] {
                add("Secret", secret["secretName"] as? String, label, optional: secret["optional"] as? Bool == true)
            }
            if let claim = volume["persistentVolumeClaim"] as? [String: Any] { add("PersistentVolumeClaim", claim["claimName"] as? String, label) }
            for source in (volume["projected"] as? [String: Any])?["sources"] as? [[String: Any]] ?? [] {
                if let map = source["configMap"] as? [String: Any] { add("ConfigMap", map["name"] as? String, label, optional: map["optional"] as? Bool == true) }
                if let secret = source["secret"] as? [String: Any] { add("Secret", secret["name"] as? String, label, optional: secret["optional"] as? Bool == true) }
            }
        }
        let containers = (spec["initContainers"] as? [[String: Any]] ?? []) + (spec["containers"] as? [[String: Any]] ?? [])
        for container in containers {
            for source in container["envFrom"] as? [[String: Any]] ?? [] {
                if let map = source["configMapRef"] as? [String: Any] { add("ConfigMap", map["name"] as? String, "envFrom", optional: map["optional"] as? Bool == true) }
                if let secret = source["secretRef"] as? [String: Any] {
                    add("Secret", secret["name"] as? String, "envFrom", optional: secret["optional"] as? Bool == true)
                }
            }
            for variable in container["env"] as? [[String: Any]] ?? [] {
                let from = variable["valueFrom"] as? [String: Any] ?? [:]
                let label = "env \(variable["name"] as? String ?? "")"
                if let key = from["configMapKeyRef"] as? [String: Any] { add("ConfigMap", key["name"] as? String, label, optional: key["optional"] as? Bool == true) }
                if let key = from["secretKeyRef"] as? [String: Any] { add("Secret", key["name"] as? String, label, optional: key["optional"] as? Bool == true) }
            }
        }
        for pull in spec["imagePullSecrets"] as? [[String: Any]] ?? [] { add("Secret", pull["name"] as? String, "imagePullSecrets") }
        add("ServiceAccount", (spec["serviceAccountName"] as? String) ?? (spec["serviceAccount"] as? String) ?? "default", "serviceAccount")
        let order = ["ConfigMap", "Secret", "PersistentVolumeClaim", "ServiceAccount"]
        return found.enumerated().sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.element.kind) ?? 9, order.firstIndex(of: b.element.kind) ?? 9)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// A StatefulSet's `volumeClaimTemplates`' names.
    static func claimTemplates(_ root: Root, _ object: [String: Any]) -> [String] {
        guard root == .statefulSet else { return [] }
        return ((object["spec"] as? [String: Any])?["volumeClaimTemplates"] as? [[String: Any]] ?? []).compactMap {
            ($0["metadata"] as? [String: Any])?["name"] as? String
        }
    }

    /// Where a rule sends: a Service, by name, and a port (a number or a name).
    struct Backend: Equatable, Sendable {
        var service: String
        var port: String?
        /// `shop.example/api → 8080`.
        var said: String
    }

    static func ingressBackends(_ ingress: [String: Any]) -> [Backend] {
        let spec = ingress["spec"] as? [String: Any] ?? [:]
        func backend(_ value: Any?, _ place: String) -> Backend? {
            guard let service = (value as? [String: Any])?["service"] as? [String: Any], let name = service["name"] as? String else { return nil }
            let port = (service["port"] as? [String: Any]).flatMap { port in
                KubeRollout.int(port["number"]).map(String.init) ?? port["name"] as? String
            }
            return Backend(service: name, port: port, said: place + (port.map { " → \($0)" } ?? ""))
        }
        var backends: [Backend] = []
        if let fallback = backend(spec["defaultBackend"], "default") { backends.append(fallback) }
        for rule in spec["rules"] as? [[String: Any]] ?? [] {
            let host = rule["host"] as? String ?? "*"
            for path in (rule["http"] as? [String: Any])?["paths"] as? [[String: Any]] ?? [] {
                if let found = backend(path["backend"], host + (path["path"] as? String ?? "/")) { backends.append(found) }
            }
        }
        return backends
    }

    static func ingressTLSSecrets(_ ingress: [String: Any]) -> [String] {
        var names: [String] = []
        for tls in (ingress["spec"] as? [String: Any])?["tls"] as? [[String: Any]] ?? [] {
            if let name = tls["secretName"] as? String, !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// An HTTPRoute's Service backends (`backendRefs` of the core group's
    /// Service kind, the default), each rule's matches said.
    static func routeBackends(_ route: [String: Any]) -> [Backend] {
        var backends: [Backend] = []
        for rule in (route["spec"] as? [String: Any])?["rules"] as? [[String: Any]] ?? [] {
            let paths = (rule["matches"] as? [[String: Any]] ?? []).compactMap { (($0["path"] as? [String: Any])?["value"] as? String) }
            let place = paths.isEmpty ? "/" : paths.joined(separator: ", ")
            for ref in rule["backendRefs"] as? [[String: Any]] ?? [] {
                guard (ref["group"] as? String ?? "").isEmpty, (ref["kind"] as? String ?? "Service") == "Service", let name = ref["name"] as? String else { continue }
                let port = KubeRollout.int(ref["port"]).map(String.init)
                backends.append(Backend(service: name, port: port, said: place + (port.map { " → \($0)" } ?? "")))
            }
        }
        return backends
    }

    struct Parent: Equatable, Sendable {
        var group: String
        var kind: String
        var namespace: String?
        var name: String
        var section: String?
    }

    static func routeParents(_ route: [String: Any]) -> [Parent] {
        ((route["spec"] as? [String: Any])?["parentRefs"] as? [[String: Any]] ?? []).compactMap { ref in
            guard let name = ref["name"] as? String else { return nil }
            return Parent(
                group: ref["group"] as? String ?? "gateway.networking.k8s.io", kind: ref["kind"] as? String ?? "Gateway", namespace: ref["namespace"] as? String,
                name: name, section: ref["sectionName"] as? String)
        }
    }

    /// What a route's status says of a parent (or any): `Accepted` or
    /// `ResolvedRefs` False is red, with its reason.
    static func routeCondition(_ route: [String: Any], parent: String?) -> (KubeTreeHealth, String?)? {
        let parents = ((route["status"] as? [String: Any])?["parents"] as? [[String: Any]] ?? []).filter { entry in
            parent == nil || (entry["parentRef"] as? [String: Any])?["name"] as? String == parent
        }
        guard !parents.isEmpty else { return nil }
        for entry in parents {
            for condition in entry["conditions"] as? [[String: Any]] ?? [] where ["Accepted", "ResolvedRefs"].contains(condition["type"] as? String ?? "") {
                if condition["status"] as? String == "False" {
                    return (.bad, "\(condition["type"] as? String ?? ""): \(condition["reason"] as? String ?? "False")")
                }
            }
        }
        return (.good, "Accepted")
    }

    // MARK: Helpers

    static func name(of object: [String: Any]) -> String { (object["metadata"] as? [String: Any])?["name"] as? String ?? "" }

    static func owners(of object: [String: Any]) -> [String] {
        ((object["metadata"] as? [String: Any])?["ownerReferences"] as? [[String: Any]] ?? []).compactMap { $0["uid"] as? String }
    }

    private static func revision(of set: [String: Any]) -> Int? {
        ((set["metadata"] as? [String: Any])?["annotations"] as? [String: Any])?["deployment.kubernetes.io/revision"].flatMap(KubeRollout.int)
    }

    /// A container waiting for one of these is broken, not on its way.
    static let failingReasons: Set<String> = [
        "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "InvalidImageName", "RunContainerError", "OOMKilled",
    ]

    /// A CronJob's Jobs, newest first.
    static func ownedJobs(_ jobs: [[String: Any]], owner: String) -> [[String: Any]] {
        jobs.filter { owners(of: $0).contains(owner) }.sorted {
            (($0["metadata"] as? [String: Any])?["creationTimestamp"] as? String ?? "") > (($1["metadata"] as? [String: Any])?["creationTimestamp"] as? String ?? "")
        }
    }

    static func matches(_ selector: [String: String], _ pod: [String: Any]) -> Bool {
        guard !selector.isEmpty else { return false }
        let labels = (pod["metadata"] as? [String: Any])?["labels"] as? [String: String] ?? [:]
        return selector.allSatisfy { labels[$0.key] == $0.value }
    }

    /// `80/TCP, 443/TCP`.
    private static func ports(of service: [String: Any]) -> String? {
        let ports = ((service["spec"] as? [String: Any])?["ports"] as? [[String: Any]] ?? []).compactMap { port -> String? in
            KubeRollout.int(port["port"]).map { "\($0)/\(port["protocol"] as? String ?? "TCP")" }
        }
        return ports.isEmpty ? nil : ports.joined(separator: ", ")
    }

    /// Whether a Service has a port, by number or by name.
    static func hasPort(_ service: [String: Any], _ port: String) -> Bool {
        ((service["spec"] as? [String: Any])?["ports"] as? [[String: Any]] ?? []).contains { declared in
            KubeRollout.int(declared["port"]).map(String.init) == port || declared["name"] as? String == port
        }
    }

    /// Flux's Helm controller's labels on what it made.
    static let fluxHelmName = "helm.toolkit.fluxcd.io/name"
    static let fluxHelmNamespace = "helm.toolkit.fluxcd.io/namespace"
}

/// What a tree read, once, as the server answered: the root's object, then
/// each list's answer — a list of objects, or of a Table's names — or why
/// it couldn't be read. Pure.
struct KubeTreeRead: Sendable {
    /// The names a Table listed, each with what its row says (a Secret's
    /// Type, a PVC's Status) — and whether that was all of them.
    struct Names: Equatable, Sendable {
        var status: [String: String]
        var complete: Bool
    }

    /// One list read: its objects, in its kind (a list's items carry no
    /// `kind`), and whether that was all of them.
    struct Objects: @unchecked Sendable {
        var items: [[String: Any]]
        var complete: Bool
    }

    var root: Data
    private(set) var objects: [KubeTree.Read.What: Objects] = [:]
    private(set) var tables: [KubeTree.Read.What: Names] = [:]
    var notes: [String] = []

    init(root: Data) { self.root = root }

    var rootObject: [String: Any] { (try? JSONSerialization.jsonObject(with: root) as? [String: Any]) ?? [:] }

    /// A list's answer added: its objects or its names; several lists of
    /// pods are one.
    mutating func add(_ read: KubeTree.Read, body: Data) {
        guard let list = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            notes.append("The \(read.said) list couldn't be read: the answer isn't JSON.")
            return
        }
        let more = ((list["metadata"] as? [String: Any])?["continue"] as? String).map { !$0.isEmpty } ?? false
        if more { notes.append("More than \(read.limit) \(read.said) in \(read.namespace): only \(read.limit) were read.") }
        if read.table {
            // Not a Table (a proxy that ignored the Accept): dropped unread,
            // said, and what it would have checked not checked.
            guard list["kind"] as? String == "Table", let table = try? KubeTableReader.read(list, namespace: read.namespace) else {
                notes.append("The \(read.kind) list in \(read.namespace) couldn't be read as a Table: its names aren't checked.")
                return
            }
            let column = read.what == .secrets ? "Type" : read.what == .claims ? "Status" : nil
            var names = tables[read.what] ?? Names(status: [:], complete: true)
            for row in table.rows { names.status[row.id.name] = column.flatMap { row.cell($0, in: table.columns)?.text } ?? "" }
            names.complete = names.complete && !more
            tables[read.what] = names
            return
        }
        let items = list["items"] as? [[String: Any]] ?? []
        var objects = self.objects[read.what] ?? Objects(items: [], complete: true)
        let known = Set(objects.items.map(KubeTree.name(of:)))
        objects.items += items.filter { !known.contains(KubeTree.name(of: $0)) }
        objects.complete = objects.complete && !more
        self.objects[read.what] = objects
    }

    /// A list that couldn't be read: said, and its kind not checked.
    mutating func failed(_ read: KubeTree.Read, _ reason: String) {
        notes.append("The \(read.said) in \(read.namespace) couldn't be listed: \(reason)")
    }

    func list(_ what: KubeTree.Read.What) -> Objects? { objects[what] }
    func items(_ what: KubeTree.Read.What) -> [[String: Any]] { objects[what]?.items ?? [] }
    func names(_ what: KubeTree.Read.What) -> Names? { tables[what] }
}
