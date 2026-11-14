import Foundation

/// One object Argo CD's marks name, as the marks' reads know it (docs/
/// design/kubernetes/gitops.md, 14.1): its kind and place, its marks
/// (`KubeMarkWire`), its health so far, its images. Pure.
struct KubeMarkedMember: Equatable, Sendable, Identifiable {
    struct ID: Hashable, Comparable, Sendable {
        var kind: KubeMarkedKind
        /// nil for a cluster-scoped object.
        var namespace: String?
        var name: String

        /// "Deployment checkout-api".
        var said: String { "\(kind.kind) \(name)" }

        /// "Deployment payments/checkout-api" where its app spans several
        /// namespaces — two objects of one name there are told apart —,
        /// else `said`.
        func said(namespaced: Bool) -> String {
            guard namespaced, let namespace else { return said }
            return "\(kind.kind) \(namespace)/\(name)"
        }

        static func < (a: ID, b: ID) -> Bool {
            (a.kind, a.namespace ?? "", a.name) < (b.kind, b.namespace ?? "", b.name)
        }
    }

    var id: ID
    var marks: KubeMarkWire
    var health: KubeMarkedHealth.Verdict?
    var images: [String] = []
    /// From the row's metadata.
    var created: Date?
    /// An Argo Rollout's `spec.workloadRef` name, once its object was read:
    /// the Deployment it runs instead of.
    var workloadRef: String?

    var said: String { id.said }

    /// A row read with marks (`KubeRow.marks`), its health from its cells;
    /// nil for a row without them.
    static func row(_ row: KubeRow, kind: KubeMarkedKind, columns: [KubeColumn], notReadySince: Date? = nil, now: Date) -> KubeMarkedMember? {
        guard let marks = row.marks else { return nil }
        return KubeMarkedMember(
            id: ID(kind: kind, namespace: row.id.namespace, name: row.id.name), marks: marks,
            health: KubeMarkedHealth.row(kind, row, columns: columns, marks: marks, notReadySince: notReadySince, now: now),
            images: images(inCell: row.cell("Images", in: columns)?.text), created: row.created)
    }

    /// A row's Images cell as kept: the cluster's text, bounded before it
    /// is split, each image capped and stripped of control and format
    /// characters (bidi overrides, zero-width) as a GET's are
    /// (`KubeMarkWire.text`), at most as many as a GET keeps.
    static func images(inCell cell: String?) -> [String] {
        guard let cell else { return [] }
        let bound = KubeMarkWire.linkCap * KubeMarkedWorkloadWire.containersKept
        let bounded = String(String.UnicodeScalarView(cell.unicodeScalars.prefix(bound)))
        return KubeDeployedCommit.images(inCell: bounded).prefix(KubeMarkedWorkloadWire.containersKept).compactMap {
            KubeMarkWire.text($0, cap: KubeMarkWire.linkCap)
        }
    }

    /// Settled by its object (a GET, `KubeMarkedWorkloadWire`): Argo CD's
    /// rule in place of its cells', the images and a Rollout's target from
    /// the object. A state Argo CD's rule gives no time of its own (a
    /// StatefulSet has no condition) keeps its row's — when it was first
    /// read not ready — else counts from `changedAt`, when its row was
    /// first read or last changed here.
    func settled(by wire: KubeMarkedWorkloadWire, changedAt: Date? = nil) -> KubeMarkedMember {
        var member = self
        if var verdict = KubeMarkedHealth.object(wire) {
            if let status = verdict.status, status != .healthy, verdict.since == nil {
                if let since = health?.since {
                    verdict.since = since
                    verdict.sinceSaid = health?.sinceSaid
                } else if let changedAt {
                    verdict.since = changedAt
                    verdict.sinceSaid = KubeMarkedHealth.sinceRowChanged
                }
            }
            member.health = verdict
        }
        let images = wire.images
        if !images.isEmpty { member.images = images }
        if id.kind == .rollout { member.workloadRef = wire.spec?.workloadRef?.name.flatMap { KubeMarkWire.text($0, cap: 253) } }
        return member
    }
}

