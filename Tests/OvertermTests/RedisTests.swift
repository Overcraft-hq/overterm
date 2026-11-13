import XCTest

@testable import Overterm

/// Redis as the database client reads it: RESP, a console's lines, what
/// reads and what destroys, a reply as rows, keys as folders — pure.
final class RedisTextTests: XCTestCase {
    func testRESPRoundTrips() throws {
        XCTAssertEqual(String(decoding: RedisProtocol.encode(["SET", "k", "a b"]), as: UTF8.self), "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\na b\r\n")
        let reply = Array("*3\r\n+OK\r\n:42\r\n$-1\r\n".utf8)
        let (value, used) = try XCTUnwrap(RedisProtocol.decode(reply))
        XCTAssertEqual(value, .array([.simple("OK"), .integer(42), .bulk(nil)]))
        XCTAssertEqual(used, reply.count)
        // Arrived in part: nothing yet, not a mistake.
        XCTAssertNil(try RedisProtocol.decode(Array("$5\r\nhel".utf8)))
        XCTAssertNil(try RedisProtocol.decode(Array("*2\r\n:1\r\n".utf8)))
        XCTAssertEqual(try RedisProtocol.decode(Array("-ERR nope\r\n".utf8))?.0, .error("ERR nope"))
        XCTAssertThrowsError(try RedisProtocol.decode(Array("?x\r\n".utf8)))
        XCTAssertEqual(RedisValue.string(Data([0x61, 0xFF])), "a\\xff", "bytes that aren't UTF-8, as redis-cli escapes them")
    }

