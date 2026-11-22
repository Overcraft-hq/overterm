import Foundation

/// A list as CSV: the columns a page shows, in its order, and the rows
/// its filter lets through, each cell as drawn (an age as it reads now).
/// RFC 4180 by `ResultExport` — a field with a comma, a quote or a line
/// break quoted, its quotes doubled — and, since a cluster's text is
/// anybody's (a CRD's printer column, an annotation), a cell a spreadsheet
/// would run as a formula (`=`, `+`, `@`, a tab or a carriage return in
/// front; `-` too, unless it is a number or `-` alone) is prefixed with `'`,
/// as OWASP's advice has it. Pure.
package enum ListExport {
    package static func csv(columns: [String], rows: [[String]]) -> String { text(.csv, columns: columns, rows: rows) }

    /// The same as `format` (`.csv`, or `.tsv` for a spreadsheet's paste):
    /// every cell inert either way.
    package static func text(_ format: ResultExport.Format, columns: [String], rows: [[String]]) -> String {
        ResultExport.text(format, columns: columns.map(inert), rows: rows.map { $0.map { inert($0) } })
    }

    /// A cell that a spreadsheet opens as text.
    package static func inert(_ cell: String) -> String {
        guard let first = cell.first else { return cell }
        switch first {
        case "=", "+", "@", "\t", "\r": return "'" + cell
        case "-" where cell.count > 1 && Double(cell) == nil: return "'" + cell
        default: return cell
        }
    }
}
