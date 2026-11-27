import AppKit
import Combine

/// A Terraform run that ends while nobody looks says so (TF-U6): a plan, a
/// drift check, an init, an apply or a test of a checkout marks that
/// checkout's tab and sends one notification — unless its window is in
/// front with the run in the right slot. Overterm's words only
/// (`TerraformRunEnd`): never terraform's output.
extension TerminalWindowController {
    /// Runs already said, across windows: one notification a run.
    @MainActor private static var announced: Set<String> = []

    package func wireTerraformRunEnds() {
        TerraformRunRegistry.shared.$runs
            .sink { [weak self] runs in runs.forEach { self?.follow($0) } }
            .store(in: &cancellables)
        TerraformRunRegistry.shared.$applies
            .sink { [weak self] applies in applies.forEach { self?.follow($0) } }
            .store(in: &cancellables)
        TerraformTestResults.shared.$runs
            .sink { [weak self] runs in runs.forEach { self?.follow($0) } }
            .store(in: &cancellables)
    }

    private func follow(_ run: TerraformPlanRun) {
        guard terraformRunWatches[run.id] == nil else { return }
        terraformRunWatches[run.id] = run.$phase.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self, weak run] _ in
                guard let self, let run else { return }
                let end = TerraformRunEnd.plan(
                    run.phase, root: run.card.name, workspace: run.card.workspace, kind: run.kind, refreshOnly: run.mode.isRefreshOnly,
                    counts: run.plan?.counts.bar)
                self.announce(end, id: run.id, checkout: run.checkout, showing: self.terraformPlanPane.run === run)
            }
    }

    private func follow(_ apply: TerraformApplyRun) {
        guard terraformRunWatches[apply.id] == nil else { return }
        terraformRunWatches[apply.id] = apply.$phase.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self, weak apply] _ in
                guard let self, let apply else { return }
                let end = TerraformRunEnd.apply(apply.phase, root: apply.marker.name, workspace: apply.marker.workspace)
                self.announce(
                    end, id: apply.id, checkout: URL(fileURLWithPath: apply.marker.checkout), showing: self.terraformPlanPane.apply === apply)
            }
    }

    private func follow(_ test: TerraformTestRun) {
        guard terraformRunWatches[test.id] == nil else { return }
        terraformRunWatches[test.id] = test.$phase.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self, weak test] _ in
                guard let self, let test else { return }
                let end = TerraformRunEnd.test(test.phase, root: test.card.name)
                self.announce(end, id: test.id, checkout: test.checkout, showing: self.terraformPlanPane.test === test)
            }
    }

    /// The end said on the checkout's tab in this window — the selected
    /// one when it is the checkout's — once a run across windows.
    private func announce(_ end: TerraformRunEnd?, id: String, checkout: URL, showing: Bool) {
        guard let end, !Self.announced.contains(id), let tab = terraformTab(for: checkout) else { return }
        let looking =
            NSApp.isActive && window?.isKeyWindow == true && showing && rightPane.mode == .terraformPlan && diffItem?.isCollapsed == false
        Self.announced.insert(id)
        if let recorder = terraformRunEndRecorder { recorder(end, tab, looking) }
        guard tab.activity.terraformRunEnded(end.text, failed: end.failed, visible: looking) else { return }
        notifyUnlessHeld(tab, note: end.text, mark: end.failed ? .failed : .done)
        updateAttentionBadge()
    }

    /// The tab a checkout's run is about: the selected one when it is in
    /// that checkout, else the first that is.
    package func terraformTab(for checkout: URL) -> Tab? {
        let path = checkout.standardizedFileURL.path
        func inside(_ tab: Tab) -> Bool { tab.checkoutSource?.root.standardizedFileURL.path == path }
        if let selected = store.selected, inside(selected) { return selected }
        return store.tabs.first(where: inside)
    }
}

// MARK: The changes pane's roots (TF-G1)

extension TerminalWindowController {
    /// Read again as the changes or the pane's visibility move, a moment
    /// after they settle — only while the pane shows changes, and only
    /// when a changed file is Terraform's: one `git ls-files`, the touched
    /// roots' files (`TerraformReviewModel.read`). Git isn't asked for the
    /// changes again: they are the pane's own.
    package func wireChangesTerraform() {
        diff.$files.map { _ in () }
            .merge(with: diff.$branchFiles.map { _ in () }, rightPane.$mode.map { _ in () })
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.readChangesTerraform() }
            .store(in: &cancellables)
    }

    package func readChangesTerraform() {
        let showing = rightPane.mode == .changes && diffItem?.isCollapsed == false
        let changed = TerraformReview.changedPaths(diff.shownFiles)
        guard showing, Settings.shared.bool("terraform.enabled"), let root = diff.root,
            changed.contains(where: { TerraformRootGuess.isTerraformName(($0 as NSString).lastPathComponent) })
        else {
            if !changesTerraform.roots.isEmpty { changesTerraform.clear() }
            return
        }
        // The same paths in the same checkout: nothing new to read.
        if changesTerraform.readCheckout == root, changesTerraform.changed == changed, changesTerraform.state != .idle { return }
        changesTerraform.read(changed: changed, checkout: root, head: nil)
    }

    /// Plan, from the line: the root's card as the read found it, asked
    /// as the panel's Plan asks.
    package func planChangedTerraformRoot(_ root: TerraformReview.Root) {
        guard let card = changesTerraform.cards[root.path], let checkout = changesTerraform.readCheckout else { return NSSound.beep() }
        planTerraformRoot(card, checkout: checkout)
    }
}
