import Foundation

/// An agent as Docker's MCP Toolkit sees it: whether its config reaches
/// the Toolkit's gateway (`docker mcp gateway run`) — and through it every
/// MCP server the user turned on in Docker.
package struct MCPToolkitClient: Equatable, Identifiable, Sendable {
    /// The Toolkit's name for it: `claude-code`, `codex`, `opencode`, `gemini`.
    package var id: String
    package var name: String
    package var connected: Bool
    package var installed: Bool
}

/// Docker's MCP Toolkit (`docker mcp`), for the agents Overterm runs:
/// `docker mcp client ls --global --json` says whether Claude Code,
/// Codex, opencode and Gemini CLI are connected (the Toolkit's own list
/// has them; pi has no MCP) — it reads their config files, nothing else — and
/// connecting or disconnecting one is a terminal tab, where the user sees
/// it change that agent's config. Pure but for `read`.
package enum DockerMCPToolkit {
    /// The agents Overterm has, in its order.
    package static let agents = ["claude-code", "codex", "opencode", "gemini"]

    package static func parse(_ output: String) -> [MCPToolkitClient]? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        return agents.compactMap { id in
            guard let client = json[id] as? [String: Any] else { return nil }
            return MCPToolkitClient(
                id: id, name: client["displayName"] as? String ?? id, connected: client["dockerMCPCatalogConnected"] as? Bool ?? false,
                installed: client["isInstalled"] as? Bool ?? false)
        }
    }

    /// What connects it everywhere (its user-wide config), or disconnects it.
    package static func command(_ client: MCPToolkitClient, connect: Bool) -> String {
        "docker mcp client \(connect ? "connect" : "disconnect") --global \(DockerCommands.quote(client.id))"
    }

    /// The agents' state, or nil: no Toolkit (Docker Desktop's plugin), or
    /// it didn't answer. An isolated run asks only a scenario's stub.
    package static func read(endpoint: DockerEndpoint?) async -> [MCPToolkitClient]? {
        guard !AppEnvironment.isIsolated || DockerCLI.override != nil, let cli = DockerCLI(endpoint: endpoint) else { return nil }
        guard let output = try? await cli.run(["mcp", "client", "ls", "--global", "--json"], timeout: 15) else { return nil }
        return parse(output)
    }
}
