#if E2E
import AppKit

/// The Server and Users pages of kinds that aren't SQL's, and a graph's
/// nodes edited in the grid. Redis against a redis-server of the scenario's
/// own (E2ERedisServer): the shared Server page's clients (one killed) and
/// slow log, its ACL users made, granted and dropped. Neo4j against
/// Scripts/database-test-servers.sh's on :57474, when it runs: a label's
/// nodes as rows of their properties, edited, previewed as Cypher, saved
/// in one transaction; its Server page. Without either, that part says so.
extension E2ERunner {
    package func databaseOpsKindsScenario() async {
        await redisOpsPages()
        await neo4jNodeEditing()
    }

    private func redisOpsPages() async {
        guard let redis = E2ERedisServer() else {
            print("E2E SKIP databaseOpsKinds' Redis pages: no redis-server on this Mac (brew install redis)")
            return
        }
        defer { redis.stop() }
        let model = DatabaseModel.shared
        let connection = redis.connection(name: "Ops Cache")
        try? model.store.save(connection, password: redis.password)
        let session = model.session(connection)
        await session.open()
        guard let driver = session.redis else { return check("the Redis connection opens", false, "\(session.state)") }
        _ = try? await driver.pipeline([["CONFIG", "SET", "slowlog-log-slower-than", "0"], ["SET", "a", "1"], ["GET", "a"], ["GET", "a"]])

        // Its own page stays Server Info: the shared one isn't offered twice.
        check("⌘K offers no second Server page for Redis", !app.databasePaletteItems().map(\.title).contains("Server: Ops Cache"))
        check("but Redis's reads are the shared ones", connection.kind.features.contains(.monitoring) && connection.kind.features.contains(.users))
        app.openDatabasePage(.server, for: connection)
        let server = app.databaseSlot.server
        check("its parts are the overview, clients and the slow log", server.parts == [.overview, .activity, .slowQueries], "\(server.parts)")
        check("the overview reads INFO", await eventually(5) { server.overview?.facts.contains { $0.title == "Clients" } == true }, server.error ?? "")

        let other = await driver.listener()
        try? await other.connect()
        server.part = .activity
        check(
            "Activity lists the clients, this one marked",
            await eventually(5) { (server.activity?.value?.count ?? 0) >= 2 && server.activity?.value?.contains(where: \.isOwn) == true },
            "\(String(describing: server.activity))")
        let stops = (DatabaseDrivers.driverType(of: .redis) as? any DatabaseMonitoring.Type)?.sessionStops(
            for: DatabaseActivity(id: "7"), kind: .redis)
        check("a client is stopped by CLIENT KILL", stops?.first?.command == "CLIENT KILL ID 7", "\(String(describing: stops))")
        if let victim = server.activity?.value?.first(where: { !$0.isOwn }) {
            await server.cancel(victim, terminate: true)
            check("killed, it is gone", await eventually(5) { server.activity?.value?.contains { $0.id == victim.id } == false }, server.error ?? "")
        }
        await other.close()
        server.part = .slowQueries
        check(
            "Slow Queries reads the slow log, a command line together",
            await eventually(5) { server.slowQueries?.value?.contains { $0.statement == "GET a" && $0.calls >= 2 } == true },
            "\(String(describing: server.slowQueries))")
        let told = (try? await DatabaseMCP.call("db_slow_queries", ["connection": "Ops Cache"], model: model))?["content"].map { "\($0)" } ?? ""
        check("db_slow_queries tells an agent the same", told.contains("GET a"), told)

        // Users from ACL: made with its password's hash, granted, dropped.
        app.openDatabasePage(.users, for: connection)
        let users = app.databaseSlot.users
        check("Users lists ACL's users", await eventually(5) { users.users?.value?.contains { $0.name == "default" } == true }, users.error ?? "")
        guard let maker = users.maker else { return check("Redis's users are made by its own statements", false) }
        let made = try? maker.create(NewUser(name: "e2e-reader", password: "s3cret-pw"))
        check("a new user's line never shows its password", made?.first.map { !$0.shown.contains("s3cret") && !$0.sql.contains("s3cret") } == true)
        if let made { check("it is made", await users.run(made) == nil, users.error ?? "") }
        let reader = DatabaseUser(name: "e2e-reader")
        if let grant = try? maker.grant(["+@read", "+@connection"], on: .server, to: reader, grantOption: false),
            let keys = try? maker.grant([RedisUserStatements.keyAccess[1]], on: .named(kind: "Keys", name: "a*"), to: reader, grantOption: false)
        {
            check("and granted", await users.run([grant, keys]) == nil, users.error ?? "")
        }
        users.selected = "e2e-reader"
        check(
            "its grants are its rules, its hash never read",
            await eventually(5) { users.grants?.value?.contains { $0.kind == "keys" && $0.object == "%R~a*" } == true }, "\(String(describing: users.grants))")
        check(
            "a password is “set”, never shown",
            users.users?.value?.first { $0.name == "e2e-reader" }?.attributes.contains("a password set") == true, "\(String(describing: users.users))")
        var signIn = connection
        signIn.user = "e2e-reader"
        let signedIn = RedisDriver(signIn, password: "s3cret-pw")
        let read = try? await signedIn.command(["GET", "a"])
        check("it signs in with that password and reads", read == .bulk(Data("1".utf8)), "\(String(describing: read))")
        await signedIn.close()
        if let drop = try? maker.drop(reader) { check("dropped", await users.run([drop]) == nil, users.error ?? "") }
        check("and gone", users.users?.value?.contains { $0.name == "e2e-reader" } == false)
        app.toggleDiff(nil)
        model.disconnect(connection)
    }

