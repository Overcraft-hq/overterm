import Foundation

/// A page that covers the window's body in place of the selected terminal
/// tab, and sits in the strip after the terminal tabs while open
/// (`TabStore.openOverlays`). Not a `Tab`: no terminal, no group, no ⌘1–9.
/// The window wires each from its declaration (`WorkspacePage`).
package enum WorkspaceOverlay: String, Equatable, CaseIterable {
    case settings, docker, kubernetes, activity, setup

    package var title: String {
        switch self {
        case .settings: "Settings"
        case .docker: "Docker"
        case .kubernetes: "Kubernetes"
        case .activity: "Activity"
        case .setup: "Setup"
        }
    }

    /// The SF Symbol in front of its name in the strip.
    package var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .docker: "shippingbox"
        case .kubernetes: "steeringwheel"
        case .activity: "cpu"
        case .setup: "wrench.and.screwdriver"
        }
    }
}
