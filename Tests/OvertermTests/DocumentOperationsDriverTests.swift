import XCTest

@testable import Overterm

/// The Server page, editing and users against real servers, with
/// OVERTERM_DB_TESTS=1: Scripts/database-test-servers.sh's MongoDB 7 (with
/// auth, standalone, on :57017) and DynamoDB Local (:58800); a one-node
/// replica set for transactions on :57018 when it is running (`docker run
/// -d --name ot-mongodb-rs -p 57018:27017 mongo:7 --replSet rs0` and
/// `rs.initiate()` — skipped otherwise); `… search`'s Elasticsearch 8
/// (security on, :59200) and OpenSearch 2 (:59210). Each makes and drops
/// what it uses.
final class DocumentOperationsDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func mongo(port: Int = 57017, user: String = "ot", readOnly: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "mongo", kind: .mongodb)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.user = user
        connection.database = "opsdocs"
        connection.authSource = user.isEmpty ? "" : "admin"
        connection.sslMode = .disable
        connection.readOnly = readOnly
        return connection
    }

    /// A find's documents edited and saved, read back — then a Save whose
    /// document is gone fails, keeping (standalone) or not (replica set)
    /// what ran before it.
    private func editDocuments(_ driver: MongoDriver, transactional: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try? await driver.execute("db.edits.drop()", limit: 1)
        _ = try await driver.execute(
            #"db.edits.insertMany([{ _id: 1, note: "first", n: NumberInt(1), tags: ["a"] }, { _id: 2, note: null, n: NumberInt(2) }, { _id: 3, note: "third", n: NumberInt(3) }])"#,
            limit: 10)
        let statement = "db.edits.find({}).sort({ _id: 1 })"
        let read = try await driver.execute(statement, limit: 100)
        guard case .success(let result)? = try await driver.editableResult(for: statement, result: read) else { return XCTFail("not editable", file: file, line: line) }
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(#"it's "x"; db.dropDatabase()"#), original: "first")
        edits.set(row: 0, column: 3, to: .absent, original: #"["a"]"#)
        edits.set(row: 1, column: 1, to: .text(""), original: nil)
        edits.set(row: 1, column: 2, to: .text("20"), original: "2")
        edits.delete(rows: [2])
        edits.add([0: .text("4"), 1: .text("new")])
        try await driver.apply(try await driver.editStatements(edits, rows: read.rows, result: result))
        let after = try await driver.execute(statement, limit: 100)
        XCTAssertEqual(after.columns, ["_id", "note", "n"], "tags removed, not nulled", file: file, line: line)
        XCTAssertEqual(after.rows, [["1", #"it's "x"; db.dropDatabase()"#, "1"], ["2", "", "20"], ["4", "new", nil]], file: file, line: line)
        XCTAssertEqual(after.types[2], "int", "an int stays an int", file: file, line: line)

        // _id 2 deleted, then one gone since it was read: the Save fails.
        var stale = PendingEdits()
        stale.delete(rows: [1])
        stale.set(row: 2, column: 1, to: .text("changed"), original: "new")
        var rows = after.rows
        rows[2][0] = "99"
        do {
            try await driver.apply(try await driver.editStatements(stale, rows: rows, result: result))
            XCTFail("a document gone saves nothing more", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("found 0 documents"), error.localizedDescription, file: file, line: line)
        }
        let kept = try await driver.execute(statement, limit: 100).rows.map { $0[0] }
        XCTAssertEqual(kept, transactional ? ["1", "2", "4"] : ["1", "4"], transactional ? "rolled back whole" : "one by one: the delete before it stays", file: file, line: line)
        _ = try await driver.execute("db.edits.drop()", limit: 1)
    }

    func testMongoEditsOneByOneOnAStandaloneServer() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MongoDriver(mongo(), password: "otpass")
        try await driver.connect()
        let note = await driver.editSaveNote()
        XCTAssertTrue(note.hasPrefix("One by one"), note)
        try await editDocuments(driver, transactional: false)
        let reader = MongoDriver(mongo(readOnly: true), password: "otpass")
        do {
            try await reader.apply([EditStatement(sql: #"db.edits.insertOne({ a: 1 })"#)])
            XCTFail("a read-only connection writes nothing")
        } catch {}
        await driver.close()
    }

    func testMongoEditsInATransactionOnAReplicaSet() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MongoDriver(mongo(port: 57018, user: ""), password: nil)
        do {
            try await driver.connect()
        } catch {
            throw XCTSkip("no replica set on :57018 — \(error.localizedDescription)")
        }
        let note = await driver.editSaveNote()
        XCTAssertTrue(note.hasPrefix("In one transaction"), note)
        try await editDocuments(driver, transactional: true)
        await driver.close()
    }

    func testMongoServerPage() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MongoDriver(mongo(), password: "otpass")
        try await driver.connect()
        _ = try await driver.execute(#"db.sizes.insertMany([{ a: 1 }, { a: 2 }])"#, limit: 10)
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Connections" }, "\(overview.facts)")
        XCTAssertTrue(overview.facts.contains { $0.title == "Version" && $0.value.hasPrefix("7.") })
        guard case .value(let sessions) = try await driver.activity() else { return XCTFail("activity unread") }
        XCTAssertTrue(sessions.contains(where: \.isOwn), "the page's own operation, marked: \(sessions)")

        // The profiler: off, said with the line; on, its operations summed.
        _ = try await driver.execute("db.runCommand({ profile: 0 })", limit: 1)
        _ = try? await driver.execute("db.system.profile.drop()", limit: 1)
        guard case .unavailable(let gap) = try await driver.slowQueries() else { return XCTFail("the profiler is off") }
        XCTAssertTrue(gap.reason.contains("setProfilingLevel"), gap.reason)
        XCTAssertEqual(gap.fix, #"db.getSiblingDB("opsdocs").runCommand({ profile: 1, slowms: 100 })"#)
        _ = try await driver.execute("db.runCommand({ profile: 2 })", limit: 1)
        _ = try await driver.execute(#"db.sizes.find({ a: 1 })"#, limit: 10)
        _ = try await driver.execute(#"db.sizes.find({ a: 2 })"#, limit: 10)
        guard case .value(let slow) = try await driver.slowQueries() else { return XCTFail("the profiler is on") }
        XCTAssertTrue(slow.contains { $0.statement.hasPrefix("opsdocs.sizes") && $0.calls >= 2 }, "\(slow)")
        _ = try await driver.execute("db.runCommand({ profile: 0 })", limit: 1)

        guard case .value(let locks) = try await driver.locks() else { return XCTFail("locks unread") }
        XCTAssertTrue(locks.isEmpty, "nobody waits: \(locks)")
        guard case .value(let sizes) = try await driver.sizes() else { return XCTFail("sizes unread") }
        XCTAssertTrue(sizes.databases.contains { $0.name == "opsdocs" }, "\(sizes.databases)")
        XCTAssertTrue(sizes.tables.contains { $0.name == "sizes" && $0.detail?.hasPrefix("2 docs") == true }, "\(sizes.tables)")
        XCTAssertTrue(sizes.indexes.contains { $0.name == "_id_" })

        // killOp of nothing running: the server says so; refused read-only.
        do {
            try await driver.cancel(session: "999999", terminate: false)
        } catch {
            XCTFail("killOp of an operation gone is a no-op: \(error)")
        }
        let reader = MongoDriver(mongo(readOnly: true), password: "otpass")
        do {
            try await reader.cancel(session: "1", terminate: false)
            XCTFail("refused on a read-only connection")
        } catch {}
        _ = try await driver.execute("db.dropDatabase()", limit: 1)
        await driver.close()
    }

    func testMongoUsers() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MongoDriver(mongo(), password: "otpass")
        try await driver.connect()
        let name = #"ops"user'; x"#
        _ = try? await driver.run([try MongoUserStatements().drop(DatabaseUser(name: name, host: "opsdocs"))])
        var new = NewUser()
        new.name = name
        new.host = "opsdocs"
        new.password = "first-Pass1"
        try await driver.run(try MongoUserStatements().create(new))
        guard case .value(let users) = try await driver.users() else { return XCTFail("users unread") }
        guard let made = users.first(where: { $0.name == name && $0.host == "opsdocs" }) else { return XCTFail("\(users)") }
        XCTAssertTrue(users.contains { $0.name == "ot" && $0.superuser }, "root is a superuser")
        try await driver.run([try MongoUserStatements().grant(["readWrite"], on: .database("opsdocs"), to: made, grantOption: false)])
        guard case .value(let grants) = try await driver.grants(of: made) else { return XCTFail("grants unread") }
        XCTAssertTrue(grants.contains { $0.kind == "role" && $0.object == "readWrite@opsdocs" }, "\(grants)")
        XCTAssertTrue(grants.contains { $0.kind == "database" && $0.object == "opsdocs" && $0.privileges.contains("insert") }, "\(grants)")
        try await driver.run([try MongoUserStatements().password(of: made, to: "second-Pass2")])
        // The new password signs in; nothing of it was kept.
        var signIn = mongo(user: name)
        signIn.authSource = "opsdocs"
        let other = MongoDriver(signIn, password: "second-Pass2")
        try await other.connect()
        _ = try await other.execute("db.things.insertOne({ a: 1 })", limit: 1)
        await other.close()
        if let revoke = MongoUserStatements().revoke(grants[0], from: made) { try await driver.run([revoke]) }
        guard case .value(let after) = try await driver.grants(of: made) else { return XCTFail() }
        XCTAssertFalse(after.contains { $0.kind == "role" }, "\(after)")
        try await driver.run([try MongoUserStatements().drop(made)])
        let reader = MongoDriver(mongo(readOnly: true), password: "otpass")
        do {
            try await reader.run([try MongoUserStatements().drop(made)])
            XCTFail("refused on a read-only connection")
        } catch {}
        _ = try await driver.execute("db.dropDatabase()", limit: 1)
        await driver.close()
    }

    // MARK: DynamoDB

    private func dynamo(readOnly: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "dynamo", kind: .dynamodb)
        connection.host = "127.0.0.1"
        connection.port = 58800
        connection.sslMode = .disable
        connection.location = "us-east-1"
        connection.readOnly = readOnly
        return connection
    }

    func testDynamoServerPageAndEdits() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = DynamoDBDriver(dynamo(), password: nil)
        _ = try? await driver.call("DeleteTable", json: #"{"TableName": "ops_items"}"#)
        _ = try await driver.call(
            "CreateTable",
            json:
                #"{"TableName": "ops_items", "BillingMode": "PAY_PER_REQUEST", "KeySchema": [{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}], "AttributeDefinitions": [{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "N"}]}"#
        )
        for statement in [
            #"INSERT INTO "ops_items" VALUE {'pk': 'a', 'sk': 1, 'note': 'first', 'n': 5, 'meta': {'k': 1}}"#,
            #"INSERT INTO "ops_items" VALUE {'pk': 'a', 'sk': 2, 'note': 'second'}"#,
            #"INSERT INTO "ops_items" VALUE {'pk': 'b''x', 'sk': 1, 'note': 'third'}"#,
        ] { _ = try await driver.execute(statement, limit: 1) }

        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Tables" }, "\(overview.facts)")
        guard case .value(let sizes) = try await driver.sizes() else { return XCTFail("sizes unread") }
        XCTAssertTrue(sizes.tables.contains { $0.name == "ops_items" && $0.detail?.contains("on-demand") == true }, "\(sizes.tables)")

        let statement = #"SELECT * FROM "ops_items""#
        let read = try await driver.execute(statement, limit: 100)
        guard case .success(let result)? = try await driver.editableResult(for: statement, result: read) else { return XCTFail("not editable") }
        func row(_ pk: String, _ sk: String) -> Int { read.rows.firstIndex { $0[0] == pk && $0[1] == sk }! }
        func column(_ name: String) -> Int { read.columns.firstIndex(of: name)! }
        var edits = PendingEdits()
        edits.set(row: row("a", "1"), column: column("note"), to: .text("it's; DROP"), original: "first")
        edits.set(row: row("a", "1"), column: column("n"), to: .absent, original: "5")
        edits.set(row: row("a", "1"), column: column("meta"), to: .text(#"{"k": 2, "l": [1, "x"]}"#), original: #"{"k":1}"#)
        edits.set(row: row("a", "2"), column: column("note"), to: .null, original: "second")
        edits.delete(rows: [row("b'x", "1")])
        edits.add([column("pk"): .text("c"), column("sk"): .text("3"), column("note"): .text("new")])
        try await driver.apply(try await driver.editStatements(edits, rows: read.rows, result: result))
        let after = try await driver.execute(#"SELECT pk, sk, note, n, meta FROM "ops_items""#, limit: 100)
        let byKey = Dictionary(after.rows.map { ("\($0[0] ?? "")/\($0[1] ?? "")", $0) }, uniquingKeysWith: { a, _ in a })
        func value(_ key: String, _ name: String) -> String? { after.columns.firstIndex(of: name).flatMap { byKey[key]?[$0] ?? nil } }
        XCTAssertEqual(byKey.count, 3)
        XCTAssertEqual(value("a/1", "note"), "it's; DROP")
        XCTAssertNil(value("a/1", "n"), "n removed")
        XCTAssertFalse(after.columns.contains("n"), "no item has it now")
        XCTAssertEqual(value("a/1", "meta"), #"{"k":2,"l":[1,"x"]}"#)
        XCTAssertNotNil(byKey["c/3"])
        XCTAssertNil(byKey["b'x/1"])

        // Changed since it was read: the transaction keeps nothing.
        var stale = PendingEdits()
        stale.set(row: row("a", "1"), column: column("note"), to: .text("again"), original: "first")
        stale.add([column("pk"): .text("d"), column("sk"): .text("4")])
        do {
            try await driver.apply(try await driver.editStatements(stale, rows: read.rows, result: result))
            XCTFail("the note isn't 'first' any more")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nothing was kept"), error.localizedDescription)
        }
        let none = try await driver.execute(#"SELECT * FROM "ops_items" WHERE pk = 'd'"#, limit: 10)
        XCTAssertTrue(none.rows.isEmpty, "the insert beside it rolled back")
        // An item already gone: deleting it again is a no-op (PartiQL checks
        // no condition of a missing item), the end the same.
        var gone = PendingEdits()
        gone.delete(rows: [row("b'x", "1")])
        try await driver.apply(try await driver.editStatements(gone, rows: read.rows, result: result))
        let reader = DynamoDBDriver(dynamo(readOnly: true), password: nil)
        do {
            try await reader.apply([EditStatement(sql: #"DELETE FROM "ops_items" WHERE pk = 'a' AND sk = 2"#)])
            XCTFail("refused on a read-only connection")
        } catch {}
        _ = try await driver.call("DeleteTable", json: #"{"TableName": "ops_items"}"#)
    }

    // MARK: Elasticsearch and OpenSearch

    private func search(_ kind: DatabaseKind, user: String = "") -> DatabaseConnection {
        var connection = DatabaseConnection(name: kind.title, kind: kind)
        connection.host = "127.0.0.1"
        connection.port = kind == .elasticsearch ? 59200 : 59210
        connection.user = user
        connection.sslMode = kind == .elasticsearch ? .require : .disable
        return connection
    }

    private func searchDriver(_ kind: DatabaseKind) async throws -> SearchDriver {
        let driver = SearchDriver(search(kind, user: kind == .elasticsearch ? "ot" : ""), password: kind == .elasticsearch ? "otpass" : nil)
        do {
            try await driver.connect()
        } catch {
            throw XCTSkip("no \(kind.title) — Scripts/database-test-servers.sh search: \(error.localizedDescription)")
        }
        return driver
    }

    private func editHits(_ driver: SearchDriver) async throws {
        _ = try? await driver.execute("DELETE /ops_hits", limit: 1)
        _ = try await driver.execute("PUT /ops_hits/_doc/1?refresh=true\n{\"note\": \"first\", \"n\": 1, \"tags\": [\"a\"]}", limit: 1)
        _ = try await driver.execute("PUT /ops_hits/_doc/a%2Fb?refresh=true\n{\"note\": \"second\", \"n\": 2}", limit: 1)
        let statement = "GET /ops_hits/_search\n{\"size\": 10, \"seq_no_primary_term\": true, \"sort\": [{\"n\": \"asc\"}]}"
        let read = try await driver.execute(statement, limit: 100)
        XCTAssertTrue(read.columns.contains("_seq_no"), "\(read.columns)")
        guard case .success(let result)? = try await driver.editableResult(for: statement, result: read) else { return XCTFail("not editable") }
        func column(_ name: String) -> Int { read.columns.firstIndex(of: name)! }
        var edits = PendingEdits()
        edits.set(row: 0, column: column("note"), to: .text(#"it's "x""#), original: "first")
        edits.set(row: 0, column: column("tags"), to: .absent, original: #"["a"]"#)
        edits.set(row: 1, column: column("n"), to: .text("20"), original: "2")
        edits.add([column("_id"): .text("3"), column("note"): .text("new"), column("n"): .text("3")])
        try await driver.apply(try await driver.editStatements(edits, rows: read.rows, result: result))
        let after = try await driver.execute(statement, limit: 100)
        func cell(_ id: String, _ name: String) -> String? { after.columns.firstIndex(of: name).flatMap { at in after.rows.first { $0[1] == id }?[at] ?? nil } }
        XCTAssertEqual(cell("1", "note"), #"it's "x""#)
        XCTAssertNil(cell("1", "tags"), "removed")
        XCTAssertEqual(cell("a/b", "n"), "20")
        XCTAssertEqual(cell("3", "note"), "new")
        // Read at an older version: refused, nothing after it runs.
        var stale = PendingEdits()
        stale.set(row: 0, column: column("note"), to: .text("again"), original: "first")
        do {
            try await driver.apply(try await driver.editStatements(stale, rows: read.rows, result: result))
            XCTFail("its seq_no moved")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed since it was read"), error.localizedDescription)
        }
        var deleting = PendingEdits()
        deleting.delete(rows: [1])
        try await driver.apply(try await driver.editStatements(deleting, rows: after.rows, result: result))
        let count = try await driver.execute("GET /ops_hits/_count", limit: 1)
        XCTAssertEqual(count.rows, [["2"]])
        _ = try await driver.execute("DELETE /ops_hits", limit: 1)
    }

    func testElasticsearch() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh search") }
        let driver = try await searchDriver(.elasticsearch)
        try await editHits(driver)
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Health" }, "\(overview.facts)")
        XCTAssertTrue(overview.facts.contains { $0.title == "Heap" })
        guard case .value(let tasks) = try await driver.activity() else { return XCTFail("tasks unread") }
        XCTAssertTrue(tasks.contains(where: \.isOwn), "\(tasks)")
        guard case .unavailable(let gap) = try await driver.slowQueries() else { return XCTFail("the slow log isn't readable") }
        XCTAssertTrue(gap.reason.contains("log files"), gap.reason)
        guard case .value(let sizes) = try await driver.sizes() else { return XCTFail("sizes unread") }
        XCTAssertFalse(sizes.notes.isEmpty)
        do {
            try await driver.cancel(session: "nonode:1", terminate: false)
            XCTFail("no such task")
        } catch {}

        // Users: made, a role granted and revoked, a password changed, dropped.
        let name = "ops/user"
        _ = try? await driver.run([try SearchUserStatements().drop(DatabaseUser(name: name))])
        var new = NewUser()
        new.name = name
        new.password = "first-Pass1"
        try await driver.run(try SearchUserStatements().create(new))
        guard case .value(let users) = try await driver.users() else { return XCTFail("users unread") }
        guard let made = users.first(where: { $0.name == name && !$0.isRole }) else { return XCTFail("\(users.map(\.name))") }
        XCTAssertTrue(users.contains { $0.name == "elastic" && $0.attributes.contains("built-in") })
        try await driver.run([try SearchUserStatements().grantRole(DatabaseUser(name: "viewer", isRole: true), to: made)])
        guard case .value(let again) = try await driver.users(), let granted = again.first(where: { $0.name == name && !$0.isRole }) else { return XCTFail() }
        XCTAssertEqual(granted.memberOf, ["viewer"])
        guard case .value(let grants) = try await driver.grants(of: granted) else { return XCTFail("grants unread") }
        XCTAssertTrue(grants.contains { $0.kind == "index" }, "\(grants)")
        try await driver.run([try SearchUserStatements().password(of: granted, to: "second-Pass2")])
        // Signed in with the new password: refused for want of `monitor`
        // (403), not for the password (401).
        let signedIn = SearchDriver(search(.elasticsearch, user: name), password: "second-Pass2")
        do {
            try await signedIn.connect()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("403"), error.localizedDescription)
        }
        if let revoke = SearchUserStatements().revoke(grants[0], from: granted) { try await driver.run([revoke]) }
        try await driver.run([try SearchUserStatements().drop(granted)])
    }

    /// OpenSearch with its security plugin on — not one the script starts:
    /// `docker run -d --name ot-opensearch-sec -e discovery.type=single-node
    /// -e OPENSEARCH_INITIAL_ADMIN_PASSWORD=… -p 59211:9200
    /// opensearchproject/opensearch:2.18.0`, the same password in
    /// OVERTERM_OPENSEARCH_ADMIN_PASSWORD.
    func testOpenSearchUsers() async throws {
        guard servers, let password = ProcessInfo.processInfo.environment["OVERTERM_OPENSEARCH_ADMIN_PASSWORD"] else {
            throw XCTSkip("OVERTERM_DB_TESTS=1 and OVERTERM_OPENSEARCH_ADMIN_PASSWORD with a secured OpenSearch on :59211")
        }
        var config = search(.opensearch, user: "admin")
        config.port = 59211
        config.sslMode = .require
        let driver = SearchDriver(config, password: password)
        try await driver.connect()
        let name = "ops/user"
        _ = try? await driver.run([try SearchUserStatements(opensearch: true).drop(DatabaseUser(name: name))])
        var new = NewUser()
        new.name = name
        new.password = "First-Pass_123!"
        try await driver.run(try SearchUserStatements(opensearch: true).create(new))
        guard case .value(let users) = try await driver.users(), let made = users.first(where: { $0.name == name && !$0.isRole }) else {
            return XCTFail("the user isn't listed")
        }
        XCTAssertTrue(users.contains { $0.name == "admin" && $0.superuser }, "admin is mapped to all_access")
        try await driver.run([try SearchUserStatements(opensearch: true).grantRole(DatabaseUser(name: "readall", isRole: true), to: made)])
        try await driver.run([try SearchUserStatements(opensearch: true).password(of: made, to: "Second-Pass_456!")])
        guard case .value(let again) = try await driver.users(), let granted = again.first(where: { $0.name == name && !$0.isRole }) else { return XCTFail() }
        XCTAssertEqual(granted.memberOf, ["readall"])
        guard case .value(let grants) = try await driver.grants(of: granted) else { return XCTFail("grants unread") }
        XCTAssertTrue(grants.contains { $0.kind == "index" }, "\(grants)")
        var signIn = config
        signIn.user = name
        do {
            try await SearchDriver(signIn, password: "Second-Pass_456!").connect()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("403"), "refused for want of monitor, not for the password: \(error)")
        }
        try await driver.run([try SearchUserStatements(opensearch: true).drop(granted)])
    }

    func testOpenSearch() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh search") }
        let driver = try await searchDriver(.opensearch)
        try await editHits(driver)
        guard case .value(let tasks) = try await driver.activity() else { return XCTFail("tasks unread") }
        XCTAssertFalse(tasks.isEmpty)
        switch try await driver.slowQueries() {
        case .value: break
        case .unavailable(let gap): XCTAssertFalse(gap.reason.isEmpty)
        }
        // Its security plugin is off there: said, not an empty list.
        guard case .unavailable(let gap) = try await driver.users() else { return XCTFail("security is off") }
        XCTAssertTrue(gap.reason.hasPrefix("Security is off"), gap.reason)
    }
}
