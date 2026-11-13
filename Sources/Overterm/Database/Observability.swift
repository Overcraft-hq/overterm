import Foundation

/// Prometheus, Loki and Tempo as the database client reads them — pure, so
/// it is tested without a server: a query's time window, what came back
/// (series, log lines, traces, a trace's spans) parsed from each API's
/// JSON, and a console's text as queries.

/// The window a query looks at: the last so long, up to now.
enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case m5 = "5m", m15 = "15m", m30 = "30m", h1 = "1h", h3 = "3h", h6 = "6h", h12 = "12h", d1 = "24h", d2 = "2d", d7 = "7d"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m5: 300
        case .m15: 900
        case .m30: 1800
        case .h1: 3600
        case .h3: 10800
        case .h6: 21600
        case .h12: 43200
        case .d1: 86400
        case .d2: 172_800
        case .d7: 604_800
        }
    }

    var title: String {
        switch self {
        case .m5: "Last 5 minutes"
        case .m15: "Last 15 minutes"
        case .m30: "Last 30 minutes"
        case .h1: "Last hour"
        case .h3: "Last 3 hours"
        case .h6: "Last 6 hours"
        case .h12: "Last 12 hours"
        case .d1: "Last 24 hours"
        case .d2: "Last 2 days"
        case .d7: "Last 7 days"
        }
    }

    func window(now: Date = Date()) -> (start: Date, end: Date) { (now.addingTimeInterval(-seconds), now) }

    /// A graph's resolution: about 300 points, never under a second.
    var step: Int { max(1, Int(seconds / 300)) }
}

// MARK: What came back

struct MetricSeries: Equatable, Sendable, Identifiable {
    struct Point: Equatable, Sendable {
        var time: Date
        var value: Double
    }

    var labels: [String: String]
    var points: [Point]

    var id: String { Self.signature(labels) }
    var name: String? { labels["__name__"] }

    /// `name{a="b", c="d"}`, as Prometheus prints a series.
    static func signature(_ labels: [String: String]) -> String {
        let rest = labels.filter { $0.key != "__name__" }.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }
        let name = labels["__name__"] ?? ""
        return rest.isEmpty ? (name.isEmpty ? "{}" : name) : name + "{" + rest.joined(separator: ", ") + "}"
    }
}

enum LogLevel: String, Sendable, CaseIterable {
    case critical, error, warn, info, debug, trace

    /// The level a line says it is: its `level` label, else `level=error`,
    /// `"level":"error"`, or a bare ERROR / WARN… near its start.
    static func of(_ line: String, labels: [String: String]) -> LogLevel? {
        for key in ["level", "detected_level", "severity", "lvl"] {
            if let value = labels[key], let level = named(value) { return level }
        }
        let head = String(line.prefix(300))
        let patterns = [#"(?i)\b(?:level|lvl|severity)\s*[=:]\s*"?([a-z]+)"#, #"(?i)"(?:level|severity)"\s*:\s*"([a-z]+)""#]
        for pattern in patterns {
            if let match = head.range(of: pattern, options: .regularExpression) {
                let found = String(head[match])
                if let word = found.split(whereSeparator: { !$0.isLetter }).last, let level = named(String(word)) { return level }
            }
        }
        for word in head.prefix(120).split(whereSeparator: { !$0.isLetter }).prefix(8) where word.count >= 4 && word == word.uppercased() {
            if let level = named(String(word)) { return level }
        }
        return nil
    }

    static func named(_ text: String) -> LogLevel? {
        switch text.lowercased() {
        case "critical", "crit", "fatal", "panic", "emerg", "alert": .critical
        case "error", "err", "eror": .error
        case "warn", "warning": .warn
        case "info", "information", "notice": .info
        case "debug", "dbug": .debug
        case "trace": .trace
        default: nil
        }
    }
}

struct LogLine: Equatable, Sendable, Identifiable {
    /// Nanoseconds since 1970, as Loki says it — ordering and the tail's
    /// next start need all of them.
    var nanos: Int64
    var labels: [String: String]
    var line: String
    /// Where it was among lines of the same instant.
    var index = 0

