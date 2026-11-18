import Darwin
import Foundation

/// Who a process belongs to (docs/design/activity/analysis.md, 6.5,
/// Owners): a place to show it, why, and how sure.
struct ActivityOwner: Hashable, Sendable {
    enum Place: Hashable, Sendable {
        /// Overterm itself and what it started (rules 1, 2; 13 for what it
        /// is responsible for).
        case overterm
        /// A pane of this run, by its tag (rules 3, 4, 9; 5 while it lives).
        case pane(String)
        /// Another Overterm, its tabs (rule 10).
        case anotherOverterm
        /// A container engine, or its VM (rule 6), by its name.
        case engine(String)
        /// An app, by its bundle's name (rules 7, 12, 13).
        case app(String)
        /// macOS's own (rule 14).
        case macOS
        /// Another user's or root's (rule 15).
        case system
        /// Anything else of the user's (rule 16; 5 once its pane is gone).
        case elsewhere
        /// What outlived its tab, its agent or an earlier Overterm (rules
        /// 8 and 11, 6.9): `ActivityOwner.leftBehind` says why.
        case leftBehind
    }

    enum Certainty: Hashable, Sendable {
        case certain
        case probably
    }

    /// What a process is in its pane (6.5, rule 4).
    enum PaneRole: Hashable, Sendable {
        /// The `login` libghostty spawned.
        case session
        /// The login's shell.
        case shell
        /// The terminal's foreground group.
        case foreground
        case background
        /// The pane's agent: the first claude or codex in its tree.
        case agent
        /// Below the agent: its MCP servers, tool shells, dev servers.
        case agentChild
    }

    /// Chips beside the name (6.5).
    struct Marks: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        /// Rule 5: a session manager or a daemon started on purpose.
        static let detached = Marks(rawValue: 1 << 0)
        /// Rule 9: it left its terminal, carrying the pane's tag.
        static let leftTerminal = Marks(rawValue: 1 << 1)
        /// It ignores SIGHUP.
        static let nohup = Marks(rawValue: 1 << 2)
        /// It leads a session of its own, with no terminal.
        static let setsid = Marks(rawValue: 1 << 3)
        /// Rule 7: an app started from a pane.
        static let fromPane = Marks(rawValue: 1 << 4)
    }

    var place: Place
    /// The rule of 6.5 that placed it.
    var rule: Int
    var reason: String?
    var certainty = Certainty.certain
    var marks: Marks = []
    /// The tab of its pane — or of the pane it was started from (an app, a
    /// detached daemon).
    var tab: UUID?
    var paneRole: PaneRole?
    /// The agent it runs under, or is.
    var agent: ActivityProcessID?
    var agentKind: Agent?
    var role = ProcessRole.other
    /// Rules 8 and 11: the sign that put it in Left Behind (6.9).
    var leftBehind: LeftBehindSign?
    /// The person kept it (Keep, or unticked in a close sheet): never in a
    /// bulk Stop, never Left Behind again for its life (6.9).
    var kept = false
}

/// What the main actor says of a tab, for owners and rows (6.5): the place
/// a tab's processes are shown at. Values only.
struct ActivityTabFacts: Hashable, Sendable {
    let id: UUID
    /// Masked as a command (`ActivityText.title`).
    var title: String
    /// The checkout its sidebar shows, and its branch.
    var checkout: String?
    var branch: String?
    /// The repository's name — its main worktree's folder — when known.
    var repository: String?
    /// Its place in the strips: every window's, in window order.
    var order = 0
    /// The agent it was opened for.
    var agent: Agent?
    /// Its agent waits for the person (`TabActivity`'s waiting mark, the
    /// agent's own): what "idle but burning" asks (6.11).
    var waiting = false
    /// Since when it waits (`TabActivity.waitingSince`): the burn counts
    /// from then.
    var waitingSince: Date?
}

/// Each process's owner, reason and certainty (6.5): pure, one snapshot,
/// one context, the tabs' facts. The first rule that matches wins; a child
/// inherits its parent's owner unless a rule above matches it. Nothing is
/// read now, no file system walked: a path is a string.
struct ActivityAttribution: Sendable {
    let owners: [ActivityProcessID: ActivityOwner]

