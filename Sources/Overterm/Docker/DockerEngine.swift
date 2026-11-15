import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// One answer from the engine (`HTTPResponse`, the shared transport's).
typealias DockerResponse = HTTPResponse

/// The engine's error status and its message, or (status 0) an engine
/// that couldn't be reached.
typealias DockerError = HTTPError

extension HTTPError {
    /// A volume's files and its export go through a container that never
    /// runs, made from any image here: there is none.
    static let noHelperImage = DockerError(
        status: 0, message: "A volume is read through a container that never runs, and it needs any image on this Mac — pull one (busybox).")

    /// The engine has no volume by that name now: removed, or pruned. 410,
    /// so nothing takes it for a helper gone under its tab (a 404).
    static func volumeGone(_ name: String) -> DockerError { DockerError(status: 410, message: "The volume \(name) is gone.") }
}

/// How bytes get to the engine and back: `UnixHTTPTransport` over a socket
/// for the app, the same over the fake engine's socket in the tests.
typealias DockerTransport = HTTPTransport

extension UnixHTTPTransport {
    /// The engine's socket (or `tcp://`, or an `ssh://` host's socket
    /// forwarded to one here): Host `docker`, ready when `/_ping` answers.
    static func docker(_ address: DockerEndpoint.Address) -> UnixHTTPTransport {
        let reached: Address =
            switch address {
            case .unix(let path): .unix(path)
            case .tcp(let host, let port): .tcp(host: host, port: port)
            case .ssh(let target): .socket { try await DockerSSHForwards.shared.socket(for: target) }
            case .unsupported(let host): .socket { throw DockerError.unreachable("\(host) isn't an address Overterm reaches yet.") }
            }
        return UnixHTTPTransport(address: reached, host: "docker", readinessPath: "/_ping", service: "Docker")
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
        self.transport = transport ?? UnixHTTPTransport.docker(endpoint.address)
    }

    /// Answers when the engine does; its API version, then used for every
    /// call.
    @discardableResult
    func ping() async throws -> String {
        let response = try await transport.ready()
        guard response.status == 200 else { throw DockerError(status: response.status, message: response.errorMessage) }
        let server = response.header("API-Version") ?? Self.clientVersion
        let version = Self.older(server, Self.clientVersion)
        negotiated.set(version, server: server)
        return version
    }

    /// A call's version when it wants a later one than every call's —
    /// `/containers/json` at 1.48 says what each container runs — and the
    /// engine speaks it; else the negotiated one.
    func version(wanting wanted: String) -> String {
        negotiated.server.map { Self.older($0, wanted) } ?? negotiated.value ?? Self.clientVersion
    }

    /// `1.44` vs `1.47`: the lower.
    static func older(_ a: String, _ b: String) -> String {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        return pa.lexicographicallyPrecedes(pb) ? a : b
    }

    /// `version`: the call's own (`version(wanting:)`), else the negotiated one.
    func path(_ path: String, _ query: [String: String] = [:], version: String? = nil) -> String {
        var components = URLComponents()
        components.path = "/v\(version ?? negotiated.value ?? Self.clientVersion)" + path
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        // `+` stays a plus in a query, which the engine reads as a space;
        // `;` stays raw, and Go refuses a query with one (a commit's comment).
        return (components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?" + $0.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: ";", with: "%3B") }
                ?? "")
    }

    /// A call whose answer is JSON; an error status throws the engine's
    /// message.
    func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String] = [:], version: String? = nil) async throws -> T {
        let response = try await send(.GET, path, query, version: version)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw DockerError(status: response.status, message: "Docker's answer to \(path) didn't read: \(error.localizedDescription)")
        }
    }

    /// The raw answer, after its status was checked.
    @discardableResult
    func send(
        _ method: HTTPMethod, _ path: String, _ query: [String: String] = [:], body: Data? = nil, headers: [(String, String)] = [],
        version: String? = nil
    ) async throws -> DockerResponse {
        let response = try await transport.send(method, self.path(path, query, version: version), body: body, headers: headers)
        guard (200..<300).contains(response.status) || response.status == 304 else {
            throw DockerError(status: response.status, message: response.errorMessage)
        }
        return response
    }

    /// The same with a body written as it is read (`DockerTransport`), its
    /// length said first.
    @discardableResult
    func send(
        _ method: HTTPMethod, _ path: String, _ query: [String: String] = [:], length: Int, body: @escaping @Sendable () async throws -> Data?,
        headers: [(String, String)] = [], sent: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> DockerResponse {
        let response = try await transport.send(method, self.path(path, query), length: length, body: body, headers: headers, sent: sent)
        guard (200..<300).contains(response.status) else { throw DockerError(status: response.status, message: response.errorMessage) }
        return response
    }

    func stream(_ path: String, _ query: [String: String] = [:]) -> AsyncThrowingStream<Data, Error> {
        transport.stream(.GET, self.path(path, query), body: nil, headers: [])
    }

    /// A GET's body a piece at a time, the next read only once `consume`
    /// has taken this one (`DockerTransport.receive`).
    func receive(_ path: String, _ query: [String: String] = [:], consume: (Data) async throws -> Void) async throws {
        try await transport.receive(.GET, self.path(path, query), headers: [], consume: consume)
    }
}

/// The version `ping` settled on, and the engine's own, read from any
/// thread.
private final class NegotiatedVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var version: String?
    private var serverVersion: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    var server: String? {
        lock.lock()
        defer { lock.unlock() }
        return serverVersion
    }

    func set(_ version: String, server: String) {
        lock.lock()
        self.version = version
        serverVersion = server
        lock.unlock()
    }
}
