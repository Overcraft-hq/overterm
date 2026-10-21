import XCTest

@testable import Overterm

/// A collection on disk: found, its tree in Bruno's order, its environments;
/// and the variables a request sees, layered as Bruno layers them.
final class BrunoCollectionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bruno-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func request(_ name: String, seq: Int, method: String = "get") -> String {
        BruFile.newRequest(name: name, method: method, url: "{{baseUrl}}/\(name.lowercased())", seq: seq).text
    }

    private func makeCollection() throws -> URL {
        let root = dir.appendingPathComponent("api", isDirectory: true)
        try write("api/bruno.json", #"{"version":"1","name":"Shop API","type":"collection","ignore":["node_modules",".git","skip"]}"#)
        try write("api/collection.bru", "vars:pre-request {\n  baseUrl: http://collection\n  shared: c\n}\n")
        try write("api/Health.bru", request("Health", seq: 2))
        try write("api/Login.bru", request("Login", seq: 1, method: "post"))
        try write("api/Users/folder.bru", "meta {\n  name: People\n  seq: 2\n}\n\nvars:pre-request {\n  shared: folder\n}\n")
        try write("api/Users/List.bru", request("List", seq: 1))
        try write("api/Users/Admin/Delete.bru", request("Delete", seq: 1, method: "delete"))
        try write("api/Orders/Create.bru", request("Create", seq: 1, method: "post"))
        try write("api/Orders/folder.bru", "meta {\n  name: Orders\n  seq: 1\n}\n")
        try write("api/environments/Local.bru", "vars {\n  baseUrl: http://localhost:3000\n}\nvars:secret [\n  token\n]\n")
        try write("api/environments/Prod.bru", "vars {\n  baseUrl: https://api.example.com\n}\n")
        try write("api/skip/Hidden.bru", request("Hidden", seq: 1))
        try write("api/environments/../notes.txt", "not a request")
        return root
    }

    func testACollectionIsFoundUnderTheCheckoutButNotInsideNodeModules() throws {
        let root = try makeCollection()
        try write("web/node_modules/pkg/bruno.json", "{}")
        try write("deep/a/b/c/d/e/f/bruno.json", "{}")
        try write("web/coverage/bruno.json", "{}")
        XCTAssertEqual(BrunoCollection.find(in: dir).map(\.standardizedFileURL), [root.standardizedFileURL])
    }

    /// Five folders down, as a monorepo's docs app keeps one.
    func testACollectionFiveFoldersDownIsFound() throws {
        try write("frontend/apps/docs/api/bruno/bruno.json", #"{"version":"1","name":"Deep"}"#)
        XCTAssertEqual(BrunoCollection.find(in: dir).map(\.lastPathComponent), ["bruno"])
    }

    func testTheTreeIsInBrunosOrderFoldersFirstBySeq() throws {
        let collection = try XCTUnwrap(BrunoCollection.load(try makeCollection()))
        XCTAssertEqual(collection.name, "Shop API")
        XCTAssertEqual(collection.tree.children?.map(\.name), ["Orders", "People", "Login", "Health"])
        XCTAssertEqual(collection.tree.children?.map(\.method), [nil, nil, "POST", "GET"])
        XCTAssertEqual(collection.requests.map(\.name), ["Create", "Delete", "List", "Login", "Health"])
        XCTAssertEqual(collection.environments.map(\.name), ["Local", "Prod"])
        XCTAssertNil(collection.tree.find(dir.appendingPathComponent("api/skip/Hidden.bru").standardizedFileURL), "ignored in bruno.json")
    }

    func testTheFoldersAroundARequestStopAtTheCollection() throws {
        let root = try makeCollection()
        let collection = try XCTUnwrap(BrunoCollection.load(root))
        XCTAssertEqual(
            collection.folders(containing: root.appendingPathComponent("Users/Admin/Delete.bru")).map(\.lastPathComponent), ["Users", "Admin"])
        XCTAssertEqual(collection.folders(containing: root.appendingPathComponent("Health.bru")), [])
    }

    func testSearchKeepsTheFoldersAroundWhatMatches() throws {
        let collection = try XCTUnwrap(BrunoCollection.load(try makeCollection()))
        let filtered = try XCTUnwrap(collection.tree.filtered("del"))
        XCTAssertEqual(filtered.allRequests.map(\.name), ["Delete"])
        XCTAssertNil(collection.tree.filtered("nothing like it"))
    }

    // MARK: Variables

    func testTheHigherLayerWins() {
        var vars = APIVariables()
        vars.collection = ["a": "collection", "b": "collection", "c": "collection", "d": "collection", "e": "collection"]
        vars.environment = ["b": "environment", "c": "environment", "d": "environment", "e": "environment"]
        vars.folders = [["c": "outer", "d": "outer", "e": "outer"], ["d": "inner", "e": "inner"]]
        vars.request = ["e": "request"]
        XCTAssertEqual(vars.interpolate("{{a}} {{b}} {{c}} {{d}} {{e}}"), "collection environment outer inner request")
        vars.runtime = ["a": "runtime", "e": "runtime"]
        XCTAssertEqual(vars.interpolate("{{a}} {{e}}"), "runtime runtime")
    }

    func testValuesThatHoldVariablesAreResolvedAndUnknownOnesLeftAsWritten() {
        var vars = APIVariables()
        vars.environment = ["host": "localhost", "baseUrl": "http://{{host}}:{{port}}", "port": "8080"]
        XCTAssertEqual(vars.interpolate("{{ baseUrl }}/users/{{id}}"), "http://localhost:8080/users/{{id}}")
        XCTAssertEqual(vars.unresolved(in: "{{baseUrl}}/{{id}}/{{$guid}}"), ["id"])
        XCTAssertEqual(vars.interpolate("{{unclosed"), "{{unclosed")
    }

    func testProcessEnvAndDynamicVariables() {
        var vars = APIVariables()
        vars.processEnv = ["TOKEN": "secret"]
        XCTAssertEqual(vars.interpolate("Bearer {{process.env.TOKEN}}"), "Bearer secret")
        let guid = vars.interpolate("{{$guid}}")
        XCTAssertNotNil(UUID(uuidString: guid))
        XCTAssertNotEqual(guid, vars.interpolate("{{$guid}}"), "fresh each time")
        XCTAssertEqual(Int(vars.interpolate("{{$timestamp}}")).map { abs($0 - Int(Date().timeIntervalSince1970)) < 5 }, true)
    }

    func testOnlyEnabledPairsCountAndAnAtNameIsLocal() {
        XCTAssertEqual(
            APIVariables.map([BruPair(key: "a", value: "1"), BruPair(key: "b", value: "2", enabled: false), BruPair(key: "@c", value: "3")]),
            ["a": "1", "c": "3"])
    }

    func testDotEnv() {
        let parsed = DotEnv.parse("# comment\nexport A=1\nB = \"two words\"\nC='single'\nD=plain # trailing\n\nbroken\nE=\"line\\nbreak\"\n")
        XCTAssertEqual(parsed, ["A": "1", "B": "two words", "C": "single", "D": "plain", "E": "line\nbreak"])
    }

    @MainActor
    func testSecretsLiveInTheStoreNotTheFile() {
        let store = MemorySecretStore()
        store.set("t0ken", collection: dir, environment: "Local", name: "token")
        XCTAssertEqual(store.value(collection: dir, environment: "Local", name: "token"), "t0ken")
        XCTAssertNil(store.value(collection: dir, environment: "Prod", name: "token"))
    }
}
