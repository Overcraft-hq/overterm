import Foundation

/// Redis as the database client reads it — pure, so it is tested without a
/// server: RESP's values, a command line as redis-cli splits it, which
/// commands only read and which destroy, and a reply as the grid's rows.
enum RedisValue: Equatable, Sendable {
    case simple(String)
    case error(String)
    case integer(Int)
    /// nil: RESP's null bulk string.
    case bulk(Data?)
    /// nil: RESP's null array.
    case array([RedisValue]?)

    /// What redis-cli would print for it, on one line.
    var text: String? {
        switch self {
        case .simple(let s), .error(let s): s
        case .integer(let n): String(n)
        case .bulk(let data): data.map(RedisValue.string)
        case .array(let items): items.map { "[" + $0.map { $0.text ?? "nil" }.joined(separator: ", ") + "]" }
        }
    }

    /// Bytes as text: UTF-8, else redis-cli's escapes ("\xff").
    static func string(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return data.map { byte in
            (0x20...0x7E).contains(byte) && byte != 0x5C ? String(UnicodeScalar(byte)) : String(format: "\\x%02x", byte)
        }.joined()
    }
}

enum RedisProtocol {
    /// A command as RESP sends it: an array of bulk strings.
    static func encode(_ arguments: [String]) -> Data {
        var out = Data("*\(arguments.count)\r\n".utf8)
        for argument in arguments {
            let bytes = Data(argument.utf8)
            out.append(Data("$\(bytes.count)\r\n".utf8))
            out.append(bytes)
            out.append(Data("\r\n".utf8))
        }
        return out
    }

    enum ParseError: Error, Equatable { case malformed(String) }

    /// One value from the front of `bytes`, and how many bytes it took —
    /// nil while it hasn't all arrived.
    static func decode(_ bytes: [UInt8], from start: Int = 0) throws -> (RedisValue, Int)? {
        guard start < bytes.count else { return nil }
        func line(at index: Int) -> (String, Int)? {
            var i = index
            while i + 1 < bytes.count {
                if bytes[i] == 0x0D, bytes[i + 1] == 0x0A {
                    return (String(decoding: bytes[index..<i], as: UTF8.self), i + 2)
                }
                i += 1
            }
            return nil
        }
        let kind = bytes[start]
        guard let (header, next) = line(at: start + 1) else { return nil }
        switch kind {
        case UInt8(ascii: "+"): return (.simple(header), next - start)
        case UInt8(ascii: "-"): return (.error(header), next - start)
        case UInt8(ascii: ":"):
            guard let n = Int(header) else { throw ParseError.malformed("integer \(header)") }
            return (.integer(n), next - start)
        case UInt8(ascii: "$"):
            guard let length = Int(header) else { throw ParseError.malformed("bulk length \(header)") }
            if length < 0 { return (.bulk(nil), next - start) }
            guard next + length + 2 <= bytes.count else { return nil }
            return (.bulk(Data(bytes[next..<(next + length)])), next + length + 2 - start)
        case UInt8(ascii: "*"):
            guard let count = Int(header) else { throw ParseError.malformed("array length \(header)") }
            if count < 0 { return (.array(nil), next - start) }
            var items: [RedisValue] = []
            var at = next
            for _ in 0..<count {
                guard let (item, used) = try decode(bytes, from: at) else { return nil }
                items.append(item)
                at += used
            }
            return (.array(items), at - start)
        default:
            throw ParseError.malformed("type byte \(kind)")
        }
    }

