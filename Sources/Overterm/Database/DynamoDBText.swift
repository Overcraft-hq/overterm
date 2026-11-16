import Foundation

/// DynamoDB's console: PartiQL, a statement a `;` as SQL splits them
/// (`SELECT * FROM "orders" WHERE pk = 'a'`). Only SELECT reads; a DELETE or
/// UPDATE without WHERE is said before it runs. Pure.
enum DynamoText: KindConsoleText {
    static func statements(in text: String) -> [NSRange] { SQLText.statements(in: text) }
    static func verb(of statement: String) -> String { SQLText.verb(of: statement) }
    static func onlyReads(_ statement: String) -> Bool { verb(of: statement) == "SELECT" }
    static func agentReads(_ statement: String) -> Bool { onlyReads(statement) }

    static func danger(of statement: String) -> String? {
        let verb = verb(of: statement)
        guard verb == "DELETE" || verb == "UPDATE" else { return nil }
        guard SQLText.stripped(statement).uppercased().range(of: #"\bWHERE\b"#, options: .regularExpression) == nil else { return nil }
        return "It has no WHERE: every item of the table is \(verb == "DELETE" ? "deleted" : "changed")."
    }

    /// Its table: `FROM "orders"."byUser"` → orders (the index after the dot).
    static func subject(of statement: String) -> String? {
        let pattern = #"(?i)\b(?:FROM|UPDATE|INTO)\s+(?:"((?:[^"]|"")+)"|([A-Za-z0-9_.\-]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = statement as NSString
        guard let match = regex.firstMatch(in: statement, range: NSRange(location: 0, length: ns.length)) else { return nil }
        if match.range(at: 1).location != NSNotFound {
            return ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "\"\"", with: "\"")
        }
        let bare = ns.substring(with: match.range(at: 2))
        return bare.split(separator: ".").first.map(String.init) ?? bare
    }

    /// `"orders"` — PartiQL quotes a name with double quotes.
    static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// The panel's Select Top: PartiQL has no LIMIT — the driver stops at the row limit.
    static func browse(_ table: String) -> String { "SELECT * FROM \(quote(table))" }
}

/// DynamoDB's typed values (`{"S": "a"}`, `{"N": "1"}`, `{"M": {…}}`) as the
/// grid shows them, and items as rows. Pure.
enum DynamoItems {
    /// A value as text: S and N as written, B as its base64, BOOL as a word,
    /// NULL as NULL; sets, lists and maps as JSON.
    static func text(_ value: [String: Any]) -> String? {
        guard let (type, inner) = value.first else { return nil }
        switch type {
        case "S", "N", "B": return inner as? String
        case "BOOL": return (inner as? Bool).map { $0 ? "true" : "false" }
        case "NULL": return nil
        default: return json(value)
        }
    }

    /// A value as plain JSON: numbers as numbers, binary as its base64,
    /// sets as arrays, maps' keys sorted.
    static func json(_ value: [String: Any]) -> String {
        guard let (type, inner) = value.first else { return "null" }
        switch type {
        case "S", "B": return HTTPDriverTransport.quoted(inner as? String ?? "")
        case "N": return number(inner as? String ?? "")
        case "BOOL": return (inner as? Bool) == true ? "true" : "false"
        case "NULL": return "null"
        case "SS", "BS": return "[" + ((inner as? [String]) ?? []).map(HTTPDriverTransport.quoted).joined(separator: ",") + "]"
        case "NS": return "[" + ((inner as? [String]) ?? []).map(number).joined(separator: ",") + "]"
        case "L": return "[" + ((inner as? [[String: Any]]) ?? []).map(json).joined(separator: ",") + "]"
        case "M":
            let map = (inner as? [String: [String: Any]]) ?? [:]
            return "{" + map.keys.sorted().map { HTTPDriverTransport.quoted($0) + ":" + json(map[$0]!) }.joined(separator: ",") + "}"
        default: return HTTPDriverTransport.text(inner).map(HTTPDriverTransport.quoted) ?? "null"
        }
    }

    /// A DynamoDB number as JSON writes one; one JSON can't read quoted.
    private static func number(_ text: String) -> String {
        text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
            ? text : HTTPDriverTransport.quoted(text)
    }

