import Foundation

/// Kept with the feature it is for; AppEnvironment holds the shell's.
extension AppEnvironment {
    /// The environment Terraform's runs are built on (`TerraformEnvironment`):
    /// the user's login shell's, so credential chains reach the providers
    /// unchanged; in a guarded run, nothing of the user's — a scratch HOME
    /// and CLI config, proxies at a dead port. Blocking the first time (the
    /// shell is asked): off the main thread.
    package static func terraformBaseEnvironment() throws -> [String: String] {
        guard guardsTerraform else { return ShellEnvironment.environment() }
        var environment = try TerraformGuards.prepareScratch(at: terraformScratchDirectory).environment
        for (name, value) in TerraformCLI.scenarioEnvironment { environment[name] = value }
        return environment
    }
}
