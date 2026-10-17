import Foundation

/// One commit, opened: its message, and what it changed.
struct CommitDetail: Equatable {
    let commit: Commit
    let files: [ChangedFile]

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

/// What `git show` is asked for a single commit. Three small reads rather
/// than one clever one: the header, the file list, and the numbers — the
/// last two parse with `GitStatus`, which the changes pane already has.
enum CommitShow {
    /// The commit's own fields, in `CommitLog`'s format so one parser does
    /// both.
    static func headerArguments(_ sha: String) -> [String] {
        [
            "show", "--no-patch", "--no-show-signature", "-z", "--decorate=full",
            "--format=%x00%H%x00%h%x00%P%x00%an%x00%ae%x00%at%x00%ar%x00%D%x00%s%x00%b", sha,
        ]
    }

    /// A merge shows nothing by default — there is no one diff to show. So
    /// every read below is against the first parent (`-m --first-parent`),
    /// which is what "what did this merge bring in" means to a person.
    static func filesArguments(_ sha: String) -> [String] {
        ["show", "--format=", "--name-status", "-z", "-M", "-m", "--first-parent", "--no-show-signature", sha]
    }

    static func numstatArguments(_ sha: String) -> [String] {
        ["show", "--format=", "--numstat", "-z", "-M", "-m", "--first-parent", "--no-show-signature", sha]
    }

    /// One file's diff in this commit — the string `FileDiff(parsing:path:)`
    /// takes, exactly as the changes pane's own diffs arrive.
    static func diffArguments(_ sha: String, path: String, originalPath: String? = nil) -> [String] {
        [
            "show", "--no-color", "--format=", "-M", "-m", "--first-parent", "--no-show-signature", sha, "--",
        ] + [originalPath, path].compactMap { $0 }
    }
}
