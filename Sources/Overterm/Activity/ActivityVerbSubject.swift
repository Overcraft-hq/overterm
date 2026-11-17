import Darwin
import Foundation

/// A process row as a verb sees it (docs/design/activity/analysis.md,
/// 6.10 step 3): its class and the facts `ActivitySignalCheck` decides by,
/// read from a fresh census when the sheet opens and again at its button,
/// and what its sheet names — its executable, command, children, the
/// supervisor that may start it again, a tree's or a group's members. Pure:
/// one snapshot, its owners, the main actor's few facts.
struct ActivityVerbSubject: Sendable {
    /// One member of a tree or a group, as its sheet lists it.
    struct Member: Hashable, Sendable {
        var signal: ActivitySignalTarget
        var name: String
        var target: ActivityTarget
        /// Why a bulk Stop leaves it out (`ActivitySignalCheck.bulkRefusal`); nil: stopped with the rest.
        var refusal: String?
    }

    var target: ActivityTarget
    /// Who a signal is for: its identity and the executable listed.
    var signal: ActivitySignalTarget
    var name: String
    /// argv masked as it was read (9.3).
    var command: String?
    /// Its pane's tag: where ⌃C is typed — the pane its owner places it in.
    var pane: String?
    var tab: UUID?
    var agent: Agent?
    /// Its process group: ⌃C typed reaches it only while the pane's
    /// foreground group is this.
    var group: pid_t
    var parent: ActivityProcessID?
    var parentName: String?
    /// The parent as the policy sees it: Stop Its Parent's.
    var parentTarget: ActivityTarget?
    /// Its live children, which a Stop leaves running.
    var children: Int
    /// The TCP ports it listens on.
    var listening: [Int]
    /// A parent that may start it again: neither a shell nor launchd nor
    /// Overterm (D-13: named, never stopped with it).
    var supervisor: (pid: pid_t, name: String)?
    /// Its subtree, parents first, itself not among them.
    var tree: [Member]
    /// Its process group's other members, when it leads one.
    var groupMembers: [Member]
    /// Its nice (`p_nice`): Lower Priority only raises it.
    var nice: Int8 = 0

    /// What the main actor knows that the census doesn't: running apps, the
    /// identities Activity stopped and put in the background, what Suspend
    /// Tab stopped.
    struct Known: Sendable {
        var appPID: pid_t = getpid()
        var runningApps: [pid_t: String] = [:]
        var stoppedHere: Set<ActivityProcessID> = []
        var suspendedTab: Set<ActivityProcessID> = []
        var backgroundHere: Set<ActivityProcessID> = []
        /// What Activity continued a moment ago: a census begun before
        /// still lists it stopped (`ActivityHeld.recentlyResumed`).
        var resumedHere: Set<ActivityProcessID> = []

        init(
            appPID: pid_t = getpid(), runningApps: [pid_t: String] = [:], stoppedHere: Set<ActivityProcessID> = [],
            suspendedTab: Set<ActivityProcessID> = [], backgroundHere: Set<ActivityProcessID> = [], resumedHere: Set<ActivityProcessID> = []
        ) {
            self.resumedHere = resumedHere
            self.appPID = appPID
            self.runningApps = runningApps
            self.stoppedHere = stoppedHere
            self.suspendedTab = suspendedTab
            self.backgroundHere = backgroundHere
        }
    }

    /// How many of a tree's members a sheet lists before "and N more".
    static let memberLimit = 512

