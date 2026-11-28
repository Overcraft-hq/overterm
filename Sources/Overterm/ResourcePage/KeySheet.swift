import SwiftUI

/// One sheet of keys, whoever's they are: a page's `?` (Docker's,
/// Activity's — `ResourceKeySheet`), Review's, and Help ▸ Keys Here for the
/// terminal, the editor and the browser. Groups of rows, the window's
/// commands among them with the key bound now (DISC-U6, DISC-N1). Pure.
package struct KeySheetRow: Equatable, Sendable, Identifiable {
    /// What is pressed: `l`, `↩`, `⌥⌘J`; `KeySheet.unbound` for a command
    /// left without one.
    package var key: String
    package var title: String
    package var id: String { key + " " + title }

    package init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

package struct KeySheetGroup: Equatable, Sendable, Identifiable {
    package var title: String
    package var rows: [KeySheetRow]
    package var id: String { title }

    package init(title: String, rows: [KeySheetRow]) {
        self.title = title
        self.rows = rows
    }
}

package enum KeySheet {
    package static let unbound = "no key"
    /// The title of a page's keys that name no group.
    package static let listGroup = "Keys in the list"
    package static let windowGroup = "Anywhere in the window"

    /// A page's keys by their `sheetGroup`, the groups in the order their first
    /// key comes in the table, each key once.
    package static func groups<Key: ResourceKey>(of _: Key.Type) -> [KeySheetGroup] {
        var groups: [KeySheetGroup] = []
        for key in Key.allCases {
            let title = key.sheetGroup ?? listGroup
            let row = KeySheetRow(key: key.key, title: key.title)
            if let at = groups.firstIndex(where: { $0.title == title }) {
                groups[at].rows.append(row)
            } else {
                groups.append(KeySheetGroup(title: title, rows: [row]))
            }
        }
        return groups
    }

    /// The window's commands as a group: each with the key `binding` says
    /// it has now (nil: none). Nil when there are none.
    package static func commands(_ commands: [KeyCommand], title: String, binding: (KeyCommand) -> String?) -> KeySheetGroup? {
        let rows = commands.map { KeySheetRow(key: binding($0) ?? unbound, title: $0.title) }
        return rows.isEmpty ? nil : KeySheetGroup(title: title, rows: rows)
    }

    /// The commands whose identifiers start with one of `prefixes`
    /// (`"docker."`), in `KeyCommands`' order.
    package static func commands(prefixed prefixes: [String]) -> [KeyCommand] {
        KeyCommands.all.filter { command in prefixes.contains { command.id.hasPrefix($0) } }
    }

    /// Where the keyboard is, for Help ▸ Keys Here: what that surface's sheet lists.
    package enum Surface: String, Sendable, CaseIterable {
        case terminal, editor, browser

        package var title: String {
            switch self {
            case .terminal: "Keys in the terminal"
            case .editor: "Keys in the editor"
            case .browser: "Keys in the browser"
            }
        }

        /// The browser's own keys while it has the keyboard — Safari's, fixed
        /// in `BrowserViewController.handleKey`, so not rebindable.
        package static let browserKeys: [KeySheetRow] = [
            KeySheetRow(key: "⌘T", title: "New page"), KeySheetRow(key: "⌘W", title: "Close the page"),
            KeySheetRow(key: "⌘L", title: "The address field"), KeySheetRow(key: "⌘R", title: "Reload"),
            KeySheetRow(key: "⌘[", title: "Back"), KeySheetRow(key: "⌘]", title: "Forward"),
            KeySheetRow(key: "⌃⇥", title: "Next page"), KeySheetRow(key: "⌃⇧⇥", title: "Previous page"),
            KeySheetRow(key: "⌘1…9", title: "A page by its place; ⌘9 the last"),
        ]

        /// The groups of `KeyCommands` the surface answers, then the window's.
        package func groups(binding: (KeyCommand) -> String?) -> [KeySheetGroup] {
            let own: [KeySheetGroup?]
            switch self {
            case .terminal:
                own = ["Terminal", "Tabs", "Panes", "Groups"].map { group in
                    KeySheet.commands(KeyCommands.all.filter { $0.group == group }, title: group, binding: binding)
                }
            case .editor:
                own = ["Editor", "Editing"].map { group in
                    KeySheet.commands(KeyCommands.all.filter { $0.group == group }, title: group, binding: binding)
                }
            case .browser:
                own = [KeySheetGroup(title: "Browser", rows: Self.browserKeys), KeySheet.commands(KeySheet.commands(prefixed: ["browser."]), title: "The column", binding: binding)]
            }
            let window = KeySheet.commands(
                KeyCommands.all.filter { ["palette.show", "sidebar.toggle", "inbox.show", "tabs.nextAttention", "app.settings"].contains($0.id) },
                title: windowGroup, binding: binding)
            return (own + [window]).compactMap { $0 }
        }
    }
}

/// The sheet: a title, its groups and a footnote. Esc, a click or (where
/// its host says so) any key closes it.
package struct KeySheetView: View {
    @ObservedObject package var theme: ChromeTheme
    package let title: String
    package let groups: [KeySheetGroup]
    package var footnote: String?
    package let identifier: String
    package let close: () -> Void

    package init(theme: ChromeTheme, title: String, groups: [KeySheetGroup], footnote: String? = nil, identifier: String, close: @escaping () -> Void) {
        self._theme = ObservedObject(wrappedValue: theme)
        self.title = title
        self.groups = groups
        self.footnote = footnote
        self.identifier = identifier
        self.close = close
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: title).font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Text(verbatim: "Esc").font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            if groups.count > 1 || group.title != KeySheet.listGroup {
                                Text(verbatim: group.title).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.text3)
                            }
                            ForEach(group.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(verbatim: row.key).font(.system(size: ChromeMetrics.text(12), design: .monospaced))
                                        .foregroundStyle(row.key == KeySheet.unbound ? theme.text3 : theme.text)
                                        .frame(width: 64, alignment: .leading)
                                    Text(verbatim: row.title).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if let footnote {
                        Text(verbatim: footnote).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                    }
                }
                .padding(18)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
        .onTapGesture { close() }
        .accessibilityIdentifier(identifier)
    }
}
