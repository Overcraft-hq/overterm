import AppKit

/// New Task's text (GIT-G11, P05): typed into the task's agent once it is
/// up, then Return — so the task is said once, in the sheet.
extension TerminalWindowController {
    /// How a text's sending ended.
    package enum TaskTextOutcome: Equatable {
        case sent
        /// The agent never came up, the tab went, or it stood at a
        /// Terraform ask: nothing typed, the text offered to copy.
        case notSent(String)
    }

    /// Waits for `tab`'s agent (`TaskPromptWait`): the census says it is
    /// the focused pane's foreground process, its screen stops changing.
    /// Then the text, as a paste, and Return on its own — a paste's last
    /// newline is literal, never a Return. Not into a tab at a Terraform
    /// ask (3.3): the text would land in the agent's permission prompt.
    @discardableResult
    package func sendTaskText(
        _ text: String, to tab: Tab, branch: String, timeout: TimeInterval = TaskPromptWait.timeout, now: () -> Date = Date.init
    ) async -> TaskTextOutcome {
        let pane = tab.terminal
        var wait = TaskPromptWait(started: now(), timeout: timeout)
        while true {
            guard store.tabs.contains(where: { $0 === tab }), tab.terminals.contains(where: { $0 === pane }) else {
                return taskTextNotSent(text, branch: branch, why: "Its tab was closed before its agent started.")
            }
            let running: Bool
            if let login = SurfaceProcesses.shared.loginPID(of: pane) {
                let tag = pane.processTag
                running = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: Self.foregroundAgent(login: login, tag: tag, inspector: ProcessInspector()) != nil)
                    }
                }
            } else {
                running = false
            }
            switch wait.step(now: now(), agentRunning: running, screen: pane.visibleText) {
            case .wait:
                try? await Task.sleep(for: .seconds(TaskPromptWait.interval))
            case .giveUp:
                return taskTextNotSent(text, branch: branch, why: "Its agent didn't start within \(Int(timeout)) seconds.")
            case .deliver:
                guard !terraformAsking(tab) else {
                    return taskTextNotSent(text, branch: branch, why: "Its agent is asking about a Terraform write.")
                }
                pane.insertText(text)
                // The paste settles before Return: an agent reading a paste
                // takes a Return in the same burst as part of it.
                try? await Task.sleep(for: .milliseconds(300))
                pane.pressReturn()
                return .sent
            }
        }
    }

    /// Said once, the text offered to copy: it isn't lost.
    private func taskTextNotSent(_ text: String, branch: String, why: String) -> TaskTextOutcome {
        let outcome = TaskTextOutcome.notSent(why)
        if let taskTextRecorder { taskTextRecorder(outcome); return outcome }
        guard let window else { return outcome }
        let alert = NSAlert()
        alert.messageText = "The task for \(branch) wasn't sent"
        alert.informativeText = why + " Nothing was typed into the tab."
        alert.addButton(withTitle: "Copy the Task")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return outcome
    }
}

/// A setup command that isn't one line: refused before the worktree is made.
package struct TaskSetupProblem: LocalizedError {
    package var message: String
    package var errorDescription: String? { message }
}

extension TerminalWindowController {
    /// What New Task's setup didn't copy, and why — said once; the task
    /// goes on without it.
    package func tellTaskSetupSkipped(_ report: TaskSetupCopy.Report, branch: String) {
        if let taskSetupRecorder { return taskSetupRecorder(report) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = report.skipped.count == 1 ? "One file wasn't copied into \(branch)" : "\(report.skipped.count) files weren't copied into \(branch)"
        alert.informativeText = report.skipped.map { "\($0.path): \($0.why)." }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
