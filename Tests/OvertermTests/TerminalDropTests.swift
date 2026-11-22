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
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

/// What a drop onto a terminal types in. The Claude Code forms follow its
/// CLI (2.1.282): a pasted image path is split off at " /", unquoted or
/// backslash-unescaped, and read if it ends in .png/.jpg/.jpeg/.gif/.webp;
/// on submit it attaches `@path` (`@([^\s]+)\b`) and `@"path"`
/// (`@"([^"]+)"`), cutting a `#…` line range off either.
final class TerminalDropTests: XCTestCase {
    private func file(_ path: String) -> TerminalDrop.Item { .file(URL(fileURLWithPath: path), isDirectory: false) }
    private func folder(_ path: String) -> TerminalDrop.Item { .file(URL(fileURLWithPath: path, isDirectory: true), isDirectory: true) }
    private let claude = TerminalDrop.Program.claude(directory: "/repo")

    // MARK: A shell, or anything but Claude Code

    func testAShellGetsShellQuotedAbsolutePathsAndATrailingSpace() {
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/src/main.swift")], for: .other), "/repo/src/main.swift ", "absolute, even inside the cwd")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/My Notes.md")], for: .other), "'/repo/My Notes.md' ")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/it's.txt")], for: .other), "'/repo/it'\\''s.txt' ")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/çay ağacı.md")], for: .other), "'/repo/çay ağacı.md' ")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/shot.png")], for: .other), "/repo/shot.png ", "an image is a path like any other")
    }

    func testSeveralFilesAndAFolderAreSeparatedBySpaces() {
        XCTAssertEqual(
            TerminalDrop.insertion([file("/repo/a.txt"), folder("/repo/Sources"), file("/tmp/b c.txt")], for: .other),
            "/repo/a.txt /repo/Sources '/tmp/b c.txt' ")
    }

    // MARK: Claude Code

    func testClaudeGetsAnImageAsItsAbsolutePathEscaped() {
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/shot.png")], for: claude), "/repo/shot.png ", "absolute, even inside where it works")
        XCTAssertEqual(
            TerminalDrop.insertion([file("/Users/me/Desktop/Screenshot 2026-09-26 at 10.00.00.png")], for: claude),
            "/Users/me/Desktop/Screenshot\\ 2026-09-26\\ at\\ 10.00.00.png ")
        XCTAssertEqual(TerminalDrop.insertion([file("/a/back\\slash.JPEG")], for: claude), "/a/back\\\\slash.JPEG ", "any case; a backslash doubled")
        XCTAssertEqual(
            TerminalDrop.insertion([file("/a/one.gif"), file("/a/two two.webp")], for: claude), "/a/one.gif /a/two\\ two.webp ",
            "each image its own \" /\"-separated part")
    }

    func testClaudeGetsOtherFilesAsAtMentions() {
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/src/main.swift")], for: claude), "@src/main.swift ", "relative inside where it works")
        XCTAssertEqual(TerminalDrop.insertion([file("/elsewhere/notes.md")], for: claude), "@/elsewhere/notes.md ", "absolute outside")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/with space.md")], for: claude), "@\"with space.md\" ", "quoted, as Claude Code quotes one")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/photo.heic")], for: claude), "@photo.heic ", "not an image Claude Code pastes")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/çay.md")], for: claude), "@çay.md ")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/kahve çekirdeği")], for: claude), "@\"kahve çekirdeği\" ")
    }

    func testClaudeGetsAFolderWithASlash() {
        XCTAssertEqual(TerminalDrop.insertion([folder("/repo/Sources")], for: claude), "@Sources/ ")
        XCTAssertEqual(TerminalDrop.insertion([folder("/repo")], for: claude), "@\"./\" ", "where it works itself")
        XCTAssertEqual(TerminalDrop.insertion([folder("/elsewhere/My Docs")], for: claude), "@\"/elsewhere/My Docs/\" ")
    }

    func testClaudeGetsThePlainPathWhereNoMentionCarriesIt() {
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/issue#12.md")], for: claude), "'/repo/issue#12.md' ", "# starts a line range")
        XCTAssertEqual(TerminalDrop.insertion([file("/repo/say \"hi\".txt")], for: claude), "'/repo/say \"hi\".txt' ")
    }

    /// Claude Code puts each image's [Image #N] before the rest of the
    /// paste: images go last, and the rest starts with a space.
    func testClaudeGetsMentionsFirstThenImages() {
        XCTAssertEqual(
            TerminalDrop.insertion([file("/repo/shot.png"), file("/repo/a.txt"), folder("/repo/lib")], for: claude),
            " @a.txt @lib/ /repo/shot.png ")
    }

    func testOptionGivesPlainPathsInClaudeToo() {
        XCTAssertEqual(
            TerminalDrop.insertion([file("/repo/a.txt"), file("/repo/shot.png"), folder("/repo/My Docs")], for: claude, plainPaths: true),
            "/repo/a.txt /repo/shot.png '/repo/My Docs' ")
    }

    // MARK: Text

    func testTextGoesInAsItIsWithoutLineBreaksAtTheEnds() {
        XCTAssertEqual(TerminalDrop.insertion([.text("https://example.com/a?b=1")], for: .other), "https://example.com/a?b=1 ")
        XCTAssertEqual(TerminalDrop.insertion([.text("git status\n")], for: claude), "git status ", "a drop never presses Return")
        XCTAssertEqual(TerminalDrop.insertion([.text("one"), .text("two words")], for: .other), "one two words ")
        XCTAssertEqual(TerminalDrop.insertion([.text("\n")], for: .other), "")
    }

    // MARK: The forms

    func testMentionQuotesWhereThePlainFormWouldBeCut() {
        XCTAssertEqual(TerminalDrop.claudeMention("src/a_b-c.swift"), "@src/a_b-c.swift")
        XCTAssertEqual(TerminalDrop.claudeMention("a b"), "@\"a b\"")
        XCTAssertEqual(TerminalDrop.claudeMention("x.txt~"), "@\"x.txt~\"", "@\\S+\\b would stop before the ~")
        XCTAssertEqual(TerminalDrop.claudeMention("Screenshot\u{202F}AM.md"), "@\"Screenshot\u{202F}AM.md\"", "a narrow no-break space is whitespace")
        XCTAssertEqual(TerminalDrop.claudeMention("a\"b.txt"), "@a\"b.txt")
        XCTAssertNil(TerminalDrop.claudeMention("\"quoted"))
        XCTAssertNil(TerminalDrop.claudeMention("trailing "))
        XCTAssertNil(TerminalDrop.claudeMention("a#L3.txt"))
    }

    func testImagePathsTheSplitWouldCutAreNotImagePaths() {
        XCTAssertNil(TerminalDrop.claudeImagePath("/a/dir /b.png"))
        XCTAssertNil(TerminalDrop.claudeImagePath("/a/line\nbreak.png"))
        XCTAssertNil(TerminalDrop.claudeImagePath("relative.png"))
        XCTAssertEqual(TerminalDrop.insertion([file("/a/dir /b.png")], for: claude), "@\"/a/dir /b.png\" ", "attached as a file instead")
    }

    /// A process's working directory comes back resolved (/private/var/…),
    /// a dropped file's URL as Finder or the shell spelled it (/var/…).
    func testRelativeToWhereClaudeWorksAcrossSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-drop-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = real.appendingPathComponent("src/a.swift")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: real)
        XCTAssertTrue(real.path.hasPrefix("/var/"), real.path)
        XCTAssertEqual(TerminalDrop.relativePath(file, to: "/private" + real.path), "src/a.swift", "/var and /private/var are one place")
        XCTAssertEqual(TerminalDrop.relativePath(base.appendingPathComponent("link/src/a.swift"), to: real.path), "src/a.swift", "through a link")
        XCTAssertEqual(TerminalDrop.relativePath(URL(fileURLWithPath: "/elsewhere/a"), to: real.path), "/elsewhere/a")
    }

    // MARK: The label

    func testTheLabelSaysWhatADropDoes() {
        XCTAssertEqual(TerminalDrop.label([file("/repo/a.txt")], for: .other), "Drop to insert path")
        XCTAssertEqual(TerminalDrop.label([file("/repo/a.txt"), folder("/repo/lib")], for: .other), "Drop to insert 2 paths")
        XCTAssertEqual(TerminalDrop.label([file("/repo/a.txt")], for: claude), "Drop to insert @ reference")
        XCTAssertEqual(TerminalDrop.label([file("/repo/a.txt"), file("/repo/b.png"), folder("/repo/c")], for: claude), "Drop to insert 3 @ references")
        XCTAssertEqual(TerminalDrop.label([file("/repo/b.png")], for: claude), "Drop to insert path", "an image goes in as its path")
        XCTAssertEqual(TerminalDrop.label([file("/repo/a.txt")], for: claude, plainPaths: true), "Drop to insert path")
        XCTAssertEqual(TerminalDrop.label([.text("https://example.com")], for: claude), "Drop to insert text")
    }

    // MARK: What runs in the pane

    func testClaudeCountsWhenItHasTheTerminal() {
        func node(_ pid: pid_t, _ name: String, _ command: String, _ cwd: String? = nil) -> ProcessNode {
            ProcessNode(identity: ActivityProcessID(pid: pid, start: UInt64(pid)), parent: 1, name: name, maskedCommand: command, cpuPercent: 0, memory: 0, workingDirectory: cwd)
        }
        let shell = node(10, "zsh", "-zsh")
        let claude = node(20, "claude.exe", "claude --continue", "/repo/.worktrees/feat")
        let groups: [pid_t: pid_t] = [10: 10, 20: 20, 30: 30]
        XCTAssertEqual(
            TerminalDrop.program(among: [shell, claude], foreground: 20, groupOf: { groups[$0] }), .claude(directory: "/repo/.worktrees/feat"),
            "by argv[0], where it works")
        XCTAssertEqual(TerminalDrop.program(among: [shell, claude], foreground: 10, groupOf: { groups[$0] }), .other, "in the background: the shell has it")
        XCTAssertEqual(TerminalDrop.program(among: [shell, claude], foreground: nil, groupOf: { _ in nil }), .claude(directory: "/repo/.worktrees/feat"))
        XCTAssertEqual(TerminalDrop.program(among: [shell, node(30, "codex", "codex")], foreground: 30, groupOf: { groups[$0] }), .other)
        XCTAssertEqual(TerminalDrop.program(among: [shell], foreground: 10, groupOf: { groups[$0] }), .other)
    }

    /// The pane's processes from a fake census, its foreground group the
    /// surface's: Claude in the foreground, where it works; the shell's
    /// group, the shell's. A fresh snapshot answers with no tick; a Claude
    /// started since — its group in the foreground, no member of it in the
    /// snapshot — gets one. A pane the census's context doesn't have is
    /// `.other`, nothing read.
    func testWhatRunsInThePaneFromTheCensus() throws {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, group: pid_t? = nil, name: String, words: [String]? = nil, folder: String? = nil)
            -> ActivityProcessID
        {
            let start = UInt64(pid) * 1_000
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, group: group, name: name))
            process.name = name
            process.path = "/opt/acme/bin/\(name)"
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            process.usage = FakeActivityKernel.usage()
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", words ?? [name])
            process.folder = folder
            kernel.add(process)
            return ActivityProcessID(pid: pid, start: start)
        }
        _ = add(1, parent: 0, uid: 0, name: "launchd")
        _ = add(1000, parent: 1, name: "Overterm")
        let login = add(1100, parent: 1000, uid: 0, name: "login")
        _ = add(1101, parent: 1100, name: "zsh")
        _ = add(1102, parent: 1101, name: "node", words: ["claude", "--continue"], folder: "/tmp/acme-checkout/.worktrees/feat")
        let tab = UUID()
        let census = ActivitySampler(kernel: kernel)
        census.appContext = ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: 1000)
        XCTAssertEqual(TerminalDrop.program(pane: "pane-a", foreground: 1102, census: census), .claude(directory: "/tmp/acme-checkout/.worktrees/feat"))
        let tables = kernel.count("processes")
        XCTAssertEqual(TerminalDrop.program(pane: "pane-a", foreground: 1101, census: census), .other, "the shell has it")
        XCTAssertEqual(kernel.count("processes"), tables, "the fresh snapshot answered")
        _ = add(1103, parent: 1101, name: "claude", folder: "/tmp/acme-checkout")
        XCTAssertEqual(TerminalDrop.program(pane: "pane-a", foreground: 1103, census: census), .claude(directory: "/tmp/acme-checkout"), "started since")
        XCTAssertEqual(kernel.count("processes"), tables + 1, "one tick")
        XCTAssertEqual(TerminalDrop.program(pane: "pane-b", foreground: 1103, census: census), .other)
        XCTAssertEqual(kernel.count("processes"), tables + 1, "nothing read for a pane it doesn't have")
    }
}
