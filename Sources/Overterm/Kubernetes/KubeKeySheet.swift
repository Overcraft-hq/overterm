import Foundation

/// `?` on the Kubernetes page: every key the page answers, grouped —
/// generated from `KubernetesKey` (each case's `group`, an exhaustive
/// switch, so a key added without one doesn't build) and the window's
/// Kubernetes commands in `KeyCommands` with the key bound now — never a
/// list written by hand that drifts from what the keys do. Pure.
package enum KubeKeyGroup: String, CaseIterable, Sendable {
    case navigation, list, verbs, writes, sections, window

    package var title: String {
        switch self {
        case .navigation: "Navigation"
        case .list: "The list"
        case .verbs: "A resource's verbs"
        case .writes: "Writes — each asked first"
        case .sections: "Sections"
        case .window: "Anywhere in the window"
        }
    }
}

extension KubernetesKey {
    package var group: KubeKeyGroup {
        switch self {
        case .overview, .workloads, .network, .config, .storage, .cluster, .custom, .helm, .gitops, .forwards: .sections
        case .open, .back, .forward, .close, .command, .namespace, .context, .filter, .help: .navigation
        case .wide, .allNamespaces, .copyKubectl, .groupBy: .list
        case .logs, .history, .tree, .metrics, .earlierRange, .laterRange, .followInTab, .shell, .attach, .portForward, .openForward, .database, .askWhy, .edit: .verbs
        case .restart, .scaleUp, .scaleDown, .scaleTo, .pause, .trigger, .cordon, .newNamespace, .debug, .delete: .writes
        }
    }
}

package enum KubeKeySheet {
    package struct Row: Equatable, Sendable, Identifiable {
        /// What is pressed, as the sheet shows it: `l`, `↩`, `⌥⌘J`; "no key"
        /// for a command left unbound.
        package var key: String
        package var title: String
        package var id: String { key + " " + title }
    }

    package struct Group: Equatable, Sendable, Identifiable {
        package var group: KubeKeyGroup
        package var rows: [Row]
        package var id: String { group.rawValue }
        package var title: String { group.title }
    }

    /// The window's commands that are the page's: `KeyCommands`' Kubernetes ones.
    package static let windowCommands: [KeyCommand] = KeyCommands.all.filter { $0.id.hasPrefix("kubernetes.") }

    package static let unbound = "no key"

    /// Every group in order, each key once, in `KubernetesKey`'s order;
    /// `binding`, a window command's key as it is bound now (nil: none).
    package static func groups(binding: (KeyCommand) -> String?) -> [Group] {
        KubeKeyGroup.allCases.compactMap { group in
            let rows: [Row]
            if group == .window {
                rows = windowCommands.map { Row(key: binding($0) ?? unbound, title: $0.title) }
            } else {
                rows = KubernetesKey.allCases.filter { $0.group == group }.map { Row(key: $0.key, title: $0.title) }
            }
            return rows.isEmpty ? nil : Group(group: group, rows: rows)
        }
    }

    /// What closes the sheet without doing anything else: Esc, or `?` again.
    package static func closes(_ characters: String) -> Bool { characters == "\u{1B}" || characters == KubernetesKey.help.key }

    /// What closes it and goes on to do what it does: the command bar and
    /// the filter keep their keys while it shows.
    package static func passesThrough(_ characters: String) -> Bool {
        characters == KubernetesKey.command.key || characters == KubernetesKey.filter.key
    }
}