    subscript(_ identity: ActivityProcessID) -> ActivityOwner? { owners[identity] }

    /// What else it is told: the main actor's facts.
    struct Inputs: Sendable {
        var tabs: [UUID: ActivityTabFacts] = [:]
        /// Every known checkout: the tabs', the worktrees'.
        var checkouts: [String] = []
        /// Running apps' bundles by pid (`NSRunningApplication`): a deleted
        /// executable's place (rule 12).
        var runningApps: [pid_t: String] = [:]

        init(tabs: [UUID: ActivityTabFacts] = [:], checkouts: [String] = [], runningApps: [pid_t: String] = [:]) {
            self.tabs = tabs
            self.checkouts = checkouts
            self.runningApps = runningApps
        }
    }

    /// Engines and their VMs' port holders by executable (rule 6,
    /// `KnownHolders`), with the engine's name.
    static let engineHolders: [String: String] = [
        "com.docker.backend": "Docker", "com.docker.vpnkit": "Docker", "vpnkit-bridge": "Docker", "com.docker.krun": "Docker",
        "com.docker.virtualization": "Docker", "OrbStack Helper": "OrbStack", "OrbStack": "OrbStack", "limactl": "Lima", "colima": "Colima",
        "gvproxy": "Podman", "vfkit": "Podman", "krunkit": "Podman",
    ]

    /// Engines' apps, by bundle name: a VM they are responsible for is theirs.
    static let engineApps: [String: String] = [
        "Docker": "Docker", "Docker Desktop": "Docker", "OrbStack": "OrbStack", "Podman Desktop": "Podman", "Rancher Desktop": "Rancher Desktop",
    ]

    /// macOS's agents by name, with what people know them as (rule 14).
    static let appleAgents: [String: String] = [
        "ControlCenter": "AirPlay Receiver (ControlCenter)", "rapportd": "Continuity (rapportd)", "Dock": "the Dock", "Finder": "the Finder",
        "SystemUIServer": "the menu bar (SystemUIServer)", "WindowServer": "the screen (WindowServer)", "sharingd": "AirDrop (sharingd)",
        "mDNSResponder": "Bonjour (mDNSResponder)", "launchd": "launchd",
    ]

    static func of(_ snapshot: ActivitySnapshot, context: ActivityContext, inputs: Inputs = Inputs()) -> ActivityAttribution {
        var builder = Builder(snapshot: snapshot, context: context, inputs: inputs)
        builder.run()
        return ActivityAttribution(owners: builder.owners)
    }

    // MARK: The rules

    private struct Builder {
        let snapshot: ActivitySnapshot
        let context: ActivityContext
        let inputs: Inputs
        var owners: [ActivityProcessID: ActivityOwner] = [:]
        let table: ProcessTable
        /// The panes' logins, and Overterm's helpers as the tick found them.
        let logins: Set<ActivityProcessID>
        let helpers: Set<ActivityProcessID>
        /// What each path says, read on earlier ticks (`ActivityPathWords`),
        /// and what this one read anew; the roles alike (`ProcessRole`).
        let knownWords = ActivityPathWords.cached()
        var madeWords: [ActivityProcessID: ActivityPathWords] = [:]
        let knownRoles = ProcessRole.cached()
        var madeRoles: [ActivityProcessID: ProcessRole.Cached] = [:]

        init(snapshot: ActivitySnapshot, context: ActivityContext, inputs: Inputs) {
            self.snapshot = snapshot
            self.context = context
            self.inputs = inputs
            table = snapshot.table
            logins = Set(snapshot.panes.compactMap(\.login)).union(context.panes.compactMap(\.login))
            helpers = Set(snapshot.helpers)
            liveTags = Set(context.panes.map(\.tag))
            openCheckouts = Set(inputs.tabs.values.compactMap(\.checkout))
        }

        /// The live panes' tags, and the checkouts a tab shows (6.9's signs).
        let liveTags: Set<String>
        let openCheckouts: Set<String>

        func title(of tab: UUID) -> String { inputs.tabs[tab]?.title ?? "" }

