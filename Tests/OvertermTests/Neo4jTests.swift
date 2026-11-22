import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// Neo4j: Cypher's statements and checks, both HTTP APIs' answers as rows —
/// offline; the driver against neo4j:5 when OVERTERM_DB_TESTS=1 and
/// Scripts/database-test-servers.sh runs it.
final class Neo4jTests: XCTestCase {
    private func statements(_ text: String) -> [String] {
        let ns = text as NSString
        return CypherText.statements(in: text).map { ns.substring(with: $0) }
    }

    func testStatements() {
        let text = """
            MATCH (n:Person {name: 'a;b'}) RETURN n; // a ; in a comment
            MATCH (`we;ird`) RETURN 1

            CREATE (n:Person)
            RETURN n
            """
        XCTAssertEqual(
            statements(text),
            [
                "MATCH (n:Person {name: 'a;b'}) RETURN n", "// a ; in a comment\nMATCH (`we;ird`) RETURN 1",
                "CREATE (n:Person)\nRETURN n",
            ])
    }

    func testWhatWrites() {
        XCTAssertTrue(CypherText.onlyReads("MATCH (n:Person) WHERE n.name = 'CREATE' RETURN n"))
        XCTAssertTrue(CypherText.onlyReads("MATCH (n) RETURN n.set, n.`delete`, $merge"))
        XCTAssertTrue(CypherText.onlyReads("MATCH (n:Create) RETURN n"), "a label isn't a clause")
        XCTAssertFalse(CypherText.onlyReads("MATCH (n) SET n.x = 1"))
        XCTAssertFalse(CypherText.onlyReads("merge (n:A)"))
        XCTAssertFalse(CypherText.onlyReads("LOAD CSV FROM 'file:///x' AS row RETURN row"))
        XCTAssertFalse(CypherText.onlyReads("MATCH (n) CALL { WITH n RETURN n } IN TRANSACTIONS RETURN n"))
        XCTAssertTrue(CypherText.onlyReads("CALL apoc.create.node(['A'], {})"), "a person's procedure: the server's read mode decides")
        XCTAssertFalse(CypherText.agentReads("CALL apoc.create.node(['A'], {})"))
        XCTAssertTrue(CypherText.agentReads("CALL db.labels()"))
        XCTAssertTrue(CypherText.agentReads("CALL db.schema.visualization()"))
        XCTAssertTrue(CypherText.agentReads("SHOW INDEXES"))
        XCTAssertTrue(CypherText.agentReads(":use other"))
        XCTAssertEqual(CypherText.verb(of: "MATCH (n) DETACH DELETE n"), "DETACH DELETE")
        XCTAssertEqual(CypherText.verb(of: "MATCH (n) RETURN n"), "MATCH")
        XCTAssertEqual(DatabaseKind.neo4j.verb(of: "MATCH (n) SET n.a = 1"), "SET")
    }

    func testDangers() {
        XCTAssertNotNil(CypherText.danger(of: "MATCH (n) DETACH DELETE n"))
        XCTAssertNotNil(CypherText.danger(of: "MATCH (n) DELETE n"))
        XCTAssertNotNil(CypherText.danger(of: "MATCH (n:Person) DETACH DELETE n"))
        XCTAssertNil(CypherText.danger(of: "MATCH (n:Person) WHERE n.name = 'a' DETACH DELETE n"))
        XCTAssertNil(CypherText.danger(of: "MATCH (n:Person {name: 'a'}) DELETE n"))
        XCTAssertNotNil(CypherText.danger(of: "DROP DATABASE shop"))
        XCTAssertNil(CypherText.danger(of: "MATCH (n) RETURN n"))
    }

    func testUseSubjectBrowse() {
        XCTAssertEqual(CypherText.use(":use movies")?.database, "movies")
        XCTAssertEqual(CypherText.use(":USE `my-db`\nMATCH (n) RETURN n")?.rest, "MATCH (n) RETURN n")
        XCTAssertNil(CypherText.use("MATCH (n) RETURN n"))
        XCTAssertEqual(CypherText.subject(of: "MATCH (p:Person)-[:ACTED_IN]->(m) RETURN p"), "Person")
        XCTAssertEqual(CypherText.subject(of: "MATCH ()-[r:`ACTED IN`]->() RETURN r"), "ACTED IN")
        let connection = DatabaseConnection(name: "n", kind: .neo4j)
        XCTAssertEqual(
            CypherText.browse(CatalogTable(schema: "neo4j", name: "Person"), connection: connection, limit: 100), "MATCH (n:Person) RETURN n LIMIT 100")
        XCTAssertEqual(
            CypherText.browse(CatalogTable(schema: "movies", name: "[:ACTED IN]"), connection: connection, limit: 5),
            ":use movies\nMATCH (a)-[r:`ACTED IN`]->(b) RETURN a, r, b LIMIT 5")
    }

