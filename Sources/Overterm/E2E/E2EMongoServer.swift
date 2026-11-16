import Foundation
import Network

/// A mongod as small as the tests need, in memory on 127.0.0.1: OP_MSG in
/// and out, no auth, no TLS. It answers hello, the catalog (listDatabases,
/// listCollections), find with an equality filter, a sort, skip and limit
/// and cursors across batches (getMore, killCursors), aggregate's $match,
/// $group by a field or a constant with $sum, $sort, $skip and $limit,
/// insert, update's $set and $unset, delete, count and drop — and, for the
/// Server page, serverStatus, `$currentOp` (this connection's operation and
/// another's), `$collStats`, profile (off) and killOp — anything else is
/// CommandNotFound, as a server says it. For the `mongodb` and `mongoOps`
/// scenarios and the always-run driver tests: the real server is
/// `MongoDriverTests`'.
final class E2EMongoServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "overterm.e2e-mongodb")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    /// database → collection → documents, in insertion order.
    private var data: [String: [String: [BSONDocument]]] = [:]
    private var cursors: [Int64: (namespace: String, rest: [BSONDocument])] = [:]
    private var nextCursor: Int64 = 1000
    private var nextReply: Int32 = 1
    /// Every command's name, as it came: for the tests to look at.
    private var received: [String] = []

    var commands: [String] { lock.withLock { received } }
    private var killed: [Int] = []
    /// The operations killOp was sent for.
    var killedOperations: [Int] { lock.withLock { killed } }
    /// What every connection's hello says is its id: the page's own operation.
    static let connectionID: Int32 = 42

    func documents(_ database: String, _ collection: String) -> [BSONDocument] {
        lock.withLock { data[database]?[collection] ?? [] }
    }

    func seed(_ database: String, _ collection: String, _ documents: [BSONDocument]) {
        lock.withLock { data[database, default: [:]][collection, default: []] += documents }
    }

    func start() throws {
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

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func connection(name: String = "Mongo", database: String = "shop") -> DatabaseConnection {
        var connection = DatabaseConnection(name: name, kind: .mongodb)
        connection.host = "127.0.0.1"
        connection.port = Int(port)
        connection.database = database
        connection.sslMode = .disable
        return connection
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: [])
    }

    private func receive(_ connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer += data }
            do {
                while let (requestID, _, body, length) = try MongoWire.reply(buffer) {
                    buffer.removeFirst(length)
                    let reply = self.answer(body)
                    let id = self.lock.withLock {
                        self.nextReply += 1
                        return self.nextReply
                    }
                    connection.send(content: Data(MongoWire.message(reply, requestID: id, responseTo: requestID)), completion: .idempotent)
                }
            } catch {
                return connection.cancel()
            }
            if complete || error != nil { return connection.cancel() }
            self.receive(connection, buffer: buffer)
        }
    }

    // MARK: Answers

    private func ok(_ fields: BSONDocument = [:]) -> BSONDocument {
        var reply = fields
        reply["ok"] = .double(1)
        return reply
    }

    private func refuse(_ message: String, code: Int32, name: String) -> BSONDocument {
        ["ok": .double(0), "errmsg": .string(message), "code": .int32(code), "codeName": .string(name)]
    }

    private func answer(_ body: BSONDocument) -> BSONDocument {
        guard let name = body.fields.first?.key else { return refuse("empty command", code: 9, name: "FailedToParse") }
        let database = body["$db"]?.string ?? "test"
        let target = body.fields.first?.value.string ?? ""
        return lock.withLock {
            received.append(name)
            switch name {
            case "hello", "isMaster", "ismaster":
                return ok([
                    "isWritablePrimary": .bool(true), "maxWireVersion": .int32(21), "maxBsonObjectSize": .int32(16_777_216),
                    "connectionId": .int32(Self.connectionID),
                ])
            case "serverStatus":
                return ok([
                    "version": .string("7.0.0-fake"), "uptime": .double(3600), "host": .string("fake"),
                    "connections": .document(["current": .int32(2), "available": .int32(98), "totalCreated": .int32(5)]),
                    "opcounters": .document(["query": .int64(Int64(received.filter { $0 == "find" }.count)), "insert": .int64(0), "command": .int64(Int64(received.count))]),
                ])
            case "profile":
                return ok(["was": .int32(0), "slowms": .int32(100)])
            case "killOp":
                killed.append(body["op"]?.int ?? -1)
                return ok(["info": .string("attempting to kill op")])
            case "ping", "buildInfo":
                return ok(name == "buildInfo" ? ["version": .string("7.0.0-fake")] : [:])
            case "listDatabases":
                let names = data.keys.sorted()
                return ok(["databases": .array(names.map { .document(["name": .string($0), "sizeOnDisk": .int64(8192), "empty": .bool(false)]) })])
            case "listCollections":
                let names = (data[database] ?? [:]).keys.sorted()
                return cursor(names.map { ["name": .string($0), "type": .string("collection")] }, namespace: "\(database).$cmd.listCollections", body: body)
            case "find":
                var found = matching(data[database]?[target] ?? [], body["filter"]?.document)
                if let sort = body["sort"]?.document { found = sorted(found, sort) }
                if let skip = body["skip"]?.int { found = Array(found.dropFirst(skip)) }
                if let limit = body["limit"]?.int, limit > 0 { found = Array(found.prefix(limit)) }
                return cursor(found, namespace: "\(database).\(target)", body: body)
            case "aggregate":
                var found = data[database]?[target] ?? []
                let stages = body["pipeline"]?.array?.compactMap(\.document) ?? []
                if stages.first?.fields.first?.key == "$currentOp" {
                    // This connection's own operation, and another's that runs long.
                    let ops: [BSONDocument] = [
                        [
                            "opid": .int32(7), "active": .bool(true), "op": .string("command"), "ns": .string("admin.$cmd.aggregate"),
                            "client": .string("127.0.0.1:50000"), "connectionId": .int32(Self.connectionID), "appName": .string("Overterm"),
                            "microsecs_running": .int64(150), "command": .document(["aggregate": .int32(1)]),
                        ],
                        [
                            "opid": .int32(8), "active": .bool(true), "op": .string("query"), "ns": .string("shop.orders"), "client": .string("10.0.0.9:41000"),
                            "connectionId": .int32(43), "appName": .string("report"), "microsecs_running": .int64(12_000_000),
                            "effectiveUsers": .array([.document(["user": .string("reporter"), "db": .string("admin")])]),
                            "command": .document(["find": .string("orders"), "filter": .document(["status": .string("open")])]),
                        ],
                    ]
                    return cursor(ops, namespace: "admin.$cmd.aggregate", body: body)
                }
                if stages.first?.fields.first?.key == "$collStats" {
                    let count = found.count
                    let stats: BSONDocument = [
                        "count": .int32(Int32(count)), "size": .int32(Int32(count * 100)), "storageSize": .int32(4096),
                        "indexSizes": .document(["_id_": .int32(4096)]),
                    ]
                    return cursor([["storageStats": .document(stats)]], namespace: "\(database).\(target)", body: body)
                }
                for stage in stages {
                    guard let operation = stage.fields.first else { continue }
                    switch operation.key {
                    case "$match": found = matching(found, operation.value.document)
                    case "$sort": found = sorted(found, operation.value.document ?? [:])
                    case "$skip": found = Array(found.dropFirst(operation.value.int ?? 0))
                    case "$limit": found = Array(found.prefix(operation.value.int ?? 0))
                    case "$group": found = grouped(found, operation.value.document ?? [:])
                    default: return refuse("Unrecognized pipeline stage name: '\(operation.key)'", code: 40324, name: "Location40324")
                    }
                }
                return cursor(found, namespace: "\(database).\(target)", body: body)
            case "getMore":
                let id = Int64(body["getMore"]?.int ?? 0)
                guard let open = cursors[id] else { return refuse("cursor id \(id) not found", code: 43, name: "CursorNotFound") }
                let size = min(100, body["batchSize"]?.int ?? 101)
                let batch = Array(open.rest.prefix(size))
                let rest = Array(open.rest.dropFirst(size))
                cursors[id] = rest.isEmpty ? nil : (open.namespace, rest)
                return ok([
                    "cursor": .document([
                        "nextBatch": .array(batch.map(BSONValue.document)), "id": .int64(rest.isEmpty ? 0 : id), "ns": .string(open.namespace),
                    ])
                ])
            case "killCursors":
                for id in body["cursors"]?.array ?? [] { cursors[Int64(id.int ?? 0)] = nil }
                return ok()
            case "insert":
                let documents = body["documents"]?.array?.compactMap(\.document) ?? []
                let existing = Set((data[database]?[target] ?? []).compactMap { $0["_id"]?.shell })
                for document in documents where existing.contains(document["_id"]?.shell ?? "") {
                    return ok([
                        "n": .int32(0),
                        "writeErrors": .array([
                            .document([
                                "index": .int32(0), "code": .int32(11000),
                                "errmsg": .string("E11000 duplicate key error collection: \(database).\(target) index: _id_ dup key"),
                            ])
                        ]),
                    ])
                }
                data[database, default: [:]][target, default: []] += documents
                return ok(["n": .int32(Int32(documents.count))])
            case "update":
                var n = 0
                var modified = 0
                for statement in body["updates"]?.array?.compactMap(\.document) ?? [] {
                    let multi = statement["multi"]?.bool == true
                    var documents = data[database]?[target] ?? []
                    for index in documents.indices where matches(documents[index], statement["q"]?.document) {
                        n += 1
                        for (key, value) in statement["u"]?.document?["$set"]?.document?.fields ?? [] where documents[index][key] != value {
                            documents[index][key] = value
                            modified += 1
                        }
                        for key in statement["u"]?.document?["$unset"]?.document?.keys ?? [] where documents[index][key] != nil {
                            documents[index][key] = nil
                            modified += 1
                        }
                        if !multi { break }
                    }
                    data[database, default: [:]][target] = documents
                }
                return ok(["n": .int32(Int32(n)), "nModified": .int32(Int32(modified))])
            case "delete":
                var n = 0
                for statement in body["deletes"]?.array?.compactMap(\.document) ?? [] {
                    var documents = data[database]?[target] ?? []
                    let all = statement["limit"]?.int == 0
                    while let index = documents.firstIndex(where: { matches($0, statement["q"]?.document) }) {
                        documents.remove(at: index)
                        n += 1
                        if !all { break }
                    }
                    data[database, default: [:]][target] = documents
                }
                return ok(["n": .int32(Int32(n))])
            case "count":
                return ok(["n": .int32(Int32(matching(data[database]?[target] ?? [], body["query"]?.document).count))])
            case "drop":
                guard data[database]?[target] != nil else { return refuse("ns not found", code: 26, name: "NamespaceNotFound") }
                data[database]?[target] = nil
                return ok()
            default:
                return refuse("no such command: '\(name)'", code: 59, name: "CommandNotFound")
            }
        }
    }

    /// A cursor's first batch, the rest kept for getMore. A batch holds
    /// 100 at most, as a real server's holds 16 MB: getMore is needed.
    private func cursor(_ documents: [BSONDocument], namespace: String, body: BSONDocument) -> BSONDocument {
        let size = min(100, body["batchSize"]?.int ?? body["cursor"]?.document?["batchSize"]?.int ?? 101)
        let first = Array(documents.prefix(size))
        let rest = Array(documents.dropFirst(size))
        var id: Int64 = 0
        if !rest.isEmpty {
            nextCursor += 1
            id = nextCursor
            cursors[id] = (namespace, rest)
        }
        return ok(["cursor": .document(["firstBatch": .array(first.map(BSONValue.document)), "id": .int64(id), "ns": .string(namespace)])])
    }

    private func matches(_ document: BSONDocument, _ filter: BSONDocument?) -> Bool {
        (filter?.fields ?? []).allSatisfy { document[$0.key] == $0.value }
    }

    private func matching(_ documents: [BSONDocument], _ filter: BSONDocument?) -> [BSONDocument] {
        documents.filter { matches($0, filter) }
    }

    private func sorted(_ documents: [BSONDocument], _ sort: BSONDocument) -> [BSONDocument] {
        guard let key = sort.fields.first else { return documents }
        let descending = (key.value.int ?? 1) < 0
        return documents.sorted { a, b in
            let (x, y) = (a[key.key], b[key.key])
            let less: Bool =
                if let x = x?.int, let y = y?.int { x < y } else { (x?.cell ?? "") < (y?.cell ?? "") }
            return descending ? !less && x != y : less
        }
    }

    /// $group by `_id` ("$field" or a constant), each other field a `$sum`.
    private func grouped(_ documents: [BSONDocument], _ spec: BSONDocument) -> [BSONDocument] {
        var groups: [(key: BSONValue, document: BSONDocument)] = []
        for document in documents {
            var key = spec["_id"] ?? .null
            if let path = key.string, path.hasPrefix("$") { key = document[String(path.dropFirst())] ?? .null }
            let index =
                groups.firstIndex { $0.key == key }
                ?? {
                    groups.append((key, ["_id": key]))
                    return groups.count - 1
                }()
            for field in spec.fields where field.key != "_id" {
                guard let sum = field.value.document?["$sum"] else { continue }
                var add = sum.int ?? 0
                if let path = sum.string, path.hasPrefix("$") { add = document[String(path.dropFirst())]?.int ?? 0 }
                groups[index].document[field.key] = .int32(Int32((groups[index].document[field.key]?.int ?? 0) + add))
            }
        }
        return groups.map(\.document)
    }
}
