import Foundation

/// Handing a piece of a terminal to an agent.
///
/// The thing you want to say to an agent is almost always on screen
/// already — a failing test, a stack trace, a diff it should look at — and
/// the way to say it was to select it, copy it, switch tabs, paste, and
/// then remember which command produced it. This carries the selection
/// and the context around it across in one step.
@MainActor
package final class AskAgentModel: ObservableObject {
    package init() {}

    /// Where the text can go.
    package struct Target: Identifiable, Equatable {
        /// Nil means "a new agent tab in this folder".
        package let id: Tab.ID?
        package let title: String
        package let detail: String
        package let color: TabColor?
        package let agent: Agent?

        package init(id: Tab.ID?, title: String, detail: String, color: TabColor?, agent: Agent?) {
            self.id = id
            self.title = title
            self.detail = detail
            self.color = color
            self.agent = agent
        }
    }

    /// What goes along with the selection. Each is only offered when there
    /// is something to put in it.
    package struct Extras: Equatable {
        package var command = true
        package var exit = true
        package var diff = false
    }

    /// What else goes with the text, each a chip that can be switched off:
    /// a container's last log lines, its compose service. `text` is what
    /// goes in the prompt, its heading included.
    package struct Part: Identifiable, Equatable {
        package let title: String
        package let text: String
        package var on = true

        package init(title: String, text: String, on: Bool = true) {
            self.title = title
            self.text = text
            self.on = on
        }

        package var id: String { title }
    }

    /// The most diff that goes into a prompt. It is typed into a terminal,
    /// and a prompt nobody can scroll past is not a prompt.
    package static let maxDiffBytes = 128 << 10

    @Published package private(set) var selection = ""
    @Published package private(set) var targets: [Target] = []
    @Published package var chosen: Tab.ID?
    @Published package var extras = Extras()
    @Published package var message = ""
    @Published package private(set) var isOpen = false
    @Published package var parts: [Part] = []
    /// What the fixed chip says the text is, in place of "N selected
    /// lines": a container that failed.
    @Published package private(set) var subject: String?

    /// The command the selection came out of, if the pane's ledger knows.
    package private(set) var command: CommandBlock?
    /// The folder a new agent tab would open in.
    package private(set) var folder: String?
    /// Whether a diff can be had at all — the selection is in a checkout.
    /// The chip is offered only then, and is off until it is asked for:
    /// the other extras are a line each, this one can be thousands.
    @Published package private(set) var canDiff = false
    /// The whole prompt is shown in the sheet before it is sent: a brief
    /// assembled for the user (Kubernetes' Ask Why), not text they picked.
    @Published package private(set) var showsBrief = false

    package var lines: Int { selection.isEmpty ? 0 : selection.components(separatedBy: "\n").count }

    /// `message`: the question already typed (a container's "Why did …?").
    package func begin(
        selection: String, command: CommandBlock?, folder: String?, targets: [Target], diff: Bool, message: String = "", subject: String? = nil,
        parts: [Part] = [], showsBrief: Bool = false
    ) {
        self.selection = selection
        self.command = command
        self.folder = folder
        self.targets = targets
        chosen = targets.first { $0.id != nil }?.id
        // A brief's sheet shows the whole of what is sent; a git diff it
        // never showed isn't offered with it.
        canDiff = diff && !showsBrief
        extras = Extras(command: command != nil, exit: command?.exit != nil, diff: false)
        self.message = message
        self.subject = subject
        self.parts = parts
        self.showsBrief = showsBrief
        isOpen = !selection.isEmpty
    }

    package func stop() {
        isOpen = false
        selection = ""
        parts = []
        subject = nil
        showsBrief = false
    }

    /// What will actually be typed. Built here rather than in the view so
    /// it can be read in a test — this is the part that matters.
    ///
    /// `diff` has no default on purpose: a caller that forgets it drops
    /// the chip's whole point without saying so, which is exactly what
    /// the window did. Pass nil to mean "there is none".
    package func prompt(diff: String?) -> String {
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

/// A terminal selection as ⌘L hands it to an agent. A pod's tab (`kubectl
/// exec`, `attach`, `logs -f`) or one pinned to a Kubernetes context
/// prints what the cluster holds: scrubbed as the page's own Logs tab
/// scrubs the same lines (every URL's password, then what looks like a
/// credential — rule 9), never handed on in the clear. Pure.
package enum AskSelection {
    /// `env`: a pod's tab's pod's plain env values, taken out as the
    /// Logs tab takes them (`KubeLogScrub`) — a `DB_PASSWORD` printed bare.
    package static func text(_ selection: String, kind: TabKind, pinned: Bool, env: [(key: String, value: String)] = []) -> String {
        guard pinned || kind == .pod || kind == .kubernetes else { return selection }
        return KubeLogScrub.scrub(selection, env: env)
    }

    /// The command the selection came from, scrubbed the same way: a
    /// `kubectl --token=… get po` typed in a pinned tab.
    package static func command(_ block: CommandBlock?, kind: TabKind, pinned: Bool, env: [(key: String, value: String)] = []) -> CommandBlock? {
        guard let block else { return nil }
        guard pinned || kind == .pod || kind == .kubernetes else { return block }
        // `--token abc`, not only `--token=abc`: the command's own flags, then as the output.
        let words = block.command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let command = text(Secrets.maskArguments(words).joined(separator: " "), kind: kind, pinned: pinned, env: env)
        guard command != block.command else { return block }
        return CommandBlock(id: block.id, command: command, startRow: block.startRow, endRow: block.endRow, exit: block.exit, seconds: block.seconds)
    }
}
