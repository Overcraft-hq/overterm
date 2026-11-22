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

/// Settings ▸ Themes ▸ Themes by folder: which theme a tab's folder takes.
final class FolderThemesTests: XCTestCase {
    private let home = "/Users/ada"

    func testRulesFromLines() {
        XCTAssertEqual(
            FolderThemes.rules(["~/Projects/prod-* = Red Alert", "  # a comment", "", "no equals", "~/work = Nord"]),
            [.init(pattern: "~/Projects/prod-*", theme: "Red Alert"), .init(pattern: "~/work", theme: "Nord")])
    }

    func testAFolderTakesItselfAndWhatIsUnderIt() {
        let rules = FolderThemes.rules(["~/work = Nord"])
        XCTAssertEqual(FolderThemes.theme(for: "/Users/ada/work", rules: rules, home: home), "Nord")
        XCTAssertEqual(FolderThemes.theme(for: "/Users/ada/work/api/src", rules: rules, home: home), "Nord")
        XCTAssertNil(FolderThemes.theme(for: "/Users/ada/workshop", rules: rules, home: home), "a prefix of a name is not a folder")
    }

    func testAGlobAndTheFirstRuleWins() {
        let rules = FolderThemes.rules(["~/Projects/prod-* = Red Alert", "~/Projects = Nord"])
        XCTAssertEqual(FolderThemes.theme(for: "/Users/ada/Projects/prod-api", rules: rules, home: home), "Red Alert")
        XCTAssertEqual(FolderThemes.theme(for: "/Users/ada/Projects/prod-api/cmd/server", rules: rules, home: home), "Red Alert")
        XCTAssertEqual(FolderThemes.theme(for: "/Users/ada/Projects/staging", rules: rules, home: home), "Nord")
        XCTAssertNil(FolderThemes.theme(for: "/tmp", rules: rules, home: home))
    }

    /// Sessions written before a group had a theme still read.
    func testAGroupsThemeIsSavedAndOldSessionsRead() throws {
        let group = SessionState.GroupState(
            name: "api", color: "red", isCollapsed: false, isStashed: false, boundFolder: nil, restoresOnLaunch: true, takesNewTabs: nil,
            theme: "Dracula")
        let data = try JSONEncoder().encode(group)
        XCTAssertEqual(try JSONDecoder().decode(SessionState.GroupState.self, from: data).theme, "Dracula")
        let old = #"{"name":"api","color":"red","isCollapsed":false,"isStashed":false,"restoresOnLaunch":true}"#
        XCTAssertNil(try JSONDecoder().decode(SessionState.GroupState.self, from: Data(old.utf8)).theme)
    }
}
