import Foundation

/// What a window's tabs looked like, enough to rebuild them on the next
/// launch. Terminal contents are not saved — each tab (each pane of a split
/// one) gets a fresh shell in its old directory, and an agent tab resumes
/// its agent's last conversation there.
struct SessionState: Codable, Equatable {
    struct TabState: Codable, Equatable {
        var workingDirectory: String?
        var customTitle: String?
        var color: String?
        var isPinned: Bool
        var agent: Agent?
        /// An attached checkout's path (absent in older session files).
        var attachedCheckout: String?
        /// A split tab's panes; absent for a tab with one terminal.
        var panes: PaneLayout?
        /// Which of `panes`, in reading order, had the keyboard.
        var focusedPane: Int?
    }

    /// A split tab's layout: each pane's directory, each split's shape.
    indirect enum PaneLayout: Codable, Equatable {
        case pane(directory: String?)
        case split(axis: String, ratio: Double, first: PaneLayout, second: PaneLayout)

        init<Leaf>(_ tree: SplitTree<Leaf>, directory: (Leaf) -> String?) {
            switch tree {
            case .leaf(let leaf):
                self = .pane(directory: directory(leaf))
            case .split(let axis, let ratio, let first, let second):
                self = .split(
                    axis: axis.rawValue, ratio: ratio, first: PaneLayout(first, directory: directory),
                    second: PaneLayout(second, directory: directory))
            }
        }

        /// The tree again, `make` building each pane from its directory
        /// (in reading order). An unknown axis falls back to side by side.
        func tree<Leaf>(_ make: (String?) -> Leaf) -> SplitTree<Leaf> {
            switch self {
            case .pane(let directory):
                return .leaf(make(directory))
            case .split(let axis, let ratio, let first, let second):
                return .split(
                    axis: SplitTree<Leaf>.Axis(rawValue: axis) ?? .horizontal, ratio: min(max(ratio, 0.05), 0.95),
                    first: first.tree(make), second: second.tree(make))
            }
        }
    }

    var tabs: [TabState]
    var selectedIndex: Int?

    static let empty = SessionState(tabs: [], selectedIndex: nil)

    static var defaultURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("session.json")
    }

    /// Nil when there is no file or it can't be read — a bad session file
    /// means a fresh start, never a failed launch.
    static func load(from url: URL = defaultURL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
