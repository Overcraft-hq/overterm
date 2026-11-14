import AppKit

/// Terraform stage 2e (docs/design/terraform/analysis.md 2.5, 4.10, 9,
/// D-10): a lock someone else holds on `FakeTerraformBackend`, cleared
/// without a terminal. Force Unlock is offered under the lock the plan
/// named; the probe (`state rm -dry-run -lock-timeout=0s`, never a plan)
/// refuses a lock that changed hands; the sheet names the holder and the
/// http backend's empty UNLOCK, and the root's name is typed — a wrong
/// name or Cancel unlocks nothing; the right one removes that lock. Called
/// by the terraform plan scenario with its locked run, through its
/// recording wrapper and the real terraform.
extension E2ERunner {
    func terraformForceUnlockChecks(
        _ locked: TerraformPlanRun, card: TerraformRootCard, backend: FakeTerraformBackend, recorder: TerraformRecorder, pane: TerraformPlanPaneModel,
        root: NSView
    ) async {
        check("Force Unlock is offered under the lock", await eventually(5) { Self.accessibilityPress("terraform.plan.forceUnlock", in: root, press: false) })
        let asked = UnlockSheets()
        TerminalWindowController.terraformUnlockQuestionRecorder = { sheet in
            asked.sheets.append(sheet)
            return asked.answer(sheet)
        }
        defer { TerminalWindowController.terraformUnlockQuestionRecorder = nil }
        func calls(since count: Int) -> [[String]] { recorder.calls().dropFirst(count).map(\.arguments) }

        // 1. The lock changed hands since the plan named it: refused at the probe, nothing asked.
        let parsedID = locked.lock?.id ?? ""
        backend.releaseLock("acme-shared")
        let other = backend.holdLock("acme-shared", who: "ci@globex-runner-9", id: "5b1d0c7e-acme-0000-0000-00000000beef")
        var before = recorder.calls().count
        let changed = await app.forceUnlock(locked)
        if case .refused(let why) = changed {
            check("a lock that changed hands is refused, the new holder named", why.contains("changed hands") && why.contains("ci@globex-runner-9"), why)
        } else {
            check("a lock that changed hands is refused", false, "\(changed)")
        }
        check("before any sheet", asked.sheets.isEmpty)
        check("the other lock untouched", backend.heldLock("acme-shared") == other && other.id != parsedID)
        check("probed with state rm -dry-run, never a plan", calls(since: before) == [TerraformCommands.lockProbe], "\(calls(since: before))")
        check(
            "said under the lock", await eventually(5) { Self.accessibilityElement("terraform.plan.unlockNote", in: root)?.text.contains("changed hands") == true })

        // 2. Planned again: the new holder named, its lock the one to force.
        app.planTerraformRoot(card)
        check(
            "the plan names the new holder",
            await eventually(40) { pane.run !== locked && pane.run?.lock?.id == other.id && pane.run?.isGoing == false },
            "\(String(describing: pane.run?.phase))")
        guard let run = pane.run, run.lock?.id == other.id else { return }

        // 2b. Refused before anything runs: a run no longer shown, and while
        // Overterm's own run holds the state's turn (its lock is Overterm's).
        before = recorder.calls().count
        let notShown = await app.forceUnlock(locked)
        check("a run no longer shown is refused", notShown == .refused("Force unlock is offered only for a lock a plan in this window was refused by."), "\(notShown)")
        let key = run.identity?.description ?? card.folder.path
        let registry = TerraformRunRegistry.shared
        check("the state's turn taken by another run", registry.take(key, id: "e2e-holder"))
        let busy = await app.forceUnlock(run)
        registry.release(key)
        if case .refused(let why) = busy {
            check("refused while Overterm's own run holds the state", why.contains("Overterm's own"), why)
        } else {
            check("refused while Overterm's own run holds the state", false, "\(busy)")
        }
        check("nothing probed, nothing unlocked", calls(since: before).isEmpty && asked.sheets.isEmpty, "\(calls(since: before))")
        check("the lock still held", backend.heldLock("acme-shared") == other)

        // 3. A wrong name, then Cancel: nothing unlocked.
        asked.answer = { _ in "envs/shard" }
        before = recorder.calls().count
        let wrong = await app.forceUnlock(run)
        check("a wrong name unlocks nothing", wrong == .refused("The name typed wasn't envs/shared: nothing was unlocked."), "\(wrong)")
        asked.answer = { _ in nil }
        check("Cancel unlocks nothing", await app.forceUnlock(run) == .cancelled)
        check("the lock still held", backend.heldLock("acme-shared") == other)
        check("no force-unlock ran", !calls(since: before).contains { $0.first == "force-unlock" }, "\(calls(since: before))")
        let sheet = asked.sheets.last
        check("the sheet asks for the root's name", sheet?.typedName == "envs/shared", sheet?.typedName ?? "none")
        check(
            "it names the holder, the collision and the http backend's empty UNLOCK",
            sheet.map { $0.detail.contains("ci@globex-runner-9") && $0.detail.contains(TerraformUnlock.warning) && $0.detail.contains(TerraformUnlock.httpWarning) }
                == true, sheet?.detail ?? "")

        // 4. The root's name typed: probed again just before, then that lock forced.
        asked.answer = { $0.typedName }
        backend.forgetRequests()
        before = recorder.calls().count
        let unlocked = await app.forceUnlock(run)
        if case .unlocked(let said) = unlocked {
            check("unlocked", said.contains(other.id), said)
        } else {
            check("unlocked", false, "\(unlocked)")
        }
        check("the lock is gone", backend.heldLock("acme-shared") == nil)
        check(
            "the probe ran just before the unlock, of that ID",
            calls(since: before) == [TerraformCommands.lockProbe, TerraformCommands.lockProbe, TerraformCommands.forceUnlock(id: other.id)!], "\(calls(since: before))")
        check("its UNLOCK went with an empty body", backend.requests.last { $0.method == "UNLOCK" }?.body == Data())
        check("nothing written to the state", !backend.requests.contains { $0.method == "POST" || $0.method == "DELETE" })
        check("said under the lock", await eventually(5) { Self.accessibilityElement("terraform.plan.unlockNote", in: root)?.text.hasPrefix("Unlocked") == true })
        check("Force Unlock no longer offered", await eventually(5) { !Self.accessibilityPress("terraform.plan.forceUnlock", in: root, press: false) })
    }
}

/// The scenario's answers to the force-unlock sheet, and the sheets asked.
@MainActor
private final class UnlockSheets {
    var sheets: [TerraformUnlock.Sheet] = []
    var answer: (TerraformUnlock.Sheet) -> String? = { _ in nil }
}
