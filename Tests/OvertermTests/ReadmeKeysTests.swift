import XCTest

@testable import Overterm

/// README's Keys table is the one list of keys outside the app: a command
/// in the menu with a default key it doesn't name fails here (DISC-G4).
final class ReadmeKeysTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// macOS's own, and the editor's — Settings ▸ Keyboard Shortcuts lists
    /// those, as the table says.
    private static let left = Set(["app.hide", "app.hideOthers", "app.quit", "window.minimize", "window.close"])
    private static let leftGroups = Set(["Editor", "Editing"])
    /// Rows that stand for several keys.
    private static let ranges = ["groups.goto": "⌃⌘1…9", "columns.": "⌃⌥⌘1…5"]

    func testEveryMenuCommandsDefaultKeyIsInTheTable() throws {
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let start = try XCTUnwrap(readme.range(of: "## Keys"))
        let end = try XCTUnwrap(readme.range(of: "\n## ", range: start.upperBound..<readme.endIndex))
        let table = readme[start.upperBound..<end.lowerBound]
        var missing: [String] = []
        for command in KeyCommands.all where command.menu && !Self.left.contains(command.id) && !Self.leftGroups.contains(command.group) {
            guard let key = command.defaultKey.flatMap(KeyCombo.init)?.display else { continue }
            if table.contains(key) { continue }
            if let range = Self.ranges.first(where: { command.id.hasPrefix($0.key) }), table.contains(range.value) { continue }
            missing.append("\(command.id) \(key)")
        }
        XCTAssertEqual(missing, [], "README.md's Keys table lacks these")
    }
}
