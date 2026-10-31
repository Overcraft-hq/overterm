import Foundation

struct PaletteItem: Identifiable {
    enum Group: String, CaseIterable {
        case history = "History"
        case snippet = "Snippet"
        case action = "Action"
        case tab = "Tab"
        case worktree = "Worktree"
        /// Containers and compose projects (⇧⌥⌘P scopes the palette to them).
        case container = "Docker"

        /// The scopes the field offers, in the order the designs have them.
        static let scopes: [Group] = [.history, .snippet, .action, .container]
    }

    let id: String
    let group: Group
    let title: String
    let subtitle: String?
    let symbol: String
    /// What the detail pane says about it, if anything: when it last ran,
    /// how it went, where.
    var detail: String?
    /// How it went last time, for the glyph beside a history row.
    var failed: Bool?
    /// `{{name}}`s to fill in before it can run (snippets).
    var placeholders: [String] = []
    /// `run`: Return (true) vs ⌥Return (false). Snippets and history care.
    let perform: @MainActor (_ run: Bool, _ values: [String: String]) -> Void
}

/// The palette's query, its ranked results and the highlighted one.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { rank() }
    }
    @Published private(set) var results: [PaletteItem] = []
    @Published var selectedIndex = 0
    /// Nil is "All" — the scope chips in the field.
    @Published var scope: PaletteItem.Group? {
        didSet { rank() }
    }
    /// What has been typed into the selected snippet's placeholders.
    @Published var values: [String: String] = [:]

    private var items: [PaletteItem] = []

    func reset(with items: [PaletteItem]) {
        self.items = items
        query = ""
        scope = nil
        values = [:]
        rank()
    }

    /// Fresh sources for the query that is already typed — history is
    /// ranked against it, so it has to be rebuilt as you type.
    func restock(_ items: [PaletteItem]) {
        guard items.map(\.id) != self.items.map(\.id) else { return }
        let wanted = selected?.id
        self.items = items
        rank()
        if let wanted, let at = results.firstIndex(where: { $0.id == wanted }) { selectedIndex = at }
    }

    /// Best matches first; with no query, the given order (actions, tabs,
    /// worktrees, snippets). Titles outrank subtitles.
    private func rank() {
        let items = scope.map { scope in self.items.filter { $0.group == scope } } ?? self.items
        guard !query.isEmpty else {
            results = items
            selectedIndex = 0
            return
        }
        results =
            items
            .compactMap { item -> (PaletteItem, Int)? in
                let title = FuzzyMatch.score(query, in: item.title).map { $0 + 1_000_000 }
                let subtitle = item.subtitle.flatMap { FuzzyMatch.score(query, in: $0) }
                guard let best = [title, subtitle].compactMap({ $0 }).max() else { return nil }
                // A history row is a guess at what you meant; an action
                // or a tab named for what you typed is not. Without this a
                // long command containing the letters n, c and l somewhere
                // outranked "New Claude Tab" for "ncl".
                return (item, item.group == .history ? best - 500_000 : best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        selectedIndex = 0
    }

    func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    var selected: PaletteItem? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    /// Whether the selected item still needs something typed in.
    var isReady: Bool {
        guard let selected else { return false }
        return selected.placeholders.allSatisfy { !(values[$0] ?? "").isEmpty }
    }
}
