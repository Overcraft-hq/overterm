import AppKit
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

@MainActor
final class ImagePasteTests: XCTestCase {
    /// A pasteboard of the test's own: never the user's clipboard.
    private func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("overterm-test-\(UUID())")) }

    func testOnlyAnImageCounts() {
        let image = board()
        image.clearContents()
        image.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        XCTAssertTrue(ImagePaste.clipboardHasOnlyImage(image))

        let both = board()
        both.clearContents()
        both.setData(Data([0x89]), forType: .png)
        both.setString("a caption", forType: .string)
        XCTAssertFalse(ImagePaste.clipboardHasOnlyImage(both), "text pastes as text")

        let text = board()
        text.clearContents()
        text.setString("hello", forType: .string)
        XCTAssertFalse(ImagePaste.clipboardHasOnlyImage(text))
    }

    /// The pane's foreground group's members and their names (7.7): an
    /// agent by the name it runs as, or by argv's first word when the name
    /// doesn't say (Claude Code as `node`); Codex too; a group of shells,
    /// another user's process named claude, no group at all: no agent.
    func testAnAgentInTheForegroundGroupHasTheKeyboard() {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, group: pid_t, uid: uid_t = 501, name: String, words: [String]) {
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: 1, uid: uid, group: group, name: name))
            process.name = name
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", words)
            kernel.add(process)
        }
        add(10, group: 10, name: "zsh", words: ["-zsh"])
        add(20, group: 20, name: "node", words: ["claude", "--resume", "acme"])
        add(21, group: 20, name: "acme-helper", words: ["acme-helper"])
        add(30, group: 30, name: "codex", words: ["codex"])
        add(40, group: 40, uid: 0, name: "claude", words: ["claude"])
        // `sudo claude`: real uid the user's, effective root's — or the
        // reverse, a setuid one: not the user's alone.
        let sudo = FakeActivityKernel.record(pid: 41, start: 41_000, parent: 1, uid: 0, realUID: 501, group: 41, name: "claude")
        var asRoot = FakeActivityKernel.Process(record: sudo)
        asRoot.name = "claude"
        kernel.add(asRoot)
        XCTAssertTrue(ImagePaste.agentHasKeyboard(foreground: 20, kernel: kernel), "by argv[0]")
        XCTAssertTrue(ImagePaste.agentHasKeyboard(foreground: 30, kernel: kernel), "Codex too, by its name")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 10, kernel: kernel), "the shell has it")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 40, kernel: kernel), "another user's is never an agent")
        XCTAssertNotNil(kernel.name(of: 40), "proc_name answers for root's too, as the live call does")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 41, kernel: kernel), "nor one that runs as root")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: nil, kernel: kernel))
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 99, kernel: kernel), "an empty group")
        kernel.resetCounts()
        _ = ImagePaste.agentHasKeyboard(foreground: 30, kernel: kernel)
        XCTAssertEqual(kernel.count("processes"), 0, "no table read")
        XCTAssertEqual(kernel.count("arguments"), 0, "its name said it: no argv read")
    }

    /// A group whose members' names can't host an agent — a shell, vim,
    /// every worker of a build — reads no argv inside the key equivalent;
    /// one that may (`node`) is read for argv[0] alone, and only so many a
    /// paste.
    func testOnlyAHostsArgumentsAreRead() {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, group: pid_t, name: String, words: [String]) {
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: 1, group: group, name: name))
            process.name = name
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", words)
            kernel.add(process)
        }
        add(10, group: 10, name: "zsh", words: ["-zsh"])
        add(11, group: 10, name: "vim", words: ["vim", "acme.txt"])
        for pid in 12..<40 { add(pid_t(pid), group: 10, name: "acme-cc", words: ["acme-cc", "-c", "globex.c"]) }
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 10, kernel: kernel))
        XCTAssertEqual(kernel.count("arguments"), 0, "a shell's, vim's or a build's group reads no argv")
        XCTAssertEqual(kernel.count("argumentsLength"), 0)

        for pid in 50..<60 { add(pid_t(pid), group: 50, name: "node", words: ["node", "fake-server.js"]) }
        kernel.resetCounts()
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: 50, kernel: kernel, argumentReads: 4))
        XCTAssertEqual(kernel.count("argumentsLength"), 4, "at most four argv reads a paste")

        add(70, group: 70, name: "2.1.0", words: ["claude"])
        add(80, group: 80, name: "codex-aarch64-apple-darwin", words: ["/opt/acme/bin/codex", "--sandbox"])
        XCTAssertTrue(ImagePaste.agentHasKeyboard(foreground: 70, kernel: kernel), "a version's name hosts Claude Code")
        XCTAssertTrue(ImagePaste.agentHasKeyboard(foreground: 80, kernel: kernel), "argv[0]'s file")
        XCTAssertTrue(ImagePaste.mayHost("node"))
        XCTAssertFalse(ImagePaste.mayHost("zsh"))
        XCTAssertFalse(ImagePaste.mayHost("..."))
    }

    /// The same of real processes, the test's own children each in a group
    /// of its own: a program named `node` — built here: the name a process
    /// runs as is its executable file's, never a link's, and a copy of a
    /// system binary isn't allowed to run — under argv[0] `claude` has the
    /// keyboard of its group; a plain `sleep` doesn't.
    nonisolated func testARealGroupsMembers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let node = folder.appendingPathComponent("node")
        let source = folder.appendingPathComponent("node.c")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [source.path, "-o", node.path]
        try cc.run()
        cc.waitUntilExit()
        try XCTSkipUnless(cc.terminationStatus == 0, "no C compiler")
        let agent = try TestChild("/bin/bash", ["-c", "exec -a claude '\(node.path)'"], environment: TestChild.cleanEnvironment)
        let plain = try TestChild("/bin/sleep", ["30"], environment: TestChild.cleanEnvironment)
        defer {
            agent.stop()
            plain.stop()
        }
        XCTAssertEqual(LiveActivityKernel().groupMembers(plain.pid, limit: 64), [plain.pid], "its group is its own")
        XCTAssertTrue(TestChild.eventually { ImagePaste.agentHasKeyboard(foreground: agent.pid) }, "claude, once it exec'd")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(foreground: plain.pid))
    }
}
