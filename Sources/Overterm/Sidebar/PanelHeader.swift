import SwiftUI

/// The row at the top of a sidebar panel: which panel you are in, which
/// island it is about, and the one or two things you can do to it.
///
/// Every panel used to draw its own, four near-identical copies of the same
/// HStack. The group is the part that is new and the reason to share it:
/// the sidebar is scoped to the tab you are in, so it has to say which
/// island that is — otherwise the worktrees and sessions it lists look like
/// all of them.
package struct PanelHeader<Trailing: View>: View {
    package let title: String
    /// The island the panel is about, if the selected tab is in one.
    package let group: TabGroup?
    @ObservedObject package var theme: ChromeTheme
    /// What the title points at, for the tooltip — a path, usually.
    package var help: String?
    @ViewBuilder package var trailing: Trailing

    package init(title: String, group: TabGroup?, theme: ChromeTheme, help: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.group = group
        self._theme = ObservedObject(wrappedValue: theme)
        self.help = help
        self.trailing = trailing()
    }

    package var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help ?? title)
            if let group { GroupTag(group: group, theme: theme) }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: ChromeMetrics.row(34))
    }
}

/// The island's colour and name, small — its own view so a rename or a
/// recolour reaches the header.
private struct GroupTag: View {
    @ObservedObject var group: TabGroup
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(group.color.color).frame(width: 7, height: 7)
            Text(verbatim: group.name)
                .font(.system(size: ChromeMetrics.text(11)))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A plain icon button in a panel header.
package struct PanelHeaderButton: View {
    package let symbol: String
    package let help: String
    package let action: () -> Void
    @ObservedObject package var theme: ChromeTheme

    package init(symbol: String, help: String, action: @escaping () -> Void, theme: ChromeTheme) {
        self.symbol = symbol
        self.help = help
        self.action = action
        self._theme = ObservedObject(wrappedValue: theme)
    }

    package var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ChromeMetrics.text(11)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        .help(help)
    }
}
