import Foundation
import Network

/// Prometheus, Loki and Tempo as their HTTP APIs answer — in one fake on
/// 127.0.0.1, for the tests and the scenario: nothing leaves the machine.
/// Its data is made around the moment it is asked, so every window has
/// some; its answers have the shapes each API documents (a range query's
/// matrix, Loki's streams with nanosecond strings, Tempo's search and its
/// OTLP JSON with base64 ids).
///
/// A `token` makes it want `Authorization: Bearer <token>`; every
/// request's headers are kept (`seen`) for the tests to look at.
final class E2EObservabilityServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "overterm.e2e-observability")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var token: String?
    private let lock = NSLock()
    private var requests: [(path: String, headers: [String: String])] = []

    /// The trace every log line of the `api` app points at.
    static let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"

    var seen: [(path: String, headers: [String: String])] { lock.withLock { requests } }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func connection(_ kind: DatabaseKind, name: String? = nil) -> DatabaseConnection {
        var connection = DatabaseConnection(name: name ?? kind.title, kind: kind)
        connection.host = "127.0.0.1"
        connection.port = Int(port)
        connection.sslMode = .disable
        return connection
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if complete || error != nil { return connection.cancel() }
                self.receive(connection, buffer: buffer)
            case .invalid:
                self.respond(connection, 400, "bad request")
            case .complete(let request):
                let (status, body) = self.answer(request)
                self.respond(connection, status, body)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ body: Any) {
        let data: Data
        let type: String
        if let text = body as? String {
            data = Data(text.utf8)
            type = "text/plain"
        } else {
            data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            type = "application/json"
        }
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        head += "Content-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: The APIs

    private func answer(_ request: HTTPRequest) -> (Int, Any) {
        let components = URLComponents(string: "http://x" + request.path)
        let path = components?.path ?? request.path
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        lock.withLock { requests.append((path, request.headers)) }
        if let token, request.headers["authorization"] != "Bearer \(token)" { return (401, "unauthorized") }
        let now = Date().timeIntervalSince1970
        func success(_ data: Any) -> [String: Any] { ["status": "success", "data": data] }

        switch path {
        // Prometheus
        case "/api/v1/status/buildinfo": return (200, success(["version": "2.53.0"]))
        case "/api/v1/label/__name__/values": return (200, success(["http_requests_total", "process_cpu_seconds_total", "up"]))
        case "/api/v1/labels": return (200, success(["__name__", "code", "instance", "job"]))
        case "/api/v1/query_range":
            let promql = query["query"] ?? ""
            if promql.contains("(") && !promql.contains(")") {
                return (400, ["status": "error", "errorType": "bad_data", "error": "1:6: parse error: unclosed left parenthesis"])
            }
            if promql.hasSuffix("]") {
                return (
                    400,
                    [
                        "status": "error", "errorType": "bad_data",
                        "error": "invalid parameter \"query\": invalid expression type \"range vector\" for range query, must be Scalar or instant Vector",
                    ]
                )
            }
            let start = Double(query["start"] ?? "") ?? now - 3600
            let end = Double(query["end"] ?? "") ?? now
            let step = max(1, Double(query["step"] ?? "") ?? 15)
            func values(_ scale: Double) -> [[Any]] {
                stride(from: start, through: end, by: step).enumerated().map { [$0.element, String(scale * Double($0.offset % 20))] }
            }
            return (
                200,
                success([
                    "resultType": "matrix",
                    "result": [
                        ["metric": ["__name__": "http_requests_total", "code": "200", "job": "api"], "values": values(2)],
                        ["metric": ["__name__": "http_requests_total", "code": "500", "job": "api"], "values": values(0.5)],
                    ],
                ])
            )
        case "/api/v1/query":
            return (
                200,
                success([
                    "resultType": "matrix",
                    "result": [["metric": ["__name__": "up", "job": "api"], "values": [[now - 30, "1"], [now - 15, "1"]]]],
                ])
            )
        case "/api/v1/targets":
            return (
                200,
                success([
                    "activeTargets": [
                        [
                            "labels": ["job": "api"], "scrapeUrl": "http://api:8080/metrics", "health": "up", "lastScrapeDuration": 0.012,
                            "lastError": "",
                        ],
                        [
                            "labels": ["job": "worker"], "scrapeUrl": "http://worker:9100/metrics", "health": "down",
                            "lastScrapeDuration": 0.0, "lastError": "connection refused",
                        ],
                    ]
                ])
            )
        case "/api/v1/alerts":
            return (
                200,
                success([
                    "alerts": [
                        [
                            "labels": ["alertname": "HighErrorRate", "severity": "page", "job": "api"], "state": "firing",
                            "activeAt": "2026-11-13T10:00:00Z", "annotations": ["summary": "5xx above 5%"],
                        ]
                    ]
                ])
            )
        case "/api/v1/rules":
            return (
                200,
                success(["groups": [["name": "api", "rules": [["name": "HighErrorRate", "type": "alerting", "health": "ok", "state": "firing", "query": "x > 1"]]]]])
            )

        // Loki
        case "/loki/api/v1/labels": return (200, success(["app", "level", "namespace"]))
        case "/loki/api/v1/label/app/values": return (200, success(["api", "worker"]))
        case "/loki/api/v1/query_range":
            let logql = query["query"] ?? ""
            if !logql.contains("{") { return (400, "parse error at line 1, col 1: syntax error: unexpected IDENTIFIER") }
            let end = Double(query["end"] ?? "").map { $0 / 1e9 } ?? now
            if logql.hasPrefix("rate(") || logql.hasPrefix("count_over_time(") || logql.hasPrefix("sum") {
                return (
                    200,
                    success(["resultType": "matrix", "result": [["metric": ["app": "api"], "values": [[end - 60, "3"], [end, "5"]]]]])
                )
            }
            if query["direction"] == "forward" {
                // The tail: one line, now — newer than anything before it.
                let ns = String(Int64(now * 1e9))
                return (200, success(["resultType": "streams", "result": [["stream": ["app": "api", "level": "info"], "values": [[ns, "tailed line"]]]]]))
            }
            func ns(_ secondsAgo: Double) -> String { String(Int64((end - secondsAgo) * 1e9)) }
            return (
                200,
                success([
                    "resultType": "streams",
                    "result": [
                        [
                            "stream": ["app": "api", "namespace": "shop"],
                            "values": [
                                [ns(5), "level=error msg=\"payment failed\" traceID=\(Self.traceID)"],
                                [ns(30), "level=info msg=\"GET /orders 200\" duration=12ms"],
                            ],
                        ],
                        ["stream": ["app": "worker", "level": "warn"], "values": [[ns(10), "queue is backing up"]]],
                    ],
                ])
            )

        // Tempo
        case "/api/echo": return (200, "echo")
        case "/api/v2/search/tags":
            return (
                200,
                [
                    "scopes": [
                        ["name": "resource", "tags": ["service.name", "k8s.namespace.name"]], ["name": "span", "tags": ["http.route"]],
                        ["name": "intrinsic", "tags": ["duration", "name", "status"]],
                    ]
                ]
            )
        case "/api/v2/search/tag/resource.service.name/values":
            return (200, ["tagValues": [["type": "string", "value": "api"], ["type": "string", "value": "worker"]]])
        case "/api/search":
            return (
                200,
                [
                    "traces": [
                        [
                            "traceID": Self.traceID, "rootServiceName": "api", "rootTraceName": "GET /orders",
                            "startTimeUnixNano": String(Int64((now - 5) * 1e9)), "durationMs": 182,
                        ],
                        [
                            "traceID": "0af7651916cd43dd8448eb211c80319c", "rootServiceName": "worker", "rootTraceName": "process job",
                            "startTimeUnixNano": String(Int64((now - 60) * 1e9)), "durationMs": 40,
                        ],
                    ]
                ]
            )
        default:
            if path.hasPrefix("/api/v2/traces/") { return (404, "404 page not found") }
            if path.hasPrefix("/api/traces/") {
                let id = String(path.dropFirst("/api/traces/".count))
                guard id == Self.traceID else { return (404, "trace not found") }
                return (200, Self.trace(start: now - 5))
            }
            return (404, "404 page not found")
        }
    }

    /// Tempo v1's answer: OTLP JSON, ids base64 as protobuf's JSON has them.
    static func trace(start: Double) -> [String: Any] {
        func b64(_ hex: String) -> String {
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                index = next
            }
            return Data(bytes).base64EncodedString()
        }
        func ns(_ ms: Double) -> String { String(Int64((start + ms / 1000) * 1e9)) }
        func span(_ id: String, _ parent: String?, _ name: String, _ from: Double, _ to: Double, error: Bool = false, attributes: [[String: Any]] = [])
            -> [String: Any]
        {
            var span: [String: Any] = [
                "traceId": b64(traceID), "spanId": b64(id), "name": name, "kind": "SPAN_KIND_SERVER", "startTimeUnixNano": ns(from),
                "endTimeUnixNano": ns(to), "attributes": attributes, "status": error ? ["code": "STATUS_CODE_ERROR"] : [:],
            ]
            if let parent { span["parentSpanId"] = b64(parent) }
            return span
        }
        func resource(_ service: String) -> [String: Any] {
            ["attributes": [["key": "service.name", "value": ["stringValue": service]]]]
        }
        return [
            "batches": [
                [
                    "resource": resource("api"),
                    "scopeSpans": [
                        [
                            "spans": [
                                span(
                                    "00f067aa0ba902b7", nil, "GET /orders", 0, 182,
                                    attributes: [["key": "http.status_code", "value": ["intValue": "500"]]]),
                                span("00f067aa0ba902b8", "00f067aa0ba902b7", "SELECT orders", 10, 60),
                            ]
                        ]
                    ],
                ],
                [
                    "resource": resource("payments"),
                    "instrumentationLibrarySpans": [["spans": [span("00f067aa0ba902b9", "00f067aa0ba902b7", "charge card", 70, 170, error: true)]]],
                ],
            ]
        ]
    }
}
