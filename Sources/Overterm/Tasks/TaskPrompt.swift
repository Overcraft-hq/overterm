import Foundation

/// When New Task's text goes to its agent (GIT-G11, P05): no agent CLI says
/// it is ready for input, so the text waits for the agent to be the pane's
/// foreground process, then for its screen to stop changing — its own
/// prompt drawn — and goes then, once. Never after `timeout`: an agent that
/// didn't start isn't typed into, the shell would run the text. Pure.
package struct TaskPromptWait {
    /// How long the screen stays as it is, with the agent there, before
    /// the text goes.
    package static let settle: TimeInterval = 1.5
    /// How long the agent has to start.
    package static let timeout: TimeInterval = 60
    /// …after a setup command, typed before it (`npm ci` takes minutes).
    package static let timeoutAfterSetup: TimeInterval = 20 * 60
    /// How often it looks.
    package static let interval: TimeInterval = 0.4

    package enum Step: Equatable { case wait, deliver, giveUp }

    private let started: Date
    private let timeout: TimeInterval
    private var agentSince: Date?
    private var screen: String?
    private var screenSince: Date?

    package init(started: Date, timeout: TimeInterval = TaskPromptWait.timeout) {
        self.started = started
        self.timeout = timeout
    }

    /// One look: whether the agent is the pane's foreground process now,
    /// and what its screen says.
    package mutating func step(now: Date, agentRunning: Bool, screen: String?) -> Step {
        if now.timeIntervalSince(started) > timeout { return .giveUp }
        guard agentRunning else {
            agentSince = nil
            return .wait
        }
        if agentSince == nil { agentSince = now }
        guard let screen, !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A blank screen in between: what comes next settles anew.
            self.screen = nil
            screenSince = nil
            return .wait
        }
        if screen != self.screen {
            self.screen = screen
            screenSince = now
            return .wait
        }
        guard let agentSince, let screenSince else { return .wait }
        let settled = now.timeIntervalSince(screenSince) >= Self.settle && now.timeIntervalSince(agentSince) >= Self.settle
        return settled ? .deliver : .wait
    }

    /// What is typed: the text as written, its trailing blank lines and
    /// spaces dropped (Return is pressed on its own); nil when nothing is
    /// left — no task, today's New Task.
    package static func text(_ task: String) -> String? {
        var text = task
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
