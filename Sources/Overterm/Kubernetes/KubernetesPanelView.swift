import SwiftUI

/// The rail's Kubernetes panel (Section 6): the selected tab's checkout,
/// what it is bound to (3.1) — or what its files suggest, to bind it —
/// the bound namespace's workloads and pods with their health, the
/// forwards there, and the deployed commit against the checkout's (3.2).
/// A pod clicked shows in the right slot.
struct KubernetesPanelView: View {
    @ObservedObject var panel: KubernetesPanelModel
    @ObservedObject var kubernetes: KubernetesModel
    @ObservedObject var forwards: KubeForwards
    @ObservedObject var settings: Settings
    @ObservedObject var theme: ChromeTheme
    let group: TabGroup?
    let openPage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Kubernetes", group: group, theme: theme, help: panel.checkout?.path) {
                if panel.binding != nil, panel.draft == nil {
                    PanelHeaderButton(symbol: "pencil", help: "Edit what this checkout is bound to", action: { panel.beginEdit() }, theme: theme)
                }
                PanelHeaderButton(symbol: "macwindow", help: "The Kubernetes page (⌥⌘J)", action: openPage, theme: theme)
            }
            if !settings.bool("kubernetes.enabled") {
                note("Kubernetes is off in Settings.")
            } else if panel.checkout == nil {
                note("No checkout here: a tab in a repository shows what it deploys.")
            } else if panel.draft != nil {
                KubeBindingForm(panel: panel, theme: theme)
            } else if let binding = panel.binding {
                bound(binding)
            } else if !panel.canBind {
                note("Not a repository's root: a tab in a git checkout can be bound to what it deploys.")
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

    private var unbound: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This checkout isn't bound to a cluster.").font(.system(size: 12)).foregroundStyle(theme.text2)
            if panel.guessing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for Kubernetes files…").font(.system(size: 11.5)).foregroundStyle(theme.text3)
                }
            } else if let guess = panel.guess, !guess.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Found \(guess.said)").font(.system(size: 11.5)).foregroundStyle(theme.text2)
                    if let release = guess.release { fact("release", release) }
                    if let namespace = guess.namespace { fact("namespace", namespace) }
                    if let selector = guess.selector { fact("labels", selector) }
                    if !guess.workloads.isEmpty { fact("workloads", guess.workloads.joined(separator: ", ")) }
                }
            } else if panel.guess != nil {
                Text("No chart, kustomization or manifest found in it.").font(.system(size: 11.5)).foregroundStyle(theme.text3)
            }
            Button {
                panel.beginEdit()
            } label: {
                Label("Bind to a Context and Namespace…", systemImage: "link").font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accentText)
            .help("Kept in Overterm's own folder, never in the repository")
            .accessibilityIdentifier("kubernetes.panel.bind")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(theme.text3).frame(width: 64, alignment: .leading)
            Text(verbatim: value).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text).lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: Bound

    private func bound(_ binding: KubeBinding) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                scope(binding)
                if let release = binding.release { helmLine(release) }
                switch panel.state {
                case .failed(let reason):
                    Text(verbatim: reason).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 6)
                    Button("Try Again") { panel.retry() }
                        .controlSize(.small).padding(.horizontal, 12)
                        .accessibilityIdentifier("kubernetes.panel.retry")
                case .reading, .idle:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 12)
                case .live:
                    ForEach(panel.problems, id: \.self) { problem in
                        Text(verbatim: problem).font(.system(size: 10.5)).foregroundStyle(TabStatusStyle.failed).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 2)
                    }
                    deployedLine
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
                            Text(verbatim: "and \(panel.podsHidden) more on the page…").font(.system(size: 11.5))
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
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func scope(_ binding: KubeBinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "⎈").font(.system(size: 12))
                Text(verbatim: (panel.production ? "PRODUCTION · " : "") + binding.said)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(panel.production ? KubernetesPageView.production : theme.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let selector = binding.selector {
                Text(verbatim: selector).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1)
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
            .font(.system(size: 11))
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
                Text(verbatim: headline.answer.text).font(.system(size: 11.5)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kubernetes.panel.deployed")
                if let source = headline.answer.sourceSaid {
                    Text(verbatim: "\(headline.workload.ref.said), \(source)").font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let found = headline.answer.found, !found.isHead || found.elsewhere > 0 {
                        Button("Diff Deployed…Current") { panel.reviewDeployed(found) }
                            .help("A review tab (⇧⌘R): what the checkout has that isn't deployed")
                            .accessibilityIdentifier("kubernetes.panel.diffDeployed")
                    }
                    if headline.answer.found == nil || headline.answer.found?.source != .revisionLabel {
                        Button(panel.lookingUp.contains(headline.workload.id) ? "Looking Up…" : "Look Up Revision") { panel.lookUp(headline.workload) }
                            .disabled(panel.lookingUp.contains(headline.workload.id))
                            .help("The image's org.opencontainers.image.revision through docker buildx imagetools, and the release's appVersion")
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                if let problem = panel.lookUpProblem {
                    Text(verbatim: problem).font(.system(size: 10.5)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
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
                Text(verbatim: workload.ref.said).font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: workload.health).font(.system(size: 10.5)).foregroundStyle(workload.failing ? TabStatusStyle.failed : theme.text3)
                    if let found = panel.deployed[workload.id]?.found {
                        Text(verbatim: found.short).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3)
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
                    Text(verbatim: pod.id.name).font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(verbatim: summary.status).foregroundStyle(failing ? TabStatusStyle.failed : theme.text3)
                        if let restarts = summary.restarts, restarts > 0 { Text(verbatim: "↻ \(restarts)").foregroundStyle(theme.text3) }
                    }
                    .font(.system(size: 10.5))
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
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(theme.text3).frame(width: 10)
            Text(verbatim: ":\(forward.spec.localPort) → \(forward.pod ?? forward.spec.target.name)").font(.system(size: 12)).foregroundStyle(theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 12)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func quiet(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11.5)).foregroundStyle(theme.text3).padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.text2).padding(.horizontal, 12).padding(.top, 8)
    }
}

