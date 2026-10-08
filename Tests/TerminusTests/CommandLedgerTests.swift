import XCTest

@testable import Terminus

/// The command ledger. libghostty gives no command boundaries, so these
/// are inferred from the title, the finish event and the scrollbar — which
/// makes every case here row arithmetic, and row arithmetic is what goes
/// wrong silently.
final class CommandLedgerTests: XCTestCase {
    /// A pane that has printed `rows` lines, scrolled to the bottom.
    private func at(_ ledger: inout CommandLedger, rows total: UInt64, screen: UInt64 = 40) {
        ledger.scrolled(total: total, offset: total > screen ? total - screen : 0, rows: min(screen, total))
    }

    func testACommandSpansTheRowsItPrinted() {
        var ledger = CommandLedger()
        at(&ledger, rows: 100)
        ledger.began(command: "pnpm build")
        at(&ledger, rows: 142)
        ledger.finished(exitCode: 0, seconds: 8.1)
        XCTAssertEqual(ledger.blocks.count, 1)
        XCTAssertEqual(ledger.blocks[0].startRow, 100)
        XCTAssertEqual(ledger.blocks[0].endRow, 141)
        XCTAssertEqual(ledger.blocks[0].rows, 42)
        XCTAssertTrue(ledger.blocks[0].isLocated)
        XCTAssertFalse(ledger.blocks[0].failed)
        XCTAssertEqual(ledger.blocks[0].detail, "8.1 s")
    }

    /// While it runs it owns everything down to the newest row, so its
    /// frame grows with its output instead of staying one line tall.
    func testARunningCommandGrowsWithItsOutput() {
        var ledger = CommandLedger()
        at(&ledger, rows: 10)
        ledger.began(command: "pnpm test --watch")
        at(&ledger, rows: 60)
        XCTAssertEqual(ledger.running?.endRow, 59)
        at(&ledger, rows: 90)
        XCTAssertEqual(ledger.running?.endRow, 89)
        XCTAssertEqual(ledger.running?.detail, "running")
    }

    func testAFailureKeepsItsExitCode() {
        var ledger = CommandLedger()
        at(&ledger, rows: 10)
        ledger.began(command: "pnpm --filter api build")
        at(&ledger, rows: 30)
        ledger.finished(exitCode: 2, seconds: 8.1)
        XCTAssertTrue(ledger.blocks[0].failed)
        XCTAssertEqual(ledger.blocks[0].detail, "exit 2 · 8.1 s")
        XCTAssertEqual(ledger.failures.count, 1)
    }

    /// The shell re-announcing the same command is not a second run; a
    /// different one closes the first, because a title cannot say "both".
    func testTheSameTitleTwiceIsOneCommand() {
        var ledger = CommandLedger()
        at(&ledger, rows: 10)
        ledger.began(command: "vim")
        ledger.began(command: "vim")
        XCTAssertEqual(ledger.blocks.count, 1)
        ledger.began(command: "git status")
        XCTAssertEqual(ledger.blocks.count, 2)
        XCTAssertFalse(ledger.blocks[0].isRunning)
    }

    func testAnEmptyTitleIsNotACommand() {
        var ledger = CommandLedger()
        ledger.began(command: "   ")
        XCTAssertTrue(ledger.blocks.isEmpty)
    }

    /// An exit reported for something that was never announced would
    /// otherwise invent an unnamed block, and the overlay would draw a
    /// frame with nothing in it.
    func testAnExitWithoutAStartIsIgnored() {
        var ledger = CommandLedger()
        at(&ledger, rows: 10)
        ledger.finished(exitCode: 1, seconds: 2)
        XCTAssertTrue(ledger.blocks.isEmpty)
    }

    /// The scrollback filling up moves every row down. Anything that falls
    /// off the top goes with it — drawn at row 0 it would frame the wrong
    /// output.
    func testTrimmingTheScrollbackSlidesTheBlocksDown() {
        var ledger = CommandLedger()
        at(&ledger, rows: 100)
        ledger.began(command: "first")
        at(&ledger, rows: 150)
        ledger.finished(exitCode: 0, seconds: 1)
        ledger.began(command: "second")
        at(&ledger, rows: 300)
        ledger.finished(exitCode: 0, seconds: 1)
        // 200 rows dropped: "first" (100…149) is gone, "second" (150…299)
        // becomes 0…99.
        at(&ledger, rows: 100)
        XCTAssertEqual(ledger.blocks.map(\.command), ["second"])
        XCTAssertEqual(ledger.blocks[0].startRow, 0)
        XCTAssertEqual(ledger.blocks[0].endRow, 99)
    }

    /// The renderer reports the scrollbar on its own cadence, so the scroll
    /// a command's last lines caused can land after its exit. The block
    /// has to take that late row, or it ends before its own output.
    func testAScrollArrivingAfterTheExitStillCloses() {
        var ledger = CommandLedger()
        at(&ledger, rows: 40)
        ledger.began(command: "noisy")
        ledger.finished(exitCode: 0, seconds: 1)
        XCTAssertFalse(ledger.blocks[0].isLocated)
        at(&ledger, rows: 160)
        XCTAssertTrue(ledger.blocks[0].isLocated)
        XCTAssertEqual(ledger.blocks[0].startRow, 40)
        XCTAssertEqual(ledger.blocks[0].endRow, 159)
    }

