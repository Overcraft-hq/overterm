import AppKit

/// What Force Unlock came to: the scenario reads it.
enum TerraformUnlockOutcome: Equatable {
    case refused(String)
    case cancelled
    case unlocked(String)
}

// MARK: Force unlock (docs/design/terraform/analysis.md 2.5, 4.10, 5.3, 5.4, D-10)

extension TerminalWindowController {
    /// A scenario's: the force-unlock sheet answered here — what was
    /// typed, or nil for Cancel — instead of on the window.
    static var terraformUnlockQuestionRecorder: ((TerraformUnlock.Sheet) -> String?)?

    /// Force Unlock…, under a lock a plan of this window couldn't take.
    func forceUnlockTerraform(_ run: TerraformPlanRun) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.forceUnlock(run)
            if case .refused(let why) = outcome { self.presentTerraformRefusal(why) }
        }
    }

    /// The force unlock of `run`'s lock: only that parsed ID, probed
    /// before the sheet and again just before it runs; the sheet naming
    /// the holder, the root's name typed on every class (5.4). Never a
    /// plan as the probe, never a lock Overterm's own run may hold.
    func forceUnlock(_ run: TerraformPlanRun) async -> TerraformUnlockOutcome {
        let unlocks = TerraformUnlockModel.shared
        guard !unlocks.going.contains(run.id) else { return .refused("A force unlock of this lock is going already.") }
        unlocks.began(run.id)
        let outcome = await forceUnlockChecked(run)
        switch outcome {
        case .unlocked(let said): unlocks.ended(run.id, .init(text: said, unlocked: true))
        case .refused(let why): unlocks.ended(run.id, .init(text: why, unlocked: false))
        case .cancelled: unlocks.ended(run.id, nil)
        }
        return outcome
    }

    /// The live terraform that may hold `run`'s lock, as a refusal: every
    /// process of this user on this Mac (panes', other terminals', other
    /// worktrees') resolved to its state off the main thread, and the
    /// panes' identities the monitor has. Nil when none.
    private func terraformLiveHolder(_ run: TerraformPlanRun) async -> String? {
        let monitor = TerraformPaneMonitor.shared
        let panePIDs = Set(monitor.processes.values.joined().map(\.pid))
        let paneIdentities = monitor.warnings.values.compactMap(\.identity)
        let identity = run.identity
        let folder = run.card.folder
        let path = run.card.path
        let name = run.card.name
        return await TerraformPanelModel.blocking {
            let live = TerraformLiveProcesses.live(panePIDs: panePIDs, paneIdentities: paneIdentities)
            let root = folder.resolvingSymlinksInPath().path
            return TerraformUnlock.holder(among: live, identity: identity, root: root, path: path).map { TerraformUnlock.liveRefusal($0, name: name) }
        }
    }

    private func forceUnlockChecked(_ run: TerraformPlanRun) async -> TerraformUnlockOutcome {
        let card = run.card
        let backendType = card.facts.backend.type
        let registry = TerraformRunRegistry.shared
        let key = run.identity?.description ?? card.folder.path
        // Only from a lock Terraform named in this window (4.10); never
        // while Overterm's own run on this state may be the holder.
        if let why = TerraformUnlock.refusalBefore(
            hasLock: run.lock != nil, shown: terraformPlanPane.run === run, going: run.isGoing, backendType: backendType,
            rootClass: card.rootClass, busy: registry.busy(key))
        {
            return .refused(why)
        }
        guard let lock = run.lock else { return .refused("Force unlock is offered only for a lock a plan in this window was refused by.") }
        guard let command = TerraformCommands.forceUnlock(id: lock.id) else { return .refused("The lock's ID isn't one terraform could be given.") }
        // A live terraform on this state — in any pane, any worktree, any terminal of this user — may be the holder.
        if let why = await terraformLiveHolder(run) { return .refused(why) }
        let note = TerraformUnlock.note(isThisMac: lock.isThisMac(), name: card.name)

        // The probe, then the sheet, then the probe again just before.
        let place: TerraformUnlockPlace
        switch await terraformUnlockPlace(run) {
        case .ready(let ready): place = ready
        case .refused(let why): return .refused(why)
        }
        let id = "tfu-" + UUID().uuidString.prefix(8).lowercased()
        guard registry.take(key, id: id) else { return .refused(registry.busy(key) ?? "Another run holds this state.") }
        let first = await Self.terraformProbe(place)
        registry.release(key)
        let probed = TerraformUnlock.probe(parsed: lock, status: first.status, stderr: first.stderr)
        if let why = TerraformUnlock.refusal(probed, parsed: lock) { return .refused(why) }
        guard case .held(var holder) = probed else { return .refused("The lock couldn't be checked: nothing was unlocked.") }
        holder.http = TerraformUnlock.isHTTP(holder: holder, parsed: lock, backendType: backendType)

        let sheet = TerraformUnlock.sheet(
            root: .init(
                name: card.name, rootClass: card.rootClass, backend: card.backendSummary, workspace: run.workspace, worktree: run.checkout.lastPathComponent),
            lock: holder, note: note)
        let answer: String?
        if let recorder = Self.terraformUnlockQuestionRecorder {
            answer = recorder(sheet)
        } else {
            answer = await WriteConfirmation(
                title: sheet.title, scope: sheet.scope, production: sheet.production, detail: sheet.detail, button: sheet.button,
                typedName: sheet.typedName, critical: true
            ).ask(on: window)
        }
        guard let answer else { return .cancelled }
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == sheet.typedName else {
            return .refused("The name typed wasn't \(sheet.typedName): nothing was unlocked.")
        }

        // The sheet may have stood for minutes: the place and the lock read again.
        guard case .ready(let now) = await terraformUnlockPlace(run), now.binary == place.binary, now.environment == place.environment else {
            return .refused("\(card.name)'s workspace, backend or terraform changed while asked: nothing was unlocked. Plan again.")
        }
        if let busy = registry.busy(key) { return .refused(busy + " Nothing was unlocked.") }
        if let why = await terraformLiveHolder(run) { return .refused(why) }
        if let busy = registry.busy(key) { return .refused(busy + " Nothing was unlocked.") }
        guard registry.take(key, id: id) else { return .refused(registry.busy(key) ?? "Another run holds this state.") }
        defer { registry.release(key) }
        let second = await Self.terraformProbe(now)
        let again = TerraformUnlock.probe(parsed: lock, status: second.status, stderr: second.stderr)
        if let why = TerraformUnlock.refusal(again, parsed: lock) { return .refused(why) }
        let stops = TerraformRun.live.generation
        let forced = await Self.terraformRun(now, command)
        let stoppedMeanwhile = TerraformRun.live.generation != stops
        if let why = TerraformUnlock.interrupted(status: forced.status, timedOut: forced.timedOut, stoppedMeanwhile: stoppedMeanwhile) {
            return .refused(why)
        }
        if let why = TerraformUnlock.unlockFailure(status: forced.status, stderr: forced.stderr) { return .refused(why) }
        return .unlocked("Unlocked \(card.name)'s state: lock \(lock.id), \(holder.who ?? "someone")'s, removed. Plan again.")
    }

    /// Where the probe and the unlock run: the plan's root and workspace,
    /// the binary and environment built as the plan's were (its
    /// credentials: the backend needs them) but read now — and refused when
    /// the root no longer says what the plan did, or the binary or
    /// environment changed between the sheet's two reads.
    struct TerraformUnlockPlace: Sendable, Equatable {
        var root: URL
        var binary: URL
        var environment: [String: String]
    }

    enum TerraformUnlockPlaceRead: Sendable {
        case ready(TerraformUnlockPlace)
        case refused(String)
    }

    private func terraformUnlockPlace(_ run: TerraformPlanRun) async -> TerraformUnlockPlaceRead {
        let card = run.card
        let name = card.name
        let root = card.folder
        let checkout = run.checkout
        let workspace = run.workspace
        let identity = run.identity
        let pluginCache = run.pluginCache
        let settingPath = Settings.shared.terraformPath
        let listKey = TerraformStateIdentity.of(backend: card.facts.backend, workspace: "default", root: root)?.description ?? root.path
        let listed = TerraformRunRegistry.shared.workspaceLists[listKey]
        let hasVersionFile = card.facts.hasVersionFile
        return await TerraformPanelModel.blocking { () -> TerraformUnlockPlaceRead in
            let facts = TerraformRootFacts.read(root: root, checkout: checkout)
            guard facts.workspace == workspace, TerraformStateIdentity.of(backend: facts.backend, workspace: facts.workspace, root: root) == identity else {
                return .refused("\(name) now plans workspace \(facts.workspace) or another backend than the plan that was refused: plan again.")
            }
            if let why = TerraformProcessCheck.refused(.forceUnlock, backendType: facts.backend.type) { return .refused(why) }
            // A workspace that doesn't exist is never touched (4.9).
            if let why = TerraformWorkspaceCheck.refusal(workspace: workspace, backend: facts.backend, localWorkspaces: facts.localWorkspaces, listed: listed) {
                return .refused(why)
            }
            guard let binary = TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: hasVersionFile) else {
                return .refused("No terraform found: set Settings ▸ Terraform ▸ terraform, or install it.")
            }
            guard let base = try? AppEnvironment.terraformBaseEnvironment(),
                let scratch = try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
            else { return .refused("The environment for terraform couldn't be read.") }
            let environment = TerraformEnvironment.build(base: base, purpose: .run(workspace: workspace, pluginCache: pluginCache), root: root, scratch: scratch)
            return .ready(TerraformUnlockPlace(root: root, binary: binary, environment: environment))
        }
    }

    nonisolated private static func terraformProbe(_ place: TerraformUnlockPlace) async -> TerraformRun.Result {
        await terraformRun(place, TerraformCommands.lockProbe)
    }

    nonisolated private static func terraformRun(_ place: TerraformUnlockPlace, _ arguments: [String]) async -> TerraformRun.Result {
        do {
            // The probe takes the state's lock, force-unlock writes it: neither interrupted by a cancelled task.
            return try await TerraformRun.short(place.binary, arguments, in: place.root, environment: place.environment, timeout: 60, interruptible: false)
        } catch {
            return TerraformRun.Result(status: 1, stdout: Data(), stderr: "Error: \(error)")
        }
    }
}
