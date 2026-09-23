import Foundation

struct PaletteItem: Identifiable {
    enum Group: String {
        case action = "Action"
        case tab = "Tab"
        case worktree = "Worktree"
        case snippet = "Snippet"
    }

    let id: String
    let group: Group
    let title: String
    let subtitle: String?
    let symbol: String
    /// `run`: Return (true) vs ⌥Return (false). Only snippets care.
    let perform: @MainActor (_ run: Bool) -> Void
}

/// The palette's query, its ranked results and the highlighted one.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { rank() }
    }
    @Published private(set) var results: [PaletteItem] = []
    @Published var selectedIndex = 0

    private var items: [PaletteItem] = []

    func reset(with items: [PaletteItem]) {
        self.items = items
        query = ""
        rank()
    }

    /// Best matches first; with no query, the given order (actions, tabs,
    /// worktrees, snippets). Titles outrank subtitles.
    private func rank() {
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
                return (item, best)
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
}
