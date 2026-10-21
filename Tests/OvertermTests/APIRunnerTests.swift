import XCTest

@testable import Overterm

/// A collection run top to bottom, against a server on this machine: a
/// variable one request sets reaching the next, setNextRequest, stop, and
/// the same run written as a bru command.
@MainActor
final class APIRunnerTests: XCTestCase {
    private var dir: URL!
    private var server: E2EEchoServer!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)", isDirectory: true)
        server = E2EEchoServer()
        try server.start()
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func request(_ name: String, seq: Int, url: String, extra: String = "") -> String {
        BruFile.newRequest(name: name, url: url, seq: seq).text + extra
    }

    private func workspace() async throws -> (APIWorkspace, BrunoCollection) {
        let workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil)
        workspace.setRoot(dir)
        workspace.visible = true
        for _ in 0..<100 where workspace.collection == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let collection = try XCTUnwrap(workspace.collection)
        workspace.environmentName = "Local"
        return (workspace, collection)
    }

    private func finish(_ runner: APIRunner) async throws {
        for _ in 0..<250 where runner.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(runner.isRunning, "the run ends")
    }

    func testACollectionRunsInOrderAndOneRequestFeedsTheNext() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"Run","type":"collection"}"#)
        try write("api/environments/Local.bru", "vars {\n  base: \(server.baseURL)\n}\n")
        try write(
            "api/Login.bru",
            request("Login", seq: 1, url: "{{base}}/login", extra: "\nscript:post-response {\n  bru.setVar(\"token\", \"t-\" + res.body.path);\n}\n"))
        try write(
            "api/Me.bru",
            request(
                "Me", seq: 2, url: "{{base}}/me?token={{token}}",
                extra: "\ntests {\n  test(\"token\", function() { expect(res.body.query.token).to.equal(\"t-/login\"); });\n}\n"))
        try write("api/Broken/Missing.bru", request("Missing", seq: 1, url: "{{base}}/status/500"))
        let (workspace, collection) = try await workspace()
        let runner = workspace.runner
        runner.run([collection.tree], title: collection.name, in: collection, workspace: workspace)
        try await finish(runner)
        XCTAssertEqual(runner.entries.map(\.name), ["Missing", "Login", "Me"])
        XCTAssertEqual(runner.entries.map(\.state), [.done, .done, .done])
        XCTAssertEqual(runner.entries.map { $0.result?.response?.status }, [500, 200, 200])
        XCTAssertEqual(runner.entries[2].result?.tests.map(\.passed), [true], "\(runner.entries[2].result?.tests ?? [])")
        XCTAssertEqual(runner.passedCount, 2)
        XCTAssertEqual(runner.failedCount, 1)
        XCTAssertEqual(runner.entries[0].folder, "Broken")
        runner.filter = .failed
        XCTAssertEqual(runner.shown.map(\.name), ["Missing"])
        XCTAssertNotNil(workspace.result(for: collection.root.appendingPathComponent("Me.bru")), "the panel marks what ran")
    }

    /// bru.setVar keeps a JavaScript value as it was — an object, a
    /// number — for the next request's scripts; {{name}} reads it as text.
    func testRuntimeVariablesKeepTheirTypeFromOneRequestToTheNext() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"Types","type":"collection"}"#)
        try write("api/environments/Local.bru", "vars {\n  base: \(server.baseURL)\n}\n")
        try write(
            "api/First.bru",
            request(
                "First", seq: 1, url: "{{base}}/first",
                extra: "\nscript:post-response {\n  bru.setVar(\"echo\", res.body);\n  bru.setVar(\"n\", 5);\n  bru.setVar(\"ok\", true);\n}\n"))
        try write(
            "api/Second.bru",
            request(
                "Second", seq: 2, url: "{{base}}/second?n={{n}}",
                extra: """

                    tests {
                      test("an object", function() { expect(bru.getVar("echo").path).to.equal("/first"); });
                      test("a number", function() { expect(bru.getVar("n")).to.equal(5); });
                      test("a boolean", function() { expect(bru.getVar("ok")).to.be.true; });
                      test("as text in the URL", function() { expect(res.body.query.n).to.equal("5"); });
                    }

                    """))
        let (workspace, collection) = try await workspace()
        let runner = workspace.runner
        runner.run([collection.tree], title: "Types", in: collection, workspace: workspace)
        try await finish(runner)
        let second = try XCTUnwrap(runner.entries.last?.result)
        XCTAssertEqual(second.tests.map(\.passed), [true, true, true, true], "\(second.tests)")
    }

    func testSetNextRequestJumpsAndStopEnds() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"Jump","type":"collection"}"#)
        try write("api/environments/Local.bru", "vars {\n  base: \(server.baseURL)\n}\n")
        try write("api/A.bru", request("A", seq: 1, url: "{{base}}/a", extra: "\nscript:post-response {\n  bru.setNextRequest(\"C\");\n}\n"))
        try write("api/B.bru", request("B", seq: 2, url: "{{base}}/b"))
        try write("api/C.bru", request("C", seq: 3, url: "{{base}}/c", extra: "\nscript:post-response {\n  bru.runner.stopExecution();\n}\n"))
        try write("api/D.bru", request("D", seq: 4, url: "{{base}}/d"))
        let (workspace, collection) = try await workspace()
        let runner = workspace.runner
        runner.run([collection.tree], title: "Jump", in: collection, workspace: workspace)
        try await finish(runner)
        XCTAssertEqual(runner.entries.map(\.state), [.done, .waiting, .done, .waiting], "A, then C, then stop")
    }

    /// A run started while another waits on a response replaces it; the
    /// old one, waking up, mustn't end the new one.
    func testARunReplacedMidRequestLeavesTheNewOneAlone() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"Again","type":"collection"}"#)
        try write("api/environments/Local.bru", "vars {\n  base: \(server.baseURL)\n}\n")
        try write(
            "api/Slow.bru",
            request("Slow", seq: 1, url: "{{base}}/slow", extra: "\nscript:pre-request {\n  var t = Date.now(); while (Date.now() - t < 300) {}\n}\n"))
        try write("api/Next.bru", request("Next", seq: 2, url: "{{base}}/next"))
        let (workspace, collection) = try await workspace()
        let runner = workspace.runner
        let first = runner.run([collection.tree], title: "first", in: collection, workspace: workspace)
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = runner.run([collection.tree], title: "second", in: collection, workspace: workspace)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(runner.isRunning(second) || runner.done == 2, "the old run's end didn't stop the new one")
        XCTAssertFalse(runner.isRunning(first))
        XCTAssertEqual(runner.entries(of: first), [])
        try await finish(runner)
        XCTAssertEqual(runner.title, "second")
        XCTAssertEqual(runner.entries(of: second).map(\.state), [.done, .done])
    }

    /// The environment is fixed when a run starts: picking another midway
    /// doesn't send the rest of it elsewhere.
    func testARunKeepsTheEnvironmentItStartedWith() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"Pinned","type":"collection"}"#)
        try write("api/environments/Local.bru", "vars {\n  base: \(server.baseURL)\n}\n")
        try write("api/environments/Nowhere.bru", "vars {\n  base: http://127.0.0.1:1\n}\n")
        try write(
            "api/A.bru",
            request("A", seq: 1, url: "{{base}}/a", extra: "\nscript:pre-request {\n  var t = Date.now(); while (Date.now() - t < 200) {}\n}\n"))
        try write("api/B.bru", request("B", seq: 2, url: "{{base}}/b"))
        let (workspace, collection) = try await workspace()
        let runner = workspace.runner
        runner.run([collection.tree], title: "Pinned", in: collection, workspace: workspace)
        XCTAssertEqual(runner.environment, "Local")
        try await Task.sleep(nanoseconds: 50_000_000)
        workspace.environmentName = "Nowhere"
        try await finish(runner)
        XCTAssertEqual(runner.entries.map { $0.result?.response?.status }, [200, 200], "both on Local")
        runner.runAgain(workspace: workspace)
        XCTAssertEqual(runner.environment, "Nowhere", "Run Again takes the pick now")
        try await finish(runner)
    }

    /// Started with no environment, a run keeps none: picking one midway
    /// doesn't send the rest there.
    func testARunStartedWithNoEnvironmentKeepsNone() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"None","type":"collection"}"#)
        try write("api/environments/Elsewhere.bru", "vars {\n  base: http://127.0.0.1:1\n}\n")
        try write(
            "api/A.bru",
            request("A", seq: 1, url: "\(server.baseURL)/a", extra: "\nscript:pre-request {\n  var t = Date.now(); while (Date.now() - t < 200) {}\n}\n"))
        try write("api/B.bru", request("B", seq: 2, url: "{{base}}/b"))
        let (workspace, collection) = try await workspace()
        workspace.environmentName = nil
        let runner = workspace.runner
        runner.run([collection.tree], title: "None", in: collection, workspace: workspace)
        XCTAssertNil(runner.environment)
        try await Task.sleep(nanoseconds: 50_000_000)
        workspace.environmentName = "Elsewhere"
        try await finish(runner)
        XCTAssertEqual(runner.entries.last?.result?.plan?.unresolved, ["base"], "still no environment: {{base}} undefined")
    }

    func testTheSameRunAsABruCommand() async throws {
        try write("api/bruno.json", #"{"version":"1","name":"Cli","type":"collection"}"#)
        try write("api/Users/List.bru", request("List", seq: 1, url: "x"))
        let collection = try XCTUnwrap(BrunoCollection.load(dir.appendingPathComponent("api")))
        XCTAssertEqual(APIRunner.bruCommand(for: [collection.tree], in: collection, environment: "Local"), "bru run -r --env 'Local'")
        let folder = try XCTUnwrap(collection.tree.children?.first)
        XCTAssertEqual(APIRunner.bruCommand(for: [folder], in: collection, environment: nil), "bru run 'Users' -r")
        let list = try XCTUnwrap(folder.children?.first)
        XCTAssertEqual(APIRunner.bruCommand(for: [list], in: collection, environment: "it's"), "bru run 'Users/List.bru' --env 'it'\\''s'")
    }
}
