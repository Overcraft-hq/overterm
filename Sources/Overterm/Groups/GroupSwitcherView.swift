import SwiftUI

/// ⌃⌘G: the islands and their tabs, side by side. ↩ switches, ⌥↩ moves the
/// current tab into the highlighted group, Esc closes.
///
/// The design asked for ⇧⌘G; Ghostty binds that to `navigate_search` and
/// eats it before the menu sees it (docs/ghostty.md), hence ⌃⌘G.
struct GroupSwitcherView: View {
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
    let onChoose: (TabGroup) -> Void
    let onChooseTab: (Tab) -> Void
    let onMoveHere: (TabGroup) -> Void
    let onDismiss: () -> Void

    private var groups: [TabGroup] {
        // Strip order, so the list reads as the strip does; stashed last.
        var seen: [TabGroup] = []
        for case .group(let g, _) in store.strip where !seen.contains(where: { $0.id == g.id }) { seen.append(g) }
        return seen + store.stashedGroups
    }

    private var highlighted: TabGroup? { store.group(store.switcherHighlight) ?? groups.first }

    var body: some View {
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
            Text("Groups").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.dimText)
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
                    if groups.isEmpty {
                        Text("No groups yet — ⌃⌘N makes one from the selected tabs")
                            .font(.system(size: 11)).foregroundStyle(theme.dimText).padding(.vertical, 8)
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
            Text("Tabs").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.dimText)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(highlighted.map { store.tabs(in: $0) } ?? []) { tab in
                        HStack(spacing: 7) {
                            TabStateGlyph(tab: tab, theme: theme)
                            Text(verbatim: tab.title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(verbatim: state(of: tab)).font(.system(size: 11)).foregroundStyle(theme.dimText)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab.id == store.selectedID ? theme.selected : .clear))
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
            Text(verbatim: "⌥↩ Move current tab here")
            Text(verbatim: "esc Close")
        }
        .font(.system(size: 10))
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
    let theme: ChromeTheme
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(group.color.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: group.name).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                    if group.isStashed {
                        Text(verbatim: "stashed").font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(theme.dimText.opacity(0.2)))
                            .foregroundStyle(theme.dimText)
                    }
                }
                Text(verbatim: GroupSummary.line(tabs)).font(.system(size: 11)).foregroundStyle(theme.dimText)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHighlighted ? theme.selected : .clear))
    }
}

private struct TabStateGlyph: View {
    @ObservedObject var tab: Tab
    let theme: ChromeTheme

    var body: some View {
        switch tab.activity.mark {
        case .waiting: WaitingDot(size: 7)
        case .failed: ResultMark(failed: true, size: 9)
        case .done: ResultMark(failed: false, size: 9)
        case .none:
            if tab.activity.isWorking {
                WorkingGlyph(symbol: tab.agent?.symbol ?? "terminal", size: 10)
            } else {
                Image(systemName: tab.agent?.symbol ?? "terminal").font(.system(size: 10)).foregroundStyle(theme.dimText)
            }
        }
    }
}

/// "4 tabs · 1 waiting for approval · 1 working" — pure, so the wording is
/// checked without a window.
@MainActor
enum GroupSummary {
    static func line(_ tabs: [Tab]) -> String {
        var parts = ["\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"]
        let waiting = tabs.filter { $0.activity.mark == .waiting }.count
        let working = tabs.filter(\.activity.isWorking).count
        let failed = tabs.filter { $0.activity.mark == .failed }.count
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if working > 0 { parts.append("\(working) working") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.count == 1 && !tabs.isEmpty { parts.append("all idle") }
        return parts.joined(separator: " · ")
    }
}

/// Takes the keyboard while shown, as the agent overview's host does.
final class GroupSwitcherHostingView<Content: View>: NSHostingView<Content> {
    var onEscape: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onEscape?() ?? () }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
