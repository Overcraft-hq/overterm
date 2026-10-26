import AppKit

/// Two islands and a loose tab, saved and brought back: every tab returns,
/// each in its island, in order. The second island used to be pruned while
/// the first was restored, and its tabs vanished.
extension E2ERunner {
    func sessionGroupsScenario() async {
        guard let first = app.store.selected else { return check("a tab", false) }
        first.customTitle = "loose"
        var made: [Tab] = []
        for name in ["a", "b", "c", "d"] {
            app.newTab(in: scratch)
            guard let tab = app.store.selected, tab !== first else { return check("tab \(name)", false) }
            tab.customTitle = name
            made.append(tab)
        }
        app.store.addToNewGroup([made[0], made[1]], name: "work")
        app.store.addToNewGroup([made[2], made[3]], name: "play")
        let before = islands()
        check("two islands to save", before == ["loose", "[work: a,b]", "[play: c,d]"], "\(before)")

        let file = scratch.appendingPathComponent("session-groups.json")
        try? app.sessionState.save(to: file)
        guard let state = SessionState.load(from: file) else { return check("the session reads back", false) }
        check("both islands are saved", state.groups?.map(\.name) == ["work", "play"], "\(String(describing: state.groups?.map(\.name)))")

        // The next launch: an empty window, then the session.
        let old = app.store.tabs
        app.restore(state)
        old.forEach { tab in
            tab.terminals.forEach { $0.close() }
            app.store.remove(tab)
        }
        let after = islands()
        check("every tab comes back, each in its island", after == before, "\(after)")
        check("nothing vanished", app.store.tabs.count == 5, "\(app.store.tabs.map(\.title))")
    }

    private func islands() -> [String] {
        app.store.strip.map {
            switch $0 {
            case .group(let group, let tabs): "[\(group.name): \(tabs.map(\.title).joined(separator: ","))]"
            case .loose(let tab): tab.title
            }
        }
    }
}
