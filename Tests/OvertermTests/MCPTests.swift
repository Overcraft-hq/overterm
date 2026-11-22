import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes

/// Where MCP servers are found — the agents' configs, read never written —
/// and the client against servers of the tests' own (E2EMCPServer).
final class MCPConfigTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("home/.codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("shop"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testTheAgentsConfigsAreRead() throws {
        let checkout = folder.appendingPathComponent("shop")
        let home = folder.appendingPathComponent("home")
        try #"""
        {"mcpServers": {
          "files": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "${PWD_ROOT:-/tmp}"], "env": {"TOKEN": "${API_TOKEN}"}},
          "remote": {"type": "http", "url": "https://${HOST}/mcp", "headers": {"Authorization": "Bearer ${API_TOKEN}"}},
          "old": {"type": "sse", "url": "http://localhost:9000/sse"}
        }}
        """#.write(to: checkout.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try """
        {"mcpServers": {"github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/"}},
         "projects": {"\(checkout.path)": {"mcpServers": {"db": {"command": "uvx", "args": ["db-mcp"]}}}, "/elsewhere": {"mcpServers": {"x": {"command": "x"}}}}}
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try """
        model = "o3"
        [mcp_servers.docs]
        command = "npx"
        args = ["-y", "docs-mcp", "--port=3"]
        env = { "KEY" = "v" }

        [mcp_servers."web search"]
        url = "https://search.example/mcp"
        [mcp_servers."web search".env]
        A = "b"

        [profiles.fast]
        model = "x"
        """.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)

        let servers = MCPServerConfig.discover(checkout: checkout, home: home, environment: ["API_TOKEN": "t0k", "HOST": "mcp.example"])
        XCTAssertEqual(servers.map(\.id), ["project:files", "project:old", "project:remote", "claudeLocal:db", "claudeUser:github", "codex:docs", "codex:web search"])
        let files = try XCTUnwrap(servers.first { $0.name == "files" })
        XCTAssertEqual(files.transport, .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], env: ["TOKEN": "t0k"]), "${VAR} and ${VAR:-default}")
        XCTAssertEqual(files.directory, checkout.path, "a project's runs in the checkout")
        XCTAssertEqual(servers.first { $0.name == "remote" }?.transport, .http(url: "https://mcp.example/mcp", headers: ["Authorization": "Bearer t0k"]))
        XCTAssertEqual(servers.first { $0.name == "old" }?.transport.kind, "sse")
        XCTAssertEqual(servers.first { $0.name == "docs" }?.transport, .stdio(command: "npx", args: ["-y", "docs-mcp", "--port=3"], env: ["KEY": "v"]))
        XCTAssertEqual(servers.first { $0.name == "web search" }?.transport.kind, "http")
    }

    func testAddedServersKeepTheirSecretsInTheKeychain() throws {
        let file = folder.appendingPathComponent("MCPServers.json")
        let secrets = MemoryMCPSecrets()
        let added = MCPAddedServers(file: file, secrets: secrets)
        try added.save([
            MCPServerConfig(name: "api", source: .overterm, transport: .http(url: "https://x/mcp", headers: ["Authorization": "Bearer s3cret"])),
            MCPServerConfig(name: "local", source: .overterm, transport: .stdio(command: "node", args: ["server.js"], env: ["KEY": "k3y"])),
        ])
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(written.contains("s3cret") || written.contains("k3y"), written)
        XCTAssertTrue(written.contains("Authorization"), "the header's name is kept")
        let loaded = added.load()
        XCTAssertEqual(loaded.first { $0.name == "api" }?.transport, .http(url: "https://x/mcp", headers: ["Authorization": "Bearer s3cret"]))
        XCTAssertEqual(loaded.first { $0.name == "local" }?.transport, .stdio(command: "node", args: ["server.js"], env: ["KEY": "k3y"]))
        try added.remove(loaded[0])
        XCTAssertEqual(added.load().map(\.name), ["local"])
        XCTAssertNil(secrets.value(server: "overterm:api", name: "Authorization"), "its secret goes with it")
    }

    @MainActor
    func testArgumentsStartFromTheSchema() {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["path": ["type": "string"], "limit": ["type": "integer"], "all": ["type": "boolean"], "mode": ["type": "string", "enum": ["fast", "slow"]], "tags": ["type": "array"]],
        ]
        XCTAssertEqual(MCPInspector.skeleton(schema), ["path": "", "limit": 0, "all": false, "mode": "fast", "tags": []])
        XCTAssertEqual(MCPInspector.skeleton(["type": "string", "default": "x"]), "x")
    }

    func testAResultIsShownByItsContent() {
        let result: JSONValue = ["content": [["type": "text", "text": "hi"], ["type": "image", "data": "aGk=", "mimeType": "image/png"]], "structuredContent": ["n": 1]]
        XCTAssertEqual(MCPContent.parts(result), [.text("hi"), .image(Data("hi".utf8)), .json(["n": 1])])
        XCTAssertEqual(MCPContent.parts(["messages": [["role": "user", "content": ["type": "text", "text": "Hello"]]]]), [.text("user: Hello")])
    }
}

