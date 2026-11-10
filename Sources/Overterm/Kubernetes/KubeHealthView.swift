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

/// The Overview's health checks as a card: the count, the severities as
/// chips, each check a row that opens to its findings (a check that
/// found problems open at first), each finding a link to its object;
/// what couldn't be read said. Read once while the Overview shows
/// (`KubeHealthSession`), Refresh again.
struct KubeOverviewHealthView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubeHealthSession
    @ObservedObject var theme: ChromeTheme
    /// The checks opened or closed against their first state.
    @State private var toggled: Set<KubeHealth.Check> = []

    var body: some View {
        if session.state != .idle {
            VStack(alignment: .leading, spacing: 10) {
                header
                if session.state == .loaded, let gitOps = KubeOverviewCards.gitOps(session.report, scope: session.scope) {
                    // What Argo CD and Flux say of what lives here, in a line.
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5, weight: .semibold))
                        Text(verbatim: gitOps.text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(gitOps.tone == .failed ? TabStatusStyle.failed : theme.orangeText)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((gitOps.tone == .failed ? TabStatusStyle.failed : theme.orangeText).opacity(0.1))
                    )
                    .help("From the checks below: Argo CD's failed (K602), drifted or stuck (K603), Flux's not ready (K601)")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("kubernetes.health.gitops")
                }
                if session.state != .loading, !session.report.byCheck.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(session.report.byCheck.enumerated()), id: \.element.check) { index, group in
                            if index > 0 { Rectangle().fill(theme.border).frame(height: 1) }
                            checkRow(group.check, group.findings)
                        }
                    }
                }
                ForEach(session.report.notes, id: \.self) { note in
                    Text(verbatim: note).font(.system(size: 11)).foregroundStyle(theme.text3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Read once while shown — nothing written, nothing installed, no Secret or ConfigMap read.").font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
            }
            .resourceCard(theme)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kubernetes.health")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Health checks").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            if session.state == .loading {
                ProgressView().controlSize(.mini)
            } else {
                let severities = KubeOverviewCards.severities(session.report)
                if severities.isEmpty {
                    Text(verbatim: session.report.said).font(.system(size: 11)).foregroundStyle(theme.text3)
                        .accessibilityIdentifier("kubernetes.health.count")
                }
                Spacer(minLength: 6)
                if !severities.isEmpty {
                    // The count, as chips by severity.
                    HStack(spacing: 6) {
                        ForEach(severities, id: \.text) { pill in
                            ResourcePill(text: pill.text, colour: pill.tone == .failed ? TabStatusStyle.failed : theme.orangeText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("kubernetes.health.count")
                }
                let passing = KubeOverviewCards.passingChecks(session.report)
                if passing > 0 {
                    ResourcePill(text: "\(passing) pass", colour: theme.greenText, symbol: "checkmark")
                }
                Button {
                    page.refreshHealth()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
                .help("Check again")
            }
            if session.state == .loading { Spacer(minLength: 0) }
        }
    }

    private func isOpen(_ check: KubeHealth.Check) -> Bool { (check.severity == .error) != toggled.contains(check) }

    private func checkRow(_ check: KubeHealth.Check, _ findings: [KubeHealth.Finding]) -> some View {
        let open = isOpen(check)
        let tone = check.severity == .error ? TabStatusStyle.failed : theme.orangeText
        return VStack(alignment: .leading, spacing: 6) {
            ResourceCardRow(theme: theme, help: check.title) {
                if toggled.contains(check) { toggled.remove(check) } else { toggled.insert(check) }
            } content: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.text3)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Image(systemName: check.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(check.severity == .error ? TabStatusStyle.failed : TabStatusStyle.waiting).frame(width: 14)
                    Text(verbatim: check.title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    Text(verbatim: check.code).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3)
                    Spacer(minLength: 6)
                    ResourcePill(text: "\(findings.count)", colour: tone)
                }
            }
            .padding(.horizontal, -8)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    KubeHealthFindingRows(findings: Array(findings.prefix(Self.shown)), theme: theme) { page.openFinding($0) }
                    if findings.count > Self.shown {
                        Text(verbatim: "and \(findings.count - Self.shown) more").font(.system(size: 11)).foregroundStyle(theme.text3)
                    }
                }
                .padding(.leading, 18)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 2)
    }

    static let shown = 8
}

/// The health checks' count as a pill in the Overview's header (the
/// findings are further down): `Health: 3 problems, 12 warnings`.
struct KubeHealthCount: View {
    @ObservedObject var session: KubeHealthSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if session.state == .loaded {
            let report = session.report
            ResourcePill(
                text: "Health: \(report.said)",
                colour: report.errors > 0 ? TabStatusStyle.failed : report.findings.isEmpty ? theme.text2 : theme.orangeText,
                symbol: "stethoscope"
            )
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
                ResourceCardCaption(text: "Pinned contexts", theme: theme)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(session.cards) { card in cardView(card) }
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
            .resourceCard(theme, tint: card.production ? KubernetesPageView.production : nil, padding: 12)
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
