import Foundation

/// What a review is of — and, pure, the pieces every review reads with:
/// a whole patch cut into files, and a file's diff laid out side by side.
enum ReviewSource: Hashable, Sendable {
    /// The checkout's branch since it left `base`, with what isn't committed
    /// yet — the changes pane's Branch: `git diff <merge-base>` and the
    /// untracked files. `branch` is only its name, for the title.
    case branch(mergeBase: String, base: String, branch: String)
    /// What `head` has that `base` doesn't: `base...head`, as a pull request
    /// reads — against their merge base.
    case range(base: String, head: String)
    /// Commits `from` through `to`, oldest first; one commit when they are
    /// the same. Against `from`'s first parent: a merge shows what it
    /// brought in.
    case commits(from: String, to: String)
    /// A pull request on GitHub, by `gh pr diff` — the branch need not be here.
    case pullRequest(number: Int)

    /// The tab's name.
    var title: String {
        switch self {
        case .branch(_, _, let branch): branch
        case .range(let base, let head): "\(Self.short(base))…\(Self.short(head))"
        case .commits(let from, let to): from == to ? Self.short(from) : "\(Self.short(from))…\(Self.short(to))"
        case .pullRequest(let number): "#\(number)"
        }
    }

    /// Under the title: what it is compared with.
    var subtitle: String {
        switch self {
        case .branch(_, let base, let branch): "\(branch) against \(base), with uncommitted changes"
        case .range(let base, let head): "What \(head) has that \(base) doesn't"
        case .commits(let from, let to): from == to ? "One commit" : "Commits \(Self.short(from)) through \(Self.short(to))"
        case .pullRequest(let number): "Pull request #\(number)"
        }
    }

    var symbol: String {
        switch self {
        case .branch, .range: "arrow.triangle.branch"
        case .commits: "smallcircle.filled.circle"
        case .pullRequest: "arrow.triangle.pull"
        }
    }

    /// A SHA is shortened; a branch's name is kept.
    static func short(_ ref: String) -> String {
        ref.count == 40 && ref.allSatisfy(\.isHexDigit) ? String(ref.prefix(7)) : ref
    }
}

/// A whole `git diff` (or `gh pr diff`) cut into its files: each file's own
/// patch, and what its header says it is.
enum ReviewPatch {
    struct File: Equatable {
        let file: ChangedFile
        let patch: String
    }

    static func split(_ diff: String) -> [File] {
        var files: [File] = []
        var current: [Substring] = []
        func finish() {
            guard !current.isEmpty else { return }
            if let file = describe(current) { files.append(File(file: file, patch: current.joined(separator: "\n") + "\n")) }
            current = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { finish() }
            if line.hasPrefix("diff --git ") || !current.isEmpty { current.append(line) }
        }
        while current.last?.isEmpty == true { current.removeLast() }
        finish()
        return files
    }

    /// What one file's header says: its path (and where it came from), how
    /// it changed, and its lines added and removed — nil for a binary file's.
    static func describe(_ lines: [Substring]) -> ChangedFile? {
        guard let first = lines.first else { return nil }
        var kind = ChangedFile.Kind.modified
        var path: String?
        var original: String?
        var oldPath: String?
        var added = 0
        var removed = 0
        var binary = false
        var inHunk = false
        for line in lines.dropFirst() {
            if inHunk {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                continue
            }
            if line.hasPrefix("@@") {
                inHunk = true
            } else if line.hasPrefix("new file mode") {
                kind = .added
            } else if line.hasPrefix("deleted file mode") {
                kind = .deleted
            } else if line.hasPrefix("rename from ") {
                kind = .renamed
                original = unquote(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                path = unquote(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy to ") {
                kind = .added
                path = unquote(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("+++ ") {
                let name = line.dropFirst(4)
                if name != "/dev/null" { path = path ?? unquote(name.hasPrefix("b/") ? name.dropFirst(2) : name) }
            } else if line.hasPrefix("--- ") {
                let name = line.dropFirst(4)
                if name != "/dev/null" { oldPath = unquote(name.hasPrefix("a/") ? name.dropFirst(2) : name) }
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                binary = true
            }
        }
        // A deleted file's path is its old one; one without ---/+++ (binary,
        // a mode change) is named by `diff --git a/x b/x`.
        guard let name = path ?? oldPath ?? headerPath(first) else { return nil }
        return ChangedFile(
            path: name, originalPath: original, kind: kind, isStaged: false, hasUnstaged: false, added: binary ? nil : added,
            removed: binary ? nil : removed)
    }

    /// `diff --git a/x b/x` → x. Only certain when both sides are the same
    /// name, which is when nothing else in the header names the file.
    private static func headerPath(_ line: Substring) -> String? {
        let rest = line.dropFirst("diff --git ".count)
        if rest.hasPrefix("\"") {
            // Quoted: "a/x y" "b/x y".
            let parts = rest.split(separator: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let last = parts.last, last.hasPrefix("b/") else { return nil }
            return String(last.dropFirst(2))
        }
        guard rest.hasPrefix("a/") else { return nil }
        let body = rest.dropFirst(2)
        // "x b/x": the name is the first half when both halves agree.
        let length = (body.count - 3) / 2
        guard length > 0, body.count == length * 2 + 3 else { return nil }
        let a = body.prefix(length)
        let b = body.suffix(length)
        return body.dropFirst(length).hasPrefix(" b/") && a == b ? String(a) : nil
    }

    /// git quotes a name with unusual characters in C style: "a/caf\303\251".
    static func unquote(_ name: Substring) -> String {
        var text = String(name)
        if let tab = text.firstIndex(of: "\t") { text = String(text[..<tab]) }
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return text }
        var bytes: [UInt8] = []
        var chars = Array(text.dropFirst().dropLast().utf8)[...]
        while let byte = chars.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = chars.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = chars.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                    chars.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        var unquoted = String(decoding: bytes, as: UTF8.self)
        for prefix in ["a/", "b/"] where unquoted.hasPrefix(prefix) {
            unquoted.removeFirst(2)
            break
        }
        return unquoted
    }
}

/// A file's diff side by side: the old file on the left, the new on the
/// right, a line of each per row. Context is on both sides; a run of
/// removed lines and the added run right after it pair up in order — as
/// `DiffHighlight.pairs` pairs them for what changed inside a line — and
/// the longer run's rest faces an empty side.
enum SplitDiff {
    struct Row: Identifiable, Equatable {
        /// The first line's id: rows keep their identity across a reload.
        let id: Int
        var left: DiffLine?
        var right: DiffLine?
        /// A hunk's header or a note ("\ No newline…"), across both sides.
        var full: DiffLine?
    }

    static func rows(_ lines: [DiffLine]) -> [Row] {
        var rows: [Row] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                rows.append(Row(id: (left ?? right)!.id, left: left, right: right))
            }
            removed = []
            added = []
        }
        for line in lines {
            switch line.kind {
            case .removed:
                // A removal after additions starts a new change.
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            case .context:
                flush()
                rows.append(Row(id: line.id, left: line, right: line))
            case .hunk, .meta:
                flush()
                rows.append(Row(id: line.id, full: line))
            }
        }
        flush()
        return rows
    }
}
