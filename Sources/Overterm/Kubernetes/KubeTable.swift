import Foundation

/// A list as the API server formats it (`as=Table;v=v1;g=meta.k8s.io`):
/// `kubectl get`'s own columns, a CRD's `additionalPrinterColumns`
/// included, so one table shows every kind. Pure.
///
/// Lists and watches ask for rows only (`includeObject=None`): the spike's
/// 2886 pods were 885 KB that way, 35 MB with the default metadata. So a
/// row carries its cells and nothing else, and it is known by its
/// namespace and name (`KubeRowID`); the full object is one GET when its
/// detail opens. The namespace is the request's — or, across all
/// namespaces, the embedded metadata's (`includeObject=Metadata`, asked
/// for there only): no core kind's Table has a Namespace column.
package struct KubeTable: Equatable, Sendable {
    package var columns: [KubeColumn]
    package var rows: [KubeRow]
    /// The collection's, to watch from.
    package var resourceVersion: String?
    /// The next page's token, when the server cut the list.
    package var continueToken: String?
    package var remainingItemCount: Int?

    package init(columns: [KubeColumn], rows: [KubeRow], resourceVersion: String? = nil, continueToken: String? = nil, remainingItemCount: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.resourceVersion = resourceVersion
        self.continueToken = continueToken
        self.remainingItemCount = remainingItemCount
    }

    /// The columns `kubectl get` shows (priority 0); the rest are `-o wide`'s.
    package var defaultColumns: [KubeColumn] { columns.filter { $0.priority == 0 } }

    package func column(named name: String) -> Int? { KubeColumn.index(of: name, in: columns) }
}

