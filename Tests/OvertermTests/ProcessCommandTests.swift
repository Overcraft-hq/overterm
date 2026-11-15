import XCTest

@testable import Overterm

/// A process's command line as Tab Info's tooltip shows it: masked when
/// it is read (`ProcessNode.command`), while what is decided from argv —
/// which agent a process is, the session a Claude resumed — is still read
/// off the words as they were given.
final class ProcessCommandTests: XCTestCase {
    /// A fake password, made at run time: no run of it may be shown.
    private let parts = ["Zq8", "vX2", "mN7", "pL4"]
    private var sentinel: String { parts.joined() }
    /// The same with a space in it.
    private var spaced: String { parts[0] + parts[1] + " " + parts[2] + parts[3] }

    /// Whether `text` holds four characters of the sentinel in a row.
    private func leaks(_ text: String) -> Bool {
        let secret = Array(sentinel)
        return (0...(secret.count - 4)).contains { text.contains(String(secret[$0..<($0 + 4)])) }
    }

    /// `command` as Claude Code runs it: `zsh -c -l "… eval '<command>' …"`.
    private func claude(_ command: String) -> [String] {
        [
            "/bin/zsh", "-c", "-l",
            "source /Users/acme/.claude/shell-snapshots/snapshot-zsh-1731650000000-acme01.sh && eval '\(command)' \\< /dev/null && pwd -P >| /var/folders/ac/T/claude-acme-cwd",
        ]
    }

    private func node(_ arguments: [String], name: String = "acme-tool", pid: pid_t = 20) -> ProcessNode {
        ProcessNode(pid: pid, parent: 1, name: name, arguments: arguments, cpuPercent: 0, memory: 0, workingDirectory: "/work/acme")
    }

    func testAPasswordIsMaskedInEveryForm() {
        let forms: [(String, [String])] = [
            ("a flag's value", ["acme-tool", "--password=\(sentinel)"]),
            ("a flag's value, the next word", ["acme-tool", "--password", sentinel]),
            ("mysql's -p", ["mysql", "-u", "acme", "-p\(sentinel)", "globex"]),
            ("a URL's userinfo", ["acme-tool", "--db", "postgres://acme:\(sentinel)@db.globex.invalid:5432/app"]),
            ("a bearer header", ["curl", "-H", "Authorization: Bearer \(sentinel)", "https://api.globex.invalid/v1"]),
            ("a password with a space in it", ["acme-tool", "--password", spaced]),
            ("a flag's value with a space in it", ["acme-tool", "--password=\(spaced)"]),
            ("mysql's -p with a space in it", ["mysql", "-u", "acme", "-p\(spaced)", "globex"]),
            ("curl's password with a space in it", ["curl", "-uacme:\(spaced)", "https://api.globex.invalid/v1"]),
            ("an assignment with a space in it", ["env", "PGPASSWORD=\(spaced)", "psql"]),
            ("a password that starts with /", ["acme-tool", "--password", "/" + sentinel]),
            ("a token that starts with /, assigned", ["env", "ACME_TOKEN=/\(sentinel)", "acme-tool"]),
            ("a secret key that starts with /, base64", ["rclone", "lsd", "s3:", "--s3-secret-access-key", "/" + [sentinel, "Qx7AcmeGlobexKey", "Rt5Wy9"].joined(separator: "/")]),
            ("Claude Code's command, eval'd", claude("PGPASSWORD=\(sentinel) psql -h db")),
            ("Claude Code's mysql, eval'd", claude("mysql -uroot -p\(sentinel) app")),
            ("Claude Code's redis-cli, eval'd", claude("redis-cli -a \(sentinel) ping")),
            ("a quoted value with a space in it, in a script", ["bash", "-lc", "PGPASSWORD='\(spaced)' psql"]),
        ]
        for (form, arguments) in forms {
            let shown = node(arguments).command
            XCTAssertTrue(shown.contains(Secrets.credentialMask), "\(form): masked — \(shown)")
            XCTAssertFalse(leaks(shown), "\(form): no run of the password — \(shown)")
        }
        // What masking the words before they are joined guards against:
        // joined first, the space splits the password, and half is shown.
        let joinedFirst = Secrets.maskArguments("acme-tool --password \(spaced)".split(separator: " ").map(String.init))
        XCTAssertTrue(leaks(joinedFirst.joined(separator: " ")))
        XCTAssertEqual(node(["acme-tool", "--port", "8080", "serve"]).command, "acme-tool --port 8080 serve", "nothing secret: as it was")
    }

