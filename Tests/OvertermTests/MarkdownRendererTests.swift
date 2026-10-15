import AppKit
import XCTest

@testable import Overterm

final class MarkdownRendererTests: XCTestCase {
    private let theme = EditorTheme(dark: true, background: .black)

    private func render(_ markdown: String) -> NSAttributedString { MarkdownRenderer.render(markdown, theme: theme) }

    private func attributes(of needle: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) in \(text.string)")
        return range.location == NSNotFound ? [:] : text.attributes(at: range.location, effectiveRange: nil)
    }

    func testHeadingsAreBigAndBold() {
        let text = render("# Title\n\nBody text.")
        let title = attributes(of: "Title", in: text)[.font] as? NSFont
        let body = attributes(of: "Body", in: text)[.font] as? NSFont
        XCTAssertGreaterThan(title?.pointSize ?? 0, (body?.pointSize ?? 0) * 1.5)
        XCTAssertTrue(NSFontManager.shared.traits(of: title!).contains(.boldFontMask))
        XCTAssertFalse(text.string.contains("#"), "the marker is markup, not text")
    }

    func testInlineStylesAndLinks() {
        let text = render("Some **bold**, *slanted* and `code` with [a link](CLAUDE.md).")
        XCTAssertTrue(NSFontManager.shared.traits(of: attributes(of: "bold", in: text)[.font] as! NSFont).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: attributes(of: "slanted", in: text)[.font] as! NSFont).contains(.italicFontMask))
        XCTAssertTrue((attributes(of: "code", in: text)[.font] as? NSFont)?.isFixedPitch == true)
        XCTAssertEqual((attributes(of: "a link", in: text)[.link] as? URL)?.relativeString, "CLAUDE.md")
        XCTAssertFalse(text.string.contains("**"))
    }

    func testListsGetMarkers() {
        let text = render("- one\n- two\n\n1. first\n2. second\n")
        XCTAssertTrue(text.string.contains("•\tone"), text.string)
        XCTAssertTrue(text.string.contains("2.\tsecond"), text.string)
    }

    func testCodeBlocksAreMonospacedOnASurface() {
        let text = render("```go\nfunc a() {}\n```\n")
        let attributes = attributes(of: "func a()", in: text)
        XCTAssertTrue((attributes[.font] as? NSFont)?.isFixedPitch == true)
        let block = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first
        XCTAssertNotNil(block?.backgroundColor)
        // Without a width a block is as narrow as it can be: a character wide.
        XCTAssertEqual(block?.contentWidth, 100)
        XCTAssertEqual(block?.contentWidthValueType, .percentageValueType)
        XCTAssertFalse(text.string.contains("```"))
    }

    func testTablesAreTables() {
        let text = render("| A | B |\n|---|---|\n| 1 | 2 |\n")
        let style = attributes(of: "2", in: text)[.paragraphStyle] as? NSParagraphStyle
        let cell = style?.textBlocks.first as? NSTextTableBlock
        XCTAssertEqual(cell?.table.numberOfColumns, 2)
        XCTAssertEqual(cell?.startingRow, 1)
        XCTAssertEqual(cell?.startingColumn, 1)
        XCTAssertFalse(text.string.contains("|"))
    }
}
