import Combine
import Foundation

/// Which panel the sidebar is showing.
///
/// It was `@AppStorage` inside the view, which was enough while every
/// panel read what it needed anyway. Overgit does not: it runs git, and
/// only while it is the panel on screen — so the window has to be able to
/// see the choice, not just the view.
@MainActor
final class SidebarModel: ObservableObject {
    static let panelKey = "sidebarPanel"

    @Published var panel: SidebarPanel {
        didSet {
            guard panel != oldValue else { return }
            AppEnvironment.defaults.set(panel.rawValue, forKey: Self.panelKey)
        }
    }

    init() {
        let stored = SidebarPanel(stored: AppEnvironment.defaults.string(forKey: Self.panelKey))
        // Left on the API panel or the notes, then switched off in Settings: Files.
        panel = stored.isEnabled ? stored : .files
    }
}
