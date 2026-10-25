import Foundation

/// SQL as text: where its statements are, what a statement does, and what
/// the caret is in the middle of writing. Pure — no database is asked.
enum SQLText {
    // MARK: Statements

    /// The statements of `text`, each one's range without its `;` and the
    /// space around it. A `;` inside a string, a quoted name, a comment or a
    /// PostgreSQL `$tag$…$tag$` body doesn't end one.
    static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        let length = ns.length
        var ranges: [NSRange] = []
        var start = 0
        var i = 0
        func add(_ end: Int) {
            let range = trimmed(NSRange(location: start, length: end - start), in: ns)
            if range.length > 0 { ranges.append(range) }
        }
        while i < length {
            let c = ns.character(at: i)
            switch c {
            case 0x27, 0x22, 0x60:  // ' " `
                i = skipQuoted(ns, from: i, quote: c)
                continue
            case 0x2D where i + 1 < length && ns.character(at: i + 1) == 0x2D:  // --
                i = skipLine(ns, from: i)
                continue
            case 0x23:  // # (MySQL's line comment)
                i = skipLine(ns, from: i)
                continue
            case 0x2F where i + 1 < length && ns.character(at: i + 1) == 0x2A:  // /*
                let close = ns.range(of: "*/", options: [], range: NSRange(location: i + 2, length: length - i - 2))
                i = close.location == NSNotFound ? length : NSMaxRange(close)
                continue
            case 0x24:  // $tag$ … $tag$
                if let end = skipDollarQuoted(ns, from: i) {
                    i = end
                    continue
                }
            case 0x3B:  // ;
                add(i)
                start = i + 1
            default:
                break
            }
            i += 1
        }
        add(length)
        return ranges
    }

    /// The statement the caret is in — or, between two, the one it just left.
    static func statement(at caret: Int, in text: String) -> NSRange? {
        let all = statements(in: text)
        if let inside = all.first(where: { caret >= $0.location && caret <= NSMaxRange($0) }) { return inside }
        return all.last { NSMaxRange($0) <= caret } ?? all.first
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let space = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool { Unicode.Scalar(ns.character(at: i)).map(space.contains) ?? false }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func skipQuoted(_ ns: NSString, from i: Int, quote: unichar) -> Int {
        var j = i + 1
        while j < ns.length {
            let c = ns.character(at: j)
            if c == 0x5C, quote != 0x60 {  // a backslash escape (MySQL's strings)
                j += 2
                continue
            }
            if c == quote {
                // A doubled quote is the quote itself.
                if j + 1 < ns.length, ns.character(at: j + 1) == quote {
                    j += 2
                    continue
                }
                return j + 1
            }
            j += 1
        }
        return ns.length
    }

    private static func skipLine(_ ns: NSString, from i: Int) -> Int {
        let newline = ns.range(of: "\n", options: [], range: NSRange(location: i, length: ns.length - i))
        return newline.location == NSNotFound ? ns.length : newline.location
    }

    private static func skipDollarQuoted(_ ns: NSString, from i: Int) -> Int? {
        var j = i + 1
        while j < ns.length {
            let c = ns.character(at: j)
            if c == 0x24 { break }
            guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F else { return nil }
            j += 1
        }
        guard j < ns.length else { return nil }
        let tag = ns.substring(with: NSRange(location: i, length: j - i + 1))
        let close = ns.range(of: tag, options: [], range: NSRange(location: j + 1, length: ns.length - j - 1))
        return close.location == NSNotFound ? ns.length : NSMaxRange(close)
    }

    // MARK: What a statement does

    /// Its first word, upper-cased, comments skipped: SELECT, INSERT, WITH…
    static func verb(of statement: String) -> String {
        var text = Substring(statement)
        while true {
            text = text.drop { $0.isWhitespace }
            if text.hasPrefix("--") || text.hasPrefix("#") {
                text = text.drop { $0 != "\n" }
            } else if text.hasPrefix("/*"), let close = text.range(of: "*/") {
                text = text[close.upperBound...]
            } else {
                break
            }
        }
        return String(text.prefix { $0.isLetter }).uppercased()
    }

    /// Statements that only read. Everything else is refused on a read-only
    /// connection. WITH counts as a read: a CTE that writes is rare, and the
    /// database's own read-only mode (set where it has one) catches it.
    static func onlyReads(_ statement: String) -> Bool {
        ["SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "VALUES", "TABLE", "PRAGMA"].contains(verb(of: statement))
    }

    /// Why a statement should be asked about first; nil when it needn't be.
    static func danger(of statement: String) -> String? {
        let verb = verb(of: statement)
        let upper = stripped(statement).uppercased()
        switch verb {
        case "DROP": return "It drops \(upper.split(separator: " ").dropFirst().prefix(2).joined(separator: " ").lowercased())."
        case "TRUNCATE": return "It empties the table."
        case "DELETE", "UPDATE":
            return upper.range(of: #"\bWHERE\b"#, options: .regularExpression) == nil
                ? "It has no WHERE: every row of the table is \(verb == "DELETE" ? "deleted" : "changed")."
                : nil
        default: return nil
        }
    }

    /// The statement with its strings and comments blanked — so a WHERE in a
    /// string isn't taken for one.
    static func stripped(_ statement: String) -> String {
        let ns = statement as NSString
        var out = ""
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x27 || c == 0x22 {
                i = skipQuoted(ns, from: i, quote: c)
                out += " ''"
                continue
            }
            if c == 0x2D, i + 1 < ns.length, ns.character(at: i + 1) == 0x2D {
                i = skipLine(ns, from: i)
                continue
            }
            if c == 0x2F, i + 1 < ns.length, ns.character(at: i + 1) == 0x2A {
                let close = ns.range(of: "*/", options: [], range: NSRange(location: i + 2, length: ns.length - i - 2))
                i = close.location == NSNotFound ? ns.length : NSMaxRange(close)
                continue
            }
            out += String(utf16CodeUnits: [c], count: 1)
            i += 1
        }
        return out
    }

    // MARK: Completion

    /// What the caret is in the middle of writing.
    enum CompletionContext: Equatable {
        /// A table (or view) — after FROM, JOIN, INTO, UPDATE, TABLE.
        case table(schema: String?, prefix: String)
        /// A column of `table` — after `alias.` or `table.`.
        case qualifiedColumn(table: String, prefix: String)
        /// Anything: a keyword, a column of the statement's tables, a table.
        case any(prefix: String)
    }

    /// From the statement's text up to the caret.
    static func completionContext(before text: String) -> CompletionContext {
        let ns = text as NSString
        var start = ns.length
        func isWord(_ c: unichar) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
        }
        while start > 0, isWord(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(from: start)
        // `x.` before the word: a qualified name.
        if start > 0, ns.character(at: start - 1) == 0x2E {
            var qualifierStart = start - 1
            while qualifierStart > 0,
                isWord(ns.character(at: qualifierStart - 1)) || ns.character(at: qualifierStart - 1) == 0x22
                    || ns.character(at: qualifierStart - 1) == 0x60
            {
                qualifierStart -= 1
            }
            let qualifier = unquote(ns.substring(with: NSRange(location: qualifierStart, length: start - 1 - qualifierStart)))
            let before = ns.substring(to: qualifierStart)
            if lastKeyword(before).map(tableKeywords.contains) == true { return .table(schema: qualifier, prefix: prefix) }
            return .qualifiedColumn(table: qualifier, prefix: prefix)
        }
        if lastKeyword(ns.substring(to: start)).map(tableKeywords.contains) == true { return .table(schema: nil, prefix: prefix) }
        return .any(prefix: prefix)
    }

    static let tableKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE", "DESC"]

    /// The word before the caret's word, upper-cased; nil when what is
    /// before it isn't a word (a comma, a parenthesis).
    private static func lastKeyword(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = trimmed.reversed().prefix { $0.isLetter }
        return word.isEmpty ? nil : String(word.reversed()).uppercased()
    }

    /// The tables a statement names, with what they are called in it:
    /// `FROM orders o JOIN public.users AS u` → o: orders, u: public.users.
    static func tables(in statement: String) -> [(name: String, schema: String?, alias: String?)] {
        let text = stripped(statement)
        let pattern =
            #"(?i)\b(?:FROM|JOIN|UPDATE|INTO)\s+((?:[`"]?[\w$]+[`"]?\.)?[`"]?[\w$]+[`"]?)(?:\s+(?:AS\s+)?([A-Za-z_][\w$]*))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let reserved: Set<String> = [
            "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON", "USING", "GROUP", "ORDER", "LIMIT", "SET",
            "VALUES", "SELECT", "UNION", "HAVING", "WINDOW", "OFFSET", "NATURAL", "LATERAL", "AS",
        ]
        var found: [(String, String?, String?)] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let qualified = ns.substring(with: match.range(at: 1))
            let parts = qualified.split(separator: ".").map { unquote(String($0)) }
            var alias = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            if let candidate = alias, reserved.contains(candidate.uppercased()) { alias = nil }
            found.append((parts.last ?? qualified, parts.count > 1 ? parts.first : nil, alias))
        }
        return found
    }

    static func unquote(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
    }

    /// The keywords completion offers, the common ones.
    static let keywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "JOIN", "LEFT JOIN",
        "RIGHT JOIN", "INNER JOIN", "FULL JOIN", "CROSS JOIN", "ON", "USING", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET",
        "DISTINCT", "AS", "CASE", "WHEN", "THEN", "ELSE", "END", "UNION", "UNION ALL", "INSERT INTO", "VALUES", "UPDATE", "SET",
        "DELETE FROM", "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "WITH", "RETURNING", "COUNT", "SUM", "AVG", "MIN", "MAX",
        "COALESCE", "CAST", "NOW()", "CURRENT_DATE", "ASC", "DESC", "TRUE", "FALSE", "EXPLAIN", "DESCRIBE", "SHOW TABLES",
    ]
}

extension SQLText {
    /// Whether an agent's statement only reads, judged more strictly than
    /// a person's: a WITH that hides an INSERT, UPDATE, DELETE or MERGE,
    /// and SELECT … INTO (a new table, in PostgreSQL), write. Text can't
    /// see what a function does — a read-only connection is the database's
    /// own guarantee.
    static func agentReads(_ statement: String) -> Bool {
        guard onlyReads(statement) else { return false }
        let upper = stripped(statement).uppercased()
        let writes = #"\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COPY|CALL)\b"#
        if upper.range(of: writes, options: .regularExpression) != nil { return false }
        if verb(of: statement) == "SELECT", upper.range(of: #"\bINTO\b"#, options: .regularExpression) != nil { return false }
        return true
    }
}
