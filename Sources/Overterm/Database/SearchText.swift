import Foundation

/// Elasticsearch and OpenSearch as the database client reads them — pure,
/// so it is tested without a server: a console's requests as Kibana's Dev
/// Tools writes them, which of them only read and which destroy, an answer
/// as the grid's rows, a mapping as columns, a pasted address or Cloud ID.

/// One request: `GET /orders/_search` and the JSON under it.
struct SearchRequest: Equatable, Sendable {
    var method: String
    /// Always from the root: `/orders/_search?q=x`.
    var path: String
    /// nil: none. `_bulk` and `_msearch`'s are a JSON object a line.
    var body: String?

    static let methods: Set<String> = ["GET", "POST", "PUT", "DELETE", "HEAD", "PATCH"]

    /// The path without its query: `/orders/_search`.
    var route: String { String(path.prefix { $0 != "?" }) }

    /// The path's parts: `["orders", "_search"]`.
    var parts: [String] { route.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) } }

    /// The API a path names: its first part that starts with `_`
    /// (`_search`, `_doc`, `_cat`); OpenSearch's plugins by the one after
    /// (`_plugins/_sql` → `_sql`). nil for an index itself (`/orders`).
    var endpoint: String? {
        let parts = parts
        guard let at = parts.firstIndex(where: { $0.hasPrefix("_") }) else { return nil }
        if ["_plugins", "_opendistro"].contains(parts[at]), at + 1 < parts.count { return parts[at + 1] }
        return parts[at]
    }

    /// The indices it names before its endpoint: `orders,returns` → two.
    var indices: [String] {
        guard let first = parts.first, !first.hasPrefix("_") else { return [] }
        return first.split(separator: ",").map(String.init)
    }

    /// Bodies a JSON object a line: what Kibana sends compacted.
    var isNDJSON: Bool { ["_bulk", "_msearch", "_mtermvectors"].contains(endpoint ?? "") || route.hasSuffix("/_msearch/template") }

    /// `METHOD path` on its first line, the body on the rest.
    static func parse(_ text: String) throws -> SearchRequest {
        let lines = SearchText.clean(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw DatabaseError.failed("No request.")
        }
        let words = first.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        let method = words.first?.uppercased() ?? ""
        guard methods.contains(method) else {
            throw DatabaseError.failed("A request starts with its method and path — GET /orders/_search, then its JSON body on the lines below.")
        }
        var path = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : "/"
        // Kibana takes it with or without the slash; a whole URL pasted, its path.
        if let url = URL(string: path), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            path = url.path + (url.query.map { "?" + $0 } ?? "")
        }
        if !path.hasPrefix("/") { path = "/" + path }
        let rest = lines.drop { $0 != first }.dropFirst()
        var body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var request = SearchRequest(method: method, path: path, body: nil)
        if !body.isEmpty {
            body = SearchText.tripleQuoted(body)
            if request.isNDJSON {
                body = try SearchText.objects(in: body).map { try SearchText.compact($0) }.joined(separator: "\n") + "\n"
            }
            request.body = body
        }
        return request
    }

    /// Only reads: GET and HEAD, and a POST to an API that only reads.
    var onlyReads: Bool {
        switch method {
        case "GET", "HEAD": return true
        case "POST":
            guard let endpoint else { return false }
            // `_search/scroll`, `_search/template`; `_sql/translate`; `_eql/search`.
            return Self.readingPosts.contains(endpoint)
        default: return false
        }
    }

    /// POSTs that only read. Not `_mapping` (a POST there changes it), not
    /// `_pit` or `_async_search` (each keeps something on the server).
    static let readingPosts: Set<String> = [
        "_search", "_count", "_msearch", "_cat", "_field_caps", "_validate", "_explain", "_mget", "_termvectors", "_mtermvectors",
        "_render", "_rank_eval", "_knn_search", "_terms_enum", "_sql", "_ppl", "_eql", "_query", "_analyze",
    ]

    /// What an agent may run without asking: what only reads, but not the
    /// security APIs (who has which key and role is not an agent's to list).
    var agentReads: Bool {
        guard onlyReads else { return false }
        // `_security/…`, and OpenSearch's `_plugins/_security/…`.
        return !parts.prefix(2).contains("_security")
    }

    /// Why it is asked about first, or nil.
    var danger: String? {
        switch endpoint {
        case "_delete_by_query": return "It deletes every document the query matches."
        case "_update_by_query": return "It changes every document the query matches."
        default: break
        }
        guard method == "DELETE" else { return nil }
        let parts = parts
        if endpoint == nil || parts == ["_all"], let first = parts.first {
            let all = first == "_all" || first.contains("*")
            return all ? "It deletes every index the name \(first) matches, and their documents." : "It deletes the index \(first) and every document in it."
        }
        if parts.first == "_data_stream", parts.count > 1 { return "It deletes the data stream \(parts[1]), its backing indices and their documents." }
        return nil
    }

    /// For the read-only refusal: `PUT /orders`.
    var verb: String { "\(method) \(route)" }
}

