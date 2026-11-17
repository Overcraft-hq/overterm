import Foundation

/// The page's columns (docs/design/activity/analysis.md, 6.5): every one it
/// offers, which show by default, and the person's own — the set shown,
/// their order and widths — kept under `AppEnvironment.defaults`
/// (`activity.page.columns.v1`), so a test run's never reach the app's.
/// `ResourceTable` reports a header moved or resized (`columnsChanged`);
/// kept here, the next change of the columns — a grouping, a section —
/// builds them as the person left them. Pure but for `load` and `save`.
enum ActivityColumns {
    /// One column as kept: its id and width.
    struct Kept: Codable, Equatable, Sendable {
        var id: String
        var width: Double
    }

    /// What is kept: each section's columns in their order.
    typealias Layout = [String: [Kept]]

    static let key = "activity.page.columns.v1"

    /// Every column Processes offers, in its default order.
    static let processes: [ResourceColumn] = [
        ResourceColumn(id: "name", title: "Name", width: 300, minWidth: 140),
        ResourceColumn(id: "pid", title: "PID", width: 64),
        ResourceColumn(id: "cpu", title: "CPU %", width: 64, help: "100% is one core, as htop and Tab Info count"),
        ResourceColumn(id: "memory", title: "Memory", width: 84, help: "The footprint: Activity Monitor's Memory"),
        ResourceColumn(id: "threads", title: "Threads", width: 60),
        ResourceColumn(id: "state", title: "St", width: 36, help: "R running, S sleeping, T stopped, Z ended and not collected"),
        ResourceColumn(id: "started", title: "Started", width: 80),
        ResourceColumn(id: "listening", title: "Listening", width: 110, sortable: false, help: "The TCP ports it listens on"),
        ResourceColumn(id: "user", title: "User", width: 90),
        ResourceColumn(id: "where", title: "Where", width: 200, help: "Its tab · checkout · agent, or who it belongs to"),
        ResourceColumn(id: "rss", title: "Real Memory", width: 90, help: "Resident size: what is in RAM now"),
        ResourceColumn(id: "time", title: "CPU Time", width: 80, help: "User and system time since it started"),
        ResourceColumn(id: "nice", title: "Nice", width: 48),
        ResourceColumn(id: "priority", title: "Priority", width: 60, help: "The scheduler's priority, a plain number"),
        ResourceColumn(id: "ppid", title: "PPID", width: 64),
        ResourceColumn(id: "pgid", title: "PGID", width: 64),
        ResourceColumn(id: "tty", title: "TTY", width: 70),
        ResourceColumn(id: "kind", title: "Kind", width: 60, help: "Apple silicon, or Intel under Rosetta"),
        ResourceColumn(id: "path", title: "Path", width: 240, minWidth: 80),
        ResourceColumn(id: "command", title: "Command", width: 320, minWidth: 80, help: "Masked: a secret in its arguments is never shown"),
    ]

    /// Shown until the person picks: 6.5's "on" — User comes with All.
    static let processDefaults: [String] = ["name", "pid", "cpu", "memory", "threads", "state", "started", "listening"]

    /// Every column Listening offers, in its default order (6.8).
    static let listening: [ResourceColumn] = [
        ResourceColumn(id: "port", title: "Port", width: 70),
        ResourceColumn(id: "proto", title: "Proto", width: 52),
        ResourceColumn(id: "address", title: "Scope", width: 130, help: "This Mac: loopback only. Network: whatever can route to this Mac"),
        ResourceColumn(id: "families", title: "IP", width: 60, sortable: false, help: "The families it serves: a dual-stack socket both"),
        ResourceColumn(id: "owner", title: "Owner", width: 190, minWidth: 90, help: "The container, forward, tunnel, tab or app it belongs to"),
        ResourceColumn(id: "process", title: "Process", width: 170, minWidth: 90),
        ResourceColumn(id: "pid", title: "PID", width: 64),
        ResourceColumn(id: "where", title: "Where", width: 180, help: "Its tab · checkout · branch · agent"),
        ResourceColumn(id: "clients", title: "Clients", width: 60, help: "Your established connections to it"),
        ResourceColumn(id: "note", title: "Note", width: 300, minWidth: 80, help: "Another holder on the same port, or what a known holder is"),
        ResourceColumn(id: "since", title: "Since", width: 70, help: "When its holder started: a socket has no time of its own"),
        ResourceColumn(id: "backlog", title: "Backlog", width: 80, help: "Connections waiting to be accepted, of how many it may hold"),
    ]

