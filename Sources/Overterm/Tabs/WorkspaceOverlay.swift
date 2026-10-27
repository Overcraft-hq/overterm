import Foundation

/// A page that covers the window's body in place of the selected terminal
/// tab, and sits in the strip after the terminal tabs while open
/// (`TabStore.openOverlays`). Not a `Tab`: no terminal, no group, no ⌘1–9.
enum WorkspaceOverlay: String, Equatable {
    case settings, docker

    var title: String {
        switch self {
        case .settings: "Settings"
        case .docker: "Docker"
        }
    }

    /// The SF Symbol in front of its name in the strip.
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .docker: "shippingbox"
        }
    }
}
