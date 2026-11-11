import SwiftUI

/// How a bound release's diff or upgrade stands, under its buttons in the rail.
struct KubeHelmUpgradeStatus: View {
    @ObservedObject var session: KubeHelmUpgradeSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let text = session.state.text {
            Text(verbatim: text)
                .font(.system(size: ChromeMetrics.text(10.5)))
                .foregroundStyle(session.state.isFailure ? TabStatusStyle.failed : theme.text3)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.panel.helmStatus")
        }
    }
}

/// The right-hand pane's diff of a bound release against the checkout's
/// chart (`KubeHelmUpgradeSession`): what it was rendered with, each
/// object's diff — masked —, and Upgrade….
struct KubeHelmDiffContent: View {
    @ObservedObject var session: KubeHelmUpgradeSession
    @ObservedObject var theme: ChromeTheme
    let onClose: () -> Void
    /// The chart's folder, in the editor.
    let onOpen: (URL) -> Void
    @State private var folded: Set<String> = []

    private var palette: DiffPalette { DiffPalette(text: theme.textNS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if let result = session.result {
                content(result)
            } else {
                Text(verbatim: session.state.text ?? "Diff Chart with Release, from the Kubernetes panel of a checkout bound to a release.")
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText).padding(12)
                Spacer(minLength: 0)
            }
        }
        .background(theme.strip)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: "⎈").foregroundStyle(theme.dimText)
            Text(verbatim: session.title).font(.system(size: ChromeMetrics.text(12), weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
            if let result = session.result {
                Text(verbatim: (result.production ? "PRODUCTION · " : "") + result.context)
                    .font(.system(size: ChromeMetrics.text(11), weight: .semibold))
                    .foregroundStyle(result.production ? KubernetesPageView.production : theme.dimText)
            }
            Spacer(minLength: 0)
            Button("Upgrade…") { session.upgrade() }
                .controlSize(.small)
                .disabled(session.state.isWorking)
                .help("helm upgrade from the checkout's chart, in a tab pinned to the context — asked first")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(11)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func content(_ result: KubeHelmUpgradeSession.Diffed) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(
                    verbatim:
                        "helm template of \(result.chartSaid ?? result.chart.lastPathComponent) with revision \(result.revision)'s values — rendered here, no cluster asked — against what revision \(result.revision) has."
                )
                .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kubernetes.helmDiff.label")
                if result.diff.secrets > 0 {
                    Text(verbatim: "Secrets' values are masked: *** (before) and *** (after) say one changed.")
                        .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.dimText)
                }
                if result.diff.withheld > 0 {
                    Text(verbatim: "\(result.diff.withheld) document\(result.diff.withheld == 1 ? "" : "s") left out: unreadable, so it couldn't be masked.")
                        .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(TabStatusStyle.failed)
                }
                if let text = session.state.text {
                    Text(verbatim: text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(session.state.isFailure ? KubernetesPageView.production : theme.dimText)
                }
                ForEach(result.diff.items) { item in
                    if item.change == .unchanged {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").foregroundStyle(theme.dimText)
                            Text(verbatim: "\(item.spoken): unchanged").foregroundStyle(theme.dimText)
                        }
                        .font(.system(size: ChromeMetrics.text(11)))
                    } else {
                        FileCard(
                            file: ChangedFile(
                                path: "\(item.namespace.map { "\($0)/" } ?? "")\(item.file)", originalPath: nil,
                                kind: item.change == .added ? .added : item.change == .removed ? .deleted : .modified, isStaged: false, hasUnstaged: false,
                                added: item.added, removed: item.removed),
                            diff: session.fileDiffs[item.id], collapsed: folded.contains(item.id), theme: theme, palette: palette,
                            onToggle: {
                                if folded.contains(item.id) { folded.remove(item.id) } else { folded.insert(item.id) }
                            }, onOpen: { onOpen(result.chart.appendingPathComponent("Chart.yaml")) })
                    }
                }
            }
            .padding(12)
        }
    }
}
