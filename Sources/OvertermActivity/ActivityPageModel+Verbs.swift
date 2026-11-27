import Darwin
import Foundation

/// Lower Priority's steps (6.10): its nice raised by 5 or 10, or to 20 —
/// never past 20, never down.
package enum ActivityNiceStep: CaseIterable, Hashable, Sendable {
    case five, ten, lowest

    package var title: String {
        switch self {
        case .five: "+5…"
        case .ten: "+10…"
        case .lowest: "20…"
        }
    }

    /// The nice a process at `nice` is given.
    package func value(from nice: Int8) -> Int32 {
        switch self {
        case .five: min(Int32(nice) + 5, ActivityPriorityChange.lowest)
        case .ten: min(Int32(nice) + 10, ActivityPriorityChange.lowest)
        case .lowest: ActivityPriorityChange.lowest
        }
    }

    /// Why this step gives a process at `nice` nothing — it is there
    /// already, and nice is only ever raised —; nil when it raises it.
    /// The row menu's step and `n`'s chooser both grey it with this.
    package func already(from nice: Int8) -> String? {
        value(from: nice) <= Int32(nice) ? "Its nice is already \(nice): nice can only be raised." : nil
    }
}

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
    package func subject(for row: ActivityProcessRow) -> ActivityVerbSubject? {
        guard let subject = verbSubject, subject.signal.identity == row.identity else { return nil }
        return Self.overlaid(subject, known: known())
    }

    /// `subject` with what the main actor knows now laid over the
    /// snapshot it was read from: what Activity stopped and put in the
    /// background (`ActivityHeld`), what Suspend Tab stopped. Those change
    /// here, at once, and a snapshot read before says otherwise for a tick
    /// or more — so Suspend says Resume as soon as it has stopped, and
    /// Resume says Suspend again — a stop a census begun before the
    /// continue still lists isn't read as ⌃Z's. A traced stop, and any
    /// other, stays the snapshot's.
    /// Pure.
    package nonisolated static func overlaid(_ subject: ActivityVerbSubject, known: ActivityVerbSubject.Known) -> ActivityVerbSubject {
        var subject = subject
        let identity = subject.signal.identity
        subject.target.backgroundedHere = known.backgroundHere.contains(identity)
        if subject.target.stopped == .traced { return subject }
        if known.stoppedHere.contains(identity) {
            subject.target.stopped = .activity
        } else if known.suspendedTab.contains(identity) {
            subject.target.stopped = .suspendTab
        } else if subject.target.stopped == .activity || subject.target.stopped == .suspendTab || known.resumedHere.contains(identity) {
            // Continued here since that snapshot.
            subject.target.stopped = nil
        }
        return subject
    }

    /// What `k` does to it: Stop Agent on an agent, Interrupt on a
    /// terraform write and on the pane's foreground job with no agent in
    /// its group, else Stop.
    package nonisolated static func stopVerb(for target: ActivityTarget) -> ActivityVerb {
        if target.kind == .agent { return .stopAgent }
        if target.terraformWrite != nil { return .interrupt }
        if target.kind == .paneJob, target.inForeground, !target.groupHoldsAgent { return .interrupt }
        return .stop
    }

    /// Whether the page stopped `identity` in the last two minutes: Force
    /// Quit then asks plainly, without "Stop it first?" (D-11).
    package func recentlyStopped(_ identity: ActivityProcessID, now: Date = Date()) -> Bool {
        stoppedAt[identity].map { now.timeIntervalSince($0) < ActivityStopWatch.forceQuitWindow } ?? false
    }

    /// The page sent `identity` a Stop or an Interrupt `now`: kept for
    /// Force Quit's two minutes, and no longer — what is older goes as
    /// each is noted, so the set holds only the last two minutes' stops.
    package func noteStopped(_ identity: ActivityProcessID, at now: Date = Date()) {
        stoppedAt = stoppedAt.filter { now.timeIntervalSince($0.value) < ActivityStopWatch.forceQuitWindow }
        stoppedAt[identity] = now
    }

    /// The stage 2 verbs of one process row; greyed, "being read", until
    /// its subject is read.
    package func signalVerbs(for row: ActivityProcessRow) -> [ResourceVerb] {
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
            // An app's Stop is its Quit (D-23): asked to quit, as its menu does.
            let quits = subject?.target.isApp == true
            add(.stop, quits ? "Quit…" : "Stop…", symbol: "stop.circle", key: primary == .stop ? "k" : nil, place: primary == .stop ? .remove : .more)
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
        // Suspend or Resume (`p`), by whether it is stopped now.
        if subject?.target.stopped != nil {
            add(.resume, "Resume", symbol: "play.circle", key: "p")
        } else {
            add(.suspend, "Suspend", symbol: "pause.rectangle", key: "p")
        }
        // Run in Background or Normally (`b`): Normally only for what
        // Activity put there (3.9).
        if subject?.target.backgroundedHere == true {
            add(.runNormally, "Run Normally", symbol: "tortoise.fill", key: "b")
        } else {
            add(.background, "Run in Background", symbol: "tortoise", key: "b")
        }
        let lower = reason(.lowerPriority)
        verbs.append(
            ResourceVerb(
                title: "Lower Priority", symbol: "arrow.down.circle", key: "n",
                children: ActivityNiceStep.allCases.map { step in
                    var why = lower
                    if why == nil, let subject { why = step.already(from: subject.nice) }
                    let title = subject.map { "\(step.title.dropLast()) — nice \(step.value(from: $0.nice))…" } ?? step.title
                    return ResourceVerb(
                        title: title, symbol: "arrow.down", unavailable: why, perform: { [weak self] in self?.actions.lower(identity, step) })
                }))
        return verbs
    }

    /// The routes the page takes from a row now: the pane's close, Suspend
    /// and Resume Tab, a pane's job suspended with its pane.
    package nonisolated static let routes: Set<ActivityRoute> = [.closePane, .suspendTab, .resumeTab, .suspendPane]
    package nonisolated static let reading = "Being read…"
    package nonisolated static let routeElsewhere = "Its owner's own verb: on its own page."

    /// Why the page doesn't do what `rule` says now; nil when it does: a
    /// refusal, or an owner's verb on another page. Pure.
    package nonisolated static func unavailable(_ rule: ActivityRule) -> String? {
        switch rule {
        case .refused(let why): return why
        case .route(let route, _): return routes.contains(route) ? nil : routeElsewhere
        case .allowed: return nil
        }
    }

    /// `k`, `K`, `x`, `p`, `b`, `n` on the selected process: `k`'s verb decided on the
    /// process read again as its sheet opens.
    package func pressSignalKey(_ key: ActivityKey) -> Bool {
        guard selection.count == 1 else { return refuse(selection.isEmpty ? Self.nothingSelected : Self.severalSelected) }
        // An ended row's pid may be another's already: never acted on.
        guard let row = selectedProcess else { return refuse(Self.notForThisRow) }
        switch key {
        case .stop: actions.stop(row.identity)
        case .forceQuit: actions.act(.forceQuit, row.identity)
        case .signal: actions.chooseSignal(row.identity)
        case .suspend:
            guard let subject = subject(for: row) else { return refuse(Self.reading) }
            actions.act(subject.target.stopped != nil ? .resume : .suspend, row.identity)
        case .background:
            guard let subject = subject(for: row) else { return refuse(Self.reading) }
            actions.act(subject.target.backgroundedHere ? .runNormally : .background, row.identity)
        case .lower: actions.chooseLower(row.identity)
        default: return false
        }
        return true
    }
}
