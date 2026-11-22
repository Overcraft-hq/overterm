import Foundation

/// Neo4j's console: Cypher, statements ended by a `;` (outside strings,
/// `backtick` names and comments) or a blank line. `:use db` — Neo4j
/// Browser's — alone or as a statement's first line, says the database the
/// rest runs in. Pure.
package enum CypherText: KindConsoleText {
    package static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        var i = 0
        var lineStart = 0
        func add(_ end: Int) {
            let range = trimmed(NSRange(location: start, length: end - start), in: ns)
            if range.length > 0 { ranges.append(range) }
        }
        while i < ns.length {
            let c = ns.character(at: i)
            let next = i + 1 < ns.length ? ns.character(at: i + 1) : 0
            switch c {
            case 0x27, 0x22, 0x60:  // ' " `
                var j = i + 1
                while j < ns.length {
                    let d = ns.character(at: j)
                    if d == 0x5C, c != 0x60 {
                        j += 2
                        continue
                    }
                    if d == c {
                        // A doubled backtick is one inside a name.
                        if c == 0x60, j + 1 < ns.length, ns.character(at: j + 1) == 0x60 {
                            j += 2
                            continue
                        }
                        break
                    }
                    j += 1
                }
                i = j + 1
                continue
            case 0x2F where next == 0x2F:  // //
                let newline = ns.range(of: "\n", options: [], range: NSRange(location: i, length: ns.length - i))
                i = newline.location == NSNotFound ? ns.length : newline.location
                continue
            case 0x2F where next == 0x2A:  // /*
                let close = ns.range(of: "*/", options: [], range: NSRange(location: i + 2, length: ns.length - i - 2))
                i = close.location == NSNotFound ? ns.length : NSMaxRange(close)
                continue
            case 0x3B:
                add(i)
                start = i + 1
            case 0x0A:
                // A blank line ends a statement too.
                let line = ns.substring(with: NSRange(location: lineStart, length: i - lineStart))
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    add(lineStart)
                    start = i + 1
                }
                lineStart = i + 1
            default:
                break
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

    /// `:use db` leading a statement, and what follows it.
    package static func use(_ statement: String) -> (database: String, rest: String)? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.prefix { $0 != "\n" }
        let words = firstLine.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2, words[0].lowercased() == ":use" else { return nil }
        var name = words[1].trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(";") { name.removeLast() }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard !name.isEmpty else { return nil }
        return (name, String(trimmed.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The statement with strings, names in backticks and comments blanked,
    /// upper-cased — what the checks read.
    package static func stripped(_ statement: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        var lineComment = false
        var blockComment = false
        var previous: Character = " "
        for c in statement {
            defer { previous = c }
            if lineComment {
                if c == "\n" {
                    lineComment = false
                    out.append("\n")
                }
                continue
            }
            if blockComment {
                if previous == "*", c == "/" { blockComment = false }
                continue
            }
            if let open = quote {
                if escaped {
                    escaped = false
                } else if c == "\\", open != "`" {
                    escaped = true
                } else if c == open {
                    quote = nil
                    out.append(open == "`" ? "x" : "'")
                }
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                quote = c
                out.append(c == "`" ? " x" : " '")
                continue
            }
            if previous == "/", c == "/" {
                out.removeLast()
                lineComment = true
                continue
            }
            if previous == "/", c == "*" {
                out.removeLast()
                blockComment = true
                continue
            }
            out.append(c)
        }
        return out.uppercased()
    }

    /// A clause that writes, as a keyword — not a property (`n.set`), a
    /// parameter (`$delete`), nor a label (`:Create`).
    private static let writes = #"(?<![\w.$:])(CREATE|MERGE|SET|DELETE|REMOVE|DROP|DETACH|FOREACH|LOAD\s+CSV|ALTER|RENAME|GRANT|REVOKE|DENY|START|STOP|ENABLE|TERMINATE)(?![\w])"#

    /// Procedures that only read: the catalog's and the server's own.
    private static let readingProcedures =
        #"^(DB\.(LABELS|RELATIONSHIPTYPES|PROPERTYKEYS|SCHEMA\.[A-Z.]+|INDEXES|CONSTRAINTS|INFO|PING|INDEX\.FULLTEXT\.QUERY[A-Z]+|INDEX\.VECTOR\.QUERY[A-Z]+)|DBMS\.(COMPONENTS|INFO|PROCEDURES|FUNCTIONS|LISTCONFIG|QUERYJMX|SHOWCURRENTUSER)|APOC\.META\.[A-Z.]+)$"#

    package static func verb(of statement: String) -> String {
        let body = use(statement).map { $0.rest.isEmpty ? statement : $0.rest } ?? statement
        let upper = stripped(body)
        if upper.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":USE") { return "USE" }
        if let range = upper.range(of: writes, options: .regularExpression) {
            let word = String(upper[range]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return word == "DETACH" ? "DETACH DELETE" : word
        }
        return String(upper.drop { $0.isWhitespace }.prefix { $0.isLetter })
    }

    /// No clause that writes, and every procedure it calls one that reads —
    /// or, for a person, any procedure (the server's read mode stops a
    /// write one: `access-mode: READ`).
    package static func onlyReads(_ statement: String) -> Bool { reads(statement, strictProcedures: false) }

    /// Stricter: a procedure only from the list that reads, and no
    /// `CALL { } IN TRANSACTIONS`.
    package static func agentReads(_ statement: String) -> Bool { reads(statement, strictProcedures: true) }

    private static func reads(_ statement: String, strictProcedures: Bool) -> Bool {
        let body = use(statement)?.rest ?? statement
        let upper = stripped(body)
        if upper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if upper.range(of: writes, options: .regularExpression) != nil { return false }
        if upper.range(of: #"\bIN\s+TRANSACTIONS\b"#, options: .regularExpression) != nil { return false }
        guard strictProcedures else { return true }
        for procedure in procedures(upper) where procedure.range(of: readingProcedures, options: .regularExpression) == nil {
            return false
        }
        return true
    }

    /// `CALL db.labels()` → DB.LABELS; a subquery's `CALL {` isn't one.
    package static func procedures(_ upper: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\bCALL\s+([A-Z_][A-Z0-9_]*(?:\.[A-Z_][A-Z0-9_]*)+)"#) else { return [] }
        let ns = upper as NSString
        return regex.matches(in: upper, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// DELETE with no WHERE and no property to match by: the whole graph,
    /// or every node of a label. DROP drops a schema's index, constraint, or a database.
    package static func danger(of statement: String) -> String? {
        let body = use(statement)?.rest ?? statement
        let upper = stripped(body)
        if upper.range(of: #"(?<![\w.$:])DROP\s+(DATABASE|ALIAS|USER|ROLE)\b"#, options: .regularExpression) != nil {
            return "It drops \(upper.components(separatedBy: "DROP").last?.split(separator: " ").first.map { $0.lowercased() } ?? "it") — and what it holds."
        }
        guard upper.range(of: #"(?<![\w.$:])DELETE(?![\w])"#, options: .regularExpression) != nil else { return nil }
        let filtered =
            upper.range(of: #"\bWHERE\b"#, options: .regularExpression) != nil
            || upper.range(of: #"\(\s*\w*\s*(:\s*[\w ]+)?\s*\{"#, options: .regularExpression) != nil
            || upper.range(of: #"\bLIMIT\b"#, options: .regularExpression) != nil
        guard !filtered else { return nil }
        let labelled = upper.range(of: #"MATCH\s*\(\s*\w*\s*:"#, options: .regularExpression) != nil
        return labelled ? "It has no WHERE: every node with that label is deleted." : "It has no WHERE: every node it matches — the whole graph — is deleted."
    }

    /// The first label (or relationship type) it names.
    package static func subject(of statement: String) -> String? {
        let body = use(statement)?.rest ?? statement
        guard let regex = try? NSRegularExpression(pattern: #"[(\[]\s*\w*\s*:\s*(`(?:[^`]|``)+`|\w+)"#) else { return nil }
        let ns = body as NSString
        guard let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }

    /// A label or type as Cypher writes it: bare when it can be.
    package static func name(_ text: String) -> String {
        text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            ? text : "`" + text.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// Relationship types in the tree are `[:TYPE]`; labels bare.
    package static func relationshipType(_ table: String) -> String? {
        table.hasPrefix("[:") && table.hasSuffix("]") ? String(table.dropFirst(2).dropLast()) : nil
    }

    package static func browse(_ table: CatalogTable, connection: DatabaseConnection, limit: Int) -> String {
        let use = table.schema == (connection.database.isEmpty ? "neo4j" : connection.database) ? "" : ":use \(table.schema)\n"
        if let type = relationshipType(table.name) {
            return use + "MATCH (a)-[r:\(name(type))]->(b) RETURN a, r, b LIMIT \(limit)"
        }
        return use + "MATCH (n:\(name(table.name))) RETURN n LIMIT \(limit)"
    }
}

/// The transactional API's answer as rows: a node as `{"labels": […],
/// "properties": {…}}`, a relationship as `{"type": …, "properties": {…}}`
/// — their labels and types from the `graph` part — and a path as the list
/// of both. Pure.
package enum Neo4jParse {
    package struct Answer {
        package var result: QueryResult
        /// `Neo.ClientError.Statement.SyntaxError`…
        package var errors: [(code: String, message: String)]
    }

    package static func answer(_ data: Data, limit: Int) throws -> Answer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DatabaseError.failed("Neo4j's answer isn't JSON: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        let errors = (object["errors"] as? [[String: Any]] ?? []).map { ($0["code"] as? String ?? "", $0["message"] as? String ?? "") }
        var result = QueryResult()
        if let query = object["data"] as? [String: Any] { return Answer(result: queryAPI(query, counters: object["counters"], limit: limit), errors: errors) }
        guard let first = (object["results"] as? [[String: Any]])?.last else { return Answer(result: result, errors: errors) }
        result.columns = first["columns"] as? [String] ?? []
        result.types = Array(repeating: "", count: result.columns.count)
        let data = first["data"] as? [[String: Any]] ?? []
        for entry in data.prefix(limit) {
            let row = entry["row"] as? [Any] ?? []
            let meta = entry["meta"] as? [Any] ?? []
            let graph = entry["graph"] as? [String: Any] ?? [:]
            var labels: [String: [String]] = [:]
            for node in graph["nodes"] as? [[String: Any]] ?? [] {
                if let id = node["id"].flatMap(HTTPDriverTransport.text) { labels[id] = node["labels"] as? [String] ?? [] }
            }
            var types: [String: String] = [:]
            for relationship in graph["relationships"] as? [[String: Any]] ?? [] {
                if let id = relationship["id"].flatMap(HTTPDriverTransport.text) { types[id] = relationship["type"] as? String ?? "" }
            }
            var cells: [String?] = []
            for (index, value) in row.enumerated() {
                let shaped = shape(value, meta: index < meta.count ? meta[index] : nil, labels: labels, types: types)
                cells.append(HTTPDriverTransport.text(shaped))
                if index < result.types.count, result.types[index].isEmpty, let kind = (index < meta.count ? meta[index] : nil) as? [String: Any],
                    let type = kind["type"] as? String
                {
                    result.types[index] = type
                }
            }
            result.rows.append(cells + Array(repeating: nil, count: max(0, result.columns.count - cells.count)))
        }
        result.truncated = data.count > limit
        if let stats = first["stats"] as? [String: Any], stats["contains_updates"] as? Bool == true {
            let changes = stats.compactMap { key, value -> String? in
                guard key != "contains_updates", key != "contains_system_updates", let n = value as? Int, n > 0 else { return nil }
                return "\(n) \(key.replacingOccurrences(of: "_", with: " "))"
            }.sorted()
            result.message = changes.joined(separator: ", ")
        }
        return Answer(result: result, errors: errors)
    }

    /// The Query API's plain JSON: `{"data": {"fields", "values"}, "counters"}`,
    /// a node `{"elementId", "labels", "properties"}`, a relationship
    /// `{"elementId", "type", "startNodeElementId", …, "properties"}`.
    package static func queryAPI(_ data: [String: Any], counters: Any?, limit: Int) -> QueryResult {
        var result = QueryResult()
        result.columns = data["fields"] as? [String] ?? []
        result.types = Array(repeating: "", count: result.columns.count)
        let values = data["values"] as? [[Any]] ?? []
        result.rows = values.prefix(limit).map { row in
            row.map { HTTPDriverTransport.text(plain($0)) } + Array(repeating: nil, count: max(0, result.columns.count - row.count))
        }
        result.truncated = values.count > limit
        if let counters = counters as? [String: Any], counters["containsUpdates"] as? Bool == true {
            let changes = counters.compactMap { key, value -> String? in
                guard !key.hasPrefix("contains"), let n = value as? Int, n > 0 else { return nil }
                // nodesCreated → nodes created
                let words = key.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression).lowercased()
                return "\(n) \(words)"
            }.sorted()
            result.message = changes.joined(separator: ", ")
        }
        return result
    }

    /// A Query API value shaped as the transactional one's are.
    package static func plain(_ value: Any) -> Any {
        if let object = value as? [String: Any], object["elementId"] != nil, let properties = object["properties"] {
            if let labels = object["labels"] { return ["labels": labels, "properties": properties] as [String: Any] }
            if let type = object["type"] { return ["type": type, "properties": properties] as [String: Any] }
        }
        if let list = value as? [Any] { return list.map(plain) }
        return value
    }

    /// Either API's rows, their raw values.
    package static func rawRows(_ data: Data) -> [[Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let query = object["data"] as? [String: Any] { return query["values"] as? [[Any]] ?? [] }
        let result = (object["results"] as? [[String: Any]])?.first
        return (result?["data"] as? [[String: Any]] ?? []).map { $0["row"] as? [Any] ?? [] }
    }

    /// A value with its meta: a node, a relationship, a path, or what it is.
    package static func shape(_ value: Any, meta: Any?, labels: [String: [String]], types: [String: String]) -> Any {
        if let meta = meta as? [String: Any], let kind = meta["type"] as? String {
            let id = meta["id"].flatMap(HTTPDriverTransport.text) ?? ""
            let properties = value as? [String: Any] ?? [:]
            switch kind {
            case "node": return ["labels": labels[id] ?? [], "properties": properties] as [String: Any]
            case "relationship": return ["type": types[id] ?? "", "properties": properties] as [String: Any]
            default: return value
            }
        }
        // A path: its parts, each with its own meta.
        if let metas = meta as? [Any], let parts = value as? [Any], metas.count == parts.count {
            return zip(parts, metas).map { shape($0, meta: $1, labels: labels, types: types) }
        }
        return value
    }

    /// An error in words: credentials, a missing database, else the server's.
    package static func explain(_ code: String, _ message: String) -> String {
        if code.hasPrefix("Neo.ClientError.Security.Unauthorized") || code.hasPrefix("Neo.ClientError.Security.AuthenticationRateLimit") {
            return "Neo4j refused the user or password (\(message))."
        }
        if code == "Neo.ClientError.Security.CredentialsExpired" {
            return "The password has expired — Neo4j asks for a new one before anything runs (change it in Neo4j Browser or cypher-shell)."
        }
        if code == "Neo.ClientError.Database.DatabaseNotFound" { return "No such database: \(message)" }
        if code.hasPrefix("Neo.ClientError.Statement.AccessMode") || code.hasPrefix("Neo.ClientError.Security.Forbidden") {
            return "This connection only reads: \(message)"
        }
        return message
    }
}
