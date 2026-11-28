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

    /// Docker is looked for where its page and the Setup page look — the
    /// PATH Overterm was started with — as well as the login shell's.
    func testDockerOnTheAppsPathCounts() {
        let found = FreshInstallSetup.tools(
            login: ["PATH": "/usr/bin:/bin"], appPath: "/Users/someone/custom-bin", home: home, exists: { _ in false },
            isExecutable: { path in path == "/Users/someone/custom-bin/docker" })
        XCTAssertTrue(found.docker)
    }

    /// A PATH folder under Desktop, Documents, Downloads or iCloud Drive is
    /// never looked in: macOS would ask the person, at their first launch.
    func testProtectedFoldersOnThePathAreNotLookedIn() {
        var asked: [String] = []
        let path = "/Users/someone/Documents/bin:/Users/someone/Desktop/tools:/Users/someone/Library/Mobile Documents/bin:/usr/bin"
        let found = FreshInstallSetup.tools(
            login: ["PATH": path], appPath: "/Users/someone/Downloads/bin", home: home, exists: { _ in false },
            isExecutable: { path in
                asked.append(path)
                return true
            })
        XCTAssertTrue(found.docker && found.kubectl && found.terraform, "found where it may look")
        XCTAssertFalse(asked.contains { path in SetupProbe.isProtected(path, home: "/Users/someone") }, "\(asked)")
        XCTAssertFalse(asked.isEmpty)
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

    /// A switch turned off and on again while the shell answers ends at its
    /// default, which settings.json doesn't hold — still the person's.
    func testASwitchTouchedWhileTheShellAnswersIsKept() async {
        let settings = settings!
        let hidden = await FreshInstallSetup.decidePanels(.fresh, settings: settings, defaults: defaults) {
            settings.set("kubernetes.enabled", .bool(false))
            settings.set("kubernetes.enabled", .bool(true))
            return FreshInstall.Tools(pathKnown: true)
        }
        XCTAssertFalse(settings.isSet("kubernetes.enabled"), "back at its default")
        XCTAssertEqual(hidden, [.docker, .terraform])
        XCTAssertTrue(settings.bool("kubernetes.enabled"))
        XCTAssertEqual(defaults.stringArray(forKey: FreshInstall.panelsHiddenKey), ["docker", "terraform"])
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
        XCTAssertEqual(FreshInstall.ghosttyConfig("font-size = 13\ntheme = Dracula\n").theme, "Dracula")
        XCTAssertEqual(FreshInstall.ghosttyConfig("theme=light:Rose Pine Dawn,dark:Rose Pine").theme, "light:Rose Pine Dawn,dark:Rose Pine")
        XCTAssertEqual(FreshInstall.ghosttyConfig("  theme = \"Nord\"  ").theme, "Nord")
        XCTAssertNil(FreshInstall.ghosttyConfig("# theme = Dracula\nfont-size = 13").theme, "a comment")
        XCTAssertEqual(FreshInstall.ghosttyConfig("theme = Nord\ntheme =").theme, "", "an empty value is Ghostty's default, the last line wins")
        XCTAssertNil(FreshInstall.ghosttyConfig("window-theme = dark").theme, "another key")
        XCTAssertEqual(FreshInstall.ghosttyConfig("config-file = ?themes.conf\nconfig-file = /etc/x").includes, ["themes.conf", "/etc/x"])
    }

    /// The default files, then what they include — relative to the including
    /// file — followed, bounded.
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

        // A file including itself, or a long chain, ends — cut short, it
        // isn't known to name no theme: the person's config is left alone.
        var count = 0
        let looped = FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("a")]) { url in
            count += 1
            return "config-file = \(url.lastPathComponent)x"
        }
        XCTAssertTrue(looped, "the limit reached: unknown, kept")
        XCTAssertLessThanOrEqual(count, FreshInstall.ghosttyFilesLimit)
        XCTAssertFalse(
            FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("a")]) { url in url.lastPathComponent == "a" ? "config-file = a" : nil },
            "a file including itself is read once: the search ends, and finds none")
    }

    /// A theme past the read limit is never read; the search cut short says
    /// so rather than "none", and no pair is chosen over it.
    func testATruncatedSearchKeepsThePersonsConfig() {
        let base = URL(fileURLWithPath: "/Users/someone/.config/ghostty")
        let count = FreshInstall.ghosttyFilesLimit + 2
        var files: [String: String] = [
            base.appendingPathComponent("config").path: (1...count).map { index in "config-file = part\(index).conf" }.joined(separator: "\n")
        ]
        for index in 1..<count { files[base.appendingPathComponent("part\(index).conf").path] = "font-size = \(index)" }
        files[base.appendingPathComponent("part\(count).conf").path] = "theme = Dracula"
        XCTAssertTrue(FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("config")]) { url in files[url.path] })
        XCTAssertFalse(FreshInstall.ghosttySetsTheme(files: [base.appendingPathComponent("config")]) { url in url.lastPathComponent == "config" ? "font-size = 13" : nil })
    }

    /// Only files that are there count against the limit: the four default
    /// paths, mostly missing, leave room for more than four includes.
    func testMoreThanFourIncludesAreRead() {
        let base = URL(fileURLWithPath: "/Users/someone/.config/ghostty")
        let paths = ["config", "config.ghostty", "support/config", "support/config.ghostty"].map { name in base.appendingPathComponent(name) }
        var files: [String: String] = [
            paths[0].path: (1...6).map { index in "config-file = part\(index).conf" }.joined(separator: "\n")
        ]
        for index in 1...5 { files[base.appendingPathComponent("part\(index).conf").path] = "font-size = \(index)" }
        files[base.appendingPathComponent("part6.conf").path] = "theme = Dracula"
        XCTAssertTrue(FreshInstall.ghosttySetsTheme(files: paths) { url in files[url.path] })
    }

    /// Ghostty's order decides: every default file, then the includes, each
    /// after the files before it — the last `theme` line read wins, a later
    /// file's `theme =` putting the default back.
    func testTheLastThemeInGhosttysOrderWins() {
        let base = URL(fileURLWithPath: "/Users/someone/.config/ghostty")
        let first = base.appendingPathComponent("config")
        let second = base.appendingPathComponent("config.ghostty")
        func sets(_ files: [String: String]) -> Bool {
            FreshInstall.ghosttySetsTheme(files: [first, second]) { url in files[url.path] }
        }
        XCTAssertFalse(sets([first.path: "theme = Dracula", second.path: "theme ="]), "a later default file resets it")
        XCTAssertTrue(sets([first.path: "theme =", second.path: "theme = Nord"]))
        let include = base.appendingPathComponent("colors.conf").path
        XCTAssertFalse(
            sets([first.path: "config-file = colors.conf", second.path: "theme = Nord", include: "theme ="]),
            "an include loads after every default file, so its reset is the last word")
        XCTAssertTrue(
            sets([first.path: "config-file = colors.conf\ntheme =", second.path: "font-size = 13", include: "theme = Nord"]),
            "an include loads after the file that names it, whatever that file says after the line")
        XCTAssertFalse(sets([first.path: "font-size = 13"]), "no theme line: Ghostty's default")
    }

    /// The done card's line names the Ghostty config only where it names a
    /// theme — read by the same scan, off the main thread.
    func testTheDoneCardsThemeFollowsTheScan() async {
        let named = Start(defaults: defaults, active: true, settings: settings, ghosttyTheme: { true })
        await named.ghosttyThemeReadDone()
        XCTAssertEqual(StartText.themeLine(named.theme), "Theme: your Ghostty config's")
        let none = Start(defaults: defaults, active: true, settings: settings, ghosttyTheme: { false })
        await none.ghosttyThemeReadDone()
        XCTAssertEqual(StartText.themeLine(none.theme), "Theme: Ghostty's default")
        XCTAssertFalse(Start.readGhosttyTheme(), "an isolated run reads none of the user's files")
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
