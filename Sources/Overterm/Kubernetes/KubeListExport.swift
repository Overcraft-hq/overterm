import Foundation

/// A list as CSV: the columns the page shows, in its order, and the rows
/// its filter lets through, each cell as drawn (an age as it reads now).
/// RFC 4180 by `ResultExport` — a field with a comma, a quote or a line
/// break quoted, its quotes doubled — and, since a cluster's text is
/// anybody's (a CRD's printer column, an annotation), a cell a spreadsheet
/// would run as a formula (`=`, `+`, `@`, a tab or a carriage return in
/// front; `-` too, unless it is a number or `-` alone) is prefixed with `'`,
/// as OWASP's advice has it. Pure.
enum KubeListExport {
    static func csv(columns: [String], rows: [[String]]) -> String { text(.csv, columns: columns, rows: rows) }

    /// The same as `format` (`.csv`, or `.tsv` for a spreadsheet's paste):
    /// every cell inert either way.
    static func text(_ format: ResultExport.Format, columns: [String], rows: [[String]]) -> String {
        ResultExport.text(format, columns: columns.map(inert), rows: rows.map { $0.map { inert($0) } })
    }

    /// A cell that a spreadsheet opens as text.
    static func inert(_ cell: String) -> String {
        guard let first = cell.first else { return cell }
        switch first {
        case "=", "+", "@", "\t", "\r": return "'" + cell
        case "-" where cell.count > 1 && Double(cell) == nil: return "'" + cell
        default: return cell
        }
    }

    /// `fake-dev-shop-deployments.csv`: what a file of the list is called.
    static func fileName(context: String, kind: KubeResourceKind, scope: KubeScope) -> String {
        let place: String? =
            switch scope {
            case _ where !kind.namespaced: nil
            case .all: "all"
            case .namespace(let name): name
            case .namespaces(let names): names.count <= 3 ? names.sorted().joined(separator: "-") : "\(names.count)-namespaces"
            }
        let name = [context, place, kind.resource].compactMap { $0 }.joined(separator: "-")
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "_" }
        return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ".csv"
    }
}

/// A Deployment row's state, read off its cells — Ready (`ready/desired`),
/// Up-to-date and Available — for the Status column the server's Table
/// doesn't have (kubectl's Deployments have none): the list is rows only,
/// so the conditions aren't there; the detail's Rollout reads them
/// (`KubeRollout`), a stuck one's deadline with them. Pure.
enum KubeDeploymentHint: Equatable, Sendable {
    case available
    case scaledToZero
    /// Fewer replicas than wanted run the newest template.
    case rollingOut(updated: Int, desired: Int)
    case unavailable(available: Int, desired: Int)
    case notReady(ready: Int, desired: Int)

    /// The Status column's id among the page's columns.
    static let column = "hint.status"

    init?(row: KubeRow, columns: [KubeColumn]) {
        guard let ready = row.cell("Ready", in: columns)?.text, case let parts = ready.split(separator: "/"), parts.count == 2,
            let readyCount = Int(parts[0]), let desired = Int(parts[1])
        else { return nil }
        let updated = row.cell("Up-to-date", in: columns).flatMap { Int($0.text) } ?? desired
        let available = row.cell("Available", in: columns).flatMap { Int($0.text) } ?? readyCount
        if desired == 0 {
            self = .scaledToZero
        } else if updated < desired {
            self = .rollingOut(updated: updated, desired: desired)
        } else if available < desired {
            self = .unavailable(available: available, desired: desired)
        } else if readyCount < desired {
            self = .notReady(ready: readyCount, desired: desired)
        } else {
            self = .available
        }
    }

    /// Whether a list of `kind` with these columns gets the column: a
    /// Deployments list whose Table has no Status of its own.
    static func applies(to kind: KubeResourceKind, columns: [KubeColumn]) -> Bool {
        kind.fullName == "deployments.apps" && !columns.isEmpty && KubeColumn.index(of: "Status", in: columns) == nil
            && KubeColumn.index(of: "Ready", in: columns) != nil
    }

    var text: String {
        switch self {
        case .available: "Available"
        case .scaledToZero: "Scaled to 0"
        case .rollingOut(let updated, let desired): "Rolling out \(updated)/\(desired)"
        case .unavailable(let available, let desired): "Unavailable \(available)/\(desired)"
        case .notReady(let ready, let desired): "Not ready \(ready)/\(desired)"
        }
    }

    var isBad: Bool { if case .unavailable = self { true } else { false } }
    var isDone: Bool { self == .available || self == .scaledToZero }
}
