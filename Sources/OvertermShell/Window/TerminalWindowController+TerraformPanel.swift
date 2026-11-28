import AppKit
import Combine

// MARK: The rail's Terraform panel and its switcher (docs/design/terraform/analysis.md 6.1, 7)

extension TerminalWindowController {
    /// The panel follows the selected tab's checkout and reads only while it
    /// is the panel on screen; the diff's watcher tells it what changed
    /// (no second watcher, CLAUDE.md), the diff's files what this branch touches.
    package func wireTerraformPanel() {
        diff.$root
            .combineLatest(store.$selectedID)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateTerraformCheckout() } }
            .store(in: &cancellables)
        sidebarPanel.$panel
            .sink { [weak self] panel in DispatchQueue.main.async { self?.updateTerraformPanelVisibility(panel: panel) } }
            .store(in: &cancellables)
        diff.changes
            .sink { [weak self] paths in self?.terraformPanel.filesChanged(paths) }
            .store(in: &cancellables)
        // @Published emits the new values before they land: those are used.
        diff.$files.combineLatest(diff.$branchFiles)
            .map { files, branch in Array(Set(files.map(\.path) + branch.map(\.path))).sorted() }
            .removeDuplicates()
            .sink { [weak self] changed in self?.terraformPanel.changedFiles = changed }
            .store(in: &cancellables)
        // The repository's other worktrees, as the window lists them: no
        // second `git worktree list` (CLAUDE.md).
        worktrees.$worktrees
            .sink { [weak self] listed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.terraformPanel.setOtherWorktrees(TerraformWorktree.comparedWith(listed, of: self.terraformPanel.checkout))
                }
            }
            .store(in: &cancellables)
        // The chip's branch @ commit, as the diff has them (6.2).
        diff.$branch.combineLatest(diff.$head)
            .map { branch, head -> String? in
                guard branch != nil || head != nil else { return nil }
                return [branch, head.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " @ ")
            }
            .removeDuplicates()
            .sink { [weak self] label in self?.terraformPanel.branchLabel = label }
            .store(in: &cancellables)
        // ⌃⌘E opened before the read landed: its rows come when the roots do.
        terraformPanel.$roots
            .map { $0.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.restockPalette() } }
            .store(in: &cancellables)
        TerraformPaneMonitor.shared.start()
    }

    /// The selected tab's checkout, as the diff and the other panels have it.
    package var terraformCheckout: URL? { store.selected?.checkoutSource?.root }

    package func updateTerraformCheckout() {
        let folder = terraformCheckout
        if terraformPanel.checkout?.standardizedFileURL != folder?.standardizedFileURL {
            terraformPanel.setOtherWorktrees(TerraformWorktree.comparedWith(worktrees.worktrees, of: folder), read: false)
            terraformPanel.checkout = folder
        }
    }

    /// On screen: the sidebar open on the panel, Terraform on, the window visible.
    package func updateTerraformPanelVisibility(panel: SidebarPanel? = nil) {
        let shown =
            sidebarItem?.isCollapsed == false && (panel ?? sidebarPanel.panel) == .terraform && Settings.shared.terraformEnabled
            && kubernetesPage.windowVisible && window != nil
        if terraformPanel.panelVisible != shown { terraformPanel.panelVisible = shown }
    }

    /// ⌥⌘E: the sidebar, on the Terraform panel.
    @objc package func showTerraformPanel(_ sender: Any?) {
        guard Settings.shared.terraformEnabled else { return openSettings(.terraform) }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .terraform
        updateTerraformPanelVisibility(panel: .terraform)
    }

    /// ⌃⌘E: the palette on the roots — the selected checkout's, then the
    /// other checkouts' the rail has read.
    @objc package func showTerraformSwitcher(_ sender: Any?) {
        guard Settings.shared.terraformEnabled else { return openSettings(.terraform) }
        // The roots are listed by the panel's read; asked for here when none was.
        if terraformPanel.roots.isEmpty, terraformPanel.checkout != nil { terraformPanel.readNow() }
        togglePalette(scope: .terraform)
    }

    /// Terminal in Terraform Root…: the switcher, its ⌥↩ the terminal.
    @objc package func openTerraformTerminalPicker(_ sender: Any?) {
        showTerraformSwitcher(sender)
    }

    package func terraformPanelSettingsChanged() {
        if !Settings.shared.terraformEnabled, sidebarPanel.panel == .terraform { sidebarPanel.panel = .files }
        sidebarPanel.objectWillChange.send()
        updateTerraformPanelVisibility()
        // A class may have changed: read again where shown.
        terraformPanel.refresh()
    }

    package var terraformPanelActions: TerraformPanelActions {
        TerraformPanelActions(
            openTerminal: { [weak self] card in self?.openTerraformTerminal(card) },
            openFile: { [weak self] url in self?.openInEditor(url) },
            validate: { [weak self] card in self?.validateTerraformRoot(card) },
            plan: { [weak self] card in self?.planTerraformRoot(card) },
            initialize: { [weak self] card in self?.initTerraformRoot(card) },
            chooseWorkspace: { [weak self] card in self?.chooseTerraformWorkspace(card) },
            showPlan: { [weak self] run in self?.showTerraformPlan(run) },
            planDestroy: { [weak self] card in self?.planTerraformDestroy(card) },
            showApply: { [weak self] apply in self?.showTerraformApply(apply) },
            showState: { [weak self] card in self?.showTerraformState(card) },
            checkDrift: { [weak self] card in self?.checkTerraformDrift(card) },
            test: { [weak self] card in self?.testTerraformRoot(card) },
            showTest: { [weak self] run in self?.showTerraformTest(run) },
            chooseVarFiles: { [weak self] card in self?.chooseTerraformVarFiles(card) },
            typeInTerminal: { [weak self] card, line in self?.openTerraformTerminal(card, typing: line) },
            openFileAt: { [weak self] url, line in self?.openInEditor(url, line: line) },
            openURL: { [weak self] url in self?.openInBrowser(url, for: self?.store.selected) },
            openFolder: { [weak self] in self?.openFolder(nil) })
    }

    /// Terminal in this root (4.9): a shell tab at the root, its icon and
    /// header saying the root; no `TF_WORKSPACE` — the root's own
    /// `.terraform/environment` selects, as for any terminal there.
    /// `typing`: the line a sentence that says "in a terminal" means
    /// (`TerraformTerminalLine`, TF-U2), typed and never run.
    @discardableResult
    package func openTerraformTerminal(_ card: TerraformRootCard, typing: String? = nil) -> Tab? {
        openTerraformTerminal(in: card.folder, name: card.name, typing: typing)
    }

    @discardableResult
    package func openTerraformTerminal(in folder: URL, name: String, typing: String? = nil) -> Tab? {
        guard let tab = newTab(in: folder, environment: [:], kubePin: nil, typing: typing) else { return nil }
        for pane in tab.terminals { pane.terraformRoot = name }
        tab.objectWillChange.send()
        return tab
    }

    /// The root's validate, from its card (TF-U11): the folder validated as
    /// the editor's bar does it (credentials stripped, nothing written),
    /// no file opened — its result on the card, which opens the first
    /// failing file. A root with nothing terraform reads says so.
    package func validateTerraformRoot(_ card: TerraformRootCard) {
        guard let folder = TerraformRootValidation.folder(of: card) else {
            NSSound.beep()
            return alert("Nothing to validate", "\(card.name) has no .tf, .tf.json or .tofu file Overterm can read.")
        }
        folder.validate(manual: true)
        terraformPanel.objectWillChange.send()
    }

    /// The switcher's rows: each root with its workspace and class; ↩ shows
    /// it in the panel, ⌥↩ a terminal in it.
    package func terraformPaletteItems() -> [PaletteItem] {
        guard Settings.shared.terraformEnabled else { return [] }
        var items = [
            PaletteItem(
                id: "a.terraform", group: .action, title: "Terraform", subtitle: "The checkout's roots, workspaces and backends",
                symbol: "square.stack.3d.up", command: "terraform.show"
            ) { [weak self] _, _ in self?.showTerraformPanel(nil) }
        ]
        for card in terraformPanel.roots {
            let subtitle = "\(card.rootClass.title) · workspace \(card.workspace) · \(card.backendSummary)"
            items.append(
                PaletteItem(id: "tf.root.\(card.path)", group: .terraform, title: card.name, subtitle: subtitle, symbol: "square.stack.3d.up") {
                    [weak self] run, _ in
                    guard let self else { return }
                    if run {
                        self.showTerraformPanel(nil)
                        self.terraformPanel.selectedPath = card.path
                    } else {
                        self.openTerraformTerminal(card)
                    }
                })
            items.append(
                PaletteItem(id: "tf.terminal.\(card.path)", group: .action, title: "Terminal in \(card.name)", subtitle: subtitle, symbol: "terminal") {
                    [weak self] _, _ in self?.openTerraformTerminal(card)
                })
        }
        let mine = terraformPanel.checkout?.standardizedFileURL.path
        for other in TerraformCheckouts.shared.checkoutsWithRoots where other != mine {
            let url = URL(fileURLWithPath: other, isDirectory: true)
            items.append(
                PaletteItem(id: "tf.checkout.\(other)", group: .terraform, title: url.lastPathComponent, subtitle: "Another checkout's roots: \(other)", symbol: "folder") { [weak self] _, _ in
                    guard let self else { return }
                    if let tab = self.store.tabs.first(where: { $0.checkoutSource?.root.standardizedFileURL.path == other }) {
                        self.store.reveal(tab)
                    }
                    self.showTerraformPanel(nil)
                })
        }
        return items
    }
}