/// One app derived from marks: the top-level objects whose tracking id
/// names themselves (or that carry only `argocd.argoproj.io/instance`),
/// under one installation id and instance name (gitops.md, 14.1). Pure.
struct KubeMarkedApp: Equatable, Sendable, Identifiable {
    var key: KubeTrackingID.AppKey
    /// Its members, by kind and name; hooks apart.
    var members: [KubeMarkedMember]
    /// Argo CD's hooks (`argocd.argoproj.io/hook`, Helm's `helm.sh/hook`):
    /// shown under the app, never in its health.
    var hooks: [KubeMarkedMember] = []
    /// Objects read here that carry a copy of one of its marks — an HPA's
    /// or a PodDisruptionBudget's copy of its Deployment's (14.1): never
    /// members, shown in its detail under the object their mark names.
    var copies: [KubeMarkedMember] = []
    /// Its surest mark: a tracking id, else the instance label, else —
    /// "probably" — `app.kubernetes.io/instance` alone.
    var mark: KubeGitOpsOwner.Mark
    /// The destination namespace a cluster-scoped member's mark says.
    var destination: String?

    var id: String { key.installation.isEmpty ? key.instance : "\(key.installation)|\(key.instance)" }

    /// The installation id, when the marks carry one.
    var installation: String? { key.installation.isEmpty ? nil : key.installation }

    /// The Application's own namespace for an `<appNamespace>_<name>` app;
    /// nil means Argo CD's own namespace, unknown from here.
    var appNamespace: String? {
        guard let underscore = key.instance.firstIndex(of: "_") else { return nil }
        return String(key.instance[..<underscore])
    }

    var appName: String {
        guard let underscore = key.instance.firstIndex(of: "_") else { return key.instance }
        return String(key.instance[key.instance.index(after: underscore)...])
    }

    /// `payments/checkout-api`, or a bare name for one in Argo CD's namespace.
    var said: String { appNamespace.map { "\($0)/\(appName)" } ?? appName }

    /// Where its members live, and the destination a cluster-scoped mark says.
    var namespaces: [String] {
        var all = Set(members.compactMap(\.id.namespace))
        if let destination { all.insert(destination) }
        return all.sorted()
    }

    /// `payments`, or `search +1`.
    var into: String {
        let all = namespaces
        guard let first = all.first else { return "" }
        return all.count == 1 ? first : "\(first) +\(all.count - 1)"
    }

    /// Members counted by kind, in the kinds' order.
    var counts: [(kind: KubeMarkedKind, count: Int)] {
        Dictionary(grouping: members, by: \.id.kind).map { ($0.key, $0.value.count) }.sorted { $0.kind < $1.kind }
    }

    /// `2 Deploy · 1 Svc · 1 HPA`.
    var countsSaid: String { counts.map { "\($0.count) \($0.kind.short)" }.joined(separator: " · ") }

    /// Members read by `argocd.argoproj.io/instance` alone ("label only").
    var labelOnly: Int {
        members.filter { if case .own = $0.marks.tracking { false } else { true } }.count
    }

    /// Every member's images, first seen first, once each.
    var images: [String] {
        var seen = Set<String>()
        return members.flatMap(\.images).filter { seen.insert($0).inserted }
    }

    /// The newest change Argo CD's own managers applied to a member.
    var argoChanged: Date? { members.compactMap(\.marks.argoChanged).max() }

    var health: KubeMarkedHealth.AppVerdict { KubeMarkedHealth.app(self) }

    /// An app from its members (hooks included), nil when none is left —
    /// copies of its marks alone make no app.
    static func make(key: KubeTrackingID.AppKey, _ all: [KubeMarkedMember], copies: [KubeMarkedMember] = []) -> KubeMarkedApp? {
        let sorted = all.sorted { $0.id < $1.id }
        let hooks = sorted.filter { $0.marks.hook != nil }
        let members = sorted.filter { $0.marks.hook == nil }
        guard !sorted.isEmpty else { return nil }
        let mark: KubeGitOpsOwner.Mark
        if sorted.contains(where: { if case .own = $0.marks.tracking { true } else { false } }) {
            mark = .trackingID
        } else if sorted.contains(where: { $0.marks.argoInstance != nil }) {
            mark = .argoInstance
        } else {
            mark = .appInstance
        }
        let destination = sorted.lazy.compactMap { member -> String? in
            guard member.id.namespace == nil, case .own(let id) = member.marks.tracking, !id.namespace.isEmpty else { return nil }
            return id.namespace
        }.first
        return KubeMarkedApp(
            key: key, members: members, hooks: hooks, copies: copies.sorted { $0.id < $1.id }, mark: mark, destination: destination)
    }
}

