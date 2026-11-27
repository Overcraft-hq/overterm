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
@testable import OvertermE2E

/// Issue #31's third patch, the editor beside an agent: the Edit menu's
/// Undo, Redo and Cut (EDIT-U3), the tree's git marks and following the
/// editor (EDIT-G6, EDIT-U2), Go to File's query (EDIT-G1) and ⌘L's text
/// from the editor (EDIT-N1).
@MainActor
final class EditorBesideTests: XCTestCase {
    // MARK: EDIT-U3

    func testUndoRedoAndCutAreEditMenuCommandsOnTheirKeys() {
        // MainMenu.build() sets NSApp.windowsMenu.
        _ = NSApplication.shared
        let edit = MainMenu.build().items.first { $0.submenu?.title == "Edit" }?.submenu
        func item(_ id: String) -> NSMenuItem? { edit?.items.first { $0.identifier?.rawValue == id } }
        XCTAssertEqual(item("edit.undo")?.action, Selector(("undo:")))
        XCTAssertEqual(item("edit.redo")?.action, Selector(("redo:")))
        XCTAssertEqual(item("edit.cut")?.action, #selector(NSText.cut(_:)))
        XCTAssertEqual(KeyCommands.byID["edit.undo"]?.defaultKey, "cmd+z")
        XCTAssertEqual(KeyCommands.byID["edit.redo"]?.defaultKey, "shift+cmd+z")
        XCTAssertEqual(KeyCommands.byID["edit.cut"]?.defaultKey, "cmd+x")
        // Nil target: whatever has the keyboard answers — the terminal has no say.
        XCTAssertNil(item("edit.undo")?.target)
    }

    /// The terminal keeps Ghostty's own ⌘Z and ⇧⌘Z: no unbind is written
    /// for them, whether or not Ghostty reports its key.
    func testTheTerminalKeepsGhosttysUndoKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for reported in [false, true] {
            let keys = Keybindings(
                url: dir.appendingPathComponent("keybindings.json"),
                ghosttyDefault: { action in
                    guard reported else { return nil }
                    return ["undo": KeyCombo("cmd+z"), "redo": KeyCombo("shift+cmd+z")][action] ?? nil
                }, watch: false)
            XCTAssertFalse(keys.ghosttyLines.contains("keybind = super+z=unbind"), "\(keys.ghosttyLines)")
            XCTAssertFalse(keys.ghosttyLines.contains("keybind = shift+super+z=unbind"), "\(keys.ghosttyLines)")
        }
    }

    // MARK: EDIT-G1

    func testGoToFileIsTheEditorsCmdP() {
        let command = KeyCommands.byID["editor.goToFile"]
        XCTAssertEqual(command?.defaultKey, "cmd+p")
        XCTAssertEqual(command?.editor, true)
        XCTAssertEqual(KeyCommands.all.filter { $0.defaultKey == "cmd+p" }.map(\.id), ["editor.goToFile"])
        XCTAssertEqual(KeyCommands.byID["view.presentation"]?.defaultKey, "shift+ctrl+cmd+p")
    }

    func testGoToFileQueryReadsNameLineAndColumn() {
        XCTAssertEqual(GoToFileQuery("main.swift"), GoToFileQuery(name: "main.swift"))
        XCTAssertEqual(GoToFileQuery("main.swift:12"), GoToFileQuery(name: "main.swift", line: 12))
        XCTAssertEqual(GoToFileQuery(" main.swift:12:4 "), GoToFileQuery(name: "main.swift", line: 12, column: 4))
        XCTAssertEqual(GoToFileQuery("main.swift:"), GoToFileQuery(name: "main.swift"))
        XCTAssertEqual(GoToFileQuery("main.swift:0"), GoToFileQuery(name: "main.swift", line: 1))
        XCTAssertEqual(GoToFileQuery("a:b.txt"), GoToFileQuery(name: "a:b.txt"))
        XCTAssertEqual(GoToFileQuery(""), GoToFileQuery(name: ""))
    }