        /// "pane 2 of “web”", or "“web”" alone when it has one pane.
        func paneWords(_ slice: ActivityPaneSlice) -> String {
            let panes = snapshot.panes(of: slice.tab)
            let quoted = "“\(title(of: slice.tab))”"
            guard panes.count > 1, let index = panes.firstIndex(where: { $0.tag == slice.tag }) else { return quoted }
            return "pane \(index + 1) of \(quoted)"
        }

        func name(_ identity: ActivityProcessID) -> String { snapshot.name(of: identity) ?? "" }

        mutating func run() {
            let processes = table.processes.sorted { $0.identity < $1.identity }
            placePanes()
            // The panes' processes' roles, now they are all placed.
            for identity in Array(owners.keys) {
                guard let process = table.process(identity), var owner = owners[identity] else { continue }
                finish(&owner, process, snapshot.facts[identity])
                owners[identity] = owner
            }
            owners.reserveCapacity(processes.count)
            // Parents first: a child is no older than its parent. Each
            // process's facts read once, its path's words once a life.
            for process in processes where owners[process.identity] == nil {
                let identity = process.identity
                let facts = snapshot.facts[identity]
                let words: ActivityPathWords
                if let known = knownWords[identity], known.describes(path: facts?.path, name: facts?.name, shortName: process.shortName) {
                    words = known
                } else {
                    words = ActivityPathWords(path: facts?.path, name: facts?.name, shortName: process.shortName)
                    madeWords[identity] = words
                }
                var owner = owner(of: process, facts, words)
                finish(&owner, process, facts)
                owners[identity] = owner
            }
            ProcessRole.remember(madeRoles, live: owners.count)
            ActivityPathWords.remember(madeWords, live: owners.count)
        }

        /// What `process`'s path and names say: as read before while they
        /// are the same strings, else read now.
        func words(_ process: ActivityProcess, _ facts: ActivityFacts?) -> ActivityPathWords {
            let identity = process.identity
            if let words = madeWords[identity] ?? knownWords[identity], words.describes(path: facts?.path, name: facts?.name, shortName: process.shortName) {
                return words
            }
            return ActivityPathWords(path: facts?.path, name: facts?.name, shortName: process.shortName)
        }

        // MARK: Rules 3–5, 7, 9: the panes

        /// The panes' trees and what carries their tags, through each
        /// pane's set (`ActivityPaneSet`): what it leaves out says rule 5
        /// or 7; the rest is the pane's. Rules 1, 2 and 6 still win.
        mutating func placePanes() {
            let appPID = context.appPID
            var sets: [(slice: ActivityPaneSlice, set: ActivityPaneSet)] = []
            for slice in snapshot.panes {
                let terminal = context.panes.first { $0.tag == slice.tag }?.terminal
                sets.append((slice, ActivityPaneSet(slice, in: snapshot, terminal: terminal, checkouts: inputs.checkouts)))
            }
            // The trees first, then what left them: a process is a tree's
            // before it is a tag's.
            for pass in 0..<2 {
                for (slice, set) in sets {
                    let inTree = Set(slice.tree + (slice.login.map { [$0] } ?? []))
                    var reasons: [ActivityProcessID: ActivityPaneSet.Exclusion] = [:]
                    for (identity, reason) in set.leftOut { reasons[identity] = reason }
                    let ordered = pass == 0 ? (slice.login.map { [$0] } ?? []) + slice.tree : slice.tagged
                    for identity in ordered where owners[identity] == nil {
                        guard let process = table.process(identity), process.pid != appPID, !helpers.contains(identity) else { continue }
                        var reason = reasons[identity]
                        if reason == .underExcluded { reason = rootReason(of: identity, reasons) }
                        // Rule 4 wins over 6 in the tree; what left it, or
                        // a daemon started from it, may be an engine's.
                        if pass == 1 || reason == .detachedOnPurpose || reason == .app,
                            let engine = engine(of: process, snapshot.facts[identity], words(process, snapshot.facts[identity]))
                        {
                            var owner = engine
                            owner.tab = slice.tab
                            owners[identity] = owner
                            continue
                        }
                        // 8. What carries the pane's tag outside its tree and
                        // started inside one of its agent's ended runs — or
                        // under one that did: left by the agent.
                        if pass == 1, reason == nil || reason == .ignoresHangup, !isKept(identity),
                            let left = agentRunOwner(process, slice)
                        {
                            owners[identity] = left
                            continue
                        }
                        owners[identity] = paneOwner(process, slice, inTree: inTree.contains(identity), exclusion: reason)
                    }
                }
            }
        }

