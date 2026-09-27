import Foundation

/// The GitHub CLI, run like git (a GCD thread, no prompts). Everything
/// GitHub goes through `gh`, so it uses the user's own login.
enum GitHub {
    enum Failure: LocalizedError, Equatable {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "The GitHub CLI (gh) isn't installed — brew install gh, then gh auth login."
            case .failed(let message): message
            }
        }
    }

    /// Set by the E2E runner: a stand-in gh that answers from fixtures.
    @MainActor static var executableOverride: URL?

    /// A GUI app's PATH has no Homebrew: look where gh is installed.
    @MainActor static var executable: URL? {
        if let executableOverride { return executableOverride }
        return ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    @MainActor
    static func run(_ arguments: [String], in directory: URL, timeout: TimeInterval? = Git.defaultTimeout) async throws -> Data {
        guard let executable else { throw Failure.notInstalled }
        do {
            return Data(try await Git.run(executable, arguments, in: directory, timeout: timeout).utf8)
        } catch let error as GitError {
            throw Failure.failed(message(for: error.stderr))
        }
    }

    /// gh's stderr, said plainly for the cases people hit.
    static func message(for stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("gh auth login") || text.contains("not logged") { return "Not logged in to GitHub — run gh auth login." }
        if text.contains("no git remotes") || text.contains("none of the git remotes") { return "This repository has no GitHub remote." }
        if text.contains("no pull requests found") { return "No pull request for this branch." }
        return text.isEmpty ? "gh failed." : text
    }
}
