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
@testable import OvertermActivity
@testable import OvertermE2E

/// RabbitMQ's console language, its answers and its address pasted —
/// offline; the driver against rabbitmq:3-management when
/// OVERTERM_DB_TESTS=1 and `Scripts/database-test-servers.sh queues` runs it.
final class RabbitMQTests: XCTestCase {
    private func statements(_ text: String) -> [String] {
        let ns = text as NSString
        return RabbitText.statements(in: text).map { ns.substring(with: $0) }
    }

    func testStatements() {
        let text = """
            # the queue
            PEEK orders 5
            peek "my queue"
            PUBLISH amq.default orders {
              "id": 1
            }
            PURGE orders

            GET /api/queues/%2F
            POST /api/exchanges/%2F/x/publish
            {"routing_key": "a"}
            """
        XCTAssertEqual(
            statements(text),
            [
                "PEEK orders 5", "peek \"my queue\"", "PUBLISH amq.default orders {\n  \"id\": 1\n}", "PURGE orders", "GET /api/queues/%2F",
                "POST /api/exchanges/%2F/x/publish\n{\"routing_key\": \"a\"}",
            ])
        // The caret in a payload's line runs its PUBLISH.
        let ns = text as NSString
        let caret = ns.range(of: "\"id\"").location
        XCTAssertEqual(DatabaseKind.rabbitmq.statement(at: caret, in: text).map(ns.substring), "PUBLISH amq.default orders {\n  \"id\": 1\n}")
        // The seeded console is only comments: nothing to run.
        XCTAssertEqual(statements(RabbitText.help), [])
    }

    func testParse() throws {
        XCTAssertEqual(try RabbitText.parse("PEEK orders"), .peek(queue: "orders", count: nil))
        XCTAssertEqual(try RabbitText.parse("peek \"my \\\"odd\\\" queue\" 3"), .peek(queue: "my \"odd\" queue", count: 3))
        XCTAssertEqual(try RabbitText.parse("USE /"), .use("/"))
        XCTAssertEqual(try RabbitText.parse("USE \"\""), .use(""))
        XCTAssertEqual(
            try RabbitText.parse("PUBLISH \"\" jobs  two  spaces kept\nand a line"),
            .publish(exchange: "", routingKey: "jobs", payload: " two  spaces kept\nand a line"))
        XCTAssertEqual(try RabbitText.parse("PUBLISH logs \"\" hi"), .publish(exchange: "logs", routingKey: "", payload: "hi"))
        XCTAssertEqual(try RabbitText.parse("PURGE orders"), .purge("orders"))
        XCTAssertEqual(try RabbitText.parse("GET /api/overview"), .api(method: "GET", path: "/api/overview", body: nil))
        XCTAssertEqual(
            try RabbitText.parse("PUT /api/queues/%2F/q\n{\"durable\": true}"), .api(method: "PUT", path: "/api/queues/%2F/q", body: "{\"durable\": true}"))
        for wrong in ["PEEK", "PEEK q zero", "PEEK q 0", "PEEK q 1 2", "PUBLISH x", "PURGE", "PURGE a b", "GET /", "GET /api/a b", "SELECT 1", "PEEK \"open"] {
            XCTAssertThrowsError(try RabbitText.parse(wrong), wrong)
        }
    }

    func testWhatWritesAndWhatAsks() {
        for read in ["USE /", "PEEK orders 3", "GET /api/queues", "get /api/overview"] {
            XCTAssertTrue(RabbitText.onlyReads(read), read)
            XCTAssertEqual(DatabaseKind.rabbitmq.agentReads(read), !read.hasPrefix("PEEK"), read)
        }
        // A peek puts its messages back redelivered (and counted on a quorum queue): an agent asks.
        XCTAssertFalse(RabbitText.agentReads("PEEK orders 3"))
        for write in ["PUBLISH amq.default q hi", "PURGE q", "PUT /api/vhosts/x", "POST /api/queues/%2F/q/get", "DELETE /api/queues/%2F/q", "nonsense"] {
            XCTAssertFalse(DatabaseKind.rabbitmq.onlyReads(write), write)
            XCTAssertFalse(DatabaseKind.rabbitmq.agentReads(write), write)
        }
        // Reads that hold credentials: an agent is asked.
        for secret in ["GET /api/users", "GET /api/users/ot", "GET /api/definitions", "GET /api/parameters/shovel?x=1", "GET /api/global-parameters"] {
            XCTAssertTrue(RabbitText.onlyReads(secret), secret)
            XCTAssertFalse(RabbitText.agentReads(secret), secret)
        }
        XCTAssertTrue(RabbitText.agentReads("GET /api/userspace"), "only the path itself, not a name it starts")
        XCTAssertNotNil(DatabaseKind.rabbitmq.danger(of: "PURGE orders"))
        XCTAssertNotNil(DatabaseKind.rabbitmq.danger(of: "DELETE /api/queues/%2F/orders"))
        XCTAssertNil(DatabaseKind.rabbitmq.danger(of: "PUBLISH amq.default q hi"))
        XCTAssertEqual(DatabaseKind.rabbitmq.verb(of: "publish x y z"), "PUBLISH")
        XCTAssertEqual(DatabaseKind.rabbitmq.subject(of: "PUBLISH \"\" q hi"), "amq.default")
        XCTAssertEqual(DatabaseKind.rabbitmq.subject(of: "PEEK orders"), "orders")
    }

