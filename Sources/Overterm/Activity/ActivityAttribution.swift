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

        var table: ProcessTable { snapshot.table }

        init(snapshot: ActivitySnapshot, context: ActivityContext, inputs: Inputs) {
            self.snapshot = snapshot
            self.context = context
            self.inputs = inputs
        }

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
            // Parents first: a child is no older than its parent.
            var pending: [ActivityProcess] = []
            for process in processes where owners[process.identity] == nil { pending.append(process) }
            for process in pending { owners[process.identity] = owner(of: process) }
            assignRoles()
        }

        // MARK: Rules 3–5, 7, 9: the panes

        /// The panes' trees and what carries their tags, through each
        /// pane's set (`ActivityPaneSet`): what it leaves out says rule 5
        /// or 7; the rest is the pane's. Rules 1, 2 and 6 still win.
        mutating func placePanes() {
            let appPID = context.appPID
            let helpers = Set(snapshot.helpers)
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
                        if pass == 1 || reason == .detachedOnPurpose || reason == .app, let engine = engine(of: process) {
                            var owner = engine
                            owner.tab = slice.tab
                            owners[identity] = owner
                            continue
                        }
                        owners[identity] = paneOwner(process, slice, inTree: inTree.contains(identity), exclusion: reason)
                    }
                }
            }
        }

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

        func owner(of process: ActivityProcess) -> ActivityOwner {
            let identity = process.identity
            let facts = snapshot.facts[identity]
            // 1. Overterm itself.
            if process.pid == context.appPID { return ActivityOwner(place: .overterm, rule: 1, reason: "Overterm itself") }
            // 2. What Overterm started: its registries, its children that
            // aren't a pane's login, what descends from them.
            if let reason = helperReason(process) { return ActivityOwner(place: .overterm, rule: 2, reason: reason) }
            // 6. An engine.
            if let engine = engine(of: process) { return engine }
            // 10. Another Overterm, by its run's marker or its own executable.
            if let other = anotherOverterm(process, facts) { return other }
            // 12. An app, by the outermost `.app` on its path.
            if let app = app(of: process, facts) { return app }
            // 13. Responsibility (D-31): an XPC service's or a VM's only —
            // anything started in a terminal app has that app as its
            // responsible one, and is the terminal's, not the app's.
            if ActivityAttribution.isServiceOrVM(process, facts), let responsible = facts?.responsible, responsible != identity,
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
            if let macOS = macOS(process, facts) { return macOS }
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
            guard let root = helperRoot(identity) else { return nil }
            if root != identity, let parentReason = owners[root]?.reason, owners[root]?.place == .overterm { return parentReason }
            return "\(name(root)), started by Overterm"
        }

        /// The app's child above `identity` that isn't a pane's `login`.
        func helperRoot(_ identity: ActivityProcessID) -> ActivityProcessID? {
            let logins = Set(snapshot.panes.compactMap(\.login)).union(context.panes.compactMap(\.login))
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
        func engine(of process: ActivityProcess) -> ActivityOwner? {
            let identity = process.identity
            let facts = snapshot.facts[identity]
            let held = (facts?.sockets?.listeners ?? []).filter { socket in
                context.published.contains { ActivityAttribution.matches(socket, $0) }
            }
            let file = facts?.path.map { ($0 as NSString).lastPathComponent } ?? process.shortName
            let known = ActivityAttribution.engineHolders[file] ?? ActivityAttribution.engineHolders[facts?.name ?? process.shortName]
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
                let engine = ActivityAttribution.engineApps[app], file.contains("Virtualization") || file.contains("VirtualMachine")
            {
                return ActivityOwner(place: .engine(engine), rule: 6, reason: "\(engine)’s Linux VM — containers run inside it")
            }
            return nil
        }

        func anotherOverterm(_ process: ActivityProcess, _ facts: ActivityFacts?) -> ActivityOwner? {
            if let run = facts?.markers?.run, run != context.run, let named = ActivityAttribution.runIdentity(run), named.pid != context.appPID,
                table.process(named) != nil
            {
                return ActivityOwner(place: .anotherOverterm, rule: 10, reason: "a tab of another Overterm")
            }
            if let path = facts?.path, let bundle = ActivityPaneSet.appBundle(of: path), let app = ActivityAttribution.appName(of: bundle),
                app.hasPrefix("Overterm"), (path as NSString).lastPathComponent == "Overterm"
            {
                return ActivityOwner(place: .anotherOverterm, rule: 10, reason: "\(app)")
            }
            return nil
        }

        func app(of process: ActivityProcess, _ facts: ActivityFacts?) -> ActivityOwner? {
            let path = facts?.path ?? inputs.runningApps[process.pid]
            guard let path, let app = ActivityAttribution.appName(of: path) else { return nil }
            // macOS's own apps are rule 14's.
            if path.hasPrefix("/System/"), facts?.codeSigning?.isPlatformBinary == true { return nil }
            return ActivityOwner(place: .app(app), rule: 12)
        }

        /// The owner of a responsible process not placed yet (it started
        /// later than the one it is responsible for — rare): its own rules,
        /// never another responsibility.
        func responsibleOwner(_ identity: ActivityProcessID) -> ActivityOwner? {
            guard let process = table.process(identity) else { return nil }
            if process.pid == context.appPID { return ActivityOwner(place: .overterm, rule: 1) }
            if helperReason(process) != nil { return ActivityOwner(place: .overterm, rule: 2) }
            return app(of: process, snapshot.facts[identity]) ?? macOS(process, snapshot.facts[identity])
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
            case .system, .elsewhere:
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
            case .pane, .system, .elsewhere:
                return nil
            }
        }

        /// Rule 14, narrow on purpose: a platform binary from /System,
        /// /usr/libexec or /usr/sbin with launchd as its parent and no app
        /// responsible — unknown signing never matches — or a known agent.
        func macOS(_ process: ActivityProcess, _ facts: ActivityFacts?) -> ActivityOwner? {
            guard let facts, facts.codeSigning?.isPlatformBinary == true else { return nil }
            let file = facts.path.map { ($0 as NSString).lastPathComponent } ?? facts.name
            if let known = ActivityAttribution.appleAgents[file] ?? ActivityAttribution.appleAgents[facts.name] {
                return ActivityOwner(place: .macOS, rule: 14, reason: known)
            }
            guard let path = facts.path, ["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: { path.hasPrefix($0) }) else { return nil }
            guard process.parentPID == 1 || process.pid == 1, facts.responsible == nil else { return nil }
            // Unread is not none: with responsibility off, or the call
            // answering nothing, the user's XPC service or VM may be an
            // app's (D-31).
            if process.isOwn(by: snapshot.uid), !facts.responsibilityRead, ActivityAttribution.isServiceOrVM(process, facts) { return nil }
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

        /// Each process's role, and each pane process's role in its pane.
        mutating func assignRoles() {
            for (identity, var owner) in owners {
                let facts = snapshot.facts[identity]
                let tcp = facts?.sockets?.listeners.contains { $0.kind == .tcp } ?? false
                owner.role = ProcessRole.of(name: name(identity), command: facts?.command, listensTCP: tcp)
                if case .pane(let tag) = owner.place, let slice = snapshot.pane(tag), let process = table.process(identity) {
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
                owners[identity] = owner
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
        guard let path else { return nil }
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part.hasSuffix(".app") && part.count > 4 {
            return String(part.dropLast(4))
        }
        return nil
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
        if let known = devices.withLock({ deviceNames[device] }) { return known }
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = String(cString: buffer)
        guard !name.isEmpty, name != "??" else { return nil }
        devices.withLock { deviceNames[device] = name }
        return name
    }
}
