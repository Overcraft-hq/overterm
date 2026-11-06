import SwiftUI

/// Health findings as rows (3.9): the check's code, its object (a link to
/// its detail), the sentence; the worst first.
struct KubeHealthFindingRows: View {
    let findings: [KubeHealth.Finding]
    /// Whether the object is said on each row (the Overview's) or not (a detail's own).
    var showsObject = true
    @ObservedObject var theme: ChromeTheme
    let open: (KubeHealth.Subject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: finding.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                        .font(.system(size: 10.5)).foregroundStyle(color(finding)).frame(width: 14)
                    Text(verbatim: finding.check.code).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3)
                    if showsObject {
                        Button {
                            open(finding.subject)
                        } label: {
                            Text(verbatim: (finding.subject.namespace.map { "\($0)/" } ?? "") + finding.subject.said)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.accentText).underline().lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Open its detail")
                    }
                    Text(verbatim: finding.sentence).font(.system(size: 12)).foregroundStyle(theme.text2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .help(finding.check.title)
            }
        }
    }

    private func color(_ finding: KubeHealth.Finding) -> Color {
        finding.severity == .error ? TabStatusStyle.failed : TabStatusStyle.waiting
    }
}

/// The Overview's health checks: what was checked and found, by check,
/// each row a link to its object; what couldn't be read said. Read once
/// while the Overview shows (`KubeHealthSession`), Refresh again.
struct KubeOverviewHealthView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubeHealthSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if session.state != .idle {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: "Health checks").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                    if session.state == .loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(verbatim: session.report.said).font(.system(size: 11)).foregroundStyle(
                            session.report.errors > 0 ? TabStatusStyle.failed : session.report.findings.isEmpty ? theme.text3 : TabStatusStyle.waiting
                        )
                        .accessibilityIdentifier("kubernetes.health.count")
                        Button {
                            page.refreshHealth()
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text3)
                        }
                        .buttonStyle(.plain)
                        .help("Check again")
                    }
                    Spacer(minLength: 0)
                }
                ForEach(session.report.byCheck, id: \.check) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "\(group.check.title) · \(group.findings.count)").font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(group.check.severity == .error ? TabStatusStyle.failed : theme.text2)
                        KubeHealthFindingRows(findings: Array(group.findings.prefix(Self.shown)), theme: theme) { page.openFinding($0) }
                        if group.findings.count > Self.shown {
                            Text(verbatim: "and \(group.findings.count - Self.shown) more").font(.system(size: 11)).foregroundStyle(theme.text3)
                        }
                    }
                    .padding(.top, 2)
                }
                ForEach(session.report.notes, id: \.self) { note in
                    Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                }
                Text("Read once while shown — nothing written, nothing installed, no Secret or ConfigMap read.").font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
            }
            .accessibilityIdentifier("kubernetes.health")
        }
    }

    static let shown = 8
}

/// The health checks' count beside the Overview's header (the findings
/// are further down): `Health: 3 problems, 12 warnings`.
struct KubeHealthCount: View {
    @ObservedObject var session: KubeHealthSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if session.state == .loaded {
            let report = session.report
            Text(verbatim: "Health: \(report.said)").font(.system(size: 12))
                .foregroundStyle(report.errors > 0 ? TabStatusStyle.failed : report.findings.isEmpty ? theme.text3 : TabStatusStyle.waiting)
                .accessibilityIdentifier("kubernetes.overview.healthCount")
        }
    }
}

/// A detail's own findings, and its tree's (a Service's pods, an Ingress's
/// Services) once that is read.
struct KubeObjectHealthView: View {
    @ObservedObject var page: KubernetesPageModel
    let own: [KubeHealth.Finding]
    @ObservedObject var tree: KubeTreeSession
    @ObservedObject var theme: ChromeTheme

    var body: some View { KubeObjectHealthList(page: page, findings: own + tree.findings, theme: theme) }
}

struct KubeObjectHealthList: View {
    @ObservedObject var page: KubernetesPageModel
    let findings: [KubeHealth.Finding]
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Health checks").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                KubeHealthFindingRows(findings: findings.sorted(by: KubeHealth.Finding.ordered), showsObject: false, theme: theme) { page.openFinding($0) }
            }
            .accessibilityIdentifier("kubernetes.detail.health")
        }
    }
}

/// The pinned contexts' cards across the Overview's top: each one's pods
/// failing, workloads and nodes not ready, or why it wasn't read; a press
/// shows that context on the page.
struct KubePinnedHealthView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubePinnedHealthSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if !session.cards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Pinned contexts").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(session.cards) { card in cardView(card) }
                    }
                }
            }
            .accessibilityIdentifier("kubernetes.pinned")
        }
    }

    private func cardView(_ card: KubePinnedHealth.Card) -> some View {
        let shown = page.model.selectedName == card.context
        return Button {
            page.showPinned(card.context)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(dot(card)).frame(width: 7, height: 7)
                    Text(verbatim: card.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(card.production ? KubernetesPageView.production : theme.text)
                }
                Text(verbatim: (card.production ? "PRODUCTION · " : "") + card.place + (shown ? " · on the page" : "")).font(.system(size: 10.5))
                    .foregroundStyle(card.production ? KubernetesPageView.production : theme.text3).lineLimit(1)
                switch card.state {
                case .waiting:
                    Text("Reading…").font(.system(size: 11)).foregroundStyle(theme.text3)
                case .notRead(let why):
                    Text(verbatim: "Not read: \(why)").font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                case .read(let summary, _):
                    line("\(summary.pods) pods", bad: summary.failingCount, word: "failing")
                    line("\(summary.workloads) workloads", bad: summary.notReadyCount, word: "not ready")
                    if summary.nodes > 0 { line("\(summary.nodes) nodes", bad: summary.notReadyNodes.count, word: "not ready") }
                    ForEach(summary.failing + summary.notReady, id: \.self) { item in
                        Text(verbatim: item).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
                    }
                    if !summary.cut.isEmpty {
                        Text(verbatim: "First \(KubePinnedHealth.limit) of \(summary.cut.joined(separator: ", ")) read").font(.system(size: 10.5))
                            .foregroundStyle(theme.text3)
                    }
                    ForEach(summary.unread, id: \.self) { why in
                        Text(verbatim: why).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(2)
                    }
                }
            }
            .padding(10)
            .frame(width: 210, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.rowHover.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(card.production ? KubernetesPageView.production.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shown ? "The context the page shows" : "Show \(card.displayName) on the page")
        .accessibilityIdentifier("kubernetes.pinned.\(card.context)")
    }

    private func line(_ text: String, bad: Int, word: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text)
            Text(verbatim: bad > 0 ? "\(bad) \(word)" : "fine").font(.system(size: 11)).foregroundStyle(bad > 0 ? TabStatusStyle.failed : theme.text3)
        }
    }

    private func dot(_ card: KubePinnedHealth.Card) -> Color {
        switch card.state {
        case .waiting, .notRead: theme.text3
        case .read(let summary, _): summary.isFine ? TabStatusStyle.done : TabStatusStyle.failed
        }
    }
}