    func testTreeAndBrowse() {
        XCTAssertEqual(RabbitText.segment("/"), "%2F")
        XCTAssertEqual(RabbitText.segment("a b/c"), "a%20b%2Fc")
        XCTAssertEqual(RabbitText.quoted("orders"), "orders")
        XCTAssertEqual(RabbitText.quoted("my queue"), "\"my queue\"")
        XCTAssertEqual(RabbitText.browse(CatalogTable(schema: "/", name: "my queue"), limit: 500), "PEEK \"my queue\" 100")
        XCTAssertEqual(
            RabbitText.browse(CatalogTable(schema: "/", name: "exchange:logs"), limit: 100), "GET /api/exchanges/%2F/logs/bindings/source")
        XCTAssertEqual(
            RabbitText.queueDetail(["type": "quorum", "messages_ready": 3, "messages_unacknowledged": 1, "consumers": 1]),
            "quorum · 3 ready · 1 unacked · 1 consumer")
        XCTAssertEqual(RabbitText.queueDetail(["type": "classic", "messages_ready": 0, "consumers": 0, "state": "idle"]), "0 ready · 0 consumers")
        let columns = RabbitText.bindingColumns([
            ["source": "", "destination": "orders", "destination_type": "queue", "routing_key": "orders"],
            ["source": "logs", "destination": "orders", "destination_type": "queue", "routing_key": "eu.#"],
            ["source": "logs", "destination": "audit", "destination_type": "exchange", "routing_key": ""],
        ])
        XCTAssertEqual(
            columns,
            [
                CatalogColumn(table: "orders", name: "← logs", type: "eu.#"), CatalogColumn(table: "exchange:logs", name: "→ orders", type: "eu.#"),
                CatalogColumn(table: "exchange:audit", name: "← logs", type: "(no key)"),
                CatalogColumn(table: "exchange:logs", name: "→ exchange:audit", type: "(no key)"),
            ])
    }

    func testMessagesAnswer() throws {
        let json = """
            [{"payload_bytes":7,"redelivered":true,"exchange":"","routing_key":"orders","message_count":1,
              "properties":{"content_type":"application/json","headers":{"x-n":1}},"payload":"{\\"a\\":1}","payload_encoding":"string"},
             {"payload_bytes":3,"redelivered":false,"exchange":"logs","routing_key":"k","message_count":0,
              "properties":[],"payload":"AAEC","payload_encoding":"base64"}]
            """
        let result = try RabbitText.messages(Data(json.utf8), limit: 10)
        XCTAssertEqual(result.columns, ["#", "payload", "routing_key", "exchange", "redelivered", "properties", "headers", "bytes"])
        XCTAssertEqual(result.rows[0], ["1", "{\"a\":1}", "orders", "amq.default", "true", "{\"content_type\":\"application/json\"}", "{\"x-n\":1}", "7"])
        XCTAssertEqual(result.rows[1], ["2", "base64:AAEC", "k", "logs", "false", nil, nil, "3"])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(RabbitText.readyCount(Data(json.utf8)), 0)
        XCTAssertTrue(try RabbitText.messages(Data(json.utf8), limit: 1).truncated)
    }