/// The apps that marks name, grouped from members and kept as rows change
/// (gitops.md, 14.1, decision D-5). A member is placed by its marks:
///
/// - a tracking id naming itself: its app under its installation id and
///   instance name — two installations are never merged;
/// - a tracking id naming another object (a copy): nobody's, counted;
/// - a tracking id Argo CD wouldn't write, or a malformed installation id:
///   counted as unparsed, never shown (an instance label beside a bad
///   tracking id still says who);
/// - `argocd.argoproj.io/instance` alone: its app, "label only";
/// - `app.kubernetes.io/instance` alone: "probably" — used only when no
///   object in the scope carries Argo CD's own marks, never with Helm's
///   release annotation beside it, never mixed into a tracked app.
///
/// `merge` re-groups only the apps whose members changed. Pure.
struct KubeMarkedApps: Equatable, Sendable {
    typealias Key = KubeTrackingID.AppKey

    /// Where a member went.
    enum Placement: Equatable, Hashable, Sendable {
        case app(Key)
        case probable(Key)
        case copied
        case unparsed
        case helm
        case unmarked
    }

    /// What was left out, counted.
    struct Tally: Equatable, Sendable {
        var copied = 0
        var unparsed = 0
        /// `app.kubernetes.io/instance` beside Helm's release annotation.
        var helm = 0
    }

    private(set) var certain: [Key: KubeMarkedApp] = [:]
    private(set) var probable: [Key: KubeMarkedApp] = [:]
    private(set) var tally = Tally()
    /// Where each member went, and whether it also carries an unparsed
    /// tracking id (placed by its instance label, still counted).
    private var placed: [KubeMarkedMember.ID: (placement: Placement, unparsed: Bool)] = [:]
    private var byKey: [Key: [KubeMarkedMember.ID: KubeMarkedMember]] = [:]
    private var probableByKey: [Key: [KubeMarkedMember.ID: KubeMarkedMember]] = [:]
    /// Copies by the app their mark names, and where each went: shown in
    /// that app's detail, never its members.
    private var copiesByKey: [Key: [KubeMarkedMember.ID: KubeMarkedMember]] = [:]
    private var copiedTo: [KubeMarkedMember.ID: Key] = [:]
    /// How many members every app made so far was made from: what `merge`
    /// costs, counted (the tests' bound on it, never a clock's).
    private(set) var membersMade = 0

    init() {}

    /// Whether the apps are `app.kubernetes.io/instance`'s alone: no
    /// object here carries Argo CD's own marks.
    var isProbable: Bool { certain.isEmpty && !probable.isEmpty }

    /// The apps, by key: Argo CD's when any object carries its marks,
    /// else the probable ones.
    var apps: [KubeMarkedApp] { (certain.isEmpty ? probable : certain).values.sorted { $0.key < $1.key } }

    var count: Int { certain.isEmpty ? probable.count : certain.count }

    subscript(_ key: Key) -> KubeMarkedApp? { certain[key] ?? (certain.isEmpty ? probable[key] : nil) }

    func placement(of id: KubeMarkedMember.ID) -> Placement? { placed[id]?.placement }

    /// Every member grouped at once.
    static func group(_ members: [KubeMarkedMember]) -> KubeMarkedApps {
        var apps = KubeMarkedApps()
        apps.merge(changed: members, removed: [])
        return apps
    }

