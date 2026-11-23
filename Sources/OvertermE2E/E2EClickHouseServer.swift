#if E2E
import Foundation
import Network

/// ClickHouse's HTTP interface as the driver uses it — a POSTed statement,
/// a JSONCompact answer — on 127.0.0.1, for the `databaseOpsClickHouse`
/// scenario: one table, `shop.orders (id UInt64, note Nullable(String))`, a
/// MergeTree ordered by id, kept in memory and changed by the exact statements
/// a Save sends; the system tables the Server and Users pages read, canned.
/// Every statement is kept (`statements`) for the scenario to look at.
package final class E2EClickHouseServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "overterm.e2e-clickhouse")
    private var listener: NWListener?
    package private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var received: [String] = []
    private var orders: [(id: Int, note: String?)] = [(1, "first"), (2, nil), (3, "third")]

    package var statements: [String] { lock.withLock { received } }
    package var notes: [String?] { lock.withLock { orders.map(\.note) } }

    package func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.listener = listener
        self.port = port
    }

    package func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if complete || error != nil { return connection.cancel() }
                self.receive(connection, buffer: buffer)
            case .invalid:
                self.respond(connection, 400, Data("bad request".utf8))
            case .complete(let request):
                let sql = String(decoding: request.body, as: UTF8.self)
                let (status, body) = self.lock.withLock { () -> (Int, Data) in
                    self.received.append(sql)
                    return self.answer(sql)
                }
                self.respond(connection, status, body)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ body: Data) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Answers

    private func table(_ columns: [(String, String)], _ rows: [[Any]]) -> (Int, Data) {
        let json: [String: Any] = ["meta": columns.map { ["name": $0.0, "type": $0.1] }, "data": rows, "rows": rows.count]
        return (200, (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private let done: (Int, Data) = (200, Data())

    /// `'…'` with ClickHouse's backslash escapes, as `SQLDialect.clickhouse` writes it.
    private static func literals(_ text: String) -> [String] {
        var out: [String] = []
        var chars = Array(text)[...]
        while let quote = chars.firstIndex(of: "'") {
            chars = chars[(quote + 1)...]
            var value = ""
            while let c = chars.first {
                chars = chars.dropFirst()
                if c == "\\", let next = chars.first {
                    chars = chars.dropFirst()
                    value.append(next == "n" ? "\n" : next)
                } else if c == "'" {
                    break
                } else {
                    value.append(c)
                }
            }
            out.append(value)
        }
        return out
    }

    /// The id a `WHERE \`id\` = '…'` names.
    private static func id(_ sql: String) -> Int? {
        guard let range = sql.range(of: "WHERE `id` = ") else { return nil }
        return literals(String(sql[range.upperBound...])).first.flatMap { Int($0) }
    }

    private func answer(_ raw: String) -> (Int, Data) {
        let sql = raw.replacingOccurrences(of: ClickHouseOps.marker, with: "")
        if sql == "SELECT 1" { return table([("1", "UInt8")], [[1]]) }
        if sql.contains("FROM system.databases") { return table([("name", "String")], [["shop"]]) }
        if sql.contains("primary_key") {
            return table(
                [("database", "String"), ("name", "String"), ("engine", "String"), ("primary_key", "String"), ("sorting_key", "String"), ("partition_key", "String")],
                [["shop", "orders", "MergeTree", "id", "id", ""]])
        }
        if sql.contains("FROM system.tables") { return table([("name", "String"), ("engine", "String")], [["orders", "MergeTree"]]) }
        if sql.contains("is_in_sorting_key") {
            return table(
                [("name", "String"), ("type", "String"), ("default_kind", "String"), ("is_in_sorting_key", "UInt8"), ("is_in_partition_key", "UInt8")],
                [["id", "UInt64", "", 1, 0], ["note", "Nullable(String)", "", 0, 0]])
        }
        if sql.contains("FROM system.columns") {
            return table([("table", "String"), ("name", "String"), ("type", "String")], [["orders", "id", "UInt64"], ["orders", "note", "Nullable(String)"]])
        }
        if sql.hasPrefix("SELECT * FROM") || sql.hasPrefix("SELECT id, note FROM") {
            return table([("id", "UInt64"), ("note", "Nullable(String)")], orders.sorted { $0.id < $1.id }.map { [String($0.id), $0.note ?? NSNull()] })
        }
        if sql.hasPrefix("SELECT count() FROM `shop`.`orders`"), let id = Self.id(sql) {
            return table([("count()", "UInt64")], [[String(orders.filter { $0.id == id }.count)]])
        }
        if sql.hasPrefix("ALTER TABLE `shop`.`orders` UPDATE `note` = "), let id = Self.id(sql) {
            let set = String(sql[sql.range(of: "UPDATE `note` = ")!.upperBound..<sql.range(of: " WHERE ")!.lowerBound])
            let value: String? = set == "NULL" ? nil : Self.literals(set).first
            for at in orders.indices where orders[at].id == id { orders[at].note = value }
            return done
        }
        if sql.hasPrefix("DELETE FROM `shop`.`orders`"), let id = Self.id(sql) {
            orders.removeAll { $0.id == id }
            return done
        }
        if sql.hasPrefix("INSERT INTO `shop`.`orders` (`id`, `note`) VALUES ("), let values = sql.range(of: "VALUES (") {
            let parts = String(sql[values.upperBound...].dropLast())
            let literals = Self.literals(parts)
            if let id = literals.first.flatMap({ Int($0) }) { orders.append((id, parts.hasSuffix("NULL") ? nil : literals.dropFirst().first)) }
            return done
        }
        if sql.contains("version()") {
            return table(
                [
                    ("version", "String"), ("uptime", "UInt32"), ("host", "String"), ("db", "String"), ("running", "UInt64"), ("connections", "Int64"),
                    ("memory", "Float64"), ("memory_total", "Float64"), ("mark_hits", "UInt64"), ("mark_misses", "UInt64"), ("queries", "UInt64"),
                    ("failed", "UInt64"), ("merges", "UInt64"), ("mutations", "UInt64"), ("total_rows", "UInt64"), ("total_bytes", "UInt64"),
                ],
                [["24.8.14.39", 3600, "fake", "shop", "2", "3", 104_857_600, 1_073_741_824, "90", "10", "500", "2", "0", "1", "3", "4096"]])
        }
        if sql.contains("system.server_settings") { return table([("value", "String")], [["4096"]]) }
        if sql.contains("system.replicas") { return table([("replicas", "UInt64"), ("delay", "UInt32")], [["0", 0]]) }
        if sql.contains("FROM system.processes") {
            let columns = [
                ("id", "String"), ("user", "String"), ("db", "String"), ("client", "String"), ("client_name", "String"), ("http_user_agent", "String"),
                ("seconds", "Float64"), ("query", "String"), ("is_cancelled", "UInt8"), ("read_rows", "UInt64"), ("memory", "String"), ("own", "UInt8"),
            ]
            return table(
                columns,
                [
                    ["q-sleep", "ot", "shop", "::ffff:10.0.0.7", "", "curl/8", 41.5, "SELECT sleepEachRow(1) FROM numbers(60)", 0, "41", "1.00 MiB", 0],
                    ["q-own", "ot", "shop", "::1", "", "Overterm", 0.001, raw, 0, "0", "0.00 B", 1],
                ])
        }
        if sql.hasPrefix("KILL QUERY WHERE query_id = ") {
            return table([("kill_status", "String"), ("query_id", "String")], [["waiting", Self.literals(sql).first ?? ""]])
        }
        if sql.contains("FROM system.users") {
            return table(
                [("name", "String"), ("storage", "String"), ("auth", "String"), ("hosts", "String"), ("default_database", "String")],
                [["ot", "users_xml", "plaintext_password", "::/0", ""], ["app", "local_directory", "sha256_password", "", "shop"]])
        }
        if sql.contains("FROM system.roles") { return table([("name", "String"), ("storage", "String")], [["readers", "local_directory"]]) }
        if sql.contains("FROM system.role_grants") {
            return table([("user_name", "String"), ("role_name", "String"), ("granted_role_name", "String")], [["app", NSNull(), "readers"]])
        }
        return table([], [])
    }
}
#endif
