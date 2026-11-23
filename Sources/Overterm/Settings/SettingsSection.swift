import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Settings' sections, as in the list on the page's left.
package enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, themes, terminal, agents, editor, browser, api, notes, database, docker, kubernetes, terraform, activity, notifications, shortcuts, about

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .themes: "Themes"
        case .terminal: "Terminal"
        case .agents: "Agents"
        case .editor: "Editor"
        case .browser: "Browser"
        case .api: "API Client"
        case .notes: "Notes"
        case .database: "Database"
        case .docker: "Docker"
        case .kubernetes: "Kubernetes"
        case .terraform: "Terraform"
        case .activity: "Activity"
        case .notifications: "Notifications"
        case .shortcuts: "Keyboard Shortcuts"
        case .about: "About"
        }
    }

    package var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .themes: "paintpalette"
        case .terminal: "terminal"
        case .agents: "sparkle"
        case .editor: "doc.text"
        case .browser: "globe"
        case .api: "arrow.left.arrow.right"
        case .notes: "note.text"
        case .database: "cylinder.split.1x2"
        case .docker: "shippingbox"
        case .kubernetes: "steeringwheel"
        case .terraform: "square.stack.3d.up"
        case .activity: "cpu"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }

    /// The JSON file its settings live in.
    package var file: String { self == .shortcuts ? "keybindings.json" : "settings.json" }

    /// Whether a search finds something here: the title, a setting, a shortcut.
    @MainActor package func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if title.lowercased().contains(query.lowercased()) { return true }
        if self == .shortcuts { return KeyCommands.all.contains { $0.matches(query) } }
        if self == .about, ["version", "update", "changelog", "release"].contains(where: { $0.contains(query.lowercased()) }) { return true }
        return SettingsSchema.specs(in: self).contains { $0.matches(query) }
    }
}