enum SearchText {
    /// A line that starts a request.
    static func isMethodLine(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return SearchRequest.methods.contains(trimmed.uppercased()) && trimmed == trimmed.uppercased()
        }
        let word = trimmed[..<space]
        return word == word.uppercased() && SearchRequest.methods.contains(String(word))
    }

    /// A line of comment: Kibana's `#` and `//`.
    static func isComment(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("#") || trimmed.hasPrefix("//")
    }

    /// Requests: each from its method line to the next one, or to a blank
    /// line where its body's braces are closed — a blank line inside a
    /// body, or inside a string, doesn't end it.
    static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        var start: Int?
        var end = 0
        var depth = 0
        var inString = false
        var inTriple = false
        func finish() {
            if let begun = start { found.append(NSRange(location: begun, length: end - begun)) }
            start = nil
            depth = 0
            inString = false
            inTriple = false
        }
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, range, _, _ in
            let line = Substring(line ?? "")
            let open = depth > 0 || inString || inTriple
            if !open, isMethodLine(line) {
                finish()
                start = range.location
                end = NSMaxRange(range)
                return
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !open { finish() }
                return
            }
            if !open, isComment(line) { return }
            guard start != nil else { return }
            end = NSMaxRange(range)
            scan(line, depth: &depth, inString: &inString, inTriple: &inTriple)
        }
        finish()
        return found
    }

    /// Braces and strings on a line, carried to the next.
    private static func scan(_ line: Substring, depth: inout Int, inString: inout Bool, inTriple: inout Bool) {
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if inTriple {
                if line[index...].hasPrefix("\"\"\"") {
                    inTriple = false
                    index = line.index(index, offsetBy: 3)
                    continue
                }
            } else if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if line[index...].hasPrefix("\"\"\"") {
                inTriple = true
                index = line.index(index, offsetBy: 3)
                continue
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                depth = max(0, depth - 1)
            }
            index = line.index(after: index)
        }
        // A JSON string never spans lines; one left open is a typo, not a body.
        inString = false
    }

    static func statement(at caret: Int, in text: String) -> NSRange? {
        statements(in: text).first { caret >= $0.location && caret <= NSMaxRange($0) }
    }

    /// The request without its comment lines.
    static func clean(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { !isComment($0) }.joined(separator: "\n")
    }

    /// Kibana's `"""…"""`: a string over lines, as a JSON string.
    static func tripleQuoted(_ body: String) -> String {
        guard body.contains("\"\"\"") else { return body }
        var out = ""
        var rest = Substring(body)
        while let open = rest.range(of: "\"\"\"") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "\"\"\"") else {
                out += rest[open.lowerBound...]
                return out
            }
            let inner = String(after[..<close.lowerBound])
            let data = (try? JSONSerialization.data(withJSONObject: [inner], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
            out += String(decoding: data, as: UTF8.self).dropFirst().dropLast()
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    /// The JSON values one after another in an NDJSON body, each whole
    /// however it was laid out over lines.
    static func objects(in body: String) throws -> [String] {
        var found: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        for c in body {
            if depth == 0, !inString, c.isWhitespace { continue }
            current.append(c)
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 {
                    found.append(current)
                    current = ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DatabaseError.failed("The body ends inside a JSON object: \(current.prefix(60))")
        }
        return found
    }

    /// A JSON value on one line.
    static func compact(_ json: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { throw DatabaseError.failed("Not JSON: \(json.prefix(80))") }
        return String(decoding: data, as: UTF8.self)
    }

    /// A tab's name: the index, else the API.
    static func subject(of statement: String) -> String? {
        guard let request = try? SearchRequest.parse(statement) else { return nil }
        if let index = request.indices.first { return index }
        let parts = request.parts
        return parts.isEmpty ? "/" : parts.prefix(2).joined(separator: "/")
    }
}

// MARK: Answers

/// What a server answered, as the grid's rows.
enum SearchResults {
    /// A value as one cell: text as it is, numbers as JSON says them, an
    /// object or an array as compact JSON; null is NULL.
    static func cell(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            guard let value, JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return "\(value ?? "")" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return cell(value) ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The keys of objects, in the order they are first met.
    private static func keys(of objects: [[String: Any]], order: [[String]] = []) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for (index, object) in objects.enumerated() {
            let listed = index < order.count ? order[index].filter { object[$0] != nil } : []
            let ordered = listed + object.keys.filter { !listed.contains($0) }.sorted()
            for key in ordered where seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    /// An answer's rows: a search's hits, SQL's and ES|QL's columns, a
    /// `_cat`'s rows, a count; anything else its JSON in one cell.
    static func result(_ data: Data, request: SearchRequest, status: Int, limit: Int) -> QueryResult {
        if request.method == "HEAD" {
            return QueryResult(message: status == 404 ? "404 — it doesn't exist." : "\(status) — it exists.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // `_cat` without format=json, a plain answer: its lines.
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .reversed().drop { $0.isEmpty }.reversed().map { $0 }
            if lines.isEmpty { return QueryResult(message: "\(status) — no body.") }
            return QueryResult(
                columns: ["response"], types: ["text"], rows: lines.prefix(limit).map { [$0] }, truncated: lines.count > limit)
        }
        if let array = json as? [[String: Any]] { return rows(array, limit: limit, order: orderedKeys(data)) }
        guard let object = json as? [String: Any] else { return QueryResult(columns: ["response"], types: ["json"], rows: [[cell(json)]]) }
        if let hits = object["hits"] as? [String: Any], let list = hits["hits"] as? [[String: Any]] {
            return search(object, hits: hits, list: list, limit: limit)
        }
        if let result = sql(object, limit: limit) { return result }
        if let count = object["count"] as? NSNumber, object.count <= 2 {
            return QueryResult(columns: ["count"], types: ["long"], rows: [[number(count)]])
        }
        return whole(object)
    }

    /// The JSON whole in one cell, and what it said in the message.
    static func whole(_ object: [String: Any]) -> QueryResult {
        var result = QueryResult(columns: ["response"], types: ["json"], rows: [[pretty(object)]])
        if object["acknowledged"] as? Bool == true {
            result.message = "Acknowledged."
        } else if let said = object["result"] as? String {
            result.message = said.prefix(1).uppercased() + said.dropFirst() + (object["_id"].flatMap(cell).map { " — _id \($0)" } ?? "") + "."
            result.affected = said == "noop" || said == "not_found" ? 0 : 1
        } else if let errors = object["errors"] as? Bool, let items = object["items"] as? [Any] {
            result.message = "\(items.count) item\(items.count == 1 ? "" : "s")\(errors ? ", some failed — see the response" : "")."
            result.affected = items.count
        } else if let changed = (object["deleted"] ?? object["updated"]) as? NSNumber, object["total"] != nil {
            result.message = object["deleted"] != nil ? "\(changed) deleted." : "\(changed) updated."
            result.affected = changed.intValue
        }
        return result
    }

    private static func number(_ value: NSNumber) -> String { value.stringValue }

    /// A search: its hits as rows — `_index`, `_id`, `_score`, then
    /// `_source`'s top-level fields — or, with none and aggregations, those.
    private static func search(_ object: [String: Any], hits: [String: Any], list: [[String: Any]], limit: Int) -> QueryResult {
        let total: (Int, Bool)? = {
            if let value = hits["total"] as? [String: Any], let n = value["value"] as? NSNumber {
                return (n.intValue, value["relation"] as? String == "gte")
            }
            if let n = hits["total"] as? NSNumber { return (n.intValue, false) }
            return nil
        }()
        let took = (object["took"] as? NSNumber).map { " in \($0) ms" } ?? ""
        let said = total.map { "\($0.1 ? "≥ " : "")\($0.0) hit\($0.0 == 1 && !$0.1 ? "" : "s")" } ?? "\(list.count) hits"
        if list.isEmpty, let aggregations = object["aggregations"] as? [String: Any] {
            var result = self.aggregations(aggregations, limit: limit)
            result.message = "\(said)\(took); the aggregations."
            return result
        }
        let shown = Array(list.prefix(limit))
        let sources = shown.map { ($0["_source"] as? [String: Any]) ?? flatFields($0["fields"]) }
        let fields = keys(of: sources)
        let hasScore = shown.contains { !($0["_score"] is NSNull) && $0["_score"] != nil }
        // What an edit finds a hit again by: its version (`seq_no_primary_term`), its routing.
        let meta = ["_seq_no", "_primary_term", "_routing"].filter { name in shown.contains { $0[name] != nil && !($0[name] is NSNull) } }
        var columns = ["_index", "_id"] + (hasScore ? ["_score"] : []) + meta
        var types = ["string", "string"] + (hasScore ? ["number"] : []) + meta.map { $0 == "_routing" ? "string" : "number" }
        columns += fields
        types += fields.map { field in jsonType(sources.compactMap { $0[field] }) }
        var rows: [[String?]] = []
        for (hit, source) in zip(shown, sources) {
            var row: [String?] = [cell(hit["_index"]), cell(hit["_id"])]
            if hasScore { row.append(cell(hit["_score"])) }
            row += meta.map { cell(hit[$0]) }
            row += fields.map { cell(source[$0]) }
            rows.append(row)
        }
        var result = QueryResult(columns: columns, types: types, rows: rows)
        result.truncated = list.count > limit || (total.map { $0.0 > shown.count || $0.1 } ?? false)
        var message = "\(said)\(took)"
        if shown.count < (total?.0 ?? 0) { message += ", \(shown.count) shown — \"size\" in the body for more" }
        if object["aggregations"] != nil { message += "; aggregations too — \"size\": 0 shows them" }
        result.message = message + "."
        return result
    }

    /// The JSON type of a field's values — string, number, boolean, object,
    /// array —, "mixed" for several, "" when every one is null: how an
    /// edited cell's text is read back (`SearchEdits`).
    static func jsonType(_ values: [Any]) -> String {
        var found: Set<String> = []
        for value in values {
            switch value {
            case is NSNull: continue
            case is String: found.insert("string")
            case let number as NSNumber: found.insert(CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number")
            case is [Any]: found.insert("array")
            case is [String: Any]: found.insert("object")
            default: found.insert("mixed")
            }
        }
        return found.count == 1 ? found.first! : found.isEmpty ? "" : "mixed"
    }

    /// `fields`' values are arrays of one: said as the one.
    private static func flatFields(_ value: Any?) -> [String: Any] {
        guard let fields = value as? [String: Any] else { return [:] }
        return fields.mapValues { ($0 as? [Any]).flatMap { $0.count == 1 ? $0[0] : nil } ?? $0 }
    }

    /// One aggregation of buckets: a row a bucket — its key, its count,
    /// each sub-aggregation's value. Else the aggregations' JSON.
    static func aggregations(_ aggregations: [String: Any], limit: Int) -> QueryResult {
        if aggregations.count == 1, let (name, value) = aggregations.first, let aggregation = value as? [String: Any] {
            if let buckets = aggregation["buckets"] as? [[String: Any]] {
                let subs = keys(of: buckets.map { $0.filter { $0.key != "key" && $0.key != "doc_count" && $0.key != "key_as_string" } })
                let simple = buckets.allSatisfy { bucket in subs.allSatisfy { sub in bucket[sub] == nil || bucket[sub] is NSNumber || (bucket[sub] as? [String: Any])?["value"] != nil } }
                if simple {
                    let columns = [name, "doc_count"] + subs
                    let rows: [[String?]] = buckets.prefix(limit).map { bucket in
                        [cell(bucket["key_as_string"] ?? bucket["key"]), cell(bucket["doc_count"])]
                            + subs.map { sub in cell((bucket[sub] as? [String: Any]).map { $0["value_as_string"] ?? $0["value"] } ?? bucket[sub]) }
                    }
                    return QueryResult(columns: columns, types: columns.map { _ in "" }, rows: rows, truncated: buckets.count > limit)
                }
            }
            if aggregation.count <= 2, let v = aggregation["value"] {
                return QueryResult(columns: [name], types: [""], rows: [[cell(aggregation["value_as_string"] ?? v)]])
            }
        }
        return QueryResult(columns: ["aggregations"], types: ["json"], rows: [[pretty(aggregations)]])
    }

    /// Elasticsearch SQL (`columns` + `rows`), ES|QL (`columns` + `values`),
    /// OpenSearch SQL and PPL (`schema` + `datarows`).
    private static func sql(_ object: [String: Any], limit: Int) -> QueryResult? {
        let header = (object["columns"] ?? object["schema"]) as? [[String: Any]]
        let body = (object["rows"] ?? object["values"] ?? object["datarows"]) as? [[Any]]
        guard let header, let body else { return nil }
        let columns = header.map { ($0["name"] as? String) ?? "" }
        let rows = body.prefix(limit).map { row in row.map(cell) }
        var result = QueryResult(columns: columns, types: header.map { ($0["type"] as? String) ?? "" }, rows: rows)
        result.truncated = body.count > limit || object["cursor"] != nil
        if object["cursor"] != nil { result.message = "There are more — the answer's cursor pages them." }
        return result
    }

    /// An array of objects (`_cat/*?format=json`): a row each, their keys
    /// the columns in the server's order.
    static func rows(_ array: [[String: Any]], limit: Int, order: [[String]] = []) -> QueryResult {
        let columns = keys(of: array, order: order)
        let rows = array.prefix(limit).map { object in columns.map { cell(object[$0]) } }
        return QueryResult(columns: columns, types: columns.map { _ in "" }, rows: rows, truncated: array.count > limit)
    }

    /// Each object's keys in the order the text has them (Foundation's
    /// dictionaries forget it): `_cat`'s columns as the server lists them.
    static func orderedKeys(_ data: Data) -> [[String]] {
        var out: [[String]] = []
        var current: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var token: [UInt8] = []
        var expectKey = false
        for byte in data {
            let c = Character(UnicodeScalar(byte))
            if inString {
                if escaped {
                    escaped = false
                    token.append(byte)
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                    if expectKey, depth == 2 { current.append(String(decoding: token, as: UTF8.self)) }
                } else {
                    token.append(byte)
                }
                continue
            }
            switch c {
            case "\"":
                inString = true
                token = []
            case "{":
                depth += 1
                if depth == 2 {
                    current = []
                    expectKey = true
                }
            case "[": depth += 1
            case "}", "]":
                if depth == 2, c == "}" { out.append(current) }
                depth -= 1
            case ",": if depth == 2 { expectKey = true }
            case ":": if depth == 2 { expectKey = false }
            default: break
            }
            if depth != 2 { expectKey = false }
        }
        return out
    }

    /// The server's error in its own words: `type: reason`, and what caused it.
    static func error(_ data: Data, status: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(1000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "The server answered \(status)." : text
        }
        if let error = object["error"] as? [String: Any] {
            var said = [error["type"] as? String, error["reason"] as? String].compactMap { $0 }.joined(separator: ": ")
            var cause = error["caused_by"] as? [String: Any]
            if cause == nil, let roots = error["root_cause"] as? [[String: Any]], let root = roots.first,
                root["reason"] as? String != error["reason"] as? String
            {
                cause = root
            }
            if let cause, let reason = cause["reason"] as? String { said += " — \(reason)" }
            if let failed = (error["failed_shards"] as? [[String: Any]])?.first?["reason"] as? [String: Any], let reason = failed["reason"] as? String,
                !said.contains(reason)
            {
                said += " — \(reason)"
            }
            return said.isEmpty ? "The server answered \(status)." : said
        }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String { return message }
        if object["found"] as? Bool == false { return "Not found (404)." }
        return "The server answered \(status): \(cell(object) ?? "")"
    }
}

// MARK: The catalog

enum SearchCatalog {
    /// The tree's folders.
    static let indices = "indices"
    static let dataStreams = "data streams"
    static let aliases = "aliases"

    /// A mapping's fields, dotted (`address.city`), each its type; an
    /// object's fields under its name, a multi-field (`name.keyword`) too.
    static func fields(_ properties: [String: Any], prefix: String = "") -> [(String, String)] {
        var out: [(String, String)] = []
        for name in properties.keys.sorted() {
            guard let field = properties[name] as? [String: Any] else { continue }
            let full = prefix + name
            if let nested = field["properties"] as? [String: Any] {
                let type = field["type"] as? String
                if let type { out.append((full, type)) }
                out += fields(nested, prefix: full + ".")
            } else {
                out.append((full, field["type"] as? String ?? "object"))
            }
            if let multi = field["fields"] as? [String: Any] {
                out += fields(multi, prefix: full + ".")
            }
        }
        return out
    }

    /// `GET /_mapping`'s answer: each index's fields.
    static func mappings(_ data: Data) -> [String: [(String, String)]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: [(String, String)]] = [:]
        for (index, value) in object {
            guard let mappings = (value as? [String: Any])?["mappings"] as? [String: Any] else { continue }
            // Before 7, a type's level between: `{"_doc": {"properties": …}}`.
            let properties =
                mappings["properties"] as? [String: Any]
                ?? mappings.values.compactMap { ($0 as? [String: Any])?["properties"] as? [String: Any] }.first ?? [:]
            out[index] = fields(properties)
        }
        return out
    }

    /// A count as the tree says it: 1.2M docs.
    static func docs(_ text: String?) -> String? {
        guard let text, let n = Int(text) else { return nil }
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB docs", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM docs", Double(n) / 1e6)
        case 10_000...: return String(format: "%.0fk docs", Double(n) / 1e3)
        default: return "\(n) doc\(n == 1 ? "" : "s")"
        }
    }

    /// Hidden and system indices (`.kibana`, `.ds-…`, `.security`) aren't the user's.
    static func isHidden(_ name: String) -> Bool { name.hasPrefix(".") }
}

// MARK: Addresses

/// A pasted address: `https://user:pass@host:9243/path`, or Elastic
/// Cloud's Cloud ID (`name:base64(domain$es-id$kibana-id)`).
struct SearchAddress: Equatable {
    var host: String
    var port: Int
    var tls: Bool
    var path = ""
    var user = ""
    var password: String?

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), let cloud = Self.cloudID(text) {
            self = cloud
            return
        }
        guard let components = URLComponents(string: text.contains("://") ? text : "http://" + text), let host = components.host, !host.isEmpty
        else { return nil }
        tls = components.scheme?.lowercased() == "https"
        self.host = host
        port = components.port ?? (tls ? 443 : 9200)
        path = components.path == "/" ? "" : components.path
        user = components.user.map { $0.removingPercentEncoding ?? $0 } ?? ""
        password = components.password.map { $0.removingPercentEncoding ?? $0 }
    }

    private init(host: String, port: Int, tls: Bool) {
        self.host = host
        self.port = port
        self.tls = tls
    }

    /// `deployment:dXMtZWFzdC0xLmF3cy5mb3VuZC5pbyRhYmMkZGVm` → `abc.us-east-1.aws.found.io:443`.
    static func cloudID(_ text: String) -> SearchAddress? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        var encoded = String(text[text.index(after: colon)...])
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else { return nil }
        let parts = decoded.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var domain = parts[0]
        var port = 443
        if let at = domain.lastIndex(of: ":"), let given = Int(domain[domain.index(after: at)...]) {
            port = given
            domain = String(domain[..<at])
        }
        return SearchAddress(host: "\(parts[1]).\(domain)", port: port, tls: true)
    }
}

