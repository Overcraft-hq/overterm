import XCTest

@testable import Overterm

/// The window's API client: secrets kept out of the committed file, and a
/// path compared the same whether or not it exists yet.
@MainActor
final class APIWorkspaceTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)", isDirectory: true)
        let env = dir.appendingPathComponent("api/environments", isDirectory: true)
        try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        try #"{"version":"1","name":"S"}"#.write(to: dir.appendingPathComponent("api/bruno.json"), atomically: true, encoding: .utf8)
        try "vars {\n  baseUrl: http://x\n  token: committed-by-mistake\n}\n".write(
            to: env.appendingPathComponent("Local.bru"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testASecretLeavesTheFileForTheStore() throws {
        let store = MemorySecretStore()
        let workspace = APIWorkspace(secrets: store, scripts: APIScriptRuntime(), personalRoot: nil)
        workspace.setRoot(dir)
        workspace.loadNow()
        let collection = try XCTUnwrap(workspace.collection)
        try workspace.saveSecrets(["token"], values: ["token": "s3cret"], environment: "Local", in: collection)
        let text = try String(contentsOf: collection.environments[0].url, encoding: .utf8)
        XCTAssertEqual(text, "vars {\n  baseUrl: http://x\n}\n\nvars:secret [\n  token\n]\n")
        XCTAssertFalse(text.contains("s3cret"))
        XCTAssertEqual(store.value(collection: collection.root, environment: "Local", name: "token"), "s3cret")
        XCTAssertEqual(workspace.environmentValues(collection, name: "Local")["token"], "s3cret", "and a request sees it")
        // No longer a secret: its value goes from the store.
        try workspace.saveSecrets([], values: [:], environment: "Local", in: collection)
        XCTAssertNil(store.value(collection: collection.root, environment: "Local", name: "token"))
    }

    /// A request opened from Files, the panel never shown: its collection
    /// is read when it is sent, so its environment applies.
    func testARequestSentWithoutThePanelFindsItsCollection() throws {
        let workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil)
        workspace.setRoot(dir)
        XCTAssertTrue(workspace.collections.isEmpty, "nothing read while the panel is away")
        let url = dir.appendingPathComponent("api/Ping.bru")
        let setup = workspace.setup(for: url, file: BruFile.newRequest(name: "Ping", url: "{{baseUrl}}/ping", seq: 1), environment: .named("Local"))
        XCTAssertEqual(setup.collectionName, "S")
        XCTAssertEqual(setup.environment["baseUrl"], "http://x")
    }

    /// The selected tab moved to another checkout while a request of this
    /// one stayed open: it is still its collection's.
    func testARequestFromAnotherCheckoutKeepsItsCollection() throws {
        let workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        workspace.setRoot(other)
        let url = dir.appendingPathComponent("api/Ping.bru")
        let setup = workspace.setup(for: url, file: BruFile.newRequest(name: "Ping", url: "{{baseUrl}}", seq: 1))
        XCTAssertEqual(setup.collectionName, "S")
        XCTAssertNil(setup.environmentName, "the pick belongs to the collection shown")
        XCTAssertEqual(workspace.setup(for: url, file: BruFile(), environment: .named("Local")).environment["baseUrl"], "http://x")
    }

    func testAPathIsTheSameBeforeAndAfterItExists() throws {
        let made = dir.appendingPathComponent("api/new.bru")
        let before = APIWorkspace.canonicalPath(made)
        try "".write(to: made, atomically: true, encoding: .utf8)
        XCTAssertEqual(before, APIWorkspace.canonicalPath(made))
    }
}
