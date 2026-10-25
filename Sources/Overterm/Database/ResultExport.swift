import Foundation

/// A result's rows as text to copy or save: TSV (what a spreadsheet takes
/// from the pasteboard), CSV, JSON, a Markdown table, INSERT statements.
/// Pure.
enum ResultExport {
    enum Format: String, CaseIterable, Identifiable {
        case tsv, csv, json, markdown, insert
        var id: String { rawValue }

        var title: String {
            switch self {
            case .tsv: "Tab-Separated"
            case .csv: "CSV"
            case .json: "JSON"
            case .markdown: "Markdown Table"
            case .insert: "INSERT Statements"
            }
        }

        var fileExtension: String {
            switch self {
            case .tsv: "tsv"
            case .csv: "csv"
            case .json: "json"
            case .markdown: "md"
            case .insert: "sql"
            }
        }
    }

    static func text(_ format: Format, columns: [String], rows: [[String?]], table: String = "table_name", header: Bool = true) -> String {
        switch format {
        case .tsv:
            let lines = rows.map { $0.map { ($0 ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") } }
            return ((header ? [columns] : []) + lines).map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .csv:
            func field(_ value: String?) -> String {
                guard let value else { return "" }
                return value.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }
            return ((header ? [columns.map(field)] : []) + rows.map { $0.map(field) }).map { $0.joined(separator: ",") }.joined(separator: "\n")
                + "\n"
        case .json:
            let objects = rows.map { row in
                Dictionary(uniqueKeysWithValues: zip(columns, row).map { ($0, $1.map { $0 as Any } ?? NSNull()) })
            }
            let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        case .markdown:
            func cell(_ value: String?) -> String { (value ?? "NULL").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            var lines = ["| " + columns.map(cell).joined(separator: " | ") + " |", "|" + columns.map { _ in " --- |" }.joined()]
            lines += rows.map { "| " + $0.map(cell).joined(separator: " | ") + " |" }
            return lines.joined(separator: "\n")
        case .insert:
            func literal(_ value: String?) -> String {
                guard let value else { return "NULL" }
                if Double(value) != nil, !value.hasPrefix("0") || value == "0" || value.hasPrefix("0.") { return value }
                return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
            }
            let names = columns.joined(separator: ", ")
            return rows.map { "INSERT INTO \(table) (\(names)) VALUES (\($0.map(literal).joined(separator: ", ")));" }.joined(separator: "\n")
        }
    }

    /// Rows sorted by a column: numbers as numbers, NULLs last.
    static func sorted(_ rows: [[String?]], by column: Int, ascending: Bool) -> [[String?]] {
        rows.sorted { a, b in
            let x = column < a.count ? a[column] : nil
            let y = column < b.count ? b[column] : nil
            switch (x, y) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?):
                if let p = Double(x), let q = Double(y) { return ascending ? p < q : p > q }
                let order = x.localizedStandardCompare(y)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
    }
}