/// One of a Table's `columnDefinitions`.
package struct KubeColumn: Equatable, Hashable, Sendable, Codable {
    package var name: String
    /// OpenAPI's: `string`, `integer`, `number`, `boolean`, `date`.
    package var type: String
    /// `name` marks the identifier column.
    package var format: String
    package var description: String
    /// 0: the default view; higher: what `-o wide` adds.
    package var priority: Int

    package init(name: String, type: String = "string", format: String = "", description: String = "", priority: Int = 0) {
        self.name = name
        self.type = type
        self.format = format
        self.description = description
        self.priority = priority
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    package static func index(of name: String, in columns: [KubeColumn]) -> Int? {
        columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The identifier column: `format: name`, else one called Name, else the first.
    package static func nameIndex(in columns: [KubeColumn]) -> Int {
        columns.firstIndex { $0.format == "name" } ?? index(of: "Name", in: columns) ?? 0
    }
}

/// One cell as the server sent it.
package enum KubeCell: Equatable, Hashable, Sendable {
    case text(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case none

    package init(json: Any?) {
        switch json {
        case let string as String: self = .text(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .number(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
        case nil, is NSNull: self = .none
        case let other?:
            // An object or a list (rare: a CRD's printer column on one):
            // its JSON, as kubectl prints it.
            let data = (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            self = .text(String(decoding: data, as: UTF8.self))
        }
    }

    /// As `kubectl get` prints it.
    package var text: String {
        switch self {
        case .text(let text): text
        case .integer(let value): String(value)
        case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .none: ""
        }
    }
}

/// Which object a row is: its namespace (nil for a cluster-scoped kind)
/// and name.
package struct KubeRowID: Hashable, Comparable, Sendable, CustomStringConvertible {
    package var namespace: String?
    package var name: String

    package var description: String { namespace.map { "\($0)/\(name)" } ?? name }

    package static func < (lhs: KubeRowID, rhs: KubeRowID) -> Bool {
        (lhs.namespace ?? "", lhs.name) < (rhs.namespace ?? "", rhs.name)
    }
}

package struct KubeRow: Equatable, Sendable, Identifiable {
    package var id: KubeRowID
    package var cells: [KubeCell]
    /// When the object was made, from the embedded metadata — only where
    /// the rows carry it (across all namespaces, `includeObject=Metadata`);
    /// with rows only, the server's Age cell is all there is (`KubeAge`).
    package var created: Date? = nil
    /// Its `app.kubernetes.io/…` labels (name, instance, part-of…), from
    /// the embedded metadata — only where the rows carry it. The others
    /// aren't kept: they are the Applications grouping's, nothing else's.
    package var labels: [String: String] = [:]
    /// Its `status.conditions` — only where the rows carry the whole object
    /// (`includeObject=Object`, the attention watches' Deployments: a
    /// stuck rollout is in its `Progressing` condition, which no cell says).
    /// Nothing else of the object is kept.
    package var conditions: [KubeRowCondition] = []
    /// The Argo CD or Flux objects its labels and tracking annotation name
    /// as what deploys it (`KubeGitOpsOwner`) — only where the list asked
    /// (`KubeListOptions.owners`: the rail's workloads).
    package var owners: [KubeGitOpsOwner] = []
    /// Argo CD's marks and what Argo CD's rules read beside them
    /// (`KubeMarkWire`'s allow-list), its tracking id checked against the
    /// kind listed — only where the list asked (`KubeListOptions.marks`)
    /// and the row carried its metadata. Nothing else of the metadata is
    /// kept: never kubectl's last-applied copy, another annotation or
    /// label, or a managed field's field set.
    package var marks: KubeMarkWire? = nil
    /// Whether its metadata carries one of Argo CD's own marks — the
    /// tracking annotation or `argocd.argoproj.io/instance` — looked up
    /// on every row that carries its metadata, nothing of it kept: what
    /// tells a context's GitOps section that marks are there to read
    /// (`KubernetesModel.marksSeen`, gitops.md 14.2.1).
    package var argoMarked = false

    package func cell(_ column: String, in columns: [KubeColumn]) -> KubeCell? {
        guard let index = KubeColumn.index(of: column, in: columns), index < cells.count else { return nil }
        return cells[index]
    }
}

/// One of an object's `status.conditions`, as a row embedding the object
/// says it: its type, status and reason — never its message.
package struct KubeRowCondition: Equatable, Hashable, Sendable {
    package var type: String
    package var status: String
    package var reason: String?

    package static func read(_ conditions: Any?) -> [KubeRowCondition] {
        (conditions as? [[String: Any]] ?? []).compactMap { condition in
            guard let type = condition["type"] as? String, let status = condition["status"] as? String else { return nil }
            return KubeRowCondition(type: type, status: status, reason: condition["reason"] as? String)
        }
    }
}

/// Reads a Table — or, from an API without Table support (an aggregated
/// one answers 406 to Table alone, so the request falls back to plain
/// JSON), a List or a single object as Name and Created At. Pure.
package enum KubeTableReader {
    package struct Malformed: Error, Equatable, LocalizedError {
        package var detail: String
        package var errorDescription: String? { "The server's answer isn't a Table: \(detail)" }
    }

    /// `namespace`: the request's, for a row without a Namespace column.
    /// `columns`: the headers kept from the list, for a watch's later
    /// events, which come without theirs. `kind`: what was listed, for
    /// the kinds whose cells are read with care (`row`), and required with
    /// `owners` or `marks`: a mark is checked against it.
    package static func read(
        _ data: Data, namespace: String?, columns: [KubeColumn]? = nil, kind: KubeResourceKind? = nil, owners: Bool = false, marks: Bool = false
    ) throws -> KubeTable {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        return try read(object, namespace: namespace, columns: columns, kind: kind, owners: owners, marks: marks)
    }

    package static func read(
        _ object: [String: Any], namespace: String?, columns kept: [KubeColumn]? = nil, kind: KubeResourceKind? = nil, owners: Bool = false,
        marks: Bool = false
    ) throws -> KubeTable {
        precondition(!(owners || marks) || kind != nil, "a row's marks are read only against the kind listed")
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let resourceVersion = metadata["resourceVersion"] as? String
        let said = object["kind"] as? String ?? ""
        if said == "Table" {
            var columns = kept ?? []
            if let definitions = object["columnDefinitions"] as? [[String: Any]], !definitions.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: definitions)
                columns = try JSONDecoder().decode([KubeColumn].self, from: data)
            }
            let rows = (object["rows"] as? [[String: Any]] ?? []).compactMap { row -> KubeRow? in
                let cells = (row["cells"] as? [Any] ?? []).map { KubeCell(json: $0) }
                return Self.row(
                    cells, columns: columns, namespace: namespace, object: row["object"] as? [String: Any], kind: kind, owners: owners, marks: marks)
            }
            return KubeTable(
                columns: columns, rows: rows, resourceVersion: resourceVersion, continueToken: (metadata["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                remainingItemCount: (metadata["remainingItemCount"] as? NSNumber)?.intValue)
        }
        if let items = object["items"] as? [[String: Any]] {
            let metadatas = items.map { $0["metadata"] as? [String: Any] ?? [:] }
            return plain(metadatas, resourceVersion: resourceVersion, continueToken: metadata["continue"] as? String)
        }
        if metadata["name"] != nil { return plain([metadata], resourceVersion: resourceVersion, continueToken: nil) }
        throw Malformed(detail: said.isEmpty ? "no kind" : said)
    }

    /// What a server without Table support gives: Name (and Namespace,
    /// when the objects have one) and Created At.
    package static func plain(_ metadatas: [[String: Any]], resourceVersion: String?, continueToken: String?) -> KubeTable {
        let namespaced = metadatas.contains { $0["namespace"] is String }
        var columns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Created At", type: "date")]
        if namespaced { columns.insert(KubeColumn(name: "Namespace"), at: 0) }
        let rows = metadatas.compactMap { metadata -> KubeRow? in
            guard let name = metadata["name"] as? String else { return nil }
            let created = KubeCell.text(metadata["creationTimestamp"] as? String ?? "")
            let cells: [KubeCell] = namespaced ? [.text(metadata["namespace"] as? String ?? ""), .text(name), created] : [.text(name), created]
            return KubeRow(id: KubeRowID(namespace: metadata["namespace"] as? String, name: name), cells: cells)
        }
        return KubeTable(
            columns: columns, rows: rows, resourceVersion: resourceVersion, continueToken: continueToken.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A row's identity: its Namespace column, else an embedded object's
    /// (asked for with `includeObject=Metadata`), else the request's; its
    /// name column. A row without a name is no row. A Flux source's
    /// (GitRepository, OCIRepository, HelmRepository…) cells lose a URL's
    /// credentials: its URL column is the `spec.url` that can carry
    /// `user:token@`, and its Status, the Ready message, may quote it.
    /// `owners`: its owners read from its marks too (`KubeRow.owners`),
    /// each tracking id checked against the object it sits on — the
    /// group and Kind from `kind`, the request's, the name and namespace
    /// from the row; never the embedded object's, which is a
    /// `PartialObjectMetadata` of `meta.k8s.io`. So `kind` is required
    /// with `owners`: a row whose marks can't be checked names nobody
    /// surely. `marks`: Argo CD's marks kept by `KubeMarkWire`'s
    /// allow-list (`KubeRow.marks`), checked the same way — `kind` is
    /// required with it too.
    package static func row(
        _ cells: [KubeCell], columns: [KubeColumn], namespace: String?, object: [String: Any]? = nil, kind: KubeResourceKind? = nil, owners: Bool = false,
        marks: Bool = false
    ) -> KubeRow? {
        var cells = cells
        if let kind, KubeGitOps.isFluxSource(kind) { cells = withoutCredentials(cells, columns: columns) }
        let nameIndex = KubeColumn.nameIndex(in: columns)
        guard nameIndex < cells.count else { return nil }
        let name = cells[nameIndex].text
        guard !name.isEmpty else { return nil }
        var rowNamespace = namespace
        let metadata = object?["metadata"] as? [String: Any]
        let created = (metadata?["creationTimestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        if let index = KubeColumn.index(of: "Namespace", in: columns), index != nameIndex, index < cells.count, !cells[index].text.isEmpty {
            rowNamespace = cells[index].text
        } else if let embedded = metadata?["namespace"] as? String {
            rowNamespace = embedded
        }
        let labels = (metadata?["labels"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }.filter { $0.key.hasPrefix(KubeApplications.prefix) }
        let conditions = KubeRowCondition.read((object?["status"] as? [String: Any])?["conditions"])
        var row = KubeRow(id: KubeRowID(namespace: rowNamespace, name: name), cells: cells, created: created, labels: labels, conditions: conditions)
        if let metadata { row.argoMarked = argoMarked(metadata) }
        if owners || marks {
            guard let kind else { preconditionFailure("a row's marks are read only against the kind listed") }
            let identity = KubeTrackingID.Identity(group: kind.group, kind: kind.kind, namespace: kind.namespaced ? rowNamespace : nil, name: name)
            if owners { row.owners = KubeGitOpsOwner.parse(metadata: metadata, self: identity) }
            if marks { row.marks = KubeMarkWire.read(metadata: metadata, self: identity) }
        }
        return row
    }

    /// Whether a row's metadata carries one of Argo CD's own marks — the
    /// tracking annotation or `argocd.argoproj.io/instance`
    /// (`KubeRow.argoMarked`): two key look-ups on what was decoded
    /// anyway, nothing kept — all `marksSeen` costs a list (gitops.md
    /// 14.2.1; the D7 leg times it against the pods leg's Overview).
    package static func argoMarked(_ metadata: [String: Any]) -> Bool {
        holds(metadata["annotations"], KubeGitOpsOwner.trackingAnnotation) || holds(metadata["labels"], KubeGitOpsOwner.argoInstanceLabel)
    }

    /// Whether a decoded object holds `key`, looked up where it lies: a
    /// JSONSerialization dictionary is asked as one, never bridged whole to
    /// a Swift dictionary first — that copied every annotation of every
    /// row, kubectl's last-applied copy among them, for one look-up (D7's
    /// leg, 15 KB rows: 6.5% of reading the rows it looked in, 0.3% asked
    /// as one).
    private static func holds(_ object: Any?, _ key: String) -> Bool {
        if let dictionary = object as? NSDictionary { return dictionary.object(forKey: key) != nil }
        return (object as? [String: Any])?[key] != nil
    }

    /// Every text cell without a URL's userinfo: the URL column read as
    /// one URL (`GitRemoteURL.withoutUserinfo`), the others as text that
    /// may name some (`stripUserinfo(inText:)`).
    package static func withoutCredentials(_ cells: [KubeCell], columns: [KubeColumn]) -> [KubeCell] {
        let url = KubeColumn.index(of: "URL", in: columns)
        return cells.enumerated().map { index, cell in
            guard case .text(let text) = cell else { return cell }
            return .text(index == url ? GitRemoteURL.withoutUserinfo(text) : GitRemoteURL.stripUserinfo(inText: text))
        }
    }
}

/// A list's rows as they stand, a list and then a watch's changes applied
/// to it. Pure: the page keeps one per section.
package struct KubeRows: Equatable, Sendable {
    package private(set) var columns: [KubeColumn] = []
    package private(set) var rows: [KubeRowID: KubeRow] = [:]
    /// Where a watch would resume.
    package private(set) var resourceVersion: String?

    package init() {}

    package init(_ table: KubeTable) {
        apply(.listed(table))
    }

    package mutating func apply(_ update: KubeFollowUpdate) {
        switch update {
        case .listed(let table):
            columns = table.columns
            rows = Dictionary(table.rows.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            resourceVersion = table.resourceVersion
        case .changed(let changes, let version):
            for change in changes {
                switch change {
                case .added(let row), .modified(let row): rows[row.id] = row
                case .deleted(let id): rows[id] = nil
                }
            }
            if let version { resourceVersion = version }
        case .bookmark(let version):
            resourceVersion = version
        case .retrying, .unlisted:
            break
        }
    }

    /// By namespace, then name.
    package var sorted: [KubeRow] { rows.values.sorted { $0.id < $1.id } }
    package var count: Int { rows.count }
    package subscript(_ id: KubeRowID) -> KubeRow? { rows[id] }
}

/// What following a list says: the whole list (first, and again after a
/// 410), rows that changed, or only how far the watch has got.
package enum KubeFollowUpdate: Equatable, Sendable {
    case listed(KubeTable)
    case changed([KubeRowChange], resourceVersion: String?)
    case bookmark(String)
    /// A 429 or the server's 5xx: the rows stand as they were while the
    /// follow waits and tries again.
    case retrying(KubeAPIError)
    /// Of several namespaces, one the follow may not list (a 403): the
    /// others go on without it (`KubeScopeMerge`).
    case unlisted(String, KubeAPIError)
}

package enum KubeRowChange: Equatable, Sendable {
    case added(KubeRow)
    case modified(KubeRow)
    case deleted(KubeRowID)

    package var id: KubeRowID {
        switch self {
        case .added(let row), .modified(let row): row.id
        case .deleted(let id): id
        }
    }
}

/// A pod as its Table row says it: `kubectl get pods`' Ready, Status and
/// Restarts read into what the list marks. Pure.
///
/// The Status column is kubectl's own reason: a waiting container's
/// (`CrashLoopBackOff`, `ImagePullBackOff`), a terminated one's
/// (`Error`, `OOMKilled`, `Completed`), `Init:…` while an init container
/// hasn't finished, `Terminating`, else the phase. Restarts is a number
/// and, since 1.22, when the last one was: `5 (2m ago)`.
package struct KubePodSummary: Equatable, Sendable {
    package var id: KubeRowID
    package var ready: Int?
    package var containers: Int?
    package var status: String
    package var restarts: Int?
    /// "2m ago", as the row says it.
    package var lastRestart: String?

    /// Waiting and terminated reasons that mean a container is failing.
    package static let failingReasons: Set<String> = [
        "CrashLoopBackOff", "Error", "OOMKilled", "ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull", "InvalidImageName",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError", "ContainerCannotRun", "StartError", "DeadlineExceeded",
        "Evicted", "Failed", "PreStartHookError", "PostStartHookError",
    ]

    package init(id: KubeRowID, ready: Int?, containers: Int?, status: String, restarts: Int?, lastRestart: String? = nil) {
        self.id = id
        self.ready = ready
        self.containers = containers
        self.status = status
        self.restarts = restarts
        self.lastRestart = lastRestart
    }

    package init?(row: KubeRow, columns: [KubeColumn]) {
        guard let status = row.cell("Status", in: columns)?.text else { return nil }
        id = row.id
        self.status = status
        let ready = row.cell("Ready", in: columns)?.text.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let ready, ready.count == 2 {
            self.ready = ready[0]
            containers = ready[1]
        }
        switch row.cell("Restarts", in: columns) {
        case .integer(let count): restarts = count
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            restarts = Int(trimmed.prefix { $0.isNumber })
            if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
                lastRestart = String(trimmed[trimmed.index(after: open)..<close])
            }
        case .number(let value): restarts = Int(value)
        default: break
        }
    }

    /// The reason without `Init:`.
    private var bareStatus: String { status.hasPrefix("Init:") ? String(status.dropFirst(5)) : status }

    /// Whether an init container is the one the status is about.
    package var isInit: Bool { status.hasPrefix("Init:") }

    /// A container failing, or one that exited with a signal or a code.
    package var isFailing: Bool {
        let bare = bareStatus
        return Self.failingReasons.contains(bare) || bare.hasPrefix("Signal:") || bare.hasPrefix("ExitCode:")
    }

    /// Why it fails, as the list says it — nil while it doesn't.
    package var exitReason: String? {
        guard isFailing else { return nil }
        return isInit ? "\(bareStatus) (init container)" : bareStatus
    }

    /// Running, every container ready.
    package var isReady: Bool {
        guard status == "Running", let ready, let containers else { return false }
        return ready == containers
    }

    package var isCompleted: Bool { status == "Completed" || status == "Succeeded" }
}
