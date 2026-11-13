import AppKit

/// Redis in the Database panel, against a redis-server of the scenario's
/// own (E2ERedisServer: a free port, nothing on disk) — the keys as
/// folders, a key's page in the right-hand pane and an edit there, the
/// console, the server's page. Without redis-server on this Mac, the
/// scenario says so and checks nothing.
extension E2ERunner {
    func redisScenario() async {
        guard let server = E2ERedisServer() else {
            print("E2E SKIP redis: no redis-server on this Mac (brew install redis)")
            return
        }
        defer { server.stop() }
        let model = DatabaseModel.shared
        let connection = server.connection(name: "Cache")
        do {
            try model.store.save(connection, password: server.password)
        } catch {
            return check("a Redis connection is saved", false, "\(error)")
        }
        let session = model.session(connection)
        await session.open()
        check("a Redis connection opens with its password", session.state == .open, "\(session.state)")
        guard let driver = session.redis else { return }
        _ = try? await driver.pipeline([
            ["HSET", "user:1:profile", "name", "Ada", "lang", "Swift"], ["SET", "user:1:token", "abc"], ["SET", "user:2:token", "def"],
            ["RPUSH", "jobs", "a", "b"], ["ZADD", "board", "3", "ada"], ["SET", "config", #"{"theme":"dark","beta":true}"#],
            ["XADD", "events", "*", "kind", "signup"],
        ])

        // The panel: the connection, db0, its keys as folders.
        app.showDatabase(nil)
        let key = connection.id.uuidString
        model.expanded.insert(key)
        model.expanded.insert("\(key)/db0")
        let browser = session.browser(0)
        await browser.scan()
        check("db0's keys are scanned with their types", browser.keys.count == 7 && browser.keys.first { $0.name == "board" }?.type == "zset", "\(browser.keys)")
        check("and laid out as folders", browser.tree.root.folders.map(\.name) == ["user"], "\(browser.tree.root.folders.map(\.name))")
        model.expanded.insert("\(key)/db0/user:")
        model.expanded.insert("\(key)/db0/user:1:")
        await pause(0.3)

        // A key opens its page on the right; a field edited there is written.
        app.openRedisKey(session, 0, "user:1:profile")
        check("a key opens in the right-hand pane", app.rightPane.mode == .redis && app.diffItem?.isCollapsed == false)
        check("read as a hash", await eventually(5) { app.redisSlot.key.phase == .loaded && app.redisSlot.key.rows.count == 2 }, "\(app.redisSlot.key.phase)")
        await pause(0.5)
        dumpRedis("redis-key")
        if let name = app.redisSlot.key.rows.first(where: { $0.id == "name" }) {
            await app.redisSlot.key.update(name, to: "Ada Lovelace")
            let stored = try? await driver.command(["HGET", "user:1:profile", "name"])
            check("an edited field is written", stored?.text == "Ada Lovelace", "\(String(describing: stored))")
        }

        // A string that is JSON reads laid out.
        app.openRedisKey(session, 0, "config")
        check("a string is read whole", await eventually(5) { app.redisSlot.key.phase == .loaded && app.redisSlot.key.text.contains("dark") })
        await pause(0.4)
        dumpRedis("redis-string")

        // A new key, from the page.
        app.redisSlot.newKey(in: session, db: 0)
        app.showRedisSlot()
        await pause(0.4)
        dumpRedis("redis-new")
        try? await RedisKeyModel.create("cart:9", type: "set", values: ["sku-1"], ttl: 120, db: 0, driver: driver)
        browser.added(RedisKeyEntry(name: "cart:9", type: "set"))
        check("a made key joins the browser", browser.keys.contains { $0.name == "cart:9" })

        // The console: a command a line, no semicolons; a read-only verb check.
        app.runInDatabaseConsole(connection, "HGETALL user:1:profile")
        guard let editor = app.editor else { return check("the editor", false) }
        check("the Redis console opens", await eventually(5) { editor.active?.sqlConsole?.connection?.id == connection.id })
        guard let console = editor.active?.sqlConsole else { return }
        check("and runs the command", await eventually(5) { console.current?.result?.rows.count == 2 }, "\(String(describing: console.current))")
        check("no semicolon is added", editor.active?.storage.string.contains(";") == false, editor.active?.storage.string ?? "")
        editor.replaceText(of: editor.active!, with: "GET user:2:token\nGET user:1:token\n")
        editor.textView.setSelectedRange(NSRange(location: 20, length: 0))
        _ = editor.runConsoleStatement()
        check("⌘↩ runs the line at the caret", await eventually(5) { console.current?.result?.rows == [["abc"]] })
        editor.replaceText(of: editor.active!, with: "HGETALL us")
        editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
        _ = editor.updateSQLCompletion()
        let keys = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("a command's key completes from the browser", keys.contains("user:1:profile"), "\(keys)")
        editor.dismissCompletion()
        await pause(0.4)
        dumpRedis("redis-console")

        // The server's page — shown even with the editor zoomed.
        app.setEditorZoomed(true)
        app.openRedisServer(session)
        check("the server's page reads INFO", await eventually(5) { app.redisSlot.page == .server && app.redisSlot.server.info.version != nil })
        check(
            "and shows, the zoom given back", app.diffItem?.isCollapsed == false && app.rightPane.mode == .redis && app.zoomedColumn == nil,
            "collapsed \(String(describing: app.diffItem?.isCollapsed)) mode \(app.rightPane.mode)")
        // A photo zooms an editor that shows: this one is the page's.
        app.editorItem?.isCollapsed = true
        await pause(0.5)
        dumpRedis("redis-server")
        app.editorItem?.isCollapsed = false
        app.redisSlot.server.tab = .pubsub
        app.redisSlot.server.channels = "news.*"
        await app.redisSlot.server.subscribe()
        await pause(0.3)
        _ = await app.redisSlot.server.publish("news.today", "hello")
        check("Pub/Sub hears what is published", await eventually(5) { app.redisSlot.server.messages.first?.text == "hello" })
        app.redisSlot.server.stopListening()

        // The connection goes, and with it nothing of its secret on disk.
        let saved = (try? String(contentsOf: model.store.file, encoding: .utf8)) ?? ""
        check("the password isn't in connections.json", !saved.contains(server.password))
        await session.close()
        try? model.delete(connection)
    }

    /// The window, when OVERTERM_DUMP_PNG names a folder.
    private func dumpRedis(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !folder.isEmpty else { return }
        app.captureWindow(to: (folder as NSString).appendingPathComponent("\(name).png"))
    }
}
