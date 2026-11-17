import AppKit

/// Left Behind's verbs that change processes (docs/design/activity/
/// analysis.md, 6.9): a bulk Stop of the certain rows of one group, asked
/// in one sheet listing each, then each stopped by its identity through
/// `ProcessSignals` — never one that ended or became another program.
extension TerminalWindowController {
    /// Stop All Certain in This Checkout…: `rows`, each listed. At the
    /// button each is read again and must still be certain, eligible and
    /// not kept — from this window or another — or it is left out, said.
    func leftBehindStopAll(_ rows: [ActivityProcessRow], group: String) {
        guard !rows.isEmpty, let window else { return }
        let targets = rows.map { ActivitySignalTarget($0.identity, path: $0.path) }
        let confirmation = WriteConfirmation(
            title: "Stop \(rows.count == 1 ? "1 process" : "\(rows.count) processes") left behind in \(group)?",
            detail: Self.leftBehindListing(rows) + "\n\nEach gets SIGTERM, by the process listed: one that ended or runs another program since is left alone.",
            button: rows.count == 1 ? "Stop Process" : "Stop \(rows.count) Processes")
        confirmation.present(on: window) { [weak self] _ in self?.leftBehindStop(targets, pick: .certain) }
    }

    /// "acme-server (pid 4242) :3001 — left by Claude in “web”…", a line each.
    static func leftBehindListing(_ rows: [ActivityProcessRow]) -> String {
        rows.prefix(20).map { row in
            var line = "\(DockerMCP.displayed(row.name)) (pid \(row.identity.pid))"
            if !row.listening.isEmpty { line += " " + row.listening.prefix(3).map { ":\($0)" }.joined(separator: " ") }
            if let reason = row.owner?.reason { line += " — \(reason)" }
            return line
        }.joined(separator: "\n") + (rows.count > 20 ? "\n…and \(rows.count - 20) more" : "")
    }

    /// `targets` read again from a fresh census and asked of the policy
    /// (`LeftBehindStop`): what may be sent SIGTERM, and what not, with why.
    /// Nil when there is no census: then nothing is sent.
    func leftBehindChecked(_ targets: [ActivitySignalTarget], pick: LeftBehindStop.Pick) async -> LeftBehindStop.Checked? {
        let kept = LeftBehindLedger.shared.kept
        return await activityRead { snapshot, owners, known in
            LeftBehindStop.check(targets, pick: pick, in: snapshot, owners: owners, known: known, kept: kept)
        }
    }

    /// SIGTERM to each the policy lets a Stop send now, off the main thread;
    /// what wasn't sent, or was refused, is said.
    func leftBehindStop(_ targets: [ActivitySignalTarget], pick: LeftBehindStop.Pick = .bulk) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let checked = await self.leftBehindChecked(targets, pick: pick) else {
                return self.tell("Not sent", "The processes couldn't be read again: nothing was sent.")
            }
            self.leftBehindSend(checked)
        }
    }

    private func leftBehindSend(_ checked: LeftBehindStop.Checked) {
        let targets = checked.send
        let refused = checked.refused
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let signals = ProcessSignals()
            let answers = targets.map { (target: $0, answer: signals.send(.term, to: $0, alone: false)) }
            Task { @MainActor [weak self] in
                let unsent = answers.filter { if case .sent = $0.answer { false } else { true } }
                let total = answers.count + refused.count
                let stopped = answers.count - unsent.count
                self?.activityPage.freeing =
                    stopped == total
                    ? "Stopped \(total == 1 ? "1 process" : "\(total) processes") left behind"
                    : "Stopped \(stopped) of \(total) left behind"
                guard !unsent.isEmpty || !refused.isEmpty, let window = self?.window else { return }
                let alert = NSAlert()
                alert.messageText = "Stopped \(stopped) of \(total)"
                let lines =
                    refused.prefix(20).map { DockerMCP.displayed($0.line) }
                    + unsent.map {
                        "pid \($0.target.identity.pid): \(ActivityPortFree.answer($0.answer, pid: $0.target.identity.pid) ?? "not sent")"
                    }
                alert.informativeText = lines.joined(separator: "\n")
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        }
    }
}

/// Kept and stopped identities across a crash (D-29): at launch the file is
/// read back and swept by one census; what Activity stopped and still is
/// stopped is offered for Resume — Leave Stopped puts it back among what
/// Activity holds, so the header's Resume All and the quit question know it.
extension TerminalWindowController {
    /// The launch's read (and a scenario's "next launch").
    func activityRestoreAtLaunch() async {
        guard let snapshot = await ActivityMonitor.shared.census() else { return }
        let stopped = ActivityPersistence.shared.restore(from: snapshot)
        guard !stopped.isEmpty else { return }
        offerResume(stopped, in: snapshot)
    }

