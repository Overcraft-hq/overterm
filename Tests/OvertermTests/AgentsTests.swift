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

/// The agents Overterm knows (`Agent`), how each is started for one launch
/// (`AgentLaunch`), recognised, guarded, and read off the screen.
final class AgentsTests: XCTestCase {
    // MARK: Commands

    func testEachAgentStartsAndResumesWithItsOwnFlags() {
        XCTAssertEqual(Agent.allCases.map(\.command), ["claude", "codex", "opencode", "pi", "gemini"])
        XCTAssertEqual(
            Agent.allCases.map(\.resumeCommand),
            ["claude --continue", "codex resume --last", "opencode --continue", "pi --continue", "gemini --resume latest"])
        XCTAssertEqual(Agent.gemini.resumeCommand(AgentLaunch(arguments: "-m gemini-2.5-pro")), "gemini --resume latest -m gemini-2.5-pro")
        XCTAssertEqual(Set(Agent.allCases.map(\.argumentsKey)).count, Agent.allCases.count)
        XCTAssertEqual(Agent.codex.argumentsKey, "agents.codexArguments", "the key people's settings.json already has")
    }

    func testEveryAgentHasASettingAndTheLegacyKeysStay() {
        for agent in Agent.allCases {
            XCTAssertNotNil(SettingsSchema.all.first { $0.key == agent.argumentsKey }, agent.rawValue)
        }
        XCTAssertEqual(SettingsSchema.legacyKeys["codexArguments"], "agents.codexArguments")
    }

    // MARK: Recognising the process

    func testAgentsAreFoundByNameOrArgv() {
        XCTAssertEqual(Agent.of(processName: "opencode"), .opencode)
        XCTAssertEqual(Agent.of(processName: "pi"), .pi, "pi sets process.title")
        XCTAssertNil(Agent.of(processName: "node"))
        XCTAssertEqual(Agent.of(arguments: ["/Users/b/.opencode/bin/opencode", "--continue"]), .opencode)
        // Gemini CLI: node and its bin script, then the relaunched child.
        XCTAssertEqual(Agent.of(arguments: ["node", "/opt/homebrew/bin/gemini", "-m", "x"]), .gemini)
        XCTAssertEqual(
            Agent.of(arguments: [
                "/opt/homebrew/opt/node/bin/node", "--max-old-space-size=8192",
                "/opt/homebrew/Cellar/gemini-cli/0.40.1/libexec/lib/node_modules/@google/gemini-cli/bundle/gemini.js",
            ]), .gemini)
        XCTAssertEqual(Agent.of(arguments: ["node", "/x/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"]), .pi)
        XCTAssertEqual(Agent.of(arguments: ["node", "/x/lib/node_modules/@openai/codex/bin/codex.js", "resume"]), .codex)
        XCTAssertNil(Agent.of(arguments: ["node", "server.js"]))
        XCTAssertNil(Agent.of(arguments: ["node"]))
        XCTAssertNil(Agent.of(arguments: ["vim", "gemini.md"]), "a file named after it is no agent")
        XCTAssertNil(Agent.of(arguments: ["cat", "/x/@google/gemini-cli/README.md"]), "only an interpreter's script")

        func node(_ pid: pid_t, name: String, _ arguments: [String]) -> ProcessNode {
            ProcessNode(
                identity: ActivityProcessID(pid: pid, start: UInt64(pid)), parent: 1, name: name, maskedCommand: arguments.joined(separator: " "),
                cpuPercent: 0, memory: 0, workingDirectory: nil, argvAgent: Agent.of(arguments: arguments))
        }
        let gemini = node(5, name: "node", ["node", "/opt/homebrew/bin/gemini"])
        XCTAssertTrue(TerminalWindowController.isAgent(gemini))
        XCTAssertEqual(AgentOverviewModel.agent(of: gemini)?.name, "Gemini")
        XCTAssertEqual(AgentOverviewModel.agent(of: node(6, name: "pi", ["pi"])), .pi)
        XCTAssertEqual(Agent.of(name: "bash", argv: nil, command: "node /opt/homebrew/bin/gemini"), .gemini, "by the masked command")
    }

