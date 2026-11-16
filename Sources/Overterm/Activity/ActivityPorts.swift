import Darwin
import Foundation

/// Who holds a listening port (docs/design/activity/analysis.md, 6.8,
/// Owners), the first of these that matches, in order: a container whose
/// published host address, port and protocol it is; a Kubernetes forward,
/// by kubectl's pid; a database tunnel, by ssh's pid and port; Overterm's
/// MCP bridge; a pane's process; then a known holder, a launchd job, an
/// app, macOS, another user's or the user's elsewhere.
enum ActivityPortOwner: Hashable, Sendable {
    case container(name: String, project: String?)
    case forward(target: String)
    case tunnel(name: String)
    case bridge
    case pane
    case overterm
    case anotherOverterm
    /// An engine's own listener on no published port: host networking.
    case engine(String)
    case known(KnownHolders.Holder)
    case service(LaunchdJobs.Job)
    case app(String)
    case macOS
    case system(user: String)
    case elsewhere

    /// The filter's `owner:` word (6.6).
    var word: String {
        switch self {
        case .container, .engine: "container"
        case .forward: "forward"
        case .tunnel: "tunnel"
        case .bridge, .overterm, .anotherOverterm: "overterm"
        case .pane: "tab"
        case .known(let holder): holder.word
        case .service: "service"
        case .app: "app"
        case .macOS: "macos"
        case .system: "system"
        case .elsewhere: "elsewhere"
        }
    }

    /// An app's, macOS's or a known holder's: what folds into "N ephemeral
    /// listeners of your apps" (6.8). A server the user started elsewhere,
    /// a launchd job and every named source never fold.
    var foldsWhenEphemeral: Bool {
        switch self {
        case .app, .macOS, .known: true
        default: false
        }
    }
}

/// A row of Listening (6.8): one holder's sockets on one protocol and port,
/// its v4 and v6 together — with the processes that share the very socket
/// (a pre-fork server's workers, a child that inherited it) as "+N
/// holders" —; a container's published port nobody in scope is seen
/// holding; a connection, paired by the 4-tuple when both ends are the
/// user's; or the fold of apps' ephemeral listeners.
struct ActivityPortRow: ResourceTableRow, Sendable {
    enum Kind: Hashable, Sendable {
        case listener
        case connection
        /// "N ephemeral listeners of your apps" (6.8).
        case folded
    }

    let id: String
    var kind = Kind.listener
    let port: Int
    let proto: String
    /// The bound address as lsof prints it (`*`, `127.0.0.1`, `[::1]`).
    let address: String
    let families: SocketRecord.Families
    let scope: ListeningPort.Scope
    var process: String
    let holder: ActivityProcessID?
    /// The tab `o` opens it in (6.8, Open): its holder's, a container's
    /// checkout's, a forward's.
    var tab: UUID?
    var tabTitle: String?
    /// Where a browser reaches it; nil when there is none to open.
    var url: URL?
    /// Who holds it, in the filter's `owner:` words (6.6).
    var owner = "elsewhere"
    var portOwner = ActivityPortOwner.elsewhere
    /// The Owner column's words.
    var ownerText = ""
    /// The Where column's: tab · checkout · branch · agent.
    var whereText = ""
    /// Others holding the very socket (`soi_so`).
    var coHolders: [ActivityProcessID] = []
    /// The holder's start (a socket has no time of its own): Since.
    var since: Date?
    var sinceText = ""
    /// The user's established connections to it, paired by the 4-tuple.
    var clients = 0
    /// Accepted by the kernel and not yet by the process, against its limit.
    var backlog = 0
    var backlogLimit = 0
    /// A loopback listener a tunnel client is connected to: "cloudflared
    /// (pid 4242)" — not This Mac only.
    var forwardedBy: String?
    /// A collision with another holder, or what a known holder is (6.8).
    var note: String?
    var collisions: [PortCollision.Kind] = []
    /// Its bound addresses, and its sockets' kernel handles: what
    /// collisions are found by.
    var bound: [ActivityAddress?] = []
    var sockets: Set<UInt64> = []
    /// In the ephemeral range and nobody's in particular: folded (6.8).
    var ephemeral = false
    /// A connection's count, a fold's listeners.
    var count = 1
    /// A fold's state.
    var folded = false
    /// The checkout it belongs to, by its folder's name.
    var checkout: String?

    var height: CGFloat { 24 }

