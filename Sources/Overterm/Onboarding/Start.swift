import Combine
import Foundation

/// The app's one learner (docs/design/onboarding/analysis.md, 7.10): the
/// Start card's state, kept, and told what happened by one-line
/// `note(_:)` calls where the work is done — `createTask`, the Inbox, the
/// changes pane, a tab selected. A call carries no logic of its own:
/// `StartState` has the rules.
///
/// Its state goes in `AppEnvironment.defaults` (`onboarding.card`,
/// `onboarding.steps`), never settings.json: any agent may write that
/// file, people sync it between Macs, and a flag there would turn up in
/// Settings' search. Nothing about the person's files, folders or
/// commands is kept, nor what the probe found.
///
/// The tips (7.6) are its too: what was seen (`onboarding.tipsSeen`),
/// ⌘K's count for T3 (`onboarding.paletteOpens`), and — this launch only —
/// the banner tip placed and those waiting for its place.
///
/// Inert in an isolated run — every scenario and picture would otherwise
/// look like a first launch — unless the run is the `onboarding` scenario,
/// which hands it a launch itself.
@MainActor
package final class Start: ObservableObject {
    package static let shared = Start(
        defaults: AppEnvironment.defaults, active: isActive(isolated: AppEnvironment.isIsolated, scenario: AppEnvironment.e2eScenario))

    package nonisolated static let cardKey = "onboarding.card"
    package nonisolated static let stepsKey = "onboarding.steps"
    package nonisolated static let tipsSeenKey = "onboarding.tipsSeen"
    package nonisolated static let paletteOpensKey = "onboarding.paletteOpens"
    /// When a fresh install first launched: what the Setup page's step
    /// times count from (D-12). Kept on this Mac only.
    package nonisolated static let firstLaunchKey = "onboarding.firstLaunch"
    /// The scenario that drives it in an isolated run.
    package nonisolated static let scenario = "onboarding"

    /// Whether a run's `Start` does anything: the person's app, or the
    /// `onboarding` scenario. Pure.
    package nonisolated static func isActive(isolated: Bool, scenario: String?) -> Bool {
        !isolated || scenario == Self.scenario
    }

    package let active: Bool
    @Published package private(set) var state: StartState
    /// What the probe found for the second step; nil until it has been asked.
    @Published package private(set) var setup: SetupFacts?
    /// `agents.newTaskAgent` as Settings has it: the menu's choice.
    @Published package private(set) var taskAgent: String
    /// The optional panels and whether each is on, for the done state's ticks.
    @Published package private(set) var panels: [SidebarPanel: Bool]
    /// Some tab needs you: the fourth step offers Open Inbox.
    @Published package private(set) var anyNeedsYou = false
    /// The panels a fresh install hid, their tool not found (`FreshInstall`),
    /// as the defaults keep them; the card names those still off.
    @Published package private(set) var hiddenAtInstall: [SidebarPanel]
    /// The terminal's theme, for the done state's line.
    @Published package private(set) var theme: StartText.Theme
    /// The clock steps are dated by; a test's own.
    package var now: () -> Date = { Date() }

    private let defaults: UserDefaults
    private let settings: Settings
    private var probing: Task<Void, Never>?
    private var settingsChanges: AnyCancellable?
    /// Whether the person's Ghostty config names a theme, by the scan a
    /// fresh install decides with (`FreshInstall.ghosttySetsTheme`): read
    /// once, off the main thread, as `Start` is made; false until then.
    private var ghosttySetsTheme = false
    private var ghosttyRead: Task<Void, Never>?

    /// `ghosttyTheme`: the read of the Ghostty config, a test's own.
    package init(
        defaults: UserDefaults, active: Bool, settings: Settings = .shared,
        ghosttyTheme: @escaping @Sendable () -> Bool = { Start.readGhosttyTheme() }
    ) {
        self.defaults = defaults
        self.active = active
        self.settings = settings
        state = StartState(
            storedCard: defaults.string(forKey: Self.cardKey), storedSteps: defaults.dictionary(forKey: Self.stepsKey), tips: settings.tips,
            storedTips: defaults.stringArray(forKey: Self.tipsSeenKey), paletteOpens: defaults.integer(forKey: Self.paletteOpensKey))
        taskAgent = settings.taskAgent
        panels = Self.panels(of: settings)
        hiddenAtInstall = FreshInstall.hidden(stored: defaults.stringArray(forKey: FreshInstall.panelsHiddenKey))
        theme = Self.theme(of: settings, ghosttySetsTheme: false)
        settingsChanges = settings.changes.sink { [weak self] keys in self?.settingsChanged(keys) }
        if active {
            ghosttyRead = Task { [weak self] in
                let sets = await Task.detached(priority: .utility) { ghosttyTheme() }.value
                self?.ghosttyThemeRead(sets)
            }
        }
    }

    /// Waits for the Ghostty config's read: a test's.
    package func ghosttyThemeReadDone() async {
        await ghosttyRead?.value
    }

    /// The Ghostty config Overterm loads, scanned as a fresh install scans
    /// it: whether its last `theme` line names one. Reads files: never on
    /// the main thread.
    package nonisolated static func readGhosttyTheme() -> Bool {
        FreshInstall.ghosttySetsTheme(files: AppEnvironment.ghosttyConfigFiles) { url in
            try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// What happened. Cheap, main-thread, and nothing at all while inert:
    /// a step already done changes nothing and publishes nothing; a tip it
    /// places shows in `state.banner`, which the windows follow.
    package func note(_ event: StartState.Event) {
        guard active else { return }
        place(state.apply(event, now: now()))
    }

    /// Whether the notification ask waits for T1's button (D-6): a fresh
    /// install's first launch, tips on, T1 not seen. Never while inert.
    package var holdsNotificationAsk: Bool { active && state.holdsNotificationAsk }

    /// The banner's ×.
    package func dismissTip() {
        guard active else { return }
        place(state.dismissingTip(now: now()))
    }

    /// What covers a tip's place — a sheet, ⌘K, Tab Peek, the held
    /// banner — and whether the app is in front, as the window sees them.
    package func room(blocked: Bool, inFront: Bool) {
        guard active else { return }
        place(state.withRoom(blocked: blocked, inFront: inFront, now: now()))
    }

    /// Help ▸ Reset Tips: every tip again, ⌘K's count from nought.
    package func resetTips() {
        guard active else { return }
        update(state.resettingTips())
    }

    /// Whether some tab needs you now — the badge's own count, from the window.
    package func noteNeedsYou(_ any: Bool) {
        guard active, any != anyNeedsYou else { return }
        anyNeedsYou = any
    }

    /// This launch, once the window shows (7.2): a fresh install's card
    /// open, an open one collapsed after the first launch, none after an update.
    package func begin(_ launch: FirstRun.Launch) {
        guard active else { return }
        if launch == .fresh, defaults.object(forKey: Self.firstLaunchKey) == nil { defaults.set(now(), forKey: Self.firstLaunchKey) }
        update(state.launched(launch))
    }

    /// When a fresh install first launched; nil for an update's.
    package var firstLaunch: Date? { defaults.object(forKey: Self.firstLaunchKey) as? Date }

    /// Help ▸ Getting Started.
    package func gettingStarted() {
        guard active else { return }
        update(state.gettingStarted())
    }

    /// The chevron, or the collapsed row.
    package func toggle() {
        guard active else { return }
        update(state.toggled())
    }

    /// × or Done: gone for good.
    package func close() {
        guard active else { return }
        update(state.closed())
    }

    /// Turn Off Tips: `general.tips` off — the card and every tip go.
    package func turnOffTips() {
        guard active else { return }
        settings.set("general.tips", .bool(false))
        update(state.withTips(false))
    }

    /// The second step's menu: what New Task starts, written where
    /// Settings ▸ Agents writes it.
    package func chooseAgent(_ value: String) {
        guard active else { return }
        settings.set("agents.newTaskAgent", .string(value))
        taskAgent = settings.taskAgent
        note(.agentChosen)
    }

    /// A done-state tick: the panel's own setting (DISC-N4). Nothing is
    /// unticked for the person.
    package func setPanel(_ panel: SidebarPanel, _ on: Bool) {
        guard active, let key = panel.toggleKey else { return }
        settings.set(key, .bool(on))
        panels = Self.panels(of: settings)
    }

    /// The panels a fresh install hid that are still off: what the card's
    /// line names, and its Show turns on.
    package var stillHidden: [SidebarPanel] { hiddenAtInstall.filter { panel in panels[panel] == false } }

    /// The fresh install's decision made (`FreshInstallSetup.decidePanels`): read again.
    package func hiddenAtInstallChanged() {
        let now = FreshInstall.hidden(stored: defaults.stringArray(forKey: FreshInstall.panelsHiddenKey))
        if now != hiddenAtInstall { hiddenAtInstall = now }
        panels = Self.panels(of: settings)
    }

    /// The hidden line's Show: each panel it hid that is still off, on again
    /// — its own switch back to its default, as a tick does it.
    package func showHidden() {
        guard active else { return }
        for panel in stillHidden {
            if let key = panel.toggleKey { settings.set(key, nil) }
        }
        panels = Self.panels(of: settings)
    }

    /// Asks the probe while the second step shows: once, and again while
    /// the shell hasn't answered (it is asked again after a minute,
    /// `ShellEnvironment.retryAfter`); `force`: Check Again.
    package func probe(force: Bool = false) {
        guard active, probing == nil, force || setup?.shellAnswered != true else { return }
        probing = Task { [weak self] in
            let facts = await SetupProbe.read()
            guard let self else { return }
            self.setup = facts
            self.probing = nil
        }
    }

    // MARK: Private

    private func place(_ applied: (state: StartState, tip: StartState.Banner?)) {
        update(applied.state)
    }

    private func update(_ next: StartState) {
        guard next != state else { return }
        let kept = next.card != state.card || next.steps != state.steps
        let tipsKept = next.tipsSeen != state.tipsSeen || next.paletteOpens != state.paletteOpens
        state = next
        if tipsKept {
            defaults.set(next.storedTips, forKey: Self.tipsSeenKey)
            defaults.set(next.paletteOpens, forKey: Self.paletteOpensKey)
        }
        guard kept else { return }
        if let card = next.card {
            defaults.set(card.rawValue, forKey: Self.cardKey)
        } else {
            defaults.removeObject(forKey: Self.cardKey)
        }
        defaults.set(next.storedSteps, forKey: Self.stepsKey)
    }

    private func settingsChanged(_ keys: Set<String>) {
        if keys.contains("general.tips") { update(state.withTips(settings.tips)) }
        if keys.contains("agents.newTaskAgent") { taskAgent = settings.taskAgent }
        let toggles = Set(SidebarPanel.allCases.compactMap(\.toggleKey))
        if !keys.isDisjoint(with: toggles) { panels = Self.panels(of: settings) }
        if !keys.isDisjoint(with: FreshInstall.themeKeys) {
            let now = Self.theme(of: settings, ghosttySetsTheme: ghosttySetsTheme)
            if now != theme { theme = now }
        }
    }

    private func ghosttyThemeRead(_ sets: Bool) {
        ghosttySetsTheme = sets
        let now = Self.theme(of: settings, ghosttySetsTheme: sets)
        if now != theme { theme = now }
    }

    private static func theme(of settings: Settings, ghosttySetsTheme: Bool) -> StartText.Theme {
        StartText.Theme(
            dark: settings.string("appearance.theme"), light: settings.string("appearance.themeLight"), follows: settings.followsSystemAppearance,
            ghosttyConfig: ghosttySetsTheme)
    }

    private static func panels(of settings: Settings) -> [SidebarPanel: Bool] {
        var panels: [SidebarPanel: Bool] = [:]
        for panel in SidebarPanel.allCases {
            if let key = panel.toggleKey { panels[panel] = settings.bool(key) }
        }
        return panels
    }
}
