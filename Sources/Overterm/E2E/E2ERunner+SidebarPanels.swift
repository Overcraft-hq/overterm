import AppKit

/// Settings ▸ General ▸ Sidebar: Sessions and Snippets switched off and on
/// — their icons go from the rail, the panel on screen gives way to Files,
/// and the palette stops listing snippets.
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
    }
}
