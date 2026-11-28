import Combine
import Foundation

/// What a press on the Setup page asks of the window
/// (`TerminalWindowController.performSetupAction`).
package enum SetupPageAction: Equatable, Sendable {
    case checkAgain
    /// A row's command, copied.
    case copy(String)
    /// A row's command typed into a new tab — no Return: the person reads it
    /// and presses it (3.2).
    case newTab(String)
    /// A tool's own install page, in the default browser.
    case open(URL)
    case settings(SettingsSection, key: String?)
    /// macOS's notification question, by this click (D-6).
    case allowNotifications
    /// `general.usageAsk`, as Settings ▸ General sets it (D-7).
    case usageAsk(Bool)
    /// Help ▸ Reset Tips, asked first.
    case resetTips
}

/// The Setup page (docs/design/onboarding/analysis.md, 7.7): what the
/// probe found, read only while the page shows — when it begins to
/// (`visible`), and on Check Again — and dropped when it goes. Nothing is
/// kept, nothing is written (7.10).
@MainActor
package final class SetupPageModel: ObservableObject {
    /// The core rows' facts; nil while the shell is being asked.
    @Published package private(set) var facts: SetupFacts?
    /// `general.usageAsk` as Settings has it now.
    @Published package private(set) var usageAsk: Bool

    /// On screen: read when it begins to be, dropped when it stops.
    package var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible { read() } else { drop() }
        }
    }

    private let settings: Settings
    /// Bumped by every read and drop: an answer that comes after is thrown away.
    private var generation = 0
    private var settingsChanges: AnyCancellable?

    package init(settings: Settings = .shared) {
        self.settings = settings
        usageAsk = settings.usageAsk
        settingsChanges = settings.changes.sink { [weak self] keys in
            guard let self, keys.contains("general.usageAsk") else { return }
            self.usageAsk = self.settings.usageAsk
        }
    }

    /// The core rows as the facts say; nil while asking.
    package var rows: [SetupRow]? { facts.map { facts in SetupCheck.rows(facts: facts) } }

    /// Check Again: everything read anew.
    package func checkAgain() {
        guard visible else { return }
        read()
    }

    /// Allow…: macOS's question, then what it says now.
    package func allowNotifications() {
        let generation = generation
        Task { [weak self] in
            let permission = await AttentionNotifier.requestNow()
            guard let self, self.generation == generation else { return }
            self.facts?.notifications = permission
        }
    }

    /// The switch beside "What runs by itself".
    package func setUsageAsk(_ on: Bool) {
        settings.set("general.usageAsk", .bool(on))
        usageAsk = settings.usageAsk
    }

    private func read() {
        generation += 1
        let generation = generation
        facts = nil
        Task { [weak self] in
            let facts = await SetupProbe.read(full: true)
            guard let self, self.generation == generation, self.visible else { return }
            self.facts = facts
        }
    }

    private func drop() {
        generation += 1
        facts = nil
    }
}