        /// Rule 8 (6.9): `process`, outside `slice`'s tree with its tag,
        /// started inside an ended run of the pane's agent, or under a
        /// process that did.
        func agentRunOwner(_ process: ActivityProcess, _ slice: ActivityPaneSlice) -> ActivityOwner? {
            var sign: LeftBehindSign?
            if let run = LeftBehind.agentRun(process.identity, tag: slice.tag, runs: context.agentRuns) {
                sign = .agentRun(run, title: title(of: slice.tab))
            } else if let parent = table.parent(of: process.identity), let owner = owners[parent.identity], owner.place == .leftBehind,
                case .agentRun? = owner.leftBehind
            {
                sign = owner.leftBehind
            }
            guard let sign else { return nil }
            return leftBehindOwner(process, sign, rule: 8)
        }

        func leftBehindOwner(_ process: ActivityProcess, _ sign: LeftBehindSign, rule: Int) -> ActivityOwner {
            var owner = ActivityOwner(place: .leftBehind, rule: rule, reason: sign.reason, certainty: sign.certainty)
            if process.ignoresHangup { owner.marks.insert(.nohup) }
            if process.flags.contains(.sessionLeader), process.terminal == nil { owner.marks.insert(.setsid) }
            owner.leftBehind = sign
            owner.tab = sign.tab
            return owner
        }

        /// Rule 11 (6.9): a closed pane's tag, an earlier Overterm's
        /// marker or argv sign, a dead group leader. One the person kept is
        /// theirs, elsewhere, "kept running".
        func leftBehind(_ process: ActivityProcess, _ facts: ActivityFacts?, _ words: ActivityPathWords) -> ActivityOwner? {
            guard process.isOwn(by: snapshot.uid) else { return nil }
            guard
                let sign = LeftBehind.sign(
                    of: process, facts: facts, table: table, context: context, live: liveTags, checkouts: inputs.checkouts,
                    openCheckouts: openCheckouts, words: words)
            else { return nil }
            if isKept(process.identity) {
                var owner = ActivityOwner(place: .elsewhere, rule: 11, reason: "kept running — \(sign.reason)", certainty: sign.certainty)
                owner.kept = true
                owner.leftBehind = sign
                return owner
            }
            return leftBehindOwner(process, sign, rule: 11)
        }

        /// Whether the person kept `identity` or one of its ancestors: what
        /// a kept server started — its workers, a database's backends — is
        /// kept with it, never in a bulk Stop (6.9). Bounded.
        func isKept(_ identity: ActivityProcessID) -> Bool { LeftBehind.isKept(identity, kept: context.kept, table: table) }

        /// The reason of the nearest ancestor left out for itself.
        func rootReason(of identity: ActivityProcessID, _ reasons: [ActivityProcessID: ActivityPaneSet.Exclusion]) -> ActivityPaneSet.Exclusion? {
            var current = identity
            for _ in 0..<512 {
                guard let parent = table.parent(of: current) else { return nil }
                if let reason = reasons[parent.identity], reason != .underExcluded { return reason }
                current = parent.identity
            }
            return nil
        }

