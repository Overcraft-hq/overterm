import XCTest

@testable import Overterm

/// Protocol Buffers by descriptor — the shop.proto fixture's, as protoc made
/// them — and gRPC calls against a server of the tests' own.
final class ProtobufTests: XCTestCase {
    private let registry = E2EGRPCServer.registry

    func testDescriptorsAreRead() throws {
        XCTAssertEqual(
            registry.paths,
            [
                "/shop.v1.Orders/GetOrder", "/shop.v1.Orders/ListOrders", "/shop.v1.Orders/UploadOrders", "/shop.v1.Orders/Chat",
            ])
        let (_, list) = try XCTUnwrap(registry.method(path: "/shop.v1.Orders/ListOrders"))
        XCTAssertEqual(list.kind, "server-streaming")
        XCTAssertEqual(registry.method(path: "/shop.v1.Orders/Chat")?.1.kind, "bidi-streaming")
        XCTAssertEqual(registry.method(path: "/shop.v1.Orders/UploadOrders")?.1.kind, "client-streaming")
        XCTAssertEqual(list.input, ".shop.v1.ListOrdersRequest")
        let order = try XCTUnwrap(registry.messages[".shop.v1.Order"])
        XCTAssertEqual(order.fields.first { $0.name == "total_cents" }?.jsonName, "totalCents")
        XCTAssertNotNil(registry.messages[".shop.v1.Order.Customer"], "a nested message, by its full name")
        XCTAssertEqual(registry.enums[".shop.v1.Status"]?.values.map(\.name), ["STATUS_UNSPECIFIED", "PAID", "SHIPPED"])
        XCTAssertTrue(registry.messages[".shop.v1.Order.QuantitiesEntry"]?.isMapEntry == true)
    }

    func testAMessageRoundTripsAsProto3JSON() throws {
        let order: JSONValue = [
            "id": "o1", "totalCents": "9007199254740993", "status": "SHIPPED", "tags": ["a", "b"], "quantities": ["apple": 3, "pear": 1],
            "createdAt": "2026-11-16T10:00:00.250Z", "customer": ["name": "Ada"], "note": "hi", "scores": [1, -2, 300], "weight": .double(2.5),
            "gift": true, "blob": "AAEC", "pickupPoint": "locker 4", "delta": "-9",
        ]
        let bytes = try Protobuf.encode(order, as: ".shop.v1.Order", registry: registry)
        let back = try Protobuf.decode(bytes, as: ".shop.v1.Order", registry: registry)
        XCTAssertEqual(back["totalCents"], "9007199254740993", "64-bit numbers as strings, whole")
        XCTAssertEqual(back["status"], "SHIPPED", "enums by name")
        XCTAssertEqual(back["quantities"], ["apple": 3, "pear": 1])
        XCTAssertEqual(back["createdAt"], "2026-11-16T10:00:00.250Z")
        XCTAssertEqual(back["customer"], ["name": "Ada"])
        XCTAssertEqual(back["note"], "hi", "a wrapper is its value")
        XCTAssertEqual(back["scores"], [1, -2, 300], "packed")
        XCTAssertEqual(back["weight"], .double(2.5))
        XCTAssertEqual(back["blob"], "AAEC", "bytes in base64")
        XCTAssertEqual(back["pickupPoint"], "locker 4")
        XCTAssertEqual(back["delta"], "-9", "sint64, zigzagged")
        XCTAssertEqual(back["tags"], ["a", "b"])
        // The snake_case name works as well as the JSON one.
        let snake = try Protobuf.decode(try Protobuf.encode(["total_cents": "5"], as: ".shop.v1.Order", registry: registry), as: ".shop.v1.Order", registry: registry)
        XCTAssertEqual(snake["totalCents"], "5")
    }