    /// A command line as redis-cli splits it: words, "double quotes" with
    /// \n \t \" \\ \xHH, 'single quotes' with \' only.
    static func words(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        let chars = Array(line)
        var i = 0
        func hex(_ c: Character) -> UInt8? { c.hexDigitValue.map(UInt8.init) }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                let quote = c
                inWord = true
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == quote {
                        closed = true
                        i += 1
                        break
                    }
                    if d == "\\", i + 1 < chars.count {
                        let e = chars[i + 1]
                        if quote == "'" {
                            if e == "'" {
                                current.append("'")
                                i += 2
                                continue
                            }
                        } else {
                            switch e {
                            case "n": current.append("\n")
                            case "r": current.append("\r")
                            case "t": current.append("\t")
                            case "x" where i + 3 < chars.count:
                                if let high = hex(chars[i + 2]), let low = hex(chars[i + 3]) {
                                    current.unicodeScalars.append(UnicodeScalar(high << 4 | low))
                                    i += 4
                                    continue
                                }
                                current.append(e)
                            default: current.append(e)
                            }
                            i += 2
                            continue
                        }
                    }
                    current.append(d)
                    i += 1
                }
                guard closed else { throw ParseError.malformed("unbalanced quotes") }
                // A closing quote must end the word, as redis-cli has it.
                if i < chars.count, !chars[i].isWhitespace { throw ParseError.malformed("closing quote must be followed by a space") }
                continue
            }
            if c.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(c)
                inWord = true
            }
            i += 1
        }
        if inWord { words.append(current) }
        return words
    }

    /// A key as a command line writes it: bare when it can be.
    static func quoted(_ key: String) -> String {
        let plain = !key.isEmpty && key.allSatisfy { !$0.isWhitespace && $0 != "\"" && $0 != "'" && $0 != "\\" }
        if plain { return key }
        return "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// A Redis console's text, as SQLText is a SQL console's: a command a line,
/// what each does.
enum RedisText {
    /// Each command: a line with something on it, `#` lines skipped.
    static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !line.hasPrefix("#") { found.append(range) }
        }
        return found
    }

    /// The command on the caret's line, if it has one.
    static func statement(at caret: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(caret, max(0, ns.length - 1)), length: 0))
        var trimmed = line
        while trimmed.length > 0, let last = ns.substring(with: NSRange(location: NSMaxRange(trimmed) - 1, length: 1)).first, last.isNewline {
            trimmed.length -= 1
        }
        let content = ns.substring(with: trimmed).trimmingCharacters(in: .whitespaces)
        return content.isEmpty || content.hasPrefix("#") ? nil : trimmed
    }

    /// The command's name, upper case — with its subcommand for the ones
    /// that have them (CONFIG GET, CLIENT LIST).
    static func verb(of command: String) -> String {
        let words = (try? RedisProtocol.words(command)) ?? command.split(separator: " ").map(String.init)
        guard let first = words.first?.uppercased() else { return "" }
        if Self.withSubcommand.contains(first), words.count > 1 { return first + " " + words[1].uppercased() }
        return first
    }

    static let withSubcommand: Set<String> = ["CONFIG", "CLIENT", "OBJECT", "MEMORY", "SCRIPT", "FUNCTION", "CLUSTER", "XINFO", "COMMAND", "ACL", "PUBSUB"]

    /// Commands that only read: everything else is refused on a read-only
    /// connection.
    static let reads: Set<String> = [
        "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DBSIZE",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN", "HSCAN", "HRANDFIELD",
        "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SCARD", "SISMEMBER", "SMISMEMBER", "SRANDMEMBER", "SSCAN", "SINTER", "SUNION", "SDIFF",
        "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT", "ZRANK",
        "ZREVRANK", "ZSCAN", "ZRANDMEMBER", "ZLEXCOUNT",
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XPENDING", "XINFO STREAM", "XINFO GROUPS", "XINFO CONSUMERS",
        "BITCOUNT", "GETBIT", "BITPOS", "PFCOUNT", "GEOPOS", "GEODIST", "GEOSEARCH", "GEOHASH",
        "INFO", "PING", "ECHO", "TIME", "LASTSAVE", "SELECT", "ROLE", "DUMP",
        "CONFIG GET", "CLIENT LIST", "CLIENT INFO", "CLIENT GETNAME", "OBJECT ENCODING", "OBJECT IDLETIME", "OBJECT FREQ",
        "MEMORY USAGE", "MEMORY STATS", "COMMAND COUNT", "COMMAND INFO", "COMMAND DOCS", "SLOWLOG", "PUBSUB CHANNELS",
        "JSON.GET", "JSON.TYPE", "JSON.MGET", "JSON.STRLEN", "JSON.ARRLEN", "JSON.OBJKEYS",
        // Overterm's own: a key's value, whatever its type.
        "VIEW",
    ]

    static func onlyReads(_ command: String) -> Bool { reads.contains(verb(of: command)) }

    /// Why a command should be asked about first; nil when it needn't be.
    static func danger(of command: String) -> String? {
        let verb = verb(of: command)
        let words = (try? RedisProtocol.words(command)) ?? []
        switch verb {
        case "FLUSHALL": return "FLUSHALL deletes every key in every database on this server."
        case "FLUSHDB": return "FLUSHDB deletes every key in this database."
        case "DEL", "UNLINK":
            let keys = words.count - 1
            return "\(verb) deletes \(keys == 1 ? "the key" : "\(keys) keys") for good."
        case "KEYS": return "KEYS walks every key and blocks the server while it does — SCAN doesn't."
        case "SHUTDOWN": return "SHUTDOWN stops the server."
        case "SWAPDB": return "SWAPDB swaps two whole databases."
        case "CONFIG SET", "CONFIG REWRITE", "CONFIG RESETSTAT": return "\(verb) changes the server's configuration."
        case "SCRIPT FLUSH", "FUNCTION FLUSH": return "\(verb) removes every script on the server."
        case "REPLICAOF", "SLAVEOF": return "\(verb) makes this server another's replica."
        case "DEBUG", "MIGRATE", "CLUSTER RESET", "CLUSTER FAILOVER": return "\(verb) changes the server itself."
        default: return nil
        }
    }
}