        func paneOwner(_ process: ActivityProcess, _ slice: ActivityPaneSlice, inTree: Bool, exclusion: ActivityPaneSet.Exclusion?)
            -> ActivityOwner
        {
            let identity = process.identity
            let words = paneWords(slice)
            var marks: ActivityOwner.Marks = []
            if process.ignoresHangup { marks.insert(.nohup) }
            if process.flags.contains(.sessionLeader), process.terminal == nil { marks.insert(.setsid) }
            switch exclusion {
            case .detachedOnPurpose?:
                var owner = ActivityOwner(place: .pane(slice.tag), rule: 5, reason: "\(name(identity)), detached on purpose, started in \(words)")
                owner.marks = marks.union(.detached)
                owner.tab = slice.tab
                return owner
            case .app?:
                // A helper below the app outside its bundle is the app's.
                var parentApp: String?
                if let parent = table.parent(of: identity), case .app(let app)? = owners[parent.identity]?.place { parentApp = app }
                let app = ActivityAttribution.appName(of: snapshot.facts[identity]?.path) ?? parentApp ?? name(identity)
                var owner = ActivityOwner(place: .app(app), rule: 7, reason: "\(app), started from \(words)")
                owner.marks = marks.union(.fromPane)
                owner.tab = slice.tab
                return owner
            default:
                break
            }
            var owner: ActivityOwner
            if inTree {
                if identity == slice.login {
                    owner = ActivityOwner(place: .pane(slice.tag), rule: 3, reason: "the session of \(words)")
                } else if let agent = slice.agent, identity != agent, table.descends(identity, from: agent) {
                    owner = ActivityOwner(place: .pane(slice.tag), rule: 4, reason: "started by \(slice.agentKind?.name ?? "the agent") in \(words)")
                } else {
                    owner = ActivityOwner(place: .pane(slice.tag), rule: 4, reason: "in \(words)")
                }
            } else {
                owner = ActivityOwner(
                    place: .pane(slice.tag), rule: 9,
                    reason: "carries \(words)’s tag: it left its terminal (nohup, disown)")
                marks.insert(.leftTerminal)
            }
            owner.marks = marks
            owner.tab = slice.tab
            if let agent = slice.agent, identity == agent || table.descends(identity, from: agent) {
                owner.agent = agent
                owner.agentKind = slice.agentKind
            }
            return owner
        }

        // MARK: The rest, in order

        func owner(of process: ActivityProcess, _ facts: ActivityFacts?, _ words: ActivityPathWords) -> ActivityOwner {
            let identity = process.identity
            // 1. Overterm itself.
            if process.pid == context.appPID { return ActivityOwner(place: .overterm, rule: 1, reason: "Overterm itself") }
            // 2. What Overterm started: its registries, its children that
            // aren't a pane's login, what descends from them.
            if let reason = helperReason(process) { return ActivityOwner(place: .overterm, rule: 2, reason: reason) }
            // 6. An engine.
            if let engine = engine(of: process, facts, words) { return engine }
            // 10. Another Overterm, by its run's marker or its own executable.
            if let other = anotherOverterm(process, facts, words) { return other }
            // 11. Left Behind by another sign (6.9).
            if let left = leftBehind(process, facts, words) { return left }
            // 12. An app, by the outermost `.app` on its path.
            if let app = app(of: process, facts, words) { return app }
            // 13. Responsibility (D-31): an XPC service's or a VM's only —
            // anything started in a terminal app has that app as its
            // responsible one, and is the terminal's, not the app's.
            if process.parentPID == 1, words.serviceOrVM, let responsible = facts?.responsible, responsible != identity,
                let owner = owners[responsible] ?? responsibleOwner(responsible),
                let inherited = inheritedByResponsibility(process, from: owner, responsible: responsible)
            {
                return inherited
            }
            // A child inherits its parent's owner unless a rule above matched.
            if let parent = table.parent(of: identity), parent.pid > 1, let owner = owners[parent.identity], let inherited = inherited(from: owner) {
                return inherited
            }
            // 14. macOS.
            if let macOS = macOS(process, facts, words) { return macOS }
            // 15. Another user's.
            if !process.isOwn(by: snapshot.uid) {
                return ActivityOwner(place: .system, rule: 15, reason: ActivityRows.userName(process.effectiveUID))
            }
            // 16. Yours elsewhere.
            return ActivityOwner(place: .elsewhere, rule: 16, reason: elsewhereReason(process))
        }

