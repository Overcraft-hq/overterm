import AppKit

/// Where an agent's write is asked (D-6 (b), P09 / MCP-U1): every MCP
/// call's confirmation — Docker's, a database's, Kubernetes', Terraform's
/// plan — comes here. It is a request held for the calling pane: on that
/// pane's window as today's sheet when the window is already in front, and
/// in the Inbox as a card with the pane's tab marked and a notification
/// otherwise — the app never brings itself forward. Unanswered for
/// `timeout`, the call ends in an error the agent reads; nothing is done.
@MainActor
package final class MCPApprovals: ObservableObject {
    package static let shared = MCPApprovals()

    /// How long a request waits for an answer (D-6: ten minutes).
    package static var timeout: Duration = .seconds(600)

    /// What the agent reads when nobody answered in time.
    package static var timedOutMessage: String {
        "Nobody answered in Overterm within \(minutes(timeout)): nothing was done. Ask again if it is still needed."
    }

    package struct Request: Identifiable, Equatable {
        package let id: UUID
        /// The calling pane's tag (`TerminalView.processTag`), nil when the
        /// call came from no pane.
        package let pane: String?
        package let confirmation: WriteConfirmation
        package let asked: Date

        package static func == (a: Request, b: Request) -> Bool { a.id == b.id }

        /// What the card and the tab's mark say it is about.
        package var summary: String { confirmation.title }
    }

    /// The requests not answered yet, oldest first.
    @Published package private(set) var pending: [Request] = []

    private var continuations: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    /// The sheet a request is shown in, while it is.
    private var sheets: [UUID: (window: NSWindow, alert: NSWindow)] = [:]
    /// A scenario's or a test's: whether a pane's window counts as in front.
    package var inFront: ((NSWindow) -> Bool)?

    package enum Outcome: Equatable {
        /// What was typed ("" when no name was asked).
        case allowed(String)
        case declined
        case timedOut
    }

    /// Asks `confirmation` for `pane`'s call; what was typed, nil when
    /// declined. Throws `BrowserMCP.ToolError` when nobody answered in time.
    package func ask(_ confirmation: WriteConfirmation, pane: String? = MCPAsker.pane) async throws -> String? {
        switch await request(confirmation, pane: pane) {
        case .allowed(let typed): return typed
        case .declined: return nil
        case .timedOut: throw BrowserMCP.ToolError(message: Self.timedOutMessage)
        }
    }

    /// The request, answered: by the sheet, the card, or the clock.
    package func request(_ confirmation: WriteConfirmation, pane: String?) async -> Outcome {
        var asked = confirmation
        if asked.asker == nil { asked.asker = await MCPAsker.current() }
        let request = Request(id: UUID(), pane: pane, confirmation: asked, asked: Date())
        let timeout = Self.timeout
        MCPCallLog.shared.asked()
        let outcome = await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            pending.append(request)
            if let window = MCPAsker.window(forPane: pane), isInFront(window) { showSheet(request.id, on: window) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(request.id, .timedOut)
            }
        }
        MCPCallLog.shared.answered(outcome)
        return outcome
    }

    /// Whether the card's Allow may be pressed: the name typed where the
    /// write asks for one (trimmed, as the callers check it).
    package nonisolated static func accepts(_ typed: String, name: String?) -> Bool {
        guard let name else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines) == name
    }

    /// The card's Allow (with what was typed) or Don't (nil).
    package func answer(_ id: UUID, typed: String?) {
        finish(id, typed.map(Outcome.allowed) ?? .declined)
    }

    /// The oldest request a pane in `panes` made.
    package func first(forPanes panes: Set<String>) -> Request? {
        pending.first { $0.pane.map(panes.contains) ?? false }
    }

    /// A pane's request as today's sheet, on its window — when its tab is
    /// looked at again, or at once when that window is in front. Once.
    package func showSheet(_ id: UUID, on window: NSWindow) {
        guard sheets[id] == nil, window.attachedSheet == nil, let request = pending.first(where: { $0.id == id }) else { return }
        let (alert, field) = request.confirmation.alert()
        sheets[id] = (window, alert.window)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.sheets.removeValue(forKey: id) != nil else { return }
                self.finish(id, response == .alertFirstButtonReturn ? .allowed(field?.stringValue ?? "") : .declined)
            }
        }
    }

    /// Whether `window` is in front: the app active and the window key.
    package func isInFront(_ window: NSWindow) -> Bool {
        if let inFront { return inFront(window) }
        return NSApp.isActive && window.isKeyWindow
    }

    private func finish(_ id: UUID, _ outcome: Outcome) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        // Answered elsewhere (the card, the clock): its sheet goes too.
        if let shown = sheets.removeValue(forKey: id) { shown.window.endSheet(shown.alert, returnCode: .cancel) }
        continuation.resume(returning: outcome)
    }

    private static func minutes(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds < 60 { return seconds == 1 ? "a second" : "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}
