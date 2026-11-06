import AppKit
import Combine

// MARK: Attention marks (docs/design/kubernetes/analysis.md, 3.13)

extension TerminalWindowController {
    /// The window's tabs' checkouts told to the attention watches (which
    /// follow only those with a tab open); their marks put on the bound
    /// checkout's tab, and "not watched" said where its failures can't mark it.
    func wireKubernetesAttention() {
        let attention = KubeAttentionWatches.shared
        store.$tabs
            .combineLatest(store.$selectedID, diff.$root)
            .sink { [weak self] _, _, _ in
                // @Published fires before the value lands: looked at once it has.
                DispatchQueue.main.async { self?.reportKubernetesCheckouts() }
            }
            .store(in: &cancellables)
        attention.events
            .sink { [weak self] event in self?.applyKubernetesAttention(event) }
            .store(in: &cancellables)
        attention.$states
            .sink { [weak self] states in DispatchQueue.main.async { self?.updateKubernetesNotWatched(states) } }
            .store(in: &cancellables)
    }

    /// A tab's checkout as a binding is keyed: its real path.
    func kubernetesCheckoutKey(_ tab: Tab) -> String? { tab.checkoutSource.map { KubeBindingStore.key($0.root) } }

    /// Which checkouts have a tab here, and the selected tab's — nothing
    /// while the marks are off, so nothing is followed for them.
    func reportKubernetesCheckouts() {
        let attention = KubeAttentionWatches.shared
        guard Settings.shared.kubernetesNotifyOnFailure else {
            attention.report(ObjectIdentifier(self), open: [], selected: nil)
            return
        }
        let open = Set(store.tabs.compactMap(kubernetesCheckoutKey))
        attention.report(ObjectIdentifier(self), open: open, selected: store.selected.flatMap(kubernetesCheckoutKey))
    }

    /// The window is going: its checkouts no longer keep watches open.
    func forgetKubernetesCheckouts() {
        KubeAttentionWatches.shared.forget(ObjectIdentifier(self))
    }

    /// A scope's marks: each raised one on the checkout's tab — the
    /// selected one when it is the checkout's, else its agent's (Ask Why
    /// goes there), else the first —; cleared ones taken off every tab of
    /// it, the mark itself once nothing behind it stands.
    func applyKubernetesAttention(_ event: KubeAttentionWatches.Event) {
        let keys = Set(event.checkouts)
        let tabs = store.tabs.filter { kubernetesCheckoutKey($0).map(keys.contains) == true }
        guard !tabs.isEmpty else { return }
        if !event.change.cleared.isEmpty {
            let gone = Set(event.change.cleared.map(\.id))
            for tab in tabs where tab.kubeAlerts.contains(where: { gone.contains($0.id) }) {
                tab.kubeAlerts.removeAll { gone.contains($0.id) }
                guard tab.kubeAlerts.isEmpty else { continue }
                if tab.activity.clusterRecovered() { AttentionNotifier.withdraw(tab: tab) } else { AttentionNotifier.withdrawSide(tab: tab) }
            }
        }
        for alert in event.change.raised {
            for key in keys {
                let mine = tabs.filter { kubernetesCheckoutKey($0) == key }
                guard
                    let tab = mine.first(where: { $0 === store.selected }) ?? mine.first(where: { $0.agent != nil }) ?? mine.first
                else { continue }
                tab.kubeAlerts.removeAll { $0.id == alert.id }
                tab.kubeAlerts.insert(alert, at: 0)
                markClusterFailure(alert.note, on: tab)
            }
        }
        kubernetesAttentionChanged()
    }

    /// Each tab's "not watched": its checkout's state, when it has one.
    func updateKubernetesNotWatched(_ states: [String: KubeAttentionWatches.State]) {
        for tab in store.tabs {
            let why = kubernetesCheckoutKey(tab).flatMap { states[$0]?.notWatched }
            if tab.kubeNotWatched != why { tab.kubeNotWatched = why }
        }
    }

    /// Ask Why on a tab's mark: the brief of what failed last there —
    /// GETs through the context's proxy in a background slot, no Secret,
    /// scrubbed (`KubeAgentBriefing`), the checkout's deployed commit with
    /// it — in the Ask Agent sheet, that tab's agent first.
    func askWhy(onMarkOf tab: Tab) {
        guard let alert = tab.kubeAlerts.first else { return NSSound.beep() }
        let model = KubernetesModel.shared
        let checkout = tab.checkoutSource?.root
        kubernetesAttentionProblem = nil
        Task { @MainActor [weak self] in
            guard let list = await model.contextsForAgents(), let context = list.context(named: alert.ref.context) else {
                self?.reportKubernetesAttention("Kubernetes is off, or \(alert.ref.context) is no longer in the kubeconfig.")
                return
            }
            let said = KubeBriefContext(name: context.name, production: context.isProduction, writable: context.isWritable)
            do {
                var brief = try await KubeAgentBriefing.brief(
                    alert.ref, client: model.attentionClient(for: context), context: said, discovery: model.knownDiscovery(of: context))
                if let checkout { brief = await KubeAgentBriefing.withDeployedCommit(brief, checkout: checkout) }
                guard let self else { return }
                if let recorder = self.kubernetesBriefRecorder { return recorder(brief, tab) }
                self.presentKubernetesBrief(brief, preferring: tab)
            } catch {
                let why = (error as? KubeBriefProblem)?.description ?? KubernetesModel.said(error)
                self?.reportKubernetesAttention("Couldn't read \(alert.object) for Ask Why: \(why)")
            }
        }
    }

    private func reportKubernetesAttention(_ problem: String) {
        kubernetesAttentionProblem = problem
        guard !AppEnvironment.isIsolated, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Ask Why"
        alert.informativeText = problem
        alert.beginSheetModal(for: window) { _ in }
    }

    /// The tab menu's item for a mark: Ask an Agent Why… about what failed last.
    func kubernetesAttentionMenuItem(for tab: Tab) -> NSMenuItem? {
        guard let alert = tab.kubeAlerts.first else { return nil }
        return ClosureMenuItem("Ask an Agent Why… (\(alert.object) \(alert.reason))") { [weak self] in self?.askWhy(onMarkOf: tab) }
    }
}

// MARK: A bound release upgraded from the checkout's chart (stage 3a)

extension TerminalWindowController: KubeHelmUpgradeHost {
    func askHelmUpgrade(_ confirmation: KubeWriteConfirmation) async -> String? {
        guard let window else { return nil }
        return await WriteConfirmation(
            title: confirmation.title, scope: confirmation.scope, production: confirmation.production, detail: confirmation.detail,
            button: confirmation.button, typedName: confirmation.typedName, critical: confirmation.production || confirmation.typedName != nil
        ).ask(on: window)
    }

    func askHelmUpgrade(_ title: String, _ detail: String, _ button: String) async -> Bool {
        guard let window else { return false }
        return await WriteConfirmation.splittingProduction(title: title, detail: detail, button: button).ask(on: window) != nil
    }

    /// The diff in the right-hand pane, where a manifest's diff shows.
    func showHelmDiff(_ session: KubeHelmUpgradeSession) {
        kubernetesManifest.helm = session
        kubernetesManifest.showsHelm = true
        rightPane.manifestOpened = true
        rightPane.mode = .manifest
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    func runHelmUpgrade(_ command: String, in context: KubeContext, namespace: String) {
        runKubernetesCommand(command, in: context, namespace: namespace)
    }
}
