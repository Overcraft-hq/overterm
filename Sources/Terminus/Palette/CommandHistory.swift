import Foundation

/// A command you have run, and how it went.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var command: String
    /// Where it was run, for "this folder first".
    var folder: String?
    var exit: Int?
    var seconds: Double?
    var lastRun: Date
    var runs: Int

    var id: String { command }
    var failed: Bool { (exit ?? 0) != 0 }

    /// "2 h ago", "yesterday" — coarse, like a stashed group's.
    func ago(_ now: Date = Date()) -> String { TabGroup.stashedAgo(lastRun, now: now) }

    /// "exit 0 · 48 s", for the detail pane.
    var outcome: String {
        var parts: [String] = []
        if let exit { parts.append("exit \(exit)") }
        if let seconds { parts.append(seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s") }
        return parts.joined(separator: " · ")
    }
}

/// What this machine has run, newest and nearest first.
///
/// Terminus had no command history at all: the palette knew actions, tabs,
/// worktrees and snippets, and the thing you most often want to run again
/// is the thing you ran an hour ago. The shell knows it, but only its own
/// — and only as a flat list with no folder, no exit code and no notion
/// of which of two similar commands worked.
///
/// So it is kept here, fed by the command ledger (which already records
/// every command with its exit, its duration and its folder) and seeded
/// once from the shell's own history file so it is not empty on day one.
@MainActor
final class CommandHistory: ObservableObject {
    /// Past this the oldest go. Large enough to cover weeks, small enough
    /// to rank in a keystroke.
    static nonisolated let limit = 2000

    @Published private(set) var entries: [HistoryEntry] = []
    private let url: URL
    private var saving: Task<Void, Never>?

    init(url: URL = AppEnvironment.supportDirectory.appendingPathComponent("history.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        } else {
            if FileManager.default.fileExists(atPath: url.path) { UnreadableFile.setAside(url) }
            entries = Self.fromShellHistory()
        }
    }

    /// A command that finished. The same command run again is the same
    /// entry, moved to the front with its new outcome — a list with
    /// `git status` in it forty times is not a history, it is a wall.
    func record(_ block: CommandBlock, folder: String?) {
        let command = block.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !CommandLedger.isPrompt(command, cwd: folder) else { return }
        var next = entries
        let runs = (next.first { $0.command == command }?.runs ?? 0) + 1
        next.removeAll { $0.command == command }
        next.insert(
            HistoryEntry(
                command: command, folder: folder, exit: block.exit, seconds: block.seconds, lastRun: Date(),
                runs: runs), at: 0)
        if next.count > Self.limit { next.removeLast(next.count - Self.limit) }
        entries = next
        scheduleSave()
    }

    /// What the palette shows for a query. Pure, because the ordering is
    /// the whole feature.
    nonisolated static func rank(
        _ entries: [HistoryEntry], query: String, folder: String?, now: Date, limit: Int = 12
    ) -> [HistoryEntry] {
        let scored: [(HistoryEntry, Int)] = entries.compactMap { entry in
            guard let match = FuzzyMatch.score(query, in: entry.command) else { return nil }
            var score = match
            // This folder first: the same command means something different
            // in another checkout, and the one you want is nearly always here.
            if let folder, let its = entry.folder {
                if its == folder {
                    score += 4000
                } else if folder.hasPrefix(its) || its.hasPrefix(folder) {
                    score += 1500
                }
            }
            // Then recency, in whole hours so that today beats last week
            // without the last minute beating a better match.
            let hours = max(0, Int(now.timeIntervalSince(entry.lastRun) / 3600))
            score += max(0, 600 - hours * 4)
            score += min(entry.runs, 20) * 10
            return (entry, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func ranked(query: String, folder: String?, limit: Int = 12) -> [HistoryEntry] {
        Self.rank(entries, query: query, folder: folder, now: Date(), limit: limit)
    }

    // MARK: Seeding and saving

    /// The shell's own history, once, so the palette is useful before you
    /// have run anything in Terminus. No folders, no exit codes — that is
    /// all the file has.
    nonisolated static func fromShellHistory(
        file: URL? = nil, now: Date = Date(), limit: Int = 2000
    ) -> [HistoryEntry] {
        let candidates =
            file.map { [$0] }
            ?? [
                ProcessInfo.processInfo.environment["HISTFILE"].map { URL(fileURLWithPath: $0) },
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bash_history"),
            ].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let data = try? Data(contentsOf: found)
        else { return [] }
        // zsh writes it latin-1-ish with metafied bytes; decoding lossily
        // is right here — a mangled character in an old command is better
        // than no history.
        let text = String(decoding: data, as: UTF8.self)
        var seen = Set<String>()
        var out: [HistoryEntry] = []
        // Newest last in the file, so walk it backwards.
        for line in text.components(separatedBy: "\n").reversed() {
            let command = Self.unextended(line)
            guard !command.isEmpty, command.count < 400, seen.insert(command).inserted else { continue }
            out.append(HistoryEntry(command: command, folder: nil, exit: nil, seconds: nil, lastRun: now, runs: 1))
            if out.count >= limit { break }
        }
        return out
    }

    /// `: 1699999999:0;git status` — zsh's extended format, when it is on.
    nonisolated static func unextended(_ line: String) -> String {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(":"), let semicolon = line.firstIndex(of: ";") else { return line }
        return String(line[line.index(after: semicolon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Coalesced: a busy pane finishes a command a second, and this is a
    /// whole-file write.
    private func scheduleSave() {
        saving?.cancel()
        let snapshot = entries
        let url = url
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.write(snapshot, to: url)
        }
    }

    private func write(_ entries: [HistoryEntry], to url: URL) async {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
