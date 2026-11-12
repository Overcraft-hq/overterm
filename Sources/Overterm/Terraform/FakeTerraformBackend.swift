import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Terraform's `http` state backend, played on 127.0.0.1 at a port of the
/// system's, for the tests and the `terraform` scenarios: a remote state
/// that is never one of the user's (analysis 11). With it the real
/// terraform, offline, shows a lock held by `ci@globex-runner-7`, a remote
/// state identity, and two worktrees on one state.
///
/// It keeps states by path (`/state/<name>`), as the backend's client
/// speaks to it (Terraform's `internal/backend/remote-state/http`):
/// - `GET`: the state, or 404 — which Terraform reads as "no state yet";
/// - `POST` (and `PUT`): the state written; `DELETE`: removed. While a lock
///   is held, only with `?ID=<the lock's ID>`, else 409 and the lock;
/// - `LOCK`: the lock taken with the body's lock info, or 423 Locked with
///   the holder's — what Terraform parses into "Error acquiring the state
///   lock", the http variant's `HTTP remote state already locked: ID=…`;
/// - `UNLOCK`: released by the holder's ID; with an **empty body** —
///   `force-unlock`'s — whatever lock is there is removed, as GitLab's
///   managed state does (analysis 4.10: the sheet says so);
/// - `failCredentials`: every answer a 401 (or 403), as an endpoint whose
///   credentials were refused.
///
/// Every request is recorded (method, path, query, whether it carried
/// credentials — never their value), so a test shows which reached it:
/// that a lock probe locked and unlocked, that a plan never wrote.
final class FakeTerraformBackend: @unchecked Sendable {
    /// A lock as Terraform's `statemgr.LockInfo` says it.
    struct Lock: Equatable, Sendable {
        var id: String
        var operation: String
        var info: String
        var who: String
        var version: String
        /// As Terraform writes it (`statemgr.NewLockInfo`: `time.Now().UTC()`,
        /// marshalled RFC 3339 with up to nine fraction digits, trailing
        /// zeros dropped — on a Mac, microseconds): `2026-11-08T11:42:46.353924Z`.
        var created: String
        var path: String

        var json: Data {
            let object: [String: String] = [
                "ID": id, "Operation": operation, "Info": info, "Who": who, "Version": version, "Created": created, "Path": path,
            ]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        init(id: String, operation: String, info: String = "", who: String, version: String, created: String, path: String = "") {
            self.id = id
            self.operation = operation
            self.info = info
            self.who = who
            self.version = version
            self.created = created
            self.path = path
        }

        /// The lock info Terraform sent; nil when it isn't one (no `ID`).
        init?(json: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let id = object["ID"] as? String, !id.isEmpty
            else { return nil }
            func text(_ key: String) -> String { object[key] as? String ?? "" }
            self.init(
                id: id, operation: text("Operation"), info: text("Info"), who: text("Who"), version: text("Version"), created: text("Created"),
                path: text("Path"))
        }
    }

    struct Request: Equatable, Sendable, CustomStringConvertible {
        var method: String
        var path: String
        var query: [String: String]
        /// Whether it carried an `Authorization` header (the backend's
        /// `username`/`password`). Never its value.
        var authorized: Bool
        var body: Data

        var description: String { "\(method) \(path)" }
        /// The lock info of a LOCK or an UNLOCK; nil for an empty body.
        var lock: Lock? { Lock(json: body) }
    }

    private let lock = NSLock()
    private var states: [String: Data] = [:]
    private var locks: [String: Lock] = [:]
    private var asked: [Request] = []
    private var credentialFailure: Int?
    private var channels: [Channel] = []
    private var boundPort = 0
    /// The port it listens on; 0 before `start`.
    var port: Int { locked { boundPort } }

    init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Serving

    /// Listens on 127.0.0.1 at a port of the system's; returns it.
    @discardableResult
    func start() throws -> Int {
        let bound = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(FakeTerraformBackendHandler(backend: self))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        let port = bound.localAddress?.port ?? 0
        locked {
            channels.append(bound)
            boundPort = port
        }
        return port
    }

    func stop() {
        let listening = locked {
            defer { channels = [] }
            return channels
        }
        for channel in listening { try? channel.close().wait() }
    }

    /// The state `name`'s address: `http://127.0.0.1:<port>/state/<name>`.
    func address(_ name: String) -> String {
        "http://127.0.0.1:\(port)/state/\(name)"
    }

    /// A root's backend block for state `name`, with its lock and unlock
    /// addresses (without them the http backend doesn't lock at all).
    func backendBlock(_ name: String) -> String {
        let address = TerraformGuards.hclString(address(name))
        return """
            terraform {
              backend "http" {
                address        = \(address)
                lock_address   = \(address)
                unlock_address = \(address)
              }
            }

            """
    }

    // MARK: What a test sets and reads

    /// The state `name` as last written; nil when there is none.
    func state(_ name: String) -> Data? { locked { states["/state/\(name)"] } }

    /// Puts a state in place, as another machine's apply would have.
    func setState(_ name: String, _ data: Data?) { locked { states["/state/\(name)"] = data } }