    func testTransactionalAnswer() throws {
        let data = Data(
            #"""
            {"results":[{"columns":["n","r","count","path"],"data":[
              {"row":[{"name":"Ann"},{"since":2020},3,[{"name":"Ann"},{},{"name":"Bob"}]],
               "meta":[{"id":1,"elementId":"4:x:1","type":"node","deleted":false},{"id":7,"elementId":"5:x:7","type":"relationship","deleted":false},null,
                       [{"id":1,"type":"node","deleted":false},{"id":8,"type":"relationship","deleted":false},{"id":2,"type":"node","deleted":false}]],
               "graph":{"nodes":[{"id":"1","labels":["Person"],"properties":{"name":"Ann"}},{"id":"2","labels":["Person"],"properties":{"name":"Bob"}}],
                        "relationships":[{"id":"7","type":"KNOWS","startNode":"1","endNode":"2","properties":{"since":2020}},
                                         {"id":"8","type":"LIKES","startNode":"1","endNode":"2","properties":{}}]}}
            ],"stats":{"contains_updates":true,"nodes_created":2,"properties_set":3}}],"errors":[]}
            """#.utf8)
        let answer = try Neo4jParse.answer(data, limit: 10)
        XCTAssertTrue(answer.errors.isEmpty)
        XCTAssertEqual(answer.result.columns, ["n", "r", "count", "path"])
        XCTAssertEqual(
            answer.result.rows,
            [
                [
                    #"{"labels":["Person"],"properties":{"name":"Ann"}}"#, #"{"properties":{"since":2020},"type":"KNOWS"}"#, "3",
                    #"[{"labels":["Person"],"properties":{"name":"Ann"}},{"properties":{},"type":"LIKES"},{"labels":["Person"],"properties":{"name":"Bob"}}]"#,
                ]
            ])
        XCTAssertEqual(answer.result.types, ["node", "relationship", "", ""])
        XCTAssertEqual(answer.result.message, "2 nodes created, 3 properties set")
        let failed = try Neo4jParse.answer(
            Data(#"{"results":[],"errors":[{"code":"Neo.ClientError.Statement.SyntaxError","message":"Invalid input 'X'"}]}"#.utf8), limit: 10)
        XCTAssertEqual(failed.errors.first?.code, "Neo.ClientError.Statement.SyntaxError")
    }

    func testQueryAPIAnswer() throws {
        let data = Data(
            #"""
            {"data":{"fields":["n","name"],"values":[
              [{"elementId":"4:x:0","labels":["Person"],"properties":{"name":"Ann"}},"Ann"],
              [{"elementId":"5:x:1","startNodeElementId":"4:x:0","endNodeElementId":"4:x:1","type":"KNOWS","properties":{}},null]]},
             "counters":{"containsUpdates":true,"nodesCreated":1,"relationshipsCreated":0}}
            """#.utf8)
        let answer = try Neo4jParse.answer(data, limit: 10)
        XCTAssertEqual(answer.result.columns, ["n", "name"])
        XCTAssertEqual(
            answer.result.rows,
            [[#"{"labels":["Person"],"properties":{"name":"Ann"}}"#, "Ann"], [#"{"properties":{},"type":"KNOWS"}"#, nil]])
        XCTAssertEqual(answer.result.message, "1 nodes created")
        XCTAssertEqual(Neo4jParse.rawRows(data).count, 2)
        XCTAssertTrue(Neo4jParse.explain("Neo.ClientError.Security.Unauthorized", "x").contains("refused"))
    }

    func testAddressPasted() throws {
        let connection = DatabaseConnection(name: "", kind: .neo4j)
        let aura = try XCTUnwrap(KindAddress.fill(connection, from: "neo4j+s://abcd1234.databases.neo4j.io"))
        XCTAssertEqual(aura.connection.port, 443)
        XCTAssertEqual(aura.connection.sslMode, .verifyFull)
        let bolt = try XCTUnwrap(KindAddress.fill(connection, from: "bolt://neo4j:pw@db.local:7687"))
        XCTAssertEqual(bolt.connection.port, 7474, "Bolt's port is not the HTTP API's")
        XCTAssertEqual(bolt.connection.sslMode, .disable)
        XCTAssertEqual(bolt.connection.user, "neo4j")
        XCTAssertEqual(bolt.password, "pw")
        let http = try XCTUnwrap(KindAddress.fill(connection, from: "http://localhost:7475/db/movies"))
        XCTAssertEqual(http.connection.port, 7475)
        XCTAssertEqual(http.connection.database, "movies")
    }

    // MARK: Against neo4j:5

    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection() -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Neo4j", kind: .neo4j)
        connection.host = "127.0.0.1"
        connection.port = 57474
        connection.user = "neo4j"
        connection.sslMode = .disable
        return connection
    }

    func testDriverAgainstNeo4j() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        for api in [Neo4jDriver.API.transactional, .query] {
            let driver = Neo4jDriver(connection(), password: "otpass1234", api: api)
            try await driver.connect()
            _ = try await driver.execute("MATCH (n:OtPerson) DETACH DELETE n", limit: 10)
            let made = try await driver.execute(
                "CREATE (a:OtPerson {name: 'Ann', age: 31})-[:OT_KNOWS {since: 2020}]->(b:OtPerson {name: 'Bob'}) RETURN a, b", limit: 10)
            XCTAssertEqual(made.rows.count, 1)
            XCTAssertEqual(made.rows[0][0], #"{"labels":["OtPerson"],"properties":{"age":31,"name":"Ann"}}"#, "\(api)")
            XCTAssertTrue(made.message?.contains("2 nodes created") == true, made.message ?? "")
            let read = try await driver.execute(
                "MATCH (a:OtPerson)-[r:OT_KNOWS]->(b) RETURN a.name AS name, r, b.age AS age", limit: 10)
            XCTAssertEqual(read.columns, ["name", "r", "age"])
            XCTAssertEqual(read.rows, [["Ann", #"{"properties":{"since":2020},"type":"OT_KNOWS"}"#, nil]], "\(api)")
            let limited = try await driver.execute("UNWIND range(1, 5) AS x RETURN x", limit: 2)
            XCTAssertEqual(limited.rows, [["1"], ["2"]])
            XCTAssertTrue(limited.truncated)
            let databases = try await driver.schemas()
            XCTAssertTrue(databases.contains("neo4j"))
            let tables = try await driver.tables(in: "neo4j").map(\.name)
            XCTAssertTrue(tables.contains("OtPerson") && tables.contains("[:OT_KNOWS]"), "\(tables)")
            let columns = try await driver.columns(in: "neo4j").filter { $0.table == "OtPerson" || $0.table == "[:OT_KNOWS]" }
                .map { "\($0.table).\($0.name) \($0.type)" }.sorted()
            XCTAssertEqual(columns, ["OtPerson.age Long", "OtPerson.name String", "[:OT_KNOWS].since Long"])
            do {
                _ = try await driver.execute("MATCH (n RETURN n", limit: 10)
                XCTFail("a syntax error ran")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Invalid input"), error.localizedDescription)
            }
            // Read-only: refused before sending, and the server's read mode.
            var readOnly = connection()
            readOnly.readOnly = true
            let reader = Neo4jDriver(readOnly, password: "otpass1234", api: api)
            do {
                _ = try await reader.execute("CREATE (n:OtPerson)", limit: 1)
                XCTFail("a read-only connection wrote")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("only reads"), error.localizedDescription)
            }
            do {
                _ = try await reader.execute("CALL db.createLabel('OtSneaky')", limit: 1)
                XCTFail("the server's read mode let a write procedure run (\(api))")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            await reader.close()
            _ = try await driver.execute("MATCH (n:OtPerson) DETACH DELETE n", limit: 10)
            await driver.close()
        }
        do {
            try await Neo4jDriver(connection(), password: "wrong").connect()
            XCTFail("a wrong password connected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refused the user or password"), error.localizedDescription)
        }
        var bolt = connection()
        bolt.port = 57687
        do {
            try await Neo4jDriver(bolt, password: "otpass1234").connect()
            XCTFail("Bolt's port answered HTTP")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
