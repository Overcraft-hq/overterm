import XCTest

@testable import Overterm
@testable import OvertermCore

/// GIT-G3: where a pick lands on GitHub, the threads at their lines, and
/// the one request a review is posted as.
final class ReviewCommentsTests: XCTestCase {
    private func line(_ id: Int, _ kind: DiffLine.Kind, old: Int? = nil, new: Int? = nil) -> DiffLine {
        DiffLine(id: id, kind: kind, text: "x\(id)", oldNumber: old, newNumber: new)
    }

    func testAPickLandsOnItsSides() throws {
        let one = try ReviewComments.anchor([line(3, .added, new: 12)]).get()
        XCTAssertEqual(one, ReviewComments.Anchor(startLine: nil, startSide: nil, line: 12, side: .right))
        let removed = try ReviewComments.anchor([line(3, .removed, old: 7)]).get()
        XCTAssertEqual(removed.side, .left)
        XCTAssertEqual(removed.line, 7)
        // From a removed line to an added one: both sides said.
        let across = try ReviewComments.anchor([line(2, .removed, old: 7), line(3, .context, old: 8, new: 9), line(4, .added, new: 10)]).get()
        XCTAssertEqual(across, ReviewComments.Anchor(startLine: 7, startSide: .left, line: 10, side: .right))
        // A hunk's header picked at the start is passed over.
        XCTAssertEqual(try ReviewComments.anchor([line(1, .hunk), line(2, .added, new: 1)]).get().line, 1)
    }

    func testACommentStaysInOneHunk() {
        guard case .failure(let refusal) = ReviewComments.anchor([line(1, .added, new: 1), line(2, .hunk), line(3, .added, new: 40)]) else {
            return XCTFail("across two hunks GitHub refuses it")
        }
        XCTAssertTrue(refusal.message.contains("within one change"), refusal.message)
    }

    func testThreadsAreDrawnUnderTheirLineOnTheirSide() throws {
        let json = #"""
            [{"id": 1, "path": "a.go", "line": 2, "side": "RIGHT", "body": "new side", "user": {"login": "ana"}},
             {"id": 2, "path": "a.go", "line": 5, "side": "LEFT", "body": "old side", "user": {"login": "bo"}},
             {"id": 3, "path": "a.go", "body": "outdated", "user": {"login": "cy"}},
             {"id": 4, "path": "b.go", "line": 2, "body": "another file", "user": {"login": "dee"}}]
            """#
        let threads = try ReviewThread.parse(Data(json.utf8))
        XCTAssertEqual(threads.first { $0.id == 2 }?.side, .left)
        let lines = [line(10, .context, old: 1, new: 1), line(11, .added, new: 2), line(12, .removed, old: 5), line(13, .context, old: 6, new: 3)]
        let placed = ReviewComments.placed(threads, path: "a.go", lines: lines)
        XCTAssertEqual(placed[11]?.map(\.id), [1])
        XCTAssertEqual(placed[12]?.map(\.id), [2], "a LEFT thread under the removed line of that number")
        XCTAssertEqual(placed.values.flatMap { $0 }.count, 2, "an outdated thread and another file's are drawn nowhere")
    }

    func testTheReviewIsOneRequest() throws {
        let comments = [
            ReviewDraftComment(path: "a.go", anchor: .init(startLine: nil, startSide: nil, line: 2, side: .right), body: "Rename it."),
            ReviewDraftComment(path: "a.go", anchor: .init(startLine: 7, startSide: .left, line: 10, side: .right), body: "Why?"),
        ]
        let data = ReviewComments.request(comments, event: .requestChanges, body: "  Two things. ", commit: "abc123")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "REQUEST_CHANGES")
        XCTAssertEqual(object["body"] as? String, "Two things.")
        XCTAssertEqual(object["commit_id"] as? String, "abc123")
        let sent = try XCTUnwrap(object["comments"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["line"] as? Int, 2)
        XCTAssertNil(sent[0]["start_line"])
        XCTAssertEqual(sent[1]["start_line"] as? Int, 7)
        XCTAssertEqual(sent[1]["start_side"] as? String, "LEFT")
        XCTAssertEqual(sent[1]["side"] as? String, "RIGHT")
        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: ReviewComments.request(comments, event: .comment, body: "", commit: nil)) as? [String: Any])
        XCTAssertNil(bare["body"])
        XCTAssertNil(bare["commit_id"])
    }

    func testTheQuestionSaysWhatGoesAndWhere() {
        let comment = ReviewDraftComment(path: "a.go", anchor: .init(startLine: 3, startSide: .right, line: 5, side: .right), body: "Split this.\nMore.")
        XCTAssertEqual(comment.span, "lines 3–5")
        let asked = ReviewComments.question(number: 9, title: "Speed up", comments: [comment], event: .approve)
        XCTAssertEqual(asked.title, "Approve #9 Speed up, with 1 comment?")
        XCTAssertTrue(asked.detail.hasPrefix("• a.go, lines 3–5: Split this.\n\n"), asked.detail)
        XCTAssertTrue(asked.detail.contains("as one review"))
    }
}
