import SwiftUI

/// An Argo CD app read from the marks on its objects, beside the GitOps
/// section in the page's detail slot (↩; docs/design/kubernetes/gitops.md,
/// 14.2.3) — a placeholder until its tree, its hints and what Argo CD alone
/// knows are drawn (D4): its name, state and why; why it is read from
/// marks; what the section read of it (each member's health as its app
/// counts it — a Deployment its Rollout scales to 0 "scaled by its
/// Rollout" —, its hooks apart); why Sync, Refresh, Rollback and Diff
/// aren't here. Reads nothing of its own: what the section holds. Its
/// verbs copy (argocd's line against the person's own server, the name),
/// never write. Esc or × closes it.
struct KubeMarkedAppDetailView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var gitOps: KubeGitOpsSession
    @ObservedObject var marked: KubeMarkedAppsSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let ranked = page.markedDetailApp {
                let detail = KubeMarkedSection.detail(ranked, mode: gitOps.marksMode, context: gitOps.context ?? page.model.selectedName ?? "")
                header(detail, ranked)
                Rectangle().fill(theme.border).frame(height: 1)
                ScrollView { content(detail).padding(14) }
            } else {
                gone
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.gitops.marked.detail")
    }

    private func header(_ detail: KubeMarkedSection.Detail, _ ranked: KubeMarkedRanked) -> some View {
        let row = KubeMarkedSection.row(ranked, installations: false)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Argo CD app").font(.system(size: ChromeMetrics.text(11), weight: .medium)).foregroundStyle(theme.text3)
                Text(verbatim: detail.title).font(.system(size: ChromeMetrics.text(14), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
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
            .help(row.hover)
            HStack(spacing: 8) {
                if let line = KubeMarkedSection.cliLine(row) {
                    Button("Copy as argocd") { page.actions?.copy(line) }.controlSize(.small)
                        .help("\(line) — against your Argo CD server; copied, never run (k)")
                        .accessibilityIdentifier("kubernetes.gitops.marked.copyArgocd")
                }
                Button("Copy Name") { page.actions?.copy(detail.title) }.controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private func content(_ detail: KubeMarkedSection.Detail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lead = detail.lead {
                Text(verbatim: lead).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(detail.facts, id: \.self) { fact in
                    Text(verbatim: fact).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            section("Its objects, as read here", detail.members)
            if !detail.hooks.isEmpty { section("Hooks", detail.hooks) }
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
                }
                Text(verbatim: "Its objects keep their own lists and verbs: Argo CD may undo a change made there.")
                    .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            .resourceCard(theme, padding: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.system(size: ChromeMetrics.text(11), weight: .semibold)).foregroundStyle(theme.text3)
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
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