    var id: String { "\(nanos)-\(index)-\(line.hashValue)" }
    var time: Date { Date(timeIntervalSince1970: Double(nanos) / 1e9) }
    var level: LogLevel? { LogLevel.of(line, labels: labels) }

    /// A trace id the line or its labels carry (`traceID=…`, `"trace_id":"…"`).
    var traceID: String? {
        for key in ["traceID", "trace_id", "traceId", "TraceId"] {
            if let value = labels[key], Self.isTraceID(value) { return value }
        }
        let pattern = #"(?i)trace[_-]?id"?\s*[=:]\s*"?([0-9a-f]{16,32})\b"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let found = line[match]
        guard let id = found.split(whereSeparator: { !$0.isHexDigit }).last.map(String.init), Self.isTraceID(id) else { return nil }
        return id
    }

    /// 16 to 32 hex digits: Tempo's search gives ids without their leading
    /// zeros (`198686e9…`, 31 of them).
    static func isTraceID(_ text: String) -> Bool {
        (16...32).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }
}

struct TraceSummary: Equatable, Sendable, Identifiable {
    var id: String
    var service: String
    var name: String
    var start: Date
    var durationMs: Double
}

struct TraceSpan: Equatable, Sendable, Identifiable {
    var id: String
    var parent: String?
    var service: String
    var name: String
    var kind: String
    var startNanos: Int64
    var endNanos: Int64
    var failed: Bool
    var attributes: [Attribute]

    struct Attribute: Equatable, Sendable {
        var key: String
        var value: String
    }

    var durationMs: Double { Double(endNanos - startNanos) / 1e6 }
}

/// A trace's spans, in the order a waterfall draws them: each under its
/// parent, siblings by start.
struct TraceDetail: Equatable, Sendable {
    var id: String
    var spans: [TraceSpan]

    struct Row: Equatable, Sendable, Identifiable {
        var span: TraceSpan
        var depth: Int
        var id: String { span.id }
    }

    var start: Int64 { spans.map(\.startNanos).min() ?? 0 }
    var end: Int64 { spans.map(\.endNanos).max() ?? 0 }
    var durationMs: Double { Double(end - start) / 1e6 }
    var services: [String] {
        var seen: [String] = []
        for span in rows.map(\.span) where !seen.contains(span.service) { seen.append(span.service) }
        return seen
    }