    /// A fold spans the columns.
    var spansColumns: Bool { kind == .folded }

    var backlogFull: Bool { backlogLimit > 0 && backlog >= backlogLimit }

    /// "This Mac" or "Network" (6.1), the one address it is bound to, or
    /// who forwards it.
    var reach: String {
        if let forwardedBy { return "forwarded by \(forwardedBy)" }
        switch scope {
        case .thisMac: return "This Mac"
        case .network: return "Network"
        case .oneAddress: return kind == .connection ? "Network" : "Network · \(address)"
        }
    }

    var familyWords: String {
        switch (families.contains(.v4), families.contains(.v6)) {
        case (true, true): "v4 + v6"
        case (true, false): "v4"
        case (false, true): "v6"
        default: ""
        }
    }

    /// "node · 4242", "+2 holders" when a forked server shares the socket.
    var processText: String {
        guard kind == .listener else { return process }
        var text = process
        if !coHolders.isEmpty { text += " +\(coHolders.count) holder\(coHolders.count == 1 ? "" : "s")" }
        return text
    }

    var accessibilityLabel: String {
        if kind == .folded { return process + (folded ? ", folded" : "") }
        var words = [kind == .connection ? "connection to :\(port)" : ":\(port) \(proto)", processText]
        if let holder { words.append("pid \(holder.pid)") }
        if !ownerText.isEmpty, portOwner != .pane { words.append(ownerText) }
        words.append(reach)
        if let tabTitle { words.append("in “\(tabTitle)”") }
        if let note { words.append(note) }
        return words.joined(separator: ", ")
    }
}

/// Listening's rows from one snapshot (6.8): pure, off the main thread.
enum ActivityPorts {
    /// What the rows are made with besides the snapshot.
    struct Inputs: Sendable {
        var context = ActivityContext()
        /// Tabs' facts, titles masked.
        var tabs: [UUID: ActivityTabFacts] = [:]
        /// The running containers, with their compose project's folder.
        var containers: [ActivityContainer] = []
        var launchAgents: [LaunchdJobs.Agent] = []
        /// `net.inet.ip.portrange.first`.
        var ephemeralFirst = 49_152
        /// The user's established connections too (the header's toggle,
        /// `c`, or `state:established`).
        var connections = false
        /// The fold of apps' ephemeral listeners: folded unless false.
        var folds: [String: Bool] = [:]
        /// A filter shows its matches, never folded away.
        var unfold = false
        var scope = ActivityScope.mac
    }

    /// What they make: Listening's rows, listeners first, and every
    /// listener (the detail's, the switcher's) whatever the fold says.
    struct Made: Sendable {
        var rows: [ActivityPortRow] = []
        var listeners: [ActivityPortRow] = []
        /// Connection lines past the cap: said, never listed.
        var droppedConnections = 0
    }

    static let ephemeralFold = "ports:ephemeral"
    /// Connections listed at most (6.8).
    static let connectionCap = 500

    /// Tunnel clients by executable: a loopback listener one is connected
    /// to reaches past this Mac (6.8, Scope).
    static let tunnelClients: Set<String> = ["ngrok", "cloudflared", "tailscale", "tailscaled", "bore", "frpc", "localtunnel", "lt"]

