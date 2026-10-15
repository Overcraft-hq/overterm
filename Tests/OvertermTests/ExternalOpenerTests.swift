import XCTest

@testable import Overterm

/// The opener against the isolated stand-in for LaunchServices (what E2E
/// runs use): nothing is launched, every open is recorded.
final class ExternalOpenerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let file = URL(fileURLWithPath: "/tmp/notes.md")
    private let zed = ExternalApp(bundleID: "dev.zed.Zed", name: "Zed", url: URL(fileURLWithPath: "/Applications/Zed.app"))
    private let textEdit = ExternalApp(
        bundleID: "com.apple.TextEdit", name: "TextEdit", url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))

    override func setUpWithError() throws {
        suite = "overterm-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// TextEdit (the system's pick) and Zed installed.
    @MainActor
    private func make() -> (ExternalOpener, IsolatedApps) {
        let apps = IsolatedApps()
        apps.installed = [textEdit, zed]
        apps.defaultBundleID = textEdit.bundleID
        return (ExternalOpener(apps: apps, defaults: defaults), apps)
    }

    @MainActor
    func testPickingAnAppOpensTheFileThereAndRemembersIt() async {
        let (opener, apps) = make()
        XCTAssertNil(opener.current, "nothing picked yet")
        await opener.open(file, with: zed).value
        XCTAssertEqual(apps.opened, [.init(file: file, bundleID: zed.bundleID)])
        XCTAssertEqual(defaults.string(forKey: OpenWith.rememberedKey), zed.bundleID)
        XCTAssertEqual(opener.current, zed)
    }

    @MainActor
    func testOpeningGoesStraightToTheRememberedApp() async {
        defaults.set(zed.bundleID, forKey: OpenWith.rememberedKey)
        let (opener, apps) = make()
        XCTAssertEqual(opener.current, zed, "known at launch: the menus and ↗ name it")
        let opening = opener.open(file)
        XCTAssertNotNil(opening, "no question")
        await opening?.value
        XCTAssertEqual(apps.opened, [.init(file: file, bundleID: zed.bundleID)])
    }

    @MainActor
    func testWithNothingRememberedOpeningAsksInsteadOfOpening() {
        let (opener, apps) = make()
        XCTAssertNil(opener.open(file), "it asks (a sheet on the window)")
        XCTAssertEqual(apps.opened, [])
    }

    @MainActor
    func testARememberedAppThatIsGoneIsAskedAboutAgain() {
        defaults.set("com.example.uninstalled", forKey: OpenWith.rememberedKey)
        let (opener, apps) = make()
        XCTAssertNil(opener.current)
        XCTAssertNil(opener.open(file))
        XCTAssertEqual(apps.opened, [], "never the system's default behind your back")
    }

    /// Installed editors come first even when they don't claim the file;
    /// the system's pick is marked.
    @MainActor
    func testOpenWithListsInstalledEditorsFirst() {
        let (opener, _) = make()
        XCTAssertEqual(
            opener.entries(for: file),
            [.app(zed, title: "Zed", isCurrent: false), .app(textEdit, title: "TextEdit (default)", isCurrent: false), .divider, .other])
    }

    @MainActor
    func testSwitchingAppsTicksTheNewOne() async {
        let (opener, apps) = make()
        await opener.open(file, with: zed).value
        await opener.open(file, with: textEdit).value
        XCTAssertEqual(defaults.string(forKey: OpenWith.rememberedKey), textEdit.bundleID)
        XCTAssertEqual(
            opener.entries(for: file),
            [.app(zed, title: "Zed", isCurrent: false), .app(textEdit, title: "TextEdit (default)", isCurrent: true), .divider, .other])
        XCTAssertEqual(apps.opened.map(\.bundleID), [zed.bundleID, textEdit.bundleID])
    }
}