    var rows: [Row] {
        let ids = Set(spans.map(\.id))
        var children: [String: [TraceSpan]] = [:]
        var roots: [TraceSpan] = []
        for span in spans {
            // A parent this trace doesn't have (not sent yet, or elsewhere): a root.
            if let parent = span.parent, ids.contains(parent), parent != span.id {
                children[parent, default: []].append(span)
            } else {
                roots.append(span)
            }
        }
        var out: [Row] = []
        var visited: Set<String> = []
        func walk(_ span: TraceSpan, _ depth: Int) {
            guard visited.insert(span.id).inserted else { return }
            out.append(Row(span: span, depth: depth))
            for child in (children[span.id] ?? []).sorted(by: { $0.startNanos < $1.startNanos }) { walk(child, depth + 1) }
        }
        for root in roots.sorted(by: { $0.startNanos < $1.startNanos }) { walk(root, 0) }
        return out
    }
}

/// What an observability query gave back, beyond the grid's rows.
enum ObservabilityPayload: Equatable, Sendable {
    case series([MetricSeries])
    case logs([LogLine])
    case traces([TraceSummary])
    case trace(TraceDetail)
}

// MARK: Reading the APIs' answers

enum ObservabilityParse {
    struct Failure: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: text.isEmpty ? "The server answered nothing." : text)
        }
        if object["status"] as? String == "error" {
            throw Failure(message: (object["error"] as? String) ?? "The query failed.")
        }
        return object
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func nanos(_ any: Any?) -> Int64? {
        if let s = any as? String { return Int64(s) }
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let n = any as? Double { return Int64(n) }
        return nil
    }

    /// Prometheus's (and Loki's metric queries') `data`: a matrix, a
    /// vector, a scalar or a string — all as series.
    static func prometheus(_ data: Data) throws -> [MetricSeries] {
        let object = try json(data)
        guard let body = object["data"] as? [String: Any] else { throw Failure(message: "No data in the answer.") }
        return series(body)
    }

    static func series(_ body: [String: Any]) -> [MetricSeries] {
        let type = body["resultType"] as? String ?? ""
        func point(_ pair: Any) -> MetricSeries.Point? {
            guard let pair = pair as? [Any], pair.count == 2, let time = number(pair[0]), let value = number(pair[1]) else { return nil }
            return MetricSeries.Point(time: Date(timeIntervalSince1970: time), value: value)
        }
        switch type {
        case "matrix", "vector":
            let result = body["result"] as? [[String: Any]] ?? []
            return result.map { item in
                let labels = item["metric"] as? [String: String] ?? [:]
                let points = type == "matrix" ? (item["values"] as? [Any] ?? []).compactMap(point) : [item["value"]].compactMap { $0.flatMap(point) }
                return MetricSeries(labels: labels, points: points)
            }
        case "scalar", "string":
            return [body["result"]].compactMap { $0.flatMap(point) }.map { MetricSeries(labels: [:], points: [$0]) }
        default:
            return []
        }
    }

    /// Loki's query_range: streams of lines (newest first) — or, for a
    /// metric query, series.
    static func loki(_ data: Data) throws -> ObservabilityPayload {
        let object = try json(data)
        guard let body = object["data"] as? [String: Any] else { throw Failure(message: "No data in the answer.") }
        guard body["resultType"] as? String == "streams" else { return .series(series(body)) }
        var lines: [LogLine] = []
        for stream in body["result"] as? [[String: Any]] ?? [] {
            let labels = stream["stream"] as? [String: String] ?? [:]
            for value in stream["values"] as? [[Any]] ?? [] {
                guard value.count >= 2, let ns = nanos(value[0]), let line = value[1] as? String else { continue }
                // A third element: structured metadata (traceID among them).
                var all = labels
                if value.count > 2, let meta = value[2] as? [String: Any] {
                    for (key, any) in (meta["structuredMetadata"] as? [String: String]) ?? (meta as? [String: String]) ?? [:] where all[key] == nil {
                        all[key] = any
                    }
                }
                lines.append(LogLine(nanos: ns, labels: all, line: line))
            }
        }
        return .logs(ordered(lines))
    }

    /// Newest first; lines of one instant keep their order.
    static func ordered(_ lines: [LogLine]) -> [LogLine] {
        var seen: [Int64: Int] = [:]
        var numbered = lines
        for index in numbered.indices {
            numbered[index].index = seen[numbered[index].nanos, default: 0]
            seen[numbered[index].nanos, default: 0] += 1
        }
        return numbered.sorted { ($0.nanos, -$0.index) > ($1.nanos, -$1.index) }
    }

    /// `{"status":"success","data":["a","b"]}` — labels, values, metric names.
    static func names(_ data: Data) throws -> [String] {
        let object = try json(data)
        return (object["data"] as? [String] ?? []).sorted()
    }

    /// Tempo's /api/search.
    static func tempoSearch(_ data: Data) throws -> [TraceSummary] {
        let object = try json(data)
        return (object["traces"] as? [[String: Any]] ?? []).compactMap { trace in
            guard let id = trace["traceID"] as? String else { return nil }
            let start = nanos(trace["startTimeUnixNano"]).map { Date(timeIntervalSince1970: Double($0) / 1e9) } ?? .distantPast
            return TraceSummary(
                id: id, service: trace["rootServiceName"] as? String ?? "<root span not yet received>",
                name: trace["rootTraceName"] as? String ?? "", start: start, durationMs: number(trace["durationMs"]) ?? 0)
        }
    }

    /// Tempo's tags: v2's scopes (`resource.service.name`, `span.http.route`,
    /// and the intrinsics bare), or v1's names.
    static func tempoTags(_ data: Data) throws -> [String] {
        let object = try json(data)
        if let scopes = object["scopes"] as? [[String: Any]] {
            var out: [String] = []
            for scope in scopes {
                let name = scope["name"] as? String ?? ""
                for tag in scope["tags"] as? [String] ?? [] { out.append(name == "intrinsic" || name.isEmpty ? tag : "\(name).\(tag)") }
            }
            // The server's order changes between asks: resource's first (the
            // services), then span's, then the rest, each alphabetical.
            func rank(_ tag: String) -> Int { tag.hasPrefix("resource.") ? 0 : tag.hasPrefix("span.") ? 1 : 2 }
            return out.sorted { (rank($0), $0) < (rank($1), $1) }
        }
        return (object["tagNames"] as? [String] ?? []).sorted()
    }

    /// Tempo's tag values: v2's `[{type, value}]` or v1's strings.
    static func tempoValues(_ data: Data) throws -> [String] {
        let object = try json(data)
        let values = object["tagValues"] as? [Any] ?? []
        return values.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["value"] as? String) }.sorted()
    }

    /// A trace as Tempo gives it in JSON: OTLP's `batches` (v1) or
    /// `resourceSpans` (v2, under `trace`), the old `instrumentationLibrarySpans`
    /// as well as `scopeSpans`; ids base64 (protobuf's JSON) or hex.
    static func tempoTrace(_ data: Data, id: String) throws -> TraceDetail {
        var object = try json(data)
        if let inner = object["trace"] as? [String: Any] { object = inner }
        let batches = (object["batches"] as? [[String: Any]]) ?? (object["resourceSpans"] as? [[String: Any]]) ?? []
        guard !batches.isEmpty else { throw Failure(message: "No trace \(id) — not found, or not yet complete.") }
        var spans: [TraceSpan] = []
        for batch in batches {
            let resource = attributes((batch["resource"] as? [String: Any])?["attributes"])
            let service = resource.first { $0.key == "service.name" }?.value ?? "unknown"
            let scopes = (batch["scopeSpans"] as? [[String: Any]]) ?? (batch["instrumentationLibrarySpans"] as? [[String: Any]]) ?? []
            for scope in scopes {
                for span in scope["spans"] as? [[String: Any]] ?? [] {
                    let status = span["status"] as? [String: Any]
                    let code = status?["code"]
                    let failed = (code as? String).map { $0.contains("ERROR") } ?? ((code as? Int) == 2)
                    let parent = (span["parentSpanId"] as? String).flatMap { $0.isEmpty ? nil : hexID($0) }
                    spans.append(
                        TraceSpan(
                            id: hexID(span["spanId"] as? String ?? UUID().uuidString), parent: parent, service: service,
                            name: span["name"] as? String ?? "", kind: (span["kind"] as? String).map(kindName) ?? "",
                            startNanos: nanos(span["startTimeUnixNano"]) ?? 0, endNanos: nanos(span["endTimeUnixNano"]) ?? 0, failed: failed,
                            attributes: attributes(span["attributes"]) + resource.map { .init(key: "resource.\($0.key)", value: $0.value) }))
                }
            }
        }
        return TraceDetail(id: id, spans: spans)
    }

    private static func kindName(_ kind: String) -> String {
        kind.replacingOccurrences(of: "SPAN_KIND_", with: "").lowercased()
    }

    /// An id as hex: kept when it is, else base64 decoded.
    static func hexID(_ text: String) -> String {
        if (text.count == 16 || text.count == 32), text.allSatisfy(\.isHexDigit) { return text.lowercased() }
        guard let data = Data(base64Encoded: text) else { return text }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func attributes(_ any: Any?) -> [TraceSpan.Attribute] {
        (any as? [[String: Any]] ?? []).compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            return TraceSpan.Attribute(key: key, value: attributeValue(item["value"]))
        }
    }

    private static func attributeValue(_ any: Any?) -> String {
        guard let value = any as? [String: Any] else { return "" }
        if let s = value["stringValue"] as? String { return s }
        if let n = value["intValue"] { return "\(n)" }
        if let n = value["doubleValue"] { return "\(n)" }
        if let b = value["boolValue"] as? Bool { return b ? "true" : "false" }
        if let array = (value["arrayValue"] as? [String: Any])?["values"] as? [Any] {
            return "[" + array.map { attributeValue($0) }.joined(separator: ", ") + "]"
        }
        return ""
    }

    /// Prometheus's /api/v1/targets: each active target, its health.
    static func targets(_ data: Data) throws -> QueryResult {
        let object = try json(data)
        let active = ((object["data"] as? [String: Any])?["activeTargets"] as? [[String: Any]]) ?? []
        let rows: [[String?]] = active.map { target in
            let labels = target["labels"] as? [String: String] ?? [:]
            return [
                labels["job"], target["scrapeUrl"] as? String, target["health"] as? String,
                (target["lastScrapeDuration"] as? Double).map { String(format: "%.0f ms", $0 * 1000) }, target["lastError"] as? String,
            ]
        }
        .sorted { ($0[2] ?? "", $0[0] ?? "") < ($1[2] ?? "", $1[0] ?? "") }
        return QueryResult(columns: ["job", "endpoint", "health", "scrape", "error"], types: ["", "", "", "", ""], rows: rows)
    }

    /// Prometheus's /api/v1/alerts: what fires and what is pending.
    static func alerts(_ data: Data) throws -> QueryResult {
        let object = try json(data)
        let alerts = ((object["data"] as? [String: Any])?["alerts"] as? [[String: Any]]) ?? []
        let rows: [[String?]] = alerts.map { alert in
            let labels = alert["labels"] as? [String: String] ?? [:]
            let annotations = alert["annotations"] as? [String: String] ?? [:]
            return [
                labels["alertname"], alert["state"] as? String, labels["severity"], alert["activeAt"] as? String,
                annotations["summary"] ?? annotations["description"],
                MetricSeries.signature(labels.filter { $0.key != "alertname" && $0.key != "severity" }),
            ]
        }
        return QueryResult(columns: ["alert", "state", "severity", "since", "summary", "labels"], types: Array(repeating: "", count: 6), rows: rows)
    }
}

