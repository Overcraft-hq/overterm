import SwiftUI

/// What the rail holds under the panels: the buttons that are about the
/// sidebar itself rather than about one panel of it.
///
/// A type rather than two buttons written into the view, so what sits at
/// the foot of the rail can be read (and checked) without drawing it.
enum SidebarRailAction: String, CaseIterable, Identifiable {
    /// The Settings tab, where VS Code keeps its gear.
    case settings
    /// Put the sidebar away — what the ✕ in the old icon bar did.
    case hide

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .hide: "sidebar.leading"
        }
    }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .hide: "Hide Sidebar"
        }
    }

    /// The key that does the same thing, for the tooltip.
    var shortcut: String {
        switch self {
        case .settings: "⌘,"
        case .hide: "⌘B"
        }
    }

    var help: String { "\(title) (\(shortcut))" }
}

/// The sidebar's activity rail: the panels down its left edge, the way VS
/// Code's activity bar does it, and the sidebar's own buttons at the foot.
///
/// The icons were a row across the top before, which cost the panel a
/// band of its height and left the choice reading as part of whichever
/// panel was open. Down the side they are a fixture: the panel below the
/// header is all panel, and the foot is somewhere for the things that
/// belong to no panel to live.
struct SidebarRail: View {
    /// Settings' "Rail icons" is Compact: smaller icons, a narrower rail.
    @MainActor static var isCompact: Bool { Settings.shared.string("general.sidebarRail") == "compact" }

    /// The rail is a fixed width at every sidebar width: it is chrome, not
    /// content.
    @MainActor static var width: CGFloat { isCompact ? 36 : 44 }
    /// What the panel beside the rail must keep — a file name is unreadable
    /// much under this.
    static let minimumPanelWidth: CGFloat = 176
    /// So the sidebar column's minimum is the two of them, not the panel's
    /// alone: a rail taking its width out of the old minimum truncated
    /// every row.
    @MainActor static var minimumSidebarWidth: CGFloat { width + minimumPanelWidth }

    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var theme: ChromeTheme
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            let shown = SidebarPanel.shown
            ForEach(shown) { item in
                RailButton(selected: sidebar.panel == item, help: item.title, theme: theme) {
                    sidebar.panel = item
                } label: {
                    item.icon(selected: sidebar.panel == item, compact: Self.isCompact)
                }
                .contextMenu {
                    Button("Move Up") { SidebarPanel.move(item, by: -1) }.disabled(item == shown.first)
                    Button("Move Down") { SidebarPanel.move(item, by: 1) }.disabled(item == shown.last)
                    if let key = item.toggleKey {
                        Divider()
                        Button("Hide \(item.title)") { Settings.shared.set(key, .bool(false)) }
                    }
                    Divider()
                    Button("Customize Sidebar…") { onSettings() }
                }
            }
            Spacer(minLength: 8)
            ForEach(SidebarRailAction.allCases) { action in
                RailButton(selected: false, help: action.help, theme: theme) {
                    switch action {
                    case .settings: onSettings()
                    case .hide: onClose()
                    }
                } label: {
                    Image(systemName: action.symbol).font(.system(size: Self.isCompact ? 12 : 14))
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(theme.win)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
    }
}

/// One square in the rail: the glyph, what it does when it is the panel
/// showing, and the bar down its leading edge that says so.
private struct RailButton<Label: View>: View {
    let selected: Bool
    let help: String
    @ObservedObject var theme: ChromeTheme
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        let side: CGFloat = SidebarRail.isCompact ? 26 : 32
        Button(action: action) {
            label
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? theme.rowSel : (hovering ? theme.rowHover : .clear))
                )
                .overlay(alignment: .leading) {
                    // VS Code's mark for the open panel: a short bar on the
                    // edge of the rail, not a tint that a theme could lose.
                    // Two points in from the card's edge, which is also the
                    // rail's — sitting on it, the card's rounded corner cut
                    // the bar in half.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.accentText)
                        .frame(width: 2, height: side * 0.56)
                        .offset(x: -4)
                        .opacity(selected ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? theme.text : theme.text2)
        .onHover { hovering = $0 }
        .help(help)
    }
}
