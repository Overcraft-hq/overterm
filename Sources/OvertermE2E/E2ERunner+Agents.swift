#if E2E
import AppKit

/// opencode, pi and Gemini CLI as Overterm knows them: in the menus, their
/// launches (the bridge each the way it takes one), their processes
/// recognised, and — none of the stand-ins sending a signal — a question
/// on a pane you aren't looking at marking its tab waiting and reaching
/// the Inbox (`AgentScreenCheck`), the mark gone with the question.
///
/// The agents are stand-ins: system bash run under the agent's name
/// (`exec -a opencode`, `exec -a pi`, `exec -a node … gemini`, as Gemini
/// CLI runs under node), printing the question as each CLI draws it. Never
/// the real CLIs, never the network.
extension E2ERunner {
    package func agentsScenario() async {
        // The menus: one New <Agent> Tab each.
        let fileItems = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu?.items.map(\.title) ?? []
        for agent in Agent.allCases {
            check("File has New \(agent.name) Tab", fileItems.contains("New \(agent.name) Tab"), "\(fileItems)")
        }
        check("the arrow by + lists every agent (Agent.allCases)", Agent.allCases.map(\.name) == ["Claude", "Codex", "opencode", "pi", "Gemini"])

        // Their launches, made and not run.
        check("the bridge listens", await eventually(5) { BrowserBridge.shared.port != nil })
        let serving = BrowserBridge.shared.isServing
        let codex = app.agentCommand(.codex, in: scratch).command
        check("Codex gets the pane's server by -c, the token by name", !serving || codex.contains("bearer_token_env_var=\"OVERTERM_MCP_TOKEN\""), codex)
        let opencode = app.agentCommand(.opencode, in: scratch).command
        check("opencode gets it in OPENCODE_CONFIG_CONTENT", !serving || opencode.contains("OPENCODE_CONFIG_CONTENT='{\"mcp\""), opencode)
        // The scratch folder isn't known to have no production root: the guard holds, failing closed.
        check("and Terraform's writes denied in OPENCODE_PERMISSION", opencode.hasPrefix("OPENCODE_PERMISSION='{\"bash\""), opencode)
        let gemini = app.agentCommand(.gemini, in: scratch).command
        let defaults = AgentLaunchFiles.directory.appendingPathComponent(serving ? "gemini-defaults-mcp.json" : "gemini-defaults.json")
        check("Gemini gets a defaults file of Overterm's", gemini.contains("GEMINI_CLI_SYSTEM_DEFAULTS_PATH='\(defaults.path)' gemini"), gemini)
        check("and its Terraform policy at the admin tier", gemini.contains("--admin-policy '\(AgentLaunchFiles.directory.path)/gemini-terraform-deny.toml'"), gemini)
        let mode = (try? FileManager.default.attributesOfItem(atPath: defaults.path))?[.posixPermissions] as? Int
        let defaultsText = (try? String(contentsOf: defaults, encoding: .utf8)) ?? ""
        check("written for the user alone", mode == 0o600, "\(mode ?? -1)")
        check("the token named, never held", !serving || defaultsText.contains("Bearer ${OVERTERM_MCP_TOKEN}"), defaultsText)
        let pi = app.agentCommand(.pi, in: scratch).command
        check("pi gets its notify extension, and no MCP", pi.contains("-e '") && pi.contains("pi-notify.ts") && !pi.contains("MCP"), pi)

        // The pane's own URL is in its environment.
        if serving {
            app.newTab(in: scratch)
            guard let shell = app.store.selected?.terminal, let port = BrowserBridge.shared.port else { return check("a shell tab", false) }
            check("its shell is up", await eventually(15) { shell.shellReported })
            let url = out("mcp-url")
            shell.insertText("printf %s \"$OVERTERM_MCP_URL\" > \(url.path)")
            shell.pressReturn()
            let want = BrowserBridge.url(port: port, tag: shell.processTag)
            check("a pane's OVERTERM_MCP_URL is its own path", await eventually(8) { (try? String(contentsOf: url, encoding: .utf8)) == want }, want)
        }

        // The stand-ins: each prints its question and waits.
        let bin = scratch.appendingPathComponent("agents-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let geminiQuestion = """
            ╭──────────────────────────────────────╮
            │ ?  Shell npm run migrate             │
            │ Allow execution of [npm]?            │
            │                                      │
            │ ● 1. Allow once                      │
            │   2. Allow for this session          │
            │   3. No, suggest changes (esc)       │
            ╰──────────────────────────────────────╯
            """
        let opencodeQuestion = """
            ┃  △ Permission required
            ┃  # Shell command
            ┃  $ npm run migrate
            ┃
            ┃  Allow once   Allow always   Reject
            """
        try? geminiQuestion.write(to: bin.appendingPathComponent("gemini-question.txt"), atomically: true, encoding: .utf8)
        try? opencodeQuestion.write(to: bin.appendingPathComponent("opencode-question.txt"), atomically: true, encoding: .utf8)
        let answer = bin.appendingPathComponent("gemini-answer")
        let go = bin.appendingPathComponent("opencode-go")
        // Gemini: one key read, then a second for a second — a Return
        // after the digit would come there (status 0); bash 3.2's timeout is 1.
        let geminiScript = """
            cat '\(bin.path)/gemini-question.txt'
            read -rsn1 a; read -rsn1 -t 1 b; s=$?
            printf '%s|%s' "$a" "$s" > '\(answer.path)'
            printf '\\033[2J\\033[H'; echo '◇  Ready'
            while :; do sleep 1; done
            """
        let opencodeScript = """
            cat '\(bin.path)/opencode-question.txt'
            while [ ! -f '\(go.path)' ]; do sleep 0.2; done
            printf '\\033[2J\\033[H'; echo 'OC | done'
            while :; do sleep 1; done
            """
        let piScript = """
            echo 'π - scratch'
            while :; do sleep 1; done
            """
        try? geminiScript.write(to: bin.appendingPathComponent("gemini"), atomically: true, encoding: .utf8)
        try? opencodeScript.write(to: bin.appendingPathComponent("opencode.sh"), atomically: true, encoding: .utf8)
        try? piScript.write(to: bin.appendingPathComponent("pi.sh"), atomically: true, encoding: .utf8)

        func start(_ agent: Agent, _ line: String) async -> Tab? {
            app.newTab(in: scratch, agent: agent, startAgent: false)
            guard let tab = app.store.selected else { return nil }
            _ = await eventually(15) { tab.terminal.shellReported }
            await pause(0.5)
            // In a subshell: the pane's own shell outlives it.
            tab.terminal.insertText("(\(line))")
            tab.terminal.pressReturn()
            return tab
        }
        guard let geminiTab = await start(.gemini, "exec -a node /bin/bash \(bin.path)/gemini"),
            let opencodeTab = await start(.opencode, "exec -a opencode /bin/bash \(bin.path)/opencode.sh"),
            let piTab = await start(.pi, "exec -a pi /bin/bash \(bin.path)/pi.sh")
        else { return check("three agent tabs", false) }
        // None of them in front of you.
        app.newTab(in: scratch)
        let elsewhere = app.store.selected

        // Recognised by their processes.
        for (tab, agent) in [(geminiTab, Agent.gemini), (opencodeTab, .opencode), (piTab, .pi)] {
            let login = SurfaceProcesses.shared.loginPID(of: tab.terminal)
            check(
                "\(agent.name) is recognised in its pane",
                await eventually(10) {
                    login.flatMap {
                        TerminalWindowController.foregroundAgent(login: $0, tag: tab.terminal.processTag, inspector: ProcessInspector())
                    } == agent
                })
        }

        // Their questions mark their tabs, with no signal sent.
        check(
            "Gemini's question marks its tab waiting",
            await eventually(20) { geminiTab.activity.mark == .waiting && geminiTab.activity.note == "Allow execution of [npm]?" },
            "\(geminiTab.activity.mark) \(geminiTab.activity.note ?? "-")")
        check(
            "opencode's dialog marks its tab waiting",
            await eventually(20) { opencodeTab.activity.mark == .waiting && opencodeTab.activity.note == "Permission required — $ npm run migrate" },
            "\(opencodeTab.activity.mark) \(opencodeTab.activity.note ?? "-")")
        check("pi asks nothing: no mark", piTab.activity.mark == .none, "\(piTab.activity.mark)")

        // The Inbox: Gemini's choices as buttons, opencode's said only.
        app.refreshInbox()
        let geminiEntry = app.inbox.entries.first { $0.id == geminiTab.id }
        let opencodeEntry = app.inbox.entries.first { $0.id == opencodeTab.id }
        check("both are in the Inbox", geminiEntry != nil && opencodeEntry != nil, "\(app.inbox.entries.map(\.title))")
        check(
            "Gemini's choices are read", geminiEntry?.prompt?.choices.map(\.label) == ["Allow once", "Allow for this session", "No, suggest changes (esc)"],
            "\(geminiEntry?.prompt?.choices.map(\.label) ?? [])")
        check("and its card says what it asks", geminiEntry?.headline.contains("wants to run [npm]") == true, geminiEntry?.headline ?? "")
        check("opencode's has no buttons, only its words", opencodeEntry?.prompt == nil && opencodeEntry?.note == "Permission required — $ npm run migrate")

        // Answered from the Inbox: the digit alone, as Gemini takes it.
        if let choice = geminiEntry?.prompt?.default {
            app.answer(choice, in: geminiTab.id)
        }
        check(
            "Gemini gets the digit and no Return", await eventually(8) { (try? String(contentsOf: answer, encoding: .utf8)).map { $0.hasPrefix("1|") && $0 != "1|0" } ?? false },
            (try? String(contentsOf: answer, encoding: .utf8)) ?? "nothing")
        check("its question gone, the mark goes", await eventually(15) { geminiTab.activity.mark == .none && geminiTab.screenAsk == nil })

        // opencode answered in its tab (here: the stand-in moves on).
        try? Data().write(to: go)
        check("opencode's too", await eventually(15) { opencodeTab.activity.mark == .none && opencodeTab.screenAsk == nil })
        if let elsewhere { app.store.select(elsewhere) }
    }
}
#endif
