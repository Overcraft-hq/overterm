import SwiftUI

/// The rail's Kubernetes panel (Section 6): the selected tab's checkout,
/// what it is bound to (3.1) — or what its files suggest, to bind it —
/// the bound namespace's workloads and pods with their health, the
/// forwards there, and the deployed commit against the checkout's (3.2).
/// A pod clicked shows in the right slot.
package struct KubernetesPanelView: View {
    @ObservedObject package var panel: KubernetesPanelModel
    @ObservedObject package var kubernetes: KubernetesModel
    @ObservedObject package var forwards: KubeForwards
    @ObservedObject package var settings: Settings
    @ObservedObject package var theme: ChromeTheme
    package let group: TabGroup?
    package let openPage: () -> Void
    /// File ▸ Open Folder…, offered with no checkout here (onboarding 7.5).
    package let openFolder: () -> Void
    /// So the header's tooltip follows a rebound key.
    @ObservedObject private var keys = Keybindings.shared

    package init(
        panel: KubernetesPanelModel, kubernetes: KubernetesModel, forwards: KubeForwards, settings: Settings, theme: ChromeTheme, group: TabGroup?,
        openPage: @escaping () -> Void, openFolder: @escaping () -> Void = {}
    ) {
        self.openFolder = openFolder
        self._panel = ObservedObject(wrappedValue: panel)
        self._kubernetes = ObservedObject(wrappedValue: kubernetes)
        self._forwards = ObservedObject(wrappedValue: forwards)
        self._settings = ObservedObject(wrappedValue: settings)
        self._theme = ObservedObject(wrappedValue: theme)
        self.group = group
        self.openPage = openPage
    }

    package var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Kubernetes", group: group, theme: theme, help: panel.checkout?.path) {
                if panel.binding != nil, panel.draft == nil {
                    PanelHeaderButton(symbol: "pencil", help: "Edit what this checkout is bound to", action: { panel.beginEdit() }, theme: theme)
                }
                PanelHeaderButton(symbol: "macwindow", help: KeyHints.help("The Kubernetes page", command: "kubernetes.page", keys: keys), action: openPage, theme: theme)
            }
            if !settings.bool("kubernetes.enabled") {
                note("Kubernetes is off in Settings.")
            } else if panel.checkout == nil {
                note("No checkout here: a tab in a repository shows what it deploys.")
                OpenFolderButton(theme: theme, identifier: "kubernetes.openFolder", action: openFolder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 8)
            } else if panel.draft != nil {
                KubeBindingForm(panel: panel, theme: theme)
            } else if let binding = panel.binding {
                bound(binding)
            } else if !panel.canBind {
                note("Not a repository's root: a tab in a git checkout can be bound to what it deploys.")
                OpenFolderButton(theme: theme, identifier: "kubernetes.openFolder", action: openFolder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 8)
            } else {
                unbound
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityIdentifier("kubernetes.panel")
    }

    // MARK: Unbound

    @ViewBuilder private var unbound: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This checkout isn't bound to a cluster.").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
            if panel.guessing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for Kubernetes files…").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                }
            } else if let guess = panel.guess, !guess.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Found \(guess.said)").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
                    if let release = guess.release { fact("release", release) }
                    if let namespace = guess.namespace { fact("namespace", namespace) }
                    if let selector = guess.selector { fact("labels", selector) }
                    if !guess.workloads.isEmpty { fact("workloads", guess.workloads.joined(separator: ", ")) }
                }
            } else if panel.guess != nil {
                Text("No chart, kustomization or manifest found in it.").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
            }
            Button {
                panel.beginEdit()
            } label: {
                Label("Bind to a Context and Namespace…", systemImage: "link").font(.system(size: ChromeMetrics.text(11.5)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accentText)
            .help("Kept in Overterm's own folder, never in the repository")
            .accessibilityIdentifier("kubernetes.panel.bind")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // What the rail had room for: the forwards running, and the pulse
        // of the page's context in the namespace the files name.
        let running = panel.forwards(forwards.forwards)
        if !running.isEmpty {
            section("Forwards")
            ForEach(running) { forward in forwardRow(forward) }
        }
        KubePulseSection(pulse: panel.pulse, theme: theme, openPage: openPage)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).frame(width: 64, alignment: .leading)
            Text(verbatim: value).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text).lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: Bound

    private func bound(_ binding: KubeBinding) -> some View {
        // A plain stack: what it holds is bounded (pods past `podLimit` are
        // the page's), and a lazy one, whose GitOps part is one tall child
        // that keeps changing height, was left drawing nothing at all after
        // the page had been opened and closed over it.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                scope(binding)
                if let release = binding.release { helmLine(release) }
                switch panel.state {
                case .failed(let reason):
                    Text(verbatim: reason).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(TabStatusStyle.failed).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 6)
                    Button("Try Again") { panel.retry() }
                        .controlSize(.small).padding(.horizontal, 12)
                        .accessibilityIdentifier("kubernetes.panel.retry")
                case .reading, .idle:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 12)
                case .live:
                    ForEach(panel.problems, id: \.self) { problem in
                        Text(verbatim: problem).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(TabStatusStyle.failed).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 2)
                    }
                    deployedLine
                    KubePanelGitOpsView(gitOps: panel.gitOps, theme: theme)
                    section("Workloads")
                    if panel.workloads.isEmpty { quiet("None here" + (binding.selector.map { " with \($0)" } ?? "")) }
                    ForEach(panel.workloads) { workload in workloadRow(workload) }
                    section("Pods")
                    if panel.pods.isEmpty { quiet("No pods") }
                    ForEach(panel.pods) { pod in podRow(pod) }
                    if panel.podsHidden > 0 {
                        Button {
                            openPage()
                        } label: {
                            Text(verbatim: "and \(panel.podsHidden) more on the page…").font(.system(size: ChromeMetrics.text(11.5)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                    let here = panel.forwards(forwards.forwards)
                    if !here.isEmpty {
                        section("Forwards")
                        ForEach(here) { forward in forwardRow(forward) }
                    }
                    KubePulseSection(pulse: panel.pulse, theme: theme, openPage: openPage)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func scope(_ binding: KubeBinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "⎈").font(.system(size: ChromeMetrics.text(12)))
                Text(verbatim: (panel.production ? "PRODUCTION · " : "") + binding.said)
                    .font(.system(size: ChromeMetrics.text(12), weight: .medium)).foregroundStyle(panel.production ? KubernetesPageView.production : theme.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let selector = binding.selector {
                Text(verbatim: selector).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityIdentifier("kubernetes.panel.scope")
    }

    /// The bound release and the checkout's chart: its diff, its upgrade.
    private func helmLine(_ release: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Button("Diff Chart") { panel.diffChart() }
                    .help("Diff Chart with Release: helm template of the checkout's chart with \(release)'s values — no cluster asked — against what the release has, masked, in the changes pane")
                    .accessibilityIdentifier("kubernetes.panel.helmDiff")
                Button("Upgrade…") { panel.upgradeChart() }
                    .help("helm upgrade \(release) from the checkout's chart, in a tab pinned to the context — after its diff, an access review and a confirmation")
                    .accessibilityIdentifier("kubernetes.panel.helmUpgrade")
            }
            .buttonStyle(.link)
            .font(.system(size: ChromeMetrics.text(11)))
            .disabled(panel.helmUpgrade?.state.isWorking == true)
            if let session = panel.helmUpgrade { KubeHelmUpgradeStatus(session: session, theme: theme) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// The last deploy against the checkout's commit.
    @ViewBuilder private var deployedLine: some View {
        if let headline = panel.headline {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: headline.answer.text).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.panel.deployed")
                if let source = headline.answer.sourceSaid {
                    Text(verbatim: "\(headline.workload.ref.said), \(source)").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let found = headline.answer.found, !found.isHead || found.elsewhere > 0 {
                        Button("Diff Deployed…Current") { panel.reviewDeployed(found) }
                            .help(KeyHints.help("A review tab", command: "review.branch", keys: keys) + ": what the checkout has that isn't deployed")
                            .accessibilityIdentifier("kubernetes.panel.diffDeployed")
                    }
                    if headline.answer.found == nil || headline.answer.found?.source != .revisionLabel {
                        Button(panel.lookingUp.contains(headline.workload.id) ? "Looking Up…" : "Look Up Revision") { panel.lookUp(headline.workload) }
                            .disabled(panel.lookingUp.contains(headline.workload.id))
                            .help("The image's org.opencontainers.image.revision through docker buildx imagetools, and the release's appVersion")
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: ChromeMetrics.text(11)))
                if let problem = panel.lookUpProblem {
                    Text(verbatim: problem).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func workloadRow(_ workload: KubernetesPanelModel.Workload) -> some View {
        HStack(spacing: 8) {
            Circle().fill(workload.failing ? TabStatusStyle.failed : TabStatusStyle.done).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: workload.ref.said).font(.system(size: ChromeMetrics.text(12.5))).foregroundStyle(theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: workload.health).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(workload.failing ? TabStatusStyle.failed : theme.text3)
                    if let found = panel.deployed[workload.id]?.found {
                        Text(verbatim: found.short).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                    } else if let tag = Self.tag(workload.images.first) {
                        // What runs, when no commit is known: its image's tag.
                        Text(verbatim: tag).font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, 12)
        .help(workload.images.joined(separator: "\n"))
    }

    /// `ghcr.io/acme/api:v1.4.2` → `:v1.4.2`; a digest → its first 12.
    package static func tag(_ image: String?) -> String? {
        guard let image else { return nil }
        if let at = image.firstIndex(of: "@") { return "@" + image[image.index(after: at)...].replacingOccurrences(of: "sha256:", with: "").prefix(12) }
        let name = image.split(separator: "/").last.map(String.init) ?? image
        guard let colon = name.lastIndex(of: ":") else { return nil }
        return String(name[colon...])
    }

    private func podRow(_ pod: KubernetesPanelModel.Pod) -> some View {
        let summary = pod.summary
        let failing = summary.isFailing || (summary.status == "Pending")
        return Button {
            panel.pick(pod.id)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(failing ? TabStatusStyle.failed : summary.isReady || summary.isCompleted ? TabStatusStyle.done : TabStatusStyle.waiting)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: pod.id.name).font(.system(size: ChromeMetrics.text(12.5))).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(verbatim: summary.status).foregroundStyle(failing ? TabStatusStyle.failed : theme.text3)
                        if let restarts = summary.restarts, restarts > 0 { Text(verbatim: "↻ \(restarts)").foregroundStyle(theme.text3) }
                    }
                    .font(.system(size: ChromeMetrics.text(10.5)))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(panel.picked == pod.id && panel.slotVisible ? theme.rowSel : .clear))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("In the right-hand pane: its log and Overview")
    }

    private func forwardRow(_ forward: KubeForward) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).frame(width: 10)
            Text(verbatim: ":\(forward.spec.localPort) → \(forward.pod ?? forward.spec.target.name)").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 12)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func quiet(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).padding(.horizontal, 12).padding(.top, 8)
    }
}

/// The binding being made or edited: the context picked, the namespace,
/// and optionally a release, a label selector and the workloads.
package struct KubeBindingForm: View {
    @ObservedObject package var panel: KubernetesPanelModel
    @ObservedObject package var theme: ChromeTheme

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(panel.binding == nil ? "Bind this checkout" : "This checkout's binding").font(.system(size: ChromeMetrics.text(12), weight: .semibold))
                .foregroundStyle(theme.text)
            Picker("Context", selection: field(\.context)) {
                ForEach(panel.contextNames, id: \.self) { Text(verbatim: $0).tag($0) }
                if !panel.contextNames.contains(panel.draft?.context ?? "") { Text(verbatim: panel.draft?.context ?? "").tag(panel.draft?.context ?? "") }
            }
            .controlSize(.small)
            labelled("Namespace", field(\.namespace), "shop")
            labelled("Release", optional(\.release), "a Helm release (optional)")
            labelled("Labels", optional(\.selector), "app.kubernetes.io/part-of=shop")
            labelled(
                "Workloads",
                Binding(
                    get: { panel.draft?.workloads.joined(separator: ", ") ?? "" },
                    set: { text in
                        panel.draft?.workloads = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }), "deploy/web, sts/db (empty: all)")
            if let problem = panel.store.problem { Text(verbatim: problem).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(TabStatusStyle.failed) }
            HStack(spacing: 8) {
                Button("Cancel") { panel.cancelEdit() }
                if panel.binding != nil { Button("Unbind") { panel.unbind() } }
                Spacer(minLength: 0)
                Button("Bind") { panel.saveDraft() }.keyboardShortcut(.defaultAction)
                    .disabled((panel.draft?.context ?? "").isEmpty || (panel.draft?.namespace ?? "").isEmpty)
                    .accessibilityIdentifier("kubernetes.panel.save")
            }
            .controlSize(.small)
            Text("Kept in Overterm's own folder, keyed by this checkout — nothing is written into the repository.")
                .font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("kubernetes.panel.form")
    }

    private func field(_ path: WritableKeyPath<KubeBinding, String>) -> Binding<String> {
        Binding(get: { panel.draft?[keyPath: path] ?? "" }, set: { panel.draft?[keyPath: path] = $0 })
    }

    private func optional(_ path: WritableKeyPath<KubeBinding, String?>) -> Binding<String> {
        Binding(get: { panel.draft?[keyPath: path] ?? "" }, set: { panel.draft?[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func labelled(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).controlSize(.small)
        }
    }
}

/// The pod picked in the rail's panel, in the right-hand pane: its log,
/// followed only while it shows, and its Overview — one GET.
package struct KubeSlotView: View {
    @ObservedObject package var panel: KubernetesPanelModel
    @ObservedObject package var theme: ChromeTheme
    package let runInTerminal: (String) -> Void

    package init(panel: KubernetesPanelModel, theme: ChromeTheme, runInTerminal: @escaping (String) -> Void) {
        self._panel = ObservedObject(wrappedValue: panel)
        self._theme = ObservedObject(wrappedValue: theme)
        self.runInTerminal = runInTerminal
    }

    package var body: some View {
        if let session = panel.session {
            KubeSlotPodView(panel: panel, session: session, theme: theme, runInTerminal: runInTerminal).id(session.id)
        } else {
            Text(panel.picked == nil ? "Pick a pod in the Kubernetes panel." : "Reading…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct KubeSlotPodView: View {
    @ObservedObject var panel: KubernetesPanelModel
    @ObservedObject var session: KubeDetailSession
    @ObservedObject var theme: ChromeTheme
    let runInTerminal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: "pod/\(session.ref.name)").font(.system(size: ChromeMetrics.text(12.5), weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Picker("", selection: Binding(get: { panel.slotTab }, set: { panel.pickTab($0) })) {
                    ForEach(KubernetesPanelModel.SlotTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(theme.border).frame(height: 1)
            switch panel.slotTab {
            case .logs:
                if let logs = session.logs {
                    LogsPane(feed: logs.feed, theme: theme, identifier: "kubernetes.slot.logs", runInTerminal: runInTerminal)
                }
            case .overview: overview
            }
        }
        .accessibilityIdentifier("kubernetes.slot")
    }

    @ViewBuilder private var overview: some View {
        switch session.state {
        case .failed(let reason):
            Text(verbatim: reason).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.failed).padding(12)
        case .loading, .withheld:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
        case .loaded:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.overview?.facts ?? []) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: item.label).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).frame(width: 90, alignment: .leading)
                            Text(verbatim: item.value).font(.system(size: ChromeMetrics.text(11.5), design: item.mono ? .monospaced : .default)).foregroundStyle(theme.text)
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(session.overview?.sections ?? []) { section in
                        Text(section.title).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3).padding(.top, 8)
                        ForEach(section.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: item.label).font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).frame(width: 90, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: item.value).font(.system(size: ChromeMetrics.text(11.5), design: item.mono ? .monospaced : .default)).foregroundStyle(theme.text)
                                    if let detail = item.detail {
                                        Text(verbatim: detail).font(.system(size: ChromeMetrics.text(10.5), design: item.detailMono ? .monospaced : .default)).foregroundStyle(theme.text3)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

/// The rail's pulse: the nodes' readiness on one line, then the last hour's
/// Warning events, newest first — a reason, what it is about, how often.
package struct KubePulseSection: View {
    @ObservedObject package var pulse: KubePanelPulse
    @ObservedObject package var theme: ChromeTheme
    package let openPage: () -> Void

    package var body: some View {
        if pulse.scope != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("WARNINGS").font(.system(size: ChromeMetrics.text(10), weight: .semibold)).foregroundStyle(theme.text3)
                    if !pulse.warnings.isEmpty {
                        Text(verbatim: "\(pulse.warnings.count)").font(.system(size: ChromeMetrics.text(10), weight: .semibold))
                            .foregroundStyle(theme.orangeText)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 2)
                if let scope = pulse.scope {
                    Text(verbatim: scope + " · last hour").font(.system(size: ChromeMetrics.text(10), design: .monospaced)).foregroundStyle(theme.text3)
                        .lineLimit(1).truncationMode(.middle).padding(.horizontal, 12).padding(.bottom, 4)
                }
                if let problem = pulse.problem {
                    Text(verbatim: problem).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
                } else if pulse.warnings.isEmpty {
                    Text("None — quiet.").font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).padding(.horizontal, 12)
                }
                ForEach(pulse.warnings.prefix(KubePanelPulse.shown)) { warning in row(warning) }
                if pulse.warnings.count > KubePanelPulse.shown {
                    Button(action: openPage) {
                        Text(verbatim: "and \(pulse.warnings.count - KubePanelPulse.shown) more on the page…").font(.system(size: ChromeMetrics.text(11.5)))
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.accentText).padding(.horizontal, 12).padding(.vertical, 2)
                }
            }
            .accessibilityIdentifier("kubernetes.panel.warnings")
        }
    }

    private func row(_ warning: KubeClusterOverview.Warning) -> some View {
        Button(action: openPage) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: warning.reason).font(.system(size: ChromeMetrics.text(11.5), weight: .medium)).foregroundStyle(theme.orangeText)
                        .lineLimit(1)
                    if let count = warning.count, count > 1 {
                        Text(verbatim: "×\(count)").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                    }
                    Spacer(minLength: 4)
                    if let age = warning.age {
                        Text(verbatim: KubeAge.format(age)).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3)
                    }
                }
                Text(verbatim: warning.object).font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text2)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: warning.message).font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(warning.message)
    }
}
