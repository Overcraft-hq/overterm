import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix

/// A gRPC server of the tests' own, nothing leaving the machine: h2c on a
/// free port, `shop.v1.Orders` (Tests/OvertermTests/Fixtures/grpc/shop.proto)
/// — a method of each kind — and server reflection (v1, or only v1alpha
/// when `reflectionV1` is off) from the descriptors protoc made of it.
final class E2EGRPCServer: @unchecked Sendable {
    /// shop.proto and what it imports, as `protoc --include_imports
    /// --descriptor_set_out` writes them — so no test needs protoc.
    static let descriptorSet = Data(
        base64Encoded:
            "Cv8BCh9nb29nbGUvcHJvdG9idWYvdGltZXN0YW1wLnByb3RvEg9nb29nbGUucHJvdG9idWYiOwoJVGltZXN0YW1wEhgKB3NlY29uZHMYASABKANSB3NlY29uZHMSFAoFbmFub3MYAiABKAVSBW5hbm9zQoUBChNjb20uZ29vZ2xlLnByb3RvYnVmQg5UaW1lc3RhbXBQcm90b1ABWjJnb29nbGUuZ29sYW5nLm9yZy9wcm90b2J1Zi90eXBlcy9rbm93bi90aW1lc3RhbXBwYvgBAaICA0dQQqoCHkdvb2dsZS5Qcm90b2J1Zi5XZWxsS25vd25UeXBlc2IGcHJvdG8zCoYECh5nb29nbGUvcHJvdG9idWYvd3JhcHBlcnMucHJvdG8SD2dvb2dsZS5wcm90b2J1ZiIjCgtEb3VibGVWYWx1ZRIUCgV2YWx1ZRgBIAEoAVIFdmFsdWUiIgoKRmxvYXRWYWx1ZRIUCgV2YWx1ZRgBIAEoAlIFdmFsdWUiIgoKSW50NjRWYWx1ZRIUCgV2YWx1ZRgBIAEoA1IFdmFsdWUiIwoLVUludDY0VmFsdWUSFAoFdmFsdWUYASABKARSBXZhbHVlIiIKCkludDMyVmFsdWUSFAoFdmFsdWUYASABKAVSBXZhbHVlIiMKC1VJbnQzMlZhbHVlEhQKBXZhbHVlGAEgASgNUgV2YWx1ZSIhCglCb29sVmFsdWUSFAoFdmFsdWUYASABKAhSBXZhbHVlIiMKC1N0cmluZ1ZhbHVlEhQKBXZhbHVlGAEgASgJUgV2YWx1ZSIiCgpCeXRlc1ZhbHVlEhQKBXZhbHVlGAEgASgMUgV2YWx1ZUKDAQoTY29tLmdvb2dsZS5wcm90b2J1ZkINV3JhcHBlcnNQcm90b1ABWjFnb29nbGUuZ29sYW5nLm9yZy9wcm90b2J1Zi90eXBlcy9rbm93bi93cmFwcGVyc3Bi+AEBogIDR1BCqgIeR29vZ2xlLlByb3RvYnVmLldlbGxLbm93blR5cGVzYgZwcm90bzMK8gkKCnNob3AucHJvdG8SB3Nob3AudjEaH2dvb2dsZS9wcm90b2J1Zi90aW1lc3RhbXAucHJvdG8aHmdvb2dsZS9wcm90b2J1Zi93cmFwcGVycy5wcm90byIhCg9HZXRPcmRlclJlcXVlc3QSDgoCaWQYASABKAlSAmlkIlIKEUxpc3RPcmRlcnNSZXF1ZXN0EhQKBWxpbWl0GAEgASgFUgVsaW1pdBInCgZzdGF0dXMYAiABKA4yDy5zaG9wLnYxLlN0YXR1c1IGc3RhdHVzIocFCgVPcmRlchIOCgJpZBgBIAEoCVICaWQSHwoLdG90YWxfY2VudHMYAiABKANSCnRvdGFsQ2VudHMSJwoGc3RhdHVzGAMgASgOMg8uc2hvcC52MS5TdGF0dXNSBnN0YXR1cxISCgR0YWdzGAQgAygJUgR0YWdzEj4KCnF1YW50aXRpZXMYBSADKAsyHi5zaG9wLnYxLk9yZGVyLlF1YW50aXRpZXNFbnRyeVIKcXVhbnRpdGllcxI5CgpjcmVhdGVkX2F0GAYgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIJY3JlYXRlZEF0EjMKCGN1c3RvbWVyGAcgASgLMhcuc2hvcC52MS5PcmRlci5DdXN0b21lclIIY3VzdG9tZXISMAoEbm90ZRgIIAEoCzIcLmdvb2dsZS5wcm90b2J1Zi5TdHJpbmdWYWx1ZVIEbm90ZRIWCgZzY29yZXMYCSADKAVSBnNjb3JlcxIWCgZ3ZWlnaHQYCiABKAFSBndlaWdodBISCgRnaWZ0GAsgASgIUgRnaWZ0EhIKBGJsb2IYDCABKAxSBGJsb2ISGgoHYWRkcmVzcxgNIAEoCUgAUgdhZGRyZXNzEiMKDHBpY2t1cF9wb2ludBgOIAEoCUgAUgtwaWNrdXBQb2ludBIUCgVkZWx0YRgPIAEoElIFZGVsdGEaNAoIQ3VzdG9tZXISEgoEbmFtZRgBIAEoCVIEbmFtZRIUCgVlbWFpbBgCIAEoCVIFZW1haWwaPQoPUXVhbnRpdGllc0VudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgFUgV2YWx1ZToCOAFCCgoIZGVsaXZlcnkiRgoNVXBsb2FkU3VtbWFyeRIUCgVjb3VudBgBIAEoBVIFY291bnQSHwoLdG90YWxfY2VudHMYAiABKANSCnRvdGFsQ2VudHMiIQoLQ2hhdE1lc3NhZ2USEgoEdGV4dBgBIAEoCVIEdGV4dCo3CgZTdGF0dXMSFgoSU1RBVFVTX1VOU1BFQ0lGSUVEEAASCAoEUEFJRBABEgsKB1NISVBQRUQQAjLsAQoGT3JkZXJzEjQKCEdldE9yZGVyEhguc2hvcC52MS5HZXRPcmRlclJlcXVlc3QaDi5zaG9wLnYxLk9yZGVyEjoKCkxpc3RPcmRlcnMSGi5zaG9wLnYxLkxpc3RPcmRlcnNSZXF1ZXN0Gg4uc2hvcC52MS5PcmRlcjABEjgKDFVwbG9hZE9yZGVycxIOLnNob3AudjEuT3JkZXIaFi5zaG9wLnYxLlVwbG9hZFN1bW1hcnkoARI2CgRDaGF0EhQuc2hvcC52MS5DaGF0TWVzc2FnZRoULnNob3AudjEuQ2hhdE1lc3NhZ2UoATABYgZwcm90bzM="
    )!

