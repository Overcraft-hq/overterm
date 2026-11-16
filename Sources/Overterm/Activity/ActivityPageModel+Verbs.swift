import Foundation

/// The page's verbs that change a process (docs/design/activity/
/// analysis.md, 6.10): Stop, Interrupt, Interrupt Turn and Stop Agent,
/// Force Quit, Send a Signal, Stop Its Tree, Group and Parent — one list
/// with the rest of a row's verbs, each greyed with the policy's reason
/// where it can't be done. What the list says is decided on the latest
/// snapshot; the sheet reads the process again, and the button again.
extension ActivityPageModel {
    /// `row`'s process as a verb sees it: the selection's, read off the
    /// main thread with every owner of the snapshot (`verbSubject`). Nil
    /// while it is read, or once it is gone from the table.
    func subject(for row: ActivityProcessRow) -> ActivityVerbSubject? {
        verbSubject?.signal.identity == row.identity ? verbSubject : nil
    }

    /// What `k` does to it: Stop Agent on an agent, Interrupt on a
    /// terraform write and on the pane's foreground job with no agent in
    /// its group, else Stop.
    nonisolated static func stopVerb(for target: ActivityTarget) -> ActivityVerb {
        if target.kind == .agent { return .stopAgent }
        if target.terraformWrite != nil { return .interrupt }
        if target.kind == .paneJob, target.inForeground, !target.groupHoldsAgent { return .interrupt }
        return .stop
    }

    /// Whether the page stopped `identity` in the last two minutes: Force
    /// Quit then asks plainly, without "Stop it first?" (D-11).
    func recentlyStopped(_ identity: ActivityProcessID, now: Date = Date()) -> Bool {
        stoppedAt[identity].map { now.timeIntervalSince($0) < ActivityStopWatch.forceQuitWindow } ?? false
    }

    /// The page sent `identity` a Stop or an Interrupt `now`: kept for
    /// Force Quit's two minutes, and no longer — what is older goes as
    /// each is noted, so the set holds only the last two minutes' stops.
    func noteStopped(_ identity: ActivityProcessID, at now: Date = Date()) {
        stoppedAt = stoppedAt.filter { now.timeIntervalSince($0.value) < ActivityStopWatch.forceQuitWindow }
        stoppedAt[identity] = now
    }

    /// The stage 2 verbs of one process row; greyed, "being read", until
    /// its subject is read.
    func signalVerbs(for row: ActivityProcessRow) -> [ResourceVerb] {
        let subject = subject(for: row)
        let identity = row.identity
        func rule(_ verb: ActivityVerb) -> ActivityRule? {
            subject.map { ActivitySignalCheck.rule(verb, for: $0.target, parent: verb == .stopParent ? $0.parentTarget : nil) }
        }
        func reason(_ verb: ActivityVerb) -> String? { rule(verb).map(Self.unavailable) ?? Self.reading }
        let act: (ActivityVerb) -> @MainActor () -> Void = { verb in { [weak self] in self?.actions.act(verb, identity) } }
        let primary = subject.map { Self.stopVerb(for: $0.target) } ?? .stop
        var verbs: [ResourceVerb] = []
        func add(_ verb: ActivityVerb, _ title: String, symbol: String, key: String? = nil, place: ResourceVerb.Place = .more) {
            verbs.append(ResourceVerb(title: title, symbol: symbol, place: place, key: key, unavailable: reason(verb), perform: act(verb)))
        }
        if case .route(.closePane, _)? = rule(.stop) {
            add(.stop, "Close Its Pane…", symbol: "xmark.square", key: "k", place: .remove)
        } else if subject?.target.kind == .agent {
            add(.interruptTurn, "Interrupt Turn…", symbol: "pause.circle", place: .button)
            add(.stopAgent, "Stop Agent…", symbol: "stop.circle", key: "k", place: .remove)
        } else {
            add(.interrupt, "Interrupt…", symbol: "pause.circle", key: primary == .interrupt ? "k" : nil, place: primary == .interrupt ? .remove : .more)
            add(.stop, "Stop…", symbol: "stop.circle", key: primary == .stop ? "k" : nil, place: primary == .stop ? .remove : .more)
        }
        add(.forceQuit, "Force Quit…", symbol: "bolt.circle", key: "K")
        verbs.append(
            ResourceVerb(
                title: "Send a Signal", symbol: "antenna.radiowaves.left.and.right", key: "x",
                children: ActivitySignal.allCases.map { signal in
                    ResourceVerb(title: "SIG\(signal.rawValue)…", symbol: "dot.radiowaves.right", unavailable: reason(.send(signal)), perform: act(.send(signal)))
                }))
        add(.stopTree, "Stop Its Tree…", symbol: "list.bullet.indent")
        add(.stopGroup, "Stop Its Group…", symbol: "square.stack.3d.up")
        add(.stopParent, "Stop Its Parent…", symbol: "arrow.up.circle")
        return verbs
    }

    /// The routes the page takes from a row now: the pane's close, Suspend
    /// and Resume Tab.
    nonisolated static let routes: Set<ActivityRoute> = [.closePane, .suspendTab, .resumeTab]
    nonisolated static let reading = "Being read…"
    nonisolated static let routeElsewhere = "Its owner's own verb: on its own page."
    nonisolated static let appVerbsLater = "An app: quit it from its menu — Activity's Quit comes with its own check."
    nonisolated static let suspendLater =
        "SIGSTOP and SIGCONT are Suspend and Resume, which come with their own step — with Activity's own record of what it stopped. Not from here yet."

    /// Why the page doesn't do what `rule` says now; nil when it does. A
    /// refusal, an owner's verb on another page, and what comes with its
    /// own step: an app's Quit, Suspend and Resume (Send a Signal ▸ STOP and
    /// CONT, a pane's job suspended with its pane), the priorities. Pure.
    nonisolated static func unavailable(_ rule: ActivityRule) -> String? {
        switch rule {
        case .refused(let why): return why
        case .allowed(.quitApp, _, _), .allowed(.forceQuitApp, _, _): return appVerbsLater
        case .allowed(.suspend, _, _), .allowed(.resume, _, _), .allowed(.background, _, _), .allowed(.normalPriority, _, _),
            .allowed(.lowerPriority, _, _), .route(.suspendPane, _):
            return suspendLater
        case .route(let route, _): return routes.contains(route) ? nil : routeElsewhere
        case .allowed: return nil
        }
    }

    /// `k`, `K`, `x` on the selected process: `k`'s verb decided on the
    /// process read again as its sheet opens.
    func pressSignalKey(_ key: ActivityKey) -> Bool {
        guard let row = selectedProcess else { return false }
        switch key {
        case .stop: actions.stop(row.identity)
        case .forceQuit: actions.act(.forceQuit, row.identity)
        case .signal: actions.chooseSignal(row.identity)
        default: return false
        }
        return true
    }
}
