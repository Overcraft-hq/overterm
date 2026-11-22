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
    @Published package private(set) var group: TabGroup?
    @Published package private(set) var targets: [Tab] = []
    @Published package var text: String = ""

    package var isOpen: Bool { group != nil }

    /// What the bar says it will do.
    package var summary: String {
        guard let group else { return "" }
        let n = targets.count
        return "Broadcasting to \(n) tab\(n == 1 ? "" : "s") in \(group.name)"
    }

    /// Whether any target runs an agent — the line about Return only
    /// matters then.
    package var hasAgent: Bool { targets.contains { $0.agent != nil } }

    package func begin(group: TabGroup, tabs: [Tab]) {
        self.group = group
        targets = tabs
        text = ""
    }

    package func stop() {
        group = nil
        targets = []
        text = ""
    }

    /// Sends the line to every target's focused pane and keeps the bar open
    /// for the next one. Returns what was sent, for the E2E scenario.
    @discardableResult
    package func send() -> String? {
        let line = text
        guard isOpen, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
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
        if targets.isEmpty { stop() }
    }
}
