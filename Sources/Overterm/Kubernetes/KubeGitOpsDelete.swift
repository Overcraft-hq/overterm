import Foundation

/// What deleting an Argo CD or Flux object takes with it (docs/design/
/// kubernetes/gitops.md, 1.1 rows 6–7, G0b):
///
/// - an Application carrying `resources-finalizer.argocd.argoproj.io` (or
///   its `/background` or `/foreground` variant: matched by prefix) has
///   Argo CD delete everything it manages;
/// - a Kustomization with `spec.prune` (or `spec.deletionPolicy: Delete`
///   or `WaitForTermination`, whatever prune says) has Flux delete its
///   inventory — `Orphan` keeps it;
/// - a HelmRelease's delete uninstalls its release;
/// - neither, while suspended: their controllers skip the cascade then;
/// - an ApplicationSet's takes the Applications it generated, and theirs
///   with them, unless `preserveResourcesOnDeletion` keeps what they made.
///
/// Read from the object after the access review, decoded straight into the
/// allow-listed fields below — never a value, a parameter or a manifest —
/// and dropped once the confirmation is made. A read that fails gives the
/// worst case, never no sentence. An object a parent manages says it will
/// be recreated. Pure.
struct KubeGitOpsDelete: Equatable, Sendable {
    enum Tool: Equatable, Sendable {
        case application, applicationSet, kustomization, helmRelease

        /// `Application`, as its CRD names it.
        var kind: String {
            switch self {
            case .application: "Application"
            case .applicationSet: "ApplicationSet"
            case .kustomization: "Kustomization"
            case .helmRelease: "HelmRelease"
            }
        }
    }

    var tool: Tool
    /// Why it couldn't be read; nil when it was. Unread, the worst is said.
    var unread: String?
    /// Argo CD's resources finalizer, as the object carries it.
    var finalizer: String?
    var prune = false
    /// A Kustomization's `spec.deletionPolicy`: MirrorPrune (the default), Delete, WaitForTermination, Orphan.
    var deletionPolicy: String?
    /// A Flux object's `spec.suspend`: its controller then leaves what it applied or installed.
    var suspended = false
    /// An ApplicationSet's `spec.syncPolicy.preserveResourcesOnDeletion`.
    var preservesResources = false
    /// How many objects it manages: an Application's `status.resources`, a Kustomization's inventory.
    var managed = 0
    /// The namespaces those live in (a cluster-scoped one in none).
    var namespaces: Set<String> = []
    /// It deploys to another cluster: an Application's destination, a Flux object's `spec.kubeConfig`.
    var remote = false
    /// What manages it, said: `Kustomization flux-system/flux-system`.
    var parents: [String] = []

    static let argoFinalizer = "resources-finalizer.argocd.argoproj.io"

    /// The GitOps kind `kind` is, if it is one whose delete takes something with it.
    static func tool(_ kind: KubeResourceKind) -> Tool? {
        switch kind.fullName {
        case "applications.argoproj.io": .application
        case "applicationsets.argoproj.io": .applicationSet
        case "kustomizations.kustomize.toolkit.fluxcd.io": .kustomization
        case "helmreleases.helm.toolkit.fluxcd.io": .helmRelease
        default: nil
        }
    }

    /// The three kinds whose delete has their controller delete what they
    /// manage: the name typed on every class (decision 13).
    static func cascades(_ kind: KubeResourceKind) -> Bool {
        guard let tool = tool(kind) else { return false }
        return tool != .applicationSet
    }

    /// Unread: the worst case.
    static func unread(_ tool: Tool, _ why: String) -> KubeGitOpsDelete { KubeGitOpsDelete(tool: tool, unread: why) }

    /// The object as the API gave it, `ref` naming it (a parent naming
    /// itself is no parent).
    static func read(_ data: Data, tool: Tool, ref: KubeObjectRef) throws -> KubeGitOpsDelete {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return facts(wire, tool: tool, namespace: ref.namespace, name: ref.name)
    }

