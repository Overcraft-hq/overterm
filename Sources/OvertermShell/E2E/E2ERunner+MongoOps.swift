#if E2E
import AppKit

/// A MongoDB find's documents edited in the grid and saved, then the
/// connection's Server page — against the fake mongod (E2EMongoServer), no
/// server needed: a field set, one removed ($unset, shown "(removed)"), a
/// document deleted and one added, previewed as the console's statements,
/// asked, run, read again; the page's own operation marked, another's
/// cancelled with killOp after asking, the profiler said to be off with the
/// line that turns it on.
extension E2ERunner {
    func mongoOpsScenario() async {
        let server = E2EMongoServer()
        do {
            try server.start()
        } catch {
            return check("the fake mongod starts", false, "\(error)")
        }
        defer { server.stop() }
        server.seed(
            "shop", "orders",
            [
                ["_id": .int32(1), "status": .string("open"), "total": .double(9.5), "note": .string("first")],
                ["_id": .int32(2), "status": .string("paid"), "total": .double(20), "note": .string("second")],
                ["_id": .int32(3), "status": .string("open"), "total": .double(4), "note": .string("third")],
            ])
        let model = DatabaseModel.shared
        let mongo = server.connection(name: "Ops Mongo")
        try? model.store.save(mongo, password: nil)

        // Find First 100, from the panel: its documents are edited by _id.
        app.runInDatabaseConsole(mongo, MongoText.find("orders", in: "shop", limit: 100))
        guard let editor = app.editor else { return check("the editor", false) }
        check("the console runs find", await eventually(5) { editor.active?.sqlConsole?.current?.result?.rows.count == 3 })
        guard let console = editor.active?.sqlConsole, let run = console.current else { return }
        var asked: WriteConfirmation?
        console.confirmWrite = { confirmation in
            asked = confirmation
            return true
        }
        guard let rows = console.editor(for: run) else { return check("a MongoDB result is offered for editing", false) }
        check("its documents are editable, found by _id", await eventually(5) { rows.editable?.key.columns == ["_id"] }, "\(rows.state)")
        check("a field can be removed, not only nulled", rows.editable?.removesFields == true)
        guard let grid = Self.mongoGrid(in: editor.view) else { return check("the grid is on screen", false) }
        let columns = run.result?.columns ?? []
        guard let note = columns.firstIndex(of: "note"), let total = columns.firstIndex(of: "total") else {
            return check("the columns", false, "\(columns)")
        }

        rows.set(row: 0, column: note, to: .text("edited"))
        rows.set(row: 1, column: note, to: .absent)
        rows.set(row: 1, column: total, to: .text("21.5"))
        rows.delete([2])
        rows.addRow()
        rows.set(new: 0, column: note, to: .text("new"))
        check("nothing runs before Save", server.documents("shop", "orders").map { $0["note"]?.string } == ["first", "second", "third"])
        check("four changes are pending", rows.edits.count == 4, "\(rows.edits)")
        check("the grid shows the added document", await eventually(3) { grid.numberOfRows == 4 }, "\(grid.numberOfRows)")
        let removed = grid.view(atColumn: note, row: 1, makeIfNecessary: true) as? GridCell
        check("a removed field says so", removed?.textField?.stringValue == "(removed)", removed?.textField?.stringValue ?? "-")
        let target = #"db.getSiblingDB("shop").getCollection("orders")"#
        let preview = await rows.preview()
        check(
            "the preview is the console's statements",
            preview
                == [
                    target + #".deleteOne({ "_id": 3 });"#,
                    target + #".updateOne({ "_id": 1 }, { "$set": { "note": "edited" } });"#,
                    target + #".updateOne({ "_id": 2 }, { "$set": { "total": 21.5 }, "$unset": { "note": "" } });"#,
                    target + #".insertOne({ "note": "new" });"#,
                ].joined(separator: "\n"), preview)

        await rows.save()
        check("Save asks first, saying it runs one by one", asked?.detail.contains("One by one") == true, asked?.detail ?? "-")
        let saved = server.documents("shop", "orders")
        check("then runs them", saved.map { $0["note"]?.string } == ["edited", nil, "new"], "\(saved.map(\.fields))")
        check("the field is gone, not null", saved.count == 3 && saved[1]["note"] == nil && saved[1]["total"] == .double(21.5))
        check("and reads the documents again", await eventually(5) { console.current?.result?.rows.count == 3 && rows.edits.isEmpty }, rows.error ?? "")
        check("what ran is in the history", model.history.contains { $0.connection == mongo.id && $0.sql.contains("updateOne") })

        // An _id can't be changed: said, nothing sent.
        let writes = server.commands.filter { $0 == "update" }.count
        rows.set(row: 0, column: 0, to: .text("99"))
        await rows.save()
        check("changing an _id is refused, said", rows.error?.contains("_id can't be changed") == true && server.commands.filter { $0 == "update" }.count == writes, rows.error ?? "")
        rows.discard()

        // The Server page: read while it shows.
        app.openDatabasePage(.server, for: mongo)
        let page = app.databaseSlot.server
        check("MongoDB's page has every part", page.parts == MonitorPart.allCases)
        check("its overview reads serverStatus", await eventually(5) { page.overview?.facts.contains { $0.title == "Connections" && $0.value == "2 of 100" } == true }, page.error ?? "")
        page.part = .activity
        check("Activity marks this connection's operation", await eventually(5) { page.activity?.value?.first { $0.id == "7" }?.isOwn == true }, page.error ?? "")
        check("and lists another's, with its user", page.activity?.value?.first { $0.id == "8" }?.user == "reporter@admin")
        let stops = page.activity?.value?.first { $0.id == "8" }.map(page.stops(for:)) ?? []
        check(
            "killOp is how an operation is stopped; nothing ends a session",
            stops.map(\.menu) == ["Kill Operation…"] && stops.first?.terminate == false && stops.first?.command.contains("killOp") == true, "\(stops)")
        if let other = page.activity?.value?.first(where: { $0.id == "8" }) { await page.cancel(other, terminate: false) }
        check("cancelling sends killOp for it", server.killedOperations == [8], "\(server.killedOperations)")
        page.part = .slowQueries
        check(
            "the profiler off is said, with the line that turns it on",
            await eventually(5) { page.slowQueries?.gap?.fix == #"db.getSiblingDB("shop").runCommand({ profile: 1, slowms: 100 })"# }, "\(String(describing: page.slowQueries))")
        page.part = .sizes
        check("Sizes lists the collection", await eventually(5) { page.sizes?.value?.tables.contains { $0.name == "orders" } == true }, "\(String(describing: page.sizes))")
        let said = (try? await DatabaseMCP.call("db_activity", ["connection": "Ops Mongo"], model: model))?["content"].map { "\($0)" } ?? ""
        check("db_activity tells an agent the same", said.contains("reporter@admin"), said)
        app.toggleDiff(nil)
        check("hidden, it reads nothing", !page.visible)
        model.disconnect(mongo)
    }

    private static func mongoGrid(in view: NSView) -> GridTableView? {
        if let grid = view as? GridTableView { return grid }
        for subview in view.subviews { if let found = mongoGrid(in: subview) { return found } }
        return nil
    }
}
#endif
