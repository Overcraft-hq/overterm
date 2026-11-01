import AppKit
import SwiftUI
import XCTest

@testable import Overterm

/// The strip in the title bar: what its buttons cost in width, and who
/// answers for the space around them.
@MainActor
final class TabStripTests: XCTestCase {
    private let theme = ChromeTheme(
        background: NSColor(srgbRed: 0.086, green: 0.090, blue: 0.102, alpha: 1),
        foreground: NSColor(srgbRed: 0.922, green: 0.922, blue: 0.941, alpha: 1))

    private func width<V: View>(of view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        return host.fittingSize.width
    }

    /// The globe is an icon, like the phone beside it: the word "Browser"
    /// took room the tabs wanted and said nothing the icon doesn't.
    func testTheBrowserButtonIsItsIcon() {
        let globe = width(of: BrowserButton(isOpen: false, theme: theme, action: {}))
        let phone = width(of: SimulatorButton(isOpen: false, theme: theme, action: {}))
        // Within a glyph's width of the phone — the word made it 85.
        XCTAssertEqual(globe, phone, accuracy: 6, "globe \(globe), phone \(phone)")
        XCTAssertLessThan(globe, 40)
    }

    /// The tabs scroll, and the scroll view answers for the empty space
    /// beside them — which moves the window but never zooms it. Such an
    /// answer goes to the drag area instead.
    func testTheScrollViewDoesNotKeepTheEmptyStrip() {
        XCTAssertTrue(TabStripHostingView<EmptyView>.isEmptyStrip(NSClipView()))
        XCTAssertTrue(TabStripHostingView<EmptyView>.isEmptyStrip(NSScrollView()))
        XCTAssertFalse(TabStripHostingView<EmptyView>.isEmptyStrip(WindowDragView()))
        XCTAssertFalse(TabStripHostingView<EmptyView>.isEmptyStrip(NSButton()))
        XCTAssertFalse(TabStripHostingView<EmptyView>.isEmptyStrip(nil))
    }

    /// On macOS 27 the scroll view's content is one plain container that
    /// answers for the tabs SwiftUI handles (a review's, a page's, the
    /// island's +) and for the empty space after them alike: it is asked by
    /// place — in the scroll view, off the tabs' row.
    func testTheEmptyStripIsWhereNoTabIs() {
        let scroller = NSRect(x: 0, y: 0, width: 600, height: 52)
        let row = NSRect(x: 0, y: 8, width: 300, height: 36)
        let container = NSView()
        func empty(_ view: NSView?, _ x: CGFloat) -> Bool {
            TabStripHostingView<EmptyView>.isEmptyStrip(view, at: NSPoint(x: x, y: 26), scroller: scroller, row: row)
        }
        XCTAssertTrue(empty(container, 450), "after the last tab")
        XCTAssertFalse(empty(container, 150), "on a tab SwiftUI handles")
        XCTAssertFalse(empty(container, 650), "beside the scroll view: a chip")
        XCTAssertFalse(empty(StripPressNSView(), 450))
        XCTAssertFalse(empty(NSButton(), 450))
        XCTAssertFalse(empty(WindowDragView(), 450))
        XCTAssertFalse(TabStripHostingView<EmptyView>.isEmptyStrip(container), "nowhere measured, nothing taken")
    }
}
