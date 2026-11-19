import CryptoKit
import XCTest

@testable import Overterm

/// The Server page, node editing and users of Neo4j, InfluxDB, RabbitMQ and
/// Redis — every pure part: the engines' answers read, the statements and
/// requests made (names that try to end them included), the key found.
final class KindOperationsTests: XCTestCase {
    // MARK: The shared shape

    func testWhichKindsHaveWhat() {
        XCTAssertEqual(DatabaseKind.neo4j.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.influxdb.features, [.monitoring, .users])
        XCTAssertEqual(DatabaseKind.rabbitmq.features, [.monitoring, .users])
        XCTAssertEqual(DatabaseKind.redis.features, [.monitoring, .users], "a key has its own page: no rows edited")
    }

    func testSizesThatCountThings() {
        XCTAssertEqual(SizeEntry(name: "Person", bytes: 3, unit: "nodes").size, "3 nodes")
        XCTAssertEqual(SizeEntry(name: "q", bytes: 2048).size, OpsText.bytes(2048))
    }

    func testRequestLines() {
        let request = UserRequest(#"NEW PUT /api/users/a%2Fb {"tags":""}"#)
        XCTAssertEqual(request?.onlyNew, true)
        XCTAssertEqual(request?.method, "PUT")
        XCTAssertEqual(request?.path, "/api/users/a%2Fb")
        XCTAssertEqual(request?.body, #"{"tags":""}"#)
        XCTAssertNil(UserRequest("DROP /api/users/x"), "only HTTP's methods")
        XCTAssertNil(UserRequest("GET /etc/passwd"), "only the API's paths")
    }

    func testTheSQLMakerIsUserStatements() throws {
        let maker = SQLUserStatements(dialect: .mysql)
        let table = maker.form.grantKinds.first { $0.title == "Table" }
        XCTAssertEqual(table?.fields.map(\.title), ["Database", "Table"])
        XCTAssertEqual(maker.target(try XCTUnwrap(table), fields: ["shop", "orders"]), .table(TableName(schema: "shop", name: "orders")))
        XCTAssertFalse(maker.offers(.password, on: DatabaseUser(name: "r", isRole: true)), "a MySQL role has no password")
        XCTAssertTrue(SQLUserStatements(dialect: .postgres).offers(.password, on: DatabaseUser(name: "r", isRole: true)))
        XCTAssertEqual(SQLUserStatements(dialect: .postgres).form.login, true)
    }

    // MARK: Redis

    func testRedisClientsAsSessions() {
        let clients = RedisClients.parse(
            """
            id=3 addr=127.0.0.1:5000 name= age=10 idle=0 flags=N db=0 cmd=client|list user=default
            id=4 addr=10.0.0.2:6000 name=worker age=99 idle=42 flags=N db=2 cmd=get user=app
            id=5 addr=10.0.0.3:6001 name= age=5 idle=3 flags=b db=0 cmd=blpop user=app
            """)
        let sessions = RedisOps.activity(clients, own: "3")
        XCTAssertEqual(sessions.map(\.id), ["3", "4", "5"])
        XCTAssertTrue(sessions[0].isOwn)
        XCTAssertEqual(sessions[0].statement, "CLIENT LIST")
        XCTAssertEqual(sessions[1].state, "idle")
        XCTAssertFalse(sessions[1].isActive)
        XCTAssertEqual(sessions[1].application, "worker")
        XCTAssertEqual(sessions[1].database, "db2")
        XCTAssertEqual(sessions[2].state, "blocked")
        XCTAssertNotNil(sessions[2].waiting)
    }

    func testRedisSlowLogTogetherAndMasked() {
        let entries = [
            RedisSlowEntry(id: 1, date: Date(), micros: 2000, command: "GET a", client: ""),
            RedisSlowEntry(id: 2, date: Date(), micros: 4000, command: "GET a", client: ""),
            RedisSlowEntry(id: 3, date: Date(), micros: 1000, command: "ACL SETUSER bob on >hunter2 #abcdef", client: ""),
            RedisSlowEntry(id: 4, date: Date(), micros: 1000, command: "AUTH bob hunter2", client: ""),
        ]
        let slow = RedisOps.slowQueries(entries)
        XCTAssertEqual(slow.first?.statement, "GET a")
        XCTAssertEqual(slow.first?.calls, 2)
        XCTAssertEqual(slow.first?.total ?? 0, 0.006, accuracy: 1e-9)
        XCTAssertEqual(slow.first?.mean ?? 0, 0.003, accuracy: 1e-9)
        XCTAssertFalse(slow.contains { $0.statement.contains("hunter2") || $0.statement.contains("abcdef") }, "\(slow.map(\.statement))")
        XCTAssertTrue(slow.contains { $0.statement == "ACL SETUSER bob on >•••• #••••" })
    }

    func testRedisACLLineNeverKeepsAHash() {
        let user = RedisACLUser("user alice on #5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8 ~cache:* %R~logs:* &news -@all +get +@read")
        XCTAssertEqual(user?.name, "alice")
        XCTAssertEqual(user?.passwords, 1)
        XCTAssertEqual(user?.keys, ["cache:*", "%R~logs:*"])
        XCTAssertEqual(user?.channels, ["news"])
        XCTAssertEqual(user?.commands, ["-@all", "+get", "+@read"])
        XCTAssertEqual(user?.user.attributes, ["a password set"])
        XCTAssertFalse("\(String(describing: user))".contains("5e8848"), "the hash is counted, not kept")
        XCTAssertEqual(user?.grants.map(\.kind), ["commands", "keys", "channels"])
        let admin = RedisACLUser("user default on nopass sanitize-payload ~* &* +@all")
        XCTAssertEqual(admin?.user.superuser, true)
        XCTAssertEqual(admin?.user.attributes, ["no password", "sanitize-payload"])
        let selectors = RedisACLUser("user s off resetchannels -@all (~logs:* +get) (%W~out:* +set)")
        XCTAssertEqual(selectors?.selectors, ["~logs:* +get", "%W~out:* +set"])
        XCTAssertEqual(selectors?.user.canLogin, false)
        XCTAssertNil(RedisACLUser("not a user line"))
    }

    func testRedisUserStatements() throws {
        let maker = RedisUserStatements()
        let made = try maker.create(NewUser(name: "a b", password: "pw\"1", login: true))
        XCTAssertEqual(made.count, 1)
        let words = try RedisProtocol.words(made[0].sql)
        XCTAssertEqual(Array(words.prefix(5)), ["ACL", "SETUSER", "a b", "reset", "on"], "a name with a space is one argument")
        XCTAssertEqual(words.last, RedisUserStatements.hash("pw\"1"))
        XCTAssertTrue(RedisUserStatements.hash("password").hasSuffix("5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"))
        XCTAssertFalse(made[0].shown.contains("pw"), made[0].shown)
        XCTAssertFalse(made[0].sql.contains("pw\"1"), "the password goes as its hash")

        let injected = DatabaseUser(name: "x; DROP")
        let grant = try maker.grant(["+@read"], on: .server, to: injected, grantOption: false)
        XCTAssertEqual(try RedisProtocol.words(grant.sql), ["ACL", "SETUSER", "x; DROP", "+@read"])
        let keys = try maker.grant([RedisUserStatements.keyAccess[1]], on: .named(kind: "Keys", name: "a b*"), to: injected, grantOption: false)
        XCTAssertEqual(try RedisProtocol.words(keys.sql), ["ACL", "SETUSER", "x; DROP", "%R~a b*"], "a pattern is one rule")
        let both = try maker.grant(RedisUserStatements.keyAccess, on: .named(kind: "Keys", name: "k"), to: injected, grantOption: false)
        XCTAssertEqual(try RedisProtocol.words(both.sql).last, "~k")
        XCTAssertThrowsError(try maker.grant(["+@all ~*"], on: .server, to: injected, grantOption: false), "only the listed categories")
        XCTAssertEqual(
            try RedisProtocol.words(try XCTUnwrap(maker.revoke(DatabaseGrant(kind: "keys", object: "a*", privileges: []), from: injected)).sql),
            ["ACL", "SETUSER", "x; DROP", "resetkeys"])
        XCTAssertEqual(try RedisProtocol.words(try maker.drop(DatabaseUser(name: "a\"b")).sql), ["ACL", "DELUSER", "a\"b"])
        let password = try maker.password(of: DatabaseUser(name: "bob"), to: "new")
        XCTAssertEqual(password.shown, "ACL SETUSER bob resetpass #••••••••")
        XCTAssertFalse(maker.offers(.grantRole, on: injected))
    }

    // MARK: Neo4j

    func testNeo4jNodeQueries() {
        XCTAssertEqual(Neo4jEdits.nodeQuery("MATCH (n:Person) RETURN n"), .init(variable: "n", label: "Person", database: nil))
        XCTAssertEqual(
            Neo4jEdits.nodeQuery(":use films\nMATCH (p:`Movie Star` {born: 1960}) WHERE p.name STARTS WITH 'A' RETURN p ORDER BY p.name SKIP 10 LIMIT 25;"),
            .init(variable: "p", label: "Movie Star", database: "films"))
        XCTAssertEqual(Neo4jEdits.nodeQuery("match (n:Person) where n.note = 'RETURN m' return n limit 5")?.label, "Person", "a string isn't a clause")
        for refused in [
            "MATCH (n:Person) RETURN n.name", "MATCH (n:Person), (m) RETURN n", "MATCH (n:Person)-[:KNOWS]->(m) RETURN n", "MATCH (n) RETURN n",
            "MATCH (n:Person) RETURN m", "MATCH (n:Person) WITH n RETURN n", "MATCH (n:Person) RETURN n UNION MATCH (n:Person) RETURN n",
            "MATCH (n:Person) SET n.x = 1 RETURN n", "MATCH (n:Person) RETURN n AS x", "MATCH (n:Person) RETURN DISTINCT n",
            "MATCH (n:Person) WHERE EXISTS { MATCH (n)--() } RETURN n",
        ] {
            XCTAssertNil(Neo4jEdits.nodeQuery(refused), refused)
        }
    }

    func testNeo4jNodesFlattened() throws {
        let transactional = Data(
            #"""
            {"results":[{"columns":["n"],"data":[
              {"row":[{"name":"Ann","age":31}],"meta":[{"id":1,"elementId":"4:a:1","type":"node","deleted":false}]},
              {"row":[{"name":"Bob","score":1.5,"tags":["x"],"ok":true}],"meta":[{"id":2,"elementId":"4:a:2","type":"node","deleted":false}]}
            ]}],"errors":[]}
            """#.utf8)
        let result = try XCTUnwrap(Neo4jEdits.flatten(transactional, variable: "n", limit: 100))
        XCTAssertEqual(result.columns, ["elementId(n)", "age", "name", "ok", "score", "tags"])
        XCTAssertEqual(result.types, ["elementId", "Integer", "String", "Boolean", "Float", "List"])
        XCTAssertEqual(result.rows[0], ["4:a:1", "31", "Ann", nil, nil, nil])
        XCTAssertEqual(result.rows[1], ["4:a:2", nil, "Bob", "true", "1.5", #"["x"]"#])
        XCTAssertNil(Neo4jEdits.flatten(transactional, variable: "m", limit: 100), "another variable's column")
        XCTAssertEqual(Neo4jEdits.flatten(transactional, variable: "n", limit: 1)?.truncated, true)

        let query = Data(
            #"{"data":{"fields":["n"],"values":[[{"elementId":"4:a:9","labels":["P"],"properties":{"name":"Cy"}}]]}}"#.utf8)
        XCTAssertEqual(Neo4jEdits.flatten(query, variable: "n", limit: 10)?.rows, [["4:a:9", "Cy"]], "the Query API's too")
        let relationship = Data(
            #"{"results":[{"columns":["n"],"data":[{"row":[{}],"meta":[{"id":1,"elementId":"5:a:1","type":"relationship"}]}]}],"errors":[]}"#.utf8)
        XCTAssertNil(Neo4jEdits.flatten(relationship, variable: "n", limit: 10), "only nodes")
    }

    func testNeo4jLiteralsByType() throws {
        XCTAssertEqual(try Neo4jEdits.literal(#"it's \ "x""#, type: "String", property: "p"), #"'it\'s \\ "x"'"#)
        XCTAssertEqual(try Neo4jEdits.literal("42", type: "Long", property: "p"), "42")
        XCTAssertThrowsError(try Neo4jEdits.literal("42; DETACH DELETE n", type: "Long", property: "age"))
        XCTAssertEqual(try Neo4jEdits.literal("1.5", type: "Double", property: "p"), "1.5")
        XCTAssertEqual(try Neo4jEdits.literal("TRUE", type: "Boolean", property: "p"), "true")
        XCTAssertEqual(try Neo4jEdits.literal(#"["a'", "b"]"#, type: "StringArray", property: "p"), #"['a\'', 'b']"#)
        XCTAssertEqual(try Neo4jEdits.literal("[1, 2]", type: "LongArray", property: "p"), "[1, 2]")
        XCTAssertThrowsError(try Neo4jEdits.literal("[1, null]", type: "LongArray", property: "p"))
        XCTAssertEqual(Neo4jEdits.writable(["String"]), "String")
        XCTAssertNil(Neo4jEdits.writable(["DateTime"]), "a date's text isn't its value")
        XCTAssertNil(Neo4jEdits.writable(["String", "Long"]), "two types: which?")
        XCTAssertEqual(
            Neo4jEdits.types(
                [
                    ["nodeLabels": ["Person"], "propertyName": "age", "propertyTypes": ["Long"]],
                    ["nodeLabels": ["Person", "Admin"], "propertyName": "age", "propertyTypes": ["String"]],
                    ["nodeLabels": ["Other"], "propertyName": "x", "propertyTypes": ["Long"]],
                ], label: "Person"), ["age": ["Long", "String"]])
    }

    func testNeo4jSaveStatements() throws {
        let key = TableKey(table: TableName(schema: "neo4j", name: "Odd`Label"), kind: .identity("elementId"), columns: ["elementId(n)"], readOnlyColumns: ["elementId(n)"])
        let result = EditableResult(key: key, columns: ["elementId(n)", "age", "my prop", "when"], keyIndexes: [0])
        let rows: [[String?]] = [["4:x:1", "31", "a", "2020"], ["4:x:'2", "5", nil, nil]]
        let types: [String: [String]] = ["age": ["Long"], "my prop": ["String"], "when": ["Date"]]
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text("32"), original: "31")
        edits.set(row: 0, column: 2, to: .null, original: "a")
        edits.delete(rows: [1])
        edits.add([1: .text("7"), 2: .text("x'y")])
        let statements = try Neo4jEdits.statements(edits, rows: rows, result: result, types: types, use: nil)
        XCTAssertEqual(
            statements.map(\.sql),
            [
                #"MATCH (n) WHERE elementId(n) = '4:x:\'2' DETACH DELETE n RETURN count(n)"#,
                "MATCH (n) WHERE elementId(n) = '4:x:1' SET n.age = 32 REMOVE n.`my prop` RETURN count(n)",
                #"CREATE (n:`Odd``Label` {age: 7, `my prop`: 'x\'y'}) RETURN count(n)"#,
            ])
        XCTAssertNotNil(statements[0].note, "a delete takes its relationships — said")
        let elsewhere = try Neo4jEdits.statements(edits, rows: rows, result: result, types: types, use: "films")
        XCTAssertTrue(elsewhere.allSatisfy { $0.sql.hasPrefix(":use films\n") })

        var dated = PendingEdits()
        dated.set(row: 0, column: 3, to: .text("2021"), original: "2020")
        XCTAssertThrowsError(try Neo4jEdits.statements(dated, rows: rows, result: result, types: types, use: nil), "a date isn't written as text")
        var bad = PendingEdits()
        bad.set(row: 0, column: 1, to: .text("old"), original: "31")
        XCTAssertThrowsError(try Neo4jEdits.statements(bad, rows: rows, result: result, types: types, use: nil)) { error in
            XCTAssertTrue((error as? EditRefusal)?.message.contains("isn't an integer") == true, "\(error)")
        }
    }

    func testNeo4jTransactions() {
        let rows: [[String: Any]] = [
            [
                "transactionId": "neo4j-transaction-1", "username": "neo4j", "currentQuery": Neo4jDriver.showTransactions, "elapsedTime": "PT0.002S",
                "status": "Running", "database": "neo4j",
            ],
            [
                "transactionId": "neo4j-transaction-2", "username": "app", "currentQuery": "MATCH (n) SET n.x = 1", "elapsedTime": "PT1M3.5S",
                "status": "Blocked by: [neo4j-transaction-3]", "database": "neo4j", "clientAddress": "10.0.0.2:5000",
            ],
            ["transactionId": "neo4j-transaction-3", "username": "app", "currentQuery": "", "elapsedTime": "P1DT2H", "status": "Running"],
        ]
        let transactions = Neo4jOps.transactions(rows, user: "neo4j")
        XCTAssertEqual(transactions.map(\.isOwn), [true, false, false])
        XCTAssertEqual(transactions[1].seconds ?? 0, 63.5, accuracy: 1e-9)
        XCTAssertEqual(transactions[2].seconds ?? 0, 93_600, accuracy: 1e-9)
        XCTAssertNil(transactions[2].query, "an idle transaction has no statement")
        XCTAssertEqual(transactions[1].activity.state, "Blocked")
        let waits = Neo4jOps.waits(transactions)
        XCTAssertEqual(waits.map(\.id), ["neo4j-transaction-2>neo4j-transaction-3"])
        XCTAssertEqual(waits.first?.blockingUser, "app")
        XCTAssertEqual(Neo4jOps.duration("PT0.5S"), 0.5)
        XCTAssertNil(Neo4jOps.duration("soon"))
        let stops = Neo4jDriver.sessionStops(for: DatabaseActivity(id: "neo4j-transaction-'9"), kind: .neo4j)
        XCTAssertEqual(stops?.first?.command, #"TERMINATE TRANSACTION 'neo4j-transaction-\'9'"#)
    }

    func testNeo4jAnswers() {
        let opened = Data(
            #"{"commit":"http://elsewhere:7474/db/neo4j/tx/17/commit","results":[{"columns":["count(n)"],"data":[{"row":[1]}]},{"columns":["count(n)"],"data":[{"row":[0]}]}],"errors":[]}"#
                .utf8)
        let answer = Neo4jOps.transactionAnswer(opened)
        XCTAssertEqual(answer.id, "17", "the id, not the server's idea of its address")
        XCTAssertEqual(answer.counts, [1, 0])
        XCTAssertNil(answer.error)
        let user = Neo4jOps.user(["user": "ann", "roles": ["admin", "PUBLIC"], "passwordChangeRequired": true, "suspended": false])
        XCTAssertEqual(user?.superuser, true)
        XCTAssertEqual(user?.memberOf, ["admin"])
        XCTAssertEqual(user?.attributes, ["must change password"])
        XCTAssertEqual(Neo4jOps.user(["user": "c", "passwordChangeRequired": false])?.memberOf, [], "Community's rows")
    }

    func testNeo4jUserStatements() throws {
        let community = Neo4jUserStatements(enterprise: false)
        let made = try community.create(NewUser(name: "a`b", password: "p'w", superuser: true))
        XCTAssertEqual(made.count, 1, "Community has no admin role to grant")
        XCTAssertTrue(made[0].sql.hasPrefix("CREATE USER `a``b` SET ENCRYPTED PASSWORD '1,"), made[0].sql)
        XCTAssertFalse(made[0].sql.contains("p'w") || made[0].shown.contains("p'w"))
        XCTAssertEqual(made[0].shown, "CREATE USER `a``b` SET ENCRYPTED PASSWORD '••••••••' CHANGE NOT REQUIRED")
        XCTAssertFalse(community.offers(.grant, on: DatabaseUser(name: "x")))
        XCTAssertFalse(community.offers(.grantRole, on: DatabaseUser(name: "x")))

        let salt = Data(repeating: 1, count: 32)
        var hash = Data(SHA256.hash(data: salt + Data("pw".utf8)))
        for _ in 1..<1024 { hash = Data(SHA256.hash(data: hash)) }
        XCTAssertEqual(
            Neo4jUserStatements.encrypted("pw", salt: salt),
            "1," + hash.map { String(format: "%02x", $0) }.joined() + "," + String(repeating: "01", count: 32))

        let enterprise = Neo4jUserStatements(enterprise: true)
        XCTAssertEqual(try enterprise.create(NewUser(name: "readers", login: false)).map(\.sql), ["CREATE ROLE readers"])
        XCTAssertEqual(try enterprise.create(NewUser(name: "ann", password: "x", superuser: true)).last?.sql, "GRANT ROLE admin TO ann")
        let role = DatabaseUser(name: "x; DROP", isRole: true)
        let grant = try enterprise.grant(["ACCESS", "START"], on: .named(kind: "DATABASE", name: "my db"), to: role, grantOption: false)
        XCTAssertEqual(grant.sql, "GRANT ACCESS ON DATABASE `my db` TO `x; DROP`;\nGRANT START ON DATABASE `my db` TO `x; DROP`")
        XCTAssertEqual(CypherText.statements(in: grant.sql).count, 2)
        XCTAssertEqual(try enterprise.grant(["MATCH {*}"], on: .named(kind: "GRAPH", name: "*"), to: role, grantOption: false).sql, "GRANT MATCH {*} ON GRAPH * TO `x; DROP`")
        XCTAssertThrowsError(try enterprise.grant(["ALL ON DBMS"], on: .named(kind: "GRAPH", name: "*"), to: role, grantOption: false))
        let listed = DatabaseGrant(
            kind: "privilege", object: "GRANT TRAVERSE ON GRAPH * NODE * TO `x; DROP`", privileges: [],
            target: .named(kind: "command", name: "GRANT TRAVERSE ON GRAPH * NODE * TO `x; DROP`"))
        XCTAssertEqual(enterprise.revoke(listed, from: role)?.sql, "REVOKE GRANT TRAVERSE ON GRAPH * NODE * FROM `x; DROP`")
        let other = DatabaseGrant(kind: "privilege", object: "", privileges: [], target: .named(kind: "command", name: "GRANT ACCESS ON DATABASE * TO `y`"))
        XCTAssertNil(enterprise.revoke(other, from: role), "only the role's own words")
        XCTAssertEqual(
            enterprise.revoke(DatabaseGrant(kind: "role", object: "admin", privileges: []), from: DatabaseUser(name: "ann"))?.sql, "REVOKE ROLE admin FROM ann")
        XCTAssertEqual(try enterprise.drop(role).sql, "DROP ROLE `x; DROP`")
        XCTAssertTrue(enterprise.offers(.grant, on: role))
        XCTAssertFalse(enterprise.offers(.grant, on: DatabaseUser(name: "ann")), "privileges go to roles")
    }

    // MARK: InfluxDB

    func testInfluxDurationsAndMetrics() {
        XCTAssertEqual(InfluxOps.goDuration("1h2m3.5s") ?? 0, 3723.5, accuracy: 1e-9)
        XCTAssertEqual(InfluxOps.goDuration("150ms") ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(InfluxOps.goDuration("12µs") ?? 0, 0.000012, accuracy: 1e-12)
        XCTAssertNil(InfluxOps.goDuration("soon"))
        let samples = InfluxOps.metrics(
            """
            # HELP influxdb_buckets_total Number of total buckets on the server
            influxdb_buckets_total 4
            storage_shard_disk_size{bucket="b1",engine="tsm1",id="1",path="/x",walPath="/y"} 1024
            storage_shard_disk_size{bucket="b1",engine="tsm1",id="2",path="/x",walPath="/y"} 1024
            influxdb_uptime_seconds 3600.5
            """)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[1].labels["bucket"], "b1")
        let overview = InfluxOps.overview2(health: ["version": "v2.7.11", "status": "pass"], metrics: samples)
        XCTAssertEqual(overview.facts.first?.value, "v2.7.11")
        XCTAssertEqual(overview.facts.first { $0.title == "Shards on disk" }?.value, OpsText.bytes(2048))
        let sizes = InfluxOps.bucketSizes(
            [
                ["id": "b1", "name": "shop", "retentionRules": [["everySeconds": 86400]]],
                ["id": "b2", "name": "_monitoring", "type": "system", "retentionRules": [["everySeconds": 0]]],
            ], metrics: samples)
        XCTAssertEqual(sizes.databases.map(\.name), ["shop", "_monitoring"])
        XCTAssertEqual(sizes.databases.first?.bytes, 2048)
        XCTAssertEqual(sizes.databases.first?.detail, "retention 1 d 0 h")
        XCTAssertEqual(sizes.databases.last?.detail, "kept forever · InfluxDB's own")
    }

    func testInflux1Answers() {
        let queries = InfluxOps.queries([
            InfluxParse.Series(
                name: "", tags: [:], columns: ["qid", "query", "database", "duration", "status"],
                values: [["1", "SHOW QUERIES", "", "52µs", "running"], ["2", "SELECT * FROM cpu", "shop", "2.5s", "running"]])
        ])
        XCTAssertEqual(queries.map(\.isOwn), [true, false])
        XCTAssertEqual(queries[1].seconds ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(queries[1].database, "shop")
        let shards = InfluxOps.shardSizes([
            InfluxParse.Series(name: "shard", tags: ["database": "shop", "retentionPolicy": "autogen"], columns: ["diskBytes"], values: [["100"]]),
            InfluxParse.Series(name: "shard", tags: ["database": "shop", "retentionPolicy": "autogen"], columns: ["diskBytes"], values: [["50"]]),
            InfluxParse.Series(name: "shard", tags: ["database": "_internal", "retentionPolicy": "monitor"], columns: ["diskBytes"], values: [["10"]]),
        ])
        XCTAssertEqual(shards.databases.map(\.name), ["shop", "_internal"])
        XCTAssertEqual(shards.databases.first?.bytes, 150)
        XCTAssertEqual(shards.tables.first?.detail, "retention policy · 2 shards")
        let users = InfluxOps.users1([InfluxParse.Series(name: "", tags: [:], columns: ["user", "admin"], values: [["ot", "true"], ["app", "false"]])])
        XCTAssertEqual(users.map(\.superuser), [true, false])
        let grants = InfluxOps.grants1([
            InfluxParse.Series(name: "", tags: [:], columns: ["database", "privilege"], values: [["shop", "READ"], ["other", "NO PRIVILEGES"]])
        ])
        XCTAssertEqual(grants, [DatabaseGrant(kind: "database", object: "shop", privileges: ["READ"], target: .database("shop"))])
    }

    func testInflux2TokensNeverRead() {
        let data = Data(
            #"{"authorizations":[{"id":"0a1","token":"SECRET-TOKEN","description":"ci","status":"active","permissions":[{"action":"read","resource":{"type":"buckets","name":"shop"}}]}]}"#
                .utf8)
        let tokens = InfluxOps.tokens(data)
        XCTAssertEqual(tokens.first?.object, "ci")
        XCTAssertEqual(tokens.first?.privileges, ["read buckets shop"])
        XCTAssertFalse("\(tokens)".contains("SECRET"))
        let maker = Influx2UserStatements()
        XCTAssertEqual(maker.revoke(tokens[0], from: DatabaseUser(name: "u"))?.sql, "DELETE /api/v2/authorizations/0a1")
        let forged = DatabaseGrant(kind: "token", object: "", privileges: [], target: .named(kind: "token", name: "../users/x"))
        XCTAssertNil(maker.revoke(forged, from: DatabaseUser(name: "u")))
    }

    func testInfluxUserStatements() throws {
        let maker = InfluxUserStatements()
        let made = try maker.create(NewUser(name: #"a"b\"#, password: #"p'w\"#, superuser: true))
        XCTAssertEqual(made[0].sql, #"CREATE USER "a\"b\\" WITH PASSWORD 'p\'w\\' WITH ALL PRIVILEGES"#)
        XCTAssertEqual(made[0].shown, #"CREATE USER "a\"b\\" WITH PASSWORD '••••••••' WITH ALL PRIVILEGES"#)
        XCTAssertEqual(try maker.password(of: DatabaseUser(name: "x; DROP"), to: "n").shown, #"SET PASSWORD FOR "x; DROP" = '••••••••'"#)
        let user = DatabaseUser(name: "app")
        XCTAssertEqual(try maker.grant(["READ", "WRITE"], on: .database("shop"), to: user, grantOption: false).sql, #"GRANT ALL ON "shop" TO "app""#)
        XCTAssertEqual(try maker.grant(["READ"], on: .database("a\"b"), to: user, grantOption: false).sql, #"GRANT READ ON "a\"b" TO "app""#)
        XCTAssertEqual(try maker.grant(["ALL PRIVILEGES"], on: .server, to: user, grantOption: false).sql, #"GRANT ALL PRIVILEGES TO "app""#)
        XCTAssertThrowsError(try maker.grant(["DROP"], on: .database("shop"), to: user, grantOption: false))
        XCTAssertEqual(
            maker.revoke(DatabaseGrant(kind: "database", object: "shop", privileges: ["WRITE"], target: .database("shop")), from: user)?.sql,
            #"REVOKE WRITE ON "shop" FROM "app""#)
        XCTAssertEqual(maker.revoke(DatabaseGrant(kind: "admin", object: "", privileges: [], target: .server), from: user)?.sql, #"REVOKE ALL PRIVILEGES FROM "app""#)
        XCTAssertEqual(try maker.drop(user).sql, #"DROP USER "app""#)

        let two = Influx2UserStatements()
        let created = try two.create(NewUser(name: "a/b", password: "longenough"))
        XCTAssertEqual(
            created.map(\.shown),
            [
                #"NEW POST /api/v2/users {"name":"a/b","status":"active"}"#, #"POST /api/v2/users/{user:a%2Fb}/password {"password":"••••••••"}"#,
                #"POST /api/v2/orgs/{org}/members {"id":"{user:a%2Fb}"}"#,
            ])
        XCTAssertFalse(created.map(\.shown).joined().contains("longenough"))
        XCTAssertEqual(Influx2UserStatements.newName(UserRequest(created[0].sql)?.body), "a/b")
        XCTAssertThrowsError(try two.create(NewUser(name: "x", password: "short")))
        XCTAssertFalse(two.offers(.grant, on: user), "tokens are made elsewhere: a new one's value would be shown")
    }

    // MARK: RabbitMQ

    func testRabbitOverview() {
        let overview = RabbitOps.overview(
            [
                "rabbitmq_version": "3.13.7", "erlang_version": "26.2", "cluster_name": "rabbit@host",
                "object_totals": ["connections": 2, "channels": 3, "queues": 4, "consumers": 1],
                "queue_totals": ["messages": 10, "messages_ready": 7, "messages_unacknowledged": 3],
                "message_stats": ["publish_details": ["rate": 2.5], "deliver_get_details": ["rate": 1.0]],
            ],
            nodes: [
                [
                    "name": "rabbit@host", "running": true, "mem_used": 104_857_600, "mem_limit": 1_073_741_824, "mem_alarm": true, "disk_free": 5_000_000_000,
                    "disk_free_limit": 50_000_000, "disk_free_alarm": false, "fd_used": 40, "fd_total": 1024, "uptime": 90_000,
                ]
            ])
        XCTAssertEqual(overview.facts.first?.value, "3.13.7")
        XCTAssertEqual(overview.facts.first { $0.title == "Messages" }?.detail, "7 ready, 3 unacked")
        XCTAssertEqual(overview.facts.first { $0.title == "File descriptors · host" }?.value, "40 of 1024")
        XCTAssertTrue(overview.notes.contains { $0.hasPrefix("Memory alarm on rabbit@host") })
        XCTAssertTrue(RabbitOps.overview([:], nodes: nil).notes.contains { $0.contains("monitoring or administrator") })
    }

    func testRabbitConnectionsAndQueues() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sessions = RabbitOps.activity(
            [
                [
                    "name": "10.0.0.2:5000 -> 10.0.0.9:5672", "user": "app", "vhost": "/", "peer_host": "10.0.0.2", "peer_port": 5000, "state": "blocked",
                    "channels": 2, "connected_at": 940_000, "protocol": "AMQP 0-9-1", "client_properties": ["connection_name": "orders-worker"],
                ]
            ],
            channels: [
                ["connection_details": ["name": "10.0.0.2:5000 -> 10.0.0.9:5672"], "consumer_count": 1, "messages_unacknowledged": 4],
                ["connection_details": ["name": "10.0.0.2:5000 -> 10.0.0.9:5672"], "consumer_count": 2, "messages_unacknowledged": 0],
            ], now: now)
        XCTAssertEqual(sessions.first?.application, "orders-worker")
        XCTAssertEqual(sessions.first?.client, "10.0.0.2:5000")
        XCTAssertEqual(sessions.first?.seconds, 60)
        XCTAssertEqual(sessions.first?.statement, "2 channels · 3 consumers · 4 unacked · AMQP 0-9-1")
        XCTAssertNotNil(sessions.first?.waiting, "blocked by an alarm")
        XCTAssertFalse(sessions.first?.isOwn ?? true, "Overterm speaks HTTP: no connection is its own")
        let stop = RabbitMQDriver.sessionStops(for: sessions[0], kind: .rabbitmq)?.first
        XCTAssertEqual(stop?.command, "DELETE /api/connections/10.0.0.2%3A5000%20-%3E%2010.0.0.9%3A5672")

        let sizes = RabbitOps.sizes([
            ["name": "small", "vhost": "/", "messages": 1, "message_bytes": 10, "consumers": 0, "type": "classic", "state": "running"],
            [
                "name": "big", "vhost": "v", "messages": 5, "messages_ready": 5, "message_bytes": 5000, "consumers": 1, "type": "quorum",
                "message_stats": ["publish_details": ["rate": 1.5]],
            ],
        ])
        XCTAssertEqual(sizes.tables.map(\.name), ["big", "small"])
        XCTAssertEqual(sizes.tables.first?.detail, "5 messages (5 ready, 0 unacked) · in 1.5/s · 1 consumers · quorum")
        XCTAssertEqual(sizes.databases.map(\.name), ["v", "/"])
    }

    func testRabbitUsersAndPermissions() {
        XCTAssertEqual(RabbitOps.user(["name": "ot", "tags": ["administrator"]])?.superuser, true)
        XCTAssertEqual(RabbitOps.user(["name": "app", "tags": "management,policymaker"])?.attributes, ["management", "policymaker"])
        let grants = RabbitOps.grants(
            permissions: [["vhost": "/", "configure": "^$", "write": ".*", "read": ".*"]], topics: [["vhost": "/", "exchange": "amq.topic", "write": ".*", "read": ""]])
        XCTAssertEqual(grants.map(\.kind), ["vhost", "topic"])
        XCTAssertEqual(grants[0].privileges, ["configure ^$", "write .*", "read .*"])
    }

    func testRabbitUserRequests() throws {
        let maker = RabbitUserStatements()
        let made = try maker.create(NewUser(name: "a/b?c", password: "pw", superuser: true))
        let request = try XCTUnwrap(UserRequest(made[0].sql))
        XCTAssertTrue(request.onlyNew, "never over a user that exists")
        XCTAssertEqual(request.path, "/api/users/a%2Fb%3Fc", "a name never reaches another path")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(request.body).utf8)) as? [String: String])
        XCTAssertEqual(body["tags"], "administrator")
        XCTAssertEqual(body["hashing_algorithm"], "rabbit_password_hashing_sha256")
        XCTAssertNil(body["password"], "never in the clear")
        let hash = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["password_hash"])))
        XCTAssertEqual(hash.count, 36)
        XCTAssertEqual(Data(hash.dropFirst(4)), Data(SHA256.hash(data: hash.prefix(4) + Data("pw".utf8))), "RabbitMQ's salted SHA-256")
        XCTAssertEqual(made[0].shown, #"PUT /api/users/a%2Fb%3Fc {"hashing_algorithm":"rabbit_password_hashing_sha256","password_hash":"••••••••","tags":"administrator"}"#)

        let user = DatabaseUser(name: "x; DROP", attributes: ["management"])
        let password = try maker.password(of: user, to: "new")
        XCTAssertFalse(UserRequest(password.sql)?.onlyNew ?? true)
        XCTAssertTrue(password.sql.contains(#""tags":"management""#), "a PUT replaces the user: its tags go with it")
        let grant = try maker.grant(["write", "read"], on: maker.target(maker.form.grantKinds[0], fields: [""]), to: user, grantOption: false)
        XCTAssertEqual(grant.sql, #"PUT /api/permissions/%2F/x%3B%20DROP {"configure":"^$","read":".*","write":".*"}"#)
        XCTAssertThrowsError(try maker.grant(["everything"], on: .named(kind: "Vhost", name: "/"), to: user, grantOption: false))
        XCTAssertEqual(
            maker.revoke(DatabaseGrant(kind: "topic", object: "", privileges: [], target: .named(kind: "Topic", name: "v/1")), from: user)?.sql,
            "DELETE /api/topic-permissions/v%2F1/x%3B%20DROP")
        XCTAssertEqual(try maker.drop(user).sql, "DELETE /api/users/x%3B%20DROP")
    }
}
