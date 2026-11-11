import AppKit
import SwiftUI

/// The page's Helm section (`8`): the releases of the context and
/// namespace shown — name, namespace, revision, status, chart, app
/// version, updated — read from Helm's records' labels alone, and beside
/// them the release opened: its Overview, History, Values (the user's or
/// computed), Manifest and Notes, every value that looks secret and every
/// Secret's data masked, and its writes — Roll Back, Uninstall, helm in a
/// tab (`KubeHelmWrite`) — greyed with why where they can't be done.
/// Where Secrets can't be listed it says so, with helm in a terminal offered.
struct KubeHelmSection: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var helm: KubeHelmSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let refused = helm.secretsRefused { refusal(refused) }
                    if let unlisted = helm.unlisted { unlistedNote(unlisted) }
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let opened = helm.opened {
                    Rectangle().fill(theme.border).frame(width: 1)
                    KubeHelmDetailView(page: page, helm: helm, opened: opened, theme: theme)
                        .frame(width: min(600, max(360, geometry.size.width * 0.5)))
                }
            }
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityIdentifier("kubernetes.helm")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: countNote).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
            Spacer(minLength: 4)
            Button("Copy helm") { page.actions?.copy(page.helmCommand) }.controlSize(.small).help(page.helmCommand)
            Button("Refresh") { page.loadHelm() }.controlSize(.small).disabled(helm.listState == .loading)
                .accessibilityIdentifier("kubernetes.helm.refresh")
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
    }

    private var countNote: String {
        switch helm.listState {
        case .idle: return "Reading Helm's release records…"
        case .loading where helm.releases.isEmpty: return "Reading Helm's release records…"
        case .failed(let reason): return reason
        default:
            let count = helm.releases.count
            return "\(count) release\(count == 1 ? "" : "s") · from Helm's records' labels; one is read when it is opened"
        }
    }

    private func refusal(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(TabStatusStyle.waiting)
                Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                let command = KubeHelmLine.list(context: helm.context ?? "", scope: helm.scope ?? .all)
                Text(verbatim: command).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text2).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Button("Copy") { page.actions?.copy(command) }.controlSize(.small)
                Button("Terminal in This Context") { page.openHelmTerminal() }.controlSize(.small)
                    .help("A tab whose kubectl and helm go to this context — your own credentials, nothing enforced inside it")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(TabStatusStyle.waiting.opacity(0.10)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.helm.refused")
    }

    /// A storage's list failed while another's listed: said, with Refresh.
    private func unlistedNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(TabStatusStyle.waiting)
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Refresh") { page.loadHelm() }.controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(TabStatusStyle.waiting.opacity(0.10)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kubernetes.helm.unlisted")
    }

    @ViewBuilder private var content: some View {
        if helm.releases.isEmpty {
            if helm.listState == .live {
                Text(verbatim: helm.secretsRefused == nil ? "No Helm releases in \(page.scopeLabel)." : "No releases readable here.")
                    .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).padding(.horizontal, 20).padding(.top, 20)
                    .accessibilityIdentifier("kubernetes.helm.empty")
            } else if helm.listState == .loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
            }
            Spacer(minLength: 0)
        } else {
            columnsHeader
            Rectangle().fill(theme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(helm.releases) { release in row(release) }
                }
            }
        }
    }

    private var showsNamespace: Bool { helm.scope?.spansNamespaces ?? false }

    private var columnsHeader: some View {
        HStack(spacing: 8) {
            if showsNamespace { cell("Namespace", width: 110) }
            cell("Name", width: nil)
            cell("Revision", width: 60)
            cell("Status", width: 110)
            cell("Chart", width: 150)
            cell("App Version", width: 90)
            cell("Updated", width: 80)
        }
        .font(.system(size: ChromeMetrics.text(11), weight: .semibold))
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 20)
        .frame(height: 24)
    }

    @ViewBuilder private func cell(_ text: String, width: CGFloat?) -> some View {
        if let width {
            Text(verbatim: text).lineLimit(1).truncationMode(.middle).frame(width: width, alignment: .leading)
        } else {
            Text(verbatim: text).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ release: KubeHelmRelease) -> some View {
        let picked = helm.selection == release.id
        let chart = helm.charts[release.id]
        return HStack(spacing: 8) {
            if showsNamespace {
                cell(release.storage == .tiller ? "\(release.namespace) (Tiller)" : release.namespace, width: 110).foregroundStyle(theme.text2)
                    .help(release.storage == .tiller ? "Tiller's namespace, where Helm 2 keeps every release's records — not the release's own" : "")
            }
            HStack(spacing: 4) {
                Text(verbatim: release.name).lineLimit(1).truncationMode(.middle)
                if release.storage != .secret {
                    Text(verbatim: release.storage == .tiller ? "Helm 2" : "ConfigMap").font(.system(size: ChromeMetrics.text(9.5))).foregroundStyle(theme.text3)
                        .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).stroke(theme.border))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(String(release.revision), width: 60).foregroundStyle(theme.text2)
            cell(release.status, width: 110).foregroundStyle(statusColor(release.status))
            cell(chart?.said ?? "—", width: 150).foregroundStyle(theme.text2)
                .help(chart == nil ? "Read when the release is opened: the list reads only the records' labels" : "")
            cell(chart?.appVersion ?? "—", width: 90).foregroundStyle(theme.text2)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                cell(release.updated.map { KubeAge.format(context.date.timeIntervalSince($0)) } ?? "—", width: 80).foregroundStyle(theme.text2)
            }
        }
        .font(.system(size: ChromeMetrics.text(12)))
        .foregroundStyle(theme.text)
        .padding(.horizontal, 20)
        .frame(height: 26)
        .background(Rectangle().fill(picked ? theme.selected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { page.openHelm(release) }
        .contextMenu { ResourceVerbMenu(verbs: page.helmWriteVerbs(for: release)) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kubernetes.helm.release.\(release.namespace).\(release.name)")
    }

    func statusColor(_ status: String) -> Color { Self.color(status, theme: theme) }

    static func color(_ status: String, theme: ChromeTheme) -> Color {
        switch status {
        case "deployed": TabStatusStyle.done
        case "failed": TabStatusStyle.failed
        case "superseded", "uninstalled": theme.text3
        default: TabStatusStyle.waiting
        }
    }
}

/// One release opened: the revision's record decoded and masked.
struct KubeHelmDetailView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var helm: KubeHelmSession
    let opened: KubeHelmSession.Opened
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            Rectangle().fill(theme.border).frame(height: 1)
            switch opened.state {
            case .confirming: confirming
            case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason): note(reason, symbol: "exclamationmark.triangle")
            case .dropped(let reason):
                VStack(spacing: 10) {
                    note(reason, symbol: "eye.slash")
                    Button("Read Again") { helm.readAgain() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .shown(let detail):
                switch helm.tab {
                case .overview: overview(detail)
                case .history: history(detail)
                case .values: values(detail)
                case .manifest: text(detail.manifest, note: manifestNote(detail), id: "kubernetes.helm.manifest")
                case .notes: text(detail.notes.isEmpty ? "(no notes)\n" : detail.notes, note: "NOTES.txt as rendered · credentials taken out", id: "kubernetes.helm.notes")
                }
            }
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityIdentifier("kubernetes.helm.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "Helm release").font(.system(size: ChromeMetrics.text(11), weight: .medium)).foregroundStyle(theme.text3)
                Spacer(minLength: 0)
                Button {
                    page.actions?.copy(KubeHelmLine.status(context: opened.context, namespace: opened.release.namespace, release: opened.release.name))
                } label: {
                    Image(systemName: "terminal").font(.system(size: ChromeMetrics.text(11), weight: .medium)).foregroundStyle(theme.text2).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy helm status — \(KubeHelmLine.status(context: opened.context, namespace: opened.release.namespace, release: opened.release.name))")
                Button {
                    helm.close()
                } label: {
                    Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(11), weight: .medium)).foregroundStyle(theme.text2).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityIdentifier("kubernetes.helm.close")
            }
            Text(verbatim: opened.release.name).font(.system(size: ChromeMetrics.text(15), weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                .textSelection(.enabled)
            Text(
                verbatim: [opened.release.namespace, "revision \(opened.record.revision)", opened.record.status, opened.release.storage.said, opened.context]
                    .joined(separator: " · ")
            )
            .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
            KubeHelmActions(page: page, writeAccess: page.model.writeAccess, release: opened.release, theme: theme).padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The release's writes as buttons — the same list as its row's menu
    /// (`helmWriteVerbs`), greyed with why until the access review says
    /// yes — and what the last one did.
    private struct KubeHelmActions: View {
        @ObservedObject var page: KubernetesPageModel
        /// The writes' access reviews.
        @ObservedObject var writeAccess: KubeAccessChecks
        let release: KubeHelmRelease
        @ObservedObject var theme: ChromeTheme

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                ResourceActionBar(verbs: page.helmWriteVerbs(for: release), theme: theme, identifier: "kubernetes.helm.actions")
                if let status = page.writeStatus {
                    Text(verbatim: status.text).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(status.isFailure ? TabStatusStyle.failed : theme.text2)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("kubernetes.helm.writeStatus")
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(KubeHelmSession.Tab.allCases) { item in
                Button {
                    helm.tab = item
                } label: {
                    Text(item.title)
                        .font(.system(size: ChromeMetrics.text(12), weight: helm.tab == item ? .semibold : .regular))
                        .foregroundStyle(helm.tab == item ? theme.text : theme.text2)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(helm.tab == item ? theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kubernetes.helm.tab.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var confirming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Read a release on \(opened.context)?").font(.system(size: ChromeMetrics.text(13), weight: .semibold)).foregroundStyle(KubernetesPageView.production)
            Text(
                "A release is a Secret of Helm's: reading it reads its values and manifest. Overterm masks what looks secret, keeps it only while it shows, and never writes or logs it. Asked once per production context this session."
            )
            .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Read Release") { helm.confirm() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { helm.cancelConfirmation() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("kubernetes.helm.confirm")
    }

    private func note(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: ChromeMetrics.text(22), weight: .light)).foregroundStyle(theme.text3)
            Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).multilineTextAlignment(.center).textSelection(.enabled)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tabs

    private func fact(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(theme.text3).frame(width: 110, alignment: .leading)
            Text(verbatim: value ?? "—").foregroundStyle(theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: ChromeMetrics.text(12)))
    }

    private static func said(_ date: Date?) -> String? { date?.formatted(date: .abbreviated, time: .standard) }

    private func overview(_ detail: KubeHelmDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                fact("Status", detail.status)
                fact("Revision", String(detail.revision))
                fact("Chart", detail.chart.said)
                fact("App version", detail.chart.appVersion)
                fact("Description", detail.summary)
                fact("First deployed", Self.said(detail.firstDeployed))
                fact("Last deployed", Self.said(detail.lastDeployed))
                if let about = detail.chartDescription { fact("About the chart", about) }
                fact("Storage", opened.release.storage.said + " " + opened.record.object)
                Text(verbatim: maskNote(detail)).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("kubernetes.helm.overview")
    }

    private func maskNote(_ detail: KubeHelmDetail) -> String {
        "Values and the manifest are masked: \(detail.maskedUserValues) of the user's values, \(detail.maskedSecrets) Secret\(detail.maskedSecrets == 1 ? "" : "s") in the manifest. Nothing read is written, logged or given to an agent."
    }

    private func history(_ detail: KubeHelmDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(opened.release.history) { record in
                    let current = record.id == opened.record.id
                    HStack(spacing: 10) {
                        Text(verbatim: String(record.revision)).font(.system(size: ChromeMetrics.text(12), design: .monospaced)).frame(width: 36, alignment: .leading)
                        Text(verbatim: record.status).foregroundStyle(KubeHelmSection.color(record.status, theme: theme)).frame(width: 110, alignment: .leading)
                        Text(verbatim: current ? detail.summary ?? "" : helm.summaries[record.id] ?? "—").foregroundStyle(theme.text2)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: record.updated.map { KubeAge.format(context.date.timeIntervalSince($0)) } ?? "—").foregroundStyle(theme.text3)
                        }
                        if record.revision != opened.release.revision { rollBack(to: record) }
                    }
                    .font(.system(size: ChromeMetrics.text(12)))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 28)
                    .background(Rectangle().fill(current ? theme.selected : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { if !current { page.openHelm(opened.release, revision: record) } }
                    .help(current ? "The revision shown" : "Read revision \(record.revision)")
                    .accessibilityIdentifier("kubernetes.helm.revision.\(record.revision)")
                }
                Text("A revision's description is read with it: press one to read it.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
                    .padding(14)
            }
        }
        .accessibilityIdentifier("kubernetes.helm.history")
    }

    private func rollBack(to record: KubeHelmRecord) -> some View {
        KubeHelmRollBack(page: page, writeAccess: page.model.writeAccess, release: opened.release, revision: record.revision, theme: theme)
    }

    /// A History row's Roll Back: to that revision, asked as any rollback
    /// is, greyed with why until the access review says yes.
    private struct KubeHelmRollBack: View {
        @ObservedObject var page: KubernetesPageModel
        @ObservedObject var writeAccess: KubeAccessChecks
        let release: KubeHelmRelease
        let revision: Int
        @ObservedObject var theme: ChromeTheme

        var body: some View {
            let unavailable = page.helmContext.flatMap { page.helmWriteUnavailable(.helmRollback, $0, release) }
            Button {
                page.runHelmWrite(.helmRollback, on: release, revision: revision)
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: ChromeMetrics.text(11), weight: .medium))
                    .foregroundStyle(unavailable == nil ? theme.text2 : theme.text3.opacity(0.5)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(unavailable != nil)
            .help(["Roll back to revision \(revision) in a tab", unavailable].compactMap { $0 }.joined(separator: " — "))
            .accessibilityIdentifier("kubernetes.helm.rollback.\(revision)")
        }
    }

    private func values(_ detail: KubeHelmDetail) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $helm.computedValues) {
                    Text("User-supplied").tag(false)
                    Text("Computed").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            let shown = helm.computedValues ? detail.computedValues : (detail.userValues.isEmpty ? "# No values supplied: the chart's defaults.\n" : detail.userValues)
            let masked = helm.computedValues ? detail.maskedComputedValues : detail.maskedUserValues
            text(
                shown, note: "\(masked) masked · keys that look secret (password, token, key, auth…) and credentials in text",
                id: "kubernetes.helm.values")
        }
    }

    private func manifestNote(_ detail: KubeHelmDetail) -> String {
        var parts = ["Every Secret's data masked (\(detail.maskedSecrets))", "secret-looking env values hidden"]
        if detail.withheldDocuments > 0 { parts.append("\(detail.withheldDocuments) document\(detail.withheldDocuments == 1 ? "" : "s") left out, unreadable") }
        return parts.joined(separator: " · ")
    }

    private func text(_ text: String, note: String, id: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: note).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 4)
                Button("Copy") { page.actions?.copy(text) }.font(.system(size: ChromeMetrics.text(11.5))).help("Copy it as shown, masked")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            LogTextView(
                count: lines.count, revision: text.hashValue, render: { range in lines[range].map { KubeDetailView.line(String($0), theme: theme) } },
                wrap: false, follow: false, identifier: id + ".text")
        }
        .accessibilityIdentifier(id)
    }
}

/// How many releases the Helm section lists, beside its name.
struct KubeHelmCount: View {
    @ObservedObject var helm: KubeHelmSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if helm.listState == .live, !helm.releases.isEmpty {
            Text(verbatim: "\(helm.releases.count)").foregroundStyle(theme.text3).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced))
        }
    }
}