/// The binding being made or edited: the context picked, the namespace,
/// and optionally a release, a label selector and the workloads.
struct KubeBindingForm: View {
    @ObservedObject var panel: KubernetesPanelModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(panel.binding == nil ? "Bind this checkout" : "This checkout's binding").font(.system(size: 12, weight: .semibold))
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
            if let problem = panel.store.problem { Text(verbatim: problem).font(.system(size: 10.5)).foregroundStyle(TabStatusStyle.failed) }
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
                .font(.system(size: 10.5)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
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
            Text(label).font(.system(size: 10.5)).foregroundStyle(theme.text3)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced)).controlSize(.small)
        }
    }
}

/// The pod picked in the rail's panel, in the right-hand pane: its log,
/// followed only while it shows, and its Overview — one GET.
struct KubeSlotView: View {
    @ObservedObject var panel: KubernetesPanelModel
    @ObservedObject var theme: ChromeTheme
    let runInTerminal: (String) -> Void

    var body: some View {
        if let session = panel.session {
            KubeSlotPodView(panel: panel, session: session, theme: theme, runInTerminal: runInTerminal).id(session.id)
        } else {
            Text(panel.picked == nil ? "Pick a pod in the Kubernetes panel." : "Reading…").font(.system(size: 12)).foregroundStyle(theme.text3)
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
                Text(verbatim: "pod/\(session.ref.name)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
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
            Text(verbatim: reason).font(.system(size: 11.5)).foregroundStyle(TabStatusStyle.failed).padding(12)
        case .loading, .withheld:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
        case .loaded:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.overview?.facts ?? []) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: item.label).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 90, alignment: .leading)
                            Text(verbatim: item.value).font(.system(size: 11.5, design: item.mono ? .monospaced : .default)).foregroundStyle(theme.text)
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(session.overview?.sections ?? []) { section in
                        Text(section.title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3).padding(.top, 8)
                        ForEach(section.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: item.label).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 90, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: item.value).font(.system(size: 11.5, design: item.mono ? .monospaced : .default)).foregroundStyle(theme.text)
                                    if let detail = item.detail {
                                        Text(verbatim: detail).font(.system(size: 10.5, design: item.detailMono ? .monospaced : .default)).foregroundStyle(theme.text3)
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
