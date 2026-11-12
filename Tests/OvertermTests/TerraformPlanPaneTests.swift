import XCTest

@testable import Overterm

/// The plan in the right slot as a model (analysis 6.3, Section 7): rows
/// kept, not built in a body; the list's keys; a long string and JSON in a
/// string diffed by line; a plan past the bound said with the stream's
/// counts; an agent's summary with its cause chains (3.5).
@MainActor
final class TerraformPlanPaneTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("envs/dev"), withIntermediateDirectories: true)
        try "variable \"acme_name\" {\n  type = string\n}\n\nresource \"terraform_data\" \"acme\" {\n  triggers_replace = var.acme_name\n}\n".write(
            to: folder.appendingPathComponent("envs/dev/main.tf"), atomically: true, encoding: .utf8)
        try "# acme\nacme_name = \"acme-two\"\n".write(to: folder.appendingPathComponent("envs/dev/dev.tfvars"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func planned() throws -> TerraformPlanRun {
        let card = TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: folder.appendingPathComponent("envs/dev"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: nil, verdict: .init(rootClass: .local, reason: "local"))
        let run = TerraformPlanRun(kind: .plan, checkout: folder, card: card, varFiles: ["dev.tfvars"])
        let plan = try TerraformPlan.decode(Data(TerraformPlanReadingTests.planted.utf8), scrub: TerraformPlan.scrub)
        run.landed(try TerraformPlanReadingTests.record(plan))
        return run
    }

    private final class Done {
        var discarded = 0
        var opened: [(URL, Int?)] = []
    }

    private func actions(_ done: Done) -> TerraformPlanActions {
        TerraformPlanActions(
            planAgain: { _, _ in }, discard: { _ in done.discarded += 1 }, copySummary: { _ in }, askWhy: { _ in }, chooseVarFiles: { _, _ in },
            open: { url, line in done.opened.append((url, line)) }, close: {})
    }

    func testTheRowsAreKeptAndTheKeysMoveOnThem() async throws {
        let pane = TerraformPlanPaneModel()
        let run = try planned()
        pane.show(run)
        XCTAssertEqual(pane.rows.first?.address, "local_file.acme_config", "kept on show, drift first")
        let all = pane.rows.count
        pane.filter = "acme_logs"
        XCTAssertEqual(pane.rows.map(\.address), [#"aws_s3_bucket.acme_logs["a"]"#], "rebuilt by the filter, not by a body")
        pane.filter = ""
        XCTAssertEqual(pane.rows.count, all)
        pane.toggle(.delete)
        XCTAssertTrue(pane.rows.allSatisfy { $0.section != .changes })
        pane.toggle(.delete)

        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 125, characters: "\u{F701}"), .down)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 126, characters: "\u{F700}"), .up)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 36, characters: "\r"), .detail)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 51, characters: "\u{7F}"), .discard)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 31, characters: "o"), .open)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 0, characters: "a"), .askWhy)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 44, characters: "/"), .filter)
        XCTAssertNil(TerraformPlanPaneModel.key(keyCode: 9, characters: "v"))

        let done = Done()
        let actions = actions(done)
        XCTAssertTrue(pane.press(.down, actions: actions))
        XCTAssertEqual(pane.selected, pane.rows[0].id)
        XCTAssertTrue(pane.press(.down, actions: actions))
        XCTAssertEqual(pane.selectedRow?.address, "terraform_data.acme")
        XCTAssertEqual(pane.copyAddress(), "terraform_data.acme", "⌘C: the address")
        XCTAssertTrue(pane.press(.detail, actions: actions))
        XCTAssertTrue(pane.expanded.contains(pane.rows[1].id), "↩ opens the detail")
        // The sources are read off the main thread once the plan shows.
        for _ in 0..<200 where pane.block(of: "terraform_data.acme") == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(pane.press(.open, actions: actions))
        XCTAssertEqual(done.opened.last?.1, 5, "o: the block's line")
        XCTAssertFalse(pane.press(.askWhy, actions: actions), "Ask Why is for a failed run")
        let focus = pane.filterFocus
        XCTAssertTrue(pane.press(.filter, actions: actions))
        XCTAssertEqual(pane.filterFocus, focus + 1)
        XCTAssertTrue(pane.press(.discard, actions: actions))
        XCTAssertEqual(done.discarded, 1)
        XCTAssertEqual(pane.causes(pane.rows[1]).map(\.text), ["triggers_replace", "var.acme_name", "envs/dev/dev.tfvars:2"])
        XCTAssertEqual(pane.causes(pane.rows[1]).last?.changed, false, "nothing changed in this branch yet")
        pane.changedLines = ["envs/dev/dev.tfvars": [2]]
        XCTAssertEqual(pane.causes(pane.rows[1]).last?.changed, true, "the changes pane's lines join the run's")
    }

    func testAnAgentsSummaryHasTheCauseChains() async throws {
        let run = try planned()
        run.changedLines = ["envs/dev/dev.tfvars": [2]]
        let status = await TerraformMCP.status(of: run)
        XCTAssertTrue(
            status.contains("why: ← triggers_replace ← var.acme_name ← envs/dev/dev.tfvars:2  changed in this branch"), status)
        for sentinel in TerraformPlanReadingTests.sentinels { XCTAssertFalse(status.contains(sentinel)) }
    }

    func testAPlanPastTheBoundIsSaidWithTheStreamsCounts() throws {
        let run = try planned()
        run.absorb([
            TerraformUIMessage.decode(#"{"type":"change_summary","changes":{"add":2000,"change":3,"remove":1,"import":0,"operation":"plan"}}"#)
        ])
        XCTAssertEqual(
            run.tooLargeText(), "Plan: 2000 to add, 3 to change, 1 to destroy. The plan is over 64 MB: too large to show attribute diffs.")
    }

    func testALongStringAndJSONInAStringAreDiffedByLine() {
        let before = #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::acme/*"}]}"#
        let after = #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:*","Resource":"arn:aws:s3:::acme/*"}]}"#
        let lines = TerraformAttributeDiff.textDiff(before, after)
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text.contains(#""Action" : "s3:GetObject""#) }, "\(lines.map(\.said))")
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text.contains(#""Action" : "s3:*""#) })
        XCTAssertFalse(lines.contains { $0.kind == .removed && $0.text.contains("Version") }, "pretty-printed first: only the line that changed")
        let change = TerraformPlan.ResourceChange(
            address: "aws_iam_policy.acme", mode: "managed", type: "aws_iam_policy", name: "acme", provider: "aws", actions: ["update"], replacePaths: [],
            before: .object(["policy": .string(before), "name": .string("acme")]), after: .object(["policy": .string(after), "name": .string("acme")]),
            changedPaths: ["policy"])
        let diff = TerraformAttributeDiff.lines(change)
        XCTAssertNotNil(diff.lines.first { $0.path == "policy" }?.text, "a JSON string gets its line diff")
        XCTAssertEqual(diff.unchanged, 1)
        let script = (1...30).map { "echo acme-\($0)" }.joined(separator: "\n")
        let edited = script.replacingOccurrences(of: "echo acme-15", with: "echo globex-15")
        let text = TerraformAttributeDiff.textDiff(script, edited)
        XCTAssertEqual(text.filter { $0.kind == .removed }.map(\.text), ["echo acme-15"])
        XCTAssertEqual(text.filter { $0.kind == .same }.count, 4, "two lines of context either side")
        XCTAssertEqual(text.first?.kind, .gap)
        XCTAssertEqual(text.last?.kind, .gap)
    }
}
