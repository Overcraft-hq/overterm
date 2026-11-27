#if E2E
import AppKit

/// Kafka in the database client, when Scripts/database-test-servers.sh
/// kafka has a broker on :59092: a message published from the console, the
/// topic in the tree, PEEK showing it, the group list read. Skipped, said,
/// without one. The database scenario's last part.
extension E2ERunner {
    func kafkaChecks() async {
        var connection = DatabaseConnection(name: "Kafka", kind: .kafka)
        connection.host = "127.0.0.1"
        connection.port = 59092
        connection.sslMode = .disable
        let probe = KafkaDriver(connection, password: nil)
        do {
            try await probe.connect()
            await probe.close()
        } catch {
            print("E2E SKIP database's Kafka part: nothing on :59092 — Scripts/database-test-servers.sh kafka starts it")
            return
        }
        let topic = "ot.e2e.\(UUID().uuidString.prefix(8).lowercased())"
        let model = DatabaseModel.shared
        try? model.store.save(connection)
        let session = model.session(connection)
        await session.open()
        check("a Kafka connection opens", session.state == .open, "\(session.state)")
        check("its tree is topics and groups", session.schemas == [KafkaText.topicsSchema, KafkaText.groupsSchema], "\(session.schemas)")

        app.runInDatabaseConsole(connection, "PUBLISH \(topic) KEY order-1 {\"id\": 1}")
        guard let editor = app.editor else { return check("the editor", false) }
        check("its console opens", await eventually(5) { editor.active?.sqlConsole?.connection?.id == connection.id })
        guard let console = editor.active?.sqlConsole else { return }
        check(
            "a message is published", await eventually(10) { console.current?.result?.affected == 1 },
            "\(String(describing: console.current?.result)) \(console.current?.error ?? "")")
        await session.loadTables(KafkaText.topicsSchema)
        check("the topic is in the tree", session.tables[KafkaText.topicsSchema]?.contains { $0.name == topic } == true)
        console.run(["PEEK \(topic) 5"])
        check(
            "PEEK reads it back, its key and value",
            await eventually(10) { console.current?.result?.rows.first.map { $0[3] == "order-1" && $0[4] == "{\"id\": 1}" } == true },
            "\(String(describing: console.current?.result?.rows)) \(console.current?.error ?? "")")
        await session.close()
    }
}
#endif
