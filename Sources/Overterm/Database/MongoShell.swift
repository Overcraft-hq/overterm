import Foundation

/// A MongoDB console's text, as mongosh's user writes it — pure: values in
/// the shell's notation (relaxed JSON: unquoted keys, single quotes,
/// `ObjectId()`, `ISODate()`, `NumberLong()`… and Extended JSON's `$oid`
/// forms), statements a line or a bracketed block, and each statement made
/// into the command the server is sent. No JavaScript runs: a statement is
/// read, not evaluated — variables, loops and functions are said to be
/// unsupported rather than guessed at.
struct MongoShellError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Values: the shell's object literals, read into BSON.
struct MongoShellParser {
    private let chars: [Character]
    private(set) var at = 0

    init(_ text: String) { chars = Array(text) }

    var atEnd: Bool {
        var copy = self
        copy.skipSpace()
        return copy.at >= copy.chars.count
    }

    private func fail(_ message: String) -> MongoShellError {
        let near = at < chars.count ? " near “\(String(chars[at..<min(chars.count, at + 12)]))”" : " at the end"
        return MongoShellError(message: message + near)
    }

    mutating func skipSpace() {
        while at < chars.count {
            let c = chars[at]
            if c.isWhitespace {
                at += 1
            } else if c == "/", at + 1 < chars.count, chars[at + 1] == "/" {
                while at < chars.count, !chars[at].isNewline { at += 1 }
            } else if c == "/", at + 1 < chars.count, chars[at + 1] == "*" {
                at += 2
                while at + 1 < chars.count, !(chars[at] == "*" && chars[at + 1] == "/") { at += 1 }
                at = min(chars.count, at + 2)
            } else {
                return
            }
        }
    }

    mutating func peek() -> Character? {
        skipSpace()
        return at < chars.count ? chars[at] : nil
    }

    mutating func eat(_ c: Character) -> Bool {
        guard peek() == c else { return false }
        at += 1
        return true
    }

    mutating func expect(_ c: Character) throws {
        guard eat(c) else { throw fail("Expected “\(c)”") }
    }

