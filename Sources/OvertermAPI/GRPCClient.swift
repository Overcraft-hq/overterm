import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix
import NIOSSL

/// gRPC over HTTP/2 — no gRPC library: a call is a stream with a HEADERS
/// frame (`:path` the method, `content-type: application/grpc`, `te:
/// trailers`, the metadata), each message a DATA frame with gRPC's five-byte
/// prefix, and the answer the same back with `grpc-status` in the trailers
/// (or in the headers alone, "trailers-only", for a call refused at once).
/// TLS by ALPN h2, or h2c to a local server.
package final class GRPCConnection: @unchecked Sendable {
    package struct Failure: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    /// What came back from a call.
    package struct Reply: Sendable, Equatable {
        package var headers: [(name: String, value: String)] = []
        package var messages: [Data] = []
        package var status = 2
        package var statusMessage = ""
        package var trailers: [(name: String, value: String)] = []

        package static func == (a: Reply, b: Reply) -> Bool {
            a.messages == b.messages && a.status == b.status && a.statusMessage == b.statusMessage && a.headers.map(\.value) == b.headers.map(\.value)
                && a.trailers.map(\.value) == b.trailers.map(\.value)
        }

        package var statusName: String { GRPCConnection.statusName(status) }
    }

    private let channel: Channel
    private let multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>
    package let authority: String
    package let scheme: String

    private init(channel: Channel, multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Void>, authority: String, scheme: String) {
        self.channel = channel
        self.multiplexer = multiplexer
        self.authority = authority
        self.scheme = scheme
    }

    /// `grpc://host:port` is h2c, `grpcs://` TLS; with neither, TLS unless
    /// the host is this Mac — as Bruno reads an address.
    package static func endpoint(_ address: String) -> (host: String, port: Int, tls: Bool, prefix: String)? {
        var text = address.trimmingCharacters(in: .whitespaces)
        var tls: Bool?
        for (scheme, secure) in [("grpcs://", true), ("https://", true), ("grpc://", false), ("http://", false)] where text.lowercased().hasPrefix(scheme) {
            tls = secure
            text = String(text.dropFirst(scheme.count))
        }
        var prefix = ""
        if let slash = text.firstIndex(of: "/") {
            prefix = String(text[slash...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            prefix = prefix.isEmpty ? "" : "/" + prefix
            text = String(text[..<slash])
        }
        guard let components = URLComponents(string: "x://" + text), let host = components.host, !host.isEmpty else { return nil }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        let secure = tls ?? !local
        return (host, components.port ?? (secure ? 443 : 80), secure, prefix)
    }

    package static func connect(host: String, port: Int, tls: Bool, verify: Bool = true, serverName: String? = nil) async throws -> GRPCConnection {
        let sslContext: NIOSSLContext?
        if tls {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.applicationProtocols = ["h2"]
            if !verify { configuration.certificateVerification = .none }
            sslContext = try NIOSSLContext(configuration: configuration)
        } else {
            sslContext = nil
        }
        let hostname = serverName ?? host
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.seconds(10))
        let (channel, multiplexer): (Channel, NIOHTTP2Handler.AsyncStreamMultiplexer<Void>)
        do {
            (channel, multiplexer) = try await bootstrap.connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        let handler = try NIOSSLClientHandler(
                            context: sslContext, serverHostname: (hostname.first?.isNumber == true || hostname.contains(":")) ? nil : hostname)
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                    let multiplexer = try channel.pipeline.syncOperations.configureAsyncHTTP2Pipeline(mode: .client) { stream in
                        // The server opens no streams of its own to a client.
                        stream.eventLoop.makeSucceededVoidFuture()
                    }
                    return (channel, multiplexer)
                }
            }
        } catch {
            throw Failure(message: "Couldn't reach \(host):\(port) — \(error.localizedDescription)")
        }
        return GRPCConnection(channel: channel, multiplexer: multiplexer, authority: port == (tls ? 443 : 80) ? host : "\(host):\(port)", scheme: tls ? "https" : "http")
    }

    package func close() {
        channel.close(promise: nil)
    }

    /// One call: the messages sent (then the stream half-closed), every
    /// message that came back and the status. `onMessage` hears each as it
    /// arrives — a server stream's, shown as they come.
    package func call(
        _ path: String, metadata: [(String, String)] = [], messages: [Data], timeout: TimeInterval = 30,
        onMessage: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Reply {
        let stream = try await multiplexer.openStream { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<HTTP2Frame.FramePayload, HTTP2Frame.FramePayload>(wrappingChannelSynchronously: channel)
            }
        }
        let authority = authority
        let scheme = scheme
        return try await withThrowingTaskGroup(of: Reply?.self) { group in
            group.addTask {
                try await stream.executeThenClose { inbound, outbound in
                    var headers: HPACKHeaders = [
                        ":method": "POST", ":scheme": scheme, ":path": path, ":authority": authority, "content-type": "application/grpc",
                        "te": "trailers", "user-agent": "overterm-grpc/\(MCPClient.appVersion)",
                        "grpc-timeout": "\(max(1, Int(timeout)))S",
                    ]
                    for (name, value) in metadata { headers.add(name: name.lowercased(), value: value) }
                    try await outbound.write(.headers(.init(headers: headers, endStream: messages.isEmpty)))
                    for (index, message) in messages.enumerated() {
                        var buffer = ByteBuffer()
                        buffer.writeInteger(UInt8(0))
                        buffer.writeInteger(UInt32(message.count))
                        buffer.writeBytes(message)
                        try await outbound.write(.data(.init(data: .byteBuffer(buffer), endStream: index == messages.count - 1)))
                    }
                    var reply = Reply()
                    var sawHeaders = false
                    var pending = ByteBuffer()
                    func finish(_ fields: HPACKHeaders) {
                        reply.trailers = fields.map { ($0.name, $0.value) }
                        reply.status = fields.first(name: "grpc-status").flatMap(Int.init) ?? 2
                        reply.statusMessage = (fields.first(name: "grpc-message") ?? "").removingPercentEncoding ?? ""
                    }
                    for try await frame in inbound {
                        switch frame {
                        case .headers(let payload):
                            if !sawHeaders {
                                sawHeaders = true
                                let status = payload.headers.first(name: ":status") ?? ""
                                reply.headers = payload.headers.map { ($0.name, $0.value) }.filter { !$0.0.hasPrefix(":") }
                                if status != "200" && payload.headers.first(name: "grpc-status") == nil {
                                    throw Failure(message: "Not a gRPC answer: HTTP \(status)" + (payload.headers.first(name: "content-type").map { " (\($0))" } ?? "") + ".")
                                }
                                // Trailers-only: the status in the headers.
                                if payload.endStream || payload.headers.first(name: "grpc-status") != nil { finish(payload.headers) }
                            } else {
                                finish(payload.headers)
                            }
                            if payload.endStream { return reply }
                        case .data(let payload):
                            if case .byteBuffer(var chunk) = payload.data { pending.writeBuffer(&chunk) }
                            while pending.readableBytes >= 5 {
                                guard let compressed = pending.getInteger(at: pending.readerIndex, as: UInt8.self),
                                    let length = pending.getInteger(at: pending.readerIndex + 1, as: UInt32.self),
                                    pending.readableBytes >= 5 + Int(length)
                                else { break }
                                pending.moveReaderIndex(forwardBy: 5)
                                let bytes = Data(pending.readBytes(length: Int(length)) ?? [])
                                if compressed != 0 { throw Failure(message: "The server compressed a message, which Overterm doesn't ask for or read.") }
                                reply.messages.append(bytes)
                                onMessage?(bytes)
                            }
                            if payload.endStream { return reply }
                        case .rstStream(let code):
                            throw Failure(message: "The server reset the stream (\(code)).")
                        default:
                            break
                        }
                    }
                    if !sawHeaders { throw Failure(message: "The server closed the stream without answering.") }
                    return reply
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout + 1))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let reply = first else {
                throw Failure(message: "No answer in \(Int(timeout)) s (DEADLINE_EXCEEDED).")
            }
            return reply
        }
    }

    /// gRPC's status codes, as the spec names them.
    package static func statusName(_ code: Int) -> String {
        let names = [
            "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS", "PERMISSION_DENIED",
            "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
            "UNAUTHENTICATED",
        ]
        return names.indices.contains(code) ? names[code] : "STATUS \(code)"
    }
}

