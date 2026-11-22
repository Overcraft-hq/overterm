import Combine
import Foundation

/// ⌘F: one query across the terminal's scrollback, the checkout's file
/// names and its file contents — and the notes vault's, when notes are on.
@MainActor
package final class SpotlightModel: ObservableObject {
    package init() {}

    package enum Row: Identifiable, Equatable {
        /// Find in the terminal: its match count (nil while unknown).
        case terminal(total: Int?)
        case file(String)
        case content(ContentMatch)
        /// A note: line 0 for its name matching, else the line that does.
        case note(ContentMatch)
        /// All: the rest of a group, behind its tab.
        case more(Scope, count: Int)

        package var id: String {
            switch self {
            case .terminal: "terminal"
            case .file(let path): "f:" + path
            case .content(let m): "c:\(m.path):\(m.line)"
            case .note(let m): "n:\(m.path):\(m.line)"
            case .more(let scope, _): "more:\(scope.rawValue)"
            }
        }
    }

    /// Which results show: a few of each, or one kind in full. A query
    /// over a checkout found hundreds of lines, and the notes were under
    /// all of them.
    package enum Scope: String, CaseIterable, Identifiable {
        case all, files, notes, terminal

        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .all: "All"
            case .files: "Files"
            case .notes: "Notes"
            case .terminal: "Terminal"
            }
        }
    }

    /// How many of each kind All shows before its "more" row.
    package nonisolated static let allLimit = 5

    @Published package var scope: Scope = .all {
        didSet {
            guard scope != oldValue else { return }
            // The notes' tab reads further than All does.
            if scope == .notes || oldValue == .notes { search() } else { rebuild() }
        }
    }

    /// Each kind's count, for the tabs (nil: still looking, or none to look in).
    package func count(of scope: Scope) -> Int? {
        switch scope {
        case .all: nil
        case .files: root == nil ? nil : names.count + contents.count
        case .notes: notes == nil ? nil : noteRows.count
        case .terminal: query.isEmpty ? nil : terminal?.search.total
        }
    }

    /// ⇥ and ⇧⇥: the next tab, the one before.
    package func cycleScope(_ offset: Int) {
        let all = Scope.allCases
        let index = all.firstIndex(of: scope) ?? 0
        scope = all[(index + offset + all.count) % all.count]
    }

    @Published package var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published package private(set) var rows: [Row] = []
    @Published package var selectedIndex = 0
    @Published package private(set) var root: URL?

    package private(set) weak var terminal: TerminalView?
    private var files: [String] = []
    private var names: [String] = []
    private var contents: [ContentMatch] = []
    private var noteRows: [ContentMatch] = []
    /// The vault's search, when notes are on (the window's).
    package var notes: (() -> (any SpotlightNotes)?)?
    private var pending: Task<Void, Never>?
    private var totalSubscription: AnyCancellable?

    /// Starts over for a terminal and the checkout its tab shows.
    package func open(root: URL?, terminal: TerminalView, needle: String?) {
        self.root = root
        self.terminal = terminal
        files = []
        names = []
        contents = []
        noteRows = []
        // The terminal search runs behind the overlay (no bar), so matches
        // highlight as you type; its count feeds the first row.
        terminal.search.begin(needle: nil)
        totalSubscription = terminal.search.$total.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }
        query = needle ?? ""
        rebuild()
        if let root {
            Task { [weak self] in
                let list = await CheckoutSearch.files(in: root)
                guard let self, self.root == root else { return }
                self.files = list
                self.search()
            }
        }
    }

    /// Closing without choosing the terminal row ends its search.
    package func close(keepTerminalSearch: Bool) {
        pending?.cancel()
        totalSubscription = nil
        if !keepTerminalSearch { terminal?.search.end() }
    }

    package func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + rows.count) % rows.count
    }

    package var selected: Row? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    /// The same query again — what it searches has arrived (the notes' index).
    package func refresh() { search() }

    private func search() {
        terminal?.search.needle = query
        // The last keystroke's search is superseded: cancelling it stops its
        // git grep too.
        pending?.cancel()
        let query = self.query
        let files = self.files
        let root = self.root
        if query.count < 2 { contents = [] }
        let vault = notes?()
        // Names now — the index has them; what notes say after the grep.
        let wide = scope == .notes
        let noteNames = vault.map { notes in
            notes.names(matching: query, limit: wide ? 30 : 5).map { ContentMatch(path: $0, line: 0, text: "") }
        }
        noteRows = query.isEmpty ? [] : noteNames ?? []
        pending = Task { [weak self] in
            // Off the main thread: every file of the checkout, per keystroke.
            let ranked = await Task.detached(priority: .userInitiated) { CheckoutSearch.rank(files, query: query) }.value
            guard !Task.isCancelled, let self, self.query == query else { return }
            self.names = ranked
            self.rebuild()
            guard query.count >= 2 else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)  // settle typing
            guard !Task.isCancelled else { return }
            if let root {
                let found = await CheckoutSearch.grep(query, in: root)
                guard !Task.isCancelled, self.query == query else { return }
                self.contents = found
                self.rebuild()
            }
            if let vault {
                let lines = await vault.lines(query, limit: wide ? 100 : 12)
                guard !Task.isCancelled, self.query == query else { return }
                self.noteRows = (noteNames ?? []) + lines
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let before = selected?.id
        rows = Self.rows(
            scope: scope, query: query, terminalTotal: terminal?.search.total, names: names, contents: contents, notes: noteRows)
        selectedIndex = rows.firstIndex { $0.id == before } ?? 0
    }

    /// The rows a tab shows. Pure: the tabs are tested without a terminal.
    package nonisolated static func rows(
        scope: Scope, query: String, terminalTotal: Int?, names: [String], contents: [ContentMatch], notes: [ContentMatch]
    ) -> [Row] {
        var rows: [Row] = []
        let terminal: [Row] = query.isEmpty ? [] : [.terminal(total: terminalTotal)]
        let files = names.map(Row.file) + contents.map(Row.content)
        let noteRows = notes.map(Row.note)
        switch scope {
        case .terminal: rows = terminal
        case .files: rows = files
        case .notes: rows = noteRows
        case .all:
            rows = terminal
            for (kind, group) in [(Scope.files, files), (Scope.notes, noteRows)] {
                rows += group.prefix(allLimit)
                if group.count > allLimit { rows.append(.more(kind, count: group.count)) }
            }
        }
        return rows
    }
}

/// The notes vault as ⌘F searches it (`OvertermNotes`' `VaultSearch`): its
/// notes' names now, what they say after the checkout's grep.
@MainActor
package protocol SpotlightNotes {
    func names(matching query: String, limit: Int) -> [String]
    /// Off the main thread.
    func lines(_ query: String, limit: Int) async -> [ContentMatch]
}
