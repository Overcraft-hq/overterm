import Foundation

/// A notes table: a ```dataview block, as Obsidian's Dataview writes it —
/// the part of its language a table over the vault's properties needs —
/// read and run over the index. The same block reads in Obsidian with the
/// plugin. Pure.
///
///     TABLE [WITHOUT ID] status, due AS "Due", file.folder
///     FROM "Projects" AND #work
///     WHERE status = "open" AND contains(tags, "q4")
///     SORT due ASC, file.name DESC
///     LIMIT 20
///
/// `LIST [field]` lists the notes. Fields are a note's properties (by name,
/// any case) and `file.name`, `file.folder`, `file.path`, `file.tags`,
/// `file.mtime`. FROM takes folders in quotes and tags, joined by AND or OR.
/// WHERE compares with = != < <= > >=, `contains(field, "x")`, a field alone
/// (set and not false), `!`, AND, OR and parentheses.
package struct NoteQuery: Equatable, Sendable {
    package enum Mode: Equatable, Sendable { case table, list }

    package struct Field: Equatable, Sendable {
        package var name: String
        package var title: String
    }

    package indirect enum Source: Equatable, Sendable {
        case folder(String)
        case tag(String)
        case all
        case and(Source, Source)
        case or(Source, Source)
    }

    package indirect enum Expression: Equatable, Sendable {
        case field(String)
        case text(String)
        case number(Double)
        case bool(Bool)
        case null
        case compare(Expression, String, Expression)
        case contains(Expression, Expression)
        case not(Expression)
        case and(Expression, Expression)
        case or(Expression, Expression)
    }

    package var mode: Mode
    package var withoutID = false
    package var fields: [Field] = []
    package var source: Source = .all
    package var filter: Expression?
    package var sort: [(field: String, ascending: Bool)] = []
    package var limit: Int?

    package static func == (a: NoteQuery, b: NoteQuery) -> Bool {
        a.mode == b.mode && a.withoutID == b.withoutID && a.fields == b.fields && a.source == b.source && a.filter == b.filter
            && a.sort.map { "\($0.field)\($0.ascending)" } == b.sort.map { "\($0.field)\($0.ascending)" } && a.limit == b.limit
    }

    /// What a table shows: its columns, and each row's cells — the note's own
    /// cell first, its path to open.
    package struct Table: Equatable, Sendable {
        package struct Cell: Equatable, Sendable {
            package var text: String
            package var path: String?
        }

        package var columns: [String] = []
        package var rows: [[Cell]] = []
        package var error: String?
        /// More notes matched than are shown.
        package var truncated = false
    }

    package struct Problem: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    /// Rows a table shows at most, whatever its LIMIT.
    package static let maxRows = 500

    // MARK: Reading

    private enum Token: Equatable {
        case word(String)
        case string(String)
        case number(Double)
        case tag(String)
        case symbol(String)
    }

    private static func tokens(_ text: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                var value = ""
                i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i])
                    i += 1
                }
                guard i < chars.count else { throw Problem(message: "A quoted text isn't closed.") }
                i += 1
                out.append(.string(value))
                continue
            }
            if c == "#" {
                var tag = ""
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_-/".contains(chars[i]) {
                    tag.append(chars[i])
                    i += 1
                }
                out.append(.tag(tag))
                continue
            }
            if c.isNumber {
                var number = String(c)
                i += 1
                while i < chars.count, chars[i].isNumber || chars[i] == "." {
                    number.append(chars[i])
                    i += 1
                }
                // A date or a version is text: 2026-11-28.
                if i < chars.count, chars[i] == "-" || chars[i].isLetter {
                    while i < chars.count, !chars[i].isWhitespace, !",()".contains(chars[i]) {
                        number.append(chars[i])
                        i += 1
                    }
                    out.append(.word(number))
                } else {
                    out.append(Double(number).map(Token.number) ?? .word(number))
                }
                continue
            }
            if c.isLetter || c == "_" {
                var word = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_.-".contains(chars[i]) {
                    word.append(chars[i])
                    i += 1
                }
                out.append(.word(word))
                continue
            }
            let two = i + 1 < chars.count ? String([c, chars[i + 1]]) : ""
            if ["!=", "<=", ">=", "=="].contains(two) {
                out.append(.symbol(two == "==" ? "=" : two))
                i += 2
                continue
            }
            if "=<>!(),".contains(c) {
                out.append(.symbol(String(c)))
                i += 1
                continue
            }
            throw Problem(message: "“\(c)” isn't understood here.")
        }
        return out
    }

    private struct Reader {
        var tokens: [Token]
        var at = 0
        /// How deep WHERE's parentheses and `!` go: a note's ten thousand
        /// `(` would overflow the stack.
        var depth = 0

        var peek: Token? { at < tokens.count ? tokens[at] : nil }
        mutating func next() -> Token? {
            defer { at += 1 }
            return peek
        }
        func isKeyword(_ word: String) -> Bool {
            if case .word(let w)? = peek { return w.uppercased() == word }
            return false
        }
        mutating func take(_ word: String) -> Bool {
            guard isKeyword(word) else { return false }
            at += 1
            return true
        }
        mutating func take(symbol: String) -> Bool {
            guard peek == .symbol(symbol) else { return false }
            at += 1
            return true
        }
        var atClause: Bool { ["FROM", "WHERE", "SORT", "LIMIT"].contains { isKeyword($0) } }
    }

    package static func parse(_ text: String) throws -> NoteQuery {
        var r = Reader(tokens: try tokens(text))
        var query: NoteQuery
        if r.take("TABLE") {
            query = NoteQuery(mode: .table)
            if r.isKeyword("WITHOUT") {
                r.at += 1
                guard r.take("ID") else { throw Problem(message: "WITHOUT is followed by ID.") }
                query.withoutID = true
            }
            while r.peek != nil, !r.atClause {
                guard case .word(let name)? = r.next() else { throw Problem(message: "TABLE lists fields: TABLE status, due") }
                var title = name
                if r.take("AS") {
                    switch r.next() {
                    case .string(let t)?, .word(let t)?: title = t
                    default: throw Problem(message: "AS takes the column's title.")
                    }
                }
                query.fields.append(Field(name: name, title: title))
                if !r.take(symbol: ",") { break }
            }
        } else if r.take("LIST") {
            query = NoteQuery(mode: .list)
            if case .word(let name)? = r.peek, !r.atClause {
                r.at += 1
                query.fields = [Field(name: name, title: name)]
            }
        } else {
            throw Problem(message: "A notes table starts with TABLE or LIST.")
        }
        while let token = r.peek {
            if r.take("FROM") {
                query.source = try source(&r)
            } else if r.take("WHERE") {
                query.filter = try orExpression(&r)
            } else if r.take("SORT") {
                repeat {
                    guard case .word(let field)? = r.next() else { throw Problem(message: "SORT takes a field: SORT due ASC") }
                    var ascending = true
                    if r.take("DESC") || r.take("DESCENDING") { ascending = false } else { _ = r.take("ASC") || r.take("ASCENDING") }
                    query.sort.append((field, ascending))
                } while r.take(symbol: ",")
            } else if r.take("LIMIT") {
                guard case .number(let n)? = r.next(), n >= 0, n.isFinite else { throw Problem(message: "LIMIT takes a number.") }
                // Past what a table shows, it is what a table shows: Int(1e20) would trap.
                query.limit = n >= Double(maxRows) ? maxRows : Int(n)
            } else {
                throw Problem(message: "“\(describe(token))” isn't understood here: FROM, WHERE, SORT or LIMIT.")
            }
        }
        return query
    }

    private static func describe(_ token: Token) -> String {
        switch token {
        case .word(let w): w
        case .string(let s): "\"\(s)\""
        case .number(let n): "\(n)"
        case .tag(let t): "#\(t)"
        case .symbol(let s): s
        }
    }

    private static func source(_ r: inout Reader) throws -> Source {
        func one() throws -> Source {
            switch r.next() {
            case .string(let folder)?: return .folder(folder)
            case .tag(let tag)?: return .tag(tag)
            default: throw Problem(message: "FROM takes a folder in quotes or a #tag.")
            }
        }
        var left = try one()
        while true {
            if r.take("AND") {
                left = .and(left, try one())
            } else if r.take("OR") {
                left = .or(left, try one())
            } else {
                return left
            }
        }
    }

    private static func orExpression(_ r: inout Reader) throws -> Expression {
        var left = try andExpression(&r)
        while r.take("OR") { left = .or(left, try andExpression(&r)) }
        return left
    }

    private static func andExpression(_ r: inout Reader) throws -> Expression {
        var left = try unary(&r)
        while r.take("AND") { left = .and(left, try unary(&r)) }
        return left
    }

    private static func unary(_ r: inout Reader) throws -> Expression {
        r.depth += 1
        defer { r.depth -= 1 }
        guard r.depth <= 64 else { throw Problem(message: "WHERE nests too deep.") }
        if r.take(symbol: "!") { return .not(try unary(&r)) }
        if r.take(symbol: "(") {
            let inner = try orExpression(&r)
            guard r.take(symbol: ")") else { throw Problem(message: "A parenthesis isn't closed.") }
            return inner
        }
        let left = try operand(&r)
        for op in ["=", "!=", "<=", ">=", "<", ">"] where r.take(symbol: op) {
            return .compare(left, op, try operand(&r))
        }
        return left
    }

    private static func operand(_ r: inout Reader) throws -> Expression {
        switch r.next() {
        case .string(let s)?: return .text(s)
        case .number(let n)?: return .number(n)
        case .tag(let t)?: return .text("#" + t)
        case .word(let w)?:
            switch w.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "contains":
                guard r.take(symbol: "(") else { return .field(w) }
                let haystack = try operand(&r)
                guard r.take(symbol: ",") else { throw Problem(message: "contains takes two: contains(tags, \"work\")") }
                let needle = try operand(&r)
                guard r.take(symbol: ")") else { throw Problem(message: "contains( isn't closed.") }
                return .contains(haystack, needle)
            default:
                // An unquoted date compares as its text.
                return w.first?.isNumber == true ? .text(w) : .field(w)
            }
        default: throw Problem(message: "WHERE compares a field with a value: WHERE status = \"open\"")
        }
    }

    // MARK: Running

    /// A value as the table and WHERE see it.
    private enum Value: Equatable {
        case text(String)
        case number(Double)
        case bool(Bool)
        case list([String])
        case null

        var display: String {
            switch self {
            case .text(let t): t
            case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
            case .bool(let b): b ? "true" : "false"
            case .list(let items): items.joined(separator: ", ")
            case .null: ""
            }
        }

        var truthy: Bool {
            switch self {
            case .null: false
            case .bool(let b): b
            case .text(let t): !t.isEmpty
            case .list(let l): !l.isEmpty
            case .number(let n): n != 0
            }
        }
    }

    private static let mtime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func value(_ field: String, path: String, entry: NotesIndex.Entry) -> Value {
        let doc = entry.document
        switch field.lowercased() {
        case "file.name": return .text(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        case "file.folder": return .text((path as NSString).deletingLastPathComponent)
        case "file.path": return .text(path)
        case "file.tags": return .list(doc.allTags.map { "#" + $0 })
        case "file.mtime": return .text(mtime.string(from: entry.modified))
        default:
            let key = doc.properties.keys.first { $0.lowercased() == field.lowercased() }
            switch key.flatMap({ doc.properties[$0] }) {
            case .text(let t)?: return .text(t)
            case .number(let n)?: return .number(n)
            case .bool(let b)?: return .bool(b)
            case .list(let l)?: return .list(l)
            case .null?, nil: return .null
            }
        }
    }

    private static func matches(_ source: Source, path: String, entry: NotesIndex.Entry) -> Bool {
        switch source {
        case .all: return true
        case .folder(let folder):
            let f = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return f.isEmpty || path.hasPrefix(f + "/") || path == f || path == f + ".md"
        case .tag(let tag):
            let t = tag.lowercased()
            return entry.document.allTags.contains { $0.lowercased() == t || $0.lowercased().hasPrefix(t + "/") }
        case .and(let a, let b): return matches(a, path: path, entry: entry) && matches(b, path: path, entry: entry)
        case .or(let a, let b): return matches(a, path: path, entry: entry) || matches(b, path: path, entry: entry)
        }
    }

    private static func evaluate(_ expression: Expression, path: String, entry: NotesIndex.Entry) -> Value {
        func eval(_ e: Expression) -> Value { evaluate(e, path: path, entry: entry) }
        switch expression {
        case .field(let name): return value(name, path: path, entry: entry)
        case .text(let t): return .text(t)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .null: return .null
        case .not(let inner): return .bool(!eval(inner).truthy)
        case .and(let a, let b): return .bool(eval(a).truthy && eval(b).truthy)
        case .or(let a, let b): return .bool(eval(a).truthy || eval(b).truthy)
        case .contains(let haystack, let needle):
            let n = eval(needle).display.lowercased()
            switch eval(haystack) {
            case .list(let items): return .bool(items.contains { $0.lowercased() == n || $0.lowercased() == "#" + n || "#" + $0.lowercased() == n })
            case let other: return .bool(other.display.lowercased().contains(n))
            }
        case .compare(let a, let op, let b):
            let order = compare(eval(a), eval(b))
            switch op {
            case "=": return .bool(order == .orderedSame)
            case "!=": return .bool(order != .orderedSame)
            case "<": return .bool(order == .orderedAscending)
            case "<=": return .bool(order != .orderedDescending)
            case ">": return .bool(order == .orderedDescending)
            default: return .bool(order != .orderedAscending)
            }
        }
    }

    /// Numbers as numbers — a number written as text too — the rest as
    /// text, as Finder orders names; nothing sorts last.
    private static func compare(_ a: Value, _ b: Value) -> ComparisonResult {
        func number(_ value: Value) -> Double? {
            switch value {
            case .number(let n): n
            case .text(let t): Double(t)
            default: nil
            }
        }
        switch (a, b) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedDescending
        case (_, .null): return .orderedAscending
        default:
            if let x = number(a), let y = number(b) { return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending }
            return a.display.localizedStandardCompare(b.display)
        }
    }

    /// The table over `index`.
    package func run(over index: NotesIndex) -> Table {
        var matched: [(String, NotesIndex.Entry)] = []
        for path in index.paths {
            guard let entry = index.notes[path], NoteQuery.matches(source, path: path, entry: entry) else { continue }
            if let filter, !NoteQuery.evaluate(filter, path: path, entry: entry).truthy { continue }
            matched.append((path, entry))
        }
        if !sort.isEmpty {
            matched.sort { a, b in
                for key in sort {
                    let order = NoteQuery.compare(NoteQuery.value(key.field, path: a.0, entry: a.1), NoteQuery.value(key.field, path: b.0, entry: b.1))
                    if order == .orderedSame { continue }
                    // Nothing sorts last whichever way.
                    let aMissing = NoteQuery.value(key.field, path: a.0, entry: a.1) == .null
                    let bMissing = NoteQuery.value(key.field, path: b.0, entry: b.1) == .null
                    if aMissing != bMissing { return bMissing }
                    return key.ascending ? order == .orderedAscending : order == .orderedDescending
                }
                return a.0.localizedStandardCompare(b.0) == .orderedAscending
            }
        }
        var table = Table()
        let cap = min(limit ?? NoteQuery.maxRows, NoteQuery.maxRows)
        table.truncated = matched.count > cap && cap == NoteQuery.maxRows
        let shown = matched.prefix(cap)
        let idColumn = !(mode == .table && withoutID)
        switch mode {
        case .table:
            table.columns = (idColumn ? ["File"] : []) + fields.map(\.title)
        case .list:
            table.columns = ["File"] + fields.map(\.title)
        }
        table.rows = shown.map { path, entry in
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var row: [Table.Cell] = idColumn ? [Table.Cell(text: name, path: path)] : []
            row += fields.map { Table.Cell(text: NoteQuery.value($0.name, path: path, entry: entry).display) }
            return row
        }
        return table
    }

    /// A block's text run: its table, or why there is none.
    package static func table(for source: String, over index: NotesIndex) -> Table {
        do {
            return try parse(source).run(over: index)
        } catch {
            return Table(error: error.localizedDescription)
        }
    }

    /// The ```dataview fences of a note's body: each one's line (zero-based,
    /// in `body`) and its text.
    package static func blocks(in body: String) -> [(line: Int, source: String)] {
        let lines = body.components(separatedBy: "\n")
        var found: [(Int, String)] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let fence = trimmed.prefix { $0 == "`" || $0 == "~" }
            if fence.count >= 3, trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).lowercased() == "dataview" {
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix(String(fence)) { end += 1 }
                found.append((index, lines[(index + 1)..<min(end, lines.count)].joined(separator: "\n")))
                index = end + 1
            } else if fence.count >= 3 {
                // Another fence: skipped whole, a dataview word inside it is code.
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix(String(fence)) { end += 1 }
                index = end + 1
            } else {
                index += 1
            }
        }
        return found.map { (line: $0.0, source: $0.1) }
    }
}
