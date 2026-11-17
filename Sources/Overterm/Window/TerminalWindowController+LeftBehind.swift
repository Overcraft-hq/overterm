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
