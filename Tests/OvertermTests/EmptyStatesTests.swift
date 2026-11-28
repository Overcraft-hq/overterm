import XCTest

@testable import Overterm
@testable import OvertermCore

/// Onboarding stage 1 (7.5): the empty states that teach — their words,
/// their keys read as bound now, and when Files' home strip shows.
@MainActor
final class EmptyStatesTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testTheHomeStripShowsOnlyForTheHomeFolderOutsideARepository() {
        XCTAssertTrue(EmptyStates.showsHomeStrip(root: home, home: home, checked: home, notARepository: true))
        XCTAssertTrue(
            EmptyStates.showsHomeStrip(root: URL(fileURLWithPath: "/Users/someone/"), home: home, checked: home, notARepository: true),
            "a trailing slash is the same folder")
        XCTAssertFalse(EmptyStates.showsHomeStrip(root: home, home: home, checked: home, notARepository: false), "a home folder kept in git")
        let project = home.appendingPathComponent("project")
        XCTAssertFalse(EmptyStates.showsHomeStrip(root: project, home: home, checked: project, notARepository: true), "any other folder")
        XCTAssertFalse(EmptyStates.showsHomeStrip(root: home, home: home, checked: project, notARepository: true), "the read was another folder's")
        XCTAssertFalse(EmptyStates.showsHomeStrip(root: home, home: home, checked: nil, notARepository: true), "nothing read yet")
        XCTAssertFalse(EmptyStates.showsHomeStrip(root: nil, home: home, checked: nil, notARepository: true))
    }

    /// Only git's "not a git repository" counts for the strip — not any
    /// failure of the changes' read (a timeout, a lock, a folder unread).
    func testOnlyNotARepositoryCountsForTheStrip() {
        let outside = GitError(
            arguments: ["status"], status: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git\n")
        XCTAssertTrue(DiffModel.isNotARepository(outside))
        XCTAssertTrue(
            DiffModel.isNotARepository(GitError(arguments: ["status"], status: 128, stderr: "fatal: kein Git-Repository (oder irgendeines der Elternverzeichnisse): .git\n")),
            "a translated git")
        XCTAssertFalse(
            DiffModel.isNotARepository(GitError(arguments: ["status"], status: 128, stderr: "fatal: Unable to create '.git/index.lock': File exists.\n")),
            "a lock")
        XCTAssertFalse(
            DiffModel.isNotARepository(GitError(arguments: ["status"], status: 128, stderr: "fatal: detected dubious ownership in repository at '/x'\n")))
        XCTAssertFalse(DiffModel.isNotARepository(CocoaError(.fileReadNoPermission)), "not git's at all")
    }

    /// No key is written into an empty state's words: each is read from
    /// keybindings.json (`KeyHint`), so a rebinding is what they say.
    func testTheWordsHoldNoKey() {
        let words = [
            EmptyStates.filesHome, EmptyStates.overgit, EmptyStates.sessions, EmptyStates.sessionsUnbound, EmptyStates.inbox, EmptyStates.inboxNext,
        ]
        for text in words {
            XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "⌘⌥⌃⇧")), text)
        }
        XCTAssertTrue(EmptyStates.sessions.contains("%@") && EmptyStates.inboxNext.contains("%@"))
    }

    func testTheHintsFollowARebinding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keybindings.json")
        func keys(_ json: String) throws -> Keybindings {
            try json.write(to: file, atomically: true, encoding: .utf8)
            return Keybindings(url: file, ghosttyDefault: { _ in nil }, watch: false)
        }
        let plain = try keys("[]")
        XCTAssertEqual(KeyHints.text(EmptyStates.sessions, command: Agent.claude.newTabCommand, keys: plain), "Start one: New Claude Tab ⌥⌘C")
        XCTAssertEqual(KeyHints.text(EmptyStates.inboxNext, command: "tabs.nextAttention", keys: plain), "⌥⌘↓ goes to the next tab that needs you.")
        XCTAssertNil(KeyHints.text("%@", command: EmptyStates.openFolderCommand, keys: plain), "Open Folder… has no key by default (D-10)")

        let rebound = try keys(#"[{ "key": "ctrl+alt+cmd+c", "command": "tabs.newClaude" }, { "key": "cmd+o", "command": "file.openFolder" }]"#)
        XCTAssertEqual(KeyHints.text(EmptyStates.sessions, command: Agent.claude.newTabCommand, keys: rebound), "Start one: New Claude Tab ⌃⌥⌘C")
        XCTAssertEqual(KeyHints.text("%@", command: EmptyStates.openFolderCommand, keys: rebound), "⌘O")
    }
}