    /// Members added or changed, and members gone: only the apps they were
    /// or are in are made again. Returns those apps' keys.
    @discardableResult
    mutating func merge(changed: [KubeMarkedMember], removed: [KubeMarkedMember.ID]) -> Set<Key> {
        var dirty = Set<Key>()
        var dirtyProbable = Set<Key>()
        func take(_ id: KubeMarkedMember.ID) {
            guard let old = placed.removeValue(forKey: id) else { return }
            if old.unparsed { tally.unparsed -= 1 }
            switch old.placement {
            case .app(let key):
                byKey[key]?[id] = nil
                dirty.insert(key)
            case .probable(let key):
                probableByKey[key]?[id] = nil
                dirtyProbable.insert(key)
            case .copied:
                tally.copied -= 1
                if let key = copiedTo.removeValue(forKey: id) {
                    copiesByKey[key]?[id] = nil
                    if copiesByKey[key]?.isEmpty == true { copiesByKey[key] = nil }
                    dirty.insert(key)
                }
            case .unparsed: tally.unparsed -= 1
            case .helm: tally.helm -= 1
            case .unmarked: break
            }
        }
        for id in removed { take(id) }
        for member in changed {
            take(member.id)
            let placement = Self.place(member.marks)
            // An unparsed tracking id beside an instance label: placed by
            // the label, still counted as an unparsed mark.
            let alsoUnparsed: Bool
            if case .app = placement { alsoUnparsed = member.marks.tracking == .unparsed } else { alsoUnparsed = false }
            if alsoUnparsed { tally.unparsed += 1 }
            placed[member.id] = (placement, alsoUnparsed)
            switch placement {
            case .app(let key):
                byKey[key, default: [:]][member.id] = member
                dirty.insert(key)
            case .probable(let key):
                probableByKey[key, default: [:]][member.id] = member
                dirtyProbable.insert(key)
            case .copied:
                tally.copied += 1
                if let key = Self.copyKey(member.marks) {
                    copiesByKey[key, default: [:]][member.id] = member
                    copiedTo[member.id] = key
                    dirty.insert(key)
                }
            case .unparsed: tally.unparsed += 1
            case .helm: tally.helm += 1
            case .unmarked: break
            }
        }
        for key in dirty {
            let members = Array(byKey[key, default: [:]].values)
            if members.isEmpty { byKey[key] = nil }
            membersMade += members.count
            certain[key] = KubeMarkedApp.make(key: key, members, copies: Array(copiesByKey[key, default: [:]].values))
        }
        for key in dirtyProbable {
            let members = Array(probableByKey[key, default: [:]].values)
            if members.isEmpty { probableByKey[key] = nil }
            membersMade += members.count
            probable[key] = KubeMarkedApp.make(key: key, members)
        }
        return dirty.union(dirtyProbable)
    }

    /// The app a copied mark names — the same installation's —; nil for
    /// anything but a copy, or one beside a malformed installation id.
    static func copyKey(_ marks: KubeMarkWire) -> Key? {
        guard case .copied(let id) = marks.tracking, !marks.installationUnparsed else { return nil }
        return id.appKey(installation: marks.installation)
    }

    /// Where marks put a member.
    static func place(_ marks: KubeMarkWire) -> Placement {
        switch marks.tracking {
        case .own(let id):
            if marks.installationUnparsed { return .unparsed }
            return id.appKey(installation: marks.installation).map(Placement.app) ?? .unparsed
        case .copied:
            return .copied
        case .unparsed, .none:
            if let instance = marks.argoInstance {
                return marks.installationUnparsed ? .unparsed : .app(Key(installation: marks.installation ?? "", instance: instance))
            }
            if marks.tracking == .unparsed { return .unparsed }
        }
        guard let instance = marks.appInstance else { return .unmarked }
        return marks.helmRelease ? .helm : .probable(Key(installation: "", instance: instance))
    }

    // `placed`'s bookkeeping and `membersMade` aren't part of what the apps are.
    static func == (a: KubeMarkedApps, b: KubeMarkedApps) -> Bool {
        a.certain == b.certain && a.probable == b.probable && a.tally == b.tally
    }
}

