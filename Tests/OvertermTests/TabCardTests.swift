import SwiftUI
import XCTest

@testable import Overterm

/// The strip's card geometry.
///
/// Three heights were picked separately once — 36 for an island, 30 for
/// a tab, 28 for the Settings tab — and a group then sat visibly taller
/// than the tab beside it. These are the relations that have to hold,
/// so the numbers cannot drift apart again without a failure.
final class TabCardTests: XCTestCase {
    /// An island is a card with a tab inside it: its inset, twice, plus
    /// what it holds, is the height of a loose tab beside it.
    func testAnIslandIsExactlyAsTallAsALooseTab() {
        XCTAssertEqual(TabCard.nested + TabCard.inset * 2, TabCard.height)
    }

    /// Nested corners are concentric only if the outer radius is the
    /// inner one plus the gap between them.
    func testTheRadiiAreConcentric() {
        XCTAssertEqual(TabCard.radius, TabCard.nestedRadius + TabCard.inset)
    }

    /// The strip is the row the traffic lights are centred in; a card
    /// has to fit in it with room above and below. The strip's height is
    /// an NSView's, on the main actor: Swift 6.1 won't read it from the
    /// assertion's autoclosure otherwise.
    @MainActor
    func testACardFitsTheStrip() {
        XCTAssertLessThan(TabCard.height, TabStripHostingView<AnyView>.height)
        XCTAssertGreaterThanOrEqual(
            (TabStripHostingView<AnyView>.height - TabCard.height) / 2, 6,
            "a card this tall leaves no band of title bar around it")
    }
}
