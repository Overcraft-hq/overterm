import Foundation

/// One database's keys in the panel: SCANned a page at a time — never KEYS,
/// which stops the server — filtered on the server by a pattern and a type,
/// each key's type read in the same round trip, and laid out as folders.
@MainActor
package final class RedisBrowser: ObservableObject {
    package let db: Int
    private weak var session: DatabaseSession?

    @Published package var pattern = ""
    /// nil: every type.
    @Published package var type: String?
    @Published package private(set) var keys: [RedisKeyEntry] = []
    @Published package private(set) var tree = RedisKeyTree([])
    /// Where the next page starts; "0" once the scan has gone round.
    @Published package private(set) var cursor = "0"
    @Published package private(set) var scanned = false
    @Published package private(set) var isScanning = false
    @Published package private(set) var error: String?
    /// DBSIZE: how many keys the database has, matched or not.
    @Published package private(set) var total: Int?
    private var ticket = 0

    /// Keys a page brings at most.
    package static let page = 500

    package init(db: Int, session: DatabaseSession) {
        self.db = db
        self.session = session
    }

    package var hasMore: Bool { scanned && cursor != "0" }

    /// From the start: a new pattern or type, or Refresh.
    package func scan() async {
        ticket += 1
        keys = []
        tree = RedisKeyTree([])
        cursor = "0"
        scanned = false
        await more()
    }

    /// The next page: SCAN until it found a page of keys or went round.
    package func more() async {
        guard let driver = session?.redis, !isScanning, !(scanned && cursor == "0") else { return }
        let ticket = self.ticket
        isScanning = true
        defer { if ticket == self.ticket { isScanning = false } }
        do {
            var found: [String] = []
            var next = cursor
            var steps = 0
            // A sparse match walks many empty steps; a bound keeps one click
            // from walking a hundred million keys.
            repeat {
                let step = try await driver.scan(db: db, cursor: next, pattern: pattern, count: 1000, type: type)
                found += step.keys
                next = step.cursor
                steps += 1
            } while next != "0" && found.count < Self.page && steps < 200
            let types = try await driver.pipeline(found.map { ["TYPE", $0] }, db: db)
            let size = try await driver.command(["DBSIZE"], db: db)
            guard ticket == self.ticket else { return }
            let known = Set(keys.map(\.name))
            // SCAN may say a key twice.
            let fresh = zip(found, types).compactMap { name, type in
                known.contains(name) ? nil : RedisKeyEntry(name: name, type: type.text ?? "none")
            }
            keys += fresh
            tree = RedisKeyTree(keys, delimiter: session?.connection.redisDelimiter ?? ":")
            cursor = next
            scanned = true
            if case .integer(let n) = size { total = n }
            error = nil
        } catch {
            guard ticket == self.ticket else { return }
            self.error = error.localizedDescription
            scanned = true
            cursor = "0"
        }
    }

    /// A key made or renamed here: in the list without a scan.
    package func added(_ entry: RedisKeyEntry) {
        guard !keys.contains(where: { $0.name == entry.name }) else { return }
        keys.append(entry)
        tree = RedisKeyTree(keys, delimiter: session?.connection.redisDelimiter ?? ":")
        total = total.map { $0 + 1 }
    }

    package func removed(_ name: String) {
        guard keys.contains(where: { $0.name == name }) else { return }
        keys.removeAll { $0.name == name }
        tree = RedisKeyTree(keys, delimiter: session?.connection.redisDelimiter ?? ":")
        total = total.map { max(0, $0 - 1) }
    }
}

extension DatabaseConnection {
    /// What separates a key's folders in the browser: `:`, as Redis
    /// Insight has it.
    package var redisDelimiter: String { ":" }
}
