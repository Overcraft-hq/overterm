import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Redis, over RESP on SwiftNIO — no client library: a command is an array
/// of strings, a reply one value (RedisProtocol). The catalog is Redis's own:
/// the databases with keys in them (INFO keyspace) as schemas, a database's
/// keys (SCAN, capped) as its tables, no columns. A console line is a
/// command, as redis-cli takes it; `VIEW key` is Overterm's own, a key's
/// value whatever its type — what a key in the tree opens with.
actor RedisDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let password: String?
    private var channel: Channel?
    private var replies: RedisReplyHandler?
    /// The database the console is on (its SELECTs).
    private var current = 0
    /// The database the connection is on now: the browser moves it, and
    /// the console's next command moves it back.
    private var selected = 0
    /// One operation at a time: a SELECT and the command after it must not
    /// have another's in between — an actor gives way at every await.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// Keys a database lists in the tree at most: SCAN stops there.
    static let keyLimit = 1000

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
    }

    /// The database a connection names: "3", "db3" or nothing (0).
    static func database(_ text: String) -> Int {
        let digits = text.lowercased().hasPrefix("db") ? String(text.dropFirst(2)) : text
        return Int(digits.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    var database: Int { current }

    private func exclusive<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { queue.append($0) }
        }
        busy = true
        defer {
            if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
        }
        return try await work()
    }

    func connect() async throws {
        try await exclusive { try await open(handler: RedisReplyHandler()) }
    }

    private func open(handler: RedisReplyHandler) async throws {
        guard channel == nil else { return }
        let host = config.host.isEmpty ? "127.0.0.1" : config.host
        let port = config.port ?? config.kind.defaultPort ?? 6379
        let tls = try Self.tls(config.sslMode, serverName: config.serverName ?? host)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(tls) }
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw DatabaseError.failed("Couldn't reach Redis at \(host):\(port) — \(error.localizedDescription)")
        }
        replies = handler
        do {
            if let password, !password.isEmpty {
                let auth = config.user.isEmpty ? ["AUTH", password] : ["AUTH", config.user, password]
                if case .error(let message) = try await send(auth) { throw DatabaseError.failed(message) }
            }
            // A server that wants a password and got none says so here, not
            // later; a TLS port spoken to in plain text closes here.
            if case .error(let message) = try await send(["PING"]) { throw DatabaseError.failed(message) }
            current = Self.database(config.database)
            selected = 0
            try await select(current)
        } catch {
            await drop()
            throw error
        }
    }

    /// TLS as Redis has it: none, or from the first byte (rediss). Prefer
    /// can't be offered — Redis doesn't negotiate — so it is plain; require
    /// encrypts without checking the certificate, verify-full checks it.
    static func tls(_ mode: DatabaseSSLMode, serverName: String) throws -> NIOSSLClientHandler? {
        switch mode {
        case .disable, .prefer: return nil
        case .require:
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            return try NIOSSLClientHandler(context: NIOSSLContext(configuration: configuration), serverHostname: nil)
        case .verifyFull:
            return try NIOSSLClientHandler(context: NIOSSLContext(configuration: .makeClientConfiguration()), serverHostname: serverName)
        }
    }

    func close() async { await drop() }

    private func drop() async {
        try? await channel?.close().get()
        channel = nil
        replies = nil
    }

    private func select(_ db: Int) async throws {
        guard db != selected else { return }
        if case .error(let message) = try await send(["SELECT", String(db)]) { throw DatabaseError.failed(message) }
        selected = db
    }

    private func send(_ arguments: [String]) async throws -> RedisValue {
        try await sendAll([arguments])[0]
    }

    /// Commands written together, their replies in order: a page of keys'
    /// types costs one round trip, not a thousand.
    private func sendAll(_ commands: [[String]]) async throws -> [RedisValue] {
        guard let channel, let replies else { throw DatabaseError.notConnected }
        let promises = commands.map { _ in channel.eventLoop.makePromise(of: RedisValue.self) }
        var bytes = Data()
        for command in commands { bytes.append(RedisProtocol.encode(command)) }
        channel.eventLoop.execute {
            for promise in promises { replies.expect(promise) }
            channel.writeAndFlush(channel.allocator.buffer(bytes: bytes), promise: nil)
        }
        var values: [RedisValue] = []
        for promise in promises { values.append(try await promise.futureResult.get()) }
        return values
    }

    /// A command on a database (nil: the console's), for the key browser
    /// and the server's page.
    func command(_ arguments: [String], db: Int? = nil) async throws -> RedisValue {
        try await pipeline([arguments], db: db)[0]
    }

    func pipeline(_ commands: [[String]], db: Int? = nil) async throws -> [RedisValue] {
        if channel == nil { try await connect() }
        return try await exclusive {
            try await select(db ?? current)
            return try await sendAll(commands)
        }
    }

    func execute(_ command: String, limit: Int) async throws -> QueryResult {
        if channel == nil { try await connect() }
        let started = Date()
        let words: [String]
        do {
            words = try RedisProtocol.words(command)
        } catch {
            throw DatabaseError.failed("Couldn't read the command: \(error)")
        }
        guard let first = words.first?.uppercased() else { throw DatabaseError.failed("No command.") }
        if ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR"].contains(first) {
            throw DatabaseError.failed("\(first) doesn't return — it listens. The server's page has Pub/Sub and the Profiler for it.")
        }
        var result: QueryResult = try await exclusive {
            try await select(current)
            if first == "VIEW" {
                guard words.count == 2 else { throw DatabaseError.failed("VIEW takes one key: VIEW user:1") }
                return try await view(words[1], limit: limit)
            }
            let reply = try await send(words)
            if first == "SELECT", case .simple = reply {
                current = Self.database(words.count > 1 ? words[1] : "0")
                selected = current
            }
            return try RedisResult.result(of: words, reply: reply, limit: limit)
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// A key's value, read as its type asks — and what it is, said.
    private func view(_ key: String, limit: Int) async throws -> QueryResult {
        let head = try await sendAll([["TYPE", key], ["TTL", key]])
        guard case .simple(let type) = head[0] else { throw DatabaseError.failed(head[0].text ?? "Couldn't read the key's type.") }
        let ttl = RedisKeyInfo.ttlText(head[1])
        guard let command = RedisKeyInfo.readCommand(type: type, key: key, limit: limit) else {
            if type == "none" { return QueryResult(message: "No key \(key) in db\(current).") }
            return QueryResult(message: "\(key) is a \(type), which Overterm doesn't read — try its own commands.")
        }
        var result = try RedisResult.result(of: command, reply: try await send(command), limit: limit)
        result.message = "\(type) · \(ttl)"
        return result
    }

    /// The databases that have keys — and the one connected to, keys or not.
    func schemas() async throws -> [String] {
        var databases: Set<Int> = [current]
        if case .bulk(let data?) = try await command(["INFO", "keyspace"]) {
            for entry in RedisResult.keyspace(RedisValue.string(data)) where entry.keys > 0 { databases.insert(entry.db) }
        }
        return databases.sorted().map { "db\($0)" }
    }

    /// A database's keys, by SCAN — at most `keyLimit`, sorted.
    func tables(in schema: String) async throws -> [CatalogTable] {
        let db = Self.database(schema)
        var keys: [String] = []
        var cursor = "0"
        repeat {
            let page = try await scan(db: db, cursor: cursor, pattern: "*", count: 500)
            cursor = page.cursor
            keys += page.keys
        } while cursor != "0" && keys.count < Self.keyLimit
        return keys.prefix(Self.keyLimit).sorted().map { CatalogTable(schema: schema, name: $0) }
    }

    /// One SCAN step: the keys it found and where the next starts ("0": done).
    func scan(db: Int, cursor: String, pattern: String, count: Int, type: String? = nil) async throws -> (keys: [String], cursor: String) {
        var command = ["SCAN", cursor, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", String(count)]
        if let type { command += ["TYPE", type] }
        let reply = try await self.command(command, db: db)
        if case .error(let message) = reply { throw DatabaseError.failed(message) }
        guard case .array(let parts?) = reply, parts.count == 2, case .array(let found?) = parts[1] else { return ([], "0") }
        return (found.compactMap(\.text), parts[0].text ?? "0")
    }

    func columns(in schema: String) async throws -> [CatalogColumn] { [] }

    // MARK: Listening

    /// Another connection to the same server — through the same tunnel,
    /// with the same password — for a listener to take over.
    func listener() -> RedisDriver {
        RedisDriver(config, password: password)
    }

    /// A connection of its own that only listens — SUBSCRIBE and MONITOR
    /// take theirs over — each message handed to `onMessage` on its event
    /// loop's thread.
    func listen(_ commands: [[String]], onMessage: @escaping @Sendable (RedisValue) -> Void) async throws {
        let handler = RedisReplyHandler()
        try await exclusive { try await open(handler: handler) }
        guard let channel else { throw DatabaseError.notConnected }
        var bytes = Data()
        for command in commands { bytes.append(RedisProtocol.encode(command)) }
        try await channel.eventLoop.submit {
            handler.onPush = onMessage
            channel.writeAndFlush(channel.allocator.buffer(bytes: bytes), promise: nil)
        }.get()
    }

    /// More for a listening connection: another channel, or UNSUBSCRIBE.
    func tell(_ command: [String]) async throws {
        guard let channel else { throw DatabaseError.notConnected }
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: RedisProtocol.encode(command))).get()
    }
}

