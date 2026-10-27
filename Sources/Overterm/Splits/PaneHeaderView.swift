import AppKit
import SwiftUI

/// What a pane's header can do. Every action names its own pane, so a
/// button works on the pane you clicked rather than on whichever one
/// happens to have the keyboard.
struct PaneHeaderActions {
    var copyOutput: (TerminalView) -> Void
    /// Stop whatever is listening — the exact pid, never a pattern.
    var killPort: (ListeningPort) -> Void
    var rerun: (TerminalView) -> Void
    var splitRight: (TerminalView) -> Void
    var splitDown: (TerminalView) -> Void
    var zoom: (TerminalView) -> Void
    var close: (TerminalView) -> Void
    var openPort: (ListeningPort) -> Void
    /// A container's port: the container on the Docker page.
    var showContainer: (String) -> Void = { _ in }
}

/// The bar across the top of every terminal pane: what is running here,
/// where, how it is doing, and what it is listening on.
///
/// A terminal says none of that itself — the title bar said it for the
/// whole tab, and a split said nothing at all. The cost is 38 pt a pane,
/// which is the trade: four panes of a 2×2 split can now be told apart,
/// and split, zoom and close stop being keyboard-only.
struct PaneHeaderView: View {
    @ObservedObject var tab: Tab
    let pane: TerminalView
    @ObservedObject var store: TabStore
    /// What this pane has run — the failure it is showing, if any.
    @ObservedObject var blocks: PaneBlocks
    @ObservedObject var theme: ChromeTheme
    let actions: PaneHeaderActions

    private var isFocused: Bool { tab.terminal === pane }
    private var isSplit: Bool { tab.terminals.count > 1 }

    /// The pane's own title where it has one — in a split the panes are
    /// different programs, and repeating the tab's title four times says
    /// nothing.
    private var title: String {
        guard isSplit, let own = pane.title, !own.isEmpty else { return tab.title }
        return Tab.shortened(own)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFocused ? theme.text : theme.text2)
                .lineLimit(1)
            if let group = store.group(of: tab) {
                GroupLabel(group: group, theme: theme)
            }
            Spacer(minLength: 4)
            if let link = blocks.hoveredLink {
                // Where the pointer is, since libghostty gives no rectangle
                // to anchor a popover to — and one placed at the pointer
                // would fight selecting the text it is over.
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 10))
                    Text(link).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Text("⌘-click to open").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
                .foregroundStyle(theme.accentText)
                .layoutPriority(1)
            } else if let failure = blocks.ledger.lastFinished, failure.failed, blocks.ledger.running == nil {
                failed(failure)
            } else if isFocused {
                status
            }
            ForEach(tab.ports + tab.containerPorts) { port in
                PortPill(port: port, theme: theme, actions: actions)
            }
            HStack(spacing: 0) {
                button("rectangle.split.2x1", "Split Right (⌘D)") { actions.splitRight(pane) }
                button("rectangle.split.1x2", "Split Down (⇧⌘D)") { actions.splitDown(pane) }
                button(
                    tab.zoomed === pane ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    "Zoom Pane (⇧⌘↩)"
                ) { actions.zoom(pane) }
                button("xmark", "Close (⌘W)") { actions.close(pane) }
            }
            .foregroundStyle(theme.text2)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: SplitHostView.headerHeight)
        .background(theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    /// The last command failed. The ring in the grid says *where*; this
    /// says what, and is where the three things you then want live —
    /// pinned, rather than hanging off the output, which scrolls away.
    private func failed(_ block: CommandBlock) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed)
            Text(block.command)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.text2)
            Text(block.detail).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed)
            smallButton("Copy output") { actions.copyOutput(pane) }
            smallButton("Rerun ⌘R") { actions.rerun(pane) }
        }
        .layoutPriority(1)
    }

    private func smallButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.rowSel))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text2)
    }

    /// The one thing the tab strip's badge cannot say in a word: what the
    /// mark is *about*.
    @ViewBuilder private var status: some View {
        switch tab.activity.mark {
        case .waiting:
            pill(tab.activity.note ?? "Waiting for you", theme.orangeText, theme.attnBg)
        case .failed:
            Text(tab.activity.note ?? "Failed").font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed)
        case .done:
            Text(tab.activity.note ?? "Finished").font(.system(size: 11)).foregroundStyle(theme.greenText)
        case .none:
            if tab.activity.isWorking {
                Text("Working").font(.system(size: 11)).foregroundStyle(theme.text2)
            }
        }
    }

    private func pill(_ text: String, _ foreground: Color, _ background: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(background))
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The island this pane's tab is in. Its own view so a rename reaches the
/// header: the group is an object of its own, not part of the tab.
private struct GroupLabel: View {
    @ObservedObject var group: TabGroup
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        Text(verbatim: group.name)
            .font(.system(size: 12))
            .foregroundStyle(theme.text3)
            .lineLimit(1)
    }
}

/// A port something in this pane's tree is listening on, and what you
/// usually want to do about it.
///
/// No preview of the page, which the design shows: rendering it would
/// mean a WebView per pill for a thumbnail. The process and its pid say
/// which of two servers this is, which is the question the thumbnail was
/// answering.
private struct PortPill: View {
    let port: ListeningPort
    @ObservedObject var theme: ChromeTheme
    let actions: PaneHeaderActions
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                if port.container != nil {
                    Image(systemName: "shippingbox.fill").font(.system(size: 8))
                } else {
                    Circle().fill(TabStatusStyle.done).frame(width: 6, height: 6)
                }
                Text(verbatim: ":\(port.port)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(theme.greenText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(TabStatusStyle.done.opacity(hovering ? 0.26 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(port.container.map { "\($0) publishes \(port.port)" } ?? "\(port.process) is listening on \(port.port)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(verbatim: "localhost:\(port.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Text(verbatim: port.container.map { "· \(port.process) · \($0)" } ?? "· \(port.process) · pid \(port.pid)")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text3)
                }
                HStack(spacing: 6) {
                    action("Open", filled: true) {
                        showing = false
                        port.url.map { NSWorkspace.shared.open($0) }
                    }
                    action("Copy URL") {
                        showing = false
                        guard let url = port.url else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    if let container = port.container {
                        action("Docker") {
                            showing = false
                            actions.showContainer(container)
                        }
                        action("Stop") {
                            showing = false
                            actions.killPort(port)
                        }
                    } else {
                        action("Kill") {
                            showing = false
                            actions.killPort(port)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 280)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
        }
    }

    private func action(_ title: String, filled: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 12, weight: filled ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(filled ? TabStatusStyle.working : theme.iconBg))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(filled ? Color.white : theme.text)
    }
}
