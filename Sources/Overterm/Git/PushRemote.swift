import Foundation

/// Which remote a branch or a tag is pushed to when it has no upstream yet
/// (GIT-U8): never `origin` by name. A fork's clone has `origin` and
/// `upstream`, or `fork` and `origin`, and the wrong one either fails or
/// opens the branch in somebody else's repository.
///
/// git's own order, then the person: `branch.<name>.pushRemote`, then
/// `remote.pushDefault`, then the branch's `branch.<name>.remote`, then the
/// one remote there is. Several and nothing said: asked. Pure but for
/// `read`, which asks git through `Git.run`.
package enum PushRemote {
    package enum Choice: Equatable {
        case remote(String)
        /// Several remotes and nothing configured: the person picks;
        /// `suggested` is preselected (origin, when there is one).
        case ask([String], suggested: String?)
        /// No remote at all.
        case none
    }

    /// `git remote`: one name a line.
    package static let remotesArguments = ["remote"]

    /// The three keys the choice reads, in one call. Exit 1 when none is
    /// set — not a failure.
    package static let configArguments = [
        "config", "-z", "--get-regexp", #"^(remote\.pushdefault|branch\..*\.(pushremote|remote))$"#,
    ]

    /// `config -z --get-regexp`: `key\nvalue\0` a record. git lowercases a
    /// key's section and name but keeps a branch's own case, so only those
    /// two parts are lowercased here.
    package static func parse(config output: String) -> [String: String] {
        var values: [String: String] = [:]
        for record in output.split(separator: "\0") {
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            values[normalized(String(key))] = parts.count > 1 ? String(parts[1]) : ""
        }
        return values
    }

    package static func parse(remotes output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `branch`: the branch pushed (nil for a tag, or detached). Only a
    /// remote that exists is chosen: a `pushDefault` left naming a removed
    /// one is passed over.
    package static func choose(branch: String?, remotes: [String], config: [String: String]) -> Choice {
        guard !remotes.isEmpty else { return .none }
        var keys = ["remote.pushdefault"]
        if let branch { keys = ["branch.\(branch).pushremote"] + keys + ["branch.\(branch).remote"] }
        for key in keys {
            if let name = config[key], remotes.contains(name) { return .remote(name) }
        }
        if remotes.count == 1 { return .remote(remotes[0]) }
        return .ask(remotes, suggested: remotes.contains("origin") ? "origin" : remotes.first)
    }

    /// Reads the remotes and the keys, then chooses.
    package static func read(branch: String?, in root: URL) async -> Choice {
        let remotes = parse(remotes: (try? await Git.run(remotesArguments, in: root)) ?? "")
        let config = parse(config: (try? await Git.run(configArguments, in: root, success: [0, 1])) ?? "")
        return choose(branch: branch, remotes: remotes, config: config)
    }

    /// `push` for a branch: `--set-upstream` the first time, so Pull and
    /// Push know where it went after.
    package static func pushArguments(remote: String, branch: String, setUpstream: Bool) -> [String] {
        ["push"] + (setUpstream ? ["--set-upstream"] : []) + [remote, branch]
    }

    private static func normalized(_ key: String) -> String {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return key.lowercased() }
        let section = parts[0].lowercased()
        let name = parts[parts.count - 1].lowercased()
        let middle = parts.dropFirst().dropLast().joined(separator: ".")
        return parts.count == 2 ? "\(section).\(name)" : "\(section).\(middle).\(name)"
    }
}
