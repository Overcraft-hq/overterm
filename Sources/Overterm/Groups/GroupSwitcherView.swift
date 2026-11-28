import SwiftUI

/// ⌃⌘G: the islands and their tabs, side by side. Typing filters them,
/// → walks the highlighted island's tabs and ← back; ↩ switches, ⌥↩ moves
/// the current tab into the highlighted group, Esc clears the filter, then
/// closes.
///
/// The design asked for ⇧⌘G; Ghostty binds that to `navigate_search` and
/// eats it before the menu sees it (docs/ghostty.md), hence ⌃⌘G.
package struct GroupSwitcherView: View {
    @ObservedObject package var store: TabStore
    @ObservedObject package var theme: ChromeTheme
    package let onChoose: (TabGroup) -> Void
    package let onChooseTab: (Tab) -> Void
    package let onMoveHere: (TabGroup) -> Void
    package let onDismiss: () -> Void

    package init(
        store: TabStore, theme: ChromeTheme, onChoose: @escaping (TabGroup) -> Void, onChooseTab: @escaping (Tab) -> Void, onMoveHere: @escaping (TabGroup) -> Void, onDismiss: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._theme = ObservedObject(wrappedValue: theme)
        self.onChoose = onChoose
        self.onChooseTab = onChooseTab
        self.onMoveHere = onMoveHere
        self.onDismiss = onDismiss
    }

    /// Strip order, so the list reads as the strip does; stashed last;
    /// only what matches what was typed.
    private var groups: [TabGroup] {
        GroupSwitcherFilter.groups(GroupSwitcherFilter.order(store), tabs: { store.tabs(in: $0) }, query: store.switcherQuery)
    }

    private var highlighted: TabGroup? { groups.first { $0.id == store.switcherHighlight } ?? groups.first }

    private var highlightedTabs: [Tab] {
        highlighted.map { GroupSwitcherFilter.tabs(of: $0, store.tabs(in: $0), query: store.switcherQuery) } ?? []
    }

    package var body: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture(perform: onDismiss)
            HStack(alignment: .top, spacing: 0) {
                groupList
                Divider()
                tabList
            }
            .frame(width: 720, height: 420)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.strip))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.dimText.opacity(0.25)))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Groups").font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.dimText)
            // What was typed: the keys go to the switcher, not a field.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                Text(verbatim: store.switcherQuery.isEmpty ? "Type to filter" : store.switcherQuery)
                    .font(.system(size: ChromeMetrics.text(12)))
                    .foregroundStyle(store.switcherQuery.isEmpty ? theme.dimText : theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: ChromeMetrics.row(26))
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.dimText.opacity(0.12)))
            .accessibilityIdentifier("groupSwitcher.query")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        GroupRow(
                            group: group, tabs: store.tabs(in: group), theme: theme,
                            isHighlighted: group.id == highlighted?.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onChoose(group) }
                        .onHover { if $0 { store.switcherHighlight = group.id } }
                    }
                    if groups.isEmpty, !store.switcherQuery.isEmpty {
                        Text(verbatim: "No group or tab matches “\(store.switcherQuery)” — ⌫ or esc")
                            .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).padding(.vertical, 8)
                    } else if groups.isEmpty {
                        Text("No groups yet — ⌃⌘N makes one from the selected tabs")
                            .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).padding(.vertical, 8)
                    }
                }
            }
            Spacer(minLength: 0)
            legend
        }
        .padding(14)
        .frame(width: 340)
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tabs").font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.dimText)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(highlightedTabs) { tab in
                        HStack(spacing: 7) {
                            TabStateGlyph(tab: tab, theme: theme)
                            Text(verbatim: tab.title).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(verbatim: state(of: tab)).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: ChromeMetrics.row(26))
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab.id == store.selectedID ? theme.selected : .clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).strokeBorder(TabStatusStyle.working, lineWidth: tab.id == store.switcherTab ? 1.5 : 0)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onChooseTab(tab) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Label("Switch", systemImage: "return").labelStyle(.titleAndIcon)
            Text(verbatim: "→ Tabs")
            Text(verbatim: "⌥↩ Move current tab here")
            Text(verbatim: "esc Close")
        }
        .font(.system(size: ChromeMetrics.text(10)))
        .foregroundStyle(theme.dimText)
    }

    private func state(of tab: Tab) -> String {
        if tab.activity.mark == .waiting { return tab.activity.note ?? "Waiting for you" }
        if tab.activity.isWorking { return "Working" }
        if tab.activity.mark == .failed { return "Failed" }
        if tab.activity.mark == .done { return "Finished" }
        return tab.agent?.name ?? "Shell"
    }
}

private struct GroupRow: View {
    @ObservedObject var group: TabGroup
    let tabs: [Tab]
    @ObservedObject var theme: ChromeTheme
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(group.color.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: group.name).font(.system(size: ChromeMetrics.text(12), weight: .medium)).foregroundStyle(theme.text)
                    if group.isStashed {
                        Text(verbatim: "stashed").font(.system(size: ChromeMetrics.text(9)))
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(theme.dimText.opacity(0.2)))
                            .foregroundStyle(theme.dimText)
                    }
                }
                Text(verbatim: GroupSummary.line(tabs)).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .frame(height: ChromeMetrics.row(40))
        .background(RoundedRectangle(cornerRadius: 7).fill(isHighlighted ? theme.selected : .clear))
    }
}

private struct TabStateGlyph: View {
    @ObservedObject var tab: Tab
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        switch tab.activity.mark {
        case .waiting: WaitingDot(size: 7)
        case .failed: ResultMark(failed: true, size: 9)
        case .done: ResultMark(failed: false, size: 9)
        case .none:
            if tab.activity.isWorking {
                WorkingGlyph(symbol: tab.agent?.symbol ?? "terminal", size: 10)
            } else {
                Image(systemName: tab.agent?.symbol ?? "terminal").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.dimText)
            }
        }
    }
}

/// "4 tabs · 1 waiting for approval · 1 working" — pure, so the wording is
/// checked without a window.
@MainActor
package enum GroupSummary {
    package static func line(_ tabs: [Tab]) -> String {
        var parts = ["\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"]
        let waiting = tabs.filter { $0.activity.mark == .waiting }.count
        let working = tabs.filter(\.activity.isWorking).count
        let failed = tabs.filter { $0.activity.mark == .failed }.count
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if working > 0 { parts.append("\(working) working") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.count == 1 && !tabs.isEmpty { parts.append("all idle") }
        return parts.joined(separator: " · ")
    }
}

/// Takes the keyboard while shown, as the agent overview's host does.
package final class GroupSwitcherHostingView<Content: View>: NSHostingView<Content> {
    package var onEscape: (() -> Void)?
    package var onKey: ((NSEvent) -> Bool)?

    package override var acceptsFirstResponder: Bool { true }

    package override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onEscape?() ?? () }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    package override func cancelOperation(_ sender: Any?) { onEscape?() }
}