// MARK: Reflection

/// A server's own description of itself: gRPC server reflection, v1 then
/// v1alpha — its services, then the files that declare them and what they
/// import.
package enum GRPCReflection {
    package static let paths = ["/grpc.reflection.v1.ServerReflection/ServerReflectionInfo", "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo"]

    /// A ServerReflectionRequest: `list_services` (7), `file_containing_symbol`
    /// (4) or `file_by_filename` (3).
    package static func request(field: Int, _ text: String) -> Data {
        var writer = Protobuf.Writer()
        writer.field(field, string: text)
        return writer.data
    }

    package struct Response {
        package var services: [String] = []
        package var files: [Data] = []
        package var error: String?
    }

    /// A ServerReflectionResponse: its service names, its files' bytes, its error.
    package static func response(_ data: Data) throws -> Response {
        var reader = Protobuf.Reader(data)
        var out = Response()
        while let (number, wire) = try reader.tag() {
            switch (number, wire) {
            case (4, .lengthDelimited):
                var files = Protobuf.Reader(try reader.bytes())
                while let (field, fieldWire) = try files.tag() {
                    if field == 1 { out.files.append(try files.bytes()) } else { try files.skip(fieldWire) }
                }
            case (6, .lengthDelimited):
                var list = Protobuf.Reader(try reader.bytes())
                while let (field, fieldWire) = try list.tag() {
                    guard field == 1 else {
                        try list.skip(fieldWire)
                        continue
                    }
                    var service = Protobuf.Reader(try list.bytes())
                    while let (inner, innerWire) = try service.tag() {
                        if inner == 1 { out.services.append(String(decoding: try service.bytes(), as: UTF8.self)) } else { try service.skip(innerWire) }
                    }
                }
            case (7, .lengthDelimited):
                var error = Protobuf.Reader(try reader.bytes())
                var message = ""
                while let (field, fieldWire) = try error.tag() {
                    if field == 2 { message = String(decoding: try error.bytes(), as: UTF8.self) } else { try error.skip(fieldWire) }
                }
                out.error = message
            default: try reader.skip(wire)
            }
        }
        return out
    }

    /// Everything the server describes, read into a registry.
    package static func registry(_ connection: GRPCConnection, metadata: [(String, String)], prefix: String = "") async throws -> Protobuf.Registry {
        var lastError = "The server has no reflection."
        for path in paths {
            let listed = try await connection.call(prefix + path, metadata: metadata, messages: [request(field: 7, "")], timeout: 15)
            guard listed.status == 0 else {
                // UNIMPLEMENTED: try the other version.
                lastError = listed.status == 12 ? "The server has no reflection (UNIMPLEMENTED) — give the request a .proto file." : "Reflection: \(listed.statusName) \(listed.statusMessage)"
                if listed.status == 12 { continue }
                throw GRPCConnection.Failure(message: lastError)
            }
            let services = try listed.messages.flatMap { try response($0).services }.filter { !$0.hasPrefix("grpc.reflection.") }
            var registry = Protobuf.Registry()
            var files: [String: Protobuf.File] = [:]
            let found = try await connection.call(
                prefix + path, metadata: metadata, messages: services.map { request(field: 4, $0) }, timeout: 15)
            for message in found.messages {
                for bytes in try response(message).files {
                    let file = try Protobuf.file(bytes)
                    files[file.name] = file
                }
            }
            // What they import and the server didn't send yet, asked by name.
            for _ in 0..<4 {
                let missing = Set(files.values.flatMap(\.dependencies)).subtracting(files.keys).sorted()
                guard !missing.isEmpty else { break }
                let more = try await connection.call(prefix + path, metadata: metadata, messages: missing.map { request(field: 3, $0) }, timeout: 15)
                var added = false
                for message in more.messages {
                    for bytes in try response(message).files {
                        let file = try Protobuf.file(bytes)
                        if files[file.name] == nil { added = true }
                        files[file.name] = file
                    }
                }
                if !added { break }
            }
            for file in files.values.sorted(by: { $0.name < $1.name }) { registry.add(file) }
            return registry
        }
        throw GRPCConnection.Failure(message: lastError)
    }
}

