import Foundation

/// The API server's own error: its `Status` (401, 403, 404, 409, 410,
/// 429…), as the proxy hands it through. A failure of the proxy's own (a
/// 500 in plain text) is a `KubeProxyProblem` instead.
struct KubeAPIError: Error, Equatable, Sendable, LocalizedError {
    var status: Int
    /// The Status's `reason`: `Expired`, `Forbidden`, `NotFound`, `Gone`…
    var reason: String?
    var message: String
    /// A 429's `Retry-After`, in seconds.
    var retryAfter: Int?
    /// The Status's `details.causes`: an apply's 409 names each field and
    /// the manager that owns it there (`FieldManagerConflict`).
    var causes: [KubeStatusCause] = []

    var errorDescription: String? { message }

    /// The resource version (or a list's `continue`) is too old: list again.
    var isGone: Bool { status == 410 }
    var isForbidden: Bool { status == 403 }
    var isNotFound: Bool { status == 404 }
    /// Throttled (429) or the server failing for now (5xx, its JSON
    /// Status — not the proxy's plain text): worth trying again.
    var isTransient: Bool { status == 429 || (500...599).contains(status) }

    /// From a response that isn't a success.
    static func from(_ response: HTTPResponse) -> KubeAPIError {
        var error =
            (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]).map { status($0, code: response.status) }
            ?? KubeAPIError(status: response.status, reason: nil, message: response.errorMessage)
        error.status = response.status
        error.retryAfter = response.header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return error
    }

    /// A `Status` object: a response's body, or an in-stream ERROR event's.
    static func status(_ object: [String: Any], code: Int? = nil) -> KubeAPIError {
        let status = (object["code"] as? NSNumber)?.intValue ?? code ?? 500
        var message = object["message"] as? String ?? (object["reason"] as? String) ?? "HTTP \(status)"
        // What the message leaves out (an eviction's PodDisruptionBudget says which, and why, only here).
        let causes = ((object["details"] as? [String: Any])?["causes"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
            .filter { !$0.isEmpty && !message.contains($0) }
        if !causes.isEmpty { message += " " + causes.joined(separator: " ") }
        var error = KubeAPIError(status: status, reason: object["reason"] as? String, message: message)
        error.causes = ((object["details"] as? [String: Any])?["causes"] as? [[String: Any]] ?? []).map {
            KubeStatusCause(reason: $0["reason"] as? String ?? "", message: $0["message"] as? String ?? "", field: $0["field"] as? String ?? "")
        }
        return error
    }
}

/// One of a Status's `details.causes`.
struct KubeStatusCause: Equatable, Sendable {
    var reason: String
    var message: String
    var field: String
}

/// One event of a watch, its object a Table of one row (or, from a server
/// without Table support, the object itself).
enum KubeWatchEvent: Equatable, Sendable {
    case added(KubeRow, resourceVersion: String?)
    case modified(KubeRow, resourceVersion: String?)
    case deleted(KubeRow, resourceVersion: String?)
    /// Nothing changed, but the watch has got this far: resume from here.
    /// `initialEventsEnd`: a streaming list's end (`sendInitialEvents`).
    case bookmark(resourceVersion: String, initialEventsEnd: Bool)
    /// An in-stream `ERROR` — a 410 most often: the resource version is
    /// too old, list again.
    case error(KubeAPIError)

    var resourceVersion: String? {
        switch self {
        case .added(_, let version), .modified(_, let version), .deleted(_, let version): version
        case .bookmark(let version, _): version
        case .error: nil
        }
    }
}

/// Newline-delimited watch events, decoded. A watch on a Table sends
/// `columnDefinitions` in its first event only; later events are Tables
/// without headers, so the ones kept (from the list, then the first event)
/// are reused. Pure.
struct KubeWatchDecoder: Sendable {
    private(set) var columns: [KubeColumn]
    let namespace: String?
    /// What is watched, for the kinds whose cells are read with care.
    let kind: KubeResourceKind?
    /// Whether the rows say who deploys them (`KubeListOptions.owners`).
    let owners: Bool
    private var lines = DockerLineSplitter()

    init(columns: [KubeColumn], namespace: String?, kind: KubeResourceKind? = nil, owners: Bool = false) {
        self.columns = columns
        self.namespace = namespace
        self.kind = kind
        self.owners = owners
    }

    /// The events whole in `data` and what came before it.
    mutating func feed(_ data: Data) throws -> [KubeWatchEvent] {
        try lines.feed(data).flatMap { try decode($0) }
    }

    /// What a stream that ended without a last newline still said.
    mutating func finish() throws -> [KubeWatchEvent] {
        guard let last = lines.finish() else { return [] }
        return try decode(last)
    }

    mutating func decode(_ line: Data) throws -> [KubeWatchEvent] {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String,
            let object = event["object"] as? [String: Any]
        else { throw KubeTableReader.Malformed(detail: String(decoding: line.prefix(120), as: UTF8.self)) }
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let version = metadata["resourceVersion"] as? String
        switch type {
        case "ERROR":
            return [.error(KubeAPIError.status(object))]
        case "BOOKMARK":
            return [.bookmark(resourceVersion: version ?? "", initialEventsEnd: bookmark(object))]
        case "ADDED", "MODIFIED", "DELETED":
            let table = try KubeTableReader.read(object, namespace: namespace, columns: columns, kind: kind, owners: owners)
            if object["kind"] as? String == "Table", !table.columns.isEmpty { columns = table.columns }
            return table.rows.map { row in
                switch type {
                case "ADDED": .added(row, resourceVersion: version)
                case "MODIFIED": .modified(row, resourceVersion: version)
                default: .deleted(row, resourceVersion: version)
                }
            }
        default:
            return []
        }
    }

    /// Whether a bookmark is a streaming list's end, its Table's columns
    /// kept. A plain object carries `k8s.io/initial-events-end` in its own
    /// metadata; a Table — what a real server sends when Tables are asked
    /// for (kind's 1.37) — carries it on its one row's object, whatever
    /// `includeObject` said, a row with empty cells that is no object.
    /// The Table's own metadata has only the version. The first Table of
    /// a stream has the columns: an empty list's end is that Table.
    private mutating func bookmark(_ object: [String: Any]) -> Bool {
        let key = "k8s.io/initial-events-end"
        func ends(_ metadata: Any?) -> Bool {
            ((metadata as? [String: Any])?["annotations"] as? [String: Any])?[key] as? String == "true"
        }
        if ends(object["metadata"]) { return true }
        guard object["kind"] as? String == "Table" else { return false }
        if let definitions = object["columnDefinitions"] as? [[String: Any]], !definitions.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: definitions),
            let read = try? JSONDecoder().decode([KubeColumn].self, from: data)
        {
            columns = read
        }
        let rows = object["rows"] as? [[String: Any]] ?? []
        return rows.contains { ends(($0["object"] as? [String: Any])?["metadata"]) }
    }
}
