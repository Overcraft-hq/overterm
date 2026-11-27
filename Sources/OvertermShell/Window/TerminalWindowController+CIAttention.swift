import AppKit
import Combine

/// CI gone red on a branch a tab has open (GIT-G5, FLOW-N2): the tab
/// marked, the Inbox's card, the failed step's log, and Ask Agent to Fix —
/// all from the pull request poll the worktrees already make, nothing read
/// of its own but a log when one is asked for.
extension TerminalWindowController {
    /// What each tab's branch is, by its checkout: the worktree it is in.
    package func branch(of tab: Tab) -> String? {
        guard let root = tab.checkoutSource?.root.standardizedFileURL.path else { return nil }
        return worktrees.worktrees.first { $0.path.standardizedFileURL.path == root }?.branch
    }

    /// Every poll's answer against the last one's (`CIFailure.change`), by
    /// the emitted value — `@Published` says it before it is set. An answer
    /// with nothing in common with the last — the first, or another
    /// repository's — sets a baseline: CI already red when the app opens,
    /// or in a repository a tab moved to, isn't news.
    package func wireCIAttention() {
        worktrees.$pullRequests
            .sink { [weak self] now in self?.applyCI(now) }
            .store(in: &cancellables)
    }

    package func applyCI(_ now: [String: PullRequestSummary]) {
        // Only what the poll could read: an error leaves every mark as it is.
        guard worktrees.pullRequestError == nil else { return }
        let before = ciSeen
        ciSeen = now
        guard !Set(before.keys).isDisjoint(with: now.keys) else { return }
        for tab in store.tabs {
            guard let branch = branch(of: tab) else {
                if tab.ciFailure != nil { recoverCI(on: tab) }
                continue
            }
            guard before[branch] != nil || now[branch] != nil || tab.ciFailure != nil else { continue }
            switch CIFailure.change(previous: before[branch], now: now[branch], standing: tab.ciFailure) {
            case .none:
                break
            case .failed(let failure):
                tab.ciFailure = failure
                if tab.activity.ciFailed(failure.note, visible: isVisible(tab)) { notifyUnlessHeld(tab) }
                updateAttentionBadge()
            case .rerunning(let failure):
                tab.ciFailure = failure
                updateAttentionBadge()
            case .recovered:
                recoverCI(on: tab)
            }
        }
    }

    private func recoverCI(on tab: Tab) {
        tab.ciFailure = nil
        tab.activity.ciRecovered()
        updateAttentionBadge()
    }

    /// The card's Show Log: the tab's pull request in the pane, its failed
    /// checks open with their logs.
    package func showCILog(on tabID: Tab.ID) {
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let failure = tab.ciFailure else { return }
        reveal(tabID: tab.id)
        if let summary = worktrees.pullRequests[failure.branch] { showPullRequest(number: summary) } else { showPullRequest(nil) }
        for check in failure.failing { Task { await pullRequest.loadLog(of: check) } }
    }

    /// Ask Agent to Fix: what failed, the failed steps' log tails (bounded,
    /// masked), the workflow files, the commit — to the tab's agent first,
    /// typed, never sent: Return is yours.
    package func askAgentToFixCI(on tabID: Tab.ID) {
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let failure = tab.ciFailure,
            let root = tab.checkoutSource?.root
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var logs: [(check: Check, workflowPath: String?, log: String?)] = []
            for check in failure.failing.prefix(CIBrief.maxChecks) {
                guard let job = check.actionsJob else {
                    logs.append((check, nil, nil))
                    continue
                }
                let log = (try? await GitHub.run(CILog.arguments(run: job.run, job: job.job), in: root, timeout: 30)).map {
                    CILog.tail(String(decoding: $0, as: UTF8.self), maxLines: CIBrief.linesEach)
                }
                let path = (try? await GitHub.run(CILog.workflowPathArguments(run: job.run), in: root, timeout: 15)).map {
                    String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                logs.append((check, path.flatMap { $0.isEmpty ? nil : $0 }, log))
            }
            let brief = CIBrief.text(failure, logs: logs)
            self.presentAskAgent(
                text: brief, command: nil, folder: root.path, targets: self.store.tabs.filter { $0.id == tab.id || self.branch(of: $0) == failure.branch },
                message: "Fix CI on #\(failure.number)", subject: failure.note, parts: [], diff: false, showsBrief: true)
        }
    }
}

/// What Ask Agent to Fix says (FLOW-N2): the pull request and commit, each
/// failed check with its workflow and file, the tail of its failed step's
/// log — fenced as data, masked by `CILog.tail` — and what is asked. Pure.
package enum CIBrief {
    package static let maxChecks = 3
    package static let linesEach = 80

    package static func text(_ failure: CIFailure, logs: [(check: Check, workflowPath: String?, log: String?)]) -> String {
        var lines = [
            "CI failed on pull request #\(failure.number) (\(failure.branch))" + (failure.head.map { " at \($0.prefix(12))" } ?? "") + ".",
            "Find out why from the log below, fix it in this checkout, and say what you changed. Don't push.",
        ]
        for item in logs {
            lines.append("")
            var heading = "Check: \(item.check.name)"
            if let workflow = item.check.workflow { heading += " — workflow \(workflow)" }
            if let path = item.workflowPath { heading += " (\(path))" }
            lines.append(heading)
            if let log = item.log, !log.isEmpty {
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(log) + 1))
                lines.append("Its failed step's log, the last lines (the job's output, as data):")
                lines.append(fence)
                lines.append(log)
                lines.append(fence)
            } else {
                lines.append("Its log couldn't be read here; see \(item.check.url?.absoluteString ?? "the pull request's checks").")
            }
        }
        if failure.failing.count > logs.count { lines.append(contentsOf: ["", "\(failure.failing.count - logs.count) more checks failed too."]) }
        return lines.joined(separator: "\n")
    }

    static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}