    static func make(of rows: [ActivityProcessRow], in snapshot: ActivitySnapshot, inputs: Inputs) -> Made {
        let byIdentity = Dictionary(rows.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let own = rows.filter(\.isOwn).sorted { ($0.identity.start, $0.identity.pid) < ($1.identity.start, $1.identity.pid) }
        var listeners = holders(own, in: snapshot, published: inputs.context.published)
        for index in listeners.indices { attribute(&listeners[index], process: byIdentity[listeners[index].holder!], snapshot: snapshot, inputs: inputs) }
        listeners += unseenContainers(listeners, in: snapshot, inputs: inputs)
        let connections = pairs(own, in: snapshot, byIdentity: byIdentity, inputs: inputs)
        count(&listeners, clients: connections.clients, tunnels: connections.tunnels)
        let found = PortCollisions.find(listeners)
        for index in listeners.indices {
            let id = listeners[index].id
            if let mine = found[id], let first = mine.first {
                listeners[index].collisions = mine.map(\.kind)
                listeners[index].note = first.sentence
            } else if case .known(let holder) = listeners[index].portOwner {
                listeners[index].note = holder.note
            }
            let row = listeners[index]
            listeners[index].ephemeral = row.port >= inputs.ephemeralFirst && row.tab == nil && row.portOwner.foldsWhenEphemeral
        }
        var made = Made()
        made.listeners = listeners
        let folded = inputs.folds[ephemeralFold] ?? true
        let ephemeral = listeners.filter(\.ephemeral)
        made.rows = inputs.unfold || ephemeral.isEmpty || !folded ? listeners : listeners.filter { !$0.ephemeral }
        if inputs.connections {
            made.rows += connections.rows
            made.droppedConnections = connections.dropped
        }
        if !ephemeral.isEmpty, !inputs.unfold {
            var fold = ActivityPortRow(
                id: ephemeralFold, kind: .folded, port: inputs.ephemeralFirst, proto: "", address: "", families: [], scope: .thisMac,
                process: "\(ephemeral.count) ephemeral listener\(ephemeral.count == 1 ? "" : "s") of your apps", holder: nil)
            fold.count = ephemeral.count
            fold.folded = folded
            made.rows.append(fold)
        }
        return made
    }

    // MARK: Listeners

    /// One row per holder, protocol and port, its v4 and v6 together; a
    /// process holding only sockets an older holder holds too — inherited,
    /// or a pre-fork server's worker — is that row's co-holder (6.8). An
    /// engine's sockets on one number for two containers (published on
    /// two host addresses) are a row each.
    static func holders(_ own: [ActivityProcessRow], in snapshot: ActivitySnapshot, published: [ActivityContext.PublishedPort] = []) -> [ActivityPortRow] {
        var result: [ActivityPortRow] = []
        var byKey: [String: [Int]] = [:]
        for process in own {
            guard let facts = snapshot.facts[process.identity], let sockets = facts.sockets else { continue }
            var order: [String] = []
            var groups: [String: [SocketRecord]] = [:]
            for record in sockets.records where record.isListener {
                var key = "\(record.kind == .udp ? "udp" : "tcp"):\(record.localPort)"
                if let container = published.first(where: { ActivityAttribution.matches(record, $0) }) {
                    key += "@\(container.container)"
                }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(record)
            }
            for key in order {
                guard let records = groups[key], let port = ListeningPorts.port(records, holder: process.identity, name: process.name) else { continue }
                let handles = Set(records.map(\.socket))
                if let shared = byKey[key]?.first(where: { !handles.isEmpty && handles.isSubset(of: result[$0].sockets) }) {
                    result[shared].coHolders.append(process.identity)
                    continue
                }
                // A container's part of the engine's sockets on this number.
                let suffix = key.firstIndex(of: "@").map { String(key[$0...]) } ?? ""
                var row = ActivityPortRow(
                    id: port.id + suffix, port: port.port, proto: port.proto, address: port.address, families: port.families, scope: port.scope,
                    process: process.name, holder: process.identity, url: port.proto == "udp" ? nil : port.url)
                row.bound = records.map(\.localAddress)
                row.sockets = handles
                row.since = process.started
                row.sinceText = process.startedText
                if let listening = records.first(where: \.isListening) {
                    row.backlog = listening.backlog
                    row.backlogLimit = listening.backlogLimit
                }
                byKey[key, default: []].append(result.count)
                result.append(row)
            }
        }
        return result
    }

    /// `row`'s owner, by 6.8's order, and the words its columns say.
    static func attribute(_ row: inout ActivityPortRow, process: ActivityProcessRow?, snapshot: ActivitySnapshot, inputs: Inputs) {
        let context = inputs.context
        guard let holder = row.holder else { return }
        let records =
            snapshot.facts[holder]?.sockets?.records.filter { $0.isListener && Int($0.localPort) == row.port && (row.sockets.isEmpty || row.sockets.contains($0.socket)) }
            ?? []
        row.tab = process?.tab
        row.tabTitle = process?.tabTitle
        row.checkout = process?.checkout
        row.whereText = process.map(whereText) ?? ""
        // 1. A container, by its published host address, port and protocol.
        if let published = context.published.first(where: { published in records.contains { ActivityAttribution.matches($0, published) } }) {
            container(&row, published, inputs: inputs)
            row.ownerText += " · via \(row.process)"
            return
        }
        // 3. A Kubernetes forward, by kubectl's pid.
        if let forward = context.forwards.first(where: { $0.pid == holder.pid && $0.pid > 0 && Int($0.port) == row.port }) {
            row.portOwner = .forward(target: forward.target)
            row.ownerText = "port-forward → \(forward.target)"
            if let tab = forward.tab {
                row.tab = tab
                row.tabTitle = inputs.tabs[tab]?.title
                row.whereText = row.tabTitle.map { "from “\($0)”" } ?? ""
            }
            if forward.https, let url = row.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.scheme = "https"
                row.url = parts.url ?? url
            }
            row.owner = row.portOwner.word
            return
        }
        // 4. A database tunnel, by ssh's pid and its port.
        if let tunnel = context.tunnels.first(where: { $0.pid == holder.pid && $0.pid > 0 && Int($0.port) == row.port }) {
            row.portOwner = .tunnel(name: tunnel.name)
            row.ownerText = "the database tunnel “\(tunnel.name)”"
            row.url = nil
            row.owner = row.portOwner.word
            return
        }
        // 5. Overterm's bridge.
        if holder.pid == context.appPID, let bridge = context.bridgePort, Int(bridge) == row.port {
            row.portOwner = .bridge
            row.ownerText = "Overterm — the agents' MCP bridge"
            row.url = nil
            row.owner = row.portOwner.word
            return
        }
        let owner = process?.owner
        let file = process?.path.map(ActivityAttribution.fileName) ?? row.process
        let known = KnownHolders.holder(file, port: row.port) ?? KnownHolders.holder(row.process, port: row.port)
        switch owner?.place {
        case .pane?:
            // 6. A pane's process.
            row.portOwner = .pane
            row.ownerText = owner?.agentKind.map { "\($0.name) in “\(row.tabTitle ?? "")”" } ?? "“\(row.tabTitle ?? "")”"
        case .overterm?:
            row.portOwner = .overterm
            row.ownerText = owner?.reason ?? "Overterm"
        case .anotherOverterm?:
            row.portOwner = .anotherOverterm
            row.ownerText = owner?.reason ?? "another Overterm"
        case .engine(let engine)?:
            row.portOwner = .engine(engine)
            row.ownerText = "\(engine)’s engine — host network"
        default:
            let facts = snapshot.facts[holder]
            if let known {
                row.portOwner = .known(known)
                row.ownerText = known.name
            } else if let job = LaunchdJobs.job(service: facts?.markers?.service)
                ?? LaunchdJobs.job(path: facts?.path, parent: process?.parentPID ?? 0, agents: inputs.launchAgents)
            {
                row.portOwner = .service(job)
                row.ownerText = job.title
            } else {
                switch owner?.place {
                case .app(let app)?:
                    row.portOwner = .app(app)
                    row.ownerText = app
                case .macOS?:
                    row.portOwner = .macOS
                    row.ownerText = "macOS"
                case .system?:
                    row.portOwner = .system(user: process?.user ?? "")
                    row.ownerText = process?.user ?? "another user"
                default:
                    row.portOwner = .elsewhere
                    row.ownerText = "yours elsewhere"
                }
            }
        }
        row.owner = row.portOwner.word
    }

