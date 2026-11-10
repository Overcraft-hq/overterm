import AppKit
import Combine

// MARK: The rail's Kubernetes panel and the right slot (docs/design/kubernetes/analysis.md, Section 6, 3.1–3.2)

extension TerminalWindowController {
    /// The panel follows the selected tab's checkout and reads only while
    /// it is the panel on screen; a pod picked takes the right slot.
    func wireKubernetesPanel() {
        kubernetesPanel.openReview = { [weak self] source, root in self?.openReview(source, in: root) }
        kubernetesPanel.helmHost = self
        kubernetesPanel.gitOpsHost = self
        kubernetesPanel.showSlot = { [weak self] in self?.showKubernetesSlot() }
        diff.$root
            .combineLatest(store.$selectedID)
            .sink { [weak self] root, _ in
                // @Published fires before the value lands; the root given is the new one.
                DispatchQueue.main.async { self?.updateKubernetesCheckout(root: root) }
            }
            .store(in: &cancellables)
        sidebarPanel.$panel
            .sink { [weak self] panel in DispatchQueue.main.async { self?.updateKubernetesPanelVisibility(panel: panel) } }
            .store(in: &cancellables)
        // An agent's `k8s_` call: its pane's tab's checkout, in any window.
        KubeMCP.paneCheckout = { tag in
            for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                if let tab = controller.store.tabs.first(where: { $0.terminals.contains { $0.processTag == tag } }) {
                    return tab.checkoutSource?.root
                }
            }
            return nil
        }
    }

    /// The selected tab's checkout, as the diff, Ask Why and agents'
    /// tools (`KubeMCP.paneCheckout`) have it: `Tab.checkoutSource`'s root
    /// — an attached checkout, else where its agent works, else the shell's.
    var kubernetesCheckout: URL? { store.selected?.checkoutSource?.root }

    /// `root` (the diff's, which follows the same) only says when to look again.
    func updateKubernetesCheckout(root _: URL?) {
        let folder = kubernetesCheckout
        if kubernetesPanel.checkout != folder { kubernetesPanel.checkout = folder }
    }

    /// On screen: the sidebar open on the panel, Kubernetes on, the window
    /// itself visible (a covered or minimized one reads nothing).
    func updateKubernetesPanelVisibility(panel: SidebarPanel? = nil) {
        let shown =
            sidebarItem?.isCollapsed == false && (panel ?? sidebarPanel.panel) == .kubernetes && Settings.shared.kubernetesEnabled
            && kubernetesPage.windowVisible && window != nil
        if kubernetesPanel.panelVisible != shown { kubernetesPanel.panelVisible = shown }
        // The right slot's pod reads only while the window is on screen too.
        let window = kubernetesPage.windowVisible && self.window != nil
        if kubernetesPanel.windowVisible != window { kubernetesPanel.windowVisible = window }
    }

    /// The rail's helm: the sidebar, on the Kubernetes panel.
    @objc func showKubernetesPanel(_ sender: Any?) {
        guard Settings.shared.kubernetesEnabled else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .kubernetes
        updateKubernetesPanelVisibility(panel: .kubernetes)
    }

    /// The pod picked, in the right-hand pane — which takes the slot (`RightSlot`).
    func showKubernetesSlot() {
        rightPane.kubernetesOpened = true
        rightPane.mode = .kubernetes
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    func kubernetesPanelSettingsChanged() {
        if !Settings.shared.kubernetesEnabled {
            if sidebarPanel.panel == .kubernetes { sidebarPanel.panel = .files }
            if rightPane.mode == .kubernetes { rightPane.mode = .changes }
            rightPane.kubernetesOpened = false
        }
        // The rail lists its icons from the setting: drawn again.
        sidebarPanel.objectWillChange.send()
        updateKubernetesPanelVisibility()
        // The attention watches follow kubernetes.notifyOnFailure and backgroundWatches.
        reportKubernetesCheckouts()
        KubeAttentionWatches.shared.refresh()
    }

    /// The agents Ask Why's brief is offered to, in order: the agents in a
    /// tab of the checkout bound to the brief's namespace (3.4) — it has
    /// the code that failed — then the selected tab's, then the window's others.
    func kubernetesBriefTargets(_ brief: KubeAgentBrief) -> [Tab] {
        let bound = Set(
            KubeBindingStore.shared.bindings(on: brief.context, namespace: brief.namespace).map(\.checkout) + [brief.checkout].compactMap { $0 })
        return KubeBriefTargets.ordered(
            store.tabs.filter { $0.agent != nil }, selected: store.selected, checkout: { $0.checkoutSource.map { KubeBindingStore.key($0.root) } },
            bound: bound, first: brief.checkout)
    }
}

// MARK: The rail's GitOps part, through the page's guard path (gitops.md 4.5)

extension TerminalWindowController: KubeGitOpsPanelHost {
    /// The page's contexts, read when they weren't: `write` and its checks
    /// find the context there (a few seconds at most, else the page says
    /// it has no such context).
    private func kubernetesContextsLoaded() async {
        let model = kubernetesPage.model
        guard !model.contextsRead else { return }
        model.reloadContexts()
        for _ in 0..<50 where !model.contextsRead { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func gitOpsWrite(_ verb: KubeWriteVerb, on ref: KubeObjectRef) async {
        await kubernetesContextsLoaded()
        kubernetesPage.write(verb, on: ref)
    }

    func gitOpsTabWrite(_ verb: KubeProcessVerb, on ref: KubeObjectRef) async {
        await kubernetesContextsLoaded()
        kubernetesPage.runTabWrite(verb, on: ref)
    }

    /// The page on the binding's context, the object's list and its detail.
    func gitOpsOpenOnPage(_ ref: KubeObjectRef) async {
        await kubernetesContextsLoaded()
        let model = kubernetesPage.model
        if model.selectedName != ref.context { model.select(ref.context) }
        showKubernetesPage()
        for _ in 0..<100 where model.selectedName != ref.context || model.catalog.kind(fullName: ref.kind.fullName) == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        kubernetesPage.openFromOverview(kind: ref.kind.fullName, KubeRowID(namespace: ref.namespace, name: ref.name), from: .gitops)
    }

    func gitOpsAskWhy(_ ref: KubeObjectRef) async {
        await kubernetesContextsLoaded()
        kubernetesPage.askWhy(ref)
    }

    var gitOpsWriteStatus: AnyPublisher<KubeWriteStatus?, Never> { kubernetesPage.$writeStatus.eraseToAnyPublisher() }
}
