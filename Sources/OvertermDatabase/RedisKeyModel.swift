import Foundation

/// The right-hand pane's Redis page: a key (its value as its type has it,
/// edited in place), a new key being made, or the server's page.
@MainActor
package final class RedisSlotModel: ObservableObject {
    package init() {}

    package enum Page: Equatable { case none, key, newKey, server }

    @Published package var page = Page.none
    package let key = RedisKeyModel()
    package let server = RedisServerModel()

    /// Read only while the pane shows it.
    package var visible = false {
        didSet {
            key.visible = visible && page == .key
            server.visible = visible && page == .server
        }
    }

    @Published package private(set) var newKeyDB = 0
    package private(set) var newKeySession: DatabaseSession?

    package func newKey(in session: DatabaseSession, db: Int) {
        newKeySession = session
        newKeyDB = db
        show(.newKey)
    }

    package func show(_ page: Page) {
        self.page = page
        key.visible = visible && page == .key
        server.visible = visible && page == .server
    }
}

/// One key, read as its type asks, a page at a time.
@MainActor
package final class RedisKeyModel: ObservableObject {
    package enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// One row of a collection: a hash's field and value, a list's index
    /// and value, a set's member, a sorted set's member and score, a
    /// stream's id and fields.
    package struct Row: Equatable, Identifiable {
        package var id: String
        package var cells: [String]
    }

    @Published package private(set) var phase = Phase.idle
    package private(set) var session: DatabaseSession?
    @Published package private(set) var db = 0
    @Published package private(set) var name = ""
    @Published package private(set) var type = ""
    /// Seconds; -1 no expiry.
    @Published package private(set) var ttl = -1
    @Published package private(set) var memory: Int?
    @Published package private(set) var encoding: String?
    @Published package private(set) var length: Int?
    /// A string's or a JSON document's text.
    @Published package var text = ""
    @Published package private(set) var savedText = ""
    @Published package private(set) var rows: [Row] = []
    /// A sorted set's, a set's or a hash's MATCH; the stream's and the
    /// list's are positions.
    @Published package var filter = ""
    @Published package private(set) var hasMore = false
    @Published package private(set) var groups: [[String: String]] = []
    /// What the last edit said, when it failed.
    @Published package var error: String?
    private var cursor = "0"
    private var ticket = 0

    package static let page = 200
    /// A string longer than this is shown cut, and not edited here.
    package static let textLimit = 512 * 1024

    package var visible = false {
        didSet { if visible, !oldValue, phase == .loading { Task { await load() } } }
    }

    package var readOnly: Bool { session?.connection.readOnly ?? true }
    package var driver: RedisDriver? { session?.redis }

    package var columns: [String] {
        switch type {
        case "hash": ["Field", "Value"]
        case "list": ["Index", "Element"]
        case "set": ["Member"]
        case "zset": ["Member", "Score"]
        case "stream": ["Entry ID", "Fields"]
        default: []
        }
    }

    package var isText: Bool { type == "string" || type == "ReJSON-RL" }
    package var textTooLong: Bool { (length ?? 0) > Self.textLimit }

    package func show(_ name: String, db: Int, session: DatabaseSession) {
        self.session = session
        self.db = db
        self.name = name
        type = ""
        rows = []
        text = ""
        savedText = ""
        filter = ""
        groups = []
        error = nil
        memory = nil
        encoding = nil
        length = nil
        phase = .loading
        ticket += 1
        if visible { Task { await load() } }
    }

    package func reload() {
        guard let session else { return }
        let filter = filter
        show(name, db: db, session: session)
        self.filter = filter
    }

    package func load() async {
        guard let driver else { return }
        // A newer read wins: two at once appended each page twice.
        ticket += 1
        let ticket = self.ticket
        do {
            let head = try await driver.pipeline(
                [["TYPE", name], ["TTL", name], ["MEMORY", "USAGE", name], ["OBJECT", "ENCODING", name]], db: db)
            guard ticket == self.ticket else { return }
            type = head[0].text ?? "none"
            if type == "none" {
                phase = .failed("No key “\(name)” in db\(db) — it was deleted, or it expired.")
                return
            }
            if case .integer(let seconds) = head[1] { ttl = seconds }
            if case .integer(let bytes) = head[2] { memory = bytes }
            if case .bulk(let data?) = head[3] { encoding = RedisValue.string(data) }
            if let count = Self.lengthCommand(type, name), case .integer(let n) = try await driver.command(count, db: db) { length = n }
            guard ticket == self.ticket else { return }
            cursor = "0"
            rows = []
            try await page(ticket)
            if type == "stream", case .array(let items?) = try await driver.command(["XINFO", "GROUPS", name], db: db) {
                groups = items.map(Self.fields)
            }
            guard ticket == self.ticket else { return }
            phase = .loaded
        } catch {
            guard ticket == self.ticket else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    package static func lengthCommand(_ type: String, _ key: String) -> [String]? {
        switch type {
        case "string": ["STRLEN", key]
        case "hash": ["HLEN", key]
        case "list": ["LLEN", key]
        case "set": ["SCARD", key]
        case "zset": ["ZCARD", key]
        case "stream": ["XLEN", key]
        default: nil
        }
    }

    /// A reply's `field value field value…` as a dictionary.
    package static func fields(_ value: RedisValue) -> [String: String] {
        guard case .array(let items?) = value else { return [:] }
        var out: [String: String] = [:]
        for index in stride(from: 0, to: items.count - 1, by: 2) {
            if let key = items[index].text { out[key] = items[index + 1].text ?? "" }
        }
        return out
    }

    package func more() async {
        guard hasMore else { return }
        do {
            try await page(ticket)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The filter changed: from the start.
    package func applyFilter() async {
        cursor = "0"
        rows = []
        do {
            try await page(ticket)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The next page of the value, as its type reads.
    private func page(_ ticket: Int) async throws {
        guard let driver else { return }
        let match = filter.isEmpty ? "*" : (filter.contains("*") || filter.contains("?") ? filter : "*\(filter)*")
        switch type {
        case "string":
            let reply = try await driver.command(
                textTooLong ? ["GETRANGE", name, "0", String(Self.textLimit - 1)] : ["GET", name], db: db)
            guard ticket == self.ticket else { return }
            if case .error(let message) = reply { throw DatabaseError.failed(message) }
            text = reply.text ?? ""
            savedText = text
            hasMore = false
        case "ReJSON-RL":
            let reply = try await driver.command(["JSON.GET", name], db: db)
            guard ticket == self.ticket else { return }
            if case .error(let message) = reply { throw DatabaseError.failed(message) }
            text = Self.pretty(reply.text ?? "")
            savedText = text
            hasMore = false
        case "hash", "set",
            "zset" where !(type == "zset" && filter.isEmpty):
            let verb = type == "hash" ? "HSCAN" : type == "set" ? "SSCAN" : "ZSCAN"
            var found: [Row] = []
            var steps = 0
            repeat {
                let reply = try await driver.command([verb, name, cursor, "MATCH", match, "COUNT", "500"], db: db)
                if case .error(let message) = reply { throw DatabaseError.failed(message) }
                guard case .array(let parts?) = reply, parts.count == 2, case .array(let items?) = parts[1] else { break }
                cursor = parts[0].text ?? "0"
                if type == "set" {
                    found += items.compactMap(\.text).map { Row(id: $0, cells: [$0]) }
                } else {
                    for index in stride(from: 0, to: items.count - 1, by: 2) {
                        let key = items[index].text ?? ""
                        found.append(Row(id: key, cells: [key, items[index + 1].text ?? ""]))
                    }
                }
                steps += 1
            } while cursor != "0" && found.count < Self.page && steps < 100
            guard ticket == self.ticket else { return }
            let known = Set(rows.map(\.id))
            rows += found.filter { !known.contains($0.id) }
            hasMore = cursor != "0"
        case "zset":
            let start = rows.count
            let reply = try await driver.command(["ZRANGE", name, String(start), String(start + Self.page - 1), "WITHSCORES"], db: db)
            guard ticket == self.ticket else { return }
            guard case .array(let items?) = reply else { throw DatabaseError.failed(reply.text ?? "Couldn't read the sorted set.") }
            for index in stride(from: 0, to: items.count - 1, by: 2) {
                let member = items[index].text ?? ""
                rows.append(Row(id: member, cells: [member, items[index + 1].text ?? ""]))
            }
            hasMore = rows.count < (length ?? 0)
        case "list":
            let start = rows.count
            let reply = try await driver.command(["LRANGE", name, String(start), String(start + Self.page - 1)], db: db)
            guard ticket == self.ticket else { return }
            guard case .array(let items?) = reply else { throw DatabaseError.failed(reply.text ?? "Couldn't read the list.") }
            for (offset, item) in items.enumerated() {
                rows.append(Row(id: String(start + offset), cells: [String(start + offset), item.text ?? ""]))
            }
            hasMore = rows.count < (length ?? 0)
        case "stream":
            // Newest first, as Insight shows a stream.
            let end = rows.last.map { "(" + $0.id } ?? "+"
            let reply = try await driver.command(["XREVRANGE", name, end, "-", "COUNT", String(Self.page)], db: db)
            guard ticket == self.ticket else { return }
            guard case .array(let items?) = reply else { throw DatabaseError.failed(reply.text ?? "Couldn't read the stream.") }
            for item in items {
                let entry = RedisResult.streamEntry(item)
                rows.append(Row(id: entry[0] ?? "", cells: [entry[0] ?? "", entry[1] ?? ""]))
            }
            hasMore = items.count == Self.page
        default:
            hasMore = false
        }
    }

    /// JSON laid out, if it is JSON; else as it came.
    package static func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return text }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Editing

    /// Runs commands on the key's database; the first error is the edit's.
    @discardableResult
    private func run(_ commands: [[String]]) async -> Bool {
        guard let driver, !readOnly else { return false }
        do {
            for reply in try await driver.pipeline(commands, db: db) {
                if case .error(let message) = reply {
                    error = message
                    return false
                }
            }
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    package func saveText() async {
        let command =
            type == "ReJSON-RL"
            ? ["JSON.SET", name, "$", text]
            // KEEPTTL: an edit doesn't take a key's expiry away.
            : ["SET", name, text, "KEEPTTL"]
        if type == "ReJSON-RL", (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) == nil {
            error = "That isn't JSON."
            return
        }
        if await run([command]) {
            savedText = text
            length = text.utf8.count
        }
    }

    /// A row's value changed: a hash field's value, a list element, a
    /// member's score — or, for a set, the member itself.
    package func update(_ row: Row, to value: String) async {
        let commands: [[String]]
        switch type {
        case "hash": commands = [["HSET", name, row.cells[0], value]]
        case "list": commands = [["LSET", name, row.cells[0], value]]
        case "zset":
            guard Double(value) != nil else {
                error = "A score is a number."
                return
            }
            commands = [["ZADD", name, value, row.cells[0]]]
        case "set":
            commands = [["SREM", name, row.cells[0]], ["SADD", name, value]]
        default: return
        }
        guard await run(commands) else { return }
        if let index = rows.firstIndex(of: row) {
            switch type {
            case "set": rows[index] = Row(id: value, cells: [value])
            default: rows[index].cells[1] = value
            }
        }
    }

    /// A new field, element, member or entry. `values` as the type takes
    /// them: field+value, element (+ "head"), member, member+score, or a
    /// stream's field=value pairs.
    package func add(_ values: [String], atHead: Bool = false) async {
        let command: [String]
        switch type {
        case "hash": command = ["HSET", name] + values
        case "list": command = [atHead ? "LPUSH" : "RPUSH", name] + values
        case "set": command = ["SADD", name] + values
        case "zset":
            guard values.count == 2, Double(values[1]) != nil else {
                error = "A score is a number."
                return
            }
            command = ["ZADD", name, values[1], values[0]]
        case "stream": command = ["XADD", name, "*"] + values
        default: return
        }
        guard await run([command]) else { return }
        reload()
    }

    package func remove(_ row: Row) async {
        let commands: [[String]]
        switch type {
        case "hash": commands = [["HDEL", name, row.cells[0]]]
        case "set": commands = [["SREM", name, row.cells[0]]]
        case "zset": commands = [["ZREM", name, row.cells[0]]]
        case "stream": commands = [["XDEL", name, row.cells[0]]]
        case "list":
            // A list has no "remove at": the element is marked, then the mark removed.
            let mark = "__overterm_removed_\(UUID().uuidString)__"
            commands = [["LSET", name, row.cells[0], mark], ["LREM", name, "1", mark]]
        default: return
        }
        guard await run(commands) else { return }
        if type == "list" {
            reload()
        } else {
            rows.removeAll { $0 == row }
            length = length.map { max(0, $0 - 1) }
        }
    }

    /// -1: no expiry.
    package func setTTL(_ seconds: Int) async {
        guard await run([seconds < 0 ? ["PERSIST", name] : ["EXPIRE", name, String(seconds)]]) else { return }
        ttl = seconds < 0 ? -1 : seconds
    }

    /// RENAMENX: never over a key that is there.
    package func rename(to newName: String) async -> Bool {
        guard let driver, !readOnly, !newName.isEmpty, newName != name else { return false }
        do {
            let reply = try await driver.command(["RENAMENX", name, newName], db: db)
            switch reply {
            case .error(let message):
                error = message
                return false
            case .integer(0):
                error = "There is already a key “\(newName)”."
                return false
            default:
                error = nil
                name = newName
                return true
            }
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    package func delete() async -> Bool {
        await run([["UNLINK", name]])
    }

    /// A new key: refused when one of that name is there. `values` as `add`
    /// takes them; a string's or a JSON's whole text first.
    package static func create(
        _ name: String, type: String, values: [String], ttl: Int?, db: Int, driver: RedisDriver
    ) async throws {
        guard !name.isEmpty else { throw DatabaseError.failed("A key needs a name.") }
        if case .integer(let n) = try await driver.command(["EXISTS", name], db: db), n > 0 {
            throw DatabaseError.failed("There is already a key “\(name)”.")
        }
        var command: [String]
        switch type {
        case "string": command = ["SET", name, values.first ?? ""]
        case "hash": command = ["HSET", name] + values
        case "list": command = ["RPUSH", name] + values
        case "set": command = ["SADD", name] + values
        case "zset":
            guard values.count == 2, Double(values[1]) != nil else { throw DatabaseError.failed("A sorted set's first member needs a numeric score.") }
            command = ["ZADD", name, values[1], values[0]]
        case "stream": command = ["XADD", name, "*"] + values
        case "ReJSON-RL": command = ["JSON.SET", name, "$", values.first ?? "{}"]
        default: throw DatabaseError.failed("Overterm doesn't make a \(type).")
        }
        if command.count < 3 { throw DatabaseError.failed("A \(RedisKeyType.label(type).lowercased()) needs a first value.") }
        var commands = [command]
        if let ttl, ttl > 0 { commands.append(["EXPIRE", name, String(ttl)]) }
        for reply in try await driver.pipeline(commands, db: db) {
            if case .error(let message) = reply { throw DatabaseError.failed(message) }
        }
    }
}

/// The server's page: what INFO says (read again every few seconds while
/// it shows), the slow log, the clients, Pub/Sub and the Profiler.
@MainActor
package final class RedisServerModel: ObservableObject {
    package enum Tab: String, CaseIterable {
        case overview = "Overview"
        case slowlog = "Slow Log"
        case clients = "Clients"
        case pubsub = "Pub/Sub"
        case profiler = "Profiler"
    }

    package struct Message: Identifiable, Equatable {
        package let id = UUID()
        package var date: Date
        package var channel: String
        package var text: String
    }

    @Published package var tab = Tab.overview
    package private(set) var session: DatabaseSession?
    @Published package private(set) var info = RedisInfo()
    @Published package private(set) var slowlog: [RedisSlowEntry] = []
    @Published package private(set) var clients: [[String: String]] = []
    @Published package private(set) var error: String?
    @Published package private(set) var updated: Date?
    /// CONFIG's slowlog-log-slower-than, µs — nil where CONFIG is refused (managed servers).
    @Published package private(set) var slowerThan: Int?
    private var refresher: Task<Void, Never>?

    // Pub/Sub
    @Published package var channels = "*"
    @Published package private(set) var subscribed: String?
    @Published package private(set) var messages: [Message] = []
    private var subscriber: RedisDriver?
    // Profiler
    @Published package private(set) var monitoring = false
    @Published package private(set) var commands: [Message] = []
    private var monitor: RedisDriver?

    /// Messages and commands kept at most: the oldest go.
    package static let keep = 2000

    package var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible { startRefreshing() } else { refresher?.cancel() }
        }
    }

    package var name: String { session?.connection.name ?? "" }

    package func show(_ session: DatabaseSession) {
        if self.session?.id != session.id {
            stopListening()
            info = RedisInfo()
            slowlog = []
            clients = []
            messages = []
            commands = []
        }
        self.session = session
        if visible { startRefreshing() }
    }

    private func startRefreshing() {
        refresher?.cancel()
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    package func refresh() async {
        guard let driver = session?.redis else {
            if let session { await session.open() }
            if session?.redis == nil {
                error = "Not connected."
                return
            }
            return await refresh()
        }
        do {
            let replies = try await driver.pipeline([
                ["INFO", "everything"], ["SLOWLOG", "GET", "128"], ["CLIENT", "LIST"], ["CONFIG", "GET", "slowlog-log-slower-than"],
            ])
            if case .array(let pair?) = replies[3], pair.count == 2 { slowerThan = pair[1].text.flatMap(Int.init) }
            if case .bulk(let data?) = replies[0] {
                info = RedisInfo(RedisValue.string(data))
            } else if case .error(let message) = replies[0] {
                // INFO everything is 7.0's; older servers take INFO.
                if case .bulk(let data?) = try await driver.command(["INFO"]) { info = RedisInfo(RedisValue.string(data)) } else { error = message }
            }
            slowlog = RedisSlowEntry.parse(replies[1])
            if case .bulk(let data?) = replies[2] { clients = RedisClients.parse(RedisValue.string(data)) }
            updated = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    package func resetSlowlog() async {
        guard let driver = session?.redis, session?.connection.readOnly == false else { return }
        _ = try? await driver.command(["SLOWLOG", "RESET"])
        await refresh()
    }

    package func kill(client id: String) async {
        guard let driver = session?.redis, session?.connection.readOnly == false else { return }
        if case .error(let message) = (try? await driver.command(["CLIENT", "KILL", "ID", id])) ?? .simple("") { error = message }
        await refresh()
    }

    // MARK: Pub/Sub

    /// Subscribes to channels — patterns, space-separated — on a connection
    /// of its own, the messages listed as they come.
    package func subscribe() async {
        guard let driver = session?.redis else { return }
        stopSubscriber()
        let patterns = channels.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return }
        let listener = await driver.listener()
        subscriber = listener
        subscribed = patterns.joined(separator: " ")
        do {
            try await listener.listen([["PSUBSCRIBE"] + patterns]) { [weak self] value in
                guard let message = Self.pubsubMessage(value) else { return }
                Task { @MainActor in self?.received(message) }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            stopSubscriber()
        }
    }

    /// A pushed `pmessage pattern channel text` (or `message channel text`).
    package nonisolated static func pubsubMessage(_ value: RedisValue) -> Message? {
        guard case .array(let parts?) = value, let kind = parts.first?.text else { return nil }
        if kind == "pmessage", parts.count == 4 { return Message(date: Date(), channel: parts[2].text ?? "", text: parts[3].text ?? "") }
        if kind == "message", parts.count == 3 { return Message(date: Date(), channel: parts[1].text ?? "", text: parts[2].text ?? "") }
        return nil
    }

    private func received(_ message: Message) {
        messages.insert(message, at: 0)
        if messages.count > Self.keep { messages.removeLast(messages.count - Self.keep) }
    }

    package func stopSubscriber() {
        if let subscriber { Task { await subscriber.close() } }
        subscriber = nil
        subscribed = nil
    }

    package func publish(_ channel: String, _ message: String) async -> Int? {
        guard let driver = session?.redis, !channel.isEmpty else { return nil }
        do {
            let reply = try await driver.command(["PUBLISH", channel, message])
            if case .error(let message) = reply {
                error = message
                return nil
            }
            if case .integer(let n) = reply { return n }
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }

    package func clearMessages() { messages = [] }

    // MARK: Profiler

    /// MONITOR on a connection of its own: every command the server runs,
    /// as it runs it. It costs the server — so it stops when asked, when the
    /// page goes, and after `keep` commands.
    package func startMonitor() async {
        guard let driver = session?.redis else { return }
        stopMonitor()
        let listener = await driver.listener()
        monitor = listener
        monitoring = true
        do {
            try await listener.listen([["MONITOR"]]) { [weak self] value in
                guard case .simple(let line) = value, line != "OK" else { return }
                Task { @MainActor in self?.monitored(line) }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            stopMonitor()
        }
    }

    private func monitored(_ line: String) {
        guard monitoring else { return }
        // `1700000000.123456 [0 127.0.0.1:5000] "GET" "a"`
        let parts = line.split(separator: " ", maxSplits: 1)
        let date = Double(parts.first ?? "").map { Date(timeIntervalSince1970: $0) } ?? Date()
        commands.insert(Message(date: date, channel: "", text: parts.count > 1 ? String(parts[1]) : line), at: 0)
        if commands.count >= Self.keep { stopMonitor() }
    }

    package func stopMonitor() {
        if let monitor { Task { await monitor.close() } }
        monitor = nil
        monitoring = false
    }

    package func clearCommands() { commands = [] }

    package func stopListening() {
        stopSubscriber()
        stopMonitor()
    }
}
