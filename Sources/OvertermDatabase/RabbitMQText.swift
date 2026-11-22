import Foundation

/// RabbitMQ's console: a small language of Overterm's over the management
/// HTTP API, a statement a line (a payload may go on over the lines below
/// it); a blank line or a `#` comment ends one. Names with spaces go in
/// double quotes. Pure.
///
///     USE <vhost>                              the vhost the rest runs in
///     PEEK <queue> [n]                         n messages (10), put back
///     PUBLISH <exchange> <routing key> <payload>
///     PURGE <queue>                            every ready message deleted
///     GET /api/…                               any management API path
///     PUT|POST|DELETE /api/… [JSON body]       … and its writes
///
/// PEEK reads with `ackmode=reject_requeue_true`: the messages stay in
/// the queue, marked redelivered (on a quorum queue each peek counts as a
/// delivery). `amq.default` (or `""`) is the default exchange.
package enum RabbitText: KindConsoleText {
    package enum Command: Equatable {
        case use(String)
        case peek(queue: String, count: Int?)
        case publish(exchange: String, routingKey: String, payload: String)
        case purge(String)
        case api(method: String, path: String, body: String?)
    }

    package static let terminator = ""
    package static let completesSQL = false

    package static let commands: Set<String> = ["USE", "PEEK", "PUBLISH", "PURGE"]
    package static let methods: Set<String> = ["GET", "PUT", "POST", "DELETE"]

    /// What a new console starts with: the language, as comments.
    package static let help = """
        # RabbitMQ — a command a line; # starts a comment. Names with spaces in "double quotes".
        #   USE <vhost>                                the vhost the rest runs in (the connection's, else /)
        #   PEEK <queue> [n]                           n messages (10), put back: they stay, marked redelivered
        #   PUBLISH <exchange> <routing key> <payload> the payload is the rest, as written (amq.default: the default exchange)
        #   PURGE <queue>                              deletes every ready message
        #   GET /api/queues/%2F?columns=name,messages  any management API path (vhost / is %2F)
        #   PUT|POST|DELETE /api/… then a JSON body on the lines below

        """

    // MARK: Statements

    package static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var current: NSRange?
        func end() {
            if let range = current, range.length > 0 { ranges.append(range) }
            current = nil
        }
        var at = 0
        while at < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(lineRange)
            let content = trimmed(lineRange, in: ns)
            guard content.length > 0 else {
                end()
                continue
            }
            let line = ns.substring(with: content)
            if line.hasPrefix("#") {
                end()
                continue
            }
            let word = line.prefix { !$0.isWhitespace }.uppercased()
            if commands.contains(word) || methods.contains(word) {
                end()
                current = content
            } else if let started = current {
                current = NSRange(location: started.location, length: NSMaxRange(content) - started.location)
            } else {
                current = content
            }
        }
        end()
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

    // MARK: Parsing

    package struct Problem: Error, Equatable {
        package let message: String
    }

    package static func parse(_ statement: String) throws -> Command {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(text)
        guard let first = word(&rest) else { throw Problem(message: "No command.") }
        let verb = first.uppercased()
        switch verb {
        case "USE":
            guard let vhost = try token(&rest), rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Problem(message: "USE takes a vhost: USE /")
            }
            return .use(vhost)
        case "PEEK":
            guard let queue = try token(&rest) else { throw Problem(message: "PEEK takes a queue: PEEK orders 10") }
            var count: Int?
            if let n = word(&rest) {
                guard let number = Int(n), number > 0 else { throw Problem(message: "PEEK's count is a number above 0, not \(n).") }
                count = number
            }
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem(message: "PEEK takes a queue and a count, nothing more.") }
            return .peek(queue: queue, count: count)
        case "PUBLISH":
            guard let exchange = try token(&rest), let key = try token(&rest) else {
                throw Problem(message: "PUBLISH takes an exchange, a routing key and the payload: PUBLISH amq.default orders {\"id\": 1}")
            }
            // One space after the key, then the payload exactly as written.
            if rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
            return .publish(exchange: exchange, routingKey: key, payload: String(rest))
        case "PURGE":
            guard let queue = try token(&rest), rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Problem(message: "PURGE takes a queue: PURGE orders")
            }
            return .purge(queue)
        case _ where methods.contains(verb):
            let line = rest.prefix { $0 != "\n" }
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/api/") || path == "/api" else {
                throw Problem(message: "\(verb) takes a management API path: \(verb) /api/queues")
            }
            guard !path.contains(" ") else { throw Problem(message: "A path has no spaces — percent-encode them (%20).") }
            let body = rest.dropFirst(line.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return .api(method: verb, path: path, body: body.isEmpty ? nil : body)
        default:
            throw Problem(message: "RabbitMQ's console takes USE, PEEK, PUBLISH, PURGE, or GET/PUT/POST/DELETE /api/… — not \(first).")
        }
    }

    /// The next whitespace-separated word, unquoted.
    private static func word(_ rest: inout Substring) -> String? {
        rest = rest.drop { $0.isWhitespace }
        let word = rest.prefix { !$0.isWhitespace }
        guard !word.isEmpty else { return nil }
        rest = rest.dropFirst(word.count)
        return String(word)
    }

    /// The next name: a word, or a `"double-quoted"` one (`\"` and `\\`
    /// inside) — `""` the empty name.
    private static func token(_ rest: inout Substring) throws -> String? {
        rest = rest.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first, first != "\n" else { return nil }
        guard first == "\"" else {
            let word = rest.prefix { !$0.isWhitespace }
            rest = rest.dropFirst(word.count)
            return String(word)
        }
        var out = ""
        var index = rest.index(after: rest.startIndex)
        var escaped = false
        while index < rest.endIndex {
            let c = rest[index]
            if escaped {
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                rest = rest[rest.index(after: index)...]
                return out
            } else {
                out.append(c)
            }
            index = rest.index(after: index)
        }
        throw Problem(message: "A quote isn't closed.")
    }

    // MARK: What a statement does

    package static func verb(of statement: String) -> String {
        statement.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isWhitespace }.uppercased()
    }

    package static func onlyReads(_ statement: String) -> Bool {
        switch try? parse(statement) {
        case .use, .peek: true
        case .api(let method, _, _): method == "GET"
        default: false
        }
    }

    /// Paths an agent is asked about even though they only read: users'
    /// password hashes, the definitions export (users too), and the
    /// parameters a shovel or federation keeps its upstream's URI — and
    /// password — in.
    package static let privatePaths = ["/api/users", "/api/definitions", "/api/parameters", "/api/global-parameters"]

    /// PEEK isn't among them: its messages go back marked redelivered, and on
    /// a quorum queue each counts toward the delivery limit — an agent asks.
    package static func agentReads(_ statement: String) -> Bool {
        guard onlyReads(statement) else { return false }
        if case .peek = try? parse(statement) { return false }
        if case .api(_, let path, _) = try? parse(statement) {
            let bare = path.split(separator: "?").first.map(String.init) ?? path
            return !privatePaths.contains { bare == $0 || bare.hasPrefix($0 + "/") }
        }
        return true
    }

    package static func danger(of statement: String) -> String? {
        switch try? parse(statement) {
        case .purge(let queue):
            "PURGE deletes every ready message in \(queue) — they can't be got back."
        case .api("DELETE", let path, _):
            "DELETE \(path) removes it — a queue's messages with it."
        default:
            nil
        }
    }

    package static func subject(of statement: String) -> String? {
        switch try? parse(statement) {
        case .use(let vhost): vhost
        case .peek(let queue, _), .purge(let queue): queue
        case .publish(let exchange, _, _): exchangeName(exchange)
        case .api(_, let path, _): path
        default: nil
        }
    }

    /// `""` is the default exchange, which the API calls `amq.default`.
    package static func exchangeName(_ name: String) -> String { name.isEmpty ? "amq.default" : name }

    /// A name as the console takes it: quoted only when it has to be.
    package static func quoted(_ name: String) -> String {
        if !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }), !name.hasPrefix("#") { return name }
        return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A path segment as the API takes it: everything but unreserved
    /// characters escaped — the vhost `/` is `%2F`.
    package static func segment(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
            ?? name
    }

    // MARK: The tree

    /// An exchange's name in the tree, apart from the queues': a queue and
    /// an exchange are often named alike.
    package static let exchangePrefix = "exchange:"

    /// What the panel's "Select Top" runs: a queue's first messages, an
    /// exchange's bindings.
    package static func browse(_ table: CatalogTable, limit: Int) -> String {
        if table.name.hasPrefix(exchangePrefix) {
            let name = String(table.name.dropFirst(exchangePrefix.count))
            return "GET /api/exchanges/\(segment(table.schema))/\(segment(name))/bindings/source"
        }
        return "PEEK \(quoted(table.name)) \(min(limit, 100))"
    }

    /// A queue's line in the tree: its type, its messages, its consumers.
    package static func queueDetail(_ queue: [String: Any]) -> String {
        func count(_ key: String) -> Int { (queue[key] as? NSNumber)?.intValue ?? 0 }
        var parts: [String] = []
        if let type = queue["type"] as? String, type != "classic" { parts.append(type) }
        parts.append("\(count("messages_ready")) ready")
        if count("messages_unacknowledged") > 0 { parts.append("\(count("messages_unacknowledged")) unacked") }
        parts.append("\(count("consumers")) consumer\(count("consumers") == 1 ? "" : "s")")
        if let state = queue["state"] as? String, !["running", "idle"].contains(state) { parts.append(state) }
        return parts.joined(separator: " · ")
    }

    /// The tree's leaves: a queue's bindings from exchanges (the default
    /// exchange's, implied for every queue, left out), an exchange's to
    /// queues and exchanges.
    package static func bindingColumns(_ bindings: [[String: Any]]) -> [CatalogColumn] {
        var columns: [CatalogColumn] = []
        for binding in bindings {
            guard let source = binding["source"] as? String, !source.isEmpty, let destination = binding["destination"] as? String else { continue }
            let key = binding["routing_key"] as? String ?? ""
            let shownKey = key.isEmpty ? "(no key)" : key
            let toExchange = binding["destination_type"] as? String == "exchange"
            columns.append(
                CatalogColumn(table: toExchange ? exchangePrefix + destination : destination, name: "← \(source)", type: shownKey))
            columns.append(CatalogColumn(table: exchangePrefix + source, name: "→ \(toExchange ? exchangePrefix : "")\(destination)", type: shownKey))
        }
        return columns
    }

    // MARK: Answers

    /// What PEEK read, a message a row: its payload (UTF-8 as text, else
    /// `base64:`), its routing, its properties and headers as JSON.
    package static func messages(_ data: Data, limit: Int) throws -> QueryResult {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Problem(message: "RabbitMQ's answer wasn't a list of messages.")
        }
        var result = QueryResult(columns: ["#", "payload", "routing_key", "exchange", "redelivered", "properties", "headers", "bytes"])
        result.types = ["", "", "", "", "", "json", "json", ""]
        for (index, message) in list.prefix(limit).enumerated() {
            var payload = message["payload"] as? String ?? ""
            if message["payload_encoding"] as? String == "base64" { payload = "base64:" + payload }
            var properties = message["properties"] as? [String: Any] ?? [:]
            let headers = properties.removeValue(forKey: "headers")
            result.rows.append([
                String(index + 1), payload, message["routing_key"] as? String ?? "", RabbitText.exchangeName(message["exchange"] as? String ?? ""),
                HTTPDriverTransport.text(message["redelivered"]), properties.isEmpty ? nil : HTTPDriverTransport.text(properties),
                (headers as? [String: Any]).flatMap { $0.isEmpty ? nil : HTTPDriverTransport.text($0) },
                HTTPDriverTransport.text(message["payload_bytes"]),
            ])
        }
        result.truncated = list.count > limit
        return result
    }

    /// What a `get`'s last message says was left in the queue behind it.
    package static func readyCount(_ data: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.last.flatMap { ($0["message_count"] as? NSNumber)?.intValue }
    }

    /// Columns the management API's objects read best by, first.
    package static let leading = [
        "name", "vhost", "type", "state", "messages", "messages_ready", "messages_unacknowledged", "consumers", "source", "destination",
        "destination_type", "routing_key", "user", "node",
    ]

    /// Any management API answer as rows: a list of objects a row each (a
    /// paged answer's `items` too), an object as its keys and values, a
    /// list of values a value a row.
    package static func rows(_ data: Data, limit: Int) throws -> QueryResult {
        guard !data.isEmpty else { return QueryResult(message: "Done") }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var message: String?
        var list: [Any]
        if let object = value as? [String: Any] {
            if let items = object["items"] as? [Any] {
                list = items
                if let page = object["page"], let pages = object["page_count"] {
                    message = "Page \(HTTPDriverTransport.text(page) ?? "?") of \(HTTPDriverTransport.text(pages) ?? "?")"
                }
            } else {
                var result = QueryResult(columns: ["key", "value"])
                let keys = object.keys.sorted()
                result.rows = keys.prefix(limit).map { [$0, HTTPDriverTransport.text(object[$0])] }
                result.truncated = keys.count > limit
                return result
            }
        } else if let array = value as? [Any] {
            list = array
        } else {
            return QueryResult(columns: ["value"], rows: [[HTTPDriverTransport.text(value)]])
        }
        var result = QueryResult(message: message)
        let objects = list.compactMap { $0 as? [String: Any] }
        if objects.count == list.count, !objects.isEmpty {
            var keys = Set<String>()
            for object in objects { keys.formUnion(object.keys) }
            result.columns = leading.filter(keys.contains) + keys.subtracting(leading).sorted()
            result.rows = objects.prefix(limit).map { object in result.columns.map { HTTPDriverTransport.text(object[$0]) } }
        } else {
            result.columns = ["value"]
            result.rows = list.prefix(limit).map { [HTTPDriverTransport.text($0)] }
        }
        result.truncated = list.count > limit
        return result
    }

    /// What RabbitMQ said when it refused: `error: reason`, else its text.
    package static func said(_ data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = object["error"] as? String ?? ""
            let reason = object["reason"] as? String ?? ""
            let both = [error, reason].filter { !$0.isEmpty }
            if !both.isEmpty { return Array(NSOrderedSet(array: both)).compactMap { $0 as? String }.joined(separator: ": ") }
        }
        return HTTPDriverTransport.said(data, status: status, kind: .rabbitmq)
    }
}