    private static func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "$" }
    private static func isIdentifierPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

    mutating func identifier() -> String? {
        skipSpace()
        guard at < chars.count, Self.isIdentifierStart(chars[at]) else { return nil }
        let start = at
        while at < chars.count, Self.isIdentifierPart(chars[at]) { at += 1 }
        return String(chars[start..<at])
    }

    /// A word that may be a field name: `a`, `$set`, `"a.b"`, `'x'`, `1`.
    private mutating func key() throws -> String {
        guard let c = peek() else { throw fail("Expected a field name") }
        if c == "\"" || c == "'" || c == "`" { return try stringLiteral() }
        if let name = identifier() { return name }
        if c.isNumber {
            let start = at
            while at < chars.count, chars[at].isNumber || chars[at] == "." { at += 1 }
            return String(chars[start..<at])
        }
        throw fail("Expected a field name")
    }

    mutating func stringLiteral() throws -> String {
        guard let quote = peek(), quote == "\"" || quote == "'" || quote == "`" else { throw fail("Expected a string") }
        at += 1
        var out = ""
        while at < chars.count {
            let c = chars[at]
            if c == quote {
                at += 1
                return out
            }
            if quote == "`", c == "$", at + 1 < chars.count, chars[at + 1] == "{" {
                throw fail("A template's ${…} runs JavaScript, which the console doesn't")
            }
            if c == "\\", at + 1 < chars.count {
                let e = chars[at + 1]
                at += 2
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{c}")
                case "0": out.append("\0")
                case "v": out.append("\u{b}")
                case "u":
                    if at < chars.count, chars[at] == "{" {
                        let end = chars[at...].firstIndex(of: "}") ?? chars.count
                        guard let code = UInt32(String(chars[(at + 1)..<end]), radix: 16), let scalar = UnicodeScalar(code) else {
                            throw fail("A bad \\u{…} escape")
                        }
                        out.unicodeScalars.append(scalar)
                        at = end + 1
                    } else {
                        guard at + 4 <= chars.count, var code = UInt32(String(chars[at..<(at + 4)]), radix: 16) else {
                            throw fail("A bad \\u escape")
                        }
                        at += 4
                        // A surrogate pair, as JSON writes what is past the BMP.
                        if (0xD800...0xDBFF).contains(code), at + 6 <= chars.count, chars[at] == "\\", chars[at + 1] == "u",
                            let low = UInt32(String(chars[(at + 2)..<(at + 6)]), radix: 16), (0xDC00...0xDFFF).contains(low)
                        {
                            code = 0x10000 + (code - 0xD800) << 10 + (low - 0xDC00)
                            at += 6
                        }
                        out.unicodeScalars.append(UnicodeScalar(code) ?? "\u{FFFD}")
                    }
                case "x":
                    guard at + 2 <= chars.count, let code = UInt8(String(chars[at..<(at + 2)]), radix: 16) else { throw fail("A bad \\x escape") }
                    out.unicodeScalars.append(UnicodeScalar(code))
                    at += 2
                case "\n": break
                default: out.append(e)
                }
                continue
            }
            if c.isNewline, quote != "`" { throw fail("A string that doesn't end on its line") }
            out.append(c)
            at += 1
        }
        throw fail("A string that doesn't end")
    }

    private mutating func numberLiteral() throws -> BSONValue {
        skipSpace()
        let start = at
        if at < chars.count, chars[at] == "-" || chars[at] == "+" { at += 1 }
        if at + 1 < chars.count, chars[at] == "0", chars[at + 1] == "x" || chars[at + 1] == "X" {
            at += 2
            let digitsStart = at
            while at < chars.count, chars[at].isHexDigit { at += 1 }
            guard let n = Int64(String(chars[digitsStart..<at]), radix: 16) else { throw fail("A bad hex number") }
            let value = chars[start] == "-" ? -n : n
            return Int32(exactly: value).map(BSONValue.int32) ?? .int64(value)
        }
        var fractional = false
        while at < chars.count {
            let c = chars[at]
            if c.isNumber {
                at += 1
            } else if c == "." || c == "e" || c == "E" {
                fractional = true
                at += 1
                if (c == "e" || c == "E"), at < chars.count, chars[at] == "-" || chars[at] == "+" { at += 1 }
            } else if c == "_" {
                at += 1
            } else {
                break
            }
        }
        let text = String(chars[start..<at]).replacingOccurrences(of: "_", with: "")
        if !fractional, let n = Int64(text) { return Int32(exactly: n).map(BSONValue.int32) ?? .int64(n) }
        guard let d = Double(text) else { throw fail("A bad number") }
        return .double(d)
    }

    private mutating func regexLiteral() throws -> BSONValue {
        at += 1
        var pattern = ""
        var inClass = false
        while at < chars.count {
            let c = chars[at]
            if c == "\\", at + 1 < chars.count {
                // `\/` is a slash; any other escape is the pattern's own.
                if chars[at + 1] != "/" { pattern.append(c) }
                pattern.append(chars[at + 1])
                at += 2
                continue
            }
            if c == "[" { inClass = true }
            if c == "]" { inClass = false }
            if c == "/", !inClass { break }
            if c.isNewline { throw fail("A regular expression that doesn't end on its line") }
            pattern.append(c)
            at += 1
        }
        guard at < chars.count else { throw fail("A regular expression that doesn't end") }
        at += 1
        var options = ""
        while at < chars.count, chars[at].isLetter {
            options.append(chars[at])
            at += 1
        }
        return .regex(pattern: pattern, options: options)
    }

    mutating func value() throws -> BSONValue {
        guard let c = peek() else { throw fail("Expected a value") }
        switch c {
        case "{": return MongoExtendedJSON.converted(try object())
        case "[": return .array(try array())
        case "\"", "'", "`": return .string(try stringLiteral())
        case "/": return try regexLiteral()
        case "-", "+", ".", "0"..."9":
            if c == "-" || c == "+", at + 1 < chars.count, chars[at + 1].isLetter {
                at += 1
                let negative = c == "-"
                guard let name = identifier(), name == "Infinity" else { throw fail("Expected a number") }
                return .double(negative ? -.infinity : .infinity)
            }
            return try numberLiteral()
        default:
            guard var name = identifier() else { throw fail("Expected a value") }
            if name == "new" {
                guard let constructor = identifier() else { throw fail("Expected a name after new") }
                name = constructor
            }
            return try named(name)
        }
    }

    mutating func object() throws -> BSONDocument {
        try expect("{")
        var document = BSONDocument()
        while true {
            if eat("}") { return document }
            let name = try key()
            try expect(":")
            document.fields.append((key: name, value: try value()))
            if eat(",") { continue }
            try expect("}")
            return document
        }
    }

    mutating func array() throws -> [BSONValue] {
        try expect("[")
        var items: [BSONValue] = []
        while true {
            if eat("]") { return items }
            items.append(try value())
            if eat(",") { continue }
            try expect("]")
            return items
        }
    }

    /// `(a, b)`: a call's arguments.
    mutating func arguments() throws -> [BSONValue] {
        try expect("(")
        var items: [BSONValue] = []
        while true {
            if eat(")") { return items }
            items.append(try value())
            if eat(",") { continue }
            try expect(")")
            return items
        }
    }

    /// A bare name, or a constructor the shell knows.
    private mutating func named(_ name: String) throws -> BSONValue {
        let called = peek() == "("
        let args = called ? try arguments() : []
        func text(_ index: Int) -> String? {
            guard index < args.count else { return nil }
            switch args[index] {
            case .string(let s): return s
            case .int32(let n): return String(n)
            case .int64(let n): return String(n)
            case .double(let d): return d == d.rounded() && abs(d) < 9e18 ? String(Int64(d)) : String(d)
            default: return nil
            }
        }
        switch name {
        case "true" where !called: return .bool(true)
        case "false" where !called: return .bool(false)
        case "null" where !called: return .null
        case "undefined" where !called: return .undefined
        case "Infinity" where !called: return .double(.infinity)
        case "NaN" where !called: return .double(.nan)
        case "MinKey": return .minKey
        case "MaxKey": return .maxKey
        case "ObjectId", "ObjectID":
            guard let hex = text(0) else { return .objectId(.generate()) }
            guard let id = ObjectID(hex: hex) else { throw MongoShellError(message: "ObjectId takes 24 hex digits: “\(hex)” isn't") }
            return .objectId(id)
        case "ISODate", "Date":
            if args.isEmpty { return .date(Int64(Date().timeIntervalSince1970 * 1000)) }
            if case .string(let s) = args[0] {
                guard let ms = MongoShellParser.date(s) else { throw MongoShellError(message: "\(name) can't read “\(s)” as a time") }
                return .date(ms)
            }
            guard let ms = args[0].int else { throw MongoShellError(message: "\(name) takes a time as text or milliseconds") }
            return .date(Int64(ms))
        case "NumberLong", "Long":
            guard let t = text(0), let n = Int64(t) else { throw MongoShellError(message: "\(name) takes a whole number") }
            return .int64(n)
        case "NumberInt", "Int32":
            guard let t = text(0), let n = Int32(t) else { throw MongoShellError(message: "\(name) takes a 32-bit whole number") }
            return .int32(n)
        case "Double":
            guard args.count == 1, let d = Double(text(0) ?? "") else { throw MongoShellError(message: "Double takes a number") }
            return .double(d)
        case "NumberDecimal", "Decimal128":
            guard let t = text(0), let d = Decimal128(t) else { throw MongoShellError(message: "\(name) takes a decimal as text: \(name)(\"1.50\")") }
            return .decimal128(d)
        case "UUID":
            guard let t = text(0) else { return .binary(subtype: 4, MongoShellParser.uuidBytes(UUID())) }
            guard let uuid = UUID(uuidString: t) ?? UUID(uuidString: MongoShellParser.dashed(t)) else {
                throw MongoShellError(message: "UUID can't read “\(t)”")
            }
            return .binary(subtype: 4, MongoShellParser.uuidBytes(uuid))
        case "BinData":
            guard args.count == 2, let subtype = args[0].int, (0...255).contains(subtype), case .string(let b64) = args[1],
                let data = Data(base64Encoded: b64)
            else { throw MongoShellError(message: "BinData takes a subtype and base64: BinData(0, \"AQID\")") }
            return .binary(subtype: UInt8(subtype), data)
        case "Timestamp":
            var t = 0
            var i = 0
            if args.count == 1, case .document(let d) = args[0] {
                t = d["t"]?.int ?? 0
                i = d["i"]?.int ?? 0
            } else if args.count == 2 {
                t = args[0].int ?? 0
                i = args[1].int ?? 0
            }
            return .timestamp(UInt64(UInt32(truncatingIfNeeded: t)) << 32 | UInt64(UInt32(truncatingIfNeeded: i)))
        case "RegExp":
            guard let pattern = text(0) else { throw MongoShellError(message: "RegExp takes a pattern") }
            return .regex(pattern: pattern, options: text(1) ?? "")
        case "Code":
            guard let code = text(0) else { throw MongoShellError(message: "Code takes its source as text") }
            return .javascript(code)
        default:
            throw MongoShellError(
                message: called
                    ? "\(name)() isn't something the console knows — it reads values, it doesn't run JavaScript"
                    : "“\(name)” isn't a value — variables aren't supported, write the value itself")
        }
    }

    static func uuidBytes(_ uuid: UUID) -> Data { withUnsafeBytes(of: uuid.uuid) { Data($0) } }

    private static func dashed(_ hex: String) -> String {
        guard hex.count == 32 else { return hex }
        var s = hex
        for at in [8, 13, 18, 23] { s.insert("-", at: s.index(s.startIndex, offsetBy: at)) }
        return s
    }

    /// ISODate's text: a date, a time with or without its fraction and
    /// zone (none is UTC, as the shell has it), or a space for the T.
    static func date(_ text: String) -> Int64? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        if s.count == 10 { s += "T00:00:00Z" }
        if let t = s.firstIndex(of: "T") {
            let time = s[s.index(after: t)...]
            if !time.contains("Z"), !time.contains("+"), !time.contains("-") { s += "Z" }
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: s) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        return nil
    }
}

