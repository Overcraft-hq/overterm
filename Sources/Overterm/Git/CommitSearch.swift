import Foundation

/// Overgit's commit search, as GitLens's: words in the message, and
/// filters — `author:`, `path:` (or `file:`), `code:` (the change added or
/// removed it), `since:`, `branch:` (or `ref:`) — read from one query.
/// Pure: the query in, `git log`'s arguments (and a local match) out.
struct CommitSearch: Equatable {
    var words: [String] = []
    var author: String?
    var path: String?
    var code: String?
    var since: String?
    var ref: String?

    /// `fix login author:ali path:src/auth since:2.weeks` — a value with
    /// spaces in quotes: `author:"Ali Veli"`.
    init(_ query: String) {
        for token in Self.tokens(query) {
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = token[..<colon].lowercased()
                let value = String(token[token.index(after: colon)...])
                guard !value.isEmpty else { continue }
                switch key {
                case "author", "by": author = value
                case "path", "file", "in": path = value
                case "code", "change": code = value
                case "since", "after": since = value
                case "branch", "ref", "on": ref = value
                default: words.append(token)
                }
            } else {
                words.append(token)
            }
        }
    }

    var isEmpty: Bool { words.isEmpty && author == nil && path == nil && code == nil && since == nil && ref == nil }

    /// Only words that could be a commit's hash: a hash search, too.
    var possibleSHA: String? {
        guard words.count == 1, let word = words.first, word.count >= 4, word.count <= 40,
            word.allSatisfy(\.isHexDigit)
        else { return nil }
        return word.lowercased()
    }

    /// `git log` for it: every word in the message (case aside), the filters
    /// as git's own options, the newest `limit`.
    func arguments(limit: Int, allRefs: Bool) -> [String] {
        var arguments = [
            "log", "-z", "--no-show-signature", "--date-order", "--decorate=full", "--max-count=\(max(1, limit))",
            "--format=%x00%H%x00%h%x00%P%x00%an%x00%ae%x00%at%x00%ar%x00%D%x00%s%x00%b", "-i",
        ]
        if !words.isEmpty, possibleSHA == nil {
            arguments.append("--all-match")
            arguments += words.map { "--grep=\($0)" }
        }
        if let author { arguments.append("--author=\(author)") }
        if let code { arguments.append("-S\(code)") }
        if let since { arguments.append("--since=\(since)") }
        if let ref {
            arguments.append(ref)
        } else {
            arguments.append(allRefs ? "--all" : "HEAD")
        }
        arguments.append("--")
        if let path { arguments.append(path) }
        return arguments
    }

    /// Whether a commit already read answers it — the list filters as you
    /// type, before git does.
    func matches(_ commit: Commit) -> Bool {
        if let sha = possibleSHA, commit.sha.hasPrefix(sha) { return true }
        if let author, !(commit.author.localizedCaseInsensitiveContains(author) || commit.authorEmail.localizedCaseInsensitiveContains(author)) {
            return false
        }
        // What only git can tell (files, a change's text, a ref) isn't
        // answered here.
        if path != nil || code != nil || since != nil || ref != nil { return false }
        let haystack = commit.subject + "\n" + commit.body + "\n" + commit.author
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Words, with "quoted values" kept whole.
    static func tokens(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