/// When the GitOps section derives Argo CD's apps from marks, and which
/// (gitops.md, 14.3 and 14.12's first consequence): whenever no
/// Application here deploys them — Argo CD's Applications not served,
/// served but none listed (whatever the marks have found so far: their
/// read, its refusals and its empty sentence are the section's then), or
/// the marks' apps absent from a whole list. Read from discovery (its
/// kinds and failed groups) and from what R1's Applications row follow
/// said — never from R2's summaries, whose cut leaves Applications
/// unsummarised, not unseen. Unknown is never said as absent: an app is
/// said missing only where the read behind it was whole, and never one
/// grouped by `app.kubernetes.io/instance` alone. Pure.
enum KubeMarkedAppsMode: Equatable, Sendable {
    typealias Key = KubeTrackingID.AppKey

    /// Why derived apps are the whole Argo CD side of the section.
    enum Reason: Equatable, Sendable {
        /// `applications.argoproj.io` isn't served, and `argoproj.io`
        /// answered discovery: Argo CD runs in another cluster.
        case notServed
        /// Served, listed whole across the cluster, and none is there.
        case noApplications
        /// `argoproj.io` didn't answer discovery: can't tell.
        case undiscovered
        /// Served, but refused across the cluster and everywhere it was
        /// looked for.
        case forbidden

        /// The section's header line, before its count.
        func line(context: String) -> String {
            switch self {
            case .notServed: "Argo CD runs in another cluster — not in your kubeconfig."
            case .noApplications: "Argo CD's Applications for these aren't in this cluster."
            case .undiscovered: "Couldn't tell whether Argo CD runs in \(context): argoproj.io didn't answer discovery."
            case .forbidden: "Argo CD's Applications can't be read in \(context) (forbidden)."
            }
        }

