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

    private func workspaceWithMyRequests() -> (APIWorkspace, URL) {
        let personal = dir.appendingPathComponent("support/api/My Requests", isDirectory: true)
        let workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: personal)
        workspace.setRoot(dir)
        workspace.loadNow()
        return (workspace, personal)
    }

    /// Imported with My Requests picked, a Postman collection lands in My
    /// Requests — it went into the checkout's collection, whatever was picked.
    func testAnImportGoesIntoThePickedCollectionEvenAPersonalOne() throws {
        let (workspace, personal) = workspaceWithMyRequests()
        workspace.selectedRoot = personal
        XCTAssertEqual(workspace.collection?.isPersonal, true)
        let postman: [String: Any] = [
            "info": ["name": "Shop", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"],
            "item": [["name": "List orders", "request": ["method": "GET", "url": ["raw": "https://shop.example.com/orders"]]]],
        ]
        let imported = try workspace.write(try PostmanImporter.make(postman))
        XCTAssertTrue(imported.folder.standardizedFileURL.path.hasPrefix(personal.standardizedFileURL.path), imported.folder.path)
        let checkout = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("api").path).sorted()
        XCTAssertEqual(checkout, ["bruno.json", "environments"], "nothing written into the checkout")
    }

    /// A collection can always be made — in the checkout beside the one it
    /// has, or of your own beside My Requests.
    func testMoreCollectionsCanBeMadeOfBothKinds() throws {
        let (workspace, personal) = workspaceWithMyRequests()
        let first = try workspace.newCheckoutCollection(named: "Payments")
        let second = try workspace.newCheckoutCollection(named: "Search")
        XCTAssertEqual(first.lastPathComponent, "bruno")
        XCTAssertEqual(second.lastPathComponent, "bruno-Search", "a second one beside the first")
        let mine = try workspace.newPersonalCollection(named: "Scratch")
        XCTAssertEqual(mine.deletingLastPathComponent().standardizedFileURL, personal.deletingLastPathComponent().standardizedFileURL)
        workspace.loadNow()
        XCTAssertEqual(Set(workspace.checkoutCollections.map(\.name)), ["S", "Payments", "Search"])
        XCTAssertEqual(Set(workspace.collections.filter(\.isPersonal).map(\.name)), ["My Requests", "Scratch"])
        XCTAssertEqual(workspace.collection?.root.standardizedFileURL, mine.standardizedFileURL, "the new one is picked")
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