/// Extended JSON's wrappers (`{"$oid": …}`, `{"$date": …}`…), as relaxed
/// and canonical mode write them, read as the values they stand for — what
/// Compass, mongoexport and the drivers print.
enum MongoExtendedJSON {
    static func converted(_ document: BSONDocument) -> BSONValue {
        if let value = wrapped(document) { return value }
        return .document(document)
    }

    private static func wrapped(_ d: BSONDocument) -> BSONValue? {
        guard let first = d.fields.first, first.key.hasPrefix("$") else { return nil }
        if d.fields.count == 2, first.key == "$binary", let b64 = first.value.string, let type = d["$type"]?.string,
            let data = Data(base64Encoded: b64), let subtype = UInt8(type, radix: 16)
        {
            return .binary(subtype: subtype, data)
        }
        guard d.fields.count == 1 else { return nil }
        let value = first.value
        switch first.key {
        case "$oid": return value.string.flatMap(ObjectID.init(hex:)).map(BSONValue.objectId)
        case "$date":
            if let s = value.string { return MongoShellParser.date(s).map(BSONValue.date) }
            if let inner = value.document, let s = inner["$numberLong"]?.string, let n = Int64(s) { return .date(n) }
            return value.int.map { .date(Int64($0)) }
        case "$numberLong": return value.string.flatMap { Int64($0) }.map(BSONValue.int64)
        case "$numberInt": return value.string.flatMap { Int32($0) }.map(BSONValue.int32)
        case "$numberDouble":
            guard let s = value.string else { return nil }
            switch s {
            case "Infinity": return .double(.infinity)
            case "-Infinity": return .double(-.infinity)
            case "NaN": return .double(.nan)
            default: return Double(s).map(BSONValue.double)
            }
        case "$numberDecimal": return value.string.flatMap(Decimal128.init).map(BSONValue.decimal128)
        case "$binary":
            guard let inner = value.document, let b64 = inner["base64"]?.string, let data = Data(base64Encoded: b64) else { return nil }
            return .binary(subtype: UInt8(inner["subType"]?.string ?? "0", radix: 16) ?? 0, data)
        case "$uuid":
            return value.string.flatMap(UUID.init(uuidString:)).map { .binary(subtype: 4, MongoShellParser.uuidBytes($0)) }
        case "$regularExpression":
            guard let inner = value.document, let pattern = inner["pattern"]?.string else { return nil }
            return .regex(pattern: pattern, options: inner["options"]?.string ?? "")
        case "$timestamp":
            guard let inner = value.document, let t = inner["t"]?.int, let i = inner["i"]?.int else { return nil }
            return .timestamp(UInt64(UInt32(truncatingIfNeeded: t)) << 32 | UInt64(UInt32(truncatingIfNeeded: i)))
        case "$minKey": return .minKey
        case "$maxKey": return .maxKey
        case "$undefined": return .undefined
        case "$symbol": return value.string.map(BSONValue.symbol)
        case "$code": return value.string.map(BSONValue.javascript)
        default: return nil
        }
    }
}

// MARK: Statements

/// One statement, read: what goes to the server, and how its answer is shown.
struct MongoCommand: Equatable {
    enum Action: Equatable {
        /// Send it; show what came back, a field a row.
        case command
        /// A cursor's documents, a row each (find, aggregate, listIndexes…).
        case cursor
        /// find's first document, or none.
        case findOne
        /// An aggregate whose one document's `n` is the answer.
        case count
        /// distinct's values, a row each.
        case distinct
        /// What a write did: inserted (with the ids made for it), matched,
        /// modified, deleted.
        case write
        /// findAndModify's document.
        case findAndModify
        case showDatabases, showCollections
        /// The collections' names alone.
        case collectionNames
        case use(String)
    }

    /// nil: the console's database.
    var database: String?
    var collection: String?
    /// What it is called in the console: find, insertOne, show dbs, runCommand.
    var method: String
    var body: BSONDocument
    var action: Action
    /// find's own `.limit(n)`; the row limit keeps fewer.
    var limit: Int?

    /// The command's name — the body's first key.
    var name: String { body.fields.first?.key ?? "" }

    /// Commands that never change data or the server: what a read-only
    /// connection and an agent may send. Anything not here writes.
    static let readCommands: Set<String> = [
        "find", "aggregate", "count", "distinct", "listCollections", "listIndexes", "listDatabases", "collStats", "dbStats", "serverStatus",
        "buildInfo", "hello", "isMaster", "ismaster", "ping", "connectionStatus", "hostInfo", "explain", "getParameter", "listCommands",
        "dataSize", "replSetGetStatus", "usersInfo", "rolesInfo", "getMore", "currentOp", "top", "whatsmyuri", "getLog", "features",
        "getCmdLineOpts", "dbHash",
    ]

    /// Whether it only reads. An aggregate ending in `$out` or `$merge`
    /// writes; so does explain of nothing — explain never applies a write.
    var onlyReads: Bool {
        switch action {
        case .use, .showDatabases, .showCollections, .collectionNames: return true
        default: break
        }
        guard Self.readCommands.contains(name) else { return false }
        if name == "aggregate", Self.writesStage(body["pipeline"]) { return false }
        if name == "explain", let inner = body["explain"]?.document, inner.fields.first?.key == "aggregate" {
            // explain never applies a write, $out included.
            return true
        }
        return true
    }

