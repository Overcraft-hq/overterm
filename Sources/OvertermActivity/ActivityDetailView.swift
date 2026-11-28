import SwiftUI

/// The selected process's detail on the right (docs/design/activity/
/// analysis.md, 6.4): its header with the row's verbs —
/// the list's right-click menu's, one list (`ActivityPageModel.verbs`) —,
/// the masked command, where and why, its tree, its listeners, its usage.
/// Every number through `Text(verbatim:)`.
package struct ActivityDetailView: View {
    package let detail: ActivityDetail
    @ObservedObject package var theme: ChromeTheme
    /// The keys it names, as bound now.
    @ObservedObject var keys = Keybindings.shared
    @ObservedObject package var page: ActivityPageModel
    /// The selection's verbs: buttons here, the same as its menu.
    package let verbs: [ResourceVerb]
    /// A chart's Copy Values as CSV.
    package var copy: ((String) -> Void)? = nil
    /// The crosshair its charts share.
    @StateObject private var cursor = TimeChartCursor()

    private var row: ActivityProcessRow { detail.row }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                block("Command") {
                    Text(verbatim: row.command ?? (row.isOwn ? "not read yet" : "another user's: not readable"))
                        .font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(row.command == nil ? theme.text3 : theme.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("activity.detail.command")
                    if let path = row.path {
                        Text(verbatim: path).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(2).truncationMode(.middle)
                    }
                    if let folder = detail.folderPath {
                        Label {
                            Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath).lineLimit(2).truncationMode(.middle)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                        .help("Its working folder: Terminal in Its Folder (e), Reveal Its Folder (⌥r)")
                        .accessibilityIdentifier("activity.detail.folder")
                    }
                }
                block("Where and why") {
                    Text(verbatim: whereWords).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("activity.detail.where")
                    if let reason = row.owner?.reason, reason != whereWords {
                        Text(verbatim: reason).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if row.owner?.certainty == .probably {
                        Text("probably: from its lineage or folder, not a tag").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                    }
                    links
                }
                block("Tree") { tree }
                if !detail.listeners.isEmpty || detail.connections > 0 || detail.bounded {
                    block("Listening") { listening }
                }
                if row.isOwn { block("Files") { files } }
                block("Usage") {
                    ForEach(Array(detail.usage.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Text(line.0).foregroundStyle(theme.text3)
                            Spacer(minLength: 6)
                            Text(verbatim: line.1).foregroundStyle(theme.text2).lineLimit(1)
                        }
                        .font(.system(size: ChromeMetrics.text(11.5)))
                    }
                    history
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.panelGround)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if row.owner?.paneRole == .agent, let agent = row.owner?.agentKind {
                    Image(systemName: agent.symbol).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
                }
                Text(verbatim: row.name).font(.system(size: ChromeMetrics.text(14), weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(verbatim: detail.subtitle).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ResourceActionBar(verbs: verbs, theme: theme, identifier: "activity.actions").padding(.top, 2)
        }
    }

    private var whereWords: String {
        if let tab = row.tabTitle {
            var words = ["in “\(tab)”"]
            if let pane = row.pane { words.append("pane \(pane)") }
            if let checkout = row.checkout { words.append(checkout) }
            if let agent = row.owner?.agentKind, row.owner?.paneRole != .agent { words.append("started by \(agent.name)") }
            return words.joined(separator: " · ")
        }
        return row.whereText.isEmpty ? (row.isOwn ? "Yours, outside every tab" : row.user) : row.whereText
    }

    /// Where and why's links (6.4): its tab, Tab Info, the checkout in
    /// Overgit — a process in no tab has none.
    @ViewBuilder
    private var links: some View {
        if let tab = row.tab, !row.ended {
            HStack(spacing: 12) {
                Button("Go to Tab") { page.goTo(row) }
                Button("Tab Info") { page.actions.tabInfo(tab) }
                if row.checkout != nil {
                    Button("Show in Overgit") { page.actions.overgit(tab) }
                        .help(KeyHints.help("Its tab's checkout in the sidebar's git panel", command: "overgit.show", keys: keys))
                        .accessibilityIdentifier("activity.detail.overgit")
                }
            }
            .buttonStyle(.link).font(.system(size: ChromeMetrics.text(11.5)))
        }
    }

    @ViewBuilder
    private var tree: some View {
        ForEach(Array(detail.ancestors.reversed().enumerated()), id: \.element.id) { index, parent in
            relative(parent, depth: index, dim: true)
        }
        relative(ActivityDetail.Relative(id: row.id, pid: row.identity.pid, name: row.name), depth: detail.ancestors.count, dim: false, own: true)
        ForEach(detail.children, id: \.id) { child in
            relative(child, depth: detail.ancestors.count + 1, dim: false)
        }
        if detail.moreChildren > 0 {
            Text(verbatim: "+\(detail.moreChildren) more").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                .padding(.leading, CGFloat(detail.ancestors.count + 1) * 10)
        }
    }

    private func relative(_ relative: ActivityDetail.Relative, depth: Int, dim: Bool, own: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: relative.name).foregroundStyle(own ? theme.text : dim ? theme.text3 : theme.text2).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "\(relative.pid)").font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text3)
        }
        .font(.system(size: ChromeMetrics.text(11.5), weight: own ? .semibold : .regular))
        .padding(.leading, CGFloat(min(depth, 10)) * 10)
        .contentShape(Rectangle())
        .onTapGesture { if !own { page.reveal(relative.id, in: .processes) } }
    }

    @ViewBuilder
    private var listening: some View {
        ForEach(detail.listeners, id: \.id) { port in
            HStack(spacing: 6) {
                Text(verbatim: port.kind == .unix ? (port.address as NSString).abbreviatingWithTildeInPath : ":\(port.port) \(port.proto)").font(
                    .system(size: ChromeMetrics.text(11.5), design: .monospaced)
                ).foregroundStyle(theme.text)
                Text(verbatim: port.reach).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(port.scope == .thisMac ? theme.text3 : TabStatusStyle.signal)
                Spacer(minLength: 4)
                if let url = port.url {
                    Button("Open") { page.actions.open(url, port.tab, false) }.controlSize(.small)
                        .help("Open it in its tab's browser column — ⌥o the default browser")
                }
            }
        }
        if detail.connections > 0 {
            Text(verbatim: detail.connections == 1 ? "1 connection" : "\(detail.connections) connections")
                .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
        }
        if detail.bounded {
            Text("more sockets than a tick reads: its listeners read in rotation").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
        }
    }

    /// Its open files and sockets (6.4's Files, `l`): read when asked.
    @ViewBuilder
    private var files: some View {
        if !page.showsFiles {
            Button("Show Open Files and Sockets (l)") {
                page.showsFiles = true
                page.readFiles()
            }
            .controlSize(.small)
            .accessibilityIdentifier("activity.detail.showFiles")
        } else if let listing = page.openFiles, listing.identity == row.identity {
            if listing.gone {
                Text("It ended: nothing to read").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
            } else {
                Text(verbatim: "\(listing.descriptors) open — \(listing.entries.count { $0.kind == .file }) files, \(listing.entries.count { $0.kind == .socket }) sockets")
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                ForEach(listing.entries, id: \.descriptor) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(entry.descriptor)").font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                            .frame(minWidth: 24, alignment: .trailing)
                        Text(verbatim: entry.kind == .file ? (entry.text as NSString).abbreviatingWithTildeInPath : entry.text)
                            .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(entry.kind == .file ? theme.text2 : theme.text3).lineLimit(1)
                            .truncationMode(.middle).help(entry.text)
                    }
                }
                if let cut = listing.cut {
                    Text(verbatim: "Read stopped: \(cut)").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(TabStatusStyle.signal)
                }
            }
        } else if row.ended {
            Text("It ended: nothing to read").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
        } else {
            Text("Reading…").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
        }
    }

    /// Its 15 minutes as charts (6.11), its subtree's for an agent, the
    /// hour folded; said plainly when nothing was read.
    @ViewBuilder
    private var history: some View {
        if let hour = detail.hour {
            Text(verbatim: hour).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                .accessibilityIdentifier("activity.detail.hour")
        }
        if detail.charts.isEmpty {
            if row.isOwn {
                Text("No history yet: it is read while the page or its tab shows").font(.system(size: ChromeMetrics.text(11)))
                    .foregroundStyle(theme.text3)
            }
        } else {
            ForEach(detail.charts, id: \.id) { data in
                TimeChartView(data: data, cursor: cursor, span: "last 15 min", height: data.id.hasSuffix(".cpu") ? 80 : 56, copy: copy, theme: theme)
            }
        }
        if !detail.subtreeCharts.isEmpty {
            Text("With everything under it").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).foregroundStyle(theme.text3)
                .padding(.top, 4)
            ForEach(detail.subtreeCharts, id: \.id) { data in
                TimeChartView(data: data, cursor: cursor, span: "last 15 min", height: 56, copy: copy, theme: theme)
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            content()
        }
    }
}