    /// `row` as `published`'s container: its owner, its checkout's tab.
    static func container(_ row: inout ActivityPortRow, _ published: ActivityContext.PublishedPort, inputs: Inputs) {
        row.portOwner = .container(name: published.container, project: published.project)
        row.ownerText = "container \(published.container)" + (published.project.map { " · \($0)" } ?? "")
        row.owner = row.portOwner.word
        if let folder = folder(of: published, inputs.containers) {
            row.checkout = ActivityRows.folderName(folder)
            if let tab = tab(of: folder, inputs.tabs) {
                row.tab = tab
                row.tabTitle = inputs.tabs[tab]?.title
            }
            row.whereText = row.checkout ?? ""
        }
        if published.proto.lowercased() != "tcp" {
            row.url = nil
        } else if row.holder == nil {
            // Its own row: by the families it is published on (6.8's
            // table) — a holder's row keeps the URL its bound sockets gave.
            row.url = url(publishedOn: published.address, port: published.port)
        }
    }

    /// The URL of a port published on `address` (Docker's `HostIp`; empty
    /// for every address, both families): `localhost` only where both
    /// families are published, `127.0.0.1` for `0.0.0.0`, `[::1]` for
    /// `::`, else that address — none for a link-local one. Pure.
    static func url(publishedOn address: String, port: UInt16) -> URL? {
        let host: String
        switch address {
        case "", "*": host = "localhost"
        case "0.0.0.0": host = "127.0.0.1"
        case "::": host = "[::1]"
        default:
            guard let parsed = ActivityAddress(text: address), !parsed.isLinkLocal else { return nil }
            if case .v6 = parsed { host = "[\(parsed.description)]" } else { host = parsed.description }
        }
        return URL(string: "http://\(host):\(port)")
    }

