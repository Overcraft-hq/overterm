import Foundation

/// Sets each feature's hooks into the shell under it (`FeatureHooks`):
/// looked up by its Objective-C name the first time a hook is read. In the
/// order the shell lists them (an agent's tools: the API client's, the notes',
/// the databases', Docker's, Kubernetes', Terraform's, Activity's). Sets storage only — reading a hook from here
/// would wait on itself.
@objc(OvertermFeatures)
final class OvertermFeatures: NSObject {
    @objc static func install() {
        APIFeature.install()
        NotesFeature.install()
        DatabaseFeature.install()
        DockerFeature.install()
        KubernetesFeature.install()
        TerraformFeature.install()
        ActivityFeature.install()
        MCPAsker.paneCheckoutStorage = { tag in await TerminalWindowController.paneCheckout(tag) }
    }
}
