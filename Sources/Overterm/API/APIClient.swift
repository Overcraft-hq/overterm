import Foundation

/// What came back: status, headers in their order, the body's bytes, and
/// where the time went.
struct APIResponse: Equatable, Sendable {
    var status: Int
    var headers: [Header]
    /// Setting it formats it again (`display`): where it is set — the
    /// client, a post-response script — is off the main thread, so a large
    /// body is never parsed while the view draws.
    var body: Data {
        didSet { (display, rawDisplay, isJSON) = Self.format(body) }
    }
    /// From the request leaving to the last byte, in milliseconds.
    var duration: Double
    var url: URL?
    var timeline: Timeline?
    /// The body as the response pane shows it: JSON indented, else its
    /// text; past `displayLimit`, cut there.
    private(set) var display: String = ""
    /// The body as sent, cut the same way.
    private(set) var rawDisplay: String = ""
    private(set) var isJSON = false

    init(status: Int, headers: [Header], body: Data, duration: Double, url: URL? = nil, timeline: Timeline? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.duration = duration
        self.url = url
        self.timeline = timeline
        (display, rawDisplay, isJSON) = Self.format(body)
    }

    /// What the pane shows of a body at most; Copy takes all of it.
    static let displayLimit = 4_000_000

    static func format(_ body: Data) -> (shown: String, raw: String, isJSON: Bool) {
        let text = String(decoding: body, as: UTF8.self)
        let isJSON = !body.isEmpty && (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) != nil
        func cut(_ text: String) -> String {
            guard text.utf8.count > displayLimit else { return text }
            let head = String(text.utf8.prefix(displayLimit)) ?? String(text.prefix(displayLimit / 4))
            return head + "\n\n… \(formatSize(body.count)) in all — Copy takes the whole body."
        }
        return (cut(isJSON ? indentJSON(text) : text), cut(text), isJSON)
    }

    struct Header: Equatable, Hashable, Sendable {
        var name: String
        var value: String
    }

    /// Milliseconds spent in each phase, where the system measured it (a
    /// reused connection has no DNS, connect or TLS).
    struct Timeline: Equatable, Sendable {
        var dns: Double?
        var connect: Double?
        var tls: Double?
        var firstByte: Double?
        var download: Double?
        var redirects: Int
        var protocolName: String?
        var remoteAddress: String?
    }

    /// The reason phrase, as RFC 9110 words it — not Foundation's, which
    /// calls 200 "no error".
    var statusText: String { Self.reasons[status] ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized }

    static let reasons: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
        204: "No Content", 205: "Reset Content", 206: "Partial Content", 300: "Multiple Choices", 301: "Moved Permanently", 302: "Found",
        303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
        402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout",
        409: "Conflict", 410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large", 414: "URI Too Long",
        415: "Unsupported Media Type", 416: "Range Not Satisfiable", 418: "I'm a teapot", 422: "Unprocessable Content", 423: "Locked",
        425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons", 500: "Internal Server Error", 501: "Not Implemented",
        502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
    ]

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: String { header("Content-Type")?.lowercased() ?? "" }

    var text: String { String(decoding: body, as: UTF8.self) }

    /// The body as JSON, when it is JSON.
    var json: Any? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }

    /// The body as a person reads it: JSON indented — its keys in the order
    /// the server sent them, nothing in it re-encoded — anything else as it
    /// came. Formatted anew: for the whole of a large body (Copy).
    var prettyText: String { isJSON ? Self.indentJSON(text) : text }

    /// Re-indents JSON text by two spaces, touching only the whitespace
    /// between tokens: parsing it into a dictionary loses its key order.
    static func indentJSON(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        var depth = 0
        var inString = false
        var escaped = false
        var pendingNewline = false
        func newline() {
            out.append("\n")
            out.append(String(repeating: "  ", count: depth))
        }
        for char in text {
            if inString {
                out.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            if char.isWhitespace { continue }
            if pendingNewline {
                pendingNewline = false
                if char == "}" || char == "]" {
                    // An empty object or array stays {} or [].
                    depth -= 1
                    out.append(char)
                    continue
                }
                newline()
            }
            switch char {
            case "{", "[":
                out.append(char)
                depth += 1
                pendingNewline = true
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                out.append(char)
            case ",":
                out.append(char)
                newline()
            case ":":
                out.append(": ")
            case "\"":
                inString = true
                out.append(char)
            default:
                out.append(char)
            }
        }
        return out
    }

    /// Size on the wire, as the body counts it.
    var size: Int { body.count }

    static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func formatDuration(_ milliseconds: Double) -> String {
        milliseconds >= 1000 ? String(format: "%.2f s", milliseconds / 1000) : String(format: "%.0f ms", milliseconds)
    }
}

