import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

/// The Server page, editing and users for the kinds whose rows are
/// documents or items — MongoDB and DocumentDB, Elasticsearch and
/// OpenSearch, DynamoDB —: their answers read, their statements made,
/// injection-shaped names kept inside their quotes. Pure; the servers are
/// `DocumentOperationsDriverTests`'.
final class DocumentOperationsTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Features

    func testKindsOfferWhatTheirEnginesHave() {
        XCTAssertEqual(DatabaseKind.mongodb.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.documentdb.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.elasticsearch.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.opensearch.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.dynamodb.features, [.monitoring, .editing], "IAM's users aren't DynamoDB's")
        XCTAssertEqual(MongoDriver.monitorParts(for: .mongodb), MonitorPart.allCases)
        XCTAssertEqual(MongoDriver.monitorParts(for: .documentdb), [.overview, .activity, .sizes], "DocumentDB's profiler is CloudWatch's")
        XCTAssertEqual(SearchDriver.monitorParts(for: .elasticsearch), [.overview, .activity, .slowQueries, .sizes])
        XCTAssertEqual(DynamoDBDriver.monitorParts(for: .dynamodb), [.overview, .sizes])
        let session = DatabaseActivity(id: "42")
        let mongo = MongoDriver.sessionStops(for: session, kind: .mongodb)
        XCTAssertEqual(mongo?.map(\.command), ["db.adminCommand({ killOp: 1, op: 42 })"])
        XCTAssertEqual(mongo?.map(\.terminate), [false], "an operation is killed, never its session")
        let task = SearchDriver.sessionStops(for: DatabaseActivity(id: "n1:7"), kind: .opensearch)
        XCTAssertEqual(task?.map(\.command), ["POST /_tasks/n1:7/_cancel"])
        XCTAssertEqual(DynamoDBDriver.sessionStops(for: session, kind: .dynamodb), [], "none offered")
        XCTAssertNil(PostgresDriver.sessionStops(for: session, kind: .postgres), "SQL's default")
        XCTAssertEqual(
            SessionStop.sql(for: DatabaseActivity(id: "7"), kind: .postgres).map(\.command), ["pg_cancel_backend(7)", "pg_terminate_backend(7)"], "SQL's words kept")
        XCTAssertEqual(SessionStop.sql(for: DatabaseActivity(id: "7"), kind: .mariadb).map(\.command), ["KILL QUERY 7", "KILL 7"])
    }

    // MARK: MongoDB: the Server page

    func testMongoOverviewReadsServerStatus() {
        let status: BSONDocument = [
            "version": .string("7.0.12"), "uptime": .double(3700), "host": .string("db1"),
            "connections": .document(["current": .int32(5), "available": .int32(995), "totalCreated": .int32(40)]),
            "opcounters": .document(["query": .int64(10), "insert": .int64(3), "update": .int64(0), "delete": .int64(0), "getmore": .int64(1), "command": .int64(20)]),
            "wiredTiger": .document(["cache": .document(["bytes currently in the cache": .int64(256), "maximum bytes configured": .int64(1024)])]),
        ]
        let overview = MongoOps.overview(status: status, hello: ["setName": .string("rs0"), "isWritablePrimary": .bool(true)], kind: .mongodb)
        let facts = Dictionary(overview.facts.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Version"]?.value, "7.0.12")
        XCTAssertEqual(facts["Connections"]?.value, "5 of 1000")
        XCTAssertEqual(facts["Operations"]?.value, "34")
        XCTAssertEqual(facts["Cache used"]?.value, "25.0%")
        XCTAssertEqual(facts["Topology"]?.value, "primary of rs0")
        XCTAssertEqual(MongoOps.overview(status: [:], hello: [:], kind: .mongodb).facts.last?.value, "standalone")
    }

    func testMongoActivityMarksItsOwnAndMasksPasswords() {
        let ops: [BSONDocument] = [
            [
                "opid": .int32(11), "active": .bool(true), "op": .string("command"), "ns": .string("admin.$cmd"), "client": .string("10.0.0.2:5000"),
                "connectionId": .int32(7), "appName": .string("mongosh"), "microsecs_running": .int64(2_500_000),
                "effectiveUsers": .array([.document(["user": .string("ot"), "db": .string("admin")])]),
                "command": .document(["createUser": .string("x"), "pwd": .string("hunter2"), "lsid": .document([:]), "$db": .string("admin")]),
            ],
            ["opid": .int32(12), "active": .bool(true), "connectionId": .int32(9), "client": .string("127.0.0.1:1"), "op": .string("command")],
            ["opid": .int32(13), "active": .bool(true), "desc": .string("TTLMonitor"), "op": .string("none")],
            ["active": .bool(true)],
        ]
        let sessions = MongoOps.activity(ops, own: 9)
        XCTAssertEqual(sessions.map(\.id), ["11", "12", "13"], "an operation without an id isn't one")
        XCTAssertEqual(sessions[0].user, "ot@admin")
        XCTAssertEqual(sessions[0].database, "admin")
        XCTAssertEqual(sessions[0].seconds, 2.5)
        XCTAssertEqual(sessions[0].statement, #"{ "createUser": "x", "pwd": "••••" }"#, "a password never shown, the session's noise left out")
        XCTAssertFalse(sessions[0].statement?.contains("hunter2") ?? true)
        XCTAssertTrue(sessions[1].isOwn)
        XCTAssertEqual(sessions[2].state, "daemon")
        XCTAssertFalse(sessions[2].isActive, "the server's own work is out of the busy list")
        XCTAssertEqual(MongoOps.operationID("12"), .int32(12))
        XCTAssertEqual(MongoOps.operationID("shard1:12"), .string("shard1:12"))
    }

    func testMongoProfilerSumsByShapeWithoutValues() {
        let entries: [BSONDocument] = [
            [
                "ns": .string("shop.orders"), "op": .string("query"), "millis": .int32(120), "nreturned": .int32(2),
                "command": .document(["find": .string("orders"), "filter": .document(["email": .string("ada@example.test")])]),
            ],
            [
                "ns": .string("shop.orders"), "op": .string("query"), "millis": .int32(80), "nreturned": .int32(1),
                "command": .document(["find": .string("orders"), "filter": .document(["email": .string("bob@example.test")])]),
            ],
            ["ns": .string("shop.users"), "op": .string("update"), "millis": .int32(300), "command": .document(["q": .document(["_id": .int32(1)])])],
        ]
        let queries = MongoOps.profiled(entries)
        XCTAssertEqual(queries.count, 2, "one statement whatever its values")
        XCTAssertEqual(queries[0].calls, 2)
        XCTAssertEqual(queries[0].total, 0.2, accuracy: 0.0001)
        XCTAssertEqual(queries[0].mean, 0.1, accuracy: 0.0001)
        XCTAssertEqual(queries[0].rows, 3)
        XCTAssertEqual(queries[0].database, "shop")
        XCTAssertEqual(queries[0].statement, #"shop.orders { "find": "?", "filter": { "email": "?" } }"#)
        XCTAssertFalse(queries.contains { $0.statement.contains("example.test") }, "no value is shown")
    }

    func testMongoLocksNameALikelyBlocker() {
        let ops: [BSONDocument] = [
            [
                "opid": .int32(1), "active": .bool(true), "client": .string("a"), "ns": .string("shop.orders"), "waitingForLock": .bool(true), "locks": .document(["Database": .string("w")]),
                "secs_running": .int32(4),
            ],
            [
                "opid": .int32(2), "active": .bool(true), "client": .string("b"), "ns": .string("shop.$cmd"), "locks": .document(["Database": .string("W")]), "secs_running": .int32(9),
                "command": .document(["compact": .string("orders")]),
            ],
            ["opid": .int32(3), "active": .bool(true), "client": .string("c"), "ns": .string("other.x"), "locks": .document(["Database": .string("X")]), "secs_running": .int32(20)],
        ]
        let waits = MongoOps.locks(ops)
        XCTAssertEqual(waits.count, 1)
        XCTAssertEqual(waits[0].waiting, "1")
        XCTAssertEqual(waits[0].blocking, "2", "the exclusive holder on the same database, not another's")
        XCTAssertEqual(waits[0].lock, "wants Database w on shop")
        let alone = MongoOps.locks([ops[0]])
        XCTAssertEqual(alone.first?.blocking, "?")
        XCTAssertEqual(alone.first?.blockingStatement, "MongoDB doesn't say who holds it")
    }

    func testMongoSizes() {
        let (tables, indexes) = MongoOps.collections(
            [
                ("small", ["count": .int32(1), "size": .int32(10), "storageSize": .int32(4096), "indexSizes": .document(["_id_": .int32(4096)])]),
                ("big", ["count": .int32(5), "size": .int32(900), "storageSize": .int32(8192), "indexSizes": .document(["_id_": .int32(4096), "email_1": .int32(12288)])]),
            ], database: "shop")
        XCTAssertEqual(tables.map(\.name), ["big", "small"])
        XCTAssertEqual(tables[0].detail, "5 docs · data 900 bytes")
        XCTAssertEqual(indexes.first?.name, "email_1")
        XCTAssertEqual(indexes.first?.detail, "on big")
    }

    // MARK: MongoDB: editing documents

    private func mongoResult(_ statement: String = #"db.getSiblingDB("shop").orders.find({})"#) throws -> EditableResult {
        let result = QueryResult(
            columns: ["_id", "status", "total", "when", "tags"], types: ["objectId", "string", "double", "date", "array"],
            rows: [[#"ObjectId("65f1a2b3c4d5e6f708192a3b")"#, "open", "9.5", "2026-01-02T03:04:05.000Z", #"["a"]"#]])
        return try MongoEdits.editable(try MongoText.command(statement), database: "shop", result: result).get()
    }

    func testMongoFindIsEditableByItsID() throws {
        let editable = try mongoResult()
        XCTAssertEqual(editable.key.columns, ["_id"])
        XCTAssertEqual(editable.key.table, TableName(schema: "shop", name: "orders"))
        XCTAssertTrue(editable.removesFields)
        XCTAssertEqual(editable.key.summary, "_id")
        func refused(_ statement: String, _ columns: [String] = ["_id", "a"], types: [String] = ["int", "int"]) -> String? {
            guard let command = try? MongoText.command(statement) else { return "unread" }
            if case .failure(let refusal) = MongoEdits.editable(command, database: "shop", result: QueryResult(columns: columns, types: types, rows: [])) {
                return refusal.message
            }
            return nil
        }
        XCTAssertNotNil(refused("db.orders.aggregate([{ $match: {} }])"))
        XCTAssertNotNil(refused("db.orders.find({}, { total: { $multiply: [\"$a\", 2] } })"), "a computed projection")
        XCTAssertNil(refused("db.orders.find({}, { status: 1 })"), "a plain projection")
        XCTAssertEqual(refused("db.orders.find({}, { _id: 0 })", ["a"], types: ["int"]), EditRefusal.keyNotShown(["_id"]).message)
        XCTAssertNotNil(refused("db.orders.find({})", ["_id"], types: ["mixed"]), "ids of several types")
    }

    func testMongoStatementsAreTheConsolesAndRoundTrip() throws {
        let editable = try mongoResult()
        let rows: [[String?]] = [[#"ObjectId("65f1a2b3c4d5e6f708192a3b")"#, "open", "9.5", "2026-01-02T03:04:05.000Z", #"["a"]"#]]
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(#"it's "x"; db.dropDatabase()"#), original: "open")
        edits.set(row: 0, column: 2, to: .text("12"), original: "9.5")
        edits.set(row: 0, column: 4, to: .absent, original: #"["a"]"#)
        edits.add([1: .text("new"), 3: .text("2026-02-01")])
        var deleting = edits
        deleting.discard()
        deleting.delete(rows: [0])
        let statements = try MongoEdits.statements(edits, rows: rows, result: editable)
        let target = #"db.getSiblingDB("shop").getCollection("orders")"#
        XCTAssertEqual(
            statements.map(\.sql),
            [
                target + #".updateOne({ "_id": ObjectId("65f1a2b3c4d5e6f708192a3b") }, { "$set": { "status": "it's \"x\"; db.dropDatabase()", "total": 12.0 }, "$unset": { "tags": "" } })"#,
                target + #".insertOne({ "status": "new", "when": ISODate("2026-02-01T00:00:00.000Z") })"#,
            ])
        XCTAssertEqual(
            try MongoEdits.statements(deleting, rows: rows, result: editable).map(\.sql),
            [target + #".deleteOne({ "_id": ObjectId("65f1a2b3c4d5e6f708192a3b") })"#])
        // What is shown is what runs: the console reads each back to the same command.
        let update = try MongoText.command(statements[0].sql)
        XCTAssertEqual(update.database, "shop")
        XCTAssertEqual(update.collection, "orders")
        let u = update.body["updates"]?.array?.first?.document
        XCTAssertEqual(u?["q"]?.document?["_id"], .objectId(ObjectID(hex: "65f1a2b3c4d5e6f708192a3b")!))
        XCTAssertEqual(u?["u"]?.document?["$set"]?.document?["status"], .string(#"it's "x"; db.dropDatabase()"#), "a value never ends the statement")
        XCTAssertEqual(u?["u"]?.document?["$set"]?.document?["total"], .double(12), "a double column stays a double")
        XCTAssertEqual(u?["multi"], .bool(false))
    }

    func testMongoValuesAreReadByTheirColumnsType() throws {
        XCTAssertEqual(try MongoEdits.value("42", type: "int"), .int32(42))
        XCTAssertEqual(try MongoEdits.value("42", type: "long"), .int64(42))
        XCTAssertEqual(try MongoEdits.value("42", type: "string"), .string("42"))
        XCTAssertEqual(try MongoEdits.value("65f1a2b3c4d5e6f708192a3b", type: "objectId"), .objectId(ObjectID(hex: "65f1a2b3c4d5e6f708192a3b")!))
        XCTAssertEqual(try MongoEdits.value("false", type: "bool"), .bool(false))
        XCTAssertEqual(try MongoEdits.value(#"{ "a": 1 }"#, type: "object"), .document(["a": .int32(1)]))
        XCTAssertEqual(try MongoEdits.value("plain words", type: "mixed"), .string("plain words"), "several types: else the text")
        XCTAssertEqual(try MongoEdits.value("7", type: "mixed"), .int32(7))
        XCTAssertThrowsError(try MongoEdits.value("not a number", type: "int"))
        XCTAssertThrowsError(try MongoEdits.value("{ broken", type: "object"))
    }

    func testMongoRefusesWhatItCantWrite() throws {
        let editable = try mongoResult()
        let rows: [[String?]] = [[#"ObjectId("65f1a2b3c4d5e6f708192a3b")"#, "open", "9.5", nil, nil]]
        var id = PendingEdits()
        id.set(row: 0, column: 0, to: .text("1"), original: rows[0][0])
        XCTAssertThrowsError(try MongoEdits.statements(id, rows: rows, result: editable), "an _id isn't changed")
        var dotted = editable
        dotted.columns[1] = "a.b"
        var edit = PendingEdits()
        edit.set(row: 0, column: 1, to: .text("x"), original: "open")
        XCTAssertThrowsError(try MongoEdits.statements(edit, rows: rows, result: dotted), "$set would read a dot as a path")
    }

    func testMongoDocumentDBAndMixedTypesAreSaid() {
        let result = MongoResult.rows([["_id": .int32(1), "a": .int32(1)], ["_id": .string("x"), "a": .null], ["_id": .int32(3), "a": .int32(2)]], limit: 10)
        XCTAssertEqual(result.types, ["mixed", "int"], "a null isn't a type of its own")
    }

    // MARK: MongoDB: users

    func testMongoUsersAndGrantsNeverHoldCredentials() {
        let users = MongoOps.users([
            ["user": .string("ada"), "db": .string("shop"), "roles": .array([.document(["role": .string("readWrite"), "db": .string("shop")])]), "mechanisms": .array([.string("SCRAM-SHA-256")])],
            ["user": .string("root"), "db": .string("admin"), "roles": .array([.document(["role": .string("root"), "db": .string("admin")])])],
        ])
        XCTAssertEqual(users.map(\.display), ["root@admin", "ada@shop"])
        XCTAssertTrue(users[0].superuser)
        XCTAssertEqual(users[1].memberOf, ["readWrite@shop"])
        let grants = MongoOps.grants([
            "roles": .array([.document(["role": .string("readWrite"), "db": .string("shop")])]),
            "inheritedPrivileges": .array([
                .document(["resource": .document(["db": .string("shop"), "collection": .string("")]), "actions": .array([.string("update"), .string("find")])]),
                .document(["resource": .document(["cluster": .bool(true)]), "actions": .array([.string("listDatabases")])]),
            ]),
        ])
        XCTAssertEqual(grants.map(\.kind), ["role", "database", "server"])
        XCTAssertEqual(grants[1].privileges, ["find", "update"])
        let revoke = MongoUserStatements().revoke(grants[0], from: users[1])
        XCTAssertEqual(revoke?.sql, #"db.getSiblingDB("shop").runCommand({ "revokeRolesFromUser": "ada", "roles": [{ "role": "readWrite", "db": "shop" }] })"#)
        XCTAssertNil(MongoUserStatements().revoke(grants[1], from: users[1]), "a role's privilege isn't the user's to revoke")
    }

    func testMongoUserStatementsQuoteAndMaskThePassword() throws {
        var user = NewUser()
        user.name = #"a"b'; db.dropDatabase()"#
        user.host = "admin"
        user.password = #"p"w'd"#
        let create = try MongoUserStatements().create(user)
        XCTAssertEqual(create.count, 1)
        XCTAssertFalse(create[0].shown.contains("p\\\"w'd"), "the preview never shows the password")
        XCTAssertTrue(create[0].shown.contains(#""pwd": "••••••••""#))
        let command = try MongoText.command(create[0].sql)
        XCTAssertEqual(command.database, "admin")
        XCTAssertEqual(command.body["createUser"], .string(#"a"b'; db.dropDatabase()"#), "a name never ends the command")
        XCTAssertEqual(command.body["pwd"], .string(#"p"w'd"#))
        let ada = DatabaseUser(name: "ada", host: "shop")
        let password = try MongoUserStatements().password(of: ada, to: "s3cret")
        XCTAssertEqual(password.shown, #"db.getSiblingDB("shop").runCommand({ "updateUser": "ada", "pwd": "••••••••" })"#)
        XCTAssertEqual(
            try MongoUserStatements().grant(["read", "dbAdmin"], on: .database("shop"), to: ada, grantOption: false).sql,
            #"db.getSiblingDB("shop").runCommand({ "grantRolesToUser": "ada", "roles": [{ "role": "read", "db": "shop" }, { "role": "dbAdmin", "db": "shop" }] })"#)
        XCTAssertThrowsError(try MongoUserStatements().grant(["root"], on: .database("shop"), to: ada, grantOption: false), "root is admin's")
        XCTAssertEqual(MongoUserStatements().privileges(on: .database("admin")).last, "root")
        XCTAssertEqual(MongoUserStatements().form.grantKinds.map(\.title), ["Database"])
        XCTAssertEqual(try MongoUserStatements().drop(DatabaseUser(name: "app", host: "shop", isRole: true)).sql, #"db.getSiblingDB("shop").runCommand({ "dropRole": "app" })"#)
        XCTAssertEqual(
            try MongoUserStatements().grantRole(DatabaseUser(name: "auditor", host: "admin", isRole: true), to: ada).sql,
            #"db.getSiblingDB("shop").runCommand({ "grantRolesToUser": "ada", "roles": [{ "role": "auditor", "db": "admin" }] })"#)
        XCTAssertThrowsError(try MongoUserStatements().password(of: DatabaseUser(name: "r", host: "admin", isRole: true), to: "x"))
    }

    // MARK: Elasticsearch and OpenSearch

    func testSearchHitsKeepTheirTypesAndVersions() throws {
        let data = Data(
            #"""
            {"hits": {"total": {"value": 2, "relation": "eq"}, "hits": [
              {"_index": "orders", "_id": "a/1", "_seq_no": 5, "_primary_term": 1, "_score": 1.0, "_source": {"note": "x", "qty": 2, "paid": true, "tags": ["a"], "mix": 1}},
              {"_index": "orders", "_id": "2", "_seq_no": 6, "_primary_term": 1, "_score": 1.0, "_routing": "r", "_source": {"note": null, "qty": 3, "mix": "one"}}
            ]}}
            """#.utf8)
        let result = SearchResults.result(data, request: SearchRequest(method: "GET", path: "/orders/_search", body: nil), status: 200, limit: 10)
        XCTAssertEqual(result.columns, ["_index", "_id", "_score", "_seq_no", "_primary_term", "_routing", "mix", "note", "paid", "qty", "tags"])
        XCTAssertEqual(result.types, ["string", "string", "number", "number", "number", "string", "mixed", "string", "boolean", "number", "array"])
        XCTAssertEqual(result.rows[0][3], "5")
        XCTAssertEqual(result.rows[1][5], "r")
    }

    private func searchEditable(_ result: QueryResult, path: String = "/orders/_search") throws -> EditableResult {
        try SearchEdits.editable(SearchRequest(method: "GET", path: path, body: nil), result: result).get()
    }

    func testSearchEditsAreDevToolsRequestsOnTheVersionRead() throws {
        let result = QueryResult(
            columns: ["_index", "_id", "_seq_no", "_primary_term", "note", "qty", "tags"], types: ["string", "string", "number", "number", "string", "number", "array"],
            rows: [["orders", "a/1?x", "5", "1", "old", "2", #"["a"]"#]])
        let editable = try searchEditable(result)
        XCTAssertEqual(editable.key.table.name, "orders")
        XCTAssertFalse(editable.isEditable(2), "_seq_no is read only")
        var edits = PendingEdits()
        edits.set(row: 0, column: 4, to: .text(#"it's "new""#), original: "old")
        edits.set(row: 0, column: 5, to: .text("7"), original: "2")
        edits.add([4: .text("fresh"), 5: .text("1")])
        edits.add([1: .text("my id"), 4: .null])
        var statements = try SearchEdits.statements(edits, rows: result.rows, result: editable)
        XCTAssertEqual(
            statements.map(\.sql),
            [
                "POST /orders/_update/a%2F1%3Fx?if_seq_no=5&if_primary_term=1&refresh=wait_for\n" + #"{"doc":{"note":"it's \"new\"","qty":7}}"#,
                "POST /orders/_doc?refresh=wait_for\n" + #"{"note":"fresh","qty":1}"#,
                "PUT /orders/_create/my%20id?refresh=wait_for\n" + #"{"note":null}"#,
            ])
        XCTAssertEqual(statements[0].terminator, "\n")
        // The console reads it back: one segment, the id whole.
        let request = try SearchRequest.parse(statements[0].sql)
        XCTAssertEqual(request.endpoint, "_update")
        XCTAssertEqual(request.parts.last, "a/1?x")
        // A field removed: a script, the values as its parameters.
        var removing = PendingEdits()
        removing.set(row: 0, column: 6, to: .absent, original: #"["a"]"#)
        removing.delete(rows: [])
        statements = try SearchEdits.statements(removing, rows: result.rows, result: editable)
        XCTAssertTrue(statements[0].sql.contains(#""params":{"set":{},"unset":["tags"]}"#), statements[0].sql)
        var deleting = PendingEdits()
        deleting.delete(rows: [0])
        XCTAssertEqual(
            try SearchEdits.statements(deleting, rows: result.rows, result: editable).map(\.sql),
            ["DELETE /orders/_doc/a%2F1%3Fx?if_seq_no=5&if_primary_term=1&refresh=wait_for"])
    }

    func testSearchRefusesWhatItCantWrite() throws {
        let result = QueryResult(columns: ["_index", "_id", "n"], types: ["string", "string", "number"], rows: [["o1", "1", "2"]])
        let several = try searchEditable(result, path: "/o*/_search")
        var added = PendingEdits()
        added.add([2: .text("1")])
        XCTAssertThrowsError(try SearchEdits.statements(added, rows: result.rows, result: several), "a pattern names no index for a new hit")
        added.set(new: 0, column: 0, to: .text("o2"))
        XCTAssertEqual(try SearchEdits.statements(added, rows: result.rows, result: several).first?.sql.hasPrefix("POST /o2/_doc"), true)
        var id = PendingEdits()
        id.set(row: 0, column: 1, to: .text("9"), original: "1")
        XCTAssertThrowsError(try SearchEdits.statements(id, rows: result.rows, result: several))
        var notNumber = PendingEdits()
        notNumber.set(row: 0, column: 2, to: .text("two"), original: "2")
        XCTAssertThrowsError(try SearchEdits.statements(notNumber, rows: result.rows, result: several))
        let filtered = SearchRequest(method: "GET", path: "/o/_search", body: #"{"_source": ["n"]}"#)
        if case .success = SearchEdits.editable(filtered, result: result) { XCTFail("a _source filter shows part of a document") }
        if case .success = SearchEdits.editable(SearchRequest(method: "GET", path: "/_cat/indices", body: nil), result: result) { XCTFail("not hits") }
        if case .failure = SearchEdits.editable(SearchRequest(method: "GET", path: "/o/_search", body: #"{"_source": true}"#), result: result) { XCTFail("_source: true is whole") }
    }

    func testSearchOverviewTasksAndSlowlog() throws {
        let overview = SearchOps.overview(
            product: "Elasticsearch 8.15.3",
            health: json(#"{"cluster_name": "c", "status": "yellow", "number_of_nodes": 1, "number_of_data_nodes": 1, "active_shards": 5, "active_primary_shards": 5, "unassigned_shards": 2}"#),
            nodes: json(
                #"{"nodes": {"n1": {"jvm": {"mem": {"heap_used_in_bytes": 256, "heap_max_in_bytes": 1024}}, "os": {"cpu": {"percent": 12}}, "fs": {"total": {"total_in_bytes": 1000, "available_in_bytes": 250}}}}}"#
            ))
        let facts = Dictionary(overview.facts.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Health"]?.value, "yellow")
        XCTAssertEqual(facts["Shards"]?.detail, "5 primary · 2 unassigned")
        XCTAssertEqual(facts["Heap"]?.value, "25.0%")
        XCTAssertEqual(facts["Disk used"]?.value, "75.0%")
        let tasks = SearchOps.tasks(
            json(
                #"{"tasks": [{"node": "n1", "id": 7, "action": "indices:data/read/search", "description": "indices[orders], search_type[QUERY_THEN_FETCH]", "running_time_in_nanos": 2000000000, "cancellable": true, "headers": {"X-Opaque-Id": "report"}}, {"node": "n1", "id": 8, "action": "cluster:monitor/tasks/lists", "running_time_in_nanos": 1000, "cancellable": false}]}"#
            ))
        XCTAssertEqual(tasks.map(\.id), ["n1:7", "n1:8"])
        XCTAssertEqual(tasks[0].database, "orders")
        XCTAssertEqual(tasks[0].application, "report")
        XCTAssertEqual(tasks[0].seconds, 2)
        XCTAssertTrue(tasks[1].isOwn, "the listing's own task")
        XCTAssertEqual(SearchOps.tasks(json(#"{"nodes": {"n1": {"tasks": {"n1:9": {"action": "x"}}}}}"#)).map(\.id), ["n1:9"], "grouped by node")
        XCTAssertEqual(
            SearchOps.cancelFailure(
                Data(#"{"node_failures": [{"type": "failed_node_exception", "reason": "Failed node [nonode]", "caused_by": {"reason": "no such node [nonode]"}}], "nodes": {}}"#.utf8)),
            "no such node [nonode]")
        XCTAssertTrue(SearchOps.insightsOff(json(#"{"defaults": {"search.insights.top_queries.latency.enabled": "false"}}"#)))
        XCTAssertFalse(SearchOps.insightsOff(json(#"{"persistent": {"search.insights.top_queries.latency.enabled": "true"}, "defaults": {"search.insights.top_queries.latency.enabled": "false"}}"#)))
        XCTAssertNil(SearchOps.cancelFailure(Data(#"{"nodes": {"n1": {"tasks": {}}}}"#.utf8)))
        XCTAssertTrue(SearchOps.isTaskID("oTUltX4IQMOUUVeiohTt8A:12"))
        XCTAssertFalse(SearchOps.isTaskID("../_security/user:1"))
        let gap = SearchOps.slowlogGap(
            json(#"{"orders": {"settings": {"index.search.slowlog.threshold.query.warn": "1s", "index.search.slowlog.threshold.fetch.warn": "-1"}}, "logs": {"settings": {}}}"#), kind: .elasticsearch)
        XCTAssertTrue(gap.reason.contains("orders: query.warn 1s"), gap.reason)
        XCTAssertTrue(gap.fix?.hasPrefix("PUT /<index>/_settings") == true)
        XCTAssertEqual(SearchOps.hotThreads("::: {n1}\n   12.3% (61ms out of 500ms) cpu usage by thread 'search'\n  more"), ["Hot thread: 12.3% (61ms out of 500ms) cpu usage by thread 'search'"])
        let top = SearchOps.topQueries(
            Data(#"{"top_queries": [{"id": "q", "indices": ["orders"], "source": {"size": 1}, "measurements": {"latency": {"number": 40, "count": 4, "aggregationType": "AVERAGE"}}}]}"#.utf8))
        XCTAssertEqual(top.first?.calls, 4)
        XCTAssertEqual(top.first?.total ?? 0, 0.16, accuracy: 0.0001)
        let sizes = SearchOps.sizes([
            ["index": "orders", "docs.count": "3", "store.size": "2048", "pri": "1", "rep": "1", "health": "yellow", "status": "open"],
            ["index": ".security-7", "store.size": "999999"],
        ])
        XCTAssertEqual(sizes.tables.map(\.name), ["orders"], "a hidden index isn't listed")
        XCTAssertEqual(sizes.tables[0].detail, "3 docs · yellow · 1 pri/1 rep")
    }

    func testSearchUsersRolesAndStatements() throws {
        let users = SearchOps.elasticUsers(
            [
                "ada": ["username": "ada", "roles": ["viewer", "editor"], "full_name": "Ada L", "email": "ada@example.test", "enabled": true, "metadata": ["_x": 1]],
                "elastic": ["roles": ["superuser"], "metadata": ["_reserved": true]],
            ],
            roles: ["viewer": ["metadata": ["_reserved": true], "cluster": [], "indices": [["names": ["*"], "privileges": ["read"]]]], "editor": [:]])
        XCTAssertEqual(users.map(\.name), ["ada", "elastic", "editor", "viewer"])
        XCTAssertEqual(users[0].memberOf, ["editor", "viewer"])
        XCTAssertTrue(users[1].superuser)
        XCTAssertEqual(users[1].attributes, ["built-in"])
        let grants = SearchOps.grants(of: users[0], roles: ["viewer": ["cluster": ["monitor"], "indices": [["names": ["*"], "privileges": ["read"]]]]])
        XCTAssertEqual(grants.map(\.kind), ["role", "role", "server", "index"])
        XCTAssertEqual(grants[3].object, "* (viewer)")

        var new = NewUser()
        new.name = "a/b?c"
        new.password = #"p"w"#
        let create = try SearchUserStatements().create(new)
        XCTAssertEqual(create[0].sql, "POST /_security/user/a%2Fb%3Fc\n" + #"{"password":"p\"w","roles":[]}"#)
        XCTAssertEqual(create[0].shown, "POST /_security/user/a%2Fb%3Fc\n" + #"{"password":"••••••••","roles":[]}"#)
        XCTAssertEqual(try SearchRequest.parse(create[0].sql).parts.last, "a/b?c", "the name stays one segment")
        XCTAssertEqual(
            try SearchUserStatements().password(of: users[0], to: "x").shown, "POST /_security/user/ada/_password\n" + #"{"password":"••••••••"}"#)
        let grant = try SearchUserStatements().grantRole(DatabaseUser(name: "monitoring_user", isRole: true), to: users[0])
        XCTAssertEqual(
            grant.sql, "POST /_security/user/ada\n" + #"{"email":"ada@example.test","enabled":true,"full_name":"Ada L","roles":["editor","viewer","monitoring_user"]}"#,
            "the update writes the user whole: its name and email kept")
        XCTAssertEqual(
            SearchUserStatements().revoke(grants[0], from: users[0])?.sql,
            "POST /_security/user/ada\n" + #"{"email":"ada@example.test","enabled":true,"full_name":"Ada L","roles":["viewer"]}"#)
        var tagged = users[0]
        tagged.attributes.append(SearchUserStatements.hasMetadata)
        XCTAssertThrowsError(try SearchUserStatements().grantRole(DatabaseUser(name: "x", isRole: true), to: tagged), "its metadata would be lost")
        XCTAssertNil(SearchUserStatements().revoke(grants[2], from: users[0]))
        XCTAssertEqual(try SearchUserStatements(opensearch: true).drop(DatabaseUser(name: "r", isRole: true)).sql, "DELETE /_plugins/_security/api/roles/r")
        XCTAssertTrue(SearchUserStatements().form.grantKinds.isEmpty, "no Grant…: roles")

        let open = SearchOps.openSearchUsers(
            ["bob": ["hash": "", "opendistro_security_roles": ["readall"], "backend_roles": ["dev"]], "kibanaserver": ["reserved": true], "ghost": ["hidden": true]],
            roles: ["readall": ["reserved": true], "all_access": [:]], mapping: ["all_access": ["users": ["bob"]], "kibana_user": ["backend_roles": ["dev"]]])
        XCTAssertEqual(open.map(\.name), ["bob", "kibanaserver", "all_access", "readall"], "a hidden one isn't listed")
        XCTAssertEqual(open[0].memberOf, ["readall"])
        XCTAssertTrue(open[0].superuser)
        XCTAssertEqual(open[0].attributes, ["mapped: all_access, kibana_user", "backend roles: dev"], "by name and by backend role")
        let openGrants = SearchOps.grants(of: open[0], roles: [:])
        XCTAssertEqual(openGrants.map(\.kind), ["role", "mapped role", "mapped role"])
        XCTAssertNil(SearchUserStatements(opensearch: true).revoke(openGrants[1], from: open[0]), "a mapping's role is the mapping's")
        XCTAssertEqual(
            try SearchUserStatements(opensearch: true).password(of: open[0], to: "x").shown,
            "PATCH /_plugins/_security/api/internalusers/bob\n" + #"[{"op":"add","path":"/password","value":"••••••••"}]"#)
        XCTAssertEqual(SearchOps.securityGap(status: 403, said: "action denied", kind: .elasticsearch, user: "ot").reason.contains("manage_security"), true)
        XCTAssertTrue(SearchOps.securityGap(status: 500, said: "Security must be explicitly enabled", kind: .elasticsearch, user: "").reason.hasPrefix("Security is off"))
    }

    // MARK: DynamoDB

    private let tableDescription: [String: Any] = [
        "TableName": "orders", "KeySchema": [["AttributeName": "pk", "KeyType": "HASH"], ["AttributeName": "sk", "KeyType": "RANGE"]],
        "AttributeDefinitions": [["AttributeName": "pk", "AttributeType": "S"], ["AttributeName": "sk", "AttributeType": "N"]],
    ]

    func testDynamoItemsAreEditableByTheirKeys() throws {
        let result = QueryResult(columns: ["pk", "sk", "note", "blob"], types: ["S", "", "S", "B"], rows: [])
        let editable = try DynamoEdits.editable(table: "orders", description: tableDescription, result: result).get()
        XCTAssertEqual(editable.key.columns, ["pk", "sk"])
        XCTAssertEqual(editable.types[1], "N", "a key's type is the table's")
        XCTAssertFalse(editable.isEditable(3), "binary has no PartiQL literal")
        XCTAssertEqual(editable.key.summary, "partition key pk and sort key sk")
        if case .success = DynamoEdits.editable(table: "orders", description: tableDescription, result: QueryResult(columns: ["pk", "note"], types: ["S", "S"], rows: [])) {
            XCTFail("the sort key isn't shown")
        }
        XCTAssertTrue(DynamoEdits.readsIndex(#"SELECT * FROM "orders"."byStatus""#))
        XCTAssertTrue(DynamoEdits.readsIndex("SELECT * FROM orders.byStatus WHERE a = 1"))
        XCTAssertFalse(DynamoEdits.readsIndex(#"SELECT * FROM "orders" WHERE pk = 'a.b'"#))
    }

    func testDynamoStatementsArePartiQLWithConditions() throws {
        let result = QueryResult(columns: ["pk", "sk", "note", "n", "meta"], types: ["S", "N", "S", "N", "M"], rows: [["a'b", "1", "old", "5", #"{"k":1}"#]])
        let editable = try DynamoEdits.editable(table: #"or"ders"#, description: tableDescription, result: result).get()
        var edits = PendingEdits()
        edits.set(row: 0, column: 2, to: .text("it's; DROP"), original: "old")
        edits.set(row: 0, column: 4, to: .text(#"{"b": [1, "x", true, null]}"#), original: #"{"k":1}"#)
        edits.set(row: 0, column: 3, to: .absent, original: "5")
        edits.add([0: .text("new"), 1: .text("2"), 2: .text("hi")])
        var deleting = PendingEdits()
        deleting.delete(rows: [0])
        XCTAssertEqual(
            try DynamoEdits.statements(edits, rows: result.rows, result: editable).map(\.sql),
            [
                #"UPDATE "or""ders" SET "note" = 'it''s; DROP' REMOVE "n" SET "meta" = {'b': [1, 'x', true, NULL]} WHERE "pk" = 'a''b' AND "sk" = 1 AND "note" = 'old' AND "n" = 5"#,
                #"INSERT INTO "or""ders" VALUE {'pk': 'new', 'sk': 2, 'note': 'hi'}"#,
            ])
        XCTAssertEqual(
            try DynamoEdits.statements(deleting, rows: result.rows, result: editable).map(\.sql),
            [#"DELETE FROM "or""ders" WHERE "pk" = 'a''b' AND "sk" = 1"#])
        var key = PendingEdits()
        key.set(row: 0, column: 0, to: .text("z"), original: "a'b")
        XCTAssertThrowsError(try DynamoEdits.statements(key, rows: result.rows, result: editable), "a key isn't changed")
        var noKey = PendingEdits()
        noKey.add([2: .text("x")])
        XCTAssertThrowsError(try DynamoEdits.statements(noKey, rows: result.rows, result: editable), "a new item needs its keys")
        XCTAssertThrowsError(try DynamoEdits.literal("1; DROP", type: "N"))
        XCTAssertEqual(try DynamoEdits.literal(#"["a","b"]"#, type: "SS"), "<<'a', 'b'>>")
        XCTAssertEqual(try DynamoEdits.literal("12", type: ""), "12", "a new attribute: JSON when it reads so")
        XCTAssertEqual(try DynamoEdits.literal("twelve", type: "mixed"), "'twelve'")
        var many = PendingEdits()
        for _ in 0...DynamoEdits.transactionLimit { many.add([0: .text("p"), 1: .text("1")]) }
        XCTAssertThrowsError(try DynamoEdits.statements(many, rows: result.rows, result: editable), "a transaction takes 100")
    }

    func testDynamoSizesSayEachTable() {
        let (entry, indexes) = DynamoOps.table(
            [
                "TableName": "orders", "ItemCount": 3, "TableSizeBytes": 120, "BillingModeSummary": ["BillingMode": "PAY_PER_REQUEST"],
                "GlobalSecondaryIndexes": [["IndexName": "byStatus", "IndexSizeBytes": 40, "ItemCount": 3, "KeySchema": [["AttributeName": "status"]]]],
            ], ttl: ["TimeToLiveDescription": ["TimeToLiveStatus": "ENABLED", "AttributeName": "expires"]],
            backups: ["ContinuousBackupsDescription": ["PointInTimeRecoveryDescription": ["PointInTimeRecoveryStatus": "DISABLED"]]])
        XCTAssertEqual(entry.detail, "3 items · on-demand · 1 GSI · TTL on expires · PITR off")
        XCTAssertEqual(entry.bytes, 120)
        XCTAssertEqual(indexes.first?.detail, "GSI on status · 3 items")
        XCTAssertEqual(indexes.first?.schema, "orders")
        let provisioned = DynamoOps.table(["TableName": "t", "ProvisionedThroughput": ["ReadCapacityUnits": 5, "WriteCapacityUnits": 2]], ttl: nil, backups: nil).0
        XCTAssertEqual(provisioned.detail, "0 items · 5/2 RCU/WCU")
    }

    // MARK: The shared grid

    func testAbsentIsItsOwnValue() {
        var edits = PendingEdits()
        edits.set(row: 0, column: 0, to: .absent, original: nil)
        XCTAssertTrue(edits.isEdited(row: 0, column: 0), "removing a field isn't setting it to null")
        XCTAssertNil(CellValue.absent.text)
        XCTAssertEqual(EditStatement.listing([EditStatement(sql: "a"), EditStatement(sql: "GET /\n{}", terminator: "\n")]), "a;\nGET /\n{}\n")
    }
}
