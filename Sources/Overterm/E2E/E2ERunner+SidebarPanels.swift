import AppKit

/// Settings ▸ General ▸ Sidebar: Sessions and Snippets switched off and on
/// — their icons go from the rail, the panel on screen gives way to Files,
/// and the palette stops listing snippets. Then the rail's order, its
/// Compact size, and the panel a new window opens on.
extension E2ERunner {
    func sidebarPanelsScenario() async {
        app.snippets.upsert(Snippet(name: "Validate everything", command: "mise run validate"))
        check("both are in the rail", SidebarPanel.shown.contains(.sessions) && SidebarPanel.shown.contains(.snippets))

        app.sidebarPanel.panel = .snippets
        Settings.shared.set("general.snippets", .bool(false))
        check("Snippets off: its icon goes", await eventually(3) { !SidebarPanel.shown.contains(.snippets) })
        check("and the sidebar on it shows Files", app.sidebarPanel.panel == .files, "\(app.sidebarPanel.panel)")
        app.showPalette(nil)
        app.palette.query = "validate"
        check("and ⌘K lists no snippet", !app.palette.results.contains { $0.group == .snippet }, "\(app.palette.results.map(\.title))")
        app.palette.query = ""
        app.hidePalette()

        app.sidebarPanel.panel = .sessions
        Settings.shared.set("general.sessions", .bool(false))
        check("Sessions off: its icon goes", await eventually(3) { !SidebarPanel.shown.contains(.sessions) })
        check("and the sidebar on it shows Files", app.sidebarPanel.panel == .files, "\(app.sidebarPanel.panel)")

        Settings.shared.set("general.snippets", nil)
        Settings.shared.set("general.sessions", nil)
        check("on again, both come back", await eventually(3) { SidebarPanel.shown.contains(.sessions) && SidebarPanel.shown.contains(.snippets) })
        app.showPalette(nil)
        app.palette.query = "validate"
        check("and ⌘K finds the snippet", app.palette.results.first?.group == .snippet, "\(app.palette.results.map(\.title))")
        app.hidePalette()

        // The order: settings.json's, Move Up / Move Down from the rail's
        // menu, and a hidden panel passed over.
        Settings.shared.set("general.sidebarOrder", .list(["database", "api", "files"]))
        let enabled = SidebarPanel.ordered(["database", "api", "files"]).filter(\.isEnabled)
        check("the rail takes settings.json's order", await eventually(3) { SidebarPanel.shown == enabled }, "\(SidebarPanel.shown)")
        let first = SidebarPanel.shown[0]
        SidebarPanel.move(first, by: 1)
        check(
            "Move Down puts it after the next icon", SidebarPanel.shown.firstIndex(of: first) == 1,
            "\(SidebarPanel.shown), file: \(Settings.shared.value("general.sidebarOrder")?.list ?? [])")
        SidebarPanel.move(first, by: -1)
        check("and Move Up back", SidebarPanel.shown.first == first, "\(SidebarPanel.shown)")
        Settings.shared.set("general.sidebarOrder", nil)
        check("the default order is today's", SidebarPanel.shown == SidebarPanel.allCases.filter(\.isEnabled))

        // Compact: a narrower rail, and the column's limits follow it.
        let regular = app.sidebarItem?.minimumThickness ?? 0
        Settings.shared.set("general.sidebarRail", .string("compact"))
        check(
            "Compact narrows the rail and the column's minimum with it",
            await eventually(3) { (self.app.sidebarItem?.minimumThickness ?? 0) == regular - 8 },
            "\(regular) → \(app.sidebarItem?.minimumThickness ?? 0)")
        Settings.shared.set("general.sidebarRail", nil)
        check("Regular gives it back", await eventually(3) { self.app.sidebarItem?.minimumThickness == regular })

        // A new window's panel: the one Settings names, else the last one.
        app.sidebarPanel.panel = .git
        check("a new window opens on the last one", SidebarModel().panel == .git)
        Settings.shared.set("general.sidebarStartPanel", .string("files"))
        check("…or the one Settings names", SidebarModel().panel == .files)
        Settings.shared.set("general.sidebarStartPanel", nil)
    }
}
