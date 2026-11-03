import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// One answer from a server over a transport.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// The server's own error message (`{"message": …}`: Docker's error,
    /// Kubernetes's Status), else the body's start, else the status.
    var errorMessage: String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let message = json["message"] as? String {
            return message
        }
        return String(decoding: body.prefix(400), as: UTF8.self).isEmpty ? "HTTP \(status)" : String(decoding: body.prefix(400), as: UTF8.self)
    }
}

/// A server's error status and its message, or (status 0) a server that
/// couldn't be reached.
struct HTTPError: LocalizedError, Equatable, Sendable {
    var status: Int
    var message: String

    var errorDescription: String? { message }

    static func unreachable(_ detail: String) -> HTTPError { HTTPError(status: 0, message: detail) }
}

/// How bytes get to a server and back: NIO over a socket for the app, the
/// same over a fake server's socket in the tests.
protocol HTTPTransport: Sendable {
    func send(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse
    /// A request whose body is written as `body` hands it over, its
    /// `length` said first: a folder's archive is read from disk as it
    /// goes, never held whole. `sent` hears the bytes written so far.
    func send(
        _ method: HTTPMethod, _ path: String, length: Int, body: @escaping @Sendable () async throws -> Data?, headers: [(String, String)],
        sent: @escaping @Sendable (Int) -> Void
    ) async throws -> HTTPResponse
    /// A response read as it arrives — events, a followed log, stats, a
    /// watch — until the server ends it or the consumer stops iterating.
    func stream(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error>
    /// A response's body handed to `consume` a piece at a time, the socket
    /// read further only as it takes them: a folder's archive written to a
    /// disk slower than the server sends slows the server down, and a few
    /// pieces wait in memory at most — never the archive. An error status
    /// throws the server's message; a connection closed before the end
    /// throws too.
    func receive(_ method: HTTPMethod, _ path: String, headers: [(String, String)], consume: (Data) async throws -> Void) async throws
    /// The server's readiness call (Docker's `/_ping`), as it answered.
    func ready() async throws -> HTTPResponse
}

/// HTTP/1.1 over a unix socket (or TCP, or a socket found when connecting:
/// an ssh forward, a proxy started on first use), on NIO's shared event
/// loops: a connection a request — a unix socket costs nothing to open,
/// and a stream holds its own until it is done. Chunked answers are
/// decoded as they come.
///
/// The Host header is the server's to check — Docker ignores it (`docker`),
/// `kubectl proxy` refuses any but `localhost` — and the readiness path is
/// the server's own.
struct UnixHTTPTransport: HTTPTransport {
    enum Address: Sendable {
        case unix(String)
        case tcp(host: String, port: Int)
        /// A unix socket whose path is found (or made) when a connection
        /// is: what it throws is said as it is when it's an `HTTPError`.
        case socket(@Sendable () async throws -> String)
    }

    let address: Address
    /// What every request says in `Host`.
    let host: String
    /// The path `ready` asks with a GET.
    let readinessPath: String
    /// Who answers, in the errors: "Docker isn't answering".
    let service: String

    init(address: Address, host: String, readinessPath: String, service: String) {
        self.address = address
        self.host = host
        self.readinessPath = readinessPath
        self.service = service
    }

    func ready() async throws -> HTTPResponse {
        try await send(.GET, readinessPath, body: nil, headers: [])
    }

    private func connect(_ handler: ChannelHandler & Sendable) async throws -> Channel {
        try await connect { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandler(handler)
                return channel
            }
        }
    }

    /// A connection to the server, its pipeline made by `initializer`.
    private func connect<Output: Sendable>(_ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>) async throws -> Output {
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.seconds(3))
        do {
            switch address {
            case .unix(let path): return try await bootstrap.connect(unixDomainSocketPath: path, channelInitializer: initializer)
            case .tcp(let host, let port): return try await bootstrap.connect(host: host, port: port, channelInitializer: initializer)
            case .socket(let find):
                let socket = try await find()
                return try await bootstrap.connect(unixDomainSocketPath: socket, channelInitializer: initializer)
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError.unreachable("\(service) isn't answering (\(error.localizedDescription)).")
        }
    }

    private func requestHead(_ method: HTTPMethod, _ path: String, _ headers: [(String, String)]) -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: path)
        head.headers.add(name: "Host", value: host)
        head.headers.add(name: "Connection", value: "close")
        head.headers.add(name: "User-Agent", value: "Overterm")
        for (name, value) in headers { head.headers.add(name: name, value: value) }
        return head
    }

    private func write(_ channel: Channel, _ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) {
        var head = requestHead(method, path, headers)
        // Always said, 0 for none: left out, NIO sends a POST chunked, and
        // Docker's engine (Go) takes a body of unknown length as one —
        // "starting container with non-empty request body" refused every
        // start.
        if method != .GET && method != .HEAD || body != nil { head.headers.add(name: "Content-Length", value: "\(body?.count ?? 0)") }
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body { channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    }

    func send(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse {
        let collector = ResponseCollector(service: service)
        let channel = try await connect(collector)
        write(channel, method, path, body: body, headers: headers)
        return try await withTaskCancellationHandler {
            try await collector.response.futureResult(on: channel.eventLoop).get()
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// Each piece written and flushed before the next is read: the
    /// socket's pace is the disk's. The server may answer before it has
    /// read everything — a read-only rootfs, a file over a folder — and
    /// close; the write then fails, and its answer is what is said.
    func send(
        _ method: HTTPMethod, _ path: String, length: Int, body: @escaping @Sendable () async throws -> Data?, headers: [(String, String)],
        sent: @escaping @Sendable (Int) -> Void
    ) async throws -> HTTPResponse {
        let collector = ResponseCollector(service: service)
        let channel = try await connect(collector)
        return try await withTaskCancellationHandler {
            var head = requestHead(method, path, headers)
            head.headers.add(name: "Content-Length", value: "\(length)")
            var total = 0
            do {
                try await channel.writeAndFlush(HTTPClientRequestPart.head(head)).get()
                while true {
                    let chunk: Data?
                    do {
                        chunk = try await body()
                    } catch {
                        // Ours, not the server's: nothing more is coming.
                        channel.close(promise: nil)
                        throw BodyFailure(error: error)
                    }
                    guard let chunk else { break }
                    try Task.checkCancellation()
                    try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: chunk)))).get()
                    total += chunk.count
                    sent(total)
                }
                try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            } catch let failure as BodyFailure {
                throw failure.error
            } catch {
                if Task.isCancelled || error is CancellationError {
                    channel.close(promise: nil)
                    throw CancellationError()
                }
                // Answered and closed before it read it all: the answer
                // says why — waited for a few seconds at most.
                let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
                defer { deadline.cancel() }
                if let answer = try? await collector.response.futureResult(on: channel.eventLoop).get() { return answer }
                throw error
            }
            return try await collector.response.futureResult(on: channel.eventLoop).get()
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

    /// NIO's async channel: its reads wait while the pieces it holds are
    /// ten, and go on below two — `consume` is the pace.
    ///
    /// A read whose connection went before any of its answer came — a
    /// server (or a socket) busy enough to drop a new connection — is asked
    /// once more: a GET or a HEAD changes nothing, and nothing of it was
    /// consumed.
    func receive(_ method: HTTPMethod, _ path: String, headers: [(String, String)], consume: (Data) async throws -> Void) async throws {
        let answered = Answered()
        do {
            try await receiveOnce(method, path, headers: headers, answered: answered, consume: consume)
        } catch let error as HTTPError where error.status == 0 && !answered.value && (method == .GET || method == .HEAD) && !Task.isCancelled {
            try await receiveOnce(method, path, headers: headers, answered: answered, consume: consume)
        }
    }

    /// Whether a response's head came.
    private final class Answered {
        var value = false
    }

    private func receiveOnce(
        _ method: HTTPMethod, _ path: String, headers: [(String, String)], answered: Answered, consume: (Data) async throws -> Void
    ) async throws {
        let connection = try await connect { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
            }
        }
        try await withTaskCancellationHandler {
            do {
                try await connection.executeThenClose { inbound, outbound in
                    var head = requestHead(method, path, headers)
                    if method != .GET && method != .HEAD { head.headers.add(name: "Content-Length", value: "0") }
                    try await outbound.write(.head(head))
                    try await outbound.write(.end(nil))
                    var status = 0
                    var errorBody = Data()
                    for try await part in inbound {
                        switch part {
                        case .head(let head):
                            status = Int(head.status.code)
                            answered.value = true
                        case .body(let buffer):
                            guard status < 400 else {
                                errorBody.append(contentsOf: buffer.readableBytesView)
                                continue
                            }
                            do {
                                try await consume(Data(buffer.readableBytesView))
                            } catch {
                                throw BodyFailure(error: error)
                            }
                        case .end:
                            guard status < 400 else {
                                throw HTTPError(status: status, message: HTTPResponse(status: status, headers: [], body: errorBody).errorMessage)
                            }
                            return
                        }
                    }
                    try Task.checkCancellation()
                    throw HTTPError.unreachable("\(service) closed the connection.")
                }
            } catch let failure as BodyFailure {
                throw failure.error
            } catch let error as HTTPError {
                throw error
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw HTTPError.unreachable(error.localizedDescription)
            }
        } onCancel: {
            connection.channel.close(promise: nil)
        }
    }
}