    /// What a port published on `address` is bound to, as a holder's
    /// sockets would say it: its families and addresses — a wildcard of
    /// each family for every address. Pure.
    static func bound(publishedOn address: String) -> (families: SocketRecord.Families, bound: [ActivityAddress?]) {
        switch address {
        case "", "*": return ([.v4, .v6], [.v4(0), .v6(0, 0)])
        case "0.0.0.0": return (.v4, [.v4(0)])
        case "::": return (.v6, [.v6(0, 0)])
        default:
            guard let parsed = ActivityAddress(text: address) else { return ([], []) }
            if case .v6 = parsed { return (.v6, [parsed]) }
            return (.v4, [parsed])
        }
    }

    /// The published ports no listener in scope is seen holding — the
    /// engine's holder isn't the user's, or is outside the scope —, as the
    /// container's own rows: at the Mac and wider than a tab, its checkout
    /// in scope (6.5: "a checkout's stack … at the checkout's scope and
    /// wider").
    static func unseenContainers(_ listeners: [ActivityPortRow], in snapshot: ActivitySnapshot, inputs: Inputs) -> [ActivityPortRow] {
        var rows: [ActivityPortRow] = []
        var seen = Set<String>()
        // A container published on both families' wildcards is published
        // on every address: one row, as an empty `HostIp` would be.
        let wildcards = Dictionary(
            grouping: inputs.context.published.filter { ["0.0.0.0", "::"].contains($0.address) },
            by: { "\($0.container):\($0.proto.lowercased()):\($0.port)" }
        ).mapValues { Set($0.map(\.address)) }
        for original in inputs.context.published {
            let proto = original.proto.lowercased()
            var published = original
            if wildcards["\(original.container):\(proto):\(original.port)"]?.count == 2 {
                published = ActivityContext.PublishedPort(
                    container: original.container, project: original.project, address: "", port: original.port, proto: original.proto)
            }
            let held = listeners.contains { row in
                row.proto == proto && row.port == Int(published.port) && row.portOwner == .container(name: published.container, project: published.project)
            }
            guard !held else { continue }
            let folder = folder(of: published, inputs.containers)
            switch inputs.scope {
            case .mac: break
            case .tab: continue
            case .allTabs: guard let folder, inputs.tabs.values.contains(where: { $0.checkout == folder }) else { continue }
            case .checkout(let path): guard folder == path else { continue }
            }
            let id = "container:\(published.container):\(proto):\(published.address):\(published.port)"
            guard seen.insert(id).inserted else { continue }
            let (_, scope) = ListeningPorts.published(hostIP: published.address.isEmpty ? nil : published.address)
            let address = ["", "0.0.0.0", "::"].contains(published.address) ? "*" : published.address
            let (families, bound) = bound(publishedOn: published.address)
            var row = ActivityPortRow(
                id: id, port: Int(published.port), proto: proto, address: address, families: families, scope: scope, process: published.container,
                holder: nil)
            // What collisions are found by: a checkout's server on
            // 127.0.0.1 beside its stack's container on 0.0.0.0.
            row.bound = bound
            container(&row, published, inputs: inputs)
            row.ownerText += " · via the engine"
            rows.append(row)
        }
        return rows
    }

    static func folder(of published: ActivityContext.PublishedPort, _ containers: [ActivityContainer]) -> String? {
        containers.first { $0.name == published.container }?.folder
            ?? published.project.flatMap { project in
                containers.first { $0.project == project && $0.folder != nil }?.folder
            }
    }

    /// The first tab, in the strips' order, showing `folder`.
    static func tab(of folder: String, _ tabs: [UUID: ActivityTabFacts]) -> UUID? {
        let path = URL(fileURLWithPath: folder).standardizedFileURL.path
        return tabs.values.filter { $0.checkout == path || $0.checkout == folder }.min { $0.order < $1.order }?.id
    }

