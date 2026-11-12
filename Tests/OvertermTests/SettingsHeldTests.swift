import XCTest

@testable import Overterm

/// D-7 (docs/design/terraform/analysis.md 5.8): any agent can write
/// settings.json, so a security setting changed there outside the Settings
/// page waits for a banner's Keep; the value before stays in effect.
@MainActor
final class SettingsHeldTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-held-\(UUID().uuidString)")
    private var url: URL { dir.appendingPathComponent("settings.json") }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let production = """
        {
          // acme's
          "kubernetes.contexts": { "acme-prod": { "class": "production" } },
          "appearance.fontSize": 14
        }

        """

    /// Kubernetes', and Terraform's: what makes a root production, and the terraform it runs.
    func testTheSecuritySettings() {
        XCTAssertEqual(
            Set(SettingsSchema.heldKeys),
            [
                "kubernetes.contexts", "kubernetes.agentWrites", "kubernetes.agentAccess", "kubernetes.kubectlPath",
                "kubernetes.helmPath", "terraform.roots", "terraform.productionPattern", "terraform.productionAccounts", "terraform.path",
                "terraform.enabled", "terraform.agentWriteGuard", "terraform.agentAccess",
            ])
        // Agents' access anywhere, and the binaries Overterm runs with a cluster's credentials.
        for spec in SettingsSchema.all where spec.key.hasPrefix("kubernetes.agent") || spec.key.hasSuffix("Path") && spec.key.hasPrefix("kubernetes.") {
            XCTAssertTrue(spec.heldWhenEditedOutside, spec.key)
        }
        // 5.8's Terraform keys, once they exist, must be held too.
        for spec in SettingsSchema.all where spec.key.hasPrefix("terraform.") {
            let security =
                ["terraform.roots", "terraform.productionPattern", "terraform.productionAccounts"].contains(spec.key)
                || spec.key.hasPrefix("terraform.agent")
            if security { XCTAssertTrue(spec.heldWhenEditedOutside, spec.key) }
        }
    }

    func testTheFileAtLaunchIsTakenAsItIs() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
    }

    /// An agent edits the file: production made local, a context named for
    /// agents' writes. Neither applies; the other edit in the file does.
    func testAnOutsideEditIsHeldTheRestApplies() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        var seen: [Set<String>] = []
        let watch = settings.changes.sink { seen.append($0) }
        defer { watch.cancel() }
        try write(
            """
            {
              // acme's
              "kubernetes.contexts": { "acme-prod": { "class": "local", "writable": true } },
              "kubernetes.agentWrites": ["acme-prod"],
              "appearance.fontSize": 16
            }

            """)
        settings.reload()
        XCTAssertEqual(Set(settings.held.keys), ["kubernetes.contexts", "kubernetes.agentWrites"])
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production, "the value before stays in effect")
        XCTAssertEqual(settings.kubernetesAgentWrites, [])
        XCTAssertEqual(settings.number("appearance.fontSize"), 16, "what isn't a security setting applies at once")
        XCTAssertEqual(seen, [["appearance.fontSize"]], "nothing says a held key changed")
        let lines = SettingsHeldBanner.lines(settings.held)
        XCTAssertEqual(
            lines,
            [
                "kubernetes.agentWrites: adds \"acme-prod\"",
                "kubernetes.contexts: \"acme-prod\": class \"production\" → \"local\", writable unset → true",
            ])
        // An edit in the app meanwhile builds on the value in effect, never the held one.
        XCTAssertEqual(settings.fileValue("kubernetes.contexts"), .entries(["acme-prod": ["class": .string("production")]]))
        XCTAssertEqual(settings.fileValue("kubernetes.agentWrites"), .list([]))
    }

    func testKeepAppliesWhatWasShown() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        try write(#"{ "kubernetes.agentWrites": ["acme-dev"], "kubernetes.contexts": { "acme-prod": { "class": "production" } } }"#)
        settings.reload()
        let shown = settings.held
        // Changed again before the Keep: the banner shows it again first.
        try write(#"{ "kubernetes.agentWrites": ["acme-prod"], "kubernetes.contexts": { "acme-prod": { "class": "production" } } }"#)
        settings.reload()
        settings.keep(shown)
        XCTAssertEqual(settings.kubernetesAgentWrites, [], "a Keep of what is no longer shown keeps nothing")
        XCTAssertEqual(SettingsHeldBanner.lines(settings.held), [#"kubernetes.agentWrites: adds "acme-prod""#])
        var seen: [Set<String>] = []
        let watch = settings.changes.sink { seen.append($0) }
        defer { watch.cancel() }
        settings.keep(settings.held)
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertEqual(settings.kubernetesAgentWrites, ["acme-prod"])
        XCTAssertEqual(seen, [["kubernetes.agentWrites"]])
        settings.reload()
        XCTAssertTrue(settings.held.isEmpty, "kept, the file is what is in effect")
    }

    /// Revert writes the value before back, in place: comments and the
    /// rest of the file kept.
    func testRevertWritesTheValueBeforeBack() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        let edited = production.replacingOccurrences(of: #""class": "production""#, with: #""class": "local""#)
            .replacingOccurrences(of: "\"appearance.fontSize\": 14", with: "\"appearance.fontSize\": 14,\n  \"kubernetes.agentWrites\": [\"acme-prod\"]")
        try write(edited)
        settings.reload()
        XCTAssertEqual(settings.held.count, 2)
        settings.revert(settings.held)
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
        XCTAssertEqual(settings.kubernetesAgentWrites, [])
        XCTAssertTrue(text().contains("// acme's") && text().contains(#""class": "production""#), text())
        XCTAssertFalse(text().contains("agentWrites"), text())
        XCTAssertEqual(try SettingsJSON.object(from: text()).count, 2, text())
        settings.reload()
        XCTAssertTrue(settings.held.isEmpty)
    }

    /// An agent about to apply on production turns Terraform off in the
    /// file: the pane header would go with it. Held; the app's own toggle isn't.
    func testTurningTerraformOffOutsideIsHeld() throws {
        try write(#"{ "appearance.fontSize": 14 }"#)
        let settings = Settings(url: url, watch: false)
        XCTAssertTrue(settings.terraformEnabled)
        try write(#"{ "terraform.enabled": false, "appearance.fontSize": 14 }"#)
        settings.reload()
        XCTAssertEqual(Set(settings.held.keys), ["terraform.enabled"])
        XCTAssertTrue(settings.terraformEnabled, "the header stays until a window's banner keeps it")
        settings.set("terraform.enabled", .bool(false))
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertFalse(settings.terraformEnabled, "Settings' own toggle applies at once")
    }

    /// A security setting removed, or given a value it can't hold, would
    /// fall to its default — a production class gone. Held too.
    func testRemovalAndUnusableValuesAreHeld() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        try write(#"{ "kubernetes.contexts": "none", "appearance.fontSize": 14 }"#)
        settings.reload()
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
        XCTAssertTrue(SettingsHeldBanner.lines(settings.held).first?.contains("can't be used") == true)
        try write(#"{ "appearance.fontSize": 14 }"#)
        settings.reload()
        XCTAssertEqual(SettingsHeldBanner.lines(settings.held), [#"kubernetes.contexts: "acme-prod" removed (it had class: "production")"#])
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
        // Written back as it was: the next read finds nothing to hold.
        try write(production)
        settings.reload()
        XCTAssertTrue(settings.held.isEmpty)
    }

    /// The page and the app's own sheets set a security setting at once;
    /// one held meanwhile takes the app's value.
    func testTheAppsOwnEditsApplyAtOnce() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        settings.set("kubernetes.agentWrites", .list(["acme-dev"]))
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertEqual(settings.kubernetesAgentWrites, ["acme-dev"])
        try write(text().replacingOccurrences(of: "acme-dev", with: "acme-prod"))
        settings.reload()
        XCTAssertNotNil(settings.held["kubernetes.agentWrites"])
        // Another setting set from the page: the held one stays held.
        settings.set("general.confirmClose", .string("whenRunning"))
        XCTAssertNotNil(settings.held["kubernetes.agentWrites"])
        XCTAssertEqual(settings.kubernetesAgentWrites, ["acme-dev"])
        // The held one set from the page, to the value in effect: the file says so again.
        settings.set("kubernetes.agentWrites", .list(["acme-dev"]))
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertTrue(text().contains(#"["acme-dev"]"#), text())
    }

    /// The JSON view shows the file: saving another edit there is not a
    /// Keep. Changing the held value itself there is the person's own.
    func testTheJSONViewsSaveKeepsWhatIsHeld() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        let agents = production.replacingOccurrences(of: #""production""#, with: #""local""#)
        try write(agents)
        settings.reload()
        settings.save(text: agents.replacingOccurrences(of: "14", with: "18"))
        XCTAssertEqual(settings.number("appearance.fontSize"), 18)
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
        XCTAssertNotNil(settings.held["kubernetes.contexts"])
        settings.save(text: agents.replacingOccurrences(of: #""local""#, with: #""remote""#))
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .remote)
    }

    /// An agent's value is shown with every character visible.
    func testTheBannerShowsHiddenCharacters() {
        let change = HeldSetting(
            key: "kubernetes.agentWrites", current: nil, proposed: .list(["acme-dev\u{202E}dorp"]), before: nil, written: .list(["acme-dev\u{202E}dorp"]))
        XCTAssertEqual(change.lines.map(\.text), [#"kubernetes.agentWrites: adds "acme-dev\u{202E}dorp""#])
    }

    /// An agent decides what would fall past a cut: decoy names ahead of
    /// the production one. Every line is there, and the banner can't Keep
    /// what it doesn't show.
    func testALongChangeIsNeverCutUnseen() {
        let decoys = (0..<40).map { "a\(String(format: "%02d", $0))-padding-padding" }
        let change = HeldSetting(
            key: "kubernetes.agentWrites", current: nil, proposed: .list(decoys + ["acme-prod"]), before: nil,
            written: .list(decoys + ["acme-prod"]))
        let lines = SettingsHeldBanner.lines(["kubernetes.agentWrites": change])
        XCTAssertEqual(lines.count, 41)
        XCTAssertGreaterThan(lines.joined().count, 300)
        XCTAssertEqual(lines.last, #"kubernetes.agentWrites: adds "acme-prod""#)
        let summary = HeldBannerSummary(lines)
        XCTAssertFalse(summary.keepInBanner)
        XCTAssertEqual(summary.hidden, 35)
        // One line too long for the banner: cut there, so no Keep there either.
        let long = HeldBannerSummary(["kubernetes.kubectlPath: now \"" + String(repeating: "/x", count: 120) + "\" (was \"\")"])
        XCTAssertTrue(long.cut)
        XCTAssertFalse(long.keepInBanner)
        XCTAssertTrue(HeldBannerSummary(Array(lines.suffix(2))).keepInBanner)
        // The review: Keep only once every line has been on screen.
        var review = HeldReviewProgress(count: lines.count)
        for index in 0..<40 { review.saw(index) }
        XCTAssertFalse(review.canKeep)
        review.saw(40)
        XCTAssertTrue(review.canKeep)
    }

    /// What widens is listed first: a context's entry changed ahead of a
    /// name only removed.
    func testWhatWidensComesFirst() {
        let names = HeldSetting(
            key: "kubernetes.agentWrites", current: .list(["acme-dev"]), proposed: .list([]), before: .list(["acme-dev"]), written: .list([]))
        let contexts = HeldSetting(
            key: "kubernetes.contexts", current: .entries(["zz-prod": ["class": .string("production")]]),
            proposed: .entries(["zz-prod": ["class": .string("local")]]), before: nil, written: nil)
        XCTAssertEqual(
            SettingsHeldBanner.lines(["kubernetes.agentWrites": names, "kubernetes.contexts": contexts]),
            [#"kubernetes.contexts: "zz-prod": class "production" → "local""#, #"kubernetes.agentWrites: removes "acme-dev""#])
    }

    /// An agent breaks the file along with its change, so nothing is held
    /// while it doesn't parse; the person fixes the typo in the JSON view —
    /// whose draft is the agent's text — and saves. Not a Keep: held.
    func testSavingAFixedBrokenFileHoldsTheChange() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        let broken = """
            {
              "kubernetes.agentWrites": ["acme-prod"],
              "kubernetes.contexts": { "acme-prod": { "class": "production" } },
              "appearance.fontSize": 14,,
            }

            """
        try write(broken)
        settings.reload()
        XCTAssertTrue(settings.held.isEmpty)
        XCTAssertFalse(settings.problems.isEmpty)
        settings.save(text: broken.replacingOccurrences(of: ",,", with: ""))
        XCTAssertEqual(Set(settings.held.keys), ["kubernetes.agentWrites"])
        XCTAssertEqual(settings.kubernetesAgentWrites, [])
    }

    /// The JSON view opened on an outside edit the watcher hasn't reported
    /// yet: its draft is that file, and saving it is not a Keep.
    func testSavingBeforeTheWatcherSawTheEditHoldsIt() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        let agents = production.replacingOccurrences(of: #""production""#, with: #""local""#)
        try write(agents)
        // No reload: the draft is the file as it is now.
        settings.save(text: agents.replacingOccurrences(of: "14", with: "15"))
        XCTAssertNotNil(settings.held["kubernetes.contexts"])
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
        XCTAssertEqual(settings.number("appearance.fontSize"), 15)
    }

    /// The app's own edit made before the watcher reported an outside one
    /// builds on the value in effect, and never carries the outside edit in.
    func testAnInAppEditBeforeTheWatcherHoldsTheOutsideEdit() throws {
        try write(production)
        let settings = Settings(url: url, watch: false)
        try write(production.replacingOccurrences(of: "\"appearance.fontSize\": 14", with: "\"appearance.fontSize\": 14,\n  \"kubernetes.agentWrites\": [\"acme-prod\"]"))
        // The context sheet reads, then writes: the value it builds on is the trusted one.
        XCTAssertEqual(settings.fileValue("kubernetes.agentWrites"), .list([]))
        settings.set("kubernetes.contexts", .entries(["acme-prod": ["class": .string("production")], "acme-dev": ["class": .string("local")]]))
        XCTAssertNotNil(settings.held["kubernetes.agentWrites"])
        XCTAssertEqual(settings.kubernetesAgentWrites, [])
        XCTAssertEqual(settings.kubernetesContexts["acme-dev"]?.contextClass, .local)
        // Keep and Revert see it too: a Keep of a stale banner keeps nothing.
        try write(text().replacingOccurrences(of: "acme-prod\"]", with: "acme-prod\", \"globex-prod\"]"))
        settings.keep(settings.held)
        XCTAssertEqual(settings.kubernetesAgentWrites, [])
        XCTAssertEqual(SettingsHeldBanner.lines(settings.held), [#"kubernetes.agentWrites: adds "acme-prod""#, #"kubernetes.agentWrites: adds "globex-prod""#])
    }

    /// Held survives a relaunch: an outside edit unanswered at quit — or
    /// made while Overterm wasn't running — is held at the next launch.
    func testAHeldEditSurvivesARelaunch() throws {
        try write(production)
        let first = Settings(url: url, watch: false)
        try write(production.replacingOccurrences(of: #""production""#, with: #""local""#))
        first.reload()
        XCTAssertNotNil(first.held["kubernetes.contexts"])
        let next = Settings(url: url, watch: false)
        XCTAssertNotNil(next.held["kubernetes.contexts"])
        XCTAssertEqual(next.kubernetesContexts["acme-prod"]?.contextClass, .production)
        XCTAssertEqual(next.number("appearance.fontSize"), 14)
        // Kept, the next launch takes it.
        next.keep(next.held)
        let third = Settings(url: url, watch: false)
        XCTAssertTrue(third.held.isEmpty)
        XCTAssertEqual(third.kubernetesContexts["acme-prod"]?.contextClass, .local)
        // Edited while not running: held at launch.
        try write(text().replacingOccurrences(of: "14", with: "14, \"kubernetes.agentAccess\": false, \"kubernetes.kubectlPath\": \"/tmp/acme/kubectl\""))
        let fourth = Settings(url: url, watch: false)
        XCTAssertEqual(Set(fourth.held.keys), ["kubernetes.kubectlPath", "kubernetes.agentAccess"])
        XCTAssertEqual(fourth.kubernetesKubectlPath, "")
    }
}
