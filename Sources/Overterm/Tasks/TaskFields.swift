import Foundation

/// What New Task's Branch and From say as they are typed (GIT-U14): a name
/// git would refuse, a branch that already exists (checked out as it is,
/// From unused), a From that names nothing — before Create, not after it.
/// Pure but for `refs` and `resolves`, which ask git through `Git.run`.
package enum TaskFields {
    /// What is wrong with `name` as a branch name, git's rules
    /// (`check-ref-format --branch`) said plainly; nil when it is fine or
    /// still empty. Create asks git itself too.
    package static func branchProblem(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("-") { return "A branch name can’t start with “-”." }
        if name == "@" || name == "HEAD" { return "“\(name)” is git’s own name, not a branch’s." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == " " }) {
            return "No spaces in a branch name — feat/my-change, for one."
        }
        if let bad = name.first(where: { "~^:?*[\\".contains($0) }) { return "A branch name can’t hold “\(bad)”." }
        if name.contains("..") { return "A branch name can’t hold “..”." }
        if name.contains("@{") { return "A branch name can’t hold “@{”." }
        if name.contains("//") || name.hasPrefix("/") || name.hasSuffix("/") { return "A “/” only goes between two parts of the name." }
        if name.hasSuffix(".") { return "A branch name can’t end with “.”." }
        for part in name.split(separator: "/") {
            if part.hasPrefix(".") { return "No part of a branch name can start with “.”." }
            if part.hasSuffix(".lock") { return "No part of a branch name can end with “.lock”." }
        }
        return nil
    }

    /// The line under Branch: its problem, else what happens to an
    /// existing one. `local`: the repository's branches.
    package static func branchNote(_ name: String, local: Set<String>) -> (text: String, isProblem: Bool)? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let problem = branchProblem(name) { return (problem, true) }
        guard !name.isEmpty, local.contains(name) else { return nil }
        return ("\(name) exists: it is checked out as it is, and From isn’t used.", false)
    }

    /// The line under From: nothing while it resolves or is being read.
    /// `resolves` nil: not read yet.
    package static func baseNote(_ base: String, resolves: Bool?, branchExists: Bool) -> (text: String, isProblem: Bool)? {
        guard !branchExists else { return nil }
        let base = base.trimmingCharacters(in: .whitespaces)
        if base.hasPrefix("-") { return ("From names a branch, a tag or a commit — not an option.", true) }
        guard resolves == false, !base.isEmpty else { return nil }
        return ("No branch, tag or commit is called “\(base)” here. Pick one from the menu, or fetch first.", true)
    }

    /// Whether `base` names a commit (a branch, a remote branch, a tag, a
    /// hash, `HEAD~2`). Never passed as an option.
    package static func resolveArguments(_ base: String) -> [String] { ["rev-parse", "--verify", "--quiet", "\(base)^{commit}"] }

    package static func resolves(_ base: String, in repo: URL) async -> Bool {
        let base = base.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return true }
        guard !base.hasPrefix("-") else { return false }
        return (try? await Git.run(resolveArguments(base), in: repo)) != nil
    }

    /// The local and remote branches From's menu offers, newest first —
    /// one `for-each-ref`, read once as the sheet opens.
    package static func refs(in repo: URL) async -> (local: [String], remote: [String]) {
        let branches = Refs.parse(branches: (try? await Git.run(Refs.branchArguments(), in: repo)) ?? "")
        return (branches.filter { !$0.isRemote }.map(\.name), branches.filter(\.isRemote).map(\.name))
    }
}
