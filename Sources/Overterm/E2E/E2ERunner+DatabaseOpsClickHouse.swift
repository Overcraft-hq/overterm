import Foundation

/// ClickHouse's rows edited as mutations, its Server page and its Users
/// page — against `E2EClickHouseServer`, a fake on 127.0.0.1 that keeps one
/// table and changes it by the exact statements a Save sends.
extension E2ERunner {
    func databaseOpsClickHouseScenario() async {
        let fake = E2EClickHouseServer()
        do { try fake.start() } catch { return check("the fake ClickHouse starts", false, "\(error)") }
        defer { fake.stop() }
        let model = DatabaseModel.shared
        var connection = DatabaseConnection(name: "Ops CH", kind: .clickhouse)
        connection.host = "127.0.0.1"
        connection.port = Int(fake.port)
        connection.user = "ot"
        connection.database = "shop"
        connection.sslMode = .disable
        try? model.store.save(connection)
        func writes() -> [String] {
            fake.statements.filter { $0.hasPrefix("ALTER") || $0.hasPrefix("DELETE") || $0.hasPrefix("INSERT") || $0.hasPrefix("KILL") }
        }

        app.runInDatabaseConsole(connection, "SELECT * FROM shop.orders LIMIT 100;")
        guard let editor = app.editor else { return check("the editor", false) }
        check("the console runs Select Top", await eventually(5) { editor.active?.sqlConsole?.current?.result?.rows.count == 3 })
        guard let console = editor.active?.sqlConsole, let run = console.current else { return }
        var asked: WriteConfirmation?
        console.confirmWrite = { confirmation in
            asked = confirmation
            return true
        }
        guard let rows = console.editor(for: run) else { return check("a ClickHouse result is offered for editing", false) }
        check("a MergeTree's rows are editable, by its primary key", await eventually(5) { rows.editable?.key.columns == ["id"] }, "\(rows.state)")
        check("the bar says they are mutations", rows.editable?.key.label == "mutations" && rows.editable?.key.note?.contains("not in a transaction") == true)

        rows.set(row: 0, column: 0, to: .text("9"))
        check("a row's sorting key can't be changed", rows.edits.isEmpty)
        rows.set(row: 0, column: 1, to: .text("it's"))
        rows.set(row: 1, column: 1, to: .text(""))
        rows.delete([2])
        rows.addRow()
        rows.set(new: 0, column: 0, to: .text("4"))
        rows.set(new: 0, column: 1, to: .text("new"))
        check("nothing runs before Save", writes().isEmpty && fake.notes == ["first", nil, "third"], "\(writes())")
        let preview = await rows.preview()
        check(
            "the preview is the mutations a Save runs",
            preview == """
                DELETE FROM `shop`.`orders` WHERE `id` = '3';
                ALTER TABLE `shop`.`orders` UPDATE `note` = 'it\\'s' WHERE `id` = '1';
                ALTER TABLE `shop`.`orders` UPDATE `note` = '' WHERE `id` = '2';
                INSERT INTO `shop`.`orders` (`id`, `note`) VALUES ('4', 'new');
                """, preview)

        let before = fake.statements.count
        await rows.save()
        check("Save asks first, saying they are mutations", asked?.detail.contains("not in a transaction") == true, asked?.detail ?? "-")
        let sent = Array(fake.statements.dropFirst(before))
        let order = sent.filter { !$0.hasPrefix("SELECT *") && !$0.contains("system.") }.map { String($0.prefix(14)) }
        check(
            "each UPDATE and DELETE counts its key's rows first, one at a time",
            order == ["SELECT count()", "DELETE FROM `s", "SELECT count()", "ALTER TABLE `s", "SELECT count()", "ALTER TABLE `s", "INSERT INTO `s"], "\(order)")
        check("then the table is changed", fake.notes == ["it's", "", "new"], "\(fake.notes)")
        check("and the rows read again", await eventually(5) { console.current?.result?.rows.map { $0[1] } == ["it's", "", "new"] }, "\(console.current?.result?.rows ?? [])")
        check("nothing is pending after", rows.edits.isEmpty && rows.error == nil, rows.error ?? "")

        // The Server page: ClickHouse's parts, its running queries, KILL QUERY.
        app.openDatabasePage(.server, for: connection)
        let server = app.databaseSlot.server
        check("ClickHouse's page has no Locks", server.parts == [.overview, .activity, .slowQueries, .sizes], "\(server.parts)")
        check("its overview reads connections of max", await eventually(5) { server.overview?.facts.contains { $0.title == "Connections" && $0.value == "3 / 4096" } == true }, server.error ?? "")
        server.part = .activity
        check(
            "Activity lists the running queries, the page's own marked", await eventually(5) { server.activity?.value?.count == 2 && server.activity?.value?.contains(where: \.isOwn) == true },
            server.error ?? "")
        guard let busy = server.activity?.value?.first(where: { $0.id == "q-sleep" }) else { return check("the running query", false) }
        let stops = server.stops(for: busy)
        check(
            "the one way to stop it is KILL QUERY: there is no session to end",
            stops.map(\.menu) == ["Kill Query…"] && stops.first?.command == "KILL QUERY WHERE query_id = 'q-sleep'", "\(stops)")
        await server.cancel(busy, terminate: true)
        check("ending a session is refused, nothing sent", !writes().contains { $0.hasPrefix("KILL") })
        await server.cancel(busy, terminate: false)
        check("a query is cancelled by KILL QUERY", writes().last == "KILL QUERY WHERE query_id = 'q-sleep'", "\(writes())")
        let said = (try? await DatabaseMCP.call("db_activity", ["connection": "Ops CH"], model: model))?["content"].map { "\($0)" } ?? ""
        check("db_activity tells an agent the same", said.contains("q-sleep") && said.contains("sleepEachRow"), said)

        // Users: a users.xml user is said, never offered a write.
        app.openDatabasePage(.users, for: connection)
        let users = app.databaseSlot.users
        check("Users lists users and roles", await eventually(5) { users.users?.value?.map(\.name) == ["ot", "app", "readers"] }, users.error ?? "")
        let ot = users.users?.value?.first
        check(
            "users.xml's user is said, and offered no write",
            ot?.attributes.contains(ClickHouseOps.configUser) == true
                && users.maker.map { maker in [UserAction.password, .grant, .grantRole, .drop].allSatisfy { !maker.offers($0, on: ot!) } } == true)
        check(
            "an SQL user is offered every write",
            users.users?.value?.first { $0.name == "app" }.map { app in users.maker?.offers(.drop, on: app) == true } == true)
        check("a role's members", users.users?.value?.first { $0.name == "app" }?.memberOf == ["readers"])
        app.toggleDiff(nil)
        model.disconnect(connection)
    }
}
