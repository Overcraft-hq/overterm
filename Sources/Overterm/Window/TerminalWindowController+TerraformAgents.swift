import AppKit
import Combine

// MARK: Terraform and the agents (docs/design/terraform/analysis.md 3.3, 3.4, 5.10)

extension TerminalWindowController {
    /// The panes' Terraform asks onto their tabs (3.3), and the `tf_`
    /// tools told which checkout a pane works in (5.10).
    func wireTerraformAgents() {
        // @Published emits before the value lands: the emitted one is used.
        TerraformPaneMonitor.shared.$asks
            .removeDuplicates()
            .sink { [weak self] asks in self?.applyTerraformAsks(asks) }
            .store(in: &cancellables)
        TerraformMCP.paneCheckout = { tag in
            for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                if let tab = controller.store.tabs.first(where: { $0.terminals.contains { $0.processTag == tag } }) {
                    return tab.checkoutSource?.root
                }
            }
            return nil
        }
    }

    /// Each tab's ask: the first of its panes' — every pane, not only the
    /// focused one (`tab.terminals`, CLAUDE.md).
    func applyTerraformAsks(_ asks: [String: TerraformAsk]) {
        for tab in store.tabs {
            var found: TerraformAsk?
            for pane in tab.terminals {
                if let ask = asks[pane.processTag] {
                    found = ask
                    break
                }
            }
            markTerraformAsk(found, on: tab)
        }
    }

    /// Whether `tab` is at a Terraform ask (3.3): its mark, or any of its
    /// panes' screens read now — nothing automated may type into it.
    func terraformAsking(_ tab: Tab) -> Bool {
        tab.terraformAsk != nil || tab.terminals.contains { $0.visibleText.map { TerraformPrompt.parse($0) != nil } ?? false }
    }

    /// Whether `pane` printed what Terraform keeps secret (5.6 rule 6):
    /// its own record, or its shell's commands'.
    func terraformSensitive(_ pane: TerminalView) -> Bool {
        pane.terraformSensitive || blocks(of: pane).printedTerraformSecrets
    }
}

// MARK: Ask Why on a failed validate (5.10)

/// The editor's way to the window's Ask Agent sheet.
@MainActor
protocol TerraformEditorHost: AnyObject {
    func askWhy(validateOf folder: TerraformFolder)
}

extension TerminalWindowController: TerraformEditorHost {
    /// The folder's last validate as a brief (`TerraformAgentBrief`), in the
    /// Ask Agent sheet — the checkout's agents first.
    func askWhy(validateOf folder: TerraformFolder) {
        let diagnostics = folder.allDiagnostics
        guard !diagnostics.isEmpty else { return NSSound.beep() }
        let url = folder.url
        let checkout = folder.checkout
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let settingPath = Settings.shared.terraformPath
        Task { @MainActor [weak self] in
            let (warning, version, providers) = await TerraformPanelModel.blocking { () -> (TerraformPaneWarning, String?, [String]) in
                let facts = TerraformRootFacts.read(root: url, checkout: checkout)
                let warning = TerraformPaneWarning.make(
                    tool: "terraform", operation: "validate", isWrite: false, folder: url, checkout: checkout, facts: facts, workspaceVariable: nil,
                    dataDirVariable: nil, awsProfile: nil, probably: false, settings: settings, identities: identities)
                // `terraform version` (no provider starts) and the lock file's providers (5.10).
                let hasVersionFile = facts.hasVersionFile
                let version = TerraformCLI.binary(forRoot: url, settingPath: settingPath, hasVersionFile: hasVersionFile).flatMap { binary -> String? in
                    let key = binary.path + (hasVersionFile ? "\u{0}" + url.path : "")
                    if let known = TerraformPanelModel.cachedVersion(key) { return known }
                    let found = TerraformCLI.version(of: binary, in: url)
                    if let found { TerraformPanelModel.cacheVersion(key, found) }
                    return found
                }
                let lock = (try? String(contentsOf: url.appendingPathComponent(".terraform.lock.hcl"), encoding: .utf8)) ?? ""
                return (warning, version, TerraformLockFile.versions(in: String(lock.prefix(1 << 20))).map { "\($0.address) \($0.version)" })
            }
            guard let self else { return }
            let root = TerraformAgentBrief.Root(
                name: warning.root, workspace: warning.workspace, backend: warning.backend, rootClass: warning.rootClass, version: version,
                providers: providers)
            let brief = TerraformAgentBrief.validate(diagnostics, root: root, checkout: checkout.path)
            if let recorder = self.terraformBriefRecorder { return recorder(brief) }
            self.presentTerraformBrief(brief)
        }
    }

    func presentTerraformBrief(_ brief: TerraformAgentBrief) {
        guard window?.attachedSheet == nil else { return NSSound.beep() }
        let key = brief.checkout.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        // Never a tab at a Terraform ask (3.3): text typed there would answer it.
        let agents = store.tabs.filter { $0.agent != nil && !terraformAsking($0) }
        let mine = agents.filter { tab in tab.checkoutSource.map { $0.root.resolvingSymlinksInPath().standardizedFileURL.path } == key }
        presentAskAgent(
            text: brief.text, command: nil, folder: brief.checkout ?? store.selected?.workingDirectory, targets: mine + agents.filter { tab in !mine.contains { $0 === tab } },
            message: brief.message, subject: brief.subject, parts: brief.parts, diff: false, showsBrief: true)
    }
}
