import AppKit
import Combine

/// One pane's command ledger, kept up to date from what libghostty pushes.
///
/// Also decides when the scroll map is on screen. macOS hides scrollbars
/// until you scroll unless you have asked for them always, and a map that
/// is always there would cost every pane 16 pt of width for something you
/// look at while scrolling — so it follows the same rule as the system's
/// own.
@MainActor
final class PaneBlocks: ObservableObject {
    @Published private(set) var ledger = CommandLedger()
    /// Whether the map is drawn right now.
    @Published private(set) var showMap = NSScroller.preferredScrollerStyle == .legacy
    private var hiding: Task<Void, Never>?

    /// How long the map stays after the last scroll, matching the feel of
    /// an overlay scrollbar.
    static let linger: Duration = .milliseconds(1200)

    func handle(_ event: TerminalEvent) {
        switch event {
        case .scrolled(let total, let offset, let rows):
            ledger.scrolled(total: total, offset: offset, rows: rows)
            flashMap()
        case .commandFinished(let exitCode, let seconds):
            ledger.finished(exitCode: exitCode, seconds: seconds)
        case .bell, .notification, .progress, .linkHover:
            break
        }
    }

    /// The shell set its title. With shell integration that is the command
    /// about to run — the only name a command ever gets — except when it
    /// is the directory, which means the prompt came back.
    func titleChanged(_ title: String, cwd: String?) {
        if CommandLedger.isPrompt(title, cwd: cwd) {
            ledger.prompted()
        } else {
            ledger.began(command: title)
        }
    }

    /// Shown while the pointer is over the right edge, as a scrollbar is.
    func hoverMap(_ inside: Bool) {
        hiding?.cancel()
        showMap = inside || NSScroller.preferredScrollerStyle == .legacy
    }

    private func flashMap() {
        guard NSScroller.preferredScrollerStyle != .legacy else { return }
        hiding?.cancel()
        showMap = true
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.showMap = false
        }
    }
}
