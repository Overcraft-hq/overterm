import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// MongoDB — and Amazon DocumentDB, which speaks its protocol — over OP_MSG
/// on SwiftNIO, no client library: a command is a BSON document, its answer
/// one (`BSON`, `MongoShell`). Signed in with SCRAM-SHA-256 or SCRAM-SHA-1,
/// whichever the server says the user has (`MongoSCRAM`). TLS from the
/// first byte or none, as MongoDB has it — a CA bundle of the connection's
/// own for Verify Full (DocumentDB's). A replica set's hosts, listed or from
/// `mongodb+srv://`'s DNS, are tried in order and the primary followed;
/// one host, or a tunnel, is spoken to directly.
///
/// The catalog: databases as schemas, a database's collections as tables,
/// the fields of a sample of each (20 documents) as columns. A console
/// statement is the mongo shell's (`MongoStatement`); documents come back a
/// row each, their top-level fields as columns.
package actor MongoDriver: DatabaseDriver {
    package let config: DatabaseConnection
    private let password: String?
    private var channel: Channel?
    private var replies: MongoReplyHandler?
    private var nextRequest: Int32 = 1
    /// The database `db` is in the console (its `use`).
    package private(set) var current: String
    /// Not the primary: reads ask for any member, writes are the server's to refuse.
    private var onSecondary = false
    /// Where it is connected, for what is said.
    private var address = ""
    /// What the server it is connected to said of itself: its replica set,
    /// mongos, this connection's id (the Server page's own operations).
    package private(set) var hello: BSONDocument?

    /// Collections a database reads fields for at most.
    package static let sampledCollections = 100
    package static let sampleSize = 20

    package init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        current = connection.database.isEmpty ? "test" : connection.database
    }

    private var product: String { config.kind == .documentdb ? "DocumentDB" : "MongoDB" }
    private var authDatabase: String { config.authSource.isEmpty ? "admin" : config.authSource }

    // MARK: Connecting

    package func connect() async throws {
        guard channel == nil else { return }
        var seeds: [(host: String, port: Int)]
        var authSource = config.authSource
        if config.srv {
            let found: MongoSRV.Found
            do {
                found = try await MongoSRV.resolve(config.host)
            } catch {
                throw DatabaseError.failed(error.localizedDescription)
            }
            seeds = found.hosts
            if authSource.isEmpty, let source = found.options["authsource"] { authSource = source }
        } else {
            let defaultPort = config.port ?? config.kind.defaultPort ?? 27017
            seeds = config.host.split(separator: ",").map { item in
                let (host, port) = MongoURL.split(String(item).trimmingCharacters(in: .whitespaces))
                return (host.isEmpty ? "127.0.0.1" : host, port ?? defaultPort)
            }
            if seeds.isEmpty { seeds = [("127.0.0.1", defaultPort)] }
        }
        // Several seeds (or srv's): a replica set, whose primary is found.
        // One, or a tunnel's local end: that server and no other.
        let discover = seeds.count > 1 || config.srv
        var failures: [String] = []
        for seed in seeds {
            do {
                var hello = try await open(seed.host, seed.port)
                if discover, !Self.writable(hello), let primary = hello["primary"]?.string {
                    let (host, port) = MongoURL.split(primary)
                    let first = (seed.host, seed.port)
                    await drop()
                    do {
                        hello = try await open(host, port ?? 27017)
                    } catch {
                        // The primary can't be reached from here: the member that answered reads.
                        await drop()
                        hello = try await open(first.0, first.1)
                    }
                }
                onSecondary = !Self.writable(hello)
                self.hello = hello
                try await authenticate(hello, source: authSource.isEmpty ? "admin" : authSource)
                return
            } catch let error as DatabaseError {
                await drop()
                // A password refused is refused by every member: said at once.
                if case .failed(let message) = error, message.hasPrefix("Authentication failed") { throw error }
                failures.append(error.localizedDescription)
            } catch {
                await drop()
                failures.append(error.localizedDescription)
            }
        }
        throw DatabaseError.failed(failures.count == 1 ? failures[0] : failures.joined(separator: "\n"))
    }

    private static func writable(_ hello: BSONDocument) -> Bool {
        hello["isWritablePrimary"]?.bool == true || hello["ismaster"]?.bool == true || hello["msg"]?.string == "isdbgrid"
    }

    /// A socket to one server, and its hello.
    private func open(_ host: String, _ port: Int) async throws -> BSONDocument {
        address = "\(host):\(port)"
        let handler = MongoReplyHandler(product: product)
        let tls = try tlsHandler(serverName: config.serverName ?? host)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(8))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(tls) }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw DatabaseError.failed("Couldn't reach \(product) at \(address) — \(Self.describe(error))")
        }
        replies = handler
        var hello: BSONDocument = [
            "hello": .int32(1), "helloOk": .bool(true),
            "client": .document([
                "application": .document(["name": .string("Overterm")]),
                "driver": .document(["name": .string("overterm"), "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")]),
                "os": .document(["type": .string("Darwin")]),
            ]),
        ]
        if !config.user.isEmpty { hello["saslSupportedMechs"] = .string("\(authDatabase).\(config.user)") }
        do {
            return try await send(hello, database: "admin", timeout: .seconds(10))
        } catch let error as MongoServerError where error.code == 59 {
            // Before hello (MongoDB 4.4, DocumentDB's older engines): isMaster.
            hello["hello"] = nil
            hello["client"] = nil
            var legacy: BSONDocument = ["isMaster": .int32(1)]
            legacy.fields += hello.fields
            return try await send(legacy, database: "admin", timeout: .seconds(10))
        } catch let error as MongoServerError {
            throw DatabaseError.failed(error.message)
        } catch {
            throw DatabaseError.failed(handshakeFailure(error))
        }
    }

    private func handshakeFailure(_ error: Error) -> String {
        if let error = error as? NIOSSLError {
            return "TLS with \(address) failed — \(Self.tlsWords(error))"
        }
        if case .failed(let message) = error as? DatabaseError, message.contains("closed the connection") {
            return config.sslMode == .disable
                ? "\(address) closed the connection before answering — if it wants TLS (DocumentDB's does), turn TLS on."
                : "\(address) closed the connection during TLS — it may not speak TLS: try with TLS off."
        }
        return "\(address) didn't answer as \(product) — \(Self.describe(error))"
    }

    package static func tlsWords(_ error: NIOSSLError) -> String {
        let said = String(describing: error)
        if said.contains("CERTIFICATE_VERIFY_FAILED") || said.contains("certificate") {
            return "its certificate isn't trusted here. Choose its CA bundle (DocumentDB's global-bundle.pem), or don't check the certificate. (\(said))"
        }
        if said.contains("WRONG_VERSION_NUMBER") || said.contains("PACKET_LENGTH") {
            return "it doesn't speak TLS on this port: turn TLS off. (\(said))"
        }
        return said
    }

    private func tlsHandler(serverName: String) throws -> NIOSSLClientHandler? {
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch config.sslMode {
        case .disable, .prefer: return nil
        case .require:
            configuration.certificateVerification = .none
        case .verifyFull:
            let path = (config.caFile.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !path.isEmpty {
                guard FileManager.default.isReadableFile(atPath: path) else {
                    throw DatabaseError.failed("The CA bundle \(config.caFile) can't be read — choose it again in Edit Connection….")
                }
                configuration.trustRoots = .file(path)
            }
        }
        // SNI takes a name, never an address.
        let isAddress = serverName.allSatisfy { $0.isNumber || $0 == "." } || serverName.contains(":")
        do {
            return try NIOSSLClientHandler(
                context: NIOSSLContext(configuration: configuration), serverHostname: isAddress || config.sslMode == .require ? nil : serverName)
        } catch {
            throw DatabaseError.failed("TLS couldn't be set up: \(Self.describe(error))")
        }
    }

    private func authenticate(_ hello: BSONDocument, source: String) async throws {
        guard !config.user.isEmpty else { return }
        guard let password, !password.isEmpty else {
            throw DatabaseError.failed("\(product) signs \(config.user) in with a password, and none was given (authMechanismRequiresPassword).")
        }
        let offered = hello["saslSupportedMechs"]?.array?.compactMap(\.string) ?? []
        // SHA-256 when the user has it; SHA-1 for older users and DocumentDB.
        let mechanism: MongoSCRAM.Mechanism = offered.contains("SCRAM-SHA-256") || (offered.isEmpty && config.kind == .mongodb) ? .sha256 : .sha1
        do {
            try await scram(MongoSCRAM(mechanism: mechanism, user: config.user, password: password), source: source)
        } catch let error as MongoServerError where offered.isEmpty && mechanism == .sha256 && error.code == 18 {
            // A server that didn't say: SHA-1 is everyone's.
            try await scram(MongoSCRAM(mechanism: .sha1, user: config.user, password: password), source: source)
        }
    }

    private func scram(_ scram: MongoSCRAM, source: String) async throws {
        do {
            let start = try await send(
                [
                    "saslStart": .int32(1), "mechanism": .string(scram.mechanism.rawValue),
                    "payload": .binary(subtype: 0, Data(scram.clientFirst.utf8)), "autoAuthorize": .int32(1),
                    "options": .document(["skipEmptyExchange": .bool(true)]),
                ], database: source, timeout: .seconds(15))
            guard case .binary(_, let first)? = start["payload"], let conversation = start["conversationId"] else {
                throw DatabaseError.failed("\(product) answered saslStart without a challenge.")
            }
            let final = try scram.clientFinal(serverFirst: String(decoding: first, as: UTF8.self))
            var reply = try await send(
                ["saslContinue": .int32(1), "conversationId": conversation, "payload": .binary(subtype: 0, Data(final.message.utf8))],
                database: source, timeout: .seconds(15))
            guard case .binary(_, let last)? = reply["payload"] else { throw DatabaseError.failed("\(product) ended SCRAM without its signature.") }
            try MongoSCRAM.verify(serverFinal: String(decoding: last, as: UTF8.self), expected: final.serverSignature)
            // A server that ignores skipEmptyExchange wants one more, empty.
            var rounds = 0
            while reply["done"]?.bool != true, rounds < 2 {
                reply = try await send(
                    ["saslContinue": .int32(1), "conversationId": conversation, "payload": .binary(subtype: 0, Data())], database: source,
                    timeout: .seconds(15))
                rounds += 1
            }
        } catch let error as MongoServerError where error.code == 18 {
            throw DatabaseError.failed(
                "Authentication failed: \(product) refused \(config.user) in the auth database \(source) (\(scram.mechanism.rawValue)) — the user, the password or the auth database is wrong."
            )
        } catch let error as MongoSCRAM.Failure {
            throw DatabaseError.failed("Authentication failed: \(error.message)")
        } catch let error as MongoServerError {
            throw DatabaseError.failed(error.message)
        }
    }

    package func close() async { await drop() }

    private func drop() async {
        try? await channel?.close().get()
        channel = nil
        replies = nil
    }

    // MARK: Sending

    /// One command on a database, its answer — or the server's error,
    /// thrown as `MongoServerError`.
    package func send(_ body: BSONDocument, database: String, timeout: TimeAmount? = nil) async throws -> BSONDocument {
        guard let channel, let replies else { throw DatabaseError.notConnected }
        var body = body
        body["$db"] = .string(database)
        if onSecondary, MongoCommand.readCommands.contains(body.fields.first?.key ?? ""), body["$readPreference"] == nil { body["$readPreference"] = .document(["mode": .string("primaryPreferred")]) }
        let id = nextRequest
        nextRequest = nextRequest == Int32.max ? 1 : nextRequest + 1
        let message = MongoWire.message(body, requestID: id)
        let promise = channel.eventLoop.makePromise(of: BSONDocument.self)
        let late = DatabaseError.failed("\(address) didn't answer in time.")
        channel.eventLoop.execute {
            replies.expect(id, promise)
            channel.writeAndFlush(channel.allocator.buffer(bytes: message), promise: nil)
            if let timeout {
                channel.eventLoop.scheduleTask(in: timeout) {
                    replies.fail(id, late)
                }
            }
        }
        let reply = try await promise.futureResult.get()
        if reply["ok"]?.bool != true {
            throw MongoServerError(reply: reply, documentDB: config.kind == .documentdb)
        }
        return reply
    }

    /// A command as the console's, its errors in words.
    package func command(_ body: BSONDocument, database: String) async throws -> BSONDocument {
        do {
            return try await send(body, database: database)
        } catch let error as MongoServerError {
            throw DatabaseError.failed(error.message)
        }
    }

    // MARK: Running

    package func execute(_ statement: String, limit: Int) async throws -> QueryResult {
        let started = Date()
        let command: MongoCommand
        do {
            command = try MongoText.command(statement)
        } catch {
            throw DatabaseError.failed(error.localizedDescription)
        }
        // Refused before it is sent, whoever asks.
        if config.readOnly, !command.onlyReads { throw DatabaseError.readOnly(command.method) }
        if channel == nil { try await connect() }
        var result = try await run(command, limit: max(1, limit))
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private func run(_ command: MongoCommand, limit: Int) async throws -> QueryResult {
        let database = command.database ?? current
        switch command.action {
        case .use(let name):
            current = name
            return QueryResult(message: "Now on \(name)")
        case .cursor:
            return MongoResult.rows(try await documents(command, database: database, limit: limit), limit: limit)
        case .findOne:
            let found = try await documents(command, database: database, limit: 1)
            if found.isEmpty { return QueryResult(message: "No document matched.") }
            return MongoResult.rows(found, limit: 1)
        case .count:
            let found = try await documents(command, database: database, limit: 1)
            let n = found.first?["n"]?.int ?? 0
            return QueryResult(columns: ["count"], types: ["long"], rows: [[String(n)]])
        case .distinct:
            let reply = try await self.command(command.body, database: database)
            return MongoResult.values(reply["values"]?.array ?? [], limit: limit)
        case .write:
            let reply = try await self.command(command.body, database: database)
            if let errors = reply["writeErrors"]?.array, !errors.isEmpty, (reply["n"]?.int ?? 0) == 0 {
                let error = errors[0].document
                throw DatabaseError.failed(
                    MongoServerError.words(error?["errmsg"]?.string ?? "The write failed.", code: error?["code"]?.int, name: error?["codeName"]?.string))
            }
            return MongoResult.write(reply, command: command)
        case .findAndModify:
            let reply = try await self.command(command.body, database: database)
            guard let document = reply["value"]?.document else { return QueryResult(message: "No document matched.") }
            return MongoResult.rows([document], limit: 1)
        case .showDatabases:
            let reply = try await self.command(command.body, database: "admin")
            var result = QueryResult(columns: ["name", "size", "empty"], types: ["string", "long", "bool"])
            for entry in reply["databases"]?.array?.compactMap(\.document) ?? [] {
                let size = entry["sizeOnDisk"]?.int.map { FilePreview.size(Int64($0)) }
                result.rows.append([entry["name"]?.string, size, entry["empty"]?.cell])
            }
            return result
        case .showCollections, .collectionNames:
            var found = try await documents(command, database: database, limit: 100_000)
            found.sort { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }
            if command.action == .collectionNames {
                return QueryResult(columns: ["name"], types: ["string"], rows: found.map { [$0["name"]?.string] })
            }
            return QueryResult(columns: ["name", "type"], types: ["string", "string"], rows: found.map { [$0["name"]?.string, $0["type"]?.string] })
        case .command:
            let reply = try await self.command(command.body, database: database)
            if command.name == "count" {
                return QueryResult(columns: ["count"], types: ["long"], rows: [[String(reply["n"]?.int ?? 0)]])
            }
            if let cursor = reply["cursor"]?.document, let batch = cursor["firstBatch"]?.array {
                return MongoResult.rows(batch.compactMap(\.document), limit: limit)
            }
            var shown = reply
            for noise in ["ok", "$clusterTime", "operationTime", "$db"] { shown[noise] = nil }
            if shown.isEmpty { return QueryResult(message: "Done") }
            return MongoResult.fields(shown)
        }
    }

    /// A cursor's documents, up to one past `limit` (so "there are more"
    /// is known), the rest of the cursor closed.
    package func documents(_ command: MongoCommand, database: String, limit: Int) async throws -> [BSONDocument] {
        var body = command.body
        let wanted = min(command.limit ?? Int.max, limit + 1)
        if command.name == "find" {
            if let own = command.limit { body["limit"] = .int64(Int64(own)) }
            body["batchSize"] = .int64(Int64(wanted))
        } else if body["cursor"] != nil || command.name == "aggregate" || command.name.hasPrefix("list") {
            var cursor = body["cursor"]?.document ?? [:]
            cursor["batchSize"] = .int64(Int64(min(wanted, 100_000)))
            body["cursor"] = .document(cursor)
        }
        let reply = try await self.command(body, database: database)
        guard let cursor = reply["cursor"]?.document else { return [] }
        var found = cursor["firstBatch"]?.array?.compactMap(\.document) ?? []
        var id = cursor["id"]?.int ?? 0
        let namespace = cursor["ns"]?.string ?? ""
        let collection = namespace.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? command.collection ?? ""
        let cursorDatabase = namespace.split(separator: ".", maxSplits: 1).first.map(String.init) ?? database
        while id != 0, found.count < wanted {
            let more = try await self.command(
                ["getMore": .int64(Int64(id)), "collection": .string(collection), "batchSize": .int64(Int64(wanted - found.count))],
                database: cursorDatabase)
            let next = more["cursor"]?.document
            found += next?["nextBatch"]?.array?.compactMap(\.document) ?? []
            id = next?["id"]?.int ?? 0
        }
        if id != 0 {
            _ = try? await send(["killCursors": .string(collection), "cursors": .array([.int64(Int64(id))])], database: cursorDatabase)
        }
        return found
    }

    // MARK: Catalog

    /// The databases — the connection's first; admin, config and local
    /// only when it is one of them.
    package func schemas() async throws -> [String] {
        if channel == nil { try await connect() }
        var names: [String]
        do {
            let reply = try await send(["listDatabases": .int32(1), "nameOnly": .bool(true)], database: "admin")
            names = reply["databases"]?.array?.compactMap { $0.document?["name"]?.string } ?? []
        } catch {
            // A user who may not list databases still has its own.
            names = []
        }
        let system: Set<String> = ["admin", "config", "local"]
        names = names.filter { !system.contains($0) || $0 == current }
        if !names.contains(current) { names.append(current) }
        return names.sorted { ($0 == current ? 0 : 1, $0) < ($1 == current ? 0 : 1, $1) }
    }

    package func tables(in schema: String) async throws -> [CatalogTable] {
        if channel == nil { try await connect() }
        let command = MongoCommand(
            method: "listCollections", body: ["listCollections": .int32(1), "nameOnly": .bool(true), "authorizedCollections": .bool(true)],
            action: .cursor)
        var found: [BSONDocument]
        do {
            found = try await documents(command, database: schema, limit: 100_000)
        } catch {
            // DocumentDB's older engines don't know authorizedCollections.
            var plain = command
            plain.body["authorizedCollections"] = nil
            found = try await documents(plain, database: schema, limit: 100_000)
        }
        return found.compactMap { entry -> CatalogTable? in
            guard let name = entry["name"]?.string, !name.hasPrefix("system.") else { return nil }
            return CatalogTable(schema: schema, name: name, isView: entry["type"]?.string == "view")
        }.sorted { $0.name < $1.name }
    }

    /// Each collection's fields, from its first documents: a collection
    /// has no schema of its own to read.
    package func columns(in schema: String) async throws -> [CatalogColumn] {
        let collections = try await tables(in: schema).prefix(Self.sampledCollections)
        var columns: [CatalogColumn] = []
        for collection in collections {
            let sample = MongoCommand(
                collection: collection.name, method: "find", body: ["find": .string(collection.name)], action: .cursor, limit: Self.sampleSize)
            guard let documents = try? await documents(sample, database: schema, limit: Self.sampleSize) else { continue }
            columns += Self.fields(of: documents).map { CatalogColumn(table: collection.name, name: $0.name, type: $0.type) }
        }
        return columns
    }

    /// The top-level fields of some documents, in the order met, `_id`
    /// first, each with the type it first has that isn't null.
    package static func fields(of documents: [BSONDocument]) -> [(name: String, type: String)] {
        var order: [String] = []
        var types: [String: String] = [:]
        for document in documents {
            for field in document.fields {
                if types[field.key] == nil {
                    if field.key == "_id" { order.insert(field.key, at: 0) } else { order.append(field.key) }
                    types[field.key] = field.value.typeName
                } else if types[field.key] == "null" {
                    types[field.key] = field.value.typeName
                }
            }
        }
        return order.map { ($0, types[$0] ?? "") }
    }

    package static func describe(_ error: Error) -> String {
        if let error = error as? NIOSSLError { return tlsWords(error) }
        if let error = error as? DatabaseError { return error.localizedDescription }
        if let error = error as? NIOConnectionError {
            if let dns = error.dnsAAAAError ?? error.dnsAError { return "the name doesn't resolve (\(dns))" }
            if let first = error.connectionErrors.first { return String(describing: first.error) }
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError { return "no answer in 8 s" }
        return String(describing: error)
    }
}

/// An `{ ok: 0 }` answer: its message, code and name — said plainly, and
/// for DocumentDB, that it is DocumentDB refusing what MongoDB would take.
package struct MongoServerError: Error {
    package let code: Int?
    package let name: String?
    package let message: String

    package init(reply: BSONDocument, documentDB: Bool) {
        code = reply["code"]?.int
        name = reply["codeName"]?.string
        var message = Self.words(reply["errmsg"]?.string ?? "The server refused the command.", code: code, name: name)
        let unsupported = [59, 115, 303].contains(code ?? 0) || (reply["errmsg"]?.string?.lowercased().contains("not supported") ?? false)
        if documentDB, unsupported { message += " — Amazon DocumentDB doesn't support this, though MongoDB does." }
        self.message = message
    }

    package static func words(_ message: String, code: Int?, name: String?) -> String {
        guard let name, !name.isEmpty, !message.contains(name) else { return message }
        return "\(message) (\(name))"
    }
}

/// OP_MSG's bytes: the header, no flags, one body section.
package enum MongoWire {
    package static let opMsg: Int32 = 2013
    package static let opReply: Int32 = 1

    package static func message(_ body: BSONDocument, requestID: Int32, responseTo: Int32 = 0) -> [UInt8] {
        let document = [UInt8](body.encoded())
        let length = Int32(16 + 4 + 1 + document.count)
        var out: [UInt8] = []
        out.reserveCapacity(Int(length))
        func append(_ n: Int32) { withUnsafeBytes(of: n.littleEndian) { out += $0 } }
        append(length)
        append(requestID)
        append(responseTo)
        append(opMsg)
        append(0)
        out.append(0)
        out += document
        return out
    }

    /// One whole message: its id, who it answers, and its body (a kind 1
    /// section's documents folded in under their name). nil when it isn't
    /// all here yet.
    package static func reply(_ bytes: [UInt8]) throws -> (requestID: Int32, responseTo: Int32, body: BSONDocument, length: Int)? {
        guard bytes.count >= 4 else { return nil }
        var reader = BSON.Reader(bytes: bytes)
        let length = Int(try reader.little(Int32.self))
        guard length >= 16, length <= 64 * 1024 * 1024 else { throw BSON.DecodeError(description: "a message of length \(length)") }
        guard bytes.count >= length else { return nil }
        let requestID = try reader.little(Int32.self)
        let responseTo = try reader.little(Int32.self)
        let opCode = try reader.little(Int32.self)
        let end = length
        switch opCode {
        case opMsg:
            let flags = try reader.little(UInt32.self)
            let sectionsEnd = flags & 1 != 0 ? end - 4 : end
            var body = BSONDocument()
            while reader.at < sectionsEnd {
                let kind = try reader.take(1).first!
                if kind == 0 {
                    body.fields += try reader.document().fields
                } else {
                    let start = reader.at
                    let size = Int(try reader.little(Int32.self))
                    let name = try reader.cstring()
                    var items: [BSONValue] = []
                    while reader.at < start + size { items.append(.document(try reader.document())) }
                    body[name] = .array(items)
                }
            }
            return (requestID, responseTo, body, length)
        case opReply:
            _ = try reader.take(4 + 8 + 4)
            let count = try reader.little(Int32.self)
            let body = count > 0 ? try reader.document() : BSONDocument()
            return (requestID, responseTo, body, length)
        default:
            throw BSON.DecodeError(description: "an answer of op code \(opCode)")
        }
    }
}

/// The socket's end: bytes in, each reply to the request it answers.
/// Touched only on its channel's event loop.
package final class MongoReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    package typealias InboundIn = ByteBuffer

    private let product: String
    private var bytes: [UInt8] = []
    private var waiting: [Int32: EventLoopPromise<BSONDocument>] = [:]

    package init(product: String) { self.product = product }

    package func expect(_ id: Int32, _ promise: EventLoopPromise<BSONDocument>) { waiting[id] = promise }

    package func fail(_ id: Int32, _ error: Error) { waiting.removeValue(forKey: id)?.fail(error) }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
        do {
            while let (_, responseTo, body, length) = try MongoWire.reply(bytes) {
                bytes.removeFirst(length)
                waiting.removeValue(forKey: responseTo)?.succeed(body)
            }
        } catch {
            failAll(DatabaseError.failed("\(product) answered something that isn't its protocol: \(error)"))
            context.close(promise: nil)
        }
    }

    package func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    package func channelInactive(context: ChannelHandlerContext) {
        failAll(DatabaseError.failed("\(product) closed the connection."))
        context.fireChannelInactive()
    }

    private func failAll(_ error: Error) {
        let pending = waiting
        waiting = [:]
        for promise in pending.values { promise.fail(error) }
    }
}
