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

/// Removing a worktree (6.9): what runs in it outside every tab, listed —
/// Stop Them and Remove (asked again in a `WriteConfirmation` listing each;
/// each stoppable one by its identity, through the policy, the removal only
/// once every one is gone), Remove Anyway, Cancel — Cancel the default.
extension TerminalWindowController {
    /// How long the removal waits for what it stopped to end.
    static let worktreeStopWait: TimeInterval = 5
    /// The read's deadline between processes, and the wait for it as a
    /// whole — a folder's read can block for a mount's timeout.
    static let worktreeReadDeadline: UInt64 = 3_000_000_000
    static let worktreeReadLimit: Duration = .seconds(4)

    /// `folder`'s processes: one census, then one sweep off the main thread
    /// under a 3 s deadline, waited for at most 4 s. `complete` false when
    /// either cut it short, or there was no census: then the listing may
    /// miss some, and says so. An isolated run lists only its own (9.9).
    func worktreeProcesses(_ folder: URL) async -> (found: [WorktreeProcess], complete: Bool) {
        guard let snapshot = await Self.census(within: .seconds(2)) else { return ([], false) }
        let paths = Array(Set([folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])).sorted()
        let kept = LeftBehindLedger.shared.kept
        var only: Set<ActivityProcessID>?
        if AppEnvironment.isIsolated {
            var context = ActivityMonitor.shared.context
            LeftBehindLedger.shared.fill(&context)
            only = WorktreeProcesses.runsOwn(
                in: snapshot, tags: Set(context.panes.map(\.tag) + context.retired.map(\.pane.tag)), run: OvertermRun.current.marker)
        }
        let scope = only
        let once = CensusOnce()
        let limit = Self.worktreeReadLimit
        let deadlineSpan = Self.worktreeReadDeadline
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let kernel = LiveActivityKernel()
                let read = WorktreeProcesses.read(
                    paths, in: snapshot, kernel: kernel, app: getpid(), deadline: kernel.uptime() + deadlineSpan, kept: kept, only: scope)
                Task { @MainActor in
                    if once.take() { continuation.resume(returning: read) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.take() { continuation.resume(returning: ([], false)) }
            }
        }
    }

