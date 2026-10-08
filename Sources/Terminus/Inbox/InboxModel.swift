import Foundation

/// Everything waiting on you, in one list.
///
/// A mark on a tab says *that* tab wants you, and the strip's chip says
/// how many — but answering still means going to each one and reading it.
/// The inbox puts the question itself in front of you: what the agent is
/// asking, the diff or command it is asking about, and its own choices as
/// buttons.
///
/// It only ever offers choices it read off that pane's screen
/// (`AgentPrompt`), so a question it does not understand gets "Open tab"
/// and nothing else. Typing a number at an agent that was asking something
/// different is the one mistake this must not make.
@MainActor
final class InboxModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: Tab.ID
        let title: String
        let group: TabGroup?
        let mark: TabActivity.Mark
        let note: String?
        /// Nil when nothing readable is on screen — then the entry is a
        /// line with "Open tab", not a card.
        let prompt: AgentPrompt?
        /// How long it has been waiting.
        let since: Date?

        /// What the card is called: the tab, and what it is asking for.
        var headline: String {
            guard let prompt else { return [title, note].compactMap { $0 }.joined(separator: " — ") }
            return "\(title) \(prompt.summary)"
        }

        static func == (a: Entry, b: Entry) -> Bool {
            a.id == b.id && a.mark == b.mark && a.note == b.note && a.prompt == b.prompt
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// Where J and K are.
    @Published var highlighted: Tab.ID?

    var isEmpty: Bool { entries.isEmpty }

    /// "2 waiting · 1 finished" — what the header and the menu bar say.
    var summary: String {
        let waiting = entries.count { $0.mark == .waiting }
        let failed = entries.count { $0.mark == .failed }
        let done = entries.count { $0.mark == .done }
        let parts = [
            waiting > 0 ? "\(waiting) waiting" : nil,
            failed > 0 ? "\(failed) failed" : nil,
            done > 0 ? "\(done) finished" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing waiting" : parts.joined(separator: " · ")
    }

    /// Rebuilt from the tabs that want something. `screen` reads a pane's
    /// visible text — passed in so the model stays testable.
    func refresh(tabs: [Tab], group: (Tab) -> TabGroup?, screen: (Tab) -> String?, now: Date = Date()) {
        let wanting = tabs.filter(\.activity.needsAttention)
        let built = Self.ordered(wanting).map { tab in
            Entry(
                id: tab.id, title: tab.title, group: group(tab), mark: tab.activity.mark, note: tab.activity.note,
                // Only a blocked agent is being asked anything; a finished
                // one has a prompt on screen that is nobody's question.
                prompt: tab.activity.mark == .waiting ? screen(tab).flatMap(AgentPrompt.parse) : nil,
                since: tab.activity.mark == .waiting ? now : nil)
        }
        if built != entries { entries = built }
        if highlighted == nil || !built.contains(where: { $0.id == highlighted }) { highlighted = built.first?.id }
    }

    /// Blocked first, then failed, then finished, tab order inside each —
    /// the order you want to deal with them in, which is the same rank the
    /// agent overview uses.
    static func ordered(_ tabs: [Tab]) -> [Tab] {
        func rank(_ tab: Tab) -> Int {
            switch tab.activity.mark {
            case .waiting: 0
            case .failed: 1
            case .done: 2
            case .none: 3
            }
        }
        return tabs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// J / K, wrapping.
    func move(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let at = entries.firstIndex { $0.id == highlighted } ?? 0
        let n = entries.count
        highlighted = entries[((at + offset) % n + n) % n].id
    }
}
