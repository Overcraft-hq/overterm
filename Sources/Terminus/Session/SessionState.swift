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
        /// A one-pane tab's saved text (a file in Scrollback.directory).
        var scrollback: String?
        /// The island it belonged to — an index into `groups` (absent in
        /// older session files, and for a tab in no group).
        var group: Int?
    }

    /// An island, enough to put it back (Groups/TabGroup).
    struct GroupState: Codable, Equatable {
        var name: String
        var color: String
        var isCollapsed: Bool
        var isStashed: Bool
        var folder: String?
        /// Off: the group's tabs are not reopened on the next launch.
        var restoresOnLaunch: Bool
    }

    /// A split tab's layout: each pane's directory, each split's shape.
    /// Sendable spelled out: Swift 6.4 doesn't infer it for an enum that
    /// holds itself, and without it neither TabState nor SessionState is
    /// Sendable — `empty` then fails to build.
    indirect enum PaneLayout: Codable, Equatable, Sendable {
        /// `scrollback`: the pane's saved text, a file in Scrollback.directory.
        case pane(directory: String?, scrollback: String? = nil)
        case split(axis: String, ratio: Double, first: PaneLayout, second: PaneLayout)

        init<Leaf>(_ tree: SplitTree<Leaf>, directory: (Leaf) -> String?, scrollback: (Leaf) -> String? = { _ in nil }) {
            switch tree {
            case .leaf(let leaf):
                self = .pane(directory: directory(leaf), scrollback: scrollback(leaf))
            case .split(let axis, let ratio, let first, let second):
                self = .split(
                    axis: axis.rawValue, ratio: ratio, first: PaneLayout(first, directory: directory, scrollback: scrollback),
                    second: PaneLayout(second, directory: directory, scrollback: scrollback))
            }
        }

        /// Every saved text it refers to.
        var scrollbackFiles: [String] {
            switch self {
            case .pane(_, let scrollback): scrollback.map { [$0] } ?? []
            case .split(_, _, let first, let second): first.scrollbackFiles + second.scrollbackFiles
            }
        }

        /// The tree again, `make` building each pane from its directory and
        /// saved text (in reading order). An unknown axis falls back to side
        /// by side.
        func tree<Leaf>(_ make: (_ directory: String?, _ scrollback: String?) -> Leaf) -> SplitTree<Leaf> {
            switch self {
            case .pane(let directory, let scrollback):
                return .leaf(make(directory, scrollback))
            case .split(let axis, let ratio, let first, let second):
                return .split(
                    axis: SplitTree<Leaf>.Axis(rawValue: axis) ?? .horizontal, ratio: min(max(ratio, 0.05), 0.95),
                    first: first.tree(make), second: second.tree(make))
            }
        }
    }

    var tabs: [TabState]
    var selectedIndex: Int?
    /// The islands, in strip order; a tab points at one by index. Absent
    /// in session files written before groups existed.
    var groups: [GroupState]?

    static let empty = SessionState(tabs: [], selectedIndex: nil)

    static var defaultURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("session.json")
    }

    /// Nil when there is no file or it can't be read — a bad session file
    /// means a fresh start, never a failed launch. The bad file is set aside
    /// (UnreadableFile), not written over by the next save.
    static func load(from url: URL = defaultURL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            UnreadableFile.setAside(url)
            return nil
        }
        return state
    }

    func save(to url: URL = defaultURL) throws {
        try Self.write(try encoded(), to: url)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
