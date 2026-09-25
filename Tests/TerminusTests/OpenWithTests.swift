import XCTest

@testable import Terminus

final class OpenWithTests: XCTestCase {
    private static func app(_ bundleID: String, _ name: String, at path: String? = nil) -> ExternalApp {
        ExternalApp(bundleID: bundleID, name: name, url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"))
    }

    private let code = app("com.microsoft.VSCode", "Visual Studio Code")
    private let zed = app("dev.zed.Zed", "Zed")
    private let xcode = app("com.apple.dt.Xcode", "Xcode")
    private let textEdit = app("com.apple.TextEdit", "TextEdit", at: "/System/Applications/TextEdit.app")
    private let ghostty = app("com.mitchellh.ghostty", "Ghostty")
    private let bbedit = app("com.barebones.bbedit", "BBEdit")
    private let macVim = app("org.vim.MacVim", "MacVim")
    private let terminus = app("ai.promptrails.terminus", "Terminus")

    // MARK: Candidates

    /// Code editors first, in their own order, whether or not they claim the
    /// file; then the system's default; then whatever else can open it, by name.
    func testEditorsComeFirstThenTheDefaultThenTheRestByName() {
        let candidates = OpenWith.candidates(
            editors: [code, zed], current: nil, systemDefault: ghostty, canOpen: [xcode, textEdit, ghostty, bbedit], excluding: nil)
        XCTAssertEqual(candidates, [code, zed, ghostty, bbedit, textEdit, xcode])
    }

    /// Xcode and Xcode-beta share a bundle id; an editor that also claims the
    /// file is listed once, where the editors are.
    func testEachAppIsOfferedOnce() {
        let beta = Self.app("com.apple.dt.Xcode", "Xcode-27.0.0")
        let candidates = OpenWith.candidates(
            editors: [xcode], current: xcode, systemDefault: xcode, canOpen: [beta, textEdit, xcode, textEdit], excluding: nil)
        XCTAssertEqual(candidates, [xcode, textEdit])
    }

    /// Terminus lists itself for text files (Finder's Open With): opening a
    /// file "externally" in Terminus would only bring it back here.
    func testTerminusItselfIsNeverOffered() {
        let candidates = OpenWith.candidates(
            editors: [zed], current: nil, systemDefault: terminus, canOpen: [terminus, textEdit], excluding: terminus.bundleID)
        XCTAssertEqual(candidates, [zed, textEdit])
    }

    /// An app picked with Other… may not claim the file at all; it is still
    /// the one in use, so the list shows it — in its place by name: picking
    /// an app doesn't reorder the menu.
    func testTheAppInUseIsOfferedEvenIfItDoesNotClaimTheFile() {
        let candidates = OpenWith.candidates(
            editors: [zed], current: macVim, systemDefault: textEdit, canOpen: [textEdit, ghostty], excluding: nil)
        XCTAssertEqual(candidates, [zed, textEdit, ghostty, macVim])
        XCTAssertEqual(
            OpenWith.candidates(editors: [zed], current: ghostty, systemDefault: textEdit, canOpen: [textEdit, ghostty, macVim], excluding: nil),
            [zed, textEdit, ghostty, macVim], "the same order whichever is in use")
    }

    func testTheEditorListNamesEachAppOnce() {
        XCTAssertFalse(OpenWith.editors.isEmpty)
        XCTAssertEqual(Set(OpenWith.editors).count, OpenWith.editors.count)
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.google.antigravity", "dev.zed.Zed", "com.apple.dt.Xcode"] {
            XCTAssertTrue(OpenWith.editors.contains(id), id)
        }
    }

    // MARK: The remembered app

    func testTheRememberedAppIsUsedWhileItIsInstalled() {
        XCTAssertEqual(OpenWith.resolve(remembered: zed.bundleID, installed: { $0 == self.zed.bundleID ? self.zed : nil }), .open(zed))
    }

    func testWithNothingRememberedItAsks() {
        XCTAssertEqual(OpenWith.resolve(remembered: nil, installed: { _ in self.zed }), .ask)
    }

    /// Uninstalled (or renamed away) since it was picked: ask again rather
    /// than fall back to the system's choice.
    func testARememberedAppThatIsGoneAsks() {
        XCTAssertEqual(OpenWith.resolve(remembered: zed.bundleID, installed: { _ in nil }), .ask)
    }

    // MARK: Titles

    func testOpenTitleNamesTheAppOrAsks() {
        XCTAssertEqual(OpenWith.openTitle(code), "Open in Visual Studio Code")
        XCTAssertEqual(OpenWith.openTitle(nil), "Open With…")
    }

    func testTheSystemDefaultIsMarked() {
        XCTAssertEqual(OpenWith.title(of: textEdit, systemDefault: textEdit.bundleID), "TextEdit (default)")
        XCTAssertEqual(OpenWith.title(of: zed, systemDefault: textEdit.bundleID), "Zed")
        XCTAssertEqual(OpenWith.title(of: zed, systemDefault: nil), "Zed")
    }

    /// The Open With menu: every candidate (the one in use ticked), a divider,
    /// Other… last.
    func testTheMenuListsTheAppsThenOther() {
        XCTAssertEqual(
            OpenWith.entries(candidates: [zed, textEdit], systemDefault: textEdit.bundleID, current: zed.bundleID),
            [.app(zed, title: "Zed", isCurrent: true), .app(textEdit, title: "TextEdit (default)", isCurrent: false), .divider, .other])
        XCTAssertEqual(OpenWith.entries(candidates: [], systemDefault: nil, current: nil), [.other], "no divider above nothing")
    }

    func testAppNamesAreFinderNamesWithoutTheExtension() {
        XCTAssertEqual(OpenWith.appName(displayName: "Visual Studio Code.app"), "Visual Studio Code")
        XCTAssertEqual(OpenWith.appName(displayName: "Zed"), "Zed")
        XCTAssertEqual(OpenWith.appName(displayName: "Sublime Text (4192)"), "Sublime Text (4192)")
    }
}
