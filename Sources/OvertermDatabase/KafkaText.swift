import Foundation

/// Kafka's console: a small language of Overterm's, a command a line (a
/// PUBLISH's value may go on over the lines below it); a blank line or a
/// `#` comment ends one. Names with spaces go in double quotes. Pure.
///
///     TOPICS                                      every topic: partitions, replicas, messages
///     DESCRIBE <topic>                            its partitions: leader, replicas, offsets
///     PEEK <topic> [n] [PARTITION p] [FROM BEGINNING | FROM <offset>]
///     PUBLISH <topic> [PARTITION p] [KEY <key>] <value>
///     GROUPS                                      consumer groups: state, members
///     LAG <group>                                 its committed offsets, the ends, the lag
///
/// PEEK reads as no consumer group: nobody's committed offset moves, and
/// the topic's consumers never see it happened. The newest n messages
/// unless FROM says where.
package enum KafkaText: KindConsoleText {
    package enum Start: Equatable, Sendable {
        case newest
        case beginning
        case offset(Int64)
    }

    package enum Command: Equatable, Sendable {
        case topics
        case describe(String)
        case peek(topic: String, count: Int, partition: Int32?, from: Start)
        case publish(topic: String, partition: Int32?, key: String?, value: String)
        case groups
        case lag(String)
    }

    package static let terminator = ""
    package static let completesSQL = false
    package static let defaultPeek = 10
    package static let maxPeek = 1000

    package static let commands: Set<String> = ["TOPICS", "DESCRIBE", "PEEK", "PUBLISH", "GROUPS", "LAG"]

    package static let help = """
        # Kafka — a command a line; # starts a comment. Names with spaces in "double quotes".
        #   TOPICS                                   every topic: partitions, replicas, messages
        #   DESCRIBE <topic>                         its partitions: leader, replicas, in sync, offsets
        #   PEEK <topic> [n] [PARTITION p] [FROM BEGINNING | FROM <offset>]
        #                                            the newest n messages (10) — read as no group: nobody's offset moves
        #   PUBLISH <topic> [PARTITION p] [KEY <key>] <value>
        #                                            the value is the rest, as written; a key picks the partition as producers do
        #   GROUPS                                   consumer groups: state, members
        #   LAG <group>                              each partition's committed offset, end and lag

        """

    // MARK: Statements

    package static func statements(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var current: NSRange?
        func end() {
            if let range = current, range.length > 0 { ranges.append(range) }
            current = nil
        }
        var at = 0
        while at < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(lineRange)
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                end()
                continue
            }
            if line.hasPrefix("#") {
                end()
                continue
            }
            let start = lineRange.location + (ns.substring(with: lineRange).prefix { $0.isWhitespace }.utf16.count)
            let length = line.utf16.count
            if commands.contains(line.prefix { !$0.isWhitespace }.uppercased()) {
                end()
                current = NSRange(location: start, length: length)
            } else if let started = current {
                current = NSRange(location: started.location, length: start + length - started.location)
            } else {
                current = NSRange(location: start, length: length)
            }
        }
        end()
        return ranges
    }

    // MARK: Parsing

    package struct Problem: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    package static func parse(_ statement: String) throws -> Command {
        var rest = Substring(statement.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = word(&rest) else { throw Problem(message: "No command.") }
        func done(_ what: String) throws {
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem(message: what) }
        }
        switch first.uppercased() {
        case "TOPICS":
            try done("TOPICS takes nothing more.")
            return .topics
        case "GROUPS":
            try done("GROUPS takes nothing more.")
            return .groups
        case "DESCRIBE":
            guard let topic = try token(&rest) else { throw Problem(message: "DESCRIBE takes a topic: DESCRIBE orders") }
            try done("DESCRIBE takes a topic, nothing more.")
            return .describe(topic)
        case "LAG":
            guard let group = try token(&rest) else { throw Problem(message: "LAG takes a consumer group: LAG billing") }
            try done("LAG takes a group, nothing more.")
            return .lag(group)
        case "PEEK":
            guard let topic = try token(&rest) else { throw Problem(message: "PEEK takes a topic: PEEK orders 10") }
            var count = defaultPeek
            var partition: Int32?
            var from = Start.newest
            while let next = word(&rest) {
                switch next.uppercased() {
                case "PARTITION":
                    guard let p = word(&rest).flatMap({ Int32($0) }), p >= 0 else { throw Problem(message: "PARTITION takes a number: PARTITION 0") }
                    partition = p
                case "FROM":
                    guard let where_ = word(&rest) else { throw Problem(message: "FROM takes BEGINNING or an offset.") }
                    if where_.uppercased() == "BEGINNING" {
                        from = .beginning
                    } else if let offset = Int64(where_), offset >= 0 {
                        from = .offset(offset)
                    } else {
                        throw Problem(message: "FROM takes BEGINNING or an offset, not \(where_).")
                    }
                default:
                    guard let n = Int(next), n > 0 else { throw Problem(message: "PEEK's count is a number above 0, not \(next).") }
                    count = min(n, maxPeek)
                }
            }
            if case .offset = from, partition == nil { throw Problem(message: "FROM an offset needs its PARTITION: PEEK orders PARTITION 0 FROM 42") }
            return .peek(topic: topic, count: count, partition: partition, from: from)
        case "PUBLISH":
            guard let topic = try token(&rest) else { throw Problem(message: "PUBLISH takes a topic and the value: PUBLISH orders {\"id\": 1}") }
            var partition: Int32?
            var key: String?
            // Options first, then the value: whatever is left, as written.
            while true {
                var probe = rest
                guard let next = word(&probe) else { break }
                if next.uppercased() == "PARTITION" {
                    guard let p = word(&probe).flatMap({ Int32($0) }), p >= 0 else { throw Problem(message: "PARTITION takes a number: PARTITION 0") }
                    partition = p
                    rest = probe
                } else if next.uppercased() == "KEY" {
                    rest = probe
                    guard let k = try token(&rest) else { throw Problem(message: "KEY takes the message's key: KEY order-1") }
                    key = k
                } else {
                    break
                }
            }
            let value = String(rest.drop { $0 == " " || $0 == "\t" }).trimmingCharacters(in: .newlines)
            guard !value.isEmpty else { throw Problem(message: "PUBLISH needs the value after the topic.") }
            return .publish(topic: topic, partition: partition, key: key, value: value)
        default:
            throw Problem(message: "\(first) isn't a Kafka command here: TOPICS, DESCRIBE, PEEK, PUBLISH, GROUPS, LAG.")
        }
    }

    /// The next word, spaces skipped.
    private static func word(_ rest: inout Substring) -> String? {
        rest = rest.drop { $0.isWhitespace }
        guard !rest.isEmpty else { return nil }
        let word = rest.prefix { !$0.isWhitespace }
        rest = rest.dropFirst(word.count)
        return String(word)
    }

    /// A name: a word, or `"…"` with `\"` inside.
    private static func token(_ rest: inout Substring) throws -> String? {
        rest = rest.drop { $0.isWhitespace }
        guard rest.first == "\"" else { return word(&rest) }
        var out = ""
        var i = rest.index(after: rest.startIndex)
        while i < rest.endIndex {
            let c = rest[i]
            if c == "\\", rest.index(after: i) < rest.endIndex {
                out.append(rest[rest.index(after: i)])
                i = rest.index(i, offsetBy: 2)
                continue
            }
            if c == "\"" {
                rest = rest[rest.index(after: i)...]
                return out
            }
            out.append(c)
            i = rest.index(after: i)
        }
        throw Problem(message: "A quoted name isn't closed.")
    }

    // MARK: What a statement does

    package static func verb(of statement: String) -> String {
        statement.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isWhitespace }.uppercased()
    }

    /// Everything reads but PUBLISH.
    package static func onlyReads(_ statement: String) -> Bool {
        guard let command = try? parse(statement) else { return false }
        if case .publish = command { return false }
        return true
    }

    package static func agentReads(_ statement: String) -> Bool { onlyReads(statement) }

    package static func danger(of statement: String) -> String? { nil }

    package static func subject(of statement: String) -> String? {
        switch try? parse(statement) {
        case .describe(let topic)?, .peek(let topic, _, _, _)?, .publish(let topic, _, _, _)?: topic
        case .lag(let group)?: group
        default: nil
        }
    }

    /// What the panel's "Select Top" runs: a topic's newest messages, a group's lag.
    package static func browse(_ table: CatalogTable, limit: Int) -> String {
        table.schema == groupsSchema ? "LAG \(quoted(table.name))" : "PEEK \(quoted(table.name)) \(min(limit, maxPeek))"
    }

    /// The tree's two: topics, and consumer groups.
    package static let topicsSchema = "topics"
    package static let groupsSchema = "groups"

    package static func quoted(_ name: String) -> String {
        name.contains(where: { $0.isWhitespace || $0 == "\"" }) || name.isEmpty
            ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : name
    }

    // MARK: Values

    /// A key's or value's bytes as the grid shows them: UTF-8 text as it
    /// is (cut at `cut`), anything else as hex and its size.
    package static func text(_ bytes: [UInt8]?, cut: Int = 50_000) -> String? {
        guard let bytes else { return nil }
        if let string = String(bytes: bytes, encoding: .utf8), !string.unicodeScalars.contains(where: { $0.value < 0x20 && !"\n\r\t".unicodeScalars.contains($0) }) {
            return string.count > cut ? String(string.prefix(cut)) + "… (\(bytes.count) bytes)" : string
        }
        let shown = bytes.prefix(32).map { String(format: "%02x", $0) }.joined()
        return "0x\(shown)\(bytes.count > 32 ? "…" : "") (\(bytes.count) bytes)"
    }
}