    static func facts(_ wire: Wire, tool: Tool, namespace: String?, name: String) -> KubeGitOpsDelete {
        var facts = KubeGitOpsDelete(tool: tool)
        let metadata = wire.metadata
        facts.finalizer = (metadata?.finalizers ?? []).first { $0 == argoFinalizer || $0.hasPrefix(argoFinalizer + "/") }
        facts.prune = wire.spec?.prune == true
        facts.deletionPolicy = wire.spec?.deletionPolicy.flatMap { $0.isEmpty ? nil : $0 }
        facts.suspended = (tool == .kustomization || tool == .helmRelease) && wire.spec?.suspend == true
        facts.preservesResources = wire.spec?.syncPolicy?.preserveResourcesOnDeletion == true
        switch tool {
        case .application:
            let resources = wire.status?.resources ?? []
            facts.managed = resources.count
            facts.namespaces = Set(resources.compactMap { $0.namespace.flatMap { $0.isEmpty ? nil : $0 } })
            if let destination = wire.spec?.destination {
                var said: [String: Any] = [:]
                if let server = destination.server { said["server"] = server }
                if let name = destination.name { said["name"] = name }
                facts.remote = !KubeGitOpsTree.argoInCluster(said)
            }
        case .kustomization:
            let entries = (wire.status?.inventory?.entries ?? []).compactMap { KubeGitOpsTree.inventoryEntry($0.id ?? "", version: "v1") }
            facts.managed = entries.count
            facts.namespaces = Set(entries.compactMap(\.namespace))
            facts.remote = wire.spec?.kubeConfig != nil
        case .helmRelease:
            facts.remote = wire.spec?.kubeConfig != nil
        case .applicationSet: break
        }
        // What manages it: a parent's marks (app-of-apps, Flux's labels), an ApplicationSet that owns it.
        var parents: [String] = []
        for owner in KubeGitOpsOwner.parse(labels: metadata?.labels?.marks ?? [:], annotations: metadata?.annotations?.marks ?? [:]) {
            // A bootstrap Kustomization applies itself: nothing would make it again.
            if owner.tool.kind == tool.kind, owner.name == name, owner.namespace == nil || owner.namespace == namespace { continue }
            let place = owner.namespace.map { "\($0)/\(owner.name)" } ?? owner.name
            parents.append(owner.isCertain ? "\(owner.tool.kind) \(place)" : "probably Argo CD \(owner.tool.kind) \(place)")
        }
        for owner in metadata?.ownerReferences ?? [] where owner.kind == "ApplicationSet" {
            guard let set = owner.name, !set.isEmpty else { continue }
            parents.append("ApplicationSet " + (namespace.map { "\($0)/\(set)" } ?? set))
        }
        facts.parents = parents
        return facts
    }

    /// Whether its controller deletes what it manages with it (as far as was read).
    var deletesManaged: Bool {
        switch tool {
        case .application: unread != nil || finalizer != nil
        case .kustomization: unread != nil || (!suspended && Self.kustomizationDeletes(prune: prune, policy: deletionPolicy))
        case .helmRelease: unread != nil || !suspended
        case .applicationSet: !preservesResources
        }
    }

    /// Flux's rule: Delete and WaitForTermination always (the latter waits
    /// for it to go), Orphan never, MirrorPrune (the default) as prune says.
    static func kustomizationDeletes(prune: Bool, policy: String?) -> Bool {
        switch policy {
        case "Delete", "WaitForTermination": true
        case "Orphan": false
        default: prune
        }
    }

