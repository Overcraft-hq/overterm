import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import Overterm

/// The shared transport over a real unix socket, against a small server of
/// the test's own that checks the Host header as `kubectl proxy` does:
/// the Host and the readiness path are the transport's, chunked answers
/// are read whole or as they come, a stream goes on until the server ends
/// it, and the errors say who didn't answer. Docker's calls over it are
/// `DockerTransportTests`.
final class UnixHTTPTransportTests: XCTestCase {
    private var server: HostCheckingServer!

    override func setUpWithError() throws {
        // A unix socket's path must stay under 104 bytes.
        server = HostCheckingServer(socket: "/tmp/ot-http-\(UUID().uuidString.prefix(8)).sock", accepting: "localhost")
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    private func transport(host: String = "localhost", readiness: String = "/readyz", service: String = "The proxy") -> UnixHTTPTransport {
        UnixHTTPTransport(address: .unix(server.socket), host: host, readinessPath: readiness, service: service)
    }

    func testTheHostAndTheReadinessPathAreTheTransports() async throws {
        let ready = try await transport().ready()
        XCTAssertEqual(ready.status, 200)
        XCTAssertEqual(String(decoding: ready.body, as: UTF8.self), "ok")
        XCTAssertEqual(server.requests, ["GET /readyz localhost"])
        let refused = try await transport(host: "docker").ready()
        XCTAssertEqual(refused.status, 403, "any Host but the one the server accepts is refused")
        XCTAssertEqual(refused.errorMessage, "Forbidden\n", "plain text, as kubectl proxy says it")
        XCTAssertEqual(server.requests.last, "GET /readyz docker")
    }

    func testAChunkedAnswerIsReadWhole() async throws {
        let response = try await transport().send(.GET, "/chunked", body: nil, headers: [])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("transfer-encoding"), "chunked")
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "one\ntwo\nthree\n")
        var received = Data()
        try await transport().receive(.GET, "/chunked", headers: []) { received.append($0) }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "one\ntwo\nthree\n")
    }

    /// A watch: pieces written over time, read as each comes, until the
    /// server ends it.
    func testAStreamGoesOnUntilTheServerEndsIt() async throws {
        var pieces: [String] = []
        for try await piece in transport().stream(.GET, "/watch", body: nil, headers: []) {
            pieces.append(String(decoding: piece, as: UTF8.self))
        }
        XCTAssertEqual(pieces.joined(), "{\"type\":\"ADDED\"}\n{\"type\":\"MODIFIED\"}\n{\"type\":\"DELETED\"}\n")
        XCTAssertGreaterThan(pieces.count, 1, "read as they came, not at the end")
    }

    func testAStatusMessageIsTheError() async throws {
        do {
            try await transport().receive(.GET, "/status", headers: []) { _ in XCTFail("no body for an error") }
            XCTFail("an error status throws")
        } catch let error as HTTPError {
            XCTAssertEqual(error, HTTPError(status: 403, message: "pods is forbidden"))
        }
        do {
            for try await _ in transport().stream(.GET, "/status", body: nil, headers: []) { XCTFail("no body for an error") }
            XCTFail("an error status ends the stream with it")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.message, "pods is forbidden")
        }
    }

    func testAnUnansweredSocketSaysWho() async throws {
        let gone = UnixHTTPTransport(address: .unix("/tmp/ot-none-\(UUID().uuidString.prefix(8)).sock"), host: "localhost", readinessPath: "/readyz", service: "The proxy")
        do {
            _ = try await gone.ready()
            XCTFail("nothing listens there")
        } catch let error as HTTPError {
            XCTAssertEqual(error.status, 0)
            XCTAssertTrue(error.message.hasPrefix("The proxy isn't answering ("), error.message)
        }
    }

    /// A socket found when connecting — a forward or a proxy started on
    /// first use — is asked for at each connection; what it throws is said
    /// as it is.
    func testASocketFoundWhenConnecting() async throws {
        let asked = Counter()
        let socket = server.socket
        let found = UnixHTTPTransport(
            address: .socket {
                asked.increment()
                return socket
            }, host: "localhost", readinessPath: "/readyz", service: "The proxy")
        _ = try await found.ready()
        _ = try await found.send(.GET, "/chunked", body: nil, headers: [])
        XCTAssertEqual(asked.value, 2)
        let refused = UnixHTTPTransport(
            address: .socket { throw HTTPError.unreachable("kubectl proxy exited: Token has expired.") }, host: "localhost", readinessPath: "/readyz",
            service: "The proxy")
        do {
            _ = try await refused.ready()
            XCTFail("no socket")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .unreachable("kubectl proxy exited: Token has expired."))
        }
    }

    /// Docker's: Host `docker`, `/_ping`, its errors in its name.
    func testDockersTransport() async throws {
        let docker = UnixHTTPTransport.docker(.unix(server.socket))
        XCTAssertEqual(docker.host, "docker")
        XCTAssertEqual(docker.readinessPath, "/_ping")
        XCTAssertEqual(docker.service, "Docker")
        _ = try await docker.ready()
        XCTAssertEqual(server.requests, ["GET /_ping docker"])
        do {
            _ = try await UnixHTTPTransport.docker(.unsupported("npipe:////./pipe/docker_engine")).ready()
            XCTFail("not an address a Mac reaches")
        } catch let error as DockerError {
            XCTAssertEqual(error, .unreachable("npipe:////./pipe/docker_engine isn't an address Overterm reaches yet."))
        }
        do {
            _ = try await UnixHTTPTransport.docker(.unix("/tmp/ot-none-\(UUID().uuidString.prefix(8)).sock")).ready()
            XCTFail("nothing listens there")
        } catch let error as DockerError {
            XCTAssertTrue(error.message.hasPrefix("Docker isn't answering ("), error.message)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Answers on a unix socket, refusing any Host but `accepting` with a
/// plain-text 403 — except `/_ping`, Docker's, which never checks it.
/// `/readyz` and `/_ping` say ok; `/chunked` answers in chunks; `/watch`
/// writes its pieces 30 ms apart; `/status` is a Status JSON 403.
private final class HostCheckingServer: @unchecked Sendable {
    let socket: String
    let accepting: String
    private let lock = NSLock()
    private var asked: [String] = []
    private var channel: Channel?

    init(socket: String, accepting: String) {
        self.socket = socket
        self.accepting = accepting
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    fileprivate func record(_ request: String) {
        lock.lock()
        asked.append(request)
        lock.unlock()
    }

    func start() throws {
        try? FileManager.default.removeItem(atPath: socket)
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(Handler(server: self))
                }
            }
        channel = try bootstrap.bind(unixDomainSocketPath: socket).wait()
    }

    func stop() {
        try? channel?.close().wait()
        try? FileManager.default.removeItem(atPath: socket)
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        let server: HostCheckingServer
        private var head: HTTPRequestHead?

        init(server: HostCheckingServer) {
            self.server = server
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): self.head = head
            case .body: break
            case .end:
                guard let head else { return }
                let host = head.headers["Host"].first ?? ""
                server.record("\(head.method.rawValue) \(head.uri) \(host)")
                if head.uri != "/_ping" && host != server.accepting {
                    whole(context, .forbidden, "Forbidden\n", type: "text/plain")
                    return
                }
                switch head.uri {
                case "/readyz", "/_ping": whole(context, .ok, "ok", type: "text/plain")
                case "/status":
                    whole(context, .forbidden, #"{"kind":"Status","status":"Failure","message":"pods is forbidden","code":403}"#, type: "application/json")
                case "/chunked": chunks(context, ["one\n", "two\n", "three\n"], every: nil)
                case "/watch": chunks(context, [#"{"type":"ADDED"}"# + "\n", #"{"type":"MODIFIED"}"# + "\n", #"{"type":"DELETED"}"# + "\n"], every: .milliseconds(30))
                default: whole(context, .notFound, "404 page not found\n", type: "text/plain")
                }
            }
        }

        private func whole(_ context: ChannelHandlerContext, _ status: HTTPResponseStatus, _ text: String, type: String) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: type)
            headers.add(name: "Content-Length", value: "\(text.utf8.count)")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }

        /// No length said: NIO sends the body chunked.
        private func chunks(_ context: ChannelHandlerContext, _ pieces: [String], every interval: TimeAmount?) {
            var headers = HTTPHeaders()
            headers.add(name: "Transfer-Encoding", value: "chunked")
            context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            guard let interval else {
                for piece in pieces { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: piece)))), promise: nil) }
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
                return
            }
            func next(_ index: Int) {
                guard index < pieces.count else {
                    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
                    return
                }
                context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: pieces[index])))), promise: nil)
                context.eventLoop.scheduleTask(in: interval) { next(index + 1) }
            }
            next(0)
        }
    }
}
