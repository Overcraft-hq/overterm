import XCTest

@testable import Overterm

/// Finding a tab's agent among its panes' process trees. A tree is read
/// from the live process table, so it can answer differently from one read
/// to the next: an agent starts or exits in between.
final class FirstAgentTests: XCTestCase {
    private func node(_ pid: pid_t, _ name: String, _ command: String) -> ProcessNode {
        ProcessNode(pid: pid, parent: 1, name: name, command: command, cpuPercent: 0, memory: 0, workingDirectory: "/work/\(pid)")
    }

    func testReadsEachPanesTreeOnceInOrder() {
        var reads: [pid_t] = []
        let found = TerminalWindowController.firstAgent(in: [(10, "a"), (20, "b"), (30, "c")]) { root, _ in
            reads.append(root ?? -1)
            return root == 20 ? [node(21, "zsh", "-zsh"), node(22, "claude", "claude --continue")] : [node(11, "zsh", "-zsh")]
        }
        XCTAssertEqual(found?.pid, 22)
        XCTAssertEqual(reads, [10, 20], "each pane once, none after the one with the agent")
    }

    /// Seen once, gone by a second look: the answer is what was seen. Read
    /// twice and force-unwrapped (`lazy.compactMap(…).first`), it crashed
    /// the app.
    func testAnAgentExitingAfterItWasSeenCannotCrashIt() {
        var reads = 0
        let found = TerminalWindowController.firstAgent(in: [(10, "a")]) { _, _ in
            reads += 1
            return reads == 1 ? [node(11, "claude", "claude")] : []
        }
        XCTAssertEqual(found?.pid, 11)
        XCTAssertEqual(reads, 1)
    }

    func testNoAgentReadsEveryPaneOnce() {
        var reads: [pid_t] = []
        let found = TerminalWindowController.firstAgent(in: [(10, "a"), (nil, "b")]) { root, _ in
            reads.append(root ?? -1)
            return [node(12, "vim", "vim claude.md")]
        }
        XCTAssertNil(found)
        XCTAssertEqual(reads, [10, -1])
    }
}
