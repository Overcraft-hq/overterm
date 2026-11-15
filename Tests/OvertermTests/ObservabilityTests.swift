import XCTest

@testable import Overterm

/// Prometheus, Loki and Tempo as the client reads them — the answers'
/// shapes, a console's queries, the levels and trace ids in log lines.
final class ObservabilityParseTests: XCTestCase {
    func testPrometheusMatrixAndVector() throws {
        let matrix = Data(
            #"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"__name__":"up","job":"api"},"values":[[1700000000,"1"],[1700000015,"0"]]}]}}"#.utf8)
        let series = try ObservabilityParse.prometheus(matrix)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].points.map(\.value), [1, 0])
        XCTAssertEqual(series[0].id, #"up{job="api"}"#)
        let vector = Data(#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1700000000.5,"NaN"]}]}}"#.utf8)
        XCTAssertTrue(try ObservabilityParse.prometheus(vector)[0].points[0].value.isNaN)
        let scalar = Data(#"{"status":"success","data":{"resultType":"scalar","result":[1700000000,"42"]}}"#.utf8)
        XCTAssertEqual(try ObservabilityParse.prometheus(scalar)[0].points[0].value, 42)
        let error = Data(#"{"status":"error","errorType":"bad_data","error":"parse error"}"#.utf8)
        XCTAssertThrowsError(try ObservabilityParse.prometheus(error)) { XCTAssertEqual($0.localizedDescription, "parse error") }
    }

    func testSeriesAsRows() {
        let series = [
            MetricSeries(labels: ["__name__": "req", "code": "200"], points: [.init(time: Date(), value: 1), .init(time: Date(), value: 3)]),
            MetricSeries(labels: ["__name__": "req", "code": "500", "job": "api"], points: [.init(time: Date(), value: 0.25)]),
        ]
        let result = ObservabilityRows.result(.series(series), limit: 10)
        XCTAssertEqual(result.columns, ["metric", "code", "job", "value", "min", "max"])
        XCTAssertEqual(result.rows[0], ["req", "200", nil, "3", "1", "3"])
        XCTAssertEqual(result.rows[1][3], "0.25")
        XCTAssertNotNil(result.payload)
    }

    func testLokiStreamsNewestFirst() throws {
        let data = Data(
            #"{"status":"success","data":{"resultType":"streams","result":[{"stream":{"app":"api"},"values":[["1700000000000000002","b"],["1700000000000000001","a"]]},{"stream":{"app":"web"},"values":[["1700000000000000003","c",{"structuredMetadata":{"trace_id":"0af7651916cd43dd8448eb211c80319c"}}]]}]}}"#
                .utf8)
        guard case .logs(let lines) = try ObservabilityParse.loki(data) else { return XCTFail("lines") }
        XCTAssertEqual(lines.map(\.line), ["c", "b", "a"])
        XCTAssertEqual(lines[0].nanos, 1_700_000_000_000_000_003, "nanoseconds kept whole")
        XCTAssertEqual(lines[0].traceID, "0af7651916cd43dd8448eb211c80319c", "structured metadata")
        let metric = Data(#"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"app":"api"},"values":[[1700000000,"3"]]}]}}"#.utf8)
        guard case .series(let series) = try ObservabilityParse.loki(metric) else { return XCTFail("a metric query is series") }
        XCTAssertEqual(series.first?.points.first?.value, 3)
    }

    func testALinesLevelAndTrace() {
        XCTAssertEqual(LogLevel.of("level=error msg=x", labels: [:]), .error)
        XCTAssertEqual(LogLevel.of(#"{"level":"warn","msg":"x"}"#, labels: [:]), .warn)
        XCTAssertEqual(LogLevel.of("2026-11-13 ERROR something broke", labels: [:]), .error)
        XCTAssertEqual(LogLevel.of("anything", labels: ["level": "debug"]), .debug)
        XCTAssertNil(LogLevel.of("an error happened in lowercase prose", labels: [:]), "prose isn't a level")
        let line = LokiLine(nanos: 0, labels: [:], line: "msg=x traceID=4bf92f3577b34da6a3ce929d0e0e4736 status=500")
        XCTAssertEqual(line.traceID, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(LokiLine(nanos: 0, labels: [:], line: #"{"trace_id":"00f067aa0ba902b7"}"#).traceID, "00f067aa0ba902b7")
        XCTAssertNil(LokiLine(nanos: 0, labels: [:], line: "no trace here").traceID)
        // Tempo's search drops an id's leading zeros.
        XCTAssertTrue(LokiLine.isTraceID("198686e929454322f5c0e1a2b3c4d5e"))
        XCTAssertFalse(LokiLine.isTraceID("deadbeef"), "too short to be one")
    }

    func testTempoSearchTagsAndValues() throws {
        let search = Data(
            #"{"traces":[{"traceID":"abc","rootServiceName":"api","rootTraceName":"GET /","startTimeUnixNano":"1700000000000000000","durationMs":12}]}"#.utf8)
        let traces = try ObservabilityParse.tempoSearch(search)
        XCTAssertEqual(traces.first?.service, "api")
        XCTAssertEqual(traces.first?.durationMs, 12)
        let v2 = Data(#"{"scopes":[{"name":"resource","tags":["service.name"]},{"name":"intrinsic","tags":["duration"]}]}"#.utf8)
        XCTAssertEqual(try ObservabilityParse.tempoTags(v2), ["resource.service.name", "duration"])
        let mixed = Data(#"{"scopes":[{"name":"intrinsic","tags":["name"]},{"name":"span","tags":["http.route"]},{"name":"resource","tags":["service.name"]}]}"#.utf8)
        XCTAssertEqual(try ObservabilityParse.tempoTags(mixed), ["resource.service.name", "span.http.route", "name"], "resource's, then span's, then the rest")
        XCTAssertEqual(try ObservabilityParse.tempoTags(Data(#"{"tagNames":["b","a"]}"#.utf8)), ["a", "b"])
        XCTAssertEqual(try ObservabilityParse.tempoValues(Data(#"{"tagValues":[{"type":"string","value":"x"}]}"#.utf8)), ["x"])
        XCTAssertEqual(try ObservabilityParse.tempoValues(Data(#"{"tagValues":["y"]}"#.utf8)), ["y"])
    }

    func testATraceAsAWaterfall() throws {
        let body = try JSONSerialization.data(withJSONObject: E2EObservabilityServer.trace(start: 1_700_000_000))
        let trace = try ObservabilityParse.tempoTrace(body, id: E2EObservabilityServer.traceID)
        XCTAssertEqual(trace.spans.count, 3)
        let rows = trace.rows
        XCTAssertEqual(rows.map(\.span.name), ["GET /orders", "SELECT orders", "charge card"], "each under its parent, by start")
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(rows[0].span.id, "00f067aa0ba902b7", "base64 ids as hex")
        XCTAssertEqual(trace.services, ["api", "payments"])
        XCTAssertTrue(rows[2].span.failed)
        XCTAssertEqual(rows[0].span.attributes.first { $0.key == "http.status_code" }?.value, "500")
        XCTAssertEqual(trace.durationMs, 182, accuracy: 0.01)
        // v2's: under `trace`, resourceSpans.
        let v2 = try JSONSerialization.data(withJSONObject: ["trace": ["resourceSpans": (E2EObservabilityServer.trace(start: 0)["batches"] as? [Any]) ?? []]])
        XCTAssertEqual(try ObservabilityParse.tempoTrace(v2, id: "x").spans.count, 3)
        XCTAssertThrowsError(try ObservabilityParse.tempoTrace(Data("{}".utf8), id: "x"))
    }

    func testAConsoleIsABlockAQuery() {
        let text = "# errors\nsum(rate(x[5m]))\n  by (code)\n\nup\n\n\n{app=\"api\"}\n"
        let ns = text as NSString
        let blocks = DatabaseKind.prometheus.statements(in: text).map { ns.substring(with: $0) }
        XCTAssertEqual(blocks, ["sum(rate(x[5m]))\n  by (code)", "up", "{app=\"api\"}"])
        XCTAssertEqual(DatabaseKind.loki.statement(at: 14, in: text).map { ns.substring(with: $0) }, "sum(rate(x[5m]))\n  by (code)")
        XCTAssertTrue(DatabaseKind.tempo.onlyReads("{ status = error }"))
        XCTAssertNil(DatabaseKind.loki.danger(of: "{a=\"b\"}"))
        XCTAssertEqual(DatabaseKind.prometheus.subject(of: "rate(http_requests_total[5m])"), "rate")
        XCTAssertEqual(DatabaseKind.loki.subject(of: "sum(rate({app=\"api\"} |= \"x\" [1m]))"), "{app=\"api\"}")
        XCTAssertEqual(DatabaseKind.tempo.subject(of: "4bf92f3577b34da6a3ce929d0e0e4736"), "trace 4bf92f35")
        XCTAssertEqual(DatabaseKind.prometheus.subject(of: ".targets"), "targets")
    }

    func testCompletionAndSelectors() throws {
        let metric = try XCTUnwrap(ObservabilityText.complete("sum(rate(http_re", kind: .prometheus, names: ["http_requests_total", "up"]))
        XCTAssertEqual(metric.typed, "http_re")
        XCTAssertEqual(metric.candidates.first?.label, "http_requests_total")
        XCTAssertTrue(try XCTUnwrap(ObservabilityText.complete("histogram_q", kind: .prometheus, names: [])).candidates.map(\.label).contains("histogram_quantile"))
        XCTAssertTrue(try XCTUnwrap(ObservabilityText.complete("{app=\"x\"} | log", kind: .loki, names: [])).candidates.map(\.label).contains("logfmt"))
        XCTAssertEqual(DatabaseSession.selector(.loki, name: "app", value: "a\"b"), #"{app="a\"b"}"#)
        XCTAssertEqual(DatabaseSession.selector(.tempo, name: "resource.service.name", value: "api"), #"{ resource.service.name = "api" }"#)
        XCTAssertEqual(DatabaseSession.selector(.tempo, name: "status", value: "error"), "{ status = error }")
        XCTAssertEqual(DatabaseSession.selector(.tempo, name: "span:name", value: "GET /"), #"{ span:name = "GET /" }"#)
    }

    func testTheTimeWindow() {
        XCTAssertEqual(TimeRange.h1.step, 12)
        XCTAssertEqual(TimeRange.m5.step, 1)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(TimeRange.m15.window(now: now).start, Date(timeIntervalSince1970: 9100))
    }

    func testOldConnectionsStillOpen() throws {
        // A connections.json from before basePath existed.
        let json = Data(#"{"id":"\#(UUID().uuidString)","name":"x","kind":"postgres"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DatabaseConnection.self, from: json).basePath, "")
        var prom = DatabaseConnection(name: "p", kind: .prometheus)
        prom.basePath = "/prometheus"
        let again = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(prom))
        XCTAssertEqual(again.basePath, "/prometheus")
        XCTAssertEqual(again.port, 9090)
    }
}

/// The driver against the fake servers' APIs (E2EObservabilityServer).
final class ObservabilityDriverTests: XCTestCase {
    private var server: E2EObservabilityServer!

    override func setUpWithError() throws {
        server = E2EObservabilityServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    func testPrometheusGraphsTablesAndItsPages() async throws {
        let driver = ObservabilityDriver(server.connection(.prometheus), password: nil)
        try await driver.connect()
        let graph = try await driver.execute("sum(rate(http_requests_total[5m])) by (code)", limit: 100, range: .m15)
        guard case .series(let series)? = graph.payload else { return XCTFail("a graph") }
        XCTAssertEqual(series.count, 2)
        XCTAssertGreaterThan(series[0].points.count, 50, "15 minutes at a 3 s step")
        XCTAssertEqual(graph.columns, ["metric", "code", "job", "value", "min", "max"])
        // A range vector isn't a graph: its samples, now.
        let samples = try await driver.execute("up[1m]", limit: 100, range: .h1)
        XCTAssertEqual(samples.columns, ["series", "time", "value"])
        XCTAssertEqual(samples.rows.count, 2)
        do {
            _ = try await driver.execute("rate(x", limit: 10, range: .h1)
            XCTFail("a parse error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unclosed left parenthesis"), error.localizedDescription)
        }
        let targets = try await driver.execute(".targets", limit: 10, range: .h1)
        XCTAssertEqual(targets.rows.map { $0[2] }, ["down", "up"], "the down one first")
        let alerts = try await driver.execute(".alerts", limit: 10, range: .h1)
        XCTAssertEqual(alerts.rows.first?[0], "HighErrorRate")
        let names = try await driver.names()
        XCTAssertEqual(names.first, "http_requests_total")
        let labels = try await driver.values(of: "http_requests_total")
        XCTAssertFalse(labels.contains("__name__"))
        // The query arrives whole: `+` isn't a space.
        _ = try await driver.execute("up + up", limit: 10, range: .h1)
        XCTAssertTrue(server.seen.contains { $0.path == "/api/v1/query_range" })
    }

    func testLokiLinesMetricsAndTheTail() async throws {
        let driver = ObservabilityDriver(server.connection(.loki), password: nil)
        try await driver.connect()
        let logs = try await driver.execute("{app=~\".+\"}", limit: 100, range: .h1)
        guard case .logs(let lines)? = logs.payload else { return XCTFail("lines") }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first?.level, .error)
        XCTAssertEqual(lines.first?.traceID, E2EObservabilityServer.traceID)
        XCTAssertEqual(lines[1].level, .warn, "a level label")
        let metric = try await driver.execute("rate({app=\"api\"}[1m])", limit: 100, range: .h1)
        guard case .series? = metric.payload else { return XCTFail("a metric query graphs") }
        let after = lines.map(\.nanos).max() ?? 0
        let tail = try await driver.tail("{app=\"api\"}", after: after, limit: 100)
        XCTAssertEqual(tail.map(\.line), ["tailed line"])
        XCTAssertGreaterThan(tail[0].nanos, after)
        let apps = try await driver.values(of: "app")
        XCTAssertEqual(apps, ["api", "worker"])
        do {
            _ = try await driver.execute("nope", limit: 10, range: .h1)
            XCTFail("Loki's parse error, in its words")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("syntax error"), error.localizedDescription)
        }
    }

    func testTempoSearchAndATrace() async throws {
        let driver = ObservabilityDriver(server.connection(.tempo), password: nil)
        try await driver.connect()
        let search = try await driver.execute("{ resource.service.name = \"api\" }", limit: 20, range: .h1)
        guard case .traces(let traces)? = search.payload else { return XCTFail("traces") }
        XCTAssertEqual(traces.map(\.service), ["api", "worker"])
        // A trace's id: v2 isn't there (older Tempo), v1 is.
        let trace = try await driver.execute(E2EObservabilityServer.traceID, limit: 100, range: .h1)
        guard case .trace(let detail)? = trace.payload else { return XCTFail("a trace") }
        XCTAssertEqual(detail.spans.count, 3)
        let tags = try await driver.names()
        XCTAssertEqual(Array(tags.prefix(3)), ["resource.k8s.namespace.name", "resource.service.name", "span.http.route"])
        let services = try await driver.values(of: "resource.service.name")
        XCTAssertEqual(services, ["api", "worker"])
    }

    func testCredentialsTenantAndAPath() async throws {
        server.token = "s3cret"
        var connection = server.connection(.loki)
        connection.database = "team-a"
        let none = ObservabilityDriver(connection, password: nil)
        do {
            try await none.connect()
            XCTFail("no token, no answer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"), error.localizedDescription)
        }
        let driver = ObservabilityDriver(connection, password: "s3cret")
        try await driver.connect()
        let last = try XCTUnwrap(server.seen.last)
        XCTAssertEqual(last.headers["authorization"], "Bearer s3cret")
        XCTAssertEqual(last.headers["x-scope-orgid"], "team-a")
        connection.user = "ada"
        let basic = ObservabilityDriver(connection, password: "pw")
        _ = try? await basic.connect()
        XCTAssertEqual(server.seen.last?.headers["authorization"], "Basic " + Data("ada:pw".utf8).base64EncodedString())
        connection.basePath = "/loki-proxy/"
        XCTAssertEqual(ObservabilityDriver(connection, password: nil).url("/loki/api/v1/labels")?.path, "/loki-proxy/loki/api/v1/labels")
    }
}

/// Queries kept by name under their connection — across launches, and gone
/// with the connection.
@MainActor
final class SavedQueryTests: XCTestCase {
    func testSavedQueriesAreKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DatabaseStore(file: file, secrets: MemoryDatabaseSecrets())
        let connection = DatabaseConnection(name: "Logs", kind: .loki)
        try store.save(connection, password: nil)
        let other = DatabaseConnection(name: "Shop", kind: .postgres)
        try store.save(other, password: nil)
        let model = DatabaseModel(store: store)
        for query in model.saved { model.remove(query) }
        model.save("errors", text: "{app=\"api\"} |= \"error\"", on: connection.id)
        model.save("  b  ", text: "{app=\"web\"}", on: connection.id)
        model.save("orders", text: "SELECT * FROM orders", on: other.id)
        XCTAssertEqual(model.saved(for: connection.id).map(\.name), ["b", "errors"], "by name, trimmed")
        model.save("errors", text: "{app=\"api\"} | level=\"error\"", on: connection.id)
        XCTAssertEqual(model.saved(for: connection.id).count, 2, "the same name replaces")
        XCTAssertEqual(model.saved(for: connection.id).last?.text, "{app=\"api\"} | level=\"error\"")
        let b = try XCTUnwrap(model.saved(for: connection.id).first)
        model.rename(b, to: "web")
        // Another launch reads them back.
        let again = DatabaseModel(store: store)
        XCTAssertEqual(again.saved(for: connection.id).map(\.name), ["errors", "web"])
        XCTAssertEqual(again.saved(for: other.id).map(\.name), ["orders"])
        try again.delete(connection)
        XCTAssertTrue(again.saved(for: connection.id).isEmpty, "gone with its connection")
        XCTAssertEqual(DatabaseModel(store: store).saved.map(\.name), ["orders"])
        for query in again.saved { again.remove(query) }
    }
}
