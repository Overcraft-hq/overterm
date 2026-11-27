import Foundation

/// A repository's New Task setup (GIT-G11, P05; D-7 (a)): the untracked
/// files a new worktree gets a copy of — `.env`, `.env.local` — and a
/// command typed in its tab before its agent starts. Kept in Overterm's
/// support folder by the repository's path (`TaskSetupStore`), never in
/// the repository: a committed setup command would be someone else's line
/// run on every machine that pulls it.
package struct TaskSetup: Codable, Equatable, Sendable {
    /// Paths relative to the repository, as typed.
    package var copy: [String] = []
    /// One line, typed in the tab; empty for none.
    package var command: String = ""

    package init(copy: [String] = [], command: String = "") {
        self.copy = copy
        self.command = command
    }

    package var isEmpty: Bool { copy.isEmpty && command.isEmpty }

    /// The sheet's field: paths by commas or new lines, blanks dropped, each
    /// once, in order. Pure.
    package static func paths(_ field: String) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for part in field.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let path = part.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// Why `command` can't be typed as one line, or nil. Pure.
    package static func commandProblem(_ command: String) -> String? {
        command.contains(where: \.isNewline) ? "The setup command is one line; join commands with && or ;." : nil
    }

    /// What the task's tab types: the setup, then — only if it succeeded —
    /// the agent. The setup is one group, `{ …; }`, so a line of its own
    /// that ends `;` or holds several commands stays whole, and what it
    /// changes (`cd`, `export`) stays in the shell the agent starts in. Nil
    /// when there is neither. Pure.
    package static func firstLine(setup: String, agent: String?) -> String? {
        var setup = setup.trimmingCharacters(in: .whitespaces)
        while setup.hasSuffix(";") { setup = String(setup.dropLast()).trimmingCharacters(in: .whitespaces) }
        switch (setup.isEmpty, agent) {
        case (true, nil): return nil
        case (true, let agent?): return agent
        case (false, nil): return setup
        case (false, let agent?):
            // A trailing `&` ends a command in a group as `;` does.
            let group = setup.hasSuffix("&") && !setup.hasSuffix("&&") ? "{ \(setup) }" : "{ \(setup); }"
            return "\(group) && \(agent)"
        }
    }
}

/// The setups, one a repository (by its standardized path), in
/// `AppEnvironment.taskSetupsFile`, 0600.
package enum TaskSetupStore {
    package static func load(file: URL = AppEnvironment.taskSetupsFile) -> [String: TaskSetup] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: TaskSetup].self, from: data)) ?? [:]
    }

    package static func setup(for repo: URL, file: URL = AppEnvironment.taskSetupsFile) -> TaskSetup {
        load(file: file)[key(repo)] ?? TaskSetup()
    }

    /// Saved as given; an empty one forgets the repository.
    package static func save(_ setup: TaskSetup, for repo: URL, file: URL = AppEnvironment.taskSetupsFile) throws {
        var all = load(file: file)
        all[key(repo)] = setup.isEmpty ? nil : setup
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    package static func key(_ repo: URL) -> String { repo.standardizedFileURL.path }
}

/// The copies into a new worktree. Each path must stay inside the
/// repository — no absolute path, no `..`, not `.git`, and once resolved,
/// links included, still under the repository's own resolved path — and
/// its copy must land inside the worktree, over nothing already there.
/// Files are copied, never read: nothing of what they hold is looked at,
/// logged or written anywhere else.
package enum TaskSetupCopy {
    package struct Report: Equatable, Sendable {
        package var copied: [String] = []
        /// The path and why it wasn't copied.
        package var skipped: [(path: String, why: String)] = []

        package static func == (a: Report, b: Report) -> Bool {
            a.copied == b.copied && a.skipped.map(\.path) == b.skipped.map(\.path) && a.skipped.map(\.why) == b.skipped.map(\.why)
        }
    }

    /// Why `path` can't name something inside a repository, or nil. Pure.
    package static func pathProblem(_ path: String) -> String? {
        if path.hasPrefix("/") || path.hasPrefix("~") { return "it isn't a path inside the repository" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.isEmpty || parts.contains(where: { $0 == ".." || $0 == "." }) { return "it isn't a path inside the repository" }
        if parts.first == ".git" { return "git's own folder isn't copied" }
        return nil
    }

    /// `path`'s real place, links resolved: `realpath(3)`. Nil when it
    /// doesn't exist.
    package static func resolved(_ url: URL) -> String? {
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    private struct Made { var problem: String? }

    /// `path`'s folders made inside `worktree`, each checked before the
    /// next: nil when one of them resolves outside it.
    private static func makeFolders(for path: String, in worktree: URL, root: String) -> Made? {
        let folders = path.split(separator: "/").dropLast()
        var place = worktree
        for folder in folders {
            place = place.appendingPathComponent(String(folder))
            if let real = resolved(place) {
                guard inside(real, root) else { return nil }
                continue
            }
            // A link that leads nowhere is still a link: never made through.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: place.path)) != nil { return nil }
            do {
                try FileManager.default.createDirectory(at: place, withIntermediateDirectories: false)
            } catch {
                return Made(problem: "its folder couldn't be made in the worktree")
            }
        }
        return Made()
    }

    package static func copy(_ paths: [String], from repo: URL, into worktree: URL) -> Report {
        var report = Report()
        guard let repoRoot = resolved(repo), let worktreeRoot = resolved(worktree) else {
            report.skipped = paths.map { ($0, "the repository or the worktree can't be read") }
            return report
        }
        let manager = FileManager.default
        for path in paths {
            if let problem = pathProblem(path) {
                report.skipped.append((path, problem))
                continue
            }
            let source = repo.appendingPathComponent(path)
            guard let real = resolved(source) else {
                report.skipped.append((path, "it isn't in the repository"))
                continue
            }
            guard inside(real, repoRoot), real != repoRoot else {
                report.skipped.append((path, "it leads outside the repository"))
                continue
            }
            let target = worktree.appendingPathComponent(path)
            if (try? target.checkResourceIsReachable()) == true || (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                report.skipped.append((path, "the worktree already has it"))
                continue
            }
            // Its folders, one at a time from the worktree down: each that is
            // there must resolve inside the worktree before anything is made
            // under it — a folder that links elsewhere is never written
            // through, not even to make a folder.
            guard let made = makeFolders(for: path, in: worktree, root: worktreeRoot) else {
                report.skipped.append((path, "its place in the worktree leads outside it"))
                continue
            }
            if let problem = made.problem {
                report.skipped.append((path, problem))
                continue
            }
            do {
                // The resolved file: a link inside the repository gives its
                // target's copy, never a link that may not resolve there.
                try manager.copyItem(atPath: real, toPath: target.path)
                report.copied.append(path)
            } catch {
                report.skipped.append((path, "it couldn't be copied"))
            }
        }
        return report
    }
}
