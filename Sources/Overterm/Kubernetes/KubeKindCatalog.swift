import Foundation

/// The page's sections (docs/design/kubernetes/analysis.md, Section 6):
/// the digits go to them while a Kubernetes list has the keyboard. Each
/// names the built-in kinds it shows, in the order it shows them; Cluster
/// takes the built-in kinds no other names, Custom resources every kind of
/// a group that isn't Kubernetes' own — the CRDs, grouped by API group.
/// Forwards is no kind: the app's port-forwards (`KubeForwards`), on its
/// digit 9 as the design numbers it. Overview and Helm join with their
/// stages. Pure.
enum KubeSection: String, CaseIterable, Identifiable, Sendable {
    case workloads, network, config, storage, access, cluster, custom, forwards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workloads: "Workloads"
        case .network: "Network"
        case .config: "Config"
        case .storage: "Storage"
        case .access: "Access Control"
        case .cluster: "Cluster"
        case .custom: "Custom Resources"
        case .forwards: "Forwards"
        }
    }

    var symbol: String {
        switch self {
        case .workloads: "cube.box"
        case .network: "network"
        case .config: "slider.horizontal.3"
        case .storage: "externaldrive"
        case .access: "person.badge.key"
        case .cluster: "server.rack"
        case .custom: "puzzlepiece.extension"
        case .forwards: "arrow.left.arrow.right"
        }
    }

    /// The built-in kinds it shows, by kubectl's full name, in order. A
    /// kind a cluster doesn't serve is passed over; of two that are one
    /// Kind (`events.events.k8s.io`, the core `events`) the first served
    /// is shown.
    var named: [String] {
        switch self {
        case .workloads:
            [
                "pods", "deployments.apps", "statefulsets.apps", "daemonsets.apps", "replicasets.apps", "jobs.batch", "cronjobs.batch",
                "horizontalpodautoscalers.autoscaling", "replicationcontrollers",
            ]
        case .network:
            [
                "services", "endpoints", "endpointslices.discovery.k8s.io", "ingresses.networking.k8s.io", "ingressclasses.networking.k8s.io",
                "networkpolicies.networking.k8s.io", "gateways.gateway.networking.k8s.io", "httproutes.gateway.networking.k8s.io",
                "gatewayclasses.gateway.networking.k8s.io", "grpcroutes.gateway.networking.k8s.io",
            ]
        case .config:
            [
                "configmaps", "secrets", "resourcequotas", "limitranges", "poddisruptionbudgets.policy", "priorityclasses.scheduling.k8s.io",
                "runtimeclasses.node.k8s.io", "leases.coordination.k8s.io", "mutatingwebhookconfigurations.admissionregistration.k8s.io",
                "validatingwebhookconfigurations.admissionregistration.k8s.io", "validatingadmissionpolicies.admissionregistration.k8s.io",
                "validatingadmissionpolicybindings.admissionregistration.k8s.io",
            ]
        case .storage:
            [
                "persistentvolumeclaims", "persistentvolumes", "storageclasses.storage.k8s.io", "volumeattachments.storage.k8s.io",
                "csidrivers.storage.k8s.io", "csinodes.storage.k8s.io", "csistoragecapacities.storage.k8s.io",
            ]
        case .access:
            [
                "serviceaccounts", "roles.rbac.authorization.k8s.io", "rolebindings.rbac.authorization.k8s.io",
                "clusterroles.rbac.authorization.k8s.io", "clusterrolebindings.rbac.authorization.k8s.io",
            ]
        case .cluster:
            [
                "nodes", "namespaces", "events.events.k8s.io", "events", "customresourcedefinitions.apiextensions.k8s.io",
                "apiservices.apiregistration.k8s.io",
            ]
        case .custom, .forwards: []
        }
    }

    /// Its digit on the list: Forwards is 9, leaving 8 to Helm.
    var key: String { self == .forwards ? "9" : String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// Whether it lists a cluster's kinds (Forwards lists Overterm's own).
    var listsKinds: Bool { self != .forwards }
}

/// What the page offers of a cluster: every kind discovery says can be
/// listed and watched, each in its section. A kind that can't be listed or
/// watched (metrics.k8s.io's, `bindings`, `tokenreviews`) is not offered:
/// a list here is a list kept live. Pure.
struct KubeKindCatalog: Equatable, Sendable {
    private(set) var sections: [KubeSection: [KubeResourceKind]] = [:]

    init() {}