    /// `identity` read in `snapshot`: nil once it is gone from the table.
    static func read(_ identity: ActivityProcessID, in snapshot: ActivitySnapshot, owners: ActivityAttribution, known: Known) -> ActivityVerbSubject? {
        let table = snapshot.table
        guard let process = table.process(identity) else { return nil }
        let reader = Reader(snapshot: snapshot, owners: owners, known: known)
        let facts = snapshot.facts[identity]
        let owner = owners[identity]
        var pane: String?
        if case .pane(let tag)? = owner?.place { pane = tag }
        let parent = table.parent(of: identity)
        let descendants = table.descendants(of: identity, limit: memberLimit)
        let treeSet = Set(descendants.map(\.identity)).union([identity])
        var target = reader.target(process)
        var groupMembers: [Member] = []
        if process.group == process.pid {
            let members = table.processes.filter { $0.group == process.group && $0.identity != identity && !$0.isZombie }
            target.leadsGroup = true
            target.groupBeyondTree = members.contains { !treeSet.contains($0.identity) }
            groupMembers = members.sorted { $0.identity < $1.identity }.map(reader.member)
            target.groupHolds = groupMembers.lazy.compactMap { ActivitySignalCheck.groupBlocker($0.target, user: snapshot.uid) }.first
        }
        var supervisor: (pid: pid_t, name: String)?
        if let parent, parent.pid > 1, parent.pid != known.appPID {
            let kind = reader.kind(parent)
            if kind != .paneSession, kind != .overterm, kind != .helper(.other) {
                supervisor = (parent.pid, reader.name(parent))
            }
        }
        var subject = ActivityVerbSubject(
            target: target, signal: ActivitySignalTarget(identity, path: facts?.path), name: reader.name(process), command: facts?.command, pane: pane,
            tab: owner?.tab, agent: owner?.agentKind, group: process.group, parent: parent?.identity, parentName: parent.map(reader.name),
            parentTarget: parent.map(reader.target),
            children: table.children(of: identity).filter { !$0.isZombie }.count,
            listening: facts?.sockets?.records.filter(\.isListening).map { Int($0.localPort) }.uniqued() ?? [], supervisor: supervisor,
            tree: descendants.filter { !$0.isZombie }.map(reader.member), groupMembers: groupMembers)
        subject.nice = process.nice
        return subject
    }

    /// Stop Its Tree's members at the button (6.10 step 4), parents first:
    /// the root and the members the sheet listed in no refusal, each as the
    /// sheet listed it — its executable then, so one that exec'd since is
    /// answered "ran another program", never sent what it runs now. `fresh`,
    /// the button's read, only leaves out one that ended or is refused now.
    /// Pure.
    static func treeSend(asked: ActivityVerbSubject, fresh: ActivityVerbSubject) -> [ActivitySignalTarget] {
        let now = Set(fresh.tree.filter { $0.refusal == nil }.map(\.signal.identity))
        return [asked.signal] + asked.tree.filter { $0.refusal == nil && now.contains($0.signal.identity) }.map(\.signal)
    }

    /// What Suspend stops (6.10: "a process outside the panes is suspended
    /// with its subtree"), parents first, itself first: its subtree's
    /// members that a bulk may reach and aren't stopped already — a
    /// terraform write, an app, what chose to outlive its terminal, a
    /// shell or an agent are left out, as a bulk Stop leaves them. Pure.
    var suspendMembers: [ActivitySignalTarget] {
        [signal] + tree.filter { $0.refusal == nil && $0.target.stopped == nil && $0.target.terraformWrite == nil }.map(\.signal)
    }

    /// Each member's name, by identity, itself included.
    var memberNames: [ActivityProcessID: String] {
        var names = [signal.identity: name]
        for member in tree { names[member.signal.identity] = member.name }
        return names
    }

    /// Each process's class and facts, by its owner (6.5) and its record.
    private struct Reader {
        let snapshot: ActivitySnapshot
        let owners: ActivityAttribution
        let known: Known
        /// The process groups an agent is in: a ⌃C or a SIGINT to one
        /// reaches the agent too.
        let agentGroups: Set<pid_t>

        init(snapshot: ActivitySnapshot, owners: ActivityAttribution, known: Known) {
            self.snapshot = snapshot
            self.owners = owners
            self.known = known
            agentGroups = Set(
                snapshot.table.processes.filter { !$0.isZombie && owners[$0.identity]?.paneRole == .agent }.map(\.group))
        }

