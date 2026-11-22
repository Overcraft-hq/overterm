import Darwin
import Foundation

/// What closing panes leaves running (docs/design/activity/analysis.md,
/// 6.9, The close sheet; D-16), from one census: what will keep running —
/// what ignores SIGHUP, or has no terminal any more (`nohup`, `setsid`, a
/// daemon's fork, what left the pane carrying its tag) — and what its shell
/// decides — background jobs that don't ignore SIGHUP: zsh sends them
/// SIGHUP at exit unless they were disowned or `NO_HUP` is set. Neither
/// holds a process detached on purpose, an app started from the pane or
/// one on another terminal: those are named on one line, "not affected".
/// Pure.
package struct ActivitySurvivors: Hashable, Sendable {
    package struct Survivor: Hashable, Sendable {
        package let identity: ActivityProcessID
        package let name: String
        package let path: String?
        /// Its listening TCP ports.
        package var ports: [Int] = []
        /// It ignores SIGHUP.
        package var nohup = false

        /// "acme-server (pid 4242) :3001".
        package var label: String {
            var words = "\(name) (pid \(identity.pid))"
            if !ports.isEmpty { words += " " + ports.prefix(3).map { ":\($0)" }.joined(separator: " ") }
            return words
        }
    }

    package var keepRunning: [Survivor] = []
    package var shellDecides: [Survivor] = []
    /// Terraform's, tofu's or terragrunt's, which go on: named, never a
    /// checkbox — SIGTERM can leave a state locked and half written; only
    /// Interrupt, from Activity, stops one (6.10).
    package var interruptOnly: [Survivor] = []
    /// Names of what started here and isn't affected (tmux, an app).
    package var unaffected: [String] = []

    package var isEmpty: Bool { keepRunning.isEmpty && shellDecides.isEmpty && interruptOnly.isEmpty }
    /// What gets a checkbox.
    package var all: [Survivor] { keepRunning + shellDecides }
    /// Whether something will go on running: closing asks then (D-16).
    package var anyKeepRunning: Bool { !keepRunning.isEmpty || !interruptOnly.isEmpty }

    /// At most this many are listed, each with its checkbox.
    package static let limit = 20

    /// `tags`' panes as `snapshot` read them. `terminals`: each pane's pty,
    /// as the context knows it. Only the user's own, never a zombie, the
    /// pane's `login` or its shell — the close path ends those.
    package static func of(
        _ tags: [String], in snapshot: ActivitySnapshot, terminals: [String: dev_t] = [:], checkouts: [String] = [],
        kept: Set<ActivityProcessID> = []
    ) -> ActivitySurvivors {
        var survivors = ActivitySurvivors()
        var seen = Set<ActivityProcessID>()
        var unaffected: [String] = []
        let table = snapshot.table
        for tag in tags {
            guard let slice = snapshot.pane(tag) else { continue }
            let set = ActivityPaneSet(slice, in: snapshot, terminal: terminals[tag], checkouts: checkouts)
            let inTree = Set(slice.tree)
            let shell = slice.tree.first { table.parent(of: $0)?.identity == slice.login }
            func isTerraform(_ identity: ActivityProcessID, _ process: ActivityProcess) -> Bool {
                TerraformCommandLine.tools.contains(ActivityPaneSet.executableName(process, facts: snapshot.facts[identity]))
            }
            func survivor(_ identity: ActivityProcessID, _ process: ActivityProcess) -> Survivor {
                let facts = snapshot.facts[identity]
                let ports = (facts?.sockets?.listeners ?? []).filter { $0.kind == .tcp }.map { Int($0.localPort) }
                return Survivor(
                    identity: identity, name: snapshot.name(of: identity) ?? process.shortName, path: facts?.path, ports: Array(Set(ports)).sorted(),
                    nohup: process.ignoresHangup)
            }
            for identity in set.members where identity != slice.login && identity != shell && !kept.contains(identity) {
                guard seen.insert(identity).inserted, let process = table.process(identity), !process.isZombie,
                    process.isOwn(by: snapshot.uid)
                else { continue }
                if !inTree.contains(identity) || process.terminal == nil {
                    if isTerraform(identity, process) {
                        survivors.interruptOnly.append(survivor(identity, process))
                        continue
                    }
                    survivors.keepRunning.append(survivor(identity, process))
                } else if let foreground = process.terminalGroup, foreground != process.group,
                    table.parent(of: identity).map({ !inTree.contains($0.identity) || $0.identity == shell }) ?? false
                {
                    // A background job's leader: its group gets the shell's SIGHUP.
                    if isTerraform(identity, process) {
                        survivors.interruptOnly.append(survivor(identity, process))
                        continue
                    }
                    survivors.shellDecides.append(survivor(identity, process))
                }
            }
            for (identity, reason) in set.leftOut {
                guard seen.insert(identity).inserted, let process = table.process(identity), !process.isZombie else { continue }
                switch reason {
                case .ignoresHangup:
                    guard process.isOwn(by: snapshot.uid), !kept.contains(identity) else { break }
                    if isTerraform(identity, process) {
                        survivors.interruptOnly.append(survivor(identity, process))
                    } else {
                        survivors.keepRunning.append(survivor(identity, process))
                    }
                case .detachedOnPurpose, .app:
                    let name = ActivityAttribution.appName(of: snapshot.facts[identity]?.path) ?? snapshot.name(of: identity) ?? process.shortName
                    if !unaffected.contains(name) { unaffected.append(name) }
                case .otherTerminal, .anotherPane, .underExcluded:
                    break
                }
            }
        }
        survivors.keepRunning = Array(survivors.keepRunning.prefix(limit))
        survivors.shellDecides = Array(survivors.shellDecides.prefix(max(limit - survivors.keepRunning.count, 0)))
        survivors.interruptOnly = Array(survivors.interruptOnly.prefix(5))
        survivors.unaffected = Array(unaffected.prefix(5))
        return survivors
    }

    /// The sheet's words (6.9): "Will keep running: …", "Its shell
    /// decides: …", "tmux and Cursor, started here, are not affected."
    package var said: String {
        var lines = listed.isEmpty ? [] : [listed]
        if !all.isEmpty { lines.append("Tick what to stop too; what you leave unticked is kept, and never offered for a bulk Stop.") }
        return lines.joined(separator: "\n")
    }

    /// The lists alone, for a sheet without checkboxes (a window's close,
    /// quitting): what goes on running is named, nothing is stopped.
    package var listed: String {
        var lines: [String] = []
        if !keepRunning.isEmpty { lines.append("Will keep running: \(keepRunning.map(\.label).joined(separator: ", ")).") }
        if !shellDecides.isEmpty {
            lines.append("Its shell decides: \(shellDecides.map(\.label).joined(separator: ", ")) — zsh hangs up background jobs it didn't disown.")
        }
        if !unaffected.isEmpty {
            let names = unaffected.count == 1 ? unaffected[0] : unaffected.dropLast().joined(separator: ", ") + " and " + unaffected.last!
            lines.append("\(names), started here, \(unaffected.count == 1 ? "is" : "are") not affected.")
        }
        if !interruptOnly.isEmpty {
            lines.append(
                "Terraform goes on: \(interruptOnly.map(\.label).joined(separator: ", ")) — never stopped here; Interrupt it from Activity, or it may leave its state locked.")
        }
        return lines.joined(separator: "\n")
    }
}