    static var registry: Protobuf.Registry { Protobuf.Registry((try? Protobuf.fileSet(descriptorSet)) ?? []) }

    private var channel: Channel?
    private(set) var port = 0
    var reflectionV1 = true
    /// A token it wants as `authorization: Bearer …` metadata, if set.
    var token: String?

    var address: String { "grpc://127.0.0.1:\(port)" }

    func start() async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureAsyncHTTP2Pipeline(mode: .server) { stream in
                        stream.eventLoop.makeCompletedFuture {
                            try NIOAsyncChannel<HTTP2Frame.FramePayload, HTTP2Frame.FramePayload>(wrappingChannelSynchronously: stream)
                        }
                    }
                }
            }
        channel = server.channel
        port = server.channel.localAddress?.port ?? 0
        Task {
            // macOS 13: no discarding task groups — a task a connection, a task a stream.
            try? await server.executeThenClose { connections in
                for try await multiplexer in connections {
                    Task {
                        for try await stream in multiplexer.inbound {
                            Task { try? await self.serve(stream) }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        channel?.close(promise: nil)
    }

    private func serve(_ stream: NIOAsyncChannel<HTTP2Frame.FramePayload, HTTP2Frame.FramePayload>) async throws {
        try await stream.executeThenClose { inbound, outbound in
            var path = ""
            var metadata = HPACKHeaders()
            var pending = ByteBuffer()
            var messages: [Data] = []
            for try await frame in inbound {
                switch frame {
                case .headers(let payload):
                    path = payload.headers.first(name: ":path") ?? ""
                    metadata = payload.headers
                    if payload.endStream { break }
                case .data(let payload):
                    if case .byteBuffer(var chunk) = payload.data { pending.writeBuffer(&chunk) }
                    while pending.readableBytes >= 5, let length = pending.getInteger(at: pending.readerIndex + 1, as: UInt32.self),
                        pending.readableBytes >= 5 + Int(length)
                    {
                        pending.moveReaderIndex(forwardBy: 5)
                        messages.append(Data(pending.readBytes(length: Int(length)) ?? []))
                    }
                    if payload.endStream { break }
                    continue
                default:
                    continue
                }
                if case .headers(let payload) = frame, !payload.endStream { continue }
                break
            }
            func trailersOnly(_ status: Int, _ message: String) async throws {
                let headers: HPACKHeaders = [":status": "200", "content-type": "application/grpc", "grpc-status": "\(status)", "grpc-message": message]
                try await outbound.write(.headers(.init(headers: headers, endStream: true)))
            }
            if let token, metadata.first(name: "authorization") != "Bearer \(token)" {
                return try await trailersOnly(16, "no token")
            }
            let replies: [Data]
            do {
                guard let reply = try self.answer(path, messages) else { return try await trailersOnly(12, "unknown method \(path)") }
                if case .failure(let status, let message) = reply { return try await trailersOnly(status, message) }
                guard case .messages(let out) = reply else { return }
                replies = out
            } catch {
                return try await trailersOnly(3, "\(error)")
            }
            try await outbound.write(.headers(.init(headers: [":status": "200", "content-type": "application/grpc", "x-served-by": "e2e"])))
            for reply in replies {
                var buffer = ByteBuffer()
                buffer.writeInteger(UInt8(0))
                buffer.writeInteger(UInt32(reply.count))
                buffer.writeBytes(reply)
                try await outbound.write(.data(.init(data: .byteBuffer(buffer))))
            }
            try await outbound.write(.headers(.init(headers: ["grpc-status": "0", "x-trailer": "done"], endStream: true)))
        }
    }

    private enum Answer {
        case messages([Data])
        case failure(Int, String)
    }

    private func answer(_ path: String, _ messages: [Data]) throws -> Answer? {
        let registry = Self.registry
        func decode(_ data: Data, _ type: String) throws -> JSONValue { try Protobuf.decode(data, as: type, registry: registry) }
        func encode(_ json: JSONValue, _ type: String) throws -> Data { try Protobuf.encode(json, as: type, registry: registry) }
        func order(_ id: String) -> JSONValue {
            [
                "id": .string(id), "totalCents": "1250", "status": "PAID", "tags": ["gift", "express"], "quantities": ["apple": 3],
                "createdAt": "2026-11-16T10:00:00Z", "customer": ["name": "Ada", "email": "ada@example.com"], "note": "leave at the door",
                "scores": [1, 2, 3], "weight": .double(1.5), "address": "1 Main St", "delta": "-7",
            ]
        }
        switch path {
        case "/shop.v1.Orders/GetOrder":
            let id = try decode(messages.first ?? Data(), ".shop.v1.GetOrderRequest")["id"].string ?? ""
            if id == "missing" { return .failure(5, "no order missing") }
            return .messages([try encode(order(id), ".shop.v1.Order")])
        case "/shop.v1.Orders/ListOrders":
            let limit = try decode(messages.first ?? Data(), ".shop.v1.ListOrdersRequest")["limit"].int ?? 0
            return .messages(try (0..<limit).map { try encode(order("o\($0 + 1)"), ".shop.v1.Order") })
        case "/shop.v1.Orders/UploadOrders":
            let total = try messages.reduce(0) { sum, data in sum + (Int(try decode(data, ".shop.v1.Order")["totalCents"].string ?? "0") ?? 0) }
            return .messages([try encode(["count": .int(messages.count), "totalCents": .string(String(total))], ".shop.v1.UploadSummary")])
        case "/shop.v1.Orders/Chat":
            return .messages(try messages.map { try encode(["text": .string("echo: " + (try decode($0, ".shop.v1.ChatMessage")["text"].string ?? ""))], ".shop.v1.ChatMessage") })
        case GRPCReflection.paths[0] where !reflectionV1:
            return nil
        case GRPCReflection.paths[0], GRPCReflection.paths[1]:
            return .messages(try messages.map(reflect))
        default:
            return nil
        }
    }

    /// A reflection request answered from the descriptor set.
    private func reflect(_ request: Data) throws -> Data {
        var reader = Protobuf.Reader(request)
        var writer = Protobuf.Writer()
        let files = try Self.fileBytes()
        while let (number, wire) = try reader.tag() {
            let text = wire == .lengthDelimited ? String(decoding: try reader.bytes(), as: UTF8.self) : ""
            switch number {
            case 7:
                var list = Protobuf.Writer()
                for name in ["shop.v1.Orders", "grpc.reflection.v1.ServerReflection"] {
                    var service = Protobuf.Writer()
                    service.field(1, string: name)
                    list.field(1, bytes: service.data)
                }
                writer.field(6, bytes: list.data)
            case 4:
                // The file that declares the symbol, alone: its imports are asked for by name.
                var found = Protobuf.Writer()
                if text.hasPrefix("shop.v1."), let shop = files.first(where: { $0.name == "shop.proto" }) { found.field(1, bytes: shop.bytes) }
                writer.field(4, bytes: found.data)
            case 3:
                var found = Protobuf.Writer()
                if let file = files.first(where: { $0.name == text }) { found.field(1, bytes: file.bytes) }
                writer.field(4, bytes: found.data)
            default:
                if wire != .lengthDelimited { try reader.skip(wire) }
            }
        }
        return writer.data
    }

    private static func fileBytes() throws -> [(name: String, bytes: Data)] {
        var reader = Protobuf.Reader(descriptorSet)
        var out: [(String, Data)] = []
        while let (number, wire) = try reader.tag() {
            guard number == 1 else {
                try reader.skip(wire)
                continue
            }
            let bytes = try reader.bytes()
            out.append((try Protobuf.file(bytes).name, bytes))
        }
        return out
    }
}