/// How a request is signed in: Basic with a user; without one, the secret
/// is an API key (`ApiKey`, Elastic's encoded form or its `id:key`) or,
/// written `Bearer …`, a token.
enum SearchAuth {
    static func header(user: String, secret: String?) -> String? {
        let secret = secret ?? ""
        if !user.isEmpty { return "Basic " + Data("\(user):\(secret)".utf8).base64EncodedString() }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("bearer ") { return "Bearer " + trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        if trimmed.lowercased().hasPrefix("apikey ") { return "ApiKey " + trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        // `id:api_key` as Kibana shows it before encoding.
        if trimmed.contains(":") { return "ApiKey " + Data(trimmed.utf8).base64EncodedString() }
        return "ApiKey " + trimmed
    }
}

/// AWS's managed OpenSearch: its region from the endpoint's name
/// (`search-x-abc.eu-west-1.es.amazonaws.com`), its service — `es`, or
/// `aoss` for Serverless.
enum SearchAWS {
    static func service(host: String) -> String { host.contains(".aoss.") ? "aoss" : "es" }

    static func region(host: String) -> String? {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard let at = parts.firstIndex(where: { $0 == "es" || $0 == "aoss" }), at >= 1, parts.dropFirst(at).contains("amazonaws") else { return nil }
        return parts[at - 1]
    }
}
