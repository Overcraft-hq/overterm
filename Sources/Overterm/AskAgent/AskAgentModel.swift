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

    /// What else goes with the text, each a chip that can be switched off:
    /// a container's last log lines, its compose service. `text` is what
    /// goes in the prompt, its heading included.
    struct Part: Identifiable, Equatable {
        let title: String
        let text: String
        var on = true

        var id: String { title }
    }

    /// The most diff that goes into a prompt. It is typed into a terminal,
    /// and a prompt nobody can scroll past is not a prompt.
    static let maxDiffBytes = 128 << 10

    @Published private(set) var selection = ""
    @Published private(set) var targets: [Target] = []
    @Published var chosen: Tab.ID?
    @Published var extras = Extras()
    @Published var message = ""
    @Published private(set) var isOpen = false
    @Published var parts: [Part] = []
    /// What the fixed chip says the text is, in place of "N selected
    /// lines": a container that failed.
    @Published private(set) var subject: String?

    /// The command the selection came out of, if the pane's ledger knows.
    private(set) var command: CommandBlock?
    /// The folder a new agent tab would open in.
    private(set) var folder: String?
    /// Whether a diff can be had at all — the selection is in a checkout.
    /// The chip is offered only then, and is off until it is asked for:
    /// the other extras are a line each, this one can be thousands.
    @Published private(set) var canDiff = false

    var lines: Int { selection.isEmpty ? 0 : selection.components(separatedBy: "\n").count }

    /// `message`: the question already typed (a container's "Why did …?").
    func begin(
        selection: String, command: CommandBlock?, folder: String?, targets: [Target], diff: Bool, message: String = "", subject: String? = nil,
        parts: [Part] = []
    ) {
        self.selection = selection
        self.command = command
        self.folder = folder
        self.targets = targets
        chosen = targets.first { $0.id != nil }?.id
        canDiff = diff
        extras = Extras(command: command != nil, exit: command?.exit != nil, diff: false)
        self.message = message
        self.subject = subject
        self.parts = parts
        isOpen = !selection.isEmpty
    }

    func stop() {
        isOpen = false
        selection = ""
        parts = []
        subject = nil
    }

    /// What will actually be typed. Built here rather than in the view so
    /// it can be read in a test — this is the part that matters.
    ///
    /// `diff` has no default on purpose: a caller that forgets it drops
    /// the chip's whole point without saying so, which is exactly what
    /// the window did. Pass nil to mean "there is none".
    func prompt(diff: String?) -> String {
        var sections: [String] = []
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(message) }
        if extras.command, let command {
            var line = "$ \(command.command)"
            if extras.exit, let exit = command.exit, exit != 0 { line += "   (exit \(exit))" }
            sections.append(line)
        }
        sections.append(selection)
        sections += parts.filter(\.on).map(\.text)
        if extras.diff, let diff, !diff.isEmpty { sections.append("git diff:\n\(diff)") }
        return sections.joined(separator: "\n\n")
    }
}