    /// "Activity stopped 2 processes before Overterm last quit": Resume or
    /// Leave Stopped, each listed by name and pid as the census reads it now.
    func offerResume(_ stopped: Set<ActivityProcessID>, in snapshot: ActivitySnapshot) {
        guard let window else { return }
        let listed = stopped.sorted().compactMap { identity -> (target: ActivitySignalTarget, name: String)? in
            guard snapshot.table.process(identity) != nil else { return nil }
            return (ActivitySignalTarget(identity, path: snapshot.facts[identity]?.path), snapshot.name(of: identity) ?? "a process")
        }
        guard !listed.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText =
            listed.count == 1
            ? "Activity stopped “\(DockerMCP.displayed(listed[0].name))” before Overterm last quit"
            : "Activity stopped \(listed.count) processes before Overterm last quit"
        alert.informativeText =
            listed.prefix(20).map { "\(DockerMCP.displayed($0.name)) (pid \($0.target.identity.pid))" }.joined(separator: "\n")
            + "\n\nThey are still stopped. Resume continues each, by the process listed."
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Leave Stopped")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                let targets = listed.map(\.target)
                DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                    let answers = targets.map { (target: $0, answer: ProcessSignals().send(.cont, to: $0, alone: false)) }
                    Task { @MainActor in
                        let sent = answers.count { if case .sent = $0.answer { true } else { false } }
                        self?.activityPage.freeing = "Resumed \(sent) of \(answers.count) stopped before Overterm last quit"
                    }
                }
            } else {
                for (target, name) in listed {
                    ActivityHeld.shared.suspended(root: target, name: name, members: [target], names: [target.identity: name])
                }
            }
        }
    }
}

/// The close sheet's survivors (6.9, D-16): what closing tabs or a pane
/// leaves running, read from a fresh one-off census taken off the main
/// thread — bounded: none in time, none said — and listed with a checkbox
/// each, all unticked. A ticked one is stopped by its identity after the
/// close; an unticked one is kept.
extension TerminalWindowController {
    /// How long a close waits for its census.
    static let closeCensusLimit: Duration = .seconds(1)

    func closeSurvivors(_ panes: [TerminalView]) async -> ActivitySurvivors {
        guard let snapshot = await Self.census(within: Self.closeCensusLimit) else { return ActivitySurvivors() }
        return Self.survivors(of: panes, in: snapshot)
    }

    static func survivors(of panes: [TerminalView], in snapshot: ActivitySnapshot) -> ActivitySurvivors {
        var terminals: [String: dev_t] = [:]
        for pane in panes { terminals[pane.processTag] = pane.terminalDevice }
        return ActivitySurvivors.of(
            panes.map(\.processTag), in: snapshot, terminals: terminals, checkouts: activityTabFacts().checkouts, kept: LeftBehindLedger.shared.kept)
    }

    /// Whether the latest census says something of `panes` will keep
    /// running: under "only when something is running" that counts (D-16).
    static func hasSurvivors(_ panes: [TerminalView]) -> Bool {
        guard let snapshot = ActivityMonitor.shared.snapshot else { return false }
        return survivors(of: panes, in: snapshot).anyKeepRunning
    }

    /// What the latest census says goes on running after closing `panes`,
    /// for a sheet with no checkboxes — a window's close, quitting: named,
    /// so a question asked for it alone says why. Empty when nothing does.
    static func survivorsListed(_ panes: [TerminalView]) -> String {
        guard let snapshot = ActivityMonitor.shared.snapshot else { return "" }
        let survivors = survivors(of: panes, in: snapshot)
        guard !survivors.isEmpty else { return "" }
        return survivors.listed + "\nActivity ▸ Left Behind lists them once closed."
    }

    /// A one-off census, or nil when none lands within `limit`.
    static func census(within limit: Duration) async -> ActivitySnapshot? {
        let once = CensusOnce()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let snapshot = await ActivityMonitor.shared.census()
                if once.take() { continuation.resume(returning: snapshot) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.take() { continuation.resume(returning: nil) }
            }
        }
    }

    /// The checkboxes under a close sheet, one a survivor, all unticked.
    static func survivorBoxes(_ survivors: ActivitySurvivors) -> (NSView, [(NSButton, ActivitySurvivors.Survivor)])? {
        guard !survivors.all.isEmpty else { return nil }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        var boxes: [(NSButton, ActivitySurvivors.Survivor)] = []
        for survivor in survivors.all {
            let box = NSButton(checkboxWithTitle: "Also stop \(DockerMCP.displayed(survivor.label))", target: nil, action: nil)
            box.state = .off
            box.setAccessibilityIdentifier("close.survivor.\(survivor.identity.pid)")
            stack.addArrangedSubview(box)
            boxes.append((box, survivor))
        }
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: stack.fittingSize.height)
        return (stack, boxes)
    }

    /// After a close: the ticked stopped by identity, the unticked kept.
    func settleSurvivors(_ boxes: [(NSButton, ActivitySurvivors.Survivor)]) {
        let ticked = boxes.filter { $0.0.state == .on }.map(\.1)
        let unticked = boxes.filter { $0.0.state != .on }.map(\.1)
        LeftBehindLedger.shared.keep(unticked.map(\.identity))
        // Each picked alone: the policy's Stop rule, not the bulk one (6.10).
        if !ticked.isEmpty { leftBehindStop(ticked.map { ActivitySignalTarget($0.identity, path: $0.path) }, pick: .picked) }
    }
}

/// One answer of two.
@MainActor
private final class CensusOnce {
    private var taken = false

    func take() -> Bool {
        defer { taken = true }
        return !taken
    }
}
