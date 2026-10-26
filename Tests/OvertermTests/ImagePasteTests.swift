import AppKit
import XCTest

@testable import Overterm

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

    func testAnAgentMustHaveTheKeyboard() {
        func node(_ pid: pid_t, _ name: String, _ command: String) -> ProcessNode {
            ProcessNode(pid: pid, parent: 1, name: name, command: command, cpuPercent: 0, memory: 0, workingDirectory: nil)
        }
        let nodes = [node(10, "zsh", "-zsh"), node(20, "node", "claude --resume"), node(30, "codex", "codex")]
        let groups: [pid_t: pid_t] = [10: 10, 20: 20, 30: 30]
        XCTAssertTrue(ImagePaste.agentHasKeyboard(among: nodes, foreground: 20, groupOf: { groups[$0] }))
        XCTAssertTrue(ImagePaste.agentHasKeyboard(among: nodes, foreground: 30, groupOf: { groups[$0] }), "Codex too")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(among: nodes, foreground: 10, groupOf: { groups[$0] }), "the shell has it")
        XCTAssertFalse(ImagePaste.agentHasKeyboard(among: nodes, foreground: nil, groupOf: { groups[$0] }))
    }
}
