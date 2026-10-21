import XCTest

@testable import Overterm

/// What the API panel offers to start from: documents in the checkout, and
/// a server on a tab's port that publishes its OpenAPI document.
@MainActor
final class APIDiscoveryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("discover-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDocumentsInTheCheckoutAreFoundAndOthersNot() throws {
        try write("api/openapi.yaml", "openapi: 3.0.0\ninfo: {title: A}\n")
        try write("docs/shop.postman_collection.json", "{}")
        try write("requests.http", "GET http://x\n")
        try write("swagger.json", "{\"name\": \"not one\"}")
        try write("node_modules/pkg/openapi.json", "{\"openapi\": \"3\"}")
        try write("old/bruno.json", "{}")
        try write("old/openapi.json", "{\"openapi\": \"3\"}")
        // /var is /private/var: compared with both sides' links resolved.
        let base = dir.resolvingSymlinksInPath().path + "/"
        let found = APIDiscovery.findFiles(in: dir).compactMap { source -> String? in
            guard case .file(let url, _) = source else { return nil }
            return url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
        }
        XCTAssertEqual(Set(found), ["api/openapi.yaml", "docs/shop.postman_collection.json", "requests.http"])
    }

    func testAServerPublishingItsDocumentIsFound() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        let found = await APIDiscovery.probeServers([Int(server.port)])
        XCTAssertEqual(found.count, 1)
        guard case .server(let base, let spec, let title) = found.first else { return XCTFail("no server") }
        XCTAssertEqual(base.port, Int(server.port))
        XCTAssertEqual(spec.path, "/openapi.json")
        XCTAssertEqual(title, "Echo")
    }

    func testImportingTheServerMakesACollectionAimedAtIt() async throws {
        let server = E2EEchoServer()
        try server.start()
        defer { server.stop() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil)
        workspace.setRoot(dir)
        let sources = await APIDiscovery.probeServers([Int(server.port)])
        let source = try XCTUnwrap(sources.first)
        let imported = try await workspace.importSource(source)
        XCTAssertEqual(imported.folder.lastPathComponent, "bruno")
        let collection = try XCTUnwrap(BrunoCollection.load(imported.folder))
        XCTAssertEqual(collection.name, "Echo")
        XCTAssertEqual(collection.tree.children?.map(\.name), ["Users", "Health"])
        let local = try XCTUnwrap(workspace.environmentFile("Local", in: collection))
        XCTAssertEqual(local.value("baseUrl", in: "vars"), "http://localhost:\(server.port)")
        XCTAssertNotNil(imported.firstRequest)
    }

    /// With no collection in the checkout, a cURL command becomes a request
    /// of your own — in My Requests, nothing written into the checkout.
    func testACurlCommandGoesToMyRequestsWhenTheCheckoutHasNoCollection() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let personal = dir.appendingPathComponent("support/My Requests", isDirectory: true)
        let checkout = dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: personal)
        workspace.setRoot(checkout)
        workspace.loadNow()
        XCTAssertEqual(workspace.collection?.isPersonal, true, "My Requests, when the checkout has none")
        XCTAssertTrue(workspace.checkoutCollections.isEmpty)
        let file = try workspace.importCurl("curl https://api.example.com/v1/users -H 'Accept: application/json'")
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, personal.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: checkout.path), [], "nothing in the checkout")
        XCTAssertEqual(BruFile(parsing: try String(contentsOf: file, encoding: .utf8)).url, "https://api.example.com/v1/users")
    }

}
