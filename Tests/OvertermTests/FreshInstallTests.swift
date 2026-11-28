import XCTest

@testable import Overterm
@testable import OvertermShell

/// A fresh install's two settings (onboarding; the owner's reversal of
/// D-8, and the theme): the panels whose tool isn't on this Mac start
/// hidden, the terminal follows macOS with a pair — only on a fresh
/// install, each once, never over the person's own setting, never by
/// looking further than a file's existence and the login shell's PATH.
@MainActor
final class FreshInstallTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private var suite: String!
    private var defaults: UserDefaults!
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-fresh-\(UUID().uuidString)")
    private var settings: Settings!

    override func setUpWithError() throws {
        suite = "overterm-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = Settings(url: dir.appendingPathComponent("settings.json"), watch: false)
    }

    override func tearDown() {
        FreshInstallSetup.toolsOverride = nil
        FreshInstallSetup.ghosttyThemeOverride = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: The panels' rule

    func testOnlyTheToolsPanelsAndOnlyThoseNotFound() {
        let none = FreshInstall.Tools(pathKnown: true)
        XCTAssertEqual(FreshInstall.panelsToHide(none) { _ in false }, [.docker, .kubernetes, .terraform])
        let all = FreshInstall.Tools(pathKnown: true, docker: true, kubectl: true, terraform: true)
        XCTAssertEqual(FreshInstall.panelsToHide(all) { _ in false }, [])
        let some = FreshInstall.Tools(pathKnown: true, docker: true, kubectl: false, terraform: true)
        XCTAssertEqual(FreshInstall.panelsToHide(some) { _ in false }, [.kubernetes])
        XCTAssertEqual(FreshInstall.toolPanels, [.docker, .kubernetes, .terraform], "API, Database, Notes, Sessions and Snippets need no tool")
    }

    func testThePathUnknownHidesNothing() {
        XCTAssertEqual(FreshInstall.panelsToHide(.unknown) { _ in false }, [])
    }

    func testAPersonsOwnSwitchIsNeverTaken() {
        let none = FreshInstall.Tools(pathKnown: true)
        XCTAssertEqual(FreshInstall.panelsToHide(none) { key in key == "docker.enabled" }, [.kubernetes, .terraform])
    }

    func testTheCardsLine() {
        XCTAssertEqual(FreshInstall.hiddenLine([.docker, .kubernetes]), "Docker, Kubernetes hidden — not found on this Mac")
        XCTAssertEqual(FreshInstall.hiddenLine([.terraform]), "Terraform hidden — not found on this Mac")
        XCTAssertNil(FreshInstall.hiddenLine([]))
    }

    func testTheKeptListPassesOverWhatItDoesntKnow() {
        XCTAssertEqual(FreshInstall.hidden(stored: ["terraform", "docker", "notes", "nonsense"]), [.docker, .terraform], "in the rail's order")
        XCTAssertEqual(FreshInstall.hidden(stored: nil), [])
    }

    // MARK: Looking

    /// Each tool where its feature looks; nothing else touched, nothing run.
    func testToolsAreLookedForWhereTheirFeaturesLook() {
        var looked: [String] = []
        func tools(_ present: Set<String>, login: [String: String]? = ["PATH": "/Users/someone/bin"]) -> FreshInstall.Tools {
            FreshInstallSetup.tools(
                login: login, home: home,
                exists: { path in
                    looked.append(path)
                    return present.contains(path)
                },
                isExecutable: { path in
                    looked.append(path)
                    return present.contains(path)
                })
        }
        XCTAssertEqual(tools([]), FreshInstall.Tools(pathKnown: true))
        XCTAssertTrue(looked.contains("/Users/someone/bin/docker") && looked.contains("/Users/someone/.orbstack/bin/docker"), "\(looked)")
        XCTAssertTrue(looked.contains("/Applications/Docker.app") && looked.contains("/Applications/OrbStack.app"))
        XCTAssertTrue(looked.contains("/Users/someone/bin/kubectl") && looked.contains("/opt/homebrew/bin/kubectl"))
        XCTAssertTrue(looked.contains("/Users/someone/bin/tofu") && looked.contains("/usr/local/bin/terraform"))
        let forbidden = ["/Documents", "/Desktop", "/Library/Mobile Documents", ".kube", ".docker/config"]
        XCTAssertFalse(looked.contains { path in forbidden.contains { part in path.contains(part) } }, "\(looked)")

        XCTAssertTrue(tools(["/Applications/OrbStack.app"]).docker, "an app counts, its CLI linked or not")
        XCTAssertTrue(tools(["/Users/someone/.docker/bin/docker"]).docker)
        XCTAssertTrue(tools(["/Users/someone/.rd/bin/kubectl"]).kubectl)
        XCTAssertTrue(tools(["/Users/someone/bin/tofu"]).terraform, "OpenTofu counts")
        XCTAssertTrue(tools(["/opt/homebrew/bin/terraform"]).terraform)

        looked = []
        XCTAssertEqual(tools(["/opt/homebrew/bin/terraform"], login: nil), .unknown)
        XCTAssertTrue(looked.isEmpty, "the PATH unknown: nothing looked at")
    }

    // MARK: Deciding

    func testAFreshInstallHidesOnceAndRemembers() async {
        FreshInstallSetup.toolsOverride = FreshInstall.Tools(pathKnown: true, docker: true)
        let hidden = await FreshInstallSetup.decidePanels(.fresh, settings: settings, defaults: defaults)
        XCTAssertEqual(hidden, [.kubernetes, .terraform])
        XCTAssertFalse(settings.bool("kubernetes.enabled"))
        XCTAssertFalse(settings.bool("terraform.enabled"))
        XCTAssertTrue(settings.bool("docker.enabled"))
        XCTAssertFalse(settings.isSet("docker.enabled"), "nothing written for what was found")
        XCTAssertTrue(defaults.bool(forKey: FreshInstall.panelsDecidedKey))
        XCTAssertEqual(defaults.stringArray(forKey: FreshInstall.panelsHiddenKey), ["kubernetes", "terraform"])

        settings.set("kubernetes.enabled", nil)
        let again = await FreshInstallSetup.decidePanels(.fresh, settings: settings, defaults: defaults)
        XCTAssertEqual(again, [], "never twice")
        XCTAssertTrue(settings.bool("kubernetes.enabled"))
    }

    func testAnUpdateOrTheSameVersionChangesNothing() async {
        FreshInstallSetup.toolsOverride = FreshInstall.Tools(pathKnown: true)
        FreshInstallSetup.ghosttyThemeOverride = false
        for launch in [FirstRun.Launch.upgraded(from: "1.6.8"), .upgraded(from: nil), .same] {
            let hidden = await FreshInstallSetup.decidePanels(launch, settings: settings, defaults: defaults)
            XCTAssertEqual(hidden, [], "\(launch)")
            XCTAssertFalse(FreshInstallSetup.chooseTheme(launch, settings: settings, defaults: defaults), "\(launch)")
        }
        XCTAssertNil(defaults.object(forKey: FreshInstall.panelsDecidedKey))
        XCTAssertNil(defaults.object(forKey: FreshInstall.themeDecidedKey))
        XCTAssertFalse((FreshInstall.toolPanels.compactMap(\.toggleKey) + FreshInstall.themeKeys).contains { key in settings.isSet(key) })
    }

    func testTheShellSilentHidesNothingAndIsDecided() async {
        FreshInstallSetup.toolsOverride = .unknown
        let hidden = await FreshInstallSetup.decidePanels(.fresh, settings: settings, defaults: defaults)
        XCTAssertEqual(hidden, [])
        XCTAssertTrue(defaults.bool(forKey: FreshInstall.panelsDecidedKey))
        XCTAssertEqual(defaults.stringArray(forKey: FreshInstall.panelsHiddenKey), [])
    }

    /// An isolated run (a unit test is one) with nothing handed over looks at nothing and decides nothing.
    func testAnIsolatedRunLooksAtNothing() async {
        let hidden = await FreshInstallSetup.decidePanels(.fresh, settings: settings, defaults: defaults)
        XCTAssertEqual(hidden, [])
        XCTAssertNil(defaults.object(forKey: FreshInstall.panelsDecidedKey))
        XCTAssertFalse(FreshInstallSetup.chooseTheme(.fresh, settings: settings, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: FreshInstall.themeDecidedKey))
    }

    // MARK: The theme

    func testThePairIsChosenOnlyWhereNothingNamesATheme() {
        XCTAssertTrue(FreshInstall.choosesTheme(ghosttySetsTheme: false, settingsHasTheme: false, themesAvailable: true))
        XCTAssertFalse(FreshInstall.choosesTheme(ghosttySetsTheme: true, settingsHasTheme: false, themesAvailable: true))
        XCTAssertFalse(FreshInstall.choosesTheme(ghosttySetsTheme: false, settingsHasTheme: true, themesAvailable: true))
        XCTAssertFalse(FreshInstall.choosesTheme(ghosttySetsTheme: false, settingsHasTheme: false, themesAvailable: false))
        XCTAssertNotEqual(FreshInstall.darkTheme, FreshInstall.lightTheme)
        XCTAssertEqual(FreshInstall.themeKeys, ["appearance.theme", "appearance.themeLight", "appearance.followSystemAppearance"])
    }

    /// A Ghostty config read as Ghostty reads its lines.
    func testAGhosttyConfigsTheme() {
        XCTAssertTrue(FreshInstall.ghosttyConfig("font-size = 13\ntheme = Dracula\n").setsTheme)
        XCTAssertTrue(FreshInstall.ghosttyConfig("theme=light:Rose Pine Dawn,dark:Rose Pine").setsTheme)
        XCTAssertTrue(FreshInstall.ghosttyConfig("  theme = \"Nord\"  ").setsTheme)
        XCTAssertFalse(FreshInstall.ghosttyConfig("# theme = Dracula\nfont-size = 13").setsTheme, "a comment")
        XCTAssertFalse(FreshInstall.ghosttyConfig("theme =").setsTheme, "an empty value is Ghostty's default")
        XCTAssertFalse(FreshInstall.ghosttyConfig("window-theme = dark").setsTheme, "another key")
        XCTAssertEqual(FreshInstall.ghosttyConfig("config-file = ?themes.conf\nconfig-file = /etc/x").includes, ["themes.conf", "/etc/x"])
    }

    /// The default files, then what they include — relative to the including
    /// file — read until a theme is found, bounded.
    func testTheConfigsIncludesAreFollowedBounded() {
        let base = URL(fileURLWithPath: "/Users/someone/.config/ghostty")
        var read: [String] = []
        let files: [String: String] = [
            base.appendingPathComponent("config").path: "config-file = ?extra.conf\nfont-size = 14",
            base.appendingPathComponent("extra.conf").path: "theme = Dracula",
        ]
        let sets = FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("config"), base.appendingPathComponent("config.ghostty")]) { url in
            read.append(url.path)
            return files[url.path]
        }
        XCTAssertTrue(sets)
        XCTAssertTrue(read.contains(base.appendingPathComponent("extra.conf").path), "\(read)")
        XCTAssertFalse(FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("none")]) { _ in nil })

        // A file including itself, or a long chain, ends.
        var count = 0
        let looped = FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("a")]) { url in
            count += 1
            return "config-file = \(url.lastPathComponent)x"
        }
        XCTAssertFalse(looped)
        XCTAssertLessThanOrEqual(count, FreshInstall.ghosttyFilesLimit)
    }

    func testAnIsolatedRunHasNoGhosttyFiles() {
        XCTAssertEqual(AppEnvironment.ghosttyConfigFiles, [], "a unit test is an isolated run")
    }

    // MARK: The card and Check Setup

    func testTheCardNamesOnlyWhatIsStillOff() throws {
        defaults.set(["docker", "kubernetes"], forKey: FreshInstall.panelsHiddenKey)
        settings.set("docker.enabled", .bool(false))
        settings.set("kubernetes.enabled", .bool(false))
        let start = Start(defaults: defaults, active: true, settings: settings)
        XCTAssertEqual(start.stillHidden, [.docker, .kubernetes])
        settings.set("kubernetes.enabled", nil)
        start.hiddenAtInstallChanged()
        XCTAssertEqual(start.stillHidden, [.docker], "one turned on by its tick is a panel like any other")
        start.showHidden()
        XCTAssertTrue(settings.bool("docker.enabled"))
        XCTAssertEqual(start.stillHidden, [])
    }

    func testCheckSetupSaysTheSame() {
        let facts = SetupPanelFacts(hiddenAtInstall: [.docker, .terraform])
        let rows = SetupCheck.panelRows(facts).filter { row in row.detail == SetupCheck.hiddenAtInstallDetail }
        XCTAssertEqual(rows.map(\.id), [.panelHidden(.docker), .panelHidden(.terraform)])
        XCTAssertEqual(rows.first?.action, .settings(.docker, key: "docker.enabled"))
        XCTAssertTrue(FreshInstall.hiddenLine([.docker])?.hasSuffix(SetupCheck.hiddenAtInstallDetail) == true, "the card's words and the page's")
    }
}
