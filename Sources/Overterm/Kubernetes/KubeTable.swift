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
struct KubeTable: Equatable, Sendable {
    var columns: [KubeColumn]
    var rows: [KubeRow]
    /// The collection's, to watch from.
    var resourceVersion: String?
    /// The next page's token, when the server cut the list.
    var continueToken: String?
    var remainingItemCount: Int?

    init(columns: [KubeColumn], rows: [KubeRow], resourceVersion: String? = nil, continueToken: String? = nil, remainingItemCount: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.resourceVersion = resourceVersion
        self.continueToken = continueToken
        self.remainingItemCount = remainingItemCount
    }

    /// The columns `kubectl get` shows (priority 0); the rest are `-o wide`'s.
    var defaultColumns: [KubeColumn] { columns.filter { $0.priority == 0 } }

    func column(named name: String) -> Int? { KubeColumn.index(of: name, in: columns) }
}

/// One of a Table's `columnDefinitions`.
struct KubeColumn: Equatable, Hashable, Sendable, Codable {
    var name: String
    /// OpenAPI's: `string`, `integer`, `number`, `boolean`, `date`.
    var type: String
    /// `name` marks the identifier column.
    var format: String
    var description: String
    /// 0: the default view; higher: what `-o wide` adds.
    var priority: Int

