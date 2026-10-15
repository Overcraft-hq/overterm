import SwiftUI

/// The row under the sidebar's icon bar: which panel you are in, which
/// island it is about, and the one or two things you can do to it.
///
/// Every panel used to draw its own, four near-identical copies of the same
/// HStack. The group is the part that is new and the reason to share it:
/// the sidebar is scoped to the tab you are in, so it has to say which
/// island that is — otherwise the worktrees and sessions it lists look like
/// all of them.
struct PanelHeader<Trailing: View>: View {
    let title: String
    /// The island the panel is about, if the selected tab is in one.
    let group: TabGroup?
    @ObservedObject var theme: ChromeTheme
    /// What the title points at, for the tooltip — a path, usually.
    var help: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
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
        .frame(height: 34)
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
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A plain icon button in a panel header.
struct PanelHeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
        .help(help)
    }
}