    /// The confirmation's warning: what goes with it, and who makes it again.
    var said: String {
        var text: String
        let elsewhere = remote ? " — in the other cluster it deploys to" : ""
        switch tool {
        case .application:
            if let unread {
                text = "\(Self.unreadSaid(unread)): Argo CD may delete everything it manages with it."
            } else if let finalizer {
                text =
                    managed > 0
                    ? "Argo CD deletes the \(Self.count(managed, "resource")) it manages with it\(Self.across(namespaces))\(elsewhere) (its \(finalizer) finalizer)."
                    : "Argo CD deletes whatever it manages with it (its \(finalizer) finalizer); it lists none now."
            } else {
                text =
                    "It has no \(Self.argoFinalizer) finalizer: "
                    + (managed > 0 ? "the \(Self.count(managed, "resource")) it manages stay, no longer managed by Argo CD." : "what it manages stays.")
            }
        case .kustomization:
            let why = deletionPolicy.map { "spec.deletionPolicy \($0)" } ?? "spec.prune"
            if let unread {
                text = "\(Self.unreadSaid(unread)): Flux may delete everything it applied with it."
            } else if suspended {
                text =
                    "It is suspended (spec.suspend): Flux removes it without deleting what it applied"
                    + (managed > 0 ? " — the \(Self.count(managed, "object")) in its inventory stay, unless it is resumed first." : ", unless it is resumed first.")
            } else if Self.kustomizationDeletes(prune: prune, policy: deletionPolicy) {
                text =
                    managed > 0
                    ? "Flux deletes the \(Self.count(managed, "object")) in its inventory with it\(Self.across(namespaces))\(elsewhere) (\(why))."
                    : "Flux deletes whatever it applied with it (\(why)); its inventory lists none now."
            } else {
                let kept = deletionPolicy == "Orphan" ? "spec.deletionPolicy Orphan" : "spec.prune is off"
                text = "\(kept): " + (managed > 0 ? "the \(Self.count(managed, "object")) it applied stay." : "what it applied stays.")
            }
        case .helmRelease:
            if unread == nil, suspended {
                text = "It is suspended (spec.suspend): Flux removes it without uninstalling its Helm release, unless it is resumed first."
            } else {
                text = "Flux uninstalls its Helm release with it\(elsewhere): everything the chart made goes."
            }
        case .applicationSet:
            if unread != nil {
                text = "Its generated Applications are deleted with it, and may delete everything they manage."
            } else if preservesResources {
                text = "Its generated Applications are deleted with it; spec.syncPolicy.preserveResourcesOnDeletion keeps what they deployed."
            } else {
                text = "Its generated Applications are deleted with it, and those carrying Argo CD's resources finalizer delete what they manage."
            }
        }
        for parent in parents {
            text += parent.hasPrefix("probably ") ? " \(parent.prefix(1).uppercased() + parent.dropFirst()) manages it: it may be recreated." : " Managed by \(parent): it will be recreated."
        }
        return text
    }

    static func unreadSaid(_ why: String) -> String { why.isEmpty ? "It wasn't read" : "Couldn't read it (\(why))" }

    /// `42 resources`, `1 resource`, `1,204 objects` — grouped the same in every locale.
    static func count(_ number: Int, _ noun: String) -> String {
        "\(grouped(number)) \(noun)\(number == 1 ? "" : "s")"
    }

    static func grouped(_ number: Int) -> String {
        let digits = Array(String(abs(number)))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (number < 0 ? "-" : "") + out
    }

    /// `, across 3 namespaces`, `, in namespace shop`, or nothing.
    static func across(_ namespaces: Set<String>) -> String {
        switch namespaces.count {
        case 0: ""
        case 1: ", in namespace \(namespaces.first!)"
        default: ", across \(grouped(namespaces.count)) namespaces"
        }
    }

    // MARK: The wire

    /// The fields read, and nothing else: unknown keys are skipped by the
    /// decoder, never built — a Helm value, a parameter, a manifest or a
    /// `last-applied-configuration` never reaches memory as a value.
    struct Wire: Decodable, Sendable {
        var metadata: Metadata?
        var spec: Spec?
        var status: Status?

        struct Metadata: Decodable, Sendable {
            var finalizers: [String]?
            var labels: Labels?
            var annotations: Annotations?
            var ownerReferences: [Owner]?
        }

        /// The owner marks only (`KubeGitOpsOwner`).
        struct Labels: Decodable, Sendable {
            var argoInstance: String?
            var appInstance: String?
            var kustomizeName: String?
            var kustomizeNamespace: String?
            var helmName: String?
            var helmNamespace: String?

