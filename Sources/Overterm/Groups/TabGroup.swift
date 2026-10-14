import Foundation
import SwiftUI

/// A named island of tabs in the strip — a repository, a task, a machine:
/// whatever you keep several terminals open for at once.
///
/// A group owns nothing. The tabs stay in `TabStore.tabs`, in one run, each
/// carrying this group's id; the store keeps that run contiguous. So every
/// existing thing that walks the tabs — closing, the session, the agent
/// overview, tab peek — keeps working without knowing groups exist.
@MainActor
final class TabGroup: ObservableObject, Identifiable {
    let id: UUID
    /// Shown in the chip, editable in place. Prefilled from the git root.
    @Published var name: String
    @Published var color: TabColor
    /// Shown as the chip alone; its tabs keep running, and a hover peeks
    /// into them.
    @Published var isCollapsed: Bool
    /// Out of the strip entirely, processes untouched — `restore` brings it
    /// back where it was.
    @Published var isStashed: Bool
    /// When it was stashed, for "Stashed 2 h ago".
    @Published var stashedAt: Date?
    /// Opening this folder — from the sidebar, Finder, the `overterm`
    /// command — opens its tab in this group. Nil, the default, is no
    /// binding at all, and ⌘T never reads it (`NewTabGroup.Opening`).
    @Published var folder: String?
    /// Reopen this group's tabs and splits on launch.
    @Published var restoresOnLaunch: Bool
    /// Whether a tab opened from one of this group's tabs joins it. Nil
    /// means nobody has said: the island was never the whole strip, so the
    /// question never had to be asked (`NewTabGroup`).
    @Published var takesNewTabs: Bool?

    init(
        id: UUID = UUID(), name: String, color: TabColor = .blue, isCollapsed: Bool = false,
        isStashed: Bool = false, stashedAt: Date? = nil, folder: String? = nil, restoresOnLaunch: Bool = true,
        takesNewTabs: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.isStashed = isStashed
        self.stashedAt = stashedAt
        self.folder = folder
        self.restoresOnLaunch = restoresOnLaunch
        self.takesNewTabs = takesNewTabs
    }

    /// What a new group is called: the folder's name, else "Group".
    static func name(for folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return "Group" }
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "Group" : last
    }

    /// The colour a new group takes: the first one no other group uses,
    /// else round-robin, so neighbouring islands never match.
    static func color(after used: [TabColor]) -> TabColor {
        let palette = TabColor.allCases.filter { $0 != .gray }
        return palette.first { !used.contains($0) } ?? palette[used.count % palette.count]
    }

    /// "Stashed 2 h ago" — coarse on purpose, and pure so it can be tested.
    nonisolated static func stashedAgo(_ then: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(then))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) m ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(seconds / 86_400) days ago"
        }
    }
}

/// The strip read in order: islands and the tabs between them.
enum TabStrip: Equatable {
    case group(TabGroup, [Tab])
    case loose(Tab)

    static func == (a: TabStrip, b: TabStrip) -> Bool {
        switch (a, b) {
        case (.group(let g1, let t1), .group(let g2, let t2)):
            g1.id == g2.id && t1.map(\.id) == t2.map(\.id)
        case (.loose(let a), .loose(let b)):
            a.id == b.id
        default:
            false
        }
    }

    var tabs: [Tab] {
        switch self {
        case .group(_, let tabs): tabs
        case .loose(let tab): [tab]
        }
    }
}
