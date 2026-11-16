import Foundation

/// InfluxDB's console: InfluxQL (1.x, and 2.x's compatibility API), Flux
/// (2.x) or SQL (3.x) — the server's version says which a statement goes to
/// (`InfluxDBDriver`). A block of lines up to a blank one is a statement, and
/// a `;` outside strings and comments ends one too (Flux has none). `USE db`
/// alone, or as a statement's first line, says the database (a bucket on
/// 2.x) the rest runs in. `WRITE` followed by line protocol — on its line
/// and the lines after, to a blank one — writes those points. Pure.
enum InfluxText: KindConsoleText {
    static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        for block in blocks(ns) {
            let chunk = ns.substring(with: block)
            if verb(of: chunk) == "WRITE" {
                ranges.append(block)
                continue
            }
            for part in splitOnSemicolons(chunk) {
                ranges.append(NSRange(location: block.location + part.location, length: part.length))
            }
        }
        return ranges
    }

    /// Runs of lines between blank ones, trimmed.
    private static func blocks(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int?
        var end = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let blank = ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
            if blank {
                if let begun = start { ranges.append(NSRange(location: begun, length: end - begun)) }
                start = nil
            } else {
                if start == nil { start = line.location }
                end = NSMaxRange(line)
            }
        }
        if let begun = start { ranges.append(NSRange(location: begun, length: end - begun)) }
        return ranges.map { trimmed($0, in: ns) }.filter { $0.length > 0 }
    }

    /// `;`s outside '…', "…", `--` and `//` comments, and `/* */`.
    private static func splitOnSemicolons(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        var i = 0
        func add(_ end: Int) {
            let range = trimmed(NSRange(location: start, length: end - start), in: ns)
            if range.length > 0 { ranges.append(range) }
        }
        while i < ns.length {
            let c = ns.character(at: i)
            let next = i + 1 < ns.length ? ns.character(at: i + 1) : 0
            if c == 0x27 || c == 0x22 {  // ' "
                var j = i + 1
                while j < ns.length {
                    let d = ns.character(at: j)
                    if d == 0x5C {
                        j += 2
                        continue
                    }
                    if d == c { break }
                    j += 1
                }
                i = j + 1
                continue
            }
            if (c == 0x2D && next == 0x2D) || (c == 0x2F && next == 0x2F) {  // -- //
                let newline = ns.range(of: "\n", options: [], range: NSRange(location: i, length: ns.length - i))
                i = newline.location == NSNotFound ? ns.length : newline.location
                continue
            }
            if c == 0x2F && next == 0x2A {  // /*
                let close = ns.range(of: "*/", options: [], range: NSRange(location: i + 2, length: ns.length - i - 2))
                i = close.location == NSNotFound ? ns.length : NSMaxRange(close)
                continue
            }
            if c == 0x3B {
                add(i)
                start = i + 1
            }
            i += 1
        }
        add(ns.length)
        return ranges
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        func isSpace(_ i: Int) -> Bool { Unicode.Scalar(ns.character(at: i)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// A `USE db` line leading a statement, and what follows it.
    static func use(_ statement: String) -> (database: String, rest: String)? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.prefix { $0 != "\n" }
        let words = firstLine.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2, words[0].uppercased() == "USE" else { return nil }
        var name = words[1].trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(";") { name.removeLast() }
        if name.count >= 2, let first = name.first, first == "\"" || first == "'" || first == "`", name.last == first {
            name = String(name.dropFirst().dropLast())
        }
        guard !name.isEmpty else { return nil }
        let rest = String(trimmed.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, rest)
    }

    /// A statement's language: InfluxQL/SQL by its first keyword, else Flux.
    static func isFlux(_ statement: String) -> Bool {
        let body = use(statement)?.rest ?? statement
        return !sqlVerbs.contains(SQLText.verb(of: body))
    }

    static let sqlVerbs: Set<String> = [
        "SELECT", "SHOW", "EXPLAIN", "WITH", "CREATE", "DROP", "DELETE", "ALTER", "GRANT", "REVOKE", "KILL", "SET", "INSERT", "UPDATE",
        "WRITE", "USE", "DESCRIBE",
    ]

    /// SELECT, SHOW…; WRITE; USE; else "Flux".
    static func verb(of statement: String) -> String {
        let body = use(statement).map { $0.rest.isEmpty ? statement : $0.rest } ?? statement
        let verb = SQLText.verb(of: body)
        return sqlVerbs.contains(verb) ? verb : "Flux"
    }

    /// The line protocol after `WRITE`, a point a line.
    static func lineProtocol(_ statement: String) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 5, trimmed.prefix(5).uppercased() == "WRITE", trimmed.dropFirst(5).first?.isWhitespace == true else { return nil }
        let lines = trimmed.dropFirst(5).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Flux functions that send data somewhere: `to()`, `wideTo()`, and
    /// the packages that post, notify or write to SQL. `sql.from` reads.
    private static let fluxWrites =
        #"(^|[^\w.])(to|wideTo)\s*\(|\b(experimental|influxdb)\.(to|wideTo)\s*\(|\bsql\.to\s*\(|\b(http|requests)\.(post|do|put|patch|delete)\s*\(|\b(slack|pagerduty|opsgenie|telegram|discord|teams|sensu|victorops|pushbullet|zenoss|servicenow|bigpanda|mqtt|alerta|hipchat|alerts|monitor)\.\w+\s*\("#

    static func onlyReads(_ statement: String) -> Bool {
        let body = use(statement).map { $0.rest } ?? statement
        if body.isEmpty { return true }  // `USE db` alone
        let verb = verb(of: body)
        switch verb {
        case "Flux":
            return blanked(body).range(of: fluxWrites, options: .regularExpression) == nil
        case "SELECT", "WITH":
            // InfluxQL's SELECT … INTO writes the points it selects.
            return SQLText.stripped(body).uppercased().range(of: #"\bINTO\b"#, options: .regularExpression) == nil
        case "SHOW", "EXPLAIN", "DESCRIBE": return true
        default: return false
        }
    }

    static func agentReads(_ statement: String) -> Bool { onlyReads(statement) }

    static func danger(of statement: String) -> String? {
        let body = use(statement)?.rest ?? statement
        let upper = SQLText.stripped(body).uppercased()
        let words = upper.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        switch verb(of: body) {
        case "DROP":
            let what = words.dropFirst().prefix(2).joined(separator: " ").lowercased()
            if words.count > 1, words[1] == "SERIES", upper.range(of: #"\b(WHERE|FROM)\b"#, options: .regularExpression) == nil {
                return "It drops every series of the database."
            }
            return "It drops \(what) — its points with it."
        case "DELETE":
            return upper.range(of: #"\bWHERE\b"#, options: .regularExpression) == nil
                ? "It has no WHERE: every point of \(words.contains("FROM") ? "the measurement" : "the database") is deleted." : nil
        default: return nil
        }
    }

    /// The measurement: InfluxQL/SQL's FROM, Flux's `_measurement == "…"`
    /// (else its bucket), a WRITE's first point's.
    static func subject(of statement: String) -> String? {
        let body = use(statement)?.rest ?? statement
        if let lines = lineProtocol(body) {
            let first = lines.prefix { $0 != "\n" }
            return String(first.prefix { $0 != "," && $0 != " " }).replacingOccurrences(of: "\\", with: "")
        }
        if isFlux(body) {
            for pattern in [#"_measurement\s*==\s*"([^"]+)""#, #"bucket\s*:\s*"([^"]+)""#] {
                if let found = firstGroup(pattern, in: body) { return found }
            }
            return nil
        }
        if let found = firstGroup(#"(?i)\bFROM\s+(?:"(?:[^"]+)"\.(?:"[^"]*"|\w*)\.)?"([^"]+)""#, in: body) { return found }
        if let found = firstGroup(#"(?i)\bFROM\s+(?:[\w-]+\.[\w-]*\.)?([\w-]+)"#, in: body) { return found }
        return nil
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Flux with its strings and comments blanked.
    private static func blanked(_ flux: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        var comment = false
        for c in flux {
            if comment {
                if c == "\n" {
                    comment = false
                    out.append(c)
                }
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                    out.append("\"")
                }
                continue
            }
            if c == "\"" {
                inString = true
                out.append("\"")
            } else if c == "/", out.last == "/" {
                out.removeLast()
                comment = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: The panel's

    /// `"cpu"` in InfluxQL and SQL; Flux's strings are JSON's.
    static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// A measurement's latest points: Flux on 2.x, else InfluxQL/SQL (the same words).
    static func browse(_ table: CatalogTable, connection: DatabaseConnection, limit: Int) -> String {
        if InfluxVersion(rawValue: connection.location) == .v2 {
            return """
                from(bucket: \(HTTPDriverTransport.quoted(table.schema)))
                  |> range(start: -1h)
                  |> filter(fn: (r) => r._measurement == \(HTTPDriverTransport.quoted(table.name)))
                  |> limit(n: \(limit))
                """
        }
        return "USE \(quote(table.schema))\nSELECT * FROM \(quote(table.name)) ORDER BY time DESC LIMIT \(limit)"
    }
}

/// Which InfluxDB: the connection's Location holds it (`1`, `2`, `3`), or
/// it is empty and `/ping` says.
enum InfluxVersion: String, CaseIterable, Identifiable, Sendable {
    case v1 = "1", v2 = "2", v3 = "3"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .v1: "1.x — InfluxQL, a user and password"
        case .v2: "2.x — Flux, a token and an organization"
        case .v3: "3.x — SQL, a token and a database"
        }
    }

    /// `X-Influxdb-Version`: `1.8.10`, `v2.7.11`, `2.7.11`, `3.0.1`…
    static func from(header: String?) -> InfluxVersion? {
        guard let header else { return nil }
        let text = header.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = text.drop { !$0.isNumber }
        switch digits.first {
        case "1": return .v1
        case "2": return .v2
        case "3": return .v3
        default: return nil
        }
    }
}

/// What InfluxDB answers, as rows. Pure.
enum InfluxParse {
    /// One InfluxQL series: `{"name", "tags", "columns", "values"}`.
    struct Series: Equatable {
        var name: String
        var tags: [String: String]
        var columns: [String]
        var values: [[String?]]
    }

    /// `/query`'s JSON: each statement's series, or its error.
    static func influxQL(_ data: Data) throws -> [[Series]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DatabaseError.failed("InfluxDB's answer isn't JSON: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        if let error = object["error"] as? String { throw DatabaseError.failed(error) }
        var statements: [[Series]] = []
        for result in object["results"] as? [[String: Any]] ?? [] {
            if let error = result["error"] as? String { throw DatabaseError.failed(error) }
            var series: [Series] = []
            for s in result["series"] as? [[String: Any]] ?? [] {
                let tags = (s["tags"] as? [String: Any] ?? [:]).mapValues { HTTPDriverTransport.text($0) ?? "" }
                let values = (s["values"] as? [[Any]] ?? []).map { $0.map(HTTPDriverTransport.text) }
                series.append(Series(name: s["name"] as? String ?? "", tags: tags, columns: s["columns"] as? [String] ?? [], values: values))
            }
            statements.append(series)
        }
        return statements
    }

    /// Series as one table: the measurement's name when there are several,
    /// then their tags (by name), then their columns in the order they come.
    static func rows(_ series: [Series], limit: Int) -> QueryResult {
        var result = QueryResult()
        guard !series.isEmpty else { return result }
        let names = Set(series.map(\.name))
        let named = names.count > 1
        let tagKeys = Array(Set(series.flatMap(\.tags.keys))).sorted()
        var columns: [String] = []
        for s in series { for column in s.columns where !columns.contains(column) { columns.append(column) } }
        result.columns = (named ? ["name"] : []) + tagKeys + columns
        result.types = Array(repeating: "", count: result.columns.count)
        var count = 0
        outer: for s in series {
            let index = Dictionary(s.columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            for value in s.values {
                count += 1
                if count > limit { break outer }
                var row: [String?] = named ? [s.name] : []
                row += tagKeys.map { s.tags[$0] }
                row += columns.map { index[$0].flatMap { $0 < value.count ? value[$0] : nil } }
                result.rows.append(row)
            }
        }
        result.truncated = count > limit
        return result
    }

    /// RFC 4180: fields split on commas, quoted ones with `""` for a quote
    /// and line breaks inside; a record a line.
    static func csv(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var startedQuoted = false
        var iterator = Array(text.unicodeScalars)[...]
        while let c = iterator.popFirst() {
            if quoted {
                if c == "\"" {
                    if iterator.first == "\"" {
                        field.unicodeScalars.append("\"")
                        iterator = iterator.dropFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty && !startedQuoted:
                quoted = true
                startedQuoted = true
            case ",":
                record.append(field)
                field = ""
                startedQuoted = false
            case "\r":
                continue
            case "\n":
                record.append(field)
                records.append(record)
                record = []
                field = ""
                startedQuoted = false
            default:
                field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty || startedQuoted {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// Flux's annotated CSV: tables, each its `#datatype`/`#group`/`#default`
    /// rows, a header, its rows, a blank line between. One table out: every
    /// column any table has (the annotation column and `result` left out),
    /// a cell empty in a non-string column NULL. An `error` table is thrown.
    static func flux(_ text: String, limit: Int) throws -> QueryResult {
        var result = QueryResult()
        var columns: [String] = []
        var types: [String: String] = [:]
        var header: [String]?
        var datatypes: [String] = []
        var count = 0
        for record in csv(text) {
            if record.allSatisfy(\.isEmpty) {
                header = nil
                datatypes = []
                continue
            }
            if let first = record.first, first.hasPrefix("#") {
                if first == "#datatype" { datatypes = record }
                continue
            }
            guard let names = header else {
                header = record
                if record.contains("error"), record.contains("reference") || record.count <= 3 { continue }
                for (index, name) in record.enumerated() where index > 0 && name != "result" && !name.isEmpty {
                    if !columns.contains(name) { columns.append(name) }
                    if index < datatypes.count, types[name] == nil { types[name] = datatypes[index] }
                }
                continue
            }
            if let at = names.firstIndex(of: "error"), names.contains("reference") || names.count <= 3, at < record.count, !record[at].isEmpty {
                throw DatabaseError.failed(record[at])
            }
            count += 1
            if count > limit { continue }
            var cells: [String: String?] = [:]
            for (index, name) in names.enumerated() where index > 0 && index < record.count {
                let value = record[index]
                let type = types[name] ?? ""
                cells[name] = value.isEmpty && type != "string" ? String?.none : value
            }
            result.rows.append(columns.map { cells[$0] ?? nil })
        }
        // A table's columns that arrive late: earlier rows NULL there.
        result.rows = result.rows.map { $0 + Array(repeating: nil, count: columns.count - $0.count) }
        result.columns = columns
        result.types = columns.map { types[$0] ?? "" }
        result.truncated = count > limit
        return result
    }

    /// A plain CSV with a header (InfluxDB 3's): empty cells NULL.
    static func plainCSV(_ text: String, limit: Int) -> QueryResult {
        var records = csv(text)
        var result = QueryResult()
        guard !records.isEmpty else { return result }
        result.columns = records.removeFirst()
        result.types = Array(repeating: "", count: result.columns.count)
        records = records.filter { !($0.count == 1 && $0[0].isEmpty) }
        result.rows = records.prefix(limit).map { record in result.columns.indices.map { $0 < record.count && !record[$0].isEmpty ? record[$0] : nil } }
        result.truncated = records.count > limit
        return result
    }

    /// One column's values (a Flux `_value`, InfluxQL's `name`), in order.
    static func column(_ name: String, of result: QueryResult) -> [String] {
        guard let index = result.columns.firstIndex(of: name) else { return [] }
        return result.rows.compactMap { $0[index] }
    }
}
