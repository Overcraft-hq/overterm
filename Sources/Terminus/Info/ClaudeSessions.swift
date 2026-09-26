import Foundation

/// A Claude Code conversation that can be picked back up: one transcript
/// in ~/.claude/projects, and what its end says.
struct ClaudeSession: Identifiable, Equatable {
    /// The session id — the transcript's file name, what --resume takes.
    let id: String
    let file: URL
    /// Where it ran; resuming must start there.
    let directory: String
    let updated: Date
    let activity: ClaudeActivity

    /// A session id is what Claude Code names its transcripts: a UUID.
    /// Anything else is not typed into a shell.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

enum ClaudeSessions {
    /// A session list reads only this much of each transcript's end.
    static let tail = 128 * 1024

    /// The newest `limit` sessions run in `directories` or below them,
    /// newest first. Claude's project folders flatten paths (every
    /// non-alphanumeric is "-"), so a folder is a candidate by prefix and
    /// kept only if its transcript's cwd really is inside a directory.
    static func list(in directories: [String], limit: Int = 60) -> [ClaudeSession] {
        let roots = directories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var sessions: [ClaudeSession] = []
        for candidate in transcripts(in: roots.map { ClaudeUsageReader.projectFolder(for: $0) }) {
            guard sessions.count < limit, let activity = ClaudeActivity.read(candidate.file, tail: tail) else { continue }
            // A transcript with nothing typed in it isn't a conversation to go back to.
            guard activity.lastPrompt != nil || activity.title != nil, let cwd = activity.cwd else { continue }
            let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
            guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let id = candidate.file.deletingPathExtension().lastPathComponent
            guard ClaudeSession.isValidID(id) else { continue }
            sessions.append(ClaudeSession(id: id, file: candidate.file, directory: path, updated: candidate.updated, activity: activity))
        }
        return sessions
    }

    /// The transcripts in Claude's project folders named `folders` (see
    /// `ClaudeUsageReader.projectFolder`) and — `below` — in those of the
    /// folders under them, newest first. By name only: a look-alike
    /// (`repo-other` for `repo`) is a candidate too.
    static func transcripts(
        in folders: [String], below: Bool = true, projects: URL = ClaudeUsageReader.projectsDirectory
    ) -> [(file: URL, updated: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        var candidates: [(file: URL, updated: Date)] = []
        for name in names where folders.contains(where: { name == $0 || (below && name.hasPrefix($0 + "-")) }) {
            let dir = projects.appendingPathComponent(name)
            let files =
                (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((file, updated))
            }
        }
        return candidates.sorted { $0.updated > $1.updated }
    }
}
