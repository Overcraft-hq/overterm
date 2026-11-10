import Foundation

/// Applications, as the recommended labels say them
/// (`app.kubernetes.io/name`, `/instance`, `/part-of`): the workloads of
/// one install — an instance, else a name — together, and the
/// applications that are part of one system under it. Pure.
enum KubeApplications {
    static let prefix = "app.kubernetes.io/"
    static let nameLabel = "app.kubernetes.io/name"
    static let instanceLabel = "app.kubernetes.io/instance"
    static let partOfLabel = "app.kubernetes.io/part-of"
    static let componentLabel = "app.kubernetes.io/component"

    /// One workload of an application.
    struct Member: Equatable, Sendable {
        var kind: KubeResourceKind
        var id: KubeRowID
        var component: String?
        var ready: Bool
    }

    struct Application: Equatable, Sendable, Identifiable {
        /// The name label, else the instance's.
        var name: String
        var instance: String?
        var partOf: String?
        var namespace: String?
        var members: [Member]

        var id: String { [partOf ?? "", namespace ?? "", instance ?? name].joined(separator: "\u{0}") }
        var notReady: Int { members.filter { !$0.ready }.count }
    }

    /// The system an application is part of, and its applications; nil
    /// `partOf` for those part of none.
    struct System: Equatable, Sendable, Identifiable {
        var partOf: String?
        var applications: [Application]

        var id: String { partOf ?? "" }
    }

    /// `workloads`' rows (with their labels) grouped: by namespace and
    /// instance (else name) into applications, those by `part-of` into
    /// systems — the systems by name, the unnamed last; a row with none of
    /// the labels is in no application.
    static func group(_ workloads: [(kind: KubeResourceKind, row: KubeRow, ready: Bool)]) -> [System] {
        var applications: [String: Application] = [:]
        for (kind, row, ready) in workloads {
            let labels = row.labels
            guard let key = labels[instanceLabel] ?? labels[nameLabel] else { continue }
            let id = [labels[partOfLabel] ?? "", row.id.namespace ?? "", key].joined(separator: "\u{0}")
            var application =
                applications[id]
                ?? Application(name: labels[nameLabel] ?? key, instance: labels[instanceLabel], partOf: labels[partOfLabel], namespace: row.id.namespace, members: [])
            application.members.append(Member(kind: kind, id: row.id, component: labels[componentLabel], ready: ready))
            applications[id] = application
        }
        var systems: [String: [Application]] = [:]
        for application in applications.values { systems[application.partOf ?? "", default: []].append(application) }
        return systems.keys.sorted { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }
            .map { key in
                let ordered = systems[key]!.sorted { ($0.name, $0.namespace ?? "", $0.instance ?? "") < ($1.name, $1.namespace ?? "", $1.instance ?? "") }
                return System(
                    partOf: key.isEmpty ? nil : key,
                    applications: ordered.map { application in
                        var sorted = application
                        sorted.members.sort { ($0.kind.resource, $0.id) < ($1.kind.resource, $1.id) }
                        return sorted
                    })
            }
    }
}

/// A workload's state as its Table row says it: ready, or how far off. Pure.
enum KubeWorkloadState {
    /// Whether the row's workload is where it should be: a Deployment's or
    /// StatefulSet's Ready `n/n` (`0/0` scaled to nothing is fine), a
    /// DaemonSet's Ready against Desired, a Job not Failed. Nil when the
    /// row says nothing of it.
    static func ready(_ row: KubeRow, columns: [KubeColumn], kind: String) -> Bool? {
        switch kind {
        case "deployments", "statefulsets", "replicasets":
            if let ready = row.cell("Ready", in: columns)?.text, let (have, want) = pair(ready) { return have >= want }
            if kind == "replicasets", let ready = number(row.cell("Ready", in: columns)), let desired = number(row.cell("Desired", in: columns)) {
                return ready >= desired
            }
            return nil
        case "daemonsets":
            guard let ready = number(row.cell("Ready", in: columns)), let desired = number(row.cell("Desired", in: columns)) else { return nil }
            return ready >= desired
        case "jobs":
            if let status = row.cell("Status", in: columns)?.text, !status.isEmpty { return !["Failed", "FailureTarget"].contains(status) }
            return true
        default: return nil
        }
    }

    /// How far off a workload is, as its row says it: `2/3 ready` (a
    /// DaemonSet's Ready of its Desired), a Job's status. Nil when it says nothing.
    static func said(_ row: KubeRow, columns: [KubeColumn], kind: String) -> String? {
        switch kind {
        case "deployments", "statefulsets", "replicasets":
            if let ready = row.cell("Ready", in: columns)?.text, pair(ready) != nil { return "\(ready) ready" }
            fallthrough
        case "daemonsets":
            guard let ready = number(row.cell("Ready", in: columns)), let desired = number(row.cell("Desired", in: columns)) else { return nil }
            return "\(ready)/\(desired) ready"
        case "jobs":
            return row.cell("Status", in: columns)?.text.nilIfEmpty
        default: return nil
        }
    }

    /// `2/3` as (2, 3).
    static func pair(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let have = parts[0], let want = parts[1] else { return nil }
        return (have, want)
    }

    static func number(_ cell: KubeCell?) -> Int? {
        switch cell {
        case .integer(let value): value
        case .number(let value): Int(value)
        case .text(let text): Int(text)
        default: nil
        }
    }
}