/// Sends plans. One per collection, so its cookies stay together while the
/// app runs (Bruno keeps a cookie jar the same way) and no other
/// collection, nor Safari, sees them.
final class APIClient: Sendable {
    struct Options: Equatable, Sendable {
        var timeout: TimeInterval = 30
        var followRedirects = true
        var verifyTLS = true
    }

    private let session: URLSession
    private let delegate: APISessionDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Overterm/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"]
        let delegate = APISessionDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    var cookies: [HTTPCookie] { session.configuration.httpCookieStorage?.cookies ?? [] }

    func clearCookies() {
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    /// Sends `plan`; cancelling the calling task cancels the request.
    func send(_ plan: APIRequestPlan, options: Options = Options()) async throws -> APIResponse {
        var request = URLRequest(url: plan.url, timeoutInterval: options.timeout)
        request.httpMethod = plan.method
        for header in plan.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        request.httpBody = plan.body
        let started = Date()
        let task = APITaskDelegate(options: options)
        let (data, response) = try await session.data(for: request, delegate: task)
        let duration = Date().timeIntervalSince(started) * 1000
        guard let http = response as? HTTPURLResponse else {
            return APIResponse(status: 0, headers: [], body: data, duration: duration, url: response.url, timeline: task.timeline)
        }
        // allHeaderFields is a dictionary: order and case as the server sent
        // them are gone, so they are listed by name.
        let headers = http.allHeaderFields.compactMap { key, value -> APIResponse.Header? in
            guard let name = key as? String else { return nil }
            return APIResponse.Header(name: name, value: "\(value)")
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return APIResponse(
            status: http.statusCode, headers: headers, body: data, duration: duration, url: http.url, timeline: task.timeline)
    }
}

/// The session's own delegate: nothing to do but exist — every task carries
/// its options in its own delegate (APITaskDelegate).
final class APISessionDelegate: NSObject, URLSessionDelegate, Sendable {}

/// One request's delegate: its redirect and TLS options, and the metrics
/// the system collects for it. Called on the session's queue, never the
/// main actor's — so nothing here is main-actor isolated (CLAUDE.md).
final class APITaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let options: APIClient.Options
    private let lock = NSLock()
    private var collected: APIResponse.Timeline?

    init(options: APIClient.Options) {
        self.options = options
    }

    var timeline: APIResponse.Timeline? { lock.withLock { collected } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(options.followRedirects ? request : nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if !options.verifyTLS, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        func span(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start) * 1000
        }
        let timeline = APIResponse.Timeline(
            dns: span(last.domainLookupStartDate, last.domainLookupEndDate),
            connect: span(last.connectStartDate, last.connectEndDate),
            tls: span(last.secureConnectionStartDate, last.secureConnectionEndDate),
            firstByte: span(last.requestStartDate, last.responseStartDate),
            download: span(last.responseStartDate, last.responseEndDate),
            redirects: metrics.redirectCount, protocolName: last.networkProtocolName,
            remoteAddress: last.remoteAddress.map { address in last.remotePort.map { "\(address):\($0)" } ?? address })
        lock.withLock { collected = timeline }
    }
}
