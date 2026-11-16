import Foundation

/// Oracle's console as SQL*Plus reads it: a SQL statement ends at `;`; a
/// PL/SQL block — `BEGIN`, `DECLARE`, `CREATE … PROCEDURE/FUNCTION/PACKAGE/
/// TRIGGER/TYPE` — has `;` inside it and ends at a line holding only `/`
/// (or the end of the text). Strings are `'…'` (doubled quote inside) and
/// `q'[…]'`; names `"…"`; comments `--` and `/* */` — never `#`, which is a
/// name's letter here. Pure.
enum OracleText: KindConsoleText {
    // MARK: Statements

    static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        let length = ns.length
        var ranges: [NSRange] = []
        var start = 0
        func add(_ end: Int) {
            let range = trimmed(NSRange(location: start, length: max(0, end - start)), in: ns)
            if range.length > 0 { ranges.append(range) }
        }
        var i = 0
        while i < length {
            // A line of `/` alone ends whatever is open, block or not.
            if i == 0 || ns.character(at: i - 1) == 0x0A, let after = slashLine(ns, at: i) {
                add(i)
                start = after
                i = after
                continue
            }
            if let end = skip(ns, at: i) {
                i = end
                continue
            }
            if ns.character(at: i) == 0x3B, !isBlock(ns.substring(with: NSRange(location: start, length: i - start))) {  // ;
                add(i)
                start = i + 1
            }
            i += 1
        }
        add(length)
        return ranges
    }

    /// Where the line after a `/`-only line at `i` starts; nil when the
    /// line at `i` isn't one.
    private static func slashLine(_ ns: NSString, at i: Int) -> Int? {
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        guard line.location == i else { return nil }
        let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "/" ? NSMaxRange(line) : nil
    }

    /// The end of a string, a quoted name or a comment starting at `i`; nil
    /// when none starts there.
    static func skip(_ ns: NSString, at i: Int) -> Int? {
        let length = ns.length
        let c = ns.character(at: i)
        func next(_ k: Int) -> unichar? { i + k < length ? ns.character(at: i + k) : nil }
        switch c {
        case 0x2D where next(1) == 0x2D:  // --
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: i, length: length - i))
            return newline.location == NSNotFound ? length : newline.location
        case 0x2F where next(1) == 0x2A:  // /*
            let close = ns.range(of: "*/", options: [], range: NSRange(location: i + 2, length: length - i - 2))
            return close.location == NSNotFound ? length : NSMaxRange(close)
        case 0x27, 0x22:  // ' "
            var j = i + 1
            while j < length {
                if ns.character(at: j) == c {
                    if j + 1 < length, ns.character(at: j + 1) == c {
                        j += 2
                        continue
                    }
                    return j + 1
                }
                j += 1
            }
            return length
        case 0x71, 0x51, 0x6E, 0x4E:  // q'…' and nq'…'
            if i > 0, isNameCharacter(ns.character(at: i - 1)) { return nil }
            var q = i
            if c == 0x6E || c == 0x4E {
                guard let after = next(1), after == 0x71 || after == 0x51 else { return nil }
                q = i + 1
            }
            guard q + 2 < length, ns.character(at: q + 1) == 0x27 else { return nil }
            let open = ns.character(at: q + 2)
            let close: unichar =
                switch open {
                case 0x5B: 0x5D  // [ ]
                case 0x7B: 0x7D  // { }
                case 0x28: 0x29  // ( )
                case 0x3C: 0x3E  // < >
                default: open
                }
            var j = q + 3
            while j + 1 < length {
                if ns.character(at: j) == close, ns.character(at: j + 1) == 0x27 { return j + 2 }
                j += 1
            }
            return length
        default:
            return nil
        }
    }

    private static func isNameCharacter(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c == 0x23 || c > 0x7F
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

    // MARK: What a statement is

    /// Its first words, upper-cased, comments skipped.
    static func words(_ statement: String, count: Int) -> [String] {
        let ns = statement as NSString
        var words: [String] = []
        var i = 0
        while i < ns.length, words.count < count {
            let c = ns.character(at: i)
            if c == 0x2D || c == 0x2F, let end = skip(ns, at: i) {
                i = end
                continue
            }
            if c == 0x3C, i + 1 < ns.length, ns.character(at: i + 1) == 0x3C {  // <<label>>
                words.append("<<")
                i += 2
                continue
            }
            if isNameCharacter(c), !(c >= 0x30 && c <= 0x39) {
                var j = i
                while j < ns.length, isNameCharacter(ns.character(at: j)) { j += 1 }
                words.append(ns.substring(with: NSRange(location: i, length: j - i)).uppercased())
                i = j
                continue
            }
            if !(Unicode.Scalar(c).map(CharacterSet.whitespacesAndNewlines.contains) ?? false) { break }
            i += 1
        }
        return words
    }

    /// PL/SQL — its `;`s are inside it, and it runs as one: an anonymous
    /// block, or the CREATE of a stored unit.
    static func isBlock(_ statement: String) -> Bool {
        var words = words(statement, count: 6)
        guard let first = words.first else { return false }
        if ["BEGIN", "DECLARE", "<<"].contains(first) { return true }
        guard first == "CREATE" else { return false }
        words.removeFirst()
        if words.starts(with: ["OR", "REPLACE"]) { words.removeFirst(2) }
        if let next = words.first, ["EDITIONABLE", "NONEDITIONABLE", "EDITIONING"].contains(next) { words.removeFirst() }
        return ["PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE", "LIBRARY", "JAVA"].contains(words.first ?? "")
    }

    static func verb(of statement: String) -> String {
        let first = words(statement, count: 1).first ?? ""
        return first == "<<" ? "BEGIN" : first
    }

    /// SQL*Plus's words the console takes too: DESC and EXEC.
    static func onlyReads(_ statement: String) -> Bool {
        guard ["SELECT", "WITH", "DESC", "DESCRIBE"].contains(verb(of: statement)) else { return false }
        // A row locked is a write's first half.
        return stripped(statement).uppercased().range(of: #"\bFOR\s+UPDATE\b"#, options: .regularExpression) == nil
    }

    /// Stricter: no write's word anywhere, nor PL/SQL declared in a WITH
    /// (12c's `WITH FUNCTION`), whose body may do anything.
    static func agentReads(_ statement: String) -> Bool {
        guard onlyReads(statement) else { return false }
        let upper = stripped(statement).uppercased()
        let writes = #"\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|CALL|EXECUTE|EXEC|LOCK|COMMIT|ROLLBACK|PURGE|FLASHBACK|RENAME)\b"#
        if upper.range(of: writes, options: .regularExpression) != nil { return false }
        if verb(of: statement) == "WITH", upper.range(of: #"^\s*WITH\s+(FUNCTION|PROCEDURE)\b"#, options: .regularExpression) != nil { return false }
        if verb(of: statement) == "SELECT", upper.range(of: #"\bINTO\b"#, options: .regularExpression) != nil { return false }
        return true
    }

    static func danger(of statement: String) -> String? {
        if isBlock(statement) {
            // A block's own statements, each as if run alone; dynamic SQL's
            // text where it is a literal.
            // A part's statement starts at its verb, past BEGIN, THEN, LOOP…;
            // a cursor's FOR UPDATE isn't one.
            let body = stripped(statement)
            let verbs = try? NSRegularExpression(pattern: #"(?i)(?<!FOR\s)\b(DELETE|UPDATE|DROP|TRUNCATE)\b"#)
            for part in body.split(separator: ";").map(String.init) {
                let ns = part as NSString
                guard let found = verbs?.firstMatch(in: part, range: NSRange(location: 0, length: ns.length)) else { continue }
                if let said = plainDanger(ns.substring(from: found.range.location)) { return said }
            }
            let dynamic = #"(?is)EXECUTE\s+IMMEDIATE\s+'\s*(DROP|TRUNCATE)\b"#
            if statement.range(of: dynamic, options: .regularExpression) != nil { return "It runs a DROP or TRUNCATE as dynamic SQL." }
            return nil
        }
        return plainDanger(statement)
    }

    private static func plainDanger(_ statement: String) -> String? {
        let words = words(statement, count: 4)
        guard let verb = words.first else { return nil }
        let upper = stripped(statement).uppercased()
        switch verb {
        case "DROP": return "It drops \(words.dropFirst().prefix(2).joined(separator: " ").lowercased())."
        case "TRUNCATE": return "It empties the table."
        case "DELETE", "UPDATE":
            return upper.range(of: #"\bWHERE\b"#, options: .regularExpression) == nil
                ? "It has no WHERE: every row of the table is \(verb == "DELETE" ? "deleted" : "changed")."
                : nil
        default: return nil
        }
    }

    static func subject(of statement: String) -> String? {
        let words = words(statement, count: 2)
        if words.first == "DESC" || words.first == "DESCRIBE" { return words.count > 1 ? words[1] : nil }
        return SQLText.tables(in: stripped(statement)).first?.name
    }

    /// The statement with its strings, quoted names and comments blanked.
    static func stripped(_ statement: String) -> String {
        let ns = statement as NSString
        var out = ""
        var i = 0
        while i < ns.length {
            if let end = skip(ns, at: i) {
                let c = ns.character(at: i)
                // A comment is nothing; a string or a name stays a word.
                if c != 0x2D, c != 0x2F { out += " '' " }
                i = end
                continue
            }
            out += String(utf16CodeUnits: [ns.character(at: i)], count: 1)
            i += 1
        }
        return out
    }

    // MARK: What is sent

    /// What the server is sent for a console's statement: SQL without its
    /// `;` (Oracle refuses one), a block as written — its last `;` added —
    /// EXEC as the block SQL*Plus makes of it. DESC is the driver's.
    static func prepared(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = words(text, count: 1).first ?? ""
        if first == "EXEC" || first == "EXECUTE" {
            let call = text.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = call.hasSuffix(";") ? String(call.dropLast()) : call
            return "BEGIN \(bare); END;"
        }
        if isBlock(text) { return text.hasSuffix(";") ? text : text + ";" }
        while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    /// `DESC [owner.]name`: the object asked about, as the dictionary
    /// spells it — upper-cased unless quoted.
    static func described(_ statement: String) -> (owner: String?, name: String)? {
        let words = words(statement, count: 1)
        guard words.first == "DESC" || words.first == "DESCRIBE" else { return nil }
        var rest = statement.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(words[0].count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while rest.hasSuffix(";") { rest.removeLast() }
        let parts = splitName(rest)
        guard !parts.isEmpty, parts.count <= 2 else { return nil }
        return (parts.count == 2 ? parts[0] : nil, parts.last!)
    }

    /// `a."b c"` → ["A", "b c"].
    static func splitName(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var wasQuoted = false
        for c in text {
            if c == "\"" {
                quoted.toggle()
                wasQuoted = true
            } else if c == ".", !quoted {
                parts.append(wasQuoted ? current : current.uppercased())
                current = ""
                wasQuoted = false
            } else if !c.isWhitespace || quoted {
                current.append(c)
            }
        }
        if !current.isEmpty { parts.append(wasQuoted ? current : current.uppercased()) }
        return parts
    }

    /// A name as SQL writes it: bare when the dictionary's spelling is
    /// what an unquoted name becomes, else quoted.
    static func quoted(_ name: String) -> String {
        if name.range(of: #"^[A-Z][A-Z0-9_$#]*$"#, options: .regularExpression) != nil { return name }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The panel's Select Top.
    static func browse(_ table: CatalogTable, limit: Int) -> String {
        "SELECT * FROM \(quoted(table.schema)).\(quoted(table.name)) FETCH FIRST \(limit) ROWS ONLY;"
    }

    /// A column's type as the dictionary's columns say it, as DESC does:
    /// VARCHAR2(100 CHAR), NUMBER(10,2), NUMBER, TIMESTAMP(6).
    static func typeName(_ type: String, length: Int?, precision: Int?, scale: Int?, charLength: Int?, charUsed: String?) -> String {
        switch type {
        case "VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR":
            let n = (type.hasPrefix("N") ? charLength : (charUsed == "C" ? charLength : length)) ?? length ?? 0
            return "\(type)(\(n)\(charUsed == "C" && !type.hasPrefix("N") ? " CHAR" : ""))"
        case "RAW": return "RAW(\(length ?? 0))"
        case "NUMBER":
            guard let precision else { return scale == 0 ? "INTEGER" : "NUMBER" }
            return scale.map { $0 == 0 ? "NUMBER(\(precision))" : "NUMBER(\(precision),\($0))" } ?? "NUMBER(\(precision))"
        case "FLOAT": return precision.map { "FLOAT(\($0))" } ?? "FLOAT"
        default: return type
        }
    }
}

/// What a pasted Easy Connect string or URL says: `host:port/service`,
/// `//host/service`, `tcps://host:2484/service?…`, `host:port:SID`, the
/// SQL*Plus way with a login in front (`user/password@host/service`), and a
/// JDBC URL (`jdbc:oracle:thin:@…`). A password in it is handed back — the
/// form keeps it, then the keychain. Pure.
enum OracleAddress {
    struct Filled: Equatable {
        var host: String
        var port: Int?
        /// A service name, or a SID (`sid` true).
        var service: String
        var sid = false
        var tls = false
        var user: String?
        var password: String?
    }

    static func parse(_ text: String) -> Filled? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("(") else { return nil }
        var user: String?
        var password: String?
        for prefix in ["jdbc:oracle:thin:", "jdbc:oracle:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        // `user/password@` (SQL*Plus) or `user@` in front; the last `@`, as a
        // password may hold one.
        if let at = text.lastIndex(of: "@") {
            let login = String(text[..<at])
            text = String(text[text.index(after: at)...])
            if !login.isEmpty {
                if let slash = login.firstIndex(of: "/") {
                    user = String(login[..<slash])
                    password = String(login[login.index(after: slash)...])
                } else {
                    user = login
                }
            }
        }
        var tls = false
        if let scheme = text.range(of: "://") {
            tls = text[..<scheme.lowerBound].lowercased() == "tcps"
            text = String(text[scheme.upperBound...])
        }
        if text.hasPrefix("//") { text.removeFirst(2) }
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        // host[:port][/service[:server][/instance]] — or host:port:SID.
        let slash = text.firstIndex(of: "/")
        let place = String(text[..<(slash ?? text.endIndex)])
        var service = slash.map { String(text[text.index(after: $0)...]) } ?? ""
        if let colon = service.firstIndex(of: ":") { service = String(service[..<colon]) }
        if let instance = service.firstIndex(of: "/") { service = String(service[..<instance]) }
        var host = place
        var port: Int?
        var sid = false
        if place.hasPrefix("["), let close = place.firstIndex(of: "]") {
            host = String(place[place.index(after: place.startIndex)..<close])
            let rest = place[place.index(after: close)...]
            port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
        } else {
            let parts = place.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            host = parts[0]
            if parts.count > 1 { port = Int(parts[1]) }
            if parts.count == 3, slash == nil, !parts[2].isEmpty {
                service = parts[2]
                sid = true
            }
        }
        guard !host.isEmpty, host.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil else { return nil }
        return Filled(host: host, port: port, service: service, sid: sid, tls: tls, user: user, password: password)
    }
}

/// Oracle's values as text, from the bytes it sends: NUMBER exactly as
/// written (never through a Double), DATE and TIMESTAMP as ISO's date and
/// time, intervals as Oracle writes them. Pure.
enum OracleValueText {
    /// NUMBER's: an exponent byte, then base-100 digits (one more than the
    /// digit; 101 less when negative, with a 102 after).
    static func number(_ bytes: [UInt8]) -> String? {
        guard let first = bytes.first else { return nil }
        let positive = first & 0x80 != 0
        if bytes.count == 1 {
            // 0x80 is zero; a lone other byte is −∞ (0x00) or +∞.
            return first == 0x80 ? "0" : positive ? "Infinity" : "-Infinity"
        }
        if positive, first == 0xFF, bytes.count == 2, bytes[1] == 101 { return "Infinity" }
        let exponentByte = positive ? first : ~first
        let exponent = Int(exponentByte) - 193
        var mantissa = Array(bytes.dropFirst())
        if !positive, mantissa.last == 102 { mantissa.removeLast() }
        var digits: [UInt8] = []
        var point = exponent * 2 + 2
        for (index, byte) in mantissa.enumerated() {
            let value = positive ? Int(byte) - 1 : 101 - Int(byte)
            guard (0...99).contains(value) else { return nil }
            let tens = UInt8(value / 10)
            let ones = UInt8(value % 10)
            if index == 0, tens == 0 {
                point -= 1
            } else {
                digits.append(tens)
            }
            digits.append(ones)
        }
        while digits.last == 0, digits.count > max(point, 1) { digits.removeLast() }
        while digits.count > 1, digits.first == 0, point > 1 {
            digits.removeFirst()
            point -= 1
        }
        let text = digits.map { String($0) }.joined()
        var out: String
        if point <= 0 {
            out = "0." + String(repeating: "0", count: -point) + text
        } else if point >= digits.count {
            out = text + String(repeating: "0", count: point - digits.count)
        } else {
            let index = text.index(text.startIndex, offsetBy: point)
            out = text[..<index] + "." + text[index...]
        }
        if out.contains(".") {
            while out.hasSuffix("0") { out.removeLast() }
            if out.hasSuffix(".") { out.removeLast() }
        }
        return (positive || out == "0" ? "" : "-") + out
    }

    /// DATE (7 bytes), TIMESTAMP (11), TIMESTAMP WITH TIME ZONE (13: the
    /// time in UTC, then the zone — an offset, or a region said as UTC).
    static func dateTime(_ bytes: [UInt8], withZone: Bool) -> String? {
        guard bytes.count >= 7 else { return nil }
        var year = (Int(bytes[0]) - 100) * 100 + Int(bytes[1]) - 100
        var month = Int(bytes[2])
        var day = Int(bytes[3])
        var hour = Int(bytes[4]) - 1
        var minute = Int(bytes[5]) - 1
        let second = Int(bytes[6]) - 1
        var nanos = 0
        if bytes.count >= 11 {
            nanos = bytes[7..<11].reduce(0) { $0 << 8 | Int($1) }
        }
        var zone = ""
        if withZone, bytes.count >= 13 {
            if bytes[11] & 0x80 != 0 {
                zone = " UTC"
            } else {
                let hours = Int(bytes[11]) - 20
                let minutes = Int(bytes[12]) - 60
                // The minutes carry their own sign (−05:30 is −5 and −30).
                let offset = hours * 60 + minutes
                // The bytes are UTC: moved to the zone's own clock.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                if offset != 0,
                    let utc = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
                    let local = calendar.date(byAdding: .minute, value: offset, to: utc)
                {
                    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: local)
                    (year, month, day, hour, minute) = (parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!)
                }
                let sign = offset < 0 ? "-" : "+"
                zone = " " + sign + pad(abs(offset) / 60) + ":" + pad(abs(offset) % 60)
            }
        }
        var text = "\(year < 0 ? "-" : "")\(pad(abs(year), 4))-\(pad(month))-\(pad(day))"
        let hasTime = bytes.count > 7 || hour != 0 || minute != 0 || second != 0
        if hasTime { text += " \(pad(hour)):\(pad(minute)):\(pad(second))" + fraction(nanos) }
        return text + zone
    }

    /// INTERVAL DAY TO SECOND (11 bytes) and YEAR TO MONTH (5), as Oracle
    /// writes them: `+02 03:04:05.5`, `+1-06`.
    static func interval(_ bytes: [UInt8], yearToMonth: Bool) -> String? {
        func int32(_ slice: ArraySlice<UInt8>) -> Int { slice.reduce(0) { $0 << 8 | Int($1) } - 0x8000_0000 }
        if yearToMonth {
            guard bytes.count >= 5 else { return nil }
            let years = int32(bytes[0..<4])
            let months = Int(bytes[4]) - 60
            let negative = years < 0 || months < 0
            return "\(negative ? "-" : "+")\(abs(years))-\(pad(abs(months)))"
        }
        guard bytes.count >= 11 else { return nil }
        let days = int32(bytes[0..<4])
        let hours = Int(bytes[4]) - 60
        let minutes = Int(bytes[5]) - 60
        let seconds = Int(bytes[6]) - 60
        let nanos = int32(bytes[7..<11])
        let negative = days < 0 || hours < 0 || minutes < 0 || seconds < 0 || nanos < 0
        return "\(negative ? "-" : "+")\(abs(days)) \(pad(abs(hours))):\(pad(abs(minutes))):\(pad(abs(seconds)))" + fraction(abs(nanos))
    }

    /// RAW and a BLOB's start: upper-case hex, as SQL*Plus shows RAW.
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// A LOB said, not dumped: its start and its size.
    static func lob(_ kind: String, text: String?, bytes: Int, shown: Int = 200) -> String {
        if let text {
            let count = text.count
            guard count > shown else { return text }
            return String(text.prefix(shown)) + "… (\(kind), \(count) characters)"
        }
        return "(\(kind), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)))"
    }

    private static func fraction(_ nanos: Int) -> String {
        guard nanos > 0 else { return "" }
        var digits = pad(nanos, 9)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "." + digits
    }

    private static func pad(_ value: Int, _ width: Int = 2) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
