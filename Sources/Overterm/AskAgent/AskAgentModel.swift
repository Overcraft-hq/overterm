import Foundation

/// Handing a piece of a terminal to an agent.
///
/// The thing you want to say to an agent is almost always on screen
/// already — a failing test, a stack trace, a diff it should look at — and
/// the way to say it was to select it, copy it, switch tabs, paste, and
/// then remember which command produced it. This carries the selection
/// and the context around it across in one step.
@MainActor
final class AskAgentModel: ObservableObject {
    /// Where the text can go.
    struct Target: Identifiable, Equatable {
        /// Nil means "a new agent tab in this folder".
        let id: Tab.ID?
        let title: String
        let detail: String
        let color: TabColor?
        let agent: Agent?
    }

    /// What goes along with the selection. Each is only offered when there
    /// is something to put in it.
    struct Extras: Equatable {
        var command = true
        var exit = true
        var diff = false
    }

    @Published private(set) var selection = ""
    @Published private(set) var targets: [Target] = []
    @Published var chosen: Tab.ID?
    @Published var extras = Extras()
    @Published var message = ""
    @Published private(set) var isOpen = false

    /// The command the selection came out of, if the pane's ledger knows.
    private(set) var command: CommandBlock?
    /// The folder a new agent tab would open in.
    private(set) var folder: String?

    var lines: Int { selection.isEmpty ? 0 : selection.components(separatedBy: "\n").count }

    func begin(selection: String, command: CommandBlock?, folder: String?, targets: [Target], diff: Bool) {
        self.selection = selection
        self.command = command
        self.folder = folder
        self.targets = targets
        chosen = targets.first { $0.id != nil }?.id
        extras = Extras(command: command != nil, exit: command?.exit != nil, diff: false)
        message = ""
        isOpen = !selection.isEmpty
    }

    func stop() {
        isOpen = false
        selection = ""
    }

    /// What will actually be typed. Built here rather than in the view so
    /// it can be read in a test — this is the part that matters.
    func prompt(diff: String? = nil) -> String {
        var parts: [String] = []
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(message) }
        if extras.command, let command {
            var line = "$ \(command.command)"
            if extras.exit, let exit = command.exit, exit != 0 { line += "   (exit \(exit))" }
            parts.append(line)
        }
        parts.append(selection)
        if extras.diff, let diff, !diff.isEmpty { parts.append("git diff:\n\(diff)") }
        return parts.joined(separator: "\n\n")
    }
}