    func testGoToFileRanksByNameAndListsFilesWithNoQuery() {
        let files = ["README.md", "Sources/App/main.swift", "Sources/App/Model.swift", "Tests/mainTests.swift"]
        XCTAssertEqual(GoToFileQuery("main.swift:3").ranked(files).first, "Sources/App/main.swift")
        XCTAssertEqual(GoToFileQuery("").ranked(files, limit: 2), ["README.md", "Sources/App/main.swift"])
        XCTAssertEqual(GoToFileQuery("zzz").ranked(files), [])
    }

    // MARK: EDIT-G6

    private let root = URL(fileURLWithPath: "/tmp/checkout")

    private func change(_ path: String, _ kind: ChangedFile.Kind) -> ChangedFile {
        ChangedFile(path: path, originalPath: nil, kind: kind, isStaged: false, hasUnstaged: true)
    }

    func testMarksTintFilesAndDotTheirFolders() {
        let marks = FileTreeMarks(
            root: root,
            changed: [
                change("Sources/App/main.swift", .modified), change("Sources/App/New.swift", .untracked),
                change("Sources/Lib/merge.swift", .conflicted), change("docs/gone.md", .deleted), change("added.txt", .added),
                change("Sources/App/Renamed.swift", .renamed),
            ])
        func mark(_ path: String, folder: Bool = false) -> FileMark? {
            marks.mark(for: root.appendingPathComponent(path), isDirectory: folder)
        }
        XCTAssertEqual(mark("Sources/App/main.swift"), .modified)
        XCTAssertEqual(mark("Sources/App/New.swift"), .untracked)
        XCTAssertEqual(mark("Sources/App/Renamed.swift"), .modified)
        XCTAssertEqual(mark("added.txt"), .added)
        XCTAssertNil(mark("docs/gone.md"), "a deleted file has no row")
        XCTAssertNil(mark("Sources/App/untouched.swift"))
        // A folder: the worst under it.
        XCTAssertEqual(mark("Sources", folder: true), .conflicted)
        XCTAssertEqual(mark("Sources/App", folder: true), .modified)
        XCTAssertEqual(mark("docs", folder: true), .modified, "a deletion marks its folder")
        XCTAssertNil(mark("Tests", folder: true))
        // Outside the checkout, nothing.
        XCTAssertNil(marks.mark(for: URL(fileURLWithPath: "/tmp/other/added.txt"), isDirectory: false))
    }

    func testMarksMatchTmpAndPrivateTmpAlike() {
        let marks = FileTreeMarks(root: URL(fileURLWithPath: "/private/tmp/checkout"), changed: [change("a.swift", .modified)])
        XCTAssertEqual(marks.mark(for: URL(fileURLWithPath: "/tmp/checkout/a.swift"), isDirectory: false), .modified)
        XCTAssertEqual(FileTreeMarks.relative("/private/var/x/a", to: "/var/x"), "a")
        XCTAssertNil(FileTreeMarks.relative("/var/xy/a", to: "/var/x"))
    }

    func testChangedOnlyRowsAreTheChangedFilesUnderTheirFolders() {
        let marks = FileTreeMarks(
            root: root,
            changed: [
                change("b.txt", .modified), change("Sources/App/main.swift", .modified), change("Sources/App/A.swift", .added),
                change("gone/old.md", .deleted),
            ])
        let rows = marks.changedRows().map { "\(String(repeating: " ", count: $0.depth))\($0.path)\($0.isDirectory ? "/" : "")" }
        XCTAssertEqual(rows, ["Sources/", " Sources/App/", "  Sources/App/A.swift", "  Sources/App/main.swift", "b.txt"])
    }

