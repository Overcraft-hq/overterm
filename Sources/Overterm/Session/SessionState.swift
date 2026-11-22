import Foundation

/// What a window's tabs looked like, enough to rebuild them on the next
/// launch. Terminal contents are not saved — each tab (each pane of a split
/// one) gets a fresh shell in its old directory, and an agent tab resumes
/// its agent's last conversation there.
package struct SessionState: Codable, Equatable {
    package struct TabState: Codable, Equatable {
        package var workingDirectory: String?
        package var customTitle: String?
        package var color: String?
        package var isPinned: Bool
        package var agent: Agent?
        /// An attached checkout's path (absent in older session files).
        package var attachedCheckout: String?
        /// A split tab's panes; absent for a tab with one terminal.
        package var panes: PaneLayout?
        /// Which of `panes`, in reading order, had the keyboard.
        package var focusedPane: Int?
        /// A one-pane tab's saved text (a file in Scrollback.directory).
        package var scrollback: String?
        /// The island it belonged to — an index into `groups` (absent in
        /// older session files, and for a tab in no group).
        package var group: Int?
        /// The page its browser showed (absent in older session files, and
        /// for a tab without one).
        package var browserURL: String? = nil
        /// Every page of its browser, and which showed (absent before the
        /// browser had tabs: `browserURL` was its one page).
        package var browserPages: [String]? = nil
        package var browserPage: Int? = nil
        /// The Kubernetes context a one-pane tab was pinned to — Terminal
        /// in this context (absent in older session files, and for a tab
        /// not pinned). Names and file paths only; restored with a new file,
        /// looked up again in the kubeconfigs as they are then.
        package var kubeContext: KubeTerminalPin? = nil
        /// A split tab's panes' pins, in reading order (as `focusedPane`):
        /// a pane moved in from another tab keeps its own, or none. Absent
        /// when no pane is pinned.
        package var paneKubeContexts: [KubeTerminalPin?]? = nil

        /// The pin pane `index` (reading order) had. A file from before
        /// panes had their own: the tab's, for every pane.
        package func kubeContext(ofPane index: Int) -> KubeTerminalPin? {
            guard let pins = paneKubeContexts else { return kubeContext }
            return pins.indices.contains(index) ? pins[index] : nil
        }

        /// Whether any pane comes back pinned.
        package var hasKubeContext: Bool { kubeContext != nil || paneKubeContexts?.contains { $0 != nil } == true }
    }

    /// An island, enough to put it back (Groups/TabGroup).
    package struct GroupState: Codable, Equatable {
        package var name: String
        package var color: String
        package var isCollapsed: Bool
        package var isStashed: Bool
        /// New tabs opened under this folder join the group, ticked in the
        /// group popover.
        ///
        /// Not `folder`, which is what sessions written before the binding
        /// was a decision called it: back then every new island bound its
        /// checkout by itself, so reading that key would hand every one of
        /// them a binding nobody ticked — the bug this rule exists to fix.
        /// Under a name those files don't have, they come back unbound.
        package var boundFolder: String?
        /// Off: the group's tabs are not reopened on the next launch.
        package var restoresOnLaunch: Bool
        /// Whether tabs opened from the group join it — absent while the
        /// question has never come up (NewTabGroup).
        package var takesNewTabs: Bool?
        /// The group's terminal theme, if it has one.
        package var theme: String?
    }

    /// A split tab's layout: each pane's directory, each split's shape.
    /// Sendable spelled out: Swift 6.4 doesn't infer it for an enum that
    /// holds itself, and without it neither TabState nor SessionState is
    /// Sendable — `empty` then fails to build.
    package indirect enum PaneLayout: Codable, Equatable, Sendable {
        /// `scrollback`: the pane's saved text, a file in Scrollback.directory.
        case pane(directory: String?, scrollback: String? = nil)
        case split(axis: String, ratio: Double, first: PaneLayout, second: PaneLayout)

        package init<Leaf>(_ tree: SplitTree<Leaf>, directory: (Leaf) -> String?, scrollback: (Leaf) -> String? = { _ in nil }) {
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
        package var scrollbackFiles: [String] {
            switch self {
            case .pane(_, let scrollback): scrollback.map { [$0] } ?? []
            case .split(_, _, let first, let second): first.scrollbackFiles + second.scrollbackFiles
            }
        }

        /// The tree again, `make` building each pane from its directory and
        /// saved text (in reading order). An unknown axis falls back to side
        /// by side.
        package func tree<Leaf>(_ make: (_ directory: String?, _ scrollback: String?) -> Leaf) -> SplitTree<Leaf> {
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

    package var tabs: [TabState]
    package var selectedIndex: Int?
    /// The islands, in strip order; a tab points at one by index. Absent
    /// in session files written before groups existed.
    package var groups: [GroupState]?

    package static let empty = SessionState(tabs: [], selectedIndex: nil)

    package static var defaultURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("session.json")
    }

    /// Nil when there is no file or it can't be read — a bad session file
    /// means a fresh start, never a failed launch. The bad file is set aside
    /// (UnreadableFile), not written over by the next save.
    package static func load(from url: URL = defaultURL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            UnreadableFile.setAside(url)
            return nil
        }
        return state
    }

    package func save(to url: URL = defaultURL) throws {
        try Self.write(try encoded(), to: url)
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    package static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
