import XCTest

@testable import Overterm

/// A page's list keys (`ResourceKey`): a typed character read by a page's
/// table — the named keys, case, digits to sections, `?` and `/` — and an
/// open sheet of keys closing on any key. Docker's table is one; a second
/// page's is another.
final class ResourceKeyTests: XCTestCase {
    /// A page's table that is not Docker's.
    private enum Fruit: String, ResourceKey {
        case open, quickLook, remove, delete, deleteAll, first, second, help, filter

        enum Section: Equatable { case apples, pears }

        var key: String {
            switch self {
            case .open: "↩"
            case .quickLook: "Space"
            case .remove: "⌫"
            case .delete: "d"
            case .deleteAll: "D"
            case .first: "1"
            case .second: "2"
            case .help: "?"
            case .filter: "/"
            }
        }

        var title: String { rawValue }

        var section: Section? {
            switch self {
            case .first: .apples
            case .second: .pears
            default: nil
            }
        }
    }

    private func pressed(_ characters: String, sheet: Bool = false) -> String? {
        guard let press = Fruit.press(characters, sheetShowing: sheet) else { return nil }
        switch press {
        case .closeSheet: return "close"
        case .section(let section): return "section \(section)"
        case .help: return "help"
        case .filter: return "filter"
        case .key(let key): return key.rawValue
        }
    }

    func testTypedCharactersAreTheTablesKeys() {
        XCTAssertEqual(Fruit.of("\r"), .open)
        XCTAssertEqual(Fruit.of(" "), .quickLook)
        XCTAssertEqual(Fruit.of("\u{7F}"), .remove, "delete")
        XCTAssertEqual(Fruit.of("\u{08}"), .remove, "backspace")
        XCTAssertEqual(Fruit.of("d"), .delete)
        XCTAssertEqual(Fruit.of("D"), .deleteAll, "case matters")
        XCTAssertNil(Fruit.of("x"))
        XCTAssertNil(Fruit.of("Space"), "a key's name is not what is typed")
        XCTAssertNil(Fruit.of(""))
    }

    func testDigitsAreSectionsAndQuestionMarkAndSlashEveryPages() {
        XCTAssertEqual(pressed("1"), "section apples")
        XCTAssertEqual(pressed("2"), "section pears")
        XCTAssertEqual(pressed("?"), "help")
        XCTAssertEqual(pressed("/"), "filter")
        XCTAssertEqual(pressed("d"), "delete")
        XCTAssertEqual(pressed("\r"), "open")
        XCTAssertNil(pressed("3"), "a digit with no section goes on to the list")
        XCTAssertNil(pressed("x"))
    }

    func testAnOpenSheetTakesAnyKeyToClose() {
        for typed in ["d", "1", "?", "x", "\r"] {
            XCTAssertEqual(pressed(typed, sheet: true), "close", typed)
        }
    }

    func testTablesAreWellFormed() {
        XCTAssertTrue(Fruit.isWellFormed)
        XCTAssertTrue(DockerKey.isWellFormed, "no Docker key twice, each reachable by typing")
    }

    func testDockersTableReadAsBefore() {
        XCTAssertEqual(DockerKey.of("\u{08}"), .remove)
        XCTAssertEqual(DockerKey.of("n"), .run)
        for (digit, section) in [("1", DockerPageModel.Section.containers), ("2", .images), ("3", .volumes), ("4", .networks), ("5", .builds), ("6", .models)] {
            guard case .section(let went) = DockerKey.press(digit, sheetShowing: false) else { return XCTFail(digit) }
            XCTAssertEqual(went, section, digit)
        }
        XCTAssertNil(DockerKey.press("7", sheetShowing: false))
        guard case .help = DockerKey.press("?", sheetShowing: false) else { return XCTFail("?") }
        guard case .filter = DockerKey.press("/", sheetShowing: false) else { return XCTFail("/") }
        guard case .key(.cleanUp) = DockerKey.press("c", sheetShowing: false) else { return XCTFail("c") }
    }
}
