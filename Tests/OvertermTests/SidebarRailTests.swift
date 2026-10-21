import XCTest

@testable import Overterm

/// The rail down the sidebar's edge: what it holds, in what order, and the
/// width it leaves the panel beside it.
@MainActor
final class SidebarRailTests: XCTestCase {
    /// Files first, then the three that are about what is running, then the
    /// API client — the order the rail draws and the order somebody reaches
    /// for them in.
    func testThePanelsInOrder() {
        XCTAssertEqual(SidebarPanel.allCases, [.files, .git, .sessions, .snippets, .api])
        XCTAssertEqual(SidebarPanel.files.title, "Files")
        XCTAssertEqual(SidebarPanel.git.title, "Overgit")
        XCTAssertEqual(SidebarPanel.api.title, "API")
    }

    /// The API client's icon is there only while Settings has it on.
    func testTheAPIPanelFollowsItsSetting() {
        XCTAssertEqual(SidebarPanel.shown.contains(.api), Settings.shared.apiEnabled)
        XCTAssertEqual(SidebarPanel.shown.filter { $0 != .api }, [.files, .git, .sessions, .snippets])
    }

    /// Four glyphs that can't be mistaken for each other — the whole point
    /// of a rail is telling them apart at 15 pt.
    func testEveryPanelHasItsOwnGlyph() {
        let symbols = SidebarPanel.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "\(symbols)")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }

    /// The foot of the rail: Settings, then the button that puts the
    /// sidebar away — the ✕ the old icon bar had.
    func testTheFootOfTheRail() {
        XCTAssertEqual(SidebarRailAction.allCases, [.settings, .hide])
        XCTAssertEqual(SidebarRailAction.settings.help, "Settings (⌘,)")
        XCTAssertEqual(SidebarRailAction.hide.help, "Hide Sidebar (⌘B)")
    }

    /// The rail's width is the column's to find, not the panel's to give
    /// up: a rail taken out of the old 180 pt minimum left every file name
    /// truncated at the narrowest width.
    func testTheColumnsMinimumHoldsBoth() {
        XCTAssertEqual(SidebarRail.minimumSidebarWidth, SidebarRail.width + SidebarRail.minimumPanelWidth)
        XCTAssertGreaterThanOrEqual(SidebarRail.minimumPanelWidth, 176)
    }
}
