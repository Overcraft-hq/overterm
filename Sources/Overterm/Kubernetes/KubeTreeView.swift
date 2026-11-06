import SwiftUI

/// A detail's dependency tree, in its Overview (3.7): one row a node,
/// indented under what it hangs off — how (owns, uses, selects, routes,
/// manages) and its health mark first, red for what is broken or missing.
/// A name opens its object's detail; right-click is its verbs, as its
/// detail has them (`KubernetesPageModel.treeVerbs`), made only as the
/// menu opens: a verb's guard asks kubectl and the server (can-i, access
/// reviews), and drawing a row must ask nothing. The page isn't observed
/// here — its every publish (a list's batch, the selection, usage) would
/// draw every row again. Read once, when the Overview shows; Refresh reads
/// again.
struct KubeTreeView: View {
    let page: KubernetesPageModel
    @ObservedObject var tree: KubeTreeSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                if let problems = tree.tree?.problems.count, problems > 0 {
                    Text(verbatim: "\(problems) broken").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(TabStatusStyle.failed)
                        .accessibilityIdentifier("kubernetes.detail.tree.problems")
                }
                Spacer(minLength: 0)
                Button {
                    page.detail?.showTree(again: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
                .disabled(tree.state == .loading)
                .help("Read the tree again — once, no watch")
                .accessibilityIdentifier("kubernetes.detail.tree.refresh")
            }
            switch tree.state {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let reason):
                Text(verbatim: reason).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).textSelection(.enabled)
            case .loaded:
                if let built = tree.tree {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(built.rows.dropFirst(), id: \.node.id) { row in
                            KubeTreeRow(page: page, node: row.node, depth: row.depth - 1, theme: theme)
                        }
                    }
                    if built.root.children.isEmpty {
                        Text("Nothing it owns, uses or is reached by.").font(.system(size: 12)).foregroundStyle(theme.text3)
                    }
                    ForEach(built.notes, id: \.self) { note in
                        Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("kubernetes.detail.tree")
    }

    private var title: String { tree.root.isGitOps ? "What it manages" : "Dependency tree" }
}

/// One node: indented, how it hangs off its parent, its mark, its kind
/// and name (a link), what it is now.
private struct KubeTreeRow: View {
    let page: KubernetesPageModel
    let node: KubeTreeNode
    let depth: Int
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
            Text(verbatim: relation).font(.system(size: 10)).foregroundStyle(theme.text3).frame(width: 52, alignment: .leading)
            Circle().fill(color).frame(width: 7, height: 7).help(node.health.rawValue)
            Text(verbatim: node.kind).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).fixedSize()
            if node.link != nil {
                Button {
                    page.openTreeNode(node)
                } label: {
                    Text(verbatim: node.name).font(.system(size: 12)).underline().foregroundStyle(theme.accentText).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(node.kind) \(node.namespace.map { "\($0)/" } ?? "")\(node.name) — right-click for its verbs")
                .accessibilityIdentifier("kubernetes.detail.tree.node.\(node.kind).\(node.name)")
            } else {
                Text(verbatim: node.name).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let how = node.how {
                Text(verbatim: how).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.tail)
            }
            if let status = node.status {
                Text(verbatim: status).font(.system(size: 11.5)).foregroundStyle(node.health.isProblem ? TabStatusStyle.failed : theme.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .overlay {
            if node.link != nil {
                ResourceVerbMenuArea { page.treeVerbs(for: node) }
            }
        }
    }

    private var relation: String {
        switch node.relation {
        case .root: ""
        case .owns: "owns"
        case .container: "runs"
        case .uses: "uses"
        case .selects: "selects"
        case .routes: "routes"
        case .source: "from"
        case .manages: "manages"
        }
    }

    private var color: Color {
        switch node.health {
        case .good: TabStatusStyle.done
        case .waiting: TabStatusStyle.waiting
        case .bad, .missing: TabStatusStyle.failed
        case .unknown, .dim: theme.text3.opacity(0.6)
        }
    }
}
