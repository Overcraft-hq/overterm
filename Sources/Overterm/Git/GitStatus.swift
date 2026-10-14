import Foundation

/// One changed path in a worktree, from `git status --porcelain=v1 -z`.
struct ChangedFile: Identifiable, Hashable {
    enum Kind: Hashable {
        case modified, added, deleted, renamed, untracked, conflicted, typeChanged
    }

    let path: String
    /// For renames and copies: where it came from.
    let originalPath: String?
    let kind: Kind
    /// X of XY: the change is (at least partly) staged.
    let isStaged: Bool
    /// Y of XY: there are unstaged changes too (or it is untracked).
    let hasUnstaged: Bool
    var added: Int?
    var removed: Int?

    var id: String { path }

    enum StageState { case none, partial, full }

    /// For the stage checkbox: nothing staged, some, or all of it.
    var stageState: StageState {
        guard isStaged else { return .none }
        return hasUnstaged ? .partial : .full
    }

    /// The single letter shown in the list.
    var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        case .typeChanged: "T"
        }
    }
}

enum GitStatus {
    /// Parses `git status --porcelain=v1 -z`: NUL-separated `XY path`
    /// records; a rename/copy record is followed by its original path.
    static func parse(porcelainZ output: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let record = fields.popFirst() {
            guard record.count > 3 else { continue }
            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let path = String(record.dropFirst(3))
            var original: String?
            if x == "R" || x == "C" { original = fields.popFirst() }

            let kind: ChangedFile.Kind
            switch (x, y) {
            case ("?", "?"): kind = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): kind = .conflicted
            case ("R", _), ("C", _): kind = .renamed
            case ("A", _): kind = .added
            case ("D", _), (_, "D"): kind = .deleted
            case ("T", _), (_, "T"): kind = .typeChanged
            default: kind = .modified
            }
            let staged = x != " " && x != "?"
            files.append(
                ChangedFile(path: path, originalPath: original, kind: kind, isStaged: staged, hasUnstaged: y != " "))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Parses `git diff --name-status -z -M <base>`: NUL-separated records of
    /// a status letter and a path; a rename or copy (`R100`, `C075`: the
    /// letter and a similarity) has two paths, the original first. Against a
    /// commit there is no index, so nothing is staged.
    static func parse(nameStatusZ output: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let status = fields.popFirst() {
            guard let letter = status.first else { continue }
            let original = letter == "R" || letter == "C" ? fields.popFirst() : nil
            guard let path = fields.popFirst(), !path.isEmpty else { continue }
            let kind: ChangedFile.Kind
            switch letter {
            case "A": kind = .added
            case "D": kind = .deleted
            case "R": kind = .renamed
            // A copy is a new file; the one it was copied from stays.
            case "C": kind = .added
            case "T": kind = .typeChanged
            case "U": kind = .conflicted
            default: kind = .modified
            }
            files.append(ChangedFile(path: path, originalPath: original, kind: kind, isStaged: false, hasUnstaged: false))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Parses `git diff --numstat -z HEAD` into path → (added, removed).
    /// Binary files report `-`, which becomes nil. A rename is
    /// `a\tb\t\0old\0new\0` — keyed by the new path.
    static func parse(numstatZ output: String) -> [String: (added: Int?, removed: Int?)] {
        var result: [String: (Int?, Int?)] = [:]
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let record = fields.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let added = Int(parts[0])
            let removed = Int(parts[1])
            var path = String(parts[2])
            if path.isEmpty {
                // Rename: the two paths follow as their own fields.
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            if !path.isEmpty { result[path] = (added, removed) }
        }
        return result
    }
}
