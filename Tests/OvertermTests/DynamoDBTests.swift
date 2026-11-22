import Foundation
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

/// DynamoDB: PartiQL's checks, typed values as text, items as rows, the
/// catalog's columns, signing — offline; the driver against DynamoDB Local
/// when OVERTERM_DB_TESTS=1 and Scripts/database-test-servers.sh runs it.
final class DynamoDBTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    func testPartiQLReadsAndDangers() {
        XCTAssertTrue(DynamoText.onlyReads(#"SELECT * FROM "orders" WHERE pk = 'a'"#))
        XCTAssertFalse(DynamoText.onlyReads(#"INSERT INTO "orders" VALUE {'pk': 'a'}"#))
        XCTAssertFalse(DynamoText.onlyReads(#"UPDATE "orders" SET n = 1 WHERE pk = 'a'"#))
        XCTAssertFalse(DynamoText.agentReads(#"DELETE FROM "orders" WHERE pk = 'a'"#))
        XCTAssertNil(DynamoText.danger(of: #"DELETE FROM "orders" WHERE pk = 'a'"#))
        XCTAssertNotNil(DynamoText.danger(of: #"DELETE FROM "orders""#))
        XCTAssertNotNil(DynamoText.danger(of: #"UPDATE "orders" SET note = 'WHERE'"#), "a WHERE in a string is none")
        XCTAssertEqual(DatabaseKind.dynamodb.statements(in: "SELECT * FROM \"a\";\nSELECT * FROM \"b;c\"").count, 2)
        XCTAssertEqual(DynamoText.subject(of: #"SELECT * FROM "my-orders"."byUser" WHERE pk = 'a'"#), "my-orders")
        XCTAssertEqual(DynamoText.subject(of: "SELECT * FROM orders"), "orders")
        XCTAssertEqual(DynamoText.browse(#"we"ird"#), #"SELECT * FROM "we""ird""#)
        XCTAssertEqual(DatabaseKind.dynamodb.verb(of: "  select 1"), "SELECT")
    }

    func testValuesAsText() {
        XCTAssertEqual(DynamoItems.text(["S": "hi"]), "hi")
        XCTAssertEqual(DynamoItems.text(["N": "12.50"]), "12.50")
        XCTAssertEqual(DynamoItems.text(["BOOL": true]), "true")
        XCTAssertNil(DynamoItems.text(["NULL": true]))
        XCTAssertEqual(DynamoItems.text(["B": "3q2+7w=="]), "3q2+7w==")
        XCTAssertEqual(DynamoItems.text(["SS": ["a", "b"]]), #"["a","b"]"#)
        XCTAssertEqual(DynamoItems.text(["NS": ["1", "2.5"]]), "[1,2.5]")
        XCTAssertEqual(
            DynamoItems.text(json(#"{"M": {"z": {"N": "1"}, "a": {"L": [{"S": "x/y"}, {"BOOL": false}, {"NULL": true}]}}}"#)),
            #"{"a":["x/y",false,null],"z":1}"#)
    }

    func testItemsAsRowsKeysFirst() {
        let items = [
            json(#"{"sk": {"S": "2"}, "pk": {"S": "a"}, "note": {"S": "hi"}}"#),
            json(#"{"pk": {"S": "b"}, "sk": {"S": "1"}, "count": {"N": "3"}}"#),
        ]
        let (columns, types, rows) = DynamoItems.rows(items, keys: ["pk", "sk"])
        XCTAssertEqual(columns, ["pk", "sk", "count", "note"])
        XCTAssertEqual(types, ["S", "S", "N", "S"])
        XCTAssertEqual(rows, [["a", "2", nil, "hi"], ["b", "1", "3", nil]])
    }

    func testTableDescriptionAsColumns() {
        let description = json(
            #"""
            {"TableName": "orders",
             "AttributeDefinitions": [{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "N"},
                                      {"AttributeName": "user", "AttributeType": "S"}],
             "KeySchema": [{"AttributeName": "sk", "KeyType": "RANGE"}, {"AttributeName": "pk", "KeyType": "HASH"}],
             "GlobalSecondaryIndexes": [{"IndexName": "byUser", "KeySchema": [{"AttributeName": "user", "KeyType": "HASH"}]}]}
            """#)
        XCTAssertEqual(DynamoItems.keyNames(description), ["pk", "sk"])
        XCTAssertEqual(
            DynamoItems.columns(of: "orders", description: description).map { "\($0.name): \($0.type)" },
            ["pk: S · partition key", "sk: N · sort key", "byUser: GSI · user"])
    }

    func testErrorsSaid() {
        let data = Data(#"{"__type":"com.amazonaws.dynamodb.v20120810#UnrecognizedClientException","message":"The security token is invalid."}"#.utf8)
        let error = DynamoItems.errorType(data)
        XCTAssertEqual(error?.type, "UnrecognizedClientException")
        XCTAssertTrue(DynamoItems.explain(error!.type, error!.message).contains("access key"))
        XCTAssertTrue(DynamoItems.isAWS("dynamodb.eu-west-1.amazonaws.com"))
        XCTAssertFalse(DynamoItems.isAWS("localhost"))
        XCTAssertEqual(DynamoItems.endpoint(region: "eu-west-1"), "dynamodb.eu-west-1.amazonaws.com")
    }

    /// AWS's own example for SigV4 with a JSON API: the target header signed.
    func testSignsTheTarget() throws {
        let signer = S3Signer(accessKey: "AKIDEXAMPLE", secretKey: "secret", sessionToken: nil, region: "us-east-1", service: "dynamodb")
        let url = try XCTUnwrap(URL(string: "https://dynamodb.us-east-1.amazonaws.com/"))
        let headers = signer.sign(
            method: "POST", url: url, headers: ["content-type": "application/x-amz-json-1.0", "x-amz-target": "DynamoDB_20120810.ListTables"],
            payloadHash: S3Signer.sha256(Data("{}".utf8)), date: Date(timeIntervalSince1970: 1_700_000_000))
        let authorization = try XCTUnwrap(headers["Authorization"])
        XCTAssertTrue(authorization.contains("Credential=AKIDEXAMPLE/20231114/us-east-1/dynamodb/aws4_request"), authorization)
        XCTAssertTrue(authorization.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-target"), authorization)
    }

    func testAddressPasted() throws {
        var connection = DatabaseConnection(name: "", kind: .dynamodb)
        let aws = try XCTUnwrap(KindAddress.fill(connection, from: "https://dynamodb.eu-central-1.amazonaws.com"))
        XCTAssertEqual(aws.connection.location, "eu-central-1")
        XCTAssertNil(aws.connection.port)
        XCTAssertEqual(aws.connection.sslMode, .verifyFull)
        connection.location = "us-east-1"
        let local = try XCTUnwrap(KindAddress.fill(connection, from: "localhost:8001"))
        XCTAssertEqual(local.connection.host, "localhost")
        XCTAssertEqual(local.connection.port, 8001)
        XCTAssertEqual(local.connection.sslMode, .disable)
        XCTAssertEqual(local.connection.name, "localhost")
    }

    // MARK: Against DynamoDB Local

    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    func testDriverAgainstDynamoDBLocal() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        var connection = DatabaseConnection(name: "DynamoDB", kind: .dynamodb)
        connection.host = "127.0.0.1"
        connection.port = 58800
        connection.sslMode = .disable
        connection.location = "us-east-1"
        let driver = DynamoDBDriver(connection, password: nil)
        try await driver.connect()
        let table = "ot_orders_\(Int.random(in: 1000...9999))"
        _ = try await driver.call(
            "CreateTable",
            json: """
                {"TableName": "\(table)", "BillingMode": "PAY_PER_REQUEST",
                 "AttributeDefinitions": [{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "N"}],
                 "KeySchema": [{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}]}
                """)
        for n in 1...5 {
            let written = try await driver.execute(
                "INSERT INTO \"\(table)\" VALUE {'pk': 'a', 'sk': \(n), 'note': 'it''s \(n)', 'tags': ['x', \(n)], 'ok': true}", limit: 10)
            XCTAssertFalse(written.hasRows)
        }
        let all = try await driver.execute("SELECT * FROM \"\(table)\" WHERE pk = 'a'", limit: 100)
        XCTAssertEqual(Array(all.columns.prefix(2)), ["pk", "sk"], "the keys first")
        XCTAssertEqual(all.rows.count, 5)
        let note = try XCTUnwrap(all.columns.firstIndex(of: "note"))
        let tags = try XCTUnwrap(all.columns.firstIndex(of: "tags"))
        XCTAssertEqual(all.rows[0][note], "it's 1")
        XCTAssertEqual(all.rows[0][tags], #"["x",1]"#)
        XCTAssertFalse(all.truncated)
        let limited = try await driver.execute("SELECT * FROM \"\(table)\"", limit: 2)
        XCTAssertEqual(limited.rows.count, 2)
        XCTAssertTrue(limited.truncated)
        let tables = try await driver.tables(in: "us-east-1").map(\.name)
        XCTAssertTrue(tables.contains(table))
        let columns = try await driver.columns(in: "us-east-1").filter { $0.table == table }
        XCTAssertEqual(columns.map(\.name), ["pk", "sk"])
        do {
            _ = try await driver.execute("SELECT * FROM \"nope_\(table)\"", limit: 10)
            XCTFail("a missing table read")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        var readOnly = connection
        readOnly.readOnly = true
        let reader = DynamoDBDriver(readOnly, password: nil)
        do {
            _ = try await reader.execute("DELETE FROM \"\(table)\" WHERE pk = 'a' AND sk = 1", limit: 1)
            XCTFail("a read-only connection wrote")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("only reads"), error.localizedDescription)
        }
        _ = try await driver.call("DeleteTable", json: #"{"TableName": "\#(table)"}"#)
        await reader.close()
        await driver.close()
        // Nobody there: said so.
        connection.port = 1
        do {
            try await DynamoDBDriver(connection, password: nil).connect()
            XCTFail("connected to nothing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing answers"), error.localizedDescription)
        }
    }
}

/// Open in Database for DynamoDB Local's, InfluxDB's and Neo4j's containers.
final class DockerGuessHTTPKindsTests: XCTestCase {
    private func container(_ image: String, inside: Int, outside: Int) -> ContainerSummary {
        ContainerSummary(
            Id: "x", Names: ["/shop-db-1"], Image: image, Created: 1, Ports: [DockerPort(IP: "0.0.0.0", PrivatePort: inside, PublicPort: outside, Type: "tcp")],
            Labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "db"], State: "running", Status: "")
    }

    func testKinds() {
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "amazon/dynamodb-local:2.5.2")?.0, .dynamodb)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "amazon/dynamodb-local")?.port, 8000)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "influxdb:2")?.0, .influxdb)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "bitnami/influxdb:2.7")?.port, 8086)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "neo4j:5-community")?.0, .neo4j)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "neo4j:5")?.port, 7474, "the HTTP API's port, not Bolt's")
        XCTAssertNil(DockerDatabaseGuess.kind(of: "prom/influxdb-exporter"), "a tool beside it")
        XCTAssertNil(DockerClient.kind(of: "influxdb:2"), "no client of its own in the container")
    }

    func testGuesses() throws {
        let neo4j = try XCTUnwrap(DockerDatabaseGuess.guess(container("neo4j:5", inside: 7474, outside: 57474), env: [("NEO4J_AUTH", "neo4j/pa/ss")]))
        XCTAssertEqual(neo4j.connection.kind, .neo4j)
        XCTAssertEqual(neo4j.connection.port, 57474)
        XCTAssertEqual(neo4j.connection.user, "neo4j")
        XCTAssertEqual(neo4j.password, "pa/ss")
        let open = try XCTUnwrap(DockerDatabaseGuess.guess(container("neo4j:5", inside: 7474, outside: 57474), env: [("NEO4J_AUTH", "none")]))
        XCTAssertEqual(open.connection.user, "")
        XCTAssertNil(open.password)
        let influx2 = try XCTUnwrap(
            DockerDatabaseGuess.guess(
                container("influxdb:2", inside: 8086, outside: 58086),
                env: [
                    ("DOCKER_INFLUXDB_INIT_MODE", "setup"), ("DOCKER_INFLUXDB_INIT_ORG", "acme"), ("DOCKER_INFLUXDB_INIT_BUCKET", "metrics"),
                    ("DOCKER_INFLUXDB_INIT_ADMIN_TOKEN", "tok"),
                ]))
        XCTAssertEqual(influx2.connection.location, "2")
        XCTAssertEqual(influx2.connection.project, "acme")
        XCTAssertEqual(influx2.connection.database, "metrics")
        XCTAssertEqual(influx2.password, "tok")
        let influx1 = try XCTUnwrap(
            DockerDatabaseGuess.guess(
                container("influxdb:1.8", inside: 8086, outside: 58087),
                env: [("INFLUXDB_DB", "shop"), ("INFLUXDB_ADMIN_USER", "admin"), ("INFLUXDB_ADMIN_PASSWORD", "pw")]))
        XCTAssertEqual(influx1.connection.location, "1")
        XCTAssertEqual(influx1.connection.user, "admin")
        XCTAssertEqual(influx1.password, "pw")
        let dynamo = try XCTUnwrap(DockerDatabaseGuess.guess(container("amazon/dynamodb-local", inside: 8000, outside: 58800), env: []))
        XCTAssertEqual(dynamo.connection.kind, .dynamodb)
        XCTAssertEqual(dynamo.connection.port, 58800)
        XCTAssertEqual(dynamo.connection.location, "us-east-1")
        XCTAssertEqual(dynamo.connection.sslMode, .disable)
    }
}
