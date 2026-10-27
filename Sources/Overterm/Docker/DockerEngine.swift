import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// One answer from the engine.
struct DockerResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// The engine's own error message (`{"message": …}`), else the status.
    var errorMessage: String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let message = json["message"] as? String {
            return message
        }
        return String(decoding: body.prefix(400), as: UTF8.self).isEmpty ? "HTTP \(status)" : String(decoding: body.prefix(400), as: UTF8.self)
    }
}

struct DockerError: LocalizedError, Equatable, Sendable {
    var status: Int
    var message: String

    var errorDescription: String? { message }

    static func unreachable(_ detail: String) -> DockerError { DockerError(status: 0, message: detail) }
}

/// How bytes get to the engine and back: NIO over a socket for the app,
/// the same over the fake engine's socket in the tests.
protocol DockerTransport: Sendable {
    func send(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> DockerResponse
    /// A response read as it arrives — events, a followed log, stats —
    /// until the engine ends it or the consumer stops iterating.
    func stream(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error>
}

/// HTTP/1.1 over the engine's unix socket (or `tcp://`), on NIO's shared
/// event loops: a connection a request — a unix socket costs nothing to
/// open, and a stream holds its own until it is done.
struct NIODockerTransport: DockerTransport {
    let address: DockerEndpoint.Address

    private func connect(_ handler: ChannelHandler & Sendable) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(3))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        do {
            switch address {
            case .unix(let path): return try await bootstrap.connect(unixDomainSocketPath: path).get()
            case .tcp(let host, let port): return try await bootstrap.connect(host: host, port: port).get()
            case .unsupported(let host): throw DockerError.unreachable("\(host) isn't an address Overterm reaches yet.")
            }
        } catch let error as DockerError {
            throw error
        } catch {
            throw DockerError.unreachable("Docker isn't answering (\(error.localizedDescription)).")
        }
    }

    private func write(_ channel: Channel, _ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) {
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: path)
        head.headers.add(name: "Host", value: "docker")
        head.headers.add(name: "Connection", value: "close")
        head.headers.add(name: "User-Agent", value: "Overterm")
        for (name, value) in headers { head.headers.add(name: name, value: value) }
        // Always said, 0 for none: left out, NIO sends a POST chunked, and the
        // engine (Go) takes a body of unknown length as one — "starting
        // container with non-empty request body" refused every start.
        if method != .GET && method != .HEAD || body != nil { head.headers.add(name: "Content-Length", value: "\(body?.count ?? 0)") }
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body { channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    }

    func send(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> DockerResponse {
        let collector = ResponseCollector()
        let channel = try await connect(collector)
        write(channel, method, path, body: body, headers: headers)
        return try await withTaskCancellationHandler {
            try await collector.response.futureResult(on: channel.eventLoop).get()
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    func stream(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let streamer = ResponseStreamer(continuation)
            let state = StreamChannel()
            // The consumer may stop before the connection is up: the
            // channel is closed whenever it arrives after that.
            continuation.onTermination = { _ in state.cancel() }
            Task {
                do {
                    let channel = try await connect(streamer)
                    guard state.attach(channel) else { return }
                    write(channel, method, path, body: body, headers: headers)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// A stream's channel and whether its consumer has gone, under one lock.
private final class StreamChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false

    /// False (and the channel closed) when the consumer already left.
    func attach(_ channel: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            channel.close(promise: nil)
            return false
        }
        self.channel = channel
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let channel = self.channel
        lock.unlock()
        channel?.close(promise: nil)
    }
}

/// Reads one whole response.
private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    /// Made on the channel's loop when the first read arrives; answered at
    /// the end (or the close).
    final class Pending: @unchecked Sendable {
        private var promise: EventLoopPromise<DockerResponse>?
        private var result: Result<DockerResponse, Error>?
        private let lock = NSLock()

        func futureResult(on loop: EventLoop) -> EventLoopFuture<DockerResponse> {
            lock.lock()
            defer { lock.unlock() }
            let promise = loop.makePromise(of: DockerResponse.self)
            if let result { promise.completeWith(result) } else { self.promise = promise }
            return promise.futureResult
        }

        func complete(_ result: Result<DockerResponse, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard self.result == nil else { return }
            self.result = result
            promise?.completeWith(result)
        }
    }

    let response = Pending()
    private var status = 0
    private var headers: [(String, String)] = []
    private var body = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            headers = head.headers.map { ($0.name, $0.value) }
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            response.complete(.success(DockerResponse(status: status, headers: headers, body: body)))
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        response.complete(.failure(DockerError.unreachable("Docker closed the connection.")))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        response.complete(.failure(DockerError.unreachable(error.localizedDescription)))
        context.close(promise: nil)
    }
}

/// Hands a response's body on as it arrives; an error status ends the
/// stream with the engine's message.
private final class ResponseStreamer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var status = 0
    private var errorBody = Data()

    init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
        case .body(var buffer):
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            if status >= 400 { errorBody.append(contentsOf: bytes) } else { continuation.yield(Data(bytes)) }
        case .end:
            if status >= 400 {
                continuation.finish(throwing: DockerError(status: status, message: DockerResponse(status: status, headers: [], body: errorBody).errorMessage))
            } else {
                continuation.finish()
            }
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: DockerError.unreachable(error.localizedDescription))
        context.close(promise: nil)
    }
}

