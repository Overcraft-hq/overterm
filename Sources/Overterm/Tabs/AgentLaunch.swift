import Foundation

/// What one launch of an agent gets beyond its plain command, each the
/// way that CLI takes it for one launch — nothing written into the user's
/// agent configuration, the pane's token only in its environment
/// (`BrowserBridge`: `OVERTERM_MCP_TOKEN`, named, never written):
///
/// - **The bridge** (Overterm's MCP tools, a path per pane —
///   `OVERTERM_MCP_URL`):
///   - Claude Code: `--mcp-config "$OVERTERM_MCP_CONFIG"`, the pane's file
///     (its header `Bearer ${OVERTERM_MCP_TOKEN}`, which Claude expands).
///   - Codex: `-c mcp_servers.<name>.url=…` and
///     `-c mcp_servers.<name>.bearer_token_env_var="OVERTERM_MCP_TOKEN"`
///     — a config override for that key path only; Codex reads the token
///     from the variable it names.
///   - opencode: `OPENCODE_CONFIG_CONTENT`, inline JSON merged last over
///     the user's config ("settings that do not conflict are preserved"),
///     a `remote` server whose URL and header are `{env:…}` substitutions.
///   - Gemini CLI: `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`, a file of Overterm's
///     (`AgentLaunchFiles`) — the lowest settings layer, its `mcpServers`
///     shallow-merged with the user's — the server an `httpUrl` and a
///     header that are `$VAR` expansions. Only where no real system
///     defaults file exists: one would be replaced (`systemDefaultsInUse`).
///   - pi: none — pi has no MCP, by design (its README: "No MCP").
/// - **Its own attention signal**, where the CLI has a switch for one
///   launch: Gemini CLI's `general.enableNotifications` (OSC 777) in that
///   same defaults file; pi's `-e` extension that writes OSC 777 when a
///   turn ends (`AgentLaunchFiles.piNotify`). Claude Code and Codex send
///   theirs by default (OSC 777 / OSC 9); opencode's is off by default and
///   lives in its TUI config — not changed here; the screen check
///   (`AgentScreenCheck`) covers it.
///
/// Pure: the files' paths and the facts come in.
struct AgentLaunch: Equatable, Sendable {
    /// `NAME='value'` words before the program.
    var environment: [String] = []
    /// After the program: Settings ▸ Agents' arguments, then the handoffs'.
    var arguments: String = ""

    /// `program` (its command, or its resume) with all of it.
    func line(_ program: String) -> String {
        let extra = arguments.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return (environment + [program] + (extra.isEmpty ? [] : [extra])).joined(separator: " ")
    }

    /// The bridge's server name, the same for every agent.
    static let serverName = "overterm-browser"

    /// What the launch needs to know.
    struct Facts: Equatable, Sendable {
        /// Settings ▸ Agents' arguments for the agent.
        var arguments = ""
        /// The bridge serves (a pane made now has `OVERTERM_MCP_*`).
        var serving = false
        /// Gemini CLI's defaults files (`AgentLaunchFiles`): with the
        /// bridge's server, without it.
        var geminiDefaults: (mcp: String, plain: String)? = nil
        /// A real Gemini system defaults file is there: not replaced.
        var geminiSystemDefaultsInUse = false
        /// pi's notify extension.
        var piNotify: String? = nil

        static func == (a: Facts, b: Facts) -> Bool {
            a.arguments == b.arguments && a.serving == b.serving && a.geminiDefaults?.mcp == b.geminiDefaults?.mcp
                && a.geminiDefaults?.plain == b.geminiDefaults?.plain && a.geminiSystemDefaultsInUse == b.geminiSystemDefaultsInUse
                && a.piNotify == b.piNotify
        }
    }

    static func make(_ agent: Agent, _ facts: Facts) -> AgentLaunch {
        var launch = AgentLaunch(arguments: facts.arguments)
        func add(_ words: String) { launch.arguments = (launch.arguments + " " + words).trimmingCharacters(in: .whitespaces) }
        switch agent {
        case .claude:
            if facts.serving { add("--mcp-config \"$\(BrowserBridge.configVariable)\"") }
        case .codex:
            if facts.serving { add(codexBridge) }
        case .opencode:
            if facts.serving { launch.environment.append("OPENCODE_CONFIG_CONTENT=" + quoted(opencodeBridge)) }
        case .gemini:
            if let files = facts.geminiDefaults, !facts.geminiSystemDefaultsInUse {
                launch.environment.append("GEMINI_CLI_SYSTEM_DEFAULTS_PATH=" + quoted(facts.serving ? files.mcp : files.plain))
            }
        case .pi:
            if let notify = facts.piNotify { add("-e " + quoted(notify)) }
        }
        return launch
    }

