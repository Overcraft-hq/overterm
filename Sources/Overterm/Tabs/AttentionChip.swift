import SwiftUI

/// "3 need you" in the strip, and the list behind it.
///
/// A mark on a tab says *that* tab wants you; with four islands and twenty
/// tabs it does not say how much is waiting in total, and the ones that are
/// collapsed or scrolled out of the strip say nothing at all. This counts
/// them in one place and takes you to any of them — the strip's answer to
/// "what is outstanding", next to the Dock badge's.
struct AttentionChip: View {
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let select: (Tab) -> Void
    @State private var showing = false

    /// Blocked first, then failed, then finished — the order you want to
    /// deal with them in. `Mark` is already ordered by urgency.
    private var waiting: [Tab] {
        store.tabs.filter(\.activity.needsAttention).sorted { $0.activity.mark > $1.activity.mark }
    }

    var body: some View {
        if !waiting.isEmpty {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                    Text(verbatim: "\(waiting.count) need you")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(theme.orangeText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(theme.attnBg))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Tabs that need you — ⌥⌘↓ for the next one")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AttentionList(
                    tabs: waiting, store: store, theme: theme,
                    select: { tab in
                        showing = false
                        select(tab)
                    })
            }
        }
    }
}

private struct AttentionList: View {
    let tabs: [Tab]
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let select: (Tab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Needs you")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ForEach(tabs) { tab in
                AttentionRow(tab: tab, group: store.group(of: tab), theme: theme, select: { select(tab) })
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 5)
            HStack {
                Text("Jump to next").font(.system(size: 12)).foregroundStyle(theme.text2)
                Spacer()
                Text(verbatim: "⌥⌘↓").font(.system(size: 12)).foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .padding(5)
        .frame(width: 340)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

private struct AttentionRow: View {
    @ObservedObject var tab: Tab
    let group: TabGroup?
    @ObservedObject var theme: ChromeTheme
    let select: () -> Void
    @State private var hovering = false

    private var detail: String {
        tab.activity.note ?? GroupFocus.describe(tab.activity.mark)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Circle()
                    .fill(TabStatusStyle.color(for: tab.activity, idle: theme.segIdle))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(tab.activity.mark == .waiting ? theme.orangeText : theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let group {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(group.color.color).frame(width: 8, height: 8)
                        Text(verbatim: group.name).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowSel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
