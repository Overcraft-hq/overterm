import Foundation

/// Broadcast input to a group (⌥⌘I): one line typed into every tab of an
/// island at once — `git pull --rebase` across five worktrees.
///
/// Typing is the same path a snippet takes: `insertText` is a bracketed
/// paste, so a trailing newline would arrive as a literal; Return is a
/// keystroke of its own (`pressReturn`). An agent tab gets the text the
/// same way and submits on the same Return — which is why the bar says so.
@MainActor
package final class BroadcastModel: ObservableObject {
    package init() {}

    @Published package private(set) var group: TabGroup?
    /// The tabs a line goes to: the island's, but those held.
    @Published package private(set) var targets: [Tab] = []
    /// The island's tabs a line doesn't go to, and why (TERM-G1).
    @Published package private(set) var held: [(tab: Tab, reason: Held)] = []
    @Published package var text: String = ""
    /// Production contexts whose panes were let in, each by its name typed.
    @Published package private(set) var includedProduction: Set<String> = []

    /// Why a tab's focused pane is left out of a broadcast: a line and a
    /// Return there would do what nobody meant.
    package enum Held: Equatable {
        /// Pinned to a production context: only with its name typed.
        case production(context: String)
        /// Its agent asks something: Return would take the marked answer.
        case asking
        /// A terraform write's question is on its screen.
        case terraform
        /// Suspended: the line would wait, then run on Resume.
        case suspended

        package var said: String {
            switch self {
            case .production(let context): "production · \(context)"
            case .asking: "its agent asks"
            case .terraform: "terraform asks"
            case .suspended: "suspended"
            }
        }
    }

    /// The window's: why a tab is held, read at the start and again at
    /// every send — the island's tabs change, an agent starts asking.
    package var hold: @MainActor (Tab) -> Held? = { _ in nil }
    /// The window's: the island's tabs now.
    package var members: @MainActor (TabGroup) -> [Tab] = { _ in [] }

    package var isOpen: Bool { group != nil }

    /// What the bar says it will do, and what it leaves out by name.
    package var summary: String {
        guard let group else { return "" }
        let n = targets.count
        let said = "Broadcasting to \(n) tab\(n == 1 ? "" : "s") in \(group.name)"
        guard !held.isEmpty else { return said }
        return said + " — not to " + held.map { "“\($0.tab.title)” (\($0.reason.said))" }.joined(separator: ", ")
    }

    /// The production contexts held now, for the bar's Include… buttons.
    package var heldProduction: [String] {
        var seen: [String] = []
        for entry in held {
            if case .production(let context) = entry.reason, !seen.contains(context) { seen.append(context) }
        }
        return seen
    }

    /// Whether any target runs an agent — the line about Return only
    /// matters then.
    package var hasAgent: Bool { targets.contains { $0.agent != nil } }

    package func begin(group: TabGroup, tabs: [Tab]) {
        self.group = group
        includedProduction = []
        text = ""
        settle(tabs)
    }

    /// The island's tabs read again, each held or not.
    package func refresh() {
        guard let group else { return }
        settle(members(group))
    }

    private func settle(_ tabs: [Tab]) {
        var going: [Tab] = []
        var left: [(tab: Tab, reason: Held)] = []
        for tab in tabs {
            if let reason = hold(tab), !isIncluded(reason) {
                left.append((tab, reason))
            } else {
                going.append(tab)
            }
        }
        if going.map(ObjectIdentifier.init) != targets.map(ObjectIdentifier.init) { targets = going }
        if left.map({ ObjectIdentifier($0.tab) }) != held.map({ ObjectIdentifier($0.tab) }) || left.map(\.reason) != held.map(\.reason) { held = left }
    }

    private func isIncluded(_ reason: Held) -> Bool {
        if case .production(let context) = reason { return includedProduction.contains(context) }
        return false
    }

    /// A production context's panes let in — the window asks for its name
    /// typed first.
    package func includeProduction(_ context: String) {
        includedProduction.insert(context)
        refresh()
    }

    package func stop() {
        group = nil
        targets = []
        held = []
        includedProduction = []
        text = ""
    }

    /// Sends the line to every target's focused pane and keeps the bar open
    /// for the next one — the targets read again first: what is held now
    /// isn't typed into. Returns what was sent, for the E2E scenario.
    @discardableResult
    package func send() -> String? {
        let line = text
        guard isOpen, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        refresh()
        for tab in targets {
            tab.terminal.insertText(line)
            tab.terminal.pressReturn()
        }
        text = ""
        return line
    }

    /// A closed tab must not be typed into.
    package func forget(_ tab: Tab) {
        targets.removeAll { $0 === tab }
        held.removeAll { $0.tab === tab }
        if targets.isEmpty && held.isEmpty { stop() }
    }
}
