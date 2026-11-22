import Foundation

extension AgentLaunchFiles {
    /// Gemini's Terraform deny policy (`TerraformAgentGuard.geminiPolicy`).
    package static func geminiPolicy() -> String? { write("gemini-terraform-deny.toml", TerraformAgentGuard.geminiPolicy) }
}