    /// The lock held on `name` now.
    func heldLock(_ name: String) -> Lock? { locked { locks["/state/\(name)"] } }

    /// Holds `name`'s lock as someone else's run would: `who` (`user@host`),
    /// an apply by default, by Terraform 1.17.1, since `created`.
    @discardableResult
    func holdLock(
        _ name: String, who: String, operation: String = "OperationTypeApply", id: String = "8a3c1e52-acme-0000-0000-0000000f00d5",
        version: String = "1.17.1", created: Date = Date(), info: String = ""
    ) -> Lock {
        let path = "/state/\(name)"
        let held = Lock(id: id, operation: operation, info: info, who: who, version: version, created: Self.goTime(created), path: "")
        locked { locks[path] = held }
        return held
    }

    /// Lets go of `name`'s lock, whoever holds it.
    func releaseLock(_ name: String) { _ = locked { locks.removeValue(forKey: "/state/\(name)") } }

    /// Every answer `status` (401: credentials needed; 403: refused) until
    /// set back to nil.
    var failCredentials: Int? {
        get { locked { credentialFailure } }
        set { locked { credentialFailure = newValue } }
    }

    var requests: [Request] { locked { asked } }
    /// What changed something: anything but a GET.
    var writes: [Request] { requests.filter { $0.method != "GET" } }

    func forgetRequests() { locked { asked = [] } }

    /// A date as Terraform's lock info carries it: Go's `time.Time` in UTC
    /// marshalled to JSON (RFC 3339 with nanoseconds, trailing zeros and an
    /// all-zero fraction dropped, `Z`). Microseconds here, a Mac's clock's.
    static func goTime(_ date: Date) -> String {
        var seconds = date.timeIntervalSince1970.rounded(.down)
        var micros = Int(((date.timeIntervalSince1970 - seconds) * 1_000_000).rounded())
        if micros >= 1_000_000 {
            seconds += 1
            micros -= 1_000_000
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        var text = formatter.string(from: Date(timeIntervalSince1970: seconds))
        guard micros > 0, text.hasSuffix("Z") else { return text }
        var fraction = String(format: "%06d", micros)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        text.removeLast()
        return text + "." + fraction + "Z"
    }

    // MARK: Answering

    enum Answer: Equatable, Sendable {
        case empty(Int)
        case json(Int, Data)
        case text(Int, String)
    }

    /// The answer to one request, recorded first. Called on the event loop.
    func answer(method: String, uri: String, authorized: Bool, body: Data) -> Answer {
        let components = URLComponents(string: "http://127.0.0.1" + uri)
        let path = components?.path ?? uri
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return locked {
            asked.append(Request(method: method, path: path, query: query, authorized: authorized, body: body))
            if let status = credentialFailure { return .text(status, status == 401 ? "Unauthorized\n" : "Forbidden\n") }
            guard path.hasPrefix("/state/"), path.count > "/state/".count else { return .text(404, "Not Found\n") }
            switch method {
            case "GET":
                guard let state = states[path] else { return .text(404, "Not Found\n") }
                return .json(200, state)
            case "POST", "PUT", "DELETE":
                if let held = locks[path], query["ID"] != held.id { return .json(409, held.json) }
                if method == "DELETE" {
                    states[path] = nil
                } else {
                    states[path] = body
                }
                return .empty(200)
            case "LOCK":
                if let held = locks[path] { return .json(423, held.json) }
                guard let asking = Lock(json: body) else { return .text(400, "No lock info\n") }
                locks[path] = asking
                return .empty(200)
            case "UNLOCK":
                guard let held = locks[path] else { return .empty(200) }
                if body.isEmpty || Lock(json: body)?.id == held.id {
                    locks[path] = nil
                    return .empty(200)
                }
                return .json(409, held.json)
            default:
                return .text(405, "Method Not Allowed\n")
            }
        }
    }
}

private final class FakeTerraformBackendHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let backend: FakeTerraformBackend
    private var head: HTTPRequestHead?
    private var body = Data()

    init(backend: FakeTerraformBackend) {
        self.backend = backend
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(let buffer): body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { return }
            self.head = nil
            respond(context, head)
        }
    }

    private func respond(_ context: ChannelHandlerContext, _ request: HTTPRequestHead) {
        let answer = backend.answer(
            method: request.method.rawValue, uri: request.uri, authorized: !request.headers["Authorization"].isEmpty, body: body)
        let (status, data, type): (Int, Data, String?) =
            switch answer {
            case .empty(let status): (status, Data(), nil)
            case .json(let status, let data): (status, data, "application/json")
            case .text(let status, let text): (status, Data(text.utf8), "text/plain; charset=utf-8")
            }
        var head = HTTPResponseHead(version: request.version, status: HTTPResponseStatus(statusCode: status))
        if let type { head.headers.add(name: "Content-Type", value: type) }
        head.headers.add(name: "Content-Length", value: "\(data.count)")
        head.headers.add(name: "Connection", value: "close")
        let channel = context.channel
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !data.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: data)))), promise: nil) }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }
}