    func testAPIAnswers() throws {
        let queues = try RabbitText.rows(
            Data(#"[{"messages":2,"name":"b","vhost":"/","arguments":{"x-queue-type":"quorum"}},{"name":"a","vhost":"/","durable":true}]"#.utf8),
            limit: 10)
        XCTAssertEqual(queues.columns, ["name", "vhost", "messages", "arguments", "durable"])
        XCTAssertEqual(queues.rows, [["b", "/", "2", "{\"x-queue-type\":\"quorum\"}", nil], ["a", "/", nil, nil, "true"]])
        let overview = try RabbitText.rows(Data(#"{"rabbitmq_version":"3.13.7","cluster_name":"rabbit@x"}"#.utf8), limit: 10)
        XCTAssertEqual(overview.columns, ["key", "value"])
        XCTAssertEqual(overview.rows, [["cluster_name", "rabbit@x"], ["rabbitmq_version", "3.13.7"]])
        let paged = try RabbitText.rows(Data(#"{"items":[{"name":"q"}],"page":1,"page_count":3}"#.utf8), limit: 10)
        XCTAssertEqual(paged.rows, [["q"]])
        XCTAssertEqual(paged.message, "Page 1 of 3")
        XCTAssertEqual(try RabbitText.rows(Data(#"["a","b","c"]"#.utf8), limit: 2).rows, [["a"], ["b"]])
        XCTAssertEqual(try RabbitText.rows(Data(), limit: 2).message, "Done")
        XCTAssertEqual(RabbitText.said(Data(#"{"error":"Object Not Found","reason":"Not Found"}"#.utf8), status: 404), "Object Not Found: Not Found")
        XCTAssertEqual(RabbitText.said(Data(#"{"error":"bad_request","reason":"bad_request"}"#.utf8), status: 400), "bad_request")
    }

    func testAddressPasted() throws {
        let connection = DatabaseConnection(name: "", kind: .rabbitmq)
        let local = try XCTUnwrap(KindAddress.fill(connection, from: "http://ot:otpass@localhost:15672/#/queues"))
        XCTAssertEqual(local.connection.host, "localhost")
        XCTAssertEqual(local.connection.port, 15672)
        XCTAssertEqual(local.connection.user, "ot")
        XCTAssertEqual(local.connection.basePath, "")
        XCTAssertEqual(local.connection.sslMode, .disable)
        XCTAssertEqual(local.password, "otpass")
        let proxied = try XCTUnwrap(KindAddress.fill(connection, from: "https://mq.example.com/rabbitmq/api"))
        XCTAssertEqual(proxied.connection.port, 443)
        XCTAssertEqual(proxied.connection.basePath, "/rabbitmq")
        XCTAssertEqual(proxied.connection.sslMode, .verifyFull)
        let amqps = try XCTUnwrap(KindAddress.fill(connection, from: "amqps://u:p%40ss@bunny.rmq.cloudamqp.com/shop"))
        XCTAssertEqual(amqps.connection.port, 443)
        XCTAssertEqual(amqps.connection.database, "shop")
        XCTAssertEqual(amqps.password, "p@ss")
        XCTAssertEqual(amqps.connection.sslMode, .verifyFull)
        let amqp = try XCTUnwrap(KindAddress.fill(connection, from: "amqp://guest:guest@rabbit:5672/%2F"))
        XCTAssertEqual(amqp.connection.port, 15672)
        XCTAssertEqual(amqp.connection.database, "/")
        XCTAssertEqual(try XCTUnwrap(KindAddress.fill(connection, from: "amqp://rabbit")).connection.database, "/")
    }

    func testDockerContainer() throws {
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "rabbitmq:3-management")?.0, .rabbitmq)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "bitnami/rabbitmq:3.13")?.0, .rabbitmq)
        XCTAssertNil(DockerDatabaseGuess.kind(of: "kbudde/rabbitmq-exporter"))
    }

    // MARK: Against a server

    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(readOnly: Bool = false, password: String = "otpass") -> (DatabaseConnection, String) {
        var connection = DatabaseConnection(name: "RabbitMQ", kind: .rabbitmq)
        connection.host = "127.0.0.1"
        connection.port = 55672
        connection.user = "ot"
        connection.sslMode = .disable
        connection.readOnly = readOnly
        return (connection, password)
    }

    func testDriverAgainstRabbitMQ() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh queues") }
        let (config, password) = connection()
        let driver = RabbitMQDriver(config, password: password)
        try await driver.connect()
        let queue = "ot-test-\(UUID().uuidString.prefix(8))"
        let exchange = "ot-x-\(UUID().uuidString.prefix(8))"
        _ = try await driver.execute("PUT /api/queues/%2F/\(queue)\n{\"durable\": false, \"arguments\": {}}", limit: 10)
        _ = try await driver.execute("PUT /api/exchanges/%2F/\(exchange)\n{\"type\": \"topic\"}", limit: 10)
        _ = try await driver.execute("POST /api/bindings/%2F/e/\(exchange)/q/\(queue)\n{\"routing_key\": \"eu.#\"}", limit: 10)

        let published = try await driver.execute("PUBLISH \(exchange) eu.orders {\"id\": 1}", limit: 10)
        XCTAssertEqual(published.affected, 1, published.message ?? "")
        _ = try await driver.execute("PUBLISH amq.default \(queue) second", limit: 10)
        let dropped = try await driver.execute("PUBLISH \(exchange) us.orders nobody", limit: 10)
        XCTAssertEqual(dropped.affected, 0)
        XCTAssertTrue(dropped.message?.contains("dropped") == true, dropped.message ?? "")

        // Read twice: PEEK puts them back.
        for _ in 0..<2 {
            let peeked = try await driver.execute("PEEK \(queue) 10", limit: 100)
            XCTAssertEqual(peeked.rows.map { $0[1] }, ["{\"id\": 1}", "second"])
            XCTAssertEqual(peeked.rows.first?[2], "eu.orders")
            XCTAssertTrue(peeked.message?.contains("of 2") == true, peeked.message ?? "")
        }
        let one = try await driver.execute("PEEK \(queue) 1", limit: 100)
        XCTAssertEqual(one.rows.count, 1)

        // The tree.
        let vhosts = try await driver.schemas()
        XCTAssertEqual(vhosts.first, "/")
        let tables = try await driver.tables(in: "/")
        let row = try XCTUnwrap(tables.first { $0.name == queue })
        // The API's counts are sampled every few seconds: only the shape is sure.
        XCTAssertTrue(row.detail?.contains(" ready · ") == true, row.detail ?? "")
        XCTAssertTrue(tables.contains { $0.name == "exchange:\(exchange)" && $0.detail == "topic" })
        XCTAssertTrue(tables.contains { $0.name == "exchange:amq.default" })
        let columns = try await driver.columns(in: "/")
        XCTAssertTrue(columns.contains(CatalogColumn(table: queue, name: "← \(exchange)", type: "eu.#")), "\(columns)")

        // The API.
        let listed = try await driver.execute("GET /api/queues/%2F?columns=name,messages", limit: 1000)
        XCTAssertEqual(listed.columns.first, "name")
        XCTAssertTrue(listed.rows.contains { $0.first == queue })
        let overview = try await driver.execute("GET /api/overview", limit: 1000)
        XCTAssertTrue(overview.rows.contains { $0.first == "rabbitmq_version" })

        // Said plainly.
        do {
            _ = try await driver.execute("PEEK nope-\(queue)", limit: 10)
            XCTFail("a missing queue")
        } catch {
            XCTAssertEqual(error.localizedDescription, "There's no queue nope-\(queue) in vhost /.")
        }
        do {
            _ = try await driver.execute("USE nowhere", limit: 10)
            XCTFail("a missing vhost")
        } catch {
            XCTAssertEqual(error.localizedDescription, "There's no vhost nowhere.")
        }

        // Read-only: nothing that writes is sent.
        let (readOnlyConfig, _) = connection(readOnly: true)
        let reader = RabbitMQDriver(readOnlyConfig, password: password)
        for write in ["PURGE \(queue)", "PUBLISH amq.default \(queue) x", "DELETE /api/queues/%2F/\(queue)"] {
            do {
                _ = try await reader.execute(write, limit: 10)
                XCTFail(write)
            } catch let error as DatabaseError {
                guard case .readOnly = error else { return XCTFail("\(error)") }
            }
        }
        let readOnlyPeek = try await reader.execute("PEEK \(queue)", limit: 10)
        XCTAssertEqual(readOnlyPeek.rows.count, 2, "a read-only connection peeks")
        await reader.close()

        let purged = try await driver.execute("PURGE \(queue)", limit: 10)
        XCTAssertEqual(purged.message, "Purged \(queue): its ready messages are deleted.")
        // A quorum queue: each peek counts as a delivery, said.
        let quorum = queue + "-q"
        _ = try await driver.execute("PUT /api/queues/%2F/\(quorum)\n{\"durable\": true, \"arguments\": {\"x-queue-type\": \"quorum\"}}", limit: 10)
        _ = try await driver.execute("PUBLISH \"\" \(quorum) q", limit: 10)
        let quorumPeek = try await driver.execute("PEEK \(quorum)", limit: 10)
        XCTAssertEqual(quorumPeek.rows.first?[1], "q")
        XCTAssertTrue(quorumPeek.message?.contains("quorum queue") == true, quorumPeek.message ?? "")
        _ = try await driver.execute("DELETE /api/queues/%2F/\(quorum)", limit: 10)

        let empty = try await driver.execute("PEEK \(queue)", limit: 10)
        XCTAssertEqual(empty.rows.count, 0)
        XCTAssertEqual(empty.message, "\(queue) has no ready messages.")
        _ = try await driver.execute("DELETE /api/queues/%2F/\(queue)", limit: 10)
        _ = try await driver.execute("DELETE /api/exchanges/%2F/\(exchange)", limit: 10)
        await driver.close()
    }

    func testWrongPasswordAndPort() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh queues") }
        let (config, _) = connection()
        let wrong = RabbitMQDriver(config, password: "nope")
        do {
            try await wrong.connect()
            XCTFail("a wrong password")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refused ot"), error.localizedDescription)
        }
        await wrong.close()
        var closed = config
        closed.port = 55699
        let nobody = RabbitMQDriver(closed, password: "otpass")
        do {
            try await nobody.connect()
            XCTFail("nothing there")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing answers"), error.localizedDescription)
        }
        await nobody.close()
    }
}
