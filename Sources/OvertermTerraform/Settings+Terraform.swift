import Foundation

extension Settings {
    /// Each root's own settings, by its path in the repository.
    package var terraformRoots: [String: TerraformRootSettings] { TerraformRootSettings.all(from: value("terraform.roots")) }
}
