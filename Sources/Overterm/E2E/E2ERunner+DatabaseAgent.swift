import AppKit
import SQLite3

/// An agent at the database client, through the MCP server's own dispatch:
/// the connections without their secrets, a schema, a read; a write
/// refused, then asked about and run only when allowed; a bucket, when the
/// S3 server of Scripts/database-test-servers.sh is running.
extension E2ERunner {
    func databaseAgentScenario() async {
        let file = scratch.appendingPathComponent("agent.sqlite")
        try? FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES (1, 'Ada'), (2, 'Linus');", nil, nil, nil)
        sqlite3_close(db)
        let model = DatabaseModel.shared
        var connection = DatabaseConnection(name: "Agent DB", kind: .sqlite)
        connection.filePath = file.path
        try? model.store.save(connection, password: "hunter2-never-told")

        func call(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool) {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let answer = await BrowserMCP.handle(message, browser: { nil })
            if let error = answer?["error"] as? [String: Any] { return (error["message"] as? String ?? "", true) }
            let result = answer?["result"] as? [String: Any]
            let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, result?["isError"] as? Bool == true)
        }
        func listed() async -> [String] {
            let answer = await BrowserMCP.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], browser: { nil })
            return ((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }

        check("agents are offered the database tools", await listed().contains("db_query"))
        let connections = await call("db_connections")
        check("db_connections names them", connections.text.contains("Agent DB") && connections.text.contains("SQLite"), connections.text)
        check("and never a secret", !connections.text.contains("hunter2"))
        let schema = await call("db_schema", ["connection": "Agent DB"])
        check("db_schema gives tables with columns", schema.text.contains("users(id") && schema.text.contains("name"), schema.text)
        let read = await call("db_query", ["connection": "agent db", "sql": "SELECT name FROM users ORDER BY id"])
        check("db_query reads rows", read.text.contains("| Ada") && read.text.contains("2 rows"), read.text)
        check("what it ran is in the history", model.history.first?.sql == "SELECT name FROM users ORDER BY id")

        let write = await call("db_query", ["sql": "DELETE FROM users WHERE id = 2"])
        check("a write is refused while agents only read", write.isError && write.text.contains("Settings ▸ Database"), write.text)
        let hidden = await call("db_query", ["sql": "WITH gone AS (DELETE FROM users RETURNING id) SELECT * FROM gone"])
        check("and a write inside a WITH too", hidden.isError, hidden.text)
        let two = await call("db_query", ["sql": "SELECT 1; SELECT 2"])
        check("one statement at a time", two.isError && two.text.contains("One statement"), two.text)

        Settings.shared.set("database.agentWrites", .bool(true))
        var asked: [String] = []
        DatabaseMCP.askOverride = { statement in
            asked.append(statement)
            return false
        }
        let declined = await call("db_query", ["sql": "DELETE FROM users WHERE id = 2"])
        check("allowed writes are asked about", asked == ["DELETE FROM users WHERE id = 2"] && declined.isError && declined.text.contains("declined"), declined.text)
        let still = await call("db_query", ["sql": "SELECT count(*) AS n FROM users"])
        check("and declined, nothing ran", still.text.contains("| 2"), still.text)
        DatabaseMCP.askOverride = { _ in true }
        let allowed = await call("db_query", ["sql": "DELETE FROM users WHERE id = 2"])
        check("said yes, it runs", !allowed.isError && allowed.text.contains("1 row affected"), allowed.text)
        DatabaseMCP.askOverride = nil
        Settings.shared.set("database.agentWrites", nil)

        Settings.shared.set("database.agentAccess", .bool(false))
        check("switched off, the tools go", !(await listed().contains("db_query")))
        let off = await call("db_connections")
        check("and a call says where to switch them on", off.isError && off.text.contains("Settings ▸ Database"), off.text)
        Settings.shared.set("database.agentAccess", nil)

        // Buckets, when there is an S3 server to read.
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:59000/")!)
        probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            print("E2E INFO databaseAgent: no S3 server on :59000 — the storage tools aren't checked")
            return
        }
        var s3 = DatabaseConnection(name: "Agent S3", kind: .s3)
        s3.apply(.minio)
        s3.host = "127.0.0.1"
        s3.port = 59000
        s3.user = "otadmin"
        try? model.store.save(s3, password: "otpass12345")
        let bucket = "ot-agent-\(UInt32.random(in: 0...UInt32.max))"
        let session = model.storage(s3)
        await session.open()
        await session.newBucket(bucket)
        try? await session.client.put(bucket: bucket, key: "logs/app.log", data: Data("started\nready\n".utf8), contentType: "text/plain")
        let buckets = await call("storage_list", ["connection": "Agent S3"])
        check("storage_list gives the buckets", buckets.text.contains(bucket), buckets.text)
        let folder = await call("storage_list", ["connection": "Agent S3", "bucket": bucket, "prefix": "logs"])
        check("and a folder's files", folder.text.contains("logs/app.log"), folder.text)
        let log = await call("storage_read", ["connection": "Agent S3", "bucket": bucket, "key": "logs/app.log"])
        check("storage_read reads a file", log.text.contains("started\nready"), log.text)
        check("never the secret", !buckets.text.contains("otpass12345") && !log.text.contains("otpass12345"))
        await session.delete(["logs/app.log"], in: bucket, refreshing: "")
    }
}
