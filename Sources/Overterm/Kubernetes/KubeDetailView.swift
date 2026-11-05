import AppKit
import SwiftUI

/// The detail beside a Kubernetes list (↩, or a click): one object, read
/// with one GET as it opens — Overview, YAML, Events — with back and
/// forward through where it has been (`[` `]`, ⌘[ ⌘]), and links (its
/// owners, its node, the pods it selects) that open theirs. Docker's
/// container detail is its pattern. A Secret is read only by its Show
/// (`KubeSecretView`), its values masked.
struct KubeDetailView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var session: KubeDetailSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            Rectangle().fill(theme.border).frame(height: 1)
            if let problem = page.linkProblem {
                Text(verbatim: problem).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).padding(.horizontal, 16).padding(.vertical, 6)
            }
            switch session.state {
            case .withheld where session.secret == nil: withheld
            case .failed(let reason): failed(reason)
            case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded, .withheld:
                switch page.detailTab {
                case .overview: overview
                case .logs:
                    if let logs = session.logs {
                        KubePodLogsView(page: page, logs: logs, theme: theme)
                    } else if let merged = session.merged {
                        KubeMergedLogsView(page: page, logs: merged, theme: theme)
                    } else if session.ref.selectsPods {
                        Text(verbatim: "It picks no pods by label: there are no logs to merge.").font(.system(size: 12)).foregroundStyle(theme.text3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        overview
                    }
                case .yaml: yaml
                case .events: events
                }
            }
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .accessibilityIdentifier("kubernetes.detail")
    }

    // MARK: The top

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                navButton("chevron.left", "Back  [  ⌘[", enabled: page.history.canGoBack, id: "kubernetes.detail.back") { page.goBack() }
                navButton("chevron.right", "Forward  ]  ⌘]", enabled: page.history.canGoForward, id: "kubernetes.detail.forward") { page.goForward() }
                Text(verbatim: session.object?.kind ?? (session.ref.kind.kind.isEmpty ? session.ref.kind.resource : session.ref.kind.kind))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text3).padding(.leading, 4)
                Spacer(minLength: 0)
                Button {
                    page.copyDetailKubectl()
                } label: {
                    Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text2).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy as kubectl — \(page.detailKubectl ?? "")")
                .accessibilityIdentifier("kubernetes.detail.copyKubectl")
                Button {
                    page.closeDetail()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text2).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityIdentifier("kubernetes.detail.close")
            }
            Text(verbatim: session.ref.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                .truncationMode(.middle).textSelection(.enabled)
                .accessibilityIdentifier("kubernetes.detail.name")
            Text(verbatim: subtitle).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1).truncationMode(.middle)
            if session.ref.isPod || KubeForwardTarget.of(kind: session.ref.kind, name: session.ref.name) != nil
                || KubeWriteVerb.allCases.contains(where: { KubeWriteCheck.offered($0, on: session.ref.kind) })
            {
                KubePodActions(
                    page: page, access: page.model.access, writeAccess: page.model.writeAccess, forwards: page.forwards, ref: session.ref, theme: theme
                ).padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A pod's tab verbs as buttons — the same list as its right-click
    /// menu (`podVerbs`), greyed with why until `kubectl auth can-i` says
    /// yes — and why the last one didn't open.
    private struct KubePodActions: View {
        @ObservedObject var page: KubernetesPageModel
        @ObservedObject var access: KubeAccessChecks
        /// The writes' access reviews.
        @ObservedObject var writeAccess: KubeAccessChecks
        /// Open Forward comes and goes with its forward.
        @ObservedObject var forwards: KubeForwards
        let ref: KubeObjectRef
        @ObservedObject var theme: ChromeTheme

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                ResourceActionBar(verbs: page.detailVerbs(for: ref), theme: theme, identifier: "kubernetes.detail.actions")
                if let problem = page.commandProblem {
                    Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("kubernetes.detail.commandProblem")
                } else if let status = page.writeStatus {
                    Text(verbatim: status.text).font(.system(size: 11)).foregroundStyle(status.isFailure ? TabStatusStyle.failed : theme.text2)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("kubernetes.detail.writeStatus")
                }
            }
        }
    }

    private var subtitle: String {
        [session.ref.namespace ?? "cluster-wide", session.ref.kind.groupVersion, session.ref.context].joined(separator: " · ")
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(enabled ? theme.text2 : theme.text3.opacity(0.5))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityIdentifier(id)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(KubeDetailTab.tabs(for: session.ref)) { item in
                Button {
                    page.showTab(item)
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: page.detailTab == item ? .semibold : .regular))
                        .foregroundStyle(page.detailTab == item ? theme.text : theme.text2)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(page.detailTab == item ? theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kubernetes.detail.tab.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: States

    private var withheld: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(theme.text3)
                Text("Not read").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            }
            Text(
                "A Secret's keys and values come only with the object itself, and one GET of it returns every value at once — so the detail doesn't ask for it. The list shows its type and how many keys it has."
            )
            .font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("kubernetes.detail.withheld")
    }

    private func failed(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 24, weight: .light)).foregroundStyle(theme.text3)
            Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(theme.text2).multilineTextAlignment(.center).textSelection(.enabled)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("kubernetes.detail.failed")
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let secret = session.secret { KubeSecretView(page: page, secret: secret, theme: theme) }
                if let overview = session.overview {
                    if let rollout = overview.rollout, rollout.state != .complete { rolloutNote(rollout) }
                    if !overview.facts.isEmpty { items(overview.facts) }
                    if session.ref.isPod { KubePodUsageView(page: page, metrics: page.model.metrics, session: session, theme: theme) }
                    if overview.pods != nil { podsSection }
                    ForEach(overview.sections) { section in
                        if !section.items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                caption(section.title)
                                items(section.items)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.loadPods() }
        .accessibilityIdentifier("kubernetes.detail.overview")
    }

    private func rolloutNote(_ rollout: KubeRollout) -> some View {
        let color = rollout.isProblem ? TabStatusStyle.failed : TabStatusStyle.waiting
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: rollout.isProblem ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath").foregroundStyle(color)
            Text(verbatim: rollout.message).font(.system(size: 12)).foregroundStyle(theme.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .accessibilityIdentifier("kubernetes.detail.rollout")
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
    }

    private func color(_ tone: KubeOverview.Tone) -> Color {
        switch tone {
        case .plain: theme.text
        case .good: TabStatusStyle.done
        case .waiting: TabStatusStyle.waiting
        case .bad: TabStatusStyle.failed
        case .dim: theme.text3
        }
    }

    private func items(_ items: [KubeOverview.Item]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: item.label).font(.system(size: 11.5)).foregroundStyle(theme.text3).lineLimit(2).truncationMode(.middle)
                        .frame(width: 128, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        value(item)
                        if let detail = item.detail {
                            Text(verbatim: detail).font(.system(size: 11, design: item.detailMono ? .monospaced : .default)).foregroundStyle(theme.text3)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if !item.ports.isEmpty { containerPorts(item.ports) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// A container's ports: each opens Port-forward… on the pod, that port picked.
    private func containerPorts(_ ports: [KubeForwardPortOption]) -> some View {
        HStack(spacing: 6) {
            ForEach(ports, id: \.self) { port in
                Button {
                    page.portForward(session.ref, port: port.port)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .semibold))
                        Text(verbatim: port.name.map { "\(port.port) (\($0))" } ?? "\(port.port)").font(.system(size: 11, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(theme.accentText)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(theme.accentText.opacity(0.4)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Port-forward… to \(port.port)  \(KubernetesKey.portForward.key)")
                .accessibilityIdentifier("kubernetes.detail.port.\(port.port)")
            }
        }
    }

    @ViewBuilder private func value(_ item: KubeOverview.Item) -> some View {
        let font = Font.system(size: 12, design: item.mono ? .monospaced : .default)
        if let link = item.link {
            Button {
                page.follow(link)
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: item.value).font(font).underline()
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(theme.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(link.kind) \(link.namespace.map { "\($0)/" } ?? "")\(link.name)")
            .accessibilityIdentifier("kubernetes.detail.link.\(link.kind).\(link.name)")
        } else {
            Text(verbatim: item.value).font(font).foregroundStyle(color(item.tone)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var podsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Pods it selects")
            switch session.pods {
            case .idle, .loading: ProgressView().controlSize(.small)
            case .failed(let reason): Text(verbatim: reason).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed)
            case .loaded(let rows) where rows.isEmpty: Text("None.").font(.system(size: 12)).foregroundStyle(theme.text3)
            case .loaded(let rows):
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 8) {
                        Button {
                            page.openPod(row)
                        } label: {
                            Text(verbatim: row.row.id.name).font(.system(size: 12)).underline().foregroundStyle(theme.accentText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kubernetes.detail.pod.\(row.row.id.name)")
                        if let summary = row.summary {
                            Text(verbatim: summary.isFailing ? (summary.exitReason ?? summary.status) : summary.status)
                                .font(.system(size: 11.5)).foregroundStyle(summary.isFailing ? TabStatusStyle.failed : theme.text2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: YAML

    @ViewBuilder private var yaml: some View {
        if let secret = session.secret, session.state == .withheld {
            VStack(alignment: .leading, spacing: 10) {
                Text("A Secret's YAML is read with its values: Show reads them, and the YAML shows them masked.")
                    .font(.system(size: 12)).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
                if secret.state == .hidden || secret.state == .confirming {
                    Button("Show Values") {
                        page.showTab(.overview)
                        _ = page.showSecret()
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("kubernetes.detail.yaml")
        } else {
            objectYAML
        }
    }

    private var objectYAML: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(
                    verbatim: (session.showsHidden ? "As the server sent it" : "Without managedFields and the last-applied annotation")
                        + (session.secret != nil ? " · every value masked" : " · secret-looking env values hidden")
                )
                .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 4)
                if session.hasHidden {
                    Toggle("Show them", isOn: $session.showsHidden).toggleStyle(.checkbox).font(.system(size: 11.5))
                        .accessibilityIdentifier("kubernetes.detail.showHidden")
                }
                Button("Copy") { page.actions?.copy(session.yaml) }.font(.system(size: 11.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            let text = session.yaml
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            LogTextView(
                count: lines.count, revision: text.hashValue, render: { range in lines[range].map { Self.line(String($0), theme: theme) } }, wrap: false,
                follow: false, identifier: "kubernetes.detail.text")
        }
        .accessibilityIdentifier("kubernetes.detail.yaml")
    }

    /// A key in the text colour, its value dimmer, a block's lines and a
    /// list's dash as they are.
    static func line(_ text: String, theme: ChromeTheme) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: LogStyle.font, .foregroundColor: theme.textNS.withAlphaComponent(0.72)])
        if let range = text.range(of: #"^\s*(- )?("[^"]*"|[^\s:"'#][^:]*?):(?=\s|$)"#, options: .regularExpression) {
            out.addAttribute(.foregroundColor, value: theme.textNS, range: NSRange(range, in: text))
        }
        return out
    }

    // MARK: Events

    private var events: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: eventsNote).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 4)
                Button("Refresh") { session.loadEvents(again: true) }.font(.system(size: 11.5)).disabled(session.events == .loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch session.events {
                    case .idle, .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    case .failed(let reason): Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(TabStatusStyle.failed)
                    case .loaded(let events) where events.isEmpty:
                        Text("No events: the cluster keeps them about an hour.").font(.system(size: 12)).foregroundStyle(theme.text3)
                    case .loaded(let events):
                        ForEach(events) { event in eventRow(event) }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { session.loadEvents() }
        .accessibilityIdentifier("kubernetes.detail.events")
    }

    private var eventsNote: String {
        guard let events = session.events.value else { return "Its events, newest first" }
        let warnings = events.filter(\.isWarning).count
        return "\(events.count) event\(events.count == 1 ? "" : "s"), newest first" + (warnings > 0 ? " · \(warnings) warning\(warnings == 1 ? "" : "s")" : "")
    }

    private func eventRow(_ event: KubeEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11)).foregroundStyle(event.isWarning ? TabStatusStyle.waiting : theme.text3).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: event.reason).font(.system(size: 12, weight: .semibold)).foregroundStyle(event.isWarning ? TabStatusStyle.waiting : theme.text)
                    if event.count > 1 { Text(verbatim: "×\(event.count)").font(.system(size: 11)).foregroundStyle(theme.text3) }
                    Spacer(minLength: 0)
                    if let last = event.last {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: KubeAge.format(context.date.timeIntervalSince(last)) + " ago").font(.system(size: 11)).foregroundStyle(theme.text3)
                        }
                    }
                }
                Text(verbatim: event.message).font(.system(size: 12)).foregroundStyle(theme.text2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.source.isEmpty { Text(verbatim: event.source).font(.system(size: 10.5)).foregroundStyle(theme.text3) }
            }
        }
        .accessibilityIdentifier("kubernetes.detail.event")
    }
}

/// A pod's Logs tab: which container (init and ephemeral ones marked),
/// Previous once it restarted, how far back, how it reads now — then the
/// shared log pane, its options kept for the window, Save As, ⌘L.
struct KubePodLogsView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var logs: KubePodLogSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(theme.border).frame(height: 1)
            LogsPane(
                feed: logs.feed, theme: theme, identifier: "kubernetes.logs", runInTerminal: { page.actions?.run($0) },
                ask: { [weak page] in page?.askAboutLogLines($0) }, options: $page.logOptions, save: { [weak page] in page?.saveLogs($0) },
                older: logs.reachedStart ? nil : { [weak logs] in logs?.loadOlder() },
                stoppedHelp: "Not followed now: shown again, it is read from its last line", focusFilter: page.focusLogFilter)
        }
        .accessibilityIdentifier("kubernetes.logs")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if logs.containers.count > 1 {
                Picker("", selection: Binding(get: { logs.container ?? "" }, set: { logs.pick(container: $0) })) {
                    ForEach(logs.containers) { container in
                        Text(verbatim: container.role == .container ? container.name : "\(container.name) (\(container.role.title))").tag(container.name)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("The container whose log shows: the pod's default one first")
                .accessibilityIdentifier("kubernetes.logs.container")
            } else if let name = logs.container {
                Text(verbatim: name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text2)
            }
            if logs.shown?.hasPrevious == true {
                Toggle("Previous", isOn: Binding(get: { logs.previous }, set: { logs.pick(previous: $0) }))
                    .toggleStyle(.checkbox).font(.system(size: 11.5))
                    .help("The last terminated instance's log" + (logs.shown?.lastTerminated.map { ": \($0)" } ?? ""))
                    .accessibilityIdentifier("kubernetes.logs.previous")
            }
            Picker("", selection: $page.logSince) {
                ForEach(KubeLogSince.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("How far back the log goes")
            .accessibilityIdentifier("kubernetes.logs.since")
            Spacer(minLength: 4)
            if logs.loadingOlder { ProgressView().controlSize(.mini) }
            if let note { Text(verbatim: note).font(.system(size: 11)).foregroundStyle(noteColor).lineLimit(1).truncationMode(.tail) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var note: String? {
        if let problem = logs.olderProblem { return "Older lines: \(problem)" }
        switch logs.reading {
        case .idle, .following: return logs.reachedStart ? "From the start of its log" : nil
        case .resuming: return "Reconnecting…"
        case .waiting(let reason): return reason
        case .ended(let reason): return reason ?? (logs.previous ? "The previous instance's whole log" : "Ended")
        }
    }

    private var noteColor: Color {
        switch logs.reading {
        case .ended(let reason?) where reason != KubeLogResume.podGone: TabStatusStyle.failed
        case .waiting, .resuming: TabStatusStyle.waiting
        default: theme.text3
        }
    }
}


/// A pod's containers' usage against what they request and are limited
/// to: the detail's object and the pods list's sample (stage 2d) — shown
/// while the list beside it reads usage, nothing read for it alone — with
/// a sparkline of the pod's samples taken while shown.
struct KubePodUsageView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var metrics: KubeMetricsMonitor
    @ObservedObject var session: KubeDetailSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let lines = page.containerUsage(of: session.ref, object: session.object?.json), !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Usage").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                ForEach(lines, id: \.container) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: line.container).font(.system(size: 11.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
                            .frame(width: 128, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "cpu \(line.cpu)").font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                            Text(verbatim: "memory \(line.memory)").font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(line.nearLimit ? TabStatusStyle.failed : theme.text)
                                .help(line.nearLimit ? "Within a tenth of its memory limit: past it, the container is OOMKilled." : "")
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
                let history = page.usageHistory(of: session.ref)
                if let span = KubeUsageHistory.span(history) {
                    HStack(spacing: 16) {
                        sparkline("cpu", history.map(\.usage.cpu))
                        sparkline("memory", history.map(\.usage.memory))
                    }
                    Text(verbatim: "The pod's total over \(span)").font(.system(size: 10.5)).foregroundStyle(theme.text3)
                        .accessibilityIdentifier("kubernetes.detail.usage.history")
                }
            }
            .accessibilityIdentifier("kubernetes.detail.usage")
        }
    }

    private func sparkline(_ title: String, _ values: [Double]) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title).font(.system(size: 10.5)).foregroundStyle(theme.text3)
            KubeSparkline(values: values, color: theme.accentText).frame(width: 120, height: 18)
        }
    }
}