        func helperReason(_ process: ActivityProcess) -> String? {
            let identity = process.identity
            if let registered = context.registered[identity] { return registered }
            if let forward = context.forwards.first(where: { $0.pid == process.pid && $0.pid > 0 }) {
                let from = forward.tab.map { " from “\(title(of: $0))”" } ?? ""
                return "kubectl port-forward to \(forward.target) Overterm started\(from)"
            }
            if let tunnel = context.tunnels.first(where: { $0.pid == process.pid && $0.pid > 0 }) { return "the database tunnel “\(tunnel.name)”" }
            // The tick's own list of the app's children and below, where it
            // read the panes; else the walk up.
            if !snapshot.helpers.isEmpty || snapshot.demand.readsPanes, !helpers.contains(identity) { return nil }
            guard let root = helperRoot(identity) else { return nil }
            if root != identity, let parentReason = owners[root]?.reason, owners[root]?.place == .overterm { return parentReason }
            return "\(name(root)), started by Overterm"
        }

        /// The app's child above `identity` that isn't a pane's `login`.
        func helperRoot(_ identity: ActivityProcessID) -> ActivityProcessID? {
            var current = identity
            for _ in 0..<512 {
                guard let parent = table.parent(of: current) else { return nil }
                if parent.pid == context.appPID {
                    guard let child = table.process(current), !logins.contains(current), child.shortName != "login" else { return nil }
                    return current
                }
                current = parent.identity
            }
            return nil
        }

        /// Rule 6: a listener on what a running container publishes, a known
        /// holder, or a VM an engine's app is responsible for.
        func engine(of process: ActivityProcess, _ facts: ActivityFacts?, _ words: ActivityPathWords) -> ActivityOwner? {
            let held =
                context.published.isEmpty
                ? []
                : (facts?.sockets?.listeners ?? []).filter { socket in
                    context.published.contains { ActivityAttribution.matches(socket, $0) }
                }
            let known = words.engine
            if !held.isEmpty {
                let containers = Set(context.published.filter { published in held.contains { ActivityAttribution.matches($0, published) } }.map(\.container))
                let engine = known ?? "Docker"
                let count = containers.count
                return ActivityOwner(
                    place: .engine(engine), rule: 6,
                    reason: "holds the published ports of \(count == 1 ? "1 container" : "\(count) containers")")
            }
            if let known { return ActivityOwner(place: .engine(known), rule: 6, reason: "\(known)’s engine") }
            if let responsible = facts?.responsible, let path = snapshot.facts[responsible]?.path, let app = ActivityAttribution.appName(of: path),
                let engine = ActivityAttribution.engineApps[app], words.vmExecutable
            {
                return ActivityOwner(place: .engine(engine), rule: 6, reason: "\(engine)’s Linux VM — containers run inside it")
            }
            return nil
        }

        func anotherOverterm(_ process: ActivityProcess, _ facts: ActivityFacts?, _ words: ActivityPathWords) -> ActivityOwner? {
            if let run = facts?.markers?.run, run != context.run, let named = ActivityAttribution.runIdentity(run), named.pid != context.appPID,
                table.process(named) != nil
            {
                return ActivityOwner(place: .anotherOverterm, rule: 10, reason: "a tab of another Overterm")
            }
            if let app = words.overtermApp { return ActivityOwner(place: .anotherOverterm, rule: 10, reason: "\(app)") }
            return nil
        }

        func app(of process: ActivityProcess, _ facts: ActivityFacts?, _ words: ActivityPathWords) -> ActivityOwner? {
            let app: String
            let underSystem: Bool
            if facts?.path != nil {
                guard let named = words.app else { return nil }
                app = named
                underSystem = words.underSystem
            } else {
                guard let path = inputs.runningApps[process.pid], let named = ActivityAttribution.appName(of: path) else { return nil }
                app = named
                underSystem = path.hasPrefix("/System/")
            }
            // macOS's own apps are rule 14's.
            if underSystem, facts?.codeSigning?.isPlatformBinary == true { return nil }
            return ActivityOwner(place: .app(app), rule: 12)
        }

        /// The owner of a responsible process not placed yet (it started
        /// later than the one it is responsible for — rare): its own rules,
        /// never another responsibility.
        func responsibleOwner(_ identity: ActivityProcessID) -> ActivityOwner? {
            guard let process = table.process(identity) else { return nil }
            if process.pid == context.appPID { return ActivityOwner(place: .overterm, rule: 1) }
            if helperReason(process) != nil { return ActivityOwner(place: .overterm, rule: 2) }
            let facts = snapshot.facts[identity]
            let words = words(process, facts)
            return app(of: process, facts, words) ?? macOS(process, facts, words)
        }