/// The engine: its address, the API version both sides speak, and the
/// calls — JSON in, JSON out, streams for what goes on.
final class DockerEngine: Sendable {
    let endpoint: DockerEndpoint
    let transport: DockerTransport
    /// What Overterm is written against; the engine's own, if older, wins
    /// (`/_ping` says it).
    static let clientVersion = "1.47"
    private let negotiated = NegotiatedVersion()

    init(endpoint: DockerEndpoint, transport: DockerTransport? = nil) {
        self.endpoint = endpoint
        self.transport = transport ?? NIODockerTransport(address: endpoint.address)
    }

    /// Answers when the engine does; its API version, then used for every
    /// call.
    @discardableResult
    func ping() async throws -> String {
        let response = try await transport.send(.GET, "/_ping", body: nil, headers: [])
        guard response.status == 200 else { throw DockerError(status: response.status, message: response.errorMessage) }
        let server = response.header("API-Version") ?? Self.clientVersion
        let version = Self.older(server, Self.clientVersion)
        negotiated.set(version)
        return version
    }

    /// `1.44` vs `1.47`: the lower.
    static func older(_ a: String, _ b: String) -> String {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        return pa.lexicographicallyPrecedes(pb) ? a : b
    }

    func path(_ path: String, _ query: [String: String] = [:]) -> String {
        var components = URLComponents()
        components.path = "/v\(negotiated.value ?? Self.clientVersion)" + path
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        // `+` stays a plus in a query, which the engine reads as a space.
        return (components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?" + $0.replacingOccurrences(of: "+", with: "%2B") } ?? "")
    }

    /// A call whose answer is JSON; an error status throws the engine's
    /// message.
    func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String] = [:]) async throws -> T {
        let response = try await send(.GET, path, query)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw DockerError(status: response.status, message: "Docker's answer to \(path) didn't read: \(error.localizedDescription)")
        }
    }

    /// The raw answer, after its status was checked.
    @discardableResult
    func send(
        _ method: HTTPMethod, _ path: String, _ query: [String: String] = [:], body: Data? = nil, headers: [(String, String)] = []
    ) async throws -> DockerResponse {
        let response = try await transport.send(method, self.path(path, query), body: body, headers: headers)
        guard (200..<300).contains(response.status) || response.status == 304 else {
            throw DockerError(status: response.status, message: response.errorMessage)
        }
        return response
    }

    func stream(_ path: String, _ query: [String: String] = [:]) -> AsyncThrowingStream<Data, Error> {
        transport.stream(.GET, self.path(path, query), body: nil, headers: [])
    }
}

/// The version `ping` settled on, read from any thread.
private final class NegotiatedVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var version: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    func set(_ version: String) {
        lock.lock()
        self.version = version
        lock.unlock()
    }
}