    static func writesStage(_ pipeline: BSONValue?) -> Bool {
        guard let stages = pipeline?.array else { return false }
        return stages.contains { stage in
            guard let key = stage.document?.fields.first?.key else { return false }
            return key == "$out" || key == "$merge"
        }
    }

    /// Why it should be asked about first; nil when it needn't be.
    var danger: String? {
        let where_ = collection.map { " in \($0)" } ?? ""
        func empty(_ value: BSONValue?) -> Bool { value?.document?.isEmpty ?? (value == nil) }
        switch name {
        case "delete":
            let deletes = body["deletes"]?.array ?? []
            let all = deletes.contains { $0.document.map { empty($0["q"]) } ?? false }
            let many = deletes.contains { $0.document?["limit"]?.int == 0 }
            if all, many { return "\(method)({}) deletes every document\(where_)." }
            if many { return "\(method) deletes every document\(where_) its filter matches." }
            return nil
        case "update":
            let updates = body["updates"]?.array ?? []
            if updates.contains(where: { $0.document.map { empty($0["q"]) && $0["multi"]?.bool == true } ?? false }) {
                return "\(method)({}, …) changes every document\(where_)."
            }
            return nil
        case "drop": return "drop deletes the collection \(body["drop"]?.string ?? collection ?? ""), its documents and its indexes."
        case "dropDatabase": return "dropDatabase deletes the database\(database.map { " \($0)" } ?? "") and every collection in it."
        case "dropIndexes": return "dropIndex removes an index\(where_); queries that used it get slower."
        case "renameCollection": return "renameCollection moves a collection — anything that reads it by name stops finding it."
        case "dropUser", "dropAllUsersFromDatabase", "dropRole", "dropAllRolesFromDatabase": return "\(name) removes access for good."
        case "shutdown": return "shutdown stops the server."
        case "aggregate":
            guard let stages = body["pipeline"]?.array else { return nil }
            for stage in stages {
                if let out = stage.document?["$out"] {
                    let target = out.string ?? out.document?["coll"]?.string ?? "its collection"
                    return "$out replaces \(target) with the pipeline's result."
                }
                if stage.document?["$merge"] != nil { return "$merge writes the pipeline's result into another collection." }
            }
            return nil
        default: return nil
        }
    }
}

enum MongoText {
    /// Each statement: a line, or a bracketed block over several, `;` ending
    /// one early; a line starting with `.` goes on with the one above
    /// (`.sort({…})`). `//` and `/* */` comments are skipped.
    static func statements(in text: String) -> [NSRange] {
        let u = Array(text.utf16)
        let n = u.count
        var found: [NSRange] = []
        var i = 0
        var depth = 0
        var start: Int?
        var last = -1
        func char(_ c: Character) -> UInt16 { c.utf16.first! }
        let slash = char("/"), star = char("*"), newline = char("\n"), semicolon = char(";"), dot = char(".")
        let quotes: Set<UInt16> = [char("\""), char("'"), char("`")]
        let opens: Set<UInt16> = [char("("), char("["), char("{")]
        let closes: Set<UInt16> = [char(")"), char("]"), char("}")]
        let beforeRegex: Set<UInt16> = Set("(,=:[!&|?{};".utf16)
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == newline }
        func close() {
            if let s = start, last >= s { found.append(NSRange(location: s, length: last + 1 - s)) }
            start = nil
            depth = 0
        }
        while i < n {
            let c = u[i]
            if start == nil {
                if isSpace(c) || c == semicolon {
                    i += 1
                    continue
                }
                if c == slash, i + 1 < n, u[i + 1] == slash {
                    while i < n, u[i] != newline { i += 1 }
                    continue
                }
                if c == slash, i + 1 < n, u[i + 1] == star {
                    i += 2
                    while i + 1 < n, !(u[i] == star && u[i + 1] == slash) { i += 1 }
                    i = min(n, i + 2)
                    continue
                }
                start = i
                last = i - 1
            }
            if quotes.contains(c) {
                var j = i + 1
                while j < n, u[j] != c {
                    if u[j] == 0x5C { j += 1 } else if u[j] == newline, c != char("`") { break }
                    j += 1
                }
                i = min(j, n - 1)
                last = i
                i += 1
                continue
            }
            if c == slash, i + 1 < n, u[i + 1] == slash {
                while i < n, u[i] != newline { i += 1 }
                continue
            }
            if c == slash, i + 1 < n, u[i + 1] == star {
                i += 2
                while i + 1 < n, !(u[i] == star && u[i + 1] == slash) { i += 1 }
                i = min(n, i + 2)
                continue
            }
            if c == slash, last < (start ?? 0) || beforeRegex.contains(u[last]) {
                // A regular expression: to its closing slash, past classes.
                var j = i + 1
                var inClass = false
                while j < n, u[j] != newline {
                    if u[j] == 0x5C {
                        j += 2
                        continue
                    }
                    if u[j] == char("[") { inClass = true } else if u[j] == char("]") { inClass = false } else if u[j] == slash, !inClass { break }
                    j += 1
                }
                i = min(j, n - 1)
                last = i
                i += 1
                continue
            }
            if opens.contains(c) { depth += 1 }
            if closes.contains(c) { depth = max(0, depth - 1) }
            if c == semicolon, depth == 0 {
                close()
                i += 1
                continue
            }
            if c == newline, depth == 0 {
                // Goes on when the next line starts with a dot.
                var j = i + 1
                while j < n, u[j] == 0x20 || u[j] == 0x09 || u[j] == 0x0D { j += 1 }
                if !(j < n && u[j] == dot) { close() }
                i += 1
                continue
            }
            if !isSpace(c) { last = i }
            i += 1
        }
        close()
        return found
    }

    /// The statement the caret is in or at the end of.
    static func statement(at caret: Int, in text: String) -> NSRange? {
        statements(in: text).first { $0.location <= caret && caret <= NSMaxRange($0) }
    }

    static func command(_ statement: String) throws -> MongoCommand { try MongoStatement.read(statement) }

    /// A collection's first documents, as the console writes it: its
    /// database named (`getSiblingDB`) — the console's `use` may have moved
    /// `db` elsewhere —, `getCollection("…")` for a name that isn't a word.
    static func find(_ collection: String, in database: String, limit: Int) -> String {
        let db = "db.getSiblingDB(\(BSONText.quoted(database)))"
        let bare = collection.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
        let reached = bare ? "\(db).\(collection)" : "\(db).getCollection(\(BSONText.quoted(collection)))"
        return "\(reached).find({}).limit(\(limit))"
    }

    static func verb(of statement: String) -> String {
        if let command = try? command(statement) { return command.method }
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        // What it would be, even unread: `db.c.insertOne(` → insertOne.
        if let open = trimmed.firstIndex(of: "("), let dot = trimmed[..<open].lastIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dot)..<open])
        }
        return String(trimmed.split(separator: " ").first ?? "")
    }

    /// A statement that can't be read writes, as far as anyone can tell.
    static func onlyReads(_ statement: String) -> Bool { (try? command(statement))?.onlyReads ?? false }

    static func danger(of statement: String) -> String? { (try? command(statement))?.danger }

    static func subject(of statement: String) -> String? {
        guard let command = try? command(statement) else { return nil }
        if let collection = command.collection { return collection }
        if let value = command.body.fields.first?.value.string, !value.isEmpty { return value }
        return nil
    }
}