        func inheritedByResponsibility(_ process: ActivityProcess, from owner: ActivityOwner, responsible: ActivityProcessID) -> ActivityOwner? {
            let name = self.name(process.identity)
            let webKit = name.contains("WebKit") || name.contains("WebContent")
            switch owner.place {
            case .overterm:
                return ActivityOwner(place: .overterm, rule: 13, reason: webKit ? "WebKit content of Overterm’s browser column" : "a service of Overterm")
            case .app(let app):
                if let engine = ActivityAttribution.engineApps[app] {
                    return ActivityOwner(place: .engine(engine), rule: 13, reason: "a service of \(engine)")
                }
                return ActivityOwner(place: .app(app), rule: 13, reason: webKit ? "WebKit content of \(app)" : "a service of \(app)")
            case .engine(let engine):
                return ActivityOwner(place: .engine(engine), rule: 13, reason: "a service of \(engine)")
            case .anotherOverterm:
                return ActivityOwner(place: .anotherOverterm, rule: 13, reason: "a service of another Overterm")
            case .pane(let tag):
                var inherited = ActivityOwner(place: .pane(tag), rule: 13, reason: "a service of a process in its tab")
                inherited.tab = owner.tab
                return inherited
            case .macOS:
                // A service of the Finder, the Dock, ControlCenter: macOS's.
                let known = ActivityAttribution.appleAgents[self.name(responsible)] ?? self.name(responsible)
                return ActivityOwner(place: .macOS, rule: 13, reason: "a service of \(known)")
            case .system, .elsewhere, .leftBehind:
                return nil
            }
        }

        /// What a child takes from its parent: an app's, an engine's,
        /// Overterm's, another Overterm's, macOS's — never a user's or a
        /// pane's place by lineage alone (the panes are placed first).
        func inherited(from owner: ActivityOwner) -> ActivityOwner? {
            switch owner.place {
            case .overterm where owner.rule == 1:
                // The app's children that aren't helpers are panes' logins.
                return nil
            case .app, .engine, .overterm, .anotherOverterm, .macOS:
                var child = ActivityOwner(place: owner.place, rule: owner.rule, reason: owner.reason)
                child.tab = owner.marks.contains(.fromPane) ? owner.tab : nil
                if owner.marks.contains(.fromPane) { child.marks = .fromPane }
                return child
            case .leftBehind:
                // What a left-behind process started is left with it.
                var child = owner
                child.marks = []
                child.paneRole = nil
                return child
            case .pane, .system, .elsewhere:
                return nil
            }
        }

        /// Rule 14, narrow on purpose: a platform binary from /System,
        /// /usr/libexec or /usr/sbin with launchd as its parent and no app
        /// responsible — unknown signing never matches — or a known agent.
        func macOS(_ process: ActivityProcess, _ facts: ActivityFacts?, _ words: ActivityPathWords) -> ActivityOwner? {
            guard let facts, facts.codeSigning?.isPlatformBinary == true else { return nil }
            if let known = words.appleAgent { return ActivityOwner(place: .macOS, rule: 14, reason: known) }
            guard words.macOSPath else { return nil }
            guard process.parentPID == 1 || process.pid == 1, facts.responsible == nil else { return nil }
            // Unread is not none: with responsibility off, or the call
            // answering nothing, the user's XPC service or VM may be an
            // app's (D-31).
            if process.isOwn(by: snapshot.uid), !facts.responsibilityRead, process.parentPID == 1, words.serviceOrVM { return nil }
            return ActivityOwner(place: .macOS, rule: 14)
        }

        func elsewhereReason(_ process: ActivityProcess) -> String {
            if let terminal = process.terminal, let device = ActivityAttribution.deviceName(terminal) {
                return "in another terminal (\(device))"
            }
            if process.parentPID == 1 { return "no terminal, parent launchd" }
            if let parent = table.parent(of: process.identity) { return "no terminal, parent \(name(parent.identity))" }
            return "no terminal"
        }

        // MARK: Roles