/// A reply as the grid shows it.
enum RedisResult {
    /// Replies that are field, value, field, value…
    static let pairs: Set<String> = ["HGETALL", "CONFIG GET", "HRANDFIELD"]

    static func result(of command: [String], reply: RedisValue, limit: Int) throws -> QueryResult {
        let verb = RedisText.verb(of: command.map(RedisProtocol.quoted).joined(separator: " "))
        let upper = command.map { $0.uppercased() }
        func table(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
            QueryResult(
                columns: columns, types: columns.map { _ in "" }, rows: Array(rows.prefix(limit)), truncated: rows.count > limit)
        }
        switch reply {
        case .error(let message):
            throw DatabaseError.failed(message)
        case .simple(let text):
            return QueryResult(message: text)
        case .integer(let n):
            var result = table(["value"], [[String(n)]])
            result.types = ["integer"]
            return result
        case .bulk(let data):
            // INFO's sections, as a table of what it says.
            if verb == "INFO", let text = data.map(RedisValue.string) { return table(["key", "value"], info(text)) }
            return table(["value"], [[data.map(RedisValue.string)]])
        case .array(nil):
            return table(["value"], [[nil]])
        case .array(let items?):
            if pairs.contains(verb) || (verb == "HRANDFIELD" && upper.contains("WITHVALUES")) {
                return table(["field", "value"], stride(from: 0, to: items.count - 1, by: 2).map { [items[$0].text, items[$0 + 1].text] })
            }
            if verb.hasPrefix("Z"), upper.contains("WITHSCORES") {
                return table(["member", "score"], stride(from: 0, to: items.count - 1, by: 2).map { [items[$0].text, items[$0 + 1].text] })
            }
            if ["SCAN", "HSCAN", "SSCAN", "ZSCAN"].contains(verb), items.count == 2, case .array(let found?) = items[1] {
                var result: QueryResult
                switch verb {
                case "HSCAN": result = table(["field", "value"], stride(from: 0, to: found.count - 1, by: 2).map { [found[$0].text, found[$0 + 1].text] })
                case "ZSCAN": result = table(["member", "score"], stride(from: 0, to: found.count - 1, by: 2).map { [found[$0].text, found[$0 + 1].text] })
                default: result = table(["value"], found.map { [$0.text] })
                }
                result.message = "Cursor \(items[0].text ?? "0")" + (items[0].text == "0" ? " — the whole scan" : " — SCAN again from it for more")
                return result
            }
            if ["XRANGE", "XREVRANGE"].contains(verb) { return table(["id", "fields"], items.map(streamEntry)) }
            return table(["#", "value"], items.enumerated().map { [String($0.offset + 1), $0.element.text] })
        }
    }

    /// A stream entry: its id, and its fields as `field=value` pairs.
    static func streamEntry(_ value: RedisValue) -> [String?] {
        guard case .array(let parts?) = value, parts.count == 2, case .array(let fields?) = parts[1] else { return [value.text, nil] }
        let pairs = stride(from: 0, to: fields.count - 1, by: 2).map { "\(fields[$0].text ?? "")=\(fields[$0 + 1].text ?? "")" }
        return [parts[0].text, pairs.joined(separator: ", ")]
    }

    /// INFO's `key:value` lines (its `# Section` headers left out).
    static func info(_ text: String) -> [[String?]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            return [String(line[..<colon]), String(line[line.index(after: colon)...])]
        }
    }

    /// INFO keyspace's `db0:keys=3,expires=0,…`: each database's number and keys.
    static func keyspace(_ text: String) -> [(db: Int, keys: Int)] {
        info(text).compactMap { row in
            guard let name = row[0], name.hasPrefix("db"), let db = Int(name.dropFirst(2)), let fields = row[1] else { return nil }
            let keys = fields.split(separator: ",").first { $0.hasPrefix("keys=") }.flatMap { Int($0.dropFirst(5)) } ?? 0
            return (db, keys)
        }
    }
}

