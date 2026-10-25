import AppKit
import XCTest

@testable import Overterm

/// Live Preview's attributes: markup hidden but on the line being edited,
/// the text styled, nothing styled inside code.
final class NoteLivePreviewTests: XCTestCase {
    private let style = NoteLivePreview(
        fonts: .init(body: .systemFont(ofSize: 14), mono: .monospacedSystemFont(ofSize: 13, weight: .regular)),
        colors: .init(text: .white, muted: .gray, accent: .blue, mark: .yellow, code: .green, heading: .white))

    /// The text with what would be hidden left out.
    private func shown(_ text: String, caret: Int? = nil) -> String {
        let ns = text as NSString
        let storage = NSMutableAttributedString(string: text)
        let runs = style.runs(
            in: ns, range: NSRange(location: 0, length: ns.length), editing: caret.map { [NSRange(location: $0, length: 0)] } ?? [],
            blocks: NoteLivePreview.blocks(in: ns))
        for run in runs { storage.addAttributes(run.attributes, range: run.range) }
        var out = ""
        storage.enumerateAttribute(.noteHidden, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            if value == nil { out += ns.substring(with: range) }
        }
        return out
    }

    func testMarkupIsHiddenOffTheCaretsLine() {
        let text = "# Title\nSome **bold**, *it*, ~~gone~~, ==mark== and `code **not**`.\nSee [[Plan#Goals|the plan]] and [site](https://x.dev)."
        XCTAssertEqual(shown(text), "Title\nSome bold, it, gone, mark and code **not**.\nSee the plan and site.")
        XCTAssertEqual(shown("a %%secret%% b\nnext", caret: 0), "a %%secret%% b\nnext")
        XCTAssertEqual(shown("a %%secret%% b\nnext", caret: 16), "a  b\nnext")
    }

    func testTheCaretsLineShowsItsMarkup() {
        let text = "# Title\n**bold** here"
        XCTAssertEqual(shown(text, caret: 10), "Title\n**bold** here")
        XCTAssertEqual(shown(text, caret: 2), "# Title\nbold here")
    }

    func testQuotesCalloutsAndTasks() {
        let text = "> [!note] Heads up\n> inside\n- [ ] todo\n- [x] done"
        // Task boxes stay as (clear) characters, so the box has room.
        XCTAssertEqual(shown(text), "Heads up\ninside\n- [ ] todo\n- [x] done")
        let ns = text as NSString
        let runs = style.runs(in: ns, range: NSRange(location: 0, length: ns.length), editing: [], blocks: [])
        let boxes = runs.compactMap { $0.attributes[.noteDecoration] as? NoteDecoration }.filter {
            if case .checkbox = $0 { return true }; return false
        }
        XCTAssertEqual(boxes, [.checkbox(done: false), .checkbox(done: true)])
    }

    func testCodeBlocksAndFrontmatterAreLeftAsWritten() {
        let text = "---\ntags: [a]\n---\n```\n**not bold** [[nolink]]\n```\nafter **b**"
        XCTAssertEqual(shown(text), "---\ntags: [a]\n---\n```\n**not bold** [[nolink]]\n```\nafter b")
    }

    func testLinksCarryWhatAClickFollows() {
        let text = "[[Plan#Goals|the plan]] [doc](My%20Note.md) [web](https://x.dev)"
        let ns = text as NSString
        let storage = NSMutableAttributedString(string: text)
        for run in style.runs(in: ns, range: NSRange(location: 0, length: ns.length), editing: [], blocks: []) {
            storage.addAttributes(run.attributes, range: run.range)
        }
        XCTAssertEqual(storage.attribute(.noteLink, at: ns.range(of: "the plan").location, effectiveRange: nil) as? String, "Plan#Goals")
        XCTAssertEqual(storage.attribute(.noteLink, at: ns.range(of: "doc").location, effectiveRange: nil) as? String, "md:My Note.md")
        XCTAssertEqual(storage.attribute(.noteURL, at: ns.range(of: "web").location, effectiveRange: nil) as? String, "https://x.dev")
    }
}
