import Foundation

/// How Processes is grouped (docs/design/activity/analysis.md, 6.5, `G`).
enum ActivityGrouping: String, CaseIterable, Sendable {
    case checkout, tab, agent, app, user, none

    var title: String {
        switch self {
        case .checkout: "Checkout"
        case .tab: "Tab"
        case .agent: "Agent"
        case .app: "App"
        case .user: "User"
        case .none: "None"
        }
    }

    /// `G`'s next.
    var next: ActivityGrouping {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The scope ladder (6.5): `[` narrower, `]` wider.
enum ActivityScope: Hashable, Sendable {
    /// One tab's panes, what left them, the forwards it started.
    case tab(UUID)
    /// Every tab of one checkout, in any window, its containers.
    case checkout(String)
    /// Every tab, Overterm and its helpers.
    case allTabs
    /// Everything.
    case mac

    var rung: Int {
        switch self {
        case .tab: 0
        case .checkout: 1
        case .allTabs: 2
        case .mac: 3
        }
    }

    /// `]`: one rung wider; a tab's scope widens to its checkout's.
    func wider(checkout: String?) -> ActivityScope {
        switch self {
        case .tab: checkout.map(ActivityScope.checkout) ?? .allTabs
        case .checkout: .allTabs
        case .allTabs, .mac: .mac
        }
    }

    /// `[`: one rung narrower, onto `tab` and its `checkout` — the
    /// selected row's, else the window's selected tab's. Nil where there
    /// is nothing narrower to go to.
    func narrower(tab: UUID?, checkout: String?) -> ActivityScope? {
        switch self {
        case .mac: return .allTabs
        case .allTabs: return checkout.map(ActivityScope.checkout) ?? tab.map(ActivityScope.tab)
        case .checkout: return tab.map(ActivityScope.tab)
        case .tab: return nil
        }
    }
}

/// A running container, as `DockerModel` and its usage monitor know it:
/// what Processes lists under its checkout, "in Docker's VM" (6.5).
struct ActivityContainer: Hashable, Sendable {
    let id: String
    let name: String
    var project: String?
    /// Its compose project's working folder.
    var folder: String?
    var cpu: Double?
    var memory: UInt64?
}

/// A row of Processes that isn't a process: a group's header, a container,
/// "+N more" (6.5).
struct ActivityGroupRow: Equatable, Sendable {
    enum Kind: String, Sendable {
        case checkout, tab, pane, agent, fixed, app, user, left, docker, container, more
    }

    let id: String
    let kind: Kind
    var depth = 0
    var title: String
    /// Beside the title: the branch, the agent, its counts.
    var detail = ""
    /// Processes under it.
    var count = 0
    var cpu: Double?
    var memory: UInt64?
    var ports: [Int] = []
    var folded = false
    var foldable = true
    var agent: Agent?

    /// A header spans the columns; a container's row has cells.
    var spansColumns: Bool { kind != .container }

    var accessibilityLabel: String {
        var words = [title]
        if !detail.isEmpty { words.append(detail) }
        if kind != .container, kind != .more { words.append(count == 1 ? "1 process" : "\(count) processes") }
        if let cpu { words.append("\(ActivityRows.percent(cpu)) percent CPU") }
        if folded { words.append("folded") }
        return words.joined(separator: ", ")
    }
}

/// A row of Processes as the page lists it.
enum ActivityListItem: Equatable, Sendable {
    case group(ActivityGroupRow)
    case process(ActivityProcessRow)

    var id: String {
        switch self {
        case .group(let row): row.id
        case .process(let row): row.id
        }
    }
}

extension ActivityRows {
    // MARK: Scope and words

    /// Whether a process `owner` places is in `scope`.
    static func inScope(
        _ owner: ActivityOwner?, _ scope: ActivityScope, tabs: [UUID: ActivityTabFacts], context: ActivityContext, identity: ActivityProcessID
    ) -> Bool {
        if scope == .mac { return true }
        guard let owner else { return false }
        // A forward Overterm started is its tab's.
        let forwardTab = context.forwards.first { $0.pid == identity.pid && $0.pid > 0 }?.tab
        let tab = paneTab(owner) ?? forwardTab
        switch scope {
        case .mac: return true
        case .allTabs:
            if tab != nil { return true }
            return owner.place == .overterm || owner.place == .anotherOverterm
        case .checkout(let path): return tab.flatMap { tabs[$0]?.checkout } == path
        case .tab(let id): return tab == id
        }
    }

    /// The tab a process shows under: its pane's — a detached daemon's
    /// while its pane lives — never an app's it was only started from.
    static func paneTab(_ owner: ActivityOwner) -> UUID? {
        if case .pane = owner.place { return owner.tab }
        return nil
    }

    /// A folder's name: what a checkout is called.
    static func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// What an owner outside the tabs is called.
    static func ownerLabel(_ owner: ActivityOwner) -> String? {
        switch owner.place {
        case .overterm: "Overterm"
        case .anotherOverterm: "another Overterm"
        case .engine(let name): "\(name)’s engine"
        case .app(let name): name
        case .macOS: "macOS"
        case .system, .elsewhere, .pane: nil
        }
    }

    /// The Where column: tab · checkout · agent, else its owner.
    static func whereText(_ row: ActivityProcessRow, tabs: [UUID: ActivityTabFacts]) -> String {
        if let owner = row.owner, let tab = paneTab(owner) {
            var words = ["“\(tabs[tab]?.title ?? "")”"]
            if let checkout = row.checkout { words.append(checkout) }
            if let agent = owner.agentKind { words.append(agent.name) }
            return words.joined(separator: " · ")
        }
        guard let owner = row.owner else { return "" }
        switch owner.place {
        case .system: return row.user
        case .elsewhere: return owner.reason ?? "elsewhere"
        default: return ownerLabel(owner) ?? ""
        }
    }

    // MARK: The list

    /// The fixed groups after the tabs (6.5), in order: Overterm, another
    /// Overterm, your apps, yours elsewhere, macOS, other users'.
    enum Fixed: String, CaseIterable {
        case overterm, anotherOverterm, apps, elsewhere, macOS, system

        var title: String {
            switch self {
            case .overterm: "Overterm (the app and its helpers)"
            case .anotherOverterm: "Another Overterm"
            case .apps: "Your apps"
            case .elsewhere: "Yours elsewhere"
            case .macOS: "macOS"
            case .system: "System — names only"
            }
        }

        /// Folded until unfolded: the long tails.
        var foldedByDefault: Bool { self == .apps || self == .elsewhere || self == .macOS || self == .system }

        var id: String { "group:fixed:\(rawValue)" }

        static func of(_ owner: ActivityOwner?) -> Fixed {
            switch owner?.place {
            case .overterm?: .overterm
            case .anotherOverterm?: .anotherOverterm
            case .app?, .engine?: .apps
            case .macOS?: .macOS
            case .system?: .system
            case .pane?, .elsewhere?, nil: .elsewhere
            }
        }
    }

    /// Processes grouped and laid out as a tree (6.5): pure, off the main
    /// thread. Groups keep a stable order — the strips' for tabs, then the
    /// fixed ones — never by load; within a group the tree's siblings, or
    /// the flat rows, follow the sort.
    static func list(
        _ rows: [ActivityProcessRow], grouping: ActivityGrouping, in snapshot: ActivitySnapshot, tabs: [UUID: ActivityTabFacts], options: Options
    ) -> [ActivityListItem] {
        var builder = ListBuilder(snapshot: snapshot, tabs: tabs, options: options)
        switch grouping {
        case .checkout: builder.byTabs(rows, checkouts: true)
        case .tab: builder.byTabs(rows, checkouts: false)
        case .agent: builder.byAgent(rows)
        case .app: builder.byApp(rows)
        case .user: builder.byUser(rows)
        case .none: builder.items += builder.tree(rows, depth: 0, group: "group:all")
        }
        return builder.items
    }

    struct ListBuilder {
        let snapshot: ActivitySnapshot
        let tabs: [UUID: ActivityTabFacts]
        let options: Options
        var items: [ActivityListItem] = []

        func folded(_ id: String, default value: Bool = false) -> Bool { options.folds[id] ?? value }

        /// A header with its rows' totals; its rows follow unless folded.
        mutating func group(_ row: ActivityGroupRow, rows: [ActivityProcessRow], containers: [ActivityContainer] = [], body: (inout ListBuilder) -> Void) {
            var header = row
            header.count = rows.count
            let rated = rows.compactMap(\.cpu) + containers.compactMap(\.cpu)
            header.cpu = rated.isEmpty ? nil : rated.reduce(0, +)
            let memory = rows.compactMap(\.memory) + containers.compactMap(\.memory)
            header.memory = memory.isEmpty ? nil : memory.reduce(0, +)
            header.ports = Array(Set(rows.flatMap(\.listening))).sorted()
            if let reveal = options.reveal, header.folded, rows.contains(where: { $0.id == reveal }) { header.folded = false }
            items.append(.group(header))
            guard !header.folded else { return }
            body(&self)
        }

        // MARK: Checkout and tab

        mutating func byTabs(_ rows: [ActivityProcessRow], checkouts: Bool) {
            var byTab: [UUID: [ActivityProcessRow]] = [:]
            var rest: [ActivityProcessRow] = []
            for row in rows {
                if let owner = row.owner, let tab = paneTab(owner) { byTab[tab, default: []].append(row) } else { rest.append(row) }
            }
            // The strips' order: every tab the snapshot read, with rows.
            let order = byTab.keys.sorted { (tabs[$0]?.order ?? .max, $0.uuidString) < (tabs[$1]?.order ?? .max, $1.uuidString) }
            if checkouts {
                var checkoutOrder: [String?] = []
                for tab in order where !checkoutOrder.contains(tabs[tab]?.checkout) { checkoutOrder.append(tabs[tab]?.checkout) }
                // Tabs outside a checkout come after every checkout.
                if let index = checkoutOrder.firstIndex(where: { $0 == nil }) { checkoutOrder.append(checkoutOrder.remove(at: index)) }
                let containers = Dictionary(grouping: options.containers) { container in checkout(of: container) }
                for checkout in checkoutOrder {
                    let its = order.filter { tabs[$0]?.checkout == checkout }
                    let members = its.flatMap { byTab[$0] ?? [] }
                    let stack = checkout.flatMap { containers[$0] } ?? []
                    let id = "group:checkout:\(checkout ?? "-")"
                    var header = ActivityGroupRow(id: id, kind: .checkout, title: checkoutTitle(checkout, tabs: its), folded: folded(id))
                    header.detail = checkoutDetail(members, tabs: its)
                    group(header, rows: members, containers: stack) { builder in
                        for tab in its { builder.tabGroup(tab, rows: byTab[tab] ?? [], depth: 1, withLeft: false) }
                        builder.left(members, depth: 1, under: id)
                        if !stack.isEmpty { builder.docker(stack, under: id) }
                    }
                }
            } else {
                for tab in order { tabGroup(tab, rows: byTab[tab] ?? [], depth: 0, withLeft: true) }
            }
            fixed(rest)
        }

        /// The folder a container's compose project works in, as the
        /// longest known checkout holding it.
        func checkout(of container: ActivityContainer) -> String? {
            guard let folder = container.folder else { return nil }
            let known = Set(tabs.values.compactMap(\.checkout)).union(options.checkouts)
            return known.filter { ActivityPaneSet.isInside(folder, $0) }.max { $0.count < $1.count }
        }

        func checkoutTitle(_ checkout: String?, tabs its: [UUID]) -> String {
            guard let checkout else { return "Tabs outside a checkout" }
            let facts = its.first.flatMap { tabs[$0] }
            let name = facts?.repository ?? folderName(checkout)
            if let branch = facts?.branch, branch != name { return "\(name) · \(branch)" }
            return name
        }

        func checkoutDetail(_ rows: [ActivityProcessRow], tabs its: [UUID]) -> String {
            var words: [String] = []
            let agents = Set(rows.compactMap { $0.owner?.paneRole == .agent ? $0.owner?.agentKind : nil })
            for agent in Agent.allCases where agents.contains(agent) { words.append("✳ \(agent.name)") }
            words.append(its.count == 1 ? "1 tab" : "\(its.count) tabs")
            return words.joined(separator: "  ")
        }

        /// A tab's header, its panes (named only in a split tab) and their
        /// trees; what left its terminal under it `withLeft` (grouped by
        /// tab), else under the checkout, after its tabs.
        mutating func tabGroup(_ tab: UUID, rows: [ActivityProcessRow], depth: Int, withLeft: Bool) {
            let id = "group:tab:\(tab.uuidString)"
            let shown = rows.filter { $0.owner?.marks.contains(.leftTerminal) != true }
            var header = ActivityGroupRow(id: id, kind: .tab, depth: depth, title: "“\(tabs[tab]?.title ?? "")”", folded: folded(id))
            if let agentRow = shown.first(where: { $0.owner?.paneRole == .agent }), let agent = agentRow.owner?.agentKind {
                header.agent = agent
                header.detail = ([agent == .claude ? "Claude Code" : "Codex"] + [agentRow.agentCounts ?? roleCounts(agentRow, in: rows)].filter { !$0.isEmpty })
                    .joined(separator: "  ")
            }
            group(header, rows: rows) { builder in
                let panes = builder.snapshot.panes(of: tab)
                if panes.count > 1 {
                    for (index, pane) in panes.enumerated() {
                        let its = shown.filter { $0.owner?.place == .pane(pane.tag) }
                        guard !its.isEmpty else { continue }
                        let paneID = "group:pane:\(pane.tag)"
                        builder.group(
                            ActivityGroupRow(id: paneID, kind: .pane, depth: depth + 1, title: "Pane \(index + 1)", folded: builder.folded(paneID)), rows: its
                        ) { builder in builder.items += builder.tree(its, depth: depth + 2, group: paneID) }
                    }
                } else {
                    builder.items += builder.tree(shown, depth: depth + 1, group: id)
                }
                if withLeft { builder.left(rows, depth: depth + 1, under: id) }
            }
        }

        /// "Left its terminal (N)" (rule 9) under its checkout or tab.
        mutating func left(_ rows: [ActivityProcessRow], depth: Int, under parent: String) {
            let left = rows.filter { $0.owner?.marks.contains(.leftTerminal) == true }
            guard !left.isEmpty else { return }
            let id = "group:left:\(parent)"
            group(ActivityGroupRow(id: id, kind: .left, depth: depth, title: "Left its terminal (\(left.count))", folded: folded(id)), rows: left) {
                builder in builder.items += builder.tree(left, depth: depth + 1, group: id)
            }
        }

        /// A checkout's containers, "in Docker's VM": their processes run
        /// inside its one VM process (rule 6).
        mutating func docker(_ containers: [ActivityContainer], under parent: String) {
            let id = "group:docker:\(parent)"
            let names = containers.map(\.name).joined(separator: ", ")
            let projects = Set(containers.compactMap(\.project)).sorted()
            var header = ActivityGroupRow(id: id, kind: .docker, depth: 1, title: "In Docker’s VM: \(names)", folded: folded(id))
            if !projects.isEmpty { header.detail = "compose project \(projects.joined(separator: ", "))" }
            group(header, rows: [], containers: containers) { builder in
                for container in containers.sorted(by: { $0.name < $1.name }) {
                    var row = ActivityGroupRow(id: "container:\(container.id)", kind: .container, depth: 2, title: container.name, foldable: false)
                    row.cpu = container.cpu
                    row.memory = container.memory
                    row.detail = container.project.map { "compose project \($0)" } ?? ""
                    builder.items.append(.group(row))
                }
            }
        }

        /// An agent row's counts: what runs under it, by role.
        func roleCounts(_ agent: ActivityProcessRow, in rows: [ActivityProcessRow]) -> String {
            let under = rows.filter { $0.owner?.agent == agent.identity && $0.identity != agent.identity }
            var counts: [String] = []
            for role in [ProcessRole.mcp, .shell, .server] {
                let count = under.filter { $0.owner?.role == role }.count
                if count > 0 { counts.append(role.counted(count)) }
            }
            return counts.joined(separator: " · ")
        }

        /// The groups after the tabs.
        mutating func fixed(_ rows: [ActivityProcessRow]) {
            let byGroup = Dictionary(grouping: rows) { Fixed.of($0.owner) }
            for fixed in Fixed.allCases {
                guard let members = byGroup[fixed], !members.isEmpty else { continue }
                let header = ActivityGroupRow(
                    id: fixed.id, kind: .fixed, title: "\(fixed.title) (\(members.count))", folded: folded(fixed.id, default: fixed.foldedByDefault))
                group(header, rows: members) { builder in
                    if fixed == .apps {
                        builder.apps(members, depth: 1)
                    } else {
                        builder.items += builder.tree(members, depth: 1, group: fixed.id)
                    }
                }
            }
        }

        /// Apps and engines, each a group of its own, by name.
        mutating func apps(_ rows: [ActivityProcessRow], depth: Int) {
            let byApp = Dictionary(grouping: rows) { row -> String in
                switch row.owner?.place {
                case .app(let name)?: name
                case .engine(let name)?: name
                default: row.name
                }
            }
            for name in byApp.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                let members = byApp[name] ?? []
                let id = "group:app:\(name)"
                var header = ActivityGroupRow(id: id, kind: .app, depth: depth, title: name, folded: folded(id))
                if let engine = members.first(where: { if case .engine = $0.owner?.place { true } else { false } }) {
                    header.detail = engine.owner?.reason ?? ""
                } else if let started = members.first(where: { $0.owner?.marks.contains(.fromPane) == true && $0.owner?.rule == 7 }) {
                    header.detail = started.owner?.reason ?? ""
                }
                group(header, rows: members) { builder in builder.items += builder.tree(members, depth: depth + 1, group: id) }
            }
        }

        // MARK: Agent, app, user

        mutating func byAgent(_ rows: [ActivityProcessRow]) {
            let agents = rows.filter { $0.owner?.paneRole == .agent }.sorted { lhs, rhs in
                (lhs.owner?.tab.flatMap { tabs[$0]?.order } ?? .max, lhs.identity) < (rhs.owner?.tab.flatMap { tabs[$0]?.order } ?? .max, rhs.identity)
            }
            var claimed = Set<ActivityProcessID>()
            for agent in agents {
                let members = rows.filter { $0.owner?.agent == agent.identity }
                claimed.formUnion(members.map(\.identity))
                let id = "group:agent:\(agent.id)"
                var words = [agent.owner?.agentKind?.name ?? agent.name]
                if let tab = agent.owner?.tab { words.append("“\(tabs[tab]?.title ?? "")”") }
                if let checkout = agent.checkout { words.append(checkout) }
                var header = ActivityGroupRow(id: id, kind: .agent, title: words.joined(separator: " · "), folded: folded(id))
                header.agent = agent.owner?.agentKind
                header.detail = roleCounts(agent, in: rows)
                group(header, rows: members) { builder in builder.items += builder.tree(members, depth: 1, group: id) }
            }
            let rest = rows.filter { !claimed.contains($0.identity) }
            guard !rest.isEmpty else { return }
            let id = "group:agent:none"
            group(ActivityGroupRow(id: id, kind: .agent, title: "No agent", folded: folded(id)), rows: rest) { builder in
                builder.items += builder.tree(rest, depth: 1, group: id)
            }
        }

        /// Apps with their helpers; the rest by executable ("node ×14").
        mutating func byApp(_ rows: [ActivityProcessRow]) {
            let byKey = Dictionary(grouping: rows) { row -> String in
                switch row.owner?.place {
                case .app(let name)?: name
                case .engine(let name)?: name
                case .overterm?: "Overterm"
                case .anotherOverterm?: "Another Overterm"
                default: row.name
                }
            }
            for key in byKey.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                let members = byKey[key] ?? []
                let isApp = members.contains {
                    switch $0.owner?.place {
                    case .app?, .engine?, .overterm?, .anotherOverterm?: true
                    default: false
                    }
                }
                let id = "group:app:\(key)"
                let title = isApp || members.count == 1 ? key : "\(key) ×\(members.count)"
                group(ActivityGroupRow(id: id, kind: .app, title: title, folded: folded(id)), rows: members) { builder in
                    builder.items += builder.tree(members, depth: 1, group: id)
                }
            }
        }

        mutating func byUser(_ rows: [ActivityProcessRow]) {
            let byUser = Dictionary(grouping: rows, by: \.user)
            let mine = rows.first(where: \.isOwn)?.user
            let order = byUser.keys.sorted { lhs, rhs in
                let left = (lhs == mine ? 0 : lhs == "root" ? 1 : 2, lhs)
                let right = (rhs == mine ? 0 : rhs == "root" ? 1 : 2, rhs)
                return left < right
            }
            for user in order {
                let members = byUser[user] ?? []
                let id = "group:user:\(user)"
                let title = user == mine ? "Yours (\(user))" : user
                group(ActivityGroupRow(id: id, kind: .user, title: title, folded: folded(id, default: user != mine)), rows: members) { builder in
                    builder.items += builder.tree(members, depth: 1, group: id)
                }
            }
        }

        // MARK: The tree

        /// `rows` as a tree by their parents (linked by start time in the
        /// table) at `depth`, siblings in the sort's order — or flat, sorted
        /// — at most `groupLimit` process rows, then "+N more".
        func tree(_ rows: [ActivityProcessRow], depth: Int, group: String) -> [ActivityListItem] {
            let sort = options.processSort
            let moreID = "more:\(group)"
            let limit = folded(moreID, default: true) ? max(options.groupLimit, 1) : Int.max
            var out: [ActivityListItem] = []
            var shown = 0
            var hidden = 0
            var truncated = false
            func emit(_ row: ActivityProcessRow) -> Bool {
                guard shown < limit else {
                    truncated = true
                    return false
                }
                out.append(.process(row))
                shown += 1
                return true
            }
            if !options.tree {
                for var row in sorted(rows, by: sort) {
                    row.depth = depth
                    row.agentCounts = row.owner?.paneRole == .agent ? roleCounts(row, in: rows) : nil
                    guard emit(row) else { break }
                }
            } else {
                let present = Set(rows.map(\.identity))
                var children: [ActivityProcessID: [ActivityProcessRow]] = [:]
                var roots: [ActivityProcessRow] = []
                for row in rows {
                    if let parent = snapshot.table.parent(of: row.identity), present.contains(parent.identity) {
                        children[parent.identity, default: []].append(row)
                    } else {
                        roots.append(row)
                    }
                }
                // Depth first, siblings sorted; a stack, bounded by the rows.
                var stack: [(ActivityProcessRow, Int)] = sorted(roots, by: sort).reversed().map { ($0, depth) }
                while let (next, level) = stack.popLast() {
                    var row = next
                    let below = children[row.identity] ?? []
                    row.depth = level
                    row.hasChildren = !below.isEmpty
                    row.folded = row.hasChildren && folded(row.id)
                    if row.owner?.paneRole == .agent { row.agentCounts = roleCounts(row, in: rows) }
                    guard emit(row) else { break }
                    if !row.folded {
                        stack += sorted(below, by: sort).reversed().map { ($0, level + 1) }
                    } else {
                        // What the fold hides, counted: never "more".
                        var under = below
                        while let next = under.popLast() {
                            hidden += 1
                            under += children[next.identity] ?? []
                        }
                    }
                }
            }
            if truncated {
                let left = max(rows.count - shown - hidden, 0)
                var more = ActivityGroupRow(id: moreID, kind: .more, depth: depth, title: "+\(left) more", folded: true)
                more.count = left
                out.append(.group(more))
            }
            return out
        }
    }
}
