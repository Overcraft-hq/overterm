import AppKit

/// A pane pill's Stop… on a process's port (`PortStop`). A forward's and a
/// container's go to their owners before this (the header's `killPort`).
extension TerminalWindowController {
    /// Read again, asked, read again, and only then signalled: a process
    /// gone already, or its pid another's, is said at once, nothing asked;
    /// one that changed while the question was up is said after it, and is
    /// sent nothing.
    func stopListener(_ port: ListeningPort) {
        Task { @MainActor [weak self] in
            let opening = await PortStop.opening(port)
            guard let self, let window = self.window else { return }
            guard opening.check == .same else { return self.sayNotStopped(.refused(opening.check), port) }
            PortStop.confirmation(for: port, command: opening.command).present(on: window) { [weak self] _ in
                Task { @MainActor [weak self] in
                    let outcome = await PortStop.signal(port)
                    self?.sayNotStopped(outcome, port)
                }
            }
        }
    }

    /// Why nothing was sent, or what kill(2) said, as a sheet; nothing once it was sent.
    private func sayNotStopped(_ outcome: PortStop.Outcome, _ port: ListeningPort) {
        guard let window, let said = PortStop.refusal(outcome, port: port) else { return }
        let alert = NSAlert()
        alert.messageText = said.title
        alert.informativeText = said.detail
        alert.beginSheetModal(for: window)
    }
}
