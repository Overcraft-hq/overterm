import Foundation

/// Sets each feature's hooks into the shell under it (`FeatureHooks`):
/// looked up by its Objective-C name the first time a hook is read. In the
/// order the shell lists them (an agent's tools: the API client's, the notes',
/// the databases', Docker's, Kubernetes', Terraform's). Sets storage only — reading a hook from here
/// would wait on itself.
@objc(OvertermFeatures)
final class OvertermFeatures: NSObject {
    @objc static func install() {
        APIFeature.install()
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix("notes_") }, enabled: { $0.notesAgentAccess },
                unavailable: "The notes aren't available to agents — Settings ▸ Notes.",
                tools: { NotesMCP.tools },
                instructions: { settings in
                    "The user's notes (an Obsidian vault): notes_search finds notes by name, #tag or what they say, notes_read reads one with its links — for context the user keeps there. Read-only."
                        + (settings.notesAgentDrawings
                            ? " notes_draw makes a new Excalidraw drawing from boxes, arrows and text — a diagram the user asked for, opened beside the terminal."
                            : "")
                },
                call: { name, arguments, _ in try await NotesMCP.call(name, arguments, notes: NotesModel.shared) }))
        DatabaseFeature.install()
        DockerFeature.install()
        KubernetesFeature.install()
        TerraformFeature.install()
        MCPAsker.paneCheckoutStorage = { tag in await TerminalWindowController.paneCheckout(tag) }
    }
}
