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

/// Elasticsearch and OpenSearch: the console's requests, the checks, the
/// answers as rows, the catalog, a pasted address — pure, always run.
final class SearchTextTests: XCTestCase {
    private func requests(_ text: String) -> [String] {
        SearchText.statements(in: text).map { (text as NSString).substring(with: $0) }
    }

    func testRequestsSplitAtMethodLinesAndBlankLinesOutsideABody() {
        let text = """
            # the orders
            GET /orders/_search
            {
              "query": {

                "match": { "note": "a\\n\\nb" }
              }
            }
            GET _cat/indices?v
            POST /orders/_doc
            {"note": "x"}

            // a comment between
            DELETE /old
            """
        let found = requests(text)
        XCTAssertEqual(found.count, 4, "\(found)")
        XCTAssertTrue(found[0].hasPrefix("GET /orders/_search") && found[0].hasSuffix("}"), found[0])
        XCTAssertTrue(found[0].contains("\"match\""), "a blank line inside the body doesn't end it")
        XCTAssertEqual(found[1], "GET _cat/indices?v")
        XCTAssertEqual(found[2], "POST /orders/_doc\n{\"note\": \"x\"}")
        XCTAssertEqual(found[3], "DELETE /old")
        // The caret anywhere in a request picks it.
        let caret = (text as NSString).range(of: "match").location
        XCTAssertEqual(SearchText.statement(at: caret, in: text).map { (text as NSString).substring(with: $0) }, found[0])
        // A body's line starting like a method, inside braces, isn't a request.
        XCTAssertEqual(requests("POST /x/_search\n{\n\"q\":\nGET\n}").count, 1)
    }

    func testARequestIsParsed() throws {
        let request = try SearchRequest.parse("# hi\nget orders/_search?q=note:a\n{\n  \"size\": 5\n}")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/orders/_search?q=note:a")
        XCTAssertEqual(request.route, "/orders/_search")
        XCTAssertEqual(request.body, "{\n  \"size\": 5\n}")
        XCTAssertEqual(request.endpoint, "_search")
        XCTAssertEqual(request.indices, ["orders"])
        XCTAssertNil(try SearchRequest.parse("GET /").body)
        XCTAssertEqual(try SearchRequest.parse("GET http://es:9200/_cluster/health?pretty").path, "/_cluster/health?pretty")
        XCTAssertThrowsError(try SearchRequest.parse("SELECT 1"))
    }

    func testBulkBodiesAreALineAnObject() throws {
        let request = try SearchRequest.parse(
            """
            POST _bulk
            { "index": { "_index": "orders", "_id": "1" } }
            {
              "note": "pretty",
              "qty": 2
            }
            """)
        XCTAssertTrue(request.isNDJSON)
        let lines = request.body?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(request.body?.hasSuffix("\n") == true, "NDJSON ends with a newline")
        XCTAssertFalse(lines[1].contains(" "), lines[1])
    }

