import XCTest

@testable import Terminus

/// What the palette offers when you type. The ordering *is* the feature —
/// a history that puts the right command fourth is a list you scroll.
final class CommandHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ command: String, folder: String? = nil, hoursAgo: Double = 1, runs: Int = 1, exit: Int? = 0)
        -> HistoryEntry
    {
        HistoryEntry(
            command: command, folder: folder, exit: exit, seconds: 1,
            lastRun: now.addingTimeInterval(-hoursAgo * 3600), runs: runs)
    }

    /// The same command means something different in another checkout, and
    /// the one you want is nearly always the one from here.
    func testThisFolderComesFirst() {
        let entries = [
            entry("pnpm build", folder: "/src/other", hoursAgo: 0.1),
            entry("pnpm build --watch", folder: "/src/app", hoursAgo: 40),
        ]
        let ranked = CommandHistory.rank(entries, query: "pnpm", folder: "/src/app", now: now)
        XCTAssertEqual(ranked.first?.command, "pnpm build --watch")
    }

    /// A folder below the one it was run in still counts, less.
    func testAFolderBelowCountsForSomething() {
        let entries = [
            entry("make test", folder: "/elsewhere", hoursAgo: 0.1),
            entry("make test all", folder: "/src", hoursAgo: 0.1),
        ]
        let ranked = CommandHistory.rank(entries, query: "make", folder: "/src/app", now: now)
        XCTAssertEqual(ranked.first?.command, "make test all")
    }

    func testRecencyBreaksTies() {
        let entries = [entry("git push", hoursAgo: 100), entry("git pull", hoursAgo: 1)]
        XCTAssertEqual(CommandHistory.rank(entries, query: "git", folder: nil, now: now).first?.command, "git pull")
    }

    func testWhatDoesNotMatchIsNotOffered() {
        let entries = [entry("git status"), entry("pnpm build")]
        let ranked = CommandHistory.rank(entries, query: "xyzzy", folder: nil, now: now)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testItOffersOnlyAsManyAsAsked() {
        let entries = (0..<50).map { entry("cmd \($0)") }
        XCTAssertEqual(CommandHistory.rank(entries, query: "cmd", folder: nil, now: now, limit: 5).count, 5)
    }

    /// zsh's extended format, which is on as often as not.
    func testZshTimestampsAreStripped() {
        XCTAssertEqual(CommandHistory.unextended(": 1699999999:0;git status"), "git status")
        XCTAssertEqual(CommandHistory.unextended("git status"), "git status")
        XCTAssertEqual(CommandHistory.unextended(": no semicolon here"), ": no semicolon here")
    }

    /// Newest last in the file, newest first in the list, and a command
    /// run forty times is one entry.
    func testTheShellsHistoryIsReadNewestFirstAndDeduped() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hist-\(UUID()).txt")
        try ": 1:0;git status\n: 2:0;pnpm build\n: 3:0;git status\n\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let entries = CommandHistory.fromShellHistory(file: file, now: now)
        XCTAssertEqual(entries.map(\.command), ["git status", "pnpm build"])
    }

    func testAMissingHistoryFileIsNotAnError() {
        let missing = URL(fileURLWithPath: "/nope/\(UUID())")
        XCTAssertTrue(CommandHistory.fromShellHistory(file: missing, now: now).isEmpty)
    }

    func testItSaysHowItWent() {
        XCTAssertEqual(entry("x", exit: 2).outcome, "exit 2 · 1.0 s")
        XCTAssertTrue(entry("x", exit: 2).failed)
        XCTAssertFalse(entry("x", exit: 0).failed)
    }
}
