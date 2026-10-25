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

extension E2ERunner {
    /// A connection through the bastion of Scripts/database-test-servers.sh
    /// (:52222) opens as any other, and closing it ends its ssh.
    func databaseTunnelScenario() async {
        guard Self.portAnswers(52222) else {
            print("E2E INFO databaseTunnel: no SSH server on :52222 — Scripts/database-test-servers.sh starts one")
            return
        }
        SSHTunnel.knownHostsFile = scratch.appendingPathComponent("known_hosts").path
        var connection = DatabaseConnection(name: "Behind the bastion", kind: .postgres)
        connection.host = "ot-pg"
        connection.port = 5432
        connection.user = "ot"
        connection.database = "shop"
        connection.sslMode = .disable
        connection.sshEnabled = true
        connection.sshHost = "127.0.0.1"
        connection.sshPort = 52222
        connection.sshUser = "tunnel"
        let model = DatabaseModel.shared
        try? model.store.save(connection, password: "otpass", sshSecret: "tunnelpass")
        let saved = (try? String(contentsOf: model.store.file, encoding: .utf8)) ?? ""
        check("the tunnel is saved with the connection", saved.contains("52222") && saved.contains("ot-pg"))
        check("and its password is not", !saved.contains("tunnelpass"))

        let session = model.session(connection)
        await session.open()
        check("it opens through the tunnel", session.state == .open, "\(session.state)")
        check("and reads the catalog", session.schemas.contains("public"), "\(session.schemas)")
        var answer: QueryResult?
        await session.run(["SELECT inet_server_port() AS port"], limit: 1) { _, result in answer = try? result.get() }
        check("a query runs on the database behind it", answer?.rows == [["5432"]], "\(String(describing: answer))")
        let ssh = Self.sshChildren()
        check("one ssh carries it", ssh.count == 1, "\(ssh)")
        await session.close()
        check("closing it ends that ssh", await eventually(5) { Self.sshChildren().isEmpty })
        SSHTunnel.knownHostsFile = nil
    }

    static func portAnswers(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// This app's ssh children.
    static func sshChildren() -> [pid_t] {
        ProcessInspector.children(of: getpid()).filter { $0.name == "ssh" }.map(\.pid)
    }
}
