import SwiftUI

/// An Argo CD app read from the marks on its objects, its detail beside the
/// GitOps section in the page's detail slot (↩; docs/design/kubernetes/
/// gitops.md, 14.2.3, D4): its state as Argo CD's built-in rules say it of
/// its objects as read here, and why it is read from marks; what only the
/// Application knows, row by row; its tree — each member with Argo CD's
/// word, under a workload its ReplicaSets and pods (their own health, not
/// counted), a CronJob's last Jobs, a copy of a member's mark under it —,
/// its hooks apart, the hints its marks carry, its images; why Sync,
/// Refresh, Rollback and Diff aren't here. What it reads is
/// `KubeMarkedDetailSession`'s (M4), only while it shows; ↻ reads it again
/// ("Read again": this cluster's objects, never Argo CD's Refresh). A node
/// opens its object in its own list (`openMarkedNode`) — its name pressed,
/// or ↩ on it from the keyboard (Tab into the tree, ↑ ↓ along it: the page's
/// `markedNode`, drawn picked and scrolled to) —, its right-click menu Open
/// and Copy — never a write. Esc or × closes it.
struct KubeMarkedAppDetailView: View {
    /// Not observed: its every publish would draw the tree again.
    let page: KubernetesPageModel
    let ref: KubeMarkedDetailRef
    /// The node the keyboard is on (`page.markedNode`), given as a value:
    /// the tree drawn again when it moves.
    let selected: String?
    @ObservedObject var gitOps: KubeGitOpsSession
    @ObservedObject var marked: KubeMarkedAppsSession
    @ObservedObject var read: KubeMarkedDetailSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = page.markedDetailShown {
                header(detail)
                Rectangle().fill(theme.border).frame(height: 1)
                ScrollViewReader { scroller in
                    ScrollView { content(detail).padding(14) }
                        .onChange(of: selected) { id in
                            if let id { scroller.scrollTo(id) }
                        }
                }
            } else if marked.state != .live {
                waiting
            } else {
                gone
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.gitops.marked.detail")
    }

    // MARK: The header

