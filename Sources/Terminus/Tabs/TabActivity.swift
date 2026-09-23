import Foundation

/// Something a terminal reported that can matter to someone not looking.
enum TerminalEvent: Equatable {
    case bell
    case notification(title: String, body: String)
    /// OSC 9;4. `active` for set/indeterminate/pause, false for remove.
    case progress(active: Bool, failed: Bool)
    /// Shell integration: a command ended after `seconds`.
    case commandFinished(exitCode: Int?, seconds: Double)
}

/// Whether a tab is busy and whether it wants you — the tab-strip dot and
/// spinner, the notification and the Dock badge all come from this.
struct TabActivity: Equatable {
    private(set) var isWorking = false
    private(set) var needsAttention = false
    /// What to say about it, when there is something specific.
    private(set) var note: String?

    /// A foreground command shorter than this finishing is not news.
    static let longCommand: Double = 10

    /// Applies an event. `visible`: the tab is selected in the key window of
    /// the active app — then nothing needs flagging, you saw it happen.
    /// Returns true when the tab has just started needing attention.
    @discardableResult
    mutating func handle(_ event: TerminalEvent, visible: Bool) -> Bool {
        var wantsYou = false
        switch event {
        case .bell:
            wantsYou = true
        case .notification(let title, let body):
            wantsYou = true
            note = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
        case .progress(let active, let failed):
            let finished = isWorking && !active
            isWorking = active
            if failed {
                wantsYou = true
                note = "Failed"
            } else if finished {
                wantsYou = true
            }
        case .commandFinished(let exitCode, let seconds):
            if seconds >= Self.longCommand {
                wantsYou = true
                note = exitCode.map { $0 == 0 ? "Command finished" : "Command failed (exit \($0))" } ?? "Command finished"
            }
        }
        guard wantsYou, !visible, !needsAttention else { return false }
        needsAttention = true
        return true
    }

    /// You looked at the tab.
    mutating func seen() {
        needsAttention = false
        note = nil
    }
}