/// What a streamed body's own side threw — a file that changed as it was
/// read, a disk that filled as it was written: said as it is, not taken
/// for the server's.
private struct BodyFailure: Error {
    var error: Error
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
        private var promise: EventLoopPromise<HTTPResponse>?
        private var result: Result<HTTPResponse, Error>?
        private let lock = NSLock()

        func futureResult(on loop: EventLoop) -> EventLoopFuture<HTTPResponse> {
            lock.lock()
            defer { lock.unlock() }
            let promise = loop.makePromise(of: HTTPResponse.self)
            if let result { promise.completeWith(result) } else { self.promise = promise }
            return promise.futureResult
        }

        func complete(_ result: Result<HTTPResponse, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard self.result == nil else { return }
            self.result = result
            promise?.completeWith(result)
        }
    }

    let response = Pending()
    private let service: String
    private var status = 0
    private var headers: [(String, String)] = []
    private var body = Data()

    init(service: String) {
        self.service = service
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            headers = head.headers.map { ($0.name, $0.value) }
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            response.complete(.success(HTTPResponse(status: status, headers: headers, body: body)))
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        response.complete(.failure(HTTPError.unreachable("\(service) closed the connection.")))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        response.complete(.failure(HTTPError.unreachable(error.localizedDescription)))
        context.close(promise: nil)
    }
}

/// Hands a response's body on as it arrives; an error status ends the
/// stream with the server's message.
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
                continuation.finish(throwing: HTTPError(status: status, message: HTTPResponse(status: status, headers: [], body: errorBody).errorMessage))
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
        continuation.finish(throwing: HTTPError.unreachable(error.localizedDescription))
        context.close(promise: nil)
    }
}
