import Combine
import Foundation

/// ⌘F: one query across the terminal's scrollback, the checkout's file
/// names and its file contents.
@MainActor
final class SpotlightModel: ObservableObject {
    enum Row: Identifiable, Equatable {
        /// Find in the terminal: its match count (nil while unknown).
        case terminal(total: Int?)
        case file(String)
        case content(ContentMatch)

        var id: String {
            switch self {
            case .terminal: "terminal"
            case .file(let path): "f:" + path
            case .content(let m): "c:\(m.path):\(m.line)"
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
    private var pending: Task<Void, Never>?
    private var totalSubscription: AnyCancellable?

    /// Starts over for a terminal and the checkout its tab shows.
    func open(root: URL?, terminal: TerminalView, needle: String?) {
        self.root = root
        self.terminal = terminal
        files = []
        names = []
        contents = []
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

    private func search() {
        terminal?.search.needle = query
        pending?.cancel()
        let query = self.query
        names = CheckoutSearch.rank(files, query: query)
        rebuild()
        guard let root, query.count >= 2 else {
            contents = []
            rebuild()
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)  // settle typing
            guard !Task.isCancelled else { return }
            let found = await CheckoutSearch.grep(query, in: root)
            guard !Task.isCancelled, let self, self.query == query else { return }
            self.contents = found
            self.rebuild()
        }
    }

    private func rebuild() {
        let before = selected?.id
        var rows: [Row] = []
        if !query.isEmpty { rows.append(.terminal(total: terminal?.search.total)) }
        rows += names.map(Row.file)
        rows += contents.map(Row.content)
        self.rows = rows
        selectedIndex = rows.firstIndex { $0.id == before } ?? 0
    }
}
