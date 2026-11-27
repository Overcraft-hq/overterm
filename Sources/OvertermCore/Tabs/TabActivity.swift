import Foundation

/// Something a terminal reported that can matter to someone not looking.
package enum TerminalEvent: Equatable {
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
package struct TabActivity: Equatable {
    /// What a tab has to tell you, by urgency. A tab shows the most urgent
    /// one it has had since you last looked.
    package enum Mark: Int, Comparable {
        case none
        /// Finished while you weren't looking.
        case done
        /// Failed (error progress, or a long command with a non-zero exit).
        case failed
        /// Wants you: a bell, or the agent's notification (a permission
        /// prompt, a question, "waiting for your input").
        case waiting

        package static func < (a: Mark, b: Mark) -> Bool { a.rawValue < b.rawValue }
    }

    package private(set) var isWorking = false
    package private(set) var mark: Mark = .none {
        didSet {
            if mark != .waiting {
                waitingSince = nil
            } else if oldValue != .waiting {
                waitingSince = Date()
            }
        }
    }
    /// Since when the tab waits for you (`.waiting`): what Activity's "idle
    /// but burning" counts from (docs/design/activity/analysis.md, 6.11).
    package private(set) var waitingSince: Date?
    /// What to say about it, when there is something specific.
    package private(set) var note: String?
    /// The mark is a cluster's (`clusterFailed`): it goes on its own once
    /// what failed has (`clusterRecovered`).
    package private(set) var fromCluster = false
    /// The mark is a Terraform ask's (`terraformAsked`): it goes once the
    /// ask has left the screen (`terraformAnswered`).
    package private(set) var fromTerraform = false
    /// The mark is Left Behind's (`leftBehind`): an agent run that ended
    /// left processes running (docs/design/activity/analysis.md, 6.9, D-17).
    package private(set) var fromLeftBehind = false
    /// The mark is the screen check's (`agentAsked`, `AgentScreenCheck`):
    /// it goes once the question has left the screen (`agentAnswered`).
    package private(set) var fromScreen = false
    /// The mark is CI's (`ciFailed`): the tab's branch's pull request went
    /// red; it goes once CI is green again (`ciRecovered`).
    package private(set) var fromCI = false
    /// The mark is an agent's MCP write asked (`mcpAsked`, MCPApprovals):
    /// it goes once that request is answered or ends (`mcpAnswered`), while
    /// its words are still the note.
    package private(set) var fromMCP = false

    package init(waitingSince: Date? = nil, note: String? = nil) {
        self.waitingSince = waitingSince
        self.note = note
    }

    /// Anything to tell you — the Dock badge counts these.
    package var needsAttention: Bool { mark != .none }

    /// A foreground command shorter than this finishing is not news.
    package static let longCommand: Double = 10

    /// Applies an event. `visible`: the tab is selected in the key window of
    /// the active app — then nothing needs marking, you saw it happen.
    /// Working state is tracked either way. Returns true when the mark just
    /// went up (the moment to notify).
    @discardableResult
    package mutating func handle(_ event: TerminalEvent, visible: Bool) -> Bool {
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
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = false
        return true
    }

    /// An agent run in the tab ended and left processes running (6.9,
    /// D-17): "Claude finished — left node :3001 running". `.done`, never
    /// `.failed` — the agent did finish —, looked at or not: what it left
    /// isn't on the screen. Under a higher mark the mark stays; a newer
    /// Left Behind note says itself over the last. True when the mark or
    /// its words just changed and nobody is looking (the moment to notify).
    @discardableResult
    package mutating func leftBehind(_ text: String, visible: Bool) -> Bool {
        guard mark < .done || (mark == .done && (fromLeftBehind || note != text)) else { return false }
        let changed = mark != .done || note != text
        mark = .done
        note = text
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = true
        fromCI = false
        fromScreen = false
        fromCI = false
        return changed && !visible
    }

    /// A pane of the tab asks for a Terraform write (TerraformPrompt,
    /// analysis 3.3): marked waiting, with what it asks — looked at or not:
    /// a person's own pane gets the mark, and the caller notifies only for
    /// an agent's. True when the mark or its words just changed and nobody
    /// is looking (the moment to notify).
    @discardableResult
    package mutating func terraformAsked(_ text: String, visible: Bool) -> Bool {
        let changed = mark != .waiting || note != text
        mark = .waiting
        note = text
        fromCluster = false
        fromTerraform = true
        fromCI = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = false
        return changed && !visible
    }

    /// The ask left the screen (answered, in the tab): its mark goes,
    /// unless something else has marked the tab since.
    @discardableResult
    package mutating func terraformAnswered() -> Bool {
        guard fromTerraform, mark == .waiting else { return false }
        seen()
        return true
    }

    /// An agent that sent no signal asks something on a pane's screen
    /// (`AgentScreenCheck`): marked waiting with its question, unless the
    /// tab is in front of you. True when the mark or its words just
    /// changed (the moment to notify).
    @discardableResult
    package mutating func agentAsked(_ text: String, visible: Bool) -> Bool {
        guard !visible, mark < .waiting || (mark == .waiting && fromScreen && note != text) else { return false }
        mark = .waiting
        note = text
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = true
        fromCI = false
        return true
    }

    /// The question left the screen (answered, in the tab): its mark goes,
    /// unless something else has marked the tab since.
    @discardableResult
    package mutating func agentAnswered() -> Bool {
        guard fromScreen, mark == .waiting else { return false }
        seen()
        return true
    }

    /// A container of the tab's checkout went wrong on its own
    /// (DockerAttention): a failure, as a long command failing is. Returns
    /// true when the mark just went up.
    @discardableResult
    package mutating func containerFailed(_ text: String, visible: Bool) -> Bool {
        guard !visible, Mark.failed > mark else { return false }
        mark = .failed
        note = text
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = false
        return true
    }

    /// What the tab's checkout deploys failed in its bound namespace
    /// (KubeAttention): a failure, as a container's is — and a newer one
    /// says itself over the last cluster mark, which isn't news any more.
    /// Returns true when the mark just went up (or said something new).
    @discardableResult
    package mutating func clusterFailed(_ text: String, visible: Bool) -> Bool {
        guard !visible else { return false }
        guard Mark.failed > mark || (mark == .failed && fromCluster && note != text) else { return false }
        mark = .failed
        note = text
        fromCluster = true
        fromCI = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = false
        return true
    }

    /// A cluster failure that came while the tab's mark is something
    /// else's — an agent waiting for you (higher), a command that failed:
    /// the mark stays what it is, but the failure is still news and is
    /// told (`markClusterFailure`), with Ask Why on the tab's alerts.
    package func clusterNewsUnderOtherMark(visible: Bool) -> Bool {
        !visible && (mark > .failed || (mark == .failed && !fromCluster))
    }

    /// Every cluster failure behind the mark has gone (its pods replaced,
    /// its rollout progressing): the mark goes, unless something else has
    /// marked the tab since.
    @discardableResult
    package mutating func clusterRecovered() -> Bool {
        guard fromCluster, mark == .failed else { return false }
        seen()
        return true
    }

    /// The tab's branch's pull request went red (GIT-G5): a failure, as a
    /// container's is — a newer one says itself over the last CI mark.
    /// Returns true when the mark just went up (or said something new).
    @discardableResult
    package mutating func ciFailed(_ text: String, visible: Bool) -> Bool {
        guard !visible else { return false }
        guard Mark.failed > mark || (mark == .failed && fromCI && note != text) else { return false }
        mark = .failed
        note = text
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = true
        return true
    }

    /// Its CI is green again: the mark goes, unless something else has
    /// marked the tab since.
    @discardableResult
    package mutating func ciRecovered() -> Bool {
        guard fromCI, mark == .failed else { return false }
        seen()
        return true
    }

    /// You looked at the tab.
    /// An agent's MCP call asks for a write (D-6, MCPApprovals): marked
    /// waiting with what it asks, looked at or not — the sheet shows over
    /// a tab in front. True when the mark or its words just changed and
    /// nobody is looking (the moment to notify).
    @discardableResult
    package mutating func mcpAsked(_ text: String, visible: Bool) -> Bool {
        let changed = mark != .waiting || note != text
        mark = .waiting
        note = text
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = false
        fromMCP = true
        return changed && !visible
    }

    /// The request was answered, or ran out of time: its mark goes, unless
    /// something else has marked the tab since (its note is another's).
    @discardableResult
    package mutating func mcpAnswered(_ text: String) -> Bool {
        guard fromMCP, mark == .waiting, note == text else { return false }
        seen()
        return true
    }

    package mutating func seen() {
        fromMCP = false
        mark = .none
        note = nil
        fromCluster = false
        fromTerraform = false
        fromLeftBehind = false
        fromScreen = false
        fromCI = false
    }
}
