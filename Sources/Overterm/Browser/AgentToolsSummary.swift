import Foundation

/// What agents may reach through Overterm's MCP server, every feature's
/// switch in one place (P09, MCP-U3) — Settings ▸ Agents shows it, read
/// only; each switch is changed in its own section. Pure over `value`.
package enum AgentToolsSummary {
    package struct Row: Equatable, Identifiable {
        package let feature: String
        /// "on", "off", "reads only", "reads; asks to write"…
        package let state: String
        /// The section the switch lives in.
        package let section: String
        package var id: String { feature }
    }

    /// `value(key)`: the setting in effect (`Settings.value`).
    package static func rows(_ value: (String) -> SettingValue?) -> [Row] {
        func on(_ key: String) -> Bool { value(key)?.bool ?? false }
        func access(_ read: String, _ writes: String? = nil, writesSay: String = "asks to write") -> String {
            guard on(read) else { return "off" }
            guard let writes else { return "on" }
            return on(writes) ? "reads; \(writesSay), each asked" : "reads only"
        }
        let contexts = value("kubernetes.agentWrites")?.list ?? []
        let kubernetes: String =
            !on("kubernetes.agentAccess")
            ? "off" : contexts.isEmpty ? "reads only" : "reads; asks to change \(contexts.joined(separator: ", ")), each asked"
        return [
            Row(feature: "Browser", state: on("browser.agentControl") ? "on" : "off", section: "Browser"),
            Row(feature: "API client", state: on("api.agentControl") ? "on" : "off", section: "API Client"),
            Row(feature: "Notes", state: access("notes.agentAccess"), section: "Notes"),
            Row(feature: "Database", state: access("database.agentAccess", "database.agentWrites"), section: "Database"),
            Row(feature: "Docker", state: access("docker.agentAccess", "docker.agentWrites", writesSay: "asks to act"), section: "Docker"),
            Row(feature: "Kubernetes", state: kubernetes, section: "Kubernetes"),
            Row(feature: "Activity", state: access("activity.agentAccess"), section: "Activity"),
            Row(feature: "Terraform", state: access("terraform.agentAccess"), section: "Terraform"),
        ]
    }
}
