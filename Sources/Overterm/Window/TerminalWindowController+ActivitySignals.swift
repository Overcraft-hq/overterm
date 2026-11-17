import AppKit

/// The Activity page's verbs that change a process (docs/design/activity/
/// analysis.md, 6.10): Stop, Interrupt, Interrupt Turn, Stop Agent, Force
/// Quit, Send a Signal, Stop Its Tree, Group and Parent. Each reads the
/// process again from a fresh census as its sheet opens and asks the policy
/// (`ActivitySignalCheck`) with those facts; every one that ends something
/// asks (`WriteConfirmation`, D-10); the button reads it again and asks the
/// policy again, so what changed while the sheet was up is refused, not
/// sent what was asked for what it was. Signals go through
/// `ProcessSignals` by the identity listed, token first; Interrupt is ⌃C
/// typed into the pane, only while its foreground group is still the
/// target's. After a Stop the process is watched: stopped, still running,
/// or came back as pid N.
extension TerminalWindowController {
    /// `verb` on the process `identity`. `stopFirstAnswered`: Force Quit
    /// chosen in "Stop it first?" — its own sheet follows, never a send.
    func activityAct(_ verb: ActivityVerb, _ identity: ActivityProcessID, stopFirstAnswered: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let subject = await self.activitySubject(identity) else {
                return self.tell("It has ended", "pid \(identity.pid) is no longer the process listed: nothing was asked, nothing sent.")
            }
            self.ask(verb, subject, stopFirstAnswered: stopFirstAnswered)
        }
    }

    /// `k`: what the process's class asks (`ActivityPageModel.stopVerb`),
    /// decided on the process read again now — never on the list's read.
    func activityStop(_ identity: ActivityProcessID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let subject = await self.activitySubject(identity) else {
                return self.tell("It has ended", "pid \(identity.pid) is no longer the process listed: nothing was asked, nothing sent.")
            }
            self.ask(ActivityPageModel.stopVerb(for: subject.target), subject)
        }
    }

    /// Send a Signal (`x`): which signal, then that signal's own question.
    func activityChooseSignal(_ identity: ActivityProcessID) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Send a signal to pid \(identity.pid)"
        alert.informativeText = "Each is asked about under the verb it equals: KILL as Force Quit, INT as Interrupt, STOP and CONT as Suspend and Resume."
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        menu.addItems(withTitles: ActivitySignal.allCases.map { "SIG\($0.rawValue)" })
        menu.selectItem(withTitle: "SIGTERM")
        menu.setAccessibilityIdentifier("activity.signalChoice")
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let index = menu.indexOfSelectedItem
            MainActor.assumeIsolated {
                guard ActivitySignal.allCases.indices.contains(index) else { return }
                self?.activityAct(.send(ActivitySignal.allCases[index]), identity)
            }
        }
    }

    /// `identity` read from a fresh census, as the policy sees it: its owners
    /// made off the main thread with the page's facts. Nil once it ended.
    func activitySubject(_ identity: ActivityProcessID) async -> ActivityVerbSubject? {
        guard let snapshot = await ActivityMonitor.shared.census(within: 0) else { return nil }
        let page = activityPage
        var context = page.monitor.context
        page.contextFacts(&context)
        let facts = page.tabFacts()
        let inputs = ActivityAttribution.Inputs(tabs: facts?.tabs ?? [:], checkouts: facts?.checkouts ?? [], runningApps: page.runningApps())
        var known = page.known()
        known.runningApps = inputs.runningApps
        let context2 = context
        let known2 = known
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let owners = ActivityAttribution.of(snapshot, context: context2, inputs: inputs)
                // What the main actor changed itself is laid over the census,
                // which may be a tick that started before that change.
                let read = ActivityVerbSubject.read(identity, in: snapshot, owners: owners, known: known2)
                continuation.resume(returning: read.map { ActivityPageModel.overlaid($0, known: known2) })
            }
        }
    }

    /// What the main actor knows of stopped processes: what Suspend Tab
    /// stopped, in every window; what Activity stopped and put in the
    /// background (`ActivityHeld`).
    static func activityKnown() -> ActivityVerbSubject.Known {
        var suspended: Set<ActivityProcessID> = []
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            for tab in controller.store.tabs {
                for pane in tab.terminals { suspended.formUnion((pane.suspended ?? []).map(\.identity)) }
            }
        }
        let held = ActivityHeld.shared
        var known = ActivityVerbSubject.Known(stoppedHere: held.stopped, suspendedTab: suspended, backgroundHere: held.backgroundHere)
        known.resumedHere = held.recentlyResumed()
        return known
    }

    /// The pane whose tag is `tag`, in whichever window, with its tab and
    /// that window's controller.
    static func activityPane(tag: String?) -> (TerminalWindowController, Tab, TerminalView)? {
        guard let tag else { return nil }
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            for tab in controller.store.tabs {
                if let pane = tab.terminals.first(where: { $0.processTag == tag }) { return (controller, tab, pane) }
            }
        }
        return nil
    }

    /// "Tab “web” · feature-x · Claude", or where it runs outside every tab.
    private func activityScope(_ subject: ActivityVerbSubject) -> String? {
        if let tab = subject.tab, let (_, found) = Self.activityWindow(of: tab) {
            return ActivityPortFree.scope(tab: found.title, checkout: found.checkoutSource?.root.lastPathComponent, agent: subject.agent ?? found.agent)
        }
        return "Outside every tab"
    }

    private func ask(_ verb: ActivityVerb, _ subject: ActivityVerbSubject, stopFirstAnswered: Bool = false) {
        guard let window else { return }
        let rule = ActivitySignalCheck.rule(verb, for: subject.target, parent: subject.parentTarget)
        let name = "“\(DockerMCP.displayed(subject.name))” (pid \(subject.signal.identity.pid))"
        if let reason = rule.refusal { return tell("Overterm doesn't do that to \(name)", reason) }
        // Stop Its Parent: the parent's own Stop, read and asked as itself.
        if verb == .stopParent {
            guard let parent = subject.parent else { return tell("Overterm doesn't do that to \(name)", ActivitySignalCheck.parentUnknown) }
            return activityAct(.stop, parent)
        }
        // Suspend, Resume, a pane's job with its pane, the priorities:
        // their own questions (`+ActivitySuspend`).
        if askHeld(verb, rule, subject) { return }
        // What comes with its own step (an app's Quit) and an owner's verb
        // on its own page: said, not asked.
        if let why = ActivityPageModel.unavailable(rule) { return tell("Overterm doesn't do that to \(name)", why) }
        // D-11: Force Quit with no Stop before it asks "Stop it first?";
        // its Force Quit then asks with Force Quit's own sheet.
        let forceQuits = rule == ActivitySignalCheck.rule(.forceQuit, for: subject.target) && (verb == .forceQuit || verb == .send(.kill))
        if forceQuits, !stopFirstAnswered, !activityPage.recentlyStopped(subject.signal.identity) {
            return askStopFirst(verb, subject, on: window)
        }
        var pane: (title: String, isSplit: Bool)?
        if let (_, tab, _) = Self.activityPane(tag: subject.pane) { pane = (tab.title, tab.isSplit) }
        guard let question = ActivityVerbQuestion.question(verb, rule, subject: subject, scope: activityScope(subject), pane: pane) else {
            return tell("Overterm doesn't do that to \(name)", ActivityPageModel.routeElsewhere)
        }
        var sheet = confirmation(question)
        var count = 1
        if case .allowed(.signalTree, _, _) = rule { count = subject.tree.filter { $0.refusal == nil }.count + 1 }
        if case .allowed(.signalGroup, _, _) = rule { count = subject.groupMembers.count + 1 }
        if ActivityVerbQuestion.typesCount(count) { sheet.typedName = String(count) }
        sheet.present(on: window) { [weak self] typed in
            guard let self else { return }
            if ActivityVerbQuestion.typesCount(count), typed != String(count) {
                return self.tell("Not sent", "The count typed wasn't \(count): nothing was sent.")
            }
            self.atButton(verb, rule, asked: subject)
        }
    }

    /// "Stop it first?": Stop, Force Quit or Cancel (D-11). Its Force Quit
    /// sends nothing: Force Quit's own sheet follows — the executable, the
    /// command, the scope and `kill -KILL N` —, read again.
    private func askStopFirst(_ verb: ActivityVerb, _ subject: ActivityVerbSubject, on window: NSWindow) {
        let words = ActivityVerbQuestion.stopFirst(subject)
        let alert = NSAlert()
        alert.messageText = words.title
        alert.informativeText = words.detail
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        let identity = subject.signal.identity
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn: self.activityAct(ActivityPageModel.stopVerb(for: subject.target), identity)
                case .alertSecondButtonReturn: self.activityAct(verb, identity, stopFirstAnswered: true)
                default: break
                }
            }
        }
    }

    /// The button (6.10 step 4): read again, the policy asked again with
    /// what it is now; then what was asked.
    private func atButton(_ verb: ActivityVerb, _ rule: ActivityRule, asked: ActivityVerbSubject) {
        let identity = asked.signal.identity
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let fresh = await self.activitySubject(identity) else {
                return self.tell("Not sent", "“\(DockerMCP.displayed(asked.name))” ended while you were asked: nothing was sent.")
            }
            let now = ActivitySignalCheck.rule(verb, for: fresh.target, parent: fresh.parentTarget)
            guard now == rule else {
                return self.tell(
                    "Not sent", "What “\(DockerMCP.displayed(asked.name))” is changed while you were asked: nothing was sent — ask again to be asked about what it is now.")
            }
            self.perform(verb, rule, fresh, asked: asked)
        }
    }

    private func perform(_ verb: ActivityVerb, _ rule: ActivityRule, _ subject: ActivityVerbSubject, asked: ActivityVerbSubject) {
        let target = asked.signal
        // Before anything is sent: a supervisor starts its child again
        // within a millisecond, and only what started after this came back.
        let sentAt = PortFreeing.now()
        switch rule {
        case .allowed(.interruptPane, _, _):
            guard let (_, _, pane) = Self.activityPane(tag: subject.pane) else {
                return tell("Not interrupted", "Its pane is gone: nothing was typed.")
            }
            let kernel = LiveActivityKernel()
            let foreground = pane.foregroundGroup
            if let refusal = ActivityPortFree.interruptRefusal(
                listed: target.identity, group: subject.group, now: kernel.process(target.identity.pid), foregroundGroup: foreground,
                leader: foreground.flatMap { kernel.process($0)?.shortName })
            {
                return tell("Not interrupted", refusal)
            }
            pane.pressControlC()
            activityPage.noteStopped(target.identity)
            watchStop(asked, sentAt: sentAt)
        case .allowed(.signal(let signal), _, _):
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let answer = ProcessSignals().send(signal, to: target, alone: true)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let said = ActivityPortFree.answer(answer, pid: target.identity.pid) { return self.tell("Not sent", said) }
                    if signal == .term || signal == .int { self.activityPage.noteStopped(target.identity) }
                    if [.term, .int, .kill, .hup, .quit].contains(signal) { self.watchStop(asked, sentAt: sentAt) }
                }
            }
        case .allowed(.signalTree(let signal), _, _):
            // The members the sheet listed, as it listed them — one that
            // exec'd since is "ran another program", never sent.
            let members = ActivityVerbSubject.treeSend(asked: asked, fresh: subject)
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let answers = ProcessSignals().sendTree(signal, to: members)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let unsent = answers.filter { if case .sent = $0.answer { false } else { true } }
                    if !unsent.isEmpty {
                        let lines = unsent.map { "pid \($0.target.identity.pid): \(ActivityPortFree.answer($0.answer, pid: $0.target.identity.pid) ?? "")" }
                        self.tell("Sent to \(answers.count - unsent.count) of \(answers.count)", lines.joined(separator: "\n"))
                    }
                    self.activityPage.noteStopped(target.identity)
                    self.watchStop(asked, sentAt: sentAt)
                }
            }
        case .allowed(.signalGroup(let signal), _, _):
            // Only the members the sheet listed: one that joined since
            // refuses the send.
            let listed = Set(asked.groupMembers.map(\.signal.identity))
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let answer = ProcessSignals().sendToGroup(signal, leader: target, listed: listed, policy: true)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let said = ActivityPortFree.answer(answer, pid: target.identity.pid) { return self.tell("Not sent", said) }
                    self.activityPage.noteStopped(target.identity)
                    self.watchStop(asked, sentAt: sentAt)
                }
            }
        case .route(.closePane, _):
            guard let (controller, tab, pane) = Self.activityPane(tag: subject.pane) else { return tell("Not closed", "Its pane is gone.") }
            controller.closeForFree(pane, in: tab)
        case .route(.suspendTab, _):
            guard let (controller, tab, _) = Self.activityPane(tag: subject.pane) else { return tell("Not suspended", "Its tab is gone.") }
            controller.suspendTab(tab)
        case .route(.resumeTab, _):
            guard let (controller, tab, _) = Self.activityPane(tag: subject.pane) else { return tell("Not resumed", "Its tab is gone.") }
            controller.resumeTab(tab)
        default:
            tell("Not sent", ActivityPageModel.routeElsewhere)
        }
    }

    /// After a Stop (6.10 step 10): the census at most once a second for
    /// five seconds, the page's header saying "Stopping “x”…", then
    /// stopped, still running — Force Quit… —, or came back as pid N.
    /// `sentAt`: taken before the signal or the ⌃C went, µs since 1970.
    private func watchStop(_ subject: ActivityVerbSubject, sentAt: UInt64) {
        let page = activityPage
        let listed = ActivityStopWatch.Listed(
            identity: subject.signal.identity, name: subject.name, path: subject.signal.path, parent: subject.parent?.pid ?? 0, ports: subject.listening)
        let first = ActivityStopWatch.label(.stopping, listed)
        page.freeing = first
        Task { @MainActor [weak page] in
            var state = ActivityStopWatch.State.stopping
            let reads = 5
            for read in 1...reads where state == .stopping {
                try? await Task.sleep(for: .seconds(1))
                guard let snapshot = await ActivityMonitor.shared.census(within: 900_000_000) else { continue }
                state = ActivityStopWatch.state(
                    listed, alive: ActivityStopWatch.alive(listed.identity, in: snapshot), seen: ActivityStopWatch.seen(in: snapshot), sentAt: sentAt,
                    final: read == reads)
            }
            if state == .stopping { state = .stillRunning }
            let said = ActivityStopWatch.label(state, listed)
            guard let page, page.freeing == first else { return }
            page.freeing = said
            try? await Task.sleep(for: Self.freeSaid)
            if page.freeing == said { page.freeing = nil }
        }
    }
}
