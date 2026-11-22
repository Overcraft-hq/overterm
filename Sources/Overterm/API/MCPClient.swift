import Foundation

/// An MCP client, as the spec has one: JSON-RPC 2.0 over a server's
/// transport — a process's stdin and stdout, Streamable HTTP, or the 2024
/// SSE transport — `initialize` first, then what the inspector asks:
/// tools, resources, prompts, a tool called.
///
/// Every message either way is handed to `onTraffic` as it goes, and a
/// process's stderr too: the inspector's log.
package actor MCPClient {
    package struct Failure: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    package enum Direction: String, Sendable { case sent, received, stderr, note }

    /// The protocol version asked for; the server answers with the one it speaks.
    package static let protocolVersion = "2025-06-18"

    package let config: MCPServerConfig
    private let environment: [String: String]
    private let onTraffic: @Sendable (Direction, String) -> Void
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    package private(set) var serverInfo: JSONValue = .null
    package private(set) var capabilities: JSONValue = .null
    package private(set) var negotiatedVersion = ""
    package private(set) var instructions: String?

    // stdio
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    // HTTP
    private let session: URLSession
    private var sessionID: String?
    /// The 2024 transport's endpoint, from its stream's first event.
    private var endpoint: URL?
    private var stream: Task<Void, Never>?

    package init(_ config: MCPServerConfig, environment: [String: String], onTraffic: @escaping @Sendable (Direction, String) -> Void) {
        self.config = config
        self.environment = environment
        self.onTraffic = onTraffic
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration)
    }

    // MARK: Connecting

    package func connect() async throws {
        switch config.transport {
        case .stdio(let command, let args, let env): try start(command, args, env)
        case .sse(let url, let headers): try await openStream(url, headers)
        case .http: break
        }
        let result = try await request(
            "initialize",
            [
                "protocolVersion": .string(Self.protocolVersion), "capabilities": [:],
                "clientInfo": ["name": "Overterm", "version": .string(Self.appVersion)],
            ])
        serverInfo = result["serverInfo"]
        capabilities = result["capabilities"]
        negotiatedVersion = result["protocolVersion"].string ?? ""
        instructions = result["instructions"].string
        try await notify("notifications/initialized")
    }

    package nonisolated static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    package func close() {
        stream?.cancel()
        stream = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? stdin?.close()
        stdin = nil
        fail(Failure(message: "Disconnected."))
        if case .http(let url, let headers) = config.transport, let sessionID, let target = URL(string: url) {
            // The spec's way to end a session: DELETE with its id.
            var request = URLRequest(url: target)
            request.httpMethod = "DELETE"
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            let session = session
            Task { _ = try? await session.data(for: request) }
        }
        sessionID = nil
    }

    /// How long a request waits for its reply.
    package static let timeout: TimeInterval = 60

    private func expire(_ id: Int, _ method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: Failure(message: "No answer to \(method) in \(Int(Self.timeout)) s."))
    }

    private func fail(_ error: Error) {
        let waiting = pending
        pending = [:]
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    // MARK: Messages

    /// A request, and its result — or the server's error.
    package func request(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if let params { message["params"] = params }
        let data = try JSONValue.object(message).encoded()
        onTraffic(.sent, String(decoding: data, as: UTF8.self))
        let reply: JSONValue = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await self.deliver(data, id: id) }
            // A server that never answers ends the wait, not the inspector.
            Task {
                try? await Task.sleep(for: .seconds(Self.timeout))
                await self.expire(id, method)
            }
        }
        if let error = reply["error"].object {
            let code = error["code"]?.int.map { " (\($0))" } ?? ""
            throw Failure(message: (error["message"]?.string ?? "The server refused it.") + code)
        }
        return reply["result"]
    }

    package func notify(_ method: String, _ params: JSONValue? = nil) async throws {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        let data = try JSONValue.object(message).encoded()
        onTraffic(.sent, String(decoding: data, as: UTF8.self))
        try await send(data, id: nil)
    }

    private func deliver(_ data: Data, id: Int) async {
        do {
            try await send(data, id: id)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    /// Writes a message; its reply comes through `received`.
    private func send(_ data: Data, id: Int?) async throws {
        switch config.transport {
        case .stdio:
            guard let stdin else { throw Failure(message: "The server isn't running.") }
            try stdin.write(contentsOf: data + Data("\n".utf8))
        case .http(let url, let headers):
            try await post(data, to: URL(string: url), headers: headers, id: id)
        case .sse(_, let headers):
            guard let endpoint else { throw Failure(message: "The server's stream named no endpoint.") }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 { throw Failure(message: "The server answered \(status).") }
        }
    }

    /// One message from the server: a reply to a request of ours, else a
    /// notification or a request of its own (logged; pings answered).
    private func received(_ data: Data) {
        onTraffic(.received, String(decoding: data, as: UTF8.self))
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if case .array(let batch) = message {
            for item in batch { if let encoded = try? item.encoded() { received(encoded) } }
            return
        }
        if let id = message["id"].int, message["method"] == .null {
            pending.removeValue(forKey: id)?.resume(returning: message)
            return
        }
        // The server asks something of us: a ping is answered, the rest refused.
        if message["method"].string != nil, message["id"] != .null {
            let isPing = message["method"].string == "ping"
            var reply: [String: JSONValue] = ["jsonrpc": "2.0", "id": message["id"]]
            if isPing {
                reply["result"] = [:]
            } else {
                reply["error"] = ["code": -32601, "message": "Overterm's inspector doesn't answer this."]
            }
            if let data = try? JSONValue.object(reply).encoded() {
                onTraffic(.sent, String(decoding: data, as: UTF8.self))
                Task { try? await self.send(data, id: nil) }
            }
        }
    }

    // MARK: stdio

    /// Every server process started, so quitting ends them — a child isn't
    /// ended with its parent, and an `npx` server left behind keeps its port.
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]
    private static let lock = NSLock()

    package static func terminateAll() {
        let all = lock.withLock { Array(running.values) }
        for process in all where process.isRunning { process.terminate() }
    }

    private func start(_ command: String, _ args: [String], _ env: [String: String]) throws {
        let process = Process()
        // The user's PATH: npx, uvx and docker are rarely on launchd's.
        var environment = self.environment
        for (key, value) in env { environment[key] = value }
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        process.environment = environment
        if let directory = config.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            Task { await self.read(chunk) }
        }
        let traffic = onTraffic
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            traffic(.stderr, String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        process.terminationHandler = { [weak self] finished in
            _ = MCPClient.lock.withLock { MCPClient.running.removeValue(forKey: ObjectIdentifier(finished)) }
            let status = finished.terminationStatus
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            Task { await self?.ended(status) }
        }
        do {
            try process.run()
        } catch {
            throw Failure(message: "Couldn't start \(command): \(error.localizedDescription)")
        }
        self.process = process
        Self.lock.withLock { Self.running[ObjectIdentifier(process)] = process }
        stdin = input.fileHandleForWriting
    }

    private func read(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D }
            if trimmed.first == UInt8(ascii: "{") || trimmed.first == UInt8(ascii: "[") {
                received(Data(trimmed))
            } else if !trimmed.isEmpty {
                // Not JSON: a server logging to stdout — shown, not read.
                onTraffic(.stderr, String(decoding: trimmed, as: UTF8.self))
            }
        }
    }

    private func ended(_ status: Int32) {
        process = nil
        onTraffic(.note, "The server exited (\(status)).")
        fail(Failure(message: "The server exited (\(status)) — its log says why."))
    }

    // MARK: Streamable HTTP

    private func post(_ data: Data, to url: URL?, headers: [String: String], id: Int?) async throws {
        guard let url else { throw Failure(message: "The server's URL isn't valid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !negotiatedVersion.isEmpty { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP answer.") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        if http.statusCode == 202 || id == nil { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw Failure(message: "The server refused the credentials (\(http.statusCode)) — its headers (Authorization) say who you are.")
        }
        if http.statusCode >= 400 {
            var text = ""
            for try await line in bytes.lines {
                text += line + "\n"
                if text.count > 500 { break }
            }
            throw Failure(message: "The server answered \(http.statusCode): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            // Events until the reply to this request.
            var event = ""
            for try await line in SSELines(bytes) {
                if line.hasPrefix("data:") {
                    event += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                } else if line.isEmpty, !event.isEmpty {
                    received(Data(event.utf8))
                    event = ""
                    if let id, pending[id] == nil { return }
                }
            }
            if !event.isEmpty { received(Data(event.utf8)) }
        } else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            received(body)
        }
    }

    // MARK: The 2024 SSE transport

    private func openStream(_ address: String, _ headers: [String: String]) async throws {
        guard let url = URL(string: address) else { throw Failure(message: "The server's URL isn't valid.") }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else { throw Failure(message: "The server's stream answered \(status).") }
        let ready = AsyncStream<URL?>.makeStream()
        stream = Task { [weak self] in
            var name = ""
            var data = ""
            do {
                for try await line in SSELines(bytes) {
                    if line.hasPrefix("event:") {
                        name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    } else if line.isEmpty {
                        if name == "endpoint" {
                            ready.continuation.yield(URL(string: data, relativeTo: url)?.absoluteURL)
                        } else if !data.isEmpty {
                            await self?.received(Data(data.utf8))
                        }
                        name = ""
                        data = ""
                    }
                }
            } catch {}
            ready.continuation.yield(nil)
            await self?.fail(Failure(message: "The server closed its stream."))
        }
        for await found in ready.stream {
            guard let found else { throw Failure(message: "The server's stream ended before naming its endpoint.") }
            endpoint = found
            return
        }
    }

    // MARK: What the inspector asks

    /// Every page of a list: tools, resources, resource templates, prompts.
    package func list(_ method: String, key: String) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        repeat {
            let result = try await request(method, cursor.map { ["cursor": .string($0)] } ?? nil)
            items += result[key].array ?? []
            cursor = result["nextCursor"].string
        } while cursor != nil && items.count < 10_000
        return items
    }

    package func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await request("tools/call", ["name": .string(name), "arguments": arguments])
    }

    package func readResource(_ uri: String) async throws -> JSONValue {
        try await request("resources/read", ["uri": .string(uri)])
    }

    package func getPrompt(_ name: String, arguments: [String: String]) async throws -> JSONValue {
        try await request("prompts/get", ["name": .string(name), "arguments": .object(arguments.mapValues(JSONValue.string))])
    }

    package func ping() async throws {
        _ = try await request("ping")
    }
}

extension JSONValue {
    package subscript(_ key: String) -> JSONValue {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }

    package var string: String? { if case .string(let value) = self { value } else { nil } }
    package var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }
    package var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    package var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    package var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    /// Indented, keys sorted: as the inspector shows a value.
    package var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// An event stream's lines, the empty ones too: they end an event, and
/// `AsyncBytes.lines` drops them — two events read as one, a reply never
/// matched, and the call waited for ever.
package struct SSELines: AsyncSequence {
    package typealias Element = String
    package let bytes: URLSession.AsyncBytes

    package init(_ bytes: URLSession.AsyncBytes) { self.bytes = bytes }

    package struct AsyncIterator: AsyncIteratorProtocol {
        package var bytes: URLSession.AsyncBytes.AsyncIterator
        package var done = false

        package mutating func next() async throws -> String? {
            guard !done else { return nil }
            var line = Data()
            while let byte = try await bytes.next() {
                if byte == 0x0A {
                    if line.last == 0x0D { line.removeLast() }
                    return String(decoding: line, as: UTF8.self)
                }
                line.append(byte)
            }
            done = true
            return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
        }
    }

    package func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: bytes.makeAsyncIterator()) }
}
