import SwiftUI

/// The two strips a group mode puts under the terminal: broadcasting into
/// an island, and focusing on one. Both are bars rather than sheets —
/// they are modes you work inside, not questions to answer.
struct GroupBarsView: View {
    @ObservedObject var broadcast: BroadcastModel
    @ObservedObject var focus: GroupFocus
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let onSend: () -> Void
    let onStopBroadcast: () -> Void
    let onLeaveFocus: () -> Void

    /// The host fills the terminal column (it must not get a say in how
    /// wide that column is); the bars sit at its bottom, and the space
    /// above them stays out of the way of the terminal.
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.allowsHitTesting(false)
            if focus.isFocusing { focusBar }
            if broadcast.isOpen { broadcastBar }
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: Broadcast

    private var broadcastBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundStyle(TabStatusStyle.signal)
                PaletteField(
                    text: $broadcast.text, onMove: { _ in }, onSubmit: { _ in onSend() },
                    onCancel: onStopBroadcast, placeholder: "Type a line for every tab in the group",
                    textColor: theme.textNS
                )
                .frame(height: 22)
                Button("Stop") { onStopBroadcast() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.dimText)
                Text(verbatim: "esc").font(.system(size: 10)).foregroundStyle(theme.dimText.opacity(0.7))
            }
            HStack(spacing: 6) {
                Text(verbatim: broadcast.summary).font(.system(size: 11)).foregroundStyle(theme.dimText)
                if broadcast.hasAgent {
                    Text(verbatim: "· Agent tabs receive text only after you press ↩")
                        .font(.system(size: 11)).foregroundStyle(theme.dimText.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.strip)
        .overlay(alignment: .top) { Rectangle().fill(TabStatusStyle.signal.opacity(0.5)).frame(height: 1) }
    }

    // MARK: Focus

    private var focusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(theme.text)
            Text(verbatim: "Focusing on \(store.focusedGroup?.name ?? "")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text)
            if !focus.held.isEmpty {
                Text(verbatim: "\(focus.held.count) held")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(theme.dimText.opacity(0.2)))
                    .foregroundStyle(theme.dimText)
                    .help(focus.held.map { "\($0.title) — \($0.note)" }.joined(separator: "\n"))
                Text(verbatim: "Held until you leave focus")
                    .font(.system(size: 11)).foregroundStyle(theme.dimText)
            }
            Spacer(minLength: 0)
            Text(verbatim: "Blocked agents always break through")
                .font(.system(size: 10)).foregroundStyle(theme.dimText.opacity(0.7))
            Button("Leave") { onLeaveFocus() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.dimText)
            Text(verbatim: "⌃⌘F").font(.system(size: 10)).foregroundStyle(theme.dimText.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.strip)
        .overlay(alignment: .top) { Rectangle().fill(theme.dimText.opacity(0.2)).frame(height: 1) }
    }
}

/// The strip's "Stashed (2)" chip and what it opens: the groups that are
/// out of the way, with what is still running in them.
struct StashedGroupsChip: View {
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let restore: (TabGroup) -> Void
    @State private var showing = false

    var body: some View {
        let stashed = store.stashedGroups
        if !stashed.isEmpty {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "archivebox").font(.system(size: 11))
                    Text(verbatim: "\(stashed.count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(theme.dimText.opacity(0.14)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Stashed groups — their processes keep running")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                StashedGroupsList(store: store, theme: theme, restore: restore)
            }
        }
    }
}

private struct StashedGroupsList: View {
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let restore: (TabGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Stashed groups").font(.system(size: 13, weight: .semibold))
                Text("Processes keep running").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(store.stashedGroups) { group in
                StashedRow(group: group, tabs: store.tabs(in: group), restore: restore)
            }
            Text("⌃⌘S stashes the current group").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct StashedRow: View {
    @ObservedObject var group: TabGroup
    let tabs: [Tab]
    let restore: (TabGroup) -> Void

    private var working: [Tab] { tabs.filter { $0.activity.isWorking } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(group.color.color).frame(width: 7, height: 7)
                Text(verbatim: group.name).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                Button("Restore") { restore(group) }.font(.system(size: 11))
            }
            Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            if let busy = working.first {
                HStack(spacing: 5) {
                    WorkingGlyph(symbol: busy.agent?.symbol ?? "terminal", size: 9)
                    Text(verbatim: "\(busy.title) is still working in the background")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var subtitle: String {
        let when = group.stashedAt.map { "Stashed \(TabGroup.stashedAgo($0))" } ?? "Stashed"
        let count = "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"
        return working.isEmpty ? "\(when) · \(count) · all idle" : "\(when) · \(count)"
    }
}
