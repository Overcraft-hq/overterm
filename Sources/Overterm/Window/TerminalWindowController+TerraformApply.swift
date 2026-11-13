import AppKit
import CryptoKit

/// What pressing Apply came to: the scenario reads it.
enum TerraformApplyOutcome {
    case refused(String)
    case cancelled
    case started(TerraformApplyRun)
}

// MARK: Apply (docs/design/terraform/analysis.md 2.3, 4.7, 4.8, 5.3, 5.4, 6.4)

extension TerminalWindowController {
    /// Apply…, the plan's button and `⇧A`: the checks of 5.4, the sheet,
    /// then the detached apply in the plan's environment.
    func applyTerraformPlan(_ run: TerraformPlanRun) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .refused(let why) = await self.applyPlan(run) { self.presentTerraformRefusal(why) }
        }
    }

    /// The apply of `run`'s plan, every guard on the way (5.4): refused
    /// with why, cancelled at a sheet, or started.
    func applyPlan(_ run: TerraformPlanRun) async -> TerraformApplyOutcome {
        let registry = TerraformRunRegistry.shared
        let writable = Settings.shared.terraformRoots[run.card.path]?.writable ?? true
        if let why = run.applyGreyed(registry, writable: writable) { return .refused(why) }
        guard let record = run.record, let plan = run.plan else { return .refused("No plan to apply.") }
        let key = run.identity?.description ?? run.card.folder.path
        // 5.4's facts: the record's, the registry's and the settings' now,
        // and what is read off the main thread — gathered before the sheet
        // and again after it, which may have stood for minutes.
        func gather() async -> TerraformApplyFacts {
            let writable = Settings.shared.terraformRoots[run.card.path]?.writable ?? true
            var facts = TerraformApplyFacts(
                plan: plan, mode: run.mode, recordSHA: record.file.sha256, recordBinary: record.binary.path, recordVersion: record.version,
                recordWorkspace: record.workspace, recordDataDir: record.dataDir, recordEnvironment: record.environment, zipLockSHA: record.zip?.lockFileSHA256,
                zipLockPinsNothing: record.zip?.lockFilePinsNothing ?? false,
                devOverrides: run.devOverrides, rootName: run.card.name, rootClass: run.card.rootClass, writable: writable,
                stateElsewhere: run.card.stateElsewhere)
            facts.staleReason = run.staleReason(registry)
            facts.busy = registry.busy(key)
            let listKey = TerraformStateIdentity.of(backend: run.card.facts.backend, workspace: "default", root: run.card.folder)?.description ?? run.card.folder.path
            let classing = TerraformPlanRun.Classing.current
            let inputs = (varFiles: run.autoVarFiles, profile: run.profile, workspace: run.workspace, terragruntTree: run.card.terragruntTree)
            return await Self.readNow(
                facts, record: record, card: run.card, checkout: run.checkout, pluginCache: run.pluginCache, listed: registry.workspaceLists[listKey],
                classing: classing, inputs: inputs)
        }
        let facts = await gather()
        let verdict = TerraformApplyCheck.check(facts)
        guard case .ask(let typed, let versionMove, let partial, let everything) = verdict else {
            if case .refused(let why) = verdict { return .refused(why) }
            return .cancelled
        }
        let sheet = TerraformApplySheet.make(
            root: .init(
                name: run.card.name, path: run.card.path, rootClass: run.card.rootClass, backend: run.card.backendSummary, workspace: record.workspace,
                worktree: run.checkout.lastPathComponent, branch: run.branch),
            plan: plan, mode: run.mode, typed: typed, versionMove: versionMove, partial: partial, createsEverything: everything,
            risks: run.risks.map(\.said), profile: run.profile, region: run.region)
        // The sheet, the name typed exactly where asked.
        let answer: String?
        if let recorder = terraformApplyQuestionRecorder {
            answer = recorder(sheet)
        } else {
            answer = await WriteConfirmation(
                title: sheet.title, scope: sheet.scope, production: sheet.production, detail: sheet.detail, button: sheet.button,
                typedName: sheet.typedName, critical: sheet.production || sheet.typedName != nil
            ).ask(on: window)
        }
        guard let answer else { return .cancelled }
        if let name = sheet.typedName, answer.trimmingCharacters(in: .whitespacesAndNewlines) != name {
            return .refused("The name typed wasn't \(name): nothing applied.")
        }
        // The version's move, confirmed on its own (D-18).
        if let move = sheet.versionMove {
            let confirm = TerraformApplySheet(
                title: "Move the state to a newer Terraform?", scope: sheet.scope, production: sheet.production, detail: move, typedName: nil,
                button: "Apply and Move the State", versionMove: move)
            let moved: String?
            if let recorder = terraformApplyQuestionRecorder {
                moved = recorder(confirm)
            } else {
                moved = await WriteConfirmation(
                    title: confirm.title, scope: confirm.scope, production: confirm.production, detail: move, button: confirm.button, critical: true
                ).ask(on: window)
            }
            guard moved != nil else { return .cancelled }
        }
        // Asked: what may have moved while the sheet was up — every fact of
        // 5.4 read again (the binary, its version, the environment, the
        // workspace, the lock file, the class), the same verdict or nothing.
        if let why = run.applyGreyed(registry, writable: Settings.shared.terraformRoots[run.card.path]?.writable ?? true) { return .refused(why) }
        guard let current = run.record, current.file.sha256 == record.file.sha256 else { return .refused("The plan changed while asked: plan again.") }
        let after = TerraformApplyCheck.check(await gather())
        if case .refused(let why) = after { return .refused("Changed while asked: " + why) }
        guard after == verdict else { return .refused("What this apply asks changed while the sheet was up: look at it again, then apply.") }
        // The sheet's own await: the record may have gone with it.
        guard run.record != nil, run.apply == nil else { return .refused("The plan changed while asked: plan again.") }
        let id = "tfa-" + UUID().uuidString.prefix(8).lowercased()
        guard registry.take(key, id: id) else { return .refused(registry.busy(key) ?? "Another run holds this state.") }
        let started = await TerraformApplyRun.start(
            record: current, plan: plan, card: run.card, checkout: run.checkout, identity: run.identity, key: key, id: id)
        switch started {
        case .failure(let failure):
            registry.release(key)
            return .refused(failure.message)
        case .success(let apply):
            apply.planRun = run
            run.apply = apply
            // Applied once: the plan's descriptor goes with its record.
            run.dropRecord()
            registry.addApply(apply)
            apply.onEnd = { [weak self] apply in self?.terraformApplyEnded(apply) }
            terraformPlanPane.showApply(apply)
            rightPane.terraformPlanOpened = true
            rightPane.mode = .terraformPlan
            if diffItem?.isCollapsed == true { toggleDiff(nil) }
            updateRightPaneVisibility()
            return .started(apply)
        }
    }

    /// 5.4's facts read now, off the main thread: the descriptor hashed, the
    /// binary and its version, the workspace, the environment built again,
    /// the lock file hashed.
    nonisolated static func readNow(
        _ given: TerraformApplyFacts, record: TerraformPlanRecord, card: TerraformRootCard, checkout: URL, pluginCache: String?, listed: [String]?,
        classing: TerraformPlanRun.Classing? = nil, inputs: (varFiles: [String], profile: String?, workspace: String, terragruntTree: Bool)? = nil
    ) async -> TerraformApplyFacts {
        let settingPath = await MainActor.run { Settings.shared.terraformPath }
        return await TerraformPanelModel.blocking { () -> TerraformApplyFacts in
            var facts = given
            let root = card.folder
            facts.descriptorSHA = TerraformPlanFile.sha256(of: record.file.descriptor, size: record.file.size)
            if let binary = TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: card.facts.hasVersionFile) {
                facts.binaryNow = binary.path
                facts.versionNow = TerraformCLI.version(of: binary, in: root)
            }
            let now = TerraformRootFacts.read(root: root, checkout: checkout)
            // The class from what the root says now (5.1), as a card decides it.
            if let classing, let inputs {
                facts.classNow =
                    TerraformRootCard.verdict(
                        path: card.path, folder: root, facts: now, workspace: inputs.workspace, varFiles: inputs.varFiles, awsProfile: inputs.profile,
                        terragruntTree: inputs.terragruntTree, settings: classing.settings, productionIdentities: classing.identities
                    ).0
            }
            facts.workspaceRefusal = TerraformWorkspaceCheck.refusal(
                workspace: record.workspace, backend: now.backend, localWorkspaces: now.localWorkspaces, listed: now.backend.type == "local" ? nil : listed)
            if let base = try? AppEnvironment.terraformBaseEnvironment(),
                let scratch = try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
            {
                let environment = TerraformEnvironment.build(
                    base: base, purpose: .run(workspace: record.workspace, pluginCache: pluginCache), root: root, scratch: scratch)
                facts.environmentNow = environment
                facts.dataDirNow = environment["TF_DATA_DIR"]
            }
            if let lock = TerraformRootFacts.smallFile(root.appendingPathComponent(".terraform.lock.hcl"), limit: 4 << 20) {
                facts.lockSHANow = SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined()
                facts.lockPinsNothingNow = !String(decoding: lock, as: UTF8.self).contains("provider \"")
            }
            return facts
        }
    }

    /// An apply ended: its state written (every other plan of it stale at
    /// once, 3.6), its turn given back, the panel read again.
    func terraformApplyEnded(_ apply: TerraformApplyRun) {
        let registry = TerraformRunRegistry.shared
        if let identity = apply.identity { registry.stateWritten(identity, by: apply.worktree, operation: "applied", at: Date()) }
        registry.release(apply.key)
        // The lists of applies going (the slot's, the cards') drop it.
        registry.objectWillChange.send()
        terraformPanel.refresh()
    }

    /// Stop (`.`): the first sends SIGINT; a second asks, then sends another.
    func stopTerraformApply(_ apply: TerraformApplyRun) {
        if apply.stop() { return }
        guard apply.isGoing else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let question = TerraformApplySheet(
                title: "Interrupt \(apply.marker.name)'s apply again?", scope: "", production: apply.marker.rootClass == TerraformClass.production.rawValue,
                detail:
                    "Terraform is stopping gracefully. A second interrupt makes it exit now: data loss may occur — what is being created may be lost from the state, and the lock may stay held.",
                typedName: nil, button: "Interrupt Again", versionMove: nil)
            let answer: String?
            if let recorder = self.terraformApplyQuestionRecorder {
                answer = recorder(question)
            } else {
                answer = await WriteConfirmation(title: question.title, detail: question.detail, button: question.button, critical: true).ask(on: self.window)
            }
            if answer != nil { apply.interruptAgain() }
        }
    }

    // MARK: Destroy, targets, replaces (2.2)

    /// "Plan Destroy…": asked, then a destroy plan — nothing is destroyed
    /// until its apply, which asks for the root's name.
    func planTerraformDestroy(_ card: TerraformRootCard, checkout: URL? = nil) {
        guard let checkout = checkout ?? terraformPanel.checkout else { return NSSound.beep() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let question = TerraformPlanGate.Question(
                title: "Plan a destroy of \(card.name)?",
                detail: "A plan of destroying everything in \(card.name), workspace \(card.workspace). Nothing is destroyed until you apply it, which asks for the root's name.",
                button: "Plan Destroy", production: card.isProduction)
            if let recorder = self.terraformPlanQuestionRecorder {
                guard recorder(question) else { return }
            } else {
                let confirmation = WriteConfirmation(
                    title: question.title, scope: "\(card.rootClass.title.uppercased()) · \(card.name)", production: card.isProduction, detail: question.detail,
                    button: question.button)
                guard await confirmation.ask(on: self.window) != nil else { return }
            }
            self.planTerraformRoot(card, checkout: checkout, mode: .destroy)
        }
    }

    /// A row's "Plan Only This" (`-target`, partial) and "Plan Replacing This" (`-replace`).
    func planTerraformAgain(_ run: TerraformPlanRun, mode: TerraformPlanMode) {
        guard mode.flags != nil else { return presentTerraformRefusal("That address can't be passed to terraform.") }
        planTerraformRoot(run.card, checkout: run.checkout, mode: mode)
    }

    // MARK: Closing a pane where terraform writes (4.8)

    /// Asks before a close that would kill a terraform write in `tabs`'
    /// panes (`panes`: only those, for a pane's close): Interrupt, Close
    /// Anyway, Cancel. True when it asked — the caller's close waits for
    /// `proceed`; false when nothing guarded runs there.
    func terraformCloseGuard(tabs: [Tab], panes: [TerminalView]? = nil, path: TerraformCloseGuard.Path, proceed: @escaping () -> Void) -> Bool {
        let running = terraformWrites(tabs: tabs, panes: panes, path: path)
        guard let question = TerraformCloseGuard.question(running, path: path), let window else { return false }
        let alert = Self.terraformCloseAlert(question)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self?.interruptTerraform(running, path: path, proceed: proceed)
                case .alertSecondButtonReturn: proceed()
                default: break
                }
            }
        }
        return true
    }

    static func terraformCloseAlert(_ question: TerraformCloseGuard.Question) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.alertStyle = .critical
        for title in TerraformCloseGuard.Question.buttons { alert.addButton(withTitle: title) }
        return alert
    }

    /// The terraform writes in these tabs' panes, found now by pid.
    func terraformWrites(tabs: [Tab], panes: [TerminalView]? = nil, path: TerraformCloseGuard.Path) -> [TerraformCloseGuard.Running] {
        var walked: [(login: pid_t, place: String, checkout: URL?, tag: String?)] = []
        for tab in tabs {
            for pane in tab.terminals where panes.map({ $0.contains { $0 === pane } }) ?? true {
                guard let login = SurfaceProcesses.shared.loginPID(of: pane) else { continue }
                let place = path == .pane ? "this pane" : "“\(tab.title)”"
                walked.append((login, place, tab.checkoutSource?.root, pane.processTag))
            }
        }
        guard !walked.isEmpty else { return [] }
        return TerraformCloseGuard.find(walked)
    }

    /// Interrupt: SIGINT to each, the close held back; the panes' headers
    /// say "shutting down"; once they have stopped, a notice offers Close
    /// Now — `proceed`, the close Interrupt held back — or keeps them.
    func interruptTerraform(_ running: [TerraformCloseGuard.Running], path: TerraformCloseGuard.Path, proceed: @escaping () -> Void) {
        TerraformCloseGuard.interrupt(running)
        terraformInterrupted = running
        TerraformPaneMonitor.shared.shuttingDown(running)
        Task { @MainActor [weak self] in
            for _ in 0..<1_800 {
                try? await Task.sleep(for: .milliseconds(500))
                guard TerraformCloseGuard.anyAlive(running) else { break }
            }
            TerraformPaneMonitor.shared.stopped(running)
            guard let self, !TerraformCloseGuard.anyAlive(running) else { return }
            self.terraformInterrupted.removeAll { item in running.contains(item) }
            await self.terraformStoppedNotice(running, path: path, proceed: proceed)
        }
    }

    /// "terraform has stopped": Close Now, or keep it open. Waits for a
    /// sheet already on the window to close rather than dropping the notice.
    private func terraformStoppedNotice(_ running: [TerraformCloseGuard.Running], path: TerraformCloseGuard.Path, proceed: @escaping () -> Void) async {
        guard let question = TerraformCloseGuard.stoppedNotice(running, path: path) else { return }
        for _ in 0..<7_200 {
            guard let window, window.isVisible || path == .quit else { return }
            if window.attachedSheet == nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        for title in TerraformCloseGuard.stoppedButtons { alert.addButton(withTitle: title) }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { proceed() }
        }
    }

    // MARK: Reattach (4.7)

    /// The applies found alive in run folders — another launch's, or, for
    /// a scenario's crash, this one's — followed again in the slot.
    @discardableResult
    func reattachTerraformApplies(_ found: [(folder: URL, marker: TerraformApplyMarker)]) -> [TerraformApplyRun] {
        let registry = TerraformRunRegistry.shared
        var made: [TerraformApplyRun] = []
        for (folder, marker) in found {
            let apply = TerraformApplyRun.reattach(folder: folder, marker: marker)
            _ = registry.take(apply.key, id: apply.id)
            registry.addApply(apply)
            apply.onEnd = { [weak self] apply in self?.terraformApplyEnded(apply) }
            made.append(apply)
        }
        // The slot shows one; every other is listed above it, each a
        // button to its progress and Stop, and on its root's card.
        if let last = made.last { showTerraformApply(last) }
        return made
    }

    /// The run folders of this session's applies, followed already.
    static var followedApplyFolders: Set<String> {
        Set(TerraformRunRegistry.shared.applies.filter(\.isGoing).map { $0.folder.standardizedFileURL.path })
    }
}
