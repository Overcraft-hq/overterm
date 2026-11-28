import Foundation

/// Who asks an Activity tool (docs/design/activity/analysis.md, 8.2): the
/// pane the bridge's path names, its tab, and the checkout that tab works
/// in — the scope every answer is cut to, as `TerraformMCP`'s is.
package struct ActivityMCPCaller: Hashable, Sendable {
    /// The pane's tag (`TerminalView.processTag`).
    package let pane: String
    package let tab: UUID
    /// The checkout's folder, standardized as the tabs' facts say it; nil
    /// when the tab works in none — then only its own tab is inside.
    package let checkout: String?

    package init(pane: String, tab: UUID, checkout: String?) {
        self.pane = pane
        self.tab = tab
        self.checkout = checkout
    }
}

/// One call, its arguments read and checked (8.2): what the pure answer is
/// made from, off the main thread.
package enum ActivityMCPRequest: Hashable, Sendable {
    case portHolder(port: Int, proto: String)
    case portList(scope: PortScope, proto: String?)
    case procMine
    case procLeftBehind(all: Bool)
    case procList(sort: Sort, limit: Int)

    package enum PortScope: String, Sendable, CaseIterable {
        case mine, checkout, all
    }

    package enum Sort: String, Sendable, CaseIterable {
        case cpu, memory
    }

    /// `proc_list`'s most rows a list (8.2).
    package static let listLimit = 50

    /// An argument the tool can't take: its words, Overterm's own.
    package struct Invalid: Error, Equatable {
        package let message: String
    }

    /// `name`'s call with `arguments`, each checked: unknown values are
    /// refused, never guessed at.
    package static func parse(_ name: String, _ arguments: [String: Any]) throws -> ActivityMCPRequest {
        func proto(_ fallback: String?) throws -> String? {
            guard let value = arguments["proto"] else { return fallback }
            guard let text = value as? String, ["tcp", "udp"].contains(text.lowercased()) else {
                throw Invalid(message: "\(name): “proto” is tcp or udp.")
            }
            return text.lowercased()
        }
        func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ fallback: T) throws -> T where T.RawValue == String {
            guard let value = arguments[key] else { return fallback }
            guard let text = value as? String, let chosen = T(rawValue: text.lowercased()) else {
                throw Invalid(message: "\(name): “\(key)” is one of \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return chosen
        }
        /// A JSON number, never a boolean: Foundation bridges `true` to 1.
        func integer(_ value: Any?) -> Int? {
            guard let value, !(value is String) else { return nil }
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return value as? Int
        }
        switch name {
        case "port_holder":
            let raw = arguments["port"]
            let port = integer(raw) ?? (raw as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: ": "))) }
            guard let port, (1...65_535).contains(port) else { throw Invalid(message: "port_holder needs “port”, a number from 1 to 65535.") }
            return .portHolder(port: port, proto: try proto("tcp") ?? "tcp")
        case "port_list":
            return .portList(scope: try choice("scope", PortScope.checkout), proto: try proto(nil))
        case "proc_mine":
            return .procMine
        case "proc_left_behind":
            guard let value = arguments["scope"] else { return .procLeftBehind(all: false) }
            guard let text = value as? String, ["checkout", "all"].contains(text.lowercased()) else {
                throw Invalid(message: "proc_left_behind: “scope” is checkout or all.")
            }
            return .procLeftBehind(all: text.lowercased() == "all")
        case "proc_list":
            var limit = 20
            if let value = arguments["limit"] {
                guard let number = integer(value), number >= 1 else { throw Invalid(message: "proc_list: “limit” is a number from 1 to \(listLimit).") }
                limit = min(number, listLimit)
            }
            return .procList(sort: try choice("sort", Sort.cpu), limit: limit)
        default:
            throw Invalid(message: "Unknown tool: \(name).")
        }
    }
}