    /// The Where column's words: tab · checkout · branch · agent.
    static func whereText(_ process: ActivityProcessRow) -> String {
        guard let title = process.tabTitle else { return process.whereText }
        var words = ["“\(title)”"]
        if let checkout = process.checkout { words.append(checkout) }
        if let branch = process.branch { words.append(branch) }
        if let agent = process.owner?.agentKind { words.append(agent.name) }
        return words.joined(separator: " · ")
    }

    // MARK: Connections

    /// One end of an established TCP connection.
    struct End: Sendable {
        let holder: ActivityProcessID
        let record: SocketRecord
    }

    /// The user's established connections (6.8): two of the user's local
    /// ends paired when one's (local, remote) is the other's (remote,
    /// local) — v4-mapped addresses already taken as v4 — one line each,
    /// the server the end whose holder listens on its port; the rest a
    /// line per process and remote end, counted. One socket held by two
    /// processes (inherited, a fork after connect) is one end, its oldest
    /// holder's. At most 500 lines, the rest counted in `dropped`; Clients
    /// and the tunnels a listener is forwarded by come from every pair.
    /// Remote addresses stay on the page: never in a row's id.
    static func pairs(
        _ own: [ActivityProcessRow], in snapshot: ActivitySnapshot, byIdentity: [ActivityProcessID: ActivityProcessRow], inputs: Inputs
    ) -> (rows: [ActivityPortRow], clients: [String: Int], tunnels: [String: String], dropped: Int) {
        struct Endpoint: Hashable {
            let local: ActivityAddress?
            let localPort: UInt16
            let remote: ActivityAddress?
            let remotePort: UInt16
        }
        var ends: [End] = []
        var listening: Set<String> = []
        var held = Set<UInt64>()
        // `own` is oldest first: a shared socket is its oldest holder's end.
        for process in own {
            guard let records = snapshot.facts[process.identity]?.sockets?.records else { continue }
            for record in records {
                if record.isListening { listening.insert("\(process.identity.id):\(record.localPort)") }
                guard record.kind == .tcp, record.state == .established else { continue }
                if record.socket != 0, !held.insert(record.socket).inserted { continue }
                ends.append(End(holder: process.identity, record: record))
            }
        }
        var byEndpoint: [Endpoint: Int] = [:]
        for (index, end) in ends.enumerated() {
            byEndpoint[Endpoint(local: end.record.localAddress, localPort: end.record.localPort, remote: end.record.remoteAddress, remotePort: end.record.remotePort)] =
                index
        }
        func isServer(_ end: End) -> Bool { listening.contains("\(end.holder.id):\(end.record.localPort)") }
        var lines: [String: ActivityPortRow] = [:]
        var order: [String] = []
        var clients: [String: Int] = [:]
        var tunnels: [String: String] = [:]
        var dropped: Set<String> = []
        var used = Set<Int>()
        func add(_ key: String, _ make: () -> ActivityPortRow) {
            if lines[key] != nil {
                lines[key]?.count += 1
            } else if order.count < connectionCap {
                lines[key] = make()
                order.append(key)
            } else {
                dropped.insert(key)
            }
        }
        for (index, end) in ends.enumerated() where !used.contains(index) {
            let peerKey = Endpoint(local: end.record.remoteAddress, localPort: end.record.remotePort, remote: end.record.localAddress, remotePort: end.record.localPort)
            let name = byIdentity[end.holder]?.name ?? "?"
            if let peerIndex = byEndpoint[peerKey], peerIndex != index, !used.contains(peerIndex) {
                used.insert(index)
                used.insert(peerIndex)
                let peer = ends[peerIndex]
                // The server is the end listening on its port.
                let (client, server) = isServer(end) && !isServer(peer) ? (peer, end) : (end, peer)
                let serverName = byIdentity[server.holder]?.name ?? "?"
                let clientName = byIdentity[client.holder]?.name ?? "?"
                let port = Int(server.record.localPort)
                clients["\(server.holder.id):\(port)", default: 0] += 1
                if let tunnel = tunnelClient(client.holder, byIdentity: byIdentity) { tunnels["\(server.holder.id):\(port)"] = tunnel }
                let key = "conn:\(client.holder.id)>\(server.holder.id):\(port)"
                add(key) {
                    var row = ActivityPortRow(
                        id: key, kind: .connection, port: port, proto: "tcp", address: ListeningPorts.address(of: server.record),
                        families: server.record.families, scope: .thisMac, process: "\(clientName) → \(serverName) :\(port)", holder: client.holder)
                    let serverRow = byIdentity[server.holder]
                    row.tab = byIdentity[client.holder]?.tab ?? serverRow?.tab
                    row.tabTitle = byIdentity[client.holder]?.tabTitle ?? serverRow?.tabTitle
                    row.whereText = serverRow.map(whereText) ?? ""
                    row.ownerText = serverRow?.tabTitle.map { "\(serverName) in “\($0)”" } ?? serverName
                    row.owner = serverRow?.tab != nil ? "tab" : "elsewhere"
                    return row
                }
                continue
            }
            // Unpaired: a process and the end it reaches, counted.
            let remote = end.record.remoteAddress
            var hasher = Hasher()
            hasher.combine(remote)
            hasher.combine(end.record.remotePort)
            let key = "conn:\(end.holder.id)>\(UInt(bitPattern: hasher.finalize()))"
            add(key) {
                let words =
                    remote.map { address -> String in
                        if case .v6 = address { return "[\(address.description)]" }
                        return address.description
                    } ?? "?"
                var row = ActivityPortRow(
                    id: key, kind: .connection, port: Int(end.record.remotePort), proto: "tcp", address: words, families: end.record.families,
                    scope: remote?.isLoopback == true ? .thisMac : .oneAddress, process: "\(name) → \(words):\(end.record.remotePort)", holder: end.holder)
                let process = byIdentity[end.holder]
                row.tab = process?.tab
                row.tabTitle = process?.tabTitle
                row.whereText = process.map(whereText) ?? ""
                row.ownerText = remote?.isLoopback == true ? "on this Mac" : "a remote end"
                row.owner = process?.tab != nil ? "tab" : "elsewhere"
                return row
            }
        }
        var rows = order.compactMap { lines[$0] }
        for index in rows.indices where rows[index].count > 1 { rows[index].process += " ×\(rows[index].count)" }
        return (rows, clients, tunnels, dropped.count)
    }

