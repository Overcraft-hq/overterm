import AppKit

/// The Activity page's verbs that hold a process rather than end it (docs/
/// design/activity/analysis.md, 6.10): Suspend — a pane's job with its pane,
/// through Suspend Tab's own path, anything else with its subtree —, Resume
/// of only what Activity stopped, Resume All, Run in Background and
/// Normally, Lower Priority. Each goes through `ProcessSignals` by the
/// identity the census listed; what Activity stopped or put in the
/// background is kept by identity (`ActivityHeld`). Suspend and Resume ask
/// for an app, a helper inside one, and more than one process; Run in
/// Background never for one; Lower Priority every time.
extension TerminalWindowController {
    /// `rule` taken here when it is one of these verbs' (from `ask`, the
    /// process read fresh as its sheet would open): true when it was.
    func askHeld(_ verb: ActivityVerb, _ rule: ActivityRule, _ subject: ActivityVerbSubject) -> Bool {
        switch rule {
        case .allowed(.suspend, let confirm, _): askSuspend(verb, rule, subject, confirm: confirm)
        case .allowed(.resume, let confirm, _): askResume(verb, rule, subject, confirm: confirm)
        case .route(.suspendPane, confirm: false):
            suspendPane(subject)
        case .route(.suspendPane, confirm: true):
            // Send a Signal ▸ STOP: the same route, asked as every Send a
            // Signal is — the pane named, read again at the button.
            guard let (_, tab, _) = Self.activityPane(tag: subject.pane), let window else {
                tell("Not suspended", "Its pane is gone.")
                return true
            }
            let question = ActivityVerbQuestion.suspendPane(subject, tab: tab.title, scope: heldScope(subject))
            confirmation(question).present(on: window) { [weak self] _ in
                guard let self else { return }
                self.heldAtButton(verb, rule, asked: subject) { fresh in self.suspendPane(fresh) }
            }
        case .route(.suspendTab, confirm: false), .route(.resumeTab, confirm: false):
            // The pane's shell's Suspend, and Resume of what Suspend Tab
            // stopped: the tab's own verb, unasked as its menu's is.
            guard let (controller, tab, _) = Self.activityPane(tag: subject.pane) else {
                tell("Not changed", "Its tab is gone.")
                return true
            }
            if rule == .route(.suspendTab, confirm: false) {
                controller.suspendTab(tab)
                say("Suspended the tab “\(DockerMCP.displayed(tab.title))”")
            } else {
                ActivityHeld.shared.resumed(Set(tab.terminals.flatMap { ($0.suspended ?? []).map(\.identity) }))
                controller.resumeTab(tab)
                say("Resumed the tab “\(DockerMCP.displayed(tab.title))”")
            }
        case .allowed(.background, _, _): setPriority(.background, subject)
        case .allowed(.normalPriority, _, _): setPriority(.normal, subject)
        case .allowed(.lowerPriority, _, _): activityChooseLower(subject.signal.identity)
        default: return false
        }
        return true
    }

    /// A word in the page's header for a while (`freeing`'s place).
    private func say(_ words: String) {
        let page = activityPage
        page.freeing = words
        Task { @MainActor [weak page] in
            try? await Task.sleep(for: Self.freeSaid)
            if page?.freeing == words { page?.freeing = nil }
        }
    }

    private func quoted(_ subject: ActivityVerbSubject) -> String { "“\(DockerMCP.displayed(subject.name))” (pid \(subject.signal.identity.pid))" }

    /// The scope a sheet names: its tab, or outside every tab.
    private func heldScope(_ subject: ActivityVerbSubject) -> String {
        if let tab = subject.tab, let (_, found) = Self.activityWindow(of: tab) {
            return ActivityPortFree.scope(tab: found.title, checkout: found.checkoutSource?.root.lastPathComponent, agent: subject.agent ?? found.agent)
        }
        return "Outside every tab"
    }

