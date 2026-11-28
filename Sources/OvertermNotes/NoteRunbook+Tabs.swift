import Foundation

extension NoteRunbook {
    /// Why a note's command isn't typed into a tab: one an agent runs in (it
    /// would be the agent's prompt, or answer its question), one at a
    /// Terraform ask (it would answer it). nil: asked as usual.
    package static func refusal(kind: TabKind, terraformAsking: Bool) -> String? {
        if terraformAsking { return "Terraform is waiting for an answer there: typing would answer it. Pick a shell tab and run it again." }
        if kind == .agent { return "An agent runs in that tab: the command would go to it as a prompt. Pick a shell tab and run it again." }
        return nil
    }
}
