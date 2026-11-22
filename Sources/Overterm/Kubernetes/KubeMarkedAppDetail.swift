import Foundation

/// An app read from Argo CD's marks, its detail beside the GitOps section
/// (↩; docs/design/kubernetes/gitops.md, 14.2.3, D4) — what it is made of
/// as Argo CD would draw it, and what only Argo CD knows:
///
/// - the header: its name, installation and namespaces, its state by Argo
///   CD's built-in rules applied to its objects as the detail read them
///   (M4: a GET of each member whose rule reads its object, at most 50),
///   and the mode's own line;
/// - "What Argo CD knows and this cluster doesn't": sync status,
///   repository and path, revisions, sync policy, last sync, project —
///   fixed rows, each saying where the Application is in the mode's
///   words, never filled from a guess;
/// - the tree: its members by kind, each with Argo CD's word; under a
///   workload, by its owner references, its newest ReplicaSet (and any
///   still running pods) and the pods, a StatefulSet's, DaemonSet's or
///   Job's pods, a CronJob's last Jobs — pods with their own health,
///   never counted toward the app's, as in Argo CD; a copy of a member's
///   mark (a ReplicaSet's, an HPA's) under what it names, never a member;
///   an `ignore-healthcheck` member grey, not counted; an Argo Rollout's
///   Deployment "scaled by its Rollout", promote and abort Argo
///   Rollouts' — not here;
/// - its hooks, apart; the hints its marks carry (sync-wave, sync-options,
///   compare-options, links as text — never opened, D-3); its images and
///   the commit an image's tag names; why Sync, Refresh, Rollback and Diff
///   aren't here; what couldn't be read.
///
/// Nothing in it reads or writes: the session reads (`KubeMarkedDetailSession`),
/// a member opens in its own list with the verbs it has there. Apps
/// grouped by `app.kubernetes.io/instance` alone are only "probably" Argo
/// CD's in every word. Pure.
package enum KubeMarkedAppDetail {
    // MARK: What a detail reads (M4)

    /// The detail's bounds (14.2.3): a GET of at most 50 members, a
    /// workload's pods up to 200 by its selector, a CronJob's Jobs from one
    /// list of its namespace, the newest 5 kept; 50 pods drawn under one
    /// owner, the rest counted.
    package struct Bounds: Equatable, Sendable {
        package var members = 50
        package var pods = 200
        package var replicaSets = 50
        package var jobs = 500
        package var jobsKept = 5
        package var podsShown = 50
    }

    /// The controller an object's `ownerReferences` name: its kind and name.
    package struct Owner: Equatable, Hashable, Sendable {
        package var kind: String
        package var name: String
    }

    /// One object a detail's list found under a member: a ReplicaSet, a
    /// pod, a Job — from its row: its cells' health, its controller, and
    /// a tracking id naming somebody else (a copy) — nothing else of it.
    package struct Child: Equatable, Hashable, Sendable {
        package enum Kind: String, Sendable {
            case replicaSet = "ReplicaSet"
            case pod = "Pod"
            case job = "Job"

            package var group: String {
                switch self {
                case .replicaSet: "apps"
                case .pod: ""
                case .job: "batch"
                }
            }

            /// Its kind's full name, as discovery serves it.
            package var resource: String {
                switch self {
                case .replicaSet: "replicasets.apps"
                case .pod: "pods"
                case .job: "jobs.batch"
                }
            }

            /// "pods", "ReplicaSets", "Jobs": a note's word.
            package var plural: String { self == .pod ? "pods" : rawValue + "s" }
        }

        package var kind: Kind
        package var namespace: String
        package var name: String
        package var created: Date?
        package var owner: Owner?
        /// The tracking id it carries when it names another object: a copy
        /// its controller made — never a member.
        package var copied: KubeTrackingID?
        package var health: KubeMarkedHealth.Verdict?
        /// A ReplicaSet's desired replicas: an old one at 0 is folded.
        package var replicas: Int?

        /// Which object it is, whichever list found it.
        package struct Place: Hashable, Sendable {
            package var kind: Kind
            package var namespace: String
            package var name: String
        }

        package var place: Place { Place(kind: kind, namespace: namespace, name: name) }
    }

    /// Each object once, as the first list found it: two workloads whose
    /// selectors overlap (`app=web`, and `app=web,track=canary`) list the
    /// narrower one's ReplicaSets and pods twice — drawn twice under it
    /// with one id, and its pods counted twice.
    package static func unique(_ children: [Child]) -> [Child] {
        var seen = Set<Child.Place>()
        return children.filter { seen.insert($0.place).inserted }
    }

    /// One list a detail reads: a member's children in its namespace, by
    /// its own selector (a CronJob's Jobs by their owner, from its
    /// namespace's list) — rows with their metadata, never whole objects.
    package struct List: Equatable, Hashable, Sendable {
        package var what: Child.Kind
        package var namespace: String
        /// The workload's selector as its object says it; nil: the
        /// namespace's Jobs, kept by their owner.
        package var selector: String?
        package var limit: Int
        /// Whose children: what a note names.
        package var of: KubeMarkedMember.ID
    }

    /// What a detail read.
    package struct Read: Equatable, Sendable {
        /// Each member read by Argo CD's rule: the detail's own GET, or the
        /// section's when it is that fresh.
        package var objects: [KubeMarkedMember.ID: KubeMarkedSettled] = [:]
        /// A member that couldn't be read, and why: said from its row.
        package var unread: [KubeMarkedMember.ID: String] = [:]
        /// Members whose rule reads their object, past the first 50: from their rows.
        package var past: [KubeMarkedMember.ID] = []
        /// What the lists found under its workloads.
        package var children: [Child] = []
        /// A list refused, cut or failed, said.
        package var notes: [String] = []
        /// When it was read; nil while nothing came.
        package var at: Date?
    }

    /// The kinds whose rule reads the object (a workload's, a CronJob's,
    /// an HPA's): a detail GETs those. A Service's, an Ingress's and a
    /// claim's rule reads what their cells show, exactly.
    package static func readsObject(_ kind: KubeMarkedKind) -> Bool {
        switch kind {
        case .deployment, .statefulSet, .daemonSet, .rollout, .cronJob, .job, .horizontalPodAutoscaler: true
        default: false
        }
    }

    /// The members a detail GETs, in the members' order (workloads first):
    /// the first `limit`, and those past it, said from their rows.
    package static func fetched(_ app: KubeMarkedApp, limit: Int) -> (read: [KubeMarkedMember.ID], past: [KubeMarkedMember.ID]) {
        let wanted = app.members.filter { readsObject($0.id.kind) }.map(\.id)
        return (Array(wanted.prefix(limit)), Array(wanted.dropFirst(limit)))
    }

    /// The lists a detail reads, from what its GETs said: a Deployment's
    /// (or a Rollout's — its own selector, else the Deployment its
    /// `workloadRef` names) ReplicaSets and pods, a StatefulSet's,
    /// DaemonSet's or Job's pods, a CronJob's namespace's Jobs. Each by
    /// the workload's own selector in its own namespace; none for a
    /// workload whose selector isn't read, or selects everything. The same
    /// list once.
    package static func lists(_ app: KubeMarkedApp, objects: [KubeMarkedMember.ID: KubeMarkedSettled], bounds: Bounds = Bounds()) -> [List] {
        var lists: [List] = []
        var seen = Set<String>()
        func add(_ what: Child.Kind, _ namespace: String, _ selector: String?, _ limit: Int, of id: KubeMarkedMember.ID) {
            guard seen.insert("\(what.rawValue)|\(namespace)|\(selector ?? "")").inserted else { return }
            lists.append(List(what: what, namespace: namespace, selector: selector, limit: limit, of: id))
        }
        for member in app.members {
            guard let namespace = member.id.namespace, let wire = objects[member.id]?.wire else { continue }
            switch member.id.kind {
            case .deployment:
                guard let selector = selector(wire) else { continue }
                add(.replicaSet, namespace, selector, bounds.replicaSets, of: member.id)
                add(.pod, namespace, selector, bounds.pods, of: member.id)
            case .rollout:
                // With a `workloadRef`, its pods are the referenced Deployment's template's.
                let referenced = wire.spec?.workloadRef?.name.flatMap { name in
                    objects[KubeMarkedMember.ID(kind: .deployment, namespace: namespace, name: name)]?.wire
                }
                guard let selector = selector(wire) ?? selector(referenced) else { continue }
                add(.replicaSet, namespace, selector, bounds.replicaSets, of: member.id)
                add(.pod, namespace, selector, bounds.pods, of: member.id)
            case .statefulSet, .daemonSet, .job:
                guard let selector = selector(wire) else { continue }
                add(.pod, namespace, selector, bounds.pods, of: member.id)
            case .cronJob:
                add(.job, namespace, nil, bounds.jobs, of: member.id)
            default:
                continue
            }
        }
        return lists
    }

    /// A workload's selector as a list's `labelSelector`: `app=web,tier
    /// in (a,b),!legacy` — its object's own (never a mark's text); nil
    /// when it has none, selects everything, has an operator the words
    /// can't say, or a key or value Kubernetes' label syntax wouldn't take
    /// (an Argo Rollout is a custom resource: its fields aren't checked by
    /// the API server as a Deployment's are) — never a query of the
    /// cluster's own making.
    package static func selector(_ wire: KubeMarkedWorkloadWire?) -> String? {
        guard let selector = wire?.spec?.selector, !selector.unusable else { return nil }
        let labels = (selector.matchLabels ?? [:]).sorted { $0.key < $1.key }
        guard labels.allSatisfy({ isLabelKey($0.key) && isLabelValue($0.value) }) else { return nil }
        var parts = labels.map { "\($0.key)=\($0.value)" }
        for expression in selector.matchExpressions ?? [] {
            guard let key = expression.key, isLabelKey(key), (expression.values ?? []).allSatisfy(isLabelValue) else { return nil }
            let values = (expression.values ?? []).sorted().joined(separator: ",")
            switch expression.operator {
            case "In": parts.append("\(key) in (\(values))")
            case "NotIn": parts.append("\(key) notin (\(values))")
            case "Exists": parts.append(key)
            case "DoesNotExist": parts.append("!\(key)")
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// A label's key as Kubernetes takes it: an optional DNS-subdomain
    /// prefix and `/`, then a name of 1–63 of `[A-Za-z0-9._-]` starting and
    /// ending alphanumeric.
    package static func isLabelKey(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return isLabelName(parts[0])
        case 2: return KubeTrackingID.isSubdomain(String(parts[0])) && isLabelName(parts[1])
        default: return false
        }
    }

    /// A label's value: empty, or a label name.
    package static func isLabelValue(_ value: String) -> Bool { value.isEmpty || isLabelName(Substring(value)) }

    private static func isLabelName(_ name: Substring) -> Bool {
        let bytes = name.utf8
        func alphanumeric(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        guard let first = bytes.first, let last = bytes.last, bytes.count <= KubeTrackingID.maxLabel, alphanumeric(first), alphanumeric(last) else {
            return false
        }
        return bytes.allSatisfy { alphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") }
    }

    /// A list's answer — a Table whose rows carry their metadata
    /// (`includeObject=Metadata`) — as children: each row's name, cells'
    /// health, controller, creation and a copied tracking id; nothing else
    /// of it is kept (no annotation, label, env or field set). `more`: rows
    /// past the list's limit — their count when the server says it, 0 when
    /// it only says there are more; nil when the list was whole.
    package static func children(_ data: Data, list: List, kind: KubeResourceKind, now: Date) throws -> (children: [Child], more: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["kind"] as? String == "Table" else {
            throw KubeTableReader.Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        var columns: [KubeColumn] = []
        if let definitions = object["columnDefinitions"] as? [[String: Any]], !definitions.isEmpty {
            columns = try JSONDecoder().decode([KubeColumn].self, from: JSONSerialization.data(withJSONObject: definitions))
        }
        var children: [Child] = []
        let rows = object["rows"] as? [[String: Any]] ?? []
        for item in rows.prefix(list.limit) {
            let cells = (item["cells"] as? [Any] ?? []).map { KubeCell(json: $0) }
            let embedded = item["object"] as? [String: Any]
            // The pods' marks aren't read: Argo CD's annotation is the workload's, never its template's.
            guard let row = KubeTableReader.row(cells, columns: columns, namespace: list.namespace, object: embedded, kind: kind, marks: list.what != .pod),
                row.id.namespace == nil || row.id.namespace == list.namespace, let name = KubeMarkWire.text(row.id.name, cap: KubeTrackingID.maxName)
            else { continue }
            var copied: KubeTrackingID?
            if case .copied(let id) = row.marks?.tracking { copied = id }
            let health: KubeMarkedHealth.Verdict?
            var replicas: Int?
            switch list.what {
            case .pod: health = KubeMarkedHealth.pod(row, columns: columns)
            case .replicaSet:
                health = KubeMarkedHealth.replicaSet(row, columns: columns)
                replicas = row.cell("Desired", in: columns).flatMap { Int($0.text) }
            case .job: health = KubeMarkedHealth.row(.job, row, columns: columns, marks: nil, now: now)
            }
            children.append(
                Child(
                    kind: list.what, namespace: list.namespace, name: name, created: row.created, owner: owner(embedded?["metadata"]), copied: copied, health: health,
                    replicas: replicas))
        }
        let metadata = object["metadata"] as? [String: Any]
        var more: Int?
        if let remaining = (metadata?["remainingItemCount"] as? NSNumber)?.intValue, remaining > 0 {
            more = remaining + max(0, rows.count - list.limit)
        } else if let next = metadata?["continue"] as? String, !next.isEmpty {
            more = 0
        } else if rows.count > list.limit {
            more = rows.count - list.limit
        }
        return (children, more)
    }

    /// The controller its `ownerReferences` name (else its first owner):
    /// the kind and name, capped, nothing else of them.
    package static func owner(_ metadata: Any?) -> Owner? {
        let references = (metadata as? [String: Any])?["ownerReferences"] as? [[String: Any]] ?? []
        guard let chosen = references.first(where: { $0["controller"] as? Bool == true }) ?? references.first,
            let kind = KubeMarkWire.text(chosen["kind"], cap: KubeTrackingID.maxLabel), let name = KubeMarkWire.text(chosen["name"], cap: KubeTrackingID.maxName)
        else { return nil }
        return Owner(kind: kind, name: name)
    }

    // MARK: The detail

    /// One node of its tree.
    package struct Node: Equatable, Sendable, Identifiable {
        package enum Role: Equatable, Sendable {
            /// One of its objects, counted toward its health.
            case member
            /// One of its objects Argo CD leaves out (`ignore-healthcheck`).
            case ignored
            /// Under a member by its owner references: a ReplicaSet, a pod, a Job.
            case owned
            /// Carries a copy of a member's mark: never a member.
            case copy
            /// Argo CD's hook: listed apart, never in its health.
            case hook
        }

        package var id: String
        /// "" for the core group.
        package var group: String
        package var kind: String
        package var namespace: String?
        package var name: String
        package var role: Role
        /// Argo CD's word for it; nil: no rule for its kind here, or not read.
        package var status: KubeMarkedHealth.Status?
        package var sentence: String
        /// Said from its row's cells, not its object.
        package var fromRow = false
        /// What it is beside its health: "not counted, as in Argo CD", a copy's.
        package var note: String?
        package var children: [Node] = []
        /// Its children not drawn, counted, and what they are.
        package var more: String?

        /// The object it is, to open: its group's version as discovery serves it.
        package var link: KubeLink {
            KubeLink(apiVersion: group.isEmpty ? "v1" : "\(group)/v1", kind: kind, namespace: namespace, name: name)
        }

        /// Its health's word: Argo CD's, else what it has instead.
        package var word: String {
            if let status { return status.word }
            return sentence.isEmpty ? "no health rule here" : "not read yet"
        }

        /// Whether Argo CD's selfHeal can set a change to it back: one of
        /// the app's own objects, whose sync status Argo CD keeps — a
        /// member, or one it leaves out of health only (`ignore-healthcheck`).
        /// Never what hangs under one (a ReplicaSet, a pod, a CronJob's Job:
        /// their controller's, or nobody's), a hook (Argo CD keeps no sync
        /// status of one), nor a copy of a mark (it names somebody else): a
        /// write on those says nothing of Argo CD.
        package var mayBeUndone: Bool { role == .member || role == .ignored }

        /// One line: `Deployment acme-cart — Degraded: rollout stalled
        /// (ProgressDeadlineExceeded)`, a namespace in front when its app
        /// spans several.
        package func said(namespaced: Bool) -> String {
            let place = namespaced ? namespace.map { "\($0)/" } ?? "" : ""
            if role == .copy { return "\(kind) \(place)\(name) — \(note ?? "a copy, not a member")" }
            var line = "\(kind) \(place)\(name) — \(word)"
            if !sentence.isEmpty { line += ": \(sentence)" }
            // A ReplicaSet's or a pod's is always its row's: said once, not on each.
            if fromRow, status != nil, role == .member || role == .ignored { line += " (from its row)" }
            if let note { line += " — \(note)" }
            return line
        }

        /// It and every node under it.
        package var all: [Node] { [self] + children.flatMap(\.all) }
    }

    /// The nodes the keyboard walks (↑ ↓; 14.2.3, ↩ on a node): the tree
    /// depth first, as it is drawn, then the hooks.
    package static func walk(_ detail: Detail) -> [Node] { detail.tree.flatMap(\.all) + detail.hooks }

    /// The node `step` from `id` along `nodes`, held at either end; the
    /// first when `id` is none of them; nil when there are none.
    package static func step(_ nodes: [Node], from id: String?, by step: Int) -> String? {
        guard let first = nodes.first else { return nil }
        guard let index = id.flatMap({ id in nodes.firstIndex { $0.id == id } }) else { return first.id }
        return nodes[min(max(index + step, 0), nodes.count - 1)].id
    }

    /// One thing only the Application knows, and where it is.
    package struct Known: Equatable, Sendable {
        package var field: String
        package var place: String
    }

    package struct Detail: Equatable, Sendable {
        /// "Argo CD app", or — grouped by `app.kubernetes.io/instance`
        /// alone — "Probably an Argo CD app".
        package var label: String
        /// `payments/checkout-api`, or a bare name in Argo CD's namespace.
        package var title: String
        /// Argo CD's word for it, as the detail read its objects.
        package var word: String
        package var state: KubeGitOpsState
        package var why: String
        /// The state's hover: Argo CD's word, each cause, what isn't known.
        package var hover: String
        /// The mode's sentence: why it is read from marks.
        package var lead: String?
        /// Its installation, its Application's namespace, its namespaces.
        package var facts: [String]
        package var knowsTitle: String
        package var knows: [Known]
        /// Its members, by kind, each with what is under it.
        package var tree: [Node]
        /// Its hooks, apart.
        package var hooks: [Node]
        /// Whether its members span several namespaces: each said with its own.
        package var namespaced: Bool
        /// sync-wave, sync-options, compare-options, links — text.
        package var hints: [String]
        /// Each image and the members running it.
        package var images: [String]
        /// The commit an image's tag names.
        package var commits: [String]
        /// The manifests' revision: the Application's alone.
        package var manifests: String
        /// Why the Application's verbs aren't here.
        package var absent: String
        /// Promote and abort are Argo Rollouts' own.
        package var rollouts: String?
        /// What couldn't be read, or was read from rows only.
        package var notes: [String]
    }

    package static let podsNotCounted = "Pods are shown with their own health: as in Argo CD, they don't count toward the app's."
    package static let notCounted = "not counted, as in Argo CD"
    package static let rolloutVerbs = "promote and abort are Argo Rollouts' — not here"

    /// The six things only the Application says (14.2.3).
    package static let applicationFields = [
        "Sync status", "Repository and path", "Target and live revision", "Sync policy (automated, prune, selfHeal)", "Last sync", "Project",
    ]

    /// The detail of one app as the section ranks it, its members settled
    /// by what the detail read (`read`): the header's state is the detail's
    /// own when it read anything, else the section's.
    package static func make(
        _ ranked: KubeMarkedRanked, read: Read = Read(), mode: KubeMarkedAppsMode, context: String, bounds: Bounds = Bounds()
    ) -> Detail {
        let app = settled(ranked.app, read)
        let health = read.objects.isEmpty ? ranked.health : KubeMarkedHealth.app(app)
        let probable = app.mark == .appInstance
        var facts: [String] = []
        if let installation = app.installation { facts.append("Installation: \(installation)") }
        if !probable {
            if let appNamespace = app.appNamespace {
                facts.append("Its Application: \(app.appName), in namespace \(appNamespace)")
            } else {
                facts.append("Its Application: \(app.appName), in Argo CD's own namespace")
            }
        }
        facts.append("Namespaces: \(app.namespaces.isEmpty ? "none read" : app.namespaces.joined(separator: ", "))")
        if let destination = app.destination { facts.append("Destination, from a cluster-scoped object's mark: \(destination)") }
        var lead: String?
        if probable {
            lead = "No Argo CD tracking id is here: this app is \(KubeMarkedSection.probablyArgos)"
        } else if case .only(let reason) = mode {
            lead = reason.line(context: context)
        }
        let rollouts = app.members.contains { $0.id.kind == .rollout } ? "Its Argo Rollout is read for its health only: \(rolloutVerbs)." : nil
        let place = whereTheApplicationIs(mode, probable: probable)
        return Detail(
            label: probable ? "Probably an Argo CD app" : "Argo CD app", title: app.said, word: health.word, state: health.state, why: health.why,
            hover: KubeMarkedSection.hover(KubeMarkedRanked(app: app, health: health)), lead: lead,
            facts: facts.map { KubeMarkedSection.capped($0) },
            knowsTitle: probable ? "What only its Application would say" : "What Argo CD knows and this cluster doesn't",
            knows: applicationFields.map { Known(field: $0, place: place) }, tree: tree(app, read: read, bounds: bounds),
            hooks: app.hooks.map(hook), namespaced: app.namespaces.count > 1, hints: hints(app), images: images(app), commits: commits(app),
            manifests: "The manifests' revision Argo CD synced: \(place)", absent: KubeMarkedSection.absentVerbs(mode, context: context, probable: probable),
            rollouts: rollouts, notes: notes(app, read: read))
    }

    /// The app with each member settled by what the detail read: Argo CD's
    /// rule from its object in place of its row's cells.
    package static func settled(_ app: KubeMarkedApp, _ read: Read) -> KubeMarkedApp {
        guard !read.objects.isEmpty else { return app }
        var app = app
        app.members = app.members.map { member in read.objects[member.id].map { member.settled(by: $0.wire) } ?? member }
        return app
    }

    /// Its members by kind, each with what is under it — by its owner
    /// references — and the copies of its mark; a copy naming none of its
    /// members at the end.
    package static func tree(_ app: KubeMarkedApp, read: Read, bounds: Bounds = Bounds()) -> [Node] {
        var copies = app.copies
        var nodes: [Node] = []
        let index = ChildIndex(read.children)
        for member in app.members {
            let verdict = KubeMarkedHealth.member(member, in: app)
            var node = Node(
                id: "member|\(member.id.kind.kind)|\(member.id.namespace ?? "")|\(member.id.name)", group: member.id.kind.group, kind: member.id.kind.kind,
                namespace: member.id.namespace, name: member.id.name, role: member.marks.ignoreHealthcheck ? .ignored : .member, status: verdict?.status,
                sentence: verdict?.sentence ?? "", fromRow: verdict?.fromRow ?? false)
            if member.marks.ignoreHealthcheck {
                node.note = "ignore-healthcheck: \(notCounted)"
            } else if member.id.kind == .rollout {
                node.note = rolloutVerbs
            } else if !isTracked(member.marks), member.marks.argoInstance != nil {
                node.note = "label only"
            }
            let (owned, more) = children(of: member, index: index, bounds: bounds)
            node.children = owned
            node.more = more
            // The copies of its mark, under it.
            let mine = copies.filter { copy in
                guard case .copied(let id) = copy.marks.tracking else { return false }
                return id.isSelf(
                    group: member.id.kind.group, kind: member.id.kind.kind, namespace: member.id.namespace, name: member.id.name,
                    clusterScoped: member.id.namespace == nil)
            }
            copies.removeAll { copy in mine.contains { $0.id == copy.id } }
            node.children += mine.map(copy)
            nodes.append(node)
        }
        return nodes + copies.map(copy)
    }

    /// The children by where they hang: their namespace, kind and owner —
    /// each looked up once, however many members ask.
    private struct ChildIndex {
        struct Key: Hashable {
            var namespace: String
            var kind: Child.Kind
            var owner: Owner
        }

        let byOwner: [Key: [Child]]

        init(_ children: [Child]) {
            var byOwner: [Key: [Child]] = [:]
            // Each object once: overlapping selectors find it in two lists.
            for child in KubeMarkedAppDetail.unique(children) {
                guard let owner = child.owner else { continue }
                byOwner[Key(namespace: child.namespace, kind: child.kind, owner: owner), default: []].append(child)
            }
            self.byOwner = byOwner.mapValues { $0.sorted(by: KubeMarkedAppDetail.newestFirst) }
        }

        func owned(in namespace: String, by kind: String, _ name: String, _ what: Child.Kind) -> [Child] {
            byOwner[Key(namespace: namespace, kind: what, owner: Owner(kind: kind, name: name))] ?? []
        }
    }

    /// A member's children by its owner references: a Deployment's or a
    /// Rollout's newest ReplicaSet and any still running pods (an old one
    /// at 0 folded), each with its pods; a StatefulSet's, a DaemonSet's or
    /// a Job's pods; a CronJob's newest Jobs. And what isn't drawn, said.
    private static func children(of member: KubeMarkedMember, index: ChildIndex, bounds: Bounds) -> (nodes: [Node], more: String?) {
        guard let namespace = member.id.namespace else { return ([], nil) }
        func owned(by kind: String, _ name: String, _ what: Child.Kind) -> [Child] {
            index.owned(in: namespace, by: kind, name, what)
        }
        func pods(of kind: String, _ name: String) -> (nodes: [Node], more: String?) {
            let all = owned(by: kind, name, .pod)
            let shown = all.prefix(bounds.podsShown).map { node($0) }
            let left = all.count - shown.count
            return (shown, left > 0 ? "\(left) more \(left == 1 ? "pod" : "pods")" : nil)
        }
        switch member.id.kind {
        case .deployment, .rollout:
            let sets = owned(by: member.id.kind.kind, member.id.name, .replicaSet)
            // The newest, and any other still asking for pods: an old one serving during a stuck rollout.
            let shown = sets.enumerated().filter { $0.offset == 0 || ($0.element.replicas ?? 0) > 0 }.map(\.element)
            let folded = sets.count - shown.count
            let nodes = shown.map { set -> Node in
                var setNode = node(set)
                let (podNodes, morePods) = pods(of: "ReplicaSet", set.name)
                setNode.children = podNodes
                setNode.more = morePods
                return setNode
            }
            return (nodes, folded > 0 ? "\(folded) older \(folded == 1 ? "ReplicaSet" : "ReplicaSets"), scaled to 0" : nil)
        case .statefulSet, .daemonSet, .job:
            return pods(of: member.id.kind.kind, member.id.name)
        case .cronJob:
            let jobs = owned(by: "CronJob", member.id.name, .job)
            let left = jobs.count - min(jobs.count, bounds.jobsKept)
            return (jobs.prefix(bounds.jobsKept).map { node($0) }, left > 0 ? "\(left) older \(left == 1 ? "Job" : "Jobs")" : nil)
        default:
            return ([], nil)
        }
    }

    /// Whether its own tracking id names it.
    private static func isTracked(_ marks: KubeMarkWire) -> Bool {
        if case .own = marks.tracking { return true }
        return false
    }

    fileprivate static func newestFirst(_ a: Child, _ b: Child) -> Bool {
        let first = a.created ?? .distantPast
        let second = b.created ?? .distantPast
        return first != second ? first > second : a.name < b.name
    }

    /// A child as a node: its own health; a copy of its owner's mark said.
    private static func node(_ child: Child) -> Node {
        var note: String?
        if let copied = child.copied {
            note = "a copy of \(copied.kind) \(copied.name)'s mark: not a member"
        }
        return Node(
            id: "owned|\(child.kind.rawValue)|\(child.namespace)|\(child.name)", group: child.kind.group, kind: child.kind.rawValue, namespace: child.namespace,
            name: child.name, role: .owned, status: child.health?.status, sentence: child.health?.sentence ?? "", fromRow: child.health?.fromRow ?? false, note: note)
    }

    /// An object carrying a copy of a member's mark: under what it names, never a member.
    private static func copy(_ member: KubeMarkedMember) -> Node {
        var named = "another object's"
        if case .copied(let id) = member.marks.tracking { named = "\(id.kind) \(id.name)'s" }
        return Node(
            id: "copy|\(member.id.kind.kind)|\(member.id.namespace ?? "")|\(member.id.name)", group: member.id.kind.group, kind: member.id.kind.kind,
            namespace: member.id.namespace, name: member.id.name, role: .copy, status: nil, sentence: "",
            note: "carries \(named) mark — a copy, not a member")
    }

    /// A hook, apart: its health as its row says it, never counted.
    private static func hook(_ member: KubeMarkedMember) -> Node {
        let types = member.marks.hook.map { $0.isEmpty ? "Argo CD" : $0 } ?? ""
        return Node(
            id: "hook|\(member.id.kind.kind)|\(member.id.namespace ?? "")|\(member.id.name)", group: member.id.kind.group, kind: member.id.kind.kind,
            namespace: member.id.namespace, name: member.id.name, role: .hook, status: member.health?.status, sentence: member.health?.sentence ?? "",
            fromRow: member.health?.fromRow ?? false, note: "a hook (\(types)): \(notCounted)")
    }

    /// What its members' marks hint at, each with its object (its namespace
    /// too when the app spans several: two of one name are told apart):
    /// sync-wave, sync-options (`Prune=false`, `ServerSideApply=true`),
    /// compare-options and `link.argocd.argoproj.io/*` — text to read and
    /// copy, never a link opened (D-3). At most 50 lines.
    package static func hints(_ app: KubeMarkedApp) -> [String] {
        var lines: [String] = []
        let namespaced = app.namespaces.count > 1
        for member in app.members + app.hooks {
            let marks = member.marks
            let on = member.id.said(namespaced: namespaced) + (marks.hook != nil ? " (a hook)" : "")
            if let wave = marks.syncWave { lines.append("sync-wave \(wave) — \(on)") }
            if let options = marks.syncOptions { lines.append("sync-options \(options) — \(on)") }
            if let options = marks.compareOptions { lines.append("compare-options \(options) — \(on)") }
            for link in marks.links { lines.append("link \(link.name): \(link.value) — \(on)") }
        }
        return Array(lines.prefix(50))
    }

    /// Each image, once, and the members running it (in their namespaces
    /// when the app spans several) — at most 20, capped.
    package static func images(_ app: KubeMarkedApp) -> [String] {
        var order: [String] = []
        var runners: [String: [String]] = [:]
        let namespaced = app.namespaces.count > 1
        for member in app.members where !member.images.isEmpty {
            for image in member.images {
                if runners[image] == nil { order.append(image) }
                runners[image, default: []].append(member.id.said(namespaced: namespaced))
            }
        }
        return order.prefix(20).map { KubeMarkedSection.capped("\($0) — \(runners[$0, default: []].joined(separator: ", "))") }
    }

    /// The commit each image's tag is shaped like — the deployed code, not
    /// the manifests: compared with a checkout in its rail.
    package static func commits(_ app: KubeMarkedApp) -> [String] {
        KubeDeployedCommit.candidates(images: app.images).prefix(10).map { candidate in
            "commit \(candidate.sha.prefix(12)) — \(candidate.source.said)" + (candidate.image.map { " (\(KubeMarkedSection.shortImage($0)))" } ?? "")
        }
    }

    /// What couldn't be read, or is said from rows only — each object in
    /// its namespace when the app spans several.
    package static func notes(_ app: KubeMarkedApp, read: Read) -> [String] {
        var notes: [String] = []
        if !read.past.isEmpty {
            notes.append("\(KubeMarkedSection.counted(read.past.count, "object")) past the first 50 \(read.past.count == 1 ? "shows" : "show") from its row: a detail reads at most 50")
        }
        let namespaced = app.namespaces.count > 1
        for (id, why) in read.unread.sorted(by: { $0.key < $1.key }) { notes.append("\(id.said(namespaced: namespaced)): not read — \(why); from its row") }
        notes += read.notes
        return notes.map { KubeMarkedSection.capped($0) }
    }

    // MARK: Words

    /// Where the Application is, in the mode's words: only `notServed`
    /// says Argo CD's cluster; an app only probably Argo CD's, nothing of
    /// where Argo CD runs.
    package static func whereTheApplicationIs(_ mode: KubeMarkedAppsMode, probable: Bool = false) -> String {
        if probable { return "in its Application, if Argo CD deploys it — none is read here" }
        switch mode {
        case .only(.notServed): return "in the Application, in Argo CD's cluster"
        case .only(.noApplications): return "in the Application, which isn't in this cluster"
        case .only(.forbidden): return "in the Application, which can't be read here"
        case .only(.undiscovered): return "in the Application, which couldn't be looked for here"
        case .beside, .off: return "in the Application, which isn't among those read here"
        }
    }

    /// What a write on one of its objects says (14.2.3): Argo CD may undo
    /// it, and whether it does — selfHeal — is the Application's, in the
    /// mode's words. Said, never a guard.
    package static func undone(_ mode: KubeMarkedAppsMode, probable: Bool = false) -> String {
        if probable { return "Argo CD may undo this if it deploys it: whether selfHeal is on is in its Application, which isn't read here." }
        switch mode {
        case .only(.notServed): return "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster."
        case .only(.noApplications): return "Argo CD may undo this: whether selfHeal is on is in the Application, which isn't in this cluster."
        case .only(.forbidden): return "Argo CD may undo this: whether selfHeal is on is in the Application, which can't be read here."
        case .only(.undiscovered): return "Argo CD may undo this: whether selfHeal is on is in the Application, which couldn't be looked for here."
        case .beside, .off: return "Argo CD may undo this: whether selfHeal is on is in the Application, which isn't among those read here."
        }
    }

    /// The writes Argo CD's selfHeal would undo on one of the app's own
    /// objects (`Node.mayBeUndone`), whose confirmation says so when it was
    /// opened from this detail: a delete, a restart, a scale, a pause or
    /// resume, a CronJob suspended or resumed — never a Job triggered from
    /// a CronJob (a new object nobody tracks).
    package static let undoneVerbs: Set<KubeWriteVerb> = [.delete, .restart, .scale, .pause, .resume, .suspend, .unsuspend]

    /// An apply's warning on a live object Argo CD tracks (its own tracking
    /// id, or its instance label alone) where Argo CD's Applications aren't
    /// read — `reason`, the section's mode there, else what discovery says:
    /// selfHeal can't be known, so "may undo", never "will be reverted".
    /// nil for a copy, an object Argo CD doesn't mark, or a context whose
    /// Applications are read.
    package static func applyWarning(live: [String: Any]?, reason: KubeMarkedAppsMode.Reason?) -> String? {
        guard let reason, tracks(live) else { return nil }
        return undone(.only(reason))
    }

    /// Whether Argo CD tracks a live object: its own tracking id names it,
    /// or — with none — its instance label. A copy names somebody else.
    package static func tracks(_ live: [String: Any]?) -> Bool {
        guard let live, let identity = KubeTrackingID.Identity.of(live),
            let marks = KubeMarkWire.read(metadata: live["metadata"] as? [String: Any], self: identity)
        else { return false }
        switch marks.tracking {
        case .own: return true
        case .none, .unparsed: return marks.argoInstance != nil
        case .copied: return false
        }
    }

    /// Copy Names: each of its objects, one a line — `Deployment team-2/acme-cart`.
    package static func names(_ app: KubeMarkedApp) -> String {
        (app.members + app.hooks).map { "\($0.id.kind.kind) \($0.id.namespace.map { "\($0)/" } ?? "")\($0.id.name)" }.joined(separator: "\n")
    }
}