    /// At the button: read again, the policy asked again; `then` only while
    /// it says what it said when asked.
    private func heldAtButton(
        _ verb: ActivityVerb, _ rule: ActivityRule, asked: ActivityVerbSubject, then: @escaping @MainActor (ActivityVerbSubject) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let fresh = await self.activitySubject(asked.signal.identity) else {
                return self.tell("Not sent", "“\(DockerMCP.displayed(asked.name))” ended while you were asked: nothing was sent.")
            }
            guard ActivitySignalCheck.rule(verb, for: fresh.target) == rule else {
                return self.tell(
                    "Not sent", "What “\(DockerMCP.displayed(asked.name))” is changed while you were asked: nothing was sent — ask again to be asked about what it is now.")
            }
            then(fresh)
        }
    }

    // MARK: Suspend and Resume

    /// A pane's job or agent with its pane: the shell stopped first, or it
    /// would take the terminal back from its stopped job.
    private func suspendPane(_ subject: ActivityVerbSubject) {
        guard let (controller, tab, pane) = Self.activityPane(tag: subject.pane) else { return tell("Not suspended", "Its pane is gone.") }
        controller.suspendPanes([pane], of: tab)
        say("Suspended its pane in “\(DockerMCP.displayed(tab.title))”: “\(DockerMCP.displayed(subject.name))” and its shell")
    }

    private func askSuspend(_ verb: ActivityVerb, _ rule: ActivityRule, _ subject: ActivityVerbSubject, confirm: Bool) {
        let members = subject.suspendMembers
        guard confirm || members.count > 1, let window else { return suspend(asked: subject, fresh: subject) }
        let question = ActivityVerbQuestion.suspend(subject, members: members, scope: heldScope(subject))
        var sheet = confirmation(question)
        if ActivityVerbQuestion.typesCount(members.count) { sheet.typedName = String(members.count) }
        sheet.present(on: window) { [weak self] typed in
            guard let self else { return }
            if ActivityVerbQuestion.typesCount(members.count), typed != String(members.count) {
                return self.tell("Not suspended", "The count typed wasn't \(members.count): nothing was stopped.")
            }
            self.heldAtButton(verb, rule, asked: subject) { fresh in self.suspend(asked: subject, fresh: fresh) }
        }
    }

    /// SIGSTOP to the members the question listed, parents first, each by
    /// its own token — less those that ended since —, and what stopped is
    /// kept by identity.
    private func suspend(asked: ActivityVerbSubject, fresh: ActivityVerbSubject) {
        let now = Set(fresh.suspendMembers.map(\.identity))
        let members = asked.suspendMembers.filter { $0.identity == asked.signal.identity || now.contains($0.identity) }
        let names = asked.memberNames
        let root = asked.signal
        let name = asked.name
        let words = quoted(asked)
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let answers = ActivityHeld.stopTree(members, signals: ProcessSignals())
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stopped = answers.filter { if case .sent = $0.answer { true } else { false } }.map(\.target)
                ActivityHeld.shared.suspended(root: root, name: name, members: stopped, names: names)
                if let first = answers.first, stopped.first?.identity != root.identity {
                    return self.tell("Not suspended", ActivityPortFree.answer(first.answer, pid: root.identity.pid) ?? "Nothing was stopped.")
                }
                let others = stopped.count - 1
                self.say(others > 0 ? "Suspended \(words) and \(others) of its tree" : "Suspended \(words)")
                self.activityPage.refreshVerbs()
            }
        }
    }

    private func askResume(_ verb: ActivityVerb, _ rule: ActivityRule, _ subject: ActivityVerbSubject, confirm: Bool) {
        let held = ActivityHeld.shared
        let targets = held.resumeTargets(for: subject.signal.identity)
        guard !targets.isEmpty else { return tell("Not resumed", ActivitySignalCheck.notStoppedHere) }
        guard confirm || targets.count > 1, let window else { return resume(targets, words: quoted(subject)) }
        let members = targets.map { (target: $0, name: held.name(of: $0.identity) ?? subject.name) }
        let title = targets.count > 1 ? "Resume \(quoted(subject)) and its tree — \(targets.count) processes?" : "Resume \(quoted(subject))?"
        confirmation(ActivityVerbQuestion.resume(title: title, members: members, scope: heldScope(subject))).present(on: window) { [weak self] _ in
            guard let self else { return }
            self.heldAtButton(verb, rule, asked: subject) { _ in self.resumeListed(targets, words: self.quoted(subject)) }
        }
    }

    /// At a Resume's button: only the listed members Activity still holds
    /// now — one let go while the sheet was up is left alone, said.
    private func resumeListed(_ listed: [ActivitySignalTarget], words: String) {
        let now = ActivityHeld.shared.stillHeld(listed)
        let dropped = listed.count - now.count
        guard !now.isEmpty else { return tell("Not resumed", "None of them is Activity's to continue any more: each was continued or ended while you were asked.") }
        if dropped > 0 {
            tell(
                "Resumed \(now.count) of \(listed.count)",
                "\(dropped == 1 ? "One was" : "\(dropped) were") continued or ended while you were asked, and \(dropped == 1 ? "isn't" : "aren't") Activity's to continue any more: left alone.")
        }
        resume(now, words: words)
    }

    /// SIGCONT, children first, each only while it is still what Activity
    /// stopped; what continued or ended is let go.
    private func resume(_ targets: [ActivitySignalTarget], words: String) {
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let answers = ProcessSignals().sendTree(.cont, to: targets)
            Task { @MainActor [weak self] in
                guard let self else { return }
                ActivityHeld.shared.resumed(Set(answers.filter { ActivityHeld.letGo($0.answer) }.map(\.target.identity)))
                let unsent = answers.filter { if case .sent = $0.answer { false } else { true } }
                if !unsent.isEmpty {
                    let lines = unsent.map { "pid \($0.target.identity.pid): \(ActivityPortFree.answer($0.answer, pid: $0.target.identity.pid) ?? "")" }
                    self.tell("Resumed \(answers.count - unsent.count) of \(answers.count)", lines.joined(separator: "\n"))
                }
                self.say(targets.count > 1 ? "Resumed \(words) and \(targets.count - 1) of its tree" : "Resumed \(words)")
                self.activityPage.refreshVerbs()
            }
        }
    }

    /// The header's Resume All: every process Activity stopped, asked when
    /// more than one, each listed.
    func activityResumeAll() {
        let held = ActivityHeld.shared
        let members = held.suspensions.flatMap { suspension in suspension.members.map { (target: $0, name: suspension.names[$0.identity] ?? suspension.name) } }
        guard !members.isEmpty else { return }
        let listed = Set(members.map(\.target.identity))
        let go = { [weak self] in
            // Planned again at the button: only what was listed and is
            // still held now — one let go while the sheet was up is left.
            let now = ActivityHeld.shared.stillHeld(listed: listed)
            let dropped = listed.count - now.reduce(0) { $0 + $1.members.count }
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let answers = ActivityHeld.continueAll(now, signals: ProcessSignals())
                Task { @MainActor [weak self] in
                    ActivityHeld.shared.resumed(Set(answers.filter { ActivityHeld.letGo($0.answer) }.map(\.target.identity)))
                    let sent = answers.filter { if case .sent = $0.answer { true } else { false } }.count
                    let left = dropped > 0 ? " — \(dropped) let go while you were asked, left alone" : ""
                    self?.say((sent == 1 ? "Resumed 1 process" : "Resumed \(sent) processes") + left)
                }
            }
        }
        guard members.count > 1, let window else { return go() }
        let title = "Resume the \(members.count) processes you suspended from Activity?"
        confirmation(ActivityVerbQuestion.resume(title: title, members: members, scope: nil)).present(on: window) { _ in go() }
    }

    // MARK: Priority

    /// Run in Background or Normally: one process, not asked (6.10); kept
    /// by identity, since nothing can read it back (3.9).
    private func setPriority(_ change: ActivityPriorityChange, _ subject: ActivityVerbSubject) {
        let target = subject.signal
        let words = quoted(subject)
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            let answer = ProcessSignals().setPriority(change, of: target)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let said = ActivityPortFree.answer(answer, pid: target.identity.pid) { return self.tell("Not changed", said) }
                if change == .background {
                    ActivityHeld.shared.backgrounded(target.identity)
                    self.say("\(words) runs in the background")
                } else {
                    ActivityHeld.shared.runsNormally(target.identity)
                    self.say("\(words) runs normally again")
                }
                self.activityPage.refreshVerbs()
            }
        }
    }

    /// `n`: which step of Lower Priority, then its question. Its nice read
    /// first: a step that gives nothing is greyed with why, as in the row
    /// menu; none that does, and nothing is asked.
    func activityChooseLower(_ identity: ActivityProcessID) {
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            guard let subject = await self.activitySubject(identity) else {
                return self.tell("It has ended", "pid \(identity.pid) is no longer the process listed: nothing was asked, nothing changed.")
            }
            let steps = ActivityNiceStep.allCases
            let greyed = steps.map { $0.already(from: subject.nice) }
            guard let first = greyed.firstIndex(where: { $0 == nil }) else {
                return self.tell("Not changed", greyed.compactMap { $0 }.first ?? ActivitySignalRefusal.niceDown.reason)
            }
            let alert = NSAlert()
            alert.messageText = "Lower the priority of pid \(identity.pid)"
            alert.informativeText = "Its nice is raised — only an administrator lowers it again. Asked next with what it runs and the command it equals."
            let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
            menu.autoenablesItems = false
            for (step, why) in zip(steps, greyed) {
                menu.addItem(withTitle: "\(step.title.dropLast()) — nice \(step.value(from: subject.nice))")
                menu.lastItem?.isEnabled = why == nil
                menu.lastItem?.toolTip = why
            }
            menu.selectItem(at: first)
            menu.setAccessibilityIdentifier("activity.lowerChoice")
            alert.accessoryView = menu
            alert.addButton(withTitle: "Continue…")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let index = menu.indexOfSelectedItem
                MainActor.assumeIsolated {
                    guard steps.indices.contains(index), greyed[index] == nil else { return }
                    self?.activityLower(identity, steps[index])
                }
            }
        }
    }

    /// Lower Priority ▸ `step`: read again, asked every time, read again at
    /// the button, then the nice raised by `ProcessSignals`.
    func activityLower(_ identity: ActivityProcessID, _ step: ActivityNiceStep) {
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            guard let subject = await self.activitySubject(identity) else {
                return self.tell("It has ended", "pid \(identity.pid) is no longer the process listed: nothing was asked, nothing changed.")
            }
            let rule = ActivitySignalCheck.rule(.lowerPriority, for: subject.target)
            if let reason = rule.refusal ?? ActivityPageModel.unavailable(rule) {
                return self.tell("Overterm doesn't do that to \(self.quoted(subject))", reason)
            }
            let nice = step.value(from: subject.nice)
            guard nice > Int32(subject.nice) else { return self.tell("Not changed", ActivitySignalRefusal.niceDown.reason) }
            self.confirmation(ActivityVerbQuestion.lower(subject, to: nice, scope: self.heldScope(subject))).present(on: window) { [weak self] _ in
                guard let self else { return }
                self.heldAtButton(.lowerPriority, rule, asked: subject) { _ in
                    let target = subject.signal
                    let words = self.quoted(subject)
                    DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                        let answer = ProcessSignals().setPriority(.nice(nice), of: target)
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let said = ActivityPortFree.answer(answer, pid: target.identity.pid) { return self.tell("Not changed", said) }
                            self.say("\(words) runs at nice \(nice)")
                        }
                    }
                }
            }
        }
    }
}
