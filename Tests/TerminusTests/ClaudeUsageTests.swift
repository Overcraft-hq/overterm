import XCTest

@testable import Terminus

final class ClaudeUsageTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func line(_ id: String, input: Int, output: Int, read: Int = 0, write: Int = 0, at time: String, model: String = "claude-opus-4-8") -> String {
        #"{"type":"assistant","timestamp":"\#(time)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write)}}}"#
            + "\n"
    }

    func testFolderNaming() {
        XCTAssertEqual(ClaudeUsageReader.projectFolder(for: "/Users/b/.claude"), "-Users-b--claude")
        XCTAssertEqual(ClaudeUsageReader.projectFolder(for: "/Users/b/Projects/acme/monorepo"), "-Users-b-Projects-acme-monorepo")
        XCTAssertEqual(ClaudeUsageReader.projectFolder(for: "/tmp/my repo_x"), "-tmp-my-repo-x")
    }

    func testRepliesRepeatedPerContentBlockCountOnce() throws {
        let text =
            #"{"type":"user","timestamp":"2026-09-23T10:00:00.000Z","message":{"role":"user","content":"hi"}}"# + "\n"
            + line("msg_1", input: 10, output: 5, read: 100, write: 50, at: "2026-09-23T10:00:01.000Z")
            + line("msg_1", input: 10, output: 5, read: 100, write: 50, at: "2026-09-23T10:00:02.000Z")
            + line("msg_1", input: 10, output: 5, read: 100, write: 50, at: "2026-09-23T10:00:03.000Z")
            + line("msg_2", input: 3, output: 7, at: "2026-09-23T10:02:00.000Z", model: "claude-sonnet-5")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let usage = try XCTUnwrap(ClaudeUsageReader().usage(of: file))
        XCTAssertEqual(usage.replies, 2)
        XCTAssertEqual([usage.input, usage.output, usage.cacheRead, usage.cacheWrite], [13, 12, 100, 50])
        XCTAssertEqual(usage.total, 175)
        XCTAssertEqual(usage.model, "claude-sonnet-5", "the latest reply's model")
        XCTAssertEqual(usage.lastActivity.map { $0.timeIntervalSince(usage.started!) }, 120)
    }

    func testReadsOnlyWhatWasAppendedAndSkipsAPartialLine() throws {
        try line("a", input: 1, output: 1, at: "2026-09-23T10:00:00.000Z").write(to: file, atomically: true, encoding: .utf8)
        let reader = ClaudeUsageReader()
        XCTAssertEqual(reader.usage(of: file)?.output, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let next = line("b", input: 2, output: 2, at: "2026-09-23T10:01:00.000Z")
        try handle.write(contentsOf: Data(next.dropLast(10).utf8))  // half a line, still being written
        XCTAssertEqual(reader.usage(of: file)?.output, 1, "a partial line is not read")
        try handle.write(contentsOf: Data(next.suffix(10).utf8))
        try handle.close()
        XCTAssertEqual(reader.usage(of: file)?.output, 3)
        XCTAssertEqual(reader.usage(of: file)?.replies, 2)
    }

    func testMalformedLinesAreSkipped() throws {
        try ("not json\n" + line("a", input: 1, output: 1, at: "2026-09-23T10:00:00.000Z")).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeUsageReader().usage(of: file)?.replies, 1)
    }

    /// The real transcripts, when there are any: parse without error and add
    /// up to something. Catches Claude Code changing its format.
    func testReadsARealTranscriptIfPresent() throws {
        // The biggest transcript: a short one may be a session abandoned
        // before any reply.
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: ClaudeUsageReader.projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        let transcripts = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey])) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard let transcript = transcripts.max(by: { size($0) < size($1) }) else {
            throw XCTSkip("no Claude Code transcripts on this machine")
        }
        let usage = try XCTUnwrap(ClaudeUsageReader().usage(of: transcript))
        XCTAssertGreaterThan(usage.replies, 0, "format changed? \(transcript.path)")
        XCTAssertGreaterThan(usage.total, 0)
        XCTAssertNotNil(usage.model)
    }
}

final class TokenFormatTests: XCTestCase {
    func testCompactTokens() {
        XCTAssertEqual(TabInfoView.tokens(950), "950")
        XCTAssertEqual(TabInfoView.tokens(1_234), "1.2K")
        XCTAssertEqual(TabInfoView.tokens(84_000), "84K")
        XCTAssertEqual(TabInfoView.tokens(1_200_000), "1.2M")
        XCTAssertEqual(TabInfoView.tokens(38_400_000), "38M")
        XCTAssertEqual(TabInfoView.tokens(2_100_000_000), "2.1B")
    }

    func testMemoryIsNeverSpelledOut() {
        XCTAssertFalse(TabInfoView.memory(0).contains("Zero"), TabInfoView.memory(0))
    }
}