        /// One page of Applications asked across the cluster (`limit=1`, a
        /// Table with no object: what an apply's warning asks where no
        /// section said, `KubeManifestRun.applicationsHere`): none, and none
        /// past it, `.noApplications`; one or more, nil — they are listed
        /// here; anything else, `.undiscovered`: can't tell. Only the rows
        /// are counted; nothing of them is kept.
        static func ofApplicationsPage(_ data: Data) -> Reason? {
            guard let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any], table["kind"] as? String == "Table" else { return .undiscovered }
            // An empty Table's rows may come as null.
            if let rows = table["rows"] as? [Any], !rows.isEmpty { return nil }
            let next = (table["metadata"] as? [String: Any])?["continue"] as? String
            return next?.isEmpty == false ? .undiscovered : .noApplications
        }
    }

    /// Applications served and listed: which marked apps have none here.
    struct Coexistence: Equatable, Sendable {
        /// "its Application isn't in this cluster": the read was whole.
        var missing: Set<Key> = []
        /// Listed, never said missing: an Application of the same name
        /// lives in another namespace — "may be <ns>/<name>".
        var maybe: [Key: KubeRowID] = [:]
        /// Listed with "installation <id>: can't tell whether it is this
        /// cluster's Argo CD": an Application carries no installation id.
        var otherInstallation: Set<Key> = []
        /// Counted, not listed: their Application's namespace wasn't read.
        var unknown: Set<Key> = []

        var isEmpty: Bool { missing.isEmpty && maybe.isEmpty && otherInstallation.isEmpty && unknown.isEmpty }

        /// The derived rows shown beside the Applications.
        var listed: Set<Key> { missing.union(maybe.keys).union(otherInstallation) }
    }

    /// What R1's Applications row follow said.
    enum ApplicationsRead: Equatable, Sendable {
        /// Its first list hasn't come.
        case notYetListed
        /// Listed across the cluster, never cut: every Application's place.
        case acrossCluster([KubeRowID])
        /// Refused across the cluster, read in these namespaces only.
        case namespaces(Set<String>, [KubeRowID])
        /// Refused across the cluster and in every namespace looked in.
        case refused
    }

    /// Today's section: nothing derived.
    case off
    /// Applications are read; these marked apps have none here.
    case beside(Coexistence)
    /// Derived apps are the section's whole Argo CD side.
    case only(Reason)

    static let applications = KubeGitOpsSummary.Kind(group: "argoproj.io", resource: "applications")

    /// The mode. `discovery` nil: nothing is known yet (a sign-in still
    /// waiting) — off, and nothing read. `marked`: the derived apps' keys;
    /// `probable`: they are grouped by `app.kubernetes.io/instance` alone
    /// (D-5), no Argo CD mark being here.
    static func of(discovery: KubeDiscovery?, applications read: ApplicationsRead, marked: Set<Key>, probable: Bool = false) -> KubeMarkedAppsMode {
        guard let discovery else { return .off }
        let served = discovery.kinds.contains { $0.group == applications.group && $0.resource == applications.resource }
        if !served {
            // Only Argo CD's own group failing leaves it unknown: a down
            // metrics.k8s.io says nothing about Argo CD.
            let argoFailed = discovery.failedGroups.keys.contains { $0 == "argoproj.io" || $0.hasPrefix("argoproj.io/") }
            return .only(argoFailed ? .undiscovered : .notServed)
        }
        switch read {
        case .notYetListed:
            return .off
        case .refused:
            return .only(.forbidden)
        case .acrossCluster(let rows) where rows.isEmpty:
            // Served, and the whole list has none (14.12's first
            // consequence): the marks' whatever they find so far — while
            // they are read, after a refused or cut read, and when a whole
            // one found none ("No Argo CD Application deploys here, and no
            // … carries its marks", Argo CD installed with nothing yet). Never
            // today's "no GitOps object" while the marks aren't all read.
            return .only(.noApplications)
        case .acrossCluster(let rows):
            // Apps grouped by `app.kubernetes.io/instance` alone are only
            // probably Argo CD's: beside Applications that are read, one
            // with none here is likelier Helm's, kustomize's or an
            // operator's than an Application gone — never listed, never
            // said missing (14.3: false negatives over false alarms).
            guard !probable else { return .off }
            let coexistence = beside(rows: rows, read: nil, marked: marked)
            return coexistence.isEmpty ? .off : .beside(coexistence)
        case .namespaces(let namespaces, let rows):
            guard !probable else { return .off }
            let coexistence = beside(rows: rows, read: namespaces, marked: marked)
            return coexistence.isEmpty ? .off : .beside(coexistence)
        }
    }

    /// Each marked app against the Applications listed. `read`: the
    /// namespaces read when the list across the cluster was refused, nil
    /// when it was whole.
    static func beside(rows: [KubeRowID], read: Set<String>?, marked: Set<Key>) -> Coexistence {
        // An Application's instance name is its name in the namespace most
        // of them live in (Argo CD's own, normally `argocd`), else `ns_name`.
        var perNamespace: [String: Int] = [:]
        for row in rows { perNamespace[row.namespace ?? "", default: 0] += 1 }
        let home = perNamespace.sorted { ($1.value, $0.key == "argocd" ? 0 : 1, $0.key) < ($0.value, $1.key == "argocd" ? 0 : 1, $1.key) }.first?.key
        var instances = Set<String>()
        var byName: [String: KubeRowID] = [:]
        for row in rows {
            let namespace = row.namespace ?? ""
            instances.insert(namespace == home ? row.name : "\(namespace)_\(row.name)")
            if byName[row.name] == nil { byName[row.name] = row }
        }
        var coexistence = Coexistence()
        for key in marked where !instances.contains(key.instance) {
            if !key.installation.isEmpty {
                coexistence.otherInstallation.insert(key)
                continue
            }
            let name: String
            let appNamespace: String?
            if let underscore = key.instance.firstIndex(of: "_") {
                appNamespace = String(key.instance[..<underscore])
                name = String(key.instance[key.instance.index(after: underscore)...])
            } else {
                appNamespace = nil
                name = key.instance
            }
            if let read {
                // Only an `ns_name` mark whose namespace was read whole can
                // be said missing: a plain name's namespace is unknown.
                guard let appNamespace, read.contains(appNamespace) else {
                    coexistence.unknown.insert(key)
                    continue
                }
            }
            if let same = byName[name] {
                coexistence.maybe[key] = same
            } else {
                coexistence.missing.insert(key)
            }
        }
        return coexistence
    }
}