    init(name: String, type: String = "string", format: String = "", description: String = "", priority: Int = 0) {
        self.name = name
        self.type = type
        self.format = format
        self.description = description
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    static func index(of name: String, in columns: [KubeColumn]) -> Int? {
        columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The identifier column: `format: name`, else one called Name, else the first.
    static func nameIndex(in columns: [KubeColumn]) -> Int {
        columns.firstIndex { $0.format == "name" } ?? index(of: "Name", in: columns) ?? 0
    }
}

/// One cell as the server sent it.
enum KubeCell: Equatable, Hashable, Sendable {
    case text(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case none

    init(json: Any?) {
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
    var text: String {
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
struct KubeRowID: Hashable, Comparable, Sendable, CustomStringConvertible {
    var namespace: String?
    var name: String

    var description: String { namespace.map { "\($0)/\(name)" } ?? name }

    static func < (lhs: KubeRowID, rhs: KubeRowID) -> Bool {
        (lhs.namespace ?? "", lhs.name) < (rhs.namespace ?? "", rhs.name)
    }
}

struct KubeRow: Equatable, Sendable, Identifiable {
    var id: KubeRowID
    var cells: [KubeCell]
    /// When the object was made, from the embedded metadata — only where
    /// the rows carry it (across all namespaces, `includeObject=Metadata`);
    /// with rows only, the server's Age cell is all there is (`KubeAge`).
    var created: Date? = nil
    /// Its `app.kubernetes.io/…` labels (name, instance, part-of…), from
    /// the embedded metadata — only where the rows carry it. The others
    /// aren't kept: they are the Applications grouping's, nothing else's.
    var labels: [String: String] = [:]
    /// Its `status.conditions` — only where the rows carry the whole object
    /// (`includeObject=Object`, the attention watches' Deployments: a
    /// stuck rollout is in its `Progressing` condition, which no cell says).
    /// Nothing else of the object is kept.
    var conditions: [KubeRowCondition] = []

    func cell(_ column: String, in columns: [KubeColumn]) -> KubeCell? {
        guard let index = KubeColumn.index(of: column, in: columns), index < cells.count else { return nil }
        return cells[index]
    }
}

/// One of an object's `status.conditions`, as a row embedding the object
/// says it: its type, status and reason — never its message.
struct KubeRowCondition: Equatable, Hashable, Sendable {
    var type: String
    var status: String
    var reason: String?

    static func read(_ conditions: Any?) -> [KubeRowCondition] {
        (conditions as? [[String: Any]] ?? []).compactMap { condition in
            guard let type = condition["type"] as? String, let status = condition["status"] as? String else { return nil }
            return KubeRowCondition(type: type, status: status, reason: condition["reason"] as? String)
        }
    }
}

/// Reads a Table — or, from an API without Table support (an aggregated
/// one answers 406 to Table alone, so the request falls back to plain
/// JSON), a List or a single object as Name and Created At. Pure.
enum KubeTableReader {
    struct Malformed: Error, Equatable, LocalizedError {
        var detail: String
        var errorDescription: String? { "The server's answer isn't a Table: \(detail)" }
    }

    /// `namespace`: the request's, for a row without a Namespace column.
    /// `columns`: the headers kept from the list, for a watch's later
    /// events, which come without theirs.
    static func read(_ data: Data, namespace: String?, columns: [KubeColumn]? = nil) throws -> KubeTable {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        return try read(object, namespace: namespace, columns: columns)
    }

    static func read(_ object: [String: Any], namespace: String?, columns kept: [KubeColumn]? = nil) throws -> KubeTable {
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let resourceVersion = metadata["resourceVersion"] as? String
        let kind = object["kind"] as? String ?? ""
        if kind == "Table" {
            var columns = kept ?? []
            if let definitions = object["columnDefinitions"] as? [[String: Any]], !definitions.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: definitions)
                columns = try JSONDecoder().decode([KubeColumn].self, from: data)
            }
            let rows = (object["rows"] as? [[String: Any]] ?? []).compactMap { row -> KubeRow? in
                let cells = (row["cells"] as? [Any] ?? []).map { KubeCell(json: $0) }
                return Self.row(cells, columns: columns, namespace: namespace, object: row["object"] as? [String: Any])
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
        throw Malformed(detail: kind.isEmpty ? "no kind" : kind)
    }

    /// What a server without Table support gives: Name (and Namespace,
    /// when the objects have one) and Created At.
    static func plain(_ metadatas: [[String: Any]], resourceVersion: String?, continueToken: String?) -> KubeTable {
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
    /// name column. A row without a name is no row.
    static func row(_ cells: [KubeCell], columns: [KubeColumn], namespace: String?, object: [String: Any]? = nil) -> KubeRow? {
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
        return KubeRow(id: KubeRowID(namespace: rowNamespace, name: name), cells: cells, created: created, labels: labels, conditions: conditions)
    }
}

/// A list's rows as they stand, a list and then a watch's changes applied
/// to it. Pure: the page keeps one per section.
struct KubeRows: Equatable, Sendable {
    private(set) var columns: [KubeColumn] = []
    private(set) var rows: [KubeRowID: KubeRow] = [:]
    /// Where a watch would resume.
    private(set) var resourceVersion: String?

    init() {}

    init(_ table: KubeTable) {
        apply(.listed(table))
    }

    mutating func apply(_ update: KubeFollowUpdate) {
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
    var sorted: [KubeRow] { rows.values.sorted { $0.id < $1.id } }
    var count: Int { rows.count }
    subscript(_ id: KubeRowID) -> KubeRow? { rows[id] }
}

/// What following a list says: the whole list (first, and again after a
/// 410), rows that changed, or only how far the watch has got.
enum KubeFollowUpdate: Equatable, Sendable {
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

enum KubeRowChange: Equatable, Sendable {
    case added(KubeRow)
    case modified(KubeRow)
    case deleted(KubeRowID)

    var id: KubeRowID {
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
struct KubePodSummary: Equatable, Sendable {
    var id: KubeRowID
    var ready: Int?
    var containers: Int?
    var status: String
    var restarts: Int?
    /// "2m ago", as the row says it.
    var lastRestart: String?

    /// Waiting and terminated reasons that mean a container is failing.
    static let failingReasons: Set<String> = [
        "CrashLoopBackOff", "Error", "OOMKilled", "ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull", "InvalidImageName",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError", "ContainerCannotRun", "StartError", "DeadlineExceeded",
        "Evicted", "Failed", "PreStartHookError", "PostStartHookError",
    ]

    init(id: KubeRowID, ready: Int?, containers: Int?, status: String, restarts: Int?, lastRestart: String? = nil) {
        self.id = id
        self.ready = ready
        self.containers = containers
        self.status = status
        self.restarts = restarts
        self.lastRestart = lastRestart
    }

    init?(row: KubeRow, columns: [KubeColumn]) {
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
    var isInit: Bool { status.hasPrefix("Init:") }

    /// A container failing, or one that exited with a signal or a code.
    var isFailing: Bool {
        let bare = bareStatus
        return Self.failingReasons.contains(bare) || bare.hasPrefix("Signal:") || bare.hasPrefix("ExitCode:")
    }

    /// Why it fails, as the list says it — nil while it doesn't.
    var exitReason: String? {
        guard isFailing else { return nil }
        return isInit ? "\(bareStatus) (init container)" : bareStatus
    }

    /// Running, every container ready.
    var isReady: Bool {
        guard status == "Running", let ready, let containers else { return false }
        return ready == containers
    }

    var isCompleted: Bool { status == "Completed" || status == "Succeeded" }
}
