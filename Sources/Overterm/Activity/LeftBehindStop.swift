import Darwin
import Foundation

/// What a Left Behind stop may send (docs/design/activity/analysis.md, 6.9,
/// 6.10): every target read again at the button and asked of the policy —
/// `ActivitySignalCheck` is the only source of what is sent. Only what its
/// Stop rule answers with a plain SIGTERM is sent; a terraform write
/// (Interrupt only), an agent (Stop Agent, critical), an app (Quit), a
/// release write (critical) and whatever the rule refuses are left out with
/// why. Pure.
package enum LeftBehindStop {
    /// How the targets were picked.
    package enum Pick: Hashable, Sendable {
        /// Several at once — Stop All Certain, the launch's Stop All, a
        /// worktree's removal: the bulk rule too (`bulkRefusal`).
        case bulk
        /// Stop All Certain in This Checkout: the bulk rule, and still
        /// Left Behind, certain and bulk-eligible now.
        case certain
        /// Ticked one by one in a close sheet: the Stop rule alone.
        case picked
    }

    package struct Refused: Hashable, Sendable {
        package let target: ActivitySignalTarget
        package let name: String
        package let reason: String

        /// "acme-server (pid 4242): a terraform write: Interrupt it alone".
        package var line: String { "\(name) (pid \(target.identity.pid)): \(reason)" }
    }

    package struct Checked: Hashable, Sendable {
        package var send: [ActivitySignalTarget] = []
        package var refused: [Refused] = []
    }

    package static let endedWords = "it has ended"
    package static let keptWords = "you kept it"
    package static let notCertainWords = "no longer certainly left behind"

    /// Each of `targets` as `snapshot` reads it now.
    package static func check(
        _ targets: [ActivitySignalTarget], pick: Pick, in snapshot: ActivitySnapshot, owners: ActivityAttribution,
        known: ActivityVerbSubject.Known, kept: Set<ActivityProcessID>
    ) -> Checked {
        var checked = Checked()
        for target in targets {
            guard let subject = ActivityVerbSubject.read(target.identity, in: snapshot, owners: owners, known: known),
                let process = snapshot.table.process(target.identity)
            else {
                checked.refused.append(Refused(target: target, name: "a process", reason: endedWords))
                continue
            }
            if let reason = refusal(
                subject, process: process, owner: owners[target.identity], pick: pick, kept: kept, table: snapshot.table, user: snapshot.uid)
            {
                checked.refused.append(Refused(target: target, name: subject.name, reason: reason))
            } else {
                checked.send.append(target)
            }
        }
        return checked
    }

    /// Why `subject` isn't sent SIGTERM here; nil when it is.
    package static func refusal(
        _ subject: ActivityVerbSubject, process: ActivityProcess, owner: ActivityOwner?, pick: Pick, kept: Set<ActivityProcessID>,
        table: ProcessTable, user: uid_t = getuid()
    ) -> String? {
        let target = subject.target
        if LeftBehind.isKept(subject.signal.identity, kept: kept, table: table) { return keptWords }
        if pick != .picked, let reason = ActivitySignalCheck.bulkRefusal(target, user: user) { return reason }
        if pick == .certain {
            guard let owner,
                LeftBehind.isBulkEligible(owner, process: process, terraformWrite: target.terraformWrite != nil, kept: owner.kept)
            else { return notCertainWords }
        }
        switch ActivitySignalCheck.rule(.stop, for: target, user: user) {
        case .allowed(.signal(.term), _, false): return nil
        case .refused(let reason): return reason
        case .allowed(.signal(.term), _, true):
            return target.kind == .agent ? "an agent: Stop Agent… alone" : "a release write: Stop… it alone"
        case .allowed(.quitApp, _, _): return "an app: Quit… it alone"
        case .allowed:
            return target.terraformWrite != nil ? "a terraform write: Interrupt it alone" : "not a plain Stop: stop it from Activity alone"
        case .route: return "not a process to signal: stop it from Activity alone"
        }
    }
}
