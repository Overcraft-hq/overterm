import Foundation

/// DuckDB's console: SQL as SQLText reads it, with DuckDB's own reads —
/// `FROM t` first, `SUMMARIZE`, `PIVOT` — and one thing more an agent is
/// asked about: a statement that reaches outside the database. DuckDB reads
/// any file or URL a query names (`FROM 'orders.csv'`, `read_parquet(…)`,
/// `query('…')` runs text as SQL), so an agent's statement naming one runs
/// only when the user allows it, as a write does. A person's never asks.
/// Pure.
package enum DuckText: KindConsoleText {
    package static func statements(in text: String) -> [NSRange] { SQLText.statements(in: text) }

    package static func verb(of statement: String) -> String { SQLText.verb(of: statement) }

    /// DuckDB's statements that only read, beyond SQL's.
    private static let reads: Set<String> = ["FROM", "SUMMARIZE", "PIVOT", "UNPIVOT"]

    package static func onlyReads(_ statement: String) -> Bool {
        SQLText.onlyReads(statement) || reads.contains(verb(of: statement))
    }

    /// Read only, judged as SQL's are — `FROM t` as `SELECT * FROM t` — and
    /// naming nothing outside the database; PRAGMA only for the ones that say
    /// what the database is.
    package static func agentReads(_ statement: String) -> Bool {
        guard onlyReads(statement), outside(statement) == nil else { return false }
        let verb = verb(of: statement)
        if verb == "PRAGMA" {
            let text = stripped(statement).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let name = text.dropFirst("PRAGMA".count).trimmingCharacters(in: .whitespaces)
            return pragmas.contains { name.hasPrefix($0) }
        }
        return SQLText.agentReads(reads.contains(verb) ? "SELECT * " + statement : statement)
    }

    /// The PRAGMAs an agent runs without asking: each only says something.
    private static let pragmas = ["TABLE_INFO", "SHOW_TABLES", "SHOW_TABLES_EXPANDED", "DATABASE_LIST", "DATABASE_SIZE", "VERSION", "STORAGE_INFO", "SHOW"]

    package static func danger(of statement: String) -> String? { SQLText.danger(of: statement) }

    package static func subject(of statement: String) -> String? { SQLText.tables(in: statement).first?.name }

    /// What a statement reaches outside the database, said; nil when it
    /// reaches nothing. Text can't see everything — a string built at run
    /// time — so it errs towards saying so: a function that reads files or
    /// URLs or runs text, and any string or quoted name that looks like a
    /// path, a URL or a file.
    package static func outside(_ statement: String) -> String? {
        let bare = stripped(statement)
        let functions = #"(?i)\b(read_[a-z_]+|glob|sniff_csv|parquet_[a-z_]+|delta_scan|iceberg_[a-z_]+|query|query_table|getenv|which_secret|duckdb_secrets)\s*\("#
        if let match = bare.range(of: functions, options: .regularExpression) {
            let name = bare[match].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return "It calls \(name)(), which reads outside the database or runs text as SQL."
        }
        for quoted in quotedTexts(statement) where looksLikeAPlace(quoted) {
            return "It names “\(quoted)”, which DuckDB reads as a file or a URL."
        }
        return nil
    }

    /// A string's or a quoted name's text that is a path, a URL or a file
    /// by its extension.
    private static func looksLikeAPlace(_ text: String) -> Bool {
        if text.contains("/") || text.contains("\\") || text.hasPrefix("~") || text.contains("://") { return true }
        let extensions = ["csv", "tsv", "txt", "parquet", "json", "jsonl", "ndjson", "gz", "zst", "xlsx", "db", "duckdb", "sqlite", "arrow", "avro", "orc"]
        return extensions.contains((text as NSString).pathExtension.lowercased())
    }

    /// Every `'…'` string's and `"…"` name's text, comments skipped.
    private static func quotedTexts(_ statement: String) -> [String] {
        var texts: [String] = []
        let chars = Array(statement)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "'" || c == "\"" {
                var text = ""
                i += 1
                while i < chars.count {
                    if chars[i] == c {
                        // A doubled quote is one of it, inside.
                        if i + 1 < chars.count, chars[i + 1] == c {
                            text.append(c)
                            i += 2
                            continue
                        }
                        break
                    }
                    text.append(chars[i])
                    i += 1
                }
                texts.append(text)
            }
            i += 1
        }
        return texts
    }

    private static func stripped(_ statement: String) -> String { SQLText.stripped(statement) }
}