    func testMistakesAreSaidPlainly() {
        XCTAssertThrowsError(try Protobuf.encode(["nope": 1], as: ".shop.v1.Order", registry: registry)) {
            XCTAssertTrue($0.localizedDescription.contains("has no field “nope”"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Protobuf.encode(["status": "LOST"], as: ".shop.v1.Order", registry: registry)) {
            XCTAssertTrue($0.localizedDescription.contains("STATUS_UNSPECIFIED, PAID, SHIPPED"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try Protobuf.encode(["tags": "x"], as: ".shop.v1.Order", registry: registry))
        XCTAssertThrowsError(try Protobuf.decode(Data([0x0A, 0x05, 0x61]), as: ".shop.v1.Order", registry: registry), "a field longer than the message")
    }

    func testASkeletonToStartFrom() throws {
        let skeleton = Protobuf.skeleton(".shop.v1.Order", registry: registry)
        XCTAssertEqual(skeleton["status"], "STATUS_UNSPECIFIED")
        XCTAssertEqual(skeleton["totalCents"], "0")
        XCTAssertEqual(skeleton["tags"], [])
        XCTAssertEqual(skeleton["quantities"], [:])
        XCTAssertEqual(skeleton["customer"], ["name": "", "email": ""])
        XCTAssertNotNil(skeleton["address"].string, "a oneof's first field")
        XCTAssertEqual(skeleton["pickupPoint"], .null, "and not its second")
        // It encodes as it stands.
        XCTAssertNoThrow(try Protobuf.encode(skeleton, as: ".shop.v1.Order", registry: registry))
    }

    func testAnAddressAsBrunoReadsIt() {
        XCTAssertEqual(GRPCConnection.endpoint("grpc://localhost:50051")?.tls, false)
        XCTAssertEqual(GRPCConnection.endpoint("grpcs://api.example.com")?.port, 443)
        XCTAssertEqual(GRPCConnection.endpoint("localhost:50051")?.tls, false, "this Mac: plain")
        XCTAssertEqual(GRPCConnection.endpoint("api.example.com:8443")?.tls, true, "elsewhere: TLS")
        XCTAssertEqual(GRPCConnection.endpoint("grpcs://edge.example.com/api/grpc")?.prefix, "/api/grpc")
    }

    func testProtocCompilesProtoFiles() throws {
        guard GRPCProtoc.locate() != nil else { throw XCTSkip("no protoc on this Mac") }
        let proto = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/grpc/shop.proto")
        let compiled = try GRPCProtoc.registry(files: [proto], importPaths: [])
        XCTAssertEqual(compiled.paths, registry.paths)
        XCTAssertThrowsError(try GRPCProtoc.registry(files: [proto.deletingLastPathComponent().appendingPathComponent("missing.proto")], importPaths: []))
    }
}

final class GRPCClientTests: XCTestCase {
    private var server: E2EGRPCServer!
    private let registry = E2EGRPCServer.registry

    override func setUp() async throws {
        server = E2EGRPCServer()
        try await server.start()
    }

    override func tearDown() { server.stop() }

    private func connect() async throws -> GRPCConnection {
        try await GRPCConnection.connect(host: "127.0.0.1", port: server.port, tls: false)
    }

    func testCallsOfEveryKind() async throws {
        let connection = try await connect()
        defer { connection.close() }
        let request = try Protobuf.encode(["id": "o42"], as: ".shop.v1.GetOrderRequest", registry: registry)
        let unary = try await connection.call("/shop.v1.Orders/GetOrder", messages: [request])
        XCTAssertEqual(unary.status, 0)
        XCTAssertEqual(try Protobuf.decode(unary.messages[0], as: ".shop.v1.Order", registry: registry)["id"], "o42")
        XCTAssertTrue(unary.headers.contains { $0.name == "x-served-by" })
        XCTAssertTrue(unary.trailers.contains { $0.name == "x-trailer" && $0.value == "done" })

        let listed = try await connection.call(
            "/shop.v1.Orders/ListOrders", messages: [try Protobuf.encode(["limit": 3], as: ".shop.v1.ListOrdersRequest", registry: registry)])
        XCTAssertEqual(listed.messages.count, 3, "a server stream's every message")

        let uploads = try ["10", "20", "30"].map { try Protobuf.encode(["totalCents": .string($0)], as: ".shop.v1.Order", registry: registry) }
        let summary = try await connection.call("/shop.v1.Orders/UploadOrders", messages: uploads)
        XCTAssertEqual(try Protobuf.decode(summary.messages[0], as: ".shop.v1.UploadSummary", registry: registry), ["count": 3, "totalCents": "60"])

        let chat = try await connection.call(
            "/shop.v1.Orders/Chat", messages: try ["hi", "there"].map { try Protobuf.encode(["text": .string($0)], as: ".shop.v1.ChatMessage", registry: registry) })
        XCTAssertEqual(try chat.messages.map { try Protobuf.decode($0, as: ".shop.v1.ChatMessage", registry: registry)["text"] }, ["echo: hi", "echo: there"])

        let missing = try await connection.call(
            "/shop.v1.Orders/GetOrder", messages: [try Protobuf.encode(["id": "missing"], as: ".shop.v1.GetOrderRequest", registry: registry)])
        XCTAssertEqual(missing.status, 5, "trailers-only: the status in the headers")
        XCTAssertEqual(missing.statusName, "NOT_FOUND")
        XCTAssertEqual(missing.statusMessage, "no order missing")
        let unknown = try await connection.call("/shop.v1.Orders/Nope", messages: [Data()])
        XCTAssertEqual(unknown.statusName, "UNIMPLEMENTED")
    }

    func testMetadataReachesTheServer() async throws {
        server.token = "t0k"
        let connection = try await connect()
        defer { connection.close() }
        let request = try Protobuf.encode(["id": "o1"], as: ".shop.v1.GetOrderRequest", registry: registry)
        let refused = try await connection.call("/shop.v1.Orders/GetOrder", messages: [request])
        XCTAssertEqual(refused.statusName, "UNAUTHENTICATED")
        let allowed = try await connection.call("/shop.v1.Orders/GetOrder", metadata: [("Authorization", "Bearer t0k")], messages: [request])
        XCTAssertEqual(allowed.status, 0)
    }

    func testReflectionV1AndV1alpha() async throws {
        let connection = try await connect()
        defer { connection.close() }
        let reflected = try await GRPCReflection.registry(connection, metadata: [])
        XCTAssertEqual(reflected.paths, registry.paths, "the services, and the imports asked for by name")
        XCTAssertNotNil(reflected.messages[".shop.v1.Order"])
        server.reflectionV1 = false
        let older = try await GRPCReflection.registry(connection, metadata: [])
        XCTAssertEqual(older.paths, registry.paths, "v1alpha when v1 is UNIMPLEMENTED")
    }

    func testAnUnreachableServerIsSaid() async throws {
        do {
            _ = try await GRPCConnection.connect(host: "127.0.0.1", port: 1, tls: false)
            XCTFail("nothing listens on port 1")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Couldn't reach 127.0.0.1:1"), error.localizedDescription)
        }
    }
}

/// Bruno's gRPC request, read and written as Bruno writes it, and the plan
/// made of it.
final class GRPCBruTests: XCTestCase {
    static let bruno = """
        meta {
          name: Get order
          type: grpc
          seq: 1
        }

        grpc {
          url: {{grpcHost}}
          method: /shop.v1.Orders/GetOrder
          body: grpc
          auth: inherit
          methodType: unary
        }

        metadata {
          x-tenant: {{tenant}}
          ~x-debug: 1
        }

        body:grpc {
          name: message 1
          content: '''
            {
              "id": "{{orderId}}"
            }
          '''
        }

        body:grpc {
          name: message 2
          content: '''
            {"id": "b"}
          '''
        }

        """

    func testBrunosFileIsReadAndKept() {
        var file = BruFile(parsing: Self.bruno)
        XCTAssertEqual(file.text, Self.bruno, "read and written back byte for byte")
        XCTAssertTrue(file.isRequest && file.isGRPC)
        XCTAssertEqual(file.grpcURL, "{{grpcHost}}")
        XCTAssertEqual(file.grpcMethod, "/shop.v1.Orders/GetOrder")
        XCTAssertEqual(file.grpcMethodType, "unary")
        XCTAssertEqual(file.authMode, .inherit, "a gRPC request's auth is in its grpc block")
        XCTAssertEqual(file.metadata.map(\.key), ["x-tenant", "x-debug"])
        XCTAssertEqual(file.grpcMessages.map(\.name), ["message 1", "message 2"])
        XCTAssertEqual(file.grpcMessages[0].content, "{\n  \"id\": \"{{orderId}}\"\n}")
        // Only the message edited is written anew; the rest keep their bytes.
        file.grpcMessages[1].content = "{\"id\": \"c\"}"
        XCTAssertTrue(file.text.contains("body:grpc {\n  name: message 1\n  content: '''\n    {\n      \"id\": \"{{orderId}}\"\n    }\n  '''\n}"), file.text)
        XCTAssertTrue(
            file.text.contains("body:grpc {\n  name: message 2\n  content: '''\n    {\"id\": \"c\"}\n  '''\n}"),
            "one line, in quotes, as Bruno writes it: \(file.text)")
        XCTAssertEqual(BruFile(parsing: file.text).grpcMessages.count, 2)
        // A new one is Bruno's.
        let made = BruFile.newGRPCRequest(name: "New", url: "grpc://localhost:50051", seq: 3)
        XCTAssertEqual(made.requestType, "grpc")
        XCTAssertEqual(made.grpcMessages.count, 1)
        XCTAssertEqual(BruFile(parsing: made.text).grpcMessages, made.grpcMessages)
    }

    func testThePlanFillsVariablesMetadataAndAuth() throws {
        let file = BruFile(parsing: Self.bruno)
        var context = APIRequestPlan.Context()
        context.collectionFile = BruFile(parsing: "headers {\n  x-app: overterm\n}\n\nauth {\n  mode: bearer\n}\n\nauth:bearer {\n  token: {{token}}\n}\n")
        context.variables.environment = ["grpcHost": "grpc://localhost:5", "tenant": "acme", "orderId": "o7", "token": "t0k"]
        let plan = try GRPCPlan.make(file, context: context, collection: nil)
        XCTAssertEqual(plan.address, "grpc://localhost:5")
        XCTAssertEqual(plan.messages[0], ["id": "o7"])
        XCTAssertEqual(
            plan.metadata.map { "\($0.0)=\($0.1)" }, ["x-app=overterm", "x-tenant=acme", "authorization=Bearer t0k"],
            "the collection's headers, the request's, the inherited auth; a switched-off one left out")
        XCTAssertTrue(plan.protoFiles.isEmpty, "no .proto: reflection")
        var broken = file
        broken.grpcMessages = [.init(name: "bad", content: "{ nope")]
        XCTAssertThrowsError(try GRPCPlan.make(broken, context: context, collection: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("“bad” isn't JSON"), $0.localizedDescription)
        }
    }
}
