import Foundation

package struct PaletteItem: Identifiable {
    package enum Group: String, CaseIterable {
        case history = "History"
        case snippet = "Snippet"
        case action = "Action"
        case tab = "Tab"
        case worktree = "Worktree"
        /// Containers and compose projects (⌃⌘P scopes the palette to them).
        case container = "Docker"
        /// Contexts, namespaces and pods (⌃⌘J scopes the palette to them).
        case kubernetes = "Kubernetes"
        /// Roots and their workspaces (⌃⌘E scopes the palette to them).
        case terraform = "Terraform"
        /// Listening ports and the busiest processes (⌃⌘A scopes the palette to them).
        case activity = "Activity"
        /// Settings, each opening ⌘, on its row.
        case setting = "Setting"

        /// The scopes the field offers, in the order the designs have them.
        package static let scopes: [Group] = [.history, .snippet, .action, .setting, .container, .kubernetes, .terraform, .activity]
    }

    package let id: String
    package let group: Group
    package let title: String
    /// What it is, and the key that does it now (`PaletteCommands.withLiveKeys`).
    package var subtitle: String?
    /// The command it does (`KeyCommands`): the key its row says is that
    /// command's as bound now, never one written into `subtitle`.
    package var command: String?
    package let symbol: String
    /// What the detail pane says about it, if anything: when it last ran,
    /// how it went, where.
    package var detail: String?
    /// How it went last time, for the glyph beside a history row.
    package var failed: Bool?
    /// `{{name}}`s to fill in before it can run (snippets).
    package var placeholders: [String] = []
    /// `run`: Return (true) vs ⌥Return (false). Snippets and history care.
    package let perform: @MainActor (_ run: Bool, _ values: [String: String]) -> Void
    /// A history row's Forget: out of the history.
    package var forget: (@MainActor () -> Void)?

    package init(
        id: String, group: Group, title: String, subtitle: String?, symbol: String, detail: String? = nil, failed: Bool? = nil, placeholders: [String] = [],
        command: String? = nil, perform: @escaping @MainActor (_ run: Bool, _ values: [String: String]) -> Void
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.command = command
        self.symbol = symbol
        self.detail = detail
        self.failed = failed
        self.placeholders = placeholders
        self.perform = perform
    }
}

/// The palette's query, its ranked results and the highlighted one.
@MainActor
package final class PaletteModel: ObservableObject {
    package init() {}

    @Published package var query = "" {
        didSet { rank() }
    }
    @Published package private(set) var results: [PaletteItem] = []
    @Published package var selectedIndex = 0
    /// Nil is "All" — the scope chips in the field.
    @Published package var scope: PaletteItem.Group? {
        didSet { rank() }
    }
    /// What has been typed into the selected snippet's placeholders.
    @Published package var values: [String: String] = [:]

    private var items: [PaletteItem] = []

    package func reset(with items: [PaletteItem]) {
        self.items = items
        query = ""
        scope = nil
        values = [:]
        rank()
    }

    /// Fresh sources for the query that is already typed — history is
    /// ranked against it, so it has to be rebuilt as you type.
    package func restock(_ items: [PaletteItem]) {
        guard items.map(\.id) != self.items.map(\.id) else { return }
        let wanted = selected?.id
        self.items = items
        rank()
        if let wanted, let at = results.firstIndex(where: { $0.id == wanted }) { selectedIndex = at }
    }

    /// A row gone from what it lists (a history entry forgotten).
    package func forget(id: String) {
        items.removeAll { $0.id == id }
        rank()
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
                // A setting comes after an action or a tab of the same
                // title — "changes" is the Changes pane before the gutter's
                // setting — and still before anything matched by subtitle only.
                let penalty = item.group == .history ? 500_000 : item.group == .setting ? 300_000 : 0
                return (item, best - penalty)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        selectedIndex = 0
    }

    package func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    package var selected: PaletteItem? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    /// How many of a group the query finds (nil: all of them), for its tab.
    package func count(of group: PaletteItem.Group?) -> Int {
        guard let group else { return items.isEmpty ? 0 : ranked(items).count }
        return ranked(items.filter { $0.group == group }).count
    }

    /// The tabs as the palette shows them: All, then the groups offered.
    package var tabs: [PaletteItem.Group?] {
        [nil]
            + PaletteItem.Group.scopes.filter {
                ($0 != .snippet || Settings.shared.snippetsEnabled) && ($0 != .container || Settings.shared.dockerEnabled)
                    && ($0 != .kubernetes || Settings.shared.kubernetesEnabled) && ($0 != .terraform || Settings.shared.terraformEnabled)
                    && ($0 != .activity || Settings.shared.activityEnabled)
            }
    }

    /// ⇥ and ⇧⇥: the next tab, the one before.
    package func cycleScope(_ offset: Int) {
        let all = tabs
        let index = all.firstIndex { $0 == scope } ?? 0
        scope = all[(index + offset + all.count) % all.count]
    }

    private func ranked(_ items: [PaletteItem]) -> [PaletteItem] {
        guard !query.isEmpty else { return items }
        return items.filter { FuzzyMatch.score(query, in: $0.title) != nil || $0.subtitle.flatMap { FuzzyMatch.score(query, in: $0) } != nil }
    }

    /// Whether the selected item still needs something typed in.
    package var isReady: Bool {
        guard let selected else { return false }
        return selected.placeholders.allSatisfy { !(values[$0] ?? "").isEmpty }
    }
}
