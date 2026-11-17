import Darwin
import Foundation

/// What Activity itself stopped and put in the background (docs/design/
/// activity/analysis.md, 6.10, 3.9): kept by identity — pid and start, and
/// the executable each was listed with —, in memory only (D-29 decides in
/// stage 3 whether the stopped ones outlive a crash). Only what is here is
/// resumed by Resume and Resume All, or put back by Run Normally: a ⌃Z
/// job is its shell's, Suspend Tab's is Resume Tab's, and the background
/// state can't be read back for another process (3.9), so nothing else is
/// said to be in it.
@MainActor
final class ActivityHeld: ObservableObject {
    static let shared = ActivityHeld()

    /// One Suspend: the process asked about and what was stopped with it —
    /// its subtree, parents first, the root first —, each as it was listed.
    struct Suspension: Hashable, Sendable, Identifiable {
        var id: ActivityProcessID { root.identity }
        let root: ActivitySignalTarget
        let name: String
        /// Parents first, `root` first: the order they were stopped in.
        var members: [ActivitySignalTarget]
        /// Each member's name, for Resume All's sheet.
        var names: [ActivityProcessID: String]
        /// When it was stopped: a census read before then can't say it runs.
        let at: Date
    }

    @Published private(set) var suspensions: [Suspension] = []
    /// What Run in Background put there, by identity, with when.
    @Published private(set) var background: [ActivityProcessID: Date] = [:]

    /// How long after a change a census is trusted to say it undid it: one
    /// read before the signal landed would say a stopped process runs.
    static let settle: TimeInterval = 2

    /// Every identity Activity stopped and still holds stopped.
    var stopped: Set<ActivityProcessID> { Set(suspensions.flatMap { $0.members.map(\.identity) }) }
    /// How many processes are stopped here: the header's "2 stopped here".
    var stoppedCount: Int { suspensions.reduce(0) { $0 + $1.members.count } }
    var backgroundHere: Set<ActivityProcessID> { Set(background.keys) }

    /// A Suspend stopped `members` (parents first, `root` first if it was).
    func suspended(root: ActivitySignalTarget, name: String, members: [ActivitySignalTarget], names: [ActivityProcessID: String], at: Date = Date()) {
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
    nonisolated static func stopTree(_ members: [ActivitySignalTarget], signals: ProcessSignals) -> [(target: ActivitySignalTarget, answer: ActivitySignalAnswer)] {
        guard let root = members.first else { return [] }
        let first = signals.sendTree(.stop, to: [root])
        guard case .sent? = first.first?.answer else { return first }
        return first + signals.sendTree(.stop, to: Array(members.dropFirst()))
    }

    /// The members of `listed` Activity still holds now, in their order:
    /// what a Resume's button sends — one let go while its sheet was up
    /// (continued elsewhere, then stopped again by its shell) is not
    /// Activity's to continue any more.
    func stillHeld(_ listed: [ActivitySignalTarget]) -> [ActivitySignalTarget] {
        let now = stopped
        return listed.filter { now.contains($0.identity) }
    }

    /// Resume All's at its button: each Suspension cut to the members its
    /// sheet listed that are still held now.
    func stillHeld(listed: Set<ActivityProcessID>) -> [Suspension] {
        suspensions.compactMap { suspension in
            var suspension = suspension
            suspension.members.removeAll { !listed.contains($0.identity) }
            return suspension.members.isEmpty ? nil : suspension
        }
    }

    /// What a Resume of `identity` continues, parents first: its whole
    /// Suspension when it is the one asked about, else itself — each as it
    /// was stopped. Empty when Activity holds nothing of it.
    func resumeTargets(for identity: ActivityProcessID) -> [ActivitySignalTarget] {
        if let whole = suspensions.first(where: { $0.root.identity == identity }) { return whole.members }
        for suspension in suspensions {
            if let member = suspension.members.first(where: { $0.identity == identity }) { return [member] }
        }
        return []
    }

    /// The name a member was stopped as.
    func name(of identity: ActivityProcessID) -> String? {
        for suspension in suspensions { if let name = suspension.names[identity] { return name } }
        return nil
    }

    /// When each was last continued here: a census that started before
    /// still lists it stopped, and a stop then is no ⌃Z (`recentlyResumed`).
    private var resumedAt: [ActivityProcessID: Date] = [:]

    /// What was continued here less than `settle` ago.
    func recentlyResumed(now: Date = Date()) -> Set<ActivityProcessID> {
        Set(resumedAt.filter { now.timeIntervalSince($0.value) <= Self.settle }.keys)
    }

    /// `identities` continued, or ended: no longer held.
    func resumed(_ identities: Set<ActivityProcessID>, at now: Date = Date()) {
        guard !identities.isEmpty else { return }
        resumedAt = resumedAt.filter { now.timeIntervalSince($0.value) <= Self.settle }
        for identity in identities { resumedAt[identity] = now }
        suspensions = suspensions.compactMap { suspension in
            var suspension = suspension
            suspension.members.removeAll { identities.contains($0.identity) }
            return suspension.members.isEmpty ? nil : suspension
        }
    }

    func backgrounded(_ identity: ActivityProcessID, at: Date = Date()) { background[identity] = at }

    func runsNormally(_ identity: ActivityProcessID) { background[identity] = nil }

    /// Each held identity against a census read at `date`: one gone, a
    /// zombie, or — stopped ones — running again (continued by its shell's
    /// `fg`, a `kill -CONT`) is let go. What changed after the census was
    /// read is kept until a later one can say.
    func prune(at date: Date, _ process: (ActivityProcessID) -> ActivityProcess?) {
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

    /// Each of `suspensions` continued, children first: every answer.
    /// Blocking; any thread.
    nonisolated static func continueAll(_ suspensions: [Suspension], signals: ProcessSignals) -> [(target: ActivitySignalTarget, answer: ActivitySignalAnswer)] {
        suspensions.flatMap { signals.sendTree(.cont, to: $0.members) }
    }

    /// Whether a CONT's answer lets its process go: continued, or ended.
    /// One refused or failed is still Activity's to say.
    nonisolated static func letGo(_ answer: ActivitySignalAnswer) -> Bool {
        switch answer {
        case .sent, .ended, .ranAnotherProgram: true
        case .refused, .failed: false
        }
    }
}