            enum CodingKeys: String, CodingKey {
                case argoInstance = "argocd.argoproj.io/instance"
                case appInstance = "app.kubernetes.io/instance"
                case kustomizeName = "kustomize.toolkit.fluxcd.io/name"
                case kustomizeNamespace = "kustomize.toolkit.fluxcd.io/namespace"
                case helmName = "helm.toolkit.fluxcd.io/name"
                case helmNamespace = "helm.toolkit.fluxcd.io/namespace"
            }

            var marks: [String: String] {
                var marks: [String: String] = [:]
                marks[KubeGitOpsOwner.argoInstanceLabel] = argoInstance
                marks[KubeGitOpsOwner.appInstanceLabel] = appInstance
                marks[KubeGitOpsOwner.kustomizeName] = kustomizeName
                marks[KubeGitOpsOwner.kustomizeNamespace] = kustomizeNamespace
                marks[KubeGitOpsOwner.helmName] = helmName
                marks[KubeGitOpsOwner.helmNamespace] = helmNamespace
                return marks
            }
        }

        struct Annotations: Decodable, Sendable {
            var trackingID: String?
            var helmRelease: String?

            enum CodingKeys: String, CodingKey {
                case trackingID = "argocd.argoproj.io/tracking-id"
                case helmRelease = "meta.helm.sh/release-name"
            }

            var marks: [String: String] {
                var marks: [String: String] = [:]
                marks[KubeGitOpsOwner.trackingAnnotation] = trackingID
                marks[KubeGitOpsOwner.helmReleaseAnnotation] = helmRelease
                return marks
            }
        }

        struct Owner: Decodable, Sendable {
            var kind: String?
            var name: String?
        }

        struct Spec: Decodable, Sendable {
            var prune: Bool?
            var deletionPolicy: String?
            var suspend: Bool?
            var destination: Destination?
            var kubeConfig: Present?
            var syncPolicy: SyncPolicy?
        }

        struct Destination: Decodable, Sendable {
            var server: String?
            var name: String?
        }

        /// That the key is there; nothing of it read (a Secret's name at most).
        struct Present: Decodable, Sendable {
            init(from decoder: Decoder) throws {}
        }

        struct SyncPolicy: Decodable, Sendable {
            var preserveResourcesOnDeletion: Bool?
        }

        struct Status: Decodable, Sendable {
            var resources: [Resource]?
            var inventory: Inventory?
        }

        struct Resource: Decodable, Sendable {
            var namespace: String?
        }

        struct Inventory: Decodable, Sendable {
            var entries: [Entry]?
        }

        struct Entry: Decodable, Sendable {
            var id: String?
        }
    }

    /// A list's page of them.
    struct WireList: Decodable, Sendable {
        var items: [Wire]?
        var metadata: ListMetadata?

        struct ListMetadata: Decodable, Sendable {
            var `continue`: String?
            var remainingItemCount: Int?
        }
    }
}