    func testOnlyAgentsThatReadAClipboardImageGetControlV() {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, name: String, words: [String]) {
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: 1, group: pid, name: name))
            process.name = name
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", words)
            kernel.add(process)
        }
        add(7, name: "opencode", words: ["opencode"])
        add(8, name: "node", words: ["node", "/opt/homebrew/bin/gemini"])
        add(9, name: "pi", words: ["pi"])
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 7, kernel: kernel), "opencode's ⌃V isn't established")
        XCTAssertTrue(ImagePaste.agentHasKeyboard(foreground: 8, kernel: kernel), "Gemini CLI under node, by its script")
        XCTAssertTrue(ImagePaste.agentHasKeyboard(foreground: 9, kernel: kernel))
    }

    // MARK: The bridge, per agent

    func testEachAgentGetsTheBridgeTheWayItTakesOne() {
        var facts = AgentLaunch.Facts(arguments: "--model x", serving: true)
        XCTAssertEqual(AgentLaunch.make(.claude, facts).line("claude"), "claude --model x --mcp-config \"$OVERTERM_MCP_CONFIG\"")
        XCTAssertEqual(
            AgentLaunch.make(.codex, facts).line("codex"),
            "codex --model x -c \"mcp_servers.overterm-browser.url=\\\"$OVERTERM_MCP_URL\\\"\" -c 'mcp_servers.overterm-browser.bearer_token_env_var=\"OVERTERM_MCP_TOKEN\"'"
        )
        let opencode = AgentLaunch.make(.opencode, facts)
        XCTAssertEqual(opencode.environment.count, 1)
        XCTAssertTrue(opencode.environment[0].hasPrefix("OPENCODE_CONFIG_CONTENT='"))
        XCTAssertTrue(opencode.line("opencode").hasSuffix(" opencode --model x"))
        XCTAssertEqual(AgentLaunch.make(.pi, facts).line("pi"), "pi --model x", "pi has no MCP")

        facts.serving = false
        XCTAssertEqual(AgentLaunch.make(.claude, facts).line("claude"), "claude --model x")
        XCTAssertEqual(AgentLaunch.make(.codex, facts).line("codex"), "codex --model x")
        XCTAssertEqual(AgentLaunch.make(.opencode, facts).line("opencode"), "opencode --model x")
    }

    func testOpencodesConfigNamesTheTokenAndNeverHoldsIt() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentLaunch.opencodeBridge.utf8)) as? [String: Any])
        let server = try XCTUnwrap((object["mcp"] as? [String: Any])?["overterm-browser"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "remote")
        XCTAssertEqual(server["url"] as? String, "{env:OVERTERM_MCP_URL}")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer {env:OVERTERM_MCP_TOKEN}")
        XCTAssertFalse(AgentLaunch.opencodeBridge.contains("'"), "one single-quoted word")
    }

    func testGeminiGetsADefaultsFileUnlessARealOneIsInstalled() throws {
        var facts = AgentLaunch.Facts(serving: true, geminiDefaults: (mcp: "/s/agents/gemini-defaults-mcp.json", plain: "/s/agents/gemini-defaults.json"))
        XCTAssertEqual(
            AgentLaunch.make(.gemini, facts).line("gemini"), "GEMINI_CLI_SYSTEM_DEFAULTS_PATH='/s/agents/gemini-defaults-mcp.json' gemini")
        facts.serving = false
        XCTAssertEqual(AgentLaunch.make(.gemini, facts).line("gemini"), "GEMINI_CLI_SYSTEM_DEFAULTS_PATH='/s/agents/gemini-defaults.json' gemini")
        facts.geminiSystemDefaultsInUse = true
        XCTAssertEqual(AgentLaunch.make(.gemini, facts).line("gemini"), "gemini", "an administrator's file is never replaced")

        let withServer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentLaunch.geminiDefaults(serving: true).utf8)) as? [String: Any])
        XCTAssertEqual((withServer["general"] as? [String: Any])?["enableNotifications"] as? Bool, true)
        XCTAssertEqual((withServer["general"] as? [String: Any])?["notificationMethod"] as? String, "osc777")
        let server = try XCTUnwrap((withServer["mcpServers"] as? [String: Any])?["overterm-browser"] as? [String: Any])
        XCTAssertEqual(server["httpUrl"] as? String, "${OVERTERM_MCP_URL}")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer ${OVERTERM_MCP_TOKEN}")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentLaunch.geminiDefaults(serving: false).utf8)) as? [String: Any])
        XCTAssertNil(plain["mcpServers"])
    }

    func testPiIsToldToSayWhenItIsDone() {
        let launch = AgentLaunch.make(.pi, AgentLaunch.Facts(piNotify: "/s/My Support/agents/pi-notify.ts"))
        XCTAssertEqual(launch.line("pi --continue"), "pi --continue -e '/s/My Support/agents/pi-notify.ts'")
        XCTAssertTrue(AgentLaunch.piNotifyExtension.contains("\\x1b]777;notify;pi;Ready for input\\x07"))
        XCTAssertTrue(AgentLaunch.piNotifyExtension.contains("pi.on(\"agent_end\""))
    }

    func testTheFilesAreWrittenOnceAndOnlyForTheUser() throws {
        let path = try XCTUnwrap(AgentLaunchFiles.write("test-\(UUID().uuidString).json", "{}"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(path.hasPrefix(AppEnvironment.supportDirectory.path))
        XCTAssertEqual(AgentLaunchFiles.write((path as NSString).lastPathComponent, "{}"), path)
    }

    // MARK: Terraform's guard, per agent

    func testTheGuardIsWhatEachAgentCanHold() {
        XCTAssertEqual(TerraformAgentGuard.launch(for: .opencode, applies: true), .denied)
        XCTAssertEqual(TerraformAgentGuard.launch(for: .gemini, applies: true), .denied)
        XCTAssertEqual(TerraformAgentGuard.launch(for: .gemini, applies: false), .none)
        guard case .notGuarded = TerraformAgentGuard.launch(for: .gemini, applies: true, geminiAdminPolicies: true) else {
            return XCTFail("an administrator's policies make --admin-policy ignored")
        }
        guard case .notGuarded = TerraformAgentGuard.launch(for: .pi, applies: true) else { return XCTFail("pi has no deny") }
        XCTAssertEqual(TerraformAgentGuard.command("pi", launch: .notGuarded("x"), agent: .pi), "pi")

        let opencode = TerraformAgentGuard.command("opencode -m x", launch: .denied, agent: .opencode)
        XCTAssertTrue(opencode.hasPrefix("OPENCODE_PERMISSION='{\"bash\":{"))
        XCTAssertTrue(opencode.hasSuffix("' opencode -m x"))
        XCTAssertEqual(
            TerraformAgentGuard.command("gemini", launch: .denied, agent: .gemini, geminiPolicy: "/s/a b/deny.toml"),
            "gemini --admin-policy '/s/a b/deny.toml'")
        XCTAssertEqual(TerraformAgentGuard.command("gemini", launch: .denied, agent: .gemini, geminiPolicy: nil), "gemini")
    }

    /// opencode's matcher, as its source has it: the whole command, `*`
    /// any run; the last rule matching wins (all ours deny).
    private func opencodeDenies(_ command: String) -> Bool {
        TerraformAgentGuard.opencodeRules.contains { pattern in
            let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return command.range(of: regex, options: .regularExpression) != nil
        }
    }

    func testOpencodesRulesDenyTheWritesAndNotTheReads() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TerraformAgentGuard.opencodePermission.utf8)) as? [String: Any])
        let bash = try XCTUnwrap(object["bash"] as? [String: String])
        XCTAssertEqual(bash.count, TerraformAgentGuard.opencodeRules.count)
        XCTAssertTrue(bash.values.allSatisfy { $0 == "deny" })
        XCTAssertFalse(TerraformAgentGuard.opencodePermission.contains("'"))
        for write in [
            "terraform apply", "terraform apply -auto-approve", "TF_WORKSPACE=prod terraform apply", "terraform -chdir=infra apply",
            "tofu destroy", "terragrunt run --all apply", "terraform state rm aws_s3_bucket.a", "terraform plan -auto-approve",
        ] {
            XCTAssertTrue(opencodeDenies(write), write)
        }
        for read in ["terraform plan", "terraform validate", "terraform fmt -check", "ls terraform"] {
            XCTAssertFalse(opencodeDenies(read), read)
        }
    }

    /// Gemini CLI's matcher, as its source builds it: a prefix as
    /// `"command":"<prefix>` then a space or quote; a regex after
    /// `"command":"`, unanchored at the end.
    private func geminiDenies(_ command: String) throws -> Bool {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["command": command], options: .withoutEscapingSlashes), as: UTF8.self)
        let policy = TerraformAgentGuard.geminiPolicy
        var patterns: [String] = []
        for line in policy.components(separatedBy: "\n") {
            if line.hasPrefix("commandPrefix = [") {
                let prefixes = line.dropFirst("commandPrefix = [".count).dropLast().components(separatedBy: ", ").map { $0.dropFirst().dropLast() }
                patterns += prefixes.map { NSRegularExpression.escapedPattern(for: "\"command\":\"\($0)") + "(?:[\\s\"]|\\\\\")" }
            } else if line.hasPrefix("commandRegex = '") {
                patterns.append("\"command\":\"" + line.dropFirst("commandRegex = '".count).dropLast())
            }
        }
        return patterns.contains { args.range(of: $0, options: .regularExpression) != nil }
    }

    func testGeminisPolicyDeniesTheWritesAndNotTheReads() throws {
        let policy = TerraformAgentGuard.geminiPolicy
        XCTAssertTrue(policy.contains("toolName = \"run_shell_command\""))
        XCTAssertTrue(policy.contains("decision = \"deny\""))
        XCTAssertFalse(policy.contains("\\"), "no escapes for TOML's literal strings")
        for write in ["terraform apply", "TF_WORKSPACE=prod terraform apply", "terraform -chdir=infra apply", "tofu destroy -auto-approve"] {
            XCTAssertTrue(try geminiDenies(write), write)
        }
        for read in ["terraform plan", "terraform validate", "terraform applyx"] {
            XCTAssertFalse(try geminiDenies(read), read)
        }
    }

    func testAnAdministratorsGeminiPoliciesAreSeen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(AgentLaunchFiles.geminiAdminPoliciesDefined(at: folder.path), "none there")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("README"))
        XCTAssertFalse(AgentLaunchFiles.geminiAdminPoliciesDefined(at: folder.path))
        try Data().write(to: folder.appendingPathComponent("org.toml"))
        XCTAssertTrue(AgentLaunchFiles.geminiAdminPoliciesDefined(at: folder.path))
    }

    // MARK: Their questions on screen

    /// Codex's approval, from its snapshot (`approval_modal_exec.snap`):
    /// the command between the question and the choices.
    private let codex = """
          Would you like to run the following command?

          Reason: the migration needs the schema

          $ terraform plan -out tf.plan

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `terraform plan` (p)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
        """

    func testCodexsQuestionIsTheOneAboveItsCommand() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(codex))
        XCTAssertEqual(prompt.question, "Would you like to run the following command?")
        XCTAssertEqual(prompt.preview, ["Reason: the migration needs the schema", "$ terraform plan -out tf.plan"])
        XCTAssertEqual(prompt.default?.key, "1")
        XCTAssertEqual(prompt.deny?.key, "3")
        XCTAssertEqual(prompt.always?.key, "2")
        XCTAssertFalse(prompt.choices.contains(where: \.confirmsOnKey), "Codex takes Return after the number")
        XCTAssertTrue(prompt.isApproval)
        XCTAssertEqual(prompt.summary, "wants to run the following command")
    }

    /// Gemini CLI's, in its round box (ToolConfirmationQueue), the command
    /// in a box of its own; `●` marks the selected choice.
    private let gemini = """
        ╭──────────────────────────────────────────────────────────╮
        │ ?  Shell terraform apply                                  │
        │                                                          │
        │ ╭──────────────────────────────────────────────────────╮ │
        │ │ terraform apply                                      │ │
        │ ╰──────────────────────────────────────────────────────╯ │
        │ Allow execution of [terraform]?                          │
        │                                                          │
        │ ● 1. Allow once                                          │
        │   2. Allow for this session                              │
        │   3. Allow this command for all future sessions          │
        │   4. No, suggest changes (esc)                           │
        ╰──────────────────────────────────────────────────────────╯
        """

    func testGeminisQuestionIsReadInsideItsBox() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(gemini))
        XCTAssertEqual(prompt.question, "Allow execution of [terraform]?")
        XCTAssertEqual(prompt.choices.map(\.label), ["Allow once", "Allow for this session", "Allow this command for all future sessions", "No, suggest changes (esc)"])
        XCTAssertEqual(prompt.default?.key, "1")
        XCTAssertEqual(prompt.deny?.key, "4")
        XCTAssertEqual(prompt.always?.key, "3")
        XCTAssertTrue(prompt.choices.allSatisfy(\.confirmsOnKey), "Gemini takes the digit alone")
        XCTAssertEqual(prompt.summary, "wants to run [terraform]")
        XCTAssertEqual(AgentPrompt.unboxed("│ │ terraform apply  │ │"), " terraform apply  ")
    }

    func testTheScreenCheckTakesApprovalsAndNothingElse() {
        XCTAssertEqual(AgentScreenCheck.question(in: codex), "Would you like to run the following command?")
        XCTAssertEqual(AgentScreenCheck.question(in: gemini), "Allow execution of [terraform]?")
        // An agent's answer that is a numbered list isn't a question.
        XCTAssertNil(AgentScreenCheck.question(in: "Here is the plan:\n1. Add the table\n2. Backfill it\n"))
        XCTAssertNil(AgentScreenCheck.question(in: "Which should I do?\n1. Add the table\n2. Drop it\n"), "nothing marked, nothing that says no")
        XCTAssertNil(AgentScreenCheck.question(in: ""))
        // pi asks nothing; a prompt line is no question.
        XCTAssertNil(AgentScreenCheck.question(in: "π - api\n> "))
    }

    /// opencode's dialog: no numbers, so said and never answered.
    func testOpencodesPermissionDialogIsSeen() {
        let screen = """
            ┃  △ Permission required
            ┃  # Shell command
            ┃  $ terraform apply
            ┃
            ┃  Allow once   Allow always   Reject
            """
        XCTAssertEqual(AgentScreenCheck.question(in: screen), "Permission required — $ terraform apply")
        XCTAssertNil(AgentPrompt.parse(screen), "no buttons for it")
        XCTAssertNil(AgentScreenCheck.question(in: "△ Permission required\n(answered)"), "its buttons gone, the dialog is")
    }

    func testWhichPanesAreLookedAt() {
        XCTAssertTrue(AgentScreenCheck.looks(running: true, signalled: false, visible: false, standing: false))
        XCTAssertFalse(AgentScreenCheck.looks(running: true, signalled: false, visible: true, standing: false), "in front of you")
        XCTAssertFalse(AgentScreenCheck.looks(running: true, signalled: true, visible: false, standing: false), "it says so itself")
        XCTAssertFalse(AgentScreenCheck.looks(running: false, signalled: false, visible: false, standing: false), "at its prompt")
        XCTAssertTrue(AgentScreenCheck.looks(running: false, signalled: true, visible: true, standing: true), "to see a question go")
    }

    func testAScreenQuestionMarksTheTabUntilItGoes() {
        var activity = TabActivity()
        XCTAssertFalse(activity.agentAsked("Allow?", visible: true), "you are looking at it")
        XCTAssertEqual(activity.mark, .none)
        XCTAssertTrue(activity.agentAsked("Allow?", visible: false))
        XCTAssertEqual(activity.mark, .waiting)
        XCTAssertEqual(activity.note, "Allow?")
        XCTAssertFalse(activity.agentAsked("Allow?", visible: false), "the same question: no second notice")
        XCTAssertTrue(activity.agentAnswered())
        XCTAssertEqual(activity.mark, .none)

        // Something else marked it since: that mark stays.
        activity.agentAsked("Allow?", visible: false)
        activity.handle(.notification(title: "Codex", body: "approve"), visible: false)
        XCTAssertTrue(activity.fromScreen, "a notification's mark doesn't outrank a waiting one")
        activity.terraformAsked("wants to apply", visible: false)
        XCTAssertFalse(activity.agentAnswered(), "the Terraform ask's mark is its own")
        XCTAssertEqual(activity.mark, .waiting)
    }

    // MARK: Their own MCP servers, read only

    func testOpencodesAndGeminisServersAreRead() throws {
        let opencode = """
            {
              // JSONC: comments allowed
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "docs": { "type": "remote", "url": "https://mcp.example/{env:REGION}", "headers": { "Authorization": "Bearer {env:API_TOKEN}" } },
                "fs": { "type": "local", "command": ["npx", "-y", "fs-mcp"], "environment": { "ROOT": "/tmp" } },
              },
            }
            """
        let found = MCPServerConfig.opencode(opencode, environment: ["REGION": "eu", "API_TOKEN": "t0k"])
        XCTAssertEqual(found.map(\.name), ["docs", "fs"])
        XCTAssertEqual(found[0].transport, .http(url: "https://mcp.example/eu", headers: ["Authorization": "Bearer t0k"]))
        XCTAssertEqual(found[1].transport, .stdio(command: "npx", args: ["-y", "fs-mcp"], env: ["ROOT": "/tmp"]))
        XCTAssertEqual(found[0].source, .opencode)

        let gemini = """
            {
              "mcpServers": {
                "a": { "httpUrl": "http://localhost:$PORT/mcp", "headers": { "X-Key": "${KEY}" } },
                "b": { "url": "http://localhost:9/sse" },
                "c": { "command": "uvx", "args": ["srv", "${UNSET:-dflt}"], "env": { "T": "$UNSET" } }
              }
            }
            """
        let read = MCPServerConfig.gemini(gemini, environment: ["PORT": "7", "KEY": "k"])
        XCTAssertEqual(read.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(read[0].transport, .http(url: "http://localhost:7/mcp", headers: ["X-Key": "k"]))
        XCTAssertEqual(read[1].transport, .sse(url: "http://localhost:9/sse", headers: [:]))
        XCTAssertEqual(read[2].transport, .stdio(command: "uvx", args: ["srv", "dflt"], env: ["T": "$UNSET"]), "an unset one left as written")
    }

    func testDiscoverReadsThemFromTheHomeItIsGiven() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-mcp-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try #"{"mcp":{"o":{"type":"remote","url":"http://o"}}}"#.write(
            to: home.appendingPathComponent(".config/opencode/opencode.jsonc"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"g":{"httpUrl":"http://g"}}}"#.write(to: home.appendingPathComponent(".gemini/settings.json"), atomically: true, encoding: .utf8)
        let servers = MCPServerConfig.discover(checkout: nil, home: home, environment: [:])
        XCTAssertEqual(servers.map(\.id), ["opencode:o", "gemini:g"])
    }

    func testDockersToolkitIsAskedAboutTheAgentsItKnows() {
        let parsed = DockerMCPToolkit.parse(
            #"{"opencode":{"displayName":"OpenCode","dockerMCPCatalogConnected":true,"isInstalled":true},"gemini":{"displayName":"Gemini","isInstalled":false}}"#)
        XCTAssertEqual(parsed?.map(\.id), ["opencode", "gemini"])
    }
}
