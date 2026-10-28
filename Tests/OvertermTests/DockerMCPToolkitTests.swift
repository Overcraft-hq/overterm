import Foundation
import XCTest

@testable import Overterm

/// Docker's MCP Toolkit as Overterm's agents see it: what `docker mcp
/// client ls --global --json` says of Claude Code and Codex, and the
/// commands that connect them, typed in a tab.
final class DockerMCPToolkitTests: XCTestCase {
    func testTheAgentsAreReadOffTheToolkitsList() throws {
        let output = """
            {"claude-code":{"displayName":"Claude Code","configName":"claude-code","dockerMCPCatalogConnected":true,"error":null,"isInstalled":true},
             "claude-desktop":{"displayName":"Claude Desktop","dockerMCPCatalogConnected":false,"isInstalled":true},
             "codex":{"displayName":"Codex","dockerMCPCatalogConnected":false,"error":null,"Cfg":null,"isInstalled":false}}
            """
        let clients = try XCTUnwrap(DockerMCPToolkit.parse(output))
        XCTAssertEqual(clients.map(\.id), ["claude-code", "codex"], "Overterm's agents, in its order; the rest left out")
        XCTAssertEqual(clients.map(\.connected), [true, false])
        XCTAssertEqual(clients.map(\.installed), [true, false])
        XCTAssertEqual(DockerMCPToolkit.command(clients[0], connect: false), "docker mcp client disconnect --global claude-code")
        XCTAssertEqual(DockerMCPToolkit.command(clients[1], connect: true), "docker mcp client connect --global codex")
        XCTAssertNil(DockerMCPToolkit.parse("unknown command: docker mcp"))
    }
}