final class MCPClientTests: XCTestCase {
    private final class Traffic: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(MCPClient.Direction, String)] = []
        func add(_ direction: MCPClient.Direction, _ text: String) { lock.withLock { lines.append((direction, text)) } }
        var all: [(MCPClient.Direction, String)] { lock.withLock { lines } }
    }

    func testStdio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-stdio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = E2EMCPServer.writeScript(in: folder)
        let traffic = Traffic()
        let config = MCPServerConfig(name: "fake", source: .overterm, transport: .stdio(command: "/bin/sh", args: [script.path], env: [:]))
        let client = MCPClient(config, environment: ProcessInfo.processInfo.environment) { traffic.add($0, $1) }
        try await client.connect()
        let info = await client.serverInfo
        XCTAssertEqual(info["name"].string, "fake-stdio")
        let instructions = await client.instructions
        XCTAssertEqual(instructions, "A test server.")
        let tools = try await client.list("tools/list", key: "tools")
        XCTAssertEqual(tools.first?["name"].string, "echo")
        let called = try await client.callTool("echo", arguments: ["text": "hello"])
        XCTAssertEqual(MCPContent.parts(called), [.text("echo: hello")])
        let read = try await client.readResource("file:///readme")
        XCTAssertEqual(MCPContent.parts(read), [.text("hello from a resource")])
        let prompt = try await client.getPrompt("greet", arguments: ["who": "Ada"])
        XCTAssertEqual(MCPContent.parts(prompt), [.text("user: Hello there")])
        do {
            _ = try await client.request("nope/nope")
            XCTFail("an unknown method is the server's error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no such method: nope/nope (-32601)")
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(traffic.all.contains { $0.0 == .stderr && $0.1.contains("handled tools/call") }, "its stderr, logged")
        XCTAssertTrue(traffic.all.contains { $0.0 == .sent && $0.1.contains("notifications/initialized") })
        await client.close()
    }

    func testStreamableHTTP() async throws {
        let server = E2EMCPServer()
        try server.start()
        defer { server.stop() }
        server.token = "t0k"
        let unauthorized = MCPClient(
            MCPServerConfig(name: "http", source: .overterm, transport: .http(url: server.url, headers: [:])), environment: [:]
        ) { _, _ in }
        do {
            try await unauthorized.connect()
            XCTFail("no token, no session")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"), error.localizedDescription)
        }
        let client = MCPClient(
            MCPServerConfig(name: "http", source: .overterm, transport: .http(url: server.url, headers: ["Authorization": "Bearer t0k"])),
            environment: [:]
        ) { _, _ in }
        try await client.connect()
        let info = await client.serverInfo
        XCTAssertEqual(info["name"].string, "fake-http")
        // Asked with the session id the server gave: it refuses without one.
        let tools = try await client.list("tools/list", key: "tools")
        XCTAssertEqual(tools.first?["name"].string, "add")
        // Answered as an event stream, a notification before the reply.
        let sum = try await client.callTool("add", arguments: ["a": 2, "b": .double(3.5)])
        XCTAssertEqual(sum["structuredContent"]["sum"], JSONValue.double(5.5))
        await client.close()
    }
}