        func name(_ process: ActivityProcess) -> String { snapshot.name(of: process.identity) ?? process.shortName }

        func member(_ process: ActivityProcess) -> Member {
            let target = target(process)
            return Member(
                signal: ActivitySignalTarget(process.identity, path: snapshot.facts[process.identity]?.path), name: name(process), target: target,
                refusal: ActivitySignalCheck.bulkRefusal(target, user: snapshot.uid))
        }

        /// Its class (6.10's rows) by its owner.
        func kind(_ process: ActivityProcess) -> ActivityClass {
            if process.pid == known.appPID { return .overterm }
            guard let owner = owners[process.identity] else { return .elsewhere }
            switch owner.place {
            case .overterm: return .helper(.other)
            case .anotherOverterm:
                // The other app itself; its tabs' processes are the user's, elsewhere.
                return known.runningApps[process.pid] != nil || name(process).hasPrefix("Overterm") ? .anotherOverterm : .elsewhere
            case .engine: return .engine
            case .macOS: return .macOS
            case .app, .system, .elsewhere: return .elsewhere
            case .leftBehind: return .leftBehind
            case .pane:
                switch owner.paneRole {
                case .session?, .shell?: return .paneSession
                case .agent?: return .agent
                case .agentChild?: return .agentChild
                default: return owner.marks.contains(.leftTerminal) ? .leftTerminal : .paneJob
                }
            }
        }

        func target(_ process: ActivityProcess) -> ActivityTarget {
            let facts = snapshot.facts[process.identity]
            let owner = owners[process.identity]
            let kind = kind(process)
            let executable = ActivityPaneSet.executableName(process, facts: facts)
            var terraformWrite: String?
            if TerraformCommandLine.tools.contains(executable) {
                if let command = facts?.command {
                    if let line = TerraformCommandLine.parse(command, probable: false), line.isWrite {
                        terraformWrite = [line.tool, line.operation].compactMap { $0 }.joined(separator: " ")
                    }
                } else {
                    // Its argv not read: a write, until it says otherwise.
                    terraformWrite = executable
                }
            }
            let releaseWrite = facts?.command.flatMap {
                ActivityTarget.releaseWrite(name: executable, arguments: $0.split(separator: " ").map(String.init))
            }
            let isApp = known.runningApps[process.pid] != nil
            let insideApp = !isApp && (facts?.path?.contains(".app/") ?? false)
            let detached = process.ignoresHangup || owner?.marks.contains(.detached) == true || owner?.marks.contains(.nohup) == true
            // A ⌃C, or a SIGINT to the group, reaches every member: an agent too.
            let groupHoldsAgent = kind == .agent || agentGroups.contains(process.group)
            var stopped: ActivityStopper?
            if process.isStopped {
                if process.flags.contains(.traced) {
                    stopped = .traced
                } else if known.stoppedHere.contains(process.identity) {
                    stopped = .activity
                } else if known.suspendedTab.contains(process.identity) {
                    stopped = .suspendTab
                } else if process.terminal != nil {
                    stopped = .jobControl
                } else {
                    stopped = .unknown
                }
            }
            var target = ActivityTarget(
                kind, pid: process.pid, effectiveUID: process.effectiveUID, realUID: process.realUID, savedUID: process.savedUID,
                isZombie: process.isZombie, inForeground: process.terminal != nil && process.terminalGroup == process.group,
                groupHoldsAgent: groupHoldsAgent, terraformWrite: terraformWrite, releaseWrite: releaseWrite, detached: detached, isApp: isApp,
                insideApp: insideApp, stopped: stopped)
            target.backgroundedHere = known.backgroundHere.contains(process.identity)
            return target
        }
    }
}

extension Array where Element: Hashable {
    /// In order, each once.
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