    /// Shown until the person picks: Since and Backlog off.
    static let listeningDefaults: [String] = ["port", "proto", "address", "families", "owner", "process", "pid", "where", "clients", "note"]

    /// Where's comes and goes with the grouping (6.5): shown when grouped
    /// by neither checkout nor tab, never picked.
    static func showsWhere(_ grouping: ActivityGrouping) -> Bool { grouping != .checkout && grouping != .tab }

    /// The columns offered in the header's menu: never Name, which every
    /// row needs, nor Where or User, which come and go with the grouping
    /// and with All.
    static func choices(_ section: ActivityPageModel.Section) -> [ResourceColumn] {
        switch section {
        case .processes, .leftBehind: processes.filter { $0.id != "name" && $0.id != "where" && $0.id != "user" }
        case .listening: listening.filter { $0.id != "port" }
        }
    }

    /// `section`'s columns as shown: the kept ones in their order and
    /// widths — an unknown id left out —, else the defaults; Processes'
    /// User while All shows (`everyone`; with Yours every row says the
    /// same user) and Where by the grouping, each at its kept place or
    /// last.
    static func columns(_ section: ActivityPageModel.Section, kept: [Kept]?, grouping: ActivityGrouping, everyone: Bool) -> [ResourceColumn] {
        let all = section == .listening ? listening : processes
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var shown: [ResourceColumn]
        if let kept, !kept.isEmpty {
            var seen = Set<String>()
            shown = kept.compactMap { entry in
                guard var column = byID[entry.id], seen.insert(entry.id).inserted else { return nil }
                column.width = max(CGFloat(entry.width), column.minWidth)
                return column
            }
            if !seen.contains("name"), section == .processes, let name = byID["name"] { shown.insert(name, at: 0) }
        } else {
            shown = (section == .processes ? processDefaults : listeningDefaults).compactMap { byID[$0] }
        }
        guard section == .processes else { return shown }
        if everyone {
            if !shown.contains(where: { $0.id == "user" }), let user = byID["user"] { shown.append(user) }
        } else {
            shown.removeAll { $0.id == "user" }
        }
        if showsWhere(grouping) {
            if !shown.contains(where: { $0.id == "where" }), let place = byID["where"] { shown.append(place) }
        } else {
            shown.removeAll { $0.id == "where" }
        }
        return shown
    }

    /// The columns as the table reports them, kept: Where's place too, so
    /// it comes back there.
    static func kept(_ columns: [ResourceColumn]) -> [Kept] {
        columns.map { Kept(id: $0.id, width: Double($0.width)) }
    }

    /// `section`'s columns with `id` shown or hidden: a new one last.
    static func toggled(_ id: String, in columns: [ResourceColumn], section: ActivityPageModel.Section) -> [ResourceColumn] {
        if columns.contains(where: { $0.id == id }) {
            guard columns.count > 1 else { return columns }
            return columns.filter { $0.id != id }
        }
        let all = section == .processes ? processes : listening
        guard let column = all.first(where: { $0.id == id }) else { return columns }
        return columns + [column]
    }

    static func load() -> Layout {
        guard let data = AppEnvironment.defaults.data(forKey: key), let layout = try? JSONDecoder().decode(Layout.self, from: data) else { return [:] }
        return layout
    }

    static func save(_ layout: Layout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        AppEnvironment.defaults.set(data, forKey: key)
    }
}
