import Foundation

/// "Waiting for you" for an agent that sends no signal: a look at the
/// screen of a pane you aren't looking at.
///
/// Claude Code tells the terminal when it waits (OSC 777) and works (OSC
/// 9;4); Codex sends OSC 9 on an approval by default; Gemini CLI and pi
/// are started with theirs on (`AgentLaunch`). opencode's is off by
/// default and lives in its own TUI config, and any agent started outside
/// Overterm's launch (typed in a shell) may have none — so its tab never
/// said it needed you. For those, the window (`TerminalWindowController+
/// AgentScreen`) looks, every `interval`:
/// - only at a pane of a tab not in front of you, that has not sent a
///   notification or progress since its last command began (`signalled`),
///   where something runs;
/// - which agent is in the pane's foreground is read off the main thread
///   (a lookup in the census, `foregroundAgent(in:snapshot:)`), at most every
///   `agentRecheck` per pane;
/// - only a pane with an agent has its screen read (the viewport's text,
///   on the main thread — `ghostty_surface_read_text`, under a millisecond
///   for a screenful), parsed off it;
/// - a question there (`question(in:)`) marks the tab waiting with its
///   words; gone, the mark goes (`TabActivity.agentAnswered`), as a
///   Terraform ask's does. A tab in front of you is read only while a
///   mark from here stands, to see the question go.
/// Pure.
package enum AgentScreenCheck {
    package static let interval: Duration = .seconds(3)
    /// How long a pane's agent, read off its processes, is believed.
    package static let agentRecheck: TimeInterval = 10
    /// The screen's last lines read: a question is the newest thing there.
    package static let window = 40

    /// Whether a pane is looked at this round: something runs in it, it
    /// hasn't signalled, and its tab isn't in front of you — or a question
    /// read there earlier still stands (to see it go).
    package static func looks(running: Bool, signalled: Bool, visible: Bool, standing: Bool) -> Bool {
        if standing { return true }
        return running && !signalled && !visible
    }

    /// What an agent asks on `text` (a pane's screen), in its own words —
    /// nil when it asks nothing:
    /// - an approval in numbers (`AgentPrompt.isApproval`: a question, one
    ///   choice marked, one that says no) — Claude Code's, Codex's,
    ///   Gemini CLI's;
    /// - opencode's dialog, `△ Permission required` with its Allow once /
    ///   Reject buttons (no numbers: nothing to answer with, only to say).
    /// pi asks nothing (no approvals, by design).
    package static func question(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n").suffix(window)
        let tail = lines.joined(separator: "\n")
        if let prompt = AgentPrompt.parse(tail), prompt.isApproval {
            return prompt.question
        }
        return opencodePermission(in: Array(lines))
    }

    /// opencode's permission dialog: the header, and its buttons below it.
    /// Its `$ <command>` line, when a shell command is asked about.
    package static func opencodePermission(in lines: [String]) -> String? {
        let clean = lines.map { AgentPrompt.unboxed($0).trimmingCharacters(in: .whitespaces) }
        guard let header = clean.lastIndex(where: { $0.contains("Permission required") }) else { return nil }
        let below = clean[header...]
        guard below.contains(where: { $0.contains("Allow once") }), below.contains(where: { $0.contains("Reject") }) else { return nil }
        let command = below.first { $0.hasPrefix("$ ") }
        return ["Permission required", command].compactMap { $0 }.joined(separator: " — ")
    }
}