    init(_ discovery: KubeDiscovery) {
        let offered = discovery.kinds.filter(Self.isOffered)
        var placed: Set<String> = []
        /// Kinds of Kubernetes' own groups, by Kind, once placed: the core
        /// `events` isn't shown beside events.k8s.io's.
        var placedKinds: Set<String> = []
        func place(_ kind: KubeResourceKind, in section: KubeSection) {
            guard !placed.contains(kind.fullName) else { return }
            placed.insert(kind.fullName)
            sections[section, default: []].append(kind)
        }
        let byName = Dictionary(offered.map { ($0.fullName, $0) }, uniquingKeysWith: { first, _ in first })
        for section in KubeSection.allCases {
            for name in section.named {
                guard let kind = byName[name], !placedKinds.contains(kind.kind) else { continue }
                placedKinds.insert(kind.kind)
                place(kind, in: section)
            }
        }
        // Kubernetes' own kinds no section names: Cluster's, by title.
        let rest = offered.filter { !placed.contains($0.fullName) && Self.isBuiltIn(group: $0.group) && !placedKinds.contains($0.kind) }
        for kind in rest.sorted(by: { Self.title(of: $0).localizedCaseInsensitiveCompare(Self.title(of: $1)) == .orderedAscending }) {
            placedKinds.insert(kind.kind)
            place(kind, in: .cluster)
        }
        // Everything else is a custom resource: by group, then title.
        let custom = offered.filter { !placed.contains($0.fullName) && !Self.isBuiltIn(group: $0.group) }
        for kind in custom.sorted(by: { ($0.group, Self.title(of: $0)) < ($1.group, Self.title(of: $1)) }) {
            place(kind, in: .custom)
        }
    }

    /// A section's kinds, in the order they show.
    func kinds(in section: KubeSection) -> [KubeResourceKind] { sections[section] ?? [] }

    var all: [KubeResourceKind] { KubeSection.allCases.flatMap { kinds(in: $0) } }

    var isEmpty: Bool { sections.isEmpty }

    /// The section a kind shows in; nil when it isn't offered.
    func section(of kind: KubeResourceKind) -> KubeSection? {
        KubeSection.allCases.first { section in kinds(in: section).contains { $0.fullName == kind.fullName } }
    }

    /// The kind offered under this full name.
    func kind(fullName: String) -> KubeResourceKind? { all.first { $0.fullName == fullName } }

    /// A list here is a list kept live: listed, then watched.
    static func isOffered(_ kind: KubeResourceKind) -> Bool { kind.canList && kind.canWatch }

    /// Kubernetes' own groups: the core, `*.k8s.io`, and the unsuffixed
    /// ones it has always had. Any other group is a custom resource's (or
    /// an aggregated API's that isn't Kubernetes').
    static func isBuiltIn(group: String) -> Bool {
        group.isEmpty || group == "k8s.io" || group.hasSuffix(".k8s.io") || unsuffixedGroups.contains(group)
    }

    static let unsuffixedGroups: Set<String> = ["apps", "batch", "autoscaling", "policy", "extensions"]

    /// What the page calls a kind: its plural Kind (`Deployments`,
    /// `NetworkPolicies`, `Ingresses`), shortened where Lens and k9s do.
    static func title(of kind: KubeResourceKind) -> String {
        if let short = shortTitles[kind.fullName] { return short }
        let name = kind.kind.isEmpty ? kind.resource : kind.kind
        if name.lowercased() == kind.resource { return name }
        return plural(name)
    }

    static let shortTitles: [String: String] = [
        "horizontalpodautoscalers.autoscaling": "HPAs", "poddisruptionbudgets.policy": "PDBs", "persistentvolumeclaims": "PVCs",
        "persistentvolumes": "PVs", "customresourcedefinitions.apiextensions.k8s.io": "CRDs",
        "mutatingwebhookconfigurations.admissionregistration.k8s.io": "Mutating Webhooks",
        "validatingwebhookconfigurations.admissionregistration.k8s.io": "Validating Webhooks",
        "validatingadmissionpolicies.admissionregistration.k8s.io": "Admission Policies",
        "validatingadmissionpolicybindings.admissionregistration.k8s.io": "Admission Policy Bindings",
    ]

    /// English plurals as Kinds need them.
    static func plural(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) { return word.dropLast() + "ies" }
        if ["s", "x", "z", "ch", "sh"].contains(where: { lower.hasSuffix($0) }) { return word + "es" }
        return word + "s"
    }
}
