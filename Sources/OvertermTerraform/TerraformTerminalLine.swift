import Foundation

/// The line a sentence that says "in a terminal" means (TF-U2): offered by
/// a button beside it that opens a terminal in the root and types the line
/// there — never runs it: `initialInput` without a newline, the person
/// presses Return. Pure.
package enum TerraformTerminalLine {
    package static let initialize = "terraform init"
    /// A backend that changed since init: `-migrate-state` asks before it
    /// copies anything, where `-reconfigure` would drop the old state.
    package static let migrateState = "terraform init -migrate-state"

    package static func newWorkspace(_ name: String) -> String { "terraform workspace new \(quoted(name))" }

    /// The line `message` asks for, when it is one of Terraform's dead ends
    /// Overterm says itself; nil for any other.
    package static func suggested(by message: String) -> String? {
        if message.contains("The backend changed since init") { return migrateState }
        if let name = missingWorkspace(in: message) { return newWorkspace(name) }
        if message.contains("in its lock file") || message.hasPrefix("Needs init") || message.contains("run init in a terminal")
            || message.contains("run terraform init in a terminal")
        {
            return initialize
        }
        return nil
    }

    /// "Workspace <name> no longer exists in …" → name.
    private static func missingWorkspace(in message: String) -> String? {
        guard message.hasPrefix("Workspace "), let end = message.range(of: " no longer exists") else { return nil }
        let name = message[message.index(message.startIndex, offsetBy: "Workspace ".count)..<end.lowerBound]
        return name.isEmpty ? nil : String(name)
    }

    /// A workspace name as zsh reads it: bare when it is plain, else in single quotes.
    private static func quoted(_ word: String) -> String {
        let plain = word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The button's words.
    package static func title(_ line: String) -> String { "Type “\(line)” in a Terminal" }
    /// Its help.
    package static let help = "Opens a terminal in this root and types the line — Return is yours"
}