/// A statement read into a command: `show dbs`, `use shop`,
/// `db.orders.find({…}).sort({…}).limit(10)`, `db.runCommand({…})`.
enum MongoStatement {
    struct Call {
        var name: String
        var args: [BSONValue]
    }

    static func read(_ text: String) throws -> MongoCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = words.first, first == "show" || first == "use" {
            guard words.count == 2 else { throw MongoShellError(message: "\(first) takes one word: \(first == "use" ? "use shop" : "show dbs")") }
            if first == "use" { return MongoCommand(method: "use", body: [:], action: .use(words[1])) }
            switch words[1] {
            case "dbs", "databases":
                return MongoCommand(
                    database: "admin", method: "show dbs", body: ["listDatabases": .int32(1), "nameOnly": .bool(false)], action: .showDatabases)
            case "collections", "tables":
                return MongoCommand(
                    method: "show collections", body: ["listCollections": .int32(1), "nameOnly": .bool(false)], action: .showCollections)
            case "users": return MongoCommand(method: "show users", body: ["usersInfo": .int32(1)], action: .command)
            case "roles": return MongoCommand(method: "show roles", body: ["rolesInfo": .int32(1)], action: .command)
            default: throw MongoShellError(message: "show \(words[1]) isn't one the console knows: show dbs, show collections, show users, show roles")
            }
        }
        var parser = MongoShellParser(trimmed)
        guard parser.identifier() == "db" else {
            throw MongoShellError(message: "A statement starts with db., show or use — db.orders.find({ status: \"open\" })")
        }
        var database: String?
        var path: [String] = []
        var calls: [Call] = []
        // db's members: names (a collection's, dots and all), then calls.
        while true {
            if parser.eat("[") {
                guard calls.isEmpty else { throw MongoShellError(message: "[…] after a call isn't supported") }
                path.append(try parser.stringLiteral())
                try parser.expect("]")
                continue
            }
            guard parser.eat(".") else { break }
            guard let name = parser.identifier() else { throw MongoShellError(message: "Expected a name after “.”") }
            if parser.peek() == "(" {
                let args = try parser.arguments()
                if calls.isEmpty, path.isEmpty, name == "getSiblingDB" || name == "getDB" {
                    guard args.count == 1, let db = args[0].string else { throw MongoShellError(message: "\(name) takes a database's name") }
                    database = db
                    continue
                }
                if calls.isEmpty, path.isEmpty, name == "getCollection" {
                    guard args.count == 1, let collection = args[0].string else { throw MongoShellError(message: "getCollection takes a name") }
                    path.append(collection)
                    continue
                }
                calls.append(Call(name: name, args: args))
            } else {
                guard calls.isEmpty else { throw MongoShellError(message: "\(name) after a call isn't supported — only calls chain") }
                path.append(name)
            }
        }
        guard parser.atEnd else { throw MongoShellError(message: "Only one statement at a time — something follows it") }
        guard let method = calls.first else {
            throw MongoShellError(message: "Nothing is called — db.\(path.joined(separator: ".")).find() reads a collection")
        }
        let collection = path.isEmpty ? nil : path.joined(separator: ".")
        var command: MongoCommand
        if let collection {
            command = try collectionMethod(collection, method, chain: Array(calls.dropFirst()))
        } else {
            guard calls.count == 1 else { throw MongoShellError(message: "\(method.name)() takes nothing after it") }
            command = try databaseMethod(method)
        }
        if command.database == nil { command.database = database }
        return command
    }

    private static func document(_ args: [BSONValue], _ index: Int, _ what: String, required: Bool = false) throws -> BSONDocument? {
        guard index < args.count else {
            if required { throw MongoShellError(message: what) }
            return nil
        }
        if case .undefined = args[index] { return nil }
        if case .null = args[index] { return nil }
        guard let d = args[index].document else { throw MongoShellError(message: what) }
        return d
    }

    private static func databaseMethod(_ call: Call) throws -> MongoCommand {
        let args = call.args
        switch call.name {
        case "runCommand", "adminCommand":
            var body: BSONDocument
            if let name = args.first?.string {
                body = [name: .int32(1)]
            } else if let d = try document(args, 0, "\(call.name) takes a command: db.\(call.name)({ ping: 1 })", required: true) {
                body = d
            } else {
                body = [:]
            }
            guard !body.isEmpty else { throw MongoShellError(message: "\(call.name) takes a command: db.\(call.name)({ ping: 1 })") }
            let cursor = body["cursor"] != nil || ["find", "listCollections", "listIndexes"].contains(body.fields[0].key)
            return MongoCommand(database: call.name == "adminCommand" ? "admin" : nil, method: call.name, body: body, action: cursor ? .cursor : .command)
        case "getCollectionNames":
            return MongoCommand(
                method: "getCollectionNames", body: ["listCollections": .int32(1), "nameOnly": .bool(true)], action: .collectionNames)
        case "getCollectionInfos":
            var body: BSONDocument = ["listCollections": .int32(1)]
            if let filter = try document(args, 0, "getCollectionInfos takes a filter") { body["filter"] = .document(filter) }
            return MongoCommand(method: "getCollectionInfos", body: body, action: .cursor)
        case "createCollection":
            guard let name = args.first?.string else { throw MongoShellError(message: "createCollection takes a name") }
            var body: BSONDocument = ["create": .string(name)]
            for field in try document(args, 1, "createCollection's options are a document")?.fields ?? [] { body[field.key] = field.value }
            return MongoCommand(collection: name, method: "createCollection", body: body, action: .command)
        case "dropDatabase": return MongoCommand(method: "dropDatabase", body: ["dropDatabase": .int32(1)], action: .command)
        case "stats": return MongoCommand(method: "stats", body: ["dbStats": .int32(1)], action: .command)
        case "serverStatus": return MongoCommand(database: "admin", method: "serverStatus", body: ["serverStatus": .int32(1)], action: .command)
        case "hello", "isMaster": return MongoCommand(method: call.name, body: ["hello": .int32(1)], action: .command)
        case "version", "buildInfo": return MongoCommand(method: call.name, body: ["buildInfo": .int32(1)], action: .command)
        case "getUsers": return MongoCommand(method: "getUsers", body: ["usersInfo": .int32(1)], action: .command)
        default:
            throw MongoShellError(
                message:
                    "db.\(call.name)() isn't one the console knows — runCommand, adminCommand, getCollectionNames, createCollection, dropDatabase, stats do"
            )
        }
    }

    /// A collection's method, and what is chained after it.
    private static func collectionMethod(_ collection: String, _ call: Call, chain: [Call]) throws -> MongoCommand {
        let args = call.args
        let name: BSONValue = .string(collection)
        func only(_ chain: [Call]) throws {
            for link in chain where !["toArray", "pretty", "itcount"].contains(link.name) {
                throw MongoShellError(message: ".\(link.name)() can't follow \(call.name)()")
            }
        }
        switch call.name {
        case "find", "findOne":
            var body: BSONDocument = ["find": name]
            if let filter = try document(args, 0, "find's filter is a document: find({ status: \"open\" })") { body["filter"] = .document(filter) }
            if let projection = try document(args, 1, "find's projection is a document: find({}, { name: 1 })") {
                body["projection"] = .document(projection)
            }
            for option in try document(args, 2, "find's options are a document")?.fields ?? [] { body[option.key] = option.value }
            var limit: Int?
            var counted = false
            for link in chain {
                let value = link.args.first
                switch link.name {
                case "sort", "projection", "hint", "collation", "max", "min":
                    guard let value else { throw MongoShellError(message: ".\(link.name)() takes a value") }
                    body[link.name] = value
                case "skip", "maxTimeMS", "batchSize":
                    guard let n = value?.int, n >= 0 else { throw MongoShellError(message: ".\(link.name)() takes a number") }
                    if link.name != "batchSize" { body[link.name] = .int64(Int64(n)) }
                case "limit":
                    guard let n = value?.int else { throw MongoShellError(message: ".limit() takes a number") }
                    if n != 0 { limit = abs(n) }
                case "comment":
                    if let value { body["comment"] = value }
                case "count", "size":
                    counted = true
                case "toArray", "pretty", "itcount", "allowDiskUse", "noCursorTimeout":
                    if link.name == "allowDiskUse" { body["allowDiskUse"] = .bool(true) }
                default:
                    throw MongoShellError(message: ".\(link.name)() isn't supported after find() — sort, limit, skip, projection, hint, count are")
                }
            }
            if let n = body["limit"]?.int, n != 0, limit == nil { limit = abs(n) }
            body["limit"] = nil
            if counted {
                var count: BSONDocument = ["count": name]
                if let filter = body["filter"] { count["query"] = filter }
                if call.name == "find", let skip = body["skip"] { count["skip"] = skip }
                if let limit { count["limit"] = .int64(Int64(limit)) }
                return MongoCommand(collection: collection, method: "count", body: count, action: .command)
            }
            if call.name == "findOne" {
                body["singleBatch"] = .bool(true)
                return MongoCommand(collection: collection, method: "findOne", body: body, action: .findOne, limit: 1)
            }
            return MongoCommand(collection: collection, method: "find", body: body, action: .cursor, limit: limit)
        case "aggregate":
            try only(chain)
            var stages: [BSONValue]
            if let array = args.first?.array {
                stages = array
            } else {
                // aggregate({…}, {…}): stages as arguments, as the shell allows.
                stages = args.filter { $0.document != nil }
                if args.count == 2, args[1].document?.fields.first?.key.hasPrefix("$") == false { stages = [args[0]] }
            }
            guard stages.allSatisfy({ $0.document?.fields.first?.key.hasPrefix("$") == true }) else {
                throw MongoShellError(message: "aggregate takes stages: aggregate([{ $match: { … } }, { $group: { … } }])")
            }
            var body: BSONDocument = ["aggregate": name, "pipeline": .array(stages), "cursor": .document([:])]
            if args.first?.array != nil {
                for option in try document(args, 1, "aggregate's options are a document")?.fields ?? [] where option.key != "cursor" {
                    body[option.key] = option.value
                }
            }
            return MongoCommand(collection: collection, method: "aggregate", body: body, action: .cursor)
        case "countDocuments":
            try only(chain)
            var stages: [BSONValue] = [.document(["$match": .document(try document(args, 0, "countDocuments' filter is a document") ?? [:])])]
            let options = try document(args, 1, "countDocuments' options are a document")
            if let skip = options?["skip"] { stages.append(.document(["$skip": skip])) }
            if let limit = options?["limit"] { stages.append(.document(["$limit": limit])) }
            stages.append(.document(["$group": .document(["_id": .int32(1), "n": .document(["$sum": .int32(1)])])]))
            return MongoCommand(
                collection: collection, method: "countDocuments", body: ["aggregate": name, "pipeline": .array(stages), "cursor": .document([:])],
                action: .count)
        case "estimatedDocumentCount", "count":
            try only(chain)
            var body: BSONDocument = ["count": name]
            if call.name == "count", let filter = try document(args, 0, "count's filter is a document") { body["query"] = .document(filter) }
            return MongoCommand(collection: collection, method: call.name, body: body, action: .command)
        case "distinct":
            try only(chain)
            guard let key = args.first?.string else { throw MongoShellError(message: "distinct takes a field's name: distinct(\"status\")") }
            var body: BSONDocument = ["distinct": name, "key": .string(key)]
            if let query = try document(args, 1, "distinct's filter is a document") { body["query"] = .document(query) }
            return MongoCommand(collection: collection, method: "distinct", body: body, action: .distinct)
        case "insertOne", "insertMany", "insert":
            try only(chain)
            var documents: [BSONDocument]
            if call.name == "insertMany" || (call.name == "insert" && args.first?.array != nil) {
                guard let items = args.first?.array, !items.isEmpty else { throw MongoShellError(message: "insertMany takes documents: insertMany([{ … }, { … }])") }
                documents = try items.map {
                    guard let d = $0.document else { throw MongoShellError(message: "insertMany takes documents, and one isn't") }
                    return d
                }
            } else {
                guard let d = try document(args, 0, "\(call.name) takes a document: insertOne({ name: \"Ada\" })", required: true) else {
                    throw MongoShellError(message: "\(call.name) takes a document")
                }
                documents = [d]
            }
            // The ids are made here, as drivers make them: then they can be said.
            documents = documents.map { document in
                guard document["_id"] == nil else { return document }
                var withID = BSONDocument([("_id", .objectId(.generate()))])
                withID.fields += document.fields
                return withID
            }
            var body: BSONDocument = ["insert": name, "documents": .array(documents.map(BSONValue.document))]
            if let ordered = try document(args, 1, "\(call.name)'s options are a document")?["ordered"] { body["ordered"] = ordered }
            return MongoCommand(collection: collection, method: call.name, body: body, action: .write)
        case "updateOne", "updateMany", "replaceOne":
            try only(chain)
            guard let filter = try document(args, 0, "\(call.name) takes a filter first", required: true), args.count >= 2 else {
                throw MongoShellError(message: "\(call.name) takes a filter and \(call.name == "replaceOne" ? "a document" : "an update"): \(call.name)({ _id: 1 }, { $set: { a: 1 } })")
            }
            let update = args[1]
            if call.name == "replaceOne" {
                guard let d = update.document, !d.keys.contains(where: { $0.hasPrefix("$") }) else {
                    throw MongoShellError(message: "replaceOne takes a whole document, without $ operators — updateOne takes those")
                }
            } else if let d = update.document {
                guard let first = d.keys.first, first.hasPrefix("$") else {
                    throw MongoShellError(message: "\(call.name)'s update needs operators — { $set: { … } }; replaceOne replaces a whole document")
                }
            } else if update.array == nil {
                throw MongoShellError(message: "\(call.name)'s update is a document or a pipeline")
            }
            var statement: BSONDocument = ["q": .document(filter), "u": update, "multi": .bool(call.name == "updateMany")]
            for option in try document(args, 2, "\(call.name)'s options are a document")?.fields ?? []
            where ["upsert", "arrayFilters", "collation", "hint"].contains(option.key) {
                statement[option.key] = option.value
            }
            return MongoCommand(
                collection: collection, method: call.name, body: ["update": name, "updates": .array([.document(statement)])], action: .write)
        case "deleteOne", "deleteMany", "remove":
            try only(chain)
            guard let filter = try document(args, 0, "\(call.name) takes a filter — {} for every document", required: true) else {
                throw MongoShellError(message: "\(call.name) takes a filter")
            }
            var statement: BSONDocument = ["q": .document(filter), "limit": .int32(call.name == "deleteOne" ? 1 : 0)]
            for option in try document(args, 1, "\(call.name)'s options are a document")?.fields ?? [] where ["collation", "hint"].contains(option.key) {
                statement[option.key] = option.value
            }
            return MongoCommand(
                collection: collection, method: call.name, body: ["delete": name, "deletes": .array([.document(statement)])], action: .write)
        case "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete":
            try only(chain)
            let filter = try document(args, 0, "\(call.name) takes a filter first", required: true) ?? [:]
            var body: BSONDocument = ["findAndModify": name, "query": .document(filter)]
            let optionsIndex = call.name == "findOneAndDelete" ? 1 : 2
            if call.name == "findOneAndDelete" {
                body["remove"] = .bool(true)
            } else {
                guard args.count >= 2 else { throw MongoShellError(message: "\(call.name) takes a filter and \(call.name == "findOneAndUpdate" ? "an update" : "a document")") }
                body["update"] = args[1]
            }
            for option in try document(args, optionsIndex, "\(call.name)'s options are a document")?.fields ?? [] {
                switch option.key {
                case "returnDocument": body["new"] = .bool(option.value.string == "after")
                case "returnNewDocument": body["new"] = option.value
                case "projection": body["fields"] = option.value
                case "sort", "upsert", "arrayFilters", "collation", "hint": body[option.key] = option.value
                default: break
                }
            }
            return MongoCommand(collection: collection, method: call.name, body: body, action: .findAndModify)
        case "drop":
            try only(chain)
            return MongoCommand(collection: collection, method: "drop", body: ["drop": name], action: .command)
        case "createIndex":
            try only(chain)
            guard let keys = try document(args, 0, "createIndex takes its keys: createIndex({ email: 1 })", required: true) else {
                throw MongoShellError(message: "createIndex takes its keys")
            }
            var index: BSONDocument = ["key": .document(keys), "name": .string(indexName(keys))]
            for option in try document(args, 1, "createIndex's options are a document")?.fields ?? [] { index[option.key] = option.value }
            return MongoCommand(
                collection: collection, method: "createIndex", body: ["createIndexes": name, "indexes": .array([.document(index)])], action: .command)
        case "dropIndex":
            try only(chain)
            guard let index = args.first, index.string != nil || index.document != nil else {
                throw MongoShellError(message: "dropIndex takes an index's name or its keys")
            }
            return MongoCommand(collection: collection, method: "dropIndex", body: ["dropIndexes": name, "index": index], action: .command)
        case "getIndexes":
            try only(chain)
            return MongoCommand(collection: collection, method: "getIndexes", body: ["listIndexes": name], action: .cursor)
        case "stats":
            try only(chain)
            return MongoCommand(collection: collection, method: "stats", body: ["collStats": name], action: .command)
        default:
            throw MongoShellError(
                message:
                    "\(call.name)() isn't one the console knows — find, findOne, aggregate, countDocuments, distinct, insertOne/Many, updateOne/Many, replaceOne, deleteOne/Many, drop, createIndex, getIndexes do"
            )
        }
    }

    /// An index's name as the server would make it: `email_1_age_-1`.
    static func indexName(_ keys: BSONDocument) -> String {
        keys.fields.map { field in
            let direction = field.value.string ?? field.value.int.map(String.init) ?? field.value.shell
            return "\(field.key)_\(direction)"
        }.joined(separator: "_")
    }
}

