import Foundation

/// Something a terminal reported that can matter to someone not looking.
enum TerminalEvent: Equatable {
    case bell
    case notification(title: String, body: String)
    /// OSC 9;4. `active` for set/indeterminate/pause, false for remove.
    case progress(active: Bool, failed: Bool)
    /// Shell integration: a command ended after `seconds`.
    case commandFinished(exitCode: Int?, seconds: Double)
    /// The viewport moved in the scrollback: `total` rows exist, the top of
    /// the view is row `offset`, and `rows` of them are on screen. Pushed by
    /// libghostty whenever it changes; there is no way to ask for it.
    case scrolled(total: UInt64, offset: UInt64, rows: UInt64)
    /// The pointer entered a link, or left one (nil).
    case linkHover(String?)
}

/// Whether a tab is busy and what it has to tell you — the tab-strip marks,
/// the notification and the Dock badge all come from this.
///
/// Claude Code needs no setup for it (checked against 2.1.280): it sees
/// TERM_PROGRAM=ghostty, so its default notification channel ("auto")
/// sends Ghostty's OSC 777 desktop notification when it wants input, and
/// its default-on terminalProgressBarEnabled emits OSC 9;4 while working —
/// spinner while it works, flagged when it finishes out of sight.
struct TabActivity: Equatable {
    /// What a tab has to tell you, by urgency. A tab shows the most urgent
    /// one it has had since you last looked.
    enum Mark: Int, Comparable {
        case none
        /// Finished while you weren't looking.
        case done
        /// Failed (error progress, or a long command with a non-zero exit).
        case failed
        /// Wants you: a bell, or the agent's notification (a permission
        /// prompt, a question, "waiting for your input").
        case waiting

        static func < (a: Mark, b: Mark) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var isWorking = false
    private(set) var mark: Mark = .none
    /// What to say about it, when there is something specific.
    private(set) var note: String?

    /// Anything to tell you — the Dock badge counts these.
    var needsAttention: Bool { mark != .none }

    /// A foreground command shorter than this finishing is not news.
    static let longCommand: Double = 10

    /// Applies an event. `visible`: the tab is selected in the key window of
    /// the active app — then nothing needs marking, you saw it happen.
    /// Working state is tracked either way. Returns true when the mark just
    /// went up (the moment to notify).
    @discardableResult
    mutating func handle(_ event: TerminalEvent, visible: Bool) -> Bool {
        var raised: Mark = .none
        var text: String?
        switch event {
        case .bell:
            raised = .waiting
        case .notification(let title, let body):
            raised = .waiting
            text = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
        case .progress(let active, let failed):
            let finished = isWorking && !active
            isWorking = active
            if failed {
                raised = .failed
                text = "Failed"
            } else if finished {
                raised = .done
                text = "Finished"
            }
        case .commandFinished(let exitCode, let seconds):
            if seconds >= Self.longCommand {
                let ok = exitCode.map { $0 == 0 } ?? true
                raised = ok ? .done : .failed
                text = ok ? "Command finished" : "Command failed (exit \(exitCode ?? -1))"
            }
        case .scrolled, .linkHover:
            // Neither is news about the tab — they are the terminal
            // reporting where it is, for the scroll map and the link
            // popovers. They go past here on their way to the window.
            return false
        }
        // A new signal means the agent moved on: a question answered, work resumed.
        if case .progress(true, _) = event, mark == .waiting { mark = .none }
        guard raised != .none, !visible, raised > mark else { return false }
        mark = raised
        note = text
        return true
    }

    /// You looked at the tab.
    mutating func seen() {
        mark = .none
        note = nil
    }
}
