import Foundation

/// How an engine writes names and values in the statements Overterm makes
/// for it (rows edited, users changed). Every name is quoted and every
/// value a literal — a name or a value never ends the statement it is in.
struct SQLDialect: Equatable, Sendable {
    enum Engine: Equatable, Sendable { case postgres, redshift, mysql, mariadb, sqlite }

    var engine: Engine
    /// MySQL's and MariaDB's strings take `\` as an escape, unless the
    /// session's sql_mode has NO_BACKSLASH_ESCAPES.
    var backslashEscapes = true

    static let postgres = SQLDialect(engine: .postgres)
    static let redshift = SQLDialect(engine: .redshift)
    static let mysql = SQLDialect(engine: .mysql)
    static let mariadb = SQLDialect(engine: .mariadb)
    static let sqlite = SQLDialect(engine: .sqlite)

    var isMySQL: Bool { engine == .mysql || engine == .mariadb }

    /// `"a""b"`, or MySQL's `` `a``b` ``.
    func identifier(_ name: String) -> String {
        isMySQL ? "`" + name.replacingOccurrences(of: "`", with: "``") + "`" : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `'it''s'` — MySQL's backslashes doubled too while they escape.
    func literal(_ text: String) -> String {
        var body = text
        if isMySQL, backslashEscapes { body = body.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + body.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func value(_ cell: CellValue) -> String {
        switch cell {
        case .null: "NULL"
        case .text(let text): literal(text)
        }
    }

    /// A table with its schema (MySQL's database) when it has one.
    func qualified(_ table: TableName) -> String {
        guard let schema = table.schema, !schema.isEmpty else { return identifier(table.name) }
        return identifier(schema) + "." + identifier(table.name)
    }
}

/// A cell's value as an edit sets it: NULL and the empty string are two.
enum CellValue: Equatable, Hashable, Sendable {
    case null
    case text(String)

    init(_ text: String?) { self = text.map(CellValue.text) ?? .null }

    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

// MARK: Which results can be edited

/// A statement whose rows are one table's, each row that table's row:
/// `SELECT * | col, col FROM [schema.]table [alias] [WHERE …] [ORDER BY …]
/// [LIMIT …] [OFFSET …]` and nothing else at its top level — no join, no
/// group, no DISTINCT, no expression or alias in the select list (an
/// alias could name another column after a key's). Pure.
struct EditableQuery: Equatable {
    var table: TableName
    /// `*` was selected (with or without names beside it).
    var star: Bool
    /// The columns selected by name, as written (unquoted).
    var named: [String]

    /// Why a statement's rows can't be edited — or the query.
    static func parse(_ sql: String) -> Result<EditableQuery, EditRefusal> {
        let tokens = SQLTokens.tokens(sql)
        var at = 0
        func peek(_ offset: Int = 0) -> SQLTokens.Token? { tokens.indices.contains(at + offset) ? tokens[at + offset] : nil }
        func isWord(_ token: SQLTokens.Token?, _ word: String) -> Bool {
            if case .word(let text)? = token { return text.uppercased() == word }
            return false
        }
        let notOneTable = EditRefusal.notOneTable
        guard isWord(peek(), "SELECT") else { return .failure(notOneTable) }
        at += 1
        var star = false
        var named: [String] = []
        // The select list: `*`, names, `t.name`, `t.*`, separated by commas.
        while true {
            guard let first = peek() else { return .failure(notOneTable) }
            if first == .symbol("*") {
                star = true
                at += 1
            } else if let name = first.name, !SQLTokens.reserved.contains(name.uppercased()) || first.isQuoted {
                at += 1
                if peek() == .symbol(".") {
                    at += 1
                    if peek() == .symbol("*") {
                        star = true
                        at += 1
                    } else if let column = peek()?.name {
                        named.append(column)
                        at += 1
                    } else {
                        return .failure(notOneTable)
                    }
                } else {
                    named.append(name)
                }
            } else {
                return .failure(notOneTable)
            }
            if peek() == .symbol(",") {
                at += 1
                continue
            }
            break
        }
        guard isWord(peek(), "FROM") else { return .failure(isWord(peek(), "INTO") ? notOneTable : .expressions) }
        at += 1
        guard let first = peek()?.name else { return .failure(notOneTable) }
        at += 1
        var table = TableName(schema: nil, name: first)
        if peek() == .symbol(".") {
            at += 1
            guard let second = peek()?.name else { return .failure(notOneTable) }
            at += 1
            table = TableName(schema: first, name: second)
        }
        if peek() == .symbol(".") { return .failure(notOneTable) }
        // An alias, with or without AS.
        if isWord(peek(), "AS") {
            at += 2
        } else if let word = peek(), case .word(let text) = word, !SQLTokens.clauses.contains(text.uppercased()) {
            at += 1
        } else if let quoted = peek(), quoted.isQuoted {
            at += 1
        }
        // What may follow: WHERE, ORDER BY, LIMIT, OFFSET, FETCH — nothing
        // at the top level that joins, groups or adds rows.
        var depth = 0
        var afterTable = true
        while let token = peek() {
            at += 1
            switch token {
            case .symbol("("): depth += 1
            case .symbol(")"): depth -= 1
            case .symbol(";"):
                if tokens[at...].isEmpty { return .success(EditableQuery(table: table, star: star, named: named)) }
                return .failure(.severalStatements)
            case .symbol(",") where depth == 0 && afterTable:
                return .failure(notOneTable)
            case .word(let text) where depth == 0:
                let upper = text.uppercased()
                if SQLTokens.joinsOrGroups.contains(upper) { return .failure(notOneTable) }
                if afterTable, !["WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH"].contains(upper) { return .failure(notOneTable) }
                afterTable = false
            default:
                if depth == 0, afterTable { return .failure(notOneTable) }
            }
        }
        return .success(EditableQuery(table: table, star: star, named: named))
    }
}

/// Why a result isn't edited — said in the status bar.
enum EditRefusal: Error, Equatable {
    case notOneTable
    case expressions
    case severalStatements
    case noKey(String)
    case keyNotShown([String])
    case unknownColumn(String)
    case duplicateColumn(String)
    case truncatedKey

    var message: String {
        switch self {
        case .notOneTable: "Rows are edited in a SELECT from one table — no join, group, DISTINCT or UNION."
        case .expressions: "Rows are edited when the columns are selected by name or *, not computed or renamed."
        case .severalStatements: "One statement at a time."
        case .noKey(let table): "\(table) has no primary key or unique key over NOT NULL columns: a row couldn't be found again."
        case .keyNotShown(let columns): "Select \(columns.joined(separator: ", ")) too — the key finds each row again."
        case .unknownColumn(let name): "“\(name)” isn't one of the table's columns."
        case .duplicateColumn(let name): "“\(name)” is selected twice."
        case .truncatedKey: "The key's values aren't all there."
        }
    }
}

/// A result's columns matched to its table's, and the key that finds a row.
struct EditableResult: Equatable {
    var key: TableKey
    /// Each result column's table column (as the catalog spells it).
    var columns: [String]
    /// Where each key column is in the result.
    var keyIndexes: [Int]

    /// The result's columns against the table's catalog columns and its key.
    static func match(resultColumns: [String], tableColumns: [String], key: TableKey) -> Result<EditableResult, EditRefusal> {
        var matched: [String] = []
        var seen: Set<String> = []
        for name in resultColumns {
            let lower = name.lowercased()
            let column: String
            if key.kind == .rowid, ["rowid", "_rowid_", "oid"].contains(lower) {
                column = "rowid"
            } else if let found = tableColumns.first(where: { $0 == name }) ?? tableColumns.first(where: { $0.lowercased() == lower }) {
                column = found
            } else {
                return .failure(.unknownColumn(name))
            }
            guard seen.insert(column.lowercased()).inserted else { return .failure(.duplicateColumn(column)) }
            matched.append(column)
        }
        var indexes: [Int] = []
        var missing: [String] = []
        for keyColumn in key.columns {
            if let at = matched.firstIndex(where: { $0.lowercased() == keyColumn.lowercased() }) { indexes.append(at) } else { missing.append(keyColumn) }
        }
        guard missing.isEmpty else { return .failure(.keyNotShown(missing)) }
        return .success(EditableResult(key: key, columns: matched, keyIndexes: indexes))
    }

    /// Whether a column's cells may be written.
    func isEditable(_ column: Int) -> Bool {
        guard columns.indices.contains(column) else { return false }
        let name = columns[column]
        return name != "rowid" || key.kind != .rowid ? !key.readOnlyColumns.contains(name) : false
    }
}

// MARK: Pending edits

/// What has been changed in a result and not saved: cells of rows that
/// exist, rows deleted, rows added. Nothing runs until Save. Pure.
struct PendingEdits: Equatable {
    /// Row (the result's index) → column → its new value.
    private(set) var updates: [Int: [Int: CellValue]] = [:]
    private(set) var deleted: Set<Int> = []
    /// New rows: column → value; a column not set takes its default.
    private(set) var inserted: [[Int: CellValue]] = []

    var isEmpty: Bool { updates.isEmpty && deleted.isEmpty && inserted.isEmpty }
    /// Rows a Save changes.
    var count: Int { updates.count + deleted.count + inserted.count }

    /// A cell of a row that exists; set back to what it was, it is no longer an edit.
    mutating func set(row: Int, column: Int, to value: CellValue, original: String?) {
        guard !deleted.contains(row) else { return }
        var cells = updates[row] ?? [:]
        if value == CellValue(original) { cells.removeValue(forKey: column) } else { cells[column] = value }
        updates[row] = cells.isEmpty ? nil : cells
    }

    func value(row: Int, column: Int) -> CellValue? { updates[row]?[column] }

    func isEdited(row: Int, column: Int) -> Bool { updates[row]?[column] != nil }

    mutating func delete(rows: [Int]) {
        for row in rows {
            deleted.insert(row)
            updates[row] = nil
        }
    }

    /// The row as it was read: its edits and its deletion undone.
    mutating func revert(row: Int) {
        updates[row] = nil
        deleted.remove(row)
    }

    /// A new row — `values` from a duplicated row, else every column its default.
    @discardableResult
    mutating func add(_ values: [Int: CellValue] = [:]) -> Int {
        inserted.append(values)
        return inserted.count - 1
    }

    /// A cell of a new row; `nil` gives the column back its default.
    mutating func set(new index: Int, column: Int, to value: CellValue?) {
        guard inserted.indices.contains(index) else { return }
        if let value { inserted[index][column] = value } else { inserted[index].removeValue(forKey: column) }
    }

    mutating func remove(new index: Int) {
        guard inserted.indices.contains(index) else { return }
        inserted.remove(at: index)
    }

    mutating func discard() { self = PendingEdits() }

    /// A duplicate's values: the row's, but not its key's (or a generated
    /// column's) — those are the new row's own.
    static func duplicate(_ row: [String?], result: EditableResult) -> [Int: CellValue] {
        var values: [Int: CellValue] = [:]
        for (at, value) in row.enumerated() where !result.keyIndexes.contains(at) && result.isEditable(at) {
            values[at] = CellValue(value)
        }
        return values
    }
}

/// The statements a Save runs, in the order it runs them: deletes (so a
/// new row may take a deleted one's key), updates, inserts — each row found
/// by its key's values as they were read. Pure.
enum EditStatements {
    static func make(_ edits: PendingEdits, rows: [[String?]], result: EditableResult, dialect: SQLDialect) throws -> [EditStatement] {
        let table = dialect.qualified(result.key.table)
        func whereKey(_ row: Int) throws -> String {
            guard rows.indices.contains(row) else { throw EditRefusal.truncatedKey }
            return try zip(result.key.columns, result.keyIndexes).map { column, at in
                guard let value = rows[row][safe: at] ?? nil else { throw EditRefusal.truncatedKey }
                return (column == "rowid" && result.key.kind == .rowid ? "rowid" : dialect.identifier(column)) + " = " + dialect.literal(value)
            }.joined(separator: " AND ")
        }
        func count(_ condition: String) -> String? {
            dialect.isMySQL ? "SELECT COUNT(*) FROM \(table) WHERE \(condition)" : nil
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            let condition = try whereKey(row)
            statements.append(EditStatement(sql: "DELETE FROM \(table) WHERE \(condition)", countSQL: count(condition)))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            let condition = try whereKey(row)
            let sets = try cells.keys.sorted().map { column -> String in
                guard result.isEditable(column) else { throw EditRefusal.unknownColumn(result.columns[safe: column] ?? "?") }
                return dialect.identifier(result.columns[column]) + " = " + dialect.value(cells[column] ?? .null)
            }
            statements.append(
                EditStatement(sql: "UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(condition)", countSQL: count(condition)))
        }
        for values in edits.inserted {
            let columns = values.keys.sorted().filter { result.isEditable($0) }
            if columns.isEmpty {
                statements.append(EditStatement(sql: dialect.isMySQL ? "INSERT INTO \(table) () VALUES ()" : "INSERT INTO \(table) DEFAULT VALUES"))
            } else {
                let names = columns.map { dialect.identifier(result.columns[$0]) }.joined(separator: ", ")
                let literals = columns.map { dialect.value(values[$0] ?? .null) }.joined(separator: ", ")
                statements.append(EditStatement(sql: "INSERT INTO \(table) (\(names)) VALUES (\(literals))"))
            }
        }
        return statements
    }
}

// MARK: Tokens

/// SQL cut into words, names, strings and symbols, comments skipped — enough
/// to tell a one-table SELECT from anything else. Pure.
enum SQLTokens {
    enum Token: Equatable {
        case word(String)
        /// A quoted name: `"a b"`, `` `a` ``, `[a]`.
        case quoted(String)
        case string
        case number
        case symbol(String)

        var name: String? {
            switch self {
            case .word(let text), .quoted(let text): text
            default: nil
            }
        }

        var isQuoted: Bool {
            if case .quoted = self { return true }
            return false
        }
    }

    /// Words that end a select list or a FROM's table.
    static let clauses: Set<String> = [
        "WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH", "GROUP", "HAVING", "UNION", "INTERSECT", "EXCEPT", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "FULL", "CROSS", "NATURAL", "WINDOW", "FOR", "ON", "USING", "LATERAL", "INTO", "AS",
    ]
    /// Words at a statement's top level that make its rows other than one table's.
    static let joinsOrGroups: Set<String> = [
        "JOIN", "GROUP", "HAVING", "UNION", "INTERSECT", "EXCEPT", "WINDOW", "INTO", "NATURAL", "CROSS", "LATERAL", "DISTINCT",
    ]
    /// Words that are never a column in a select list.
    static let reserved: Set<String> = clauses.union(["SELECT", "FROM", "DISTINCT", "ALL", "CASE", "NOT", "NULL", "TOP"])

    static func tokens(_ sql: String) -> [Token] {
        let chars = Array(sql.unicodeScalars)
        var out: [Token] = []
        var i = 0
        func isWordStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c.properties.isAlphabetic }
        func isWordPart(_ c: Unicode.Scalar) -> Bool { isWordStart(c) || c == "$" || ("0"..."9").contains(c) }
        while i < chars.count {
            let c = chars[i]
            if c.properties.isWhitespace {
                i += 1
            } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "#" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c == "'" {
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" {
                        i += 2
                        continue
                    }
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" {
                            i += 2
                            continue
                        }
                        break
                    }
                    i += 1
                }
                i += 1
                out.append(.string)
            } else if c == "\"" || c == "`" || c == "[" {
                let close: Unicode.Scalar = c == "[" ? "]" : c
                var text = String.UnicodeScalarView()
                i += 1
                while i < chars.count {
                    if chars[i] == close {
                        if close != "]", i + 1 < chars.count, chars[i + 1] == close {
                            text.append(close)
                            i += 2
                            continue
                        }
                        break
                    }
                    text.append(chars[i])
                    i += 1
                }
                i += 1
                out.append(.quoted(String(text)))
            } else if ("0"..."9").contains(c) {
                while i < chars.count, isWordPart(chars[i]) || chars[i] == "." { i += 1 }
                out.append(.number)
            } else if isWordStart(c) {
                var text = String.UnicodeScalarView()
                while i < chars.count, isWordPart(chars[i]) {
                    text.append(chars[i])
                    i += 1
                }
                out.append(.word(String(text)))
            } else {
                out.append(.symbol(String(c)))
                i += 1
            }
        }
        return out
    }
}