    func testALineSplitsAsRedisCLISplitsIt() throws {
        XCTAssertEqual(try RedisProtocol.words(#"SET "user:1" "a \"b\"\n" 'it\'s'"#), ["SET", "user:1", "a \"b\"\n", "it's"])
        XCTAssertEqual(try RedisProtocol.words("  GET   k  "), ["GET", "k"])
        XCTAssertThrowsError(try RedisProtocol.words(#"GET "k"#))
        XCTAssertEqual(RedisProtocol.quoted("user:1"), "user:1")
        XCTAssertEqual(RedisProtocol.quoted("a b"), "\"a b\"")
    }

    func testAConsoleIsALineACommand() {
        let text = "GET a\n\n# a note\nHGETALL b\n"
        let ns = text as NSString
        XCTAssertEqual(DatabaseKind.redis.statements(in: text).map { ns.substring(with: $0).trimmingCharacters(in: .newlines) }, ["GET a", "HGETALL b"])
        XCTAssertEqual(DatabaseKind.redis.statement(at: 2, in: text).map { ns.substring(with: $0) }, "GET a")
        XCTAssertNil(DatabaseKind.redis.statement(at: 8, in: text), "a comment runs nothing")
        // SQL keeps its semicolons.
        XCTAssertEqual(DatabaseKind.postgres.statements(in: "SELECT 1; SELECT 2;").count, 2)
    }

    func testWhatReadsAndWhatDestroys() {
        XCTAssertEqual(RedisText.verb(of: "config get maxmemory"), "CONFIG GET")
        XCTAssertTrue(DatabaseKind.redis.onlyReads("HGETALL user:1"))
        XCTAssertTrue(DatabaseKind.redis.onlyReads("VIEW user:1"))
        XCTAssertFalse(DatabaseKind.redis.onlyReads("SET a 1"))
        XCTAssertFalse(DatabaseKind.redis.onlyReads("CONFIG SET maxmemory 1"))
        XCTAssertFalse(DatabaseKind.redis.agentReads("DEL a"))
        XCTAssertNotNil(DatabaseKind.redis.danger(of: "FLUSHALL"))
        XCTAssertEqual(DatabaseKind.redis.danger(of: "DEL a b"), "DEL deletes 2 keys for good.")
        XCTAssertNotNil(DatabaseKind.redis.danger(of: "keys *"), "KEYS blocks the server")
        XCTAssertNil(DatabaseKind.redis.danger(of: "SET a 1"))
        XCTAssertEqual(DatabaseKind.redis.subject(of: "HGETALL user:1"), "user:1")
        XCTAssertEqual(DatabaseKind.redis.subject(of: "OBJECT ENCODING user:1"), "user:1")
    }

    func testRepliesAsRows() throws {
        let hash = try RedisResult.result(of: ["HGETALL", "u"], reply: .array([.bulk(Data("name".utf8)), .bulk(Data("Ada".utf8))]), limit: 10)
        XCTAssertEqual(hash.columns, ["field", "value"])
        XCTAssertEqual(hash.rows, [["name", "Ada"]])
        let zset = try RedisResult.result(
            of: ["ZRANGE", "z", "0", "-1", "WITHSCORES"], reply: .array([.bulk(Data("a".utf8)), .bulk(Data("1".utf8))]), limit: 10)
        XCTAssertEqual(zset.columns, ["member", "score"])
        let scan = try RedisResult.result(of: ["SCAN", "0"], reply: .array([.bulk(Data("17".utf8)), .array([.bulk(Data("k".utf8))])]), limit: 10)
        XCTAssertEqual(scan.rows, [["k"]])
        XCTAssertTrue(scan.message?.contains("17") == true, "the cursor to go on from")
        let list = try RedisResult.result(of: ["LRANGE", "l", "0", "-1"], reply: .array([.bulk(Data("x".utf8)), .bulk(Data("y".utf8))]), limit: 1)
        XCTAssertEqual(list.rows, [["1", "x"]])
        XCTAssertTrue(list.truncated)
        XCTAssertThrowsError(try RedisResult.result(of: ["GET"], reply: .error("ERR wrong number"), limit: 10))
        XCTAssertEqual(RedisResult.keyspace("# Keyspace\r\ndb0:keys=3,expires=1,avg_ttl=0\r\ndb4:keys=1,expires=0\r\n").map(\.db), [0, 4])
    }

    func testKeysAsFolders() {
        let keys = ["user:1:profile", "user:1:cart", "user:2", "session", "cache:a", "orders:"].map { RedisKeyEntry(name: $0, type: "string") }
        let tree = RedisKeyTree(keys)
        XCTAssertEqual(tree.root.folders.map(\.name), ["user"])
        XCTAssertEqual(tree.root.keys.map(\.name), ["cache:a", "orders:", "session"], "a folder of one key is just that key; a trailing `:` is a leaf")
        let user = tree.root.folders[0]
        XCTAssertEqual(user.prefix, "user:")
        XCTAssertEqual(user.count, 3)
        XCTAssertEqual(user.folders.map(\.prefix), ["user:1:"])
        XCTAssertEqual(user.keys.map(\.name), ["user:2"])
    }

    func testAURLFillsTheForm() throws {
        let plain = try XCTUnwrap(RedisURL("redis://app:s%40cret@cache.local:6380/3"))
        XCTAssertEqual(plain, RedisURL("redis://app:s%40cret@cache.local:6380/3"))
        XCTAssertEqual(plain.host, "cache.local")
        XCTAssertEqual(plain.port, 6380)
        XCTAssertEqual(plain.user, "app")
        XCTAssertEqual(plain.password, "s@cret")
        XCTAssertEqual(plain.database, "3")
        XCTAssertFalse(plain.tls)
        let tls = try XCTUnwrap(RedisURL("rediss://:token@db.example.com:25061"))
        XCTAssertTrue(tls.tls, "rediss is TLS")
        XCTAssertEqual(tls.user, "")
        XCTAssertEqual(tls.password, "token")
        XCTAssertNil(RedisURL("postgres://a@b/c"))
    }

    func testTheServersPageReadsINFO() {
        let info = RedisInfo(
            "# Server\r\nredis_version:7.2.4\r\nuptime_in_seconds:7300\r\n# Stats\r\nkeyspace_hits:3\r\nkeyspace_misses:1\r\n# Keyspace\r\ndb0:keys=5,expires=2\r\ndb1:keys=1,expires=0\r\n")
        XCTAssertEqual(info.version, "7.2.4")
        XCTAssertEqual(info.uptime, "2 h 1 min")
        XCTAssertEqual(info.hitRatio, 0.75)
        XCTAssertEqual(info.totalKeys, 6)
        let slow = RedisSlowEntry.parse(
            .array([.array([.integer(7), .integer(1_700_000_000), .integer(15000), .array([.bulk(Data("KEYS".utf8)), .bulk(Data("*".utf8))]), .bulk(Data("127.0.0.1:5".utf8))])]))
        XCTAssertEqual(slow.first?.command, "KEYS *")
        XCTAssertEqual(slow.first?.micros, 15000)
        XCTAssertEqual(RedisClients.parse("id=3 addr=127.0.0.1:5 name= db=0 cmd=client|list\n").first?["cmd"], "client|list")
        XCTAssertEqual(
            RedisServerModel.pubsubMessage(.array([.bulk(Data("pmessage".utf8)), .bulk(Data("news.*".utf8)), .bulk(Data("news.a".utf8)), .bulk(Data("hi".utf8))]))?.text, "hi")
    }

    func testConsoleCompletion() throws {
        let commands = try XCTUnwrap(RedisCompletion.complete("hge", keys: []))
        XCTAssertEqual(commands.typed, "hge")
        XCTAssertTrue(commands.candidates.map(\.label).contains("HGETALL"))
        let keys = try XCTUnwrap(RedisCompletion.complete("HGETALL us", keys: ["user:1", "user:2", "orders"]))
        XCTAssertEqual(keys.candidates.map(\.label), ["user:1", "user:2"])
        XCTAssertNil(RedisCompletion.complete("SELECT ", keys: ["user:1"]), "SELECT takes a number, not a key")
        XCTAssertNil(RedisCompletion.complete("HSET user:1 na", keys: ["user:1"]), "only the first argument is a key")
    }
}

/// The driver, the browser and a key's page against a real redis-server
/// of the test's own (E2ERedisServer) — plain, and over TLS. Skipped where
/// there is no redis-server.
@MainActor
final class RedisDriverTests: XCTestCase {
    private func server(tls: Bool = false) throws -> E2ERedisServer {
        guard let server = E2ERedisServer(tls: tls) else { throw XCTSkip("no redis-server on this Mac") }
        addTeardownBlock { server.stop() }
        return server
    }

    func testTheConsoleRunsCommands() async throws {
        let server = try server()
        let driver = RedisDriver(server.connection(), password: server.password)
        try await driver.connect()
        let set = try await driver.execute(#"SET greeting "hello world""#, limit: 100)
        XCTAssertEqual(set.message, "OK")
        let got = try await driver.execute("GET greeting", limit: 100)
        XCTAssertEqual(got.rows, [["hello world"]])
        _ = try await driver.execute("HSET user:1 name Ada lang Swift", limit: 100)
        let view = try await driver.execute("VIEW user:1", limit: 100)
        XCTAssertEqual(view.columns, ["field", "value"])
        XCTAssertEqual(Set(view.rows.map { $0[0] ?? "" }), ["name", "lang"])
        XCTAssertTrue(view.message?.hasPrefix("hash") == true, view.message ?? "")
        do {
            _ = try await driver.execute("HGETALL greeting", limit: 100)
            XCTFail("a wrong type is an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("WRONGTYPE"), error.localizedDescription)
        }
        // SELECT holds for the console's next command — and the catalog doesn't move it.
        _ = try await driver.execute("SELECT 2", limit: 10)
        _ = try await driver.execute("SET only-in-2 x", limit: 10)
        let schemas = try await driver.schemas()
        XCTAssertEqual(schemas, ["db0", "db2"])
        let db0 = try await driver.tables(in: "db0")
        XCTAssertEqual(Set(db0.map(\.name)), ["greeting", "user:1"])
        let after = try await driver.execute("GET only-in-2", limit: 10)
        XCTAssertEqual(after.rows, [["x"]], "still on db2 after the catalog read db0")
        do {
            _ = try await driver.execute("SUBSCRIBE news", limit: 10)
            XCTFail("a command that never returns is refused")
        } catch {}
        await driver.close()
    }

    func testAWrongPasswordIsSaid() async throws {
        let server = try server()
        let none = RedisDriver(server.connection(), password: nil)
        do {
            try await none.connect()
            XCTFail("no password, no connection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("NOAUTH"), error.localizedDescription)
        }
        let wrong = RedisDriver(server.connection(), password: "nope")
        do {
            try await wrong.connect()
            XCTFail("a wrong password, no connection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("WRONGPASS") || error.localizedDescription.contains("invalid"), error.localizedDescription)
        }
    }

    func testRedissIsTLS() async throws {
        let server = try server(tls: true)
        let tls = RedisDriver(server.connection(), password: server.password)
        try await tls.connect()
        let pong = try await tls.execute("PING", limit: 10)
        XCTAssertEqual(pong.message, "PONG")
        await tls.close()
        // Its certificate is its own: checked, it is refused.
        var verified = server.connection()
        verified.sslMode = .verifyFull
        let checked = RedisDriver(verified, password: server.password)
        do {
            try await checked.connect()
            XCTFail("a self-signed certificate doesn't verify")
        } catch {}
        // And plain text to a TLS port doesn't get through.
        var plain = server.connection()
        plain.sslMode = .disable
        let wrong = RedisDriver(plain, password: server.password)
        do {
            try await wrong.connect()
            XCTFail("plain text to a TLS port")
        } catch {}
    }

    func testTheBrowserAndAKeysPage() async throws {
        let server = try server()
        let secrets = MemoryDatabaseSecrets()
        let connection = server.connection()
        secrets.set(server.password, .password, for: connection.id)
        let session = DatabaseSession(connection, secrets: secrets)
        await session.open()
        XCTAssertEqual(session.state, .open)
        let driver = try XCTUnwrap(session.redis)
        var setup: [[String]] = (1...30).map { ["SET", "user:\($0):name", "u\($0)"] }
        setup += [["HSET", "user:1:profile", "a", "1", "b", "2"], ["RPUSH", "queue", "x", "y", "z"], ["SADD", "tags", "red", "blue"]]
        setup += [["ZADD", "board", "10", "ada", "5", "bob"], ["XADD", "events", "*", "kind", "signup"]]
        _ = try await driver.pipeline(setup)

        let browser = session.browser(0)
        await browser.scan()
        XCTAssertEqual(browser.keys.count, 35)
        XCTAssertEqual(browser.total, 35)
        XCTAssertEqual(browser.tree.root.folders.map(\.name), ["user"])
        XCTAssertEqual(browser.keys.first { $0.name == "board" }?.type, "zset")
        browser.pattern = "user:1*"
        await browser.scan()
        XCTAssertEqual(Set(browser.keys.map(\.name)), Set(["user:1:name", "user:1:profile"] + (10...19).map { "user:\($0):name" }))
        browser.pattern = ""
        browser.type = "list"
        await browser.scan()
        XCTAssertEqual(browser.keys.map(\.name), ["queue"])

        // Not shown: each read is the test's own, awaited.
        let key = RedisKeyModel()
        // A hash: read, a field changed, one added, one removed.
        key.show("user:1:profile", db: 0, session: session)
        await key.load()
        XCTAssertEqual(key.type, "hash")
        XCTAssertEqual(key.length, 2)
        XCTAssertEqual(Set(key.rows.map(\.cells)), [["a", "1"], ["b", "2"]])
        let a = try XCTUnwrap(key.rows.first { $0.id == "a" })
        await key.update(a, to: "one")
        await key.add(["c", "3"])
        await key.load()
        XCTAssertEqual(Set(key.rows.map(\.cells)), [["a", "one"], ["b", "2"], ["c", "3"]])
        await key.remove(try XCTUnwrap(key.rows.first { $0.id == "b" }))
        let reply1 = try await driver.command(["HEXISTS", "user:1:profile", "b"])
        XCTAssertEqual(reply1, .integer(0))
        key.filter = "c"
        await key.applyFilter()
        XCTAssertEqual(key.rows.map(\.id), ["c"])

        // A list: an element removed from its middle.
        key.show("queue", db: 0, session: session)
        await key.load()
        await key.remove(try XCTUnwrap(key.rows.first { $0.cells[1] == "y" }))
        let reply2 = try await driver.command(["LRANGE", "queue", "0", "-1"])
        XCTAssertEqual(reply2, .array([.bulk(Data("x".utf8)), .bulk(Data("z".utf8))]))

        // A sorted set's score; a set's member renamed.
        key.show("board", db: 0, session: session)
        await key.load()
        XCTAssertEqual(key.rows.map(\.id), ["bob", "ada"])
        await key.update(try XCTUnwrap(key.rows.first { $0.id == "bob" }), to: "50")
        let reply3 = try await driver.command(["ZSCORE", "board", "bob"])
        XCTAssertEqual(reply3.text, "50")
        key.show("tags", db: 0, session: session)
        await key.load()
        await key.update(try XCTUnwrap(key.rows.first { $0.id == "red" }), to: "green")
        let reply4 = try await driver.command(["SISMEMBER", "tags", "green"])
        XCTAssertEqual(reply4, .integer(1))

        // A stream, newest first; an entry added.
        key.show("events", db: 0, session: session)
        await key.load()
        XCTAssertEqual(key.rows.count, 1)
        await key.add(["kind", "login"])
        await key.load()
        XCTAssertEqual(key.rows.first?.cells[1], "kind=login")

        // A string: saved keeps its TTL; a TTL set, then taken away; renamed; deleted.
        key.show("user:2:name", db: 0, session: session)
        await key.load()
        await key.setTTL(300)
        key.text = "Grace"
        await key.saveText()
        let reply5 = try await driver.command(["GET", "user:2:name"])
        XCTAssertEqual(reply5.text, "Grace")
        if case .integer(let ttl) = try await driver.command(["TTL", "user:2:name"]) { XCTAssertGreaterThan(ttl, 200, "SET … KEEPTTL") }
        await key.setTTL(-1)
        let reply6 = try await driver.command(["TTL", "user:2:name"])
        XCTAssertEqual(reply6, .integer(-1))
        let renamed = await key.rename(to: "user:1:name")
        XCTAssertFalse(renamed, "never over a key that is there")
        let renamedFree = await key.rename(to: "people:grace")
        XCTAssertTrue(renamedFree)
        let deleted = await key.delete()
        XCTAssertTrue(deleted)
        let reply7 = try await driver.command(["EXISTS", "people:grace"])
        XCTAssertEqual(reply7, .integer(0))

        // A new key, refused over an old one.
        try await RedisKeyModel.create("cart:9", type: "hash", values: ["sku", "42"], ttl: 60, db: 3, driver: driver)
        let reply8 = try await driver.command(["HGET", "cart:9", "sku"], db: 3)
        XCTAssertEqual(reply8.text, "42")
        do {
            try await RedisKeyModel.create("cart:9", type: "string", values: ["x"], ttl: nil, db: 3, driver: driver)
            XCTFail("a key of that name is there")
        } catch {}

        await session.close()
    }

    func testPubSubAndTheServersPage() async throws {
        let server = try server()
        let secrets = MemoryDatabaseSecrets()
        let connection = server.connection()
        secrets.set(server.password, .password, for: connection.id)
        let session = DatabaseSession(connection, secrets: secrets)
        await session.open()
        let page = RedisServerModel()
        page.show(session)
        await page.refresh()
        XCTAssertNotNil(page.info.version)
        XCTAssertFalse(page.clients.isEmpty)
        page.channels = "news.*"
        await page.subscribe()
        XCTAssertEqual(page.subscribed, "news.*")
        try await Task.sleep(for: .milliseconds(200))
        let received = await page.publish("news.today", "hello")
        XCTAssertEqual(received, 1, "the page's own listener")
        for _ in 0..<40 where page.messages.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(page.messages.first?.channel, "news.today")
        XCTAssertEqual(page.messages.first?.text, "hello")
        page.stopListening()
        await page.startMonitor()
        try await Task.sleep(for: .milliseconds(200))
        _ = try await session.redis?.command(["SET", "watched", "1"])
        for _ in 0..<40 where !page.commands.contains(where: { $0.text.contains("watched") }) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(page.commands.contains { $0.text.contains("\"SET\" \"watched\"") }, "\(page.commands.map(\.text))")
        page.stopListening()
        await session.close()
    }
}
