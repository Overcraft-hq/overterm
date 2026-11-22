#if E2E
import AppKit

/// MongoDB in the Database panel, against the fake mongod (E2EMongoServer):
/// the tree's databases, collections and a sample's fields; a console's
/// statements — a block over several lines, the documents as rows, a write
/// said, a read-only connection refusing one before it is sent; completion
/// of a collection; an agent's read and its write refused.
extension E2ERunner {
    func mongoScenario() async {
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
                ["_id": .int32(1), "status": .string("open"), "total": .double(9.5), "customer": .document(["name": .string("Ada")])],
                ["_id": .int32(2), "status": .string("paid"), "total": .double(20)],
                ["_id": .int32(3), "status": .string("open"), "total": .double(4)],
            ])
        server.seed("shop", "users", [["_id": .int32(1), "email": .string("ada@example.test")]])
        server.seed("analytics", "events", [["_id": .int32(1), "kind": .string("view")]])
        let model = DatabaseModel.shared
        let mongo = server.connection(name: "Shop Mongo")
        var reader = server.connection(name: "Shop Mongo (read-only)")
        reader.readOnly = true
        for connection in [mongo, reader] { try? model.store.save(connection, password: nil) }
        app.showDatabase(nil)

        // The tree: databases, the connection's first; collections; fields.
        model.expanded.insert(mongo.id.uuidString)
        let session = model.session(mongo)
        await session.open()
        check("MongoDB connects", session.state == .open, "\(session.state)")
        check("its databases, its own first", session.schemas == ["shop", "analytics"], "\(session.schemas)")
        check("on its own database", session.schema == "shop", session.schema ?? "")
        model.expanded.insert("\(mongo.id.uuidString)/shop")
        await session.loadTables("shop")
        await session.loadColumns("shop")
        check("its collections", session.tables["shop"]?.map(\.name) == ["orders", "users"], "\(session.tables["shop"] ?? [])")
        model.expanded.insert("\(mongo.id.uuidString)/shop/orders")
        check(
            "a collection's fields, from a sample", session.columns(of: "orders", in: "shop").map(\.name) == ["_id", "status", "total", "customer"],
            "\(session.columns(of: "orders", in: "shop"))")
        await pause(0.5)
        dumpMongo("tree")

        // A statement over several lines, its documents a row each.
        app.runInDatabaseConsole(mongo, "db.orders.find({\n  status: \"open\"\n})\n  .sort({ _id: -1 })")
        guard let editor = app.editor else { return check("the editor", false) }
        guard await eventually(5, { editor.active?.sqlConsole?.connection?.id == mongo.id }), let console = editor.active?.sqlConsole else {
            return check("the MongoDB console opens", false)
        }
        let found = await eventually(5) { console.current?.result?.rows.count == 2 }
        check("find's documents are rows", found, "\(String(describing: console.current?.error))")
        check("_id first, then each field", console.current?.result?.columns == ["_id", "status", "total", "customer"], "\(console.current?.result?.columns ?? [])")
        check("sorted as asked", console.current?.result?.rows.map { $0[0] } == ["3", "1"])
        check("a nested document as the shell writes it", console.current?.result?.rows.last?[3] == #"{ "name": "Ada" }"#)
        check("the tab is named for what it did", console.current.map { SQLConsoleView.title($0, index: 0, kind: .mongodb) } == "find orders")
        await pause(0.6)
        dumpMongo("find")

        console.run([#"db.orders.insertOne({ status: "new", total: 1 })"#])
        let inserted = await eventually(5) { console.current?.result?.message == "1 inserted" }
        check("a write says what it did", inserted, "\(String(describing: console.current?.result?.message)) \(String(describing: console.current?.error))")
        console.run(["db.orders.countDocuments({})"])
        check("and is there", await eventually(5) { console.current?.result?.rows == [["4"]] }, "\(String(describing: console.current?.result?.rows))")
        console.run(["db.orders.find({ $where: 'sleep(1)' }"])
        check("a statement that doesn't read is said, not sent", await eventually(5) { console.current?.error?.contains("Expected") == true }, console.current?.error ?? "")

        // Read-only: refused before it is sent.
        let before = server.commands.filter { $0 == "insert" }.count
        app.runInDatabaseConsole(reader, #"db.orders.insertOne({ status: "sneaky" })"#)
        guard await eventually(5, { editor.active?.sqlConsole?.connection?.id == reader.id }), let readOnly = editor.active?.sqlConsole else {
            return check("the read-only console opens", false)
        }
        check("a read-only connection refuses a write", await eventually(5) { readOnly.current?.error?.contains("only reads") == true }, readOnly.current?.error ?? "")
        check("and never sends it", server.commands.filter { $0 == "insert" }.count == before)

        // Completion: a collection after db.
        app.runInDatabaseConsole(mongo, "show collections")
        _ = await eventually(5) { editor.active?.sqlConsole?.connection?.id == mongo.id }
        editor.replaceText(of: editor.active!, with: "db.us")
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        _ = editor.updateSQLCompletion()
        // The collections are read at the first `db.`, and the list offered when they come.
        var names: [String] = []
        _ = await eventually(5) {
            names = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
            return names.first == "users"
        }
        check("a collection completes after db.", names.first == "users", "\(names)")
        editor.dismissCompletion()

        // An agent reads; its write is refused while agents only read.
        let read = try? await DatabaseMCP.call("db_query", ["connection": "Shop Mongo", "sql": #"db.orders.find({ status: "paid" })"#], model: model)
        let text = (read?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        check("an agent's find comes back as a table", text.contains("| 2") && text.contains("paid"), text)
        do {
            _ = try await DatabaseMCP.call("db_query", ["connection": "Shop Mongo", "sql": "db.orders.deleteMany({})"], model: model)
            check("an agent's write is refused", false)
        } catch {
            check("an agent's write is refused", "\(error)".contains("Agents only read") || error.localizedDescription.contains("Agents only read"), "\(error)")
        }
        let schema = try? await DatabaseMCP.call("db_schema", ["connection": "Shop Mongo"], model: model)
        let described = (schema?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        check("db_schema gives collections with their fields", described.contains("collection orders(_id int, status string"), described)

        for connection in [mongo, reader] {
            await model.session(connection).close()
            try? model.delete(connection)
        }
    }

    private func dumpMongo(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !folder.isEmpty else { return }
        app.captureWindow(to: (folder as NSString).appendingPathComponent("mongo-\(name).png"))
    }
}
#endif