    /// The listing: Cancel the default — a Return stops nothing.
    func askAboutWorktreeProcesses(_ found: [WorktreeProcess], complete: Bool, in worktree: Worktree, force: Bool, repo: URL, on window: NSWindow) {
        let stoppable = found.filter { $0.excluded == nil }
        let alert = NSAlert()
        alert.messageText =
            found.isEmpty
            ? "What runs in “\(worktree.displayName)” couldn’t be read in time"
            : "\(found.count == 1 ? "1 process runs" : "\(found.count) processes run") in “\(worktree.displayName)”"
        var words = found.prefix(20).map { "• " + DockerMCP.displayed($0.line) }.joined(separator: "\n")
        if found.count > 20 { words += "\n…and \(found.count - 20) more" }
        if !found.isEmpty { words += "\n\nRemoving the worktree leaves them running in a deleted folder." }
        if !complete {
            words += (words.isEmpty ? "" : "\n\n") + "The listing may be incomplete: reading each process’s folder and open files took too long."
        }
        alert.informativeText = words
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Anyway")
        if !stoppable.isEmpty { alert.addButton(withTitle: "Stop \(stoppable.count) and Remove…") }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertSecondButtonReturn:
                self.performRemoveWorktree(worktree, force: force, repo: repo)
            case .alertThirdButtonReturn:
                self.confirmStopThenRemove(stoppable, worktree: worktree, force: force, repo: repo, on: window)
            default:
                break
            }
        }
    }

    /// The stop asked as every write is (D-10): each process listed.
    private func confirmStopThenRemove(_ processes: [WorktreeProcess], worktree: Worktree, force: Bool, repo: URL, on window: NSWindow) {
        let confirmation = WriteConfirmation(
            title: "Stop \(processes.count == 1 ? "1 process" : "\(processes.count) processes") and remove “\(worktree.displayName)”?",
            detail: processes.prefix(20).map { "\(DockerMCP.displayed($0.name)) (pid \($0.identity.pid))" }.joined(separator: "\n")
                + (processes.count > 20 ? "\n…and \(processes.count - 20) more" : "")
                + "\n\nEach gets SIGTERM, by the process listed, where Activity’s policy allows a Stop; the worktree goes once every one has ended.",
            button: processes.count == 1 ? "Stop and Remove" : "Stop \(processes.count) and Remove")
        confirmation.present(on: window) { [weak self] _ in self?.stopThenRemove(processes, worktree: worktree, force: force, repo: repo) }
    }

    /// Each read again and asked of the policy, then SIGTERM by its
    /// identity; the removal once every one is gone, else "still running —
    /// Remove Anyway?" naming what was refused.
    private func stopThenRemove(_ processes: [WorktreeProcess], worktree: Worktree, force: Bool, repo: URL) {
        let targets = processes.map { ActivitySignalTarget($0.identity, path: $0.path) }
        let wait = Self.worktreeStopWait
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let checked = await self.leftBehindChecked(targets, pick: .bulk) else {
                return self.tell("Not removed", "The processes couldn’t be read again: nothing was sent, nothing removed.")
            }
            let sending = checked.send
            let refused = checked.refused.filter { $0.reason != LeftBehindStop.endedWords }
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let signals = ProcessSignals()
                for target in sending { _ = signals.send(.term, to: target, alone: false) }
                let kernel = LiveActivityKernel()
                let until = Date().addingTimeInterval(wait)
                var running = sending
                while !running.isEmpty, Date() < until {
                    running = running.filter { target in kernel.process(target.identity.pid).map { $0.identity == target.identity && !$0.isZombie } ?? false }
                    if !running.isEmpty { usleep(100_000) }
                }
                let left = running.map(\.identity.pid)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !left.isEmpty || !refused.isEmpty, let window = self.window else {
                        return self.performRemoveWorktree(worktree, force: force, repo: repo)
                    }
                    var lines = refused.prefix(20).map { "Not stopped — " + DockerMCP.displayed($0.line) }
                    if !left.isEmpty { lines.append("pid \(left.map(String.init).joined(separator: ", ")) didn’t end within \(Int(wait)) s.") }
                    let alert = NSAlert()
                    alert.messageText = "Still running — Remove Anyway?"
                    alert.informativeText = lines.joined(separator: "\n")
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Remove Anyway")
                    alert.buttons[0].keyEquivalent = "\r"
                    alert.buttons[1].keyEquivalent = ""
                    alert.beginSheetModal(for: window) { [weak self] response in
                        guard response == .alertSecondButtonReturn else { return }
                        self?.performRemoveWorktree(worktree, force: force, repo: repo)
                    }
                }
            }
        }
    }
}

/// The launch check (6.9, D-14): 10 s after launch — never in an isolated
/// run — one census lists what an earlier Overterm left, with one asked
/// Stop All, Show and Later. Nothing is stopped automatically.
extension TerminalWindowController {
    static let launchCheckDelay: Duration = .seconds(10)

    func leftBehindAtLaunch() async {
        guard Settings.shared.activityEnabled, let snapshot = await Self.census(within: .seconds(5)) else { return }
        let context = ActivityMonitor.shared.context
        let facts = Self.activityTabFacts()
        let found = await PaneAgent.offMain {
            LeftBehindAtLaunch.of(
                snapshot, owners: ActivityAttribution.of(snapshot, context: context, inputs: ActivityAttribution.Inputs(tabs: facts.tabs, checkouts: facts.checkouts)))
        }
        guard !found.isEmpty, let window else { return }
        let stops = found.all.filter(\.stops)
        let alert = NSAlert()
        alert.messageText = DockerMCP.displayed(found.title)
        alert.informativeText = DockerMCP.displayed(found.detail)
        alert.addButton(withTitle: stops.isEmpty ? "Show" : "Stop \(stops.count)…")
        if !stops.isEmpty { alert.addButton(withTitle: "Show") }
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let show = stops.isEmpty ? response == .alertFirstButtonReturn : response == .alertSecondButtonReturn
            if show { return self.showActivityPage(.leftBehind) }
            guard !stops.isEmpty, response == .alertFirstButtonReturn else { return }
            let confirmation = WriteConfirmation(
                title: "Stop \(stops.count == 1 ? "1 process" : "\(stops.count) processes") an earlier Overterm left?",
                detail: stops.prefix(20).map { "\(DockerMCP.displayed($0.name)) (pid \($0.identity.pid))" }.joined(separator: "\n")
                    + "\n\nEach gets SIGTERM, by the process listed.",
                button: stops.count == 1 ? "Stop Process" : "Stop \(stops.count) Processes")
            confirmation.present(on: window) { [weak self] _ in
                self?.leftBehindStop(stops.map { ActivitySignalTarget($0.identity, path: $0.path) })
            }
        }
    }
}