    /// "cloudflared (pid 4242)" when `holder` is a tunnel client.
    static func tunnelClient(_ holder: ActivityProcessID, byIdentity: [ActivityProcessID: ActivityProcessRow]) -> String? {
        guard let process = byIdentity[holder] else { return nil }
        let file = process.path.map(ActivityAttribution.fileName) ?? process.name
        guard tunnelClients.contains(file) || (file == "ssh" && (process.command ?? "").contains(" -R")) else { return nil }
        return "\(file) (pid \(holder.pid))"
    }

    /// The listeners' clients, and a loopback listener a tunnel client
    /// reaches marked forwarded (6.8, Scope) — both by the server's
    /// identity and port, from every pair, listed or past the cap.
    static func count(_ listeners: inout [ActivityPortRow], clients: [String: Int], tunnels: [String: String]) {
        for index in listeners.indices {
            guard let holder = listeners[index].holder else { continue }
            let row = listeners[index]
            let keys = ([holder] + row.coHolders).map { "\($0.id):\(row.port)" }
            listeners[index].clients = keys.reduce(0) { $0 + (clients[$1] ?? 0) }
            if row.scope == .thisMac, let key = keys.first(where: { tunnels[$0] != nil }) { listeners[index].forwardedBy = tunnels[key] }
        }
    }
}

/// What the Activity page holds of Docker's (6.5, 6.8): nothing; its
/// model shown — the running containers' published ports, Listening's
/// owners —; or that and their usage, while Processes lists them.
enum ActivityContainerWant: Hashable, Sendable {
    case none, listed, usage
}

extension ActivityPorts {
    private static let ephemeralLock = NSLock()
    nonisolated(unsafe) private static var ephemeralRead: Int?

    /// `net.inet.ip.portrange.first`, read once for the app; 49152 where
    /// it can't be.
    static func ephemeralRangeFirst() -> Int {
        if let known = ephemeralLock.withLock({ ephemeralRead }) { return known }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let first = sysctlbyname("net.inet.ip.portrange.first", &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 49_152
        ephemeralLock.withLock { ephemeralRead = first }
        return first
    }
}

extension ActivityAddress {
    /// An address as Docker's `HostIp` writes it, IPv4 or IPv6 (a v4-mapped
    /// one taken as the IPv4 it maps); nil for anything else. Pure.
    init?(text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self.init(v4: v4)
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text, &v6) == 1 else { return nil }
        self.init(v6: v6)
    }
}