    private func neo4jNodeEditing() async {
        let model = DatabaseModel.shared
        var connection = DatabaseConnection(name: "Ops Graph", kind: .neo4j)
        connection.host = "127.0.0.1"
        connection.port = 57474
        connection.user = "neo4j"
        connection.sslMode = .disable
        try? model.store.save(connection, password: "otpass1234")
        let session = model.session(connection)
        await session.open()
        guard session.isOpen else {
            print("E2E SKIP databaseOpsKinds' Neo4j editing: nothing on :57474 — Scripts/database-test-servers.sh starts it")
            return
        }
        let setup = Neo4jDriver(connection, password: "otpass1234")
        _ = try? await setup.execute("MATCH (n:E2EOpsPerson) DETACH DELETE n", limit: 10)
        _ = try? await setup.execute(
            "CREATE (:E2EOpsPerson {name: 'Ann', age: 31}), (:E2EOpsPerson {name: 'Bob', age: 40, note: 'x'}), (:E2EOpsPerson {name: 'Cy', age: 5})-[:E2E_KNOWS]->(:E2EOpsOther)",
            limit: 10)

        app.runInDatabaseConsole(connection, "MATCH (n:E2EOpsPerson) RETURN n ORDER BY n.name")
        guard let editor = app.editor else { return check("the editor", false) }
        check(
            "a label's nodes come back as rows of their properties",
            await eventually(5) { editor.active?.sqlConsole?.current?.result?.columns == ["elementId(n)", "age", "name", "note"] },
            "\(editor.active?.sqlConsole?.current?.result?.columns ?? [])")
        guard let console = editor.active?.sqlConsole, let run = console.current else { return }
        var asked: WriteConfirmation?
        console.confirmWrite = { confirmation in
            asked = confirmation
            return true
        }
        guard let rows = console.editor(for: run) else { return check("Neo4j's nodes are offered for editing", false) }
        check("each is found by its elementId", await eventually(5) { rows.editable?.key.summary == "elementId" }, "\(rows.state)")
        check("the grid is on screen", Self.opsGrid(in: editor.view) != nil)

        rows.set(row: 0, column: 1, to: .text("thirty"))
        let refused = await rows.preview()
        check("an integer property takes only an integer", refused.contains("isn't an integer"), refused)
        rows.set(row: 0, column: 1, to: .text("32"))
        rows.set(row: 1, column: 3, to: .null)
        rows.delete([2])
        rows.addRow()
        rows.set(new: 0, column: 2, to: .text("Dee's"))
        rows.set(new: 0, column: 1, to: .text("7"))
        let preview = await rows.preview()
        check("the preview is Cypher: SET a typed value", preview.contains("SET n.age = 32 RETURN count(n)"), preview)
        check("NULL removes the property", preview.contains("REMOVE n.note RETURN count(n)"), preview)
        check("a node deleted takes its relationships", preview.contains("DETACH DELETE n RETURN count(n)"), preview)
        check("a node added is created with its label", preview.contains(#"CREATE (n:E2EOpsPerson {age: 7, name: 'Dee\'s'}) RETURN count(n)"#), preview)
        let before = try? await setup.execute("MATCH (n:E2EOpsPerson) RETURN count(n) AS c", limit: 1)
        check("nothing runs before Save", before?.rows.first?.first == "3", "\(String(describing: before?.rows))")

        await rows.save()
        check("Save asks, saying a delete takes relationships", asked?.detail.contains("DETACH DELETE deletes a node's relationships") == true, asked?.detail ?? "-")
        let after = try? await setup.execute(
            "MATCH (n:E2EOpsPerson) RETURN n.name AS name, n.age AS age, n.note AS note ORDER BY name", limit: 10)
        check(
            "then runs them in one transaction",
            after?.rows == [["Ann", "32", nil], ["Bob", "40", nil], ["Dee's", "7", nil]], "\(String(describing: after?.rows))")
        check(
            "and reads the nodes again",
            await eventually(5) { console.current?.result?.rows.compactMap { $0[2] } == ["Ann", "Bob", "Dee's"] }, "\(console.current?.result?.rows ?? [])")
        check("nothing is pending after", rows.edits.isEmpty && rows.error == nil, rows.error ?? "")

        // A query that isn't one label's nodes says why.
        console.run(["MATCH (n:E2EOpsPerson) RETURN n.name"])
        check("a property's result runs", await eventually(5) { console.current?.sql == "MATCH (n:E2EOpsPerson) RETURN n.name" && console.current?.result != nil })
        if let other = console.current, let refused = console.editor(for: other) {
            check("and isn't edited, said why", await eventually(5) { if case .refused(let why) = refused.state { why.contains("RETURN n") } else { false } }, "\(refused.state)")
        }

        app.openDatabasePage(.server, for: connection)
        let server = app.databaseSlot.server
        check("Neo4j's Server page has every part", server.parts == MonitorPart.allCases)
        check("its overview counts the nodes", await eventually(5) { server.overview?.facts.contains { $0.title == "Nodes" } == true }, server.error ?? "")
        server.part = .activity
        check("Activity lists the transactions, its own marked", await eventually(5) { server.activity?.value?.contains(where: \.isOwn) == true }, server.error ?? "")
        server.part = .sizes
        check(
            "Sizes counts a label's nodes",
            await eventually(5) { server.sizes?.value?.tables.contains { $0.name == "E2EOpsPerson" && $0.bytes == 3 && $0.unit == "nodes" } == true },
            "\(String(describing: server.sizes))")
        app.toggleDiff(nil)
        _ = try? await setup.execute("MATCH (n) WHERE n:E2EOpsPerson OR n:E2EOpsOther DETACH DELETE n", limit: 10)
        await setup.close()
        model.disconnect(connection)
    }

    private static func opsGrid(in view: NSView) -> GridTableView? {
        if let grid = view as? GridTableView { return grid }
        for subview in view.subviews { if let found = opsGrid(in: subview) { return found } }
        return nil
    }
}
#endif
