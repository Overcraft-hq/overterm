import XCTest

@testable import Overterm

/// The API client's MCP tools, as an agent calls them: on a collection on
/// disk, against a server on this machine.
@MainActor
final class APIMCPTests: XCTestCase {
    private var dir: URL!
    private var server: E2EEchoServer!
    private var workspace: APIWorkspace!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-api-\(UUID().uuidString)", isDirectory: true)
        server = E2EEchoServer()
        try server.start()
        func write(_ path: String, _ text: String) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("api/bruno.json", #"{"version":"1","name":"Agents","type":"collection"}"#)
        try write("api/environments/Local.bru", "vars {\n  base: \(server.baseURL)\n}\n")
        try write("api/environments/Other.bru", "vars {\n  base: http://127.0.0.1:1\n}\n")
        try write(
            "api/Users/List.bru",
            BruFile.newRequest(name: "List users", url: "{{base}}/users", seq: 1).text
                + "\ntests {\n  test(\"ok\", function() { expect(res.status).to.equal(200); });\n}\n")
        try write("api/Broken.bru", BruFile.newRequest(name: "Broken", url: "{{base}}/status/500", seq: 2).text + "\nassert {\n  res.status: eq 200\n}\n")
        workspace = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil)
        workspace.setRoot(dir)
        workspace.loadNow()
        workspace.environmentName = "Local"
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// An agent's first call reads the checkout — off the main thread, and
    /// once: the walk isn't repeated on every call.
    func testAnAgentsFirstCallReadsTheCheckoutOnce() async throws {
        let fresh = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil)
        fresh.setRoot(dir)
        XCTAssertTrue(fresh.collections.isEmpty)
        let listed = text(try await APIMCP.call("api_collections", [:], api: fresh))
        XCTAssertTrue(listed.contains("Agents"), listed)
        XCTAssertEqual(fresh.loadedRoot, dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("api/bruno.json"))
        _ = try await APIMCP.call("api_collections", [:], api: fresh)
        XCTAssertEqual(fresh.collections.count, 1, "not walked again for the same checkout")
    }

    /// Away to another checkout and back, with the panel hidden: the
    /// agent's next call reads it again rather than finding nothing.
    func testBackFromAnotherCheckoutTheCollectionIsReadAgain() async throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        workspace.setRoot(other)
        workspace.setRoot(dir)
        let listed = text(try await APIMCP.call("api_collections", [:], api: workspace))
        XCTAssertTrue(listed.contains("Agents"), listed)
    }

    /// A read now while the panel's is in flight leaves the panel loaded,
    /// not spinning.
    func testAReadNowDoesntStrandThePanelsRead() async throws {
        workspace.visible = true
        workspace.reload()
        XCTAssertTrue(workspace.isLoading)
        workspace.loadNow()
        XCTAssertFalse(workspace.isLoading)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(workspace.isLoading)
        XCTAssertFalse(workspace.collections.isEmpty)
    }

    func testCollectionsListsRequestsByFolderAndTheEnvironments() async throws {
        let listed = text(try await APIMCP.call("api_collections", [:], api: workspace))
        XCTAssertTrue(listed.contains("Collection “Agents”"), listed)
        XCTAssertTrue(listed.contains("Environments: Local, Other — the user picked Local"), listed)
        XCTAssertTrue(listed.contains("Users/\n  GET List users — Users/List.bru"), listed)
        XCTAssertTrue(listed.contains("GET Broken — Broken.bru"), listed)
    }

    func testSendRunsARequestByPathOrNameWithItsTests() async throws {
        let byPath = text(try await APIMCP.call("api_send", ["request": "Users/List.bru"], api: workspace))
        XCTAssertTrue(byPath.contains("200 OK"), byPath)
        XCTAssertTrue(byPath.contains("Tests: 1/1 passed"), byPath)
        XCTAssertTrue(byPath.contains(#""path": "\/users""#), byPath)
        let byName = text(try await APIMCP.call("api_send", ["request": "list users"], api: workspace))
        XCTAssertTrue(byName.contains("200 OK"))
        XCTAssertNotNil(workspace.result(for: dir.appendingPathComponent("api/Users/List.bru")), "the panel shows what the agent ran")
        // Another environment, for this call only.
        // Another environment, for this call only — and never the panel's
        // pick while it waits, which a request sent meanwhile would use.
        let workspace = self.workspace!
        let other = Task { @MainActor in
            let result = try await APIMCP.call("api_send", ["request": "Users/List.bru", "environment": "Other"], api: workspace)
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        await Task.yield()
        XCTAssertEqual(workspace.environmentName, "Local", "not switched while the agent's request is out")
        let manual = await workspace.run(
            BruFile(parsing: try String(contentsOf: dir.appendingPathComponent("api/Users/List.bru"), encoding: .utf8)),
            at: dir.appendingPathComponent("api/Users/List.bru"))
        XCTAssertEqual(manual.response?.status, 200, "a request sent meanwhile uses the user's environment")
        let otherText = try await other.value
        XCTAssertTrue(otherText.contains("Error:"), otherText)
        XCTAssertEqual(workspace.environmentName, "Local")
        do {
            _ = try await APIMCP.call("api_send", ["request": "Nope"], api: workspace)
            XCTFail("an unknown request")
        } catch let error as BrowserMCP.ToolError {
            XCTAssertTrue(error.message.contains("api_collections"))
        }
    }

    /// A path outside the collection — absolute, or climbing out with `..`
    /// — isn't run, though the file is there.
    func testOnlyTheCollectionsOwnRequestsAreRun() async throws {
        let outside = dir.appendingPathComponent("Outside.bru")
        try BruFile.newRequest(name: "Outside", url: "http://127.0.0.1:1/", seq: 1).text.write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertNil(APIMCP.find(outside.path, in: workspace))
        XCTAssertNil(APIMCP.find("../Outside.bru", in: workspace))
        XCTAssertNil(APIMCP.find("../../../etc/hosts", in: workspace))
        XCTAssertNotNil(APIMCP.find("Users/List.bru", in: workspace))
        XCTAssertNotNil(APIMCP.find(dir.appendingPathComponent("api/Users/List.bru").path, in: workspace), "its own, by absolute path")
    }

    /// A secret fills a committed request in, never a one-off an agent
    /// aims at a host of its choosing — and is never repeated back.
    func testSecretsNeverReachAnAgent() async throws {
        let collection = try XCTUnwrap(workspace.collection)
        try workspace.saveSecrets(["token"], values: ["token": "t0p-s3cret"], environment: "Local", in: collection)
        let oneOff = text(try await APIMCP.call("api_request", ["url": "{{base}}/leak?k={{token}}"], api: workspace))
        XCTAssertFalse(oneOff.contains("t0p-s3cret"), oneOff)
        XCTAssertTrue(oneOff.contains("Undefined variables: token"), oneOff)
        try "\(BruFile.newRequest(name: "Authed", url: "{{base}}/me?k={{token}}", seq: 3).text)".write(
            to: dir.appendingPathComponent("api/Authed.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        let sent = text(try await APIMCP.call("api_send", ["request": "Authed"], api: workspace))
        XCTAssertTrue(sent.contains("200 OK"), sent)
        XCTAssertFalse(sent.contains("t0p-s3cret"), "the request had it; the agent's answer doesn't")
        XCTAssertTrue(sent.contains("‹secret›"), sent)
    }

    /// A misspelt environment is an error, never the user's pick instead.
    func testAnUnknownEnvironmentIsRefusedNotReplaced() async throws {
        do {
            _ = try await APIMCP.call("api_send", ["request": "Users/List.bru", "environment": "Prdo"], api: workspace)
            XCTFail("sent on the user's pick")
        } catch let error as BrowserMCP.ToolError {
            XCTAssertEqual(error.message, "“Agents” has no environment “Prdo”. It has: Local, Other.")
        }
        XCTAssertNil(workspace.result(for: dir.appendingPathComponent("api/Users/List.bru")), "nothing was sent")
    }

    /// A second collection's secrets are masked too, and a secret the URL
    /// percent-encoded as well.
    func testEveryCollectionsSecretsAreMaskedEncodedOrNot() async throws {
        let second = dir.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("environments"), withIntermediateDirectories: true)
        try #"{"version":"1","name":"Second"}"#.write(to: second.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        try "vars {\n  base: \(server.baseURL)\n}\nvars:secret [\n  key\n]\n".write(
            to: second.appendingPathComponent("environments/Local.bru"), atomically: true, encoding: .utf8)
        try BruFile.newRequest(name: "Keyed", url: "{{base}}/k?key={{key}}", seq: 1).text.write(
            to: second.appendingPathComponent("Keyed.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        let other = try XCTUnwrap(workspace.collections.first { $0.name == "Second" })
        workspace.secrets.set("a b&c+d", collection: other.root, environment: "Local", name: "key")
        let sent = text(try await APIMCP.call("api_send", ["request": "Keyed", "environment": "Local"], api: workspace))
        XCTAssertTrue(sent.contains("200 OK"), sent)
        XCTAssertFalse(sent.contains("a b&c+d") || sent.contains("a%20b") || sent.contains("b%26c"), sent)
    }

    /// The environment is checked against the request's own collection:
    /// another collection having that name isn't enough.
    func testAnEnvironmentOfAnotherCollectionIsRefused() async throws {
        let second = dir.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("environments"), withIntermediateDirectories: true)
        try #"{"version":"1","name":"Second"}"#.write(to: second.appendingPathComponent("bruno.json"), atomically: true, encoding: .utf8)
        try "vars {\n  base: x\n}\n".write(to: second.appendingPathComponent("environments/Staging.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        do {
            _ = try await APIMCP.call("api_send", ["request": "Users/List.bru", "environment": "Staging"], api: workspace)
            XCTFail("sent on Agents' pick though only Second has Staging")
        } catch let error as BrowserMCP.ToolError {
            XCTAssertEqual(error.message, "“Agents” has no environment “Staging”. It has: Local, Other.")
        }
    }

    /// A one-off request runs in the checkout's collection — never in the
    /// user's own My Requests, even when that is what the panel shows.
    func testAOneOffRequestNeverRunsInMyRequests() async throws {
        let personal = dir.appendingPathComponent("support/My Requests", isDirectory: true)
        let mine = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: personal)
        mine.setRoot(dir)
        mine.loadNow()
        let personalCollection = try XCTUnwrap(mine.collections.first(where: \.isPersonal))
        try "headers {\n  X-Mine: personal\n}\n".write(to: personal.appendingPathComponent("collection.bru"), atomically: true, encoding: .utf8)
        mine.selectedRoot = personalCollection.root
        let sent = text(try await APIMCP.call("api_request", ["url": "{{base}}/one"], api: mine))
        XCTAssertTrue(sent.contains("200 OK"), "the checkout's environment, not My Requests': \(sent)")
        XCTAssertFalse(sent.contains("x-mine"), sent)
        let listed = text(try await APIMCP.call("api_collections", [:], api: mine))
        XCTAssertFalse(listed.contains("My Requests"), listed)
    }

    /// A secret a script set with bru.setEnvVar stays a secret: not filled
    /// into an agent's one-off request, and masked in what it is told.
    func testASecretSetByAScriptStaysASecret() async throws {
        let collection = try XCTUnwrap(workspace.collection)
        try workspace.saveSecrets(["token"], values: ["token": "from-keychain"], environment: "Local", in: collection)
        try BruFile(parsing: BruFile.newRequest(name: "Login", url: "{{base}}/login", seq: 9).text + "\nscript:post-response {\n  bru.setEnvVar(\"token\", \"fresh-from-login\");\n}\n")
            .text.write(to: dir.appendingPathComponent("api/Login.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        _ = try await APIMCP.call("api_send", ["request": "Login"], api: workspace)
        let oneOff = text(try await APIMCP.call("api_request", ["url": "{{base}}/leak?t={{token}}"], api: workspace))
        XCTAssertFalse(oneOff.contains("fresh-from-login"), oneOff)
        try BruFile.newRequest(name: "Uses", url: "{{base}}/uses?t={{token}}", seq: 10).text.write(
            to: dir.appendingPathComponent("api/Uses.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        let committed = text(try await APIMCP.call("api_send", ["request": "Uses"], api: workspace))
        XCTAssertTrue(committed.contains("200 OK"), committed)
        XCTAssertFalse(committed.contains("fresh-from-login"), "filled in, and masked: \(committed)")
    }

    /// A secret copied into a runtime variable by a committed request's
    /// script doesn't ride along in an agent's one-off request.
    func testASecretCopiedIntoARuntimeVariableStaysOut() async throws {
        let collection = try XCTUnwrap(workspace.collection)
        try workspace.saveSecrets(["token"], values: ["token": "k3ychain-only"], environment: "Local", in: collection)
        try (BruFile.newRequest(name: "Copy", url: "{{base}}/c", seq: 9).text + "\nscript:post-response {\n  bru.setVar(\"t\", bru.getEnvVar(\"token\"));\n}\n")
            .write(to: dir.appendingPathComponent("api/Copy.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        _ = try await APIMCP.call("api_send", ["request": "Copy"], api: workspace)
        XCTAssertEqual(workspace.runtimeVariables(collection)["t"], "k3ychain-only", "the committed request has it")
        let oneOff = text(try await APIMCP.call("api_request", ["url": "{{base}}/leak?t={{t}}"], api: workspace))
        XCTAssertTrue(oneOff.contains("Undefined variables: t"), oneOff)
    }

    /// Workspaces of one window share what runs leave behind: an agent's
    /// login survives the user switching tabs.
    func testWorkspacesOfAWindowShareTheirRunsState() async throws {
        let other = APIWorkspace(secrets: MemorySecretStore(), scripts: APIScriptRuntime(), personalRoot: nil, session: workspace.session)
        other.setRoot(dir)
        other.loadNow()
        try (BruFile.newRequest(name: "Login", url: "{{base}}/login", seq: 9).text + "\nscript:post-response {\n  bru.setVar(\"session\", \"s1\");\n}\n")
            .write(to: dir.appendingPathComponent("api/Login.bru"), atomically: true, encoding: .utf8)
        workspace.loadNow()
        other.loadNow()
        _ = try await APIMCP.call("api_send", ["request": "Login"], api: other)
        XCTAssertEqual(workspace.runtimeVariables(try XCTUnwrap(workspace.collection))["session"], "s1")
    }

    /// Two requests out at once: each keeps what it set — the last to end
    /// doesn't write its starting copy over the other's.
    func testOverlappingRequestsKeepEachOthersVariables() async throws {
        let collection = try XCTUnwrap(workspace.collection)
        let slow = "\nscript:pre-request {\n  var t = Date.now(); while (Date.now() - t < 150) {}\n}\n"
        let a = dir.appendingPathComponent("api/A.bru")
        let b = dir.appendingPathComponent("api/B.bru")
        try (BruFile.newRequest(name: "A", url: "{{base}}/a", seq: 7).text + slow + "\nscript:post-response {\n  bru.setVar(\"a\", 1);\n}\n")
            .write(to: a, atomically: true, encoding: .utf8)
        try (BruFile.newRequest(name: "B", url: "{{base}}/b", seq: 8).text + "\nscript:post-response {\n  bru.setVar(\"b\", 2);\n}\n")
            .write(to: b, atomically: true, encoding: .utf8)
        workspace.loadNow()
        let workspace = self.workspace!
        let fileA = BruFile(parsing: try String(contentsOf: a, encoding: .utf8))
        let fileB = BruFile(parsing: try String(contentsOf: b, encoding: .utf8))
        let first = Task { @MainActor in await workspace.run(fileA, at: a) }
        let second = Task { @MainActor in await workspace.run(fileB, at: b) }
        _ = await (first.value, second.value)
        let vars = workspace.runtimeVariables(collection)
        XCTAssertEqual(vars["a"], "1")
        XCTAssertEqual(vars["b"], "2")
    }

    func testAOneOffRequestFillsInTheEnvironment() async throws {
        let sent = text(
            try await APIMCP.call(
                "api_request", ["method": "POST", "url": "{{base}}/things", "headers": ["X-Agent": "yes"], "body": ["a": 1]], api: workspace))
        XCTAssertTrue(sent.contains("POST \(server.baseURL)/things"), sent)
        XCTAssertTrue(sent.contains("\"x-agent\": \"yes\""), sent)
        XCTAssertTrue(sent.contains(#""body": "{\n  \"a\": 1\n}""#) || sent.contains("\\\"a\\\": 1"), sent)
    }

    func testRunReportsEachRequestAndItsFailures() async throws {
        let ran = text(try await APIMCP.call("api_run", [:], api: workspace))
        XCTAssertTrue(ran.hasPrefix("Ran Agents: 2 of 2 requests, 1 passed, 1 failed."), ran)
        XCTAssertTrue(ran.contains("✗ GET Broken — 500"), ran)
        XCTAssertTrue(ran.contains("    ✗ res.status: eq 200"), ran)
        let nestedFile = dir.appendingPathComponent("api/Users/Admin/Nested.bru")
        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BruFile.newRequest(name: "Nested", url: "{{base}}/nested", seq: 1).text.write(to: nestedFile, atomically: true, encoding: .utf8)
        workspace.loadNow()
        let nested = text(try await APIMCP.call("api_run", ["folder": "Users/Admin"], api: workspace))
        XCTAssertTrue(nested.hasPrefix("Ran Admin: 1 of 1 requests"), nested)
        do {
            _ = try await APIMCP.call("api_run", ["folder": "../.."], api: workspace)
            XCTFail("a folder outside the collection")
        } catch is BrowserMCP.ToolError {}
        do {
            _ = try await APIMCP.call("api_run", ["folder": "Users/List.bru"], api: workspace)
            XCTFail("a request is not a folder")
        } catch is BrowserMCP.ToolError {}
        let folder = text(try await APIMCP.call("api_run", ["folder": "Users"], api: workspace))
        XCTAssertTrue(folder.hasPrefix("Ran Users: 2 of 2 requests, 2 passed, 0 failed."), folder)
    }

    /// Over JSON-RPC, as the bridge hands it on: api_ tools reach the API client.
    func testTheServerRoutesAPIToolsToTheAPIClient() async throws {
        let answer = await BrowserMCP.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "api_collections", "arguments": [:]]],
            browser: { nil }, api: { self.workspace })
        let result = try XCTUnwrap(answer?["result"] as? [String: Any])
        if Settings.shared.apiAgentControl {
            XCTAssertTrue(text(result).contains("Agents"))
        } else {
            XCTAssertEqual(result["isError"] as? Bool, true)
        }
        XCTAssertEqual(
            BrowserMCP.offered.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("api_") }.count,
            Settings.shared.apiAgentControl ? 4 : 0)
    }
}
