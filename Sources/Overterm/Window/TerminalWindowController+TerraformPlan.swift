import AppKit
import Combine

// MARK: The plan in the right slot (docs/design/terraform/analysis.md 4.3–4.13, 5.5, 6.3)

extension TerminalWindowController {
    /// The diff's added lines feed the cause chains; a root's file written
    /// after its plan marks the plan stale; agents' `tf_plan` reaches the
    /// window of their pane.
    func wireTerraformPlan() {
        // @Published emits the new value before it lands: the emitted one is used.
        diff.$diffs
            .map { TerraformPlanPaneModel.addedLines($0) }
            .removeDuplicates()
            .sink { [weak self] lines in self?.terraformPlanPane.changedLines = lines }
            .store(in: &cancellables)
        diff.changes
            .sink { [weak self] paths in self?.terraformFilesChanged(paths) }
            .store(in: &cancellables)
        TerraformMCP.startPlan = { card, checkout, pane in
            for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                guard controller.store.tabs.contains(where: { $0.terminals.contains { $0.processTag == pane } }) else { continue }
                return await controller.agentPlan(card, checkout: checkout)
            }
            return .failure(TerraformReadFailure(message: "The pane that asked isn't in any window."))
        }
        TerraformMCP.paneModels = { NSApp.windows.compactMap { ($0.windowController as? TerminalWindowController)?.terraformPlanPane } }
        TerraformRunFolder.sweepAtLaunch()
    }

    var terraformPlanActions: TerraformPlanActions {
        TerraformPlanActions(
            planAgain: { [weak self] run, lock in
                guard let self else { return }
                if run.kind == .initialize { self.initTerraformRoot(run.card, checkout: run.checkout) } else { self.planTerraformRoot(run.card, checkout: run.checkout, lock: lock) }
            },
            discard: { [weak self] run in
                TerraformRunRegistry.shared.discard(run)
                if self?.terraformPlanPane.run === run { self?.terraformPlanPane.clear() }
            },
            copySummary: { [weak self] run in self?.copyTerraformSummary(run) },
            askWhy: { [weak self] run in self?.askWhy(run: run) },
            chooseVarFiles: { [weak self] run, files in
                TerraformRootStore.shared.setVarFiles(files, checkout: run.checkout, root: run.card.path)
                self?.planTerraformRoot(run.card, checkout: run.checkout)
            },
            open: { [weak self] url, line in self?.openInEditor(url, line: line) },
            close: { [weak self] in self?.toggleDiff(nil) })
    }

    /// The run in the right slot, which takes it (`RightSlot`).
    func showTerraformPlan(_ run: TerraformPlanRun) {
        terraformPlanPane.show(run)
        rightPane.terraformPlanOpened = true
        rightPane.mode = .terraformPlan
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// A root's file written after its plan started — while it ran too,
    /// when the plan may have read the old file: the plan is stale (6.3),
    /// said once it lands.
    func terraformFilesChanged(_ paths: [String]) {
        for run in TerraformRunRegistry.shared.runs where run.kind == .plan && !run.configChanged && (run.isGoing || run.record != nil) {
            let started = run.started
            let folder = run.card.folder.standardizedFileURL.path
            let real = FileTreeModel.realPath(run.card.folder.standardizedFileURL)
            guard paths.contains(where: { $0 == folder || $0 == real || $0.hasPrefix(folder + "/") || $0.hasPrefix(real + "/") }) else { continue }
            let root = run.card.folder
            Task { @MainActor in
                let changed = await TerraformPanelModel.blocking { Self.terraformFilesWritten(in: root, since: started) }
                if changed { run.configChanged = true }
            }
        }
    }

    /// Whether a configuration or var file of `root` was written after `date`. Blocking (stats).
    nonisolated static func terraformFilesWritten(in root: URL, since date: Date) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).prefix(TerraformRootGuess.maxFilesPerFolder)
        return names.contains { name in
            guard name.hasSuffix(".tf") || name.hasSuffix(".tfvars") || name.hasSuffix(".tfvars.json") || name == ".terraform.lock.hcl" else { return false }
            let modified = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.modificationDate]) as? Date
            return modified.map { $0 > date } ?? false
        }
    }

    // MARK: Plan

    /// The checkout's branch @ commit as the chip says it, when it is the panel's.
    private func terraformBranch(_ checkout: URL) -> String? {
        terraformPanel.checkout?.standardizedFileURL == checkout.standardizedFileURL ? terraformPanel.branchLabel : nil
    }

    /// Plans `card` — the person's click: asked first where 5.3 and 5.5
    /// say (production's first plan this session, a commit not theirs,
    /// risks new against the base branch), then in the slot.
    func planTerraformRoot(_ card: TerraformRootCard, checkout: URL? = nil, lock: TerraformCommands.LockWait = .person) {
        guard let checkout = checkout ?? terraformPanel.checkout else { return NSSound.beep() }
        Task { @MainActor [weak self] in
            guard let self, let run = await self.preparePlan(card, checkout: checkout, lock: lock, agent: nil) else { return }
            self.showTerraformPlan(run)
            await run.start(settingPath: Settings.shared.terraformPath)
            self.terraformPanel.objectWillChange.send()
        }
    }

    /// An agent's `tf_plan` (D-12): never production in stage 1 (writes
    /// there need the session switch, which stage 2a brings); the first per
    /// root and session asked; `-lock-timeout=0s`; no var file, no flag.
    func agentPlan(_ card: TerraformRootCard, checkout: URL) async -> Result<TerraformPlanRun, TerraformReadFailure> {
        if card.isProduction {
            return .failure(TerraformReadFailure(message: "\(card.name) is production: the person plans it, from Overterm's Terraform panel."))
        }
        if let why = TerraformProcessCheck.refused(.plan, backendType: card.facts.backend.type) { return .failure(TerraformReadFailure(message: why + ".")) }
        guard let run = await preparePlan(card, checkout: checkout, lock: .agent, agent: await MCPAsker.current() ?? "an agent") else {
            return .failure(TerraformReadFailure(message: "The person declined the plan of \(card.name)."))
        }
        showTerraformPlan(run)
        Task { @MainActor in await run.start(settingPath: Settings.shared.terraformPath) }
        return .success(run)
    }

    /// The questions, then the run made and registered (not started).
    private func preparePlan(_ card: TerraformRootCard, checkout: URL, lock: TerraformCommands.LockWait, agent: String?) async -> TerraformPlanRun? {
        let registry = TerraformRunRegistry.shared
        if let why = TerraformProcessCheck.refused(.plan, rootClass: card.rootClass)
            ?? TerraformProcessCheck.refused(.plan, backendType: card.facts.backend.type)
        {
            presentTerraformRefusal(why)
            return nil
        }
        let key = TerraformRootStore.key(checkout: checkout, root: card.path) + "\u{0}" + card.workspace
        let firstOnProduction = card.isProduction && !registry.productionPlanned.contains(key)
        // What its code runs or reaches, now and against the base branch.
        let base = diff.root?.standardizedFileURL == checkout.standardizedFileURL ? diff.comparison?.mergeBase ?? "HEAD" : "HEAD"
        let baseFacts = await TerraformRunRisks.readBase(checkout: checkout, rootPath: card.path, base: base)
        let config = card.facts.config
        let lockProviders = card.facts.lockProviders
        let fresh = TerraformRunRisks.new(config: config, lockProviders: lockProviders, base: baseFacts)
        let listed = TerraformRunRisks.listed(config: config, lockProviders: lockProviders, plan: nil, base: baseFacts)
        let all = TerraformRunRisks.risks(config: config, lockProviders: lockProviders)
        let authored = await Self.authoredByPerson(checkout, base: base)
        let changed = await TerraformChangedLines.read(checkout: checkout, root: card.path, base: base)
        let agentKey = key + "\u{0}agent"
        // An agent's: asked once per root and session — and again when its
        // code now runs or reaches something the approved one didn't (D-12, 5.10).
        let agentAllowed = agent != nil && !TerraformPlanGate.agentAsks(approved: registry.agentAllowed[agentKey], risks: all)
        // The profile the run uses: the environment it is built from (never in an isolated run's).
        let profile = AppEnvironment.guardsTerraform ? nil : ShellEnvironment.known()?["AWS_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
        if !agentAllowed,
            let question = TerraformPlanGate.question(
                root: card.name, workspace: card.workspace, rootClass: card.rootClass, profile: profile,
                firstOnProduction: firstOnProduction, authoredByPerson: authored, newRisks: fresh, allRisks: all, agent: agent)
        {
            let scope = "\(card.rootClass.title.uppercased()) · \(card.name) · workspace \(card.workspace) · \(card.backendSummary)"
            let confirmation = WriteConfirmation(
                title: question.title, scope: scope, production: question.production, detail: question.detail, button: question.button,
                critical: question.production)
            if let recorder = terraformPlanQuestionRecorder {
                guard recorder(question) else { return nil }
            } else {
                guard await confirmation.ask(on: window) != nil else { return nil }
            }
        }
        if card.isProduction { registry.productionPlanned.insert(key) }
        if agent != nil { registry.agentAllowed[agentKey, default: []].formUnion(all) }
        let run = TerraformPlanRun(
            kind: .plan, checkout: checkout, card: card, agent: agent, lockWait: lock,
            varFiles: agent == nil ? TerraformRootStore.shared.varFiles(checkout: checkout, root: card.path) : [],
            branch: terraformBranch(checkout))
        run.risks = listed
        run.changedLines = changed
        registry.add(run)
        return run
    }

    /// The most commits since the base whose authors are compared.
    static let maxAuthoredCommits = 500

    /// Whether the person wrote every commit since `base` (5.5: a branch
    /// of a teammate's commits with one of the person's on top isn't
    /// theirs) — HEAD's alone when there are none since it; nil when it
    /// can't be told, which the gate counts as not theirs.
    static func authoredByPerson(_ checkout: URL, base: String) async -> Bool? {
        let me = try? await Git.run(["config", "user.email"], in: checkout)
        var authors: [String] = []
        if base != "HEAD", let listed = try? await Git.run(["log", "--format=%ae", "-n", "\(maxAuthoredCommits)", "\(base)..HEAD"], in: checkout) {
            authors = listed.split(separator: "\n").map(String.init)
        }
        if authors.isEmpty, let head = try? await Git.run(["log", "-1", "--format=%ae"], in: checkout) {
            authors = [head]
        }
        return TerraformPlanGate.authoredByPerson(authors: authors, me: me)
    }

    func presentTerraformRefusal(_ why: String) {
        guard let window, window.attachedSheet == nil else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Not run"
        alert.informativeText = why
        alert.beginSheetModal(for: window)
    }

    // MARK: Init

    /// Init, the person's click (4.13): the fetch list shown first; the
    /// plugin cache offered at the first Init where two worktrees of the
    /// repository have roots; `-lockfile=readonly`, always.
    func initTerraformRoot(_ card: TerraformRootCard, checkout: URL? = nil) {
        guard let checkout = checkout ?? terraformPanel.checkout else { return NSSound.beep() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = TerraformRootStore.shared
            let worktrees =
                1
                + TerraformWorktree.others(self.worktrees.worktrees, of: checkout).filter {
                    FileManager.default.fileExists(atPath: (card.path.isEmpty ? $0.url : $0.url.appendingPathComponent(card.path)).path)
                }.count
            let shell = ShellEnvironment.known() ?? [:]
            if TerraformInitPlan.offersCache(
                answered: store.pluginCache != nil, worktreesWithRoots: worktrees,
                userConfiguresCLI: AppEnvironment.terraformUserConfiguresCLI(shell: shell))
            {
                let taken: Bool
                if let recorder = self.terraformCacheOfferRecorder {
                    taken = recorder()
                } else {
                    taken = await self.askPluginCache(worktrees: worktrees)
                }
                store.setPluginCache(taken)
            }
            let items = TerraformInitPlan.items(config: card.facts.config, lockProviders: card.facts.lockProviders)
            var detail = items.isEmpty ? "Nothing to fetch: no provider or module outside the root." : "What init fetches:\n"
            detail += items.prefix(30).map { item in
                "• \(item.kind == .provider ? "provider" : "module") \(item.name) — \(item.source)" + (item.version.map { " \($0)" } ?? "")
                    + (item.flag.map { "\n   ⚠ \($0)" } ?? "")
            }.joined(separator: "\n")
            detail += "\n\nWith -lockfile=readonly: the lock file is never rewritten. Providers are programs that run with your credentials."
            let question = TerraformPlanGate.Question(title: "Init \(card.name)?", detail: detail, button: "Init", production: card.isProduction)
            if let recorder = self.terraformPlanQuestionRecorder {
                guard recorder(question) else { return }
            } else {
                let confirmation = WriteConfirmation(
                    title: question.title, scope: "\(card.rootClass.title.uppercased()) · \(card.name)", production: card.isProduction, detail: detail,
                    button: "Init")
                guard await confirmation.ask(on: self.window) != nil else { return }
            }
            var cache: String?
            if store.pluginCache == true, !AppEnvironment.terraformUserConfiguresCLI(shell: shell) {
                let folder = AppEnvironment.terraformCacheDirectory
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                cache = folder.path
            }
            let run = TerraformPlanRun(kind: .initialize, checkout: checkout, card: card, pluginCache: cache, branch: self.terraformBranch(checkout))
            TerraformRunRegistry.shared.add(run)
            self.showTerraformPlan(run)
            await run.start(settingPath: Settings.shared.terraformPath)
            self.terraformPanel.refresh()
        }
    }

    private func askPluginCache(worktrees: Int) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Share one provider cache between worktrees?"
        alert.informativeText =
            "\(worktrees) worktrees of this repository have Terraform roots, and each init copies its providers again (hundreds of MB for a cloud provider). Overterm can give its own runs one cache, in its own folder (\(AppEnvironment.terraformCacheDirectory.path)), one init at a time. Your ~/.terraformrc and terminals are left alone."
        alert.addButton(withTitle: "Share a Cache")
        alert.addButton(withTitle: "Not Now")
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        return response == .alertFirstButtonReturn
    }

    // MARK: Workspace

    /// The chip's menu (4.9): the backend's workspaces; Select writes the
    /// checkout's `.terraform/environment`.
    func chooseTerraformWorkspace(_ card: TerraformRootCard, checkout: URL? = nil) {
        guard let checkout = checkout ?? terraformPanel.checkout else { return }
        let settingPath = Settings.shared.terraformPath
        let hasVersionFile = card.facts.hasVersionFile
        let root = card.folder
        Task { @MainActor [weak self] in
            let answer = await TerraformPanelModel.blocking {
                TerraformWorkspaces.list(root: root, checkout: checkout, settingPath: settingPath, hasVersionFile: hasVersionFile)
            }
            guard let self else { return }
            switch answer {
            case .failed(let why): self.presentTerraformRefusal(why)
            case .names(let names):
                let menu = NSMenu()
                let header = NSMenuItem(title: "Select writes \(card.name)/.terraform/environment: every terminal there follows it", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                menu.addItem(.separator())
                for name in names {
                    menu.addItem(
                        ClosureMenuItem(name, state: name == card.workspace ? .on : .off) { [weak self] in
                            self?.selectTerraformWorkspace(name, card: card)
                        })
                }
                guard let view = self.window?.contentView else { return }
                let point = view.convert(self.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
                menu.popUp(positioning: nil, at: point, in: view)
            }
        }
    }

    func selectTerraformWorkspace(_ name: String, card: TerraformRootCard) {
        let settingPath = Settings.shared.terraformPath
        let hasVersionFile = card.facts.hasVersionFile
        let root = card.folder
        Task { @MainActor [weak self] in
            let why = await TerraformPanelModel.blocking { TerraformWorkspaces.select(name, root: root, settingPath: settingPath, hasVersionFile: hasVersionFile) }
            if let why { self?.presentTerraformRefusal(why) }
            self?.terraformPanel.refresh()
        }
    }

    // MARK: Summary, Ask Why

    func copyTerraformSummary(_ run: TerraformPlanRun) {
        guard let plan = run.plan else { return NSSound.beep() }
        let causes = terraformPlanPane.run === run ? terraformPlanPane.causeTexts() : [:]
        let text = TerraformPlanText.copySummary(plan, root: run.card.name, workspace: run.workspace, branch: run.branch, causes: causes)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Ask Why on a failed plan or init, or a held lock (5.10).
    func askWhy(run: TerraformPlanRun) {
        let root = run.card.folder
        Task { @MainActor [weak self] in
            let providers = await TerraformPanelModel.blocking { () -> [String] in
                let lock = (try? String(contentsOf: root.appendingPathComponent(".terraform.lock.hcl"), encoding: .utf8)) ?? ""
                return TerraformLockFile.versions(in: String(lock.prefix(1 << 20))).map { "\($0.address) \($0.version)" }
            }
            guard let self else { return }
            let brief = TerraformAgentBrief.run(
                operation: run.kind == .plan ? "plan" : "init", diagnostics: run.diagnostics, lock: run.lock, log: run.log,
                root: .init(
                    name: run.card.name, workspace: run.workspace, backend: run.card.backendSummary, rootClass: run.card.rootClass,
                    version: run.record?.version ?? run.card.version, providers: providers),
                checkout: run.checkout.path)
            if let recorder = self.terraformBriefRecorder { return recorder(brief) }
            self.presentTerraformBrief(brief)
        }
    }

    // MARK: Menu and palette

    /// Plan Terraform Root: the panel's selected root, else its only one, else the switcher.
    @objc func planSelectedTerraformRoot(_ sender: Any?) {
        guard Settings.shared.terraformEnabled else { return openSettings(.terraform) }
        let roots = terraformPanel.roots
        if let card = roots.first(where: { $0.path == terraformPanel.selectedPath }) ?? (roots.count == 1 ? roots.first : nil) {
            return planTerraformRoot(card)
        }
        showTerraformSwitcher(sender)
    }

    @objc func copyTerraformPlanSummary(_ sender: Any?) {
        guard let run = terraformPlanPane.run else { return NSSound.beep() }
        copyTerraformSummary(run)
    }

    /// The palette's Plan and Init rows, one per root (8).
    func terraformPlanPaletteItems() -> [PaletteItem] {
        guard Settings.shared.terraformEnabled else { return [] }
        var items: [PaletteItem] = []
        for card in terraformPanel.roots {
            let subtitle = "\(card.rootClass.title) · workspace \(card.workspace) · \(card.backendSummary)"
            items.append(
                PaletteItem(id: "tf.plan.\(card.path)", group: .action, title: "Plan \(card.name)", subtitle: subtitle, symbol: "square.stack.3d.up") {
                    [weak self] _, _ in self?.planTerraformRoot(card)
                })
            items.append(
                PaletteItem(id: "tf.init.\(card.path)", group: .action, title: "Init \(card.name)…", subtitle: subtitle, symbol: "arrow.down.circle") {
                    [weak self] _, _ in self?.initTerraformRoot(card)
                })
        }
        return items
    }
}

extension TerraformRunFolder {
    /// The sweep, once per app, off the main thread.
    @MainActor static func sweepAtLaunch() {
        guard !swept else { return }
        swept = true
        let work: @Sendable () -> Void = { TerraformRunFolder.sweep() }
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    @MainActor private static var swept = false
}