// MARK: Results

/// An answer as the grid shows it: documents a row each, their top-level
/// fields as columns across the page (the first one's order, then each new
/// one as it is met; `_id` first), nested values as the shell writes them.
enum MongoResult {
    static func rows(_ documents: [BSONDocument], limit: Int) -> QueryResult {
        var columns: [String] = []
        var types: [String: String] = [:]
        var seen: Set<String> = []
        let shown = Array(documents.prefix(limit))
        for document in shown {
            for field in document.fields where !seen.contains(field.key) {
                seen.insert(field.key)
                if field.key == "_id" { columns.insert(field.key, at: 0) } else { columns.append(field.key) }
            }
            for field in document.fields where types[field.key] == nil || types[field.key] == "null" { types[field.key] = field.value.typeName }
        }
        var result = QueryResult()
        result.columns = columns
        result.types = columns.map { types[$0] ?? "" }
        result.rows = shown.map { document in columns.map { document[$0]?.cell } }
        result.truncated = documents.count > limit
        return result
    }

    /// One document as `field | value` rows: a command's answer.
    static func fields(_ document: BSONDocument) -> QueryResult {
        var result = QueryResult()
        result.columns = ["field", "value"]
        result.types = ["", ""]
        result.rows = document.fields.map { [$0.key, $0.value.cell] }
        return result
    }