    /// Masked, argv[0] itself changes here — a long relative path reads as
    /// a base64 blob —, and a check reading the shown line would miss the
    /// agent. Each reads `argvAgent`, taken off the raw words.
    func testWhichAgentRunsIsReadOffTheRawWords() {
        let path = ["Tools2024", "AgentBuilds", "CLI", "bin", "claude"].joined(separator: "/")
        let claude = node([path, "--continue", "--api-key", sentinel], name: "acme-node")
        XCTAssertFalse(claude.command.contains("claude"), "argv[0] is masked too: \(claude.command)")
        XCTAssertFalse(leaks(claude.command))
        let codex = node(["/opt/homebrew/bin/codex", "resume", "--last", "--password=\(sentinel)"], name: "node", pid: 30)
        let shell = node(["-zsh"], name: "zsh", pid: 10)
        let editor = node(["vim", "claude.md"], name: "vim", pid: 40)

        XCTAssertTrue(TerminalWindowController.isAgent(claude))
        XCTAssertTrue(TerminalWindowController.isAgent(codex))
        XCTAssertFalse(TerminalWindowController.isAgent(shell))
        XCTAssertFalse(TerminalWindowController.isAgent(editor), "a file named after it is no agent")
        XCTAssertEqual(TerminalWindowController.firstAgent(in: [[shell, editor], [claude]])?.pid, claude.pid)

        XCTAssertEqual(AgentOverviewModel.agent(of: claude), .claude)
        XCTAssertEqual(AgentOverviewModel.agent(of: codex), .codex)
        XCTAssertNil(AgentOverviewModel.agent(of: editor))
        XCTAssertEqual(AgentOverviewModel.agent(of: node(["acme"], name: "claude")), .claude, "by its name")

        XCTAssertEqual(MCPAsker.agentName(claude), "Claude")
        XCTAssertEqual(MCPAsker.agentName(codex), "Codex")
        XCTAssertNil(MCPAsker.agentName(editor))

        XCTAssertEqual(TabInfoModel.runningClaude(in: [shell, editor, claude, codex])?.pid, claude.pid, "Tab Info's Claude session")
        XCTAssertNil(TabInfoModel.runningClaude(in: [shell, editor, codex]))

        let groups: [pid_t: pid_t] = [10: 10, 20: 20, 30: 30, 40: 40]
        XCTAssertEqual(TerminalDrop.program(among: [shell, claude], foreground: 20, groupOf: { groups[$0] }), .claude(directory: "/work/acme"))
        XCTAssertEqual(TerminalDrop.program(among: [shell, claude], foreground: 10, groupOf: { groups[$0] }), .other)
        XCTAssertTrue(ImagePaste.agentHasKeyboard(among: [shell, claude], foreground: 20, groupOf: { groups[$0] }))
        XCTAssertTrue(ImagePaste.agentHasKeyboard(among: [shell, codex], foreground: 30, groupOf: { groups[$0] }))
        XCTAssertFalse(ImagePaste.agentHasKeyboard(among: [shell, editor], foreground: 40, groupOf: { groups[$0] }))
    }

    /// `--fork-session` reads as a secret flag (`SESSION`): masked, the
    /// `-r` after it goes, and Sessions would have lost the resumed id.
    func testTheSessionAClaudeResumedIsReadOffTheRawWords() {
        let id = "8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33"
        let forked = node(["claude", "--fork-session", "-r", id, "--api-key", sentinel], name: "claude")
        XCTAssertFalse(forked.command.split(separator: " ").contains("-r"), "masked: \(forked.command)")
        XCTAssertFalse(leaks(forked.command))
        XCTAssertEqual(forked.resumes, id)

        let session = ClaudeSession(id: id, file: URL(fileURLWithPath: "/tmp/\(id).jsonl"), directory: "/work/acme", updated: Date(), activity: ClaudeActivity())
        let tab = UUID()
        XCTAssertEqual(SessionsModel.running([session], [.init(tab: tab, directory: "/work/acme", resumes: forked.resumes)]), [id: tab])

        XCTAssertEqual(node(["/opt/bin/claude", "--resume", id, "--model", "opus"], name: "acme-node").resumes, id, "a Claude by argv[0]")
        XCTAssertEqual(node(["claude", "-r", id]).resumes, id)
        XCTAssertNil(node(["claude", "--continue"]).resumes)
        XCTAssertNil(node(["claude", "--resume", "x; rm -rf ~"]).resumes, "only an id is kept")
        XCTAssertNil(node(["acme-tool", "-r", "abc123"]).resumes, "only a Claude's")
    }
}