/// What a namespace's delete takes through the GitOps objects in it
/// (gitops.md 1.1 row 7): its Applications with Argo CD's finalizer, its
/// pruning Kustomizations, its HelmReleases — and what they manage,
/// wherever it lives. Each kind read in pages of whole objects decoded
/// into `KubeGitOpsDelete.Wire`, bounded. Pure.
struct KubeNamespaceGitOps: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        var tool: KubeGitOpsDelete.Tool
        /// How many of the kind it holds.
        var count = 0
        /// …of which delete what they manage.
        var cascading = 0
        /// What those manage.
        var managed = 0
        /// More than were read: said as "at least".
        var atLeast = false
    }

    var parts: [Part] = []
    /// What the cascading ones manage lives in these.
    var namespaces: Set<String> = []
    /// Kinds whose objects couldn't be read: the worst is said of them.
    var unread: [KubeGitOpsDelete.Tool] = []
    /// The context's discovery wasn't known: which GitOps kinds it serves
    /// couldn't be said, so none were counted — the worst is said.
    var uncounted = false

    /// Discovery unknown: the worst case, never no sentence.
    static let notCounted = KubeNamespaceGitOps(uncounted: true)

    /// The kinds read, as the server serves them, in this order.
    static let wanted: [(String, KubeGitOpsDelete.Tool)] = [
        ("applications.argoproj.io", .application), ("kustomizations.kustomize.toolkit.fluxcd.io", .kustomization),
        ("helmreleases.helm.toolkit.fluxcd.io", .helmRelease),
    ]
    /// At most this many objects of a kind are read; the rest counted by the server's remainingItemCount.
    static let readLimit = 500
    static let pageLimit = 100
    /// Applications carry their resources, history, operation and source
    /// (Helm values too): 100 of them can pass `pageBytes`.
    static let applicationPageLimit = 20
    static let pageBytes = 16 << 20

    static func kinds(in discovery: KubeDiscovery?) -> [(KubeResourceKind, KubeGitOpsDelete.Tool)] {
        guard let discovery else { return [] }
        return wanted.compactMap { name, tool in
            discovery.kinds.first { $0.fullName == name && $0.namespaced && $0.canList }.map { ($0, tool) }
        }
    }

    /// One page of a kind's objects added.
    mutating func add(_ objects: [KubeGitOpsDelete], tool: KubeGitOpsDelete.Tool) {
        var part = parts.first { $0.tool == tool } ?? Part(tool: tool)
        for object in objects {
            part.count += 1
            guard object.deletesManaged else { continue }
            part.cascading += 1
            part.managed += object.managed
            namespaces.formUnion(object.namespaces)
        }
        if let index = parts.firstIndex(where: { $0.tool == tool }) { parts[index] = part } else { parts.append(part) }
    }

    /// A kind read in full added; a kind whose read failed part way is
    /// never merged — it is unread, said once as the worst case.
    mutating func merge(_ other: KubeNamespaceGitOps) {
        for part in other.parts {
            if let index = parts.firstIndex(where: { $0.tool == part.tool }) {
                parts[index].count += part.count
                parts[index].cascading += part.cascading
                parts[index].managed += part.managed
                parts[index].atLeast = parts[index].atLeast || part.atLeast
            } else {
                parts.append(part)
            }
        }
        namespaces.formUnion(other.namespaces)
        for tool in other.unread where !unread.contains(tool) { unread.append(tool) }
        uncounted = uncounted || other.uncounted
    }

    mutating func more(_ tool: KubeGitOpsDelete.Tool, count: Int?) {
        guard let index = parts.firstIndex(where: { $0.tool == tool }) else { return }
        parts[index].atLeast = true
        if let count { parts[index].count += count }
    }

    /// Said after what the namespace holds; nil when it holds no GitOps object and all were read.
    var said: String? {
        var sentences: [String] = []
        let apps = parts.first { $0.tool == .application && $0.cascading > 0 }
        let kustomizations = parts.first { $0.tool == .kustomization && $0.cascading > 0 }
        var who: [String] = []
        if let apps {
            let atLeast = apps.atLeast ? "at least " : "the "
            who.append(
                apps.cascading == 1 && !apps.atLeast
                    ? "the Application in it with Argo CD's resources finalizer" : "\(atLeast)\(KubeGitOpsDelete.grouped(apps.cascading)) Applications in it with Argo CD's resources finalizer")
        }
        if let kustomizations {
            let atLeast = kustomizations.atLeast ? "at least " : "the "
            who.append(
                kustomizations.cascading == 1 && !kustomizations.atLeast
                    ? "the pruning Kustomization in it" : "\(atLeast)\(KubeGitOpsDelete.grouped(kustomizations.cascading)) pruning Kustomizations in it")
        }
        if !who.isEmpty {
            let managed = (apps?.managed ?? 0) + (kustomizations?.managed ?? 0)
            let atLeast = apps?.atLeast == true || kustomizations?.atLeast == true ? "at least " : ""
            let verb = who.count == 1 && (apps?.cascading ?? kustomizations?.cascading ?? 0) == 1 && atLeast.isEmpty ? "deletes what it manages" : "delete what they manage"
            var sentence = "And " + who.joined(separator: " and ") + " " + verb
            if managed > 0 {
                sentence += ": \(atLeast)\(KubeGitOpsDelete.count(managed, "object"))"
                if namespaces.count > 1 { sentence += " across \(KubeGitOpsDelete.grouped(namespaces.count)) namespaces" }
                if namespaces.count == 1 { sentence += " in namespace \(namespaces.first!)" }
            }
            sentences.append(sentence + ".")
        }
        if let releases = parts.first(where: { $0.tool == .helmRelease && $0.cascading > 0 }) {
            let atLeast = releases.atLeast ? "at least " : ""
            sentences.append(
                releases.cascading == 1 && !releases.atLeast
                    ? "Its HelmRelease uninstalls its release." : "Its \(atLeast)\(KubeGitOpsDelete.grouped(releases.cascading)) HelmReleases uninstall their releases.")
        }
        if uncounted {
            sentences.append("Its GitOps objects weren't counted: any Applications, Kustomizations or HelmReleases in it may delete what they manage.")
        }
        for tool in unread {
            switch tool {
            case .application: sentences.append("Its Applications couldn't be read: they may delete everything they manage.")
            case .kustomization: sentences.append("Its Kustomizations couldn't be read: they may delete everything they applied.")
            case .helmRelease: sentences.append("Its HelmReleases couldn't be read: they may uninstall their releases.")
            case .applicationSet: break
            }
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

extension KubeClient {
    /// What deleting a GitOps object takes with it: the object read once,
    /// bounded, into the allow-listed fields; nil for any other kind. A
    /// failed or refused read is the worst case.
    func gitOpsDelete(_ ref: KubeObjectRef) async -> KubeGitOpsDelete? {
        guard let tool = KubeGitOpsDelete.tool(ref.kind) else { return nil }
        do {
            let data = try await get(KubeWrites.path(ref), maxBytes: KubeNamespaceGitOps.pageBytes)
            return try KubeGitOpsDelete.read(data, tool: tool, ref: ref)
        } catch {
            return .unread(tool, KubernetesModel.said(error))
        }
    }

    /// What the GitOps objects a namespace holds take with it: the worst
    /// case while the context's discovery isn't known, nil when it is and
    /// serves none of their kinds.
    func gitOpsHeld(in namespace: String, discovery: KubeDiscovery?) async -> KubeNamespaceGitOps? {
        guard discovery != nil else { return .notCounted }
        let kinds = KubeNamespaceGitOps.kinds(in: discovery)
        guard !kinds.isEmpty else { return nil }
        var held = KubeNamespaceGitOps()
        for (kind, tool) in kinds {
            var token: String?
            var read = 0
            // A kind is merged only once read to its end: a page that fails
            // after others leaves no partial count beside "couldn't be read".
            var part = KubeNamespaceGitOps()
            let limit = tool == .application ? KubeNamespaceGitOps.applicationPageLimit : KubeNamespaceGitOps.pageLimit
            do {
                repeat {
                    var query = [("limit", String(limit))]
                    if let token { query.append(("continue", token)) }
                    let data = try await get(KubePath.query(kind.path(namespace: namespace), query), maxBytes: KubeNamespaceGitOps.pageBytes)
                    let page = try JSONDecoder().decode(KubeGitOpsDelete.WireList.self, from: data)
                    let items = page.items ?? []
                    part.add(items.map { KubeGitOpsDelete.facts($0, tool: tool, namespace: namespace, name: "") }, tool: tool)
                    read += items.count
                    token = page.metadata?.continue.flatMap { $0.isEmpty ? nil : $0 }
                    if token != nil, read >= KubeNamespaceGitOps.readLimit {
                        part.more(tool, count: page.metadata?.remainingItemCount)
                        token = nil
                    }
                } while token != nil
                held.merge(part)
            } catch {
                held.unread.append(tool)
            }
        }
        return held
    }
}