    /// Values a row each: distinct's.
    static func values(_ values: [BSONValue], limit: Int) -> QueryResult {
        var result = QueryResult()
        result.columns = ["value"]
        result.types = [values.first?.typeName ?? ""]
        result.rows = values.prefix(limit).map { [$0.cell] }
        result.truncated = values.count > limit
        return result
    }

    /// A write's answer: what it did, said.
    static func write(_ reply: BSONDocument, command: MongoCommand) -> QueryResult {
        var result = QueryResult()
        let n = reply["n"]?.int ?? 0
        switch command.name {
        case "insert":
            result.affected = n
            result.message = "\(n) inserted"
            let ids = (command.body["documents"]?.array ?? []).compactMap { $0.document?["_id"] }
            if !ids.isEmpty {
                result.columns = ["_id"]
                result.types = [ids[0].typeName]
                result.rows = ids.prefix(n).map { [$0.cell] }
            }
        case "update":
            let modified = reply["nModified"]?.int ?? 0
            let upserted = reply["upserted"]?.array ?? []
            result.affected = modified + upserted.count
            var said = "\(n - upserted.count) matched, \(modified) modified"
            if !upserted.isEmpty { said += ", \(upserted.count) upserted" }
            result.message = said
            if !upserted.isEmpty {
                let ids = upserted.compactMap { $0.document?["_id"] }
                result.columns = ["upserted _id"]
                result.types = [ids.first?.typeName ?? ""]
                result.rows = ids.map { [$0.cell] }
            }
        case "delete":
            result.affected = n
            result.message = "\(n) deleted"
        default:
            result.message = "Done"
        }
        if let errors = reply["writeErrors"]?.array, !errors.isEmpty {
            let first = errors[0].document?["errmsg"]?.string ?? "a write failed"
            result.message = (result.message ?? "") + " — \(errors.count) failed: \(first)"
        }
        return result
    }
}