/// What a console's text is to its connection: SQL statements ended by
/// `;`, or Redis commands a line. Everything that splits, checks or names
/// a statement asks this, never SQLText directly.
extension DatabaseKind {
    func statements(in text: String) -> [NSRange] { isRedis ? RedisText.statements(in: text) : SQLText.statements(in: text) }
    func statement(at caret: Int, in text: String) -> NSRange? {
        isRedis ? RedisText.statement(at: caret, in: text) : SQLText.statement(at: caret, in: text)
    }
    func verb(of statement: String) -> String { isRedis ? RedisText.verb(of: statement) : SQLText.verb(of: statement) }
    func onlyReads(_ statement: String) -> Bool { isRedis ? RedisText.onlyReads(statement) : SQLText.onlyReads(statement) }
    /// What an agent may run without asking.
    func agentReads(_ statement: String) -> Bool { isRedis ? RedisText.onlyReads(statement) : SQLText.agentReads(statement) }
    func danger(of statement: String) -> String? { isRedis ? RedisText.danger(of: statement) : SQLText.danger(of: statement) }
    /// What a statement is about, for a tab's name and an export's: its
    /// first table, or a Redis command's key.
    func subject(of statement: String) -> String? {
        if isRedis {
            let words = (try? RedisProtocol.words(statement)) ?? []
            let skip = RedisText.withSubcommand.contains(words.first?.uppercased() ?? "") ? 2 : 1
            return words.count > skip ? words[skip] : nil
        }
        return SQLText.tables(in: statement).first?.name
    }
}

/// What a Redis console completes: a command's name at a line's start —
/// with how it is written — and a key, from the browser's keys, where the
/// command takes one.
enum RedisCompletion {
    /// Commands, and how each is written.
    static let commands: [(String, String)] = [
        ("GET", "key"), ("SET", "key value [EX seconds] [NX|XX] [KEEPTTL]"), ("MGET", "key [key …]"), ("MSET", "key value [key value …]"),
        ("INCR", "key"), ("INCRBY", "key increment"), ("DECR", "key"), ("APPEND", "key value"), ("GETRANGE", "key start end"),
        ("STRLEN", "key"), ("GETDEL", "key"), ("GETEX", "key [EX seconds|PERSIST]"), ("SETEX", "key seconds value"), ("SETNX", "key value"),
        ("DEL", "key [key …]"), ("UNLINK", "key [key …]"), ("EXISTS", "key [key …]"), ("TYPE", "key"), ("RENAME", "key newkey"),
        ("RENAMENX", "key newkey"), ("EXPIRE", "key seconds"), ("PEXPIRE", "key milliseconds"), ("PERSIST", "key"), ("TTL", "key"),
        ("PTTL", "key"), ("SCAN", "cursor [MATCH pattern] [COUNT count] [TYPE type]"), ("KEYS", "pattern"), ("RANDOMKEY", ""),
        ("DBSIZE", ""), ("SELECT", "index"), ("COPY", "source destination [DB index] [REPLACE]"), ("DUMP", "key"),
        ("HGET", "key field"), ("HSET", "key field value [field value …]"), ("HGETALL", "key"), ("HDEL", "key field [field …]"),
        ("HKEYS", "key"), ("HVALS", "key"), ("HLEN", "key"), ("HEXISTS", "key field"), ("HINCRBY", "key field increment"),
        ("HMGET", "key field [field …]"), ("HSCAN", "key cursor [MATCH pattern] [COUNT count]"), ("HRANDFIELD", "key [count [WITHVALUES]]"),
        ("LPUSH", "key element [element …]"), ("RPUSH", "key element [element …]"), ("LPOP", "key [count]"), ("RPOP", "key [count]"),
        ("LRANGE", "key start stop"), ("LLEN", "key"), ("LINDEX", "key index"), ("LSET", "key index element"), ("LREM", "key count element"),
        ("LTRIM", "key start stop"), ("LPOS", "key element"), ("LMOVE", "source destination LEFT|RIGHT LEFT|RIGHT"),
        ("SADD", "key member [member …]"), ("SREM", "key member [member …]"), ("SMEMBERS", "key"), ("SCARD", "key"),
        ("SISMEMBER", "key member"), ("SSCAN", "key cursor [MATCH pattern] [COUNT count]"), ("SINTER", "key [key …]"),
        ("SUNION", "key [key …]"), ("SDIFF", "key [key …]"), ("SRANDMEMBER", "key [count]"), ("SPOP", "key [count]"),
        ("ZADD", "key score member [score member …]"), ("ZREM", "key member [member …]"), ("ZRANGE", "key start stop [BYSCORE|BYLEX] [REV] [WITHSCORES]"),
        ("ZREVRANGE", "key start stop [WITHSCORES]"), ("ZRANGEBYSCORE", "key min max [WITHSCORES]"), ("ZSCORE", "key member"),
        ("ZINCRBY", "key increment member"), ("ZCARD", "key"), ("ZCOUNT", "key min max"), ("ZRANK", "key member"),
        ("ZSCAN", "key cursor [MATCH pattern] [COUNT count]"), ("ZPOPMIN", "key [count]"), ("ZPOPMAX", "key [count]"),
        ("XADD", "key * field value [field value …]"), ("XRANGE", "key start end [COUNT count]"), ("XREVRANGE", "key end start [COUNT count]"),
        ("XLEN", "key"), ("XDEL", "key id [id …]"), ("XTRIM", "key MAXLEN count"), ("XREAD", "[COUNT count] STREAMS key id"),
        ("XINFO", "STREAM|GROUPS|CONSUMERS key"), ("XGROUP", "CREATE key group id"), ("XPENDING", "key group"),
        ("JSON.GET", "key [path]"), ("JSON.SET", "key path value"), ("JSON.DEL", "key [path]"), ("JSON.TYPE", "key [path]"),
        ("PFADD", "key element [element …]"), ("PFCOUNT", "key [key …]"), ("GEOADD", "key longitude latitude member"),
        ("GEOSEARCH", "key FROMLONLAT lon lat BYRADIUS radius m"), ("SETBIT", "key offset value"), ("GETBIT", "key offset"),
        ("BITCOUNT", "key"), ("PUBLISH", "channel message"), ("PUBSUB", "CHANNELS [pattern]"), ("OBJECT", "ENCODING|IDLETIME|FREQ key"),
        ("MEMORY", "USAGE key"), ("INFO", "[section]"), ("CONFIG", "GET parameter"), ("CLIENT", "LIST|INFO|KILL"), ("SLOWLOG", "GET [count]"),
        ("PING", ""), ("ECHO", "message"), ("TIME", ""), ("ROLE", ""), ("FLUSHDB", "[ASYNC]"), ("EVAL", "script numkeys [key …] [arg …]"),
        ("VIEW", "key — Overterm's: a key's value, whatever its type"),
    ]