// MARK: As the grid shows it

enum ObservabilityRows {
    static func result(_ payload: ObservabilityPayload, limit: Int) -> QueryResult {
        var result: QueryResult
        switch payload {
        case .series(let series):
            // The labels as columns, the last value — what an agent, or a
            // saved CSV, wants of a graph.
            var keys: [String] = []
            for item in series { for key in item.labels.keys.sorted() where key != "__name__" && !keys.contains(key) { keys.append(key) } }
            let named = series.contains { $0.name != nil }
            let columns = (named ? ["metric"] : []) + keys + ["value", "min", "max"]
            let rows: [[String?]] = series.map { item in
                let values = item.points.map(\.value)
                return (named ? [item.name] : []) + keys.map { item.labels[$0] } + [
                    values.last.map(format), values.min().map(format), values.max().map(format),
                ]
            }
            result = QueryResult(columns: columns, types: columns.map { _ in "" }, rows: rows)
        case .logs(let lines):
            result = QueryResult(
                columns: ["time", "labels", "line"], types: ["", "", ""],
                rows: lines.map { [timestamp($0.time), MetricSeries.signature($0.labels), $0.line] })
        case .traces(let traces):
            result = QueryResult(
                columns: ["trace id", "service", "name", "start", "duration"], types: ["", "", "", "", ""],
                rows: traces.map { [$0.id, $0.service, $0.name, timestamp($0.start), milliseconds($0.durationMs)] })
        case .trace(let trace):
            let start = trace.start
            result = QueryResult(
                columns: ["service", "span", "start", "duration", "status"], types: ["", "", "", "", ""],
                rows: trace.rows.map { row in
                    [
                        row.span.service, String(repeating: "  ", count: row.depth) + row.span.name,
                        milliseconds(Double(row.span.startNanos - start) / 1e6), milliseconds(row.span.durationMs), row.span.failed ? "error" : "ok",
                    ]
                })
        }
        if result.rows.count > limit {
            result.rows = Array(result.rows.prefix(limit))
            result.truncated = true
        }
        result.payload = payload
        return result
    }

