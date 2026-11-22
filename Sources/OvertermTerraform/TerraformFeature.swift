import Foundation

/// Terraform's part in the shell under it, set once (`OvertermFeatures`).
package enum TerraformFeature {
    package static func install() {
        TerraformEditor.install()
        SettingsSchema.entryFieldsStorage["terraform.roots"] = TerraformRootSettings.fields
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix(TerraformMCP.prefix) }, enabled: { $0.terraformAgentAccess },
                unavailable: "Terraform isn't available to agents — Settings ▸ Terraform.",
                tools: { TerraformMCP.tools }, instructions: { TerraformMCP.instructions },
                call: { name, arguments, pane, _ in try await TerraformMCP.call(name, arguments, pane: pane) },
                said: { error in TerraformMCP.scrubbed(error.localizedDescription) }))
    }
}