// MARK: protoc

/// `.proto` files compiled by the `protoc` on this Mac into the descriptors
/// a call needs — as Bruno reads its collection's proto files.
package enum GRPCProtoc {
    /// On the user's PATH — or, where their shell isn't asked (a test, a
    /// scenario), the one this process has, then Homebrew's places.
    package static func locate() -> URL? {
        locate(environment: ShellEnvironment.environment())
    }

    /// Where Homebrew puts it, after the PATH.
    package static let fallbackPaths = ["/opt/homebrew/bin/protoc", "/usr/local/bin/protoc"]

    /// `protoc` on `environment`'s PATH, else in `fallbackPaths`: pure but
    /// for `isExecutable` — the Setup page looks the same way, never running it.
    package static func locate(environment: [String: String], isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> URL? {
        if let found = ShellEnvironment.executable("protoc", in: environment, isExecutable: isExecutable) { return found }
        return fallbackPaths.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }

    package static func registry(files: [URL], importPaths: [URL]) throws -> Protobuf.Registry {
        guard let protoc = locate() else {
            throw GRPCConnection.Failure(message: "protoc isn't installed — `brew install protobuf` — or use a server with reflection.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-\(UUID().uuidString).pb")
        defer { try? FileManager.default.removeItem(at: output) }
        var includes = importPaths.map(\.path)
        for file in files where !includes.contains(file.deletingLastPathComponent().path) { includes.append(file.deletingLastPathComponent().path) }
        let process = Process()
        process.executableURL = protoc
        process.arguments = ["--include_imports", "--descriptor_set_out=\(output.path)"] + includes.map { "-I\($0)" } + files.map(\.path)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GRPCConnection.Failure(message: "protoc: " + String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Protobuf.Registry(try Protobuf.fileSet(try Data(contentsOf: output)))
    }
}
