import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell

/// The Server page's reads, node editing and users of Neo4j, InfluxDB and
/// RabbitMQ against Scripts/database-test-servers.sh's servers (and
/// `… queues` for RabbitMQ) when OVERTERM_DB_TESTS=1; Redis's against a
/// redis-server of its own (E2ERedisServer), skipped where there is none.
final class KindOperationsDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    // MARK: Redis

    func testRedis() async throws {
        guard let server = E2ERedisServer() else { throw XCTSkip("no redis-server on this Mac") }
        defer { server.stop() }
        let driver = RedisDriver(server.connection(), password: server.password)
        try await driver.connect()
        _ = try await driver.pipeline([["CONFIG", "SET", "slowlog-log-slower-than", "0"], ["SET", "k", "v"], ["GET", "k"]])

        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Clients" && $0.detail?.contains("maxclients") == true }, "\(overview.facts)")
        let other = await driver.listener()
        try await other.connect()
        let read1 = try await driver.activity().value
        let sessions = try XCTUnwrap(read1)
        XCTAssertEqual(sessions.filter(\.isOwn).count, 1)
        let victim = try XCTUnwrap(sessions.first { !$0.isOwn })
        let own = try XCTUnwrap(sessions.first(where: \.isOwn))
        do {
            try await driver.cancel(session: own.id, terminate: true)
            XCTFail("its own client is never killed")
        } catch {}
        try await driver.cancel(session: victim.id, terminate: true)
        let read2 = try await driver.activity().value
        let after = try XCTUnwrap(read2)
        XCTAssertFalse(after.contains { $0.id == victim.id })
        await other.close()
        let read3 = try await driver.slowQueries().value
        let slow = try XCTUnwrap(read3)
        XCTAssertTrue(slow.contains { $0.statement == "GET k" }, "\(slow.map(\.statement))")

        // ACL: made, signed in with, granted, revoked, dropped.
        let maker = await driver.userStatements()
        let user = DatabaseUser(name: "ot-acl")
        try await driver.run(try maker.create(NewUser(name: "ot-acl", password: "pw-1")))
        do {
            try await driver.run(try maker.create(NewUser(name: "ot-acl", password: "other")))
            XCTFail("a new user never replaces one")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already"), error.localizedDescription)
        }
        try await driver.run([
            try maker.grant(["+@read", "+@connection"], on: .server, to: user, grantOption: false),
            try maker.grant([RedisUserStatements.keyAccess[0]], on: .named(kind: "Keys", name: "k*"), to: user, grantOption: false),
        ])
        let read4 = try await driver.users().value?.first { $0.name == "ot-acl" }
        let listed = try XCTUnwrap(read4)
        XCTAssertTrue(listed.attributes.contains("a password set"), "\(listed.attributes)")
        let read5 = try await driver.grants(of: listed).value
        let grants = try XCTUnwrap(read5)
        XCTAssertEqual(grants.first { $0.kind == "keys" }?.object, "k*")
        var signIn = server.connection()
        signIn.user = "ot-acl"
        let reader = RedisDriver(signIn, password: "pw-1")
        let read = try await reader.command(["GET", "k"])
        XCTAssertEqual(read, .bulk(Data("v".utf8)))
        await reader.close()
        try await driver.run([try XCTUnwrap(maker.revoke(try XCTUnwrap(grants.first { $0.kind == "keys" }), from: listed))])
        let read6 = try await driver.grants(of: listed).value?.first { $0.kind == "keys" }
        XCTAssertNil(read6)
        try await driver.run([try maker.drop(listed)])
        let read7 = try await driver.users().value?.contains { $0.name == "ot-acl" } ?? true
        XCTAssertFalse(read7)

        var readOnly = server.connection()
        readOnly.readOnly = true
        let refused = RedisDriver(readOnly, password: server.password)
        do {
            try await refused.run([try maker.drop(listed)])
            XCTFail("a read-only connection changes no user")
        } catch {}
        await driver.close()
    }

    // MARK: Neo4j

    private func neo4j(readOnly: Bool = false) -> Neo4jDriver {
        var connection = DatabaseConnection(name: "Neo4j", kind: .neo4j)
        connection.host = "127.0.0.1"
        connection.port = 57474
        connection.user = "neo4j"
        connection.sslMode = .disable
        connection.readOnly = readOnly
        return Neo4jDriver(connection, password: "otpass1234")
    }

    func testNeo4jServerPage() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = neo4j()
        try await driver.connect()
        _ = try await driver.execute("MATCH (n:OtOps) DETACH DELETE n", limit: 10)
        _ = try await driver.execute("CREATE (:OtOps {i: 1})-[:OT_OPS]->(:OtOps {i: 2})", limit: 10)
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Neo4j Kernel" || $0.title == "Neo4j" }, "\(overview.facts)")
        XCTAssertTrue(overview.facts.contains { $0.title == "Nodes" && $0.value != "—" }, "\(overview.facts)")
        let read8 = try await driver.activity().value
        let activity = try XCTUnwrap(read8)
        XCTAssertEqual(activity.filter(\.isOwn).count, 1, "\(activity)")
        do {
            try await driver.cancel(session: activity.first(where: \.isOwn)?.id ?? "", terminate: true)
            XCTFail("its own transaction is never terminated")
        } catch {}
        let read9 = try await driver.locks().value
        XCTAssertNotNil(read9)
        let read10 = try await driver.sizes().value
        let sizes = try XCTUnwrap(read10)
        XCTAssertEqual(sizes.tables.first { $0.name == "OtOps" }?.bytes, 2)
        XCTAssertEqual(sizes.tables.first { $0.name == "[:OT_OPS]" }?.unit, "relationships")
        _ = try await driver.execute("MATCH (n:OtOps) DETACH DELETE n", limit: 10)
    }

    func testNeo4jNodesEdited() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = neo4j()
        try await driver.connect()
        _ = try await driver.execute("MATCH (n:OtEdit) DETACH DELETE n", limit: 10)
        _ = try await driver.execute(
            "CREATE (:OtEdit {name: 'Ann', age: 31, tags: ['a']}), (:OtEdit {name: 'Bob', age: 40, born: date('1990-01-01')})-[:OT_R]->(:OtOther)", limit: 10)
        let statement = "MATCH (n:OtEdit) RETURN n ORDER BY n.name"
        let result = try await driver.execute(statement, limit: 100)
        XCTAssertEqual(result.columns, ["elementId(n)", "age", "born", "name", "tags"])
        guard case .success(let editable)? = try await driver.editableResult(for: statement, result: result) else {
            return XCTFail("a label's nodes are edited")
        }
        XCTAssertFalse(editable.isEditable(0), "the elementId")
        XCTAssertFalse(editable.isEditable(2), "a date's text isn't its value")
        XCTAssertTrue(editable.isEditable(1) && editable.isEditable(4))
        guard case .failure? = try await driver.editableResult(for: "MATCH (n:OtEdit) RETURN n.name", result: QueryResult(columns: ["n.name"])) else {
            return XCTFail("a property's result isn't edited")
        }

        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text("32"), original: "31")
        edits.set(row: 0, column: 4, to: .text(#"["a", "b'"]"#), original: #"["a"]"#)
        edits.set(row: 1, column: 3, to: .text(""), original: "Bob")
        edits.add([3: .text("Cy"), 1: .text("5")])
        let statements = try await driver.editStatements(edits, rows: result.rows, result: editable)
        try await driver.apply(statements)
        let after = try await driver.execute("MATCH (n:OtEdit) RETURN n.name AS name, n.age AS age, n.tags AS tags ORDER BY n.age", limit: 10)
        XCTAssertEqual(after.rows, [["Cy", "5", nil], ["Ann", "32", #"["a","b'"]"#], ["", "40", nil]], "an empty string isn't NULL")

        // A node gone since it was read: nothing of the Save is kept.
        let again = try await driver.execute(statement, limit: 100)
        var stale = PendingEdits()
        stale.set(row: 0, column: 1, to: .text("1"), original: again.rows[0][1])
        stale.delete(rows: [1])
        let staleStatements = try await driver.editStatements(stale, rows: again.rows, result: editable)
        _ = try await driver.execute("MATCH (n:OtEdit {name: 'Ann'}) DETACH DELETE n", limit: 10)
        do {
            try await driver.apply(staleStatements)
            XCTFail("a row gone fails the Save")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing was saved"), error.localizedDescription)
        }
        let kept = try await driver.execute("MATCH (n:OtEdit) RETURN count(n) AS c", limit: 1)
        XCTAssertEqual(kept.rows.first?.first, "2", "the delete before it was rolled back too")

        // DETACH DELETE takes its relationships.
        let last = try await driver.execute(statement, limit: 100)
        var delete = PendingEdits()
        delete.delete(rows: Array(last.rows.indices))
        try await driver.apply(try await driver.editStatements(delete, rows: last.rows, result: editable))
        let left = try await driver.execute("MATCH (n:OtEdit) RETURN count(n) AS c", limit: 1)
        XCTAssertEqual(left.rows.first?.first, "0")
        _ = try await driver.execute("MATCH (n:OtOther) DETACH DELETE n", limit: 10)

        do {
            try await neo4j(readOnly: true).apply(statements)
            XCTFail("a read-only connection saves nothing")
        } catch {}
    }

    func testNeo4jUsers() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = neo4j()
        try await driver.connect()
        let maker = await driver.userStatements()
        _ = try? await driver.run([try maker.drop(DatabaseUser(name: "ot_user"))])
        try await driver.run(try maker.create(NewUser(name: "ot_user", password: "ot-pass-1")))
        let read14 = try await driver.users().value
        let users = try XCTUnwrap(read14)
        XCTAssertTrue(users.contains { $0.name == "ot_user" }, "\(users)")
        XCTAssertTrue(users.contains { $0.name == "neo4j" })

        // The encrypted password is the one typed: it signs in.
        var signIn = DatabaseConnection(name: "u", kind: .neo4j)
        signIn.host = "127.0.0.1"
        signIn.port = 57474
        signIn.user = "ot_user"
        signIn.sslMode = .disable
        try await Neo4jDriver(signIn, password: "ot-pass-1").connect()
        try await driver.run([try maker.password(of: DatabaseUser(name: "ot_user"), to: "ot-pass-2")])
        try await Neo4jDriver(signIn, password: "ot-pass-2").connect()

        if await driver.edition() != "enterprise" {
            let read15 = try await driver.grants(of: DatabaseUser(name: "ot_user")).gap
            XCTAssertNotNil(read15, "Community: no roles, said")
        }
        try await driver.run([try maker.drop(DatabaseUser(name: "ot_user"))])
        let read16 = try await driver.users().value?.contains { $0.name == "ot_user" } ?? true
        XCTAssertFalse(read16)
    }

    // MARK: InfluxDB

    private func influx(port: Int, user: String = "", password: String) -> InfluxDBDriver {
        var connection = DatabaseConnection(name: "Influx", kind: .influxdb)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.user = user
        connection.sslMode = .disable
        connection.database = "shop"
        if port == 58086 { connection.project = "ot" }
        return InfluxDBDriver(connection, password: password)
    }

    func testInflux1() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = influx(port: 58087, user: "ot", password: "otpass")
        try await driver.connect()
        // A database of its own: the other tests read `shop`'s measurements.
        _ = try await driver.execute("CREATE DATABASE ot_ops", limit: 1)
        _ = try await driver.execute("USE ot_ops", limit: 1)
        _ = try await driver.execute("WRITE cpu,host=a value=1", limit: 1)
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "InfluxDB" && $0.value.contains("1.") }, "\(overview.facts)")
        let read17 = try await driver.activity().value
        let activity = try XCTUnwrap(read17)
        XCTAssertTrue(activity.contains(where: \.isOwn), "\(activity)")
        let read18 = try await driver.sizes().value
        let sizes = try XCTUnwrap(read18)
        XCTAssertTrue(sizes.databases.contains { $0.name == "ot_ops" }, "\(sizes)")

        let maker = await driver.userStatements()
        _ = try? await driver.run([try maker.drop(DatabaseUser(name: "ot_reader"))])
        try await driver.run(try maker.create(NewUser(name: "ot_reader", password: "pw'1")))
        let user = DatabaseUser(name: "ot_reader")
        try await driver.run([try maker.grant(["READ"], on: .database("ot_ops"), to: user, grantOption: false)])
        let read19 = try await driver.grants(of: user).value
        let grants = try XCTUnwrap(read19)
        XCTAssertEqual(grants.map(\.object), ["ot_ops"])
        let reader = influx(port: 58087, user: "ot_reader", password: "pw'1")
        _ = try await reader.execute("SELECT * FROM ot_ops..cpu", limit: 1)
        let gap = try await reader.activity().gap
        XCTAssertNotNil(gap, "SHOW QUERIES wants an admin — said")
        try await driver.run([try XCTUnwrap(maker.revoke(grants[0], from: user)), try maker.drop(user)])
        let read20 = try await driver.users().value?.contains { $0.name == "ot_reader" } ?? true
        XCTAssertFalse(read20)
        _ = try await driver.execute("DROP DATABASE ot_ops", limit: 1)
    }

    func testInflux2() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = influx(port: 58086, password: "ot-test-token")
        try await driver.connect()
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Buckets" }, "\(overview)")
        let read21 = try await driver.activity().gap
        XCTAssertNotNil(read21, "2.x lists no queries — said")
        let read22 = try await driver.sizes().value
        let sizes = try XCTUnwrap(read22)
        XCTAssertTrue(sizes.databases.contains { $0.name == "shop" }, "\(sizes)")

        let maker = await driver.userStatements()
        _ = try? await driver.run([try maker.drop(DatabaseUser(name: "ot-two"))])
        try await driver.run(try maker.create(NewUser(name: "ot-two", password: "ot-pass-123")))
        let read23 = try await driver.users().value
        let users = try XCTUnwrap(read23)
        XCTAssertTrue(users.contains { $0.name == "ot-two" }, "\(users)")
        let read24 = try await driver.grants(of: DatabaseUser(name: "ot")).value
        XCTAssertNotNil(read24, "the admin's tokens, values never read")
        try await driver.run([try maker.password(of: DatabaseUser(name: "ot-two"), to: "ot-pass-456")])
        try await driver.run([try maker.drop(DatabaseUser(name: "ot-two"))])
        let read25 = try await driver.users().value?.contains { $0.name == "ot-two" } ?? true
        XCTAssertFalse(read25)
    }

    // MARK: RabbitMQ

    private func rabbit(user: String = "ot", password: String = "otpass", readOnly: Bool = false) -> RabbitMQDriver {
        var connection = DatabaseConnection(name: "Rabbit", kind: .rabbitmq)
        connection.host = "127.0.0.1"
        connection.port = 55672
        connection.user = user
        connection.sslMode = .disable
        connection.readOnly = readOnly
        return RabbitMQDriver(connection, password: password)
    }

    func testRabbitMQ() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh queues") }
        let driver = rabbit()
        try await driver.connect()
        _ = try await driver.execute("PUT /api/queues/%2F/ot-ops\n{\"durable\": false}", limit: 1)
        _ = try await driver.execute("PUBLISH amq.default ot-ops hello", limit: 1)
        // A node's memory comes with its first stats, a few seconds after the
        // management API answers: a server just started has none yet.
        var overview = try await driver.overview()
        for _ in 0..<20 where !overview.facts.contains(where: { $0.title.hasPrefix("Memory") }) {
            try await Task.sleep(for: .milliseconds(500))
            overview = try await driver.overview()
        }
        XCTAssertTrue(overview.facts.contains { $0.title.hasPrefix("Memory") }, "\(overview.facts)")
        let read26 = try await driver.activity().value
        XCTAssertNotNil(read26)
        let read27 = try await driver.sizes().value
        var sizes = try XCTUnwrap(read27)
        for _ in 0..<20 where sizes.tables.first(where: { $0.name == "ot-ops" })?.detail?.hasPrefix("1 messages") != true {
            try await Task.sleep(for: .milliseconds(500))  // the queue's counts are sampled every few seconds
            let read28 = try await driver.sizes().value
            sizes = try XCTUnwrap(read28)
        }
        XCTAssertTrue(sizes.tables.first { $0.name == "ot-ops" }?.detail?.hasPrefix("1 messages") == true, "\(sizes.tables)")

        let maker = await driver.userStatements()
        let user = DatabaseUser(name: "ot-rabbit", attributes: ["management"])
        _ = try? await driver.run([try maker.drop(user)])
        var new = NewUser(name: "ot-rabbit", password: "pw-1")
        new.superuser = false
        try await driver.run(try maker.create(new))
        do {
            try await driver.run(try maker.create(new))
            XCTFail("a new user never replaces one")
        } catch {}
        let target = maker.target(maker.form.grantKinds[0], fields: ["/"])
        try await driver.run([try maker.grant(["read", "write", "configure"], on: target, to: user, grantOption: false)])
        let read29 = try await driver.grants(of: user).value
        let grants = try XCTUnwrap(read29)
        XCTAssertEqual(grants.first?.privileges, ["configure .*", "write .*", "read .*"])
        // A password change is a PUT of the whole user: the tags it is given
        // go with it. The hash sent is the password: the user signs in.
        try await driver.run([try maker.password(of: user, to: "pw-2")])
        let read30 = try await driver.users().value?.first { $0.name == "ot-rabbit" }?.attributes
        XCTAssertEqual(read30, ["management"])
        let signedIn = rabbit(user: "ot-rabbit", password: "pw-2")
        _ = try await signedIn.execute("GET /api/whoami", limit: 1)
        let read31 = try await driver.users().value
        let listed = try XCTUnwrap(read31)
        XCTAssertTrue(listed.contains { $0.name == "ot-rabbit" })
        let refused = try await signedIn.users()
        XCTAssertNotNil(refused.gap, "a user who isn't an administrator is told so")
        try await driver.run([try XCTUnwrap(maker.revoke(grants[0], from: user)), try maker.drop(user)])
        let read32 = try await driver.users().value?.contains { $0.name == "ot-rabbit" } ?? true
        XCTAssertFalse(read32)
        do {
            try await rabbit(readOnly: true).run([try maker.drop(user)])
            XCTFail("a read-only connection changes no user")
        } catch {}
        _ = try await driver.execute("DELETE /api/queues/%2F/ot-ops", limit: 1)
    }
}
