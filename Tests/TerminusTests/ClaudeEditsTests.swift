import XCTest

@testable import Terminus

/// Transcript lines in the shape Claude Code writes them (2.1.28x): one
/// content part per assistant line (a message's parts share its id), the
/// edit's result on a later user line (`tool_use_id`, `is_error`,
/// `toolUseResult.structuredPatch` — a subagent's transcript keeps no
/// toolUseResult). Only made-up content.
struct TranscriptFixture {
    var session = "8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33"
    var base = Date(timeIntervalSince1970: 1_790_000_000)

    func stamp(_ second: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(TimeInterval(second)))
    }

    /// A JSON string literal, as JSON.stringify writes one (slashes left alone).
    func q(_ text: String) -> String {
        var out = "\""
        for c in text {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    func envelope(_ type: String, _ body: String, at t: Int, extra: String = "") -> String {
        #"{"parentUuid":"p\#(t)","isSidechain":false,\#(body),"type":"\#(type)","uuid":"u\#(t)","timestamp":"\#(stamp(t))","userType":"external","cwd":"/r","sessionId":"\#(session)","version":"2.1.281","gitBranch":"main"\#(extra)}"#
    }

    func prompt(_ text: String, at t: Int, extra: String = "") -> String {
        envelope("user", #""promptId":"x","message":{"role":"user","content":\#(q(text))}"#, at: t, extra: extra)
    }

    func assistant(_ parts: String, message: String, at t: Int) -> String {
        envelope(
            "assistant",
            #""message":{"model":"claude-opus-5","id":"\#(message)","type":"message","role":"assistant","content":[\#(parts)],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":9}},"requestId":"req_\#(message)""#,
            at: t)
    }

    func textPart(_ text: String) -> String { #"{"type":"text","text":\#(q(text))}"# }
    func thinkingPart(_ text: String) -> String { #"{"type":"thinking","thinking":\#(q(text)),"signature":"sig"}"# }
    func toolPart(_ id: String, _ name: String, _ input: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{\#(input)},"caller":{"type":"direct"}}"#
    }
    func editPart(_ id: String, _ path: String) -> String {
        toolPart(id, "Edit", #""file_path":\#(q(path)),"old_string":"a","new_string":"b","replace_all":false"#)
    }

    func said(_ text: String, message: String = "msg_1", at t: Int) -> String { assistant(textPart(text), message: message, at: t) }
    func thought(_ text: String, message: String = "msg_1", at t: Int) -> String { assistant(thinkingPart(text), message: message, at: t) }
    func edit(_ id: String, _ path: String, message: String = "msg_1", at t: Int) -> String {
        assistant(editPart(id, path), message: message, at: t)
    }
    func bash(_ id: String, message: String = "msg_1", at t: Int) -> String {
        assistant(toolPart(id, "Bash", #""command":"make test","description":"Run the tests""#), message: message, at: t)
    }

    func result(_ id: String, at t: Int, hunks: [(Int, Int, Int, Int)] = [(1, 1, 1, 2)], type: String? = nil) -> String {
        let patch = hunks.map { #"{"oldStart":\#($0.0),"oldLines":\#($0.1),"newStart":\#($0.2),"newLines":\#($0.3),"lines":["-a","+b","+c"]}"# }
        let kind = type.map { #""type":"\#($0)","# } ?? ""
        return envelope(
            "user",
            #""promptId":"x","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"The file has been updated successfully."}]}"#,
            at: t,
            extra:
                #","toolUseResult":{\#(kind)"filePath":"/r/x","oldString":"a","newString":"b","originalFile":"a\n","structuredPatch":[\#(patch.joined(separator: ","))],"userModified":false,"replaceAll":false},"sourceToolAssistantUUID":"u0""#
        )
    }

    /// As a subagent's transcript has it: no toolUseResult.
    func bareResult(_ id: String, at t: Int) -> String {
        envelope(
            "user",
            #""promptId":"x","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"The file has been updated successfully."}]}"#,
            at: t, extra: #","sourceToolAssistantUUID":"u0""#)
    }

    func failed(_ id: String, at t: Int) -> String {
        envelope(
            "user",
            #""promptId":"x","message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>String to replace not found in file.</tool_use_error>","is_error":true,"tool_use_id":"\#(id)"}]}"#,
            at: t, extra: #","toolUseResult":"Error: String to replace not found in file.","sourceToolAssistantUUID":"u0""#)
    }

    /// Writes `lines` as this session's transcript — or one of its
    /// subagents' — in `projects`, in the folder Claude Code names after
    /// `directory`.
    @discardableResult
    func write(_ lines: [String], to projects: URL, for directory: String, subagent: String? = nil) throws -> URL {
        var folder = projects.appendingPathComponent(ClaudeUsageReader.projectFolder(for: directory))
        if subagent != nil { folder = folder.appendingPathComponent(session).appendingPathComponent("subagents") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(subagent.map { "agent-\($0).jsonl" } ?? "\(session).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

final class ClaudeEditsTests: XCTestCase {
    private let t = TranscriptFixture()
    private var session: String { t.session }
    private var base: Date { t.base }

    private func parse(_ lines: [String]) -> [ClaudeEdit] {
        ClaudeEdits.parse(lines: lines.map { Data($0.utf8) }, session: session)
    }

    private func reasons(_ edits: [ClaudeEdit]) -> [ClaudeEdit.Reason?] { edits.map(\.reason) }
    private func said(_ text: String) -> ClaudeEdit.Reason { .init(text: text, source: .said) }

    // MARK: Parsing

    func testTheReasonIsWhatItSaidInTheSameMessage() {
        let split = parse([
            t.prompt("rename the flag", at: 0), t.said("The flag reads better as isEnabled.", message: "msg_1", at: 1),
            t.edit("toolu_1", "/r/a.swift", message: "msg_1", at: 2), t.result("toolu_1", at: 3),
        ])
        XCTAssertEqual(split.count, 1)
        XCTAssertEqual(split.first?.path, "/r/a.swift")
        XCTAssertEqual(split.first?.tool, "Edit")
        XCTAssertEqual(split.first?.session, session)
        XCTAssertEqual(split.first?.time, base.addingTimeInterval(3), "when the result came back: the file changed then")
        XCTAssertEqual(split.first?.hunks, [.init(oldStart: 1, oldLines: 1, newStart: 1, newLines: 2)])
        XCTAssertEqual(reasons(split), [said("The flag reads better as isEnabled.")])
        // Older transcripts put a message's parts on one line — its thinking too.
        let joined = parse([
            t.prompt("rename the flag", at: 0),
            t.assistant(
                [t.textPart("The flag reads better as isEnabled."), t.thinkingPart("musing on names"), t.editPart("toolu_1", "/r/a.swift")]
                    .joined(separator: ","), message: "msg_1", at: 1),
            t.result("toolu_1", at: 2),
        ])
        XCTAssertEqual(reasons(joined), [said("The flag reads better as isEnabled.")])
    }

    func testTheReasonIsTheNearestEarlierTextOfTheTurn() {
        let edits = parse([
            t.prompt("the parser loses a line", at: 0),
            t.said("Let me look at the parser.", message: "msg_1", at: 1), t.bash("toolu_1", message: "msg_1", at: 2),
            t.result("toolu_1", at: 3),
            t.said("The loop stops one line early; the bound must include the last one.", message: "msg_2", at: 4),
            t.thought("", message: "msg_3", at: 5), t.thought("private musing about the bound", message: "msg_3", at: 6),
            t.bash("toolu_2", message: "msg_3", at: 7), t.result("toolu_2", at: 8),
            t.edit("toolu_3", "/r/Parser.swift", message: "msg_4", at: 9), t.result("toolu_3", at: 10),
            t.edit("toolu_4", "/r/ParserTests.swift", message: "msg_5", at: 11), t.result("toolu_4", at: 12),
        ])
        XCTAssertEqual(
            reasons(edits), Array(repeating: said("The loop stops one line early; the bound must include the last one."), count: 2),
            "one text can cover several edits; thinking is never a reason")
    }

    func testAnErroredEditIsIgnored() {
        let edits = parse([
            t.prompt("fix it", at: 0),
            t.said("Replacing the old call.", at: 1), t.edit("toolu_1", "/r/a.swift", at: 2), t.failed("toolu_1", at: 3),
            t.said("The call was spelled differently; replacing that.", at: 4), t.edit("toolu_2", "/r/a.swift", at: 5),
            t.result("toolu_2", at: 6),
            t.said("Also the docs.", at: 7), t.edit("toolu_3", "/r/README.md", at: 8),  // no result yet
        ])
        XCTAssertEqual(edits.map(\.path), ["/r/a.swift"], "errored and unanswered edits changed nothing")
        XCTAssertEqual(reasons(edits), [said("The call was spelled differently; replacing that.")])
    }

    func testAWriteThatCreatesAFile() {
        let edits = parse([
            t.prompt("add a changelog", at: 0), t.said("A CHANGELOG makes releases easier to follow.", at: 1),
            t.assistant(t.toolPart("toolu_1", "Write", ##""file_path":"/r/CHANGELOG.md","content":"# Changes\n""##), message: "msg_1", at: 2),
            t.result("toolu_1", at: 3, hunks: [], type: "create"),
        ])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.tool, "Write")
        XCTAssertEqual(edits.first?.path, "/r/CHANGELOG.md")
        XCTAssertEqual(edits.first?.created, true)
        XCTAssertEqual(reasons(edits), [said("A CHANGELOG makes releases easier to follow.")])
    }

    func testAMultiEditWithItsEdits() {
        let input = #""file_path":"/r/a.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d","replace_all":true}]"#
        let edits = parse([
            t.prompt("tidy up", at: 0), t.said("Two renames in one go.", at: 1),
            t.assistant(t.toolPart("toolu_1", "MultiEdit", input), message: "msg_1", at: 2),
            t.result("toolu_1", at: 3, hunks: [(3, 1, 3, 1), (40, 2, 40, 3)]),
        ])
        XCTAssertEqual(edits.map(\.tool), ["MultiEdit"])
        XCTAssertEqual(edits.first?.path, "/r/a.swift")
        XCTAssertEqual(edits.first?.created, false)
        XCTAssertEqual(edits.first?.hunks.map(\.newStart), [3, 40])
        XCTAssertEqual(reasons(edits), [said("Two renames in one go.")])
    }

    func testANotebookEditNamesItsNotebook() {
        let input = #""notebook_path":"/r/nb.ipynb","cell_id":"c1","new_source":"x = 1","edit_mode":"replace""#
        let edits = parse([t.prompt("set x", at: 0), t.assistant(t.toolPart("toolu_1", "NotebookEdit", input), message: "m", at: 1), t.bareResult("toolu_1", at: 2)])
        XCTAssertEqual(edits.map(\.path), ["/r/nb.ipynb"])
    }

    func testFallsBackToThePromptThenTheTitle() {
        let asked = parse([
            t.said("Done with the first thing.", at: 0),
            t.prompt("  Make the login test pass\n", at: 1), t.thought("the test is flaky because…", at: 2),
            t.edit("toolu_1", "/r/Login.swift", at: 3), t.result("toolu_1", at: 4),
        ])
        XCTAssertEqual(reasons(asked), [.init(text: "Make the login test pass", source: .asked)], "trimmed; not the last turn's words, not thinking")

        // A slash command starts a turn nobody typed: nothing said or asked in it.
        let command = "<command-message>release is running…</command-message>\n<command-name>/release</command-name>"
        let titled = parse([
            #"{"type":"ai-title","aiTitle":"Ship the release","sessionId":"s"}"#,
            t.prompt("bump it", at: 0), t.said("Bumped.", at: 1),
            t.prompt(command, at: 2), t.edit("toolu_1", "/r/VERSION", at: 3), t.result("toolu_1", at: 4),
        ])
        XCTAssertEqual(reasons(titled), [.init(text: "Ship the release", source: .title)])
        let renamed = parse([
            #"{"type":"custom-title","customTitle":"Release 2.0","sessionId":"s"}"#,
            t.prompt(command, at: 2), t.edit("toolu_1", "/r/VERSION", at: 3), t.result("toolu_1", at: 4),
            #"{"type":"ai-title","aiTitle":"Ship the release","sessionId":"s"}"#,
        ])
        XCTAssertEqual(reasons(renamed), [.init(text: "Release 2.0", source: .title)], "your own name for it first, wherever it is")
        XCTAssertEqual(
            parse([t.prompt(command, at: 0), t.edit("toolu_1", "/r/VERSION", at: 1), t.result("toolu_1", at: 2)]).count, 0,
            "no reason at all: nothing to show")
    }

    /// What Claude Code writes as the user that nobody typed.
    func testWhatIsAndIsNotAPrompt() {
        func reason(after line: String) -> ClaudeEdit.Reason? {
            parse([
                #"{"type":"ai-title","aiTitle":"Session","sessionId":"s"}"#,
                t.prompt("first ask", at: 0), t.said("Earlier words.", at: 1), line,
                t.edit("toolu_1", "/r/a", at: 3), t.result("toolu_1", at: 4),
            ]).first?.reason
        }
        let earlier = said("Earlier words.")
        XCTAssertEqual(reason(after: t.prompt("second ask", at: 2)), .init(text: "second ask", source: .asked))
        XCTAssertEqual(
            reason(
                after: t.envelope(
                    "user",
                    #""message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"text","text":"like this"}]}"#,
                    at: 2)),
            .init(text: "like this", source: .asked), "typed with an image")
        XCTAssertEqual(reason(after: t.prompt("<system-reminder>be brief</system-reminder>", at: 2, extra: #","isMeta":true"#)), earlier)
        XCTAssertEqual(reason(after: t.prompt("Base directory for this skill: …", at: 2, extra: #","isMeta":true"#)), earlier)
        XCTAssertEqual(reason(after: t.prompt("[Request interrupted by user]", at: 2)), earlier)
        XCTAssertEqual(reason(after: t.prompt("<local-command-stdout>Set model to opus</local-command-stdout>", at: 2)), earlier)
        XCTAssertEqual(reason(after: t.prompt("<bash-input>ls</bash-input>", at: 2)), earlier)
        XCTAssertEqual(
            reason(after: t.prompt("This session is being continued from a previous conversation…", at: 2, extra: #","isCompactSummary":true"#)),
            earlier, "compaction goes on with the same work")
        XCTAssertEqual(
            reason(after: t.prompt("<task-notification>build finished</task-notification>", at: 2, extra: #","origin":{"kind":"task-notification"}"#)),
            .init(text: "Session", source: .title), "a background task's notice starts a turn nobody typed")
        XCTAssertEqual(
            reason(after: t.prompt("Now do the tests too.", at: 2, extra: #","isMeta":true,"origin":{"kind":"coordinator"}"#)),
            .init(text: "Now do the tests too.", source: .asked), "the coordinator's message is a subagent's prompt")
        // Typed while Claude was working: delivered with the next tool result.
        XCTAssertEqual(
            reason(
                after:
                    #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"also the README","commandMode":"prompt"},"uuid":"q","timestamp":"\#(t.stamp(2))","sessionId":"\#(session)"}"#
            ), .init(text: "also the README", source: .asked))
    }

    func testMalformedAndForeignLinesAreSkipped() {
        let edits = parse([
            "not json", "", #"{"type":"progress","data":{"type":"text"}}"#, t.prompt("go", at: 0), t.said("Going.", at: 1),
            #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: overloaded"}]},"isApiErrorMessage":true}"#,
            t.edit("toolu_1", "/r/a", at: 2), t.result("toolu_1", at: 3),
        ])
        XCTAssertEqual(reasons(edits), [said("Going.")], "an API error is not Claude's reason")
    }

    // MARK: By file

    private func made(_ path: String, _ text: String?, at second: Int, source: ClaudeEdit.Reason.Source = .said) -> ClaudeEdit {
        ClaudeEdit(
            path: path, tool: "Edit", time: base.addingTimeInterval(TimeInterval(second)), session: session, hunks: [], created: false,
            reason: text.map { .init(text: $0, source: source) })
    }

    func testOnlyFilesUnderTheRootByRelativePath() {
        let byFile = ClaudeEdits.byFile(
            [
                made("/r/app/Sources/a.swift", "inside", at: 1), made("/r/app-other/b.swift", "a look-alike folder", at: 2),
                made("/elsewhere/c.swift", "elsewhere", at: 3), made("/r/app/d.swift", nil, at: 4),
            ], root: URL(fileURLWithPath: "/r/app"))
        XCTAssertEqual(Array(byFile.keys), ["Sources/a.swift"], "outside the root, or with no reason: dropped")
        XCTAssertEqual(byFile["Sources/a.swift"]?.first?.reason?.text, "inside")
    }

    func testVarAndPrivateVarAreOnePlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-why-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(root.path.hasPrefix("/var/"), "the temporary directory is under the /var symlink: \(root.path)")
        let privateRoot = URL(fileURLWithPath: "/private" + root.path)
        let edits = [
            made(privateRoot.path + "/src/a.swift", "resolved", at: 1),
            made(root.path + "/src/gone/b.swift", "a file since deleted, in a folder since deleted", at: 2),
        ]
        for root in [root, privateRoot] {
            XCTAssertEqual(ClaudeEdits.byFile(edits, root: root).keys.sorted(), ["src/a.swift", "src/gone/b.swift"], root.path)
        }
    }

    func testNewestFirstOneEntryPerReasonAndACap() {
        let edits = [
            made("/r/a", "oldest", at: 1), made("/r/a", "twice", at: 2), made("/r/a", "twice", at: 3),
            made("/r/a", "third", at: 4), made("/r/a", "newest", at: 5), made("/r/b", "b's", at: 6),
        ]
        let byFile = ClaudeEdits.byFile(edits, root: URL(fileURLWithPath: "/r"), limit: 3)
        XCTAssertEqual(byFile["a"]?.map(\.reason?.text), ["newest", "third", "twice"])
        XCTAssertEqual(byFile["a"]?.map(\.time), [5, 4, 3].map { base.addingTimeInterval($0) }, "a repeated reason keeps its newest edit")
        XCTAssertEqual(byFile["b"]?.count, 1)
        let recent = ClaudeEdits.byFile(edits, root: URL(fileURLWithPath: "/r"), since: base.addingTimeInterval(4.5))
        XCTAssertEqual(recent["a"]?.map(\.reason?.text), ["newest"], "edits from before `since` are about older work")
    }

    func testRelativeTime() {
        let now = base
        XCTAssertEqual(ClaudeEdits.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(ClaudeEdits.ago(now.addingTimeInterval(-5 * 60), now: now), "5 min ago")
        XCTAssertEqual(ClaudeEdits.ago(now.addingTimeInterval(-3 * 3600 - 100), now: now), "3 h ago")
        XCTAssertEqual(ClaudeEdits.ago(now.addingTimeInterval(-2 * 86400), now: now), "2 d ago")
        XCTAssertEqual(ClaudeEdits.ago(now.addingTimeInterval(30), now: now), "just now", "a clock a little ahead")
    }

    // MARK: Reading transcripts

    private var projects: URL!

    override func setUpWithError() throws {
        projects = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-projects-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projects)
    }

    private func reader() -> ClaudeEditsReader {
        let projects = projects!
        return ClaudeEditsReader(projects: { projects })
    }

    func testReadsTheSessionsSubagentsToo() throws {
        try t.write(
            [t.prompt("rename it", at: 0), t.said("Renaming in the app.", at: 1), t.edit("toolu_1", "/r/app/a.swift", at: 2), t.result("toolu_1", at: 3)],
            to: projects, for: "/r/app")
        try t.write(
            [t.prompt("Update the tests for the rename.", at: 4), t.edit("toolu_9", "/r/app/aTests.swift", at: 5), t.bareResult("toolu_9", at: 6)],
            to: projects, for: "/r/app", subagent: "a1b2c3")
        // A session started below the checkout.
        var docs = t
        docs.session = "11111111-2222-3333-4444-555555555555"
        try docs.write(
            [t.prompt("docs", at: 7), t.said("Docs too.", at: 8), t.edit("toolu_2", "/r/app/docs/x.md", at: 9), t.result("toolu_2", at: 10)],
            to: projects, for: "/r/app/docs")
        let edits = reader().edits(in: ["/r/app"], since: .distantPast)
        XCTAssertEqual(Set(edits.map(\.path)), ["/r/app/a.swift", "/r/app/aTests.swift", "/r/app/docs/x.md"])
        let fromSubagent = edits.first { $0.path.hasSuffix("aTests.swift") }
        XCTAssertEqual(fromSubagent?.session, session, "a subagent's edits belong to its session")
        XCTAssertEqual(fromSubagent?.reason, .init(text: "Update the tests for the rename.", source: .asked), "what it was asked to do")
        XCTAssertEqual(reader().edits(in: ["/r/app/docs"], since: .distantPast).map(\.path), ["/r/app/docs/x.md"])
    }

    func testReadsWhatWasAppendedAndOnlyRecentTranscripts() throws {
        let file = try t.write([t.prompt("go", at: 0), t.said("Changing a.", at: 1), t.edit("toolu_1", "/r/a", at: 2)], to: projects, for: "/r")
        let reader = reader()
        XCTAssertEqual(reader.edits(in: ["/r"], since: .distantPast).count, 0, "no result yet")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let next = Data((t.result("toolu_1", at: 3) + "\n").utf8)
        try handle.write(contentsOf: next.dropLast(20))  // half a line, still being written
        XCTAssertEqual(reader.edits(in: ["/r"], since: .distantPast).count, 0, "a partial line is not read")
        try handle.write(contentsOf: next.suffix(20))
        try handle.write(contentsOf: Data([t.said("Changing b.", at: 4), t.edit("toolu_2", "/r/b", at: 5), t.result("toolu_2", at: 6), ""].joined(separator: "\n").utf8))
        try handle.close()
        XCTAssertEqual(reader.edits(in: ["/r"], since: .distantPast).map(\.reason?.text), ["Changing a.", "Changing b."], "the turn read before goes on")

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
        XCTAssertEqual(self.reader().edits(in: ["/r"], since: Date().addingTimeInterval(-60)).count, 0, "not written since")
    }

    /// Claude Code names the folder after its cwd, resolved (/private/var/…);
    /// the checkout may be known by its /var path.
    func testFindsTheFolderOfEitherSpelling() throws {
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-why-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        let resolved = "/private" + checkout.path
        try t.write([t.prompt("go", at: 0), t.edit("toolu_1", resolved + "/a", at: 1), t.result("toolu_1", at: 2)], to: projects, for: resolved)
        XCTAssertEqual(reader().edits(in: [checkout.path], since: .distantPast).count, 1)
    }
}