    func testTheTreeTakesOnlyItsOwnCheckoutsChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("src/a.swift").path, contents: Data())
        let tree = FileTreeModel()
        tree.setRoot(dir)
        tree.setChanges([change("src/a.swift", .modified)], root: dir.deletingLastPathComponent())
        XCTAssertTrue(tree.marks.isEmpty, "another checkout's paths mean nothing here")
        tree.setChanges([change("src/a.swift", .modified)], root: dir)
        XCTAssertEqual(tree.marks.mark(for: dir.appendingPathComponent("src/a.swift"), isDirectory: false), .modified)
        tree.changedOnly = true
        XCTAssertEqual(tree.visibleRows.map(\.entry.name), ["src", "a.swift"])
        tree.changedOnly = false
        XCTAssertEqual(tree.visibleRows.map(\.entry.name), ["src"])
    }

    // MARK: EDIT-U2

    func testRevealOpensTheFoldersDownToTheFileAndSelectsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a/b/c/deep.txt").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("top.txt").path, contents: Data())
        let tree = FileTreeModel()
        tree.setRoot(dir)
        XCTAssertEqual(tree.rows.map(\.entry.name), ["a", "top.txt"])
        XCTAssertTrue(tree.reveal(dir.appendingPathComponent("a/b/c/deep.txt")))
        XCTAssertEqual(tree.rows.map(\.entry.name), ["a", "b", "c", "deep.txt", "top.txt"])
        XCTAssertEqual(tree.selectedRow?.entry.name, "deep.txt")
        // Outside the root, and the root itself: nothing to reveal.
        XCTAssertFalse(tree.reveal(URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertFalse(tree.reveal(dir))
        XCTAssertFalse(tree.reveal(URL(fileURLWithPath: "/")))
        XCTAssertEqual(tree.selectedRow?.entry.name, "deep.txt")
    }

    // MARK: EDIT-N1

    func testTheEditorsAskCarriesPathLinesTextAndProblem() {
        let text = EditorAskSelection.text(
            path: "Sources/main.swift", first: 12, last: 14, selection: "let a = 1\nlet b = a\nprint(b)", language: "swift",
            problem: .init(severity: "error", message: "cannot find 'c' in scope", source: "sourcekit"), scrub: false)
        XCTAssertEqual(
            text,
            "Sources/main.swift, lines 12–14:\n```swift\nlet a = 1\nlet b = a\nprint(b)\n```\n\nProblem marked there (error, sourcekit): cannot find 'c' in scope")
        XCTAssertEqual(EditorAskSelection.subject(path: "a.swift", first: 3, last: 3), "a.swift:3")
        XCTAssertEqual(EditorAskSelection.span(first: 3, last: 3), "line 3")
    }

    func testAFenceOutlastsTheBackticksInside() {
        XCTAssertEqual(EditorAskSelection.fenced("a ``` b", info: "md"), "````md\na ``` b\n````")
    }

    func testAVirtualBufferAndTfvarsAreScrubbed() {
        XCTAssertTrue(EditorAskSelection.scrubs(fileName: "prod.tfvars", isVirtual: false))
        XCTAssertTrue(EditorAskSelection.scrubs(fileName: "prod.tfvars.json", isVirtual: false))
        XCTAssertTrue(EditorAskSelection.scrubs(fileName: "deployment.yaml", isVirtual: true))
        XCTAssertFalse(EditorAskSelection.scrubs(fileName: "main.tf", isVirtual: false))
        let secret = "db_password = \"hunter2-very-secret\"\nurl = \"postgres://app:s3cretpass@db:5432/app\""
        let scrubbed = EditorAskSelection.text(path: "prod.tfvars", first: 1, last: 2, selection: secret, language: "hcl", problem: nil, scrub: true)
        XCTAssertFalse(scrubbed.contains("hunter2-very-secret"), scrubbed)
        XCTAssertFalse(scrubbed.contains("s3cretpass"), scrubbed)
        XCTAssertTrue(scrubbed.contains("db_password"), scrubbed)
        let plain = EditorAskSelection.text(path: "main.tf", first: 1, last: 2, selection: secret, language: "hcl", problem: nil, scrub: false)
        XCTAssertTrue(plain.contains("hunter2-very-secret"))
    }
}