    /// Codex's two overrides: the URL from the pane's variable (in double
    /// quotes for the shell, TOML's own inside), the token by name.
    static let codexBridge =
        "-c \"mcp_servers.\(serverName).url=\\\"$\(BrowserBridge.urlVariable)\\\"\" -c 'mcp_servers.\(serverName).bearer_token_env_var=\"\(BrowserBridge.tokenVariable)\"'"

    /// opencode's inline config: substitutions only, so it is the same
    /// text for every pane.
    static let opencodeBridge: String = json([
        "mcp": [
            serverName: [
                "type": "remote", "enabled": true, "url": "{env:\(BrowserBridge.urlVariable)}",
                "headers": ["Authorization": "Bearer {env:\(BrowserBridge.tokenVariable)}"],
            ]
        ]
    ])

    /// Gemini CLI's defaults file: notifications on (OSC 777, which
    /// Overterm reads as a desktop notification), and the bridge's server
    /// when `serving`.
    static func geminiDefaults(serving: Bool) -> String {
        var settings: [String: Any] = ["general": ["enableNotifications": true, "notificationMethod": "osc777"]]
        if serving {
            settings["mcpServers"] = [
                serverName: [
                    "httpUrl": "${\(BrowserBridge.urlVariable)}", "headers": ["Authorization": "Bearer ${\(BrowserBridge.tokenVariable)}"],
                ]
            ]
        }
        return json(settings)
    }

    /// pi's extension: OSC 777 when a turn ends — pi's own example
    /// (`examples/extensions/notify.ts`), its one terminal's branch.
    static let piNotifyExtension = """
        // Overterm: tells the terminal when pi is done and waiting (OSC 777).
        // Loaded for one launch with -e; written by Overterm, never edited by hand.
        export default function (pi: any) {
          pi.on("agent_end", async () => {
            process.stdout.write("\\x1b]777;notify;pi;Ready for input\\x07");
          });
        }

        """

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One word for zsh.
    static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The few files of Overterm's an agent's launch names: Gemini CLI's
/// defaults (with and without the bridge), pi's notify extension and
/// Gemini's Terraform deny policy. In Overterm's support folder, 0600, the
/// same text for every pane — no token, no URL: those are the pane's
/// variables, expanded by the agent. Written when a launch needs them.
enum AgentLaunchFiles {
    static var directory: URL { AppEnvironment.supportDirectory.appendingPathComponent("agents", isDirectory: true) }

    /// Gemini CLI's system defaults file when no override names one.
    static let geminiSystemDefaults = "/Library/Application Support/GeminiCli/system-defaults.json"
    /// Where Gemini CLI's administrator policies live: `.toml` there and
    /// it ignores `--admin-policy`.
    static let geminiSystemPolicies = "/Library/Application Support/GeminiCli/policies"

    /// The facts a launch is made from, its files written.
    @MainActor static func facts(for agent: Agent, arguments: String, serving: Bool) -> AgentLaunch.Facts {
        var facts = AgentLaunch.Facts(arguments: arguments, serving: serving)
        switch agent {
        case .gemini:
            facts.geminiSystemDefaultsInUse =
                ProcessInfo.processInfo.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"] != nil
                || FileManager.default.fileExists(atPath: geminiSystemDefaults)
            if let mcp = write("gemini-defaults-mcp.json", AgentLaunch.geminiDefaults(serving: true)),
                let plain = write("gemini-defaults.json", AgentLaunch.geminiDefaults(serving: false))
            {
                facts.geminiDefaults = (mcp, plain)
            }
        case .pi:
            facts.piNotify = write("pi-notify.ts", AgentLaunch.piNotifyExtension)
        case .claude, .codex, .opencode:
            break
        }
        return facts
    }

    /// Gemini's Terraform deny policy (`TerraformAgentGuard.geminiPolicy`).
    static func geminiPolicy() -> String? { write("gemini-terraform-deny.toml", TerraformAgentGuard.geminiPolicy) }

    /// Whether an administrator's Gemini policies are in place.
    static func geminiAdminPoliciesDefined(at folder: String = geminiSystemPolicies) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.hasSuffix(".toml") }
    }

    /// `name` with `text`, 0600, unless it already says exactly that.
    static func write(_ name: String, _ text: String) -> String? {
        let file = directory.appendingPathComponent(name)
        if (try? String(contentsOf: file, encoding: .utf8)) == text { return file.path }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }
}
