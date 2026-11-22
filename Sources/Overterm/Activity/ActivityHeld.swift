import Darwin
import Foundation

/// What Activity itself stopped and put in the background (docs/design/
/// activity/analysis.md, 6.10, 3.9): kept by identity — pid and start, and
/// the executable each was listed with —, in memory; the stopped ones'
/// identities alone are also written down (`ActivityPersistence`, D-29), so
/// the next launch after a crash offers to resume them. Only what is here is
/// resumed by Resume and Resume All, or put back by Run Normally: a ⌃Z
/// job is its shell's, Suspend Tab's is Resume Tab's, and the background
/// state can't be read back for another process (3.9), so nothing else is
/// said to be in it. Quitting with any still stopped asks (`quitQuestion`).
@MainActor
package final class ActivityHeld: ObservableObject {
    package static let shared = ActivityHeld()

    /// One Suspend: the process asked about and what was stopped with it —
    /// its subtree, parents first, the root first —, each as it was listed.
    package struct Suspension: Hashable, Sendable, Identifiable {
        package var id: ActivityProcessID { root.identity }
        package let root: ActivitySignalTarget
        package let name: String
        /// Parents first, `root` first: the order they were stopped in.
        package var members: [ActivitySignalTarget]
        /// Each member's name, for Resume All's sheet.
        package var names: [ActivityProcessID: String]
        /// When it was stopped: a census read before then can't say it runs.
        package let at: Date
    }

    @Published package private(set) var suspensions: [Suspension] = []
    /// What Run in Background put there, by identity, with when.
    @Published package private(set) var background: [ActivityProcessID: Date] = [:]

    /// How long after a change a census is trusted to say it undid it: one
    /// read before the signal landed would say a stopped process runs.
    package static let settle: TimeInterval = 2

    /// Every identity Activity stopped and still holds stopped.
    package var stopped: Set<ActivityProcessID> { Set(suspensions.flatMap { $0.members.map(\.identity) }) }
    /// How many processes are stopped here: the header's "2 stopped here".
    package var stoppedCount: Int { suspensions.reduce(0) { $0 + $1.members.count } }
    package var backgroundHere: Set<ActivityProcessID> { Set(background.keys) }

    /// A Suspend stopped `members` (parents first, `root` first if it was).
    package func suspended(root: ActivitySignalTarget, name: String, members: [ActivitySignalTarget], names: [ActivityProcessID: String], at: Date = Date()) {
        guard !members.isEmpty else { return }
        let ids = Set(members.map(\.identity))
        // Stopped again from here: one record each.
        var kept = suspensions.compactMap { suspension -> Suspension? in
            var suspension = suspension
            suspension.members.removeAll { ids.contains($0.identity) }
            return suspension.members.isEmpty ? nil : suspension
        }
        kept.append(Suspension(root: root, name: name, members: members, names: names, at: at))
        suspensions = kept
    }

    /// Suspend's SIGSTOPs, `members` parents first with the root first: the
    /// root alone first, and the rest only once it was stopped — a root
    /// that ended, exec'd or was refused stops nothing of its tree, so
    /// nothing is left frozen that the person was told wasn't. Every
    /// answer; blocking, any thread.
    package nonisolated static func stopTree(_ members: [ActivitySignalTarget], signals: ProcessSignals) -> [(target: ActivitySignalTarget, answer: ActivitySignalAnswer)] {
        guard let root = members.first else { return [] }
        let first = signals.sendTree(.stop, to: [root])
        guard case .sent? = first.first?.answer else { return first }
        return first + signals.sendTree(.stop, to: Array(members.dropFirst()))
    }

    /// The members of `listed` Activity still holds now, in their order:
    /// what a Resume's button sends — one let go while its sheet was up
    /// (continued elsewhere, then stopped again by its shell) is not
    /// Activity's to continue any more.
    package func stillHeld(_ listed: [ActivitySignalTarget]) -> [ActivitySignalTarget] {
        let now = stopped
        return listed.filter { now.contains($0.identity) }
    }

    /// Resume All's at its button: each Suspension cut to the members its
    /// sheet listed that are still held now.
    package func stillHeld(listed: Set<ActivityProcessID>) -> [Suspension] {
        suspensions.compactMap { suspension in
            var suspension = suspension
            suspension.members.removeAll { !listed.contains($0.identity) }
            return suspension.members.isEmpty ? nil : suspension
        }
    }

    /// What a Resume of `identity` continues, parents first: its whole
    /// Suspension when it is the one asked about, else itself — each as it
    /// was stopped. Empty when Activity holds nothing of it.
    package func resumeTargets(for identity: ActivityProcessID) -> [ActivitySignalTarget] {
        if let whole = suspensions.first(where: { $0.root.identity == identity }) { return whole.members }
        for suspension in suspensions {
            if let member = suspension.members.first(where: { $0.identity == identity }) { return [member] }
        }
        return []
    }

    /// The name a member was stopped as.
    package func name(of identity: ActivityProcessID) -> String? {
        for suspension in suspensions { if let name = suspension.names[identity] { return name } }
        return nil
    }

    /// When each was last continued here: a census that started before
    /// still lists it stopped, and a stop then is no ⌃Z (`recentlyResumed`).
    private var resumedAt: [ActivityProcessID: Date] = [:]

    /// What was continued here less than `settle` ago.
    package func recentlyResumed(now: Date = Date()) -> Set<ActivityProcessID> {
        Set(resumedAt.filter { now.timeIntervalSince($0.value) <= Self.settle }.keys)
    }

    /// `identities` continued, or ended: no longer held.
    package func resumed(_ identities: Set<ActivityProcessID>, at now: Date = Date()) {
        guard !identities.isEmpty else { return }
        resumedAt = resumedAt.filter { now.timeIntervalSince($0.value) <= Self.settle }
        for identity in identities { resumedAt[identity] = now }
        suspensions = suspensions.compactMap { suspension in
            var suspension = suspension
            suspension.members.removeAll { identities.contains($0.identity) }
            return suspension.members.isEmpty ? nil : suspension
        }
    }

    package func backgrounded(_ identity: ActivityProcessID, at: Date = Date()) { background[identity] = at }

    package func runsNormally(_ identity: ActivityProcessID) { background[identity] = nil }

    /// Each held identity against a census read at `date`: one gone, a
    /// zombie, or — stopped ones — running again (continued by its shell's
    /// `fg`, a `kill -CONT`) is let go. What changed after the census was
    /// read is kept until a later one can say.
    package func prune(at date: Date, _ process: (ActivityProcessID) -> ActivityProcess?) {
        func alive(_ identity: ActivityProcessID) -> ActivityProcess? {
            guard let found = process(identity), found.identity == identity, !found.isZombie else { return nil }
            return found
        }
        let pruned = suspensions.compactMap { suspension -> Suspension? in
            guard date.timeIntervalSince(suspension.at) > Self.settle else { return suspension }
            var suspension = suspension
            suspension.members.removeAll { alive($0.identity)?.isStopped != true }
            return suspension.members.isEmpty ? nil : suspension
        }
        if pruned != suspensions { suspensions = pruned }
        let kept = background.filter { date.timeIntervalSince($0.value) <= Self.settle || alive($0.key) != nil }
        if kept != background { background = kept }
    }

    /// What is still stopped now, read through `kernel` — each member's
    /// structure, microseconds: the quit question's count. Parents first.
    package func stillStopped(kernel: any ActivityKernel = LiveActivityKernel()) -> [ActivitySignalTarget] {
        suspensions.flatMap(\.members).filter { member in
            guard let process = kernel.process(member.identity.pid) else { return false }
            return process.identity == member.identity && !process.isZombie && process.isStopped
        }
    }

    /// Continues every held process — each Suspension's members children
    /// first, by the identity it was stopped with — and lets each go: the
    /// quit question's Resume and Quit, on the main thread at quit
    /// (microseconds a member: `ProcessSignals`' reads at a decision).
    /// What wasn't continued, with why — refused or failed, still held:
    /// only what continued or ended is let go.
    @discardableResult
    package func resumeAll(signals: ProcessSignals = ProcessSignals()) -> [(target: ActivitySignalTarget, answer: ActivitySignalAnswer)] {
        let answers = Self.continueAll(suspensions, signals: signals)
        resumed(Set(answers.filter { Self.letGo($0.answer) }.map(\.target.identity)))
        return answers.filter { !Self.letGo($0.answer) }
    }

    /// After Resume and Quit, when some weren't continued: they stay
    /// stopped once Overterm is gone, so the quit is asked again — each
    /// listed with why. Its buttons: Don't Quit (the default), Quit Anyway.
    package nonisolated static func notResumedQuestion(_ failed: [(pid: pid_t, name: String?, why: String)]) -> (title: String, detail: String)? {
        guard !failed.isEmpty else { return nil }
        let title = failed.count == 1 ? "A process you suspended couldn't be resumed" : "\(failed.count) processes you suspended couldn't be resumed"
        let lines = failed.map { "pid \($0.pid)\($0.name.map { " " + DockerMCP.displayed($0) } ?? ""): \($0.why)" }
        let detail =
            lines.joined(separator: "\n")
            + "\n\(failed.count == 1 ? "It stays" : "They stay") stopped once Overterm is gone. Resume All on the Activity page tries again."
        return (title, detail)
    }

    package nonisolated static let notResumedButtons = ["Don't Quit", "Quit Anyway"]

    /// Each of `suspensions` continued, children first: every answer.
    /// Blocking; any thread.
    package nonisolated static func continueAll(_ suspensions: [Suspension], signals: ProcessSignals) -> [(target: ActivitySignalTarget, answer: ActivitySignalAnswer)] {
        suspensions.flatMap { signals.sendTree(.cont, to: $0.members) }
    }

    /// Whether a CONT's answer lets its process go: continued, or ended.
    /// One refused or failed is still Activity's to say.
    package nonisolated static func letGo(_ answer: ActivitySignalAnswer) -> Bool {
        switch answer {
        case .sent, .ended, .ranAnotherProgram: true
        case .refused, .failed: false
        }
    }

    /// Quitting with processes Activity stopped (6.10, Escalation,
    /// suspension, priority): nil when none is still stopped. Its buttons
    /// are `quitButtons`; the first, the default, resumes them and quits.
    package nonisolated static func quitQuestion(stopped count: Int) -> (title: String, detail: String)? {
        guard count > 0 else { return nil }
        let title =
            count == 1 ? "A process you suspended from Activity is still stopped" : "\(count) processes you suspended from Activity are still stopped"
        let detail =
            "Nothing continues \(count == 1 ? "it" : "them") once Overterm is gone: \(count == 1 ? "it stays" : "they stay") stopped, holding \(count == 1 ? "its" : "their") memory and ports. "
            + "Resume and Quit continues each first, by the process it was stopped as."
        return (title, detail)
    }

    package nonisolated static let quitButtons = ["Resume and Quit", "Quit", "Cancel"]
}