    private func header(_ detail: KubeMarkedAppDetail.Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: detail.label).font(.system(size: ChromeMetrics.text(11), weight: .medium)).foregroundStyle(theme.text3)
                Text(verbatim: detail.title).font(.system(size: ChromeMetrics.text(14), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                // This cluster's objects read again — not Argo CD's Refresh, which is the Application's.
                Button {
                    page.updateMarkedDetailReading(again: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
                .disabled(read.state == .loading)
                .help("Read again: its objects in this cluster, once — no watch")
                .accessibilityLabel("Read again")
                .accessibilityIdentifier("kubernetes.gitops.marked.readAgain")
                Button {
                    page.closeMarkedApp()
                    page.giveListTheKeyboard()
                } label: {
                    Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityIdentifier("kubernetes.gitops.marked.close")
            }
            HStack(spacing: 6) {
                Text(verbatim: detail.state.glyph).font(.system(size: ChromeMetrics.text(10)))
                Text(verbatim: detail.word).font(.system(size: ChromeMetrics.text(12.5), weight: .semibold))
                Text(verbatim: detail.why).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(2)
            }
            .foregroundStyle(colour(detail.state))
            .help(detail.hover)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kubernetes.gitops.marked.state")
            if let lead = detail.lead {
                Text(verbatim: lead).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                    .help(KubeMarkedSection.limitsHover(gitOps.marksMode, kinds: marked.reading.kinds, rolloutsServed: marked.reading.rolloutsServed, tally: marked.tally))
                    .accessibilityIdentifier("kubernetes.gitops.marked.lead")
            }
            HStack(spacing: 8) {
                if let line = KubeMarkedSection.cliLine(key: ref.key) {
                    Button("Copy as argocd") { page.actions?.copy(line) }.controlSize(.small)
                        .help("\(line) — against your Argo CD server; copied, never run (k)")
                        .accessibilityIdentifier("kubernetes.gitops.marked.copyArgocd")
                }
                Button("Copy Name") { page.actions?.copy(detail.title) }.controlSize(.small)
                Button("Copy Names") { page.copyMarkedNames() }.controlSize(.small)
                    .help("Each of its objects, one a line")
                Spacer(minLength: 0)
            }
            // The verbs it hasn't, said beside those it has (14.2.3).
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(verbatim: detail.absent).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
                .accessibilityIdentifier("kubernetes.gitops.marked.absent")
                if let rollouts = detail.rollouts {
                    Text(verbatim: rollouts).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kubernetes.gitops.marked.rollouts")
                }
                Text(verbatim: "Its objects keep their own lists and verbs: Argo CD may undo a change made there.")
                    .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            .resourceCard(theme, padding: 10)
        }
        .padding(14)
    }

    // MARK: The content

    private func content(_ detail: KubeMarkedAppDetail.Detail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(detail.facts.enumerated()), id: \.offset) { _, fact in
                    Text(verbatim: fact).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            knows(detail)
            tree(detail)
            if !detail.hooks.isEmpty {
                section("Hooks — apart, as in Argo CD", id: "kubernetes.gitops.marked.hooks") {
                    ForEach(detail.hooks) { node in
                        KubeMarkedNodeRow(page: page, node: node, depth: 0, namespaced: detail.namespaced, selected: node.id == selected, theme: theme).id(node.id)
                    }
                }
            }
            // Lines by their place, never by their text: two may read alike.
            if !detail.hints.isEmpty {
                section("What its marks hint at", id: "kubernetes.gitops.marked.hints") {
                    ForEach(Array(detail.hints.enumerated()), id: \.offset) { _, hint in
                        Text(verbatim: hint).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Text(verbatim: "A link is text here: copy it, it is never opened.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                }
            }
            section("Images", id: "kubernetes.gitops.marked.images") {
                ForEach(Array((detail.images + detail.commits).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text(verbatim: detail.manifests).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            if !detail.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(detail.notes.enumerated()), id: \.offset) { _, note in
                        Text(verbatim: note).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("kubernetes.gitops.marked.notes")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What only the Application says: fixed rows, never filled from a guess.
    private func knows(_ detail: KubeMarkedAppDetail.Detail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ResourceCardCaption(text: detail.knowsTitle, theme: theme)
            ForEach(detail.knows, id: \.field) { known in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: known.field).font(.system(size: ChromeMetrics.text(11.5), weight: .medium)).foregroundStyle(theme.text2)
                        .frame(width: 150, alignment: .leading)
                    Text(verbatim: known.place).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .resourceCard(theme, padding: 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kubernetes.gitops.marked.knows")
    }

    /// Its objects, each with what is under it, as Argo CD would draw them;
    /// the one the keyboard is on picked.
    private func tree(_ detail: KubeMarkedAppDetail.Detail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ResourceCardCaption(text: "Its objects", theme: theme)
                if read.state == .loading { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Text(verbatim: selected == nil ? "Tab: its objects from the keyboard" : "↑ ↓ along them · ↩ opens one · Tab: back to the list")
                    .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
                    .accessibilityIdentifier("kubernetes.gitops.marked.keys")
            }
            let rows = Self.rows(detail.tree)
            ForEach(rows, id: \.node.id) { row in
                KubeMarkedNodeRow(page: page, node: row.node, depth: row.depth, namespaced: detail.namespaced, selected: row.node.id == selected, theme: theme)
                    .id(row.node.id)
                if let more = row.node.more {
                    Text(verbatim: more).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                        .padding(.leading, CGFloat(row.depth + 1) * 16 + 14)
                }
            }
            if rows.contains(where: { $0.node.kind == KubeMarkedAppDetail.Child.Kind.pod.rawValue }) {
                Text(verbatim: KubeMarkedAppDetail.podsNotCounted).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.gitops.marked.tree")
    }

    /// Depth first, each node with its depth.
    static func rows(_ nodes: [KubeMarkedAppDetail.Node]) -> [(depth: Int, node: KubeMarkedAppDetail.Node)] {
        func walk(_ node: KubeMarkedAppDetail.Node, _ depth: Int) -> [(depth: Int, node: KubeMarkedAppDetail.Node)] {
            [(depth, node)] + node.children.flatMap { walk($0, depth + 1) }
        }
        return nodes.flatMap { walk($0, 0) }
    }

    private func section<Content: View>(_ title: String, id: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ResourceCardCaption(text: title, theme: theme)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    private var waiting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: "Reading the marks on its objects…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var gone: some View {
        HStack(spacing: 8) {
            Text(verbatim: "This app is no longer read here: its marks are gone, or its Application is read now.")
                .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Close") {
                page.closeMarkedApp()
                page.giveListTheKeyboard()
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private func colour(_ state: KubeGitOpsState) -> Color {
        switch state.mark {
        case .bad, .missing: TabStatusStyle.failed
        case .waiting: theme.orangeText
        case .good: theme.greenText
        case .dim: theme.text3
        case .unknown: theme.text2
        }
    }
}

/// One node of a marked app's tree: indented under what it hangs off, its
/// health's mark, its kind and name (a button: its object in its own
/// list), Argo CD's word and sentence, what it is beside (not counted, a
/// copy). Grey when it doesn't count: a hook, `ignore-healthcheck`, a copy.
/// Picked when the keyboard is on it (↩ opens it).
private struct KubeMarkedNodeRow: View {
    let page: KubernetesPageModel
    let node: KubeMarkedAppDetail.Node
    let depth: Int
    let namespaced: Bool
    var selected = false
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
            Circle().fill(colour).frame(width: 7, height: 7).help(node.status?.word ?? node.word)
            Text(verbatim: node.kind).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1).fixedSize()
            Button {
                page.openMarkedNode(node)
            } label: {
                Text(verbatim: namespaced ? "\(node.namespace.map { "\($0)/" } ?? "")\(node.name)" : node.name)
                    .font(.system(size: ChromeMetrics.text(12))).underline().foregroundStyle(dim ? theme.text3 : theme.accentText).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Open \(node.kind) \(node.namespace.map { "\($0)/" } ?? "")\(node.name) in its own list (↩ on it) — right-click to copy it")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("kubernetes.gitops.marked.node.\(node.kind).\(node.name)")
            Text(verbatim: said).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(problem ? TabStatusStyle.failed : theme.text2).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? theme.selected : .clear).padding(.horizontal, -4))
        .contentShape(Rectangle())
        .overlay { ResourceVerbMenuArea { page.markedNodeVerbs(node) } }
    }

    /// Its word and sentence, and what it is beside.
    private var said: String {
        if node.role == .copy { return node.note ?? "" }
        var text = node.status?.word ?? node.word
        if !node.sentence.isEmpty { text += ": \(node.sentence)" }
        if let note = node.note { text += " — \(note)" }
        return text
    }

    /// It doesn't count toward the app's health: drawn grey.
    private var dim: Bool { [.hook, .ignored, .copy].contains(node.role) }

    private var problem: Bool { !dim && node.status == .degraded }

    private var colour: Color {
        if dim { return theme.text3.opacity(0.6) }
        switch node.status {
        case .healthy?: return TabStatusStyle.done
        case .progressing?, .suspended?: return TabStatusStyle.waiting
        case .degraded?, .missing?: return TabStatusStyle.failed
        case .unknown?, nil: return theme.text3.opacity(0.6)
        }
    }
}