    static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "+Inf" : "-Inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.6g", value)
    }

    static func milliseconds(_ ms: Double) -> String {
        ms < 1 ? String(format: "%.0f µs", ms * 1000) : ms < 1000 ? String(format: "%.1f ms", ms) : String(format: "%.2f s", ms / 1000)
    }

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String { stamp.string(from: date) }
}

// MARK: A console's text

/// An observability console's text: a query a block — lines up to a blank
/// one, as PromQL and LogQL run over lines — `#` lines comments.
enum ObservabilityText {
    static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        var start: Int?
        var end = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let begun = start { found.append(NSRange(location: begun, length: end - begun)) }
                start = nil
            } else if !line.hasPrefix("#") {
                if start == nil { start = range.location }
                end = NSMaxRange(range)
            }
        }
        if let begun = start { found.append(NSRange(location: begun, length: end - begun)) }
        return found
    }

    static func statement(at caret: Int, in text: String) -> NSRange? {
        statements(in: text).first { caret >= $0.location && caret <= NSMaxRange($0) }
    }

    /// The query on one line, its comments out.
    static func clean(_ query: String) -> String {
        query.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tab's name: the metric, the stream's selector, the trace.
    static func subject(of query: String, kind: DatabaseKind) -> String? {
        let query = clean(query)
        if query.hasPrefix(".") { return String(query.dropFirst()) }
        switch kind {
        case .tempo:
            if LogLine.isTraceID(query) { return "trace " + query.prefix(8) }
            return query == "{}" || query.isEmpty ? "recent traces" : String(query.prefix(40))
        case .loki:
            if let open = query.firstIndex(of: "{"), let close = query[open...].firstIndex(of: "}") { return String(query[open...close]) }
            return String(query.prefix(40))
        default:
            let name = query.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" }
            return name.isEmpty ? String(query.prefix(40)) : String(name)
        }
    }

    // MARK: Completion

    static let promFunctions = [
        "rate", "irate", "increase", "sum", "avg", "min", "max", "count", "topk", "bottomk", "quantile", "histogram_quantile",
        "sum_by", "avg_over_time", "max_over_time", "min_over_time", "sum_over_time", "count_over_time", "quantile_over_time",
        "delta", "idelta", "deriv", "predict_linear", "abs", "ceil", "floor", "round", "clamp", "clamp_min", "clamp_max", "absent",
        "absent_over_time", "changes", "resets", "label_replace", "label_join", "time", "timestamp", "vector", "scalar", "sort", "sort_desc",
        "by", "without", "on", "ignoring", "group_left", "group_right", "offset", "and", "or", "unless",
    ]
    static let logqlWords = [
        "json", "logfmt", "pattern", "regexp", "unpack", "line_format", "label_format", "unwrap", "rate", "count_over_time",
        "bytes_over_time", "bytes_rate", "sum", "avg", "max", "min", "topk", "by", "without", "sum_over_time", "avg_over_time",
        "quantile_over_time", "absent_over_time", "decolorize", "drop", "keep",
    ]
    static let traceqlWords = [
        "resource.service.name", "span.http.method", "span.http.route", "span.http.status_code", "name", "status", "duration", "kind",
        "rootServiceName", "rootName", "traceDuration", "error", "ok", "unset", "server", "client", "select", "count", "avg", "max",
        "min", "sum", "by",
    ]

    struct Answer: Equatable {
        var typed: String
        var candidates: [SQLCompletion.Candidate]
    }

    /// Words of the query's language and the catalog's names (metrics, labels, tags).
    static func complete(_ before: String, kind: DatabaseKind, names: [String]) -> Answer? {
        let typed = String(before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" || $0 == "." }.reversed())
        guard typed.count >= 1 else { return nil }
        let words =
            switch kind {
            case .loki: logqlWords
            case .tempo: traceqlWords
            default: promFunctions
            }
        var out: [SQLCompletion.Candidate] = []
        var seen: Set<String> = []
        for name in names where name.hasPrefix(typed) && name != typed && seen.insert(name).inserted {
            out.append(.init(label: name, insert: name, kind: .table, detail: kind == .prometheus ? "metric" : kind == .loki ? "label" : "tag"))
            if out.count >= 150 { break }
        }
        for word in words where word.hasPrefix(typed) && word != typed && seen.insert(word).inserted {
            out.append(.init(label: word, insert: word, kind: .keyword, detail: ""))
        }
        return out.isEmpty ? nil : Answer(typed: typed, candidates: out)
    }
}
