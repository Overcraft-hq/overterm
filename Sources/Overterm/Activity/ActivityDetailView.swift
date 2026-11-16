import SwiftUI

/// The selected process's detail on the right (docs/design/activity/
/// analysis.md, 6.4), without history: its header with the row's verbs —
/// the list's right-click menu's, one list (`ActivityPageModel.verbs`) —,
/// the masked command, where and why, its tree, its listeners, its usage.
/// Every number through `Text(verbatim:)`.
struct ActivityDetailView: View {
    let detail: ActivityDetail
    @ObservedObject var theme: ChromeTheme
    @ObservedObject var page: ActivityPageModel
    /// The selection's verbs: buttons here, the same as its menu.
    let verbs: [ResourceVerb]

    private var row: ActivityProcessRow { detail.row }

    var body: some View {
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
                }
                block("Tree") { tree }
                if !detail.listeners.isEmpty || detail.connections > 0 || detail.bounded {
                    block("Listening") { listening }
                }
                block("Usage") {
                    ForEach(Array(detail.usage.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Text(line.0).foregroundStyle(theme.text3)
                            Spacer(minLength: 6)
                            Text(verbatim: line.1).foregroundStyle(theme.text2).lineLimit(1)
                        }
                        .font(.system(size: ChromeMetrics.text(11.5)))
                    }
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
                Text(verbatim: ":\(port.port) \(port.proto)").font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
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

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            content()
        }
    }
}
