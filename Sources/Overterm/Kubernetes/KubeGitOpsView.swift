import SwiftUI

/// The GitOps section (`g`; docs/design/kubernetes/gitops.md, 2.2), in the
/// Overview's card and pill language, problems first: a header card (the
/// context and scope, which tools are served, how old the summaries are,
/// what was refused or cut), the banner when a controller isn't ready, the
/// chips — a state each, counted, a press its rows alone — then one row an
/// object (`ResourceTable`), state, kind, name, where it deploys, why, its
/// revision, its source, since when. Presentation only: every row comes
/// from what `KubeGitOpsSession` already holds.
struct KubeGitOpsSectionView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var gitOps: KubeGitOpsSession
    @ObservedObject var model: KubernetesModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let rows = page.gitOpsVisibleRows
        let listed = page.gitOpsListRows(rows)
        VStack(alignment: .leading, spacing: 10) {
            header
            if let banner = KubeGitOpsControllers.banner(gitOps.controllers) { bannerCard(banner) }
            chips
            if rows.isEmpty {
                empty
                Spacer(minLength: 0)
            } else {
                ResourceTable(
                    rows: listed, selection: $page.gitOpsView.selection, columns: KubeGitOpsSection.columns, sort: $page.gitOpsView.sort,
                    cell: { row, column in
                        switch row {
                        case .group(let group, let folded): groupCell(group, folded: folded)
                        case .object(let row): cell(row, column)
                        }
                    }, verbs: { page.gitOpsVerbs(for: $0) },
                    copy: {
                        let names = rows.filter { page.gitOpsView.selection.contains($0.id) }.map(\.ref.description)
                        if !names.isEmpty { page.actions?.copy(names.joined(separator: "\n")) }
                    }, accessibilityIdentifier: "kubernetes.gitops"
                )
                .clipShape(RoundedRectangle(cornerRadius: ResourceCard.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ResourceCard.radius, style: .continuous).strokeBorder(theme.border))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.gitops.section")
    }

    // MARK: The header

    private var header: some View {
        let tools = KubeGitOpsSummary.tools(model.discovery)
        let said = KubeGitOpsSection.header(argo: tools.argo, flux: tools.flux, summarisedAt: gitOps.summarisedAt, summarising: gitOps.summarising, now: gitOps.now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: KubeSection.gitops.symbol).font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(theme.text2)
                Text(verbatim: "GitOps").font(.system(size: ChromeMetrics.text(15), weight: .semibold)).foregroundStyle(theme.text)
                Text(verbatim: [model.selectedName, model.scope.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if gitOps.summarising { ProgressView().controlSize(.mini) }
                Text(verbatim: said).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).lineLimit(1)
                    .accessibilityIdentifier("kubernetes.gitops.header")
                Button("Refresh") { page.refreshGitOps() }.controlSize(.small).disabled(gitOps.summarising)
                    .help("Every kind summarised again (⌘R)").accessibilityIdentifier("kubernetes.gitops.refresh")
            }
            ForEach(gitOps.notes, id: \.self) { note in
                Label {
                    Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.gitops.notes")
        }
        .resourceCard(theme, padding: 12)
    }

    private func bannerCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.orangeText)
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(12), weight: .medium)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .resourceCard(theme, tint: TabStatusStyle.waiting, padding: 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kubernetes.gitops.banner")
    }

    // MARK: Chips

    private var chips: some View {
        let counted = KubeGitOpsSection.chips(gitOps.rows.shown)
        let view = page.gitOpsView
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(counted, id: \.state) { chip in
                    let on = view.chip == chip.state
                    Button {
                        page.pressGitOpsChip(chip.state)
                    } label: {
                        ResourcePill(text: KubeGitOpsSection.chipText(chip.state, chip.count), colour: colour(chip.state), symbol: on ? "checkmark" : nil)
                            .overlay(Capsule().strokeBorder(on ? colour(chip.state) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Show every state again" : "Only \(chip.state.word)")
                    .accessibilityIdentifier("kubernetes.gitops.chip.\(chip.state.word.lowercased())")
                }
                if model.scope != .all, !gitOps.rows.notPlaced.isEmpty {
                    Button {
                        page.toggleGitOpsNotPlaced()
                    } label: {
                        ResourcePill(text: "\(gitOps.rows.notPlaced.count) not placed", colour: theme.text2, symbol: view.notPlaced ? "checkmark" : nil)
                    }
                    .buttonStyle(.plain)
                    .help("Rows not summarised: with no spec or status, they can't be placed in a scope — never implied in or out")
                    .accessibilityIdentifier("kubernetes.gitops.notPlaced")
                }
                if let tool = view.tool {
                    Button {
                        page.gitOpsView.tool = nil
                    } label: {
                        ResourcePill(text: "\(tool.said) only", colour: theme.text2, symbol: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("kubernetes.gitops.tool")
                }
                if let refusal = page.gitOpsFilterRefusal {
                    Text(verbatim: refusal).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(TabStatusStyle.failed).lineLimit(1)
                        .help(refusal).accessibilityIdentifier("kubernetes.gitops.filterRefused")
                }
                Spacer(minLength: 8)
                groupMenu
                if gitOps.rows.shown.contains(where: { $0.state == .ready }) {
                    Toggle("Hide Ready", isOn: Binding(get: { page.gitOpsHidesReady }, set: { page.gitOpsView.hideReady = $0 }))
                        .toggleStyle(.checkbox).controlSize(.small).font(.system(size: ChromeMetrics.text(11.5)))
                        .help("Ready rows are hidden by default above \(KubeGitOpsSection.hideReadyAbove) rows; their chip still counts them")
                        .accessibilityIdentifier("kubernetes.gitops.hideReady")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.gitops.chips")
    }

    /// `G`'s grouping, picked here too.
    private var groupMenu: some View {
        let current = page.gitOpsView.groupBy
        return Menu {
            ForEach(KubeGitOpsGroupBy.allCases, id: \.self) { by in
                Button {
                    page.groupGitOps(by: by)
                } label: {
                    if by == current { Label(by.title, systemImage: "checkmark") } else { Text(verbatim: by.title) }
                }
            }
        } label: {
            Text(verbatim: current == .none ? "Group" : "Group: \(current.title)").font(.system(size: ChromeMetrics.text(11.5)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Group by tool, source, owner or destination (\(KubernetesKey.groupBy.key) cycles)")
        .accessibilityIdentifier("kubernetes.gitops.groupBy")
    }

    // MARK: Empty

    @ViewBuilder private var empty: some View {
        if gitOps.state != .live && gitOps.summarising && gitOps.rows.shown.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: "Reading Argo CD's and Flux's objects…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
            }
            .padding(.top, 12)
        } else if !gitOps.rows.shown.isEmpty {
            Text(verbatim: page.filter.isEmpty ? "Nothing in this state." : "Nothing matches “\(page.filter)”.")
                .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).padding(.top, 12)
        } else {
            let hint = KubeGitOpsSection.emptyHint(gitOps.rows, scope: model.scope)
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: ChromeMetrics.text(16))).foregroundStyle(theme.text3)
                Text(verbatim: hint.text).font(.system(size: ChromeMetrics.text(12.5))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                if let namespace = hint.namespace {
                    Button("Show \(namespace)") { page.showGitOpsNamespace(namespace) }.controlSize(.small)
                        .help("Adds \(namespace) to the namespaces shown")
                        .accessibilityIdentifier("kubernetes.gitops.showNamespace")
                }
                Spacer(minLength: 0)
            }
            .resourceCard(theme, padding: 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.gitops.empty")
        }
    }

    // MARK: Cells

    private func colour(_ state: KubeGitOpsState) -> Color {
        switch state.mark {
        case .bad, .missing: TabStatusStyle.failed
        case .waiting: theme.orangeText
        case .good: theme.greenText
        case .dim: theme.text3
        case .unknown: theme.text2
        }
    }

    /// A group's row: its fold, its title (the source or owner heading it,
    /// with that one's own state), what it holds.
    private func groupCell(_ group: KubeGitOpsGroup, folded: Bool) -> AnyView {
        AnyView(
            HStack(spacing: 8) {
                Button {
                    page.toggleGitOpsGroup(group.id)
                } label: {
                    Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.text2)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(folded ? "Unfold" : "Fold")
                Text(verbatim: group.title).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(group.rest ? theme.text2 : theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if let head = group.head {
                    HStack(spacing: 4) {
                        Text(verbatim: head.state.glyph).font(.system(size: ChromeMetrics.text(9)))
                        Text(verbatim: head.state.word).font(.system(size: ChromeMetrics.text(11), weight: .medium))
                    }
                    .foregroundStyle(colour(head.state))
                }
                Text(verbatim: group.said).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(theme.rowHover.opacity(0.5))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kubernetes.gitops.group"))
    }

    private func cell(_ row: KubeGitOpsRow, _ column: ResourceColumn?) -> AnyView {
        let small = Font.system(size: ChromeMetrics.text(12))
        switch column?.id {
        case "state":
            return AnyView(
                HStack(spacing: 5) {
                    Text(verbatim: row.state.glyph).font(.system(size: ChromeMetrics.text(10)))
                    Text(verbatim: row.state.word).font(.system(size: ChromeMetrics.text(12), weight: .medium))
                }
                .foregroundStyle(colour(row.state)).lineLimit(1)
                .accessibilityIdentifier("kubernetes.gitops.row.\(row.ref.namespace ?? "").\(row.ref.name)"))
        case "kind":
            return AnyView(Text(verbatim: row.role.short).font(.system(size: ChromeMetrics.text(11), weight: .medium, design: .monospaced)).foregroundStyle(theme.text2))
        case "name":
            return AnyView(
                Text(verbatim: row.ref.description).font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(theme.text).lineLimit(1)
                    .truncationMode(.middle))
        case "into":
            return AnyView(Text(verbatim: row.into).font(small).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle))
        case "why":
            let tags = row.tags.map { $0.said(now: gitOps.now) }
            return AnyView(
                HStack(spacing: 6) {
                    Text(verbatim: row.why).font(small).foregroundStyle(row.summarised ? theme.text : theme.text3).lineLimit(1).truncationMode(.tail)
                    ForEach(tags, id: \.self) { tag in
                        Text(verbatim: tag).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
                            .padding(.horizontal, 5).background(Capsule().fill(theme.rowHover))
                    }
                }
                .help(row.hover))
        case "revision":
            return AnyView(Text(verbatim: row.revision).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1))
        case "source":
            return AnyView(Text(verbatim: row.source).font(small).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle).help(row.source))
        case "age":
            let age = row.since.map { KubeAge.format(max(0, gitOps.now.timeIntervalSince($0))) } ?? ""
            return AnyView(Text(verbatim: age).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).monospacedDigit())
        default:
            return AnyView(EmptyView())
        }
    }
}
