import Foundation

/// The Left Behind section (docs/design/activity/analysis.md, 6.9): its
/// rows grouped by checkout — the closed tab's, the dead leader's folder's —
/// then what an earlier Overterm or a test run left, then the rest. Each
/// header counts its rows and how many a bulk Stop may take. Pure.
extension ActivityRows {
    /// Where a Left Behind row is grouped: its checkout's path, or one of
    /// the fixed keys.
    static func leftBehindGroup(_ row: ActivityProcessRow, tabs: [UUID: ActivityTabFacts]) -> String {
        guard let sign = row.owner?.leftBehind else { return "-" }
        if let checkout = sign.checkout ?? row.owner?.tab.flatMap({ tabs[$0]?.checkout }) { return checkout }
        if sign == .testRun { return "~test" }
        if sign.isEarlierRun { return "~earlier" }
        return "-"
    }

    static func leftBehindTitle(_ key: String) -> String {
        switch key {
        case "~test": "Left by a test run"
        case "~earlier": "Left by an earlier Overterm"
        case "-": "Outside a checkout"
        default: folderName(key)
        }
    }

    /// The section's list: `rows` already scoped and filtered.
    static func leftBehindList(_ rows: [ActivityProcessRow], tabs: [UUID: ActivityTabFacts], options: Options) -> [ActivityListItem] {
        let left = rows.filter { $0.owner?.place == .leftBehind }
        guard !left.isEmpty else { return [] }
        let groups = Dictionary(grouping: left) { leftBehindGroup($0, tabs: tabs) }
        // Checkouts by name, then the fixed groups.
        let keys = groups.keys.sorted { lhs, rhs in
            let fixed = (lhs.hasPrefix("~") || lhs == "-", rhs.hasPrefix("~") || rhs == "-")
            if fixed.0 != fixed.1 { return !fixed.0 }
            return leftBehindTitle(lhs).lowercased() < leftBehindTitle(rhs).lowercased()
        }
        var items: [ActivityListItem] = []
        for key in keys {
            let members = sorted(groups[key] ?? [], by: options.processSort)
            let id = "group:left:\(key)"
            var header = ActivityGroupRow(id: id, kind: .left, title: leftBehindTitle(key), folded: options.folds[id] ?? false)
            // An ended row (6.7) is shown, never counted.
            let counted = members.filter { !$0.ended }
            header.count = counted.count
            let rated = counted.compactMap(\.cpu)
            header.cpu = rated.isEmpty ? nil : rated.reduce(0, +)
            let memory = counted.compactMap(\.memory)
            header.memory = memory.isEmpty ? nil : memory.reduce(0, +)
            header.ports = Array(Set(counted.flatMap(\.listening))).sorted()
            let certain = counted.count { $0.bulkEligible }
            header.detail = certain == counted.count ? "all certain" : "\(certain) certain"
            items.append(.group(header))
            guard !header.folded else { continue }
            for var row in members {
                row.depth = 1
                row.hasChildren = false
                items.append(.process(row))
            }
        }
        return items
    }

    /// The rows "Stop All Certain in This Checkout…" takes for `row`'s
    /// group (6.9): certain ones only, never one kept, ignoring SIGHUP,
    /// detached, an app or a terraform write — a probably row is picked by hand.
    static func certainInGroup(of row: ActivityProcessRow, in rows: [ActivityProcessRow], tabs: [UUID: ActivityTabFacts]) -> [ActivityProcessRow] {
        let key = leftBehindGroup(row, tabs: tabs)
        return rows.filter { $0.owner?.place == .leftBehind && $0.bulkEligible && !$0.ended && leftBehindGroup($0, tabs: tabs) == key }
    }
}

/// Left Behind's own verbs on a row (6.9): Keep, and Stop All Certain in
/// This Checkout… — each process's Stop is the class's, in the list above.
extension ActivityPageModel {
    func leftBehindVerbs(for row: ActivityProcessRow) -> [ResourceVerb] {
        guard let owner = row.owner, owner.place == .leftBehind || owner.kept else { return [] }
        var verbs: [ResourceVerb] = []
        verbs.append(
            ResourceVerb(
                title: owner.kept ? "Kept" : "Keep", symbol: "pin", unavailable: owner.kept ? "Kept: it is yours to keep running" : nil,
                perform: { [weak self] in self?.actions.keep(row.identity) }))
        guard owner.place == .leftBehind else { return verbs }
        let tabs = lastTabsForVerbs
        let group = ActivityRows.leftBehindGroup(row, tabs: tabs)
        let certain = ActivityRows.certainInGroup(of: row, in: content.processes, tabs: tabs)
        let title = ActivityRows.leftBehindTitle(group)
        verbs.append(
            ResourceVerb(
                title: group.hasPrefix("~") || group == "-" ? "Stop All Certain Here…" : "Stop All Certain in This Checkout…", symbol: "stop.circle",
                unavailable: certain.isEmpty ? "None here is certain: a probably row, a nohup'd, detached or kept one is picked by hand" : nil,
                perform: { [weak self] in self?.actions.stopAll(certain, title) }))
        return verbs
    }
}