/// The Overview section (`1`; stage 2d): load and health at a glance —
/// what fails first (pods failing and why, workloads not ready, nodes not
/// ready, recent Warning events), then the counts per kind and pods by
/// phase, then the applications. Made from the rows the section follows
/// (`KubeClusterOverviewSession`). Pure.
struct KubeClusterOverview: Equatable, Sendable {
    /// Pods by phase, in the API's order.
    static let phases = ["Running", "Pending", "Succeeded", "Failed", "Unknown"]

    struct WorkloadCount: Equatable, Sendable, Identifiable {
        var title: String
        var resource: String
        var total: Int
        var notReady: [KubeRowID]
        /// How far off a row not ready is, as its row says it (`0/1 ready`, `Failed`).
        var said: [KubeRowID: String] = [:]

        var id: String { resource }
    }

    struct Warning: Equatable, Sendable, Identifiable {
        var object: String
        var reason: String
        var message: String
        var namespace: String?
        /// How long ago it was last seen, in seconds; nil when unknown.
        var age: TimeInterval?
        var count: Int?
        /// The event's own name: what tells two alike apart.
        var event = ""

        var id: String { [namespace ?? "", event, object, reason].joined(separator: "\u{0}") }
    }

    var workloads: [WorkloadCount] = []
    /// Pods in each phase (`phases`), for the phases that could be read.
    var phases: [String: Int] = [:]
    var failingPods: [KubePodSummary] = []
    /// Of those, the ones whose phase is Pending (an image not pulled): counted once, as failing.
    var failingPending = 0
    var nodes = 0
    var notReadyNodes: [String] = []
    /// The last hour's Warning events, newest first.
    var warnings: [Warning] = []
    var systems: [KubeApplications.System] = []
    /// Workloads that carry none of the recommended labels.
    var unlabelled = 0

    var pods: Int { phases.values.reduce(0, +) }
    var applications: Int { systems.reduce(0) { $0 + $1.applications.count } }
    /// What fails, in all: the first things shown.
    var problems: Int { failingPods.count + workloads.reduce(0) { $0 + $1.notReady.count } + notReadyNodes.count }

    /// How recent a warning must be to be shown.
    static let recent: TimeInterval = 3600
    static let maxWarnings = 50

    /// Rows and their columns, by what the section follows.
    struct Input {
        var pods: [String: KubeRows] = [:]
        var workloads: [(kind: KubeResourceKind, rows: KubeRows)] = []
        var nodes: KubeRows?
        var warnings: KubeRows?
        /// Each warning row's anchor, for its age.
        var anchors: [KubeRowID: KubeAge.Anchor] = [:]
    }

    static func of(_ input: Input, now: Date = Date()) -> KubeClusterOverview {
        var overview = KubeClusterOverview()
        for phase in phases {
            guard let rows = input.pods[phase] else { continue }
            overview.phases[phase] = rows.count
            if phase == "Succeeded" { continue }
            let failing = rows.sorted.compactMap { KubePodSummary(row: $0, columns: rows.columns) }.filter { $0.isFailing || phase == "Failed" || phase == "Unknown" }
            if phase == "Pending" { overview.failingPending = failing.count }
            overview.failingPods += failing
        }
        overview.failingPods.sort { $0.id < $1.id }
        var members: [(kind: KubeResourceKind, row: KubeRow, ready: Bool)] = []
        for (kind, rows) in input.workloads {
            var notReady: [KubeRowID] = []
            var said: [KubeRowID: String] = [:]
            for row in rows.sorted {
                let ready = KubeWorkloadState.ready(row, columns: rows.columns, kind: kind.resource) ?? true
                if !ready {
                    notReady.append(row.id)
                    said[row.id] = KubeWorkloadState.said(row, columns: rows.columns, kind: kind.resource)
                }
                if row.labels[KubeApplications.instanceLabel] ?? row.labels[KubeApplications.nameLabel] != nil {
                    members.append((kind, row, ready))
                } else {
                    overview.unlabelled += 1
                }
            }
            overview.workloads.append(WorkloadCount(title: KubeKindCatalog.title(of: kind), resource: kind.fullName, total: rows.count, notReady: notReady, said: said))
        }
        overview.systems = KubeApplications.group(members)
        if let nodes = input.nodes {
            overview.nodes = nodes.count
            overview.notReadyNodes = nodes.sorted.filter { row in
                let status = row.cell("Status", in: nodes.columns)?.text ?? ""
                return status.split(separator: ",").first.map(String.init) != "Ready"
            }
            .map(\.id.name)
        }
        if let events = input.warnings {
            let columns = events.columns
            overview.warnings = events.sorted.compactMap { row -> Warning? in
                if let type = row.cell("Type", in: columns)?.text, type != "Warning" { return nil }
                let age = input.anchors[row.id]?.age(at: now) ?? row.cell("Last Seen", in: columns).flatMap { KubeAge.seconds($0.text) }
                if let age, age > recent { return nil }
                return Warning(
                    object: row.cell("Object", in: columns)?.text ?? row.id.name, reason: row.cell("Reason", in: columns)?.text ?? "",
                    message: row.cell("Message", in: columns)?.text ?? "", namespace: row.id.namespace, age: age,
                    count: KubeWorkloadState.number(row.cell("Count", in: columns)), event: row.id.name)
            }
            .sorted { ($0.age ?? .infinity, $0.id) < ($1.age ?? .infinity, $1.id) }
            if overview.warnings.count > maxWarnings { overview.warnings = Array(overview.warnings.prefix(maxWarnings)) }
        }
        return overview
    }
}