        /// `owner`'s role, and a pane process's role in its pane.
        mutating func finish(_ owner: inout ActivityOwner, _ process: ActivityProcess, _ facts: ActivityFacts?) {
            let identity = process.identity
            let tcp = facts?.sockets?.listeners.contains { $0.kind == .tcp } ?? false
            // A role is read from its name and argv, an identity's own:
            // read once, kept while it lives (its TCP listening apart).
            let name = facts?.name ?? process.shortName
            if let cached = madeRoles[identity] ?? knownRoles[identity], cached.name == name, cached.command == facts?.command {
                owner.role = tcp ? cached.listening : cached.quiet
            } else {
                let cached = ProcessRole.Cached(
                    name: name, command: facts?.command, quiet: ProcessRole.of(name: name, command: facts?.command, listensTCP: false),
                    listening: ProcessRole.of(name: name, command: facts?.command, listensTCP: true))
                madeRoles[identity] = cached
                owner.role = tcp ? cached.listening : cached.quiet
            }
            if case .pane(let tag) = owner.place, let slice = snapshot.pane(tag) {
                if identity == slice.login {
                    owner.paneRole = .session
                } else if identity == slice.agent {
                    owner.paneRole = .agent
                } else if owner.agent != nil {
                    owner.paneRole = .agentChild
                } else if let login = slice.login, table.parent(of: identity)?.identity == login {
                    owner.paneRole = .shell
                } else if let foreground = process.terminalGroup, foreground == process.group {
                    owner.paneRole = .foreground
                } else {
                    owner.paneRole = .background
                }
            }
        }
    }

    // MARK: Helpers, pure

    /// Rule 13's processes (6.5): an XPC service or a virtual machine —
    /// its path inside an `.xpc` bundle, or a Virtualization executable —
    /// with launchd as its parent.
    static func isServiceOrVM(_ process: ActivityProcess, _ facts: ActivityFacts?) -> Bool {
        guard process.parentPID == 1, let path = facts?.path else { return false }
        if ProcessRole.contains(path, ".xpc/") || ProcessRole.contains(path, "/XPCServices/") { return true }
        let file = fileName(path)
        return file.contains("Virtualization") || file.contains("VirtualMachine")
    }

    /// Whether `socket` is what `published` names: host address, port, protocol.
    static func matches(_ socket: SocketRecord, _ published: ActivityContext.PublishedPort) -> Bool {
        guard Int(socket.localPort) == Int(published.port) else { return false }
        let proto = socket.kind == .tcp ? "tcp" : socket.kind == .udp ? "udp" : ""
        guard proto == published.proto.lowercased() else { return false }
        let wildcard = ["", "0.0.0.0", "::", "*"].contains(published.address)
        guard let local = socket.localAddress else { return wildcard }
        if wildcard { return local.isWildcard }
        return local.description == published.address
    }


    /// The outermost `.app` on `path`, by its name without `.app`: a string
    /// walk bounded by its components, nothing read.
    static func appName(of path: String?) -> String? {
        guard let path, ProcessRole.contains(path, ".app") else { return nil }
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part.hasSuffix(".app") && part.count > 4 {
            return String(part.dropLast(4))
        }
        return nil
    }

    /// A path's last component, without Foundation.
    static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `OVERTERM_RUN`'s `<kind>.<pid>.<start>` (D-15): the run it names.
    static func runIdentity(_ run: String) -> ActivityProcessID? {
        let parts = run.split(separator: ".")
        guard parts.count >= 3, let pid = pid_t(parts[parts.count - 2]), pid > 0, let start = UInt64(parts[parts.count - 1]) else { return nil }
        return ActivityProcessID(pid: pid, start: start)
    }

    private static let devices = NSLock()
    nonisolated(unsafe) private static var deviceNames: [dev_t: String] = [:]

    /// A terminal's name (`ttys003`), kept for the app's life.
    static func deviceName(_ device: dev_t) -> String? {
        if let known = devices.withLock({ deviceNames[device] }) { return known.isEmpty ? nil : known }
        var buffer = [CChar](repeating: 0, count: 64)
        var name = devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil ? String(cString: buffer) : ""
        if name == "??" { name = "" }
        // A device with no name is kept as none: never asked again.
        devices.withLock { deviceNames[device] = name }
        return name.isEmpty ? nil : name
    }
}