    /// Only the one that just finished, and only once: the next command's
    /// scrolling must not stretch the previous block over it.
    func testALaterCommandDoesNotStretchTheOneBefore() {
        var ledger = CommandLedger()
        at(&ledger, rows: 40)
        ledger.began(command: "first")
        ledger.finished(exitCode: 0, seconds: 1)
        at(&ledger, rows: 100)
        ledger.began(command: "second")
        at(&ledger, rows: 400)
        ledger.finished(exitCode: 0, seconds: 1)
        at(&ledger, rows: 400)
        XCTAssertEqual(ledger.blocks[0].endRow, 99)
        XCTAssertEqual(ledger.blocks[1].endRow, 399)
    }

    /// Half of what the title reports is the directory, not a command.
    /// Recording those made a block per prompt, and each one stole the rows
    /// of the command before it.
    func testADirectoryTitleIsThePromptNotACommand() {
        let cwd = NSHomeDirectory() + "/src/app"
        XCTAssertTrue(CommandLedger.isPrompt(cwd, cwd: cwd))
        XCTAssertTrue(CommandLedger.isPrompt("~/src/app", cwd: cwd))
        XCTAssertTrue(CommandLedger.isPrompt("app", cwd: cwd))
        XCTAssertTrue(CommandLedger.isPrompt("/var/log", cwd: cwd))
        XCTAssertTrue(CommandLedger.isPrompt("", cwd: cwd))
        XCTAssertTrue(CommandLedger.isPrompt("   ", cwd: nil))
    }

    /// A command that happens to start with a path is still a command, and
    /// so is `cd` — the shell announces it before showing where it landed.
    func testACommandIsStillACommand() {
        let cwd = NSHomeDirectory() + "/src/app"
        XCTAssertFalse(CommandLedger.isPrompt("cd ../other", cwd: cwd))
        XCTAssertFalse(CommandLedger.isPrompt("pnpm build", cwd: cwd))
        XCTAssertFalse(CommandLedger.isPrompt("./scripts/deploy.sh api", cwd: cwd))
        XCTAssertFalse(CommandLedger.isPrompt("/usr/bin/env ruby", cwd: cwd))
    }

    /// The prompt coming back ends what was running without starting
    /// anything, so the rows that arrive late still land on the command.
    func testThePromptEndsTheCommandWithoutTakingItsRows() {
        var ledger = CommandLedger()
        at(&ledger, rows: 40)
        ledger.began(command: "noisy")
        ledger.prompted()
        XCTAssertEqual(ledger.blocks.count, 1)
        XCTAssertFalse(ledger.blocks[0].isRunning)
        ledger.finished(exitCode: 0, seconds: 1)
        at(&ledger, rows: 200)
        XCTAssertEqual(ledger.blocks.count, 1)
        XCTAssertEqual(ledger.blocks[0].endRow, 199)
    }

    func testItKeepsOnlyTheMostRecentBlocks() {
        var ledger = CommandLedger()
        for i in 0..<(CommandLedger.limit + 20) {
            at(&ledger, rows: UInt64(i * 2 + 1))
            ledger.began(command: "cmd \(i)")
            ledger.finished(exitCode: 0, seconds: 1)
        }
        XCTAssertEqual(ledger.blocks.count, CommandLedger.limit)
        XCTAssertEqual(ledger.blocks.first?.command, "cmd 20")
    }

    /// ⌥⌘↓ walks the failures forwards and comes back round.
    func testNextFailureWrapsAround() {
        var ledger = CommandLedger()
        at(&ledger, rows: 10)
        ledger.began(command: "a")
        at(&ledger, rows: 20)
        ledger.finished(exitCode: 1, seconds: 1)
        ledger.began(command: "b")
        at(&ledger, rows: 30)
        ledger.finished(exitCode: 0, seconds: 1)
        ledger.began(command: "c")
        at(&ledger, rows: 40)
        ledger.finished(exitCode: 3, seconds: 1)
        XCTAssertEqual(ledger.nextFailure(after: 0)?.command, "a")
        XCTAssertEqual(ledger.nextFailure(after: 15)?.command, "c")
        XCTAssertEqual(ledger.nextFailure(after: 999)?.command, "a")
    }

    func testScrollingToARowIsADeltaFromWhereWeAre() {
        var ledger = CommandLedger()
        ledger.scrolled(total: 1000, offset: 400, rows: 40)
        XCTAssertEqual(ledger.lines(toReach: 500), 100)
        XCTAssertEqual(ledger.lines(toReach: 300), -100)
    }

    func testTheMapPlacesBlocksAndTheViewportAsFractions() {
        var ledger = CommandLedger()
        at(&ledger, rows: 100)
        ledger.began(command: "x")
        at(&ledger, rows: 200, screen: 50)
        ledger.finished(exitCode: 0, seconds: 1)
        XCTAssertEqual(ledger.position(of: ledger.blocks[0]), 0.5...1.0)
        XCTAssertEqual(ledger.viewport, 0.75...1.0)
    }

    func testAnEmptyPaneMapsToNothing() {
        let ledger = CommandLedger()
        XCTAssertNil(ledger.viewport)
        XCTAssertNil(ledger.lastFinished)
        XCTAssertNil(ledger.running)
    }
}