// MARK: Completion

/// What a MongoDB console completes: a collection after `db.`, a method
/// after `db.<collection>.`, and a statement's start.
enum MongoCompletion {
    static let collectionMethods: [(String, String)] = [
        ("find", "({ filter }, { projection }).sort({ … }).limit(n)"), ("findOne", "({ filter })"), ("aggregate", "([{ $match: … }, …])"),
        ("countDocuments", "({ filter })"), ("estimatedDocumentCount", "()"), ("distinct", "(\"field\", { filter })"),
        ("insertOne", "({ … })"), ("insertMany", "([{ … }, …])"), ("updateOne", "({ filter }, { $set: { … } })"),
        ("updateMany", "({ filter }, { $set: { … } })"), ("replaceOne", "({ filter }, { … })"), ("deleteOne", "({ filter })"),
        ("deleteMany", "({ filter })"), ("findOneAndUpdate", "({ filter }, { $set: … }, { returnDocument: \"after\" })"),
        ("findOneAndDelete", "({ filter })"), ("createIndex", "({ field: 1 }, { unique: true })"), ("getIndexes", "()"),
        ("dropIndex", "(\"name\")"), ("stats", "()"), ("drop", "()"),
    ]

    static let databaseMethods: [(String, String)] = [
        ("runCommand", "({ ping: 1 })"), ("adminCommand", "({ … })"), ("getCollection", "(\"name\")"), ("getSiblingDB", "(\"name\")"),
        ("getCollectionNames", "()"), ("createCollection", "(\"name\")"), ("stats", "()"), ("dropDatabase", "()"),
    ]

    struct Answer: Equatable {
        var typed: String
        var candidates: [SQLCompletion.Candidate]
    }

    static func complete(_ before: String, collections: [String]) -> Answer? {
        let line = String(before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        if let match = line.range(of: #"\bdb\.([A-Za-z0-9_$]+)\.([A-Za-z]*)$"#, options: .regularExpression) {
            let typed = String(line[match].split(separator: ".", omittingEmptySubsequences: false).last ?? "")
            let found = collectionMethods.filter { $0.0.hasPrefix(typed) && $0.0 != typed }
            guard !found.isEmpty else { return nil }
            return Answer(typed: typed, candidates: found.map { .init(label: $0.0, insert: $0.0 + "(", kind: .keyword, detail: $0.1) })
        }
        if let match = line.range(of: #"\bdb\.([A-Za-z0-9_$]*)$"#, options: .regularExpression) {
            let typed = String(line[match].dropFirst(3))
            let names = collections.filter { $0.hasPrefix(typed) && $0 != typed }.sorted().prefix(200)
            let plain = names.map { name -> SQLCompletion.Candidate in
                let bare = name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
                return .init(label: name, insert: bare ? name + "." : "getCollection(\(BSONText.quoted(name))).", kind: .table, detail: "collection")
            }
            let methods = databaseMethods.filter { $0.0.hasPrefix(typed) && $0.0 != typed }
                .map { SQLCompletion.Candidate(label: $0.0, insert: $0.0 + "(", kind: .keyword, detail: $0.1) }
            let all = plain + methods
            return all.isEmpty ? nil : Answer(typed: typed, candidates: all)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains(".") else { return nil }
        let starts = ["db.", "show dbs", "show collections", "use "].filter { $0.hasPrefix(trimmed) && $0 != trimmed }
        guard !starts.isEmpty else { return nil }
        return Answer(typed: trimmed, candidates: starts.map { .init(label: $0, insert: $0, kind: .keyword, detail: "") })
    }
}
