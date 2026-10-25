import Combine
import Foundation

/// ⌘F: one query across the terminal's scrollback, the checkout's file
/// names and its file contents — and the notes vault's, when notes are on.
@MainActor
final class SpotlightModel: ObservableObject {
    enum Row: Identifiable, Equatable {
        /// Find in the terminal: its match count (nil while unknown).
        case terminal(total: Int?)
        case file(String)
        case content(ContentMatch)
        /// A note: line 0 for its name matching, else the line that does.
        case note(ContentMatch)

        var id: String {
            switch self {
            case .terminal: "terminal"
            case .file(let path): "f:" + path
            case .content(let m): "c:\(m.path):\(m.line)"
            case .note(let m): "n:\(m.path):\(m.line)"
            }
        }
    }

    @Published var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published var selectedIndex = 0
    @Published private(set) var root: URL?

    private(set) weak var terminal: TerminalView?
    private var files: [String] = []
    private var names: [String] = []
    private var contents: [ContentMatch] = []
    private var noteRows: [ContentMatch] = []
    /// The vault and its index, when notes are on (the window's).
    var notes: (() -> (NotesVault, NotesIndex)?)?
    private var pending: Task<Void, Never>?
    private var totalSubscription: AnyCancellable?

    /// Starts over for a terminal and the checkout its tab shows.
    func open(root: URL?, terminal: TerminalView, needle: String?) {
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
    func close(keepTerminalSearch: Bool) {
        pending?.cancel()
        totalSubscription = nil
        if !keepTerminalSearch { terminal?.search.end() }
    }

    func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + rows.count) % rows.count
    }

    var selected: Row? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    /// The same query again — what it searches has arrived (the notes' index).
    func refresh() { search() }

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
        let noteNames = vault.map { _, index in
            index.notes(matching: query, limit: 5).map { ContentMatch(path: $0, line: 0, text: "") }
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
            if let (vault, index) = vault {
                let paths = index.notes(matching: "", limit: .max)
                let lines = await Task.detached(priority: .userInitiated) { NotesSearch.lines(query, in: vault, paths: paths, limit: 12) }.value
                guard !Task.isCancelled, self.query == query else { return }
                self.noteRows = (noteNames ?? []) + lines
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let before = selected?.id
        var rows: [Row] = []
        if !query.isEmpty { rows.append(.terminal(total: terminal?.search.total)) }
        rows += names.map(Row.file)
        rows += contents.map(Row.content)
        rows += noteRows.map(Row.note)
        self.rows = rows
        selectedIndex = rows.firstIndex { $0.id == before } ?? 0
    }
}