/// What a key is, and how each type's value is read.
enum RedisKeyInfo {
    static func ttlText(_ value: RedisValue) -> String {
        guard case .integer(let seconds) = value else { return "" }
        return seconds < 0 ? "no expiry" : "expires in \(duration(seconds))"
    }

    /// Seconds as a person reads them: 45 s, 12 min, 3 h 20 min, 2 d 4 h.
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" + (seconds % 3600 >= 60 ? " \(seconds % 3600 / 60) min" : "") }
        return "\(seconds / 86400) d" + (seconds % 86400 >= 3600 ? " \(seconds % 86400 / 3600) h" : "")
    }

    /// The command that reads a key of this type, nil for one Overterm doesn't read.
    static func readCommand(type: String, key: String, limit: Int) -> [String]? {
        switch type {
        case "string": ["GET", key]
        case "hash": ["HGETALL", key]
        case "list": ["LRANGE", key, "0", String(max(0, limit - 1))]
        case "set": ["SSCAN", key, "0", "COUNT", String(limit)]
        case "zset": ["ZRANGE", key, "0", String(max(0, limit - 1)), "WITHSCORES"]
        case "stream": ["XRANGE", key, "-", "+", "COUNT", String(limit)]
        case "ReJSON-RL": ["JSON.GET", key]
        default: nil
        }
    }
}

/// The pipeline's end: bytes in, one RESP value out per command sent, in
/// order. Touched only on its channel's event loop.
final class RedisReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var bytes: [UInt8] = []
    private var waiting: [EventLoopPromise<RedisValue>] = []
    /// A listening connection's: every value, as it comes.
    var onPush: (@Sendable (RedisValue) -> Void)?

    func expect(_ promise: EventLoopPromise<RedisValue>) { waiting.append(promise) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
        do {
            while let (value, used) = try RedisProtocol.decode(bytes) {
                bytes.removeFirst(used)
                if !waiting.isEmpty {
                    waiting.removeFirst().succeed(value)
                } else {
                    onPush?(value)
                }
            }
        } catch {
            fail(DatabaseError.failed("Redis answered something that isn't RESP: \(error)"))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(DatabaseError.failed("Redis closed the connection."))
        context.fireChannelInactive()
    }

    private func fail(_ error: Error) {
        let pending = waiting
        waiting = []
        for promise in pending { promise.fail(error) }
    }
}
