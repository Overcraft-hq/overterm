#if E2E
import AppKit

/// A gRPC request against the scenario's own server: its methods read by
/// reflection, one of each kind called, a failure's status shown — and the
/// methods read from the collection's .proto by protoc, where there is one.
extension E2ERunner {
    package func apiGRPCScenario() async {
        let server = E2EGRPCServer()
        do { try await server.start() } catch { return check("the gRPC server starts", false, "\(error)") }
        defer { server.stop() }
        let checkout = out("grpc-shop")
        let root = checkout.appendingPathComponent("bruno", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("environments"), withIntermediateDirectories: true)
        try? #"{"version":"1","name":"gRPC API","type":"collection"}"#.write(to: root.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        try? "vars {\n  grpcHost: \(server.address)\n}\n".write(to: root.appendingPathComponent("environments/Local.bru"), atomically: true, encoding: .utf8)
        let api = app.apiWorkspace
        api.setRoot(checkout)
        app.showAPIClient(nil)
        check("the collection is read", await eventually(3) { api.collection?.name == "gRPC API" })
        api.environmentName = "Local"

        guard let draft = try? api.newDraft(in: root, kind: .grpc) else { return check("a gRPC draft", false) }
        app.openInEditor(draft)
        guard let editor = app.editor else { return check("the editor", false) }
        check("New gRPC Request opens as a request", await eventually(3) { editor.active?.url == draft && editor.active?.request?.file.isGRPC == true })
        guard let model = editor.active?.request else { return }
        model.update { $0.grpcURL = "{{grpcHost}}" }
        api.loadGRPCSchema(model.file, at: model.url)
        let reflected = await eventually(5) {
            if case .loaded(let registry)? = api.grpcSchema(model.file, at: model.url) { return registry.paths.count == 4 }
            return false
        }
        check("its methods are read by the server's reflection", reflected, "\(String(describing: api.grpcSchema(model.file, at: model.url)))")
        guard case .loaded(let registry)? = api.grpcSchema(model.file, at: model.url) else { return }

        // Unary.
        model.update { file in
            file.grpcMethod = "/shop.v1.Orders/GetOrder"
            file.grpcMethodType = "unary"
            file.grpcMessages = [.init(name: "message 1", content: #"{"id": "o42"}"#)]
        }
        model.send()
        check("a unary call is answered", await eventually(5) { api.grpcResult(for: model.url)?.status == 0 }, api.grpcResult(for: model.url)?.error ?? "")
        check("its reply read as JSON", api.grpcResult(for: model.url)?.received.first?["id"] == "o42" && api.grpcResult(for: model.url)?.received.first?["status"] == "PAID")
        await pause(0.5)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.captureWindow(to: (png as NSString).appendingPathComponent("grpc.png"))
        }
        // A failure's status, as gRPC names it.
        model.update { $0.grpcMessages = [.init(name: "message 1", content: #"{"id": "missing"}"#)] }
        model.send()
        check("a refused call shows its status", await eventually(5) { api.grpcResult(for: model.url)?.statusName == "NOT_FOUND" }, "\(String(describing: api.grpcResult(for: model.url)))")
        // A server stream.
        model.update { file in
            file.grpcMethod = "/shop.v1.Orders/ListOrders"
            file.grpcMethodType = "server-streaming"
            file.grpcMessages = [.init(name: "message 1", content: #"{"limit": 3}"#)]
        }
        model.send()
        check("a server stream's every message", await eventually(5) { api.grpcResult(for: model.url)?.status == 0 && api.grpcResult(for: model.url)?.received.count == 3 })
        // A client stream: every message sent.
        model.update { file in
            file.grpcMethod = "/shop.v1.Orders/UploadOrders"
            file.grpcMethodType = "client-streaming"
            file.grpcMessages = [.init(name: "message 1", content: #"{"totalCents": "100"}"#), .init(name: "message 2", content: #"{"totalCents": "50"}"#)]
        }
        model.send()
        check(
            "a client stream sends them all", await eventually(5) { api.grpcResult(for: model.url)?.received.first == ["count": 2, "totalCents": "150"] },
            "\(String(describing: api.grpcResult(for: model.url)))")
        check("the file is Bruno's", model.file.text.contains("body:grpc {\n  name: message 2"), model.file.text)
        check("the schema came by reflection, not protoc", registry.messages[".shop.v1.Order"] != nil)

        // The collection's .proto, compiled by protoc — where there is one.
        guard GRPCProtoc.locate() != nil else { return print("E2E SKIP the .proto part: no protoc on this Mac") }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("protos"), withIntermediateDirectories: true)
        let fixture = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Tests/OvertermTests/Fixtures/grpc/shop.proto")
        let proto = root.appendingPathComponent("protos/shop.proto")
        if (try? FileManager.default.copyItem(at: fixture, to: proto)) == nil {
            return print("E2E SKIP the .proto part: the fixture isn't beside the app")
        }
        model.update { $0.protoPath = "protos/shop.proto" }
        api.loadGRPCSchema(model.file, at: model.url)
        let compiled = await eventually(10) {
            if case .loaded(let registry)? = api.grpcSchema(model.file, at: model.url) { return registry.paths.count == 4 }
            return false
        }
        check("with a .proto, its methods come from protoc", compiled, "\(String(describing: api.grpcSchema(model.file, at: model.url)))")
        check("and the protoPath is Bruno's", model.file.text.contains("protoPath: protos/shop.proto"))
    }
}
#endif
