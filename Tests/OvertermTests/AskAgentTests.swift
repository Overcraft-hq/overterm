import XCTest

@testable import Overterm

/// What actually gets typed into an agent. The sheet's job is to build one
/// string; everything else about it is layout.
@MainActor
final class AskAgentTests: XCTestCase {
    private func model(command: CommandBlock? = nil, diff: Bool = false) -> AskAgentModel {
        let model = AskAgentModel()
        model.begin(
            selection: "AssertionError: expected 200 to be 401\n  at bank.test.ts:58", command: command,
            folder: "/src/app",
            targets: [
                .init(id: UUID(), title: "api · claude", detail: "idle", color: .purple, agent: .claude),
                .init(id: nil, title: "New agent tab in this folder", detail: "", color: nil, agent: .claude),
            ], diff: diff)
        return model
    }

    private let failed = CommandBlock(
        id: 0, command: "pnpm --filter api test", startRow: 0, endRow: 10, exit: 1, seconds: 4)

    func testItSendsTheSelectionOnItsOwnWhenThereIsNothingElse() {
        let model = model()
        XCTAssertEqual(model.prompt(diff: nil), "AssertionError: expected 200 to be 401\n  at bank.test.ts:58")
    }

    /// The command that produced it is the context the agent cannot see,
    /// and the exit code is the part of it that matters.
    func testTheCommandAndItsExitComeWithIt() {
        let model = model(command: failed)
        let prompt = model.prompt(diff: nil)
        XCTAssertTrue(prompt.contains("$ pnpm --filter api test   (exit 1)"))
        XCTAssertTrue(prompt.contains("AssertionError"))
    }

    func testEachExtraCanBeLeftOut() {
        let model = model(command: failed)
        model.extras.exit = false
        XCTAssertTrue(model.prompt(diff: nil).contains("$ pnpm --filter api test"))
        XCTAssertFalse(model.prompt(diff: nil).contains("exit 1"))
        model.extras.command = false
        XCTAssertFalse(model.prompt(diff: nil).contains("pnpm"))
    }

    /// A command that succeeded has no exit worth saying.
    func testASuccessfulCommandDoesNotAnnounceItsExit() {
        let ok = CommandBlock(id: 1, command: "pnpm build", startRow: 0, endRow: 1, exit: 0, seconds: 1)
        let model = model(command: ok)
        XCTAssertEqual(model.prompt(diff: nil).contains("exit"), false)
    }

    func testWhatYouTypeGoesFirst() {
        let model = model(command: failed)
        model.message = "Fix this failing test"
        XCTAssertTrue(model.prompt(diff: nil).hasPrefix("Fix this failing test"))
    }

    func testTheDiffIsOnlyThereWhenAskedFor() {
        let model = model(diff: true)
        XCTAssertFalse(model.prompt(diff: "diff --git a/x b/x").contains("git diff"))
        model.extras.diff = true
        XCTAssertTrue(model.prompt(diff: "diff --git a/x b/x").contains("git diff:"))
    }

    /// The chip is only worth offering where a diff can be had, and
    /// `begin` is what is told. It used to be handed that and throw it
    /// away, so the chip showed outside a checkout and did nothing in one.
    func testTheChipIsOfferedOnlyInACheckout() {
        XCTAssertFalse(model(diff: false).canDiff)
        XCTAssertTrue(model(diff: true).canDiff)
    }

    /// The whole point of the chip: switched on, the diff is in what gets
    /// typed — selection and all.
    func testASheetWithTheChipOnProducesAPromptContainingTheDiff() {
        let model = model(command: failed, diff: true)
        model.message = "Why does this fail?"
        model.extras.diff = true
        let prompt = model.prompt(diff: "diff --git a/bank.ts b/bank.ts\n+  return 401")
        XCTAssertTrue(prompt.contains("git diff:"), prompt)
        XCTAssertTrue(prompt.contains("+  return 401"), prompt)
        XCTAssertTrue(prompt.contains("AssertionError"), prompt)
        XCTAssertTrue(prompt.hasPrefix("Why does this fail?"), prompt)
    }

    /// Nothing to show is not an empty section.
    func testNoDiffMeansNoDiffSection() {
        let model = model(diff: true)
        model.extras.diff = true
        XCTAssertFalse(model.prompt(diff: nil).contains("git diff"))
        XCTAssertFalse(model.prompt(diff: "").contains("git diff"))
    }

    func testItCountsTheLinesItIsSending() {
        XCTAssertEqual(model().lines, 2)
    }