/// The answers of Activity's agents' reads (8.2, 8.4, 8.5): JSON objects,
/// pure, made off the main thread from one full snapshot's rows.
///
/// **Inside the caller's checkout** (its tab's, or any tab of the same
/// checkout, or what it left): masked commands, ports, URLs, folders
/// relative to the checkout, tab titles masked, CPU and memory. **Outside
/// it:** the checkout's folder name, each process's name, pid, owner class
/// and ports — never its command, folder, tab title or branch; other apps
/// summed by owner class. **Never** an environment value (the census holds
/// none), a remote address (no connection is read for them), a home path
/// (said as `~`).
///
/// Overterm's own words sit in fixed fields (`class`, `advice`, `note`,
/// `state`); what other programs wrote — a process's name, its masked
/// command, a tab's title, a container's name — sits in fields of its own,
/// each through `ActivityText.forAgents`: masked again, one line with every
/// character visible, capped at 120 characters. The instructions call them
/// data, never instructions.
package enum ActivityMCPAnswer {
    /// The facts an answer is made from.
    package struct Scene: Sendable {
        package let caller: ActivityMCPCaller
        package let content: ActivityPageContent
        package let snapshot: ActivitySnapshot
        package let tabs: [UUID: ActivityTabFacts]
        /// The containers running, with their compose projects' folders:
        /// whose checkout a container's port is, by path.
        package var containers: [ActivityContainer] = []
        /// A test run lists only its own tabs' processes (9.9).
        package var isolated = false
        package var home = ActivityText.home

        package init(
            caller: ActivityMCPCaller, content: ActivityPageContent, snapshot: ActivitySnapshot, tabs: [UUID: ActivityTabFacts], containers: [ActivityContainer] = [], isolated: Bool = false,
            home: String = ActivityText.home
        ) {
            self.caller = caller
            self.content = content
            self.snapshot = snapshot
            self.tabs = tabs
            self.containers = containers
            self.isolated = isolated
            self.home = home
        }
    }

    /// The most entries a list gives; the rest counted.
    package static let listCap = 200

    /// `request`'s answer, as JSON text.
    package static func text(_ request: ActivityMCPRequest, _ scene: Scene) -> String {
        json(answer(request, scene))
    }

    package static func answer(_ request: ActivityMCPRequest, _ scene: Scene) -> [String: Any] {
        let reading = Reading(scene)
        switch request {
        case .portHolder(let port, let proto): return reading.portHolder(port, proto: proto)
        case .portList(let scope, let proto): return reading.portList(scope, proto: proto)
        case .procMine: return reading.procMine()
        case .procLeftBehind(let all): return reading.leftBehind(all: all)
        case .procList(let sort, let limit): return reading.procList(sort, limit: limit)
        }
    }

    /// `folder` as `word` where a path starts with it — the folder itself
    /// or below it, `ActivityText.replacingHome`'s boundary: never
    /// `/src/web-api` for `/src/web`.
    package static func replacing(folder: String, with word: String, in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: folder) {
            let after = rest[range.upperBound...]
            let ends = after.first.map { $0 == "/" || $0.isWhitespace || "\"'),;:".contains($0) } ?? true
            out += rest[..<range.lowerBound]
            out += ends ? word : String(rest[range])
            rest = after
        }
        return out + rest
    }

    /// Keys sorted, so an answer reads the same each time.
    package static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One scene read: its rows by identity, the caller's place.
    private struct Reading {
        let scene: Scene
        let caller: ActivityMCPCaller
        let rows: [ActivityProcessID: ActivityProcessRow]
        let listeners: [ActivityPortRow]

        init(_ scene: Scene) {
            self.scene = scene
            caller = scene.caller
            rows = Dictionary(scene.content.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
            listeners = scene.content.listeners.filter { $0.kind == .listener }
        }

        // MARK: Where

        /// The caller's own pane's process.
        func inPane(_ row: ActivityProcessRow?) -> Bool {
            guard let row, case .pane(let tag)? = row.owner?.place else { return false }
            return tag == caller.pane
        }

        /// A tab inside the caller's scope: its own, or one of its checkout.
        func inside(tab: UUID?) -> Bool {
            guard let tab else { return false }
            if tab == caller.tab { return true }
            guard let checkout = caller.checkout else { return false }
            return scene.tabs[tab]?.checkout == checkout
        }

        /// A process inside the caller's scope: in a tab of it, or left
        /// behind by one (its group the caller's checkout).
        func inside(_ row: ActivityProcessRow?) -> Bool {
            guard let row else { return false }
            if inside(tab: row.tab ?? row.owner?.tab) { return true }
            guard row.owner?.place == .leftBehind, let checkout = caller.checkout else { return false }
            return ActivityRows.leftBehindGroup(row, tabs: scene.tabs) == checkout
        }

        /// A port row inside the caller's scope: its holder's, else the tab
        /// it opens in, else — a container with no tab of its checkout open
        /// — its checkout's folder name.
        func inside(_ port: ActivityPortRow) -> Bool {
            if let holder = port.holder, let row = rows[holder], inside(row) { return true }
            if inside(tab: port.tab) { return true }
            if case .container(let name, let project) = port.portOwner, let checkout = caller.checkout, port.tab == nil {
                // By the compose project's folder, never its name alone: two
                // clones called `web` are two checkouts.
                guard let folder = containerFolder(name: name, project: project) else { return false }
                return URL(fileURLWithPath: folder).standardizedFileURL.path == checkout
            }
            return false
        }

        /// A container's compose project folder, as `ActivityPorts` finds it.
        func containerFolder(name: String, project: String?) -> String? {
            scene.containers.first { $0.name == name }?.folder
                ?? project.flatMap { project in scene.containers.first { $0.project == project && $0.folder != nil }?.folder }
        }

        /// The checkout's folder name a process outside belongs to, when one is known.
        func checkoutName(of row: ActivityProcessRow?) -> String? {
            guard let row else { return nil }
            if let tab = row.tab ?? row.owner?.tab, let checkout = scene.tabs[tab]?.checkout { return ActivityRows.folderName(checkout) }
            if row.owner?.place == .leftBehind {
                let group = ActivityRows.leftBehindGroup(row, tabs: scene.tabs)
                if group.hasPrefix("/") { return ActivityRows.folderName(group) }
            }
            return nil
        }

        // MARK: Classes, Overterm's words

        func processClass(_ row: ActivityProcessRow?) -> String {
            guard let row else { return "not readable" }
            guard let owner = row.owner else { return row.isOwn ? "yours, outside Overterm's tabs" : "another user's" }
            switch owner.place {
            case .pane(let tag):
                if tag == caller.pane { return "your pane" }
                if (row.tab ?? owner.tab) == caller.tab { return "another pane of your tab" }
                if inside(row) { return "another tab of your checkout" }
                return checkoutName(of: row) == nil ? "another tab" : "another checkout"
            case .overterm: return "Overterm"
            case .anotherOverterm: return "another Overterm"
            case .engine: return "container engine"
            case .app: return "app"
            case .macOS: return "macOS"
            case .system: return "another user's"
            case .elsewhere: return "yours, outside Overterm's tabs"
            case .leftBehind: return "left behind"
            }
        }

        func portClass(_ port: ActivityPortRow, holder: ActivityProcessRow?) -> String {
            switch port.portOwner {
            case .container: return "container"
            case .forward: return "Kubernetes port-forward"
            case .tunnel: return "database tunnel"
            case .bridge: return "Overterm's MCP bridge"
            case .pane: return processClass(holder)
            case .overterm: return "Overterm"
            case .anotherOverterm: return "another Overterm"
            case .engine: return "container engine (host network)"
            case .known(let known): return known.name
            case .service: return "launchd job"
            case .launchdSocket: return "launchd, for a system job"
            case .app: return "app"
            case .macOS: return "macOS"
            case .system: return "another user's"
            case .elsewhere: return "yours, outside Overterm's tabs"
            case .leftBehind: return "left behind"
            }
        }

        /// A collision in Overterm's words alone: the page's note names the
        /// other holder's tab, which may be outside the caller's checkout.
        func collision(_ kind: PortCollision.Kind) -> String {
            switch kind {
            case .split: "localhost may reach either holder: one listens on IPv4 only, the other on IPv6 only"
            case .wildcardBesideSpecific: "another holder listens on the same port on another address"
            case .sharedPort: "two servers share this port: connections go to either"
            case .knownHolder: "AirPlay Receiver holds this port too — turned off in System Settings ▸ General ▸ AirDrop & Handoff"
            }
        }

        // MARK: Fields

        /// Another program's text, for an agent (8.2, 8.4).
        func field(_ text: String) -> String { ActivityText.forAgents(text, home: scene.home) }

        /// A masked command inside the checkout: its folder said relative —
        /// the folder itself or below it, never a sibling sharing its prefix
        /// (`acme-web-old` for `acme-web`).
        func command(_ text: String) -> String {
            var text = text
            if let checkout = caller.checkout, checkout.count > 1 {
                text = ActivityMCPAnswer.replacing(folder: checkout, with: ".", in: text)
            }
            return ActivityText.forAgents(text, home: scene.home, limit: 240)
        }

        func megabytes(_ bytes: UInt64?) -> Int? { bytes.map { Int(($0 + (1 << 19)) >> 20) } }

        func percent(_ cpu: Double?) -> Double? { cpu.map { ($0 * 10).rounded() / 10 } }

        func since(_ row: ActivityProcessRow) -> String { LeftBehind.clock(row.started) }

        /// A process as an agent reads it: everything inside, its name,
        /// pid, class and ports outside.
        func process(_ row: ActivityProcessRow, usage: Bool = true) -> [String: Any] {
            var object: [String: Any] = ["name": field(row.name), "pid": Int(row.identity.pid), "start": row.identity.start, "class": processClass(row)]
            if !row.listening.isEmpty { object["ports"] = row.listening }
            if !row.boundUDP.isEmpty { object["udp"] = row.boundUDP }
            if usage {
                if let cpu = percent(row.cpu) { object["cpu"] = cpu }
                if let memory = megabytes(row.memory) { object["footprintMB"] = memory }
            }
            if inside(row) {
                object["since"] = since(row)
                if let text = row.command { object["command"] = command(text) }
                if let label = row.label { object["label"] = field(label) }
                if let title = row.tabTitle { object["tab"] = field(title) }
                if let pane = row.pane { object["pane"] = pane }
                if let branch = row.branch { object["branch"] = field(branch) }
                if let role = row.owner?.paneRole { object["role"] = paneRole(role, process: row.owner?.role) }
                if let agent = row.owner?.agentKind, row.owner?.paneRole == .agent { object["agent"] = agent.name }
            } else if let checkout = checkoutName(of: row) {
                object["checkout"] = field(checkout)
            }
            if row.owner?.place == .leftBehind, let owner = row.owner { object["leftBehind"] = leftBehind(row, owner) }
            return object
        }

        func paneRole(_ role: ActivityOwner.PaneRole, process: ProcessRole?) -> String {
            switch role {
            case .session: return "login"
            case .shell: return "shell"
            case .foreground: return "foreground job"
            case .background: return "background job"
            case .agent: return "agent"
            case .agentChild:
                switch process {
                case .mcp?: return "agent's MCP server"
                case .shell?: return "agent's tool shell"
                case .server?: return "agent's server"
                case .build?: return "agent's build"
                default: return "agent's child"
                }
            }
        }

        /// Why it is Left Behind: the page's reason inside — a closed tab's
        /// title is the caller's own checkout's —, the sign's kind outside.
        func leftBehind(_ row: ActivityProcessRow, _ owner: ActivityOwner) -> [String: Any] {
            var object: [String: Any] = ["certainty": owner.certainty == .certain ? "certain" : "probably"]
            if inside(row) {
                if let sign = owner.leftBehind { object["reason"] = ActivityText.forAgents(sign.reason, home: scene.home, limit: 200) }
            } else {
                object["why"] = signKind(owner.leftBehind)
            }
            if row.ignoresHangup { object["ignoresHangup"] = true }
            return object
        }

        func signKind(_ sign: LeftBehindSign?) -> String {
            switch sign {
            case .closedPane?: "a closed tab's"
            case .agentRun?: "an ended agent run's"
            case .earlierRun?: "an earlier Overterm's"
            case .testRun?: "a test run's"
            case .deadLeader?: "its group's leader is gone"
            case nil: "left behind"
            }
        }

        /// A listener's URL for an agent: none for one bound to a single
        /// address, whose URL would carry that address (a LAN's, a VPN's).
        static func url(_ port: ActivityPortRow) -> URL? {
            port.scope == .oneAddress ? nil : port.url
        }

        /// A listener as an agent reads it.
        func port(_ port: ActivityPortRow) -> [String: Any] {
            let holder = port.holder.flatMap { rows[$0] }
            let inside = inside(port)
            var object: [String: Any] = ["port": port.port, "proto": port.proto, "class": portClass(port, holder: holder)]
            object["reach"] =
                switch port.scope {
                case .thisMac: "This Mac"
                case .network: "Network"
                case .oneAddress: "one address"
                }
            var families: [String] = []
            if port.families.contains(.v4) { families.append("v4") }
            if port.families.contains(.v6) { families.append("v6") }
            if !families.isEmpty { object["families"] = families }
            if let url = Reading.url(port) { object["url"] = url.absoluteString }
            if inPane(holder) { object["yours"] = true }
            if let holder {
                object["holder"] = process(holder, usage: false)
            } else if let id = port.holder {
                object["holder"] = ["name": field(port.process), "pid": Int(id.pid)]
            }
            if !port.coHolders.isEmpty { object["coHolders"] = port.coHolders.count }
            if case .container(let name, let project) = port.portOwner {
                var container: [String: Any] = ["name": field(name)]
                if inside, let project { container["project"] = field(project) }
                object["container"] = container
                object["hint"] = "Docker's docker_ tools say more of a container."
            }
            if case .forward(let target) = port.portOwner, inside { object["forwardTo"] = field(target) }
            if case .tunnel(let name) = port.portOwner, inside { object["tunnel"] = field(name) }
            if case .service(let job) = port.portOwner { object["service"] = field(job.title) }
            if !inside, holder == nil, let checkout = port.checkout { object["checkout"] = field(checkout) }
            if let first = port.collisions.first { object["note"] = collision(first) }
            return object
        }

        // MARK: The tools

        func portHolder(_ number: Int, proto: String) -> [String: Any] {
            let held = listeners.filter { $0.port == number && $0.proto == proto }
            var answer: [String: Any] = ["port": number, "proto": proto]
            let own = listeners.filter { $0.proto == "tcp" && inPane($0.holder.flatMap { rows[$0] }) && $0.port != number }
            if !own.isEmpty {
                answer["yourServers"] = own.prefix(20).map { row -> [String: Any] in
                    var server: [String: Any] = ["port": row.port]
                    if let url = Reading.url(row) { server["url"] = url.absoluteString }
                    return server
                }
            }
            guard !held.isEmpty else {
                answer["state"] = "not listed"
                answer["yours"] = false
                let mine = scene.isolated ? "Nothing in this test run's own tabs listens on :\(number)" : "None of your processes listens on :\(number)"
                // What nettop said of every user's (D-25): every "none" true.
                switch scene.content.summary.others {
                case .checked, .unchecked:
                    answer["advice"] = "\(mine), and nettop lists no other user's or macOS's listener on it: it looks free — binding is the test."
                case .blind, .failed:
                    answer["advice"] = "\(mine). \(scene.content.summary.others.sentence) So it may still be taken: binding is the test."
                default:
                    answer["advice"] =
                        scene.isolated
                        ? "\(mine); outside them nothing is read in a test run."
                        : "\(mine). Other users' and macOS's listeners aren't read here, so it may still be taken: binding is the test."
                }
                return answer
            }
            let yours = held.contains { inPane($0.holder.flatMap { rows[$0] }) }
            answer["state"] = "held"
            answer["yours"] = yours
            answer["holders"] = held.map(port)
            if let url = held.compactMap(Reading.url).first { answer["url"] = url.absoluteString }
            if yours {
                answer["advice"] = "Yours: a process of your own pane holds :\(number)."
            } else if held.contains(where: { if case .container = $0.portOwner { true } else { false } }) {
                answer["advice"] = "A container's, not yours. Ask the person before freeing :\(number), or use another port."
            } else if held.allSatisfy(inside) {
                answer["advice"] = "Your checkout's, but another pane's or tab's: not yours. Ask the person before freeing :\(number), or use another port."
            } else {
                answer["advice"] = "Not yours. Ask the person before freeing :\(number), or use another port."
            }
            return answer
        }

        func portList(_ scope: ActivityMCPRequest.PortScope, proto: String?) -> [String: Any] {
            var listed = listeners.filter { proto == nil || $0.proto == proto }
            switch scope {
            case .mine: listed = listed.filter { inPane($0.holder.flatMap { rows[$0] }) }
            case .checkout: listed = listed.filter(inside)
            case .all: break
            }
            listed.sort { ($0.port, $0.proto) < ($1.port, $1.proto) }
            var answer: [String: Any] = ["scope": scope.rawValue, "count": listed.count, "ports": listed.prefix(listCap).map(port)]
            if listed.count > listCap { answer["more"] = listed.count - listCap }
            if scope == .all, !scene.isolated {
                answer["note"] = "Other users' and macOS's listeners aren't read here."
            } else if scene.isolated {
                answer["note"] = "A test run lists only its own tabs' processes."
            }
            return answer
        }

        func procMine() -> [String: Any] {
            var answer: [String: Any] = [:]
            let mine = scene.content.processes.filter(inPane)
            if let slice = scene.snapshot.pane(caller.pane), let agent = slice.agent, let row = rows[agent] {
                var you = process(row)
                // Only what the census read: an unread kind is never guessed.
                if let kind = slice.agentKind { you["agent"] = kind.name }
                // The agent's subtree over the ring's 15 minutes (6.11, 8.5).
                if let span = scene.snapshot.history.spanCPU(.agent(agent)), let mean = percent(span.mean) { you["cpuMean15m"] = mean }
                answer["you"] = you
            }
            var children: [String: Int] = [:]
            for row in mine where row.owner?.paneRole == .agentChild {
                let key =
                    switch row.owner?.role ?? .other {
                    case .mcp: "mcp"
                    case .shell: "shells"
                    case .server: "servers"
                    case .build: "builds"
                    case .other: "others"
                    }
                children[key, default: 0] += 1
            }
            if !children.isEmpty { answer["children"] = children }
            let sorted = mine.sorted { ($0.cpu ?? -1, $0.identity.pid) > ($1.cpu ?? -1, $1.identity.pid) }
            answer["processes"] = sorted.prefix(ActivityMCPRequest.listLimit).map { process($0) }
            if sorted.count > ActivityMCPRequest.listLimit { answer["more"] = sorted.count - ActivityMCPRequest.listLimit }
            let servers = listeners.filter { inPane($0.holder.flatMap { rows[$0] }) }.sorted { $0.port < $1.port }
            answer["servers"] = servers.map { server in
                var object = port(server)
                if object["note"] == nil, let holder = server.holder.flatMap({ rows[$0] }),
                    let note = ActivityMovedServers.note(holder.chips, port: server.port)
                {
                    object["note"] = field(note)
                }
                return object
            }
            let left = leftBehindRows().filter(inside)
            if !left.isEmpty { answer["leftEarlier"] = left.prefix(ActivityMCPRequest.listLimit).map { process($0) } }
            if servers.isEmpty {
                answer["advice"] = "Nothing in your pane listens. Before starting a server, ask port_holder about its port: another worktree's server may hold it."
            }
            if scene.snapshot.pane(caller.pane) == nil { answer["note"] = "Your pane's processes weren't read in this census yet." }
            return answer
        }

        func leftBehindRows() -> [ActivityProcessRow] {
            scene.content.processes.filter { $0.owner?.place == .leftBehind }
                .sorted { ($0.identity.start, $0.identity.pid) < ($1.identity.start, $1.identity.pid) }
        }

        func leftBehind(all: Bool) -> [String: Any] {
            let left = leftBehindRows()
            let mine = left.filter(inside)
            var answer: [String: Any] = ["scope": all ? "all" : "checkout", "checkout": mine.prefix(listCap).map { process($0) }]
            if all {
                let others = left.filter { !inside($0) }
                answer["elsewhere"] = others.prefix(listCap).map { process($0) }
                if others.count > listCap { answer["more"] = others.count - listCap }
            }
            answer["note"] = "Nothing here is stopped on its own; the person stops what was left, from Activity's Left Behind (its section 3)."
            return answer
        }

        func procList(_ sort: ActivityMCPRequest.Sort, limit: Int) -> [String: Any] {
            func key(_ row: ActivityProcessRow) -> Double {
                switch sort {
                case .cpu: row.cpu ?? -1
                case .memory: row.memory.map(Double.init) ?? -1
                }
            }
            let ranked = scene.content.processes.sorted { (key($0), $0.identity.pid) > (key($1), $1.identity.pid) }
            var mine: [ActivityProcessRow] = []
            var checkouts: [ActivityProcessRow] = []
            var totals: [String: (count: Int, cpu: Double, memory: UInt64)] = [:]
            for row in ranked {
                if inside(row) {
                    mine.append(row)
                } else if checkoutName(of: row) != nil {
                    checkouts.append(row)
                } else {
                    let name = processClass(row)
                    var total = totals[name] ?? (0, 0, 0)
                    total.count += 1
                    total.cpu += row.cpu ?? 0
                    total.memory += row.memory ?? 0
                    totals[name] = total
                }
            }
            var answer: [String: Any] = ["sort": sort.rawValue]
            answer["checkout"] = mine.prefix(limit).map { process($0) }
            answer["otherCheckouts"] = checkouts.prefix(limit).map { process($0) }
            answer["elsewhere"] = totals.sorted { $0.key < $1.key }.map { name, total -> [String: Any] in
                ["class": name, "count": total.count, "cpu": (total.cpu * 10).rounded() / 10, "footprintMB": megabytes(total.memory) ?? 0]
            }
            if mine.count > limit { answer["moreInCheckout"] = mine.count - limit }
            if checkouts.count > limit { answer["moreInOtherCheckouts"] = checkouts.count - limit }
            if scene.isolated { answer["note"] = "A test run lists only its own tabs' processes." }
            return answer
        }
    }
}