    func testTripleQuotesAreAJSONString() throws {
        let request = try SearchRequest.parse("POST /_sql\n{\"query\": \"\"\"\nSELECT \"a\"\nFROM t\n\"\"\"}")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((request.body ?? "").utf8)) as? [String: String])
        XCTAssertEqual(object["query"], "\nSELECT \"a\"\nFROM t\n")
    }

    func testWhatOnlyReads() throws {
        func reads(_ text: String) throws -> Bool { try SearchRequest.parse(text).onlyReads }
        XCTAssertTrue(try reads("GET /orders/_doc/1"))
        XCTAssertTrue(try reads("HEAD /orders"))
        XCTAssertTrue(try reads("POST /orders/_search\n{}"))
        XCTAssertTrue(try reads("POST /_search/scroll\n{}"))
        XCTAssertTrue(try reads("POST /orders,returns/_count"))
        XCTAssertTrue(try reads("POST _msearch\n{}\n{}"))
        XCTAssertTrue(try reads("POST /_sql?format=json\n{\"query\": \"SELECT 1\"}"))
        XCTAssertTrue(try reads("POST /_plugins/_sql\n{\"query\": \"SELECT 1\"}"))
        XCTAssertFalse(try reads("POST /orders/_doc\n{}"))
        XCTAssertFalse(try reads("PUT /orders"))
        XCTAssertFalse(try reads("DELETE /orders/_doc/1"))
        XCTAssertFalse(try reads("POST /orders/_delete_by_query\n{}"))
        XCTAssertFalse(try reads("POST /orders/_mapping\n{}"), "a POST to _mapping changes it")
        XCTAssertFalse(try reads("POST /_pit?keep_alive=1m"))
        XCTAssertFalse(try reads("POST /orders/_update/1\n{}"))
        XCTAssertFalse(try reads("POST _bulk\n{}"))
        // The kind's checks say the same; a line that isn't a request is no read.
        XCTAssertTrue(DatabaseKind.elasticsearch.onlyReads("GET /_cat/indices"))
        XCTAssertFalse(DatabaseKind.opensearch.onlyReads("nonsense"))
        XCTAssertEqual(DatabaseKind.elasticsearch.verb(of: "PUT /orders?pretty\n{}"), "PUT /orders")
        // Agents read, but not who holds which key.
        XCTAssertTrue(DatabaseKind.elasticsearch.agentReads("GET /orders/_search"))
        XCTAssertFalse(DatabaseKind.elasticsearch.agentReads("GET /_security/api_key"))
        XCTAssertFalse(DatabaseKind.opensearch.agentReads("GET /_plugins/_security/api/internalusers"))
        XCTAssertFalse(DatabaseKind.opensearch.agentReads("PUT /orders"))
    }

    func testWhatDestroys() {
        let kind = DatabaseKind.elasticsearch
        XCTAssertEqual(kind.danger(of: "DELETE /orders"), "It deletes the index orders and every document in it.")
        XCTAssertNotNil(kind.danger(of: "DELETE /logs-*"))
        XCTAssertNotNil(kind.danger(of: "DELETE /_all"))
        XCTAssertNotNil(kind.danger(of: "DELETE /_data_stream/logs-app"))
        XCTAssertNotNil(kind.danger(of: "POST /orders/_delete_by_query\n{\"query\": {\"match_all\": {}}}"))
        XCTAssertNotNil(kind.danger(of: "POST /orders/_update_by_query"))
        XCTAssertNil(kind.danger(of: "DELETE /orders/_doc/1"))
        XCTAssertNil(kind.danger(of: "GET /orders"))
        XCTAssertEqual(kind.subject(of: "GET /orders/_search"), "orders")
        XCTAssertEqual(kind.subject(of: "GET /_cat/indices?v"), "_cat/indices")
    }

    // MARK: Answers

    private func result(_ json: String, _ request: String = "GET /orders/_search", limit: Int = 100) throws -> QueryResult {
        SearchResults.result(Data(json.utf8), request: try SearchRequest.parse(request), status: 200, limit: limit)
    }

    func testHitsAreRows() throws {
        let answer = """
            {"took": 3, "hits": {"total": {"value": 12, "relation": "eq"}, "max_score": 1.0, "hits": [
              {"_index": "orders", "_id": "1", "_score": 1.0, "_source": {"note": "first", "qty": 2, "address": {"city": "Ankara"}}},
              {"_index": "orders", "_id": "2", "_score": 0.5, "_source": {"note": null, "paid": true, "tags": ["a", "b"]}}
            ]}}
            """
        let result = try result(answer)
        XCTAssertEqual(result.columns, ["_index", "_id", "_score", "address", "note", "qty", "paid", "tags"])
        XCTAssertEqual(result.rows[0], ["orders", "1", "1", "{\"city\":\"Ankara\"}", "first", "2", nil, nil])
        XCTAssertEqual(result.rows[1], ["orders", "2", "0.5", nil, nil, nil, "true", "[\"a\",\"b\"]"])
        XCTAssertTrue(result.truncated, "12 hits, 2 shown")
        XCTAssertEqual(result.message, "12 hits in 3 ms, 2 shown — \"size\" in the body for more.")
        // The grid's limit keeps the first.
        XCTAssertEqual(try self.result(answer, limit: 1).rows.count, 1)
    }

    func testSortedHitsHaveNoScoreColumn() throws {
        let result = try result(#"{"hits": {"total": {"value": 1, "relation": "gte"}, "hits": [{"_index": "o", "_id": "1", "_score": null, "_source": {"a": 1}}]}}"#)
        XCTAssertEqual(result.columns, ["_index", "_id", "a"])
        XCTAssertEqual(result.message, "≥ 1 hits.")
    }

    func testBucketsAreRows() throws {
        let answer = """
            {"took": 1, "hits": {"total": {"value": 3, "relation": "eq"}, "hits": []},
             "aggregations": {"cities": {"buckets": [
               {"key": "Ankara", "doc_count": 2, "avg_qty": {"value": 1.5}},
               {"key": "Izmir", "doc_count": 1, "avg_qty": {"value": 3}}
             ]}}}
            """
        let result = try result(answer)
        XCTAssertEqual(result.columns, ["cities", "doc_count", "avg_qty"])
        XCTAssertEqual(result.rows, [["Ankara", "2", "1.5"], ["Izmir", "1", "3"]])
        let metric = try self.result(#"{"hits": {"hits": []}, "aggregations": {"total": {"value": 42}}}"#)
        XCTAssertEqual(metric.rows, [["42"]])
        let nested = try self.result(#"{"hits": {"hits": []}, "aggregations": {"a": {"value": 1}, "b": {"value": 2}}}"#)
        XCTAssertEqual(nested.columns, ["aggregations"])
        XCTAssertTrue(nested.rows[0][0]?.contains("\"b\"") == true)
    }

    func testCatSQLAndCountAreRows() throws {
        let cat = try result(
            #"[{"health": "green", "index": "orders", "docs.count": "3"}, {"health": "yellow", "index": "logs", "docs.count": "10"}]"#, "GET _cat/indices")
        XCTAssertEqual(cat.columns, ["health", "index", "docs.count"], "the server's order")
        XCTAssertEqual(cat.rows[1], ["yellow", "logs", "10"])
        let sql = try result(
            #"{"columns": [{"name": "qty", "type": "integer"}, {"name": "note", "type": "text"}], "rows": [[1, "a"], [2, null]]}"#, "POST /_sql")
        XCTAssertEqual(sql.columns, ["qty", "note"])
        XCTAssertEqual(sql.types, ["integer", "text"])
        XCTAssertEqual(sql.rows, [["1", "a"], ["2", nil]])
        let opensearch = try result(
            #"{"schema": [{"name": "qty", "type": "integer"}], "datarows": [[1], [2]], "total": 2, "size": 2, "status": 200}"#, "POST /_plugins/_sql")
        XCTAssertEqual(opensearch.rows, [["1"], ["2"]])
        let esql = try result(#"{"columns": [{"name": "n", "type": "long"}], "values": [[7]]}"#, "POST /_query")
        XCTAssertEqual(esql.rows, [["7"]])
        let count = try result(#"{"count": 3, "_shards": {"total": 1}}"#, "GET /orders/_count")
        XCTAssertEqual(count.rows, [["3"]])
        let text = try result("health index\ngreen  orders\n", "GET _cat/indices?format=txt")
        XCTAssertEqual(text.rows, [["health index"], ["green  orders"]])
    }

    func testOtherAnswersAreTheirJSON() throws {
        let created = try result(#"{"_index": "orders", "_id": "9", "result": "created"}"#, "POST /orders/_doc")
        XCTAssertEqual(created.columns, ["response"])
        XCTAssertEqual(created.message, "Created — _id 9.")
        XCTAssertEqual(created.affected, 1)
        XCTAssertEqual(try result(#"{"acknowledged": true}"#, "PUT /orders").message, "Acknowledged.")
        XCTAssertEqual(try result(#"{"took": 5, "deleted": 4, "total": 4}"#, "POST /orders/_delete_by_query").message, "4 deleted.")
        let exists = SearchResults.result(Data(), request: try SearchRequest.parse("HEAD /orders"), status: 404, limit: 10)
        XCTAssertEqual(exists.message, "404 — it doesn't exist.")
    }

    func testErrorsInTheServersWords() {
        let missing = """
            {"error": {"root_cause": [{"type": "index_not_found_exception", "reason": "no such index [nope]"}],
             "type": "index_not_found_exception", "reason": "no such index [nope]"}, "status": 404}
            """
        XCTAssertEqual(SearchResults.error(Data(missing.utf8), status: 404), "index_not_found_exception: no such index [nope]")
        let parse = """
            {"error": {"type": "x_content_parse_exception", "reason": "[1:10] [bool] failed to parse",
             "caused_by": {"type": "illegal_argument_exception", "reason": "unknown field [mutt]"}}, "status": 400}
            """
        XCTAssertEqual(SearchResults.error(Data(parse.utf8), status: 400), "x_content_parse_exception: [1:10] [bool] failed to parse — unknown field [mutt]")
        XCTAssertEqual(SearchResults.error(Data("Bad gateway".utf8), status: 502), "Bad gateway")
    }

    // MARK: The catalog and the connection

    func testMappingsAreDottedFields() {
        let answer = """
            {"orders": {"mappings": {"properties": {
              "note": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
              "address": {"properties": {"city": {"type": "keyword"}}},
              "items": {"type": "nested", "properties": {"sku": {"type": "keyword"}}}
            }}},
             "old": {"mappings": {"_doc": {"properties": {"a": {"type": "long"}}}}}}
            """
        let found = SearchCatalog.mappings(Data(answer.utf8))
        XCTAssertEqual(
            found["orders"]?.map { "\($0.0) \($0.1)" },
            ["address.city keyword", "items nested", "items.sku keyword", "note text", "note.keyword keyword"])
        XCTAssertEqual(found["old"]?.map(\.0), ["a"], "a mapping type's level, before 7")
        XCTAssertEqual(SearchCatalog.docs("1"), "1 doc")
        XCTAssertEqual(SearchCatalog.docs("1500000"), "1.5M docs")
    }

    func testAddressesAndCloudIDs() throws {
        let url = try XCTUnwrap(SearchAddress("https://elastic:p%40ss@search.example.com:9243/es"))
        XCTAssertEqual(url.host, "search.example.com")
        XCTAssertEqual(url.port, 9243)
        XCTAssertTrue(url.tls)
        XCTAssertEqual(url.path, "/es")
        XCTAssertEqual(url.user, "elastic")
        XCTAssertEqual(url.password, "p@ss")
        XCTAssertEqual(SearchAddress("localhost")?.port, 9200)
        let id = "shop:" + Data("us-east-1.aws.found.io$abc123$def456".utf8).base64EncodedString()
        let cloud = try XCTUnwrap(SearchAddress(id))
        XCTAssertEqual(cloud.host, "abc123.us-east-1.aws.found.io")
        XCTAssertEqual(cloud.port, 443)
        XCTAssertTrue(cloud.tls)
    }

    func testAuthHeaders() {
        XCTAssertEqual(SearchAuth.header(user: "ot", secret: "otpass"), "Basic " + Data("ot:otpass".utf8).base64EncodedString())
        XCTAssertEqual(SearchAuth.header(user: "", secret: "VnVhQ2ZHY0JDZGJrUW0tZTVhT3g6dWkybHAyYXhUTm1zeWFrdzl0dk5udw=="), "ApiKey VnVhQ2ZHY0JDZGJrUW0tZTVhT3g6dWkybHAyYXhUTm1zeWFrdzl0dk5udw==")
        XCTAssertEqual(SearchAuth.header(user: "", secret: "id1:key1"), "ApiKey " + Data("id1:key1".utf8).base64EncodedString())
        XCTAssertEqual(SearchAuth.header(user: "", secret: "Bearer abc"), "Bearer abc")
        XCTAssertNil(SearchAuth.header(user: "", secret: nil))
        XCTAssertEqual(SearchAWS.region(host: "search-shop-abc.eu-west-1.es.amazonaws.com"), "eu-west-1")
        XCTAssertEqual(SearchAWS.service(host: "abc.us-east-1.aoss.amazonaws.com"), "aoss")
        XCTAssertNil(SearchAWS.region(host: "localhost"))
    }

    func testPathsAreEncodedAsTheServerReadsThem() {
        var connection = DatabaseConnection(name: "es", kind: .elasticsearch)
        connection.basePath = "/proxy"
        connection.sslMode = .require
        let driver = SearchDriver(connection, password: nil)
        XCTAssertEqual(driver.url("/logs-*,orders/_search?q=note:a b")?.absoluteString, "https://localhost:9200/proxy/logs-*,orders/_search?q=note:a%20b")
        XCTAssertEqual(driver.url("/orders/_doc/a%2Fb")?.absoluteString, "https://localhost:9200/proxy/orders/_doc/a%2Fb")
    }

    func testAGetWithABodyGoesAsTheReadingPost() throws {
        XCTAssertEqual(try SearchDriver.wireMethod(SearchRequest.parse("GET /orders/_search\n{\"size\": 1}")), "POST")
        XCTAssertEqual(try SearchDriver.wireMethod(SearchRequest.parse("GET /orders/_search")), "GET")
        XCTAssertEqual(try SearchDriver.wireMethod(SearchRequest.parse("PUT /orders\n{}")), "PUT")
        // A POST to _mapping writes: never what a GET becomes.
        XCTAssertThrowsError(try SearchDriver.wireMethod(SearchRequest.parse("GET /orders/_mapping\n{}")))
    }

    func testDockerImagesAreConnections() throws {
        func container(_ image: String) -> ContainerSummary {
            ContainerSummary(
                Id: "x", Names: ["/search"], Image: image, Created: 1,
                Ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 9200, PublicPort: 59200, Type: "tcp")], Labels: [:], State: "running", Status: "")
        }
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "docker.elastic.co/elasticsearch/elasticsearch:8.15.3")?.0, .elasticsearch)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "opensearchproject/opensearch:2")?.0, .opensearch)
        XCTAssertNil(DockerDatabaseGuess.kind(of: "opensearchproject/opensearch-dashboards:2"))
        XCTAssertNil(DockerDatabaseGuess.kind(of: "quay.io/prometheuscommunity/elasticsearch-exporter"))
        let elastic = try XCTUnwrap(DockerDatabaseGuess.guess(container("elasticsearch:8.15.3"), env: [("ELASTIC_PASSWORD", "s3cret")]))
        XCTAssertEqual(elastic.connection.kind, .elasticsearch)
        XCTAssertEqual(elastic.connection.port, 59200)
        XCTAssertEqual(elastic.connection.user, "elastic")
        XCTAssertEqual(elastic.connection.sslMode, .require)
        XCTAssertEqual(elastic.password, "s3cret")
        let open = try XCTUnwrap(DockerDatabaseGuess.guess(container("elasticsearch:8.15.3"), env: [("xpack.security.enabled", "false")]))
        XCTAssertEqual(open.connection.sslMode, .disable)
        XCTAssertEqual(open.connection.user, "")
        XCTAssertEqual(try XCTUnwrap(DockerDatabaseGuess.guess(container("elasticsearch:7.17.10"), env: [])).connection.sslMode, .disable)
        let plain = try XCTUnwrap(DockerDatabaseGuess.guess(container("opensearchproject/opensearch:2"), env: [("DISABLE_SECURITY_PLUGIN", "true")]))
        XCTAssertEqual(plain.connection.kind, .opensearch)
        XCTAssertEqual(plain.connection.sslMode, .disable)
        let secured = try XCTUnwrap(
            DockerDatabaseGuess.guess(container("opensearchproject/opensearch:2"), env: [("OPENSEARCH_INITIAL_ADMIN_PASSWORD", "Str0ng!pass")]))
        XCTAssertEqual(secured.connection.user, "admin")
        XCTAssertEqual(secured.password, "Str0ng!pass")
        XCTAssertEqual(secured.connection.sslMode, .require)
    }
}

/// The driver against real servers: Elasticsearch 8 (security on: TLS with
/// its own certificate, user `ot`) and OpenSearch 2 (its security plugin
/// off), when OVERTERM_DB_TESTS=1 and `Scripts/database-test-servers.sh
/// search` has them running.
final class SearchDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(_ kind: DatabaseKind, port: Int, user: String = "", tls: Bool) -> DatabaseConnection {
        var connection = DatabaseConnection(name: kind.title, kind: kind)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.user = user
        connection.sslMode = tls ? .require : .disable
        return connection
    }

    /// Reachable, or skipped: `search` starts these two apart from the rest.
    private func reachable(_ driver: SearchDriver) async throws {
        do {
            try await driver.connect()
        } catch let error as DatabaseError where error.localizedDescription.contains("Couldn't reach") {
            throw XCTSkip("Scripts/database-test-servers.sh search — \(error.localizedDescription)")
        }
    }

    /// The same work on both: an index made, filled by _bulk, searched,
    /// counted, aggregated, asked in SQL, listed; a mistake said as the
    /// server says it; the catalog; read-only refused before sending.
    private func exercise(_ driver: SearchDriver, kind: DatabaseKind, sqlPath: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let product = await driver.product ?? ""
        XCTAssertTrue(product.hasPrefix(kind == .opensearch ? "OpenSearch" : "Elasticsearch"), product, file: file, line: line)
        _ = try? await driver.execute("DELETE /ot-orders", limit: 10)
        let made = try await driver.execute(
            """
            PUT /ot-orders
            {
              "mappings": {
                "properties": {
                  "note": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
                  "qty": {"type": "integer"},
                  "address": {"properties": {"city": {"type": "keyword"}}}
                }
              }
            }
            """, limit: 10)
        XCTAssertEqual(made.message, "Acknowledged.", file: file, line: line)
        let bulk = try await driver.execute(
            """
            POST /_bulk?refresh=true
            {"index": {"_index": "ot-orders", "_id": "1"}}
            {"note": "first", "qty": 1, "address": {"city": "Ankara"}}
            {"index": {"_index": "ot-orders", "_id": "2"}}
            {
              "note": "it's second",
              "qty": 2,
              "address": {"city": "Ankara"}
            }
            {"index": {"_index": "ot-orders", "_id": "3"}}
            {"note": null, "qty": 3, "address": {"city": "Izmir"}}
            """, limit: 10)
        XCTAssertEqual(bulk.affected, 3, bulk.message ?? "", file: file, line: line)
        let all = try await driver.execute("GET /ot-orders/_search\n{\"sort\": [{\"qty\": \"asc\"}]}", limit: 100)
        XCTAssertEqual(all.columns, ["_index", "_id", "address", "note", "qty"], file: file, line: line)
        XCTAssertEqual(all.rows.map { $0[1] }, ["1", "2", "3"], file: file, line: line)
        XCTAssertEqual(all.rows[0][2], "{\"city\":\"Ankara\"}", file: file, line: line)
        XCTAssertEqual(all.rows[2][3], nil, file: file, line: line)
        XCTAssertFalse(all.truncated, file: file, line: line)
        XCTAssertTrue(all.message?.hasPrefix("3 hits") == true, all.message ?? "", file: file, line: line)
        let limited = try await driver.execute("GET /ot-orders/_search", limit: 2)
        XCTAssertEqual(limited.rows.count, 2, file: file, line: line)
        XCTAssertTrue(limited.truncated, file: file, line: line)
        let count = try await driver.execute("GET /ot-orders/_count\n{\"query\": {\"match\": {\"note\": \"second\"}}}", limit: 10)
        XCTAssertEqual(count.rows, [["1"]], file: file, line: line)
        let cities = try await driver.execute(
            "POST /ot-orders/_search\n{\"size\": 0, \"aggs\": {\"cities\": {\"terms\": {\"field\": \"address.city\"}, \"aggs\": {\"qty\": {\"sum\": {\"field\": \"qty\"}}}}}}",
            limit: 10)
        XCTAssertEqual(cities.columns, ["cities", "doc_count", "qty"], file: file, line: line)
        XCTAssertEqual(cities.rows, [["Ankara", "2", "3"], ["Izmir", "1", "3"]], file: file, line: line)
        let cat = try await driver.execute("GET /_cat/indices/ot-*?h=index,docs.count", limit: 10)
        XCTAssertEqual(cat.columns, ["index", "docs.count"], file: file, line: line)
        XCTAssertEqual(cat.rows, [["ot-orders", "3"]], file: file, line: line)
        // Elasticsearch quotes a name in double quotes, OpenSearch in backticks.
        let name = kind == .opensearch ? "`ot-orders`" : "\"ot-orders\""
        let sql = try await driver.execute("POST \(sqlPath)\n{\"query\": \"\"\"\nSELECT qty FROM \(name) ORDER BY qty\n\"\"\"}", limit: 10)
        XCTAssertEqual(sql.columns, ["qty"], file: file, line: line)
        XCTAssertEqual(sql.rows, [["1"], ["2"], ["3"]], file: file, line: line)
        let exists = try await driver.execute("HEAD /ot-orders", limit: 1)
        XCTAssertEqual(exists.message, "200 — it exists.", file: file, line: line)
        do {
            _ = try await driver.execute("GET /ot-nope/_search", limit: 10)
            XCTFail("a missing index", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("index_not_found_exception"), error.localizedDescription, file: file, line: line)
        }
        _ = try await driver.execute("POST /_aliases\n{\"actions\": [{\"add\": {\"index\": \"ot-orders\", \"alias\": \"ot-current\"}}]}", limit: 10)
        let schemas = try await driver.schemas()
        XCTAssertEqual(schemas.first, SearchCatalog.indices, file: file, line: line)
        XCTAssertTrue(schemas.contains(SearchCatalog.aliases), "\(schemas)", file: file, line: line)
        let tables = try await driver.tables(in: SearchCatalog.indices)
        XCTAssertEqual(tables.first { $0.name == "ot-orders" }?.detail, "3 docs", "\(tables)", file: file, line: line)
        XCTAssertFalse(tables.contains { $0.name.hasPrefix(".") }, "hidden indices aren't listed", file: file, line: line)
        let columns = try await driver.columns(in: SearchCatalog.indices).filter { $0.table == "ot-orders" }
        XCTAssertEqual(
            columns.map { "\($0.name) \($0.type)" }, ["address.city keyword", "note text", "note.keyword keyword", "qty integer"], file: file, line: line)
        let aliased = try await driver.columns(in: SearchCatalog.aliases).filter { $0.table == "ot-current" }
        XCTAssertEqual(aliased.count, 4, file: file, line: line)
        let deleted = try await driver.execute("POST /ot-orders/_delete_by_query?refresh=true\n{\"query\": {\"term\": {\"qty\": 3}}}", limit: 10)
        XCTAssertEqual(deleted.affected, 1, file: file, line: line)
        _ = try await driver.execute("DELETE /ot-orders", limit: 10)
        await driver.close()
    }

    func testElasticsearch() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh search") }
        let config = connection(.elasticsearch, port: 59200, user: "ot", tls: true)
        let driver = SearchDriver(config, password: "otpass")
        try await reachable(driver)
        try await exercise(driver, kind: .elasticsearch, sqlPath: "/_sql?format=json")
        // ES|QL's columns too.
        let esql = SearchDriver(config, password: "otpass")
        try await esql.connect()
        let answer = try await esql.execute("POST /_query\n{\"query\": \"ROW a = 1, b = \\\"two\\\"\"}", limit: 10)
        XCTAssertEqual(answer.columns, ["a", "b"])
        XCTAssertEqual(answer.rows, [["1", "two"]])

        // A data stream: its own folder, its fields its backing index's.
        _ = try await esql.execute(
            "PUT /_index_template/ot-logs\n{\"index_patterns\": [\"ot-logs*\"], \"data_stream\": {}, \"template\": {\"mappings\": {\"properties\": {\"msg\": {\"type\": \"keyword\"}}}}}",
            limit: 10)
        _ = try await esql.execute("PUT /_data_stream/ot-logs", limit: 10)
        let folders = try await esql.schemas()
        XCTAssertTrue(folders.contains(SearchCatalog.dataStreams), "\(folders)")
        let streams = try await esql.tables(in: SearchCatalog.dataStreams)
        XCTAssertTrue(streams.contains { $0.name == "ot-logs" }, "\(streams)")
        let streamed = try await esql.columns(in: SearchCatalog.dataStreams).filter { $0.table == "ot-logs" }.map(\.name)
        XCTAssertTrue(streamed.contains("msg") && streamed.contains("@timestamp"), "\(streamed)")
        _ = try await esql.execute("DELETE /_data_stream/ot-logs", limit: 10)
        _ = try await esql.execute("DELETE /_index_template/ot-logs", limit: 10)

        // An API key, the password's place without a user.
        let made = try await esql.execute("POST /_security/api_key\n{\"name\": \"ot-test\", \"expiration\": \"1h\"}", limit: 10)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((made.rows.first?.first ?? "")?.utf8 ?? "".utf8)) as? [String: Any])
        let encoded = try XCTUnwrap(object["encoded"] as? String)
        let keyed = SearchDriver(connection(.elasticsearch, port: 59200, tls: true), password: encoded)
        try await keyed.connect()
        let health = try await keyed.execute("GET /_cluster/health", limit: 10)
        XCTAssertTrue(health.rows.first?.first??.contains("\"status\"") == true)
        await keyed.close()
        _ = try? await esql.execute("DELETE /_security/api_key\n{\"name\": \"ot-test\"}", limit: 10)
        await esql.close()

        // A wrong password, in words; TLS checked against a self-signed certificate, refused.
        let wrong = SearchDriver(config, password: "nope")
        do {
            try await wrong.connect()
            XCTFail("a wrong password")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refused the credentials (401)"), error.localizedDescription)
        }
        var verified = config
        verified.sslMode = .verifyFull
        verified.serverName = "127.0.0.1"
        do {
            try await SearchDriver(verified, password: "otpass").connect()
            XCTFail("a self-signed certificate checked")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("TLS failed"), error.localizedDescription)
        }
        // Read-only: refused before it is sent.
        var reader = config
        reader.readOnly = true
        let readOnly = SearchDriver(reader, password: "otpass")
        try await readOnly.connect()
        do {
            _ = try await readOnly.execute("PUT /ot-never", limit: 1)
            XCTFail("a write on a read-only connection")
        } catch {
            XCTAssertEqual(error as? DatabaseError, .readOnly("PUT /ot-never"))
        }
        let exists = try await readOnly.execute("HEAD /ot-never", limit: 1)
        XCTAssertEqual(exists.message, "404 — it doesn't exist.")
        await readOnly.close()
    }

    func testOpenSearch() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh search") }
        let driver = SearchDriver(connection(.opensearch, port: 59210, tls: false), password: nil)
        try await reachable(driver)
        try await exercise(driver, kind: .opensearch, sqlPath: "/_plugins/_sql")
    }
}
