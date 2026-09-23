import Foundation

/// A "task" is a worktree on its own branch with a tab (and usually an
/// agent) in it. This is the git half.
enum TaskCreator {
    /// Where a task's worktree goes: next to the repository, as
    /// `<repo>-wt-<branch>` — the layout already used by hand.
    static func worktreePath(repo: URL, branch: String) -> URL {
        let parent = repo.standardizedFileURL.deletingLastPathComponent()
        return parent.appendingPathComponent("\(repo.lastPathComponent)-wt-\(slug(branch))")
    }

    /// `feat/Cosign signing` → `feat-cosign-signing`.
    static func slug(_ branch: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var result = ""
        for scalar in branch.lowercased().unicodeScalars {
            let c = allowed.contains(scalar) ? Character(scalar) : "-"
            if c == "-", result.last == "-" { continue }
            result.append(c)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    enum Failure: LocalizedError {
        case invalidBranch(String)
        case pathExists(URL)

        var errorDescription: String? {
            switch self {
            case .invalidBranch(let name): "“\(name)” isn’t a valid branch name."
            case .pathExists(let url): "\(url.path) already exists."
            }
        }
    }

    /// Creates the worktree and returns its path. A new branch starts at
    /// `base`; an existing branch is checked out as it is (`base` unused).
    static func create(repo: URL, branch: String, base: String) async throws -> URL {
        guard (try? await Git.run(["check-ref-format", "--branch", branch], in: repo)) != nil else {
            throw Failure.invalidBranch(branch)
        }
        let path = worktreePath(repo: repo, branch: branch)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw Failure.pathExists(path) }

        let exists = (try? await Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
        if exists {
            _ = try await Git.run(["worktree", "add", path.path, branch], in: repo)
        } else {
            _ = try await Git.run(["worktree", "add", "-b", branch, path.path, base], in: repo)
        }
        return path
    }
}
