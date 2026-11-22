import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity

/// The rail down the sidebar's edge: what it holds, in what order, and the
/// width it leaves the panel beside it.
@MainActor
final class SidebarRailTests: XCTestCase {
    /// Files first, then the three that are about what is running, then the
    /// API client and the notes — the order the rail draws and the order
    /// somebody reaches for them in.
    func testThePanelsInOrder() {
        XCTAssertEqual(SidebarPanel.allCases, [.files, .git, .sessions, .snippets, .api, .notes, .database, .docker, .kubernetes, .terraform])
        XCTAssertEqual(SidebarPanel.files.title, "Files")
        XCTAssertEqual(SidebarPanel.git.title, "Overgit")
        XCTAssertEqual(SidebarPanel.api.title, "API")
        XCTAssertEqual(SidebarPanel.notes.title, "Notes")
        XCTAssertEqual(SidebarPanel.terraform.title, "Terraform")
        XCTAssertEqual(SidebarPanel.terraform.toggleKey, "terraform.enabled")
    }

    /// The optional panels' icons are there only while Settings has them
    /// on — this Mac's settings, whatever they say; Files and Overgit always.
    func testThePanelsThatFollowTheirSettings() {
        XCTAssertEqual(SidebarPanel.shown.contains(.api), Settings.shared.apiEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.notes), Settings.shared.notesEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.database), Settings.shared.databaseEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.docker), Settings.shared.dockerEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.kubernetes), Settings.shared.kubernetesEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.terraform), Settings.shared.terraformEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.sessions), Settings.shared.sessionsEnabled)
        XCTAssertEqual(SidebarPanel.shown.contains(.snippets), Settings.shared.snippetsEnabled)
        XCTAssertEqual(SidebarPanel.shown, SidebarPanel.order.filter(\.isEnabled), "in the user's order")
    }

    /// The order settings.json gives: what it names first, what it doesn't
    /// know (another version's panel, a typo, a repeat) passed over, and
    /// what it leaves out after — so a new panel turns up in an old order.
    func testTheUsersOrder() {
        XCTAssertEqual(SidebarPanel.ordered([]), SidebarPanel.allCases)
        XCTAssertEqual(
            SidebarPanel.ordered(["database", "files", "nope", "database", "git"]),
            [.database, .files, .git, .sessions, .snippets, .api, .notes, .docker, .kubernetes, .terraform])
    }

    /// Moving goes past the next icon you can see: a hidden panel between
    /// the two is not a step that does nothing.
    func testMovingSkipsHiddenPanels() {
        let order = SidebarPanel.allCases
        let visible: [SidebarPanel] = [.files, .git, .api, .database]  // sessions, snippets, notes, docker off
        XCTAssertEqual(
            SidebarPanel.moving(.api, by: -1, in: order, visible: visible),
            [.files, .api, .git, .sessions, .snippets, .notes, .database, .docker, .kubernetes, .terraform])
        XCTAssertEqual(
            SidebarPanel.moving(.api, by: 1, in: order, visible: visible),
            [.files, .git, .sessions, .snippets, .notes, .database, .api, .docker, .kubernetes, .terraform])
        XCTAssertEqual(SidebarPanel.moving(.files, by: -1, in: order, visible: visible), order, "nothing before the first")
        XCTAssertEqual(SidebarPanel.moving(.database, by: 1, in: order, visible: visible), order, "nothing after the last")
    }

    /// The panels that can be hidden say which toggle does it; Files and
    /// Overgit are always there.
    func testEachOptionalPanelHasItsToggle() {
        XCTAssertNil(SidebarPanel.files.toggleKey)
        XCTAssertNil(SidebarPanel.git.toggleKey)
        for panel in SidebarPanel.allCases {
            if let key = panel.toggleKey { XCTAssertNotNil(SettingsSchema.byKey[key], key) }
        }
    }

    /// Glyphs that can't be mistaken for each other — the whole point
    /// of a rail is telling them apart at 15 pt.
    func testEveryPanelHasItsOwnGlyph() {
        let symbols = SidebarPanel.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "\(symbols)")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }

    /// The foot of the rail: the Activity page, Settings, then the button
    /// that puts the sidebar away — the ✕ the old icon bar had. Activity's
    /// only while Settings has it on.
    func testTheFootOfTheRail() {
        XCTAssertEqual(SidebarRailAction.allCases, [.activity, .settings, .hide])
        XCTAssertEqual(SidebarRailAction.activity.help, "Activity (⌥⌘A)")
        XCTAssertEqual(SidebarRailAction.settings.help, "Settings (⌘,)")
        XCTAssertEqual(SidebarRailAction.hide.help, "Hide Sidebar (⌘B)")
        XCTAssertEqual(
            SidebarRailAction.shown,
            Settings.shared.activityEnabled ? [.activity, .settings, .hide] : [.settings, .hide])
        let symbols = SidebarRailAction.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "\(symbols)")
    }

    /// The rail's width is the column's to find, not the panel's to give
    /// up: a rail taken out of the old 180 pt minimum left every file name
    /// truncated at the narrowest width.
    func testTheColumnsMinimumHoldsBoth() {
        XCTAssertEqual(SidebarRail.minimumSidebarWidth, SidebarRail.width + SidebarRail.minimumPanelWidth)
        XCTAssertGreaterThanOrEqual(SidebarRail.minimumPanelWidth, 176)
    }
}