    /// An agent tab is picked by default; "a new tab" is the fallback, not
    /// the first thing.
    func testAnExistingAgentIsChosenFirst() {
        XCTAssertNotNil(model().chosen)
    }

    func testNothingSelectedIsNotAQuestion() {
        let model = AskAgentModel()
        model.begin(selection: "", command: nil, folder: nil, targets: [], diff: false)
        XCTAssertFalse(model.isOpen)
    }

    /// What came with the text (a container's logs, its compose service)
    /// goes after it, in order, and each chip can leave its part out.
    func testPartsGoAfterTheSelectionAndCanBeLeftOut() {
        let model = AskAgentModel()
        model.begin(
            selection: "Container shop-worker-1", command: nil, folder: nil, targets: [], diff: false,
            parts: [.init(title: "last 3 log lines", text: "Its last 3 log lines:\nboom"), .init(title: "compose service", text: "image: node:22")])
        XCTAssertEqual(model.prompt(diff: nil), "Container shop-worker-1\n\nIts last 3 log lines:\nboom\n\nimage: node:22")
        model.parts[0].on = false
        XCTAssertEqual(model.prompt(diff: nil), "Container shop-worker-1\n\nimage: node:22")
    }

    /// The fixed chip says what the text is when it isn't lines picked out.
    func testASubjectNamesTheFixedChip() {
        let model = AskAgentModel()
        model.begin(
            selection: "Container shop-worker-1", command: nil, folder: nil, targets: [], diff: false, subject: "shop-worker-1 ran out of memory",
            parts: [.init(title: "compose service", text: "image: node:22")])
        XCTAssertEqual(model.subject, "shop-worker-1 ran out of memory")
        model.stop()
        XCTAssertNil(model.subject)
        XCTAssertTrue(model.parts.isEmpty, "the next sheet starts without them")
        model.begin(selection: "a line", command: nil, folder: nil, targets: [], diff: false)
        XCTAssertNil(model.subject)
    }

    /// A question can be started for you, and is still yours to change.
    func testAQuestionCanBeStartedFor() {
        let model = AskAgentModel()
        model.begin(selection: "Container shop-worker-1", command: nil, folder: nil, targets: [], diff: false, message: "Why did it exit?")
        XCTAssertTrue(model.prompt(diff: nil).hasPrefix("Why did it exit?\n\nContainer shop-worker-1"), model.prompt(diff: nil))
        model.message = "Fix it"
        XCTAssertTrue(model.prompt(diff: nil).hasPrefix("Fix it"))
    }
}

/// The other half of the chip: the window has to read the diff and hand
/// it over. It did not — `prompt()` was called with no argument at all.
@MainActor
final class AskAgentDiffReadingTests: XCTestCase {
    func testItReadsWhatTheCheckoutHasChanged() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: [String]) async throws {
            _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=T"] + arguments, in: repo)
        }
        let file = repo.appendingPathComponent("a.txt")

        try await git(["init", "-q", "-b", "main"])
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        // Before the first commit there is no HEAD to compare with.
        try await git(["add", "-A"])
        let staged = await TerminalWindowController.uncommittedDiff(in: repo)
        XCTAssertTrue(staged?.contains("+one") == true, staged ?? "nil")

        try await git(["commit", "-q", "-m", "Add a"])
        let clean = await TerminalWindowController.uncommittedDiff(in: repo)
        XCTAssertNil(clean, "a clean checkout has no diff to send")

        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        let unstaged = await TerminalWindowController.uncommittedDiff(in: repo)
        XCTAssertTrue(unstaged?.contains("+two") == true, unstaged ?? "nil")
        try await git(["add", "-A"])
        let both = await TerminalWindowController.uncommittedDiff(in: repo)
        XCTAssertTrue(both?.contains("+two") == true, "staged counts too: \(both ?? "nil")")
    }

    /// A diff bigger than the cap is cut, and says so: it is typed into a
    /// terminal.
    func testABigDiffIsBoundedAndSaysSo() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-ask-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=T", "init", "-q", "-b", "main"], in: repo)
        let big = (0..<40_000).map { "line \($0)" }.joined(separator: "\n")
        try big.write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        _ = try await Git.run(["add", "-A"], in: repo)
        let diff = await TerminalWindowController.uncommittedDiff(in: repo)
        let text = try XCTUnwrap(diff)
        XCTAssertTrue(text.hasSuffix("… diff truncated."), String(text.suffix(40)))
        XCTAssertLessThan(text.utf8.count, AskAgentModel.maxDiffBytes + 200)
    }
}