    /// Commands whose first argument isn't a key.
    static let keyless: Set<String> = [
        "SCAN", "KEYS", "SELECT", "INFO", "CONFIG", "CLIENT", "SLOWLOG", "PING", "ECHO", "TIME", "ROLE", "FLUSHDB", "FLUSHALL", "PUBLISH",
        "PUBSUB", "OBJECT", "MEMORY", "EVAL", "XREAD", "XINFO", "XGROUP", "MSET", "DBSIZE", "RANDOMKEY",
    ]

    struct Answer: Equatable {
        /// What was typed of the word being completed.
        var typed: String
        var candidates: [SQLCompletion.Candidate]
    }

    /// The candidates for a line's text up to the caret.
    static func complete(_ before: String, keys: [String]) -> Answer? {
        let line = String(before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"), !line.contains("\""), !line.contains("'") else { return nil }
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let typing = line.last.map { !$0.isWhitespace } ?? false
        let typed = typing ? words.last ?? "" : ""
        let position = typing ? words.count - 1 : words.count
        if position == 0 {
            let found = commands.filter { $0.0.hasPrefix(typed.uppercased()) && $0.0 != typed.uppercased() }
            guard !found.isEmpty else { return nil }
            return Answer(typed: typed, candidates: found.map { .init(label: $0.0, insert: $0.0 + " ", kind: .keyword, detail: $0.1) })
        }
        guard position == 1, let command = words.first?.uppercased(), !keyless.contains(command),
            commands.contains(where: { $0.0 == command })
        else { return nil }
        let found = keys.filter { $0.hasPrefix(typed) && $0 != typed }.sorted().prefix(200)
        guard !found.isEmpty else { return nil }
        return Answer(typed: typed, candidates: found.map { .init(label: $0, insert: RedisProtocol.quoted($0), kind: .table, detail: "key") })
    }
}
