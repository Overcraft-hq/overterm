import AppKit
import Combine

// MARK: The rail's Terraform panel and its switcher (docs/design/terraform/analysis.md 6.1, 7)

extension TerminalWindowController {
    /// The panel follows the selected tab's checkout and reads only while it
    /// is the panel on screen; the diff's watcher tells it what changed
    /// (no second watcher, CLAUDE.md), the diff's files what this branch touches.
    func wireTerraformPanel() {
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
                    self.terraformPanel.setOtherWorktrees(TerraformWorktree.others(listed, of: self.terraformPanel.checkout))
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
    var terraformCheckout: URL? { store.selected?.checkoutSource?.root }

    func updateTerraformCheckout() {
        let folder = terraformCheckout
        if terraformPanel.checkout?.standardizedFileURL != folder?.standardizedFileURL {
            terraformPanel.setOtherWorktrees(TerraformWorktree.others(worktrees.worktrees, of: folder), read: false)
            terraformPanel.checkout = folder
        }
    }

    /// On screen: the sidebar open on the panel, Terraform on, the window visible.
    func updateTerraformPanelVisibility(panel: SidebarPanel? = nil) {
        let shown =
            sidebarItem?.isCollapsed == false && (panel ?? sidebarPanel.panel) == .terraform && Settings.shared.terraformEnabled
            && kubernetesPage.windowVisible && window != nil
        if terraformPanel.panelVisible != shown { terraformPanel.panelVisible = shown }
    }

    /// ⌥⌘E: the sidebar, on the Terraform panel.
    @objc func showTerraformPanel(_ sender: Any?) {
        guard Settings.shared.terraformEnabled else { return openSettings(.terraform) }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .terraform
        updateTerraformPanelVisibility(panel: .terraform)
    }

    /// ⌃⌘E: the palette on the roots — the selected checkout's, then the
    /// other checkouts' the rail has read.
    @objc func showTerraformSwitcher(_ sender: Any?) {
        guard Settings.shared.terraformEnabled else { return openSettings(.terraform) }
        // The roots are listed by the panel's read; asked for here when none was.
        if terraformPanel.roots.isEmpty, terraformPanel.checkout != nil { terraformPanel.readNow() }
        togglePalette(scope: .terraform)
    }

    /// Terminal in Terraform Root…: the switcher, its ⌥↩ the terminal.
    @objc func openTerraformTerminalPicker(_ sender: Any?) {
        showTerraformSwitcher(sender)
    }

    func terraformPanelSettingsChanged() {
        if !Settings.shared.terraformEnabled, sidebarPanel.panel == .terraform { sidebarPanel.panel = .files }
        sidebarPanel.objectWillChange.send()
        updateTerraformPanelVisibility()
        // A class may have changed: read again where shown.
        terraformPanel.refresh()
    }

    var terraformPanelActions: TerraformPanelActions {
        TerraformPanelActions(
            openTerminal: { [weak self] card in self?.openTerraformTerminal(card) },
            openFile: { [weak self] url in self?.openInEditor(url) },
            validate: { [weak self] card in self?.validateTerraformRoot(card) },
            plan: { [weak self] card in self?.planTerraformRoot(card) },
            initialize: { [weak self] card in self?.initTerraformRoot(card) },
            chooseWorkspace: { [weak self] card in self?.chooseTerraformWorkspace(card) },
            showPlan: { [weak self] run in self?.showTerraformPlan(run) },
            allowWrites: { [weak self] card in self?.allowTerraformProductionWrites(card) },
            endWrites: { [weak self] card in self?.endTerraformProductionWrites(card) },
            planDestroy: { [weak self] card in self?.planTerraformDestroy(card) },
            showApply: { [weak self] apply in self?.showTerraformApply(apply) })
    }

    /// Terminal in this root (4.9): a shell tab at the root, its icon and
    /// header saying the root; no `TF_WORKSPACE` — the root's own
    /// `.terraform/environment` selects, as for any terminal there.
    @discardableResult
    func openTerraformTerminal(_ card: TerraformRootCard) -> Tab? {
        guard let tab = newTab(in: card.folder, environment: [:], kubePin: nil) else { return nil }
        for pane in tab.terminals { pane.terraformRoot = card.name }
        tab.objectWillChange.send()
        return tab
    }

    /// The root's first configuration file in the editor, then validate
    /// (stage 1a's: credentials stripped, nothing written).
    func validateTerraformRoot(_ card: TerraformRootCard) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: card.folder.path)) ?? []).sorted()
        guard let name = names.first(where: { $0 == "main.tf" }) ?? names.first(where: { $0.hasSuffix(".tf") }) else { return }
        let file = card.folder.appendingPathComponent(name)
        openInEditor(file)
        TerraformEditorModel.shared.folder(for: file).validate(manual: true)
    }

    /// The switcher's rows: each root with its workspace and class; ↩ shows
    /// it in the panel, ⌥↩ a terminal in it.
    func terraformPaletteItems() -> [PaletteItem] {
        guard Settings.shared.terraformEnabled else { return [] }
        var items = [
            PaletteItem(
                id: "a.terraform", group: .action, title: "Terraform", subtitle: "The checkout's roots, workspaces and backends  ⌥⌘E",
                symbol: "square.stack.3d.up"
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
                        self.store.select(tab)
                    }
                    self.showTerraformPanel(nil)
                })
        }
        return items
    }
}