    /// Items as rows: the table's keys first (`keys`, partition then sort),
    /// then every other attribute any item has, by name; a column's type the
    /// letter its first value has. An attribute an item lacks is NULL.
    static func rows(_ items: [[String: Any]], keys: [String]) -> (columns: [String], types: [String], rows: [[String?]]) {
        var names = Set<String>()
        for item in items { names.formUnion(item.keys) }
        let columns = keys.filter(names.contains) + names.subtracting(keys).sorted()
        var types = Array(repeating: "", count: columns.count)
        var rows: [[String?]] = []
        for item in items {
            var row: [String?] = []
            for (index, name) in columns.enumerated() {
                guard let value = item[name] as? [String: Any] else {
                    row.append(nil)
                    continue
                }
                if let type = value.keys.first, type != "NULL" {
                    // Several types: an edit reads the value from its JSON.
                    if types[index].isEmpty { types[index] = type } else if types[index] != type { types[index] = "mixed" }
                }
                row.append(text(value))
            }
            rows.append(row)
        }
        return (columns, types, rows)
    }

    /// AWS's error type without its namespace:
    /// `com.amazonaws.dynamodb.v20120810#ResourceNotFoundException` → ResourceNotFoundException.
    static func errorType(_ data: Data) -> (type: String, message: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["__type"] as? String else { return nil }
        let type = raw.split(separator: "#").last.map(String.init) ?? raw
        return (type, (object["message"] as? String) ?? (object["Message"] as? String) ?? type)
    }

    /// An error in words — the credentials' kinds said as what to do.
    static func explain(_ type: String, _ message: String) -> String {
        switch type {
        case "UnrecognizedClientException": "AWS doesn't know this access key (\(message)) — check it, or the profile."
        case "InvalidSignatureException": "The secret key doesn't match the access key — Edit Connection to enter it again."
        case "ExpiredTokenException", "ExpiredToken": "The session's credentials have expired — sign in again (aws sso login, or refresh the profile)."
        case "MissingAuthenticationTokenException": "No credentials were sent — an access key, or an AWS profile."
        default: message
        }
    }

    /// A table's description as the tree's columns: its keys (partition,
    /// sort) with their types, then each index with its keys.
    static func columns(of table: String, description: [String: Any]) -> [CatalogColumn] {
        let definitions = Dictionary(
            ((description["AttributeDefinitions"] as? [[String: Any]]) ?? []).compactMap { d -> (String, String)? in
                guard let name = d["AttributeName"] as? String, let type = d["AttributeType"] as? String else { return nil }
                return (name, type)
            }, uniquingKeysWith: { a, _ in a })
        func keys(_ schema: Any?) -> [(String, String)] {
            ((schema as? [[String: Any]]) ?? []).compactMap { k in
                guard let name = k["AttributeName"] as? String else { return nil }
                return (name, k["KeyType"] as? String ?? "")
            }.sorted { $0.1 == "HASH" && $1.1 != "HASH" }
        }
        var columns = keys(description["KeySchema"]).map { name, role in
            CatalogColumn(
                table: table, name: name, type: "\(definitions[name] ?? "?") · \(role == "HASH" ? "partition key" : "sort key")", nullable: false)
        }
        for (field, label) in [("GlobalSecondaryIndexes", "GSI"), ("LocalSecondaryIndexes", "LSI")] {
            for index in (description[field] as? [[String: Any]]) ?? [] {
                guard let name = index["IndexName"] as? String else { continue }
                let on = keys(index["KeySchema"]).map(\.0).joined(separator: ", ")
                columns.append(CatalogColumn(table: table, name: name, type: "\(label) · \(on)"))
            }
        }
        return columns
    }

    /// Partition key, then sort key.
    static func keyNames(_ description: [String: Any]) -> [String] {
        ((description["KeySchema"] as? [[String: Any]]) ?? [])
            .sorted { ($0["KeyType"] as? String) == "HASH" && ($1["KeyType"] as? String) != "HASH" }
            .compactMap { $0["AttributeName"] as? String }
    }

    /// AWS's own endpoint, not DynamoDB Local or another.
    static func isAWS(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn") || host.hasSuffix(".api.aws")
    }

    /// A region's endpoint.
    static func endpoint(region: String) -> String {
        "dynamodb.\(region.isEmpty ? "us-east-1" : region).amazonaws.com" + (region.hasPrefix("cn-") ? ".cn" : "")
    }
}
